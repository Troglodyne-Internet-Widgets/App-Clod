package App::Clod::Outage;

# ABSTRACT: Hold the work while GitHub or Claude refuses its token

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';

use List::Util  ();
use Time::HiRes qw{time};

use App::Clod::Budget();

# How long an outage holds the work before a job asks again.
our $SECONDS = 600;

# The tasks that each outage holds.  Undef holds every task.
our %HOLDS = (
    github => undef,
    claude => \@App::Clod::Budget::CLAUDE_TASKS,
);

our %NAME = ( github => 'GitHub', claude => 'Claude' );

# How many of the newest jobs L</last_note> reads.
our $SCAN = 500;

=func lock_name

C<($service)>.  The Minion lock that is held while the outage lasts.

=cut

sub lock_name ($service) { return "outage-$service" }

=func begin

C<($job, $service, $error)>.  Starts an outage of C<github> or C<claude>, or
extends it, so that it lasts C<$SECONDS> from now.  Notes C<outage> on the job,
which is where L</summary> finds the error.

=cut

sub begin ( $job, $service, $error ) {
    my $minion = $job->minion;
    $minion->unlock( lock_name($service) );
    $minion->lock( lock_name($service), $SECONDS );
    $job->note( outage => { service => $service, error => $error, at => time } );
    return;
}

=func holding

C<($minion, $task)>.  The service whose outage holds that task, or undef.

=cut

sub holding ( $minion, $task ) {
    for my $service ( sort keys %HOLDS ) {
        my $tasks = $HOLDS{$service};
        next            if $tasks && !List::Util::any { $_ eq $task } @$tasks;
        return $service if $minion->is_locked( lock_name($service) );
    }
    return;
}

=func summary

C<($minion)>.  One C<{service, name, error, at, job}> for each outage that
lasts now.  C<error>, C<at> and C<job> come from L</last_note>, and are absent
when it finds none.

=cut

sub summary ($minion) {
    my @summary;
    for my $service ( grep { $minion->is_locked( lock_name($_) ) } sort keys %HOLDS ) {
        push @summary, { service => $service, name => $NAME{$service}, %{ last_note( $minion, $service ) // {} } };
    }
    return \@summary;
}

=func last_note

C<($minion, $service)>.  C<{error, at, job}> from the newest job that noted an
outage of the service, among the newest C<$SCAN> jobs of the tasks that it
holds, or undef.

=cut

# The SQLite backend of Minion cannot list jobs by their notes.
sub last_note ( $minion, $service ) {
    my $tasks = $HOLDS{$service};
    my $jobs  = $minion->jobs( $tasks ? { tasks => $tasks } : {} );
    my $seen  = 0;
    while ( my $info = $jobs->next ) {
        last if ++$seen > $SCAN;
        my $note = $info->{notes}{outage} // next;
        return { error => $note->{error}, at => $note->{at}, job => $info->{id} } if $note->{service} eq $service;
    }
    return;
}

1;

=head1 SYNOPSIS

    use 5.040;
    use App::Clod::Outage;

    # Inside a Minion task.
    sub careful ( $job, $call ) {
        my $minion = $job->minion;
        return $job->retry( { delay => $App::Clod::Outage::SECONDS } ) if App::Clod::Outage::holding( $minion, $job->task );
        my $ok = eval { $call->(); 1 };
        App::Clod::Outage::begin( $job, 'github', $@ ) if !$ok;
        return App::Clod::Outage::summary($minion);
    }

=head1 DESCRIPTION

When GitHub answers 401, or a C<claude> run reports a 401, the token is wrong
or revoked, and every job that needs it can only fail.  So the first job to see
it takes a Minion lock for that service.  While the lock is held, the work that
needs the service waits.  The lock expires after C<$SECONDS>, and the next job
then asks the service again.  So an outage ends by itself within C<$SECONDS> of
a working token.

A GitHub outage holds every task, because each one reads or writes GitHub.  A
Claude outage holds only the tasks that run C<claude>.

=cut
