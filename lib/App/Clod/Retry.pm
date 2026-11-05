package App::Clod::Retry;

# ABSTRACT: Try again when GitHub fails for a moment

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';

use Time::HiRes ();

# The pause before each try after the first, in seconds.  Four tries in all.
our @DELAYS = ( 5, 30, 120 );

=func attempt

C<($what, $transient, $try)>.  Calls C<< $try->() >> and returns what it
returns, in list context.  If it dies with an error for which
C<< $transient->($error) >> is true, it waits the next of C<@DELAYS>, warns
with C<$what> and the error, and calls it again.  When the delays run out, or
the error is not transient, it dies with the last error.

=cut

sub attempt ( $what, $transient, $try ) {
    my @delays = @DELAYS;
    while (1) {
        my @out;
        return @out if eval { @out = $try->(); 1 };
        my $error = $@;
        die $error if !@delays || !$transient->($error);
        my $delay = shift @delays;
        warn "$what failed for a moment, trying again in ${delay}s: $error";
        Time::HiRes::sleep($delay);
    }
    return;
}

1;

=head1 SYNOPSIS

    use App::Clod::Retry ();

    my $out = App::Clod::Retry::attempt(
        'git push',
        sub ($error) { $error =~ m{Internal\ Server\ Error} },
        sub { push_it() },
    );

=head1 DESCRIPTION

GitHub answers some requests with a server error, or not at all, while it is
under load, and the same request a minute later succeeds.  This is the loop
that the GitHub client and the git commands of a spoke try again in.  The
caller says which errors are worth another try, because only the caller knows
whether a request that failed can have done its work anyway.

=cut
