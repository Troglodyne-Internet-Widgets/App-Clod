package App::Clod::Deps;

# ABSTRACT: The Perl modules of the bot, in a local lib that it can upgrade

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';

use IPC::Run ();

# The programs, found on the PATH.  A test points them at fakes.
our @DZIL     = ('dzil');
our @CPM      = ('cpm');
our @OUTDATED = ('cpan-outdated');

=func listdeps

C<($checkout)>.  The modules that the distribution in C<$checkout> needs, as
C<dzil listdeps> names them, without C<perl>.

=cut

sub listdeps ($checkout) {
    return grep { $_ ne q{} && $_ ne 'perl' } split m{\n}, run( { dir => "$checkout" }, @DZIL, 'listdeps' );
}

=func install

C<($lib, @modules)>.  Installs each module of C<@modules> into the local lib
C<$lib>, with cpm and no tests, whether or not the perl has it already.  A
module can carry a version range in the syntax of cpm, such as C<Foo~1.2>.

=cut

sub install ( $lib, @modules ) {
    return if !@modules;
    run( {}, @CPM, qw{install --without-test -L}, "$lib", @modules );
    return;
}

=func outdated

C<($lib)>.  The modules in the local lib C<$lib> that CPAN has a newer release
of, each a hash with C<module>, C<version>, the one installed, C<latest>, and
C<dist>, the path of the release on CPAN.  The modules of the core of the perl
are not in it.

=cut

sub outdated ($lib) {
    my @lines = split m{\n}, run( {}, @OUTDATED, '-L', "$lib", qw{--exclude-core --verbose} );
    return [ map { my ( $module, $version, $latest, $dist ) = split; { module => $module, version => $version, latest => $latest, dist => $dist } } grep { m{\S} } @lines ];
}

=func upgrade

C<($lib)>.  Installs the newest release of each module that L</outdated> finds
in C<$lib>, and returns what it found.

=cut

sub upgrade ($lib) {
    my $outdated = outdated($lib);
    install( $lib, map { "$_->{module}~$_->{latest}" } @$outdated );
    return $outdated;
}

=func run

C<(\%how, @cmd)>.  Runs C<@cmd>, in the directory C<dir> of C<%how> if it has
one, and returns what it printed.  Dies with what it printed on its standard
error if it fails.

=cut

sub run ( $how, @cmd ) {
    my ( $out, $err ) = ( q{}, q{} );
    my @init = $how->{dir} ? ( init => sub { chdir $how->{dir} or die "chdir $how->{dir}: $!\n" } ) : ();
    my $ok   = eval { IPC::Run::run( \@cmd, @init, '<', \undef, '>', \$out, '2>', \$err ) };
    die "@cmd: " . ( $err ne q{} ? $err : $@ || 'failed' ) . "\n" if !$ok;
    return $out;
}

1;

=head1 SYNOPSIS

    use App::Clod::Deps ();

    App::Clod::Deps::install( $lib, App::Clod::Deps::listdeps($checkout) );
    my $outdated = App::Clod::Deps::outdated($lib);
    App::Clod::Deps::upgrade($lib);

=head1 DESCRIPTION

The modules that the bot needs come from CPAN into the perl of the host, which
root owns.  So the bot cannot upgrade them.  With C<local_lib> in
F<clod.conf>, they go into a local lib that the service user owns as well,
which comes first on the C<PERL5LIB> of the units.  Then the bot can install
what a new version of itself needs, and upgrade what has a newer release, with
no sudo.  The command C<clod deps> runs these from the shell, and the
dashboard runs them from its buttons.

cpm installs a module into a local lib even when the perl has it already, so
the local lib holds a copy of every module, and an upgrade there wins.

=cut
