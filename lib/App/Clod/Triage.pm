package App::Clod::Triage;

# ABSTRACT: The triage question, and what counts as an answer to it

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';

use JSON::Validator::Schema::Draft7 ();

my @SCOPES = qw{single multi upstream clarify};

=func schema

C<(\@spokes)>.  The JSON Schema of an answer, for C<--json-schema> and for
L</validate>.  Under C<single> and C<multi>, each repository must be one of
C<@spokes>, and the count of them must fit the scope.  C<upstream> needs
C<upstream.project> and C<upstream.explanation>, and C<clarify> needs
C<question.text>.  A new schema comes back from each call.

=cut

sub schema ($spokes) {
    my $text  = sub () { return { type => 'string', minLength => 1 } };
    my $scope = sub ($name) { return { properties => { scope => { const => $name } } } };
    my $repos = sub (%count) {
        my $entry = { type => 'object', required => [qw{repo order instructions}], properties => { repo => { type => 'string', enum => [@$spokes] }, order => { type => 'integer' }, instructions => $text->() } };
        return { properties => { repos => { %count, items => $entry } } };
    };
    return {
        type       => 'object',
        required   => [qw{scope reason repos}],
        properties => {
            scope    => { type => 'string', enum => [@SCOPES] },
            reason   => $text->(),
            repos    => { type => 'array' },
            upstream => { type => 'object', required => [qw{project explanation}], properties => { project => $text->(), path => { type => 'string' }, explanation => $text->() } },
            question => { type => 'object', required => ['text'], properties => { text => $text->(), path => { type => 'string' } } },
        },
        allOf => [
            { if => $scope->('single'),   then => $repos->( minItems => 1, maxItems => 1 ) },
            { if => $scope->('multi'),    then => $repos->( minItems => 2 ) },
            { if => $scope->('upstream'), then => { required => ['upstream'] } },
            { if => $scope->('clarify'),  then => { required => ['question'] } },
        ],
    };
}

=func validate

C<($answer, \@spokes)>.  Returns the answer with C<repos> sorted by C<order>,
and empty for C<upstream> and C<clarify>.  Dies with every way in which the
answer breaks L</schema>, or with a repository that it names twice, in words
that can go back to the model as they are.

=cut

sub validate ( $answer, $spokes ) {
    my @errors = JSON::Validator::Schema::Draft7->new( schema($spokes) )->validate($answer);
    die join( "\n", 'The answer does not fit the schema:', map { "  $_" } @errors ) . "\n" if @errors;
    return { %$answer, repos => [] }                                                       if $answer->{scope} eq 'upstream' || $answer->{scope} eq 'clarify';
    my %seen;
    $seen{ $_->{repo} }++ and die "$_->{repo} is listed twice\n" for @{ $answer->{repos} };
    return { %$answer, repos => [ sort { $a->{order} <=> $b->{order} } @{ $answer->{repos} } ] };
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
    my $outcome = App::Clod::Claude->new->run( dir => $hub, prompt => $prompt, schema => App::Clod::Triage::schema( \@spokes ) );
    my $answer  = App::Clod::Triage::validate( $outcome->{structured}, \@spokes );

=head1 DESCRIPTION

Triage runs before every fix, review and review answer.  It asks one question:
is this change best made in one repository, in several, or upstream in a
project that we do not own?  A fourth answer, C<clarify>, says that the request
cannot be planned without a person's answer to C<question.text>.  L</schema> is
the form of an answer and every rule that it must follow, so that claude gets
the rules as well as the form.  L</validate> checks an answer against it, and
checks the one rule that JSON Schema cannot say: that no repository is named
twice.

=cut
