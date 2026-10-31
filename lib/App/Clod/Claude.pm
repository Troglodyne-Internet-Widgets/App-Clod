package App::Clod::Claude;

# ABSTRACT: Run claude -p in a directory and read what it did

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Mojo::Base -base, -signatures;

use Carp     ();
use IPC::Run ();
use Mojo::JSON();
use Time::HiRes qw{time};

# How long to wait when a run hit the limit and did not say when it resets.
my $UNKNOWN_RESET = 1800;

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

=method command

The argument list, for C<%run> as C<run> takes it.  Separate so that a test can
read it.

=cut

sub command ( $self, %run ) {
    my @cmd = ( $self->bin, qw{-p --output-format stream-json --verbose} );
    push @cmd, '--model', $self->model if $self->model;
    push @cmd, '--permission-mode', $run{permission_mode} // 'acceptEdits';
    my $tools = $run{tools} // $self->allowed_tools;
    push @cmd, '--allowedTools',         join( q{,}, @$tools ) if @$tools;
    push @cmd, '--add-dir',              $_ for @{ $run{add_dirs} // [] };
    push @cmd, '--json-schema',          Mojo::JSON::encode_json( $run{schema} ) if $run{schema};
    push @cmd, '--append-system-prompt', $run{system}                            if $run{system};
    return \@cmd;
}

=method run

Takes C<dir>, C<prompt>, and optionally C<tools>, C<add_dirs>, C<schema>,
C<system>, C<permission_mode> and C<on_event>.  Returns a hash:

=over

=item ok

True when the process exited zero and the result was not an error.

=item result, structured

The final text, and the C<--json-schema> answer.

=item cost, usage, turns, session_id

=item rate_limit

The last C<rate_limit_info>: the utilization and reset time of each quota
window.

=item quota_reset

The epoch second when the quota opens again, set when a run hit the limit.

=item unauthorized

True when the API refused the token with a 401.

=item exit, timed_out, stderr, events

=back

=cut

sub run ( $self, %run ) {
    my $dir = $run{dir} // Carp::croak('run needs a dir');
    Carp::croak("$dir is not a directory") if !-d $dir;
    my $prompt = $run{prompt} // Carp::croak('run needs a prompt');
    my $cmd    = $self->command(%run);

    my %outcome = ( events => 0 );
    my $buffer  = q{};
    my $stderr  = q{};
    my $read    = sub ($chunk) {
        $buffer .= $chunk;
        while ( $buffer =~ s/\A([^\n]*)\n// ) {
            my $line  = $1;
            my $event = eval { Mojo::JSON::decode_json($line) };
            next if ref $event ne 'HASH';
            $outcome{events}++;
            absorb( \%outcome, $event );
            $run{on_event}->($event) if $run{on_event};
        }
    };

    local %ENV = ( %ENV, %{ $self->env } );
    my $ok = eval {
        IPC::Run::run( $cmd, init => sub { chdir $dir or die "chdir $dir: $!" }, '<', \$prompt, '>', $read, '2>', \$stderr, IPC::Run::timeout( $self->timeout ) );
        1;
    };
    $outcome{timed_out} = 1 if !$ok && index( lc $@, q{timeout} ) >= 0;
    $outcome{exit}      = $ok ? $? >> 8 : -1;
    $outcome{stderr}    = substr $stderr, 0, 4000;
    $outcome{ok}        = $ok && !$outcome{exit} && !$outcome{is_error} ? 1 : 0;
    return \%outcome;
}

=method absorb

C<(\%outcome, \%event)>.  Folds one stream-json event into the outcome that
C<run> returns.

=cut

sub absorb ( $outcome, $event ) {
    my $type = $event->{type} // q{};
    if ( $type eq 'rate_limit_event' ) {
        my $info = $event->{rate_limit_info} // {};
        $outcome->{rate_limit}  = $info;
        $outcome->{quota_reset} = $info->{resetsAt} if ( $info->{status} // 'allowed' ) ne 'allowed';
    }
    elsif ( $type eq 'system' && ( $event->{subtype} // q{} ) eq 'init' ) {
        $outcome->{session_id} = $event->{session_id};
    }
    elsif ( $type eq 'result' ) {
        $outcome->{result}       = $event->{result};
        $outcome->{structured}   = $event->{structured_output};
        $outcome->{cost}         = $event->{total_cost_usd} // 0;
        $outcome->{is_error}     = $event->{is_error} ? 1 : 0;
        $outcome->{unauthorized} = 1 if $outcome->{is_error} && ( $event->{api_error_status} // 0 ) == 401;
        $outcome->{turns}        = $event->{num_turns};
        my $usage = $event->{usage} // {};
        $outcome->{usage} = { map { $_ => $usage->{$_} // 0 } qw{input_tokens output_tokens cache_read_input_tokens cache_creation_input_tokens} };
        $outcome->{quota_reset} //= time + $UNKNOWN_RESET
          if $outcome->{is_error} && ( $event->{result} // q{} ) =~ m{usage\ limit | out\ of\ extra\ usage | rate\ limit}i;
    }
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
