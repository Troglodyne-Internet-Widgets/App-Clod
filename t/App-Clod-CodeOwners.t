#!/usr/bin/env perl
use 5.040;
no autovivification;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use FindBin::libs;

use App::Clod::CodeOwners();

my $rules = App::Clod::CodeOwners::parse(<<'CODEOWNERS');
# a comment line
*                 @fallback
*.js              @js-owner
docs/             @docs-owner   # a trailing comment
/build/logs/      @logs-owner
apps/github       @Test-Org/apps-team
lib/**/Data.pm    @data-owner
\#notes.md         @hash-owner
CODEOWNERS

subtest parse => sub {
    is( scalar @$rules,      7,              'each rule line is a rule, and comments are not' );
    is( $rules->[2]{owners}, ['docs-owner'], 'owners lose the @ and a trailing comment is dropped' );
};

subtest owners => sub {
    my %cases = (
        'README.md'               => ['fallback'],
        'src/thing.js'            => ['js-owner'],
        'docs/index.md'           => ['docs-owner'],
        'nested/docs/index.md'    => ['docs-owner'],
        'build/logs/a.log'        => ['logs-owner'],
        'nested/build/logs/a.log' => ['fallback'],
        'apps/github/x.pm'        => ['Test-Org/apps-team'],
        'other/apps/github'       => ['fallback'],
        'lib/Foo/Bar/Data.pm'     => ['data-owner'],
        '/docs/leading-slash.md'  => ['docs-owner'],
        q{#notes.md}              => [q{hash-owner}],
    );
    for my $path ( sort keys %cases ) {
        is( App::Clod::CodeOwners::owners( $rules, $path ), $cases{$path}, "$path is owned by @{ $cases{$path} }" );
    }
    is( App::Clod::CodeOwners::owners( App::Clod::CodeOwners::parse(q{}), 'any' ), [], 'no rules own nothing' );
};

done_testing;
