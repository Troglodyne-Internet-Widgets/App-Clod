#!/usr/bin/env perl
use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use FindBin::libs;
use File::Temp ();
use Mojo::File ();
use Mojo::JSON ();

use App::Clod::Claude();

my $here   = Mojo::File->new(__FILE__)->dirname->to_abs;
my $fake   = $here->child( 'bin', 'fake-claude' )->to_string;
my $tmp    = File::Temp->newdir;
my $record = "$tmp/record";

sub recorded () { return split /\0/, Mojo::File->new($record)->slurp }

subtest command => sub {
    my $claude = App::Clod::Claude->new( bin => 'test-claude', model => 'test-model', allowed_tools => [ 'Read', 'Bash(git log:*)' ] );
    my $cmd    = $claude->command( add_dirs => [ '/bogus/a', '/bogus/b' ], schema => { type => 'object' }, permission_mode => 'default' );
    is(
        $cmd,
        [
            qw{test-claude -p --output-format stream-json --verbose --model test-model --permission-mode default},
            '--allowedTools', 'Read,Bash(git log:*),Bash(rtk git log:*)',
            qw{--add-dir /bogus/a --add-dir /bogus/b},
            '--json-schema', '{"type":"object"}',
        ],
        'the arguments follow the run, one list element each'
    );
    my $plain = App::Clod::Claude->new( bin => 'test-claude' )->command( tools => [] );
    ok( !( grep { $_ eq '--allowedTools' || $_ eq '--model' } @$plain ), 'no tools and no model add no flags' );
    is( ( grep { $_ eq 'acceptEdits' } @$plain )[0], 'acceptEdits', 'the permission mode defaults to acceptEdits' );

    # The rtk hook rewrites a command before the permission check.
    is(
        [ map { App::Clod::Claude::rtk_too($_) } 'Read', 'Bash(prove:*)', 'Bash(*/bin/provision *)', 'Bash(rtk git:*)' ],
        [ 'Read', 'Bash(prove:*)', 'Bash(rtk prove:*)', 'Bash(*/bin/provision *)', 'Bash(rtk */bin/provision *)', 'Bash(rtk git:*)' ],
        'each Bash rule also allows the command that rtk makes of it, and other rules stay as they are'
    );
};

subtest run => sub {
    my $claude = App::Clod::Claude->new( bin => $fake, env => { FAKE_CLAUDE_RECORD => $record, FAKE_CLAUDE_STREAM => $here->child( 'data', 'stream-ok.jsonl' )->to_string } );
    my @seen;
    my $outcome = $claude->run( dir => "$tmp", prompt => 'the prompt', on_event => sub ($e) { push @seen, $e->{type} } );

    is( $outcome->{ok},                                                 1,               'a clean exit with a good result is ok' ) or diag $outcome->{stderr};
    is( $outcome->{structured},                                         { answer => 4 }, 'the structured answer comes back' );
    is( $outcome->{cost},                                               0.25,            'and the cost' );
    is( $outcome->{usage}{output_tokens},                               381,             'and the usage' );
    is( $outcome->{session_id},                                         'test-session',  'and the session' );
    is( $outcome->{rate_limit}{unifiedWindows}{five_hour}{utilization}, 0.13,            'and the quota windows' );
    ok( !exists $outcome->{quota_reset}, 'an allowed quota sets no reset' );
    is( \@seen, [qw{system assistant rate_limit_event result}], 'each JSON line is an event, and other lines are not' );

    my ( $cwd, $prompt ) = recorded();
    is( $cwd,    "$tmp",       'it runs in the directory it was given' );
    is( $prompt, 'the prompt', 'with the prompt on standard input' );

    is( dies { $claude->run( dir => '/bogus/nowhere', prompt => 'x' ) }, "/bogus/nowhere is not a directory\n", 'a missing directory dies before anything runs' );
    like( dies { $claude->run( dir => "$tmp" ) }, qr/needs\ a\ prompt/, 'so does a missing prompt' );
};

subtest 'run, and the environment of claude' => sub {
    local $ENV{GH_TOKEN}                = 'test-github-token';
    local $ENV{GITHUB_TOKEN}            = 'test-github-token';
    local $ENV{CLAUDE_CODE_OAUTH_TOKEN} = 'test-claude-token';
    my $names  = "$tmp/env-names";
    my $claude = App::Clod::Claude->new( bin => $fake, env => { FAKE_CLAUDE_ENV => $names, FAKE_CLAUDE_STREAM => $here->child( 'data', 'stream-ok.jsonl' )->to_string, TEST_EXTRA => 1 } );
    $claude->run( dir => "$tmp", prompt => 'x' );
    my %seen = map { $_ => 1 } split /\n/, Mojo::File->new($names)->slurp;
    ok( !$seen{GH_TOKEN} && !$seen{GITHUB_TOKEN}, 'claude, and every command it runs, gets no GitHub token' );
    ok( $seen{CLAUDE_CODE_OAUTH_TOKEN},           'but keeps its own token' );
    ok( $seen{TEST_EXTRA},                        'and the extra environment' );
    is( $ENV{GH_TOKEN}, 'test-github-token', 'and the worker keeps the GitHub token for itself' );
};

subtest 'run, as another account' => sub {
    local $ENV{PATH}                    = join q{:}, $here->child( 'bin', 'sudo-dir' ), $here->child('bin'), $ENV{PATH};
    local $ENV{GH_TOKEN}                = 'test-github-token';
    local $ENV{CLAUDE_CODE_OAUTH_TOKEN} = 'test-claude-token';
    local $ENV{FAKE_SUDO_RECORD}        = "$tmp/sudo-account";
    my $names  = "$tmp/env-as-agent";
    my $claude = App::Clod::Claude->new(
        bin    => 'fake-claude',
        run_as => 'test-agent',
        env    => { FAKE_CLAUDE_ENV => $names, FAKE_CLAUDE_RECORD => $record, FAKE_CLAUDE_STREAM => $here->child( 'data', 'stream-ok.jsonl' )->to_string, GH_TOKEN => 'test-github-token' },
    );
    my $outcome = $claude->run( dir => "$tmp", prompt => 'the prompt' );
    is( $outcome->{ok},                              1,            'a run through sudo finds claude on the PATH of the worker, which secure_path replaces' ) or diag $outcome->{stderr};
    is( Mojo::File->new("$tmp/sudo-account")->slurp, 'test-agent', 'and runs as the account of run_as' );
    my %seen = map { $_ => 1 } split /\n/, Mojo::File->new($names)->slurp;
    ok( !$seen{CLAUDE_CODE_OAUTH_TOKEN}, 'the token of the worker does not go through sudo, which would log it' );
    ok( $seen{FAKE_CLAUDE_STREAM},       'and the extra environment' );
    ok( !$seen{GH_TOKEN},                'but not the GitHub token, even when the extra environment names it' );
    my ( $cwd, $prompt ) = recorded();
    is( $cwd,    "$tmp",       'in the directory that it was given' );
    is( $prompt, 'the prompt', 'with the prompt on standard input' );
};

# In -p a call that the permissions do not allow is refused, and the result
# says which.
subtest 'run, with refused calls' => sub {
    my $stream = Mojo::File->new("$tmp/stream-denied.jsonl");
    my @denied = (
        { tool_name => 'Bash',     tool_use_id => 'a', tool_input => { command   => 'rtk git add -A', description => 'Stage' } },
        { tool_name => 'Write',    tool_use_id => 'b', tool_input => { file_path => '/bogus/.git/hooks/pre-commit' } },
        { tool_name => 'WebFetch', tool_use_id => 'c', tool_input => {} },
    );
    $stream->spew( Mojo::JSON::encode_json( { type => 'result', is_error => Mojo::JSON::false, result => 'done', structured_output => {}, total_cost_usd => 0.1, usage => {}, permission_denials => \@denied } ) . "\n" );
    my $outcome = App::Clod::Claude->new( bin => $fake, env => { FAKE_CLAUDE_STREAM => "$stream" } )->run( dir => "$tmp", prompt => 'x' );
    is( $outcome->{ok},     1,                                                                             'a run with refused calls can still end well' );
    is( $outcome->{denied}, [ 'Bash(rtk git add -A)', 'Write(/bogus/.git/hooks/pre-commit)', 'WebFetch' ], 'and it says each refused call, as the rule that would allow it' );

    my $clean = App::Clod::Claude->new( bin => $fake, env => { FAKE_CLAUDE_STREAM => $here->child( 'data', 'stream-ok.jsonl' )->to_string } )->run( dir => "$tmp", prompt => 'x' );
    is( $clean->{denied}, [], 'a run with none refused says none' );
};

subtest 'run, with no newline after the last event' => sub {
    my $claude = App::Clod::Claude->new( bin => $fake, env => { FAKE_CLAUDE_STREAM => $here->child( 'data', 'stream-unterminated.jsonl' )->to_string } );
    my @seen;
    my $outcome = $claude->run( dir => "$tmp", prompt => 'x', on_event => sub ($e) { push @seen, $e->{type} } );
    is( \@seen,                 [qw{system assistant rate_limit_event result}], 'the last event still counts' );
    is( $outcome->{structured}, { answer => 4 },                                'with its answer' );
    is( $outcome->{cost},       0.25,                                           'and its cost' );
};

subtest 'run, with no result' => sub {
    my $claude  = App::Clod::Claude->new( bin => $fake, env => { FAKE_CLAUDE_STREAM => $here->child( 'data', 'stream-no-result.jsonl' )->to_string } );
    my $outcome = $claude->run( dir => "$tmp", prompt => 'x' );
    is( $outcome->{exit}, 0, 'a run that exits zero' );
    is( $outcome->{ok},   0, 'but sends no result is not ok' );
    like( $outcome->{stderr}, qr/\Aclaude\ ended\ without\ a\ result\./, 'and says why' );
};

subtest absorb => sub {
    my %outcome = ( events => 1 );
    App::Clod::Claude::absorb( \%outcome, $_ ) for { type => 'assistant', message => {} }
    , { type => 'test-type-from-a-later-claude' }, {}, { type => 'system', subtype => 'test-subtype', session_id => 'test-session' };
    is( \%outcome, { events => 1 }, 'an event that it does not read leaves the outcome as it is' );
    App::Clod::Claude::absorb( \%outcome, { type => 'system', subtype => 'init', session_id => 'test-session' } );
    is( $outcome{session_id}, 'test-session', 'and the init event gives the session' );
};

subtest ends => sub {
    is( App::Clod::Claude::ends( 'abcdefghij',  5 ), 'abcdefghij',                            'text of twice the length is kept whole' );
    is( App::Clod::Claude::ends( 'abcdefghijk', 5 ), "abcde\n[1 characters left out]\nghijk", 'one character more keeps the first and the last five' );
    is( App::Clod::Claude::ends( q{},           5 ), q{},                                     'and nothing is nothing' );
};

subtest 'run, at the limit' => sub {
    my $claude  = App::Clod::Claude->new( bin => $fake, env => { FAKE_CLAUDE_STREAM => $here->child( 'data', 'stream-limited.jsonl' )->to_string, FAKE_CLAUDE_EXIT => 1 } );
    my $outcome = $claude->run( dir => "$tmp", prompt => 'x' );
    is( $outcome->{ok},          0,          'a run at the limit is not ok' );
    is( $outcome->{exit},        1,          'and keeps its exit code' );
    is( $outcome->{quota_reset}, 1793233200, 'and reports when the quota resets' );
};

subtest 'run, with a refused token' => sub {
    my $claude  = App::Clod::Claude->new( bin => $fake, env => { FAKE_CLAUDE_STREAM => $here->child( 'data', 'stream-unauthorized.jsonl' )->to_string, FAKE_CLAUDE_EXIT => 1 } );
    my $outcome = $claude->run( dir => "$tmp", prompt => 'x' );
    is( $outcome->{ok},           0, 'a run whose token the API refuses is not ok' );
    is( $outcome->{unauthorized}, 1, 'and says that the token was refused' );
    like( $outcome->{result}, qr/401\ Invalid\ bearer\ token/, 'with the reason' );
    ok( !exists $outcome->{quota_reset}, 'and is not taken for the quota' );

    my $limited = App::Clod::Claude->new( bin => $fake, env => { FAKE_CLAUDE_STREAM => $here->child( 'data', 'stream-limited.jsonl' )->to_string, FAKE_CLAUDE_EXIT => 1 } )->run( dir => "$tmp", prompt => 'x' );
    ok( !$limited->{unauthorized}, 'an error that is not a 401 is not a refused token' );
};

subtest plugins => sub {

    # A claude that answers the two plugin commands as the real one does, and
    # records that the marketplaces were refreshed first.
    my $home = Mojo::File->new("$tmp/plugin-home");
    my $bin  = $home->child('claude');
    $home->child( '.claude', 'plugins' )->make_path;
    $bin->spew(<<~'SH');
        #!/bin/sh
        case "$*" in
          'plugin marketplace update') echo refreshed >> "$HOME/log" ;;
          'plugin list --json') grep -q refreshed "$HOME/log" || exit 3; cat "$HOME/installed.json" ;;
          *) exit 2 ;;
        esac
        SH
    chmod 0755, "$bin" or die "chmod $bin: $!";
    my $market = $home->child('market');
    my $meta   = $market->child('.claude-plugin')->make_path;
    $meta->child('marketplace.json')->spew( Mojo::JSON::encode_json( { plugins => [ { name => 'kit', version => '0.14.0' }, { name => 'other', version => '9' } ] } ) );
    $home->child(qw{.claude plugins known_marketplaces.json})->spew( Mojo::JSON::encode_json( { 'test-market' => { installLocation => "$market" }, 'gone-market' => { installLocation => "$home/nowhere" } } ) );
    $home->child('installed.json')->spew( Mojo::JSON::encode_json( [ { id => 'kit@test-market', version => '0.13.0' }, { id => 'lost@gone-market', version => '1.0' } ] ) );

    local $ENV{HOME} = "$home";
    my $plugins = App::Clod::Claude->new( bin => "$bin" )->plugins;
    is(
        $plugins,
        [ { id => 'kit@test-market', version => '0.13.0', latest => '0.14.0' }, { id => 'lost@gone-market', version => '1.0', latest => undef } ],
        'each installed plugin, with the version that its marketplace offers, after a refresh'
    );
    like( dies { App::Clod::Claude->new( bin => "$bin" )->cli(qw{no such}) }, qr/\A\S+\ no\ such:\ failed\n\z/, 'a command of claude that fails dies' );
};

subtest 'the agent lib' => sub {

    # A claude that prints what the agent lib gives each program it runs.
    my $bin = Mojo::File->new("$tmp/lib-claude");
    $bin->spew(qq{#!/bin/sh\nprintf '%s|%s' "\${PERL5LIB:-none}" "\${PATH%%:*}"\n});
    chmod 0755, "$bin" or die "chmod $bin: $!";
    local $ENV{PERL5LIB} = '/bogus/bot-lib/lib/perl5';

    is( App::Clod::Claude->new( bin => "$bin", lib => '/bogus/agent-lib' )->cli('x'), '/bogus/agent-lib/lib/perl5|/bogus/agent-lib/bin', 'claude gets the agent lib first on PERL5LIB and its bin first on PATH' );
    like( App::Clod::Claude->new( bin => "$bin" )->cli('x'), qr/\Anone\|/, 'and without one, no PERL5LIB, so not the modules of the bot' );

    local $ENV{PATH} = join q{:}, $here->child( 'bin', 'sudo-dir' ), $ENV{PATH};
    is( App::Clod::Claude->new( bin => "$bin", lib => '/bogus/agent-lib', run_as => 'test-agent' )->cli('x'), '/bogus/agent-lib/lib/perl5|/bogus/agent-lib/bin', 'also as another account, through sudo, which resets the environment' );
};

subtest 'the own lib of the agent' => sub {

    # A claude that prints the lib path, the first two of PATH, and the own lib.
    my $bin = Mojo::File->new("$tmp/own-lib-claude");
    $bin->spew(qq{#!/bin/sh\nIFS=:; set -- \$PATH; printf '%s|%s:%s|%s' "\$PERL5LIB" "\$1" "\$2" "\${CLOD_OWN_LIB:-none}"\n});
    chmod 0755, "$bin" or die "chmod $bin: $!";
    my %libs   = ( lib => '/bogus/agent-lib', own_lib => '/bogus/own-lib' );
    my $wanted = '/bogus/agent-lib/lib/perl5:/bogus/own-lib/lib/perl5|/bogus/agent-lib/bin:/bogus/own-lib/bin|/bogus/own-lib';
    is( App::Clod::Claude->new( bin => "$bin", %libs )->cli('x'), $wanted, 'comes after the agent lib on PERL5LIB and PATH, so it cannot replace a tool, and CLOD_OWN_LIB names it' );

    local $ENV{PATH} = join q{:}, $here->child( 'bin', 'sudo-dir' ), $ENV{PATH};
    is( App::Clod::Claude->new( bin => "$bin", %libs, run_as => 'test-agent' )->cli('x'), $wanted, 'also through sudo' );
};

subtest is_behind => sub {
    my %cases = (
        'a newer patch'                      => [ '0.13.0', '0.13.1', 1 ],
        'a two-part version, as dotted'      => [ '0.9',    '0.10',   1 ],
        'the same version'                   => [ '1.0',    '1.0',    0 ],
        'an older version offered'           => [ '2.0',    '1.9',    0 ],
        'no version offered'                 => [ '1.0',    undef,    0 ],
        'no version string, but a different' => [ 'beta',   'gamma',  1 ],
    );
    for my $what ( sort keys %cases ) {
        my ( $have, $offered, $behind ) = @{ $cases{$what} };
        is( App::Clod::Claude::is_behind( { version => $have, latest => $offered } ), $behind, $what );
    }
};

subtest 'run, past the timeout' => sub {
    my $slow = "$tmp/slow";
    Mojo::File->new($slow)->spew("#!/bin/sh\nsleep 5\n");
    chmod 0755, $slow or die "chmod $slow: $!";
    my $outcome = App::Clod::Claude->new( bin => $slow, timeout => 1 )->run( dir => "$tmp", prompt => 'x' );
    is( $outcome->{timed_out}, 1, 'a run past the timeout is killed and says so' );
    is( $outcome->{ok},        0, 'and is not ok' );
};

done_testing;
