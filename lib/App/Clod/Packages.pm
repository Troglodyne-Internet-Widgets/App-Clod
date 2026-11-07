package App::Clod::Packages;

# ABSTRACT: The system packages that the spokes declare, and whether the host has them

use 5.040;
no autovivification;
use warnings FATAL => 'all';
use re '/aasx';

use List::Util       ();
use Mojo::File       ();
use Text::ParseWords ();

use Dist::Conformance::Check::SystemPackages();

use App::Clod::Deps();

# The programs, found on the PATH.  A test points them at fakes.
our @DPKG_QUERY = ('dpkg-query');
our @SUDO       = qw{sudo -n};

# How long a declared program may run before it counts as failing.
our $PROGRAM_SECONDS = 60;

# For each packager, whether the host has a package of it, and an archive of it.
our %INSTALLED  = ( deb => \&deb_installed );
our %HAS_SOURCE = ( deb => \&deb_has_source );
our %OWNERS     = ( deb => \&deb_owners );

# Where the host says what it is, and where apt keeps its archives.  A test points them at fixtures.
our $OS_RELEASE  = '/etc/os-release';
our $APT_SOURCES = '/etc/apt/sources.list.d';

=func os_release

The distribution of the host, from C<$OS_RELEASE>, as
L<Dist::Conformance::Check::SystemPackages/resolve> takes it: C<distro> from
C<ID>, C<release> from C<VERSION_ID> and C<codename> from
C<VERSION_CODENAME>, each left out when the file does not have it, as
L<Dist::Conformance::Check::SystemPackages/os_release> reads the file.  Dies
when the file cannot be read.

=cut

sub os_release () {
    my $text  = eval { Mojo::File->new($OS_RELEASE)->slurp('UTF-8') } // die "$OS_RELEASE cannot be read: $@";
    my %field = %{ Dist::Conformance::Check::SystemPackages::os_release($text) };
    my %as    = ( ID => 'distro', VERSION_ID => 'release', VERSION_CODENAME => 'codename' );
    return map { defined $field{$_} && $field{$_} ne q{} ? ( $as{$_} => $field{$_} ) : () } sort keys %as;
}

=func installed

C<($packager, $name)>.  True when the host has the package C<$name> of
C<$packager> installed.  Dies for a packager that is not a key of
C<%INSTALLED>.

=cut

sub installed ( $packager, $name ) {
    my $asks = $INSTALLED{$packager} // die "There is no way to ask whether a $packager package is installed\n";
    return $asks->($name);
}

=func deb_installed

C<($name)>.  True when dpkg says that the package is installed: its status is
C<install ok installed>.  A package that dpkg does not know is not: then
C<dpkg-query> fails, and says C<no packages found matching>.  Dies when
C<dpkg-query> fails for any other reason, such as not being there, so that
a host that cannot answer does not look like one that lacks every package.

=cut

sub deb_installed ($name) {
    my $status = eval { App::Clod::Deps::run( { timeout => $PROGRAM_SECONDS }, @DPKG_QUERY, qw{-W -f ${Status}}, $name ) };
    if ( !defined $status ) {
        return 0 if $@ =~ m{no\ packages\ found\ matching};
        die $@;
    }
    return $status eq 'install ok installed' ? 1 : 0;
}

=func has_source

C<($packager, $source)>, a source as
L<Dist::Conformance::Check::SystemPackages/resolve> returns it.  True when the
host has that archive.  Dies for a packager that is not a key of
C<%HAS_SOURCE>.

=cut

sub has_source ( $packager, $source ) {
    my $has = $HAS_SOURCE{$packager} // die "There is no way to ask whether the host has a $packager archive\n";
    return $has->($source);
}

=func deb_has_source

C<($source)>.  True when apt has F<NAME.sources> in C<$APT_SOURCES>, as the
installer writes it.

=cut

sub deb_has_source ($source) { return -e "$APT_SOURCES/$source->{name}.sources" ? 1 : 0 }

=func owners

C<($packager, $file)>.  The packages of C<$packager> that have the file
C<$file>, an absolute path, as the packager says.  None when no package has
it.  Dies for a packager that is not a key of C<%OWNERS>.

=cut

sub owners ( $packager, $file ) {
    my $asks = $OWNERS{$packager} // die "There is no way to ask which $packager package has a file\n";
    return $asks->($file);
}

=func deb_owners

C<($file)>.  The packages that have C<$file>, as C<dpkg-query -S> says,
without their architecture.  A line of a diversion names no package that has
the file, so it is left out.  None when dpkg says C<no path found matching>.
Dies when C<dpkg-query> fails for any other reason.

=cut

sub deb_owners ($file) {
    my $said = eval { App::Clod::Deps::run( { timeout => $PROGRAM_SECONDS }, @DPKG_QUERY, '-S', $file ) };
    if ( !defined $said ) {
        return if $@ =~ m{no\ path\ found\ matching};
        die $@;
    }
    my @lists = map { m{\A (.+?) :[ ] \Q$file\E \z} ? $1 : () } grep { !m{\Adiversion[ ]} } split m{\n}, $said;
    return List::Util::uniq( map { s{:[^:]*\z}{}r } split m{,[ ]}, join q{, }, @lists );
}

=func program_file

C<($claude, $name)>.  The file that the command C<$name> runs, as the shell of
a claude run finds it: the first executable file of that name in an absolute
directory of the C<PATH> of L<App::Clod::Claude/run_env>, with each symbolic
link resolved.  Undef when there is none.  A directory of the C<PATH> that is
not absolute is passed over, because the run resolves it in the worktree.
Whether the file is executable is what the worker can tell.

=cut

sub program_file ( $claude, $name ) {
    my %env = $claude->run_env;
    for my $dir ( grep { m{\A/} } split m{:}, $env{PATH} // q{} ) {
        my $file = Mojo::File->new( $dir, $name );

        # The shell passes over a file without the execute bit, and -x asks for that bit.
        return $file->realpath->to_string if -e $file && !-d _ && -x _;    ## no critic (ValuesAndExpressions::ProhibitFiletest_rwxRWX)
    }
    return;
}

=func program_error

C<($claude, $line)>: an L<App::Clod::Claude>, and a command line, the
C<test> of a dependency, such as C<ffmpeg -version>.  Undef when it exits 0, and else why
it failed: what it printed, or why it did not run.  The line is split into
words as a shell does, and runs with no shell, no input, and at most
C<$PROGRAM_SECONDS> seconds.

It runs as the account that claude runs as, as
L<App::Clod::Claude/as_account> runs a command, when there is one.  The line
comes from a spoke, and that account is the one meant for code from spokes,
while the worker holds the token of the bot in its environment, and can read
F<clod.conf>.  Without such an account, it runs as the worker, with only the
C<PATH> of this process in its environment, so that the token does not reach
it at least.

=cut

sub program_error ( $claude, $line ) {
    my @words = Text::ParseWords::shellwords($line);
    return 'it is not a command line' if !@words;
    my @cmd = $claude->as_account(@words);
    my $ok  = eval { App::Clod::Deps::run( { env => { PATH => $ENV{PATH} }, timeout => $PROGRAM_SECONDS, merge => 1 }, @cmd ); 1 };
    return $ok ? undef : $@ =~ s{\A\Q@cmd\E:\ }{}r =~ s{\s+\z}{}r;
}

=func install

C<($installer, $sources_file, @names)>.  Runs C<sudo -n $installer @names>,
with C<--sources-file $sources_file> first when it is defined, and returns what
it printed, its standard error too.  Dies with that when it fails.

=cut

sub install ( $installer, $sources_file, @names ) {
    return App::Clod::Deps::run( { merge => 1 }, @SUDO, $installer, ( defined $sources_file ? ( '--sources-file', $sources_file ) : () ), @names );
}

1;

=head1 SYNOPSIS

    use 5.040;
    use App::Clod::Claude;
    use App::Clod::Packages;

    my @lacks = grep { !App::Clod::Packages::installed( deb => $_ ) } qw{ffmpeg libmagic-dev};
    say App::Clod::Packages::install( '/bogus/clod-install-packages', undef, @lacks ) if @lacks;
    say App::Clod::Packages::program_error( App::Clod::Claude->new( run_as => 'agent' ), 'ffmpeg -version' ) // 'ffmpeg runs';

=head1 DESCRIPTION

A spoke declares the dependencies on the operating system that it has under
C<x_system_packages> in its F<metamerge.yml>, and the archives that their
packages come from under C<x_system_sources>, as
L<Dist::Conformance::Check::SystemPackages> reads them.  The C<system_packages>
of F<clod.conf> names the packager of the host, such as C<deb>, and the
program that installs packages, which the service user may run with sudo and
no password.  The installer installs from the archives that the host trusts,
and from the archives in the file of sources that it is given, and refuses a
name that is not a plain package name.  A dependency can have another package
on a distribution or a release of one, or none, so what the host needs
comes from L</os_release>.

L<App::Clod::Tasks/self_check> asks this module what the host lacks, and
L<App::Clod::Tasks/packages_install> installs it, from a button of the
dashboard.  L<App::Clod::Tasks/branch_packages> asks the same about the
branch of a pull request of the bot.

=cut
