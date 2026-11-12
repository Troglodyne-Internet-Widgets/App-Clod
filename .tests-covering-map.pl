#!/usr/bin/env perl
use 5.014;
use strict;
use warnings FATAL => 'all';
use re '/aa';

=head1 NAME

.tests-covering-map.pl - which tests reach the files that no test loads, for
tests-covering

=head1 DESCRIPTION

git-hooks/pre-commit asks tests-covering which tests a commit can break.
tests-covering follows the Perl that each test loads, and asks this map about
every other file in the diff.  See "THE MAP" in L<Perl::Tests::Covering>.

The map answers C<q{}>, which is C<NO_TESTS>, for the files of a distribution
that C<prove -l t/> never reads:

=over

=item Documentation

Markdown, POD in F<.pod> files outside F<lib/>, F<Changes>, F<LICENSE> and
F<README>.

=item The build and the release

F<dist.ini>, F<weaver.ini>, F<prereqs.yml> and F<prereqs.json>, F<MANIFEST.SKIP>
and F<cpanfile>.  C<dzil> reads them, and C<dzil test> checks what they build.

=item The tools and the hooks

The C<perltidy> and C<perlcritic> configuration and the files that it reads,
F<.mailmap>, F<.gitignore>, F<.gitattributes>, this map, F<git-hooks/> and
F<.github/>.

=item The author tests

F<xt/>, which the hooks do not run.

=back

Anything else, it leaves unexplained, and the hook then runs every test.  A
file that a test reads without loading it, such as a template or a fixture,
wants a rule here that names the tests that read it.

=cut

# Read by the tools, by dzil or by people, and by no test.
my %NO_TESTS = map { $_ => 1 } qw{
  Changes LICENSE README README.md
  dist.ini weaver.ini prereqs.yml prereqs.json MANIFEST.SKIP cpanfile
  .perltidyrc .perlcriticrc .perlcriticrc.compat .pod_stopwords .preferred_modules.ini .preferred_binaries.ini
  .mailmap .gitignore .gitattributes .tests-covering-map.pl
};

return sub {
    my ($path) = @_;

    return q{} if $NO_TESTS{$path};
    return q{} if $path =~ m{\A(?:git-hooks|[.]github|xt)/}sx;

    # Read by the tests, never loaded by them.
    return qw{t/App-Clod-Tasks.t t/App-Clod.t}                            if $path =~ m{\Ashare/prompts/}sx;
    return qw{t/App-Clod.t t/App-Clod-Controller-Dashboard.t}             if $path =~ m{\Ashare/templates/}sx;
    return qw{t/App-Clod-Deps.t t/App-Clod-Claude.t t/clod-skill-edits.t} if $path =~ m{\Ashare/agent-bin/}sx;
    return qw{t/App-Clod-Claude.t t/App-Clod-Tasks.t}                     if $path eq q{t/bin/fake-claude};
    return qw{t/App-Clod-Loccount.t t/App-Clod-Tasks.t}                   if $path eq q{t/bin/fake-loccount};
    return qw{t/App-Clod-Loccount.t t/App-Clod-Tasks.t}                   if $path =~ m{\At/data/loccount-}sx;
    return qw{t/App-Clod-Harness.t t/App-Clod-Tasks.t}                    if $path =~ m{\At/data/standards/}sx;
    return 't/App-Clod-Claude.t'                                          if $path =~ m{\At/data/}sx;
    return qw{t/App-Clod-Claude.t t/App-Clod-Packages.t}                  if $path eq q{t/bin/sudo-dir/sudo};

    return q{} if $path =~ m{[.]md\z}sx;
    return q{} if $path =~ m{[.]pod\z}sx && $path !~ m{\Alib/}sx;

    return;
};
