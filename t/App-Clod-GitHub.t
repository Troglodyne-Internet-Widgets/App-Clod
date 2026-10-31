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
get '/repos/Test-Org/one' => sub ($c) { return $c->render( json => { message => 'Bad credentials' }, status => 401 ) };

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

subtest request => sub {
    like( dies { $gh->repo('Test-Org/one') }, qr{GitHub\ GET\ /repos/Test-Org/one:\ 401\ Bad\ credentials}, 'an error status dies with the status and the message' );

    my $refused = dies { $gh->repo('Test-Org/one') };
    my $missing = dies { $gh->get('/repos/Test-Org/one/contents/missing.txt') };
    ok( App::Clod::GitHub::is_unauthorized($refused),  'a 401 is a refused token' );
    ok( !App::Clod::GitHub::is_unauthorized($missing), 'a 404 is not' ) or diag $missing;

    my $nowhere = App::Clod::GitHub->new( token => 'test-token', api => 'http://127.0.0.1:1', timeout => 2 );
    my $silent  = dies { $nowhere->repo('Test-Org/one') };
    like( $silent, qr{no\ response}, 'no answer at all dies differently from an error status' );
    ok( !App::Clod::GitHub::is_unauthorized($silent), 'and is not a refused token' );
    local $ENV{GH_TOKEN};
    like( dies { App::Clod::GitHub->new->token }, qr{GH_TOKEN\ is\ not\ set}, 'no token dies when it is first needed' );
};

done_testing;
