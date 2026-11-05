package App::Clod::Command::deps;    ## no critic (NamingConventions::Capitalization) -- Mojolicious runs this package as the command clod deps

# ABSTRACT: Install, list or upgrade the Perl modules of the bot in its local lib

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Mojo::Base 'Mojolicious::Command', -signatures;

use App::Clod::Deps  ();
use App::Clod::Tasks ();

has description => 'Install, list or upgrade the Perl modules of the bot in its local lib';
has usage       => <<'EOF';
Usage: clod deps install|outdated|upgrade

  install   install every module that the checkout needs into local_lib,
            and the tools of the agent into agent_lib
  outdated  list the modules in either lib that CPAN has a newer release of
  upgrade   install the newest release of each of them
EOF

=method run

C<($what)>, one of C<install>, C<outdated> and C<upgrade>.  Works on
C<local_lib> and C<agent_lib>, each that F<clod.conf> names.  C<install> puts
the modules of the checkout into the first and the
L<App::Clod::Tasks/agent_tools> into the second.  Dies when F<clod.conf> names
neither, or C<install> into C<local_lib> runs from no checkout.

=cut

sub run ( $self, $what = q{} ) {
    my $config = $self->app->clod_config;
    my @libs   = grep { $config->{$_} } qw{local_lib agent_lib};
    die "clod.conf names no local_lib and no agent_lib\n" if !@libs;
    if ( $what eq 'install' ) {
        if ( $config->{local_lib} ) {
            my $checkout = App::Clod::checkout() // die "the bot runs from no checkout, so there is nothing to list the modules of\n";
            App::Clod::Deps::install( $config->{local_lib}, App::Clod::Deps::listdeps($checkout) );
        }
        App::Clod::Deps::install( $config->{agent_lib}, App::Clod::Tasks::agent_tools($config) ) if $config->{agent_lib};
        return;
    }
    if ( $what eq 'outdated' || $what eq 'upgrade' ) {
        my @found = map { @{ $what eq 'upgrade' ? App::Clod::Deps::upgrade( $config->{$_} ) : App::Clod::Deps::outdated( $config->{$_} ) } } @libs;
        my $lines = join q{}, map { join( "\t", @$_{qw{module version latest}} ) . "\n" } @found;
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
