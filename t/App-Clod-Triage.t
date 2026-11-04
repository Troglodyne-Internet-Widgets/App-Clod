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

subtest schema => sub {
    my $schema = App::Clod::Triage::schema( \@spokes );
    my @enums  = map { $_->{then}{properties}{repos}{items}{properties}{repo}{enum} // () } @{ $schema->{allOf} };
    is( \@enums, [ \@spokes, \@spokes ], 'under single and multi, a repository must be a spoke' );
    push @{ $enums[0] }, 'Other/repo';
    is( App::Clod::Triage::schema( \@spokes )->{allOf}[0]{then}{properties}{repos}{items}{properties}{repo}{enum}, \@spokes,                        'and a change to one schema reaches neither the spokes nor the next schema' );
    is( \@spokes,                                                                                                  [qw{Test-Org/one Test-Org/two}], 'nor the list of spokes it was made from' );
};

subtest validate => sub {
    my $multi = App::Clod::Triage::validate( { scope => 'multi', reason => 'both', repos => [ entry( 'Test-Org/two', 2 ), entry( 'Test-Org/one', 1 ) ] }, \@spokes );
    is( [ map { $_->{repo} } @{ $multi->{repos} } ], [qw{Test-Org/one Test-Org/two}], 'repos come back in order' );

    my $up = App::Clod::Triage::validate( { scope => 'upstream', reason => 'theirs', repos => [ entry( 'Test-Org/one', 1 ) ], upstream => { project => 'Other/lib', explanation => 'bug there' } }, \@spokes );
    is( $up->{repos}, [], 'an upstream answer plans no spoke work, whatever repos it named' );

    my $ask = App::Clod::Triage::validate( { scope => 'clarify', reason => 'unclear', repos => [ entry( 'Test-Org/one', 1 ) ], question => { text => 'Which one?' } }, \@spokes );
    is( $ask->{repos},          [],           'a clarify answer plans no spoke work either' );
    is( $ask->{question}{text}, 'Which one?', 'and keeps its question' );

    my %bad = (
        'not a hash'           => [ [],                                                                                                        qr{\A.*\n\ \ /:\ Expected\ object}s ],
        'unknown scope'        => [ { scope => 'some', reason => 'r', repos => [ entry( 'Test-Org/one', 1 ) ] },                               qr{/scope:\ Not\ in\ enum\ list}s ],
        'empty reason'         => [ { scope => 'single', reason => q{}, repos => [ entry( 'Test-Org/one', 1 ) ] },                             qr{/reason:\ String\ is\ too\ short}s ],
        'no repos'             => [ { scope => 'single', reason => 'r', repos => [] },                                                         qr{/repos:\ \S+\ Not\ enough\ items:\ 0/1}s ],
        'not a spoke'          => [ { scope => 'single', reason => 'r', repos => [ entry( 'Other/repo', 1 ) ] },                               qr{/repos/0/repo:\ \S+\ Not\ in\ enum\ list}s ],
        'twice'                => [ { scope => 'multi', reason => 'r', repos => [ entry( 'Test-Org/one', 1 ), entry( 'Test-Org/one', 2 ) ] },  qr/listed\ twice/ ],
        'single with two'      => [ { scope => 'single', reason => 'r', repos => [ entry( 'Test-Org/one', 1 ), entry( 'Test-Org/two', 2 ) ] }, qr{/repos:\ \S+\ Too\ many\ items:\ 2/1}s ],
        'multi with one'       => [ { scope => 'multi', reason => 'r', repos => [ entry( 'Test-Org/one', 1 ) ] },                              qr{/repos:\ \S+\ Not\ enough\ items:\ 1/2}s ],
        'no instructions'      => [ { scope => 'single', reason => 'r', repos => [ { repo => 'Test-Org/one', order => 1 } ] },                 qr{/repos/0/instructions:\ \S+\ Missing\ property}s ],
        'clarify, no question' => [ { scope => 'clarify', reason => 'r', repos => [] },                                                        qr{/question:\ \S+\ Missing\ property}s ],
        'clarify, empty text'  => [ { scope => 'clarify', reason => 'r', repos => [], question => { text => q{} } },                           qr{/question/text:\ String\ is\ too\ short}s ],
        'upstream, no detail'  => [ { scope => 'upstream', reason => 'r', repos => [] },                                                       qr{/upstream:\ \S+\ Missing\ property}s ],
    );
    for my $case ( sort keys %bad ) {
        my ( $answer, $error ) = @{ $bad{$case} };
        like( dies { App::Clod::Triage::validate( $answer, \@spokes ) }, $error, "rejects: $case" );
    }
    is( dies { App::Clod::Triage::validate( { scope => 'single', reason => 'r', repos => [ entry( 'Other/repo', 1 ) ] }, \@spokes ) }, "The answer does not fit the schema:\n  /repos/0/repo: /allOf/0 Not in enum list: Test-Org/one, Test-Org/two.\n", 'a rejection is the whole message, with no file or line, so it can go back to the model as it is' );
};

subtest 'new repositories' => sub {
    my %create = ( orgs => ['Test-Org'], max => 1 );
    my $new    = { org => 'Test-Org', name => 'Fresh-Dist', description => 'A fresh distribution.', asked_by => 'trusted', quote => 'Make a new repository for this.' };
    my %answer = ( scope => 'multi', reason => 'r', repos => [ entry( 'Test-Org/one', 1 ), entry( 'Test-Org/Fresh-Dist', 2 ) ], new_repos => [$new] );

    my $ok = App::Clod::Triage::validate( {%answer}, \@spokes, %create );
    is( [ map { $_->{repo} } @{ $ok->{repos} } ], [qw{Test-Org/one Test-Org/Fresh-Dist}], 'with creation allowed, repos may name a new repository' );
    like( $ok->{new_repos}, [ { repo => 'Test-Org/Fresh-Dist', module => 'Fresh::Dist' } ], 'which comes back with its full name, and a module from its name when triage named none' );
    is( App::Clod::Triage::validate( +{ %answer, new_repos => [ +{ %$new, module => 'Fresh::Thing' } ] }, \@spokes, %create )->{new_repos}[0]{module}, 'Fresh::Thing', 'or the module that triage named' );
    is( App::Clod::Triage::validate( +{ %answer, scope => 'clarify', question => { text => 'Which?' } }, \@spokes, %create )->{new_repos}, [], 'a clarify answer makes no repository, whatever it named' );

    my $off = App::Clod::Triage::schema( \@spokes );
    is( $off->{properties}{new_repos}{maxItems}, 0, 'without creation, the schema allows no new repository' );

    my %bad = (
        'creation off'      => [ [ {%answer} ],                                                                                                                                      qr{/new_repos:\ Too\ many\ items:\ 1/0} ],
        'another org'       => [ [ +{ %answer, new_repos => [ +{ %$new, org => 'Other-Org' } ] }, %create ],                                                                         qr{/new_repos/0/org:\ Not\ in\ enum\ list} ],
        'over the cap'      => [ [ +{ %answer, repos => [ @{ $answer{repos} }, entry( 'Test-Org/Second', 3 ) ], new_repos => [ $new, +{ %$new, name => 'Second' } ] }, %create ],    qr{/new_repos:\ Too\ many\ items:\ 2/1} ],
        'not in repos'      => [ [ +{ %answer, repos => [ entry( 'Test-Org/one', 1 ), entry( 'Test-Org/two', 2 ) ] }, %create ],                                                     qr{not\ in\ repos} ],
        'not new'           => [ [ +{ %answer, repos => [ entry( 'Test-Org/one', 1 ), entry( 'Test-Org/two', 2 ) ], new_repos => [ +{ %$new, name => 'two' } ] }, %create ],         qr{Test-Org/two\ is\ a\ spoke\ already} ],
        'repo not asked'    => [ [ +{ %answer, new_repos => [] }, %create ],                                                                                                         qr{Fresh-Dist\ is\ not\ a\ spoke,\ and\ not} ],
        'a dot in the name' => [ [ +{ %answer, repos => [ entry( 'Test-Org/one', 1 ), entry( 'Test-Org/x.git', 2 ) ], new_repos => [ +{ %$new, name => 'x.git' } ] }, %create ],     qr{/new_repos/0/name:\ String\ does\ not\ match} ],
        'a newline at end'  => [ [ +{ %answer, repos => [ entry( 'Test-Org/one', 1 ), entry( "Test-Org/fresh\n", 2 ) ], new_repos => [ +{ %$new, name => "fresh\n" } ] }, %create ], qr{does\ not\ fit\ the\ rule} ],
        'two lines'         => [ [ +{ %answer, new_repos => [ +{ %$new, description => "one\ntwo" } ] }, %create ],                                                                  qr{more\ than\ one\ line} ],
        'no quote'          => [ [ +{ %answer, new_repos => [ +{ %$new, quote => 'yes' } ] }, %create ],                                                                             qr{/new_repos/0/quote:\ String\ is\ too\ short} ],
        'no asker'          => [ [ +{ %answer, new_repos => [ +{ map { $_ => $new->{$_} } qw{org name description quote} } ] }, %create ],                                           qr{/new_repos/0/asked_by:\ Missing\ property} ],
    );
    for my $case ( sort keys %bad ) {
        my ( $args,   $error ) = @{ $bad{$case} };
        my ( $answer, %how )   = @$args;
        like( dies { App::Clod::Triage::validate( $answer, \@spokes, %how ) }, $error, "rejects: $case" );
    }
    ok( !App::Clod::Triage::repo_name("fresh\n"),   'a name with a newline at its end does not fit the rule' );
    ok( App::Clod::Triage::repo_name( 'a' x 100 ),  'a name of a hundred characters fits' );
    ok( !App::Clod::Triage::repo_name( 'a' x 101 ), 'and one of a hundred and one does not' );
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
