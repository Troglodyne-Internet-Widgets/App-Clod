#!/usr/bin/env perl
use 5.040;
no autovivification;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use FindBin::libs;
use Test::MockModule ();

use App::Clod::Retry();

# The pauses, recorded rather than slept.
my @slept;
my $time = Test::MockModule->new('Time::HiRes');
$time->redefine( sleep => sub ($seconds) { push @slept, $seconds; return $seconds } );

my $transient = sub ($error) { $error =~ m{\Aflaky} };

subtest attempt => sub {
    my @errors = ( "flaky one\n", "flaky two\n" );
    my $tries  = 0;
    my @got;
    my $said = warnings {
        @got = App::Clod::Retry::attempt( 'the thing', $transient, sub { $tries++; die shift @errors if @errors; return qw{a b} } );
    };
    is( \@got,   [qw{a b}], 'what the last try returns comes back, as a list' );
    is( $tries,  3,         'after a try for each transient error' );
    is( \@slept, [ 5, 30 ], 'with the pauses of @DELAYS in order' );
    like( $said, [ qr/\Athe\ thing\ failed.*\ in\ 5s:\ flaky\ one/, qr/in\ 30s:\ flaky\ two/ ], 'and a warning that names the thing and the error' );

    @slept = ();
    $tries = 0;
    is(
        dies {
            App::Clod::Retry::attempt( 'the thing', $transient, sub { $tries++; die "broken\n" } )
        },
        "broken\n",
        'an error that is not transient dies at once'
    );
    is( [ $tries, scalar @slept ], [ 1, 0 ], 'with no pause and no second try' );

    @slept = ();
    $tries = 0;
    my $error;
    my $each = warnings {
        $error = dies {
            App::Clod::Retry::attempt( 'the thing', $transient, sub { $tries++; die "flaky $tries\n" } )
        }
    };
    is( scalar @$each,      3,                  'with a warning before each try after the first' );
    is( [ $error, $tries ], [ "flaky 4\n", 4 ], 'when the pauses run out, the last error dies' );
    is( \@slept,            [ 5, 30, 120 ],     'after every pause' );
};

done_testing;
