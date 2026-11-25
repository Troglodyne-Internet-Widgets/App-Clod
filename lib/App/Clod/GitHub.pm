package App::Clod::GitHub;

# ABSTRACT: The GitHub REST calls that the bot makes

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Mojo::Base -base, -signatures;

use Mojo::UserAgent();
use Mojo::URL  ();
use Mojo::Util ();

use App::Clod::Retry ();

=attr api

The API base URL.

=cut

has api => 'https://api.github.com';

=attr token

The bot's token.  Default C<GH_TOKEN>.

=cut

has token => sub { $ENV{GH_TOKEN} // die "GH_TOKEN is not set\n" };

=attr timeout

Seconds for each request.

=cut

has timeout => 30;

=attr ua

The L<Mojo::UserAgent>.

=cut

has ua => sub ($self) {
    my $ua = Mojo::UserAgent->new( max_redirects => 3 );
    $ua->connect_timeout(10)->request_timeout( $self->timeout )->inactivity_timeout( $self->timeout );
    return $ua;
};

my sub next_link ($link) {
    my ($next) = ( $link // q{} ) =~ m{<([^>]+)>;\s*rel="next"};
    return $next;
}

=method request

C<< ($method, $path_or_url, %opt) >>, where C<%opt> takes C<query>, C<json>,
C<headers>, C<accept> and C<ok>.  Returns the L<Mojo::Message::Response>.
A failure that L</transient> calls a moment's trouble at GitHub gets more
tries, through L<App::Clod::Retry/attempt>.

Returns a Mojo::Message::Response object, the answer of GitHub.

    my $res = $gh->request( GET => "/repos/$repo", ok => [404] );

=cut

sub request ( $self, $method, $path, %opt ) {
    return ( App::Clod::Retry::attempt( "GitHub $method $path", sub ($error) { transient( $method, $error ) }, sub { $self->request_once( $method, $path, %opt ) } ) )[0];
}

=func transient

C<($method, $error)>.  True if the error of L</request> is worth another try.
A GET tries again after any server error, or no answer at all.  Any other
method changes something, and a server error or a lost answer can mean that
GitHub did it anyway.  So it tries again only after a 502, 503 or 504, which a
proxy in front of GitHub answers.

Returns Bool, true when another try is worth it.

    my $again = App::Clod::GitHub::transient( POST => $error );

=cut

sub transient ( $method, $error ) {
    return $error =~ m{:\ (?:5\d\d\ |no\ response:)} if $method eq 'GET';
    return $error =~ m{:\ 50[234]\ };
}

=method request_once

Makes the request of L</request> once, with no retry.

Returns a Mojo::Message::Response object, the answer of GitHub.

Dies when no answer comes back, and when the answer has a status of 400 or
more that C<ok> does not name.  L</DESCRIPTION> gives the form of each
message.

    my $res = $gh->request_once( GET => "/repos/$repo" );

=cut

sub request_once ( $self, $method, $path, %opt ) {
    my $url = $path =~ m{\Ahttps?://} ? Mojo::URL->new($path) : Mojo::URL->new( $self->api . $path );
    $url->query( $opt{query} ) if $opt{query};
    my %headers = (
        Authorization          => 'Bearer ' . $self->token,
        Accept                 => $opt{accept} // 'application/vnd.github+json',
        'X-GitHub-Api-Version' => '2022-11-28',
        %{ $opt{headers} // {} },
    );
    my $tx = $self->ua->build_tx( $method => $url => \%headers, exists $opt{json} ? ( json => $opt{json} ) : () );
    $tx = $self->ua->start($tx);

    my $res = $tx->res;

    # No code means that no answer came back: DNS, connect, TLS or the timeout.
    die "GitHub $method $url: no response: " . ( $tx->error->{message} // 'unknown' ) . "\n" if !$res->code;

    my %ok = map { $_ => 1 } @{ $opt{ok} // [] };
    if ( $res->code >= 400 && !$ok{ $res->code } ) {
        my $message = eval { $res->json->{message} } // $res->body;
        die sprintf( "GitHub %s %s: %d %s\n", $method, $url->path, $res->code, $message // q{} );
    }
    return $res;
}

=func is_unauthorized

C<($error)>.  True when the error is the one that L</request> dies with for a
401, which GitHub answers to a token that is wrong, expired or revoked.

Returns Bool, true for the error of a 401.

    warn "the token is bad\n" if App::Clod::GitHub::is_unauthorized($error);

=cut

sub is_unauthorized ($error) { return ( $error // q{} ) =~ m{\AGitHub\ [[:upper:]]+\ \S+:\ 401\ } }

=method get

Returns the decoded JSON, or the body for a raw C<accept>.

    my $repository = $gh->get("/repos/$repo");

=cut

sub get ( $self, $path, %opt ) {
    my $res = $self->request( GET => $path, %opt );
    return index( $opt{accept} // q{}, q{raw} ) >= 0 ? $res->body : $res->json;
}

=method paginate

Follows C<Link: rel="next"> and returns every item.

Returns ArrayRef[HashRef], the items of every page.

    my $labels = $gh->paginate("/repos/$repo/labels");

=cut

sub paginate ( $self, $path, %opt ) {
    my @items;
    my $next  = $path;
    my %query = ( per_page => 100, %{ $opt{query} // {} } );
    while ($next) {
        my $res  = $self->request( GET => $next, %opt, query => ( $next eq $path ? \%query : undef ) );
        my $page = $res->json;
        push @items, ref $page eq 'ARRAY' ? @$page : @{ $page->{items} // [] };
        $next = next_link( $res->headers->header('Link') );
    }
    return \@items;
}

=method post

C<($path, $json, %opt)>.

Returns HashRef, the decoded JSON.

    $gh->post( "/repos/$repo/labels", { name => 'bug' } );

=cut

sub post ( $self, $path, $json, %opt ) { return $self->request( POST => $path, json => $json, %opt )->json }

=method patch

C<($path, $json)>.

Returns HashRef, the decoded JSON.

    $gh->patch( "/repos/$repo/issues/12", { state => 'closed' } );

=cut

sub patch ( $self, $path, $json ) { return $self->request( PATCH => $path, json => $json )->json }

=method notifications

C<($if_modified_since)>.

Returns ArrayRef[HashRef] or HashRef: two values in list context.  The
ArrayRef of the threads comes first, then a HashRef of C<last_modified>,
C<poll_interval> and C<scopes>.  A 304 returns no threads.

    my ( $threads, $meta ) = $gh->notifications( $meta->{last_modified} );

=cut

sub notifications ( $self, $if_modified_since = undef ) {
    my %headers = $if_modified_since ? ( 'If-Modified-Since' => $if_modified_since ) : ();
    my $res     = $self->request( GET => '/notifications', headers => \%headers, ok => [304] );
    my %meta    = (
        last_modified => $res->headers->header('Last-Modified'),
        poll_interval => $res->headers->header('X-Poll-Interval'),
        scopes        => $res->headers->header('X-OAuth-Scopes'),
    );
    return ( [], \%meta ) if $res->code == 304;
    my $threads = $res->json;
    my $next    = next_link( $res->headers->header('Link') );
    push @$threads, @{ $self->paginate($next) } if $next;
    return ( $threads, \%meta );
}

=method mark_read

C<($thread_id)>.  Marks a notification thread read.

Returns a Mojo::Message::Response object, the answer of GitHub.

    $gh->mark_read( $thread->{id} );

=cut

sub mark_read ( $self, $thread_id ) { return $self->request( PATCH => "/notifications/threads/$thread_id", ok => [304] ) }

=method repo

C<($repo)>.  The repository, as C<Owner/Name>.

Returns HashRef, the repository as GitHub describes it.

    my $branch = $gh->repo('Owner/Name')->{default_branch};

=cut

sub repo ( $self, $repo ) { return $self->get("/repos/$repo") }

=method repo_exists

C<($repo)>.  False when GitHub answers 404 for the repository.  A repository
that was renamed answers with a redirect to its new name, so its old name
exists too.  A private repository that the token cannot see answers 404 as
well, so it shows only when making it fails.

Returns Bool, true when the repository exists.

    $gh->create_org_repo( 'Test-Org', { name => 'Name' } ) if !$gh->repo_exists('Test-Org/Name');

=cut

sub repo_exists ( $self, $repo ) { return $self->request( GET => "/repos/$repo", ok => [404] )->code != 404 }

=method create_org_repo

C<($org, \%repo)>.  Makes a repository in the organization, as the bot, with
the fields of C<%repo>, such as C<name>, C<description>, C<visibility> and
C<auto_init>.

Returns HashRef, the new repository.

    my $new = $gh->create_org_repo( 'Test-Org', { name => 'Name', auto_init => 1 } );

=cut

sub create_org_repo ( $self, $org, $repo ) { return $self->post( "/orgs/$org/repos", $repo ) }

=method create_issue

C<($repo, \%issue)>, where C<%issue> has C<title>, C<body> and optionally
C<assignees>.

Returns HashRef, the new issue, whose C<assignees> say whom GitHub really
assigned.

    my $issue = $gh->create_issue( $repo, { title => 'The build fails', body => 'See the log.' } );

=cut

sub create_issue ( $self, $repo, $issue ) { return $self->post( "/repos/$repo/issues", $issue ) }

=method issue

C<($repo, $number)>.

Returns HashRef, the issue or pull request.

    my $title = $gh->issue( $repo, 12 )->{title};

=cut

sub issue ( $self, $repo, $number ) { return $self->get("/repos/$repo/issues/$number") }

=method pull

C<($repo, $number)>.

Returns HashRef, the pull request.

    my $head = $gh->pull( $repo, 12 )->{head}{sha};

=cut

sub pull ( $self, $repo, $number ) { return $self->get("/repos/$repo/pulls/$number") }

=method issue_comments

C<($repo, $number)>.  Every comment on the issue or pull request.

Returns ArrayRef[HashRef], the comments, oldest first.

    my $comments = $gh->issue_comments( $repo, 12 );

=cut

sub issue_comments ( $self, $repo, $number ) { return $self->paginate("/repos/$repo/issues/$number/comments") }

=method issue_events

C<($repo, $number)>.  Every event, such as an assignment.

Returns ArrayRef[HashRef], the events.

    my $events = $gh->issue_events( $repo, 12 );

=cut

sub issue_events ( $self, $repo, $number ) { return $self->paginate("/repos/$repo/issues/$number/events") }

=method review_comments

C<($repo, $number)>.  Every line comment of every review.

Returns ArrayRef[HashRef], the line comments.

    my $comments = $gh->review_comments( $repo, 12 );

=cut

sub review_comments ( $self, $repo, $number ) { return $self->paginate("/repos/$repo/pulls/$number/comments") }

=method reviews

C<($repo, $number)>.  Every review of the pull request that the token can see,
each with its C<body>, C<state> and C<submitted_at>.

Returns ArrayRef[HashRef], the reviews.

    my @approved = grep { $_->{state} eq 'APPROVED' } @{ $gh->reviews( $repo, 12 ) };

=cut

sub reviews ( $self, $repo, $number ) { return $self->paginate("/repos/$repo/pulls/$number/reviews") }

=method react

C<($repo, $number, $content)>.  Adds a reaction, C<eyes> by default.

Returns HashRef, the reaction.

    $gh->react( $repo, 12, '+1' );

=cut

sub react ( $self, $repo, $number, $content = 'eyes' ) {
    return $self->post( "/repos/$repo/issues/$number/reactions", { content => $content } );
}

=method comment

C<($repo, $number, $body)>.

Returns HashRef, the new comment.

    $gh->comment( $repo, 12, 'On it.' );

=cut

sub comment ( $self, $repo, $number, $body ) { return $self->post( "/repos/$repo/issues/$number/comments", { body => $body } ) }

=method reply_review_comment

C<($repo, $number, $comment_id, $body)>.  Replies in the thread of a line
comment.

Returns HashRef, the new reply.

    $gh->reply_review_comment( $repo, 12, $comment->{id}, 'Fixed.' );

=cut

sub reply_review_comment ( $self, $repo, $number, $comment_id, $body ) {
    return $self->post( "/repos/$repo/pulls/$number/comments/$comment_id/replies", { body => $body } );
}

=method create_pull

C<($repo, \%pull)>, where C<%pull> has C<title>, C<head>, C<base> and C<body>,
and optionally C<draft>, true for a draft.

Returns HashRef, the new pull request.

    my $pull = $gh->create_pull( $repo, { title => 'Fix the build', head => 'fix-build', base => 'master', body => 'Fixes #12' } );

=cut

sub create_pull ( $self, $repo, $pull ) { return $self->post( "/repos/$repo/pulls", $pull ) }

=method open_pulls

C<($repo)>.  The open pull requests of the repository.

Returns ArrayRef[HashRef], the pull requests.

    my $pulls = $gh->open_pulls($repo);

=cut

sub open_pulls ( $self, $repo ) { return $self->paginate( "/repos/$repo/pulls", query => { state => 'open' } ) }

=method update_pull

C<($repo, $number, \%fields)>.

Returns HashRef, the changed pull request.

    $gh->update_pull( $repo, 12, { body => 'Fixes #11' } );

=cut

sub update_pull ( $self, $repo, $number, $fields ) { return $self->patch( "/repos/$repo/pulls/$number", $fields ) }

=method mark_draft

C<($node_id)>.  Makes the pull request with that C<node_id> a draft.  The
REST API cannot do this, so it goes through L</graphql>.

Returns HashRef, the C<data> of the answer.

    $gh->mark_draft( $pull->{node_id} );

=cut

sub mark_draft ( $self, $node_id ) {
    return $self->graphql( 'mutation($id: ID!) { convertPullRequestToDraft(input: {pullRequestId: $id}) { pullRequest { isDraft } } }', id => $node_id );
}

=method mark_ready

C<($node_id)>.  Makes the draft pull request with that C<node_id> ready for
review, through L</graphql>, as L</mark_draft> does.

Returns HashRef, the C<data> of the answer.

    $gh->mark_ready( $pull->{node_id} );

=cut

sub mark_ready ( $self, $node_id ) {
    return $self->graphql( 'mutation($id: ID!) { markPullRequestReadyForReview(input: {pullRequestId: $id}) { pullRequest { isDraft } } }', id => $node_id );
}

=method graphql

C<($query, %variables)>.  Posts the query to the GraphQL API, at
L</graphql_url>.  GitHub answers a query that it cannot do with a 200 and
C<errors>.  Then this dies with each message.

Returns HashRef, the C<data> of the answer.

    my $data = $gh->graphql( 'query($login: String!) { user(login: $login) { name } }', login => $login );

=cut

sub graphql ( $self, $query, %variables ) {
    my $answer = $self->request( POST => graphql_url( $self->api ), json => { query => $query, variables => \%variables } )->json // {};
    my @errors = map { $_->{message} // 'no message' } @{ $answer->{errors} // [] };
    die 'GitHub GraphQL: ' . join( q{; }, @errors ) . "\n" if @errors;
    return $answer->{data};
}

=func graphql_url

C<($api)>, an L</api>.  The URL of the GraphQL API beside it: F</graphql>
for api.github.com, and F</api/graphql> for a GitHub Enterprise Server, whose
REST API is at F</api/v3>.

Returns Str, the URL.

    my $url = App::Clod::GitHub::graphql_url('https://github.test.test/api/v3');

=cut

sub graphql_url ($api) {
    return $api =~ s{/api/v3/?\z}{/api/graphql}r if $api =~ m{/api/v3/?\z};
    return "$api/graphql";
}

=method review

C<($repo, $number, \%review)>, where C<%review> has C<event>, C<body>,
C<commit_id> and optionally C<comments>.

Returns HashRef, the new review.

    $gh->review( $repo, 12, { event => 'COMMENT', body => 'Looks right.', commit_id => $sha } );

=cut

sub review ( $self, $repo, $number, $review ) { return $self->post( "/repos/$repo/pulls/$number/reviews", $review ) }

=method assign

C<($repo, $number, @logins)>.

Returns HashRef, the issue with its new C<assignees>.

    $gh->assign( $repo, 12, $login );

=cut

sub assign ( $self, $repo, $number, @logins ) {
    return $self->post( "/repos/$repo/issues/$number/assignees", { assignees => \@logins } );
}

=method unassign

C<($repo, $number, @logins)>.

Returns a Mojo::Message::Response object, the answer of GitHub.

    $gh->unassign( $repo, 12, $login );

=cut

sub unassign ( $self, $repo, $number, @logins ) {
    return $self->request( DELETE => "/repos/$repo/issues/$number/assignees", json => { assignees => \@logins } );
}

=method org_repos

C<($org)>.  The public repositories of an organization.

Returns ArrayRef[HashRef], the repositories.

    my @names = map { $_->{full_name} } @{ $gh->org_repos('Test-Org') };

=cut

sub org_repos ( $self, $org ) { return $self->paginate( "/orgs/$org/repos", query => { type => 'public' } ) }

=method assigned_issues

C<($repo, $login)>.  The open issues and pull requests assigned to C<$login>.

Returns ArrayRef[HashRef], the issues and pull requests.

    my $mine = $gh->assigned_issues( $repo, $login );

=cut

sub assigned_issues ( $self, $repo, $login ) {
    return $self->paginate( "/repos/$repo/issues", query => { assignee => $login, state => 'open' } );
}

=method open_issues_by

C<($repo, $login)>.  The open issues that C<$login> opened, without the pull
requests that the same list of GitHub holds.

Returns ArrayRef[HashRef], the issues.

    my $issues = $gh->open_issues_by( $repo, $login );

=cut

sub open_issues_by ( $self, $repo, $login ) {
    return [ grep { !$_->{pull_request} } @{ $self->paginate( "/repos/$repo/issues", query => { creator => $login, state => 'open' } ) } ];
}

=method search_issues

C<($query)>.  The issues and pull requests that the search C<$query> finds,
such as C<user:Test-Org is:issue is:open>, each with C<repository_url>.  Dies
when it finds more than GitHub returns for one search, 1000, because a count
of them would then be too low.

Returns ArrayRef[HashRef], the issues and pull requests.

    my $open = $gh->search_issues('user:Test-Org is:issue is:open');

=cut

our $SEARCH_MAX = 1000;

sub search_issues ( $self, $query ) {
    my $items = $self->paginate( '/search/issues', query => { q => $query } );
    die "GitHub search '$query' finds more than $SEARCH_MAX items, which it does not return\n" if @$items >= $SEARCH_MAX;
    return $items;
}

=method open_pulls_by

C<($login)>.  The open pull requests that C<$login> wrote, in any
repository that the token can see, from a search through L</graphql>.  Each
is a C<PullRequest> node with C<url>, C<number>, C<title>, C<isDraft>,
C<updatedAt>, C<mergeable>, C<reviewDecision>, C<repository> with
C<nameWithOwner> and C<owner>'s C<login>, C<author>'s C<login>, and the
C<statusCheckRollup> of its last commit.  It reads every page of 100.  Like
L</search_issues>, it dies when the search finds more than C<$SEARCH_MAX>,
because GitHub returns no more than that, and the list would be short.

Returns ArrayRef[HashRef], the C<PullRequest> nodes.

    my @drafts = grep { $_->{isDraft} } @{ $gh->open_pulls_by($login) };

=cut

my $OPEN_PULLS = <<~'GRAPHQL';
    query($q: String!, $after: String) { search(query: $q, type: ISSUE, first: 100, after: $after) { issueCount pageInfo { hasNextPage endCursor } nodes { ... on PullRequest {
      url number title isDraft updatedAt mergeable reviewDecision
      repository { nameWithOwner owner { login } }
      author { login }
      commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } } } } }
    GRAPHQL

sub open_pulls_by ( $self, $login ) {
    no autovivification;
    my $q = "is:pr is:open author:$login";
    my ( @pulls, $after );
    while (1) {
        my $search = $self->graphql( $OPEN_PULLS, q => $q, after => $after )->{search};
        die "GitHub search '$q' finds more than $SEARCH_MAX pull requests, which it does not return\n" if $search->{issueCount} > $SEARCH_MAX;
        push @pulls, @{ $search->{nodes} };
        last if !$search->{pageInfo}{hasNextPage};
        $after = $search->{pageInfo}{endCursor};
    }
    return \@pulls;
}

=method tree

C<($repo, $ref)>.  The recursive tree as a hash of path to entry.

Returns HashRef[HashRef], each entry of the tree by its path.

    my $has_dist_ini = exists $gh->tree( $repo, 'master' )->{'dist.ini'};

=cut

sub tree ( $self, $repo, $ref ) {
    my $tree = $self->get( "/repos/$repo/git/trees/" . Mojo::Util::url_escape($ref), query => { recursive => 1 } );
    return { map { $_->{path} => $_ } @{ $tree->{tree} } };
}

=method compare

C<($repo, $base, $head)>.  The comparison of two refs, as GitHub answers it,
with C<ahead_by>, the count of the commits of C<$head> that C<$base> lacks,
and C<commits>, the first 250 of them, oldest first.  Each ref is escaped, so
that a slash in it, as in C<refs/tags/0.006> or a branch name, does not split
the range.

Returns HashRef or undef.  It is undef when either ref is not there.

    my $comparison = $gh->compare( $repo, 'refs/tags/0.006', 'master' );

=cut

sub compare ( $self, $repo, $base, $head ) {
    my $res = $self->request( GET => "/repos/$repo/compare/" . Mojo::Util::url_escape($base) . '...' . Mojo::Util::url_escape($head), ok => [404] );
    return if $res->code == 404;
    return $res->json;
}

=method file

C<($repo, $path, $ref)>.

Returns Str or undef: the raw content, or undef when the file is not there.

    my $text = $gh->file( $repo, 'README.md', 'master' );

=cut

# Undef for a file that is not there, so a caller can tell absence from failure.
sub file ( $self, $repo, $path, $ref = undef ) {
    my $res = $self->request(
        GET    => "/repos/$repo/contents/$path",
        accept => 'application/vnd.github.raw+json',
        ok     => [404],
        $ref ? ( query => { ref => $ref } ) : (),
    );
    return if $res->code == 404;
    return $res->body;
}

1;

=head1 SYNOPSIS

    use 5.040;
    use App::Clod::GitHub;

    my $gh = App::Clod::GitHub->new( timeout => 30 );
    my ( $threads, $meta ) = $gh->notifications;
    ( $threads, $meta ) = $gh->notifications( $meta->{last_modified} );
    $gh->comment( 'Owner/Name', 12, 'On it.' );

=head1 DESCRIPTION

A blocking client, for use inside a Minion job, over L<Mojo::UserAgent>.  The
token comes from C<GH_TOKEN>.

A request that got no answer dies with "no response" and the transport error.
A request that got an answer of 400 or more dies with the status and GitHub's
message, unless the caller named that status in C<ok>.  So the two failures
read differently in a job's result.  Each message ends in a newline, so perl
adds no file and line to it, and it can be shown as it is.

=cut
