package App::Clod::Claude;

# ABSTRACT: Run claude -p in a directory and read what it did

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Mojo::Base -base, -signatures;

use IPC::Run ();
use Mojo::JSON();
use Time::HiRes qw{time};

# How long to wait when a run hit the limit and did not say when it resets.
my $UNKNOWN_RESET = 1800;

# How much of each end of its stderr a run keeps in the job result.
my $STDERR_END = 2000;

=head1 WHAT CLAUDE DOES NOT GET

C<@WITHHELD> names the variables of the worker that a C<claude> run, and every
command that it runs, does not get.  By default they are C<GH_TOKEN> and
C<GITHUB_TOKEN>, the token of the bot.  A spoke run commits, and the job pushes
the branch and opens the pull request with the token itself.  With the token in
its environment, an agent that may run C<git> or C<perl> could push, or call
the API, wherever the bot can.  C<CLAUDE_CODE_OAUTH_TOKEN> stays, because
claude needs it, unless L</run_as> is set.  C<run> takes them out after it adds L</env>, so C<env> cannot
give them back.

That keeps the token out of the environment of claude, but not out of its
reach, while claude runs as the account of the worker.  A process can read
F</proc/$pid/environ> of every process of its own account, and the worker has
the token in its environment.  So set L</run_as> on a host where an agent runs
unattended.

=cut

our @WITHHELD = qw{GH_TOKEN GITHUB_TOKEN};

=attr bin

The C<claude> program.

=cut

has bin => 'claude';

=attr model

The C<--model>, or undef for the default.

=cut

has model => undef;

=attr timeout

Seconds before the run is killed.

=cut

has timeout => 3600;

=attr env

Extra environment for the child, such as the OpenTelemetry variables.

=cut

has env => sub { {} };

=attr allowed_tools

The default C<--allowedTools>.

=cut

has allowed_tools => sub { [] };

=attr run_as

The account that claude runs as, through C<sudo>, or undef to run it as the
worker.  The account cannot read F</proc/$pid/environ> of the worker, so it
cannot reach the token.  sudo needs a rule such as:

    worker ALL=(agent) NOPASSWD:SETENV: ALL

C<SETENV> is for C<--preserve-env>, which passes the names in L</env> through
the environment.  The argument list is no place for them, because C<ps> shows
it to every account.

The account brings its own C<CLAUDE_CODE_OAUTH_TOKEN>, for example from a file
that only it can read, through a L</bin> that loads it and runs claude.  The
token of the worker does not go through sudo, because sudo logs each variable
that C<--preserve-env> passes, with its value, to the journal.  C<PATH> goes to
F</usr/bin/env> as an argument instead, because the C<secure_path> of sudo
replaces it otherwise, and the git hooks of a spoke find their tools on it.
C<-H> makes the C<HOME> of the account the C<HOME> of claude, so its settings
are the settings of that account.

The account and the worker share the workspace through a group.  See
L<App::Clod::Spoke/DESCRIPTION>.

=cut

has run_as => undef;

=method command

The argument list, for C<%run> as C<run> takes it.  Separate so that a test can
read it.

=cut

sub command ( $self, %run ) {
    my @cmd = ( $self->bin, qw{-p --output-format stream-json --verbose} );
    if ( my $account = $self->run_as ) {
        my @kept = sort { $a cmp $b } grep { $_ ne 'CLAUDE_CODE_OAUTH_TOKEN' } keys %{ $self->env };
        unshift @cmd, qw{sudo -n -H -u}, $account, ( @kept ? '--preserve-env=' . join( q{,}, @kept ) : () ), qw{-- /usr/bin/env}, 'PATH=' . ( $ENV{PATH} // q{} );
    }
    push @cmd, '--model', $self->model if $self->model;
    push @cmd, '--permission-mode', $run{permission_mode} // 'acceptEdits';
    my $tools = $run{tools} // $self->allowed_tools;
    push @cmd, '--allowedTools',         join( q{,}, map { rtk_too($_) } @$tools ) if @$tools;
    push @cmd, '--add-dir',              $_ for @{ $run{add_dirs} // [] };
    push @cmd, '--json-schema',          Mojo::JSON::encode_json( $run{schema} ) if $run{schema};
    push @cmd, '--append-system-prompt', $run{system}                            if $run{system};
    return \@cmd;
}

=func rtk_too

C<($rule)>.  The permission rule, and for a rule of the C<Bash> tool the same
rule for the command that rtk makes of it.  The rtk hook rewrites C<git add -A>
to C<rtk git add -A> before the permission check, so C<Bash(git:*)> alone does
not allow it, and a run with no person to ask is refused.  A rule for rtk
itself comes back alone.

=cut

sub rtk_too ($rule) {
    my ($command) = $rule =~ m/\ABash[(](.+)[)]\z/;
    return $rule if !defined $command || $command =~ m/\Artk\b/;
    return ( $rule, "Bash(rtk $command)" );
}

=method run

Takes C<dir>, C<prompt>, and optionally C<tools>, C<add_dirs>, C<schema>,
C<system>, C<permission_mode> and C<on_event>.  Returns a hash:

=over

=item ok

True when the process exited zero, and sent a result that was not an error.

=item result, structured

The final text, and the C<--json-schema> answer.

=item cost, usage, turns, session_id

=item rate_limit

The last C<rate_limit_info>: the utilization and reset time of each quota
window.

=item quota_reset

The epoch second when the quota opens again, set when a run hit the limit.

=item denied

Each tool call that claude refused, as L</denial> gives it.  In C<-p> nobody
can approve a call that the permissions do not allow, so a refused call did
not happen.

=item unauthorized

True when the API refused the token with a 401.

=item stderr

What claude wrote to stderr.  Past 4000 characters, only the first 2000 and
the last 2000 are kept, so that both the start of a stack trace and the last
error survive.  See L</ends>.  When claude exited with no result, it starts
with C<claude ended without a result.>

=item exit, timed_out, events

=back

=cut

sub run ( $self, %run ) {
    my $dir = $run{dir} // die "run needs a dir\n";
    die "$dir is not a directory\n" if !-d $dir;
    my $prompt = $run{prompt} // die "run needs a prompt\n";
    my $cmd    = $self->command(%run);

    my %outcome = ( events => 0 );
    my $buffer  = q{};
    my $stderr  = q{};
    my $take    = sub ($line) {
        my $event = eval { Mojo::JSON::decode_json($line) };
        return if ref $event ne 'HASH';
        $outcome{events}++;
        absorb( \%outcome, $event );
        $run{on_event}->($event) if $run{on_event};
    };
    my $read = sub ($chunk) {
        $buffer .= $chunk;
        while ( ( my $at = index $buffer, "\n" ) >= 0 ) { $take->( substr $buffer, 0, $at + 1, q{} ) }
    };

    local %ENV = ( %ENV, %{ $self->env } );
    delete @ENV{@WITHHELD};
    my $ok = eval {
        IPC::Run::run( $cmd, init => sub { chdir $dir or die "chdir $dir: $!\n" }, '<', \$prompt, '>', $read, '2>', \$stderr, IPC::Run::timeout( $self->timeout ) );
        1;
    };

    # The last event, when claude ended without its newline.
    $take->($buffer) if $buffer ne q{};
    $outcome{timed_out} = 1 if !$ok && index( lc $@, q{timeout} ) >= 0;
    $outcome{exit}      = $ok ? $? >> 8 : -1;
    $outcome{stderr}    = ends( $stderr, $STDERR_END );
    $outcome{stderr}    = "claude ended without a result. $outcome{stderr}" if $ok && !exists $outcome{result};
    $outcome{ok}        = $ok && !$outcome{exit} && !$outcome{is_error} && exists $outcome{result} ? 1 : 0;
    return \%outcome;
}

=func ends

C<($text, $length)>.  Returns C<$text> if it holds no more than twice
C<$length> characters.  Otherwise returns its first and its last C<$length>
characters, with a line between them that says how many were left out.

=cut

sub ends ( $text, $length ) {
    my $over = length($text) - 2 * $length;
    return $text if $over <= 0;
    return substr( $text, 0, $length ) . "\n[$over characters left out]\n" . substr( $text, -$length );
}

=method absorb

C<(\%outcome, \%event)>.  Folds one stream-json event into the outcome that
C<run> returns.

It reads three types of event: C<rate_limit_event>, C<system> with the subtype
C<init>, and C<result>.  Every other event leaves the outcome as it is.  That
includes C<assistant> and C<user>, which hold the conversation, and any type
that a later claude adds.  C<on_event> still gets every event.

=cut

my %ABSORB = (
    rate_limit_event => sub ( $outcome, $event ) {
        my $info = $event->{rate_limit_info} // {};
        $outcome->{rate_limit}  = $info;
        $outcome->{quota_reset} = $info->{resetsAt} if ( $info->{status} // 'allowed' ) ne 'allowed';
    },
    system => sub ( $outcome, $event ) {
        $outcome->{session_id} = $event->{session_id} if ( $event->{subtype} // q{} ) eq 'init';
    },
    result => sub ( $outcome, $event ) {
        $outcome->{result}       = $event->{result};
        $outcome->{structured}   = $event->{structured_output};
        $outcome->{cost}         = $event->{total_cost_usd} // 0;
        $outcome->{is_error}     = $event->{is_error} ? 1 : 0;
        $outcome->{unauthorized} = 1 if $outcome->{is_error} && ( $event->{api_error_status} // 0 ) == 401;
        $outcome->{turns}        = $event->{num_turns};
        $outcome->{denied}       = [ map { denial($_) } @{ $event->{permission_denials} // [] } ];
        my $usage = $event->{usage} // {};
        $outcome->{usage} = { map { $_ => $usage->{$_} // 0 } qw{input_tokens output_tokens cache_read_input_tokens cache_creation_input_tokens} };
        $outcome->{quota_reset} //= time + $UNKNOWN_RESET
          if $outcome->{is_error} && ( $event->{result} // q{} ) =~ m{usage\ limit | out\ of\ extra\ usage | rate\ limit}i;
    },
);

=func denial

C<(\%denial)>.  One entry of C<permission_denials> of a result, as the
permission rule that would have allowed it, such as C<Bash(git add -A)>: the
tool, and its command or the file that it wanted.

=cut

sub denial ($denial) {
    my $input = $denial->{tool_input} // {};
    my $what  = $input->{command}     // $input->{file_path} // $input->{path};
    my $tool  = $denial->{tool_name}  // 'a tool';
    return defined $what ? "$tool($what)" : $tool;
}

sub absorb ( $outcome, $event ) {
    my $absorb = defined $event->{type} ? $ABSORB{ $event->{type} } : undef;
    $absorb->( $outcome, $event ) if $absorb;
    return;
}

=head1 SYNOPSIS

    use 5.040;
    use App::Clod::Claude;

    my ( $worktree, $prompt ) = @ARGV;
    my $claude  = App::Clod::Claude->new( timeout => 1800 );
    my $outcome = $claude->run(
        dir      => $worktree,
        prompt   => $prompt,
        schema   => { type => 'object', required => ['summary'], properties => { summary => { type => 'string' } } },
        on_event => sub ($event) { print "$event->{type}\n" },
    );
    die $outcome->{stderr} if !$outcome->{ok};
    my $answer = $outcome->{structured};

=head1 DESCRIPTION

Runs C<claude -p> with C<--output-format stream-json>, with the prompt on
standard input and the working directory set to C<dir>.  So the CLAUDE.md, the
settings and the hooks of that directory apply to the run.  C<IPC::Run> runs it
from a list, never through a shell.

=cut
