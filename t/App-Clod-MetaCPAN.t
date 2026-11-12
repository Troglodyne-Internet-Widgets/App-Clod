#!/usr/bin/env perl
use 5.040;
no autovivification;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use FindBin::libs;
use Mojolicious::Lite -signatures;

use App::Clod::MetaCPAN();

# A fake of the MetaCPAN API, served in this process.
my %seen;
app->log->level('fatal');
get '/release/versions/:dist' => sub ($c) {
    $seen{dist} = $c->param('dist');
    return $c->render( json => { message  => 'Internal Server Error' }, status => 500 ) if $c->param('dist') eq 'Broken-Dist';
    return $c->render( json => { releases => [], total => 0 } ) if $c->param('dist') eq 'Never-Released';
    return $c->render( json => { releases => [ { name => 'Test-Dist-0.002', version => '0.002', status => 'latest' }, { name => 'Test-Dist-0.001', version => '0.001', status => 'backpan' } ], total => 2 } );
};

my $cpan = App::Clod::MetaCPAN->new;
$cpan->ua->server->app(app);
my $server = $cpan->ua->server->url;
$cpan->api( $server->to_string =~ s{/\z}{}r );

subtest versions => sub {
    is( $cpan->versions('Test-Dist'),      [qw{0.002 0.001}], 'every version of the distribution, newest first, also the ones that left CPAN for BackPAN' );
    is( $seen{dist},                       'Test-Dist',       'asked by the name of the distribution' );
    is( $cpan->versions('Never-Released'), [],                'a distribution that MetaCPAN does not know has no version, and is no error' );
};

subtest errors => sub {
    is( dies { $cpan->versions('Broken-Dist') }, "MetaCPAN GET /release/versions/Broken-Dist: 500 Internal Server Error\n", 'an error status dies with the status and the message, and no file or line' );
    my $nowhere = App::Clod::MetaCPAN->new( api => 'http://127.0.0.1:1', timeout => 2 );
    is( dies { $nowhere->versions('Test-Dist') }, "MetaCPAN GET http://127.0.0.1:1/release/versions/Test-Dist: no response: Connection refused\n", 'no answer at all dies differently' );
};

done_testing;
