#!/usr/bin/env perl
use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use FindBin::libs;
use Mojolicious::Lite -signatures;

use App::Clod::GitHub();

# A fake of the GitHub API, served in this process.
my %seen;
app->log->level('fatal');
under sub ($c) { $seen{auth} = $c->req->headers->authorization; 1 };
get '/notifications' => sub ($c) {
    if ( ( $c->req->headers->if_modified_since // q{} ) eq 'then' ) {
        return $c->rendered(304);
    }
    my $headers = $c->res->headers;
    $headers->header( 'X-Poll-Interval' => 90 );
    $headers->header( 'Last-Modified'   => 'now' );
    $headers->header( 'X-OAuth-Scopes'  => 'repo, notifications' );
    my $page = $c->param('page') // 1;
    $c->res->headers->link( '<' . $c->url_for('/notifications')->to_abs->query( page => 2 ) . '>; rel="next"' ) if $page == 1;
    return $c->render( json => [ { id => "t$page" } ] );
};
get '/repos/Test-Org/one/contents/*file' => sub ($c) {
    return $c->render( json => { message => 'Not Found' }, status => 404 ) if $c->param('file') ne 'there.txt';
    $seen{accept} = $c->req->headers->accept;
    $seen{ref}    = $c->param('ref');
    return $c->render( text => 'raw content' );
};
get '/repos/Test-Org/one/git/trees/*ref' => sub ($c) {
    return $c->render( json => { tree => [ { path => 'a', sha => 'sha-a' }, { path => 'b/c', sha => 'sha-c' } ] } );
};
get '/repos/Test-Org/one/issues' => sub ($c) {
    $seen{issues} = $c->req->params->to_hash;
    return $c->render( json => [ { number => 1, created_at => '2026-01-03T00:00:00Z' }, { number => 2, created_at => '2026-01-01T00:00:00Z' }, { number => 3, created_at => '2026-01-03T00:00:00Z', pull_request => {} } ] );
};
get '/search/issues' => sub ($c) {
    $seen{q} = $c->param('q');
    return $c->render( json => { items => [ { number => 7 } ] } );
};
get '/repos/Test-Org/one' => sub ($c) { return $c->render( json => { message => 'Bad credentials' }, status => 401 ) };

# Answers each request with the next status of its queue, and then with 200.
my %flaky;
any '/flaky' => sub ($c) {
    $seen{flaky}{ $c->req->method }++;
    my $status = shift @{ $flaky{ $c->req->method } // [] } // 200;
    return $c->render( json => { message => "status $status" }, status => $status );
};

my $gh = App::Clod::GitHub->new( token => 'test-token' );
$gh->ua->server->app(app);
my $server = $gh->ua->server->url;
$gh->api( $server->to_string =~ s{/\z}{}r );

subtest notifications => sub {
    my ( $threads, $meta ) = $gh->notifications;
    is( [ map { $_->{id} } @$threads ], [qw{t1 t2}],                                                                      'every page of threads comes back' );
    is( $meta,                          { last_modified => 'now', poll_interval => 90, scopes => 'repo, notifications' }, 'with the polling and scope headers' );
    is( $seen{auth},                    'Bearer test-token',                                                              'the token goes as a bearer token' );
    my ($none) = $gh->notifications('then');
    is( $none, [], 'a 304 gives no threads, and does not die' );
};

subtest file => sub {
    is( $gh->file(qw{Test-Org/one there.txt main}), 'raw content',                     'a file comes back raw' );
    is( $seen{accept},                              'application/vnd.github.raw+json', 'because it asks for raw' );
    is( $seen{ref},                                 'main',                            'at the ref it was given' );
    is( $gh->file( 'Test-Org/one', 'missing.txt' ), undef,                             'a missing file is undef, not an error' );
};

subtest tree => sub {
    my $tree = $gh->tree( 'Test-Org/one', 'main' );
    is( [ sort keys %$tree ], [ 'a', 'b/c' ], 'the tree is keyed by path' );
    is( $tree->{'b/c'}{sha},  'sha-c',        'and keeps each blob SHA' );
};

subtest 'issues and pull requests' => sub {
    my $unassigned = $gh->unassigned_issues('Test-Org/one');
    is( [ map { $_->{number} } @$unassigned ], [ 1, 2 ],                                                 'an item with a pull_request is no unassigned issue' );
    is( $seen{issues},                         { assignee => 'none', state => 'open', per_page => 100 }, 'and the list asked for open issues with no assignee' );

    my $opened = $gh->opened_issues( 'Test-Org/one', '2026-01-02T00:00:00Z' );
    is( [ map { $_->{number} } @$opened ], [1],                    'an issue created before the time is not opened since, though it was updated since' );
    is( $seen{issues}{since},              '2026-01-02T00:00:00Z', 'the time goes as since' );

    my $merged = $gh->merged_pulls( 'Test-Org/one', '2026-01-02T00:00:00Z' );
    is( [ map { $_->{number} } @$merged ], [7],                                                               'merged pull requests come from the items of the search' );
    is( $seen{q},                          'repo:Test-Org/one is:pr is:merged merged:>=2026-01-02T00:00:00Z', 'with the repository and the time in the query' );
};

subtest request => sub {
    is( dies { $gh->repo('Test-Org/one') }, "GitHub GET /repos/Test-Org/one: 401 Bad credentials\n", 'an error status dies with the status and the message, and no file or line' );

    my $refused = dies { $gh->repo('Test-Org/one') };
    my $missing = dies { $gh->get('/repos/Test-Org/one/contents/missing.txt') };
    ok( App::Clod::GitHub::is_unauthorized($refused),  'a 401 is a refused token' );
    ok( !App::Clod::GitHub::is_unauthorized($missing), 'a 404 is not' ) or diag $missing;

    local @App::Clod::Retry::DELAYS = ( 0, 0, 0 );
    my $nowhere = App::Clod::GitHub->new( token => 'test-token', api => 'http://127.0.0.1:1', timeout => 2 );
    my $silent;
    my $tries = warnings {
        $silent = dies { $nowhere->repo('Test-Org/one') }
    };
    is( scalar @$tries, 3,                                                                                     'a GET with no answer at all is tried four times' );
    is( $silent,        "GitHub GET http://127.0.0.1:1/repos/Test-Org/one: no response: Connection refused\n", 'no answer at all dies differently from an error status, and no file or line' );
    ok( !App::Clod::GitHub::is_unauthorized($silent), 'and is not a refused token' );
    local $ENV{GH_TOKEN};
    like( dies { App::Clod::GitHub->new->token }, qr{GH_TOKEN\ is\ not\ set}, 'no token dies when it is first needed' );
};

subtest 'when GitHub fails for a moment' => sub {
    local @App::Clod::Retry::DELAYS = ( 0, 0, 0 );
    my $try = sub ( $method, @statuses ) {
        %flaky = ( $method => [@statuses] );
        delete $seen{flaky};
        my $answer;
        my $said = warnings {
            $answer = eval { $gh->request( $method => '/flaky', json => {} )->code } // $@
        };
        return ( $answer, $seen{flaky}{$method}, scalar @$said );
    };

    is( [ $try->( GET => 500, 502 ) ], [ 200, 3, 2 ], 'a GET is tried again after any server error, and says so each time' );
    is( [ $try->( POST => 502, 503, 504 ) ], [ 200, 4, 3 ], 'a POST is tried again after an error of the proxy in front of GitHub' );
    my ( $error, $count ) = $try->( POST => 500 );
    is( [ $error, $count ], [ "GitHub POST /flaky: 500 status 500\n", 1 ], 'but not after a 500, which GitHub can answer to a POST that it did' );
    is( [ ( $try->( GET => 404 ) )[ 0, 1 ] ],                [ "GitHub GET /flaky: 404 status 404\n", 1 ], 'and an error that is no server error gets no second try' );
    is( [ ( $try->( GET => 503, 503, 503, 503 ) )[ 0, 1 ] ], [ "GitHub GET /flaky: 503 status 503\n", 4 ], 'after four tries, it dies with the last error' );
};

done_testing;
