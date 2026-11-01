#!/usr/bin/env perl
use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use FindBin::libs;

use App::Clod::Config();

my %minimal = (
    bot       => 'test-bot',
    workspace => '/bogus/workspace',
    spokes    => ['Test-Org/one'],
    auth      => { trusted_header => 'X-Remote-User' },
);

subtest validate => sub {
    my $config = App::Clod::Config::validate( {%minimal} );
    is( $config->{minion},      'sqlite:/bogus/workspace/minion.db', 'the Minion database defaults to the workspace' );
    is( $config->{bot_email},   'test-bot@users.noreply.github.com', 'the commit address defaults to the no-reply one' );
    is( $config->{claude}{bin}, 'claude',                            'the claude section gets its defaults' );

    my $merged = App::Clod::Config::validate( { %minimal, claude => { model => 'test-model' } } );
    is( $merged->{claude}{model}, 'test-model', 'a section key from the file is kept' );
    ok( scalar @{ $merged->{claude}{allowed_tools} }, 'and the rest of that section still has its defaults' );

    is( $config->{system_prompts}, {}, 'no system prompt by default' );
    ok( lives { App::Clod::Config::validate( { %minimal, system_prompts => { triage => 'Test with the provisioner.' } } ) }, 'a system prompt for a task that runs claude lives' );
    like( dies { App::Clod::Config::validate( { %minimal, system_prompts => { inbox_poll => 'x' } } ) },   qr/does\ not\ run\ claude/, 'a system prompt for a task that runs no claude dies' );
    like( dies { App::Clod::Config::validate( { %minimal, system_prompts => { triage     => ['x'] } } ) }, qr/must\ be\ text/,         'a system prompt that is not text dies' );
    like( dies { App::Clod::Config::validate( { %minimal, system_prompts => 'x' } ) }, qr/must\ be\ a\ hash/, 'system prompts that are not a hash die' );
    is( [ $config->{spoke_prompt}, $config->{tool_spokes}, $config->{claude}{extra_tools} ], [ undef, [], [] ], 'no spoke prompt, tool spokes or extra tools by default' );
    ok( lives { App::Clod::Config::validate( { %minimal, spoke_prompt => 'Test on a guest.' } ) }, 'a spoke prompt that is text lives' );
    like( dies { App::Clod::Config::validate( { %minimal, spoke_prompt => ['x'] } ) }, qr/spoke_prompt\ must\ be\ text/, 'a spoke prompt that is not text dies' );
    is( App::Clod::Config::validate( { %minimal, tool_spokes => ['Test-Org/tools'] } )->{tool_spokes}, ['Test-Org/tools'], 'a tool spoke that is Owner/Name lives' );
    like( dies { App::Clod::Config::validate( { %minimal, tool_spokes => ['tools'] } ) },        qr/tool_spokes\ must\ be\ Owner\/Name,\ not\ 'tools'/, 'a tool spoke that is not Owner/Name dies' );
    like( dies { App::Clod::Config::validate( { %minimal, tool_spokes => [undef] } ) },          qr/must\ be\ Owner\/Name/,                             'so does an undefined one' );
    like( dies { App::Clod::Config::validate( { %minimal, tool_spokes => 'Test-Org/tools' } ) }, qr/tool_spokes\ must\ be\ a\ list/,                    'tool spokes that are not a list die' );
    my $extra = App::Clod::Config::validate( { %minimal, claude => { extra_tools => ['Bash(bin/provision:*)'] } } );
    is( $extra->{claude}{extra_tools}, ['Bash(bin/provision:*)'], 'extra tools are kept' );
    ok( scalar @{ $extra->{claude}{read_tools} }, 'beside the default read tools' );
    like( dies { App::Clod::Config::validate( { %minimal, claude => { extra_tools => 'Bash' } } ) }, qr/extra_tools\ must\ be\ a\ list/,           'extra tools that are not a list die' );
    like( dies { App::Clod::Config::validate( { %minimal, claude => { extra_tools => [ [] ] } } ) }, qr/extra_tools\ must\ be\ a\ list\ of\ text/, 'and so do extra tools that are not text' );
    like( dies { App::Clod::Config::validate( [] ) }, qr/must\ be\ a\ hash/, 'a configuration that is not a hash dies' );

    for my $key (qw{bot workspace auth}) {
        my %without = %minimal;
        delete $without{$key};
        like( dies { App::Clod::Config::validate( \%without ) }, qr/no\ value\ for:\ $key/, "a configuration without $key dies" );
    }
    like( dies { App::Clod::Config::validate( { %minimal, spokes => [] } ) }, qr/names\ no\ spokes\ and\ no\ spoke_orgs/, 'no spokes and no organizations dies' );
    ok( lives { App::Clod::Config::validate( { %minimal, spokes => [], spoke_orgs => ['Test-Org'] } ) }, 'an organization alone lives' );
    like( dies { App::Clod::Config::validate( { %minimal, spoke_orgs => ['Test-Org/one'] } ) }, qr/must\ be\ a\ login/,    'an organization that is a repository dies' );
    like( dies { App::Clod::Config::validate( { %minimal, spokes     => ['nope'] } ) },         qr/must\ be\ Owner\/Name/, 'a spoke that is not Owner/Name dies' );
    like( dies { App::Clod::Config::validate( { %minimal, spokes     => 'Test-Org/one' } ) },   qr/must\ be\ a\ list/,     'spokes that are not a list die' );
    like( dies { App::Clod::Config::validate( { %minimal, auth       => { user => 'u' } } ) },  qr/auth\ needs/,           'basic auth without a password hash dies' );
    ok( lives { App::Clod::Config::validate( { %minimal, auth => { user => 'u', password_sha256 => 'x' } } ) }, 'basic auth with both parts lives' );
};

done_testing;
