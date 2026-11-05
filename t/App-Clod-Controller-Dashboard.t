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

use App::Clod::Outage();

my $tmp  = File::Temp->newdir;
my $conf = Mojo::File->new( "$tmp", 'clod.conf' );
$conf->spew( Mojo::Util::dumper( { bot => 'test-bot', workspace => "$tmp/ws", spokes => ['Test-Org/one'], auth => { trusted_header => 'X-Test-User' } } ) );
local $ENV{CLOD_CONFIG} = "$conf";

my $t = Test::Mojo->new('App::Clod');
$t->app->log->level('fatal');
$t->ua->on( start => sub ( $ua, $tx ) { $tx->req->headers->header( 'X-Test-User' => 'tester' ) } );
my $minion = $t->app->minion;

# Each task finishes, or fails, with the result it is given, in place of its real work.
for my $task (qw{harness_scan inbox_poll assigned_sweep spoke_sweep spoke_fix triage reply create_repo file_issues harness_fix self_check self_update plugin_update deps_upgrade}) {
    $minion->add_task( $task => sub ( $job, @args ) { my $r = $job->info->{notes}{result}; $job->info->{notes}{fail} ? $job->fail($r) : $job->finish($r) } );
}

sub action_texts () {
    my $json = $t->tx->res->json;
    return join "\n", map { $_->{text} } @{ $json->{actions} };
}

sub action_about ($pattern) {
    my $json = $t->tx->res->json;
    return ( grep { $_->{text} =~ $pattern } @{ $json->{actions} } )[0];
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
    job( inbox_poll   => { polled_at => time, scopes => 'notifications, read:org' } );
    job( spoke_sweep  => { repos     => [], dropped => { 'Test-Org/hidden' => 'its visibility is private, and a spoke must be public' }, errors => { 'Test-Org' => 'GitHub GET /orgs/Test-Org/repos: 404' } } );
    job( spoke_fix    => { error     => 'it broke', cost => 2 }, fail => 1, notes => { origin => 'Test-Org/one#3' } );
    $minion->perform_jobs;

    $t->get_ok('/api/overview')->status_is(200)->json_is( '/budget/cost_7d' => 2, 'a failed run still counts against the budget' );
    my $texts = action_texts();
    like( $texts, qr/Marketplace:\ the\ marketplace\ pins\ 0\.1/,                 'a stale marketplace pin is an action item' );
    like( $texts, qr/Test-Org\/one\ fails\ 1\ harness\ check\(s\):\ CLAUDE\.md/,  'so is a failing harness check' );
    like( $texts, qr/Harness\ scan\ of\ Test-Org\/two\ failed:\ no\ response/,    'and a scan that failed' );
    like( $texts, qr/lacks\ the\ scopes:\ repo\./,                                'and a missing token scope' );
    like( $texts, qr/repositories\ of\ Test-Org\ failed:\ GitHub\ GET\ \S+\ 404/, 'and an organization that could not be listed' );
    like( $texts, qr/hidden\ is\ not\ a\ spoke:\ its\ visibility\ is\ private/,   'and a configured repository that is not public' );
    unlike( $texts, qr/Test-Org\/one\ is\ not\ a\ spoke/, 'but not a public spoke' );
    like( $texts, qr/\(spoke_fix\ for\ Test-Org\/one\#3\)\ failed:\ it\ broke/, 'and a failed job, with its origin and error' );
    unlike( $texts, qr/inbox\ has\ not\ been\ read/, 'a recent poll is not an action item' );
};

subtest 'the buttons of the action items' => sub {
    my %act = ( 'X-Clod-Action' => 'yes' );
    $t->get_ok('/api/overview')->status_is(200);
    my $failed = action_about(qr/\(spoke_fix\ for\ Test-Org\/one\#3\)\ failed/);
    is( [ map { $_->{label} } @{ $failed->{buttons} } ], [qw{Retry Ignore}], 'a failed job can be retried or ignored' );
    my $id = $failed->{job};

    $t->post_ok("/act/jobs/$id/retry")->status_is( 403, 'an action without the header is refused, so another site cannot post it' );
    is( $minion->job($id)->info->{state}, 'failed', 'and does nothing' );
    $t->post_ok( "/act/jobs/$id/retry" => \%act )->status_is(200)->json_is( '/retried' => $id );
    is( $minion->job($id)->info->{state}, 'inactive', 'Retry queues the failed job again' );
    $t->post_ok( "/act/jobs/$id/retry" => \%act )->status_is( 404, 'and a job that has not failed cannot be retried' );

    my $other = job( spoke_fix => { error => 'broke again' }, fail => 1, notes => { origin => 'Test-Org/one#4' } );
    $minion->perform_jobs;
    $t->post_ok( "/act/jobs/$other/ignore" => \%act )->status_is(200);
    ok( $minion->job($other)->info->{notes}{ignored}, 'Ignore notes the job as ignored' );
    is( $minion->job($other)->info->{state}, 'failed', 'and leaves it failed, in the history' );
    $t->get_ok('/api/overview')->status_is(200);
    unlike( action_texts(), qr/Test-Org\/one\#4/, 'and it is no action item any more' );

    my $harness = action_about(qr/Test-Org\/one\ fails\ 1\ harness\ check/);
    is( $harness->{buttons}, [ { label => 'Fix', act => 'harness/fix', body => { repo => 'Test-Org/one' } } ], 'a spoke that fails a harness check can be fixed' );
    $t->post_ok( '/act/harness/fix' => \%act => json => { repo => 'Test-Org/one' } )->status_is(200);
    my $res  = $t->tx->res;
    my $fix  = $res->json->{queued};
    my $info = $minion->job($fix)->info;
    is( [ $info->{task}, $info->{args}[0] ], [ 'harness_fix', { repo => 'Test-Org/one', checks => [ { check => 'CLAUDE.md', detail => undef } ], by => 'tester' } ], 'Fix queues a harness fix, with the failing checks, and who pressed it' );
    $t->post_ok( '/act/harness/fix' => \%act => json => { repo => 'Test-Org/one' } )->status_is(200)->json_is( '/queued' => $fix, 'and a second press queues no second one' );
    $t->get_ok('/api/overview')->status_is(200);
    like( action_about(qr/harness\ check/), { job => $fix, text => qr/A\ harness\ fix\ of\ it\ is\ queued/ }, 'and while it waits, the item says so, with no button' );
    ok( !action_about(qr/harness\ check/)->{buttons}, 'none' );
    $t->post_ok( '/act/harness/fix' => \%act => json => { repo => 'Test-Org/two' } )->status_is( 404, 'a spoke that fails no check has nothing to fix' );
    $minion->perform_jobs;
};

subtest 'an update of the bot' => sub {
    my %act     = ( 'X-Clod-Action' => 'yes' );
    my $running = $t->app->running;
    $t->get_ok('/api/overview')->status_is(200)->json_is( '/running' => $running, 'the overview names the commit that the page runs' );
    like( $running->{short}, qr/\A[[:xdigit:]]{7}\z/, 'which is the short sha of this checkout' );

    job( self_check => { checked_at => time, running => $running, checkout => { head => $running->{sha}, upstream => 'f' x 40, behind => 2, ahead => 0 }, plugins => [ { id => 'kit@m', version => '0.9', latest => '0.10' }, { id => 'ok@m', version => '1', latest => '1' } ] } );
    $minion->perform_jobs;
    $t->get_ok('/api/overview')->status_is(200);
    my $behind = action_about(qr/out\ of\ date/);
    like( $behind, { text => qr/2\ commit\(s\)\ behind\ upstream/, buttons => [ { label => 'Update', act => 'self/update' } ] }, 'a bot behind its upstream can be updated' );
    my $plugins = action_about(qr/Plugins/);
    like( $plugins, { text => qr/kit\@m\ 0\.9\ to\ 0\.10\.\z/, buttons => [ { label => 'Update plugins', act => 'plugins/update' } ] }, 'and a plugin behind its marketplace, compared as a version' );
    unlike( $plugins->{text}, qr/ok\@m/, 'and not a plugin that is current' );

    $t->post_ok( '/act/self/update' => \%act )->status_is(200);
    my $res    = $t->tx->res;
    my $queued = $res->json->{queued};
    is( $minion->job($queued)->info->{task}, 'self_update', 'Update queues self_update' );
    $t->post_ok( '/act/self/update' => \%act )->status_is(200)->json_is( '/queued' => $queued, 'and a second press no second one' );
    $t->get_ok('/api/overview')->status_is(200);
    like( action_about(qr/out\ of\ date/), { job => $queued, text => qr/It\ is\ queued\.\z/ }, 'and while it waits, the item names it' );
    $t->post_ok( '/act/plugins/update' => \%act )->status_is(200);
    $res = $t->tx->res;
    is( $minion->job( $res->json->{queued} )->info->{task}, 'plugin_update', 'Update plugins queues plugin_update' );
    $minion->perform_jobs;

    job( self_check => { checked_at => time, running => $running, checkout => { head => 'e' x 40, upstream => 'e' x 40, behind => 0, ahead => 0 }, plugins => [] } );
    $minion->perform_jobs;
    $t->get_ok('/api/overview')->status_is(200);
    like( action_about(qr/out\ of\ date/)->{text}, qr/at\ eeeeeee,\ which\ it\ does\ not\ run\ yet/, 'a pulled checkout that the bot does not run yet can be updated too' );

    job( self_check => { checked_at => time, running => $running, checkout => { head => $running->{sha}, upstream => $running->{sha}, behind => 0, ahead => 0 }, plugins => [], deps => [ { module => 'Try::Tiny', version => '0.30', latest => '0.32' } ] } );
    $minion->perform_jobs;
    $t->get_ok('/api/overview')->status_is(200);
    ok( !action_about(qr/out\ of\ date|Plugins/), 'and an up-to-date bot is no action item' );
    like( action_about(qr/Perl\ modules/), { text => qr/Try::Tiny\ 0\.30\ to\ 0\.32/, buttons => [ { label => 'Upgrade modules', act => 'deps/upgrade' } ] }, 'a module with a newer release can be upgraded' );
    $t->post_ok( '/act/deps/upgrade' => \%act )->status_is(200);
    $res = $t->tx->res;
    is( $minion->job( $res->json->{queued} )->info->{task}, 'deps_upgrade', 'Upgrade modules queues deps_upgrade' );
    $minion->perform_jobs;
};

subtest work => sub {
    my $child = job( spoke_fix   => { pr_url  => 'https://test.test/pull/1', summary => 'done' }, notes => { repo => 'Test-Org/one' } );
    my $made  = job( create_repo => { created => 1, repo_url => 'https://test.test/Test-Org/fresh', release_url => 'https://test.test/Test-Org/fresh/issues/1' }, notes => { repo => 'Test-Org/fresh' } );
    my $filed = job( file_issues => { issues => ['https://test.test/Test-Org/two/issues/3'] } );
    job( triage => { children => [ $made, $child, $filed ] }, args => [ { repo => 'Test-Org/one', number => 5, kind => 'fix', title => 'T' } ], notes => { scope => 'single', children => [ $made, $child, $filed ] } );
    job( assigned_sweep => { checked_at => 1, issues => [ { repo => 'Test-Org/one', number => 5 }, { repo => 'Test-Org/one', number => 6 } ] } );
    $minion->perform_jobs;

    $t->get_ok('/api/work')->status_is(200);
    my $work = $t->tx->res->json;
    my ($item) = grep { $_->{task} eq 'triage' } @{ $work->{items} };
    is( [ @$item{qw{origin scope kind}} ], [ q{Test-Org/one#5}, qw{single fix} ], 'an item shows its origin, scope and kind' );
    like( $item->{url}, qr{github\.com/Test-Org/one/issues/5\z}, 'and links to it' );
    is( $item->{children}[1]{pr_url}, 'https://test.test/pull/1', 'its spoke jobs show their pull requests' );
    like( $item->{children}[0], { task => 'create_repo', repo => 'Test-Org/fresh', repo_url => qr{/Test-Org/fresh\z}, release_url => qr{/fresh/issues/1\z} }, 'and a repository that the hub made shows, with its release issue' );
    is( $item->{children}[2]{issue_urls},                 ['https://test.test/Test-Org/two/issues/3'], 'and the follow-up issues that it filed' );
    is( [ map { $_->{has_job} } @{ $work->{assigned} } ], [ 1, 0 ],                                    'an assigned issue with no job is shown as waiting' );
};

subtest 'an outage' => sub {
    job( inbox_poll => { polled_at => time - 3600 } );
    job( triage     => { cost      => 0 }, notes => { outage => { service => 'github', error => 'GitHub GET /notifications: 401 Bad credentials', at => time } } );
    $minion->perform_jobs;
    $t->get_ok('/api/overview')->status_is(200);
    like( action_texts(), qr/inbox\ has\ not\ been\ read/, 'an old poll with no outage is an action item' );

    $minion->lock( App::Clod::Outage::lock_name('github'), 60 );
    $t->get_ok('/api/overview')->status_is(200)->json_is( '/outages/0/service' => 'github', 'the overview names the outage' );
    my $res   = $t->tx->res;
    my $first = $res->json->{actions}[0];
    is( $first->{level}, 'danger', 'and the outage is the first action item' );
    my $when  = qr/\AGitHub\ refuses\ the\ token,\ last\ at\ .+\ UTC:\ /;
    my $error = qr/GitHub\ GET\ \/notifications:\ 401\ Bad\ credentials\.\ /;
    like( $first->{text}, qr/$when$error All\ work\ waits/, 'with the error and what it holds' );
    unlike( action_texts(), qr/inbox\ has\ not\ been\ read/, 'and it replaces the warning about the inbox' );
    $minion->unlock( App::Clod::Outage::lock_name('github') );
};

subtest 'an inbox that waits for spokes' => sub {
    job( inbox_poll => { no_spokes_since => time - 60 } );
    $minion->perform_jobs;
    $t->get_ok('/api/overview')->status_is(200);
    my $item = action_about(qr/spoke/);
    is( $item->{level}, 'info', 'a short wait for the first sweep is only information' );
    like( $item->{text}, qr/waits\ for\ the\ first\ spoke\ sweep/, 'and says what it waits for' );
    unlike( action_texts(), qr/inbox\ has\ not\ been\ read/, 'and does not ask whether a worker runs' );

    job( inbox_poll => { no_spokes_since => time - 1200 } );
    $minion->perform_jobs;
    $t->get_ok('/api/overview')->status_is(200);
    $item = action_about(qr/spoke/);
    is( $item->{level}, 'danger', 'a wait of more than 15 minutes needs a person' );
    like( $item->{text}, qr/No\ repository\ has\ been\ a\ spoke\ for\ 20\ minutes/, 'and says how long it waited' );
};

subtest harness => sub {
    $t->get_ok('/api/harness')->status_is(200)->json_is( '/checks' => [ 'CLAUDE.md', 'git hooks' ], 'the last scan comes back as it is' );
};

done_testing;
