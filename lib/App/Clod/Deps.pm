package App::Clod::Deps;

# ABSTRACT: The Perl modules of the bot, in a local lib that it can upgrade

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';

use Config              ();
use Config::Tiny        ();
use IPC::Run            ();
use Mojo::File          ();
use Module::Metadata    ();
use Perl::Critic::Utils ();

# The programs, found on the PATH.  A test points them at fakes.
our @DZIL     = ('dzil');
our @CPM      = ('cpm');
our @OUTDATED = ('cpan-outdated');

# The tools of the agent that every spoke needs, beside the policies of the
# critic profiles of the standards.  App::Clod::Config lets a run use them.
our @TOOLS = qw{Perl::Critic Perl::Tidy Devel::NYTProf Dist::Zilla::App::Command::podchecker};

=func listdeps

C<($checkout)>.  The modules that the distribution in C<$checkout> needs, as
C<dzil listdeps> names them, without C<perl>.

=cut

sub listdeps ($checkout) {
    return grep { $_ ne q{} && $_ ne 'perl' } split m{\n}, run( { dir => "$checkout" }, @DZIL, 'listdeps' );
}

=func install

C<($lib, @modules)>.  Installs each module of C<@modules> into the local lib
C<$lib>, with cpm and no tests, whether or not the perl has it already.  It
installs with C<umask 0027>, so the group of the lib may read what it installs
and not change it.  A
module can carry a version range in the syntax of cpm, such as C<Foo~1.2>.

=cut

sub install ( $lib, @modules ) {
    return if !@modules;
    my $umask = umask oct '0027';
    my $ok    = eval { run( {}, @CPM, qw{install --without-test -L}, "$lib", @modules ); 1 };
    umask $umask;
    die $@ if !$ok;
    return;
}

=func install_programs

C<($lib)>.  Puts each program of F<share/agent-bin>, such as F<clod-cpm>, in
the F<bin> of the agent lib C<$lib>, for its group to read and run, and replaces what is
there.

=cut

sub install_programs ($lib) {
    my $bin = Mojo::File->new( "$lib", 'bin' )->make_path;
    for my $program ( App::Clod::share_dir()->child('agent-bin')->list->each ) {
        $program->copy_to( $bin->child( $program->basename ) )->chmod( oct '0750' );
    }
    return;
}

=func stale_programs

C<($lib)>.  The names of the programs of F<share/agent-bin> that the bin of
the agent lib C<$lib> lacks, or has another version of.

=cut

sub stale_programs ($lib) {
    my $bin = Mojo::File->new( "$lib", 'bin' );
    return map { $_->basename } grep {
        my $there = $bin->child( $_->basename );
        !-e $there || $there->slurp ne $_->slurp
    } App::Clod::share_dir()->child('agent-bin')->list->each;
}

=func policies

C<(@profiles)>, the texts of F<.perlcriticrc> files.  The module of each policy
that a profile turns on, sorted and once each.  Config::Tiny reads a profile,
as Perl::Critic does, and each section names a policy,
which C<policy_long_name> of L<Perl::Critic::Utils> turns into its module, a
short name too.  A section C<[-X]> turns X off.  Dies with the error of
Config::Tiny when a profile does not parse.

=cut

sub policies (@profiles) {
    my %on;
    for my $text (@profiles) {
        my $ini = Config::Tiny->read_string($text) // die 'A critic profile does not parse: ' . Config::Tiny->errstr . "\n";
        $on{ Perl::Critic::Utils::policy_long_name($_) } = 1 for grep { $_ ne q{_} && !m{\A-} } keys %$ini;
    }
    my @policies = sort keys %on;
    return @policies;
}

=func missing

C<($lib, @modules)>.  The modules of C<@modules> that the local lib C<$lib>
does not have a file of, in its directory for this architecture or in the one
for every architecture.

=cut

sub missing ( $lib, @modules ) {
    my @dirs = ( "$lib/lib/perl5/$Config::Config{archname}", "$lib/lib/perl5" );
    return grep { !Module::Metadata->find_module_by_name( $_, \@dirs ) } @modules;
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

C<(\%how, @cmd)>.  Runs C<@cmd>, and returns what it printed.  Dies with what
it printed on its standard error if it fails.  C<%how> can have:

=over

=item dir

The directory to run it in.

=item env

The whole environment of the command, a hash reference, in place of the one
of this process.

=item timeout

Seconds.  A command that runs longer is killed, and fails.

=item merge

True to take its standard error into what it printed, so the result, and the
error it dies with, have both, in the order that it printed them.

=back

=cut

sub run ( $how, @cmd ) {
    my ( $out, $err ) = ( q{}, q{} );
    my @init = ( $how->{dir} || $how->{env} )
      ? (
        init => sub {
            if ( $how->{dir} ) { chdir $how->{dir} or die "chdir $how->{dir}: $!\n" }

            # init runs in the child before the exec, where a local would be undone first.
            %ENV = %{ $how->{env} } if $how->{env};    ## no critic (Variables::RequireLocalizedPunctuationVars)
        }
      )
      : ();
    my @out  = $how->{merge}   ? ( '>&', \$out )                          : ( '>', \$out, '2>', \$err );
    my @time = $how->{timeout} ? ( IPC::Run::timeout( $how->{timeout} ) ) : ();
    my $ok   = eval { IPC::Run::run( \@cmd, @init, '<', \undef, @out, @time ) };
    my $said = $how->{merge} ? $out : $err;
    die "@cmd: " . ( $said ne q{} ? $said : $@ || 'failed' ) . "\n" if !$ok;
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
