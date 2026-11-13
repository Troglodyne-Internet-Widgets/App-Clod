#!/usr/bin/env perl
use 5.040;
no autovivification;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use FindBin::libs;
use Capture::Tiny qw{capture_stdout};
use File::Temp    ();
use Mojo::File    ();
use Mojo::Util    ();

use App::Clod();
use App::Clod::Evidence();

my $tmp  = File::Temp->newdir;
my $conf = Mojo::File->new( "$tmp", 'clod.conf' );
$conf->spew( Mojo::Util::dumper( { bot => 'test-bot', workspace => "$tmp/ws", evidence => "$tmp/evidence", spokes => ['Test-Org/one'], auth => { trusted_header => 'X-Test-User' } } ) );
my $app = do {
    local $ENV{CLOD_CONFIG} = "$conf";
    App::Clod->new;
};
$app->log->level('fatal');

my $record = App::Clod::Evidence->new( root => "$tmp/evidence", job => 7, attempt => 1 )->recorder( task => 'spoke_fix', dir => '/bogus/work/7', prompt => 'Build a guest.' );
$record->( { type => 'system',    subtype  => 'init' } );
$record->( { type => 'assistant', message  => { content => [ { type => 'text', text => 'Running the preflight.' }, { type => 'tool_use', name => 'Bash', input => { command => 'bin/preflight' } } ] } } );
$record->( { type => 'user',      message  => { content => [ { type => 'tool_result', is_error => 1, content => [ { type => 'text', text => 'x' x 2500 } ] } ] } } );
$record->( { type => 'result',    is_error => 0, result => 'Blocked.', permission_denials => [ { tool_name => 'Bash', tool_input => { command => 'ssh hv' } } ] } );

subtest 'clod evidence' => sub {
    my $out   = capture_stdout { $app->commands->run(qw{evidence 7}) };
    my @lines = split m{\n}, $out;
    is( $lines[0],                '== job 7, attempt 1, run 1',                                             'each run of each attempt has a heading' );
    is( [ @lines[ 1, 2, 3, 4 ] ], [ 'task: spoke_fix', 'dir: /bogus/work/7', 'prompt:', 'Build a guest.' ], 'then what the run was given' );
    like( $lines[5],                                      qr/\A\[\s*\d+[.]\ds\]\ system\ init\z/,               'then each event, after the seconds since the run started' );
    like( $lines[6],                                      qr/says:\ Running\ the\ preflight[.]\z/,              'the text of the model' );
    like( $lines[7],                                      qr/calls\ Bash:\ \{"command":"bin\\\/preflight"\}\z/, 'each call with its input' );
    like( $lines[8],                                      qr/result\ \(error\):\ x{2000}\ \[cut\]\z/,           'each result, cut short, marked when it is an error' );
    like( $lines[9],                                      qr/result:\ Blocked[.]\z/,                            'the result of the run' );
    like( $lines[10],                                     qr/refused:\ .*ssh\ hv/,                              'and each call that claude refused' );
    like( dies { $app->commands->run(qw{evidence 8}) },   qr/job\ 8\ kept\ no\ evidence/,                       'a job that kept nothing says so' );
    like( dies { $app->commands->run(qw{evidence two}) }, qr/Usage:/,                                           'and an argument that is no job id gets the usage' );
};

done_testing;
