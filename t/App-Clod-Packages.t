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

use App::Clod::Claude();
use App::Clod::Packages();

my $here = Mojo::File->new(__FILE__)->dirname->to_abs;

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
    if [ "$1" = -S ]; then
      case "$2" in
        */ffmpeg)  echo "ffmpeg: $2" ;;
        */shared)  echo "libfoo:amd64, libbar: $2"; echo "libbaz: $2.d/other" ;;
        */diverts) echo "diversion by other from: $2"; echo "diversion by other to: $2.real"; echo "real: $2" ;;
        */broken)  echo "dpkg-query: error: parsing file '/var/lib/dpkg/status'" >&2; exit 2 ;;
        *)         echo "dpkg-query: no path found matching pattern $2" >&2; exit 1 ;;
      esac
      exit 0
    fi
    case "$4" in
      ffmpeg) printf 'install ok installed' ;;
      broken) echo "dpkg-query: error: parsing file '/var/lib/dpkg/status'" >&2; exit 2 ;;
      gone)   printf 'deinstall ok config-files' ;;
      *)      echo "dpkg-query: no packages found matching $4" >&2; exit 1 ;;
    esac
    SH

subtest installed => sub {
    ok( App::Clod::Packages::installed( deb  => 'ffmpeg' ),       'a package with the status install ok installed is installed' );
    ok( !App::Clod::Packages::installed( deb => 'gone' ),         'one that was removed is not' );
    ok( !App::Clod::Packages::installed( deb => 'libmagic-dev' ), 'and neither is one that dpkg does not know' );
    like( $tmp->child('dpkg-query.log')->slurp,                       qr/\A-W\ -f\ \$\{Status\}\ ffmpeg\n/, 'dpkg is asked for the status of the one package' );
    like( dies { App::Clod::Packages::installed( deb => 'broken' ) }, qr/parsing\ file/,                    'a dpkg that fails in another way dies, and says why, in place of saying that the package is not there' );
    local @App::Clod::Packages::DPKG_QUERY = ('/bogus/dpkg-query');
    like( dies { App::Clod::Packages::installed( deb => 'ffmpeg' ) }, qr{/bogus/dpkg-query},                          'and so does a dpkg-query that is not there' );
    like( dies { App::Clod::Packages::installed( rpm => 'ffmpeg' ) }, qr/no\ way\ to\ ask\ whether\ a\ rpm\ package/, 'a packager that it cannot ask about dies' );
};

subtest owners => sub {
    is( [ App::Clod::Packages::owners( deb => '/bogus/bin/ffmpeg' ) ],  ['ffmpeg'],          'the package that has the file' );
    is( [ App::Clod::Packages::owners( deb => '/bogus/bin/shared' ) ],  [qw{libfoo libbar}], 'each package that has it, without its architecture, and none that has another file' );
    is( [ App::Clod::Packages::owners( deb => '/bogus/bin/diverts' ) ], ['real'],            'and not the lines of a diversion' );
    is( [ App::Clod::Packages::owners( deb => '/bogus/bin/nobody' ) ],  [],                  'a file of no package has none' );
    like( $tmp->child('dpkg-query.log')->slurp, qr{^-S\ /bogus/bin/ffmpeg\n}m, 'dpkg is asked about the one file' );
    like( dies { App::Clod::Packages::owners( deb => '/bogus/bin/broken' ) }, qr/parsing\ file/,                         'a dpkg that fails in another way dies, and says why' );
    like( dies { App::Clod::Packages::owners( rpm => '/bogus/bin/ffmpeg' ) }, qr/no\ way\ to\ ask\ which\ rpm\ package/, 'and so does a packager that it cannot ask' );
};

my $worker = App::Clod::Claude->new;

subtest program_file => sub {
    my $first  = $tmp->child('path-one')->make_path;
    my $second = $tmp->child('path-two')->make_path;
    my $lib    = $tmp->child('agent-lib')->make_path;
    $lib->child('bin')->make_path;
    for my $bin ( $second->child('tool'), $second->child('later'), $lib->child( 'bin', 'tool' ) ) {
        $bin->spew("#!/bin/sh\n");
        $bin->chmod( oct '0755' );
    }
    $first->child('later')->spew("#!/bin/sh\n");
    symlink $second->child('tool')->to_string, $first->child('link')->to_string or die "symlink: $!";
    local $ENV{PATH} = "relative:$first:$second";
    is( App::Clod::Packages::program_file( $worker, 'tool' ),    $second->child('tool')->realpath->to_string,  'the executable file of the name on the PATH' );
    is( App::Clod::Packages::program_file( $worker, 'later' ),   $second->child('later')->realpath->to_string, 'a file that is not executable is passed over' );
    is( App::Clod::Packages::program_file( $worker, 'link' ),    $second->child('tool')->realpath->to_string,  'and a symbolic link is the file that it points to' );
    is( App::Clod::Packages::program_file( $worker, 'missing' ), undef,                                        'a name that is on no directory of the PATH has none' );
    my $relative = $tmp->child('relative')->make_path;
    $relative->child('here')->spew("#!/bin/sh\n");
    $relative->child('here')->chmod( oct '0755' );
    my $cwd = Mojo::File->new->to_abs;
    chdir "$tmp" or die "chdir: $!";
    is( App::Clod::Packages::program_file( $worker, 'here' ), undef, 'and a directory of the PATH that is not absolute is passed over' );
    chdir "$cwd" or die "chdir: $!";
    is( App::Clod::Packages::program_file( App::Clod::Claude->new( lib => "$lib" ), 'tool' ), $lib->child( 'bin', 'tool' )->realpath->to_string, 'on the PATH that claude runs with' );
};

subtest program_error => sub {
    is( App::Clod::Packages::program_error( $worker, 'true' ), undef, 'a program that exits 0 runs' );
    my $says = script( 'says', 'echo "token=$GH_TOKEN args=$*"; exit 4' . "\n" );
    local $ENV{GH_TOKEN} = 'test-token';
    is( App::Clod::Packages::program_error( $worker, qq{$says -version 'two words'} ), "token= args=-version two words", 'one that fails says what it printed, with its words split as a shell does, and no token of the bot' );
    like( App::Clod::Packages::program_error( $worker, '/bogus/no-such-program -version' ), qr/no-such-program/, 'and one that is not there says so' );
    is( App::Clod::Packages::program_error( $worker, q{ } ), 'it is not a command line', 'a line with no word is not a command' );
    local $App::Clod::Packages::PROGRAM_SECONDS = 1;
    like( App::Clod::Packages::program_error( $worker, script( 'hangs', "sleep 10\n" ) ), qr/timeout/i, 'and one that runs too long fails' );
};

subtest 'a program, as the account of the agent' => sub {
    local $ENV{PATH}     = "$here/bin/sudo-dir:$ENV{PATH}";
    local $ENV{GH_TOKEN} = 'test-token';
    my $says  = script( 'whoami', 'echo "home=$HOME token=$GH_TOKEN"; exit 3' . "\n" );
    my $agent = App::Clod::Claude->new( run_as => 'test-agent' );
    is( App::Clod::Packages::program_error( $agent, $says ),  'home=/bogus/home/test-agent token=', 'with an account for claude, a program runs as that account, through sudo, and its error is what it printed' );
    is( App::Clod::Packages::program_error( $agent, 'true' ), undef,                                'and one that runs, runs' );
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
    is( App::Clod::Packages::install( $installer, undef,                  qw{ffmpeg libmagic-dev} ), "installing ffmpeg libmagic-dev\na warning\n",                          'the installer gets the names, and what it printed comes back, its errors too' );
    is( App::Clod::Packages::install( $installer, '/bogus/sources.jsonl', 'jellyfin' ),              "installing --sources-file /bogus/sources.jsonl jellyfin\na warning\n", 'and a file of sources, before the names, when there is one' );
    like( dies { App::Clod::Packages::install( $installer, undef, 'bad' ) }, qr/installing\ bad\na\ warning\n/, 'an installer that fails dies with what it printed' );
};

subtest os_release => sub {
    my $release = $tmp->child('os-release');
    $release->spew(qq{NAME="Ubuntu"\nID=ubuntu\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\nID_LIKE=debian\n});
    local $App::Clod::Packages::OS_RELEASE = "$release";
    is( { App::Clod::Packages::os_release() }, { distro => 'ubuntu', release => '24.04', codename => 'noble' }, 'the distribution, its release and its codename, quoted or not' );
    $release->spew(qq{ID=debian\nVERSION_CODENAME=\n});
    is( { App::Clod::Packages::os_release() }, { distro => 'debian' }, 'and only what the file says, as on a release of Debian testing' );
    local $App::Clod::Packages::OS_RELEASE = '/bogus/os-release';
    like( dies { App::Clod::Packages::os_release() }, qr{\A/bogus/os-release\ cannot\ be\ read:}, 'a host that does not say dies' );
};

subtest has_source => sub {
    my $apt = $tmp->child('sources.list.d')->make_path;
    $apt->child('jellyfin.sources')->spew("Types: deb\n");
    local $App::Clod::Packages::APT_SOURCES = "$apt";
    ok( App::Clod::Packages::has_source( deb  => { name => 'jellyfin' } ), 'an archive whose .sources file apt has is there' );
    ok( !App::Clod::Packages::has_source( deb => { name => 'other' } ),    'and one without is not' );
    like( dies { App::Clod::Packages::has_source( rpm => { name => 'other' } ) }, qr/no\ way\ to\ ask/, 'and a packager that it cannot ask about dies' );
};

done_testing;
