#!/usr/bin/env perl
use 5.040;
no autovivification;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use FindBin::libs;

use App::Clod::Config();
use App::Clod::Tasks();

my %minimal = (
    bot       => 'test-bot',
    workspace => '/bogus/workspace',
    spokes    => ['Test-Org/one'],
    auth      => { trusted_header => 'X-Remote-User' },
);

my $INVALID = qr/\AThe\ configuration\ is\ not\ valid:\n/;
my $LINES   = qr/(?:.*\n)*?/;

sub refused ( $config, $error, $name ) {
    my $died = ( dies { App::Clod::Config::validate($config) } ) // q{};
    return like( $died, qr/$INVALID$LINES\ \ \Q$error\E/, $name );
}

my $HASH = 'f' x 64;

subtest validate => sub {
    my $config = App::Clod::Config::validate( {%minimal} );
    is( $config->{minion},        'sqlite:/bogus/workspace/minion.db', 'the Minion database defaults to the workspace' );
    is( $config->{bot_email},     'test-bot@users.noreply.github.com', 'the commit address defaults to the no-reply one' );
    is( $config->{claude}{bin},   'claude',                            'the claude section gets its defaults' );
    is( $config->{agent_own_lib}, undef,                               'with no agent lib, the agent has no own lib' );
    ok( ( grep { $_ eq 'Bash(clod-cpm:*)' } @{ $config->{claude}{allowed_tools} } ), 'a run that changes a repository may install a module into it' );
    is( App::Clod::Config::validate( { %minimal, agent_lib => '/bogus/agent-perl5' } )->{agent_own_lib}, '/bogus/workspace/agent-own-lib', 'and with one, its own lib is in the workspace, which the agent can write' );

    my $merged = App::Clod::Config::validate( { %minimal, claude => { model => 'test-model' } } );
    is( $merged->{claude}{model}, 'test-model', 'a section key from the file is kept' );
    ok( scalar @{ $merged->{claude}{allowed_tools} }, 'and the rest of that section still has its defaults' );

    is( $config->{claude}{run_as},                                                                           undef,        'claude runs as the worker by default' );
    is( App::Clod::Config::validate( { %minimal, claude => { run_as => 'test-agent' } } )->{claude}{run_as}, 'test-agent', 'or as the account that run_as names' );
    refused( { %minimal, claude => { run_as => '-test' } }, '/claude/run_as: String does not match', 'an account that sudo would take for an option dies' );
    refused( { %minimal, claude => { run_as => '#0' } },    '/claude/run_as: String does not match', 'and so does a uid' );

    is( $config->{system_prompts}, {}, 'no system prompt by default' );
    ok( lives { App::Clod::Config::validate( { %minimal, system_prompts => { triage => 'Test with the provisioner.' } } ) }, 'a system prompt for a task that runs claude lives' );
    refused( { %minimal, system_prompts => { inbox_poll => 'x' } },   '/system_prompts: Properties not allowed: inbox_poll.', 'a system prompt for a task that runs no claude dies' );
    refused( { %minimal, system_prompts => { triage     => ['x'] } }, '/system_prompts/triage: Expected string',              'a system prompt that is not text dies' );
    refused( { %minimal, system_prompts => 'x' }, '/system_prompts: Expected object', 'system prompts that are not a hash die' );
    is( [ $config->@{qw{spoke_prompt tool_spokes}}, $config->{claude}{extra_tools} ], [ undef, [], [] ], 'no spoke prompt, tool spokes or extra tools by default' );
    ok( lives { App::Clod::Config::validate( { %minimal, spoke_prompt => 'Test on a guest.' } ) }, 'a spoke prompt that is text lives' );
    refused( { %minimal, spoke_prompt => ['x'] }, '/spoke_prompt: Expected string', 'a spoke prompt that is not text dies' );
    is( App::Clod::Config::validate( { %minimal, tool_spokes => ['Test-Org/tools'] } )->{tool_spokes}, ['Test-Org/tools'], 'a tool spoke that is Owner/Name lives' );
    refused( { %minimal, tool_spokes => ['tools'] },        '/tool_spokes/0: String does not match', 'a tool spoke that is not Owner/Name dies' );
    refused( { %minimal, tool_spokes => [undef] },          '/tool_spokes/0: Expected string',       'so does an undefined one' );
    refused( { %minimal, tool_spokes => 'Test-Org/tools' }, '/tool_spokes: Expected array',          'tool spokes that are not a list die' );
    my $extra = App::Clod::Config::validate( { %minimal, claude => { extra_tools => ['Bash(bin/provision:*)'] } } );
    is( $extra->{claude}{extra_tools}, ['Bash(bin/provision:*)'], 'extra tools are kept' );
    ok( scalar @{ $extra->{claude}{read_tools} }, 'beside the default read tools' );
    refused( { %minimal, claude => { extra_tools => 'Bash' } }, '/claude/extra_tools: Expected array',    'extra tools that are not a list die' );
    refused( { %minimal, claude => { extra_tools => [ [] ] } }, '/claude/extra_tools/0: Expected string', 'and so do extra tools that are not text' );
    like( dies { App::Clod::Config::validate( [] ) }, qr/must\ be\ a\ hash/, 'a configuration that is not a hash dies' );

    is( $config->{system_packages}, undef, 'no system packages by default, so the feature is off' );
    my %packages = ( packager => 'deb', installer => '/usr/local/sbin/clod-install-packages' );
    is( App::Clod::Config::validate( { %minimal, system_packages => \%packages } )->{system_packages}, \%packages, 'a packager and an installer live' );
    refused( { %minimal, system_packages => { %packages, packager  => 'rpm' } },        '/system_packages/packager: Not in enum list',       'a packager that the bot cannot ask about dies' );
    refused( { %minimal, system_packages => { %packages, installer => 'install-it' } }, '/system_packages/installer: String does not match', 'and so does an installer that is not an absolute path, which sudo finds on no PATH' );
    refused( { %minimal, system_packages => { packager => 'deb' } }, '/system_packages/installer: Missing property.', 'and a packager without an installer' );

    for my $key (qw{bot workspace auth}) {
        my %without = %minimal;
        delete $without{$key};
        refused( \%without, "/$key: Missing property.", "a configuration without $key dies" );
    }
    is( dies { App::Clod::Config::validate( { %minimal, spokes => [] } ) }, "The configuration names no spokes and no spoke_orgs\n", 'no spokes and no organizations dies, with no file or line' );
    ok( lives { App::Clod::Config::validate( { %minimal, spokes => [], spoke_orgs => ['Test-Org'] } ) }, 'an organization alone lives' );
    refused( { %minimal, spoke_orgs => ['Test-Org/one'] },                             '/spoke_orgs/0: String does not match',         'an organization that is a repository dies' );
    refused( { %minimal, spokes     => ['nope'] },                                     '/spokes/0: String does not match',             'a spoke that is not Owner/Name dies' );
    refused( { %minimal, spokes     => 'Test-Org/one' },                               '/spokes: Expected array',                      'spokes that are not a list die' );
    refused( { %minimal, auth       => { user => 'u' } },                              '/auth/password_sha256: /anyOf/1 Missing',      'basic auth without a password hash dies' );
    refused( { %minimal, auth       => { user => 'u', password_sha256 => uc $HASH } }, '/auth/password_sha256: String does not match', 'and so does a hash that is not lowercase hex, which no password matches' );
    ok( lives { App::Clod::Config::validate( { %minimal, auth => { user => 'u', password_sha256 => $HASH } } ) }, 'basic auth with both parts lives' );
};

subtest 'the tools of a run that changes a spoke' => sub {
    my $config  = App::Clod::Config::validate( {%minimal} );
    my $cmd     = App::Clod::Tasks::claude($config)->command;
    my ($i)     = grep { $cmd->[$_] eq '--allowedTools' } 0 .. $#$cmd;
    my %allowed = map  { $_ => 1 } split /,/, $cmd->[ $i + 1 ];
    for my $program (qw{perlcritic perltidy make strace gdb nytprofhtml nytprofmerge}) {
        ok( $allowed{"Bash($program:*)"} && $allowed{"Bash(rtk $program:*)"}, "claude may run $program, also through rtk" );
    }
    my %read = map { $_ => 1 } @{ $config->{claude}{read_tools} };
    ok( !$read{'Bash(perltidy:*)'},                       'and a run that only reads may not, because perltidy rewrites files' );
    ok( !( grep { $read{"Bash($_:*)"} } qw{strace gdb} ), q{nor may it trace or debug, because strace and gdb each run a program of their choosing} );
};

subtest create_repos => sub {
    ok( !App::Clod::Config::validate( {%minimal} )->{create_repos},                                                 'no repository is made unless the configuration turns it on' );
    ok( App::Clod::Config::validate( { %minimal, spoke_orgs => ['Test-Org'], create_repos => 1 } )->{create_repos}, 'with spoke_orgs, it can be' );
    like(
        dies { App::Clod::Config::validate( { %minimal, create_repos => 1 } ) },
        qr/\Acreate_repos\ needs\ spoke_orgs/,
        'without spoke_orgs it dies, because a new repository would not stay a spoke'
    );
    like( dies { App::Clod::Config::validate( { %minimal, spoke_orgs => ['Test-Org'], create_repos => { orgs => ['Test-Org'] } } ) }, qr{/create_repos:}, 'orgs and max are gone, so the old form dies' );
};

subtest follow_up_max => sub {
    is( App::Clod::Config::validate( {%minimal} )->{follow_up_max},                       3, 'a request may have three follow-up issues filed by default' );
    is( App::Clod::Config::validate( { %minimal, follow_up_max => 0 } )->{follow_up_max}, 0, 'and 0 lives, which turns filing off' );
    refused( { %minimal, follow_up_max => -1 }, '/follow_up_max: -1 < minimum(0)', 'a cap below none dies' );
};

subtest 'the standards of the harness' => sub {
    my $config = App::Clod::Config::validate( {%minimal} );
    is( $config->{harness}{flavor}, 'troglodyne-compat', 'a spoke without .conformance.yml is held to troglodyne-compat' );
    is(
        $config->{harness}{standards},
        { git => 'https://github.com/Troglodyne-Internet-Widgets/perl-slop-plugin.git', path => 'skills/packaging-perl' },
        'from the packaging-perl skill of the plugin'
    );
    my $forge = App::Clod::Config::validate( { %minimal, github_web => 'https://forge.test.test', harness => { plugin_repo => 'Test-Org/test-plugin' } } );
    is( $forge->{harness}{standards}{git}, 'https://forge.test.test/Test-Org/test-plugin.git', 'which is the plugin_repo on github_web' );
    my $set = { directory => '/bogus/standards', path => 'here' };
    is( App::Clod::Config::validate( { %minimal, harness => { standards => $set } } )->{harness}{standards}, $set, 'standards that the file sets are kept' );
    like( dies { App::Clod::Config::validate( { %minimal, harness => { standards => { path => 'here' } } } ) }, qr/conformance/, 'and standards that are not a source die' );
};

subtest 'keys that the schema does not name' => sub {
    refused( { %minimal, spoke  => ['Test-Org/one'] }, '/: Properties not allowed: spoke.', 'a misspelled key dies' );
    refused( { %minimal, claude => { modle     => 'm' } }, '/claude: Properties not allowed: modle.', 'and so does one inside a section' );
    refused( { %minimal, otel   => { OTEL_TEST => [] } },  '/otel/OTEL_TEST: Expected string',        'an OpenTelemetry variable must be text' );
};

subtest 'what validate shares' => sub {
    my %raw   = ( %minimal, claude => { model => 'test-model' } );
    my $first = App::Clod::Config::validate( \%raw );
    is( [ sort keys %{ $raw{claude} } ], ['model'], 'the hash it was given gets no defaults' );

    push @{ $first->{claude}{allowed_tools} }, 'Bash(test-tool:*)';
    my $second = App::Clod::Config::validate( {%minimal} );
    ok( !( grep { $_ eq 'Bash(test-tool:*)' } @{ $second->{claude}{allowed_tools} } ), 'a change to one result reaches no later one' );
};

done_testing;
