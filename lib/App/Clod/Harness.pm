package App::Clod::Harness;

# ABSTRACT: Whether a spoke conforms to its standards, and whether the marketplace pins the plugin

use 5.040;
no autovivification;
use warnings FATAL => 'all';
use re '/aasx';

use Mojo::File();
use Mojo::JSON();
use Perl::Critic::Utils();
use version ();

use App::Clod::Deps();

use Dist::Conformance();
use Dist::Conformance::Config();
use Dist::Conformance::Snapshot::Directory();
use Dist::Conformance::Snapshot::Tree();
use Dist::Conformance::Source::Git();

# perlcritic, found on the PATH, and the directories of a spoke that it reads.
# A program and not Perl::Critic, because the policies are in the libs of the
# agent, which the worker must not load over the modules that it runs on.
our @PERLCRITIC = ('perlcritic');
our @SOURCES    = qw{lib bin script t};

=func default_config

C<($settings)>, the C<harness> section of F<clod.conf>.  The validated
F<.conformance.yml> of a spoke that has none: the C<flavor> of the settings,
from their C<standards>.  Dies as L<Dist::Conformance::Config/validate> does.

Returns HashRef, the configuration with its defaults filled in.

    my $config = App::Clod::Harness::default_config( $config->{harness} );

=cut

sub default_config ($settings) {
    return Dist::Conformance::Config::validate( { flavor => $settings->{flavor}, source => $settings->{standards} } );
}

=func default_cache

The directory of the clones of git sources when F<clod.conf> names none: the
one that L<Dist::Conformance::Source::Git/cache> chooses for the account that
runs the bot, under C<$XDG_CACHE_HOME> or F<~/.cache>.  Dies when neither
C<XDG_CACHE_HOME> nor C<HOME> is set.

Returns Str, the path of the directory.

    my $cache = $config->{harness}{cache} // App::Clod::Harness::default_cache();

=cut

sub default_cache () {

    # The URL is never fetched.  Only a source knows the rule for its cache.
    return Dist::Conformance::Source::Git->new( url => 'unused' )->cache;
}

=func standards

C<($settings, %options)>.  The L<Dist::Conformance::Source> of
L</default_config>, which a scan builds once and gives to every spoke that has
no F<.conformance.yml>, so a git source is fetched once.  C<cache> is the
directory of its clone.

Returns a Dist::Conformance::Source object.  Dies as L</conformance> does.

    my $standards = App::Clod::Harness::standards( $settings, cache => $cache );

=cut

sub standards ( $settings, %options ) {
    my $nothing = Dist::Conformance::Snapshot::Tree->new( paths => {}, fetch => sub ($) { return } );
    return conformance( $nothing, $settings, %options )->source;
}

=func snapshot

C<($tree, $fetch)>: what L<App::Clod::GitHub/tree> returns, and a sub that
returns the content of a path.  A L<Dist::Conformance::Snapshot::Tree> of the
files of the tree, without the entries for its directories.

Returns a Dist::Conformance::Snapshot::Tree object.

    my $snapshot = App::Clod::Harness::snapshot( $gh->tree( $repo, 'main' ), sub ($path) { $gh->file( $repo, $path, 'main' ) } );

=cut

sub snapshot ( $tree, $fetch ) {
    my @blobs = grep { ( $_->{type} // 'blob' ) eq 'blob' } values %$tree;
    return Dist::Conformance::Snapshot::Tree->new( paths => { map { $_->{path} => $_->{sha} } @blobs }, fetch => $fetch );
}

=func conformance

C<($snapshot, $settings, %options)>.  The L<Dist::Conformance> of a spoke.  With
a F<.conformance.yml>, the spoke names its own flavor and source.  Without one,
it gets L</default_config>, and the C<source> of the options when given, such
as the one from L</standards>.  C<cache> is the directory of the clones of git
sources.  It is made mode 0700, every time, because the worker runs git in
each clone, and so runs what the configuration and the hooks of the clone
name.  The worker runs with a umask that lets its group write, and dies here
when it does not own the directory.

Returns a Dist::Conformance object.  Dies when it cannot change the mode of
C<cache>, and as L</default_config> does.

    my $conformance = App::Clod::Harness::conformance( $snapshot, $settings, cache => $cache );

=cut

sub conformance ( $snapshot, $settings, %options ) {
    my %args = ( snapshot => $snapshot );
    if ( defined $options{cache} ) {
        my $cache = Mojo::File->new( $options{cache} )->make_path;
        chmod 0700, "$cache" or die "chmod $cache: $!\n";
        $args{cache} = "$cache";
    }
    if ( !$snapshot->contains($Dist::Conformance::Config::FILE) ) {
        $args{config} = default_config($settings);
        $args{source} = $options{source} if $options{source};
    }
    return Dist::Conformance->new(%args);
}

=func workflows

C<($snapshot, $settings)>.  C<(status, detail)>: whether each workflow of
C<required_workflows> exists under F<.github/workflows>.  With none required,
it is info, and lists the ones present.

Returns a list of two Str: the status, C<pass>, C<fail> or C<info>, and the
detail.

    my ( $status, $detail ) = App::Clod::Harness::workflows( $snapshot, $settings );

=cut

sub workflows ( $snapshot, $settings ) {
    my @have   = sort map { m{\A[.]github/workflows/([^/]+)\z} } keys %{ $snapshot->paths };
    my @wanted = @{ $settings->{required_workflows} // [] };
    return ( 'info', @have ? "present: @have" : 'none' ) if !@wanted;
    my %have    = map  { $_ => 1 } @have;
    my @missing = grep { !$have{$_} } @wanted;
    return ( 'fail', "missing: @missing" ) if @missing;
    return ( 'pass', 'all present' );
}

=func unchecked

C<($snapshot, $settings)>.  Why the spoke gets no checks, or undef when it
gets them.  A spoke gets them when it names its flavor in its own
F<.conformance.yml>, or when the top of its tree has one of the C<markers> of
the settings, the files of a Perl distribution.  The standards are those of a
Perl distribution, and a repository of another kind can only fail them.

Returns Str or undef, undef when the spoke gets the checks.

    my $why = App::Clod::Harness::unchecked( $snapshot, $settings );

=cut

sub unchecked ( $snapshot, $settings ) {
    my @markers = ( $Dist::Conformance::Config::FILE, @{ $settings->{markers} } );
    foreach my $marker (@markers) { return if $snapshot->contains($marker) }
    return 'not a Perl distribution: it has none of ' . join q{, }, @markers;
}

=func check

C<($snapshot, $settings, %options)>, as L</conformance> takes them.  Returns
C<{flavor, chosen, checks}>: the flavor, whether the spoke chose it in its own
F<.conformance.yml>, and a list of C<{check, status, detail}>.  The list is
every check of the flavor, as L<Dist::Conformance/check> returns it, and then
C<workflows>.  Dies when the configuration or the flavor cannot be read, or the
source cannot be fetched.

Returns HashRef, with the keys C<flavor>, C<chosen> and C<checks>.

    my $result = App::Clod::Harness::check( $snapshot, $settings, source => $standards );

=cut

sub check ( $snapshot, $settings, %options ) {
    my $conformance = conformance( $snapshot, $settings, %options );
    my @results     = @{ $conformance->check };

    my ( $status, $detail ) = workflows( $snapshot, $settings );
    push @results, { check => 'workflows', status => $status, detail => $detail };
    return { flavor => $conformance->config->{flavor}, chosen => $snapshot->contains($Dist::Conformance::Config::FILE) ? 1 : 0, checks => \@results };
}

=func update

C<($tree, $settings, %options)>, with C<%options> as L</conformance> takes them.
Runs the update of every check on the checkout C<$tree>, as
C<conformance update> does there, and returns what
L<Dist::Conformance/update> returns: for each check, its C<changes> and what
is C<manual>, left for a person.  It writes the files of the standards into
the checkout, and commits nothing.

Returns ArrayRef[HashRef], one hash for each check, with C<check>, C<changes>
and C<manual>.  Dies when the checks cannot be made, as
L<Dist::Conformance/update> dies, and as L</conformance> does.

    my $results = App::Clod::Harness::update( $tree, $settings, cache => $cache );

=cut

sub update ( $tree, $settings, %options ) {
    my $conformance = conformance( Dist::Conformance::Snapshot::Directory->new( root => "$tree" ), $settings, %options );
    $conformance->root("$tree");
    return $conformance->update;
}

=func dropped

C<($tree, $settings, %options)>, with C<%options> as L</conformance> takes them.
What the update would drop of the checkout C<$tree>, as it is before the
update: what L<Dist::Conformance/adopt> finds in the files of each check, and
the configuration of that check does not already say.  A check that writes a
whole file, such as C<DistIni>, replaces whatever the file chose otherwise
than its template, and its update leaves nothing for a person.  This is how a
person sees what that was.  Each entry is in the form that the check takes
under C<checks> in F<.conformance.yml>, so a person keeps one by adding it
there.

Returns HashRef, from the name of each check to the keys of its configuration
that differ, such as C<overrides>, each to the entries that differ.  It is
empty when adopt finds nothing that the configuration lacks.  Dies as
L</conformance> does, and when the adopt of a check dies.

    my $dropped = App::Clod::Harness::dropped( $tree, $settings, cache => $cache );

=cut

sub dropped ( $tree, $settings, %options ) {
    my $conformance = conformance( Dist::Conformance::Snapshot::Directory->new( root => "$tree" ), $settings, %options );
    my $adopted     = $conformance->adopt;
    my %config      = map { local ($_) = $_; $_->name => $_->config } @{ $conformance->checks };
    my %dropped;
    for my $check ( keys %$adopted ) {
        for my $key ( keys %{ $adopted->{$check} } ) {
            my ( $want, $have ) = ( $adopted->{$check}{$key}, $config{$check}{$key} );
            my %differ;
            for my $name ( keys %$want ) {
                next if ref $have eq 'HASH' && exists $have->{$name} && Mojo::JSON::encode_json( [ $have->{$name} ] ) eq Mojo::JSON::encode_json( [ $want->{$name} ] );
                $differ{$name} = $want->{$name};
            }
            $dropped{$check}{$key} = \%differ if %differ;
        }
    }
    return \%dropped;
}

=func new_violations

C<($tree, $profile, $old)>: a checkout, the path in it of the critic profile
that the update changed, and the text of that profile before the update, or
undef when there was none.  What perlcritic, with the profile, reports in the
Perl files of the directories of C<@SOURCES> of the checkout, and did not
report there with the old one, or with none at all when C<$old> is undef.
Only the profile differs between the two runs, so a violation that the code
had already is in both, and only what the change of the profile brings
remains.  A hash reference from the name of each policy, as perlcritic names
it, to the files that break it, sorted.

It runs C<@PERLCRITIC> in C<$tree>, as a hook of the spoke runs it, so it
finds the policies on the C<PERL5LIB> of the caller, and the paths in a
profile are of the checkout.  Dies as L<App::Clod::Deps/run> does when
perlcritic fails, for example over a policy that is not installed.

Returns HashRef[ArrayRef[Str]], empty when the checkout has no Perl files or
the new profile brings no violation.

    my $new = App::Clod::Harness::new_violations( $tree, "$tree/.perlcriticrc", $old_profile );

=cut

sub new_violations ( $tree, $profile, $old ) {
    my @files = map { local ($_) = $_; Mojo::File->new($_)->to_rel("$tree")->to_string } Perl::Critic::Utils::all_perl_files( grep { -d } map { "$tree/$_" } @SOURCES );
    return {} if !@files;
    my $before = defined $old ? Mojo::File::tempfile()->spew($old) : undef;
    my %before = map { $_ => 1 } violations( $tree, ( defined $before ? ( '--profile', "$before" ) : '--noprofile' ), @files );
    my %by;
    for my $violation ( grep { !$before{$_} } violations( $tree, '--profile', $profile, @files ) ) {
        my ( $policy, $file ) = split m{\t}, $violation;
        $by{$policy}{$file} = 1;
    }
    return { map { $_ => [ sort keys %{ $by{$_} } ] } keys %by };
}

=func violations

C<($tree, @args)>.  Each violation that C<@PERLCRITIC> with C<@args> reports
in C<$tree>, as a line of the policy, the file, the line and the column,
separated by tabs.

Returns a list of Str, one line for each violation.  Dies as
L<App::Clod::Deps/run> does when perlcritic fails.

    my @lines = App::Clod::Harness::violations( $tree, '--profile', "$tree/.perlcriticrc", 'lib/Foo.pm' );

=cut

sub violations ( $tree, @args ) {
    return split m{\n}, App::Clod::Deps::run( { dir => "$tree", exits => [ 0, 2 ] }, @PERLCRITIC, '--quiet', '--verbose', '%p\t%f\t%l\t%c\n', @args );
}

=func tidy

C<($tree, $profile)>, a checkout and the path of its tidy profile.  Runs
C<@PERLTIDY> with that profile over the Perl files of the directories of
C<@SOURCES> of the checkout, as L</new_violations> finds them, and rewrites
each in place.  Returns the files that it changed, relative to the checkout
and sorted.  It finds perltidy on the C<PATH> of the caller.  Dies as
L<App::Clod::Deps/run> does when perltidy fails.

Returns a list of Str, empty when it changed nothing.

    my @changed = App::Clod::Harness::tidy( $tree, "$tree/.perltidyrc" );

=cut

our @PERLTIDY = ('perltidy');

sub tidy ( $tree, $profile ) {
    my @files = map { local ($_) = $_; Mojo::File->new($_)->to_rel("$tree")->to_string } Perl::Critic::Utils::all_perl_files( grep { -d } map { "$tree/$_" } @SOURCES );
    return if !@files;
    my %before = map { local ($_) = $_; $_ => Mojo::File->new("$tree/$_")->slurp } @files;

    # -bext=/ keeps no backup once a file is written.
    App::Clod::Deps::run( { dir => "$tree", exits => [ 0, 2 ] }, @PERLTIDY, "--profile=$profile", '-b', '-bext=/', @files );
    my @changed = sort grep { local ($_) = $_; Mojo::File->new("$tree/$_")->slurp ne $before{$_} } @files;
    return @changed;
}

=func critic_profiles

C<($settings, %options)>, as L</standards> takes them.  The texts of the critic
profiles of the standards, each F<templates/perlcriticrc*> of them, so that
L<App::Clod::Deps/policies> can name the policies that the agent must have.

Returns a list of Str, the texts of the profiles, sorted by file name.  Dies
as L</standards> does.

    my @policies = App::Clod::Deps::policies( App::Clod::Harness::critic_profiles( $settings, cache => $cache ) );

=cut

sub critic_profiles ( $settings, %options ) {
    my $templates = standards( $settings, %options )->base->child('templates');
    return map { local ($_) = $_; $_->slurp } sort { $a cmp $b } grep { local ($_) = $_; $_->basename =~ m{\Aperlcriticrc} } $templates->list->each;
}

=func marketplace_check

C<($plugin_json, $marketplace_json, $plugin)>, the texts of the plugin's
F<.claude-plugin/plugin.json> and the marketplace's
F<.claude-plugin/marketplace.json>.  Fails when the pin is older than the
plugin.

Returns HashRef, with C<plugin>, C<latest>, C<pinned>, C<status> and
C<detail>.  The C<status> is C<fail> when it cannot read both versions.

    my $result = App::Clod::Harness::marketplace_check( $plugin_json, $marketplace_json, 'perl-slop' );

=cut

sub marketplace_check ( $plugin_json, $marketplace_json, $plugin ) {
    my $latest  = eval { Mojo::JSON::decode_json($plugin_json)->{version} };
    my $plugins = eval { Mojo::JSON::decode_json($marketplace_json)->{plugins} } // [];
    my ($entry) = grep { ( $_->{name} // q{} ) eq $plugin } @$plugins;
    my $pinned  = $entry ? $entry->{version} : undef;
    my %result  = ( plugin => $plugin, latest => $latest, pinned => $pinned );
    if ( !defined $latest || !defined $pinned ) {
        return { %result, status => 'fail', detail => 'could not read both versions' };
    }
    my $behind = eval { version->declare($pinned) < version->declare($latest) };
    return { %result, status => 'fail', detail => "the marketplace pins $pinned; the plugin is at $latest" } if $behind;
    return { %result, status => 'pass', detail => "the marketplace pins $pinned" };
}

1;

=head1 SYNOPSIS

    use 5.040;
    use App::Clod::GitHub;
    use App::Clod::Harness;

    my ( $repo, $branch ) = ( 'Owner/Name', 'main' );
    my $settings  = { flavor => 'troglodyne-compat', standards => { directory => '/bogus/standards' } };
    my $gh        = App::Clod::GitHub->new;
    my $standards = App::Clod::Harness::standards($settings);
    my $snapshot  = App::Clod::Harness::snapshot( $gh->tree( $repo, $branch ), sub ($path) { $gh->file( $repo, $path, $branch ) } );
    my $result    = App::Clod::Harness::check( $snapshot, $settings, source => $standards );
    say "$_->{status}\t$_->{check}" for @{ $result->{checks} };

=head1 DESCRIPTION

A spoke conforms when its harness meets the standards of its flavor:
CLAUDE.md, the perlcritic profile, the configuration of the tools, the git
hooks, and the Claude Code settings.  L<Dist::Conformance> runs the checks,
from the flavor files of the plugin, on a snapshot of the default branch that
the GitHub API reads.  So the checks are the ones that C<conformance check>
runs in a checkout, and this module does not repeat them.

A spoke names its flavor in its own F<.conformance.yml>.  A spoke without one
gets the C<flavor> of the C<harness> section of F<clod.conf>, from its
C<standards>.

L</workflows> is the one check of this module, because F<clod.conf> and not
the flavor says which workflows a spoke needs.

=cut
