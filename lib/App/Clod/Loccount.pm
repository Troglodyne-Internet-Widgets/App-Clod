package App::Clod::Loccount;

# ABSTRACT: Count the lines of a directory with loccount, and read its estimates

use 5.040;
no autovivification;
use warnings FATAL => 'all';
use re '/aasx';
use Mojo::Base -base, -signatures;

use IPC::Run   ();
use List::Util ();
use Mojo::JSON ();

=attr bin

The loccount program.  Default C<loccount>, from C<PATH>.

=cut

has bin => 'loccount';

=attr timeout

Seconds for one count.  Default 300.

=cut

has timeout => 300;

=method count

C<($dir)>.  Runs C<loccount -j -c> on C<$dir> and returns what L</parse>
reads from its output.  It dies with the error output of loccount when
loccount fails or does not finish in L</timeout>.  On success loccount can
still complain on its error output about a file that its lexer did not
follow, and those files are still counted, so that output is dropped then.

=cut

sub count ( $self, $dir ) {
    my @cmd = ( $self->bin, qw{-j -c}, $dir );
    my ( $out, $err ) = ( q{}, q{} );
    my $ok = eval { IPC::Run::run( \@cmd, '<', \undef, '>', \$out, '2>', \$err, IPC::Run::timeout( $self->timeout ) ) };
    if ( !$ok ) {
        my $why = $err =~ s{\s+\z}{}r || $@ =~ s{\s+\z}{}r || 'exit ' . ( $? >> 8 );
        die "@cmd: $why\n";
    }
    return parse($out);
}

=func parse

C<($out)>, the output of C<loccount -j -c>.  A hash of:

=over

=item C<languages>

One hash for each language that loccount found, with C<language>, C<sloc>,
C<lloc> and C<filecount>, the most SLOC first, as loccount prints them.  The
total that loccount prints as the language C<all> is not one of them.

=item C<sloc>, C<lloc>

The physical and the logical source lines of the whole directory.  loccount
counts logical lines only of the languages whose statements it can tell
apart, so C<lloc> can be 0 when C<sloc> is not.

=item C<files>

The count of the files that loccount classified.

=item C<cocomo>

The estimates that loccount makes, as C<sloc>, the COCOMO I estimate from the
physical lines, and C<lloc>, the COCOMO II estimate from the logical lines.
Each has C<lines>, C<person_months>, C<schedule_months>, C<developers>,
C<cost> in dollars, and the C<salary> and C<overhead> that the cost assumes.

=back

loccount prints the estimates as text even with C<-j>, so they are read from
that text by their labels.  It dies when the output has no estimate of the
physical or of the logical lines, as when loccount changed what it prints.

=cut

# The label of each line of an estimate, left of its =, and the key of its
# number.  The effort and the schedule are years, then months in parentheses,
# and the last number of a line is the one kept, so they are months.
my %FIELD = (
    'Total Physical Source Lines of Code (SLOC)'                => 'lines',
    'Total Logical Source Lines of Code (LLOC)'                 => 'lines',
    'Development Effort Estimate, Person-Years (Person-Months)' => 'person_months',
    'Schedule Estimate, Years (Months)'                         => 'schedule_months',
    'Estimated Average Number of Developers (Effort/Schedule)'  => 'developers',
    'Total Estimated Cost to Develop'                           => 'cost',
);

sub parse ($out) {
    my ( @languages, %cocomo, $model );
    for my $line ( split m{\n}, $out ) {
        if ( index( $line, '{' ) == 0 ) {
            my $row = Mojo::JSON::decode_json($line);
            push @languages, $row if $row->{language} ne 'all';
            next;
        }
        my ( $label, $value ) = split m{\s*=\s*}, $line, 2;
        next if !defined $value;
        if ( my ($lines) = $label =~ m{\ATotal\ \w+\ Source\ Lines\ of\ Code\ [(]([SL]LOC)[)]\z} ) {
            $model = $cocomo{ lc $lines } = {};
        }
        next if !$model;
        if ( my $key = $FIELD{$label} ) {
            ( $model->{$key} ) = map { 0 + $_ } $value =~ m{([\d.]+)\D*\z};
        }
        elsif ( my @assumed = $line =~ m{average\ salary\ =\ \$(\d+)/year,\ overhead\ =\ ([\d.]+)} ) {
            @{$model}{qw{salary overhead}} = map { 0 + $_ } @assumed;
        }
    }
    die "loccount printed no COCOMO estimate of the physical and the logical lines\n" if !$cocomo{sloc} || !$cocomo{lloc};
    return {
        languages => \@languages,
        sloc      => $cocomo{sloc}{lines},
        lloc      => $cocomo{lloc}{lines},
        files     => List::Util::sum0( map { $_->{filecount} } @languages ),
        cocomo    => \%cocomo,
    };
}

1;

=head1 SYNOPSIS

    use 5.040;
    use App::Clod::Loccount;

    my $count = App::Clod::Loccount->new( timeout => 300 )->count('/path/to/tree');
    say "$_->{language}: $_->{sloc}" for @{ $count->{languages} };
    say "COCOMO II: \$$count->{cocomo}{lloc}{cost}";

=head1 DESCRIPTION

A wrapper of Eric S. Raymond's loccount, L<https://gitlab.com/esr/loccount>,
for use inside a Minion job.  loccount counts the lines of each language in a
directory, and makes COCOMO estimates of the cost to develop it.  Inside a git
work tree it counts only what git tracks.  Its errors read like those of
L<App::Clod::GitHub>: each message ends in a newline, so it can be shown as
it is.

=cut
