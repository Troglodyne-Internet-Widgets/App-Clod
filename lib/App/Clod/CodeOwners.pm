package App::Clod::CodeOwners;

# ABSTRACT: Who owns a path, by the rules of a CODEOWNERS file

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';

our @LOCATIONS = qw{.github/CODEOWNERS CODEOWNERS docs/CODEOWNERS};

=func parse

C<($text)>.  The rules of a CODEOWNERS file, in file order, each with C<pattern>, C<owners> and C<regex>.

=cut

sub parse ($text) {
    my @rules;
    for my $line ( split /\n/, $text // q{} ) {
        $line =~ s/(?:\A|\s)\#.*//;
        my ( $pattern, @owners ) = split q{ }, $line;
        next if !defined $pattern;
        push @rules, { pattern => $pattern, owners => [ map { s/\A@//r } @owners ], regex => pattern_regex($pattern) };
    }
    return \@rules;
}

=func owners

Returns the owners of the path as an array reference, empty if no rule matches.

=cut

# The last rule that matches wins, as GitHub does it.
sub owners ( $rules, $path ) {
    $path =~ s{\A/}{};
    my $owners = [];
    for my $rule (@$rules) {
        $owners = $rule->{owners} if $path =~ $rule->{regex};
    }
    return $owners;
}

=func pattern_regex

The regular expression for one CODEOWNERS pattern.

=cut

# A CODEOWNERS pattern is a gitignore pattern: anchored when it has a slash
# before its end, a directory when it ends in one.
sub pattern_regex ($pattern) {
    my $anchored = $pattern =~ m{\A/} || $pattern =~ m{/.};
    my $dir      = $pattern =~ m{/\z};
    $pattern =~ s{\A/}{};
    $pattern =~ s{/\z}{};

    # A backslash keeps a leading # from starting a comment, and is not part of the name.
    $pattern = substr $pattern, 1 if index( $pattern, '\#' ) == 0;
    my $re = join q{}, map { $_ eq '**' ? '.*' : $_ eq '*' ? '[^/]*' : $_ eq '?' ? '[^/]' : quotemeta $_ } split /(\*\*|[*?])/, $pattern;
    $re = ( $anchored ? '\A' : '(?:\A|/)' ) . $re;
    $re .= $dir ? '/' : '(?:\z|/)';
    return qr{$re};
}

=head1 SYNOPSIS

    use 5.040;
    use App::Clod::CodeOwners;

    my $rules  = App::Clod::CodeOwners::parse("lib/  \@someone \@org/team\n");
    my $owners = App::Clod::CodeOwners::owners( $rules, 'lib/Foo.pm' );    # ['someone', 'org/team']

=head1 DESCRIPTION

Reads the CODEOWNERS syntax that GitHub documents: one pattern and its owners on
each line, C<#> comments, C<\#> at the start of a pattern that starts with
C<#>, gitignore-style patterns, and the last matching rule wins.  Owners lose
their leading C<@>.  A team owner keeps its C<org/> prefix, so a caller can tell
a team from a user.

=cut
