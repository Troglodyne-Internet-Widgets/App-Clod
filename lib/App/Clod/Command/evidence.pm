package App::Clod::Command::evidence;    ## no critic (NamingConventions::Capitalization) -- Mojolicious runs this package as the command clod evidence

# ABSTRACT: Print what the claude runs of a job did

use 5.040;
no autovivification;
use warnings FATAL => 'all';
use re '/aasx';
use Mojo::Base 'Mojolicious::Command', -signatures;

use Mojo::JSON ();

use App::Clod::Evidence ();

# How much of the text of one tool result a line keeps.
our $RESULT_LENGTH = 2000;

has description => 'Print what the claude runs of a job did';
has usage       => <<'EOF_USAGE';
Usage: clod evidence JOB

  Prints the transcript of each claude run of each attempt of the job, as
  the evidence directory kept it: the prompt, then each call of a tool with
  its input, each result, and the text of the model, with the seconds since
  the run started.  A job that turned out fine kept nothing.
EOF_USAGE

=method run

C<($job)>.  Prints the evidence of the job C<$job>, as L</lines> gives it, for
each attempt and each run.  Dies with the usage when C<$job> is not a job
id, and says so when the job kept no evidence.

=cut

sub run ( $self, $job = q{} ) {
    die $self->usage if $job !~ m{\A\d+\z};
    my $root     = $self->app->clod_config->{evidence};
    my $attempts = App::Clod::Evidence->new( root => $root, job => $job )->attempts;
    die "job $job kept no evidence\n" if !@$attempts;
    my @out;
    for my $attempt (@$attempts) {
        my $runs = App::Clod::Evidence->new( root => $root, job => $job, attempt => $attempt )->runs;
        for my $n ( 1 .. @$runs ) {
            push @out, "== job $job, attempt $attempt, run $n", lines( $runs->[ $n - 1 ] ), q{};
        }
    }
    print {*STDOUT} map { "$_\n" } @out or die "Cannot print: $!\n";
    return;
}

=func lines

C<(\@run)>, one transcript of L<App::Clod::Evidence/runs>.  The lines that
describe it: the task, the directory and the prompt of the run, then one
line for each piece of each event, after the seconds since the run started.
A piece is the text of the model, a call of a tool with its input as JSON,
or the result of a call, cut to C<$RESULT_LENGTH> characters, marked when it
is an error.  The result of the run has its error flag and the calls that
claude refused.  An event of another type is its type.

=cut

sub lines ($run) {
    my ( $head, @events ) = @$run;
    my $start = $head->{at};
    my @lines = ( "task: $head->{run}{task}", "dir: $head->{run}{dir}", "prompt:\n$head->{run}{prompt}" );
    for my $line (@events) {
        my $at = sprintf '[%7.1fs]', $line->{at} - $start;
        push @lines, map { "$at $_" } pieces( $line->{event} );
    }
    return @lines;
}

=func pieces

C<(\%event)>.  The parts of one stream-json event, as L</lines> describes
them, without the time.

=cut

sub pieces ($event) {
    my $type = $event->{type} // 'unknown';
    if ( $type eq 'result' ) {
        my @denied = map { Mojo::JSON::encode_json($_) } @{ $event->{permission_denials} // [] };
        return ( 'result' . ( $event->{is_error} ? ' (error)' : q{} ) . ': ' . ( $event->{result} // q{} ), map { "refused: $_" } @denied );
    }
    return "$type " . ( $event->{subtype} // q{} ) if $type ne 'assistant' && $type ne 'user';
    my $content = ( $event->{message} // {} )->{content};
    return "$type: $content" if !ref $content;
    return map { piece($_) } grep { ref $_ eq 'HASH' } @$content;
}

=func piece

C<(\%part)>.  One part of the content of a message, as L</pieces> describes
it.

=cut

sub piece ($part) {
    my $kind = $part->{type} // q{};
    return "says: $part->{text}"                                                     if $kind eq 'text';
    return "calls $part->{name}: " . Mojo::JSON::encode_json( $part->{input} // {} ) if $kind eq 'tool_use';
    return $kind                                                                     if $kind ne 'tool_result';
    my $text = $part->{content} // q{};
    $text = join "\n", map { $_->{text} // q{} } grep { ref $_ eq 'HASH' } @$text if ref $text eq 'ARRAY';
    $text = substr( $text, 0, $RESULT_LENGTH ) . ' [cut]' if length $text > $RESULT_LENGTH;
    return 'result' . ( $part->{is_error} ? ' (error)' : q{} ) . ": $text";
}

1;

=head1 SYNOPSIS

    clod evidence 15285

=head1 DESCRIPTION

The shell side of L<App::Clod::Evidence>.  Run it as the account of the
worker, because nobody else can read the evidence.

=cut
