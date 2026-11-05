package App::Clod;

# ABSTRACT: Hub-and-spoke agent manager that keeps it simple

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Mojo::Base 'Mojolicious', -signatures;

use IPC::Run    ();
use Mojo::File  ();
use Mojo::Util  ();
use Digest::SHA ();
use File::ShareDir();

use App::Clod::Config();
use App::Clod::Tasks();

my $DAY = 86_400;

=func share_dir

Returns the F<share> directory as a L<Mojo::File>: the one beside F<lib> in a
checkout, else the installed one.

=cut

sub share_dir {
    my $file = Mojo::File->new(__FILE__)->to_abs;
    my $here = $file->dirname->dirname->sibling(q{share});
    return $here if -d $here->child('prompts');
    return Mojo::File->new( File::ShareDir::dist_dir('App-Clod') );
}

=func checkout

The git checkout that this code runs from, as a L<Mojo::File>: the directory
above F<lib>, if it holds F<.git>.  Undef for an installed distribution.

=cut

sub checkout {
    my $file = Mojo::File->new(__FILE__)->to_abs;
    my $root = $file->dirname->dirname->dirname;
    return -e $root->child('.git') ? $root : undef;
}

=func running_commit

The commit that the L</checkout> is at, as C<{sha, short}>, or undef when this
code runs from no checkout, or git cannot say.  L</startup> asks once, so the
helper C<running> is the commit that the process loaded, and a pull changes it
only after a restart.

=cut

sub running_commit {
    my $dir = checkout() // return;
    my ( $sha, $err ) = ( q{}, q{} );
    IPC::Run::run( [ qw{git -C}, "$dir", qw{rev-parse HEAD} ], '<', \undef, '>', \$sha, '2>', \$err ) or return;
    chomp $sha;
    return { sha => $sha, short => substr $sha, 0, 7 };
}

=method startup

The Mojolicious entry point.

=cut

sub startup ($self) {
    my $raw    = $self->plugin( Config => { file => $ENV{CLOD_CONFIG} // 'clod.conf', default => {} } );
    my $config = App::Clod::Config::validate($raw);
    Mojo::File->new( $config->{workspace} )->make_path;
    $self->config($config);
    $self->helper( clod_config => sub { $config } );
    my $running = running_commit();
    $self->helper( running => sub { $running } );

    $self->renderer->paths( [ share_dir()->child('templates')->to_string ] );
    $self->plugin( Minion => { SQLite => $config->{minion} } );
    $self->minion->remove_after( $config->{retention_days} * $DAY );

    App::Clod::Tasks::register( $self, $config );
    App::Clod::Tasks::schedule( $self->minion );

    my $authed = $self->routes->under( '/' => sub ($c) { return authorized( $c, $config->{auth} ) } );
    $self->plugin( 'Minion::Admin' => { route => $authed->any('/minion'), return_to => '/' } );
    $authed->get('/')->to('dashboard#page');
    $authed->get('/api/overview')->to('dashboard#overview');
    $authed->get('/api/work')->to('dashboard#work');
    $authed->get('/api/harness')->to('dashboard#harness');

    my $act = $authed->under(
        '/act' => sub ($c) {
            return 1 if ( $c->req->headers->header('X-Clod-Action') // q{} ) eq 'yes';
            $c->render( json => { error => 'an action needs the header X-Clod-Action: yes' }, status => 403 );
            return;
        }
    );
    $act->post('/jobs/:id/retry')->to('dashboard#retry');
    $act->post('/jobs/:id/ignore')->to('dashboard#ignore');
    $act->post('/harness/fix')->to('dashboard#harness_fix');
    $act->post('/self/update')->to('dashboard#self_update');
    $act->post('/plugins/update')->to('dashboard#plugin_update');
    return;
}

=func authorized

C<($c, $auth)>.  True when the request passes the C<auth> configuration: a
non-empty trusted header, or HTTP basic credentials whose password hashes to
C<password_sha256>.  Otherwise it renders a 401 and returns false.

=cut

sub authorized ( $c, $auth ) {
    my $req = $c->req;
    if ( my $header = $auth->{trusted_header} ) {
        return 1 if ( $req->headers->header($header) // q{} ) ne q{};
    }
    elsif ( my $userinfo = $req->url->to_abs->userinfo ) {
        my ( $user, $password ) = split /:/, $userinfo, 2;
        return 1
          if Mojo::Util::secure_compare( $user // q{},                                $auth->{user} )
          && Mojo::Util::secure_compare( Digest::SHA::sha256_hex( $password // q{} ), $auth->{password_sha256} );
    }
    $c->res->headers->www_authenticate('Basic realm="clod"');
    $c->render( text => 'Authentication required', status => 401 );
    return;
}

=head1 SYNOPSIS

    # clod.conf is a perl hash; see App::Clod::Config for every key.
    my $clod_conf = {
        bot              => 'our-bot',
        authorized_users => ['a-maintainer'],
        owners           => ['Our-Org'],
        spokes           => [ 'Our-Org/repo-one', 'Our-Org/repo-two' ],
        workspace        => '/var/lib/clod',
        auth             => { user => 'admin', password_sha256 => '...' },
    };

=head1 DESCRIPTION

An agent works best when it starts in the repository that it changes, because
that repository's CLAUDE.md, hooks and critic profile shape the work.  Many
fixes cross repositories.  App::Clod is a GitHub bot that plans across them and
then works inside each one.

It reads the bot user's notification inbox.  It acts on an item only when a
user in C<authorized_users> caused it.  An assignment to an issue becomes a
fix, a review request becomes a review, activity on the bot's own pull request
becomes work on the review comments, and a mention becomes a reply.  An
assignment to a pull request becomes work on the review comments if the pull
request is the bot's own, and a review if it is not.  On the bot's own pull
request, a mention is work on the review comments too.

Work on the review comments needs a review comment or a comment of an
authorized user since the last comment of the bot.  If there is none, the bot
makes no job and changes nothing.

That work starts with a sort: one C<claude -p> run that can only read a
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
C<claude -p> run that can read every spoke and decides whether one
repository, several, or an upstream project that we do not own is the right
place for the change.  Then
one C<claude -p> run per repository does the work, inside a git worktree of
that repository.  For a change across several repositories, Minion parents run
them in order, and each run gets the summaries of the runs before it.  The bot
pushes the branches, opens the pull requests and links them to each other and
to the issue.

How a spoke run tests a change is a matter of the installation, so
F<clod.conf> says it: C<spoke_prompt> is added to the system prompt of every
spoke run, and triage is told it too, so that its instructions agree.  The
tools for a test, such as a provisioner that builds a guest, can live in a
repository of their own, a tool spoke.  Each spoke run gets its own worktree of
each tool spoke, removed after the run, so that runs in parallel never share
one.  It is at the branch of an earlier spoke of the same change that changed
the tool spoke, so a run can test with a recipe that the run before it just
added.  C<extra_tools> allows the runs that change a repository to run those
tools.  See L<App::Clod::Config>.

If the best fix is upstream, the bot changes nothing.  It assigns the issue to
the owner of the affected path in CODEOWNERS, or to the repository owner, and
explains why.  The bot never opens a pull request on a project that we do not
own.  To go on, that person runs claude in a clone of the upstream project,
with C<perl-slop:pull-requests>, opens the pull request there, and mentions the
bot on the issue with a link to it.  Nothing watches the upstream pull request
yet, so a change that our code needs after it merges is for a person to make.

If a site turns on C<create_repos>, an authorized user can ask the bot for a
new repository, in one of the organizations of C<spoke_orgs>.  Triage plans one
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
request, nothing else runs.  C<follow_up_max> caps how many one request may
file.

If triage or a spoke cannot go on without an answer from a person, the bot
changes nothing and does not guess.  It asks the question in a comment, assigns
the issue to the same person, and removes itself, so that the question reaches
that person's inbox.  On a pull request, that person is the author, or the
reviewer if the bot is the author.  The comment also mentions every team that
owns the path.  To go on, the person answers with a mention of the bot, or
assigns the bot again.  Only a person in C<authorized_users> can restart the
work.  A review or a reply to review comments asks its questions in the review
or the reply itself.

All state is in Minion.  A job's notes and result hold what it did, and
Minion::Admin under F</minion> shows them.

=head1 THE TWO PROCESSES

    GH_TOKEN=... CLOD_CONFIG=clod.conf clod daemon -l http://127.0.0.1:3000
    GH_TOKEN=... CLAUDE_CODE_OAUTH_TOKEN=... CLOD_CONFIG=clod.conf clod minion worker -j 2

=over

=item C<clod daemon>

Serves the health page at F</>, its JSON under F</api>, and Minion::Admin under
F</minion>, all behind the C<auth> configuration.

=item C<clod minion worker>

Runs the jobs.  The worker also enqueues the scheduled jobs: the inbox poll,
the harness scan and the sweep of assigned issues.

=back

Both read the configuration from C<CLOD_CONFIG>, or F<clod.conf> in the
application home.  Secrets come only from the environment: C<GH_TOKEN> for
GitHub and C<CLAUDE_CODE_OAUTH_TOKEN> for Claude Code.  With C<run_as>, the
account that claude runs as brings its own token: see
L<App::Clod::Claude/run_as>.

=head1 WHEN A TOKEN STOPS WORKING

If GitHub or Claude refuses its token with a 401, the bot is in an outage.  The
jobs do not fail one after another.  A GitHub outage holds all work, and a
Claude outage holds the work that runs C<claude>.  Each held job waits ten
minutes, and then the next job tries the token again.  The Overview tab names
the outage first.  After you replace the token in the environment and restart
both processes, the work starts again within ten minutes.  See
L<App::Clod::Outage>.

=head1 WHAT THE HOST NEEDS

=over

=item *

C<git> and the C<claude> program, signed in through C<CLAUDE_CODE_OAUTH_TOKEN>.

=item *

The tools that the hooks of each spoke run, such as perltidy, perlcritic with
its policies, and tests-covering.  The bot installs each spoke's own
F<git-hooks>, so a commit in a worktree fails when a tool is missing.

=item *

A bot account with write access to every spoke, and a classic token with the
C<repo> and C<notifications> scopes.  The Overview tab names a missing scope.
For C<create_repos>, the account must also be allowed to make repositories in
each organization of C<spoke_orgs>.

=back

=head1 THE HEALTH PAGE

=over

=item Overview

Jobs by state, the Claude Code quota used in the five-hour and seven-day
windows, and the action items: an outage, a marketplace pin older than the
plugin, failed jobs, harness checks that fail, token scopes that are missing,
and an inbox that waits because no repository is a spoke.

Some action items have a button, which settles them from the page:

=over

=item * Retry, on a failed job, queues it again, as F</minion> does.

=item * Ignore, on a failed job, takes it off the action items.  The job
stays failed in F</minion>.

=item * Fix, on a spoke that fails harness checks, queues
L<App::Clod::Tasks/harness_fix>.  That job runs the update of the standards
on a new branch, with no claude run, and opens a pull request for what it
changed, with an issue that it closes.

=item * Update, when the bot is out of date, queues
L<App::Clod::Tasks/self_update>.  The bot is out of date when its checkout is
behind its upstream, or when it runs another commit than its checkout has.
L<App::Clod::Tasks/self_check> finds that out every half hour.

=item * Update plugins, when a plugin of the account that claude runs as is
behind its marketplace, queues L<App::Clod::Tasks/plugin_update>.

=back

The header of the page shows the short sha of the commit that the page runs.

The buttons post to F</act>, which takes a request only with the header
C<X-Clod-Action: yes>.  A browser sends the credentials of the page with a
form that another site posts, but it sends no such header for another site.

=item Work

The items in progress with their repositories and pull requests, the items in
the queue, and the open issues assigned to the bot that no job has yet.

=item Harness

For each spoke, its flavor and the result of each check of that flavor.  A
spoke without a F<.conformance.yml> shows the default flavor, marked
"(default)".  See L<App::Clod::Harness>.

=back

=head1 CAVEATS

The bot account must be used by App::Clod alone.  App::Clod knows what it has
answered by the login of the bot, and what is new by which of the bot's
notifications are unread.  Anything else that uses the same account changes
both:

=over

=item *

A comment by the account from another program, or from a person signed in as
the bot, counts as an answer of the bot.  Every comment before it then counts
as answered, and so does each review thread whose last message it is.

=item *

Anything that marks the account's notifications read hides them from the
poll, which reads only unread ones.  That includes a person who opens them on
GitHub while signed in as the bot.

=item *

An assignment or a review request made by the account has the bot as its
actor, and the bot is not an authorized user, so the poll ignores it.

=back

One installation must serve public repositories or private ones, never both.
Triage reads every spoke, and a spoke run reads its tool spokes and the
summaries of the spokes before it.  So what a private repository holds can
reach a prompt about a public one, and from there a public pull request or
comment.  Run a second installation, with a bot account of its own, for
private repositories.  For the same reason C<create_repos> makes public
repositories only, and the bot refuses a request for a private one.

An edit to a comment that the bot has already answered is not seen.  GitHub
sends no notification for an edit, and the comment keeps its place before the
answer.  To change a request, add a comment.

=head1 SEE ALSO

L<App::Clod::Config>
L<App::Clod::Tasks>
L<App::Clod::Harness>
L<Minion>

=cut
