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

my $INVALID = qr/\AThe\ configuration\ is\ not\ valid:\n/;
my $LINES   = qr/(?:.*\n)*?/;

sub refused ( $config, $error, $name ) {
    my $died = ( dies { App::Clod::Config::validate($config) } ) // q{};
    return like( $died, qr/$INVALID$LINES\ \ \Q$error\E/, $name );
}

my $HASH = 'f' x 64;

subtest validate => sub {
    my $config = App::Clod::Config::validate( {%minimal} );
    is( $config->{minion},      'sqlite:/bogus/workspace/minion.db', 'the Minion database defaults to the workspace' );
    is( $config->{bot_email},   'test-bot@users.noreply.github.com', 'the commit address defaults to the no-reply one' );
    is( $config->{claude}{bin}, 'claude',                            'the claude section gets its defaults' );

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
    is( [ $config->{spoke_prompt}, $config->{tool_spokes}, $config->{claude}{extra_tools} ], [ undef, [], [] ], 'no spoke prompt, tool spokes or extra tools by default' );
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

    for my $key (qw{bot workspace auth}) {
        my %without = %minimal;
        delete $without{$key};
        refused( \%without, "/$key: Missing property.", "a configuration without $key dies" );
    }
    like( dies { App::Clod::Config::validate( { %minimal, spokes => [] } ) }, qr/names\ no\ spokes\ and\ no\ spoke_orgs/, 'no spokes and no organizations dies' );
    ok( lives { App::Clod::Config::validate( { %minimal, spokes => [], spoke_orgs => ['Test-Org'] } ) }, 'an organization alone lives' );
    refused( { %minimal, spoke_orgs => ['Test-Org/one'] },                             '/spoke_orgs/0: String does not match',         'an organization that is a repository dies' );
    refused( { %minimal, spokes     => ['nope'] },                                     '/spokes/0: String does not match',             'a spoke that is not Owner/Name dies' );
    refused( { %minimal, spokes     => 'Test-Org/one' },                               '/spokes: Expected array',                      'spokes that are not a list die' );
    refused( { %minimal, auth       => { user => 'u' } },                              '/auth/password_sha256: /anyOf/1 Missing',      'basic auth without a password hash dies' );
    refused( { %minimal, auth       => { user => 'u', password_sha256 => uc $HASH } }, '/auth/password_sha256: String does not match', 'and so does a hash that is not lowercase hex, which no password matches' );
    ok( lives { App::Clod::Config::validate( { %minimal, auth => { user => 'u', password_sha256 => $HASH } } ) }, 'basic auth with both parts lives' );
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
