package App::Clod::Command::deps;    ## no critic (NamingConventions::Capitalization) -- Mojolicious runs this package as the command clod deps

# ABSTRACT: Install, list or upgrade the Perl modules of the bot in its local lib

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Mojo::Base 'Mojolicious::Command', -signatures;

use App::Clod::Deps ();

has description => 'Install, list or upgrade the Perl modules of the bot in its local lib';
has usage       => <<'EOF';
Usage: clod deps install|outdated|upgrade

  install   install every module that the checkout needs into local_lib
  outdated  list the modules in local_lib that CPAN has a newer release of
  upgrade   install the newest release of each of them
EOF

=method run

C<($what)>, one of C<install>, C<outdated> and C<upgrade>.  Dies when
F<clod.conf> names no C<local_lib>, or C<install> runs from no checkout.

=cut

sub run ( $self, $what = q{} ) {
    my $lib = $self->app->clod_config->{local_lib} // die "clod.conf names no local_lib\n";
    if ( $what eq 'install' ) {
        my $checkout = App::Clod::checkout() // die "the bot runs from no checkout, so there is nothing to list the modules of\n";
        App::Clod::Deps::install( $lib, App::Clod::Deps::listdeps($checkout) );
        return;
    }
    if ( $what eq 'outdated' || $what eq 'upgrade' ) {
        my $found = $what eq 'upgrade' ? App::Clod::Deps::upgrade($lib) : App::Clod::Deps::outdated($lib);
        my $lines = join q{}, map { join( "\t", @$_{qw{module version latest}} ) . "\n" } @$found;
        print {*STDOUT} $lines or die "Cannot print: $!\n";
        return;
    }
    die $self->usage;
}

1;

=head1 SYNOPSIS

    clod deps install
    clod deps outdated
    clod deps upgrade

=head1 DESCRIPTION

The shell side of L<App::Clod::Deps>.  The clod recipe of trog-provisioner
runs C<clod deps install> as the service user before the units start, so the
local lib holds every module that the checkout needs.

=cut
