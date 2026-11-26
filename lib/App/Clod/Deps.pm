package App::Clod::Deps;

# ABSTRACT: The Perl modules of the bot, in a local lib that it can upgrade

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';

use Config              ();
use Config::Tiny        ();
use IPC::Run            ();
use List::Util          ();
use Mojo::File          ();
use Module::Metadata    ();
use Mutex::Flock        ();
use Perl::Critic::Utils ();

# The programs, found on the PATH.  A test points them at fakes.
our @DZIL     = ('dzil');
our @CPM      = ('cpm');
our @OUTDATED = ('cpan-outdated');

# The tools of the agent that every spoke needs, beside the policies of the
# critic profiles of the standards.  App::Clod::Config lets a run use them.
our @TOOLS = qw{Perl::Critic Perl::Tidy Devel::NYTProf Dist::Zilla::App::Command::podchecker};

# The environment of this process, with the modules of the local lib $lib on
# PERL5LIB, so that a dzil that runs with it loads the plugins installed there.
my sub with_lib ($lib) {
    return { %ENV, PERL5LIB => join q{:}, "$lib/lib/perl5", grep { defined && $_ ne q{} } $ENV{PERL5LIB} };
}

=func listdeps

C<($checkout, $lib)>.  The modules that the distribution in C<$checkout>
needs, as C<dzil listdeps> names them, without C<perl>.  C<$lib> is optional.
With it, C<dzil> runs with the modules of that local lib on C<PERL5LIB>, so
it finds the plugins that were installed there.

Returns a list of Str, the names of the modules.  Dies as L</run> does when
C<dzil listdeps> fails, which it does when a plugin of F<dist.ini> is not
installed.

    my @modules = App::Clod::Deps::listdeps($checkout);
    my @modules = App::Clod::Deps::listdeps( $checkout, $lib );

=cut

sub listdeps ( $checkout, $lib = undef ) {
    return grep { $_ ne q{} && $_ ne 'perl' } split m{\n}, run( { dir => "$checkout", ( defined $lib ? ( env => with_lib($lib) ) : () ) }, @DZIL, 'listdeps' );
}

=func authordeps

C<($checkout, $lib)>.  What C<dzil> needs to build the distribution in C<$checkout>:
the plugins of its F<dist.ini>, and the modules of its C<; authordep> lines,
as C<dzil authordeps> names them.  Each comes with its version in the syntax of
cpm, such as C<Foo~1.2>, when F<dist.ini> asks for one.  C<dzil authordeps>
reads F<dist.ini> and loads no plugin, so it works when the plugins are
missing, and L</listdeps> does not.

C<$lib> is optional.  With it, the list has only what C<dzil> cannot load at
the version that F<dist.ini> asks for, when it runs with the modules of that
local lib on C<PERL5LIB>, as C<dzil authordeps --missing> finds it.

Returns a list of Str, the modules.  Dies as L</run> does when C<dzil
authordeps> fails.

    my @modules = App::Clod::Deps::authordeps($checkout);
    my @missing = App::Clod::Deps::authordeps( $checkout, $lib );

=cut

sub authordeps ( $checkout, $lib = undef ) {
    my @with = defined $lib ? ( env => with_lib($lib) ) : ();
    my @only = defined $lib ? ('--missing')             : ();
    return map { my ( $module, $version ) = split m{ \h* = \h* }x; $version ? "$module~$version" : $module } grep { $_ ne q{} } split m{\n}, run( { dir => "$checkout", @with }, @DZIL, qw{authordeps --versions}, @only );
}

=func install_deps

C<($lib, $checkout)>.  Installs into the local lib C<$lib> what the
distribution in C<$checkout> needs to build, as L</authordeps> names it, and
then what it needs to run, as L</listdeps> names it.  The first install comes
first because C<dzil listdeps> loads every plugin of F<dist.ini>, so a new
plugin that is not installed stops it.

Returns nothing.  Dies as L</install> and L</run> do.

    App::Clod::Deps::install_deps( $lib, $checkout );

=cut

sub install_deps ( $lib, $checkout ) {
    install( $lib, authordeps($checkout) );
    install( $lib, listdeps($checkout) );
    return;
}

=func install

C<($lib, @modules)>.  Installs each module of C<@modules> into the local lib
C<$lib>, with cpm and no tests, whether or not the perl has it already.  It
installs with C<umask 0027>, so the group of the lib may read what it installs
and not change it.  A
module can carry a version range in the syntax of cpm, such as C<Foo~1.2>.

Returns nothing.  It does nothing when C<@modules> is empty.  Dies with the
error of L</run> when cpm fails.  It puts the umask back first.

    App::Clod::Deps::install( $lib, 'Mojolicious', 'Minion~10.0' );

=cut

sub install ( $lib, @modules ) {
    return if !@modules;
    my $umask = umask oct '0027';
    my $ok    = eval { run( {}, @CPM, qw{install --without-test -L}, "$lib", @modules ); 1 };
    umask $umask;
    die $@ if !$ok;
    return;
}

=func install_needed

C<($lib, $checkout)>.  Installs into the local lib C<$lib> what the
distribution in C<$checkout> needs.  First it installs what C<dzil> needs to
build it, as L</authordeps> finds it missing with C<$lib>.  Then it installs
each module that L</listdeps> names, with C<$lib>, and that neither C<$lib> nor
the C<@INC> of this process has.  The first install comes first because
C<dzil listdeps> loads every plugin of F<dist.ini>, so a plugin that is not
installed stops it.

A checkout with no F<dist.ini> needs none.  It installs as L</install> does,
with a lock on F<.lock> in C<$lib>, because every worker shares the lib.  The
lock is inside the lib, because the directory above it can be one that the
agent can write too, such as the workspace.  Dies as L</run> does.

Returns a list of Str, the modules that it installed, each with its version
in the syntax of cpm when F<dist.ini> asks for one.  The list is empty when
nothing was missing.

    my @installed = App::Clod::Deps::install_needed( $lib, $checkout );

=cut

sub install_needed ( $lib, $checkout ) {
    return if !-e "$checkout/dist.ini";
    my $dir   = Mojo::File->new("$lib")->make_path;
    my $lock  = Mutex::Flock->new( path => $dir->child('.lock')->to_string );
    my @build = authordeps( $checkout, $lib );
    $lock->synchronize( sub { install( $lib, @build ) } ) if @build;
    my @run = grep { local ($_) = $_; !Module::Metadata->find_module_by_name($_) } missing( $lib, listdeps( $checkout, $lib ) );
    $lock->synchronize( sub { install( $lib, @run ) } ) if @run;
    return ( @build, @run );
}

=func install_programs

C<($lib)>.  Puts each program of F<share/agent-bin>, such as F<clod-cpm>, in
the F<bin> of the agent lib C<$lib>, for its group to read and run, and replaces what is
there.

Returns nothing.

    App::Clod::Deps::install_programs($lib) if App::Clod::Deps::stale_programs($lib);

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

Returns a list of Str, empty when the bin is up to date.

    my @stale = App::Clod::Deps::stale_programs($lib);

=cut

sub stale_programs ($lib) {
    my $bin = Mojo::File->new( "$lib", 'bin' );
    return map { local ($_) = $_; $_->basename } grep {
        local ($_) = $_;
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

Returns a list of Str, the names of the modules of the policies.

    my @policies = App::Clod::Deps::policies( Mojo::File->new('.perlcriticrc')->slurp );

=cut

sub policies (@profiles) {
    my %on;
    for my $text (@profiles) {
        my $ini = Config::Tiny->read_string($text) // die 'A critic profile does not parse: ' . Config::Tiny->errstr . "\n";
        foreach my $policy ( grep { $_ ne q{_} && !m{\A-} } keys %$ini ) {
            $on{ Perl::Critic::Utils::policy_long_name($policy) } = 1;
        }
    }
    my @policies = sort keys %on;
    return @policies;
}

=func missing

C<($lib, @modules)>.  The modules of C<@modules> that the local lib C<$lib>
does not have a file of, in its directory for this architecture or in the one
for every architecture.

Returns a list of Str, in the order of C<@modules>.

    my @missing = App::Clod::Deps::missing( $lib, @App::Clod::Deps::TOOLS );

=cut

sub missing ( $lib, @modules ) {
    my @dirs = ( "$lib/lib/perl5/$Config::Config{archname}", "$lib/lib/perl5" );
    return grep { local ($_) = $_; !Module::Metadata->find_module_by_name( $_, \@dirs ) } @modules;
}

=func outdated

C<($lib)>.  The modules in the local lib C<$lib> that CPAN has a newer release
of, each a hash with C<module>, C<version>, the one installed, C<latest>, and
C<dist>, the path of the release on CPAN.  The modules of the core of the perl
are not in it.

Returns ArrayRef[HashRef], empty when every module is current.  Dies as
L</run> does when C<cpan-outdated> fails.

    my $outdated = App::Clod::Deps::outdated($lib);

=cut

sub outdated ($lib) {
    my @lines = split m{\n}, run( {}, @OUTDATED, '-L', "$lib", qw{--exclude-core --verbose} );
    return [ map { my ( $module, $version, $latest, $dist ) = split; { module => $module, version => $version, latest => $latest, dist => $dist } } grep { m{\S} } @lines ];
}

=func upgrade

C<($lib)>.  Installs the newest release of each module that L</outdated> finds
in C<$lib>, and returns what it found.

Returns ArrayRef[HashRef], as L</outdated> returns it.  Dies as L</outdated>
and L</install> do.

    my $upgraded = App::Clod::Deps::upgrade($lib);

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

=item exits

The exit statuses that are success, a list reference.  Default C<[0]>.  So a
command whose status says what it found, such as perlcritic, which exits 2
when it reports a violation, is not taken for one that failed.

=back

Returns Str, what the command printed on its standard output.

    my $out = App::Clod::Deps::run( { dir => $checkout, timeout => 600 }, 'dzil', 'listdeps' );

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
    my $ran  = eval { IPC::Run::run( \@cmd, @init, '<', \undef, @out, @time ); 1 };
    my $exit = $? >> 8;
    my $ok   = $ran && List::Util::any { $_ == $exit } @{ $how->{exits} // [0] };
    my $said = $how->{merge} ? $out : $err;
    die "@cmd: " . ( $said ne q{} ? $said : $@ || 'failed' ) . "\n" if !$ok;
    return $out;
}

1;

=head1 SYNOPSIS

=for test_synopsis my ( $lib, $checkout );

    use App::Clod::Deps ();

    App::Clod::Deps::install_deps( $lib, $checkout );
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
