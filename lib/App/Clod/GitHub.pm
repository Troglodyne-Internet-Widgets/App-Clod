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

=cut

sub transient ( $method, $error ) {
    return $error =~ m{:\ (?:5\d\d\ |no\ response:)} if $method eq 'GET';
    return $error =~ m{:\ 50[234]\ };
}

=method request_once

Makes the request of L</request> once, with no retry.

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

=cut

sub is_unauthorized ($error) { return ( $error // q{} ) =~ m{\AGitHub\ [[:upper:]]+\ \S+:\ 401\ } }

=method get

Returns the decoded JSON, or the body for a raw C<accept>.

=cut

sub get ( $self, $path, %opt ) {
    my $res = $self->request( GET => $path, %opt );
    return index( $opt{accept} // q{}, q{raw} ) >= 0 ? $res->body : $res->json;
}

=method paginate

Follows C<Link: rel="next"> and returns every item.

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

C<($path, $json, %opt)>.  Returns the decoded JSON.

=cut

sub post ( $self, $path, $json, %opt ) { return $self->request( POST => $path, json => $json, %opt )->json }

=method patch

C<($path, $json)>.  Returns the decoded JSON.

=cut

sub patch ( $self, $path, $json ) { return $self->request( PATCH => $path, json => $json )->json }

=method notifications

C<($if_modified_since)>.  Returns the threads and a hash of C<last_modified>,
C<poll_interval> and C<scopes>.  A 304 returns no threads.

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

=cut

sub mark_read ( $self, $thread_id ) { return $self->request( PATCH => "/notifications/threads/$thread_id", ok => [304] ) }

=method repo

C<($repo)>.  The repository, as C<Owner/Name>.

=cut

sub repo ( $self, $repo ) { return $self->get("/repos/$repo") }

=method repo_exists

C<($repo)>.  False when GitHub answers 404 for the repository.  A repository
that was renamed answers with a redirect to its new name, so its old name
exists too.  A private repository that the token cannot see answers 404 as
well, so it shows only when making it fails.

=cut

sub repo_exists ( $self, $repo ) { return $self->request( GET => "/repos/$repo", ok => [404] )->code != 404 }

=method create_org_repo

C<($org, \%repo)>.  Makes a repository in the organization, as the bot, with
the fields of C<%repo>, such as C<name>, C<description>, C<visibility> and
C<auto_init>.  Returns the new repository.

=cut

sub create_org_repo ( $self, $org, $repo ) { return $self->post( "/orgs/$org/repos", $repo ) }

=method create_issue

C<($repo, \%issue)>, where C<%issue> has C<title>, C<body> and optionally
C<assignees>.  Returns the issue, whose C<assignees> say whom GitHub really
assigned.

=cut

sub create_issue ( $self, $repo, $issue ) { return $self->post( "/repos/$repo/issues", $issue ) }

=method issue

C<($repo, $number)>.

=cut

sub issue ( $self, $repo, $number ) { return $self->get("/repos/$repo/issues/$number") }

=method pull

C<($repo, $number)>.

=cut

sub pull ( $self, $repo, $number ) { return $self->get("/repos/$repo/pulls/$number") }

=method issue_comments

C<($repo, $number)>.  Every comment on the issue or pull request.

=cut

sub issue_comments ( $self, $repo, $number ) { return $self->paginate("/repos/$repo/issues/$number/comments") }

=method issue_events

C<($repo, $number)>.  Every event, such as an assignment.

=cut

sub issue_events ( $self, $repo, $number ) { return $self->paginate("/repos/$repo/issues/$number/events") }

=method review_comments

C<($repo, $number)>.  Every line comment of every review.

=cut

sub review_comments ( $self, $repo, $number ) { return $self->paginate("/repos/$repo/pulls/$number/comments") }

=method reviews

C<($repo, $number)>.  Every review of the pull request that the token can see,
each with its C<body>, C<state> and C<submitted_at>.

=cut

sub reviews ( $self, $repo, $number ) { return $self->paginate("/repos/$repo/pulls/$number/reviews") }

=method react

C<($repo, $number, $content)>.  Adds a reaction, C<eyes> by default.

=cut

sub react ( $self, $repo, $number, $content = 'eyes' ) {
    return $self->post( "/repos/$repo/issues/$number/reactions", { content => $content } );
}

=method comment

C<($repo, $number, $body)>.

=cut

sub comment ( $self, $repo, $number, $body ) { return $self->post( "/repos/$repo/issues/$number/comments", { body => $body } ) }

=method reply_review_comment

C<($repo, $number, $comment_id, $body)>.  Replies in the thread of a line
comment.

=cut

sub reply_review_comment ( $self, $repo, $number, $comment_id, $body ) {
    return $self->post( "/repos/$repo/pulls/$number/comments/$comment_id/replies", { body => $body } );
}

=method create_pull

C<($repo, \%pull)>, where C<%pull> has C<title>, C<head>, C<base> and C<body>.

=cut

sub create_pull ( $self, $repo, $pull ) { return $self->post( "/repos/$repo/pulls", $pull ) }

=method open_pulls

C<($repo)>.  The open pull requests of the repository.

=cut

sub open_pulls ( $self, $repo ) { return $self->paginate( "/repos/$repo/pulls", query => { state => 'open' } ) }

=method update_pull

C<($repo, $number, \%fields)>.

=cut

sub update_pull ( $self, $repo, $number, $fields ) { return $self->patch( "/repos/$repo/pulls/$number", $fields ) }

=method review

C<($repo, $number, \%review)>, where C<%review> has C<event>, C<body>,
C<commit_id> and optionally C<comments>.

=cut

sub review ( $self, $repo, $number, $review ) { return $self->post( "/repos/$repo/pulls/$number/reviews", $review ) }

=method assign

C<($repo, $number, @logins)>.

=cut

sub assign ( $self, $repo, $number, @logins ) {
    return $self->post( "/repos/$repo/issues/$number/assignees", { assignees => \@logins } );
}

=method unassign

C<($repo, $number, @logins)>.

=cut

sub unassign ( $self, $repo, $number, @logins ) {
    return $self->request( DELETE => "/repos/$repo/issues/$number/assignees", json => { assignees => \@logins } );
}

=method org_repos

C<($org)>.  The public repositories of an organization.

=cut

sub org_repos ( $self, $org ) { return $self->paginate( "/orgs/$org/repos", query => { type => 'public' } ) }

=method assigned_issues

C<($repo, $login)>.  The open issues and pull requests assigned to C<$login>.

=cut

sub assigned_issues ( $self, $repo, $login ) {
    return $self->paginate( "/repos/$repo/issues", query => { assignee => $login, state => 'open' } );
}

=method unassigned_issues

C<($repo)>.  The open issues that nobody is assigned to.  GitHub lists pull
requests among the issues, so this drops each item that has a C<pull_request>.

=cut

sub unassigned_issues ( $self, $repo ) {
    my $list = $self->paginate( "/repos/$repo/issues", query => { assignee => 'none', state => 'open' } );
    return [ grep { !$_->{pull_request} } @$list ];
}

=method opened_issues

C<($repo, $since)>.  The issues, open or closed, that were created at or after
C<$since>, an ISO 8601 time in UTC.  The C<since> parameter of GitHub selects on
the time of the last update, so this also checks C<created_at>.  Pull requests
are not issues here.

=cut

sub opened_issues ( $self, $repo, $since ) {
    my $list = $self->paginate( "/repos/$repo/issues", query => { state => 'all', since => $since } );
    return [ grep { !$_->{pull_request} && ( $_->{created_at} // q{} ) ge $since } @$list ];
}

=method merged_pulls

C<($repo, $since)>.  The pull requests that were merged at or after C<$since>,
an ISO 8601 time in UTC, found with the search API.  A search returns at most
1000 items, which is far above what a repository merges in a week.

=cut

sub merged_pulls ( $self, $repo, $since ) {
    return $self->paginate( '/search/issues', query => { q => "repo:$repo is:pr is:merged merged:>=$since" } );
}

=method tree

C<($repo, $ref)>.  The recursive tree as a hash of path to entry.

=cut

sub tree ( $self, $repo, $ref ) {
    my $tree = $self->get( "/repos/$repo/git/trees/" . Mojo::Util::url_escape($ref), query => { recursive => 1 } );
    return { map { $_->{path} => $_ } @{ $tree->{tree} } };
}

=method file

C<($repo, $path, $ref)>.  The raw content, or undef when the file is not there.

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
