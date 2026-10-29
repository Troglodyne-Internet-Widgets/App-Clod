#!/usr/bin/env perl
use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use FindBin::libs;

use App::Clod::Harness();

my %settings = ( plugin => 'test-plugin', marketplace => 'test-market', required_workflows => [], require_claude_settings => 0 );
my %current  = ( 'pre-commit' => 'sha-pre', 'post-commit' => 'sha-post' );

# A snapshot as harness_scan builds one: the tree, the template SHAs, and the files.
sub snapshot (%files) {

    # A key sha:PATH gives PATH its blob SHA, and is not itself a file.
    my %sha;
    for my $key ( grep { index( $_, q{sha:} ) == 0 } keys %files ) {
        $sha{ substr $key, 4 } = delete $files{$key};
    }
    my %tree = map { $_ => { path => $_, sha => $sha{$_} // "sha-of-$_" } } keys %files;
    return { tree => \%tree, templates => \%current, file => sub ($path) { $files{$path} } };
}

sub by_check ( $snapshot, $over = {} ) {
    return { map { $_->{check} => $_ } @{ App::Clod::Harness::check( $snapshot, { %settings, %$over } ) } };
}

# Modeled on a repository that has had the whole scaffold.
my %conforming = (
    'CLAUDE.md'                 => "Invoke `perl-slop:reading-perl` first.\n",
    '.perlcriticrc'             => "# Troglodyne perlcritic policy, for a distribution that declares use 5.040 or\n",
    '.perltidyrc'               => q{},
    '.preferred_modules.ini'    => q{},
    '.pod_stopwords'            => q{},
    '.tests-covering-map.pl'    => q{},
    'git-hooks/pre-commit'      => q{},
    'git-hooks/post-commit'     => q{},
    'sha:git-hooks/pre-commit'  => 'sha-pre',
    'sha:git-hooks/post-commit' => 'sha-post',
    'dist.ini'                  => q{},
    'weaver.ini'                => q{},
    'Changes'                   => q{},
    'prereqs.yml'               => q{},
    '.claude/settings.json'     => '{"enabledPlugins":{"test-plugin@test-market":true}}',
);

subtest check => sub {
    my $all = by_check( snapshot(%conforming) );
    is( [ map { $_->{check} } @{ App::Clod::Harness::check( snapshot(%conforming), \%settings ) } ], [ map { $_->[0] } @App::Clod::Harness::CHECKS ], 'one result per check, in order' );
    for my $name ( 'CLAUDE.md', 'perlcritic profile', 'tool configuration', 'git hooks', 'dist files', 'Claude settings' ) {
        is( $all->{$name}{status}, 'pass', "a conforming repo passes $name" ) or diag $all->{$name}{detail};
    }
    is( $all->{'.perl-slop.json'}{status}, 'info', 'no .perl-slop.json is only info' );
    is( $all->{workflows}{status},         'info', 'with none required, workflows are info' );

    my $bare = by_check( snapshot( 'README.md' => q{} ) );
    is( $bare->{$_}{status},                                                                                       'fail', "an empty repo fails $_" ) for ( 'CLAUDE.md', 'perlcritic profile', 'tool configuration', 'git hooks' );
    is( $bare->{'dist files'}{status},                                                                             'info', 'no dist.ini is only info' );
    is( $bare->{'Claude settings'}{status},                                                                        'info', 'no settings is info when they are not required' );
    is( by_check( snapshot( 'README.md' => q{} ), { require_claude_settings => 1 } )->{'Claude settings'}{status}, 'fail', 'and fail when they are' );

    my $old = by_check( snapshot( %conforming, '.perlcriticrc' => "# Troglodyne perlcritic policy\n\nseverity = 1\n" ) );
    is( $old->{'perlcritic profile'}{detail}, 'outdated profile', 'the old header is an outdated profile' );

    my $custom = by_check( snapshot( %conforming, 'sha:git-hooks/pre-commit' => 'sha-local' ) );
    is( $custom->{'git hooks'}{status}, 'info', 'a hook unlike the template is info' );
    like( $custom->{'git hooks'}{detail}, qr/pre-commit/, 'and names the hook' );

    delete local $conforming{Changes};
    is( by_check( snapshot(%conforming) )->{'dist files'}{detail}, 'missing: Changes', 'a dist.ini without Changes fails' );

    is( by_check( snapshot( %conforming, '.perl-slop.json' => '{"before_edit":{}}' ) )->{'.perl-slop.json'}{status}, 'pass',                'a valid .perl-slop.json passes' );
    is( by_check( snapshot( %conforming, '.perl-slop.json' => '{"other":1}' ) )->{'.perl-slop.json'}{detail},        'unknown keys: other', 'an unknown key fails' );
    is( by_check( snapshot( %conforming, '.perl-slop.json' => '{' ) )->{'.perl-slop.json'}{detail},                  'does not parse',      'bad JSON fails' );

    my %flows = ( %conforming, '.github/workflows/ci.yml' => q{} );
    is( by_check( snapshot(%flows), { required_workflows => ['ci.yml'] } )->{workflows}{status},   'pass',              'a required workflow that is there passes' );
    is( by_check( snapshot(%flows), { required_workflows => ['lint.yml'] } )->{workflows}{detail}, 'missing: lint.yml', 'one that is not fails' );

    my $broken = App::Clod::Harness::check( { tree => {}, file => sub { die 'boom' } }, \%settings );
    ok( scalar @$broken, 'a check that dies still gives a result for every check' );
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
