#!/usr/bin/env perl
use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use FindBin::libs;
use Mojo::File ();
use Dist::Conformance::Snapshot();

use App::Clod::Harness();

my $here      = Mojo::File->new(__FILE__)->dirname->to_abs;
my $STANDARDS = $here->child( 'data', 'standards' );
my $HOOK      = $STANDARDS->child( 'templates', 'pre-commit' )->slurp;

my %settings = ( flavor => 'test-default', standards => { directory => "$STANDARDS" }, required_workflows => [] );

# A tree as App::Clod::GitHub::tree returns one, of %files, and a sub that
# fetches them.  A key sha:PATH gives PATH its blob SHA, and is not itself a file.
sub tree (%files) {
    my %sha;
    for my $key ( grep { index( $_, q{sha:} ) == 0 } keys %files ) {
        $sha{ substr $key, 4 } = delete $files{$key};
    }
    my %tree = map { $_ => { path => $_, type => 'blob', sha => $sha{$_} // Dist::Conformance::Snapshot::blob_sha( $files{$_} ) } } keys %files;
    return ( \%tree, sub ($path) { $files{$path} } );
}

sub snapshot (%files) { return App::Clod::Harness::snapshot( tree(%files) ) }

sub by_check ($result) {
    return { map { $_->{check} => $_ } @{ $result->{checks} } };
}

# Modeled on a repository that has had the whole scaffold of test-default.
my %conforming = (
    'CLAUDE.md'             => "Invoke `perl-slop:reading-perl` first.\n",
    'git-hooks/pre-commit'  => $HOOK,
    '.claude/settings.json' => '{"enabledPlugins":{"test-plugin@test-market":true}}',
);

subtest snapshot => sub {
    my ( $tree, $fetch ) = tree( 'lib/Foo.pm' => "1;\n" );
    $tree->{lib} = { path => 'lib', type => 'tree', sha => 'sha-of-lib' };
    my $snapshot = App::Clod::Harness::snapshot( $tree, $fetch );
    is( [ sort keys %{ $snapshot->paths } ], ['lib/Foo.pm'],             'the snapshot has the files of the tree, and not its directories' );
    is( $snapshot->sha('lib/Foo.pm'),        $tree->{'lib/Foo.pm'}{sha}, 'with their blob SHAs' );
    is( $snapshot->content('lib/Foo.pm'),    "1;\n",                     'and fetches their content' );
};

subtest 'a spoke without .conformance.yml' => sub {
    my $result = App::Clod::Harness::check( snapshot(%conforming), \%settings );
    is( $result->{flavor},                              'test-default',                                   'gets the flavor of the settings' );
    is( $result->{chosen},                              0,                                                'which it did not choose' );
    is( [ map { $_->{check} } @{ $result->{checks} } ], [qw{ClaudeMd ClaudeSettings GitHooks workflows}], 'one result for each check of the flavor, in order, and then workflows' );
    my $all = by_check($result);
    is( $all->{$_}{status}, 'pass', "a conforming spoke passes $_" ) or diag $all->{$_}{detail} for qw{ClaudeMd ClaudeSettings GitHooks};

    my $bare = by_check( App::Clod::Harness::check( snapshot( 'README.md' => q{} ), \%settings ) );
    is( $bare->{ClaudeMd}{status},       'fail', 'an empty spoke fails ClaudeMd' );
    is( $bare->{GitHooks}{status},       'fail', 'and GitHooks' );
    is( $bare->{ClaudeSettings}{status}, 'info', 'and settings that the flavor does not require are info' );

    my $custom = by_check( App::Clod::Harness::check( snapshot( %conforming, 'git-hooks/pre-commit' => "#!/bin/sh\nexit 1\n" ), \%settings ) );
    is( $custom->{GitHooks}{status}, 'info', 'a hook unlike the template is info' );
    like( $custom->{GitHooks}{detail}, qr/pre-commit/, 'and names the hook' );
};

subtest 'the standards of a scan' => sub {
    my $standards = App::Clod::Harness::standards( \%settings );
    is( $standards->base->to_string, "$STANDARDS", 'are the source of the settings' );

    my %elsewhere = ( %settings, standards => { directory => '/bogus/standards' } );
    my $result    = App::Clod::Harness::check( snapshot(%conforming), \%elsewhere, source => $standards );
    is( by_check($result)->{ClaudeMd}{status}, 'pass', 'and a spoke without .conformance.yml reads its flavor from them, not from the settings again' );
    like( dies { App::Clod::Harness::check( snapshot(%conforming), \%elsewhere ) }, qr/bogus/, 'which it would otherwise' );
};

subtest 'a spoke that names its flavor' => sub {
    my $yml = "flavor: test-chosen\nsource:\n  directory: $STANDARDS\n";
    my $own = App::Clod::Harness::check( snapshot( %conforming, '.conformance.yml' => $yml ), \%settings );
    is( $own->{flavor},                              'test-chosen',                              'is held to its own flavor' );
    is( $own->{chosen},                              1,                                          'which it chose' );
    is( [ map { $_->{check} } @{ $own->{checks} } ], [qw{ClaudeMd ToolConfiguration workflows}], 'and runs only the checks of that flavor' );
    is( by_check($own)->{ToolConfiguration}{detail}, 'missing: .perltidyrc',                     'which it can fail' );

    my $skips = App::Clod::Harness::check( snapshot( %conforming, '.conformance.yml' => "${yml}skip:\n  - ToolConfiguration\n" ), \%settings );
    is( by_check($skips)->{ToolConfiguration}{status}, 'skip', 'a check that it skips is skip' );

    like( dies { App::Clod::Harness::check( snapshot( %conforming, '.conformance.yml' => "flavor: test-chosen\n" ),                                 \%settings ) }, qr/source/,    'a .conformance.yml that does not validate dies' );
    like( dies { App::Clod::Harness::check( snapshot( %conforming, '.conformance.yml' => "flavor: test-gone\nsource:\n  directory: $STANDARDS\n" ), \%settings ) }, qr/test-gone/, 'and so does a flavor that the source does not have' );
};

subtest workflows => sub {
    my %flows = ( %conforming, '.github/workflows/ci.yml' => q{} );
    is( [ App::Clod::Harness::workflows( snapshot(%conforming), \%settings ) ],                        [ 'info', 'none' ],              'with none required and none present, workflows are info' );
    is( [ App::Clod::Harness::workflows( snapshot(%flows), \%settings ) ],                             [ 'info', 'present: ci.yml' ],   'with none required, they list the ones present' );
    is( [ App::Clod::Harness::workflows( snapshot(%flows), { required_workflows => ['ci.yml'] } ) ],   [ 'pass', 'all present' ],       'a required workflow that is there passes' );
    is( [ App::Clod::Harness::workflows( snapshot(%flows), { required_workflows => ['lint.yml'] } ) ], [ 'fail', 'missing: lint.yml' ], 'one that is not fails' );
};

subtest marketplace_check => sub {
    my $plugin = '{"version":"0.11.0"}';
    my $behind = App::Clod::Harness::marketplace_check( $plugin, '{"plugins":[{"name":"test-plugin","version":"0.10.0"}]}', 'test-plugin' );
    is( $behind->{status}, 'fail', 'a pin older than the plugin fails' );
    like( $behind->{detail}, qr/pins\ 0\.10\.0;\ the\ plugin\ is\ at\ 0\.11\.0/, 'and says both versions' );
    is( App::Clod::Harness::marketplace_check( $plugin, '{"plugins":[{"name":"test-plugin","version":"0.11.0"}]}', 'test-plugin' )->{status}, 'pass',                         'an equal pin passes' );
    is( App::Clod::Harness::marketplace_check( $plugin, '{"plugins":[{"name":"test-plugin","version":"0.9.10"}]}', 'test-plugin' )->{status}, 'fail',                         'versions compare as versions, not strings' );
    is( App::Clod::Harness::marketplace_check( $plugin, '{"plugins":[]}',                                          'test-plugin' )->{status}, 'fail',                         'a plugin missing from the marketplace fails' );
    is( App::Clod::Harness::marketplace_check( undef,   undef,                                                     'test-plugin' )->{detail}, 'could not read both versions', 'missing files fail' );
};

done_testing;
