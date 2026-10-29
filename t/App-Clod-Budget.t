#!/usr/bin/env perl
use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use FindBin::libs;
use File::Temp  ();
use Minion      ();
use Time::HiRes qw{time};

use App::Clod::Budget();

my $HOUR = 3600;
my $DAY  = 86_400;

my $tmp    = File::Temp->newdir;
my $minion = Minion->new( SQLite => "sqlite:$tmp/minion.db" );
$minion->add_task( $_ => sub ( $job, $result ) { $job->finish($result) } ) for @App::Clod::Budget::CLAUDE_TASKS, 'harness_scan';

# A finished job with this result, finished this many seconds ago.
sub finished ( $task, $result, $ago ) {
    my $id = $minion->enqueue( $task => [$result] );
    $minion->perform_jobs;
    my $db = $minion->backend->sqlite->db;
    $db->query( q{update minion_jobs set finished = datetime(?, 'unixepoch') where id = ?}, time - $ago, $id );
    return $id;
}

subtest pause => sub {
    ok( !App::Clod::Budget::paused($minion), 'not paused to begin with' );
    App::Clod::Budget::pause( $minion, time - 5 );
    ok( !App::Clod::Budget::paused($minion), 'a reset in the past does not pause' );
    App::Clod::Budget::pause( $minion, time + 60 );
    ok( App::Clod::Budget::paused($minion), 'a reset in the future pauses' );
    App::Clod::Budget::pause( $minion, time + 120 );
    ok( App::Clod::Budget::paused($minion), 'a second pause replaces the first rather than failing' );
    $minion->unlock($App::Clod::Budget::LOCK);
};

subtest summary => sub {
    my $now = time;
    finished( spoke_fix    => { cost => 4, rate_limit => { unifiedWindows => { five_hour => { utilization => 0.9, resetsAt => 1 } } } },                                          8 * $DAY );
    finished( spoke_fix    => { cost => 2 },                                                                                                                                      3 * $DAY );
    finished( triage       => { cost => 1, quota_reset => $now + 600 },                                                                                                           2 * $HOUR );
    finished( reply        => { cost => 0.5, rate_limit => { unifiedWindows => { five_hour => { utilization => 0.426, resetsAt => 7 }, seven_day => { utilization => 0.2 } } } }, 60 );
    finished( harness_scan => { cost => 100 },                                                                                                                                    60 );

    my $s = App::Clod::Budget::summary( $minion, $now );
    is( $s->{cost_7d},            3.5,                                                'a week sums the runs of the last seven days, and no older' );
    is( $s->{cost_24h},           1.5,                                                'a day sums the runs of the last day' );
    is( $s->{cost_5h},            1.5,                                                'five hours sums the runs of the last five hours' );
    is( $s->{runs_7d},            3,                                                  'and counts the runs of the week' );
    is( $s->{five_hour},          { percent => 43, resets_at => 7, status => undef }, 'the newest report of a window wins' );
    is( $s->{seven_day}{percent}, 20,                                                 'each window is reported' );
    is( $s->{paused_until},       $now + 600,                                         'a reset still ahead is the pause' );
    is( $s->{paused},             0,                                                  'but without the lock nothing is paused' );
};

done_testing;
