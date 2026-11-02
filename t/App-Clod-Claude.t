#!/usr/bin/env perl
use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use FindBin::libs;
use File::Temp ();
use Mojo::File ();

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
            '--allowedTools', 'Read,Bash(git log:*)',
            qw{--add-dir /bogus/a --add-dir /bogus/b},
            '--json-schema', '{"type":"object"}',
        ],
        'the arguments follow the run, one list element each'
    );
    my $plain = App::Clod::Claude->new( bin => 'test-claude' )->command( tools => [] );
    ok( !( grep { $_ eq '--allowedTools' || $_ eq '--model' } @$plain ), 'no tools and no model add no flags' );
    is( ( grep { $_ eq 'acceptEdits' } @$plain )[0], 'acceptEdits', 'the permission mode defaults to acceptEdits' );
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

    like( dies { $claude->run( dir => '/bogus/nowhere', prompt => 'x' ) }, qr/not\ a\ directory/, 'a missing directory dies before anything runs' );
    like( dies { $claude->run( dir => "$tmp" ) },                          qr/needs\ a\ prompt/,  'so does a missing prompt' );
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
    ok( $seen{CLAUDE_CODE_OAUTH_TOKEN}, 'claude gets its token through the reset environment of sudo' );
    ok( $seen{FAKE_CLAUDE_STREAM},      'and the extra environment' );
    ok( !$seen{GH_TOKEN},               'but not the GitHub token, even when the extra environment names it' );
    my ( $cwd, $prompt ) = recorded();
    is( $cwd,    "$tmp",       'in the directory that it was given' );
    is( $prompt, 'the prompt', 'with the prompt on standard input' );
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

subtest 'run, past the timeout' => sub {
    my $slow = "$tmp/slow";
    Mojo::File->new($slow)->spew("#!/bin/sh\nsleep 5\n");
    chmod 0755, $slow or die "chmod $slow: $!";
    my $outcome = App::Clod::Claude->new( bin => $slow, timeout => 1 )->run( dir => "$tmp", prompt => 'x' );
    is( $outcome->{timed_out}, 1, 'a run past the timeout is killed and says so' );
    is( $outcome->{ok},        0, 'and is not ok' );
};

done_testing;
