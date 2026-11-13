#!/usr/bin/env perl
use 5.040;
no autovivification;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use FindBin::libs;
use File::Temp  ();
use List::Util  ();
use Mojo::File  ();
use Time::HiRes qw{time};

use App::Clod::Evidence();

my $tmp  = Mojo::File->new( File::Temp->newdir->dirname )->child( 'clod-evidence-' . $$ )->make_path;
my $root = $tmp->child('evidence');
END { $tmp->remove_tree if $tmp }

my $DAY = 86_400;

sub evidence (%args) { return App::Clod::Evidence->new( root => "$root", job => 41, %args ) }

subtest recorder => sub {
    my $before = time;
    my $record = evidence()->recorder( task => 'spoke_fix', prompt => 'Fix it.' );
    $record->( { type => 'system', subtype => 'init' } );
    $record->( { type => 'result', result  => 'done' } );

    my $runs = evidence()->runs;
    is( scalar @$runs,                                         1,                                            'one run, one transcript' );
    is( $runs->[0][0]{run},                                    { task => 'spoke_fix', prompt => 'Fix it.' }, 'which starts with what the run was given' );
    is( [ map { $_->{event}{type} } @{ $runs->[0] }[ 1, 2 ] ], [qw{system result}],                          'and then each event, in the order that it arrived' );
    ok( ( List::Util::all { $_->{at} >= $before && $_->{at} <= time } @{ $runs->[0] } ), 'each line says when it arrived' );

    is( sprintf( '%04o', $root->stat->mode & oct 7777 ), '0700', 'nobody but the worker can enter the evidence' );
    my $first = evidence()->dir->child('01.jsonl');
    is( sprintf( '%04o', $first->stat->mode & oct 7777 ), '0600', 'or read a transcript' );

    chmod oct 750, "$root";
    evidence()->recorder( task => 'spoke_fix' )->( { type => 'result' } );
    is( sprintf( '%04o', $root->stat->mode & oct 7777 ), '0700', 'a directory that somebody opened up is closed again' );
    is( scalar @{ evidence()->runs },                    2,      'a second run of the attempt gets a transcript of its own' );

    evidence( attempt => 1 )->recorder( task => 'spoke_fix' );
    is( scalar @{ evidence( attempt => 1 )->runs }, 1, 'and the next attempt starts its own count' );
    is( scalar @{ evidence()->runs },               2, 'beside the first' );
};

subtest discard => sub {
    evidence()->discard;
    is( evidence()->runs, [], 'the attempt is gone' );
    ok( -d evidence( attempt => 1 )->dir, 'and the other attempt stays, with the directory of the job' );

    evidence( attempt => 1 )->discard;
    ok( !-e $root->child(41),                      'the directory of the job goes with the last attempt' );
    ok( lives { evidence( job => 404 )->discard }, 'a job that kept nothing has nothing to discard' );
};

subtest prune => sub {
    evidence( job => 1 )->recorder( task => 'triage' );
    evidence( job => 2 )->recorder( task => 'triage' );
    my $old = time - 3 * $DAY;
    utime $old, $old, $root->child(1)->to_string or die "utime: $!";

    is( evidence()->prune( 2 * $DAY ), ['1'], 'the job that no run added to for longer than that is removed' );
    ok( !-e $root->child(1), 'with its transcripts' );
    ok( -d $root->child(2),  'and the newer one stays' );
    is( App::Clod::Evidence->new( root => $tmp->child('none')->to_string )->prune(1), [], 'with no evidence yet there is nothing to prune' );
};

done_testing;
