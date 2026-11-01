package App::Clod::Config;

# ABSTRACT: Defaults and validation for the clod.conf hash

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Carp       ();
use List::Util ();

use App::Clod::Budget();

my %DEFAULTS = (
    github_api     => 'https://api.github.com',
    github_web     => 'https://github.com',
    retention_days => 30,
    poll_interval  => 60,
    http_timeout   => 30,
    claude         => {
        bin           => 'claude',
        model         => undef,
        timeout       => 3600,
        allowed_tools => [qw{Read Edit Write Grep Glob Bash(git:*) Bash(prove:*) Bash(perl:*) Bash(dzil:*) Bash(podchecker:*)}],
        read_tools    => [ qw{Read Grep Glob}, 'Bash(git log:*)', 'Bash(git grep:*)', 'Bash(git show:*)', 'Bash(git diff:*)' ],
        extra_tools   => [],
    },
    harness => {
        plugin                  => 'perl-slop',
        plugin_repo             => 'Troglodyne-Internet-Widgets/perl-slop-plugin',
        marketplace             => 'troglodyne-marketplace',
        marketplace_repo        => 'Troglodyne-Internet-Widgets/claude-plugins-marketplace',
        required_workflows      => [],
        require_claude_settings => 0,
    },
    otel           => {},
    system_prompts => {},
    spoke_prompt   => undef,
    tool_spokes    => [],
);

my @REQUIRED = qw{bot workspace auth};

my sub list_of ( $config, $key ) {
    my $value = $config->{$key} // [];
    Carp::croak("$key must be a list") if ref $value ne 'ARRAY';
    return $value;
}

my sub repos_of ( $config, $key ) {
    my $repos = list_of( $config, $key );
    for my $repo (@$repos) {
        my $name = $repo // q{};
        Carp::croak("Each of $key must be Owner/Name, not '$name'") if $name !~ m{\A[\w.-]+/[\w.-]+\z};
    }
    return $repos;
}

my sub is_text ($value) { return defined $value && !ref $value }

=func validate

Takes the raw hash and returns a new one with the defaults filled in.  Dies on
a missing or malformed key.

=cut

sub validate ($raw) {
    Carp::croak('The configuration must be a hash') if ref $raw ne 'HASH';
    my %config = ( %DEFAULTS, %$raw );
    for my $section (qw{claude harness}) {
        $config{$section} = { %{ $DEFAULTS{$section} }, %{ $raw->{$section} // {} } };
    }

    my @missing = grep { !defined $config{$_} } @REQUIRED;
    Carp::croak("The configuration has no value for: @missing") if @missing;

    $config{authorized_users} = list_of( \%config, 'authorized_users' );
    $config{owners}           = list_of( \%config, 'owners' );
    $config{spokes}           = repos_of( \%config, 'spokes' );
    $config{tool_spokes}      = repos_of( \%config, 'tool_spokes' );
    $config{spoke_orgs}       = list_of( \%config, 'spoke_orgs' );
    for my $org ( @{ $config{spoke_orgs} } ) {
        Carp::croak("A spoke organization must be a login, not '$org'") if $org !~ m{\A[\w.-]+\z};
    }
    Carp::croak('The configuration names no spokes and no spoke_orgs') if !@{ $config{spokes} } && !@{ $config{spoke_orgs} };

    my $system = $config{system_prompts};
    Carp::croak('system_prompts must be a hash') if ref $system ne 'HASH';
    my %runs_claude = map { $_ => 1 } @App::Clod::Budget::CLAUDE_TASKS;
    for my $task ( sort keys %$system ) {
        Carp::croak("system_prompts names $task, which does not run claude") if !$runs_claude{$task};
        Carp::croak("system_prompts for $task must be text")                 if !is_text( $system->{$task} );
    }
    Carp::croak('spoke_prompt must be text') if defined $config{spoke_prompt} && !is_text( $config{spoke_prompt} );
    $config{claude}{extra_tools} = list_of( $config{claude}, 'extra_tools' );
    Carp::croak('extra_tools must be a list of text') if List::Util::any { !is_text($_) } @{ $config{claude}{extra_tools} };

    my $auth = $config{auth};
    Carp::croak('auth must be a hash') if ref $auth ne 'HASH';
    Carp::croak('auth needs trusted_header, or user and password_sha256')
      if !$auth->{trusted_header} && !( $auth->{user} && $auth->{password_sha256} );

    $config{minion}    //= "sqlite:$config{workspace}/minion.db";
    $config{bot_email} //= "$config{bot}\@users.noreply.github.com";
    return \%config;
}

=head1 SYNOPSIS

    use 5.040;
    use App::Clod::Config;

    my $config = App::Clod::Config::validate(
        {
            bot       => 'our-bot',
            workspace => '/var/lib/clod',
            spokes    => ['Our-Org/repo-one'],
            auth      => { trusted_header => 'X-Remote-User' },
        }
    );

=head1 DESCRIPTION

F<clod.conf> is a perl hash, read by L<Mojolicious::Plugin::Config>.  This
module fills in the defaults and dies on a configuration that cannot work.
Secrets are never in it: C<GH_TOKEN> and C<CLAUDE_CODE_OAUTH_TOKEN> come from
the environment.

=head1 KEYS

=over

=item bot

The GitHub login of the bot user.  Required.

=item workspace

The directory for the Minion database, the clones and the worktrees.  Required.

=item auth

Either C<< { trusted_header => 'X-Remote-User' } >>, for a proxy that does the
authentication, or C<< { user => ..., password_sha256 => ... } >> for HTTP basic
authentication.  Required.

=item spokes

The repositories that the bot works on, as C<Owner/Name>.  This list or
C<spoke_orgs> must name at least one.

=item spoke_orgs

Organizations whose public repositories are spokes too, except forks and
archived ones.  C<spoke_sweep> lists them every fifteen minutes, so a new
repository becomes a spoke without a restart.  See
L<App::Clod::Tasks/spokes>.

=item authorized_users

The GitHub logins whose assignments, review requests and mentions the bot acts
on.  Everything else is marked read and left alone.

=item owners

The users and organizations whose repositories are ours.  A fix whose best
place is a repository outside this list goes back to a person.

=item minion

The Minion SQLite connection string.  Default F<minion.db> in the workspace.

=item bot_email

The address for the bot's commits.  Default the GitHub no-reply address.

=item poll_interval

The least number of seconds between two inbox reads.  GitHub can ask for more
with C<X-Poll-Interval>, and the bot obeys.  Default 60.

=item http_timeout

Seconds for each GitHub request.  Default 30.

=item retention_days

How long Minion keeps finished jobs.  The budget figures and the history on the
page come from them.  Default 30.

=item claude

C<bin>, C<model>, C<timeout> in seconds, C<allowed_tools> for runs that change
a repository, and C<read_tools> for runs that only read.

C<extra_tools> is a list of Claude Code permission rules, such as
C<Bash(bin/provision:*)>, added to C<allowed_tools> of this installation.  So
the defaults stay, and only the runs that change a repository, C<spoke_fix>
and C<spoke_address>, get the rules.  They never reach C<read_tools>, so
triage, C<spoke_review> and C<reply> stay read-only.  The bot runs unattended,
so a rule here is permission that no person confirms.  Default none.

=item harness

C<plugin>, C<plugin_repo>, C<marketplace>, C<marketplace_repo>,
C<required_workflows> and C<require_claude_settings>.  See
L<App::Clod::Harness>.

=item system_prompts

Text to append to the system prompt of the C<claude> runs of a task, keyed by
the task: C<triage>, C<spoke_fix>, C<spoke_review>, C<spoke_address> or
C<reply>.  Use it for what every run of that task must know about this
installation, such as how to test a change.  Because F<clod.conf> is perl, a
value can be read from a file:

    system_prompts => { triage => Mojo::File->new('/etc/clod/triage.md')->slurp('UTF-8') },

Default none.

=item spoke_prompt

Text to append to the system prompt of every C<spoke_fix>, C<spoke_review>
and C<spoke_address> run, before the C<system_prompts> text of that task, if
it has one.  Use it for what every spoke run must know, such as how to test a
change on this installation.  Triage reads it too: its prompt says that this
is what each spoke run is told, so that the C<instructions> it writes for each
repository agree with it.  Default none.

=item tool_spokes

Repositories, as C<Owner/Name>, whose tools every spoke run can use, such as a
provisioner that builds a guest to test on.  Each C<spoke_fix>,
C<spoke_review> and C<spoke_address> run gets its own worktree of each one,
added to the run with C<--add-dir> and named in its prompt, and removed after
the run.  The worktree is at the branch of the nearest earlier job of the same
change that left one in that repository, else at its default branch.  A run in
a tool spoke gets no second copy of it.  For triage to plan a change to a tool
spoke, it must be a spoke too, in C<spokes> or in C<spoke_orgs>.  See
L<App::Clod::Tasks/in_worktree>.  Default none.

=item otel

Environment variables, such as C<OTEL_EXPORTER_OTLP_ENDPOINT>, for every
C<claude> run.  If it is not empty, C<CLAUDE_CODE_ENABLE_TELEMETRY=1> is set
too.

=back

=cut
