#!/usr/bin/env perl
use 5.040;
no autovivification;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use FindBin::libs;
use File::Temp ();
use Mojo::File ();

use App::Clod::Loccount();

my $here = Mojo::File->new(__FILE__)->dirname->to_abs;
my $fake = $here->child(qw{bin fake-loccount})->to_string;

# Both fixtures are what loccount 2.28 printed with -j -c: one for a tree, and
# one for a directory of one file, where loccount prints no "all" line.
my $tree = $here->child(qw{data loccount-tree.txt});
my $one  = $here->child(qw{data loccount-one-file.txt});

subtest parse => sub {
    my $count = App::Clod::Loccount::parse( $tree->slurp );
    is( [ map { $_->{language} } @{ $count->{languages} } ], [qw{Perl Markdown INI sh YAML JSONL License}],                       'every language that loccount found, most SLOC first, and not its total "all"' );
    is( $count->{languages}[0],                              { language => 'Perl', sloc => 6468, lloc => 4738, filecount => 39 }, 'each with its SLOC, LLOC and files' );
    is( [ @{$count}{qw{sloc lloc files}} ],                  [ 7158, 4738, 73 ],                                                  'the totals of the tree' );
    is(
        $count->{cocomo},
        {
            sloc => { lines => 7158, person_months => 18.96, schedule_months => 7.65, developers => 2.48, cost => 492851, salary => 130000, overhead => 2.4 },
            lloc => { lines => 4738, person_months => 16.39, schedule_months => 7.24, developers => 2.26, cost => 426086, salary => 130000, overhead => 2.4 },
        },
        'the COCOMO I estimate of the SLOC and the COCOMO II estimate of the LLOC, in months and dollars'
    );

    my $single = App::Clod::Loccount::parse( $one->slurp );
    is( [ @{$single}{qw{sloc lloc files}} ], [ 1, 1, 1 ], 'a directory of one file has its totals from the estimates, as loccount prints no "all" line then' );

    my $first = ( split m{\n\n}, $tree->slurp )[0];
    like( dies { App::Clod::Loccount::parse($first) }, qr{no\ COCOMO\ estimate}, 'output without the estimates dies, rather than counting nothing' );
    my $sloc_only = ( $tree->slurp =~ s{\n\nTotal\ Logical.*\z}{}sr );
    like( dies { App::Clod::Loccount::parse($sloc_only) }, qr{no\ COCOMO\ estimate}, 'and so does output with the estimate of the SLOC alone' );
};

subtest count => sub {
    my $dir    = File::Temp->newdir;
    my $record = "$dir/args";
    local $ENV{FAKE_LOCCOUNT_RECORD} = $record;
    local $ENV{FAKE_LOCCOUNT_OUTPUT} = "$tree";
    my $counter = App::Clod::Loccount->new( bin => $fake );

    is( $counter->count('/bogus/tree')->{sloc}, 7158,                    'the count is what the output of loccount says' );
    is( Mojo::File->new($record)->slurp,        "-j\0-c\0/bogus/tree\n", 'loccount was asked for JSON and the estimates, of that directory' );

    local $ENV{FAKE_LOCCOUNT_FAIL} = 'lstat /bogus/tree: no such file or directory';
    is( dies { $counter->count('/bogus/tree') }, "$fake -j -c /bogus/tree: lstat /bogus/tree: no such file or directory\n", 'a loccount that fails dies with its error output' );

    my $missing = App::Clod::Loccount->new( bin => "$dir/no-loccount" );
    like( dies { $missing->count('/bogus/tree') }, qr{\A\Q$dir\E/no-loccount\ -j\ -c\ /bogus/tree:\ .+\n\z}, 'and so does a loccount that is not there' );
};

done_testing();
