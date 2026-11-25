# NAME

App::Clod - Hub-and-spoke agent manager that keeps it simple

# VERSION

version 0.001

# SYNOPSIS

```perl
# clod.conf is a perl hash; see App::Clod::Config for every key.
my $clod_conf = {
    bot              => 'our-bot',
    authorized_users => ['a-maintainer'],
    owners           => ['Our-Org'],
    spokes           => [ 'Our-Org/repo-one', 'Our-Org/repo-two' ],
    workspace        => '/var/lib/clod',
    auth             => { user => 'admin', password_sha256 => '...' },
};
```

# DESCRIPTION

An agent works best when it starts in the repository that it changes, because
that repository's CLAUDE.md, hooks and critic profile shape the work.  Many
fixes cross repositories.  App::Clod is a GitHub bot that plans across them and
then works inside each one.

It reads the bot user's notification inbox.  It acts on an item only when a
user in `authorized_users` caused it.  An assignment to an issue becomes a
fix, a review request becomes a review, activity on the bot's own pull request
becomes work on the review comments, and a mention becomes a reply.  An
assignment to a pull request becomes work on the review comments if the pull
request is the bot's own, and a review if it is not.  On the bot's own pull
request, a mention is work on the review comments too.

Work on the review comments needs a review comment or a comment of an
authorized user since the last comment of the bot.  If there is none, the bot
makes no job and changes nothing.

That work starts with a sort: one `claude -p` run that can only read a
checkout of the branch.  It answers each review thread that asks a question in
that thread, and the plain comments in one comment, if none of them asks for a
change.  Only what asks for a change goes on to a run that can change the
branch.  So a question in a line comment gets an answer, and never a commit.
If the sort is not sure, it takes the comment for a request for a change, and
the run that makes changes answers it.

GitHub keeps one notification per issue or pull request, not one per comment.
Each new comment updates it, and its reason is the reason of the latest one.
Several comments that arrive while the work on a pull request waits to start
get no job of their own, because that work collects everything that was said
since the bot last answered.  A comment that arrives while that work runs gets
a job of its own.

Each fix and review starts with triage, and so does a review answer that the
sort finds needs a change in another spoke as well.  Triage is one
`claude -p` run that can read every spoke and decides whether one
repository, several, or an upstream project that we do not own is the right
place for the change.  Then
one `claude -p` run per repository does the work, inside a git clone of that
repository that is its own.  For a change across several repositories, Minion parents run
them in order, and each run gets the summaries of the runs before it.  The bot
pushes the branches, opens the pull requests and links them to each other and
to the issue.

How a spoke run tests a change is a matter of the installation, so
`clod.conf` says it: `spoke_prompt` is added to the system prompt of every
spoke run, and triage is told it too, so that its instructions agree.  The
tools for a test, such as a provisioner that builds a guest, can live in a
repository of their own, a tool spoke.  Each spoke run gets its own worktree of
each tool spoke, removed after the run, so that runs in parallel never share
one.  It is at the branch of an earlier spoke of the same change that changed
the tool spoke, so a run can test with a recipe that the run before it just
added.  `extra_tools` allows the runs that change a repository to run those
tools.  See [App::Clod::Config](https://metacpan.org/pod/App%3A%3AClod%3A%3AConfig).  A repository can also declare the programs
in it that those runs may run, in `clod.json` at its top.  The bot reads it
from the default branch, so a declaration takes effect when a person merges
it.  ["declared\_rules" in App::Clod::Tasks](https://metacpan.org/pod/App%3A%3AClod%3A%3ATasks#declared_rules) says what it may hold.  It can also
name, in `cleanup`, the programs that remove what a run made outside its
worktree, such as a guest that a test built.  They run after every run, also a
run that failed, and the sweep of each half hour runs them for a run whose
worker was killed.  ["clean\_up" in App::Clod::Tasks](https://metacpan.org/pod/App%3A%3AClod%3A%3ATasks#clean_up) says how.

If the best fix is upstream, the bot changes nothing.  It assigns the issue to
the owner of the affected path in CODEOWNERS, or to the repository owner, and
explains why.  The bot never opens a pull request on a project that we do not
own.  To go on, that person runs claude in a clone of the upstream project,
with `perl-slop:pull-requests`, opens the pull request there, and mentions the
bot on the issue with a link to it.  Nothing watches the upstream pull request
yet, so a change that our code needs after it merges is for a person to make.

If a site turns on `create_repos`, an authorized user can ask the bot for a
new repository, in one of the organizations of `spoke_orgs`.  Triage plans one
only when that user asked for it in their own words, which the bot checks
against what they wrote.  The worker makes it, public and with a first commit, as
the bot: the claude runs never hold a token.  The new repository is a spoke at
once, gets its spoke run like any other, and gets an issue for its first
release, assigned to the person who asked for it.  The bot never takes over a
repository that exists already.

An authorized user can also ask the bot to file a follow-up issue, such as
"file a follow-up issue about this and we will move on".  Triage plans it on
the same check of their own words, and the worker files it in a spoke,
assigned to that user, and links it where they asked.  If filing settles the
request, nothing else runs.  `follow_up_max` caps how many one request may
file.

If triage or a spoke cannot go on without an answer from a person, the bot
changes nothing and does not guess.  It asks the question in a comment, assigns
the issue to the same person, and removes itself, so that the question reaches
that person's inbox.  On a pull request, that person is the author, or the
reviewer if the bot is the author.  The comment also mentions every team that
owns the path.  To go on, the person answers with a mention of the bot, or
assigns the bot again.  Only a person in `authorized_users` can restart the
work.  A review or a reply to review comments asks its questions in the review
or the reply itself.

All state is in Minion.  A job's notes and result hold what it did, and
Minion::Admin under `/minion` shows them.

# METHODS

## startup

The Mojolicious entry point.  Mojolicious calls it once, from `new`.

Returns nothing.  Dies when `clod.conf` does not validate, as
["validate" in App::Clod::Config](https://metacpan.org/pod/App%3A%3AClod%3A%3AConfig#validate) dies.

```
# What Mojolicious->new does with the new application:
$app->startup;
```

# FUNCTIONS

## share\_dir

Returns the `share` directory as a [Mojo::File](https://metacpan.org/pod/Mojo%3A%3AFile): the one beside `lib` in a
checkout, else the installed one.

```perl
my $prompts = App::Clod::share_dir()->child('prompts');
```

## checkout

The git checkout that this code runs from, as a [Mojo::File](https://metacpan.org/pod/Mojo%3A%3AFile): the directory
above `lib`, if it holds `.git`.  Undef for an installed distribution.

Returns a Mojo::File object or undef.

```perl
my $dir = App::Clod::checkout() // die "This clod is not a git checkout\n";
```

## running\_commit

The commit that the ["checkout"](#checkout) is at, as `{sha, short}`, or undef when this
code runs from no checkout, or git cannot say.  ["startup"](#startup) asks once, so the
helper `running` is the commit that the process loaded, and a pull changes it
only after a restart.

Returns HashRef or undef.

```perl
my $commit = App::Clod::running_commit();
say "running $commit->{short}" if $commit;
```

## authorized

`($c, $auth)`.  True when the request passes the `auth` configuration: a
non-empty trusted header, or HTTP basic credentials whose password hashes to
`password_sha256`.  Otherwise it renders a 401 and returns false.

Returns Bool.

```perl
my $authed = $app->routes->under( '/' => sub ($c) { App::Clod::authorized( $c, $config->{auth} ) } );
```

## viewer

`($c, $auth)`.  Who is logged in to the page: the value of the trusted header,
or the user of the basic credentials.  Undef when ["authorized"](#authorized) would refuse
the request.  The helper `viewer` calls it with the `auth` configuration.

Returns Str or undef.

```perl
my $who = App::Clod::viewer( $c, $config->{auth} ) // 'nobody';
```

# THE TWO PROCESSES

```
GH_TOKEN=... CLOD_CONFIG=clod.conf clod daemon -l http://127.0.0.1:3000
GH_TOKEN=... CLAUDE_CODE_OAUTH_TOKEN=... CLOD_CONFIG=clod.conf clod minion worker -j 2
```

- `clod daemon`

    Serves the health page at `/`, its JSON under `/api`, and Minion::Admin under
    `/minion`, all behind the `auth` configuration.

- `clod minion worker`

    Runs the jobs.  The worker also enqueues the scheduled jobs that
    ["schedule" in App::Clod::Tasks](https://metacpan.org/pod/App%3A%3AClod%3A%3ATasks#schedule) lists, such as the inbox poll, the harness scan
    and the sweeps.

Both read the configuration from `CLOD_CONFIG`, or `clod.conf` in the
application home.  Secrets come only from the environment: `GH_TOKEN` for
GitHub and `CLAUDE_CODE_OAUTH_TOKEN` for Claude Code.  With `run_as`, the
account that claude runs as brings its own token: see
["run\_as" in App::Clod::Claude](https://metacpan.org/pod/App%3A%3AClod%3A%3AClaude#run_as).

# WHEN A TOKEN STOPS WORKING

If GitHub or Claude refuses its token with a 401, the bot is in an outage.  The
jobs do not fail one after another.  A GitHub outage holds all work, and a
Claude outage holds the work that runs `claude`.  Each held job waits ten
minutes, and then the next job tries the token again.  The Overview tab names
the outage first.  After you replace the token in the environment and restart
both processes, the work starts again within ten minutes.  See
[App::Clod::Outage](https://metacpan.org/pod/App%3A%3AClod%3A%3AOutage).

# WHAT THE HOST NEEDS

- `git` and the `claude` program, signed in through `CLAUDE_CODE_OAUTH_TOKEN`.
- The tools that the hooks of each spoke run, such as perltidy, perlcritic with
its policies, and tests-covering.  The bot installs each spoke's own
`git-hooks`, so a commit in a worktree fails when a tool is missing.
- A bot account with write access to every spoke, and a classic token with the
`repo` and `notifications` scopes.  The Overview tab names a missing scope.
For `create_repos`, the account must also be allowed to make repositories in
each organization of `spoke_orgs`.

# THE HEALTH PAGE

- Overview

    Jobs by state, the Claude Code quota used in the five-hour and seven-day
    windows, and the action items: an outage, a marketplace pin older than the
    plugin, failed jobs, harness checks that fail, token scopes that are missing,
    an inbox that waits because no repository is a spoke, upstream pull
    requests that conflict, distributions whose work is not on CPAN, and spokes
    whose line count failed.

    Some action items have a button, which settles them from the page:

    - Retry, on a failed job, queues it again, as `/minion` does.
    - Ignore, on a failed job, takes it off the action items.  The job
    stays failed in `/minion`.
    - Fix, on a spoke that fails harness checks, queues
    ["harness\_fix" in App::Clod::Tasks](https://metacpan.org/pod/App%3A%3AClod%3A%3ATasks#harness_fix).  That job runs the update of the standards
    on a new branch, and opens a pull request for what it changed, with an issue
    that it closes.  What the update leaves for a person, such as code that a new
    critic policy flags, goes to a claude run.
    - Update, when the bot is out of date, queues
    ["self\_update" in App::Clod::Tasks](https://metacpan.org/pod/App%3A%3AClod%3A%3ATasks#self_update).  The bot is out of date when its checkout is
    behind its upstream, or when it runs another commit than its checkout has.
    ["self\_check" in App::Clod::Tasks](https://metacpan.org/pod/App%3A%3AClod%3A%3ATasks#self_check) finds that out every half hour.
    - Update plugins, when a plugin of the account that claude runs as is
    behind its marketplace, queues ["plugin\_update" in App::Clod::Tasks](https://metacpan.org/pod/App%3A%3AClod%3A%3ATasks#plugin_update).
    - Upgrade modules, when a Perl module in `local_lib` has a newer
    release on CPAN, queues ["deps\_upgrade" in App::Clod::Tasks](https://metacpan.org/pod/App%3A%3AClod%3A%3ATasks#deps_upgrade), which upgrades them
    there and restarts the bot.
    - Install packages, when a spoke declares system packages that the host
    lacks, queues ["packages\_install" in App::Clod::Tasks](https://metacpan.org/pod/App%3A%3AClod%3A%3ATasks#packages_install), which installs them with
    the `installer` of `system_packages`.  See [App::Clod::Packages](https://metacpan.org/pod/App%3A%3AClod%3A%3APackages).  A host that
    is built again needs no click: the provisioner queues
    ["packages\_restore" in App::Clod::Tasks](https://metacpan.org/pod/App%3A%3AClod%3A%3ATasks#packages_restore), which queues the same install for
    each spoke.
    - Install and resume, when a pull request of the bot needs system
    packages that the host lacks, installs them, as Install packages does, and
    then queues the work on that pull request again.  The bot reads such a
    declaration from its own branch, so a change that adds a dependency can be
    tested before it merges.  A run that needs a package that the host lacks
    declares it, runs the tests, and commits.  The bot then opens the pull
    request as a draft, or makes it one, and does not fail the job.  After the
    install, the run finishes the work and runs the tests again, and the bot
    makes the pull request ready for review.  Ignore takes the item off the
    list.

        Before it installs anything, the button shows the packages and the archives,
        and a link to the change of `metamerge.yml` in the pull request.  Read that
        change before you confirm.  Nobody reviewed that branch, and the bot wrote
        it from the text of an issue.  The install runs as root, and an archive that
        it adds is trusted for every package of the host from then on.  See
        ["branch\_packages" in App::Clod::Tasks](https://metacpan.org/pod/App%3A%3AClod%3A%3ATasks#branch_packages).

    The header of the page shows the short sha of the commit that the page runs.

    The buttons post to `/act`, which takes a request only with the header
    `X-Clod-Action: yes`.  A browser sends the credentials of the page with a
    form that another site posts, but it sends no such header for another site.

- Work

    The items in progress with their repositories and pull requests, the items in
    the queue, and the open issues assigned to the bot that no job has yet.

- Harness

    For each spoke, its flavor and the result of each check of that flavor.  A
    spoke without a `.conformance.yml` shows the default flavor, marked
    "(default)".  See [App::Clod::Harness](https://metacpan.org/pod/App%3A%3AClod%3A%3AHarness).

- Upstream

    The open pull requests that the `authorized_users` wrote in repositories
    that are not ours, with their merge state, review decision and checks.  A
    repository is ours when its owner is in `owners` or `spoke_orgs`, or owns a
    spoke.  The ones that conflict with their base come first, marked as needing a
    rebase, and the Overview tab counts them.  It also shows when the sweep last
    ran, and the users whose search failed.  See
    ["upstream\_sweep" in App::Clod::Tasks](https://metacpan.org/pod/App%3A%3AClod%3A%3ATasks#upstream_sweep).

- Releases

    The Perl distributions among the spokes whose work is not all on CPAN: a
    distribution that was never released, a version that was raised and not
    uploaded, and a released version with commits after its tag, which it lists.
    A released version without a tag, or a `dist.ini` that sets no version, is
    listed too, because the sweep cannot tell.  The Overview tab counts them.  It
    also shows when the sweep last ran, and the spokes whose check failed.  See
    ["release\_sweep" in App::Clod::Tasks](https://metacpan.org/pod/App%3A%3AClod%3A%3ATasks#release_sweep).

- Code

    How big each spoke is, as loccount counts it: the physical and the logical
    source lines, the files, the languages, and the COCOMO II estimate of what it
    would cost to write, with a line of how the lines changed over the days that
    the sweep kept.  The whole of the spokes is the first row.  It also shows when
    the sweep last ran, the spokes whose count failed, and the spokes that have no
    reference worktree yet, which the sweep cannot count.  See
    ["loc\_sweep" in App::Clod::Tasks](https://metacpan.org/pod/App%3A%3AClod%3A%3ATasks#loc_sweep).

# CAVEATS

The bot account must be used by App::Clod alone.  App::Clod knows what it has
answered by the login of the bot, and what is new by which of the bot's
notifications are unread.  Anything else that uses the same account changes
both:

- A comment by the account from another program, or from a person signed in as
the bot, counts as an answer of the bot.  Every comment before it then counts
as answered, and so does each review thread whose last message it is.
- Anything that marks the account's notifications read hides them from the
poll, which reads only unread ones.  That includes a person who opens them on
GitHub while signed in as the bot.
- An assignment or a review request made by the account has the bot as its
actor, and the bot is not an authorized user, so the poll ignores it.

One installation must serve public repositories or private ones, never both.
Triage reads every spoke, and a spoke run reads its tool spokes and the
summaries of the spokes before it.  So what a private repository holds can
reach a prompt about a public one, and from there a public pull request or
comment.  Run a second installation, with a bot account of its own, for
private repositories.  For the same reason `create_repos` makes public
repositories only, and the bot refuses a request for a private one.  The
spoke sweep drops a repository of `spokes` that GitHub reports as not public,
and the Overview tab names it.  It cannot drop a private repository that the
token cannot see, because GitHub answers 404 for it, and such a repository
stays a spoke.

An edit to a comment that the bot has already answered is not seen.  GitHub
sends no notification for an edit, and the comment keeps its place before the
answer.  To change a request, add a comment.

# SEE ALSO

Please see those modules/websites for more information related to this module.

- [App::Clod::Config](https://metacpan.org/pod/App%3A%3AClod%3A%3AConfig)
- [App::Clod::Tasks](https://metacpan.org/pod/App%3A%3AClod%3A%3ATasks)
- [App::Clod::Harness](https://metacpan.org/pod/App%3A%3AClod%3A%3AHarness)
- [Minion](https://metacpan.org/pod/Minion)

# BUGS

Please report any bugs or feature requests on the bugtracker website
[https://github.com/Troglodyne-Internet-Widgets/App-Clod/issues](https://github.com/Troglodyne-Internet-Widgets/App-Clod/issues)

When submitting a bug or request, please include a test-file or a
patch to an existing test-file that illustrates the bug or desired
feature.

# AUTHORS

Current Maintainers:

- George S. Baugh <george@troglodyne.net>

# CONTRIBUTORS

- troglodyne-bot <morpheus@troglodyne.net>
- troglodyne-bot <troglodyne-bot@users.noreply.github.com>
- troglodyne-robot <trogbot@troglodyne.net>

# COPYRIGHT AND LICENSE

Copyright (c) 2026 Troglodyne LLC

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
