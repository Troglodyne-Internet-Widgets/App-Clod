package App::Clod::Config;

# ABSTRACT: The schema of the clod.conf hash, and its validation

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Clone ();
use JSON::Validator::Schema::Troglodyne();

use App::Clod::Budget();
use App::Clod::Harness();

my $REPO  = { type => 'string', pattern => '\A[\w.-]+/[\w.-]+\z' };
my $LOGIN = { type => 'string', pattern => '\A[\w.-]+\z' };
my $TEXT  = { type => 'string' };

my sub list_of ( $item, %more )       { return { type => 'array',   items                => $item, default => [], %more } }
my sub section ( $properties, %more ) { return { type => 'object',  additionalProperties => 0, default => {}, properties => $properties, %more } }
my sub seconds ($default)             { return { type => 'integer', minimum              => 1, default => $default } }

our %SCHEMA = (
    type                 => 'object',
    required             => [qw{bot workspace auth}],
    additionalProperties => 0,
    properties           => {
        bot       => $LOGIN,
        workspace => { type => 'string', minLength => 1 },
        auth      => section(
            {
                trusted_header  => { type => 'string', minLength => 1 },
                user            => { type => 'string', minLength => 1 },
                password_sha256 => { type => 'string', pattern   => '\A[0-9a-f]{64}\z' },
            },
            anyOf => [ { required => ['trusted_header'] }, { required => [qw{user password_sha256}] } ],
        ),
        spokes           => list_of($REPO),
        spoke_orgs       => list_of($LOGIN),
        tool_spokes      => list_of($REPO),
        authorized_users => list_of($LOGIN),
        owners           => list_of($LOGIN),
        minion           => { type => 'string',  nullable => 1, default => undef },
        bot_email        => { type => 'string',  nullable => 1, default => undef },
        github_api       => { type => 'string',  default  => 'https://api.github.com' },
        github_web       => { type => 'string',  default  => 'https://github.com' },
        retention_days   => { type => 'integer', minimum  => 1, default => 30 },
        poll_interval    => { type => 'integer', minimum  => 0, default => 60 },
        http_timeout     => seconds(30),
        claude           => section(
            {
                bin           => { type => 'string', default  => 'claude' },
                model         => { type => 'string', nullable => 1, default => undef },
                run_as        => { type => 'string', nullable => 1, default => undef, pattern => '\A[a-z_][a-z0-9_-]*\z' },
                timeout       => seconds(3600),
                allowed_tools => list_of( $TEXT, default => [qw{Read Edit Write Grep Glob Bash(git:*) Bash(prove:*) Bash(perl:*) Bash(dzil:*) Bash(podchecker:*) Bash(perlcritic:*) Bash(perltidy:*) Bash(make:*) Bash(nytprofhtml:*) Bash(nytprofmerge:*)}] ),
                read_tools    => list_of( $TEXT, default => [ qw{Read Grep Glob}, 'Bash(git log:*)', 'Bash(git grep:*)', 'Bash(git show:*)', 'Bash(git diff:*)' ] ),
                extra_tools   => list_of($TEXT),
            }
        ),
        harness => section(
            {
                plugin             => { type => 'string', default => 'perl-slop' },
                plugin_repo        => { %$REPO, default => 'Troglodyne-Internet-Widgets/perl-slop-plugin' },
                marketplace        => { type => 'string', default => 'troglodyne-marketplace' },
                marketplace_repo   => { %$REPO, default => 'Troglodyne-Internet-Widgets/claude-plugins-marketplace' },
                required_workflows => list_of($TEXT),
                flavor             => { type => 'string', minLength => 1, default => 'troglodyne-compat' },
                standards          => { type => 'object', nullable  => 1, default => undef },
            }
        ),
        otel           => { type => 'object', additionalProperties => $TEXT, default => {} },
        system_prompts => section( { map { $_ => $TEXT } @App::Clod::Budget::CLAUDE_TASKS } ),
        spoke_prompt   => { type => 'string',  nullable => 1, default => undef },
        follow_up_max  => { type => 'integer', minimum  => 0, default => 3 },
        create_repos   => { type => 'boolean', default  => 0 },
        restart_units  => list_of( { type => 'string', pattern => '\A[\w@.:-]+[.]service\z' } ),
        local_lib      => { type => 'string', nullable => 1, default => undef },
        agent_lib      => { type => 'string', nullable => 1, default => undef },
    },
);

=func validate

Takes the raw hash and returns a new one, checked against C<%SCHEMA>, with the
defaults filled in.  Dies with every error that the schema reports, each at
the JSON pointer of its key, on a missing, unknown or malformed key.  The
caller's hash is not changed, and nothing in the result is shared with the
schema or with another result.

=cut

sub validate ($raw) {
    die "The configuration must be a hash\n" if ref $raw ne 'HASH';
    my $config    = Clone::clone($raw);
    my $validator = JSON::Validator::Schema::Troglodyne->new;
    $validator->coerce( { %{ $validator->coerce }, defaults => 1 } );
    my @errors = $validator->validate( $config, \%SCHEMA );
    die join( "\n", 'The configuration is not valid:', map { "  $_" } @errors ) . "\n"                                     if @errors;
    die "The configuration names no spokes and no spoke_orgs\n"                                                            if !@{ $config->{spokes} } && !@{ $config->{spoke_orgs} };
    die "create_repos needs spoke_orgs, because a repository is made in one of them, so that the sweep keeps it a spoke\n" if $config->{create_repos} && !@{ $config->{spoke_orgs} };

    $config = Clone::clone($config);
    $config->{minion}             //= "sqlite:$config->{workspace}/minion.db";
    $config->{bot_email}          //= "$config->{bot}\@users.noreply.github.com";
    $config->{harness}{standards} //= { git => "$config->{github_web}/$config->{harness}{plugin_repo}.git", path => 'skills/packaging-perl' };
    App::Clod::Harness::default_config( $config->{harness} );
    return $config;
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
module checks it against C<%SCHEMA>, an OpenAPI v3 schema for
L<JSON::Validator::Schema::Troglodyne>, which also holds every default.  It
dies on a configuration that cannot work, and on a key that the schema does
not name, which is how a misspelled key shows.  Secrets are never in it:
C<GH_TOKEN> and C<CLAUDE_CODE_OAUTH_TOKEN> come from the environment, and with
C<run_as> the token of claude comes from that account.

L<App::Clod/startup> validates the hash after the plugin has read it.  So two
things that the plugin does come first.  It merges a file for the mode of the
application, such as F<clod.production.conf>, if there is one.  It also loads
each Mojolicious plugin that a C<plugins> key names, before this module
refuses that key.

=head1 KEYS

=over

=item bot

The GitHub login of the bot user.  Required.

=item workspace

The directory for the Minion database, the clones and the worktrees.  Required.

=item auth

Either C<< { trusted_header => 'X-Remote-User' } >>, for a proxy that does the
authentication, or C<< { user => ..., password_sha256 => ...  } >> for HTTP
basic authentication.  C<password_sha256> is the SHA-256 of the password in
lowercase hex, as C<Digest::SHA::sha256_hex> gives it.  Required.

=item spokes

The repositories that the bot works on, as C<Owner/Name>.  This list or
C<spoke_orgs> must name at least one.  C<spoke_sweep> asks GitHub for the
visibility of each one, and a repository that is not public is not a spoke.
The Overview tab names it.  A repository that GitHub answers 404 for stays a
spoke.

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
with C<X-Poll-Interval>, and the bot obeys.  0 means no wait of its own.
Default 60.

=item http_timeout

Seconds for each GitHub request.  Default 30.

=item retention_days

How long Minion keeps finished jobs.  The budget figures and the history on the
page come from them.  Default 30.

=item claude

C<bin>, C<model>, C<timeout> in seconds, C<allowed_tools> for runs that change
a repository, and C<read_tools> for runs that only read.

The default C<allowed_tools> are the tools of the files and the Perl
programs that a spoke is built and checked with: C<Read>, C<Edit>, C<Write>,
C<Grep> and C<Glob>, and C<git>, C<prove>, C<perl>, C<dzil>, C<podchecker>,
C<perlcritic>, C<perltidy>, C<make>, C<nytprofhtml> and C<nytprofmerge>.  So a
run can criticize and tidy the whole tree, and not only what the hooks of a
commit see, and profile with C<perl -d:NYTProf> and read the profile.  The
default C<read_tools> are C<Read>, C<Grep> and C<Glob>, and C<git log>, C<git
grep>, C<git show> and C<git diff>.

C<run_as> is the account that every C<claude> run runs as, through C<sudo>.
Unset, claude runs as the worker, and can read the token of the bot in the
environment of the worker.  L<App::Clod::Claude/run_as> says what sudo must
allow, and L<App::Clod::Spoke/DESCRIPTION> what the workspace needs.  It is
an account name, so that sudo cannot take it for an option or a UID.  The
account brings its own C<CLAUDE_CODE_OAUTH_TOKEN>, usually through C<bin>, and
the worker then needs none.

C<extra_tools> is a list of Claude Code permission rules, such as
C<Bash(bin/provision:*)>, added to C<allowed_tools> of this installation.  So
the defaults stay, and only the runs that change a repository, C<spoke_fix>
and C<spoke_address>, get the rules.  They never reach C<read_tools>, so
triage, C<spoke_review> and C<reply> stay read-only.  The bot runs unattended,
so a rule here is permission that no person confirms.  Default none.

=item harness

C<plugin>, C<plugin_repo>, C<marketplace>, C<marketplace_repo>,
C<required_workflows>, C<flavor> and C<standards>.  See L<App::Clod::Harness>.

C<flavor> is the flavor of a spoke without a F<.conformance.yml>.  Default
C<troglodyne-compat>.  C<standards> is where that flavor comes from, as the
C<source> key of F<.conformance.yml> gives it: C<{ git, ref, path }> or
C<{ directory, path }>.  Default C<path> F<skills/packaging-perl> of the git
repository of C<plugin_repo> on C<github_web>.  The configuration dies when
the two do not make a valid F<.conformance.yml>.

=item system_prompts

Text to append to the system prompt of the C<claude> runs of a task, keyed by
the task: C<triage>, C<spoke_fix>, C<spoke_review>, C<spoke_address>,
C<sort_review> or C<reply>.  Use it for what every run of that task must know about this
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
a tool spoke gets no second copy of it.  Triage is told which they are, and to
put a change to one first in its plan.  For triage to plan a change to a tool
spoke, it must be a spoke too, in C<spokes> or in C<spoke_orgs>.  See
L<App::Clod::Tasks/in_worktree>.  Default none.

=item follow_up_max

How many follow-up issues one request may have the hub file, counted over
every job for the same issue or pull request.  An authorized user asks for one
in their own words, such as "file a follow-up issue about this", and the hub
files it in a spoke, assigned to that user.  0 turns it off.  Default 3.  It
needs no other switch: it makes no repository, and it writes only to spokes,
where the bot already opens pull requests.  See
L<App::Clod::Tasks/file_issues>.

=item create_repos

Whether triage may ask the hub to make a new repository.  Default false.

The hub makes it in one of the organizations of C<spoke_orgs>, so that the
sweep keeps it a spoke after the job that made it.  So the configuration dies
when this is true and C<spoke_orgs> is empty.  The token of the bot must be
allowed to make repositories there.

One request makes one repository at most, counted over every job for the same
issue or pull request.

Every repository that the hub makes is public, and the hub refuses a request
for a private one.  A bot that serves public and private repositories at once
can carry what is in a private one into a public one: into a prompt, a pull
request or a comment.  So an installation serves public repositories or
private ones, never both, and one that makes repositories serves public ones.
Nothing in the configuration changes that.  See L<App::Clod/CAVEATS>.

The release issue of each new repository is assigned to the person who asked
for the repository.  See L<App::Clod::Tasks/create_repo>.

=item restart_units

The systemd units of the bot, such as C<clod-example.test.service> and
C<clod-worker-example.test.service>, that L<App::Clod::Tasks/self_update>
restarts after it pulls new code.  Default none: then the dashboard says that
a person must restart them.  The service user must be allowed to run
C</usr/bin/systemctl restart $unit> with sudo and no password, for each unit.
The clod recipe of trog-provisioner grants that, and fills this in.

=item local_lib

A local lib, such as F</opt/domains/example.test/perl5>, that the service user
owns and that comes first on the C<PERL5LIB> of the units.  Default none.
With one, L<App::Clod::Deps> keeps every module of the bot there:
L<App::Clod::Tasks/self_update> installs what a new version needs, and the
dashboard can upgrade what has a newer release, with no sudo.  The clod recipe
of trog-provisioner makes it, and fills this in.

=item agent_lib

A local lib, such as F</opt/domains/example.test/agent-perl5>, for the tools
of the agent: Perl::Critic and every policy of the critic profiles of the
standards, Perl::Tidy and Devel::NYTProf.  Default none.  With one, every
claude run gets it first on C<PERL5LIB> and its F<bin> first on C<PATH>, so
perlcritic in a spoke, and in its hooks, finds the policies that the
standards name.  C<clod deps install> fills it, and the dashboard installs
what it lacks and upgrades what has a newer release, with no sudo and no
provision.

The service user owns it, and the account of C<run_as> must be able to read
it and not to change it.  The clod recipe of trog-provisioner makes it so,
and fills this in.

=item otel

Environment variables, such as C<OTEL_EXPORTER_OTLP_ENDPOINT>, for every
C<claude> run.  If it is not empty, C<CLAUDE_CODE_ENABLE_TELEMETRY=1> is set
too.

=back

=cut
