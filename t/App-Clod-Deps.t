#!/usr/bin/env perl
use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use FindBin::libs;
use File::Temp ();
use Mojo::File ();

use App::Clod::Deps();

my $tmp = Mojo::File->new( File::Temp->newdir( CLEANUP => 1 )->dirname )->child("clod-deps-$$")->make_path;
END { $tmp->remove_tree if $tmp }

# A stand-in for a program: it appends its directory and arguments to a log,
# and prints $out.
sub fake ( $name, $out, $exit = 0 ) {
    my $bin = $tmp->child($name);
    $bin->spew(qq{#!/bin/sh\necho "\$(pwd) \$*" >> '$tmp/$name.log'\nprintf '%s' '$out'\nexit $exit\n});
    chmod 0755, "$bin" or die "chmod $bin: $!";
    return "$bin";
}

sub logged ($name) {
    my $log = $tmp->child("$name.log");
    return [] if !-e $log;
    my @lines = split m{\n}, $log->slurp;
    $log->remove;
    return \@lines;
}

my $checkout = $tmp->child('checkout')->make_path;
local @App::Clod::Deps::DZIL     = fake( 'dzil',          "Mojolicious\nperl\nTry::Tiny\n" );
local @App::Clod::Deps::CPM      = fake( 'cpm',           q{} );
local @App::Clod::Deps::OUTDATED = fake( 'cpan-outdated', "Try::Tiny                      0.30    0.32    E/ET/ETHER/Try-Tiny-0.32.tar.gz\n" );

subtest listdeps => sub {
    is( [ App::Clod::Deps::listdeps($checkout) ], [qw{Mojolicious Try::Tiny}], 'the modules that dzil lists, without perl' );
    is( logged('dzil'),                           ["$checkout listdeps"],      'which it asks in the checkout' );
};

subtest install => sub {
    App::Clod::Deps::install( '/bogus/lib', qw{Mojolicious Try::Tiny} );
    my $cpm = logged('cpm');
    is( scalar @$cpm, 1, 'one cpm' );
    like( $cpm->[0], qr{\ install\ --without-test\ },                'installs them with no tests' );
    like( $cpm->[0], qr{\ -L\ /bogus/lib\ Mojolicious\ Try::Tiny\z}, 'into the local lib' );
    App::Clod::Deps::install('/bogus/lib');
    is( logged('cpm'), [], 'and no module runs no cpm' );
};

subtest outdated => sub {
    is( App::Clod::Deps::outdated('/bogus/lib'), [ { module => 'Try::Tiny', version => '0.30', latest => '0.32', dist => 'E/ET/ETHER/Try-Tiny-0.32.tar.gz' } ], 'each line of cpan-outdated, as a hash' );
    like( logged('cpan-outdated')->[0], qr{\ -L\ /bogus/lib\ --exclude-core\ --verbose\z}, 'about the local lib, without the core of the perl' );
};

subtest upgrade => sub {
    is( [ map { $_->{module} } @{ App::Clod::Deps::upgrade('/bogus/lib') } ], ['Try::Tiny'], 'an upgrade says what it found' );
    like( logged('cpm')->[0], qr{\ -L\ /bogus/lib\ Try::Tiny~0\.32\z}, 'and installs its newest release' );
    logged('cpan-outdated');

    local @App::Clod::Deps::OUTDATED = fake( 'cpan-outdated', q{} );
    is( App::Clod::Deps::upgrade('/bogus/lib'), [], 'with nothing outdated, it finds nothing' );
    is( logged('cpm'),                          [], 'and installs nothing' );
};

subtest policies => sub {
    my $profile = "severity = 1\n\n[Variables::RequireNoAutovivification]\n\n[ProhibitPipeOpen]\nmax = 1\n\n[-Subroutines::ProhibitExplicitReturnUndef]\n";
    is(
        [ App::Clod::Deps::policies( $profile, "[ProhibitPipeOpen]\n" ) ],
        [qw{Perl::Critic::Policy::ProhibitPipeOpen Perl::Critic::Policy::Variables::RequireNoAutovivification}],
        'each policy that a profile turns on, a short name too, once each, and none that it turns off'
    );
};

subtest missing => sub {
    my $lib = $tmp->child('agent-lib');
    my $dir = $lib->child(qw{lib perl5 Perl Critic})->make_path;
    $dir->child('Policy.pm')->spew("1;\n");
    is( [ App::Clod::Deps::missing( "$lib", qw{Perl::Critic::Policy Perl::Tidy} ) ], ['Perl::Tidy'], 'what the lib has no file of' );
};

subtest 'install, readable by its group and no more' => sub {
    my $lib  = $tmp->child('umask-lib');
    my $made = $tmp->child('cpm-made');
    local @App::Clod::Deps::CPM = ( '/bin/sh', '-c', qq{touch '$made'; mkdir -p '$made.d'}, 'cpm' );
    my $worker = oct '0007';
    my $before = umask $worker;
    App::Clod::Deps::install( "$lib", 'Foo' );
    is( umask, $worker, 'it puts back the umask of the worker' );
    umask $before;
    my $perms = oct '7777';
    is( sprintf( '%04o', ( stat $made )[2] & $perms ),     '0640', 'what it installs, the group may read and not change' );
    is( sprintf( '%04o', ( stat "$made.d" )[2] & $perms ), '0750', 'and enter, in a directory' );
};

subtest run => sub {
    local @App::Clod::Deps::CPM = fake( 'cpm', q{}, 1 );
    my $error = dies { App::Clod::Deps::install( '/bogus/lib', 'Foo' ) };
    like( $error, qr{/cpm\ install\ },    'a program that fails dies, and names the command' );
    like( $error, qr{\ Foo:\ failed\n\z}, 'with its arguments, on one line' );
};

done_testing;
