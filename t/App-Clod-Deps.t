#!/usr/bin/env perl
use 5.040;
no autovivification;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use FindBin::libs;
use Config     ();
use File::Temp ();
use Mojo::File ();

use App::Clod();
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

subtest install_needed => sub {
    my $lib     = $tmp->child('own-lib');
    my $already = $lib->child(qw{lib perl5 Already})->make_path;
    $already->child('There.pm')->spew("package Already::There;\n1;\n");
    local @App::Clod::Deps::DZIL = fake( 'dzil', "Mojolicious\nAlready::There\nNot::Installed::Anywhere\nperl\n" );

    is( [ App::Clod::Deps::install_needed( $lib, $checkout ) ], [], 'a checkout with no dist.ini needs nothing' );
    is( logged('dzil'),                                         [], 'and asks dzil nothing' );

    $checkout->child('dist.ini')->spew("name = Bogus\n");
    is( [ App::Clod::Deps::install_needed( $lib, $checkout ) ], ['Not::Installed::Anywhere'], 'with one, a module that neither the lib nor @INC has is installed' );
    like( logged('cpm'), [qr{\ -L\ \Q$lib\E\ Not::Installed::Anywhere\z}], 'into the lib, alone' );
    ok( -e "$lib.lock", 'under the lock that clod-cpm takes' );
    logged('dzil');

    local @App::Clod::Deps::DZIL = fake( 'dzil', "Mojolicious\nAlready::There\n" );
    is( [ App::Clod::Deps::install_needed( $lib, $checkout ) ], [], 'and with everything there, nothing is' );
    is( logged('cpm'),                                          [], 'and cpm does not run' );
    logged('dzil');
    $checkout->child('dist.ini')->remove;
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
    like( dies { App::Clod::Deps::policies("[Variables::RequireNoAutovivification\n") }, qr/\AA\ critic\ profile\ does\ not\ parse:\ /, 'and a profile that does not parse dies, and says so' );
};

subtest missing => sub {
    my $lib = $tmp->child('agent-lib');
    my $dir = $lib->child(qw{lib perl5 Perl Critic})->make_path;
    $dir->child('Policy.pm')->spew("1;\n");
    my $arch = $lib->child( qw{lib perl5}, $Config::Config{archname}, 'Devel' )->make_path;
    $arch->child('NYTProf.pm')->spew("1;\n");
    is( [ App::Clod::Deps::missing( "$lib", qw{Perl::Critic::Policy Devel::NYTProf Perl::Tidy} ) ], ['Perl::Tidy'], 'what the lib has no file of, where a module with C code is in the directory of the architecture' );
};

subtest install_programs => sub {
    my $lib = $tmp->child('programs-lib');
    is( [ App::Clod::Deps::stale_programs("$lib") ], [qw{clod-cpm clod-skill-edits}], 'an agent lib without the programs lacks each of them' );
    App::Clod::Deps::install_programs("$lib");
    is( [ App::Clod::Deps::stale_programs("$lib") ], [], 'and has them once they are installed' );
    my $cpm = $lib->child(qw{bin clod-cpm});
    is( sprintf( '%04o', $cpm->stat->mode & oct '7777' ), '0750', 'clod-cpm goes into the bin of the agent lib, for its group to run and not to change' );
    $cpm->spew("#!/bin/sh\n");
    is( [ App::Clod::Deps::stale_programs("$lib") ], ['clod-cpm'], 'and lacks one again when it is another version' );
    App::Clod::Deps::install_programs("$lib");

    # A cpm that prints what it was asked, on the PATH of clod-cpm.
    my $fake = $tmp->child('fake-cpm')->make_path;
    $fake->child('cpm')->spew(qq{#!/bin/sh\nprintf '%s ' "\$@"\n})->chmod( oct '0755' );
    my $own = $tmp->child('own-lib');
    my @env = ( qw{/usr/bin/env -u CLOD_OWN_LIB}, "PATH=$fake:$ENV{PATH}" );
    IPC::Run::run( [ @env, "CLOD_OWN_LIB=$own", "$cpm", 'Test::Module' ], \undef, \my $out, \my $err );
    is( [ $out, -d $own ], [ "install --without-test -L $own Test::Module ", 1 ], 'which makes the own lib, and installs into it' ) or diag $err;
    ok( !IPC::Run::run( [ @env, "$cpm", 'Test::Module' ], \undef, \my $none, \my $why ), 'and refuses with no own lib to install into' );
    like( $why, qr/names\ no\ own\ lib/, 'and says so' );
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

    my @say = ( '/bin/sh', '-c', 'echo "out $CLOD_TEST_ENV"; echo err >&2; exit "$1"', 'sh' );
    local $ENV{CLOD_TEST_ENV} = 'inherited';
    is( App::Clod::Deps::run( { merge => 1 }, @say, 0 ), "out inherited\nerr\n", 'with merge, the output has its standard error too' );
    like( dies { App::Clod::Deps::run( { merge => 1 }, @say, 3 ) }, qr{:\ out\ inherited\nerr\n}, 'and so does the error when it fails' );
    is( App::Clod::Deps::run( { env   => { PATH => $ENV{PATH} } }, @say, 0 ), "out \n",          'with env, it runs with that environment, and no other' );
    is( App::Clod::Deps::run( { exits => [ 0, 2 ] },               @say, 2 ), "out inherited\n", 'with exits, a status among them is success' );
    like( dies { App::Clod::Deps::run( { exits => [ 0, 2 ] }, @say, 1 ) }, qr{\ 1:\ err\n}, 'and one that is not still fails' );
    like( dies { App::Clod::Deps::run( { timeout => 1 }, '/bin/sh', '-c', 'sleep 10' ) }, qr{sleep\ 10:\ .*timeout}i, 'and a command that runs longer than the timeout fails' );
};

done_testing;
