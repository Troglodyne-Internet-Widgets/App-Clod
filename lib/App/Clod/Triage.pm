package App::Clod::Triage;

# ABSTRACT: The triage question, and what counts as an answer to it

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';

use JSON::Validator::Schema::Draft7 ();

my @SCOPES = qw{single multi upstream clarify follow_up};

# The name of a repository that the bot may make, without its organization.
our $NAME = q{[A-Za-z0-9][A-Za-z0-9_-]{0,99}};

# The name of a perl module, which names the release issue of a new repository.
our $MODULE = q{[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z0-9_]+)*};

=func schema

C<(\@spokes, %allow)>.  The JSON Schema of an answer, for C<--json-schema>
and for L</validate>.  Under C<single> and C<multi>, each repository must be
one of C<@spokes>, and the count of them must fit the scope.  C<upstream>
needs C<upstream.project> and C<upstream.explanation>, and C<clarify> needs
C<question.text>.  C<follow_up> needs at least one entry of C<follow_ups> and
no entry of C<repos>: the request is settled once the issues are filed.  A
new schema comes back from each call.

C<%allow> says what else the answer may ask the hub to make.  C<orgs> is for
a new repository, in C<new_repos>: the organizations that it may make one in.
One answer may ask for one at most.  Without C<orgs>, C<new_repos> must be
empty, and C<repos> names spokes alone.  With it, an entry of C<repos> or of C<follow_ups> may also name C<Org/name>, for
one of C<orgs> and a name that is L</repo_name>, and L</validate> checks that
it is one of C<new_repos>.  C<follow_ups> is how many follow-up issues the
answer may ask for, default none.

Each entry of C<new_repos> has the C<org>, the C<name>, a C<description> of
one line, the C<module> that the repository will hold if triage knows it, and
C<private> if the person asked for a private repository, which the hub
refuses.  Each entry of C<follow_ups> has the C<repo> to file the issue in, its
C<title> and its C<body>.  Both kinds have C<asked_by> and C<quote>: the login
of the person who asked, and their words, as they wrote them.  The schema
cannot check that those words are theirs: L<App::Clod::Tasks/asked_for> does.

=cut

sub schema ( $spokes, %allow ) {
    my @orgs   = @{ $allow{orgs} // [] };
    my $text   = sub () { return { type => 'string', minLength => 1 } };
    my $scope  = sub ($name) { return { properties => { scope => { const => $name } } } };
    my $asking = sub () { return ( asked_by => $text->(), quote => { type => 'string', minLength => 10 } ) };
    my $repo   = sub () {
        my $spoke = { type => 'string', enum => [@$spokes] };
        return $spoke if !@orgs;
        return { anyOf => [ $spoke, { type => 'string', pattern => '^(?:' . join( q{|}, map { s{[.]}{\\.}gr } @orgs ) . ")/$NAME\$" } ] };
    };
    my $repos = sub (%count) {
        my $entry = { type => 'object', required => [qw{repo order instructions}], properties => { repo => $repo->(), order => { type => 'integer' }, instructions => $text->() } };
        return { properties => { repos => { %count, items => $entry } } };
    };
    my $new_repo = {
        type       => 'object',
        required   => [qw{org name description asked_by quote}],
        properties => {
            org         => { type => 'string', enum      => [@orgs] },
            name        => { type => 'string', pattern   => "^$NAME\$" },
            description => { type => 'string', minLength => 1, maxLength => 350 },
            module      => { type => 'string', pattern   => "^$MODULE\$" },
            private     => { type => 'boolean' },
            $asking->(),
        },
    };
    my $follow_up = {
        type       => 'object',
        required   => [qw{repo title body asked_by quote}],
        properties => { repo => $repo->(), title => { type => 'string', minLength => 1, maxLength => 256 }, body => $text->(), $asking->() },
    };
    return {
        type       => 'object',
        required   => [qw{scope reason repos}],
        properties => {
            scope      => { type => 'string', enum => [@SCOPES] },
            reason     => $text->(),
            repos      => { type => 'array' },
            new_repos  => { type => 'array',  maxItems => @orgs ? 1 : 0,             items      => $new_repo },
            follow_ups => { type => 'array',  maxItems => $allow{follow_ups} // 0,   items      => $follow_up },
            upstream   => { type => 'object', required => [qw{project explanation}], properties => { project => $text->(), path => { type => 'string' }, explanation => $text->() } },
            question   => { type => 'object', required => ['text'],                  properties => { text => $text->(), path => { type => 'string' } } },
        },
        allOf => [
            { if => $scope->('single'),    then => $repos->( minItems => 1, maxItems => 1 ) },
            { if => $scope->('multi'),     then => $repos->( minItems => 2 ) },
            { if => $scope->('upstream'),  then => { required => ['upstream'] } },
            { if => $scope->('clarify'),   then => { required => ['question'] } },
            { if => $scope->('follow_up'), then => { required => ['follow_ups'], properties => { repos => { maxItems => 0 }, follow_ups => { minItems => 1 } } } },
        ],
    };
}

=func repo_name

C<($name)>.  True when the hub may give a new repository that name: a letter
or a digit, then letters, digits, C<-> and C<_>, at most a hundred in all.  So
there is no dot, which leaves out the names C<.> and C<..> and a name that ends
the way a bare clone does.  The schema says the same with C<^> and C<$>, for
claude, but in perl C<$> also matches before a newline at the end, so this is
the check that counts.

=cut

sub repo_name ($name) { return ( $name // q{} ) =~ m{\A$NAME\z} }

=func module_of

C<($entry)>.  The perl module that an entry of C<new_repos> will hold: its
C<module>, else its C<name> with C<::> for each C<->, the way a distribution
name gives a module name.

=cut

sub module_of ($entry) { return $entry->{module} // $entry->{name} =~ s/-/::/gr }

=func validate

C<($answer, \@spokes, %allow)>.  Returns the answer with C<repos> sorted by
C<order>, and C<repos>, C<new_repos> and C<follow_ups> empty for C<upstream>
and C<clarify>.  Each entry of C<new_repos> gets C<repo>, as C<Org/name>, and
C<module>, from L</module_of>.  C<follow_ups> is always there, empty when the
answer asked for none.

Dies with every way in which the answer breaks L</schema>, or with a
repository that it names twice.  It dies too with a new repository that is a
spoke already, that C<repos> does not name, or whose name or description does
not fit, and with an entry of C<repos> or of C<follow_ups> that is neither a
spoke nor a new repository.  The words can go back to the model as they are.

=cut

sub validate ( $answer, $spokes, %allow ) {
    my @errors = JSON::Validator::Schema::Draft7->new( schema( $spokes, %allow ) )->validate($answer);
    die join( "\n", 'The answer does not fit the schema:', map { "  $_" } @errors ) . "\n" if @errors;
    return { %$answer, repos => [], new_repos => [], follow_ups => [] }                    if $answer->{scope} eq 'upstream' || $answer->{scope} eq 'clarify';
    my %seen;
    $seen{ $_->{repo} }++ and die "$_->{repo} is listed twice\n" for @{ $answer->{repos} };

    my %spoke = map { $_ => 1 } @$spokes;
    my ( @new, %new );
    for my $entry ( @{ $answer->{new_repos} // [] } ) {
        my $repo = "$entry->{org}/$entry->{name}";
        die "$repo is a spoke already, so it is not new\n"                           if $spoke{$repo};
        die "$repo is in new_repos twice\n"                                          if $new{$repo}++;
        die "$repo is in new_repos, but not in repos: a new repository needs work\n" if !$seen{$repo};
        die "The name of $repo does not fit the rule for a new repository\n"         if !repo_name( $entry->{name} );
        die "The description of $repo is more than one line\n"                       if index( $entry->{description}, "\n" ) >= 0;
        push @new, { %$entry, repo => $repo, module => module_of($entry) };
    }
    for my $entry ( @{ $answer->{repos} }, @{ $answer->{follow_ups} // [] } ) {
        die "$entry->{repo} is not a spoke, and not in new_repos\n" if !$spoke{ $entry->{repo} } && !$new{ $entry->{repo} };
    }
    return { %$answer, repos => [ sort { $a->{order} <=> $b->{order} } @{ $answer->{repos} } ], new_repos => \@new, follow_ups => [ @{ $answer->{follow_ups} // [] } ] };
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
cannot be planned without a person's answer to C<question.text>, and a fifth,
C<follow_up>, that filing the issues in C<follow_ups> settles it.  L</schema> is
the form of an answer and every rule that it must follow, so that claude gets
the rules as well as the form.  L</validate> checks an answer against it, and
checks the rules that JSON Schema cannot say: that no repository is named
twice, and that each new repository in C<new_repos> is new and has work in
C<repos>.

=cut
