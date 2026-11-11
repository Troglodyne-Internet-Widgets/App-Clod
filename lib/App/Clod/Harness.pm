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

# perlcritic, found on the PATH, and the directories of a spoke that it reads.
# A program and not Perl::Critic, because the policies are in the libs of the
# agent, which the worker must not load over the modules that it runs on.
our @PERLCRITIC = ('perlcritic');
our @SOURCES    = qw{lib bin script t};

=func default_config

C<($settings)>, the C<harness> section of F<clod.conf>.  The validated
F<.conformance.yml> of a spoke that has none: the C<flavor> of the settings,
from their C<standards>.  Dies as L<Dist::Conformance::Config/validate> does.

=cut

sub default_config ($settings) {
    return Dist::Conformance::Config::validate( { flavor => $settings->{flavor}, source => $settings->{standards} } );
}

=func standards

C<($settings, %options)>.  The L<Dist::Conformance::Source> of
L</default_config>, which a scan builds once and gives to every spoke that has
no F<.conformance.yml>, so a git source is fetched once.  C<cache> is the
directory of its clone.

=cut

sub standards ( $settings, %options ) {
    my $nothing = Dist::Conformance::Snapshot::Tree->new( paths => {}, fetch => sub ($) { return } );
    return conformance( $nothing, $settings, %options )->source;
}

=func snapshot

C<($tree, $fetch)>: what L<App::Clod::GitHub/tree> returns, and a sub that
returns the content of a path.  A L<Dist::Conformance::Snapshot::Tree> of the
files of the tree, without the entries for its directories.

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
sources.

=cut

sub conformance ( $snapshot, $settings, %options ) {
    my %args = ( snapshot => $snapshot );
    $args{cache} = $options{cache} if defined $options{cache};
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

=func check

C<($snapshot, $settings, %options)>, as L</conformance> takes them.  Returns
C<{flavor, chosen, checks}>: the flavor, whether the spoke chose it in its own
F<.conformance.yml>, and a list of C<{check, status, detail}>.  The list is
every check of the flavor, as L<Dist::Conformance/check> returns it, and then
C<workflows>.  Dies when the configuration or the flavor cannot be read, or the
source cannot be fetched.

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

=cut

sub update ( $tree, $settings, %options ) {
    my $conformance = conformance( Dist::Conformance::Snapshot::Directory->new( root => "$tree" ), $settings, %options );
    $conformance->root("$tree");
    return $conformance->update;
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

=cut

sub new_violations ( $tree, $profile, $old ) {
    my @files = map { Mojo::File->new($_)->to_rel("$tree")->to_string } Perl::Critic::Utils::all_perl_files( grep { -d } map { "$tree/$_" } @SOURCES );
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

=cut

sub violations ( $tree, @args ) {
    return split m{\n}, App::Clod::Deps::run( { dir => "$tree", exits => [ 0, 2 ] }, @PERLCRITIC, '--quiet', '--verbose', '%p\t%f\t%l\t%c\n', @args );
}

=func critic_profiles

C<($settings, %options)>, as L</standards> takes them.  The texts of the critic
profiles of the standards, each F<templates/perlcriticrc*> of them, so that
L<App::Clod::Deps/policies> can name the policies that the agent must have.

=cut

sub critic_profiles ( $settings, %options ) {
    my $templates = standards( $settings, %options )->base->child('templates');
    return map { $_->slurp } sort { $a cmp $b } grep { $_->basename =~ m{\Aperlcriticrc} } $templates->list->each;
}

=func marketplace_check

C<($plugin_json, $marketplace_json, $plugin)>, the texts of the plugin's
F<.claude-plugin/plugin.json> and the marketplace's
F<.claude-plugin/marketplace.json>.  Fails when the pin is older than the
plugin.

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
