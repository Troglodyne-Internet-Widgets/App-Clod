#!/usr/bin/env perl
use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use FindBin::libs;

use App::Clod::Triage();

my @spokes = qw{Test-Org/one Test-Org/two};

sub entry ( $repo, $order ) { return { repo => $repo, order => $order, instructions => "work in $repo" } }

subtest validate => sub {
    my $multi = App::Clod::Triage::validate( { scope => 'multi', reason => 'both', repos => [ entry( 'Test-Org/two', 2 ), entry( 'Test-Org/one', 1 ) ] }, \@spokes );
    is( [ map { $_->{repo} } @{ $multi->{repos} } ], [qw{Test-Org/one Test-Org/two}], 'repos come back in order' );

    my $up = App::Clod::Triage::validate( { scope => 'upstream', reason => 'theirs', repos => [ entry( 'Test-Org/one', 1 ) ], upstream => { project => 'Other/lib', explanation => 'bug there' } }, \@spokes );
    is( $up->{repos}, [], 'an upstream answer plans no spoke work, whatever repos it named' );

    my %bad = (
        'not a hash'          => [ [],                                                                                                        qr/not\ a\ JSON\ object/ ],
        'unknown scope'       => [ { scope => 'some', reason => 'r', repos => [ entry( 'Test-Org/one', 1 ) ] },                               qr/scope\ must\ be/ ],
        'empty reason'        => [ { scope => 'single', reason => q{}, repos => [ entry( 'Test-Org/one', 1 ) ] },                             qr/reason\ is\ empty/ ],
        'no repos'            => [ { scope => 'single', reason => 'r', repos => [] },                                                         qr/non-empty\ list/ ],
        'not a spoke'         => [ { scope => 'single', reason => 'r', repos => [ entry( 'Other/repo', 1 ) ] },                               qr/not\ a\ spoke/ ],
        'twice'               => [ { scope => 'multi', reason => 'r', repos => [ entry( 'Test-Org/one', 1 ), entry( 'Test-Org/one', 2 ) ] },  qr/listed\ twice/ ],
        'single with two'     => [ { scope => 'single', reason => 'r', repos => [ entry( 'Test-Org/one', 1 ), entry( 'Test-Org/two', 2 ) ] }, qr/single\ names\ 2/ ],
        'multi with one'      => [ { scope => 'multi', reason => 'r', repos => [ entry( 'Test-Org/one', 1 ) ] },                              qr/multi\ names\ one/ ],
        'no instructions'     => [ { scope => 'single', reason => 'r', repos => [ { repo => 'Test-Org/one', order => 1 } ] },                 qr/needs\ repo,\ order\ and\ instructions/ ],
        'upstream, no detail' => [ { scope => 'upstream', reason => 'r', repos => [] },                                                       qr/needs\ upstream.project/ ],
    );
    for my $case ( sort keys %bad ) {
        my ( $answer, $error ) = @{ $bad{$case} };
        like( dies { App::Clod::Triage::validate( $answer, \@spokes ) }, $error, "rejects: $case" );
    }
};

subtest intro => sub {
    is( App::Clod::Triage::intro("# CLAUDE.md\n\nFirst para\nstill first.\n\nSecond."), "First para\nstill first.", 'the first paragraph that is not a heading' );
    is( App::Clod::Triage::intro(undef),                                                undef,                      'no file, no intro' );
};

subtest hub_claude_md => sub {
    my $md = App::Clod::Triage::hub_claude_md( \@spokes, sub ($repo) { $repo eq 'Test-Org/one' ? 'One does things.' : undef } );
    like( $md, qr/\#\#\ Test-Org\/one\n\nOne\ does\ things\./, 'a spoke gets its introduction' );
    like( $md, qr/\#\#\ Test-Org\/two\n\n\(no\ CLAUDE\.md\)/,  'a spoke without one says so' );
};

done_testing;
