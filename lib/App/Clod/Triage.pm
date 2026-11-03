package App::Clod::Triage;

# ABSTRACT: The triage question, and what counts as an answer to it

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';

my @SCOPES = qw{single multi upstream clarify};
my %SCOPES = map { $_ => 1 } @SCOPES;

our %SCHEMA = (
    type       => 'object',
    required   => [qw{scope reason repos}],
    properties => {
        scope  => { type => 'string', enum => \@SCOPES },
        reason => { type => 'string' },
        repos  => {
            type  => 'array',
            items => {
                type       => 'object',
                required   => [qw{repo order instructions}],
                properties => { repo => { type => 'string' }, order => { type => 'integer' }, instructions => { type => 'string' } },
            },
        },
        upstream => {
            type       => 'object',
            properties => { project => { type => 'string' }, path => { type => 'string' }, explanation => { type => 'string' } },
        },
        question => {
            type       => 'object',
            properties => { text => { type => 'string' }, path => { type => 'string' } },
        },
    },
);

=func validate

C<($answer, \@spokes)>.  Returns the answer with C<repos> sorted by C<order>,
and empty for C<upstream> and C<clarify>.  Dies with a message that can go back
to the model as it is.

=cut

# Returns the answer with repos in order, or dies with what is wrong with it,
# in words that can go back to the model as they are.
sub validate ( $answer, $spokes ) {
    die "The answer is not a JSON object\n" if ref $answer ne 'HASH';
    my $scope = $answer->{scope} // q{};
    die "scope must be one of @SCOPES, not '$scope'\n" if !$SCOPES{$scope};
    die "reason is empty\n"                            if ( $answer->{reason} // q{} ) eq q{};

    if ( $scope eq 'upstream' ) {
        my $up = $answer->{upstream};
        die "scope upstream needs upstream.project and upstream.explanation\n"
          if ref $up ne 'HASH' || !$up->{project} || !$up->{explanation};
        return { %$answer, repos => [] };
    }
    if ( $scope eq 'clarify' ) {
        die "scope clarify needs question.text\n" if ref $answer->{question} ne 'HASH' || ( $answer->{question}{text} // q{} ) eq q{};
        return { %$answer, repos => [] };
    }

    my %spoke = map { $_ => 1 } @$spokes;
    my $repos = $answer->{repos};
    die "repos must be a non-empty list\n" if ref $repos ne 'ARRAY' || !@$repos;
    my %seen;
    for my $entry (@$repos) {
        die "each entry in repos needs repo, order and instructions\n"
          if ref $entry ne 'HASH' || !$entry->{repo} || !defined $entry->{order} || ( $entry->{instructions} // q{} ) eq q{};
        die "$entry->{repo} is not a spoke; the spokes are: @$spokes\n" if !$spoke{ $entry->{repo} };
        die "$entry->{repo} is listed twice\n"                          if $seen{ $entry->{repo} }++;
    }
    die 'scope single names ' . scalar(@$repos) . " repos\n" if $scope eq 'single' && @$repos != 1;
    die "scope multi names one repo\n"                       if $scope eq 'multi'  && @$repos < 2;

    return { %$answer, repos => [ sort { $a->{order} <=> $b->{order} } @$repos ] };
}

=func hub_claude_md

Takes the spokes and a sub that returns a spoke's introduction.

=cut

# The CLAUDE.md of the hub workspace: what each spoke is, from its own CLAUDE.md.
sub hub_claude_md ( $spokes, $intro_of ) {
    my @lines = (
        '# The spokes',
        q{},
        'Each directory added to this session is a checkout of one of these repositories, at its default branch.',
        'Read them; do not change them.',
        q{},
    );
    for my $repo (@$spokes) {
        push @lines, "## $repo", q{}, $intro_of->($repo) // '(no CLAUDE.md)', q{};
    }
    return join "\n", @lines;
}

=func intro

The first paragraph of a CLAUDE.md that is not a heading.

=cut

sub intro ($claude_md) {
    return if !defined $claude_md;
    my @paragraphs = grep { $_ ne q{} && substr( $_, 0, 1 ) ne q{#} } split /\n\s*\n/, $claude_md;
    return $paragraphs[0];
}

=head1 SYNOPSIS

    use 5.040;
    use App::Clod::Claude;
    use App::Clod::Triage;

    my ( $hub, $prompt, @spokes ) = @ARGV;
    my $outcome = App::Clod::Claude->new->run( dir => $hub, prompt => $prompt, schema => \%App::Clod::Triage::SCHEMA );
    my $answer  = App::Clod::Triage::validate( $outcome->{structured}, \@spokes );

=head1 DESCRIPTION

Triage runs before every fix, review and review answer.  It asks one question:
is this change best made in one repository, in several, or upstream in a
project that we do not own?  A fourth answer, C<clarify>, says that the request
cannot be planned without a person's answer to C<question.text>.  The answer
must follow C<%SCHEMA>, and C<validate> checks the things that a schema cannot:
that each repository is a spoke, that none is named twice, and that the count
fits the scope.

=cut
