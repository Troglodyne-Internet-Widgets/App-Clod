#!/usr/bin/env perl
use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use FindBin::libs;
use File::Temp  ();
use Mojo::File  ();
use Mojo::Util  ();
use Test::Mojo  ();
use Time::HiRes qw{time};

my $tmp  = File::Temp->newdir;
my $conf = Mojo::File->new( "$tmp", 'clod.conf' );
$conf->spew( Mojo::Util::dumper( { bot => 'test-bot', workspace => "$tmp/ws", spokes => ['Test-Org/one'], auth => { trusted_header => 'X-Test-User' } } ) );
local $ENV{CLOD_CONFIG} = "$conf";

my $t = Test::Mojo->new('App::Clod');
$t->app->log->level('fatal');
$t->ua->on( start => sub ( $ua, $tx ) { $tx->req->headers->header( 'X-Test-User' => 'tester' ) } );
my $minion = $t->app->minion;

# Each task finishes, or fails, with the result it is given, in place of its real work.
for my $task (qw{harness_scan inbox_poll assigned_sweep spoke_fix triage reply}) {
    $minion->add_task( $task => sub ( $job, @args ) { my $r = $job->info->{notes}{result}; $job->info->{notes}{fail} ? $job->fail($r) : $job->finish($r) } );
}

sub action_texts () {
    my $json = $t->tx->res->json;
    return join "\n", map { $_->{text} } @{ $json->{actions} };
}

sub job ( $task, $result, %opt ) {
    return $minion->enqueue( $task => $opt{args} // [], { notes => { result => $result, $opt{fail} ? ( fail => 1 ) : (), %{ $opt{notes} // {} } } } );
}

subtest 'overview, with nothing done yet' => sub {
    $t->get_ok('/api/overview')->status_is(200)->json_is( '/items/active' => 0, 'no items' );
    my $texts = action_texts();
    like( $texts, qr/No\ harness\ scan\ has\ finished\ yet/, 'says that no scan ran' );
    like( $texts, qr/inbox\ has\ not\ been\ read/,           'and that no worker read the inbox' );
};

subtest overview => sub {
    job( harness_scan => { repos     => { 'Test-Org/one' => { checks => [ { check => 'CLAUDE.md', status => 'fail' }, { check => 'git hooks', status => 'pass' } ] } }, errors => { 'Test-Org/two' => 'no response' }, marketplace => { status => 'fail', detail => 'the marketplace pins 0.1; the plugin is at 0.2' }, checks => [ 'CLAUDE.md', 'git hooks' ] } );
    job( inbox_poll   => { polled_at => time, scopes => 'repo' } );
    job( spoke_fix    => { error     => 'it broke', cost => 2 }, fail => 1, notes => { origin => 'Test-Org/one#3' } );
    $minion->perform_jobs;

    $t->get_ok('/api/overview')->status_is(200)->json_is( '/budget/cost_7d' => 2, 'a failed run still counts against the budget' );
    my $texts = action_texts();
    like( $texts, qr/Marketplace:\ the\ marketplace\ pins\ 0\.1/,                'a stale marketplace pin is an action item' );
    like( $texts, qr/Test-Org\/one\ fails\ 1\ harness\ check\(s\):\ CLAUDE\.md/, 'so is a failing harness check' );
    like( $texts, qr/Harness\ scan\ of\ Test-Org\/two\ failed:\ no\ response/,   'and a scan that failed' );
    like( $texts, qr/lacks\ the\ scopes:\ notifications/,                        'and a missing token scope' );
    like( $texts, qr/\(spoke_fix\ for\ Test-Org\/one\#3\)\ failed:\ it\ broke/,  'and a failed job, with its origin and error' );
    unlike( $texts, qr/inbox\ has\ not\ been\ read/, 'a recent poll is not an action item' );
};

subtest work => sub {
    my $child = job( spoke_fix => { pr_url => 'https://test.test/pull/1', summary => 'done' }, notes => { repo => 'Test-Org/one' } );
    job( triage => { children => [$child] }, args => [ { repo => 'Test-Org/one', number => 5, kind => 'fix', title => 'T' } ], notes => { scope => 'single', children => [$child] } );
    job( assigned_sweep => { checked_at => 1, issues => [ { repo => 'Test-Org/one', number => 5 }, { repo => 'Test-Org/one', number => 6 } ] } );
    $minion->perform_jobs;

    $t->get_ok('/api/work')->status_is(200);
    my $work = $t->tx->res->json;
    my ($item) = grep { $_->{task} eq 'triage' } @{ $work->{items} };
    is( [ @$item{qw{origin scope kind}} ], [ q{Test-Org/one#5}, qw{single fix} ], 'an item shows its origin, scope and kind' );
    like( $item->{url}, qr{github\.com/Test-Org/one/issues/5\z}, 'and links to it' );
    is( $item->{children}[0]{pr_url},                     'https://test.test/pull/1', 'its spoke jobs show their pull requests' );
    is( [ map { $_->{has_job} } @{ $work->{assigned} } ], [ 1, 0 ],                   'an assigned issue with no job is shown as waiting' );
};

subtest harness => sub {
    $t->get_ok('/api/harness')->status_is(200)->json_is( '/checks' => [ 'CLAUDE.md', 'git hooks' ], 'the last scan comes back as it is' );
};

done_testing;
