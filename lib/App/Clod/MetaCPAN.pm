package App::Clod::MetaCPAN;

# ABSTRACT: The MetaCPAN calls that the release sweep makes

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Mojo::Base -base, -signatures;

use Mojo::UserAgent();
use Mojo::URL  ();
use Mojo::Util ();

=attr api

The API base URL.

=cut

has api => 'https://fastapi.metacpan.org/v1';

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

=method get

C<($path)>.  The decoded JSON of the answer.  It dies with "no response" and
the transport error when no answer came, and with the status and the message
for an answer of 400 or more.

=cut

sub get ( $self, $path ) {
    my $url = Mojo::URL->new( $self->api . $path );
    my $tx  = $self->ua->get($url);
    my $res = $tx->res;
    die "MetaCPAN GET $url: no response: " . ( $tx->error->{message} // 'unknown' ) . "\n" if !$res->code;
    if ( $res->code >= 400 ) {
        my $message = eval { $res->json->{message} } // $res->body;
        die sprintf( "MetaCPAN GET %s: %d %s\n", $url->path, $res->code, $message // q{} );
    }
    return $res->json;
}

=method versions

C<($dist)>.  The version of each release of the distribution, newest first.
That includes a release that was deleted from CPAN and is on BackPAN only,
because PAUSE never takes that version of the distribution again.  A
distribution that MetaCPAN does not know has none.

=cut

sub versions ( $self, $dist ) {
    return [ map { $_->{version} } @{ $self->get( '/release/versions/' . Mojo::Util::url_escape($dist) )->{releases} // [] } ];
}

1;

=head1 SYNOPSIS

    use 5.040;
    use App::Clod::MetaCPAN;

    my $cpan     = App::Clod::MetaCPAN->new( timeout => 30 );
    my $released = grep { $_ eq '0.006' } @{ $cpan->versions('App-Clod') };

=head1 DESCRIPTION

A blocking client, for use inside a Minion job, over L<Mojo::UserAgent>, of
the MetaCPAN API, which needs no token.  Its errors read like those of
L<App::Clod::GitHub>: each message ends in a newline, so perl adds no file and
line to it, and it can be shown as it is.

=cut
