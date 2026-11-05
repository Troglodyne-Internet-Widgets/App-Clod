package App::Clod::Budget;

# ABSTRACT: How much of the Claude quota the bot has used, and the pause

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';

use Time::HiRes qw{time};

our $LOCK = 'budget-pause';

my $HOUR = 3600;
my $DAY  = 86_400;
my $WEEK = 7 * $DAY;

# The tasks whose results carry a claude outcome.
our @CLAUDE_TASKS = qw{triage spoke_fix spoke_review spoke_address sort_review reply};

=func pause

C<($minion, $until)>, an epoch second.

=cut

sub pause ( $minion, $until ) {
    my $seconds = $until - time;
    return if $seconds <= 0;
    $minion->unlock($LOCK);
    $minion->lock( $LOCK, $seconds );
    return;
}

=func paused

C<($minion)>.  True while the pause lock is held.

=cut

sub paused ($minion) { return $minion->is_locked($LOCK) }

=func summary

The cost over five hours, a day and a week, the runs in the week, the last
reported utilization of each window as C<five_hour> and C<seven_day>, and the
pause.

=cut

sub summary ( $minion, $now = time ) {
    my %summary = ( cost_5h => 0, cost_24h => 0, cost_7d => 0, runs_7d => 0, paused => paused($minion) ? 1 : 0 );
    my $jobs    = $minion->jobs( { tasks => \@CLAUDE_TASKS, states => [qw{finished failed}] } );
    while ( my $info = $jobs->next ) {
        my $at = $info->{finished} // next;

        # Ids follow the enqueue, not the finish, so a long job can come after a newer one.
        next if $at < $now - $WEEK;
        my $result = ref $info->{result} eq 'HASH' ? $info->{result} : next;
        my $cost   = $result->{cost} // 0;
        $summary{runs_7d}++ if exists $result->{cost};
        $summary{cost_7d}  += $cost;
        $summary{cost_24h} += $cost if $at >= $now - $DAY;
        $summary{cost_5h}  += $cost if $at >= $now - 5 * $HOUR;
        $summary{rate_limit} //= $result->{rate_limit} if $result->{rate_limit};
        $summary{paused_until} = $result->{quota_reset}
          if $result->{quota_reset} && $result->{quota_reset} > $now && $result->{quota_reset} > ( $summary{paused_until} // 0 );
    }
    my $windows = ( $summary{rate_limit} // {} )->{unifiedWindows} // {};
    for my $window (qw{five_hour seven_day}) {
        my $w = $windows->{$window} // next;
        $summary{$window} = { percent => sprintf( '%.0f', 100 * ( $w->{utilization} // 0 ) ) + 0, resets_at => $w->{resetsAt}, status => $w->{status} };
    }
    return \%summary;
}

1;

=head1 SYNOPSIS

    use 5.040;
    use App::Clod::Budget;

    # Inside a Minion task, after a claude run.
    sub after_run ( $job, $outcome ) {
        my $minion = $job->minion;
        App::Clod::Budget::pause( $minion, $outcome->{quota_reset} ) if $outcome->{quota_reset};
        return $job->retry( { delay => 600 } ) if App::Clod::Budget::paused($minion);
        return App::Clod::Budget::summary($minion);
    }

=head1 DESCRIPTION

Each C<claude -p> run reports the utilization of the five-hour and seven-day
quota windows in its C<rate_limit_event>.  The bot keeps the last report and
the cost of each run in the job's result.  So the budget is a read of recent
finished jobs, and needs no store of its own.

When a run hits the limit, C<pause> takes a Minion lock that expires when the
quota opens again.  A job that needs Claude and finds the lock taken retries
later.

=cut
