#!/usr/bin/env perl
use 5.040;
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

use App::Clod();

my $tmp = File::Temp->newdir;

my $CONFIGS = 0;

sub app_with ($auth) {
    my $conf = Mojo::File->new( "$tmp", 'clod-' . ++$CONFIGS . '.conf' );
    $conf->spew( Mojo::Util::dumper( { bot => 'test-bot', workspace => "$tmp/ws", spokes => ['Test-Org/one'], auth => $auth } ) );
    local $ENV{CLOD_CONFIG} = "$conf";
    my $t = Test::Mojo->new('App::Clod');
    $t->app->log->level('fatal');
    return $t;
}

subtest share_dir => sub {
    ok( -e App::Clod::share_dir()->child( 'prompts', 'triage.md' ), 'the share directory of the checkout is found' );
};

subtest 'startup, with basic auth' => sub {
    my $t = app_with( { user => 'tester', password_sha256 => Digest::SHA::sha256_hex('secret') } );
    $t->get_ok('/')->status_is(401)->header_like( 'WWW-Authenticate' => qr/Basic/, 'no credentials, no page' );
    $t->get_ok('//tester:wrong@/')->status_is( 401, 'a wrong password, no page' );
    $t->get_ok('//nobody:secret@/')->status_is( 401, 'a wrong user, no page' );
    $t->get_ok('//tester:secret@/')->status_is(200)->text_is( 'title' => 'Clod', 'the right credentials get the page' );
    $t->get_ok('//tester:secret@/')->element_exists( 'button[data-bs-target="#harness"]', 'with the harness tab' );
    $t->get_ok('/api/overview')->status_is( 401, 'the JSON is behind the same check' );
    $t->get_ok('/minion')->status_is( 401, 'and so is Minion::Admin' );
    $t->get_ok('//tester:secret@/minion')->status_is( 200, 'which the right credentials reach' );

    my $backend = $t->app->minion->backend;
    ok( $backend->list_schedules( 0, 10 )->{total} >= 3, 'startup creates the schedules' );
};

subtest 'startup, with a trusted header' => sub {
    my $t = app_with( { trusted_header => 'X-Test-User' } );
    $t->get_ok('/')->status_is( 401, 'no header, no page' );
    $t->get_ok( '/' => { 'X-Test-User' => q{} } )->status_is( 401, 'an empty header, no page' );
    $t->get_ok( '/' => { 'X-Test-User' => 'someone' } )->status_is( 200, 'the header gets the page' );
};

done_testing;
