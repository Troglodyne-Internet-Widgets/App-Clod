#!/usr/bin/env perl
use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use FindBin::libs;

use App::Clod::Config();

my %minimal = (
    bot       => 'test-bot',
    workspace => '/bogus/workspace',
    spokes    => ['Test-Org/one'],
    auth      => { trusted_header => 'X-Remote-User' },
);

subtest validate => sub {
    my $config = App::Clod::Config::validate( {%minimal} );
    is( $config->{minion},      'sqlite:/bogus/workspace/minion.db', 'the Minion database defaults to the workspace' );
    is( $config->{bot_email},   'test-bot@users.noreply.github.com', 'the commit address defaults to the no-reply one' );
    is( $config->{claude}{bin}, 'claude',                            'the claude section gets its defaults' );

    my $merged = App::Clod::Config::validate( { %minimal, claude => { model => 'test-model' } } );
    is( $merged->{claude}{model}, 'test-model', 'a section key from the file is kept' );
    ok( scalar @{ $merged->{claude}{allowed_tools} }, 'and the rest of that section still has its defaults' );

    like( dies { App::Clod::Config::validate( [] ) }, qr/must\ be\ a\ hash/, 'a configuration that is not a hash dies' );
    for my $key (qw{bot workspace auth}) {
        my %without = %minimal;
        delete $without{$key};
        like( dies { App::Clod::Config::validate( \%without ) }, qr/no\ value\ for:\ $key/, "a configuration without $key dies" );
    }
    like( dies { App::Clod::Config::validate( { %minimal, spokes => [] } ) }, qr/names\ no\ spokes\ and\ no\ spoke_orgs/, 'no spokes and no organizations dies' );
    ok( lives { App::Clod::Config::validate( { %minimal, spokes => [], spoke_orgs => ['Test-Org'] } ) }, 'an organization alone lives' );
    like( dies { App::Clod::Config::validate( { %minimal, spoke_orgs => ['Test-Org/one'] } ) }, qr/must\ be\ a\ login/,    'an organization that is a repository dies' );
    like( dies { App::Clod::Config::validate( { %minimal, spokes     => ['nope'] } ) },         qr/must\ be\ Owner\/Name/, 'a spoke that is not Owner/Name dies' );
    like( dies { App::Clod::Config::validate( { %minimal, spokes     => 'Test-Org/one' } ) },   qr/must\ be\ a\ list/,     'spokes that are not a list die' );
    like( dies { App::Clod::Config::validate( { %minimal, auth       => { user => 'u' } } ) },  qr/auth\ needs/,           'basic auth without a password hash dies' );
    ok( lives { App::Clod::Config::validate( { %minimal, auth => { user => 'u', password_sha256 => 'x' } } ) }, 'basic auth with both parts lives' );
};

done_testing;
