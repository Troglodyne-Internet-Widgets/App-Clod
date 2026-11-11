#!/usr/bin/env perl
use 5.040;
no autovivification;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use FindBin::libs;
use File::Temp ();
use Mojo::File ();
use Dist::Conformance::Snapshot();
use Dist::Conformance::Snapshot::Directory();

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

# A critic profile that turns on @policies and no other.
sub profile (@policies) {
    return join q{}, "severity = 1\nonly = 1\n", map { "[$_]\n" } @policies;
}

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

subtest update => sub {
    my $tmp  = File::Temp->newdir;
    my $tree = Mojo::File->new( $tmp->dirname )->child('spoke')->make_path;
    $tree->child('README.md')->spew(q{});
    my $results = App::Clod::Harness::update( $tree, \%settings );
    my %by      = map { $_->{check} => $_ } @$results;
    ok( ( grep { $_->{path} eq 'git-hooks/pre-commit' } @{ $by{GitHooks}{changes} } ), 'the update of an empty spoke writes the hook of the standards' ) or diag Mojo::Util::dumper $results;
    is( $tree->child(qw{git-hooks pre-commit})->slurp, $HOOK, 'into the checkout' );
    my $after = by_check( App::Clod::Harness::check( Dist::Conformance::Snapshot::Directory->new( root => "$tree" ), \%settings ) );
    is( $after->{GitHooks}{status}, 'pass', 'and then the spoke passes the check' );
    my $again = App::Clod::Harness::update( $tree, \%settings );
    is( [ map { @{ $_->{changes} } } @$again ], [], 'and a second update changes nothing' );
};

subtest critic_profiles => sub {
    my @profiles = App::Clod::Harness::critic_profiles( \%settings );
    is( scalar @profiles, 1, 'the standards have one critic profile' );
    like( $profiles[0], qr/^\[ProhibitPipeOpen\]$/m, 'and it is the one of their templates' );
};

subtest new_violations => sub {
    my $tmp  = File::Temp->newdir;
    my $tree = Mojo::File->new( $tmp->dirname )->child('spoke')->make_path;
    is( App::Clod::Harness::new_violations( $tree, '.perlcriticrc', undef ), {}, 'a checkout with no Perl has no violations, and runs no perlcritic' );

    # Policies of Perl::Critic itself, which every perlcritic has.
    my $bareword = 'InputOutput::ProhibitBarewordFileHandles';
    my $magic    = 'ValuesAndExpressions::ProhibitMagicNumbers';
    my $unless   = 'ControlStructures::ProhibitUnlessBlocks';
    my ( $lib, $t ) = map { $tree->child($_)->make_path } qw{lib t};
    $lib->child('Spoke.pm')->spew(qq{package Spoke;\nopen FH, '<', 'x';\nmy \$x = 42;\n1;\n});
    $t->child('spoke.t')->spew(qq{my \$y = 42;\n});
    $tree->child('README.md')->spew(qq{my \$z = 42;\n});
    $tree->child('.perlcriticrc')->spew( profile( $bareword, $magic ) );

    is( App::Clod::Harness::new_violations( $tree, '.perlcriticrc', profile($bareword) ),                    { $magic => [ 'lib/Spoke.pm', 't/spoke.t' ] }, 'a policy that the profile adds counts in each Perl file that breaks it, and one that it had already does not' );
    is( App::Clod::Harness::new_violations( $tree, '.perlcriticrc', profile( $bareword, $magic, $unless ) ), {},                                            'with no policy that the code breaks more than before, there are none' );
    is( App::Clod::Harness::new_violations( $tree, '.perlcriticrc', undef ),                                 { $magic => [ 'lib/Spoke.pm', 't/spoke.t' ] }, 'with no profile before, perlcritic with none, at its default severity, is what the code had' );
    $tree->child('.perlcriticrc')->spew( profile('Test::NoSuchPolicy') );
    like( dies { App::Clod::Harness::new_violations( $tree, '.perlcriticrc', undef ) }, qr/perlcritic/, 'a profile that perlcritic cannot run dies' );
};

subtest tidy => sub {
    my $tmp  = File::Temp->newdir;
    my $tree = Mojo::File->new( $tmp->dirname )->child('spoke')->make_path;
    $tree->child('.perltidyrc')->spew("-l=100\n");
    is( [ App::Clod::Harness::tidy( $tree, '.perltidyrc' ) ], [], 'a checkout with no Perl has nothing to tidy, and runs no perltidy' );

    my ( $lib, $t ) = map { $tree->child($_)->make_path } qw{lib t};
    $lib->child('Messy.pm')->spew(qq{package Messy;\nmy \$x=1+2;\n1;\n});
    $lib->child('Tidy.pm')->spew(qq{package Tidy;\nmy \$x = 1;\n1;\n});
    $t->child('messy.t')->spew(qq{my \$y=3;\n});
    $tree->child('README.md')->spew(qq{my \$z=4;\n});
    is( [ App::Clod::Harness::tidy( $tree, '.perltidyrc' ) ], [ 'lib/Messy.pm', 't/messy.t' ],           'it names the Perl files that it changed, and not one that was tidy already' );
    is( $lib->child('Messy.pm')->slurp,                       qq{package Messy;\nmy \$x = 1 + 2;\n1;\n}, 'which it tidied in place, with the profile' );
    is( $tree->child('README.md')->slurp,                     qq{my \$z=4;\n},                           'and leaves what is not Perl alone' );
    is( [ map { $_->basename } $lib->list->each ],            [qw{Messy.pm Tidy.pm}],                    'and leaves no backup behind' );

    $tree->child('.perltidyrc')->spew("--no-such-perltidy-option\n");
    $lib->child('Messy.pm')->spew(qq{my \$x=1;\n});
    like( dies { App::Clod::Harness::tidy( $tree, '.perltidyrc' ) }, qr/perltidy/, 'a profile that perltidy cannot run dies' );
};

subtest marketplace_check => sub {
    my $plugin = '{"version":"0.11.0"}';
    my $behind = App::Clod::Harness::marketplace_check( $plugin, '{"plugins":[{"name":"test-plugin","version":"0.10.0"}]}', 'test-plugin' );
    is( $behind->{status}, 'fail', 'a pin older than the plugin fails' );
    like( $behind->{detail}, qr/pins\ 0\.10\.0;\ the\ plugin\ is\ at\ 0\.11\.0/, 'and says both versions' );
    is( App::Clod::Harness::marketplace_check( $plugin, '{"plugins":[{"name":"test-plugin","version":"0.11.0"}]}', 'test-plugin' )->{status}, 'pass', 'an equal pin passes' );
    is( App::Clod::Harness::marketplace_check( $plugin, '{"plugins":[{"name":"test-plugin","version":"0.9.10"}]}', 'test-plugin' )->{status}, 'fail', 'versions compare as versions, not strings' );
    my $two = '{"name":"test-plugin","version":"0.10"}';
    is( App::Clod::Harness::marketplace_check( $two,    '{"plugins":[{"name":"test-plugin","version":"0.9"}]}', 'test-plugin' )->{status}, 'fail',                         'and a version with two parts compares as dotted, so 0.9 is older than 0.10' );
    is( App::Clod::Harness::marketplace_check( $plugin, '{"plugins":[]}',                                       'test-plugin' )->{status}, 'fail',                         'a plugin missing from the marketplace fails' );
    is( App::Clod::Harness::marketplace_check( undef,   undef,                                                  'test-plugin' )->{detail}, 'could not read both versions', 'missing files fail' );
};

done_testing;
