#!/usr/bin/env perl
use 5.040;
no autovivification;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use FindBin::libs;
use File::Temp  ();
use Minion      ();
use Time::HiRes qw{time};

use App::Clod::Outage();

my $tmp    = File::Temp->newdir;
my $minion = Minion->new( SQLite => "sqlite:$tmp/minion.db" );
$minion->add_task( $_ => sub ( $job, @ ) { $job->finish } ) for qw{triage harness_scan};

# Starts an outage from a job of that task, as a task does when it is refused.
sub refused ( $task, $service, $error ) {
    my $id  = $minion->enqueue($task);
    my $job = $minion->worker->register->dequeue( 0, { id => $id } );
    App::Clod::Outage::begin( $job, $service, $error );
    $job->finish;
    $minion->worker->unregister;
    return $id;
}

subtest holding => sub {
    is( App::Clod::Outage::holding( $minion, 'triage' ), undef, 'nothing is held to begin with' );

    refused( harness_scan => claude => 'Claude refused it' );
    is( App::Clod::Outage::holding( $minion, 'triage' ),       'claude', 'a Claude outage holds a task that runs claude' );
    is( App::Clod::Outage::holding( $minion, 'harness_scan' ), undef,    'and not one that does not' );

    refused( triage => github => 'GitHub refused it' );
    is( App::Clod::Outage::holding( $minion, 'harness_scan' ), 'github', 'a GitHub outage holds every task' );

    ok( lives { refused( triage => github => 'refused again' ) }, 'a second refusal extends the outage rather than failing' );
    is( App::Clod::Outage::holding( $minion, 'harness_scan' ), 'github', 'and the outage lasts' );
};

subtest summary => sub {
    my $summary = App::Clod::Outage::summary($minion);
    is( [ map { $_->{service} } @$summary ], [qw{claude github}], 'one entry for each outage' );
    my ($github) = grep { $_->{service} eq 'github' } @$summary;
    is( $github->{error}, 'refused again', 'with the error of the newest job that saw it' );
    is( $github->{name},  'GitHub',        'and the name of the service' );
    ok( $github->{at} > time - 60, 'and when' );

    $minion->unlock( App::Clod::Outage::lock_name('claude') );
    is( [ map { $_->{service} } @{ App::Clod::Outage::summary($minion) } ], ['github'], 'an outage whose lock is gone is over' );

    $minion->reset( { all => 1 } );
    $minion->lock( App::Clod::Outage::lock_name('github'), 60 );
    is( App::Clod::Outage::summary($minion), [ { service => 'github', name => 'GitHub' } ], 'an outage whose job is removed still shows, without its error' );
    $minion->unlock( App::Clod::Outage::lock_name('github') );
    is( App::Clod::Outage::summary($minion), [], 'and no lock is no outage' );
};

done_testing;
