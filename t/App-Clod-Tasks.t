#!/usr/bin/env perl
use 5.040;
no autovivification;
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
$r->get('/repos/:o/:n/pulls')->to( cb => sub ($c) { $c->render( json => $state{open_pulls} // [] ) } );
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
$r->get('/repos/:o/:n/contents/*file')->to(
    cb => sub ($c) {
        push @{ $state{refs}{ $c->param('file') } }, $c->param('ref');
        my $f = $state{files}{ $c->param('file') };
        defined $f ? $c->render( text => $f ) : $c->render( json => {}, status => 404 );
    }
);
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
$r->get('/repos/:o/:n/issues')->to(
    cb => sub ($c) {
        my $repo = $c->param('o') . q{/} . $c->param('n');
        return $c->render( json => { message => 'Not Found' }, status => 404 ) if $state{issues_fail}{$repo};
        my $list = $state{issues}{$repo} // [ { number => 5, title => 'Assigned', html_url => 'https://test.test/5', updated_at => 'today' } ];
        push @{ $state{issue_queries} }, $c->req->params->to_hash;
        $list = [ grep { !$_->{assignee} } @$list ] if ( $c->param('assignee') // q{} ) eq 'none';
        $c->render( json => $list );
    }
);
$r->get('/search/issues')->to(
    cb => sub ($c) {
        my $q = $c->param('q');
        push @{ $state{searches} }, $q;
        my ($owner) = $q =~ m{user:(\S+)};
        return $c->render( json => { message => 'API rate limit exceeded' }, status => 403 ) if $state{search_fail}{$owner};
        my ($what) = grep { index( $q, $state{search_kinds}{$_} ) >= 0 } sort keys %{ $state{search_kinds} // {} };
        my @items = grep { $_->{repository_url} =~ m{/repos/\Q$owner\E/} } @{ $state{found}{ $what // q{} } // [] };
        $c->render( json => { total_count => scalar @items, items => \@items } );
    }
);
$r->get('/repos/:o/:n')->to(
    cb => sub ($c) {
        return $c->render( json => { message => 'Not Found' }, status => 404 ) if $state{absent}{ $c->param('o') . q{/} . $c->param('n') };
        return $c->render( json => { default_branch => 'main', private => Mojo::JSON::true, visibility => 'private' } ) if $c->param('n') eq 'hidden';
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
            restart_units    => [qw{clod-test.test.service clod-worker-test.test.service}],
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
    my %denied = $env{denied} ? ( permission_denials => $env{denied} ) : ();
    $stream->spew( Mojo::JSON::encode_json( { type => 'result', is_error => Mojo::JSON::false, structured_output => $structured, total_cost_usd => 0.5, usage => {}, %denied } ) . "\n" );
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

    # As GitHub sends it: the events API puts the assignee in actor, and the
    # user who assigned in assigner.
    $state{events} = [ { event => 'assigned', assignee => { login => $BOT }, actor => { login => $BOT }, assigner => { login => 'trusted' } } ];

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
    $state{events}  = [ { event => 'assigned', assignee => { login => $BOT }, actor => { login => $BOT }, assigner => { login => 'stranger' } } ];
    my $stranger = run_job('inbox_poll');
    like( $stranger->{result}{ignored}, [qr/requested\ by\ stranger,\ who\ is\ not\ authorized/], 'an assignment by someone not authorized is left alone' );

    # The events API names who asked for the review in review_requester.
    $state{threads} = [ { id    => 6, reason => 'review_requested', updated_at => 't5', repository => { full_name => 'Test-Org/one' }, subject => { type => 'PullRequest', url => "$api/repos/Test-Org/one/pulls/9", title => 'Look at this' } } ];
    $state{events}  = [ { event => 'review_requested', requested_reviewer => { login => $BOT }, actor => { login => 'stranger' }, review_requester => { login => 'trusted' } } ];
    my $review = run_job('inbox_poll');
    is( scalar @{ $review->{result}{queued} }, 1, 'a review that an authorized user asks for becomes work' ) or diag Mojo::Util::dumper $review->{result};

    $state{threads}   = [ { id => 5, reason => 'mention', updated_at => 't3', repository => { full_name => 'Test-Org/one' }, subject => { type => 'Issue', url => "$api/repos/Test-Org/one/issues/8", latest_comment_url => "$api/comment" } } ];
    $state{commenter} = 'trusted';
    my $mention = run_job('inbox_poll');
    is( $minion->job( $mention->{result}{queued}[0] )->info->{task}, 'reply', 'a mention goes straight to a reply' );

    # An assignment to a pull request, by an authorized user.
    my $own_pull = { user => { login => $BOT }, head => { repo => { full_name => 'Test-Org/one' } }, base => { ref => 'main' } };
    $state{events} = [ { event => 'assigned', assignee => { login => $BOT }, actor => { login => $BOT }, assigner => { login => 'trusted' } } ];
    my $assign_pull = sub ( $id, $number ) {
        $state{threads} = [ { id => $id, reason => 'assign', updated_at => "t$id", repository => { full_name => 'Test-Org/one' }, subject => { type => 'PullRequest', url => "$api/repos/Test-Org/one/pulls/$number", title => 'A change' } } ];
        return run_job('inbox_poll')->{result};
    };

    $state{pull}           = $own_pull;
    $state{issue_comments} = [ { id => 1, user => { login => 'trusted' }, body => 'Rename the sub.', created_at => '1' } ];
    my $own = $assign_pull->( 20, 12 );
    is( scalar @{ $own->{queued} }, 1, 'an assignment to the bot\'s own pull request becomes work' ) or diag Mojo::Util::dumper $own;
    like( $minion->job( $own->{queued}[0] )->info, { task => 'sort_review', args => [ { kind => 'address_review', number => 12 } ] }, 'which sorts its review comments, on that pull request' );

    @calls = ();
    $state{issue_comments} = [ { id => 1, user => { login => 'trusted' }, body => 'Rename the sub.', created_at => '1' }, { id => 2, user => { login => $BOT }, body => 'Done.', created_at => '2' } ];
    my $answered = $assign_pull->( 21, 13 );
    is( $answered->{queued}, [], 'with nothing since the last comment of the bot, it makes no job' );
    like( $answered->{ignored}, [qr/nothing\ on\ Test-Org\/one\#13\ waits\ for\ an\ answer/], 'and says so' );
    is( [ map { $_->[0] } @calls ], ['read'], 'it is marked read, without a reaction' );

    $state{review_comments} = [ { id => 30, user => { login => 'trusted' }, body => 'Not here.', path => 'lib/X.pm', line => 3 } ];
    my $threaded = $assign_pull->( 22, 14 );
    is( scalar @{ $threaded->{queued} }, 1, 'but a review thread whose last word is not the bot\'s is work' ) or diag Mojo::Util::dumper $threaded;
    delete $state{review_comments};

    $state{pull} = { user => { login => 'someone' }, head => { repo => { full_name => 'Test-Org/one' } }, base => { ref => 'main' } };
    my $theirs = $assign_pull->( 23, 15 );
    like( $minion->job( $theirs->{queued}[0] )->info, { task => 'triage', args => [ { kind => 'review', number => 15 } ] }, 'an assignment to the pull request of someone else becomes a review' );
    delete @state{qw{pull issue_comments}};

    # A review with a line comment.  Its notification names no latest comment,
    # or names the pull request itself.
    $state{pull}            = $own_pull;
    $state{issue_comments}  = [];
    $state{reviews}         = [ { id => 40, user => { login => 'trusted' }, body => q{}, state => 'COMMENTED', submitted_at => '2026-01-01T00:00:02Z' } ];
    $state{review_comments} = [ { id => 41, user => { login => 'trusted' }, body => 'What happens here?', path => 'lib/X.pm', line => 3, created_at => '2026-01-01T00:00:02Z' } ];
    my $reviewed = sub ( $id, %subject ) {
        $state{threads} = [ { id => $id, reason => 'author', updated_at => "t$id", repository => { full_name => 'Test-Org/one' }, subject => { type => 'PullRequest', url => "$api/repos/Test-Org/one/pulls/16", title => 'A change', %subject } } ];
        return run_job('inbox_poll')->{result};
    };
    my $bare = $reviewed->(24);
    is( scalar @{ $bare->{queued} }, 1, 'a line comment of an authorized user, in a notification that names no comment, is work' ) or diag Mojo::Util::dumper $bare;
    my $bare_job = $minion->job( $bare->{queued}[0] // -1 );
    like( $bare_job ? $bare_job->info : {}, { args => [ { kind => 'address_review', requester => 'trusted' } ] }, 'asked for by the author of the latest review' );
    $minion->reset( { all => 1 } );

    my $self_url = $reviewed->( 25, latest_comment_url => "$api/repos/Test-Org/one/pulls/16" );
    is( scalar @{ $self_url->{queued} }, 1, 'and so is one whose latest comment is the pull request itself' ) or diag Mojo::Util::dumper $self_url;
    $minion->reset( { all => 1 } );

    push @{ $state{review_comments} }, { id => 42, user => { login => 'stranger' }, body => 'Me too.', path => 'lib/X.pm', line => 3, in_reply_to_id => 41, created_at => '2026-01-01T00:00:09Z' };
    my $strange = $reviewed->(26);
    like( $strange->{ignored}, [qr/requested\ by\ stranger,\ who\ is\ not\ authorized/], 'but the latest word of a user who is not authorized is not' );
    delete @state{qw{pull issue_comments reviews review_comments}};
    $minion->reset( { all => 1 } );

    @calls          = ();
    $state{closed}  = { 9 => 1 };
    $state{threads} = [ { id => 6, reason => 'author', updated_at => 't4', repository => { full_name => 'Test-Org/one' }, subject => { type => 'PullRequest', url => "$api/repos/Test-Org/one/pulls/9", latest_comment_url => "$api/comment" } } ];
    my $closed = run_job('inbox_poll');
    is( $closed->{result}{queued}, [], 'a notification on a closed pull request makes no work' );
    like( $closed->{result}{ignored}, [qr/Test-Org\/one\#9\ is\ closed/], 'and says so' );
    is( [ map { $_->[0] } @calls ], ['read'], 'it is marked read, without a reaction' );
    $minion->reset( { all => 1 } );

    $state{issue_comments} = [ { id => 1, user => { login => q{trusted} }, body => q{Please change it.}, created_at => q{1} } ];
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
    is( $sent->{properties}{repos}{items}{properties}{repo}{enum}, App::Clod::Tasks::spokes( $minion, $app->clod_config ), 'and claude is told which repositories are spokes, in the schema' );
    is( [ grep { exists $sent->{$_} } qw{allOf anyOf oneOf} ],     [],                                                     'which has no allOf, anyOf or oneOf at its top level, because the API refuses them there' );
    delete $fake{FAKE_CLAUDE_RECORD};
    delete $system->{triage};
    ok( -e $tmp->child(qw{workspace hub CLAUDE.md}), 'the hub workspace has its CLAUDE.md' );
    like( $tmp->child(qw{workspace hub CLAUDE.md})->slurp, qr/Test-Org\/two\ is\ a\ test\ spoke/, 'which describes each spoke from its own' );
    $minion->reset( { all => 1 } );

    answer( { scope => 'single', reason => 'r', repos => [ { repo => 'Not/aspoke', order => 1, instructions => 'x' } ] } );
    my $bad = run_job( triage => \%item );
    is( $bad->{state}, 'failed', 'an answer that names a repo that is not a spoke fails, after its retry' );
    like( $bad->{result}{error}, qr{/repos/0/repo:\ Not\ in\ enum\ list:\ Test-Org/one}, 'and says why' );
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
    is( calls_of('assign'), [ [ 'assign', '/repos/Test-Org/one/issues/101/assignees', { assignees => ['trusted'] } ] ], 'and is assigned to the requester, so that it reaches them' );
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

    # In -p nobody can approve a call that the permissions do not allow, so a
    # run that committed nothing because of one failed.
    answer( { title => 't', summary => 'Not committed: the commit was refused.' }, denied => [ { tool_name => 'Bash', tool_use_id => 'x', tool_input => { command => 'rtk git add -A' } } ] );
    my $refused = run_job( spoke_fix => { item => \%item, repo => 'Test-Org/two', instructions => 'x' } );
    is( $refused->{state}, 'failed', 'a run that commits nothing because claude refused a call fails' ) or diag Mojo::Util::dumper $refused->{result};
    like( $refused->{result}{error}, qr/made\ no\ commit.*\n\ \ Bash\(rtk\ git\ add\ -A\)\z/s, 'and its error names each refused call, as the rule that would allow it' );
    is( scalar @{ calls_of('pull') }, 1, 'and it opens nothing' );

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

subtest 'a push that fails keeps the work for a retry' => sub {
    %state = ();
    @calls = ();
    my $bare   = $remote->child('Test-Org/one.git')->to_string;
    my $mirror = App::Clod::Tasks::spoke( $app->clod_config, 'Test-Org/one' )->mirror->to_string;
    my $mock   = Test::MockModule->new('App::Clod::Spoke');
    my $push   = $mock->original('push_branch');
    my $fails  = 0;
    $mock->redefine( push_branch => sub ( $self, @args ) { die "git push: remote: Internal Server Error\n" if $fails-- > 0; return $push->( $self, @args ) } );
    my $is_kept = sub ($id) {
        my $sha = eval { git( '--git-dir', $mirror, qw{rev-parse --verify --quiet}, "refs/clod/kept/$id" ) };
        return $sha;
    };

    # Runs the job again, as the retry button does, with a claude that would
    # commit nothing, and says whether claude ran.
    my $retry = sub ($id) {
        answer( { title => 'A second run', summary => 'Nothing.', replies => [] } );
        unlink "$tmp/kept-record";
        $fake{FAKE_CLAUDE_RECORD} = "$tmp/kept-record";
        $minion->job($id)->retry;
        my $info = run_id($id);
        delete $fake{FAKE_CLAUDE_RECORD};
        return ( $info, -e "$tmp/kept-record" ? 1 : 0 );
    };

    $fails = 1;
    answer( { title => 'The first title', summary => 'The first run.' }, commit => 1 );
    my $id     = $minion->enqueue( spoke_fix => [ { item => \%item, repo => 'Test-Org/one', instructions => 'do it' } ] );
    my $failed = run_id($id);
    is( $failed->{state}, 'failed', 'a fix whose push fails fails' );
    like( $failed->{result}, qr/Internal\ Server\ Error/, 'with the error of the push' );
    my $kept = $failed->{notes}{kept} // {};
    is( $is_kept->($id),  $kept->{sha}, 'and keeps its commit in the bare clone' );
    is( calls_of('pull'), [],           'and opens no pull request' );

    my ( $fixed, $ran ) = $retry->($id);
    is( $fixed->{state},                                                  'finished',        'a retry of it finishes' ) or diag Mojo::Util::dumper $fixed->{result};
    is( $ran,                                                             0,                 'without another claude run' );
    is( calls_of('pull')->[0][2]{title},                                  'The first title', 'and opens the pull request of the first run' );
    is( git( '--git-dir', $bare, 'rev-parse', $fixed->{result}{branch} ), $kept->{sha},      'with the commit that it kept' );
    is( [ $fixed->{notes}{kept}, $is_kept->($id) ],                       [ undef, undef ],  'and then keeps it no more' );

    # An answer to a review, on a branch that nobody else pushes to.
    git( q{--git-dir}, $bare, qw{branch clod/3-kept main} );
    $state{pull}            = { user => { login => $BOT }, head => { ref => 'clod/3-kept', sha => git( q{--git-dir}, $bare, qw{rev-parse clod/3-kept} ), repo => { full_name => 'Test-Org/one' } }, base => { ref => 'main' }, html_url => 'https://test.test/pull/13' };
    $state{review_comments} = [ { id => 21, user => { login => 'trusted' }, path => 'CLAUDE.md', line => 1, body => 'rename this' } ];
    my $pr      = { %item, kind => 'address_review', is_pr => 1, number => 13 };
    my $address = sub {
        $fails = 1;
        answer( { summary => 'Renamed.', replies => [ { id => 21, body => 'Renamed it.' } ] }, commit => 1 );
        my $aid = $minion->enqueue( spoke_address => [ { item => $pr, repo => 'Test-Org/one' } ] );
        return ( $aid, run_id($aid) );
    };
    @calls = ();
    my ( $aid, $afailed ) = $address->();
    is( [ $afailed->{state}, calls_of('reply') ], [ 'failed', [] ], 'an answer to a review whose push fails fails, and replies to nobody' );
    my ( $answered, $again ) = $retry->($aid);
    is( [ $answered->{state}, $again ],                       [ 'finished', 0 ],            'a retry of it finishes, without another claude run' ) or diag Mojo::Util::dumper $answered->{result};
    is( [ map { $_->[2]{body} } @{ calls_of('reply') } ],     ['Renamed it.'],              'and posts the replies of the first run' );
    is( git( '--git-dir', $bare, qw{rev-parse clod/3-kept} ), $afailed->{notes}{kept}{sha}, 'after it pushed the commit that it kept' );

    # Someone pushed to the branch between the two tries.
    $state{pull}{head}{sha} = git( q{--git-dir}, $bare, qw{rev-parse clod/3-kept} );
    my ($bid) = $address->();
    $state{pull}{head}{sha} = 'a-commit-of-someone-else';
    my ( undef, $reran ) = $retry->($bid);
    is( $reran,           1,     'but when the branch moved since, the retry runs claude again, and does not push over the new commit' );
    is( $is_kept->($bid), undef, 'and drops what it kept' );
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
    $state{pull}            = { user => { login => $BOT }, head => { ref => 'clod/1-ours', repo => { full_name => 'Test-Org/one' } }, base => { ref => 'stacked-on' }, html_url => 'https://test.test/pull/11' };
    $state{review_comments} = [ { id => 21, user => { login => 'trusted' }, path => 'CLAUDE.md', line => 1, body => 'rename this' } ];
    answer( { summary => 'Renamed.', replies => [ { id => 21, body => 'Done.' }, { id => 99, body => 'not a thread' } ] }, commit => 1 );
    my $pr   = { %item, kind => 'address_review', is_pr => 1, number => 11 };
    my $info = run_job( spoke_address => { item => $pr, repo => 'Test-Org/one', instructions => 'answer them' } );
    is( $info->{state},           'finished', 'the answer to the review finishes' ) or diag Mojo::Util::dumper $info->{result};
    is( $info->{result}{commits}, 1,          'the fix is committed' );
    isnt( git( '--git-dir', $bare, 'rev-parse', 'clod/1-ours' ), git( '--git-dir', $bare, 'rev-parse', 'main' ), 'and pushed to the pull request branch' );
    is( [ map { $_->[1] } @{ calls_of('reply') } ], ['/repos/Test-Org/one/pulls/11/comments/21/replies'], 'only the open thread gets a reply' );

    # A reply would say that the change was made, so a refused run says nothing.
    @calls = ();
    answer( { summary => 'Renamed.', replies => [ { id => 21, body => 'Done.' } ] }, denied => [ { tool_name => 'Bash', tool_use_id => 'x', tool_input => { command => 'rtk git commit -m x' } } ] );
    my $refused = run_job( spoke_address => { item => $pr, repo => 'Test-Org/one', instructions => 'answer them' } );
    is( $refused->{state}, 'failed', 'an answer to a review that commits nothing because claude refused a call fails' ) or diag Mojo::Util::dumper $refused->{result};
    like( $refused->{result}{error}, qr/Bash\(rtk\ git\ commit\ -m\ x\)/, 'and names the refused call' );
    is( calls_of('reply'), [], 'and replies to nobody' );

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
    like( $asked, qr{rebase\ onto\s+`origin/stacked-on`}, 'and a rebase that names no branch goes onto the base of the pull request, not the default branch' );
    is( [ map { $_->[2]{body} } @{ calls_of('comment') } ], ['Renamed it throughout.'], 'and answers it with a comment' );
    delete @state{qw{issue_comments reviews}};

    $state{pull} = { %{ $state{pull} }, user => { login => 'someone' } };
    is( run_job( spoke_address => { item => $pr, repo => 'Test-Org/one' } )->{state}, 'failed', 'a pull request that is not the bot\'s own is refused' );
    $minion->reset( { all => 1 } );
};

subtest sort_review => sub {
    %state = ();
    @calls = ();
    my $bare = $remote->child('Test-Org/one.git')->to_string;
    git( q{--git-dir}, $bare, qw{branch clod/2-sort main} );
    $state{pull}            = { user => { login => $BOT }, head => { ref => 'clod/2-sort', repo => { full_name => 'Test-Org/one' } }, html_url => 'https://test.test/pull/12' };
    $state{issue_comments}  = [ { id => 31, user => { login => 'trusted' }, body => 'Why a hash here?', created_at => '2026-11-01T10:00:00Z' } ];
    $state{review_comments} = [ { id => 21, user => { login => 'trusted' }, path => 'CLAUDE.md', line => 1, body => 'What does this line do?' } ];
    my $pr   = { %item, kind => 'address_review', is_pr => 1, number => 12 };
    my $head = git( q{--git-dir}, $bare, qw{rev-parse clod/2-sort} );

    answer( { summary => 'Two questions.', threads => [ { id => 21, verdict => 'answer', body => 'It names the file.' } ], comments => { verdict => 'answer', body => 'Lookup by name.' } } );
    $fake{FAKE_CLAUDE_RECORD} = "$tmp/sort-record";
    my $asked = run_job( sort_review => $pr );
    delete $fake{FAKE_CLAUDE_RECORD};
    is( $asked->{state},                                    'finished',                                           'questions are sorted' ) or diag Mojo::Util::dumper $asked->{result};
    is( [ map { $_->[1] } @{ calls_of('reply') } ],         ['/repos/Test-Org/one/pulls/12/comments/21/replies'], 'a question in a thread is answered in that thread' );
    is( [ map { $_->[2]{body} } @{ calls_of('comment') } ], ['Lookup by name.'],                                  'and the plain comments in one comment' );
    is( $asked->{result}{next},                             undef,                                                'and with nothing left, no job comes after' );
    my $run  = record_of("$tmp/sort-record");
    my @read = ( qw{Read Grep Glob}, map { "Bash(git $_:*)" } qw{log grep show diff} );
    is( $run->{flags}{'--allowedTools'}, [ join q{,}, map { App::Clod::Claude::rtk_too($_) } @read ], 'the run has the read tools alone' );
    like( $run->{prompt}, qr/What\ does\ this\ line\ do\?/, 'and gets the threads' );
    is( git( q{--git-dir}, $bare, qw{rev-parse clod/2-sort} ), $head, 'and the branch is as it was' );

    @calls = ();
    $state{review_comments} = [ @{ $state{review_comments} }, { id => 22, user => { login => 'trusted' }, path => 'CLAUDE.md', line => 2, body => 'Rename this.' }, { id => 23, user => { login => 'trusted' }, path => 'CLAUDE.md', line => 3, body => 'Hmm.' } ];
    answer( { summary => 'One question, one change.', threads => [ { id => 21, verdict => 'answer', body => 'It names the file.' }, { id => 22, verdict => 'change' } ], comments => { verdict => 'change' }, instructions => 'Rename it.' } );
    my $mixed = run_job( sort_review => $pr );
    is( [ map { $_->[1] } @{ calls_of('reply') } ], ['/repos/Test-Org/one/pulls/12/comments/21/replies'], 'with a change asked for as well, only the question is answered' );
    is( calls_of('comment'),                        [],                                                   'and plain comments that ask for a change are left to the change' );
    is( $mixed->{result}{answered},                 [21],                                                 'which it says' );
    my $next = $minion->job( $mixed->{result}{next}{id} // -1 );
    like( $next ? $next->info : {}, { task => 'spoke_address', args => [ { repo => 'Test-Org/one', instructions => 'Rename it.', item => { number => 12 } } ], notes => { origin => 'Test-Org/one#12' } }, 'the change goes to spoke_address, with the instructions' );

    answer( { summary => 'Needs the other spoke.', threads => [ { id => 22, verdict => 'elsewhere' } ], comments => { verdict => 'answer', body => 'Lookup by name.' } } );
    my $wide   = run_job( sort_review => $pr );
    my $triage = $minion->job( $wide->{result}{next}{id} // -1 );
    like( $triage ? $triage->info : {}, { task => 'triage', args => [ { kind => 'address_review', number => 12 } ], notes => { kind => 'address_review' } }, 'a change in another spoke goes to triage' );
    is( $wide->{result}{next}{task}, 'triage', 'even beside a thread that has no verdict' );

    answer( { summary => 'Unsure.', threads => [ { id => 21, verdict => 'answer' } ], comments => { verdict => 'answer', body => q{} } } );
    @calls = ();
    my $unsure = run_job( sort_review => $pr );
    is( [ @{ calls_of('reply') }, @{ calls_of('comment') } ], [],              'an answer with no body is posted nowhere' );
    is( $unsure->{result}{next}{task},                        'spoke_address', 'it is a change' );
    $minion->reset( { all => 1 } );

    $state{issue_comments}  = [ { id => 31, user => { login => 'trusted' }, body => 'Why?' }, { id => 32, user => { login => $BOT }, body => 'Because.' } ];
    $state{review_comments} = [];
    is( run_job( sort_review => $pr )->{result}{nothing}, 1, 'with nothing pending, it runs nothing' );

    $state{pull} = { %{ $state{pull} }, user => { login => 'someone' } };
    is( run_job( sort_review => $pr )->{state}, 'failed', 'a pull request that is not the bot\'s own is refused' );

    # A mention on the bot's own pull request is sorted too, and not a reply.
    $state{pull}           = { user => { login => $BOT }, head => { ref => 'clod/2-sort', repo => { full_name => 'Test-Org/one' } } };
    $state{issue_comments} = [ { id => 33, user => { login => 'trusted' }, body => "\@$BOT why?" } ];
    $state{commenter}      = 'trusted';
    $state{threads}        = [ { id => 50, reason => 'mention', updated_at => 't50', repository => { full_name => 'Test-Org/one' }, subject => { type => 'PullRequest', url => "$api/repos/Test-Org/one/pulls/12", latest_comment_url => "$api/comment" } } ];
    my $poll   = run_job('inbox_poll')->{result};
    my $queued = $minion->job( $poll->{queued}[0] // -1 );
    is( $queued ? $queued->info->{task} : undef, 'sort_review', 'a mention on the bot\'s own pull request is sorted' ) or diag Mojo::Util::dumper $poll;

    $state{pull}    = { user => { login => 'someone' }, head => { repo => { full_name => 'Test-Org/one' } } };
    $state{threads} = [ +{ %{ $state{threads}[0] }, id => 51, updated_at => 't51' } ];
    my $theirs = $minion->job( run_job('inbox_poll')->{result}{queued}[0] // -1 );
    is( $theirs ? $theirs->info->{task} : undef, 'reply', 'and on the pull request of someone else, it is a reply' );
    $minion->reset( { all => 1 } );
};

subtest claude => sub {
    my $config = Clone::clone( $app->clod_config );
    is( App::Clod::Tasks::claude($config)->run_as, undef, 'claude runs as the worker unless the configuration says otherwise' );
    $config->{claude}{run_as} = 'test-agent';
    is( App::Clod::Tasks::claude($config)->run_as, 'test-agent', 'and as the account of run_as when it does' );
};

subtest system_text => sub {
    my %config = ( spoke_prompt => 'Test on a guest.', system_prompts => { spoke_fix => 'Fix with care.' } );
    is( App::Clod::Tasks::system_text( \%config, 'spoke_fix' ), "Test on a guest.\n\nFix with care.", 'a spoke run gets the spoke prompt, then the prompt of its task' );
    $config{agent_own_lib} = '/bogus/own-lib';
    my $install = qr/If\ the\ change\ needs\ a\ CPAN\ module.*/;
    like( App::Clod::Tasks::system_text( \%config, 'spoke_fix' ), qr/\ATest\ on\ a\ guest[.]\n\n$install\n\nFix\ with\ care[.]\z/, 'and with an own lib, how to install a module, between them' );
    is( App::Clod::Tasks::system_text( \%config, 'triage' ), undef, 'but a run that is not in a spoke gets neither' );
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
    like( $told->{flags}{'--allowedTools'}[0], qr/,Bash\(bin\/provision:\*\),Bash\(rtk\ bin\/provision:\*\)\z/, 'and the extra tools are allowed, after the configured ones, with the rule for what rtk makes of each' );
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
    like( [ $died->@{qw{state result}} ], [ 'failed', qr/500/ ], 'a job that dies after the run fails' );
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

    answer( { action => 'fix', body => 'I will fix it.' } );
    my $on_pull = $minion->job( run_job( reply => { %item, kind => 'reply', is_pr => 1, number => 9 } )->{result}{triage_job} // -1 );
    is( $on_pull ? $on_pull->info->{args}[0]{kind} : undef, 'fix', 'on the pull request of someone else too, which the bot cannot push to' );
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

subtest harness_fix => sub {
    %state = ();
    @calls = ();

    # The worker sets none of these, and a shell that does would name its own author.
    delete local @ENV{qw{GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL}};
    my $bare = $remote->child('Test-Org/two.git')->to_string;
    my $args = { repo => 'Test-Org/two', checks => [ { check => 'GitHooks', detail => 'there is no git-hooks/pre-commit' } ], by => 'trusted' };
    my $info = run_job( harness_fix => $args );
    is( $info->{state}, 'finished', 'a harness fix finishes' ) or diag Mojo::Util::dumper $info->{result};
    my ($issue) = map { $_->[2] } @{ calls_of('issue') };
    is( $issue->{title}, 'Meet the harness standards', 'it files an issue' );
    like( $issue->{body}, qr/`GitHooks`:\ there\ is\ no\ git-hooks\/pre-commit/, 'that names each failing check' );
    is( $issue->{assignees},                                    ['trusted'],     'assigned to who pressed the button' );
    is( [ map { $_->[2]{assignees} } @{ calls_of('assign') } ], [ ['trusted'] ], 'and so is the pull request' );
    my $pull = calls_of('pull')->[0][2];
    like( $pull,         { title => 'Meet the harness standards', head => $info->{result}{branch}, base => 'main', body => qr/Closes\ \#1/ }, 'and opens a pull request that closes it' );
    like( $pull->{body}, qr/`GitHooks`:\ \w+\ `git-hooks\/pre-commit`/,                                                                       'and says what the update changed' );
    my $hook = $here->child(qw{data standards templates pre-commit})->slurp;
    chomp $hook;
    is( git( '--git-dir', $bare, 'show', "$info->{result}{branch}:git-hooks/pre-commit" ), $hook, 'with the hook of the standards on its branch' );
    like( git( '--git-dir', $bare, 'log', '-1', '--format=%an %s', $info->{result}{branch} ), qr/\A$BOT\ Meet\ the\ harness\ standards\z/, 'committed by the bot' );

    @calls = ();
    $state{open_pulls} = [ { title => 'Meet the harness standards', user => { login => $BOT }, html_url => 'https://test.test/pull/7' } ];
    my $again = run_job( harness_fix => $args );
    is( $again->{result},                                  { repo => 'Test-Org/two', pr_url => 'https://test.test/pull/7', open_already => 1 }, 'with that pull request open, a second fix does nothing' );
    is( [ @{ calls_of('issue') }, @{ calls_of('pull') } ], [],                                                                                  'and files nothing' );
    delete $state{open_pulls};

    # The login of the dashboard need not be one of GitHub, nor authorized.
    $app->clod_config->{authorized_users} = [qw{trusted other}];
    is( [ App::Clod::Tasks::reviewers( $app->clod_config, 'other' ) ],           ['other'],           'a pull request goes to an authorized user who asked' );
    is( [ App::Clod::Tasks::reviewers( $app->clod_config, 'dashboard-admin' ) ], [qw{trusted other}], 'and for anyone else, to every authorized user' );
    is( [ App::Clod::Tasks::reviewers( $app->clod_config, undef ) ],             [qw{trusted other}], 'as for nobody known' );
    $app->clod_config->{authorized_users} = ['trusted'];

    @calls = ();
    $state{refuse_assign} = 1;
    my $refused = run_job( harness_fix => { %$args, repo => 'Test-Org/one' } );
    is( $refused->{state}, 'finished', 'an assignment that GitHub refuses does not fail the job' ) or diag Mojo::Util::dumper $refused->{result};
    like( $refused->{notes}{log}, [ { message => qr/opened/ }, { message => qr/could\ not\ assign\ Test-Org\/one\#\d+\ to\ trusted/ } ], 'and says so in its log' );
    delete $state{refuse_assign};

    my $harness = Test::MockModule->new('App::Clod::Harness');
    $harness->redefine( update => sub (@) { return [ { check => 'ClaudeMd', changes => [], manual => ['Say what the repository is for.'] } ] } );
    @calls = ();
    my $nothing = run_job( harness_fix => $args );
    is( [ $nothing->{result}{no_change}, calls_of('pull') ], [ 1, [] ], 'an update that changes no file opens no pull request' );
    my $said = calls_of('comment')->[0][2]{body};
    like( $said, qr/changes\ no\ file/,      'and says on the issue that nothing changed' );
    like( $said, qr/`ClaudeMd`:\ Say\ what/, 'and what is left for a person' );
    $minion->reset( { all => 1 } );
};

subtest 'self_check and self_update' => sub {
    %state = ();
    @calls = ();

    # An upstream with one commit more than the checkout that the bot runs.
    my $origin = $tmp->child('self-origin.git');
    git( qw{init --quiet --bare --initial-branch=main}, "$origin" );
    my $seed = $tmp->child('self-seed')->make_path;
    git( q{-C}, "$seed", qw{init --quiet --initial-branch=main} );
    my $commit = sub ($what) {
        git( q{-C}, "$seed", qw{-c user.name=t -c user.email=t@test.test commit --quiet --allow-empty -m}, $what );
        git( q{-C}, "$seed", 'push', '--quiet', "$origin", 'main' );
        return git( q{-C}, "$seed", qw{rev-parse HEAD} );
    };
    my $first    = $commit->('one');
    my $checkout = $tmp->child('self-checkout');
    git( 'clone', '--quiet', "$origin", "$checkout" );
    my $second = $commit->('two');

    my $self = Test::MockModule->new('App::Clod');
    $self->redefine( checkout => sub { $checkout } );
    my $running = { sha => $first, short => substr $first, 0, 7 };
    $app->helper( running => sub { $running } );
    my $claude = Test::MockModule->new('App::Clod::Claude');
    my @updated;
    $claude->redefine( plugins => sub ($) { [ { id => 'kit@m', version => '1.0', latest => '1.1' }, { id => 'ok@m', version => '2', latest => '2' } ] } );
    $claude->redefine( cli     => sub ( $, @args ) { push @updated, [@args]; return q{} } );

    my $check = run_job('self_check');
    is( $check->{state}, 'finished', 'the check finishes' ) or diag Mojo::Util::dumper $check->{result};
    like( $check->{result}, { running => { sha => $first }, checkout => { head => $first, upstream => $second, behind => 1, ahead => 0 } }, 'it fetches, and finds the checkout one commit behind its upstream' );
    is( scalar @{ $check->{result}{plugins} }, 2, 'and lists the plugins' );

    my @restarted;
    my $tasks = Test::MockModule->new('App::Clod::Tasks');
    $tasks->redefine( restart_unit => sub ($unit) { push @restarted, $unit; return } );
    my $cgroup = $tmp->child('cgroup');
    $cgroup->spew("0::/system.slice/clod-worker-test.test.service\n");
    local $App::Clod::Tasks::CGROUP = "$cgroup";

    my $update = run_job('self_update');
    is( $update->{state},                              'finished',                                                 'the update finishes' ) or diag Mojo::Util::dumper $update->{result};
    is( git( q{-C}, "$checkout", qw{rev-parse HEAD} ), $second,                                                    'it pulls the new commit' );
    is( \@restarted,                                   [qw{clod-test.test.service clod-worker-test.test.service}], 'and restarts the units, its own one last' );
    is( $update->{result}{restarted},                  \@restarted,                                                'and says which' );

    @restarted = ();
    $running   = { sha => $second, short => substr $second, 0, 7 };
    my $again = run_job('self_update');
    is( [ $again->{result}{to}, \@restarted ], [ $second, [] ], 'with nothing new, and the new commit running, it restarts nothing' );

    git( q{-C}, "$checkout", qw{reset --quiet --hard}, $first );
    $running = { sha => $first, short => substr $first, 0, 7 };
    $commit->('three');
    $checkout->child('local')->spew('a change of somebody');
    git( q{-C}, "$checkout", qw{add local} );
    git( q{-C}, "$checkout", qw{-c user.name=t -c user.email=t@test.test commit --quiet -m local} );
    @restarted = ();
    is( run_job('self_update')->{state}, 'failed', 'a checkout with commits of its own is not merged, and the update fails' );
    is( \@restarted,                     [],       'and restarts nothing' );

    # With a local lib, the update installs what the new commit needs before
    # it restarts, and an upgrade of the modules restarts too.
    my @deps;
    my $deps = Test::MockModule->new('App::Clod::Deps');
    $deps->redefine( listdeps         => sub ($dir) { push @deps, "listdeps $dir";                     return qw{Foo Bar} } );
    $deps->redefine( install          => sub ( $lib, @modules ) { push @deps, "install $lib @modules"; return } );
    $deps->redefine( outdated         => sub ($lib) { return [ { module => 'Foo', version => '1', latest => '2' } ] } );
    $deps->redefine( upgrade          => sub ($lib) { push @deps, "upgrade $lib";  return [ { module => 'Foo', version => '1', latest => '2' } ] } );
    $deps->redefine( install_programs => sub ($lib) { push @deps, "programs $lib"; return } );
    $app->clod_config->{local_lib} = '/bogus/perl5';
    $app->clod_config->{agent_lib} = '/bogus/agent-perl5';
    git( q{-C}, "$checkout", qw{reset --quiet --hard}, '@{upstream}' );
    $commit->('four');
    @restarted = ();
    my $with_lib = run_job('self_update');
    delete $app->clod_config->{agent_lib};
    is( [ $with_lib->{state}, \@deps ], [ 'finished', [ "listdeps $checkout", 'install /bogus/perl5 Foo Bar', 'programs /bogus/agent-perl5' ] ], 'with a local lib, the update installs what the checkout needs, and the programs of the agent lib' ) or diag Mojo::Util::dumper $with_lib->{result};
    is( scalar @restarted,              2,                                                                                                       'and then restarts' );

    is( run_job('self_check')->{result}{deps}, [ { module => 'Foo', version => '1', latest => '2' } ], 'the check lists the modules with a newer release' );
    @deps      = ();
    @restarted = ();
    run_job('deps_upgrade');
    is( [ \@deps, scalar @restarted ], [ ['upgrade /bogus/perl5'], 2 ], 'an upgrade of the modules upgrades them in the local lib, and restarts' );
    $deps->redefine( upgrade => sub ($lib) { return [] } );
    @restarted = ();
    is( [ run_job('deps_upgrade')->{result}, \@restarted ], [ { upgraded => [] }, [] ], 'and with nothing to upgrade, restarts nothing' );
    delete $app->clod_config->{local_lib};

    my $plugins = run_job('plugin_update');
    is( $plugins->{result}{updated}, ['kit@m'],                     'the plugins that are behind are updated' );
    is( \@updated,                   [ [qw{plugin update kit@m}] ], 'with claude plugin update, and the others are not' );

    my $checks = $minion->jobs( { tasks => ['self_check'], states => ['inactive'] } );
    is( $checks->total, 1, 'each action queues a new check, so its action item does not wait half an hour, and no second while one waits' );
    ok( $checks->next->{delayed} >= time + $App::Clod::Tasks::RECHECK_DELAY - 5, 'which waits, so that it does not start in the worker that the action restarts' );
    $minion->reset( { all => 1 } );
};

subtest 'the references that triage reads' => sub {
    %state = ();
    @calls = ();
    my @refreshed;
    my $mock = Test::MockModule->new('App::Clod::Spoke');
    my $real = $mock->original('refresh_reference');
    $mock->redefine( refresh_reference => sub ( $self, @args ) { push @refreshed, $self->repo; return $real->( $self, @args ) } );
    my $config = $app->clod_config;
    my $gh     = App::Clod::Tasks::github($config);

    App::Clod::Tasks::prepare_hub( $config, $gh, \@SPOKES );
    @refreshed = ();
    my ( undef, $ref ) = App::Clod::Tasks::prepare_hub( $config, $gh, \@SPOKES, 'Test-Org/two' );
    is( \@refreshed,         ['Test-Org/two'], 'with every reference there, triage refreshes only the one of its request' );
    is( [ sort keys %$ref ], \@SPOKES,         'and still reads every spoke' );

    App::Clod::Tasks::spoke( $config, 'Test-Org/one' )->reference->remove_tree;
    @refreshed = ();
    App::Clod::Tasks::prepare_hub( $config, $gh, \@SPOKES, 'Test-Org/two' );
    is( [ sort @refreshed ], \@SPOKES, 'and a spoke that has no reference yet, so that it can read it' );

    $minion->reset( { all => 1 } );
    run_job('spoke_sweep');
    my $next = $minion->jobs( { tasks => ['refresh_references'] } )->next;
    ok( $next, 'a spoke sweep queues a refresh of the references' ) or return;
    run_job('spoke_sweep');
    is( $minion->jobs( { tasks => ['refresh_references'] } )->total, 1, 'and no second one while one waits' );

    @refreshed = ();
    my $refresh = run_id( $next->{id} );
    is( [ $refresh->{result}{refreshed}, [ sort @refreshed ] ], [ 2, \@SPOKES ], 'the refresh refreshes every spoke' );
    $minion->reset( { all => 1 } );
};

subtest 'the agent lib' => sub {
    %state = ();
    my $config = $app->clod_config;
    is(
        [ App::Clod::Tasks::agent_tools($config) ],
        [qw{Perl::Critic Perl::Tidy Devel::NYTProf Dist::Zilla::App::Command::podchecker Perl::Critic::Policy::ProhibitPipeOpen Perl::Critic::Policy::Variables::RequireNoAutovivification}],
        'the agent needs its tools, and each policy of the critic profiles of the standards'
    );

    my ( @did, @restarted );
    my $deps = Test::MockModule->new('App::Clod::Deps');
    $deps->redefine(
        missing => sub ( $lib, @modules ) {
            return grep { m{Autovivification} } @modules;
        }
    );
    $deps->redefine( outdated         => sub ($lib) { return [ { module => 'Perl::Tidy', version => '1', latest => '2' } ] } );
    $deps->redefine( install          => sub ( $lib, @modules ) { push @did, "install $lib @modules"; return } );
    $deps->redefine( install_programs => sub ($lib) { push @did, "programs $lib";                     return } );
    $deps->redefine( stale_programs   => sub ($lib) { return 'clod-cpm' } );
    $deps->redefine( upgrade          => sub ($lib) { push @did, "upgrade $lib"; return $lib =~ m{agent} ? [ { module => 'Perl::Tidy' } ] : [] } );
    my $tasks = Test::MockModule->new('App::Clod::Tasks');
    $tasks->redefine( restart_unit => sub ($unit) { push @restarted, $unit; return } );
    my $claude = Test::MockModule->new('App::Clod::Claude');
    $claude->redefine( plugins => sub ($) { [] } );

    $config->{agent_lib} = '/bogus/agent-perl5';
    my $check = run_job('self_check');
    is( $check->{result}{agent_deps}, { missing => [ 'Perl::Critic::Policy::Variables::RequireNoAutovivification', 'clod-cpm' ], outdated => [ { module => 'Perl::Tidy', version => '1', latest => '2' } ] }, 'the check says what the agent lib lacks, and what has a newer release' );

    my $upgrade = run_job('deps_upgrade');
    is( \@did,                                  [ 'install /bogus/agent-perl5 Perl::Critic::Policy::Variables::RequireNoAutovivification', 'programs /bogus/agent-perl5', 'upgrade /bogus/agent-perl5' ], 'an upgrade installs what the agent lib lacks, and its programs, and upgrades what is outdated' );
    is( [ $upgrade->{state}, \@restarted ],     [ 'finished', [] ],                                                                                                                                       'and restarts nothing, because the next claude run loads them' );
    is( App::Clod::Tasks::claude($config)->lib, '/bogus/agent-perl5',                                                                                                                                     'and claude runs with the agent lib' );
    $config->{agent_own_lib} = '/bogus/own-lib';
    is( App::Clod::Tasks::claude($config)->own_lib, '/bogus/own-lib', 'and with the own lib of the agent' );
    delete $config->{agent_own_lib};
    delete $config->{agent_lib};
    $minion->reset( { all => 1 } );
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
    is( $one->{fix_pr},                                                          undef,                 'with no harness fix open, a failing spoke names none' );

    $state{open_pulls} = [ { title => 'Meet the harness standards', user => { login => $BOT }, html_url => 'https://test.test/pull/33' }, { title => 'Meet the harness standards', user => { login => 'someone' }, html_url => 'https://test.test/pull/34' } ];
    is( run_job('harness_scan')->{result}{repos}{'Test-Org/one'}{fix_pr}, 'https://test.test/pull/33', 'and with the harness fix of the bot open, it names that one' );
    delete $state{open_pulls};

    $state{files}{'.conformance.yml'} = "flavor: test-chosen\nsource:\n  directory: " . $here->child( 'data', 'standards' ) . "\n";
    my $chosen = run_job('harness_scan')->{result};
    is( $chosen->{checks},                        [qw{ClaudeMd ToolConfiguration workflows}], 'a spoke that names its flavor is checked against that one' );
    is( $chosen->{repos}{'Test-Org/one'}{chosen}, 1,                                          'which it chose' );

    $state{files}{'.conformance.yml'} = "flavor: test-gone\nsource:\n  directory: " . $here->child( 'data', 'standards' ) . "\n";
    like( run_job('harness_scan')->{result}{errors}{'Test-Org/one'}, qr/test-gone/, 'and one whose flavor cannot be read is an error of the scan' );
};

subtest 'system packages' => sub {
    %state = ();
    my $config = $app->clod_config;
    my $simple = "x_system_packages:\n  ffmpeg:\n    deb: ffmpeg\n    test: ffmpeg -version\n";
    $state{files} = {
        'CLAUDE.md'                       => 'perl-slop:reading-perl',
        '.claude-plugin/plugin.json'      => '{"version":"0.11.0"}',
        '.claude-plugin/marketplace.json' => '{"plugins":[{"name":"perl-slop","version":"0.11.0"}]}',
        'metamerge.yml'                   => $simple,
    };
    ok( !exists run_job('harness_scan')->{result}{system_packages}, 'without system_packages in the configuration, the scan reads no declaration' );

    $config->{system_packages} = { packager => 'deb', installer => '/bogus/clod-install-packages' };
    delete $state{refs};
    my $scan     = run_job('harness_scan')->{result};
    my %declared = ( packages => { ffmpeg => { deb => 'ffmpeg', test => 'ffmpeg -version' } }, sources => {} );
    is( $scan->{system_packages},      { map { $_ => \%declared } @SPOKES }, 'with it, the scan reads what each spoke declares' );
    is( $state{refs}{'metamerge.yml'}, [ 'main', 'main' ],                   'from its default branch, and no branch that the bot pushed' );

    $state{files}{'metamerge.yml'} = "x_system_packages:\n  ffmpeg:\n    deb: foo=1.2\n";
    my $invalid = run_job('harness_scan');
    is( $invalid->{state}, 'finished', 'a declaration that is not valid does not stop the scan' );
    like( $invalid->{result}{system_package_errors}{'Test-Org/one'}, qr/\Ametamerge\.yml\ is\ not\ valid:\n\s+\S/, 'it is a finding of the spoke, with each error' );
    is( [ sort keys %{ $invalid->{result}{repos} } ], \@SPOKES, 'and the spoke is still checked' );
    ok( !exists $invalid->{result}{system_packages}{'Test-Org/one'}, 'with no declaration' );

    $state{files}{'metamerge.yml'} = <<~'YAML';
        x_system_packages:
          libmagic:
            deb:
              name: libmagic-dev
              ubuntu/24.04: libmagic-t64
          ffmpeg:
            deb:
              name: ffmpeg
              source: jellyfin
            test: ffmpeg -version
          FooLib:
            deb:
              ubuntu/24.04: libfoo-dev
              debian/12: ~
        x_system_sources:
          deb:
            - name: jellyfin
              uri: https://repo.test.test/ubuntu
              suites: ['{codename}']
              components: [main]
              key: https://repo.test.test/key.gpg
              fingerprint: 0123456789ABCDEF0123456789ABCDEF01234567
              distros: [ubuntu/24.04]
        YAML
    run_job('harness_scan');

    my $os_release = $tmp->child('os-release');
    my $apt        = $tmp->child('sources.list.d')->make_path;
    local $App::Clod::Packages::OS_RELEASE  = "$os_release";
    local $App::Clod::Packages::APT_SOURCES = "$apt";
    my %jellyfin = ( name => 'jellyfin', uri => 'https://repo.test.test/ubuntu', suites => ['noble'], components => ['main'], key => 'https://repo.test.test/key.gpg', fingerprint => '0123456789ABCDEF0123456789ABCDEF01234567' );

    my $self = Test::MockModule->new('App::Clod');
    $self->redefine( checkout => sub { return } );
    my $claude = Test::MockModule->new('App::Clod::Claude');
    $claude->redefine( plugins => sub ($) { [] } );
    my ( %have, %error, @asked, @ran, @installed );
    my $packages = Test::MockModule->new('App::Clod::Packages');
    $packages->redefine( installed     => sub ( $packager, $name ) { push @asked, "$packager $name";          return $have{$name} } );
    $packages->redefine( program_error => sub ( $claude,   $line ) { push @ran,   [ $claude->run_as, $line ]; return $error{$line} } );
    %have = ( 'libfoo-dev' => 1 );
    $os_release->spew(qq{ID=ubuntu\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\n});
    my $check = run_job('self_check')->{result};
    my %noble = (
        needs      => [ { name => 'ffmpeg', package => 'ffmpeg', archive => \%jellyfin }, { name => 'libmagic', package => 'libmagic-t64', archive => undef } ],
        missing    => [qw{ffmpeg libmagic-t64}],
        sources    => [ \%jellyfin ],
        unresolved => [],
        failing    => [],
    );
    is( $check->{system_packages}, { map { $_ => \%noble } @SPOKES },                               'the check finds each dependency whose package the host lacks, by its name on this release, and the archive that it adds, for this codename' );
    is( $check->{system_host},     { distro => 'ubuntu', release => '24.04', codename => 'noble' }, 'for the distribution of the host' );
    is( [ \@asked, \@ran ],        [ [ 'deb libfoo-dev', 'deb ffmpeg', 'deb libmagic-t64' ], [] ],  'it asks dpkg once about each package, and runs no test while a package is missing' );

    $os_release->spew(qq{ID=debian\nVERSION_ID="12"\nVERSION_CODENAME=bookworm\n});
    is(
        run_job('self_check')->{result}{system_packages}{'Test-Org/one'},
        { needs => [ { name => 'libmagic', package => 'libmagic-dev', archive => undef } ], missing => ['libmagic-dev'], sources => [], unresolved => ['ffmpeg'], failing => [] },
        'on another distribution, a package has its other name, a dependency that needs no package there needs nothing, and one whose archive is not for it is unresolved'
    );
    $os_release->spew(qq{ID=ubuntu\nVERSION_ID="24.04"\n});
    like( run_job('self_check')->{result}{system_packages}{'Test-Org/one'}, { missing => [], error => qr/needs\ the\ codename/ }, 'a declaration that does not resolve on this host is an error of its spoke' );
    $os_release->spew(qq{ID=ubuntu\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\n});
    $apt->child('jellyfin.sources')->spew("Types: deb\n");
    my $known = run_job('self_check')->{result}{system_packages}{'Test-Org/one'};
    is( [ $known->{sources}, $known->{needs}[0]{archive} ], [ [], undef ], 'and an archive that apt has already is not added again' );
    $apt->child('jellyfin.sources')->remove;

    %have                     = ( ffmpeg            => 1, 'libmagic-t64' => 1, 'libfoo-dev' => 1 );
    %error                    = ( 'ffmpeg -version' => 'ffmpeg: error while loading shared libraries' );
    @ran                      = ();
    $config->{claude}{run_as} = 'test-agent';
    $check                    = run_job('self_check')->{result};
    is( $check->{system_packages}{'Test-Org/one'}{failing}, [ { program => 'ffmpeg -version', dependency => 'ffmpeg', error => 'ffmpeg: error while loading shared libraries' } ], 'with every package there, a test that fails is a finding of its dependency' );
    is( \@ran,                                              [ ( [ 'test-agent', 'ffmpeg -version' ] ) x 2 ],                                                                       'which it runs for each spoke, as the account that claude runs as' );
    $config->{claude}{run_as} = undef;

    $packages->redefine( program_error => sub ( $claude, $line ) { return } );
    is( run_job('self_check')->{result}{system_packages}, {}, 'and a host with everything finds nothing' );
    $packages->redefine( installed => sub (@) { die "dpkg-query: not found\n" } );
    like( run_job('self_check')->{result}, { system_packages => {}, system_packages_error => 'dpkg-query: not found' }, 'a check that cannot ask says why' );

    $minion->reset( { all => 1 } );
    my $output = "Setting up libmagic-dev\n";
    my @lines;
    $packages->redefine(
        install => sub ( $installer, $file, @names ) {
            push @installed, [ $installer, $file, @names ];
            @lines = defined $file ? map { Mojo::JSON::decode_json($_) } split m{\n}, Mojo::File->new($file)->slurp : ();
            return $output;
        }
    );
    my $install = run_job( packages_install => { repo => 'Test-Org/one', packages => ['libmagic-dev'] } );
    is( \@installed,                                                                 [ [ '/bogus/clod-install-packages', undef, 'libmagic-dev' ] ],                                              'an install runs the installer with the names of the job, and no other, and no file of sources when it adds none' );
    is( [ $install->@{qw{state result}} ],                                           [ 'finished', { repo => 'Test-Org/one', packages => ['libmagic-dev'], sources => [], output => $output } ], 'and records what it printed' );
    is( $minion->jobs( { tasks => ['self_check'], states => ['inactive'] } )->total, 1,                                                                                                          'and queues a check, so that the item clears' );

    @installed = ();
    my $with = run_job( packages_install => { repo => 'Test-Org/one', packages => ['jellyfin-ffmpeg'], sources => [ \%jellyfin ] } );
    my $file = $tmp->child( 'workspace', 'work', $with->{id}, 'sources.jsonl' );
    is( \@installed,              [ [ '/bogus/clod-install-packages', "$file", 'jellyfin-ffmpeg' ] ], 'with sources, the installer gets a file of them in the directory of the job' );
    is( \@lines,                  [ \%jellyfin ],                                                     'one JSON object on each line' );
    is( $with->{result}{sources}, ['jellyfin'],                                                       'the job names the archives that it added' );
    ok( !-e $file->dirname, 'and the directory is gone afterwards' );

    $minion->reset( { all => 1 } );
    $packages->redefine( install => sub ( $installer, $file, @names ) { die "sudo -n /bogus/clod-install-packages libmagic-dev: E: Unable to locate package\n" } );
    my $failed = run_job( packages_install => { repo => 'Test-Org/one', packages => ['libmagic-dev'] } );
    is( $failed->{state}, 'failed', 'an installer that fails fails the job' );
    like( $failed->{result}{error}, qr/Unable\ to\ locate\ package/, 'with what it printed' );
    is( $minion->jobs( { tasks => ['self_check'], states => ['inactive'] } )->total,        1,        'and still queues a check, for what it installed before it failed' );
    is( run_job( packages_install => { repo => 'Test-Org/one', packages => [] } )->{state}, 'failed', 'and a job with no package runs no installer' );

    delete $config->{system_packages};
    is( run_job( packages_install => { repo => 'Test-Org/one', packages => ['libmagic-dev'] } )->{result}{error}, 'clod.conf has no system_packages', 'without the configuration, an install fails, and says why' );
    $minion->reset( { all => 1 } );
};

subtest assigned_sweep => sub {
    %state = ();
    my $info = run_job('assigned_sweep');
    is( scalar @{ $info->{result}{issues} }, 2,              'the assigned issues of each spoke are listed' );
    is( $info->{result}{issues}[0]{repo},    'Test-Org/one', 'with their repo' );
};

subtest activity_sweep => sub {
    %state = ();
    my $item = sub ( $repo, $number ) { return { number => $number, repository_url => "https://api.test.test/repos/$repo" } };
    $state{search_kinds} = { unassigned => 'is:issue is:open no:assignee', opened => 'is:issue created:>=', merged => 'is:pr is:merged merged:>=' };
    $state{found}        = {
        unassigned => [ $item->( 'Test-Org/one', 1 ), $item->( 'Test-Org/two', 2 ), $item->( 'Test-Org/private', 3 ) ],
        opened     => [ $item->( 'Test-Org/one', 1 ) ],
        merged     => [ $item->( 'Test-Org/one', 4 ), $item->( 'Test-Org/two', 9 ) ],
    };
    my $swept = run_job('activity_sweep')->{result};
    is( [ @{$swept}{qw{unassigned opened_7d merged_7d}} ], [ 2, 1, 2 ], 'each count is over the spokes, and not over another repository of the owner' );
    is( $swept->{errors},                                  {},          'and nothing failed' );
    ok( $swept->{checked_at}, 'with the time of the check' );
    is( scalar @{ $state{searches} }, 3, 'one search for each count, and not one for each spoke, because GitHub allows 30 searches a minute' );
    my $window = qr{\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ};
    is(
        [ sort @{ $state{searches} } ],
        [ map { match($_) } qr{\Auser:Test-Org\ is:issue\ created:>=$window\z}, qr{\Auser:Test-Org\ is:issue\ is:open\ no:assignee\z}, qr{\Auser:Test-Org\ is:pr\ is:merged\ merged:>=$window\z} ],
        'each search names the owner, and the 7 day window where it has one'
    );

    $state{search_fail}{'Test-Org'} = 1;
    my $failed = run_job('activity_sweep')->{result};
    like( $failed->{errors}{'Test-Org'}, qr/403/, 'an owner whose search fails is recorded' );
    is( [ @{$failed}{qw{unassigned opened_7d merged_7d}} ], [ 0, 0, 0 ], 'and adds nothing' );
    ok( App::Clod::Tasks::last_result( $minion, 'activity_sweep' ), 'the last result is there for the dashboard' );
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

    my $configured = $config->{spokes};
    $config->{spokes} = [ @SPOKES, 'Test-Org/hidden' ];
    my $private = run_job('spoke_sweep');
    like( $private->{result}{dropped}, { 'Test-Org/hidden' => qr/private/ }, 'a configured repository that is not public is dropped, with the reason' );
    is( [ keys %{ $private->{result}{dropped} } ],    ['Test-Org/hidden'], 'and the public ones are not' );
    is( App::Clod::Tasks::spokes( $minion, $config ), \@SPOKES,            'it is not a spoke, even without spoke_orgs' );
    ok( !App::Clod::Tasks::is_spoke( $minion, $config, 'Test-Org/hidden' ), 'and is_spoke says no' );
    ok( App::Clod::Tasks::is_spoke( $minion,  $config, 'Test-Org/one' ),    'while a public configured one stays' );

    $state{absent}{'Test-Org/hidden'} = 1;
    my $lookup_failed = run_job('spoke_sweep');
    is( [ keys %{ $lookup_failed->{result}{dropped} } ], ['Test-Org/hidden'], 'a lookup that fails keeps the verdict of the sweep before' );
    $minion->reset( { all => 1 } );
    my $unknown = run_job('spoke_sweep');
    is( $unknown->{result}{dropped}, {}, 'and a 404 with no verdict before leaves the repository a spoke' );
    $config->{spokes} = $configured;
    %state = ();
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
    $state{events}        = [ { event => 'assigned', assignee => { login => $BOT }, actor => { login => $BOT }, assigner => { login => 'trusted' } } ];
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
