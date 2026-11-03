package App::Clod;

# ABSTRACT: Hub-and-spoke agent manager that keeps it simple

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Mojo::Base 'Mojolicious', -signatures;

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

=method startup

The Mojolicious entry point.

=cut

sub startup ($self) {
    my $raw    = $self->plugin( Config => { file => $ENV{CLOD_CONFIG} // 'clod.conf', default => {} } );
    my $config = App::Clod::Config::validate($raw);
    Mojo::File->new( $config->{workspace} )->make_path;
    $self->config($config);
    $self->helper( clod_config => sub { $config } );

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
becomes work on the review comments, and a mention becomes a reply.

GitHub keeps one notification per issue or pull request, not one per comment.
Each new comment updates it, and its reason is the reason of the latest one.
So a comment on the bot's own pull request that mentions the bot by name is a
mention, and gets a reply, not work on the review comments.  If the reply finds
that the person asked for a change, it starts that work.  Several comments that
arrive while the work on a pull request waits to start get no job of their own,
because that work collects everything that was said since the bot last
answered.  A comment that arrives while that work runs gets a job of its own.

Each fix, review and review answer starts with triage: one C<claude -p> run
that can read every spoke and decides whether one repository, several, or an
upstream project that we do not own is the right place for the change.  Then
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
GitHub and C<CLAUDE_CODE_OAUTH_TOKEN> for Claude Code.

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

=back

=head1 THE HEALTH PAGE

=over

=item Overview

Jobs by state, the Claude Code quota used in the five-hour and seven-day
windows, and the action items: an outage, a marketplace pin older than the
plugin, failed jobs, harness checks that fail, and token scopes that are
missing.

=item Work

The items in progress with their repositories and pull requests, the items in
the queue, and the open issues assigned to the bot that no job has yet.

=item Harness

For each spoke, whether each part of the standard harness is in place.  See
L<App::Clod::Harness>.

=back

=head1 SEE ALSO

L<App::Clod::Config>
L<App::Clod::Tasks>
L<App::Clod::Harness>
L<Minion>

=cut
