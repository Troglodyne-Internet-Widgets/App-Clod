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
becomes work on the review comments, and a mention becomes a reply.

GitHub keeps one notification per issue or pull request, not one per comment.
Each new comment updates it, and its reason is the reason of the latest one.
So a comment on the bot's own pull request that mentions the bot by name is a
mention, and gets a reply, not work on the review comments.  If the reply finds
that the person asked for a change, it starts that work.  Several comments that
arrive while the work on a pull request waits to start get no job of their own,
because that work collects everything that was said since the bot last
answered.  A comment that arrives while that work runs gets a job of its own.

Each fix, review and review answer starts with triage: one `claude -p` run
that can read every spoke and decides whether one repository, several, or an
upstream project that we do not own is the right place for the change.  Then
one `claude -p` run per repository does the work, inside a git worktree of
that repository.  For a change across several repositories, Minion parents run
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
tools.  See [App::Clod::Config](https://metacpan.org/pod/App%3A%3AClod%3A%3AConfig).

If the best fix is upstream, the bot changes nothing.  It assigns the issue to
the owner of the affected path in CODEOWNERS, or to the repository owner, and
explains why.  The bot never opens a pull request on a project that we do not
own.  To go on, that person runs claude in a clone of the upstream project,
with `perl-slop:pull-requests`, opens the pull request there, and mentions the
bot on the issue with a link to it.  Nothing watches the upstream pull request
yet, so a change that our code needs after it merges is for a person to make.

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

The Mojolicious entry point.

# FUNCTIONS

## share\_dir

Returns the `share` directory as a [Mojo::File](https://metacpan.org/pod/Mojo%3A%3AFile): the one beside `lib` in a
checkout, else the installed one.

## authorized

`($c, $auth)`.  True when the request passes the `auth` configuration: a
non-empty trusted header, or HTTP basic credentials whose password hashes to
`password_sha256`.  Otherwise it renders a 401 and returns false.

# THE TWO PROCESSES

```
GH_TOKEN=... CLOD_CONFIG=clod.conf clod daemon -l http://127.0.0.1:3000
GH_TOKEN=... CLAUDE_CODE_OAUTH_TOKEN=... CLOD_CONFIG=clod.conf clod minion worker -j 2
```

- `clod daemon`

    Serves the health page at `/`, its JSON under `/api`, and Minion::Admin under
    `/minion`, all behind the `auth` configuration.

- `clod minion worker`

    Runs the jobs.  The worker also enqueues the scheduled jobs: the inbox poll,
    the harness scan and the sweep of assigned issues.

Both read the configuration from `CLOD_CONFIG`, or `clod.conf` in the
application home.  Secrets come only from the environment: `GH_TOKEN` for
GitHub and `CLAUDE_CODE_OAUTH_TOKEN` for Claude Code.

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

# THE HEALTH PAGE

- Overview

    Jobs by state, the Claude Code quota used in the five-hour and seven-day
    windows, and the action items: an outage, a marketplace pin older than the
    plugin, failed jobs, harness checks that fail, and token scopes that are
    missing.

- Work

    The items in progress with their repositories and pull requests, the items in
    the queue, and the open issues assigned to the bot that no job has yet.

- Harness

    For each spoke, whether each part of the standard harness is in place.  See
    [App::Clod::Harness](https://metacpan.org/pod/App%3A%3AClod%3A%3AHarness).

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

# CONTRIBUTOR

troglodyne-bot <morpheus@troglodyne.net>

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
