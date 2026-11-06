package App::Clod::Packages;

# ABSTRACT: The system packages that the spokes declare, and whether the host has them

use 5.040;
no autovivification;
use warnings FATAL => 'all';
use re '/aasx';

use Text::ParseWords ();

use App::Clod::Deps();

# The programs, found on the PATH.  A test points them at fakes.
our @DPKG_QUERY = ('dpkg-query');
our @SUDO       = qw{sudo -n};

# How long a declared program may run before it counts as failing.
our $PROGRAM_SECONDS = 60;

# For each packager, whether the host has a package of it.
our %INSTALLED = ( deb => \&deb_installed );

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
C<install ok installed>.  A package that dpkg does not know is not.

=cut

sub deb_installed ($name) {
    my $status = eval { App::Clod::Deps::run( { timeout => $PROGRAM_SECONDS }, @DPKG_QUERY, qw{-W -f ${Status}}, $name ) } // return 0;
    return $status eq 'install ok installed' ? 1 : 0;
}

=func program_error

C<($line)>, a command line of C<programs>, such as C<ffmpeg -version>.  Undef
when it exits 0, and else why it failed: what it printed, or why it did not
run.  The line is split into words as a
shell does, and runs with no shell, no input, only the C<PATH> of this process
in its environment, so no token of the bot reaches it, and at most
C<$PROGRAM_SECONDS> seconds.

=cut

sub program_error ($line) {
    my @words = Text::ParseWords::shellwords($line);
    return 'it is not a command line' if !@words;
    my $ok = eval { App::Clod::Deps::run( { env => { PATH => $ENV{PATH} }, timeout => $PROGRAM_SECONDS, merge => 1 }, @words ); 1 };
    return $ok ? undef : $@ =~ s{\A\Q@words\E:\ }{}r =~ s{\s+\z}{}r;
}

=func install

C<($installer, @names)>.  Runs C<sudo -n $installer @names>, and returns what
it printed, its standard error too.  Dies with that when it fails.

=cut

sub install ( $installer, @names ) {
    return App::Clod::Deps::run( { merge => 1 }, @SUDO, $installer, @names );
}

1;

=head1 SYNOPSIS

    use 5.040;
    use App::Clod::Packages;

    my @lacks = grep { !App::Clod::Packages::installed( deb => $_ ) } qw{ffmpeg libmagic-dev};
    say App::Clod::Packages::install( '/bogus/clod-install-packages', @lacks ) if @lacks;
    say App::Clod::Packages::program_error('ffmpeg -version') // 'ffmpeg runs';

=head1 DESCRIPTION

A spoke declares the packages of the operating system that it needs under
C<x_system_packages> in its F<metamerge.yml>, as
L<Dist::Conformance::Check::SystemPackages> reads it.  The C<system_packages>
of F<clod.conf> names the packager of the host, such as C<deb>, and the
program that installs packages, which the service user may run with sudo and
no password.  The installer installs only from the archives that the host
trusts, and refuses a name that is not a plain package name.

L<App::Clod::Tasks/self_check> asks this module what the host lacks, and
L<App::Clod::Tasks/packages_install> installs it, from a button of the
dashboard.

=cut
