#!/usr/bin/env perl
use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use FindBin::libs;
use Clone            ();
use File::Temp       ();
use IPC::Run         ();
use Mojo::File       ();
use Mojo::JSON       ();
use Mojo::UserAgent  ();
use Mojolicious      ();
use Test::MockModule ();
use Time::HiRes      qw{time};

use App::Clod();
use App::Clod::Outage();
use App::Clod::Tasks();

my $here = Mojo::File->new(__FILE__)->dirname->to_abs;
my $tmp  = Mojo::File->new( File::Temp->newdir->dirname )->child( 'clod-tasks-' . $$ )->make_path;
END { $tmp->remove_tree if $tmp }

my $BOT    = 'test-bot';
my @SPOKES = qw{Test-Org/one Test-Org/two};

sub git (@args) {
    my ( $out, $err );
    IPC::Run::run( [ "git", @args ], ">", \$out, "2>", \$err ) or die "git @args: $err";
    chomp $out;
    return $out;
}

# Each spoke is a bare repository on disk, standing in for GitHub's git side.
my $remote = $tmp->child('remote');

sub seed ( $repo, $name, $text ) {
    my $bare = $remote->child("$repo.git");
    $bare->dirname->make_path;
    git( qw{init --quiet --bare --initial-branch=main}, "$bare" );
    my $seed = $tmp->child( 'seed', $repo )->make_path;
    git( q{-C}, "$seed", qw{init --quiet --initial-branch=main} );
    $seed->child($name)->spew($text);
    git( '-C',  "$seed", 'add', q{.} );
    git( q{-C}, "$seed", qw{-c user.name=t -c user.email=t@test.test commit --quiet -m seed} );
    git( '-C',  "$seed", 'push', '--quiet', "$bare", 'main' );
    return;
}
seed( $_, 'CLAUDE.md', "# CLAUDE.md\n\n$_ is a test spoke.\n" ) for @SPOKES;

sub path_of ($c) {
    my $url = $c->req->url;
    return $url->path->to_string;
}

# The REST side of GitHub, recording each call that changes something.
my ( @calls, %state );
my $fake = Mojolicious->new;
$fake->log->level('fatal');
$fake->hook( before_dispatch => sub ($c) { $c->render( json => { message => 'Bad credentials' }, status => 401 ) if $state{bad_token} } );
my $r      = $fake->routes;
my $record = sub ($what) {
    return sub ($c) {
        return $c->render( json => { message => 'Server Error' }, status => 500 ) if $state{"refuse_$what"};
        push @calls, [ $what, path_of($c), $c->req->json ];
        $c->render( json => $state{$what} // {}, status => 201 );
    };
};
$r->get('/notifications')->to( cb => sub ($c) { $state{inbox_reads}++; $c->render( json => $state{threads} // [] ) } );
$r->patch('/notifications/threads/:id')->to( cb => $record->('read') );
$r->get('/repos/:o/:n/issues/:num/events')->to( cb => sub ($c) { $c->render( json => $state{events} // [] ) } );
$r->get('/repos/:o/:n/issues/:num/comments')->to( cb => sub ($c) { $c->render( json => $state{issue_comments} // [ { id => 1, user => { login => 'someone' }, body => 'a comment' } ] ) } );
$r->get('/repos/:o/:n/issues/:num')->to( cb => sub ($c) { $c->render( json => { title => 'The issue', body => 'Please fix it.', user => { login => 'someone' }, state => $state{closed}{ $c->param('num') } ? 'closed' : 'open' } ) } );
$r->post('/repos/:o/:n/issues/:num/reactions')->to( cb => $record->('react') );
$r->post('/repos/:o/:n/issues/:num/comments')->to( cb => $record->('comment') );
$r->post('/repos/:o/:n/issues/:num/assignees')->to( cb => $record->('assign') );
$r->delete('/repos/:o/:n/issues/:num/assignees')->to( cb => $record->('unassign') );
$r->get('/repos/:o/:n/pulls/:num/comments')->to( cb => sub ($c) { $c->render( json => $state{review_comments} // [] ) } );
$r->get('/repos/:o/:n/pulls/:num/reviews')->to( cb => sub ($c) { $c->render( json => $state{reviews} // [] ) } );
$r->post('/repos/:o/:n/pulls/:num/comments/:id/replies')->to( cb => $record->('reply') );
$r->post('/repos/:o/:n/pulls/:num/reviews')->to(
    cb => sub ($c) {
        push @calls, [ 'review', path_of($c), $c->req->json ];
        return $c->render( json => { message  => 'Unprocessable' }, status => 422 ) if $state{refuse_comments} && @{ $c->req->json->{comments} // [] };
        return $c->render( json => { html_url => 'https://test.test/review' } );
    }
);
$r->get('/repos/:o/:n/pulls/:num')->to( cb => sub ($c) { $c->render( json => $state{pull} // { body => 'old body', base => { ref => 'main' }, head => { sha => 'abc' } } ) } );
$r->patch('/repos/:o/:n/pulls/:num')->to( cb => $record->('update_pull') );
$r->post('/repos/:o/:n/pulls')->to(
    cb => sub ($c) {
        return $c->render( json => { message => 'Server Error' }, status => 500 ) if $state{refuse_pull};
        push @calls, [ 'pull', path_of($c), $c->req->json ];
        my $n = 100 + scalar grep { $_->[0] eq 'pull' } @calls;
        $c->render( json => { number => $n, html_url => "https://test.test/" . $c->param('o') . q{/} . $c->param('n') . "/pull/$n" }, status => 201 );
    }
);
$r->get('/repos/:o/:n/contents/*file')->to( cb => sub ($c) { my $f = $state{files}{ $c->param('file') }; defined $f ? $c->render( text => $f ) : $c->render( json => {}, status => 404 ) } );
$r->get('/repos/:o/:n/git/trees/*ref')->to(
    cb => sub ($c) {
        $c->render( json => { tree => [ map { { path => $_, sha => "sha-$_" } } sort keys %{ $state{files} // {} } ] } );
    }
);
$r->get('/orgs/:o/repos')->to(
    cb => sub ($c) {
        return $c->render( json => { message => 'Not Found' }, status => 404 ) if $state{org_missing};
        $c->render(
            json => [
                { full_name => 'Test-Org/one',  fork => Mojo::JSON::false, archived => Mojo::JSON::false },
                { full_name => 'Test-Org/new',  fork => Mojo::JSON::false, archived => Mojo::JSON::false },
                { full_name => 'Test-Org/fork', fork => Mojo::JSON::true,  archived => Mojo::JSON::false },
                { full_name => 'Test-Org/old',  fork => Mojo::JSON::false, archived => Mojo::JSON::true },
            ]
        );
    }
);
$r->get('/repos/:o/:n/issues')->to( cb => sub ($c) { $c->render( json => [ { number => 5, title => 'Assigned', html_url => 'https://test.test/5', updated_at => 'today' } ] ) } );
$r->get('/repos/:o/:n')->to(
    cb => sub ($c) {
        return $c->render( json => { message => 'Not Found' }, status => 404 ) if $state{absent}{ $c->param('o') . q{/} . $c->param('n') };
        $c->render( json => { default_branch => 'main', owner => { type => 'Organization', login => $c->param('o') } } );
    }
);

# Making a repository puts it on disk, with the README that auto_init writes.
$r->post('/orgs/:o/repos')->to(
    cb => sub ($c) {
        my $full = $c->param('o') . q{/} . $c->req->json->{name};
        push @calls, [ 'create', path_of($c), $c->req->json ];
        delete $state{absent}{$full};
        seed( $full, 'README.md', "# $full\n" );
        $c->render( json => { full_name => $full, html_url => "https://test.test/$full", default_branch => 'main' }, status => 201 );
    }
);
$r->post('/repos/:o/:n/issues')->to(
    cb => sub ($c) {
        push @calls, [ 'issue', path_of($c), $c->req->json ];
        my @assignees = $state{drop_assignee} ? () : map { { login => $_ } } @{ $c->req->json->{assignees} // [] };
        $c->render( json => { number => 1, html_url => 'https://test.test/' . $c->param('o') . q{/} . $c->param('n') . '/issues/1', assignees => \@assignees }, status => 201 );
    }
);

$r->get('/comment')->to( cb => sub ($c) { $c->render( json => { user => { login => $state{commenter} } } ) } );

my $fake_ua = Mojo::UserAgent->new;
$fake_ua->server->app($fake);
my $api    = $fake_ua->server->url->to_string =~ s{/\z}{}r;
my $github = Test::MockModule->new('App::Clod::GitHub');
$github->redefine( new => sub ( $class, %args ) { $github->original("new")->( $class, %args, api => $api, token => "test-token", ua => $fake_ua ) } );

my $conf = $tmp->child('clod.conf');
$conf->spew(
    Mojo::Util::dumper(
        {
            bot              => $BOT,
            workspace        => $tmp->child('workspace')->to_string,
            github_web       => "file://$remote",
            spokes           => \@SPOKES,
            authorized_users => ['trusted'],
            owners           => ['Test-Org'],
            auth             => { trusted_header => 'X-Test-User' },
            poll_interval    => 0,
            claude           => { bin    => $here->child( 'bin', 'fake-claude' )->to_string, timeout   => 60 },
            harness          => { flavor => 'test-default',                                  standards => { directory => $here->child( 'data', 'standards' )->to_string } },
        }
    )
);
local $ENV{CLOD_CONFIG} = "$conf";
local $ENV{GH_TOKEN}    = 'test-token';
my $app = App::Clod->new;
$app->log->level('fatal');
my $minion = $app->minion;

# The fake claude prints these events, ending with this structured answer.
# run_id gives %fake to its environment.
my $STREAMS = 0;
my %fake;

sub answer ( $structured, %env ) {
    my $stream = $tmp->child( 'stream-' . ++$STREAMS . '.jsonl' );
    $stream->spew( Mojo::JSON::encode_json( { type => 'result', is_error => Mojo::JSON::false, structured_output => $structured, total_cost_usd => 0.5, usage => {} } ) . "\n" );
    %fake = ( FAKE_CLAUDE_STREAM => "$stream", FAKE_CLAUDE_COMMIT => $env{commit} ? 1 : 0 );
    return;
}

sub run_job ( $task, @args ) { return run_id( $minion->enqueue( $task => \@args ) ) }

# Runs the job in this process, where the fake GitHub is listening.
sub run_id ($id) {
    local @ENV{ keys %fake } = values %fake;
    my $job = $minion->worker->register->dequeue( 0, { id => $id } );
    my $err = $job->execute;
    $job->fail($err) if defined $err;
    $minion->worker->unregister;
    return $minion->job($id)->info;
}

sub calls_of ($what) {
    return [ grep { $_->[0] eq $what } @calls ];
}

# What the fake claude recorded: its directory, its prompt, and the values of each flag.
sub record_of ($file) {
    my ( $cwd, $prompt, @argv ) = split /\0/, Mojo::File->new($file)->slurp;
    my %flags;
    push @{ $flags{ $argv[$_] } }, $argv[ $_ + 1 ] for grep { $argv[$_] =~ m{\A--} } 0 .. $#argv - 1;
    return { cwd => $cwd, prompt => $prompt, flags => \%flags };
}

my %item = ( repo => 'Test-Org/one', number => 7, kind => 'fix', is_pr => 0, title => 'Fix the thing!', requester => 'trusted' );

subtest inbox_poll => sub {
    %state = ();
    @calls = ();
    my %thread = ( reason => 'assign', updated_at => 't1', subject => { type => 'Issue', url => "$api/repos/Test-Org/one/issues/7", title => 'Fix the thing!' } );
    $state{threads} = [
        +{ %thread, id => 1, repository => { full_name => 'Test-Org/one' } },
        +{ %thread, id => 2, repository => { full_name => 'Elsewhere/repo' } },
        +{ %thread, id => 3, repository => { full_name => 'Test-Org/two' }, reason => 'subscribed' },
    ];
    $state{events} = [ { event => 'assigned', assignee => { login => $BOT }, actor => { login => 'trusted' } } ];

    my $info = run_job('inbox_poll');
    is( $info->{state},                      'finished', 'the poll finishes' ) or diag Mojo::Util::dumper $info->{result};
    is( scalar @{ $info->{result}{queued} }, 1,          'one thread becomes work' );
    my $triage = $minion->job( $info->{result}{queued}[0] )->info;
    is( $triage->{task}, 'triage', 'an assignment goes to triage' );
    like( $triage->{args}[0], { repo => 'Test-Org/one', number => 7, kind => 'fix', requester => 'trusted' }, 'with the item' );
    is( $triage->{notes}{origin},      'Test-Org/one#7', 'noted with its origin' );
    is( scalar @{ calls_of('react') }, 1,                'the bot reacts to what it takes' );
    is( scalar @{ calls_of('read') },  3,                'and marks every thread read, taken or not' );
    like( $info->{result}{ignored}, [ qr/Elsewhere\/repo\ is\ not\ a\ spoke/, qr/nothing\ to\ do\ for\ reason\ 'subscribed'/ ], 'and says why it left the rest' );

    my $again = run_job('inbox_poll');
    is( $again->{result}{queued}, [], 'a thread seen before at the same update is not queued twice' );

    $state{threads} = [ +{ %thread, id => 4, updated_at => 't2', repository => { full_name => 'Test-Org/one' } } ];
    $state{events}  = [ { event => 'assigned', assignee => { login => $BOT }, actor => { login => 'stranger' } } ];
    my $stranger = run_job('inbox_poll');
    like( $stranger->{result}{ignored}, [qr/requested\ by\ stranger,\ who\ is\ not\ authorized/], 'an assignment by someone not authorized is left alone' );

    $state{threads}   = [ { id => 5, reason => 'mention', updated_at => 't3', repository => { full_name => 'Test-Org/one' }, subject => { type => 'Issue', url => "$api/repos/Test-Org/one/issues/8", latest_comment_url => "$api/comment" } } ];
    $state{commenter} = 'trusted';
    my $mention = run_job('inbox_poll');
    is( $minion->job( $mention->{result}{queued}[0] )->info->{task}, 'reply', 'a mention goes straight to a reply' );

    @calls          = ();
    $state{closed}  = { 9 => 1 };
    $state{threads} = [ { id => 6, reason => 'author', updated_at => 't4', repository => { full_name => 'Test-Org/one' }, subject => { type => 'PullRequest', url => "$api/repos/Test-Org/one/pulls/9", latest_comment_url => "$api/comment" } } ];
    my $closed = run_job('inbox_poll');
    is( $closed->{result}{queued}, [], 'a notification on a closed pull request makes no work' );
    like( $closed->{result}{ignored}, [qr/Test-Org\/one\#9\ is\ closed/], 'and says so' );
    is( [ map { $_->[0] } @calls ], ['read'], 'it is marked read, without a reaction' );
    $minion->reset( { all => 1 } );

    my %comment = ( id => 7, reason => 'author', repository => { full_name => 'Test-Org/one' }, subject => { type => 'PullRequest', url => "$api/repos/Test-Org/one/pulls/11", latest_comment_url => "$api/comment" } );
    my $waiting = $minion->enqueue( spoke_address => [ {} ], { notes => { origin => 'Test-Org/one#11' } } );
    $state{threads} = [ +{ %comment, updated_at => 't5' } ];
    my $once = run_job('inbox_poll');
    is( $once->{result}{queued}, [], 'a comment on a pull request that a waiting job will answer makes no second job' );
    like( $once->{result}{ignored}, [qr/job\ $waiting\ will\ answer\ Test-Org\/one\#11/], 'and says which job will' );

    my $worker  = $minion->worker->register;
    my $running = $worker->dequeue( 0, { id => $waiting } );
    $state{threads} = [ +{ %comment, updated_at => 't6' } ];
    my $later = run_job('inbox_poll');
    is( scalar @{ $later->{result}{queued} }, 1, 'but a job that already runs has read what it answers, so a later comment gets a job of its own' ) or diag Mojo::Util::dumper $later->{result};
    $running->finish;
    $worker->unregister;
    $minion->reset( { all => 1 } );
};

subtest triage => sub {
    %state = ();
    answer( { scope => 'multi', reason => 'both need it', repos => [ { repo => 'Test-Org/two', order => 2, instructions => 'then two' }, { repo => 'Test-Org/one', order => 1, instructions => 'first one' } ] } );
    my $info = run_job( triage => \%item );
    is( $info->{state}, 'finished', 'triage finishes' ) or diag Mojo::Util::dumper $info->{result};
    my @children = map { $minion->job($_)->info } @{ $info->{result}{children} };
    is( [ map { $_->{task} } @children ],                [qw{spoke_fix spoke_fix report}],       'a multi fix is a spoke job per repo, then a report' );
    is( [ map { $_->{args}[0]{repo} // () } @children ], [qw{Test-Org/one Test-Org/two}],        'in the order triage gave' );
    is( $children[1]{parents},                           [ $children[0]{id} ],                   'each spoke waits for the one before it' );
    is( $children[2]{parents},                           [ map { $_->{id} } @children[ 0, 1 ] ], 'the report waits for them all' );
    ok( $children[2]{lax}, 'and runs even if one failed' );
    is( $info->{notes}{scope}, 'multi', 'the scope is noted for the page' );
    my $system = $app->clod_config->{system_prompts};
    $system->{triage} = 'Test with the provisioner.';
    $fake{FAKE_CLAUDE_RECORD} = "$tmp/triage-record";
    run_job( triage => \%item );
    is( record_of("$tmp/triage-record")->{flags}{'--append-system-prompt'}, ['Test with the provisioner.'], 'the system prompt of triage from the configuration reaches the run' );
    my $sent = Mojo::JSON::decode_json( record_of("$tmp/triage-record")->{flags}{'--json-schema'}[0] );
    is( $sent->{allOf}[0]{then}{properties}{repos}{items}{properties}{repo}{enum}, App::Clod::Tasks::spokes( $minion, $app->clod_config ), 'and claude is told which repositories are spokes, in the schema' );
    delete $fake{FAKE_CLAUDE_RECORD};
    delete $system->{triage};
    ok( -e $tmp->child(qw{workspace hub CLAUDE.md}), 'the hub workspace has its CLAUDE.md' );
    like( $tmp->child(qw{workspace hub CLAUDE.md})->slurp, qr/Test-Org\/two\ is\ a\ test\ spoke/, 'which describes each spoke from its own' );
    $minion->reset( { all => 1 } );

    answer( { scope => 'single', reason => 'r', repos => [ { repo => 'Not/aspoke', order => 1, instructions => 'x' } ] } );
    my $bad = run_job( triage => \%item );
    is( $bad->{state}, 'failed', 'an answer that names a repo that is not a spoke fails, after its retry' );
    like( $bad->{result}{error}, qr{/repos/0/repo:\ \S+\ Not\ in\ enum\ list:\ Test-Org/one}, 'and says why' );
    is( $bad->{result}{cost}, 1, 'and counts the cost of both tries' );

    my $broken = $tmp->child('triage-broken.jsonl');
    $broken->spew( '{"type":"result","is_error":true,"result":"something broke","total_cost_usd":0.5}' . "\n" );
    %fake = ( FAKE_CLAUDE_STREAM => "$broken", FAKE_CLAUDE_EXIT => 1 );
    my $failed = run_job( triage => \%item );
    is( $failed->{state}, 'failed', 'a triage run that fails, fails the job' );
    like( $failed->{result}{error}, qr/\Athe\ triage\ run\ failed:\ /, 'and says that the run failed' );
    is( $failed->{result}{cost}, 0.5, 'without a second run, which cannot mend a failed run' );

    answer( { scope => 'upstream', reason => 'theirs', repos => [], upstream => { project => 'Other/lib', path => 'lib/X.pm', explanation => 'X is broken there' } } );
    my $up = run_job( triage => \%item );
    is( $minion->job( $up->{result}{children}[0] )->info->{task}, 'kickback', 'an upstream answer is a kickback' );

    answer( { scope => 'clarify', reason => 'two readings', repos => [], question => { text => 'Which one?' } } );
    my $ask      = run_job( triage => \%item );
    my $kickback = $minion->job( $ask->{result}{children}[0] )->info;
    is( [ $kickback->{task}, scalar @{ $ask->{result}{children} } ], [ 'kickback', 1 ], 'a clarify answer is a kickback, and nothing else' );
    $minion->reset( { all => 1 } );
};

subtest spoke_fix => sub {
    %state = ();
    @calls = ();
    answer( { title => 'A title', summary => 'What changed.' }, commit => 1 );
    my $info = run_job( spoke_fix => { item => \%item, repo => 'Test-Org/one', instructions => 'do it' } );
    is( $info->{state}, 'finished', 'the fix finishes' ) or diag Mojo::Util::dumper $info->{result};
    like( $info->{result}, { repo => 'Test-Org/one', commits => 1, pr => 101, branch => qr{\Aclod/\d+-fix-the-thing\z} }, 'it reports the branch, the commit and the pull request' );
    ok( git( '--git-dir', $remote->child('Test-Org/one.git')->to_string, 'rev-parse', '--verify', $info->{result}{branch} ), 'the branch was pushed' );
    my $pull = calls_of('pull')->[0][2];
    is( [ @$pull{qw{title head base}} ], [ 'A title', $info->{result}{branch}, 'main' ], 'the pull request has the title, the branch and the base' );
    like( $pull->{body}, qr/What\ changed\..*issues\/7/s, 'and a body with the summary and the origin' );
    ok( !-e $tmp->child( "workspace", "work", $info->{id} ), "the worktree and its directory are gone afterwards" );

    my $mock = Test::MockModule->new('App::Clod::Spoke');
    $mock->redefine( remove_worktree => sub { die "git will not let go\n" } );
    answer( { title => 't', summary => 'Nothing to do here.' } );
    my $stuck;
    like( warning { $stuck = run_job( spoke_fix => { item => \%item, repo => 'Test-Org/one', instructions => 'x' } ) }, qr/could\ not\ remove .* git\ will\ not\ let\ go/, 'a worktree that git will not remove is reported' );
    $mock->unmock('remove_worktree');
    ok( !-e $tmp->child( 'workspace', 'work', $stuck->{id} ), 'and its directory is gone anyway' );
    my $mirror = App::Clod::Tasks::spoke( $app->clod_config, 'Test-Org/one' )->mirror->to_string;
    unlike( git( '--git-dir', $mirror, qw{worktree list --porcelain} ), qr{/work/$stuck->{id}/}, 'and the bare clone forgets it, so it holds no branch' );

    answer( { title => 't', summary => 'Nothing to do here.' } );
    my $none = run_job( spoke_fix => { item => \%item, repo => 'Test-Org/two', instructions => 'x' } );
    is( $none->{result}{no_change},   1, 'a run that commits nothing opens nothing' );
    is( scalar @{ calls_of('pull') }, 1, 'so no second pull request' );

    answer( { title => 't', summary => 's' }, commit => 1 );
    my $unnamed = run_job( spoke_fix => { item => { %item, title => '!!!' }, repo => 'Test-Org/one', instructions => 'x' } );
    is( $unnamed->{result}{branch}, "clod/$unnamed->{id}", 'a title that gives no slug names the branch by the job alone' ) or diag Mojo::Util::dumper $unnamed->{result};

    @calls         = ();
    $state{files}  = { CODEOWNERS => "lib/  \@lib-owner\n" };
    $state{assign} = { assignees  => [ { login => 'lib-owner' } ] };
    answer( { title => 't', summary => 's', question => 'Keep the old name?', path => 'lib/X.pm' } );
    my $ask = run_job( spoke_fix => { item => \%item, repo => 'Test-Org/one', instructions => 'x' } );
    like( $ask->{result}, { question => 'Keep the old name?', person => 'lib-owner', assigned => 1 }, 'a spoke that asks a question gives the issue to the owner of the path' );
    my $resume = qr/mention\ \@$BOT\ here\ or\ assign\ this\ to\ \@$BOT\ again/;
    my $asks   = qr/Test-Org\/one.*Keep\ the\ old\ name\?/s;
    like( calls_of('comment')->[0][2]{body}, qr/\A\@lib-owner:\ .*$asks.*$resume/s, 'and asks it there, with how to go on' );
    is( calls_of('unassign')->[0][2], { assignees => [$BOT] }, 'and the bot lets go of the issue' );
    is( scalar @{ calls_of('pull') }, 0,                       'and opens no pull request' );

    my $next = run_id( $minion->enqueue( spoke_fix => [ { item => \%item, repo => 'Test-Org/two', instructions => 'x' } ], { parents => [ $ask->{id} ] } ) );
    like( $next->{result}, { waiting => 1, summary => qr/Test-Org\/one/ }, 'a spoke after one that asked waits, and does not run' );
    my $after = run_id( $minion->enqueue( spoke_fix => [ { item => \%item, repo => 'Test-Org/two', instructions => 'x' } ], { parents => [ $next->{id} ] } ) );
    is( $after->{result}{waiting}, 1, 'and so does the one after that' );
    $minion->reset( { all => 1 } );

    $minion->lock( 'repo:Test-Org/one', 60 );
    my $locked = run_job( spoke_fix => { item => \%item, repo => 'Test-Org/one', instructions => 'x' } );
    is( $locked->{state}, 'inactive', 'a fix whose spoke another job holds goes back in the queue' );
    ok( $locked->{delayed} > time + 60, 'for later' );
    $minion->unlock('repo:Test-Org/one');
    $minion->reset( { all => 1 } );
};

subtest retry_after => sub {
    my $job = $minion->worker->register->dequeue( 0, { id => $minion->enqueue('reply') } );
    my @got = App::Clod::Tasks::retry_after( $job, 300 );
    $minion->worker->unregister;
    is( \@got, [], 'it returns nothing' );
    my $info = $job->info;
    is( $info->{retries}, 1, 'and retries the job' );
    ok( $info->{delayed} > time + 240 && $info->{delayed} <= time + 300, 'in that many seconds' ) or diag $info->{delayed} - time;
    $minion->reset( { all => 1 } );
};

subtest report => sub {
    %state = ();
    @calls = ();
    $minion->add_task( fake_spoke => sub ( $job, $r ) { $job->finish($r) } );
    my @parents = map { $minion->enqueue( fake_spoke => [$_] ) } { repo => 'Test-Org/one', pr => 1, pr_url => 'https://test.test/one/1' }, { repo => 'Test-Org/two', pr => 2, pr_url => 'https://test.test/two/2' };
    run_id($_) for @parents;
    my $info = run_id( $minion->enqueue( report => [ { item => \%item } ], { parents => \@parents } ) );
    is( $info->{result}{prs}, [ 'https://test.test/one/1', 'https://test.test/two/2' ], 'the report lists every pull request' );
    like( calls_of('comment')->[0][2]{body}, qr{one/1.*two/2}s, 'on the origin' );
    is( scalar @{ calls_of('update_pull') }, 2, 'and links each pull request to the others' );
    like( calls_of('update_pull')->[0][2]{body}, qr{\Aold\ body\n},                        'keeping the body it had' );
    like( calls_of('update_pull')->[0][2]{body}, qr{Merge\ together\ with:\n-\ \S+/two/2}, 'by adding the siblings to its body' );

    @calls = ();
    my @asked = map { $minion->enqueue( fake_spoke => [$_] ) } { repo => 'Test-Org/one', question => 'Which?' }, { repo => 'Test-Org/two', waiting => 1 };
    run_id($_) for @asked;
    my $quiet = run_id( $minion->enqueue( report => [ { item => \%item } ], { parents => \@asked } ) );
    is( [ $quiet->{result}{waiting}, scalar @{ calls_of('comment') } ], [ 1, 0 ], 'when a spoke asked and none opened a pull request, the question is the last word' );

    my @some = map { $minion->enqueue( fake_spoke => [$_] ) } { repo => 'Test-Org/one', pr => 1, pr_url => 'https://test.test/one/1' }, { repo => 'Test-Org/two', question => 'Which?' };
    run_id($_) for @some;
    run_id( $minion->enqueue( report => [ { item => \%item } ], { parents => \@some } ) );
    like( calls_of('comment')->[0][2]{body}, qr{one/1.*1\ of\ 2.*wait\ for\ the\ answer}s, 'otherwise the report says that the rest wait for the answer' );

    @calls = ();
    my $pr  = { %item, kind => 'address_review', is_pr => 1, number => 11 };
    my @own = map { $minion->enqueue( fake_spoke => [$_] ) } { repo => 'Test-Org/one', pr => 11, pr_url => 'https://test.test/one/11' };
    run_id($_) for @own;
    my $own = run_id( $minion->enqueue( report => [ { item => $pr } ], { parents => \@own } ) );
    is( [ $own->{result}{quiet}, scalar @{ calls_of('comment') } ], [ 1, 0 ], 'an answer on the bot\'s own pull request alone is not reported on it again' );

    my @wider = map { $minion->enqueue( fake_spoke => [$_] ) } { repo => 'Test-Org/one', pr => 11, pr_url => 'https://test.test/one/11' }, { repo => 'Test-Org/two', pr => 2, pr_url => 'https://test.test/two/2' };
    run_id($_) for @wider;
    run_id( $minion->enqueue( report => [ { item => $pr } ], { parents => \@wider } ) );
    like( calls_of('comment')->[0][2]{body}, qr{two/2}, 'but one that opened a pull request in another spoke is' );
    $minion->reset( { all => 1 } );
};

subtest kickback => sub {
    %state         = ();
    @calls         = ();
    $state{files}  = { '.github/CODEOWNERS' => "*  \@fallback\nlib/  \@lib-owner \@Test-Org/team\n" };
    $state{assign} = { assignees            => [ { login => 'lib-owner' } ] };
    my $triage = { scope => 'upstream', reason => 'not ours', upstream => { project => 'Other/lib', path => 'lib/X.pm', explanation => 'X is broken there' } };
    my $info   = run_job( kickback => { item => \%item, triage => $triage } );
    like( $info->{result}, { person => 'lib-owner', assigned => 1, teams => ['Test-Org/team'] }, 'the issue goes to the user who owns the path' );
    is( calls_of('assign')->[0][2],   { assignees => ['lib-owner'] }, 'it is assigned to them' );
    is( calls_of('unassign')->[0][2], { assignees => [$BOT] },        'and the bot lets go of it' );
    my $to = qr/\A\@lib-owner\ \@Test-Org\/team:\ /;
    like( calls_of('comment')->[0][2]{body}, qr/$to.*Other\/lib.*X\ is\ broken\ there/s, 'and says why, to them and to the team that owns the path' );
    my $clone   = qr/run\ claude\ yourself\ in\ a\ clone\ of\ Other\/lib,/;
    my $by_hand = qr/$clone\ with\ perl-slop:pull-requests/;
    my $tell    = qr/mention\ \@$BOT\ here\ with\ a\ link/;
    like( calls_of('comment')->[0][2]{body}, qr/$by_hand.*$tell/s, 'and how to fix it upstream by hand, then tell the bot' );

    @calls = ();
    $state{files} = {};
    my $ask = run_job( kickback => { item => \%item, triage => { scope => 'clarify', reason => 'two readings', question => { text => 'Which one do you mean?' } } } );
    like( $ask->{result}, { person => 'trusted', assigned => 0, question => 'Which one do you mean?' }, 'with no CODEOWNERS and an organization owner, a question goes back to the requester' );
    my $resume = qr/mention\ \@$BOT\ here\ or\ assign\ this\ to\ \@$BOT\ again/;
    like( calls_of('comment')->[0][2]{body}, qr/\A\@trusted:\ .*Which\ one\ do\ you\ mean\?.*$resume/s, 'it asks the question, and says how to go on' );

    @calls = ();
    $state{pull} = { user => { login => 'pr-author' } };
    is( run_job( kickback => { item => { %item, is_pr => 1 }, triage => { scope => 'clarify', reason => 'r', question => { text => 'Why?' } } } )->{result}{person}, 'pr-author', 'on a pull request, it goes to the author' );
    $state{pull} = { user => { login => $BOT } };
    is( run_job( kickback => { item => { %item, is_pr => 1 }, triage => { scope => 'clarify', reason => 'r', question => { text => 'Why?' } } } )->{result}{person}, 'trusted', 'or to the reviewer, when the bot is the author' );
    $minion->reset( { all => 1 } );
};

subtest spoke_review => sub {
    %state = ();
    @calls = ();
    answer( { event => 'COMMENT', body => 'Looks fine.', comments => [ { path => 'CLAUDE.md', line => 3, body => 'nit' } ] } );
    my $pr   = { %item, kind => 'review', is_pr => 1, number => 9 };
    my $head = git( '--git-dir', $remote->child('Test-Org/one.git')->to_string, 'rev-parse', 'main' );
    git( '--git-dir', $remote->child('Test-Org/one.git')->to_string, 'update-ref', 'refs/pull/9/head', $head );
    my $info = run_job( spoke_review => { item => $pr, repo => 'Test-Org/one', instructions => 'review it', related => ['Test-Org/two'] } );
    is( $info->{state},                       'finished',                                                             'the review finishes' ) or diag Mojo::Util::dumper $info->{result};
    is( calls_of('review')->[0][2]{comments}, [ { path => 'CLAUDE.md', line => 3, side => 'RIGHT', body => 'nit' } ], 'the line comments go with the review' );

    @calls = ();
    $state{refuse_comments} = 1;
    run_job( spoke_review => { item => $pr, repo => 'Test-Org/one', instructions => 'review it' } );
    my $reviews = calls_of('review');
    is( scalar @$reviews, 2, 'a review that GitHub refuses for its line comments is sent again' );
    like( $reviews->[1][2]{body}, qr/Looks\ fine\.\n\n`CLAUDE\.md:3`:\ nit/, 'with the comments in its body' );
    $minion->reset( { all => 1 } );
};

subtest spoke_address => sub {
    %state = ();
    @calls = ();
    my $bare = $remote->child('Test-Org/one.git')->to_string;
    git( q{--git-dir}, $bare, qw{branch clod/1-ours main} );
    $state{pull}            = { user => { login => $BOT }, head => { ref => 'clod/1-ours', repo => { full_name => 'Test-Org/one' } }, html_url => 'https://test.test/pull/11' };
    $state{review_comments} = [ { id => 21, user => { login => 'trusted' }, path => 'CLAUDE.md', line => 1, body => 'rename this' } ];
    answer( { summary => 'Renamed.', replies => [ { id => 21, body => 'Done.' }, { id => 99, body => 'not a thread' } ] }, commit => 1 );
    my $pr   = { %item, kind => 'address_review', is_pr => 1, number => 11 };
    my $info = run_job( spoke_address => { item => $pr, repo => 'Test-Org/one', instructions => 'answer them' } );
    is( $info->{state},           'finished', 'the answer to the review finishes' ) or diag Mojo::Util::dumper $info->{result};
    is( $info->{result}{commits}, 1,          'the fix is committed' );
    isnt( git( '--git-dir', $bare, 'rev-parse', 'clod/1-ours' ), git( '--git-dir', $bare, 'rev-parse', 'main' ), 'and pushed to the pull request branch' );
    is( [ map { $_->[1] } @{ calls_of('reply') } ], ['/repos/Test-Org/one/pulls/11/comments/21/replies'], 'only the open thread gets a reply' );

    @calls                  = ();
    $state{review_comments} = [];
    $state{issue_comments}  = [ { id => 31, user => { login => 'trusted' }, body => 'Mojo is already a dependency of a dependency.' } ];
    answer( { summary => 'Nothing to change.', replies => [], comment => 'Then there is no need for this change.' } );
    $fake{FAKE_CLAUDE_RECORD} = "$tmp/address-record";
    my $plain = run_job( spoke_address => { item => $pr, repo => 'Test-Org/one' } );
    my ( undef, $told ) = split /\0/, Mojo::File->new("$tmp/address-record")->slurp;
    my $history = qr/\#\ The\ issue .* Mojo\ is\ already/;
    like( $told, qr/$history .* "comments":\[\{"body":"Mojo/, 'the run gets the whole conversation, and the comment to answer' );
    is( $plain->{state},                                    'finished',                                 'a plain comment on the pull request is answered' ) or diag Mojo::Util::dumper $plain->{result};
    is( [ map { $_->[2]{body} } @{ calls_of('comment') } ], ['Then there is no need for this change.'], 'with a comment on the pull request' );

    $state{issue_comments} = [ @{ $state{issue_comments} }, { id => 32, user => { login => $BOT }, body => 'Then there is no need for this change.' } ];
    is( run_job( spoke_address => { item => $pr, repo => 'Test-Org/one' } )->{result}{nothing}, 1, 'a comment that the bot answered is not answered again' );
    delete $state{issue_comments};

    @calls                 = ();
    $state{issue_comments} = [];
    $state{reviews}        = [ { id => 41, user => { login => 'trusted' }, body => 'Rename it throughout.', state => 'CHANGES_REQUESTED', submitted_at => '2026-11-01T11:00:00Z' } ];
    answer( { summary => 'Renamed.', replies => [], comment => 'Renamed it throughout.' } );
    $fake{FAKE_CLAUDE_RECORD} = "$tmp/address-record";
    my $reviewed = run_job( spoke_address => { item => $pr, repo => 'Test-Org/one' } );
    my ( undef, $asked ) = split /\0/, Mojo::File->new("$tmp/address-record")->slurp;
    is( $reviewed->{result}{nothing}, undef, 'a review with a body and no line comments is answered' ) or diag Mojo::Util::dumper $reviewed->{result};
    my $entry = Mojo::JSON::encode_json( [ { body => 'Rename it throughout.', by => 'trusted', id => 41, review => 1 } ] );
    ok( index( $asked, qq{"comments":$entry} ) >= 0, 'the run gets its body as a comment to answer' ) or diag $asked;
    is( [ map { $_->[2]{body} } @{ calls_of('comment') } ], ['Renamed it throughout.'], 'and answers it with a comment' );
    delete @state{qw{issue_comments reviews}};

    $state{pull} = { %{ $state{pull} }, user => { login => 'someone' } };
    is( run_job( spoke_address => { item => $pr, repo => 'Test-Org/one' } )->{state}, 'failed', 'a pull request that is not the bot\'s own is refused' );
    $minion->reset( { all => 1 } );
};

subtest claude => sub {
    my $config = Clone::clone( $app->clod_config );
    is( App::Clod::Tasks::claude($config)->run_as, undef, 'claude runs as the worker unless the configuration says otherwise' );
    $config->{claude}{run_as} = 'test-agent';
    is( App::Clod::Tasks::claude($config)->run_as, 'test-agent', 'and as the account of run_as when it does' );
};

subtest 'tool spokes and the spoke prompt' => sub {
    %state = ();
    @calls = ();
    my $config = $app->clod_config;
    $config->{spoke_prompt}              = 'Test on a guest.';
    $config->{tool_spokes}               = ['Test-Org/two'];
    $config->{claude}{extra_tools}       = ['Bash(bin/provision:*)'];
    $config->{system_prompts}{spoke_fix} = 'Fix with care.';
    my $tools = $remote->child('Test-Org/two.git')->to_string;
    my $main  = git( '--git-dir', $tools, 'rev-parse', 'main' );
    my ( $record_file, $heads ) = ( "$tmp/tool-record", "$tmp/tool-heads" );
    my $head_of = sub () {
        return { map { split /\t/ } split /\n/, Mojo::File->new($heads)->slurp };
    };

    answer( { title => 't', summary => 'Tested on a guest.' }, commit => 1 );
    @fake{qw{FAKE_CLAUDE_RECORD FAKE_CLAUDE_HEADS}} = ( $record_file, $heads );
    my $fix  = run_job( spoke_fix => { item => \%item, repo => 'Test-Org/one', instructions => 'do it' } );
    my $told = record_of($record_file);
    my $dir  = $tmp->child( 'workspace', 'work', $fix->{id}, 'Test-Org', 'two' )->to_string;
    is( $fix->{state},                            'finished',                             'a fix with a tool spoke finishes' ) or diag Mojo::Util::dumper $fix->{result};
    is( $told->{flags}{'--append-system-prompt'}, ["Test on a guest.\n\nFix with care."], 'a spoke run is told the spoke prompt, then the system prompt of its task' );
    is( $told->{flags}{'--add-dir'},              [$dir],                                 'it gets a worktree of the tool spoke of its own' );
    like( $told->{prompt}, qr/-\ Test-Org\/two\ in\ \Q$dir\E,\ at\ main\n/, 'and its prompt says where, at which branch' );
    is( $head_of->(), { $dir => $main }, 'with no earlier job in the tool spoke, the worktree is at its default branch' );
    like( $told->{flags}{'--allowedTools'}[0], qr/,Bash\(bin\/provision:\*\)\z/, 'and the extra tools are allowed, after the configured ones' );
    ok( !-e $tmp->child( 'workspace', 'work', $fix->{id} ), 'every worktree of the run is gone afterwards' );
    is( [ grep { m{/work/} } split /\n/, git( '--git-dir', $tools, 'worktree', 'list' ) ], [], 'and the bare clone of the tool spoke has no worktree left' );

    # A recipe that an earlier spoke of the same change pushed, two jobs back.
    my $seed = $tmp->child( 'seed', 'Test-Org/two' );
    git( q{-C}, "$seed", qw{checkout --quiet -b clod/1-recipe} );
    git( q{-C}, "$seed", qw{-c user.name=t -c user.email=t@test.test commit --quiet --allow-empty -m recipe} );
    git( q{-C}, "$seed", 'push', '--quiet', $tools, 'clod/1-recipe' );
    git( q{-C}, "$seed", qw{checkout --quiet main} );
    my $recipe = git( '--git-dir', $tools, 'rev-parse', 'clod/1-recipe' );
    $minion->add_task( fake_spoke => sub ( $job, $r ) { $job->finish($r) } );
    my $first = $minion->enqueue( fake_spoke => [ { repo => 'Test-Org/two', branch => 'clod/1-recipe', pr_url => 'https://test.test/two/1' } ] );
    run_id($first);
    my $between = $minion->enqueue( fake_spoke => [ { repo => 'Test-Org/one', no_change => 1, summary => 'Nothing to do here.' } ], { parents => [$first] } );
    run_id($between);
    answer( { title => 't', summary => 's' } );
    @fake{qw{FAKE_CLAUDE_RECORD FAKE_CLAUDE_HEADS}} = ( $record_file, $heads );
    my $after = run_id( $minion->enqueue( spoke_fix => [ { item => \%item, repo => 'Test-Org/one', instructions => 'x' } ], { parents => [$between] } ) );
    my $later = $tmp->child( 'workspace', 'work', $after->{id}, 'Test-Org', 'two' )->to_string;
    is( $after->{state}, 'finished',            'a fix after an earlier spoke that changed nothing finishes' ) or diag Mojo::Util::dumper $after->{result};
    is( $head_of->(),    { $later => $recipe }, 'a tool worktree is at the branch of the nearest earlier job that changed the tool spoke' );
    like( record_of($record_file)->{prompt}, qr/at\ clod\/1-recipe\n/, 'and the prompt names that branch' );

    answer( { title => 't', summary => 's' } );
    @fake{qw{FAKE_CLAUDE_RECORD FAKE_CLAUDE_EXIT}} = ( $record_file, 1 );
    my $failed = run_job( spoke_fix => { item => \%item, repo => 'Test-Org/one', instructions => 'x' } );
    is( $failed->{state},                              'failed',                                                                            'a run that fails fails the job' );
    is( record_of($record_file)->{flags}{'--add-dir'}, [ $tmp->child( 'workspace', 'work', $failed->{id}, 'Test-Org', 'two' )->to_string ], 'after it had a tool worktree' );
    ok( !-e $tmp->child( 'workspace', 'work', $failed->{id} ), 'which is gone after the failure too' );

    answer( { title => 't', summary => 's' }, commit => 1 );
    $state{refuse_pull} = 1;
    my $died = run_job( spoke_fix => { item => \%item, repo => 'Test-Org/one', instructions => 'x' } );
    like( [ $died->{state}, $died->{result} ], [ 'failed', qr/500/ ], 'a job that dies after the run fails' );
    ok( !-e $tmp->child( 'workspace', 'work', $died->{id} ), 'and its tool worktree is gone too' );
    delete $state{refuse_pull};

    answer( { title => 't', summary => 's' } );
    $fake{FAKE_CLAUDE_RECORD} = $record_file;
    run_job( spoke_fix => { item => \%item, repo => 'Test-Org/two', instructions => 'x' } );
    is( record_of($record_file)->{flags}{'--add-dir'}, undef, 'a run in the tool spoke itself gets no second copy of it' );

    answer( { event => 'COMMENT', body => 'Fine.', comments => [] } );
    $fake{FAKE_CLAUDE_RECORD} = $record_file;
    my $review = run_job( spoke_review => { item => { %item, kind => 'review', is_pr => 1, number => 9 }, repo => 'Test-Org/one', instructions => 'x' } );
    my $read   = record_of($record_file);
    is( $read->{flags}{'--append-system-prompt'}, ['Test on a guest.'],                                                                'a review is told the spoke prompt, and not the system prompt of another task' );
    is( $read->{flags}{'--add-dir'},              [ $tmp->child( 'workspace', 'work', $review->{id}, 'Test-Org', 'two' )->to_string ], 'and gets a tool worktree too' );
    unlike( $read->{flags}{'--allowedTools'}[0], qr/provision/, 'but not the extra tools, because it only reads' );

    answer( { scope => 'single', reason => 'r', repos => [ { repo => 'Test-Org/one', order => 1, instructions => 'x' } ] } );
    $fake{FAKE_CLAUDE_RECORD} = $record_file;
    run_job( triage => \%item );
    my $triage = record_of($record_file);
    like( $triage->{prompt}, qr/<<<SPOKE_PROMPT\nTest\ on\ a\ guest\.\nSPOKE_PROMPT>>>/, 'triage is told what each spoke run is told' );
    like( $triage->{prompt}, qr/tools:\ Test-Org\/two\./,                                'and which the tool spokes are' );
    unlike( $triage->{flags}{'--allowedTools'}[0], qr/provision/, 'and is not allowed the extra tools' );
    is( $triage->{flags}{'--append-system-prompt'}, undef, 'nor told the spoke prompt as its own' );

    delete $config->{spoke_prompt};
    answer( { scope => 'single', reason => 'r', repos => [ { repo => 'Test-Org/one', order => 1, instructions => 'x' } ] } );
    $fake{FAKE_CLAUDE_RECORD} = $record_file;
    run_job( triage => \%item );
    my $alone = record_of($record_file)->{prompt};
    unlike( $alone, qr/SPOKE_PROMPT/, 'without a spoke prompt, triage is told none' );
    like( $alone, qr/tools:\ Test-Org\/two\./, 'but it is still told which the tool spokes are' );
    $config->{tool_spokes} = [];
    run_job( triage => \%item );
    unlike( record_of($record_file)->{prompt}, qr/SPOKE_PROMPT|tool\ spokes/, 'without either, triage has no such section' );
    delete $config->{system_prompts}{spoke_fix};
    $config->{claude}{extra_tools} = [];
    $minion->reset( { all => 1 } );
};

subtest reply => sub {
    %state = ();
    @calls = ();
    answer( { action => 'reply', body => 'It works like this.' } );
    my $info = run_job( reply => { %item, kind => 'reply' } );
    is( calls_of('comment')->[0][2]{body}, 'It works like this.', 'a reply is posted as a comment' );
    ok( !$info->{result}{triage_job}, 'and starts nothing else' );

    answer( { action => 'fix', body => 'I will fix it.' } );
    my $fix    = run_job( reply => { %item, kind => 'reply' } );
    my $triage = $minion->job( $fix->{result}{triage_job} )->info;
    is( [ $triage->{task}, $triage->{args}[0]{kind} ], [ 'triage', 'fix' ], 'a request for a change starts triage for a fix' );
    $minion->reset( { all => 1 } );
};

subtest 'the quota' => sub {
    App::Clod::Budget::pause( $minion, time + 600 );
    my $info = run_job( reply => { %item, kind => 'reply' } );
    is( $info->{state}, 'inactive', 'a job that needs Claude while the quota is out goes back in the queue' );
    ok( $info->{delayed} > time + 60, 'for later' );
    $minion->unlock($App::Clod::Budget::LOCK);
    $minion->reset( { all => 1 } );

    my $stream = $tmp->child('limited.jsonl');
    $stream->spew( join "\n", '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":' . ( time + 900 ) . '}}', '{"type":"result","is_error":true,"result":"usage limit reached"}', q{} );
    %fake = ( FAKE_CLAUDE_STREAM => "$stream" );
    my $limited = run_job( reply => { %item, kind => 'reply' } );
    is( $limited->{state}, 'inactive', 'a run that hits the limit retries' );
    ok( App::Clod::Budget::paused($minion), 'and pauses the rest' );
    $minion->unlock($App::Clod::Budget::LOCK);
    $minion->reset( { all => 1 } );
};

subtest 'an outage' => sub {
    %state = ( files => { '.claude-plugin/plugin.json' => '{"version":"0.11.0"}', '.claude-plugin/marketplace.json' => '{"plugins":[{"name":"perl-slop","version":"0.11.0"}]}' } );
    my $before = run_job('harness_scan')->{result};
    ok( $before->{repos}, 'a scan before the outage' ) or diag Mojo::Util::dumper $before;
    %state = ( bad_token => 1 );
    @calls = ();
    my $poll = run_job('inbox_poll');
    is( $poll->{state},        'finished', 'a poll whose token GitHub refuses does not fail' ) or diag Mojo::Util::dumper $poll->{result};
    is( $poll->{result}{held}, 1,          'it is held' );
    like( $poll->{notes}{outage}, { service => 'github', error => qr/401\ Bad\ credentials/ }, 'and notes why' );
    is( App::Clod::Outage::holding( $minion, 'triage' ), 'github', 'so a GitHub outage starts' );

    %state = ();
    my $triage = run_job( triage => \%item );
    is( $triage->{state}, 'inactive', 'during it, a job that does work goes back in the queue' );
    ok( $triage->{delayed} > time + 60, 'for later' );
    is( \@calls, [], 'without a call to GitHub' );
    ok( !$triage->{notes}{progress}, 'and without a claude run' );
    my $scan = run_job('harness_scan');
    is( $scan->{result}, { %$before, held => 1 }, 'and a scheduled job finishes at once, with the last result it had' );

    $minion->unlock( App::Clod::Outage::lock_name('github') );
    my $stream = $tmp->child('refused.jsonl');
    $stream->spew( '{"type":"result","is_error":true,"api_error_status":401,"result":"Failed to authenticate. API Error: 401 Invalid bearer token"}' . "\n" );
    %fake = ( FAKE_CLAUDE_STREAM => "$stream" );
    my $reply = run_job( reply => { %item, kind => 'reply' } );
    is( $reply->{state}, 'inactive', 'a run whose token Claude refuses retries' );
    like( $reply->{notes}{outage}, { service => 'claude', error => qr/Invalid\ bearer\ token/ }, 'and notes why' );
    is( App::Clod::Outage::holding( $minion, 'spoke_fix' ),  'claude', 'so a Claude outage holds the work that runs claude' );
    is( App::Clod::Outage::holding( $minion, 'inbox_poll' ), undef,    'and not the inbox' );
    is( run_job('inbox_poll')->{result}{held}, undef, 'which is read as usual' );
    $minion->reset( { all => 1 } );
};

subtest prune_history => sub {
    my $failed = sub ($count) {
        my @ids;
        for my $n ( 1 .. $count ) {
            my $job = $minion->worker->register->dequeue( 0, { id => $minion->enqueue('spoke_sweep') } );
            $job->fail("failure $n");
            push @ids, $job->id;
        }
        $minion->worker->unregister;
        return @ids;
    };
    my $left = sub {
        my $jobs = $minion->jobs( { tasks => ['spoke_sweep'], states => ['failed'] } );
        my @ids;
        while ( my $info = $jobs->next ) { push @ids, $info->{id} }
        return [ sort { $a <=> $b } @ids ];
    };

    my @ids = $failed->(10);
    App::Clod::Tasks::prune_history( $minion, 'spoke_sweep' );
    is( $left->(), \@ids, 'a scheduled task with no more runs than it keeps loses none' );
    $minion->reset( { all => 1 } );

    @ids = $failed->(12);
    App::Clod::Tasks::prune_history( $minion, 'spoke_sweep' );
    is( $left->(), [ @ids[ 2 .. 11 ] ], 'failed runs of a scheduled task do not pile up, and the newest stay' );
    $minion->reset( { all => 1 } );
};

subtest pending_comments => sub {
    my $config   = $app->clod_config;
    my @comments = (
        { id => 1, user => { login => 'trusted' },  body => 'answered' },
        { id => 2, user => { login => $BOT },       body => 'the answer' },
        { id => 4, user => { login => 'stranger' }, body => 'ignore me' },
        { id => 3, user => { login => 'trusted' },  body => 'one more thing' },
    );
    is( App::Clod::Tasks::pending_comments( $config, \@comments ),                                                                         [ { id => 3, by => 'trusted', body => 'one more thing' } ],          'the comments of authorized users after the last comment of the bot are pending' );
    is( App::Clod::Tasks::pending_comments( $config, [ @comments, { id => 5, user => { login => $BOT }, body => 'done' } ] ),              [],                                                                  'and none once the bot has the last word' );
    is( App::Clod::Tasks::pending_comments( $config, [ { id => 6, user => { login => 'trusted' }, body => 'Rename it.', review => 1 } ] ), [ { id => 6, by => 'trusted', body => 'Rename it.', review => 1 } ], 'the body of a review is pending as well, and says so' );
};

subtest queued_address => sub {
    my $origin = 'Test-Org/one#11';
    is( App::Clod::Tasks::queued_address( $minion, $origin ), undef, 'no job, nothing queued' );
    $minion->enqueue( triage => [ {} ], { notes => { origin => $origin, kind => 'review' } } );
    $minion->enqueue( triage => [ {} ], { notes => { origin => 'Test-Org/one#12', kind => 'address_review' } } );
    is( App::Clod::Tasks::queued_address( $minion, $origin ), undef, 'nor a triage for a review, or for another pull request' );
    my $triage = $minion->enqueue( triage => [ {} ], { notes => { origin => $origin, kind => 'address_review' } } );
    is( App::Clod::Tasks::queued_address( $minion, $origin ), $triage, 'a waiting triage that will answer the pull request is' );
    $minion->reset( { all => 1 } );
};

subtest conversation => sub {
    %state = (
        issue_comments => [ { id => 31, user => { login => 'trusted' }, body => 'first',  created_at   => '2026-11-01T10:00:00Z' }, { id => 32, user => { login => 'trusted' }, body => 'third', created_at => '2026-11-01T12:00:00Z' } ],
        reviews        => [ { id => 41, user => { login => 'trusted' }, body => 'second', submitted_at => '2026-11-01T11:00:00Z', state => 'CHANGES_REQUESTED' }, { id => 42, user => { login => 'trusted' }, body => q{}, submitted_at => '2026-11-01T11:30:00Z', state => 'COMMENTED' } ],
    );
    my $gh   = App::Clod::Tasks::github( $app->clod_config );
    my $said = App::Clod::Tasks::conversation( $gh, { %item, is_pr => 1, number => 11 } );
    is( [ map { $_->{body} } @$said ],                                             [qw{first second third}], 'on a pull request, the review bodies are among the comments, in the order they were made, and an empty one is left out' );
    is( $said->[1]{review},                                                        1,                        'and a review body says so' );
    is( [ map { $_->{body} } @{ App::Clod::Tasks::conversation( $gh, \%item ) } ], [qw{first third}],        'an issue has no reviews to read' );
    my $first  = qr/\#\#\ comment\ by\ trusted\n\nfirst/;
    my $second = qr/\#\#\ review\ by\ trusted\n\nsecond/;
    like( App::Clod::Tasks::context( $app->clod_config, $gh, { %item, is_pr => 1, number => 11 } ), qr/$first.*$second.*third/s, 'and the context of a pull request shows the review where it came' );
    %state = ();
};

subtest pending_threads => sub {
    %state = ();
    my $config   = $app->clod_config;
    my @comments = (
        { id => 1, user => { login => 'trusted' },  path           => 'a', line => 1, body => 'fix this' },
        { id => 2, user => { login => $BOT },       in_reply_to_id => 1,   body => 'done' },
        { id => 3, user => { login => 'trusted' },  path           => 'b', line => 2, body => 'and this' },
        { id => 4, user => { login => 'stranger' }, path           => 'c', line => 3, body => 'ignore me' },
        { id => 5, user => { login => 'trusted' },  path           => 'a', line => 1, in_reply_to_id => 1, body => 'not quite' },
    );
    my $pending = App::Clod::Tasks::pending_threads( $config, \@comments );
    is( [ map { $_->{id} } @$pending ], [ 1, 3 ], 'a thread is pending when an authorized user has the last word' );
    is( [ map { $_->{by} } @{ $pending->[0]{messages} } ], [ 'trusted', $BOT, 'trusted' ], 'with its whole history' );
};

subtest harness_scan => sub {
    %state = ();
    $state{files} = { 'CLAUDE.md' => 'perl-slop:reading-perl', '.claude-plugin/plugin.json' => '{"version":"0.11.0"}', '.claude-plugin/marketplace.json' => '{"plugins":[{"name":"perl-slop","version":"0.10.0"}]}' };
    my $info = run_job('harness_scan');
    is( [ sort keys %{ $info->{result}{repos} } ], \@SPOKES,                                         'every spoke is scanned' );
    is( $info->{result}{marketplace}{status},      'fail',                                           'and the marketplace pin is checked' );
    is( $info->{result}{checks},                   [qw{ClaudeMd ClaudeSettings GitHooks workflows}], 'the result names the checks of every spoke, for the page' );
    my $one = $info->{result}{repos}{'Test-Org/one'};
    is( [ @{$one}{qw{flavor chosen}} ],                                          [ 'test-default', 0 ], 'a spoke without .conformance.yml gets the flavor of the configuration' );
    is( { map { $_->{check} => $_->{status} } @{ $one->{checks} } }->{ClaudeMd}, 'pass',                'and is checked against it' );

    $state{files}{'.conformance.yml'} = "flavor: test-chosen\nsource:\n  directory: " . $here->child( 'data', 'standards' ) . "\n";
    my $chosen = run_job('harness_scan')->{result};
    is( $chosen->{checks},                        [qw{ClaudeMd ToolConfiguration workflows}], 'a spoke that names its flavor is checked against that one' );
    is( $chosen->{repos}{'Test-Org/one'}{chosen}, 1,                                          'which it chose' );

    $state{files}{'.conformance.yml'} = "flavor: test-gone\nsource:\n  directory: " . $here->child( 'data', 'standards' ) . "\n";
    like( run_job('harness_scan')->{result}{errors}{'Test-Org/one'}, qr/test-gone/, 'and one whose flavor cannot be read is an error of the scan' );
};

subtest assigned_sweep => sub {
    %state = ();
    my $info = run_job('assigned_sweep');
    is( scalar @{ $info->{result}{issues} }, 2,              'the assigned issues of each spoke are listed' );
    is( $info->{result}{issues}[0]{repo},    'Test-Org/one', 'with their repo' );
};

subtest spoke_sweep => sub {
    %state = ();
    my $config = $app->clod_config;
    is( App::Clod::Tasks::spokes( $minion, $config ), \@SPOKES, 'without spoke_orgs, the spokes are the configured ones' );

    $config->{spoke_orgs} = ['Test-Org'];
    my $info = run_job('spoke_sweep');
    is( $info->{result}{repos},                       [qw{Test-Org/new Test-Org/one}],              'the sweep lists the public repositories, without forks and archived ones' );
    is( App::Clod::Tasks::spokes( $minion, $config ), [qw{Test-Org/new Test-Org/one Test-Org/two}], 'and they join the configured spokes, each once' );
    ok( App::Clod::Tasks::is_spoke( $minion, $config, 'Test-Org/new' ), 'so a new repository is a spoke at once' );

    $state{org_missing} = 1;
    my $failed = run_job('spoke_sweep');
    like( $failed->{result}{errors}{'Test-Org'}, qr/404/, 'a listing that fails is recorded' );
    is( $failed->{result}{repos}, [qw{Test-Org/new Test-Org/one}], 'and the repositories of the sweep before stay spokes' );
    delete $config->{spoke_orgs};
    $minion->reset( { all => 1 } );
};

subtest 'inbox_poll before the first spoke_sweep' => sub {
    %state = ();
    @calls = ();
    my $config = $app->clod_config;
    my $spokes = $config->{spokes};
    $config->{spokes}     = [];
    $config->{spoke_orgs} = ['Test-Org'];
    $state{threads}       = [ { id => 1, reason => 'assign', updated_at => 't1', repository => { full_name => 'Test-Org/one' }, subject => { type => 'Issue', url => "$api/repos/Test-Org/one/issues/7" } } ];
    $state{events}        = [ { event => 'assigned', assignee => { login => $BOT }, actor => { login => 'trusted' } } ];
    my $sweeps = sub { $minion->jobs( { tasks => ['spoke_sweep'], states => ['inactive'] } )->total };

    my $first = run_job('inbox_poll');
    is( $state{inbox_reads}, undef, 'with no spoke known, the poll does not read the inbox' );
    is( calls_of('read'),    [],    'so it marks no thread read' );
    ok( $first->{result}{no_spokes_since}, 'and says since when it has waited' ) or diag Mojo::Util::dumper $first->{result};
    is( $sweeps->(), 1, 'and queues a sweep, rather than wait for the next quarter hour' );

    my $second = run_job('inbox_poll');
    is( $second->{result}{no_spokes_since}, $first->{result}{no_spokes_since}, 'a second poll keeps the time that the wait began' );
    is( $sweeps->(),                        1,                                 'and queues no second sweep while one waits' );

    run_id( $minion->jobs( { tasks => ['spoke_sweep'], states => ['inactive'] } )->next->{id} );
    my $after = run_job('inbox_poll');
    is( $state{inbox_reads},                  1, 'once the sweep finished, the poll reads the inbox' );
    is( scalar @{ $after->{result}{queued} }, 1, 'and the thread that waited becomes work' ) or diag Mojo::Util::dumper $after->{result};
    ok( !exists $after->{result}{no_spokes_since}, 'and the wait is over' );
    $config->{spokes} = $spokes;
    delete $config->{spoke_orgs};
    $minion->reset( { all => 1 } );
};

subtest create_repo => sub {
    %state = ();
    @calls = ();
    my $config = $app->clod_config;
    $config->{spoke_orgs}   = ['Test-Org'];
    $config->{create_repos} = 1;
    $state{absent}          = { 'Test-Org/Fresh-Dist' => 1 };
    $state{issue_comments}  = [ { id => 1, user => { login => 'trusted' }, body => "Please make a new repository\nfor this one." } ];
    my $new  = { org => 'Test-Org', name => 'Fresh-Dist', description => 'A fresh distribution.', asked_by => 'trusted', quote => 'Please make a new repository for this one.' };
    my %plan = ( scope => 'multi', reason => 'asked for', repos => [ { repo => 'Test-Org/one', order => 1, instructions => 'first' }, { repo => 'Test-Org/Fresh-Dist', order => 2, instructions => 'fill it' } ], new_repos => [$new] );

    answer( {%plan} );
    $fake{FAKE_CLAUDE_RECORD} = "$tmp/create-record";
    my $triage = run_job( triage => \%item );
    is( $triage->{state}, 'finished', 'a triage that asks for a repository that a trusted user asked for finishes' ) or diag Mojo::Util::dumper $triage->{result};
    my $where = qr/in\ one\ of\ these\ organizations:\ Test-Org,/;
    like( record_of("$tmp/create-record")->{prompt}, qr/$where\nand\ one\ at\ most\ for\ this\ request/, 'triage is told where it may ask for one, and that it is one' );
    my @children = map { $minion->job($_)->info } @{ $triage->{result}{children} };
    is( [ map { $_->{task} } @children ], [qw{create_repo spoke_fix spoke_fix report}], 'the repository is made first, then each spoke works, then the report' );
    is( $children[1]{parents},            [ $children[0]{id} ],                         'the first spoke waits for the new repository' );
    is( $children[2]{args}[0]{created},   1,                                            'and the run in the new one is told that it is new' );
    is( calls_of('create'),               [],                                           'triage itself makes nothing' );
    ok( !App::Clod::Tasks::is_spoke( $minion, $config, 'Test-Org/Fresh-Dist' ), 'before it is made, it is not a spoke' );

    my $made = run_id( $children[0]{id} );
    is( $made->{state},                                      'finished',                                                                                                              'the hub makes the repository' ) or diag Mojo::Util::dumper $made->{result};
    is( [ map { [ @$_[ 0, 1 ] ] } @{ calls_of('create') } ], [ [ 'create', '/orgs/Test-Org/repos' ] ],                                                                                'once, in the organization' );
    is( calls_of('create')->[0][2],                          { name => 'Fresh-Dist', description => 'A fresh distribution.', visibility => 'public', auto_init => Mojo::JSON::true }, 'public, so that the sweep finds it, and with a first commit, so that it has a branch to work from' );
    my $issues = calls_of('issue');
    my $yours  = qr/first\ release\ of\ Fresh::Dist\ is\ yours/;
    my $fresh  = qr{https://test\.test/Test-Org/Fresh-Dist};
    my $named  = qr{repository\ Test-Org/Fresh-Dist\ for\ this:\ $fresh};
    is( [ map { $_->[1] } @$issues ], ['/repos/Test-Org/Fresh-Dist/issues'], 'it opens one issue in the new repository' );
    like( $issues->[0][2],          { title => 'Release Fresh::Dist', assignees => ['trusted'], body => qr/\A\@trusted:\ .*Test-Org\/one\/issues\/7.*$yours/s }, 'to release the module that its name gives, assigned to the person who asked' );
    like( calls_of('comment')->[0], [ 'comment', '/repos/Test-Org/one/issues/7/comments', { body => qr{$named.*/issues/1}s } ],                                  'and says on the origin what it made' );
    is( $minion->jobs( { tasks => ['spoke_sweep'] } )->total, 0, 'with no sweep' );
    ok( App::Clod::Tasks::is_spoke( $minion, $config, 'Test-Org/Fresh-Dist' ), 'the new repository is a spoke at once' );

    answer( { title => 'One', summary => 'Done in one.' }, commit => 1 );
    is( run_id( $children[1]{id} )->{state}, 'finished', 'the spoke before it works' );
    answer( { title => 'Fresh', summary => 'Filled it.' }, commit => 1 );
    $fake{FAKE_CLAUDE_RECORD} = "$tmp/create-record";
    my $fix = run_id( $children[2]{id} );
    is( $fix->{state}, 'finished', 'and so does the run in the new repository' ) or diag Mojo::Util::dumper $fix->{result};
    like( record_of("$tmp/create-record")->{prompt}, qr/Test-Org\/Fresh-Dist\ is\ new:\ the\ hub\ made\ it/, 'which is told that it is new' );
    is( calls_of('pull')->[-1][1], '/repos/Test-Org/Fresh-Dist/pulls', 'and the hub opens its pull request there' );

    @calls = ();
    $state{absent}{'Test-Org/Second'} = 1;
    my %left = App::Clod::Tasks::creation( $minion, $config, \%item );
    is( $left{orgs}, undef, 'once the origin has made one, triage may ask for no more' );
    my $second = qr{Test-Org/Second};
    my $one    = qr/one\ per\ request/;
    my $capped = run_job( create_repo => { item => \%item, org => 'Test-Org', name => 'Second', description => 'd', asked_by => 'trusted' } );
    like( $capped->{result}, { refused => qr/made\ a\ repository\ already,\ and\ I\ make\ $one/, question => T() }, 'and the hub refuses one more for the same origin' );
    is( calls_of('create'), [], 'so it makes nothing' );
    like( calls_of('comment')->[0][2]{body}, qr/\A\@trusted:\ I\ did\ not\ make\ the\ repository\ $second/, 'and gives the origin back with the reason' );

    @calls = ();
    my $other = { %item, number => 8 };
    $state{absent}{'Other-Org/Fresh'} = 1;
    like( run_job( create_repo => { item => $other, org => 'Other-Org', name => 'Fresh', description => 'd', asked_by => 'trusted' } )->{result}, { refused => qr/does\ not\ let\ me\ make\ repositories\ in\ Other-Org/ }, 'the hub refuses an organization that is not in spoke_orgs' );
    like( run_job( create_repo => { item => $other, org => 'Test-Org',  name => 'two',   description => 'd', asked_by => 'trusted' } )->{result}, { refused => qr/Test-Org\/two\ exists\ already/ },                        'and a name that exists' );
    like( run_job( create_repo => { item => $other, org => 'Test-Org',  name => 'x.git', description => 'd', asked_by => 'trusted' } )->{result}, { refused => qr/does\ not\ fit\ the\ rule/ },                             'and a name that does not fit the rule' );
    $state{absent}{'Test-Org/Hidden'} = 1;
    my $private = run_job( create_repo => { item => $other, org => 'Test-Org', name => 'Hidden', description => 'd', private => 1, asked_by => 'trusted' } );
    my $public  = qr/I\ make\ public\ repositories\ only/;
    my $leak    = qr/can\ leak\ what\ is\ in\ one/;
    like( $private->{result},                 { refused => qr/to\ be\ private,\ and\ $public/ }, 'and a repository that is to be private' );
    like( calls_of('comment')->[-1][2]{body}, qr/\A\@trusted:\ .*$leak\ into\ the\ other/s,      'and tells the person why' );
    is( calls_of('create'), [], 'none of which it makes' );

    $state{absent}{'Test-Org/Retried'} = 1;
    $state{refuse_comment} = 1;
    my %retried = ( item => $other, org => 'Test-Org', name => 'Retried', description => 'd', module => 'Retried::Module', asked_by => 'trusted' );
    my $failed  = run_job( create_repo => \%retried );
    is( $failed->{state}, 'failed', 'a job that fails after it made the repository fails' );
    delete $state{refuse_comment};
    $minion->job( $failed->{id} )->retry;
    is( run_id( $failed->{id} )->{state},                  'finished',                  'and its retry finishes' );
    is( scalar @{ calls_of('create') },                    1,                           'without making the repository again' );
    is( [ map { $_->[2]{title} } @{ calls_of('issue') } ], ['Release Retried::Module'], 'or a second release issue, named for the module that triage gave' );

    @calls = ();
    $minion->reset( { all => 1 } );
    $state{absent}         = { 'Test-Org/Fresh-Dist' => 1 };
    $state{issue_comments} = [ { id => 1, user => { login => 'someone' }, body => 'Please make a new repository for this one.' } ];
    answer( {%plan} );
    like( run_job( triage => \%item )->{result}{error}, qr/not\ in\ anything\ that\ trusted\ wrote/, 'triage cannot ask for a repository on the words of someone else' );
    $state{review_comments} = [ { id => 51, user => { login => 'trusted' }, path => 'lib/X.pm', line => 3, body => "Please make a new repository for\nthis one." } ];
    answer( {%plan} );
    my $line = run_job( triage => { %item, is_pr => 1, number => 12 } );
    is( $line->{state}, 'finished', 'but it can on the words of a trusted user in a line comment of a review' ) or diag Mojo::Util::dumper $line->{result};
    delete $state{review_comments};
    answer( +{ %plan, new_repos => [ +{ %$new, asked_by => 'someone' } ] } );
    like( run_job( triage => \%item )->{result}{error}, qr/someone\ is\ not\ an\ authorized\ user/, 'nor for someone who is not authorized' );
    $config->{create_repos} = 0;
    $state{issue_comments} = [ { id => 1, user => { login => 'trusted' }, body => 'Please make a new repository for this one.' } ];
    answer( {%plan} );
    like( run_job( triage => \%item )->{result}{error}, qr{/new_repos:\ Too\ many\ items:\ 1/0}, 'nor for any, when create_repos is false' );
    is( calls_of('create'), [], 'and nothing is made' );

    $minion->reset( { all => 1 } );
    delete $config->{spoke_orgs};
    $config->{create_repos} = 0;
    delete $fake{FAKE_CLAUDE_RECORD};
};

subtest file_issues => sub {
    %state = ();
    @calls = ();
    my $config = $app->clod_config;
    my $pr     = { %item, kind => 'address_review', is_pr => 1, number => 11 };
    my $asked  = 'File a follow-up issue about the logging and we will move on.';
    $state{issue_comments} = [ { id => 1, user => { login => 'trusted' }, body => $asked } ];
    my $issue = { repo => 'Test-Org/two', title => 'Log less', body => 'The log says too much.', asked_by => 'trusted', quote => 'File a follow-up issue about the logging' };
    my %plan  = ( scope => 'follow_up', reason => 'filing settles it', repos => [], follow_ups => [$issue] );

    answer( {%plan} );
    $fake{FAKE_CLAUDE_RECORD} = "$tmp/follow-record";
    my $triage = run_job( triage => $pr );
    is( $triage->{state}, 'finished', 'a triage that only files a follow-up issue, which a trusted user asked for, finishes' ) or diag Mojo::Util::dumper $triage->{result};
    like( record_of("$tmp/follow-record")->{prompt}, qr/file\ follow-up\ issues\ in\ the\ spokes,\ at\ most\ 3/, 'triage is told that it may, and how many' );
    my @children = map { $minion->job($_)->info } @{ $triage->{result}{children} };
    is( [ map { $_->{task} } @children ], ['file_issues'], 'filing is the whole plan: no spoke runs, and no report' );
    is( calls_of('issue'),                [],              'triage itself files nothing' );

    my $filed = run_id( $children[0]{id} );
    is( $filed->{state}, 'finished', 'the hub files the issue' ) or diag Mojo::Util::dumper $filed->{result};
    my $issues = calls_of('issue');
    is( [ map { $_->[1] } @$issues ], ['/repos/Test-Org/two/issues'], 'once, in the spoke that triage named' );
    my $says = qr/\AThe\ log\ says\ too\ much\.\n\n/;
    my $link = qr{https://test\.test/Test-Org/two/issues/1};
    like( $issues->[0][2],          { title => 'Log less', assignees => ['trusted'], body => qr/$says\@trusted\ asked\ for\ this\ on\ \S+\/pull\/11\./ },                'with its title and body, assigned to the person who asked' );
    like( calls_of('comment')->[0], [ 'comment', '/repos/Test-Org/one/issues/11/comments', { body => qr{follow-up\ issues:\n-\ Test-Org/two:\ $link\ \(Log\ less\)} } ], 'and links it on the pull request that asked' );

    @calls = ();
    $state{refuse_comment} = 1;
    my $failed = run_job( file_issues => { item => { %$pr, number => 12 }, issues => [ $issue, { %$issue, title => 'Log better' } ] } );
    is( $failed->{state}, 'failed', 'a job that fails after it filed its issues fails' );
    delete $state{refuse_comment};
    $minion->job( $failed->{id} )->retry;
    is( run_id( $failed->{id} )->{state},                  'finished',                   'and its retry finishes' );
    is( [ map { $_->[2]{title} } @{ calls_of('issue') } ], [ 'Log less', 'Log better' ], 'without filing either issue twice' );

    @calls = ();
    $config->{follow_up_max} = 2;
    my %left = App::Clod::Tasks::creation( $minion, $config, { %$pr, number => 12 } );
    is( $left{follow_ups}, undef, 'once the origin has filed as many as it may, triage may ask for no more' );
    like( run_job( file_issues => { item => { %$pr, number => 12 }, issues => [$issue] } )->{result},                                   { refused => qr/filed\ 2\ already/, question => T() }, 'and the hub refuses one more for the same origin' );
    like( run_job( file_issues => { item => { %$pr, number => 13 }, issues => [ +{ %$issue, repo => 'Elsewhere/repo' } ] } )->{result}, { refused => qr{Elsewhere/repo\ is\ not\ a\ spoke} },  'and an issue in a repository that is not a spoke' );
    is( calls_of('issue'), [], 'neither of which it files' );
    $config->{follow_up_max} = 3;

    $state{issue_comments} = [ { id => 1, user => { login => 'someone' }, body => $asked } ];
    answer( {%plan} );
    my $theirs = qr/is\ not\ in\ anything\ that\ trusted\ wrote/;
    like( run_job( triage => { %$pr, number => 14 } )->{result}{error}, qr/follow-up\ issue\ "Log\ less"\ $theirs/, 'triage cannot file on the words of someone else' );
    $config->{follow_up_max} = 0;
    answer( {%plan} );
    like( run_job( triage => { %$pr, number => 14 } )->{result}{error}, qr{/follow_ups:\ Too\ many\ items:\ 1/0}, 'nor at all, when follow_up_max is 0' );
    $config->{follow_up_max} = 3;
    delete $fake{FAKE_CLAUDE_RECORD};
    $minion->reset( { all => 1 } );
};

subtest made_repos => sub {
    my $made   = { repo => 'Test-Org/Fresh', created => 1, created_at => 100 };
    my $finish = sub ($result) {
        my $job = $minion->worker->register->dequeue( 0, { id => $minion->enqueue('create_repo') } );
        $job->finish($result);
        $minion->worker->unregister;
    };
    $finish->($made);
    $finish->( { repo => 'Test-Org/Refused', refused => 'it exists' } );
    is( [ App::Clod::Tasks::made_repos( $minion, {} ) ], ['Test-Org/Fresh'], 'a repository that was made is a spoke before any sweep, and a refused one is not' );
    is( [ App::Clod::Tasks::made_repos( $minion, { started_at => 99 } ) ],                                   ['Test-Org/Fresh'], 'and after a sweep that started before it was made' );
    is( [ App::Clod::Tasks::made_repos( $minion, { started_at => 101 } ) ],                                  [],                 'a sweep that started after it was made says alone whether it is a spoke' );
    is( [ App::Clod::Tasks::made_repos( $minion, { started_at => 101, errors => { 'Test-Org' => 'x' } } ) ], ['Test-Org/Fresh'], 'unless that sweep could not list its organization' );
    $minion->reset( { all => 1 } );
};

subtest slug => sub {
    %state = ();
    is( App::Clod::Tasks::slug('Fix the thing!'),      'fix-the-thing', 'a title becomes a branch name' );
    is( App::Clod::Tasks::slug('!!!'),                 q{},             'a title with nothing usable gives no slug' );
    is( App::Clod::Tasks::slug(undef),                 q{},             'nor does no title' );
    is( length App::Clod::Tasks::slug( 'word ' x 30 ), 39,              'a long title is cut, and loses its trailing dash' );
};

subtest prompt => sub {
    %state = ();
    like( App::Clod::Tasks::prompt( triage => repo => 'Test-Org/one', kind => 'fix' ), qr/than\ in\ Test-Org\/one\ alone/, 'placeholders are filled' );
    unlike( App::Clod::Tasks::prompt( triage => () ), qr/\{\{/, 'and a missing one is left empty, not as a placeholder' );
};

done_testing;
