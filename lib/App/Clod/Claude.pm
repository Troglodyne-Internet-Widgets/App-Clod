package App::Clod::Claude;

# ABSTRACT: Run claude -p in a directory and read what it did

use 5.040;
no autovivification;
use warnings FATAL => 'all';
use re '/aasx';
use Mojo::Base -base, -signatures;

use IPC::Run   ();
use Mojo::File ();
use Mojo::JSON();
use Time::HiRes qw{time};
use version     ();

# How long to wait when a run hit the limit and did not say when it resets.
my $UNKNOWN_RESET = 1800;

# How much of each end of its stderr a run keeps in the job result.
my $STDERR_END = 2000;

# The PermissionRequest hook of a run that edits, in share/agent-bin.
my $SKILL_HOOK = 'clod-skill-edits';

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

=head1 THE SKILLS OF A WORK TREE

Claude Code protects F<.claude/>.  In C<acceptEdits> it asks before it writes
there, and no allow rule answers for a person.  In C<-p> nobody answers, so a
run cannot change a skill of its repository.  So a run in C<acceptEdits>,
which is how a run that changes a work tree runs, gets
L</skill_settings>: a C<PermissionRequest> hook, F<clod-skill-edits> of
F<share/agent-bin>, that allows an C<Edit> or C<Write> inside
F<.claude/skills/> of its C<dir>, and decides nothing else.  The change still
reaches the default branch only through a pull request.  A run in another
mode does not get the hook, because there the hook would let a run that may
not edit edit the skills.

The hook runs from the F<bin> of L</lib>, where L<App::Clod::Deps/install_programs>
puts it for the account of L</run_as> to read and run, or from F<share> with
no L</lib>.  It runs on the perl of the worker, C<$^X>, with an empty
environment.  So C<PERL5LIB>, which names L</own_lib>, a lib that the agent
may install into, cannot give it another module, and C<PATH> cannot give it
another perl.

=cut

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

=attr lib

A local lib, such as C<agent_lib> of F<clod.conf>, that comes first on the
C<PERL5LIB> of every program that claude runs, with its F<bin> first on
C<PATH>.  It holds the tools of the agent.  Default none: then claude gets the
C<PATH> of the worker, and no C<PERL5LIB>, so not the modules of the bot.

=cut

has lib => undef;

=attr own_lib

A local lib that the agent may install into, such as C<agent_own_lib> of
F<clod.conf>.  It comes after L</lib> on C<PERL5LIB>, with its F<bin> after
that of L</lib> on C<PATH>, so that it adds modules and cannot replace one of
L</lib>.  C<CLOD_OWN_LIB> names it, for F<clod-cpm>.  Default none.

=cut

has own_lib => undef;

=method run_env

The C<PATH> and C<PERL5LIB> that claude runs with, as a hash, from L</lib>
and L</own_lib>, and C<CLOD_OWN_LIB> with an L</own_lib>.

=cut

sub run_env ($self) {
    my @libs = grep { defined } $self->lib, $self->own_lib;
    my $path = join q{:}, ( map { "$_/bin" } @libs ), $ENV{PATH} // ();
    return ( PATH => $path ) if !@libs;
    my %env = ( PATH => $path, PERL5LIB => join q{:}, map { "$_/lib/perl5" } @libs );
    $env{CLOD_OWN_LIB} = $self->own_lib if defined $self->own_lib;
    return %env;
}

=method command

The argument list, for C<%run> as C<run> takes it.  Separate so that a test can
read it.

=cut

sub command ( $self, %run ) {
    my @cmd = $self->as_account( $self->bin, qw{-p --output-format stream-json --verbose} );
    push @cmd, '--model', $self->model if $self->model;
    my $mode = $run{permission_mode} // 'acceptEdits';
    push @cmd, '--permission-mode', $mode;
    push @cmd, '--settings',        $self->skill_settings( $run{dir} ) if $mode eq 'acceptEdits' && defined $run{dir};
    my $tools = $run{tools} // $self->allowed_tools;
    push @cmd, '--allowedTools',         join( q{,}, map { rtk_too($_) } @$tools ) if @$tools;
    push @cmd, '--add-dir',              $_ for @{ $run{add_dirs} // [] };
    push @cmd, '--json-schema',          Mojo::JSON::encode_json( $run{schema} ) if $run{schema};
    push @cmd, '--append-system-prompt', $run{system}                            if $run{system};
    return \@cmd;
}

=method skill_settings

C<($dir)>.  The C<--settings> of a run in the work tree C<$dir>, as JSON: a
C<PermissionRequest> hook, F<clod-skill-edits>, that lets the run edit the
skills of C<$dir>.  See L</THE SKILLS OF A WORK TREE>.

=cut

sub skill_settings ( $self, $dir ) {
    my $hook = defined $self->lib ? Mojo::File->new( $self->lib, 'bin', $SKILL_HOOK ) : App::Clod::share_dir()->child( 'agent-bin', $SKILL_HOOK );
    my $run  = { type => 'command', command => '/usr/bin/env', args => [ '-i', $^X, "$hook", Mojo::File->new($dir)->to_abs->to_string ] };
    return Mojo::JSON::encode_json( { hooks => { PermissionRequest => [ { matcher => 'Edit|Write', hooks => [$run] } ] } } );
}

=method child_env

The environment that claude runs with: C<%ENV>, the C<env> of claude, and,
when there is no L</run_as>, the C<PATH> and C<PERL5LIB> of L</run_env>, and no
other C<PERL5LIB>.  None of C<@WITHHELD>.  With an account, L</as_account>
passes C<PATH> and C<PERL5LIB> to F</usr/bin/env> instead, because sudo resets
the environment.

=cut

sub child_env ($self) {
    my %env = ( %ENV, %{ $self->env } );
    delete @env{@WITHHELD};
    if ( !$self->run_as ) {
        delete $env{PERL5LIB};
        %env = ( %env, $self->run_env );
    }
    return %env;
}

=method as_account

C<(@cmd)>.  The argument list that runs C<@cmd> as L</run_as>, through sudo as
L</run_as> describes, or C<@cmd> itself when there is no such account.

=cut

sub as_account ( $self, @cmd ) {
    my $account = $self->run_as // return @cmd;
    my @kept    = sort { $a cmp $b } grep { $_ ne 'CLAUDE_CODE_OAUTH_TOKEN' } keys %{ $self->env };
    my %env     = $self->run_env;
    return ( qw{sudo -n -H -u}, $account, ( @kept ? '--preserve-env=' . join( q{,}, @kept ) : () ), qw{-- /usr/bin/env}, ( map { "$_=$env{$_}" } sort keys %env ), @cmd );
}

=method cli

C<(@args)>.  Runs C<claude @args> as L</as_account> does, for a command of
claude that is not a session, such as C<plugin list>, and returns what it
printed.  Dies with what it printed on its standard error if it fails.

=cut

sub cli ( $self, @args ) { return $self->as_account_run( $self->bin, @args ) }

=method as_account_run

C<(@cmd)>.  Runs C<@cmd> as L</as_account> does, with the C<env> of claude and
none of C<@WITHHELD>, and returns what it printed.  Dies with what it printed
on its standard error if it fails.

=cut

sub as_account_run ( $self, @cmd ) {
    local %ENV = $self->child_env;
    my ( $out, $err ) = ( q{}, q{} );
    my $ok = eval { IPC::Run::run( [ $self->as_account(@cmd) ], '<', \undef, '>', \$out, '2>', \$err, IPC::Run::timeout(600) ) };
    die "@cmd: " . ( $err ne q{} ? $err : $@ || 'failed' ) . "\n" if !$ok;
    return $out;
}

=method plugins

The plugins that claude has installed for its account, each a hash with
C<id>, such as C<perl-slop@troglodyne-marketplace>, C<version>, the version
that is installed, and C<latest>, the version that its marketplace offers, or
undef when the marketplace does not say.  It first refreshes the
marketplaces, as C<claude plugin marketplace update> does.  The list of
installed plugins does not say which version is the newest, and the manifest
of each marketplace does.

=cut

sub plugins ($self) {
    $self->cli(qw{plugin marketplace update});
    my $installed = Mojo::JSON::decode_json( $self->cli(qw{plugin list --json}) );
    my $known     = Mojo::JSON::decode_json( $self->as_account_run( qw{/bin/sh -c}, 'cat "$HOME/.claude/plugins/known_marketplaces.json"' ) );
    my %offered;
    for my $market ( sort keys %$known ) {
        my $dir      = $known->{$market}{installLocation}                                                                         // next;
        my $manifest = eval { Mojo::JSON::decode_json( $self->as_account_run( 'cat', "$dir/.claude-plugin/marketplace.json" ) ) } // next;
        $offered{"$_->{name}\@$market"} = $_->{version} for grep { ref $_ eq 'HASH' && defined $_->{name} } @{ $manifest->{plugins} // [] };
    }
    return [ map { { id => $_->{id}, version => $_->{version}, latest => $offered{ $_->{id} } } } sort { $a->{id} cmp $b->{id} } @$installed ];
}

=func is_behind

C<($plugin)>, an entry of L</plugins>.  True when its marketplace offers a
newer version than the one that is installed.  The versions compare as
versions, so 0.10 is newer than 0.9.  A version that is no version string is
behind when it differs from the one offered.

=cut

sub is_behind ($plugin) {
    my ( $have, $offered ) = @$plugin{qw{version latest}};
    return 0 if !defined $offered || !defined $have;
    my $newer = eval { version->declare($offered) > version->declare($have) };
    return defined $newer ? ( $newer ? 1 : 0 ) : ( $offered ne $have ? 1 : 0 );
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

    local %ENV = $self->child_env;
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

1;

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
