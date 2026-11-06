#!/usr/bin/env perl
use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use FindBin::libs;
use Capture::Tiny    qw{capture_stdout};
use File::Temp       ();
use Mojo::File       ();
use Mojo::Util       ();
use Test::MockModule ();

use App::Clod();

my $tmp = File::Temp->newdir;

# The app, with a clod.conf that has these keys too.
sub app_with (%more) {
    my $conf = Mojo::File->new( "$tmp", 'clod.conf' );
    $conf->spew( Mojo::Util::dumper( { bot => 'test-bot', workspace => "$tmp/ws", spokes => ['Test-Org/one'], auth => { trusted_header => 'X-Test-User' }, %more } ) );
    local $ENV{CLOD_CONFIG} = "$conf";
    my $app = App::Clod->new;
    $app->log->level('fatal');
    return $app;
}

my @did;
my $deps = Test::MockModule->new('App::Clod::Deps');
$deps->redefine( listdeps         => sub ($dir) { return qw{Foo Bar} } );
$deps->redefine( install          => sub ( $lib, @modules ) { push @did, "install $lib @modules"; return } );
$deps->redefine( install_programs => sub ($lib) { push @did, "programs $lib";                     return } );
$deps->redefine( outdated         => sub ($lib) { return [ { module => 'Foo', version => '1', latest => '2' } ] } );
$deps->redefine( upgrade          => sub ($lib) { push @did, "upgrade $lib"; return [ { module => 'Foo', version => '1', latest => '2' } ] } );

subtest 'clod deps' => sub {
    my $app = app_with( local_lib => '/bogus/perl5' );
    $app->commands->run(qw{deps install});
    is( \@did, ['install /bogus/perl5 Foo Bar'], 'install installs what the checkout needs into the local lib' );

    is( capture_stdout { $app->commands->run(qw{deps outdated}) }, "Foo\t1\t2\n", 'outdated prints each module with a newer release, and its versions' );
    @did = ();
    is( capture_stdout { $app->commands->run(qw{deps upgrade}) }, "Foo\t1\t2\n",            'upgrade prints what it upgraded' );
    is( \@did,                                                    ['upgrade /bogus/perl5'], 'in the local lib' );

    my $tasks = Test::MockModule->new('App::Clod::Tasks');
    $tasks->redefine( agent_tools => sub ($config) { return qw{Perl::Critic Perl::Tidy} } );
    @did = ();
    app_with( local_lib => '/bogus/perl5', agent_lib => '/bogus/agent-perl5' )->commands->run(qw{deps install});
    is( \@did, [ 'install /bogus/perl5 Foo Bar', 'install /bogus/agent-perl5 Perl::Critic Perl::Tidy', 'programs /bogus/agent-perl5' ], 'with an agent lib, install fills it with the tools and the programs of the agent too' );
    @did = ();
    app_with( agent_lib => '/bogus/agent-perl5' )->commands->run(qw{deps install});
    is( \@did, [ 'install /bogus/agent-perl5 Perl::Critic Perl::Tidy', 'programs /bogus/agent-perl5' ], 'and with an agent lib alone, only it' );

    like( dies { $app->commands->run(qw{deps sideways}) },       qr/\AUsage:\ clod\ deps/,                     'anything else prints the usage' );
    like( dies { app_with()->commands->run(qw{deps outdated}) }, qr/names\ no\ local_lib\ and\ no\ agent_lib/, 'and with neither lib, it says so' );
};

done_testing;
