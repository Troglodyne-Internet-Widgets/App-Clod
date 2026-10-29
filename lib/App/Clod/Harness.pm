package App::Clod::Harness;

# ABSTRACT: Whether a spoke has the standard agent harness in place

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';

use Mojo::JSON();
use version ();

our $TEMPLATES = 'skills/packaging-perl/templates';

# The first line of the current perlcritic profile, and of the one before it.
our $CURRENT_PROFILE = q{# Troglodyne perlcritic policy, for a distribution that};
our $OLD_PROFILE     = q{# Troglodyne perlcritic policy};
our @HOOKS           = qw{pre-commit post-commit};

my sub has_path ( $snapshot, $path ) { return exists $snapshot->{tree}{$path} }

my sub missing ( $snapshot, @paths ) {
    return grep { !has_path( $snapshot, $_ ) } @paths;
}

my sub json_of ( $snapshot, $path ) {
    my $data = eval { Mojo::JSON::decode_json( $snapshot->{file}->($path) ) };
    return ref $data eq 'HASH' ? $data : undef;
}

# Each check takes the snapshot and the harness settings, and returns
# (status, detail).  Status is pass, fail or info.
our @CHECKS = (
    [
        'CLAUDE.md' => sub ( $snapshot, $ ) {
            return ( 'fail', 'CLAUDE.md is missing' ) if !has_path( $snapshot, 'CLAUDE.md' );
            my $text = $snapshot->{file}->('CLAUDE.md') // q{};
            return ( 'pass', 'names perl-slop:reading-perl' ) if index( $text, 'perl-slop:reading-perl' ) >= 0;
            return ( 'fail', 'CLAUDE.md does not name perl-slop:reading-perl' );
        }
    ],
    [
        'perlcritic profile' => sub ( $snapshot, $ ) {
            return ( 'fail', '.perlcriticrc is missing' ) if !has_path( $snapshot, '.perlcriticrc' );
            my ($first) = split /\n/, $snapshot->{file}->('.perlcriticrc') // q{};
            return ( 'pass', 'current profile' )  if index( $first // q{}, $CURRENT_PROFILE ) == 0;
            return ( 'fail', 'outdated profile' ) if index( $first // q{}, $OLD_PROFILE ) == 0;
            return ( 'fail', 'not a Troglodyne profile' );
        }
    ],
    [
        'tool configuration' => sub ( $snapshot, $ ) {
            my @missing = missing( $snapshot, qw{.perltidyrc .preferred_modules.ini .pod_stopwords .tests-covering-map.pl} );
            return ( 'fail', "missing: @missing" ) if @missing;
            return ( 'pass', 'all present' );
        }
    ],
    [
        'git hooks' => sub ( $snapshot, $ ) {
            my @missing = missing( $snapshot, map { "git-hooks/$_" } @HOOKS );
            return ( 'fail', "missing: @missing" ) if @missing;
            my $templates = $snapshot->{templates} // {};
            my @differ    = grep { $templates->{$_} && $snapshot->{tree}{"git-hooks/$_"}{sha} ne $templates->{$_} } @HOOKS;
            return ( 'info', "customized or outdated: @differ" ) if @differ;
            return ( 'pass', 'match the current templates' );
        }
    ],
    [
        'dist files' => sub ( $snapshot, $ ) {
            return ( 'info', 'no dist.ini' ) if !has_path( $snapshot, 'dist.ini' );
            my @missing = missing( $snapshot, qw{weaver.ini Changes prereqs.yml} );
            return ( 'fail', "missing: @missing" ) if @missing;
            return ( 'pass', 'all present' );
        }
    ],
    [
        '.perl-slop.json' => sub ( $snapshot, $ ) {
            return ( 'info', 'none' ) if !has_path( $snapshot, '.perl-slop.json' );
            my $data    = json_of( $snapshot, '.perl-slop.json' ) // return ( 'fail', 'does not parse' );
            my @unknown = grep { $_ ne 'before_edit' && $_ ne 'before_commit' } sort keys %$data;
            return ( 'fail', "unknown keys: @unknown" ) if @unknown;
            return ( 'pass', 'valid' );
        }
    ],
    [
        'Claude settings' => sub ( $snapshot, $settings ) {
            my $miss = $settings->{require_claude_settings} ? 'fail' : 'info';
            return ( $miss, '.claude/settings.json is missing' ) if !has_path( $snapshot, '.claude/settings.json' );
            my $data = json_of( $snapshot, '.claude/settings.json' ) // return ( 'fail', '.claude/settings.json does not parse' );
            my $key  = "$settings->{plugin}\@$settings->{marketplace}";
            return ( 'pass', "enables $key" ) if ( $data->{enabledPlugins} // {} )->{$key};
            return ( $miss,  "does not enable $key" );
        }
    ],
    [
        'workflows' => sub ( $snapshot, $settings ) {
            my @have   = sort map { m{\A[.]github/workflows/([^/]+)\z} } keys %{ $snapshot->{tree} };
            my @wanted = @{ $settings->{required_workflows} // [] };
            return ( 'info', @have ? "present: @have" : 'none' ) if !@wanted;
            my %have    = map  { $_ => 1 } @have;
            my @missing = grep { !$have{$_} } @wanted;
            return ( 'fail', "missing: @missing" ) if @missing;
            return ( 'pass', 'all present' );
        }
    ],
);

=func check

Returns a list of C<{check, status, detail}>.

=cut

sub check ( $snapshot, $settings ) {
    my @results;
    for my $check (@CHECKS) {
        my ( $name,   $code )   = @$check;
        my ( $status, $detail ) = eval { $code->( $snapshot, $settings ) };
        ( $status, $detail ) = ( 'fail', "the check died: $@" ) if !$status;
        push @results, { check => $name, status => $status, detail => $detail };
    }
    return \@results;
}

=func marketplace_check

C<($plugin_json, $marketplace_json, $plugin)>, the texts of the plugin's
F<.claude-plugin/plugin.json> and the marketplace's
F<.claude-plugin/marketplace.json>.  Fails when the pin is older than the
plugin.

=cut

# The pinned version against the plugin's own.
sub marketplace_check ( $plugin_json, $marketplace_json, $plugin ) {
    my $latest  = eval { Mojo::JSON::decode_json($plugin_json)->{version} };
    my $plugins = eval { Mojo::JSON::decode_json($marketplace_json)->{plugins} } // [];
    my ($entry) = grep { ( $_->{name} // q{} ) eq $plugin } @$plugins;
    my $pinned  = $entry ? $entry->{version} : undef;
    my %result  = ( plugin => $plugin, latest => $latest, pinned => $pinned );
    if ( !defined $latest || !defined $pinned ) {
        return { %result, status => 'fail', detail => 'could not read both versions' };
    }
    my $behind = eval { version->parse($pinned) < version->parse($latest) };
    return { %result, status => 'fail', detail => "the marketplace pins $pinned; the plugin is at $latest" } if $behind;
    return { %result, status => 'pass', detail => "the marketplace pins $pinned" };
}

=head1 SYNOPSIS

    use 5.040;
    use App::Clod::GitHub;
    use App::Clod::Harness;

    my ( $repo, $branch, $settings ) = ( 'Owner/Name', 'main', {} );
    my $gh      = App::Clod::GitHub->new;
    my $results = App::Clod::Harness::check(
        {
            tree      => $gh->tree( $repo, $branch ),
            file      => sub ($path) { $gh->file( $repo, $path, $branch ) },
            templates => { 'pre-commit' => 'a blob SHA', 'post-commit' => 'a blob SHA' },
        },
        $settings,
    );

=head1 DESCRIPTION

A spoke conforms when it has what the packaging-perl skill of the plugin
scaffolds, and the configuration that makes Claude Code load the plugin.  The
checks read a snapshot of the default branch: the recursive tree, which gives
every path and its blob SHA, and a sub that fetches a file's content on demand.

=over

=item CLAUDE.md

It exists and names C<perl-slop:reading-perl>.

=item perlcritic profile

F<.perlcriticrc> starts with the header of the current profile.  The older
header, without the perl version, is an outdated profile.

=item tool configuration

F<.perltidyrc>, F<.preferred_modules.ini>, F<.pod_stopwords> and
F<.tests-covering-map.pl> exist.

=item git hooks

F<git-hooks/pre-commit> and F<git-hooks/post-commit> exist.  If a hook's blob
SHA differs from the template in the plugin, the result is info: the repository
customized it, or it is older.

=item dist files

If F<dist.ini> exists, so do F<weaver.ini>, F<Changes> and F<prereqs.yml>.

=item .perl-slop.json

If it exists, it parses and has only C<before_edit> and C<before_commit>.

=item Claude settings

F<.claude/settings.json> enables the plugin from the marketplace.  This is info
unless C<require_claude_settings> is set.

=item workflows

Each workflow in C<required_workflows> exists under F<.github/workflows>.  With
none required, it lists the ones present.

=back

=cut
