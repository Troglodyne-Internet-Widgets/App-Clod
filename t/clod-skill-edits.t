#!/usr/bin/env perl
use 5.040;
no autovivification;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use File::Temp ();
use IPC::Run   ();
use Mojo::File ();
use Mojo::JSON ();

# The hook runs as claude runs it: a program that reads a request on its
# standard input, and prints a decision or nothing.
my $t    = Mojo::File->new(__FILE__)->to_abs->dirname;
my $hook = $t->sibling(qw{share agent-bin clod-skill-edits});
my $tmp  = Mojo::File->new( File::Temp->newdir->dirname )->child("clod-skill-edits-$$");
$tmp = $tmp->make_path->realpath;
END { $tmp->remove_tree if $tmp }

my $tree   = $tmp->child('tree');
my $skills = $tree->child(qw{.claude skills});
$skills->child('recipes')->make_path;
$skills->child(qw{recipes SKILL.md})->spew("old\n");
$tree->child(qw{.claude settings.json})->spew("{}\n");
my $home = $tmp->child(qw{home .claude skills mine})->make_path;
$tmp->child('elsewhere')->make_path;
$tmp->child(qw{elsewhere SKILL.md})->spew("old\n");

# What the hook says to a call of $tool on $path, in the work tree $dir.
sub decision ( $tool, $path, $dir = $tree, %input ) {
    my $request = Mojo::JSON::encode_json( { hook_event_name => 'PermissionRequest', cwd => "$dir", tool_name => $tool, tool_input => { file_path => "$path", %input } } );
    my ( $out, $err ) = ( q{}, q{} );
    IPC::Run::run( [ $^X, "$hook", "$dir" ], '<', \$request, '>', \$out, '2>', \$err ) or die "the hook failed: $err";
    return q{nothing} if $out eq q{};
    my $said = Mojo::JSON::decode_json($out);
    return $said->{hookSpecificOutput}{decision}{behavior};
}

subtest 'inside the skills of the work tree' => sub {
    is( decision( Edit  => $skills->child(qw{recipes SKILL.md}) ),   'allow', 'an edit of a skill of the work tree is allowed' );
    is( decision( Write => $skills->child(qw{recipes notes.md}) ),   'allow', 'and a new file of a skill' );
    is( decision( Write => $skills->child(qw{new-skill SKILL.md}) ), 'allow', 'and a new file in a directory of a skill that does not exist yet' );

    my $bare = $tmp->child('bare')->make_path;
    is( decision( Write => $bare->child(qw{.claude skills first SKILL.md}), $bare ), 'allow', 'and the first skill of a work tree that has no .claude yet' );

    my $alias = $tmp->child('alias');
    symlink "$tree", "$alias" or die "symlink: $!";
    is( decision( Edit => $alias->child(qw{.claude skills recipes SKILL.md}), $alias ), 'allow', 'and a work tree that its run names through a link' );
};

subtest 'out of the skills of the work tree' => sub {
    is( decision( Edit  => $tree->child(qw{.claude settings.json}) ),     'nothing', 'the settings of the work tree get no decision' );
    is( decision( Write => $tree->child(qw{.claude hooks pre.sh}) ),      'nothing', 'nor its hooks' );
    is( decision( Write => $tree->child(qw{.git hooks pre-commit}) ),     'nothing', 'nor its git hooks' );
    is( decision( Write => $tree->child(qw{.claude skills-x SKILL.md}) ), 'nothing', 'nor a directory whose name only starts like skills' );
    is( decision( Write => $skills ),                                     'nothing', 'nor the directory of the skills itself' );
    is( decision( Write => $skills->child(qw{.. settings.json}) ),        'nothing', 'nor .. out of the skills, to a file that exists' );
    is( decision( Write => $skills->child(qw{nope .. .. agents.md}) ),    'nothing', 'nor .. out of the skills, through a directory that does not exist' );
    is( decision( Write => "$skills/recipes/" ),                          'nothing', 'nor a directory of a skill, which no edit writes' );
    is( decision( Write => '.claude/skills/recipes/SKILL.md' ),           'nothing', 'nor a relative path' );
    is( decision( Write => $tmp->child(qw{other .claude skills x.md}) ),  'nothing', 'nor the skills of another directory' );
    is( decision( Write => $home->child('SKILL.md') ),                    'nothing', 'nor the skills of the account' );
};

subtest 'links out of the skills' => sub {
    symlink $tmp->child('elsewhere')->to_string, $skills->child('out')->to_string or die "symlink: $!";
    is( decision( Edit => $skills->child(qw{out SKILL.md}) ), 'nothing', 'a link in the skills to a directory elsewhere gets no decision' );

    symlink $tmp->child(qw{nowhere SKILL.md})->to_string, $skills->child('dangling')->to_string or die "symlink: $!";
    is( decision( Write => $skills->child('dangling') ), 'nothing', 'nor a link that points nowhere, which a write would create elsewhere' );

    link $tmp->child(qw{elsewhere SKILL.md})->to_string, $skills->child(qw{recipes linked.md})->to_string or die "link: $!";
    is( decision( Edit => $skills->child(qw{recipes linked.md}) ), 'nothing', 'nor a second name of a file elsewhere' );

    my $linked = $tmp->child('linked-tree')->make_path;
    $linked->child('.claude')->make_path;
    symlink $home->dirname->to_string, $linked->child(qw{.claude skills})->to_string or die "symlink: $!";
    is( decision( Write => $linked->child(qw{.claude skills mine SKILL.md}), $linked ), 'nothing', 'nor skills of a work tree that link to the skills of the account' );
};

subtest 'other tools and other requests' => sub {
    my $skill = $skills->child(qw{recipes SKILL.md});
    is( decision( $_ => $skill ), 'nothing', "$_ gets no decision, even on a skill" ) for qw{Read Bash NotebookEdit MultiEdit};

    my ( $out, $err ) = ( q{}, q{} );
    IPC::Run::run( [ $^X, "$hook", "$tree" ], '<', \'not json', '>', \$out, '2>', \$err );
    is( [ $? >> 8, $out ], [ 0, q{} ], 'a request that is no JSON gets no decision, and the hook succeeds' );
    IPC::Run::run( [ $^X, "$hook" ], '<', \Mojo::JSON::encode_json( { tool_name => 'Edit', tool_input => { file_path => "$skill" } } ), '>', \$out );
    is( $out, q{}, 'and a hook that is given no work tree decides nothing' );
};

done_testing;
