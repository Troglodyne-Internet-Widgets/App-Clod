#!/usr/bin/env perl
use 5.040;
no autovivification;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use FindBin::libs;
use File::Temp ();
use Mojo::File ();

use App::Clod::Packages();

my $dir = File::Temp->newdir;
my $tmp = Mojo::File->new("$dir");

sub script ( $name, $body ) {
    my $bin = $tmp->child($name);
    $bin->spew("#!/bin/sh\n$body");
    $bin->chmod( oct '0755' );
    return "$bin";
}

# dpkg-query as it answers: the status of a package that it knows, and an
# error and exit 1 for one that it does not.
local @App::Clod::Packages::DPKG_QUERY = script( 'dpkg-query', <<~'SH' );
    echo "$*" >> "$0.log"
    case "$4" in
      ffmpeg) printf 'install ok installed' ;;
      gone)   printf 'deinstall ok config-files' ;;
      *)      echo "dpkg-query: no packages found matching $4" >&2; exit 1 ;;
    esac
    SH

subtest installed => sub {
    ok( App::Clod::Packages::installed( deb  => 'ffmpeg' ),       'a package with the status install ok installed is installed' );
    ok( !App::Clod::Packages::installed( deb => 'gone' ),         'one that was removed is not' );
    ok( !App::Clod::Packages::installed( deb => 'libmagic-dev' ), 'and neither is one that dpkg does not know' );
    like( $tmp->child('dpkg-query.log')->slurp,                       qr/\A-W\ -f\ \$\{Status\}\ ffmpeg\n/,           'dpkg is asked for the status of the one package' );
    like( dies { App::Clod::Packages::installed( rpm => 'ffmpeg' ) }, qr/no\ way\ to\ ask\ whether\ a\ rpm\ package/, 'a packager that it cannot ask about dies' );
};

subtest program_error => sub {
    is( App::Clod::Packages::program_error('true'), undef, 'a program that exits 0 runs' );
    my $says = script( 'says', 'echo "token=$GH_TOKEN args=$*"; exit 4' . "\n" );
    local $ENV{GH_TOKEN} = 'test-token';
    is( App::Clod::Packages::program_error(qq{$says -version 'two words'}), "token= args=-version two words", 'one that fails says what it printed, with its words split as a shell does, and no token of the bot' );
    like( App::Clod::Packages::program_error('/bogus/no-such-program -version'), qr/no-such-program/, 'and one that is not there says so' );
    is( App::Clod::Packages::program_error(q{ }), 'it is not a command line', 'a line with no word is not a command' );
    local $App::Clod::Packages::PROGRAM_SECONDS = 1;
    like( App::Clod::Packages::program_error( script( 'hangs', "sleep 10\n" ) ), qr/timeout/i, 'and one that runs too long fails' );
};

subtest install => sub {
    is( \@App::Clod::Packages::SUDO, [qw{sudo -n}], 'the installer runs with sudo, which must not ask for a password' );
    local @App::Clod::Packages::SUDO = ();
    my $installer = script( 'installer', <<~'SH' );
        echo "installing $*"
        echo "a warning" >&2
        [ "$1" = bad ] && exit 2
        exit 0
        SH
    is( App::Clod::Packages::install( $installer, qw{ffmpeg libmagic-dev} ), "installing ffmpeg libmagic-dev\na warning\n", 'the installer gets the names, and what it printed comes back, its errors too' );
    like( dies { App::Clod::Packages::install( $installer, 'bad' ) }, qr/installing\ bad\na\ warning\n/, 'an installer that fails dies with what it printed' );
};

done_testing;
