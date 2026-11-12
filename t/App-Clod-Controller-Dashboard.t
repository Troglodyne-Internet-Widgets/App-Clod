#!/usr/bin/env perl
use 5.040;
no autovivification;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use FindBin::libs;
use Digest::SHA ();
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
for my $task (qw{harness_scan inbox_poll assigned_sweep activity_sweep spoke_sweep upstream_sweep release_sweep spoke_fix spoke_address triage reply create_repo file_issues harness_fix self_check self_update plugin_update deps_upgrade packages_install}) {
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
    $t->get_ok('/api/overview')->status_is(200);
    $t->json_is( '/items/active' => 0, 'no items' )->json_is( '/activity' => undef, 'and no activity' );
    my $texts = action_texts();
    like( $texts, qr/No\ harness\ scan\ has\ finished\ yet/, 'says that no scan ran' );
    like( $texts, qr/inbox\ has\ not\ been\ read/,           'and that no worker read the inbox' );
};

subtest overview => sub {
    job( harness_scan   => { repos      => { 'Test-Org/one' => { checks => [ { check => 'CLAUDE.md', status => 'fail' }, { check => 'git hooks', status => 'pass' } ] } }, errors => { 'Test-Org/two' => 'no response' }, marketplace => { status => 'fail', detail => 'the marketplace pins 0.1; the plugin is at 0.2' }, checks => [ 'CLAUDE.md', 'git hooks' ] } );
    job( inbox_poll     => { polled_at  => time, scopes => 'notifications, read:org' } );
    job( spoke_sweep    => { repos      => [], dropped => { 'Test-Org/hidden' => 'its visibility is private, and a spoke must be public' }, errors => { 'Test-Org' => 'GitHub GET /orgs/Test-Org/repos: 404' } } );
    job( spoke_fix      => { error      => 'it broke', cost => 2 }, fail => 1, notes => { origin => 'Test-Org/one#3' } );
    job( activity_sweep => { checked_at => 1, unassigned => 4, opened_7d => 5, merged_7d => 3, errors => { 'Test-Other' => 'GitHub GET /search/issues: 403 API rate limit exceeded' } } );
    $minion->perform_jobs;

    $t->get_ok('/api/overview')->status_is(200);
    $t->json_is( '/budget/cost_7d'      => 2, 'a failed run still counts against the budget' );
    $t->json_is( '/activity/unassigned' => 4, 'the open issues come from the last activity sweep' );
    $t->json_is( '/activity/opened_7d'  => 5, 'with the issues of 7 days' );
    $t->json_is( '/activity/merged_7d'  => 3, 'and the merged pull requests' );
    my $texts = action_texts();
    like( $texts, qr/Marketplace:\ the\ marketplace\ pins\ 0\.1/,                'a stale marketplace pin is an action item' );
    like( $texts, qr/Test-Org\/one\ fails\ 1\ harness\ check\(s\):\ CLAUDE\.md/, 'so is a failing harness check' );
    like( $texts, qr/Harness\ scan\ of\ Test-Org\/two\ failed:\ no\ response/,   'and a scan that failed' );
    like( $texts, qr/lacks\ the\ scopes:\ repo\./,                               'and a missing token scope' );
    my $counts   = qr/counts\ of\ issues\ and\ pull\ requests/;
    my $left_out = qr/$counts\ leave\ out\ the\ spokes\ of\ Test-Other,/;
    like( $texts, qr/$left_out\ because\ their\ search\ failed:\ GitHub\ GET\ \S+\ 403/, 'and counts that leave out an owner whose search failed' );
    like( $texts, qr/repositories\ of\ Test-Org\ failed:\ GitHub\ GET\ \S+\ 404/,        'and an organization that could not be listed' );
    like( $texts, qr/hidden\ is\ not\ a\ spoke:\ its\ visibility\ is\ private/,          'and a configured repository that is not public' );
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

subtest 'a harness fix that waits for review' => sub {
    my $scan = { checked_at => time - 600, repos => { 'Test-Org/one' => { checks => [ { check => 'CLAUDE.md', status => 'fail' } ] } }, checks => [ 'CLAUDE.md', 'git hooks' ] };
    job( harness_scan => $scan );
    job( harness_fix  => { repo => 'Test-Org/one', pr_url => 'https://github.com/Test-Org/one/pull/33' }, notes => { repo => 'Test-Org/one' } );
    $minion->perform_jobs;
    $t->get_ok('/api/overview')->status_is(200);
    my $item = action_about(qr/harness\ check/);
    like( $item, { text => qr/A\ fix\ waits\ for\ review:\z/, link => { url => 'https://github.com/Test-Org/one/pull/33', label => '#33' } }, 'a harness fix that opened a pull request links to it' );
    ok( !$item->{buttons}, 'and offers no second Fix' );

    job( harness_scan => { %$scan, checked_at => time + 1, repos => { 'Test-Org/one' => { %{ $scan->{repos}{'Test-Org/one'} }, fix_pr => 'https://github.com/Test-Org/one/pull/33' } } } );
    $minion->perform_jobs;
    $t->get_ok('/api/overview')->status_is(200);
    is( action_about(qr/harness\ check/)->{link}{label}, '#33', 'a later scan that finds it open keeps the link' );

    job( harness_scan => { %$scan, checked_at => time + 2 } );
    $minion->perform_jobs;
    $t->get_ok('/api/overview')->status_is(200);
    is( [ map { $_->{label} } @{ action_about(qr/harness\ check/)->{buttons} // [] } ], ['Fix'], 'and once a scan finds it closed, Fix is back' );

    # The claude run that a harness fix queues when the hooks refuse its commit.
    my $run = job( spoke_fix => {}, notes => { repo => 'Test-Org/one', harness => 'Test-Org/one' } );
    $t->get_ok('/api/overview')->status_is(200);
    like( action_about(qr/harness\ check/), { job => $run, text => qr/A\ harness\ fix\ of\ it\ is\ queued/ }, 'while the claude run of a harness fix waits, the item says so' );
    $t->post_ok( '/act/harness/fix' => { 'X-Clod-Action' => 'yes' } => json => { repo => 'Test-Org/one' } )->status_is(200)->json_is( '/queued' => $run, 'and Fix queues no second fix' );
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
    job( self_check => { checked_at => time, running => $running, checkout => { head => $running->{sha}, upstream => $running->{sha}, behind => 0, ahead => 0 }, plugins => [], agent_deps => { missing => ['Perl::Critic::Policy::ProhibitPipeOpen'], outdated => [ { module => 'Perl::Tidy', version => '1', latest => '2' } ] } } );
    $minion->perform_jobs;
    $t->get_ok('/api/overview')->status_is(200);
    my $tools = action_about(qr/agent/);
    like( $tools,         { text => qr/lacks\ these\ tools:\ \S+ProhibitPipeOpen\./, buttons => [ { label => 'Install tools', act => 'deps/upgrade' } ] }, 'tools that the agent lacks can be installed' );
    like( $tools->{text}, qr/Perl::Tidy\ 1\ to\ 2\.\z/,                                                                                                    'and so can those with a newer release' );
    $t->post_ok( '/act/deps/upgrade' => \%act )->status_is(200);
    $res = $t->tx->res;
    is( $minion->job( $res->json->{queued} )->info->{task}, 'deps_upgrade', 'Upgrade modules queues deps_upgrade' );
    $minion->perform_jobs;

    my $check = $minion->enqueue( self_check => [] => { delay => 60 } );
    $t->get_ok('/api/overview')->status_is(200);
    my $rechecked = action_about(qr/agent/);
    like( $rechecked, { job => $check, text => qr/A\ new\ check\ is\ queued\.\z/ }, 'after the action, the item names the check that it queued' );
    ok( !$rechecked->{buttons}, 'and has no button, because the check will say whether the action worked' );
    $minion->job($check)->remove;
};

subtest 'system packages' => sub {
    my %act = ( 'X-Clod-Action' => 'yes' );
    job( harness_scan => { checked_at => time, repos => {}, checks => [ 'CLAUDE.md', 'git hooks' ], system_packages => {}, system_package_errors => { 'Test-Org/two' => "metamerge.yml is not valid:\n  /x_system_packages/deb/0: String does not match" } } );
    my %jellyfin = ( name => 'jellyfin', uri => 'https://repo.test.test/ubuntu', suites => ['noble'], components => ['main'], key => 'https://repo.test.test/key.gpg', fingerprint => '0123456789ABCDEF0123456789ABCDEF01234567' );
    my %lacks    = (
        'Test-Org/one' => {
            needs      => [ { name => 'libxml2', package => 'libxml2-dev', archive => undef }, { name => 'ffmpeg', package => 'ffmpeg', archive => \%jellyfin } ],
            missing    => [qw{libxml2-dev ffmpeg}],
            sources    => [ \%jellyfin ],
            unresolved => ['FooLib'],
            failing    => [],
        },
        'Test-Org/three' => { needs => [], missing => [], sources => [], unresolved => [], failing => [], error => 'The source jellyfin needs the codename of the host, for the suite {codename}' },
        'Test-Org/two'   => { needs => [], missing => [], sources => [], unresolved => [], failing => [ { program => 'ffmpeg -version', dependency => 'ffmpeg', error => 'ffmpeg: not found' } ] },
    );
    $t->app->clod_config->{system_packages} = { packager => 'deb', installer => '/bogus/clod-install-packages' };
    job( self_check => { checked_at => time, plugins => [], system_host => { distro => 'ubuntu', release => '24.04', codename => 'noble' }, system_packages => \%lacks } );
    $minion->perform_jobs;
    $t->get_ok('/api/overview')->status_is(200);
    my $unreadable = qr/\AHarness\ scan\ of\ Test-Org\/two\ cannot\ read\ .+:\ /;
    like( action_about(qr/system\ packages\ that\ it\ needs/), { level => 'danger', text => qr/${unreadable}metamerge\.yml\ is\ not\ valid:/ }, 'a declaration that is not valid is a finding of its spoke, as a scan that failed is' );
    my $needs = action_about(qr/libxml2\ \(/);
    is(
        $needs,
        { level => 'warning', text => "Test-Org/one needs libxml2 (libxml2-dev) and ffmpeg (ffmpeg, from the archive jellyfin, key 0123\N{HORIZONTAL ELLIPSIS}4567).", buttons => [ { label => 'Install packages', act => 'packages/install', body => { repo => 'Test-Org/one' } } ] },
        'packages that the host lacks are an item of their spoke, which names each dependency with its package, and the archive that an install adds, with its key, and a button that installs them'
    );
    is( action_about(qr/declares\ no/),    { level => 'danger',  text => 'Test-Org/one needs FooLib, and declares no deb package for it on ubuntu 24.04.' },                                                           'a dependency with no package for this host is an item of its own, with no button, beside the button for the rest' );
    is( action_about(qr/Test-Org\/three/), { level => 'warning', text => 'The bot cannot tell what Test-Org/three needs on this host: The source jellyfin needs the codename of the host, for the suite {codename}' }, 'and a declaration that does not resolve on this host says why, with no button' );
    is( action_about(qr/fails,\ and/),     { level => 'warning', text => 'ffmpeg -version fails, and Test-Org/two needs it for ffmpeg: ffmpeg: not found' },                                                           'and a program that fails with every package there is an item with no button' );

    $t->post_ok( '/act/packages/install' => json => { repo => 'Test-Org/one' } )->status_is( 403, 'an install without the header is refused' );
    $t->post_ok( '/act/packages/install' => \%act => json => { repo => 'Test-Org/one', packages => ['bogus-package'], sources => [ { name => 'bogus' } ] } )->status_is(200);
    my $res  = $t->tx->res;
    my $id   = $res->json->{queued};
    my $info = $minion->job($id)->info;
    is( [ $info->@{qw{task args}} ], [ 'packages_install', [ { repo => 'Test-Org/one', packages => [qw{libxml2-dev ffmpeg}], sources => [ \%jellyfin ] } ] ], 'Install packages queues an install of the names and the archives that the check found, and none that the request names' );
    $t->post_ok( '/act/packages/install' => \%act => json => { repo => 'Test-Org/one' } )->status_is(200)->json_is( '/queued' => $id, 'and a second press queues no second one' );
    $t->get_ok('/api/overview')->status_is(200);
    like( action_about(qr/libxml2\ \(/), { job => $id, text => qr/It\ is\ queued\.\z/ }, 'while it waits, the item names it' );
    ok( !action_about(qr/libxml2\ \(/)->{buttons}, 'and has no button' );
    $t->post_ok( '/act/packages/install' => \%act => json => { repo => 'Test-Org/two' } )->status_is( 404, 'a spoke that misses no package has nothing to install' );
    $minion->perform_jobs;

    my $check = $minion->enqueue( self_check => [] => { delay => 60 } );
    $t->get_ok('/api/overview')->status_is(200);
    like( action_about(qr/libxml2\ \(/), { job => $check, text => qr/A\ new\ check\ is\ queued\.\z/ }, 'after the install, the item names the check that it queued' );
    $minion->job($check)->remove;
    job( self_check => { checked_at => time, plugins => [], system_packages => {} } );
    $minion->perform_jobs;
    $t->get_ok('/api/overview')->status_is(200);
    ok( !action_about(qr/libxml2\ \(|fails,\ and/), 'and once the check finds everything, there is no item' );

    job( self_check => { checked_at => time, plugins => [], system_packages => {}, system_packages_error => 'dpkg-query: Command not found' } );
    $minion->perform_jobs;
    $t->get_ok('/api/overview')->status_is(200);
    is( action_about(qr/system\ packages\ of\ the\ spokes/), { level => 'warning', text => 'The bot cannot tell whether it has the system packages of the spokes: dpkg-query: Command not found' }, 'a check that cannot ask dpkg says so, with no button' );
    ok( !action_about(qr/libxml2\ \(/), 'and lists no package as missing' );
    delete $t->app->clod_config->{system_packages};
};

subtest 'a pull request that needs system packages' => sub {
    my %act      = ( 'X-Clod-Action' => 'yes' );
    my %jellyfin = ( name            => 'jellyfin', uri => 'https://repo.test.test/ubuntu', suites => ['noble'], components => ['main'], key => 'https://repo.test.test/key.gpg', fingerprint => '0123456789ABCDEF0123456789ABCDEF01234567' );
    my $url      = 'https://github.test/Test-Org/one/pull/7';
    my %waits    = ( repo => 'Test-Org/one', pr => 7, pr_url => $url, branch => 'clod/1-video', needs_packages => 1, packages => ['ffmpeg'], sources => [ \%jellyfin ], needs => [ { name => 'ffmpeg', package => 'ffmpeg', archive => \%jellyfin } ] );
    my $fix      = job( spoke_fix => \%waits, notes => { repo => 'Test-Org/one' } );
    $minion->perform_jobs;
    $t->get_ok('/api/overview')->status_is(200);
    my $item = action_about(qr/\#7\ needs/);
    my $diff = "$url/files#diff-" . Digest::SHA::sha256_hex('metamerge.yml');
    is(
        $item,
        {
            level   => 'warning',
            job     => $fix,
            text    => "Test-Org/one#7 needs ffmpeg (ffmpeg, from the archive jellyfin, key 0123\N{HORIZONTAL ELLIPSIS}4567) to test its change.",
            link    => { url => $url, label => '#7' },
            buttons => [
                { label => 'Install and resume', act => 'packages/install', body => { job => $fix }, confirm => { pr_url => $url, diff_url => $diff, packages => ['ffmpeg'], sources => [ { name => 'jellyfin', uri => 'https://repo.test.test/ubuntu', key => 'https://repo.test.test/key.gpg', fingerprint => '0123456789ABCDEF0123456789ABCDEF01234567' } ] } },
                { label => 'Ignore', act => "jobs/$fix/ignore" },
            ],
        },
        'a pull request whose branch needs packages that the host lacks is an item, with a button that installs them and resumes, which first shows what it installs and links to the diff of the declaration'
    );

    $t->post_ok( '/act/packages/install' => json => { job => $fix } )->status_is( 403, 'an install and resume without the header is refused' );
    $t->post_ok( '/act/packages/install' => \%act => json => { job => $fix, packages => ['bogus-package'] } )->status_is(200);
    my $res     = $t->tx->res;
    my $install = $res->json->{queued};
    my $info    = $minion->job($install)->info;
    is( [ $info->@{qw{task args}} ], [ 'packages_install', [ { repo => 'Test-Org/one', packages => ['ffmpeg'], sources => [ \%jellyfin ], resume => $fix } ] ], 'Install and resume queues an install of what the job found, and no name that the request names, which resumes that job' );
    $t->post_ok( '/act/packages/install' => \%act => json => { job => $fix } )->status_is(200)->json_is( '/queued' => $install, 'and a second press queues no second one' );
    $t->get_ok('/api/overview')->status_is(200);
    like( action_about(qr/\#7\ needs/), { job => $install, text => qr/It\ is\ queued\.\z/ }, 'while it waits, the item names it' );
    ok( !action_about(qr/\#7\ needs/)->{buttons}, 'and has no button' );
    $t->post_ok( '/act/packages/install' => \%act => json => { job => 'x' } )->status_is( 404, 'a job that is not a number waits for no package' );
    my $plain = job( spoke_fix => { repo => 'Test-Org/one', pr => 8, pr_url => 'https://github.test/Test-Org/one/pull/8' } );
    $minion->perform_jobs;
    $t->post_ok( '/act/packages/install' => \%act => json => { job => $plain } )->status_is( 404, 'and nor does a job whose branch needs none' );

    my $resume = $minion->enqueue('spoke_address');
    $minion->job($fix)->note( resumed => $resume );
    $t->post_ok( '/act/packages/install' => \%act => json => { job => $fix } )->status_is( 404, 'a job whose work resumed cannot resume again' );
    $t->get_ok('/api/overview')->status_is(200);
    like( action_about(qr/\#7\ needs/), { job => $resume, text => qr/the\ work\ resumes\.\z/ }, 'after the install, the item names the job that resumes the work' );
    $minion->perform_jobs;
    $t->get_ok('/api/overview')->status_is(200);
    ok( !action_about(qr/\#7\ needs/), 'and once that job ran, there is no item' );

    my $other = job( spoke_fix => { %waits, pr => 9, pr_url => 'https://github.test/Test-Org/one/pull/9' } );
    $minion->perform_jobs;
    $t->get_ok('/api/overview')->status_is(200);
    is( action_about(qr/\#9\ needs/)->{job}, $other, 'another pull request that needs packages is an item' );
    job( spoke_address => { repo => 'Test-Org/one', pr => 9, pr_url => 'https://github.test/Test-Org/one/pull/9' } );
    $minion->perform_jobs;
    $t->get_ok('/api/overview')->status_is(200);
    ok( !action_about(qr/\#9\ needs/), 'until a later job of the same pull request needs none' );

    my $ignored = job( spoke_fix => { %waits, pr => 10, pr_url => 'https://github.test/Test-Org/one/pull/10' } );
    $minion->perform_jobs;
    $t->post_ok( "/act/jobs/$ignored/ignore" => \%act )->status_is(200)->json_is( '/ignored' => $ignored );
    $t->get_ok('/api/overview')->status_is(200);
    ok( !action_about(qr/\#10\ needs/), 'and Ignore takes the item off the list' );
    $t->post_ok( "/act/jobs/$plain/ignore" => \%act )->status_is( 404, 'a finished job that needs no package cannot be ignored' );

    $t->get_ok('/')->status_is(200);
    my $dom   = $t->tx->res->dom;
    my $where = qr/Nobody\ has\ reviewed .* from\ the\ text\ of\ an\ issue/s;
    my $trust = qr/trusts\ the\ archive/;
    my $root  = qr/as\ root .* signing\ key .* $trust\ for\ every\ package/s;
    my $read  = qr/Read\ the\ change\ to\ the\ declaration/;
    like( $dom->at('#confirm-install .modal-body')->all_text, qr/$where .* $root .* $read/s, 'the dialog says where the declaration comes from, what the install does as root, and to read the diff first' );
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

subtest 'the filter of the action items' => sub {
    $t->get_ok('/')->status_is(200);
    for my $pair ( [ danger => 'Failures' ], [ warning => 'Warnings' ], [ info => 'Info' ] ) {
        my ( $level, $label ) = @$pair;
        $t->element_exists( qq{#action-filter button.active[data-level="$level"][aria-pressed="true"]}, "the $level button is on by default" )->text_is( qq{#action-filter button[data-level="$level"]} => $label, "and reads $label" );
    }
};

subtest upstream => sub {
    $t->get_ok('/api/upstream')->status_is(200)->json_is( '' => { pulls => [], errors => {} }, 'before the first sweep, no pull request and no error' );
    $t->get_ok('/api/overview')->status_is(200);
    ok( !action_about(qr/upstream/), 'and no action item' );

    my %pull = ( repo => 'Upstream/one', number => 1, url => 'https://test.test/Upstream/one/pull/1', mergeable => 'MERGEABLE' );
    job( upstream_sweep => { checked_at => 1, pulls => [ \%pull, +{ %pull, number => 2, mergeable => 'UNKNOWN' } ], errors => {} } );
    $minion->perform_jobs;
    $t->get_ok('/api/overview')->status_is(200);
    ok( !action_about(qr/upstream/), 'pull requests that do not conflict are no action item' );

    my $sweep = { checked_at => 2, pulls => [ +{ %pull, number => 3, mergeable => q{CONFLICTING} }, +{ %pull, number => 4, mergeable => q{CONFLICTING} }, \%pull ], errors => { 'some-user' => 'GitHub GraphQL: API rate limit exceeded' } };
    job( upstream_sweep => $sweep );
    $minion->perform_jobs;
    $t->get_ok('/api/upstream')->status_is(200)->json_is( '' => $sweep, 'the endpoint serves the last sweep as it is, with its errors' );
    $t->get_ok('/api/overview')->status_is(200);
    is( action_about(qr/upstream/), { level => 'warning', text => '2 upstream PRs conflict with their base, and need a rebase:', link => { url => '#upstream', label => 'Upstream' } }, 'conflicting pull requests are one warning that counts them, with a link to the Upstream tab' );

    $t->get_ok('/')->status_is(200);
    $t->element_exists( '[data-bs-toggle="tab"][data-bs-target="#upstream"]', 'the page has the Upstream tab' )->element_exists( 'section#upstream #upstream-pulls', 'with its table' );
};

subtest releases => sub {
    $t->get_ok('/api/releases')->status_is(200)->json_is( '' => { dists => [], errors => {} }, 'before the first sweep, no distribution and no error' );
    $t->get_ok('/api/overview')->status_is(200);
    ok( !action_about(qr/CPAN|release\ check/), 'and no action item' );

    job( release_sweep => { checked_at => 1, checked => 2, dists => [], errors => {} } );
    $minion->perform_jobs;
    $t->get_ok('/api/overview')->status_is(200);
    ok( !action_about(qr/CPAN|release\ check/), 'a sweep that found every distribution on CPAN is no action item' );

    my %dist  = ( repo => 'Test-Org/one', name => 'Test-One', version => '0.002', state => 'never_released' );
    my $sweep = { checked_at => 2, checked => 3, dists => [ \%dist, +{ %dist, repo => 'Test-Org/two', name => 'Test-Two', state => 'no_tag' } ], errors => { 'Test-Org/three' => 'MetaCPAN GET /release/versions/Test-Three: 500 Internal Server Error' } };
    job( release_sweep => $sweep );
    $minion->perform_jobs;
    $t->get_ok('/api/releases')->status_is(200)->json_is( '' => $sweep, 'the endpoint serves the last sweep as it is, with its errors' );
    $t->get_ok('/api/overview')->status_is(200);
    is( action_about(qr/not\ on\ CPAN/), { level => 'info', text => '2 distributions have work that is not on CPAN:', link => { url => '#releases', label => 'Releases' } }, 'the distributions are one item that counts them, with a link to the Releases tab' );
    is(
        action_about(qr/release\ check/),
        { level => 'warning', text => 'The release check of Test-Org/three failed, so the Releases tab keeps what the sweep before found for it: MetaCPAN GET /release/versions/Test-Three: 500 Internal Server Error' },
        'and a spoke whose check failed is a warning'
    );

    $t->get_ok('/')->status_is(200);
    $t->element_exists( '[data-bs-toggle="tab"][data-bs-target="#releases"]', 'the page has the Releases tab' )->element_exists( 'section#releases #releases-dists', 'with its table' );
};

subtest harness => sub {
    $t->get_ok('/api/harness')->status_is(200)->json_is( '/checks' => [ 'CLAUDE.md', 'git hooks' ], 'the last scan comes back as it is' );
};

done_testing;
