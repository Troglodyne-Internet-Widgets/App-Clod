package App::Clod::Tasks;

# ABSTRACT: The Minion tasks: inbox, triage, the spokes, and the scans

use 5.040;
no autovivification;
use warnings FATAL => 'all';
use re '/aasx';

use IPC::Run         ();
use List::Util       ();
use Mojo::File       ();
use Mojo::JSON       ();
use POSIX            ();
use Text::ParseWords ();
use Time::HiRes      qw{time};

use App::Clod::Budget();
use App::Clod::Claude();
use App::Clod::CodeOwners();
use App::Clod::Deps();
use App::Clod::GitHub();
use App::Clod::Harness();
use App::Clod::Outage();
use App::Clod::Packages();
use App::Clod::Spoke();
use App::Clod::Triage();

use Dist::Conformance::Check::SystemPackages();

# What each kind of notification asks the bot to do.
our %KIND = (
    assign           => 'fix',
    review_requested => 'review',
    author           => 'address_review',
    mention          => 'reply',
);

our %TASKS = (
    inbox_poll         => \&inbox_poll,
    triage             => \&triage,
    spoke_fix          => \&spoke_fix,
    spoke_review       => \&spoke_review,
    spoke_address      => \&spoke_address,
    sort_review        => \&sort_review,
    reply              => \&reply,
    report             => \&report,
    kickback           => \&kickback,
    harness_scan       => \&harness_scan,
    assigned_sweep     => \&assigned_sweep,
    activity_sweep     => \&activity_sweep,
    spoke_sweep        => \&spoke_sweep,
    refresh_references => \&refresh_references,
    create_repo        => \&create_repo,
    file_issues        => \&file_issues,
    harness_fix        => \&harness_fix,
    self_check         => \&self_check,
    self_update        => \&self_update,
    plugin_update      => \&plugin_update,
    deps_upgrade       => \&deps_upgrade,
    packages_install   => \&packages_install,
);

# Each Minion schedule: its cron line and its task.
our %SCHEDULES = (
    inbox    => [ '* * * * *',    'inbox_poll' ],
    harness  => [ '17 * * * *',   'harness_scan' ],
    assigned => [ '*/15 * * * *', 'assigned_sweep' ],
    activity => [ '*/15 * * * *', 'activity_sweep' ],
    spokes   => [ '*/15 * * * *', 'spoke_sweep' ],
    self     => [ '7,37 * * * *', 'self_check' ],
);
our %SCHEDULED = map { $_->[1] => 1 } values %SCHEDULES;

# The tasks that run claude in a worktree of one spoke.
our %SPOKE_TASKS = map { $_ => 1 } qw{spoke_fix spoke_review spoke_address};

my $HOUR          = 3600;
my $DAY           = 86_400;
my $CLAIM_SECONDS = 30 * $DAY;
my $REPO_SECONDS  = 4 * $HOUR;
my $HISTORY       = 10;

=func register

C<($app, $config)>.  Adds every task in C<%TASKS> to the Minion of the app.

=cut

sub register ( $app, $config ) {
    for my $name ( sort keys %TASKS ) {
        my $code = $TASKS{$name};
        $app->minion->add_task( $name => sub ( $job, @args ) { return perform( $job, $config, $code, @args ) } );
    }
    return;
}

=func perform

C<($job, $config, $code, @args)>.  Runs the task, unless an outage holds it.
If GitHub refuses the token, it starts a GitHub outage, and the job waits
through C<hold> in place of failing.

=cut

sub perform ( $job, $config, $code, @args ) {
    return hold($job) if App::Clod::Outage::holding( $job->minion, $job->task );
    return 1          if eval { $code->( $job, $config, @args ); 1 };
    my $error = $@;
    die $error if !App::Clod::GitHub::is_unauthorized($error);
    App::Clod::Outage::begin( $job, github => $error );
    log_note( $job, 'GitHub refused the token; all work waits' );
    return hold($job);
}

=func hold

C<($job)>.  Keeps the job from doing anything during an outage.  A scheduled
task finishes with the result of the last one and C<held>, because the schedule
starts the next one anyway.  Any other job retries after the outage lock
expires.

=cut

sub hold ($job) {
    my ( $minion, $task ) = ( $job->minion, $job->task );
    return retry_after( $job, $App::Clod::Outage::SECONDS ) if !$SCHEDULED{$task};
    prune_history( $minion, $task );
    return $job->finish( { %{ last_result( $minion, $task ) // {} }, held => 1 } );
}

=func schedule

C<($minion)>.  Creates or updates the Minion schedules of C<inbox_poll>,
C<harness_scan>, C<assigned_sweep>, C<activity_sweep> and C<spoke_sweep>.

=cut

sub schedule ($minion) {
    $minion->schedule( $_ => @{ $SCHEDULES{$_} } ) for sort keys %SCHEDULES;
    return;
}

=func github

C<($config)>.  An L<App::Clod::GitHub> for that configuration.

=cut

sub github ($config) { return App::Clod::GitHub->new( api => $config->{github_api}, timeout => $config->{http_timeout} ) }

=func spoke

C<($config, $repo)>.  An L<App::Clod::Spoke> for that repository.

=cut

sub spoke ( $config, $repo ) {
    return App::Clod::Spoke->new(
        repo         => $repo,
        workspace    => $config->{workspace},
        github_web   => $config->{github_web},
        author_name  => $config->{bot},
        author_email => $config->{bot_email},
    );
}

=func claude

C<($config)>.  An L<App::Clod::Claude> with the configured program, tools and
telemetry.  Its default tools are C<allowed_tools> and then C<extra_tools>.
The runs that change a repository get them, and the rules of
L</change_tools> after them.  A read-only run passes
C<read_tools> as C<tools>, so C<extra_tools> never reaches it.

=cut

sub claude ($config) {
    my $c   = $config->{claude};
    my %env = %{ $config->{otel} };
    $env{CLAUDE_CODE_ENABLE_TELEMETRY} = 1 if %env;
    return App::Clod::Claude->new(
        bin           => $c->{bin},
        model         => $c->{model},
        run_as        => $c->{run_as},
        lib           => $config->{agent_lib},
        own_lib       => $config->{agent_own_lib},
        timeout       => $c->{timeout},
        allowed_tools => [ @{ $c->{allowed_tools} }, @{ $c->{extra_tools} } ],
        env           => \%env,
    );
}

=func prompt

Reads F<share/prompts/$name.md> and fills its C<{{name}}> placeholders.

=cut

sub prompt ( $name, %vars ) {
    my $text = App::Clod::share_dir()->child( 'prompts', "$name.md" )->slurp('UTF-8');
    $text =~ s/\{\{(\w+)\}\}/$vars{$1} \/\/ q{}/ge;
    return $text;
}

=func last_result

C<($minion, $task)>.  The result of the newest finished job of that task, or
undef.

=cut

sub last_result ( $minion, $task ) {
    my $info = $minion->jobs( { tasks => [$task], states => ['finished'] } )->next;
    return $info ? $info->{result} : undef;
}

=func prune_history

Removes all but the last few finished jobs, and the last few failed jobs, of a
scheduled task.

=cut

# The scheduled tasks run all day; only their last results mean anything.
sub prune_history ( $minion, $task, $keep = $HISTORY ) {
    for my $state (qw{finished failed}) {
        my $jobs = $minion->jobs( { tasks => [$task], states => [$state] } );
        next if $jobs->total <= $keep;
        my $seen = 0;
        while ( my $info = $jobs->next ) {
            $minion->job( $info->{id} )->remove if ++$seen > $keep;
        }
    }
    return;
}

=func log_note

Appends to the job's C<log> note and to the application log.

=cut

sub log_note ( $job, $message ) {
    my $log = $job->info->{notes}{log} // [];
    push @$log, { at => time, message => $message };
    $job->note( log => $log );
    $job->app->log->info( sprintf 'job %d (%s): %s', $job->id, $job->task, $message );
    return;
}

=func system_text

C<($config, $task)>.  The text that the claude runs of the task append to
their system prompt: C<spoke_prompt> for a spoke task, and with an
C<agent_own_lib> F<share/prompts/install.md>, which says how to install a
module, then the C<system_prompts> text of the task, a blank line between
them.  Undef when there is none.

=cut

sub system_text ( $config, $task ) {
    my @spoke = $SPOKE_TASKS{$task} ? ( $config->{spoke_prompt}, $config->{agent_own_lib} ? prompt('install') : undef ) : ();
    my @parts = grep { ( $_ // q{} ) ne q{} } @spoke, $config->{system_prompts}{$task};
    return @parts ? join( "\n\n", @parts ) : undef;
}

=func packages_prompt

C<($config, @programs)>.  What a run that changes a spoke is told about a
system package that the host lacks: F<share/prompts/system-packages.md>.
With C<@programs>, from L</declared_programs>, it also names the programs
that the run may run, as F<share/prompts/package-programs.md> says.  Empty
without C<system_packages>, because then the hub installs nothing.

=cut

sub packages_prompt ( $config, @programs ) {
    return q{} if !$config->{system_packages};
    return prompt( 'system-packages', programs => @programs ? prompt( 'package-programs', programs => join q{, }, map { "`$_`" } @programs ) : q{} );
}

=func change_tools

C<($config, @programs)>.  The tools of a run that changes a spoke: the default
tools of L</claude>, and then the rule C<Bash(PROGRAM:*)> for each of
C<@programs>, from L</declared_programs>.

=cut

sub change_tools ( $config, @programs ) {
    return [ @{ claude($config)->allowed_tools }, map { "Bash($_:*)" } @programs ];
}

=func retry_after

C<($job, $delay)>.  Retries the job in C<$delay> seconds, and returns nothing,
which is how L</run_claude> tells its callers that the job will retry.

=cut

sub retry_after ( $job, $delay ) {
    $job->retry( { delay => $delay } );
    return;
}

=func run_claude

C<($job, $config, %run)>.  Runs claude as L<App::Clod::Claude/run> does, with
the L</system_text> of the job's task as C<system>, and writes its progress to
the job notes.  Returns the outcome of L<App::Clod::Claude/run>, a hash
reference.  If the quota is paused or runs out, or Claude refuses the token, it
retries the job and returns undef instead, so the caller returns at once.  A
refused token starts a Claude outage, see L<App::Clod::Outage>.

=cut

sub run_claude ( $job, $config, %run ) {
    my $minion = $job->minion;
    return retry_after( $job, 600 ) if App::Clod::Budget::paused($minion);
    my $events  = 0;
    my $outcome = claude($config)->run(
        system => system_text( $config, $job->task ),
        %run,
        on_event => sub ($event) {
            $job->note( progress => { events => $events, last => $event->{type}, at => time } ) if !( ++$events % 25 );
        },
    );
    $job->note( progress => { events => $outcome->{events}, done => time } );
    if ( $outcome->{unauthorized} ) {
        App::Clod::Outage::begin( $job, claude => $outcome->{result} // $outcome->{stderr} );
        log_note( $job, 'Claude refused the token; Claude work waits' );
        return retry_after( $job, $App::Clod::Outage::SECONDS );
    }
    if ( $outcome->{quota_reset} ) {
        App::Clod::Budget::pause( $minion, $outcome->{quota_reset} );
        if ( !$outcome->{ok} ) {
            log_note( $job, 'the Claude quota ran out; retrying after it resets' );
            return retry_after( $job, List::Util::max( 60, $outcome->{quota_reset} - time + 60 ) );
        }
    }
    return $outcome;
}

=func usage_of

C<(@outcomes)>.  The C<cost>, the last C<rate_limit>, and any C<quota_reset> of
the runs, as a list for a job result.

=cut

sub usage_of (@outcomes) {
    my %usage = ( cost => List::Util::sum0( map { $_->{cost} // 0 } @outcomes ) );
    my ($last) = grep { $_->{rate_limit} } reverse @outcomes;
    $usage{rate_limit} = $last->{rate_limit} if $last;
    my ($reset) = grep { $_ } map { $_->{quota_reset} } @outcomes;
    $usage{quota_reset} = $reset if $reset;
    return %usage;
}

=func origin_of

C<($item)>.  C<Owner/Name#number>.

=cut

sub origin_of ($item) { return "$item->{repo}#$item->{number}" }

=func origin_url

C<($config, $item)>.  The web URL of the issue or pull request.

=cut

sub origin_url ( $config, $item ) {
    return "$config->{github_web}/$item->{repo}/" . ( $item->{is_pr} ? 'pull' : 'issues' ) . "/$item->{number}";
}

=func spokes

C<($minion, $config)>.  The spokes: C<spokes> from the configuration, except
those that the last C<spoke_sweep> dropped because they are not public, the
repositories that the sweep found in C<spoke_orgs>, and the L</made_repos>,
sorted and each once.  Before the first sweep finishes, only the configured
ones and the made ones.

=cut

sub spokes ( $minion, $config ) {
    my $swept   = last_result( $minion, 'spoke_sweep' ) // {};
    my $dropped = $swept->{dropped}                     // {};
    return [ sort( List::Util::uniq( ( grep { !$dropped->{$_} } @{ $config->{spokes} } ), @{ $swept->{repos} // [] }, made_repos( $minion, $swept ) ) ) ];
}

=func made_repos

C<($minion, $swept)>.  The repositories that a C<create_repo> job made, until
the sweep C<$swept> knows them.  A sweep knows a repository when it started
after the repository was made and listed its organization without an error.
From then on that sweep alone says whether it is a spoke, so a repository
that was archived later stops being one.  Until then, a notification about the
new repository, such as a review of its first pull request, is not lost as
"not a spoke".

=cut

sub made_repos ( $minion, $swept ) {
    my $jobs = $minion->jobs( { tasks => ['create_repo'], states => ['finished'] } );
    my @made;
    while ( my $info = $jobs->next ) {
        my $result = $info->{result};
        next if ref $result ne 'HASH' || !$result->{created};
        my ($org) = split m{/}, $result->{repo};
        next if ( $swept->{started_at} // 0 ) > $result->{created_at} && !( $swept->{errors} // {} )->{$org};
        push @made, $result->{repo};
    }
    return @made;
}

=func is_spoke

C<($minion, $config, $repo)>.

=cut

sub is_spoke ( $minion, $config, $repo ) {
    return List::Util::any { $_ eq $repo } @{ spokes( $minion, $config ) };
}

=func authorized

C<($config, $login)>.  True when the login is in C<authorized_users>.

=cut

sub authorized ( $config, $login ) {
    return List::Util::any { $_ eq ( $login // q{} ) } @{ $config->{authorized_users} };
}

=func inbox_poll

Runs every minute from a Minion schedule, and reads GitHub no more often than
C<poll_interval> or C<X-Poll-Interval> allow.  Its result holds the cursor for
the next poll.  A notification is claimed with a Minion lock named after the
thread and its update time, so a second poll does not enqueue it twice.  A
notification on a closed issue or pull request makes no work, because closing
it settled the matter.

While no repository is a spoke, the poll does not read GitHub, and leaves every
notification unread for a later poll.  Its result is then the cursor before it,
with C<no_spokes_since>, the time that it first found no spoke.  If
C<spoke_orgs> names any organization, it also queues a C<spoke_sweep>, unless one
already waits or runs, so the first start does not wait for the sweep of the
next quarter hour.

=cut

sub inbox_poll ( $job, $config ) {
    my $minion = $job->minion;
    my $cursor = last_result( $minion, 'inbox_poll' ) // {};
    prune_history( $minion, q{inbox_poll} );
    my $interval = List::Util::max( $config->{poll_interval}, $cursor->{poll_interval} // 0 );
    if ( $cursor->{polled_at} && time - $cursor->{polled_at} < $interval ) {
        return $job->finish( { %$cursor, skipped => 1 } );
    }

    # A thread that is read before the spokes are known is marked read as "not a spoke", and lost.
    if ( !@{ spokes( $minion, $config ) } ) {
        my $sweeping = $minion->jobs( { tasks => ['spoke_sweep'], states => [qw{inactive active}] } )->total;
        $minion->enqueue('spoke_sweep') if @{ $config->{spoke_orgs} // [] } && !$sweeping;
        return $job->finish( { %$cursor, no_spokes_since => $cursor->{no_spokes_since} // time } );
    }

    my $gh = github($config);
    my ( $threads, $meta ) = $gh->notifications( $cursor->{last_modified} );
    my ( @queued, @ignored );
    for my $thread (@$threads) {
        my $outcome = eval { inbox_thread( $job, $config, $gh, $thread ) } // "failed: $@";
        if   ( $outcome =~ m{\A\d+\z} ) { push @queued,  $outcome }
        else                            { push @ignored, "$thread->{id}: $outcome" }
    }
    return $job->finish(
        {
            polled_at     => time,
            last_modified => $meta->{last_modified} // $cursor->{last_modified},
            poll_interval => $meta->{poll_interval} // $cursor->{poll_interval},
            scopes        => $meta->{scopes}        // $cursor->{scopes},
            threads       => scalar @$threads,
            queued        => \@queued,
            ignored       => \@ignored,
        }
    );
}

=func inbox_thread

C<($job, $config, $gh, $thread)>.  Turns one notification into a job.  Returns
the job id, or the reason it made none.

=cut

# Returns the id of the job that it queued, or why it did not.
sub inbox_thread ( $job, $config, $gh, $thread ) {
    my $minion  = $job->minion;
    my $repo    = $thread->{repository}{full_name};
    my $reason  = $thread->{reason}  // q{};
    my $subject = $thread->{subject} // {};

    if ( !is_spoke( $minion, $config, $repo ) ) {
        $gh->mark_read( $thread->{id} );
        return "$repo is not a spoke";
    }
    my $claim = "thread:$thread->{id}:$thread->{updated_at}";
    return 'already handled' if !$minion->lock( $claim, $CLAIM_SECONDS );

    my $is_pr = ( $subject->{type} // q{} ) eq 'PullRequest' ? 1 : 0;
    my $kind  = $KIND{$reason};
    $kind = 'reply' if $kind && $kind eq 'address_review' && !$is_pr;
    my ($number) = ( $subject->{url} // q{} ) =~ m{/(\d+)\z};
    if ( !$kind || !$number ) {
        $gh->mark_read( $thread->{id} );
        return "nothing to do for reason '$reason'";
    }
    if ( ( $gh->issue( $repo, $number )->{state} // q{} ) eq 'closed' ) {
        $gh->mark_read( $thread->{id} );
        return "$repo#$number is closed";
    }

    my $requester = requester( $config, $gh, $repo, $number, $reason, $subject );
    if ( !authorized( $config, $requester ) ) {
        $gh->mark_read( $thread->{id} );
        return 'requested by ' . ( $requester // 'nobody known' ) . ', who is not authorized';
    }
    if ( $is_pr && ( $kind eq 'fix' || $kind eq 'reply' ) ) {
        my $own = own_pull( $config, $gh->pull( $repo, $number ), $repo );
        $kind = $own ? 'address_review' : $kind eq 'fix' ? 'review' : 'reply';
    }

    my %item = (
        repo        => $repo,
        number      => 0 + $number,
        kind        => $kind,
        is_pr       => $is_pr,
        title       => $subject->{title},
        requester   => $requester,
        thread      => $thread->{id},
        comment_url => $subject->{latest_comment_url},
    );
    my $origin = origin_of( \%item );
    if ( $kind eq 'address_review' && ( my $queued = queued_address( $minion, $origin ) ) ) {
        $gh->mark_read( $thread->{id} );
        return "job $queued will answer $origin";
    }
    if ( $kind eq 'address_review' && !List::Util::any { @$_ } pending( $config, $gh, \%item ) ) {
        $gh->mark_read( $thread->{id} );
        return "nothing on $origin waits for an answer";
    }
    $gh->react( $repo, $number, 'eyes' );
    my $task = $kind eq 'reply' ? 'reply' : $kind eq 'address_review' ? 'sort_review' : 'triage';
    my $id   = $minion->enqueue( $task => [ \%item ], { notes => { origin => $origin, kind => $kind } } );
    $gh->mark_read( $thread->{id} );
    log_note( $job, "queued job $id for $kind on $origin" );
    return $id;
}

=func queued_address

C<($minion, $origin)>.  The id of a job that has yet to read the conversation of
the pull request C<$origin> and answer it: a C<triage> of it for
C<address_review> that waits or runs, or a C<sort_review> or C<spoke_address>
of it that waits.  Undef if there is none.  A C<sort_review> or
C<spoke_address> that runs does not count: it read what was pending when it
started, so it does not answer a later comment.

=cut

sub queued_address ( $minion, $origin ) {
    my $jobs = $minion->jobs( { tasks => [qw{triage sort_review spoke_address}], states => [qw{inactive active}] } );
    while ( my $info = $jobs->next ) {
        next if ( $info->{notes}{origin} // q{} ) ne $origin;
        next if $info->{task} eq 'triage' && ( $info->{notes}{kind} // q{} ) ne 'address_review';
        next if $info->{task} ne 'triage' && $info->{state} ne 'inactive';
        return $info->{id};
    }
    return;
}

=func requester

Who caused the notification: the user who made the assignment or the review
request, or the author of the latest comment.  The events API puts the assignee
in C<actor> of an assignment, so that user is in C<assigner>, and the one who
asked for a review is in C<review_requester>.

If C<latest_comment_url> names no comment, or names the pull request itself, the
author of the latest review or line comment on the pull request caused it.  A
review of an authorized user came with such a notification.

=cut

sub requester ( $config, $gh, $repo, $number, $reason, $subject ) {
    my $bot = $config->{bot};
    if ( $reason eq 'assign' || $reason eq 'review_requested' ) {
        my $wanted  = $reason eq 'assign' ? 'assigned' : 'review_requested';
        my $field   = $reason eq 'assign' ? 'assignee' : 'requested_reviewer';
        my $by      = $reason eq 'assign' ? 'assigner' : 'review_requester';
        my ($event) = grep { ( $_->{event} // q{} ) eq $wanted && ( $_->{$field}{login} // q{} ) eq $bot } reverse @{ $gh->issue_events( $repo, $number ) };
        return $event ? $event->{$by}{login} : undef;
    }
    my $latest = $subject->{latest_comment_url} // q{};
    return $gh->get($latest)->{user}{login} if $latest ne q{} && $latest ne ( $subject->{url} // q{} );
    return if ( $subject->{type} // q{} ) ne 'PullRequest';

    my @said = (
        ( map { { by => $_->{user}{login}, at => $_->{created_at} } } @{ $gh->review_comments( $repo, $number ) } ),
        ( map { { by => $_->{user}{login}, at => $_->{submitted_at} } } @{ $gh->reviews( $repo, $number ) } ),
    );
    my $last = ( sort { ( $a->{at} // q{} ) cmp ( $b->{at} // q{} ) } @said )[-1];
    return $last ? $last->{by} : undef;
}

=func context

C<($config, $gh, $item)>.  The issue or pull request and the last twenty
entries of its L</conversation>, as Markdown for a prompt.

=cut

sub context ( $config, $gh, $item ) {
    my $issue = $gh->issue( $item->@{qw(repo number)} );
    my @said  = @{ conversation( $gh, $item ) };
    @said = @said[ -20 .. -1 ] if @said > 20;
    my @lines = ( "# $issue->{title}", "by $issue->{user}{login}, " . origin_url( $config, $item ), q{}, $issue->{body} // q{}, q{} );
    push @lines, '## ' . ( $_->{review} ? 'review' : 'comment' ) . " by $_->{user}{login}", q{}, $_->{body} // q{}, q{} for @said;
    return join "\n", @lines;
}

=func conversation

C<($gh, $item)>.  The comments on the issue or pull request, oldest first.  On
a pull request, the body of each review that has one is an entry too, with
C<review> set and C<created_at> from its C<submitted_at>.  Line comments are
not entries: they belong to their threads.

=cut

sub conversation ( $gh, $item ) {
    my @said = @{ $gh->issue_comments( $item->@{qw(repo number)} ) };
    if ( $item->{is_pr} ) {
        push @said, map { { id => $_->{id}, user => $_->{user}, body => $_->{body}, created_at => $_->{submitted_at}, review => 1 } }
          grep { ( $_->{body} // q{} ) ne q{} } @{ $gh->reviews( $item->@{qw(repo number)} ) };
    }
    return [ sort { ( $a->{created_at} // q{} ) cmp ( $b->{created_at} // q{} ) || $a->{id} <=> $b->{id} } @said ];
}

=func default_branch

C<($gh, $repo)>.

=cut

sub default_branch ( $gh, $repo ) { return $gh->repo($repo)->{default_branch} }

=func prepare_hub

C<($config, $gh, \@spokes, @fresh)>.  Makes sure that each spoke has a
reference worktree, writes the hub CLAUDE.md, and returns the hub directory and
a hash of repository to reference worktree.  It refreshes the reference of each
spoke of C<@fresh>, the repository of the request, and of a spoke that has no
reference yet.  The others are as L</refresh_references> left them, at most a
sweep old.

Triage reads every spoke to judge which ones a request needs, and does not
change any of them, so a reference a quarter of an hour old is good enough.  A
spoke run fetches its own worktree, so no change starts from it.

=cut

sub prepare_hub ( $config, $gh, $spokes, @fresh ) {
    my %fresh = map { $_ => 1 } grep { defined } @fresh;
    my %ref;
    for my $repo (@$spokes) {
        my $spoke = spoke( $config, $repo );
        $ref{$repo} = $fresh{$repo} || !-d $spoke->reference ? $spoke->refresh_reference( default_branch( $gh, $repo ) ) : $spoke->reference;
    }
    my $hub = Mojo::File->new( $config->{workspace}, 'hub' )->make_path;
    my $md  = App::Clod::Triage::hub_claude_md(
        $spokes,
        sub ($repo) {
            my $file = $ref{$repo}->child('CLAUDE.md');
            return App::Clod::Triage::intro( -e $file ? $file->slurp('UTF-8') : undef );
        }
    );
    $hub->child('CLAUDE.md')->spew( $md, 'UTF-8' );
    return ( $hub, \%ref );
}

=func spoke_briefing

C<($config)>.  The section of the triage prompt that says what every spoke run
is told by C<spoke_prompt>, and which tool spokes it gets a checkout of.  Each
part is there when its setting is, and the section is empty when neither is.

=cut

sub spoke_briefing ($config) {
    my $told  = $config->{spoke_prompt} // q{};
    my @tools = @{ $config->{tool_spokes} };
    my @parts = (
        ( $told ne q{} ? prompt( 'triage-spoke-prompt', spoke_prompt => $told ) : () ),
        ( @tools ? prompt( 'triage-tool-spokes', tool_spokes => join q{, }, @tools ) : () ),
    );
    return join "\n", @parts;
}

=func creation

C<($minion, $config, $item)>.  What L<App::Clod::Triage/schema> is told that
the answer for this item may ask the hub to make.  For a new repository,
C<orgs>, which is C<spoke_orgs>.  It is not there when C<create_repos> is
false, or when the origin made one already, by L</made_for>.  For follow-up
issues, C<follow_ups>, how many this request may still file, which
is C<follow_up_max> less L</filed_for> the origin; it is not there when none
are left.  Empty for a review, which changes nothing.

=cut

sub creation ( $minion, $config, $item ) {
    return if $item->{kind} eq 'review';
    my $origin = origin_of($item);
    my $repo   = $config->{create_repos} && !made_for( $minion, $origin );
    my $issues = $config->{follow_up_max} - filed_for( $minion, $origin );
    return ( ( $repo ? ( orgs => $config->{spoke_orgs} ) : () ), ( $issues > 0 ? ( follow_ups => $issues ) : () ) );
}

=func made_for

C<($minion, $origin, $except)>.  How many repositories the C<create_repo>
jobs for the origin have made, whatever their state now, leaving out the job
C<$except>.  A job counts from the moment that it notes C<created>, so a job
that made its repository and then failed still counts.

=cut

sub made_for ( $minion, $origin, $except = 0 ) {
    my $jobs = $minion->jobs( { tasks => ['create_repo'] } );
    my $made = 0;
    while ( my $info = $jobs->next ) {
        $made++ if $info->{id} != $except && item_origin($info) eq $origin && $info->{notes}{created};
    }
    return $made;
}

=func filed_for

C<($minion, $origin, $except)>.  How many follow-up issues the
C<file_issues> jobs for the origin have filed, whatever their state now,
leaving out the job C<$except>.  Each issue counts from the moment that its
job notes it in C<filed>.

=cut

sub filed_for ( $minion, $origin, $except = 0 ) {
    my $jobs  = $minion->jobs( { tasks => ['file_issues'] } );
    my $filed = 0;
    while ( my $info = $jobs->next ) {
        next if $info->{id} == $except || item_origin($info) ne $origin;
        $filed += keys %{ $info->{notes}{filed} // {} };
    }
    return $filed;
}

=func item_origin

C<($info)>.  The L</origin_of> the C<item> in the arguments of a job, from its
Minion info, or the empty string for a job without one.  The arguments say it
for every job that a change made, whether triage enqueued it or a person did.

=cut

sub item_origin ($info) {
    my $item = ( $info->{args}[0] // {} )->{item};
    return ref $item eq 'HASH' ? origin_of($item) : q{};
}

=func written

C<($gh, $item)>.  What each person wrote on the issue or pull request: its
body, every entry of its L</conversation>, and on a pull request every line
comment of its review threads, each a C<{by, body}>.

=cut

sub written ( $gh, $item ) {
    my $issue = $gh->issue( $item->@{qw(repo number)} );
    my @lines = $item->{is_pr} ? @{ $gh->review_comments( $item->@{qw(repo number)} ) } : ();
    return [ map { { by => $_->{user}{login} // q{}, body => $_->{body} // q{} } } $issue, @{ conversation( $gh, $item ) }, @lines ];
}

=func asked_for

C<($config, \@written, $entry, $what)>.  Dies unless the entry of
C<new_repos> or C<follow_ups>, which C<$what> names in the message, was asked
for by an authorized user: C<asked_by> must be in C<authorized_users>, and
C<quote> must be in something that C<asked_by> wrote, from L</written>, with
every run of white space as one space and none at either end.  So the hub
makes a repository or files an issue only when a person who may ask for one
did, in their own words.  The model cannot make that up from a task that
seems to want one, nor take it from the words of somebody else.

=cut

sub asked_for ( $config, $written, $entry, $what ) {
    my $who = $entry->{asked_by};
    die "$who is not an authorized user, so $what cannot be made on their word\n" if !authorized( $config, $who );
    my $flat  = sub ($text) { return $text =~ s/\s+/ /gr =~ s/\A\ |\ \z//gr };
    my $quote = $flat->( $entry->{quote} );
    return 1 if List::Util::any { $_->{by} eq $who && index( $flat->( $_->{body} ), $quote ) >= 0 } @$written;
    die "The quote that asks for $what is not in anything that $who wrote here; ask for it only when they did\n";
}

=func triage

Refreshes a reference worktree of every spoke, writes the hub CLAUDE.md, and
asks the triage question with read-only tools.  An answer that does not pass
L<App::Clod::Triage/validate> gets one more try, with the error.  A run that
fails, with no answer to judge, fails the job at once with its stderr.  Then it
enqueues the work: C<kickback> for upstream or clarify, one C<spoke_review> for
a review, and otherwise a chain of C<spoke_fix> or C<spoke_address> jobs, each
the parent of the next, and a C<report> after them all.

When L</creation> allows it, the answer may also ask for new repositories, in
C<new_repos>, and for follow-up issues, in C<follow_ups>.  Each one must pass
L</asked_for> as well, or the answer is rejected like one that breaks the
schema.  Then a C<create_repo> job for each new repository comes before the
chain, as the parents of its first job, and one C<file_issues> job files the
follow-up issues after the new repositories are made.  An answer of scope
C<follow_up> has no chain and no C<report>: filing the issues settles it.

=cut

sub triage ( $job, $config, $item ) {
    my $gh     = github($config);
    my $spokes = spokes( $job->minion, $config );
    my ( $hub, $ref ) = prepare_hub( $config, $gh, $spokes, $item->{repo} );
    my %create  = creation( $job->minion, $config, $item );
    my $written = %create ? written( $gh, $item ) : [];
    my %vars    = (
        kind           => $item->{kind},
        origin         => origin_of($item),
        repo           => $item->{repo},
        requester      => $item->{requester},
        owners         => join( q{, }, @{ $config->{owners} } ),
        context        => context( $config, $gh, $item ),
        spoke_briefing => spoke_briefing($config),
        new_repos      => $create{orgs}       ? prompt( 'triage-new-repos',  orgs => join( q{, }, @{ $create{orgs} } ) ) : q{},
        follow_ups     => $create{follow_ups} ? prompt( 'triage-follow-ups', max  => $create{follow_ups} )               : q{},
    );

    my ( @outcomes, $answer, $error );
    for my $attempt ( 1 .. 2 ) {
        my $outcome = run_claude(
            $job, $config,
            dir             => $hub,
            prompt          => prompt( triage => %vars, retry => $attempt > 1 ? "\nYour last answer was rejected: $error\n" : q{} ),
            tools           => $config->{claude}{read_tools},
            permission_mode => 'default',
            add_dirs        => [ map { "$_" } values %$ref ],
            schema          => App::Clod::Triage::claude_schema( $spokes, %create ),
        ) // return;
        push @outcomes, $outcome;
        return $job->fail( { error => "the triage run failed: $outcome->{stderr}", usage_of(@outcomes) } ) if !$outcome->{ok};
        $answer = eval {
            my $valid = App::Clod::Triage::validate( $outcome->{structured}, $spokes, %create );
            asked_for( $config, $written, $_, $_->{repo} )                            for @{ $valid->{new_repos} };
            asked_for( $config, $written, $_, qq{the follow-up issue "$_->{title}"} ) for @{ $valid->{follow_ups} };
            $valid;
        };
        last if $answer;
        $error = $@;
    }
    return $job->fail( { error => "triage gave no usable answer: $error", usage_of(@outcomes) } ) if !$answer;
    $job->note( scope => $answer->{scope}, triage => $answer );
    log_note( $job, "scope $answer->{scope}: $answer->{reason}" );

    my @children = plan_children( $job, $item, $answer );
    $job->note( children => \@children );
    return $job->finish( { triage => $answer, children => \@children, usage_of(@outcomes) } );
}

=func plan_children

C<($job, $item, $answer)>.  Enqueues the jobs that the triage answer calls for,
and returns their ids.

=cut

sub plan_children ( $job, $item, $answer ) {
    my $minion = $job->minion;
    my %notes  = ( origin => origin_of($item), triage_job => $job->id );
    if ( $answer->{scope} eq 'upstream' || $answer->{scope} eq 'clarify' ) {
        return $minion->enqueue( kickback => [ { item => $item, triage => $answer } ], { notes => \%notes } );
    }

    my @repos = @{ $answer->{repos} };
    if ( $item->{kind} eq 'review' ) {
        my ($own)   = grep { $_->{repo} eq $item->{repo} } @repos;
        my @related = map  { $_->{repo} } grep { $_->{repo} ne $item->{repo} } @repos;
        my $args    = { item => $item, repo => $item->{repo}, instructions => $own ? $own->{instructions} : $answer->{reason}, related => \@related };
        return $minion->enqueue( spoke_review => [$args], { notes => { %notes, repo => $item->{repo} } } );
    }

    # Answering a review starts in the pull request's own repository, unless filing settles it.
    if ( $item->{kind} eq 'address_review' && $answer->{scope} ne 'follow_up' ) {
        my ($own) = grep { $_->{repo} eq $item->{repo} } @repos;
        @repos = ( $own // { repo => $item->{repo}, instructions => $answer->{reason} }, grep { $_->{repo} ne $item->{repo} } @repos );
    }

    # Every new repository is made before the first spoke runs.
    my @new  = @{ $answer->{new_repos} // [] };
    my %new  = map { $_->{repo} => 1 } @new;
    my @made = map {
        my %args = ( item => $item, %$_{qw{org name description module private asked_by}} );
        $minion->enqueue( create_repo => [ \%args ], { notes => { %notes, repo => $_->{repo} } } );
    } @new;
    my @issues = @{ $answer->{follow_ups} // [] };
    my @filing = @issues ? $minion->enqueue( file_issues => [ { item => $item, issues => \@issues } ], { notes => \%notes, @made ? ( parents => [@made] ) : () } ) : ();

    my ( @ids, $parent );
    for my $entry (@repos) {
        my $task    = $item->{kind} eq 'address_review' && $entry->{repo} eq $item->{repo} ? 'spoke_address' : 'spoke_fix';
        my @parents = $parent                                                              ? ($parent)       : @made;
        my $id      = $minion->enqueue(
            $task => [ { item => $item, repo => $entry->{repo}, instructions => $entry->{instructions}, $new{ $entry->{repo} } ? ( created => 1 ) : () } ],
            { notes => { %notes, repo => $entry->{repo} }, @parents ? ( parents => \@parents ) : () }
        );
        push @ids, $id;
        $parent = $id;
    }
    push @ids, $minion->enqueue( report => [ { item => $item } ], { parents => [@ids], lax => 1, notes => \%notes } ) if @ids;
    return ( @made, @filing, @ids );
}

=func parent_results

C<($job)>.  The results of the parents of the job, where they are hashes.

=cut

sub parent_results ($job) {
    my $minion = $job->minion;
    return map {
        my $parent = $minion->job($_);
        my $result = $parent ? $parent->info->{result} : undef;
        ref $result eq q{HASH} ? $result : ();
    } @{ $job->info->{parents} // [] };
}

=func ancestor_results

C<($job)>.  The results of the parents of the job, of their parents, and so
on, where they are hashes: the nearest first, each job once.

=cut

sub ancestor_results ($job) {
    my $minion = $job->minion;
    my @queue  = @{ $job->info->{parents} // [] };
    my ( %seen, @results );
    while ( defined( my $id = shift @queue ) ) {
        next if $seen{$id}++;
        my $earlier = $minion->job($id) or next;
        my $info    = $earlier->info;
        push @results, $info->{result} if ref $info->{result} eq q{HASH};
        push @queue,   @{ $info->{parents} // [] };
    }
    return @results;
}

=func tool_branch

C<($job, $gh, $tool)>.  The branch for a worktree of a tool spoke: the branch
of the nearest earlier job of the chain that left one in that repository, so
that a run uses what an earlier spoke of the same change just added, else the
default branch.  A C<spoke_fix> result names a branch only when it pushed one,
and a C<spoke_address> result names the branch of the pull request that it
answers.

=cut

sub tool_branch ( $job, $gh, $tool ) {
    my ($earlier) = grep { ( $_->{repo} // q{} ) eq $tool && $_->{branch} } ancestor_results($job);
    return $earlier ? $earlier->{branch} : default_branch( $gh, $tool );
}

=func tools_note

C<(\@checkouts)>.  The paragraph of a spoke prompt that names where each tool
spoke is checked out, or empty when there is none.

=cut

sub tools_note ($checkouts) {
    return q{} if !@$checkouts;
    return join "\n",
      'These repositories are checked out for their tools, each in a directory added to this session and made for this run alone:',
      ( map { "- $_->{repo} in $_->{dir}, at $_->{branch}" } @$checkouts ),
      'Use their tools, but do not change them: each checkout is removed when this run ends.';
}

=func in_worktree

C<($job, $config, $repo, \%how, $work)>.  Takes the lock of the spoke, makes a
worktree with the options in C<%how>, and a worktree of each tool spoke at its
L</tool_branch>, runs C<< $work->($spoke, $tree, \%tools) >>, and removes every
worktree and the directory of the job under F<work/> whatever happened.  A
worktree that git will not remove is deleted with the rest and pruned from its
bare clone, so that it holds no branch.  C<%tools> has C<add_dirs>, the tool
worktrees for the run, and C<note>, the L</tools_note> for its prompt.  The
spoke's own repository gets no second worktree when it is a tool spoke.  If
another job holds the lock, the job retries later.

A tool worktree is made without the lock of its repository.  The lock keeps two
jobs from working on one repository at once, and a tool worktree is no such
work: it is detached, so it holds no branch, it writes no shared configuration,
and nothing is pushed from it.  The one write that it shares with other jobs is
the fetch into the bare clone, which triage already makes without the lock.
Two fetches at once can meet on the lock file of a ref, and then one of them
fails, with the job.  Taking the lock would hold every spoke run back while any
job works in a tool spoke, for up to four hours.

=cut

sub in_worktree ( $job, $config, $repo, $how, $work ) {
    my $guard = $job->minion->guard( "repo:$repo", $REPO_SECONDS );
    return retry_after( $job, 120 ) if !$guard;
    my $root  = Mojo::File->new( $config->{workspace}, 'work', $job->id );
    my $spoke = spoke( $config, $repo );
    my @made  = ( { spoke => $spoke, dir => $root->child($repo) } );
    my $tree  = $spoke->worktree( $made[0]{dir}, %$how );
    my @out   = eval {
        my $gh = github($config);
        for my $tool ( grep { $_ ne $repo } @{ $config->{tool_spokes} } ) {
            my %checkout = ( repo => $tool, spoke => spoke( $config, $tool ), dir => $root->child($tool), branch => tool_branch( $job, $gh, $tool ) );
            push @made, \%checkout;
            $checkout{spoke}->worktree( $checkout{dir}, detach => $checkout{branch} );
        }
        my @checkouts = @made[ 1 .. $#made ];
        $work->( $spoke, $tree, { add_dirs => [ map { "$_->{dir}" } @checkouts ], note => tools_note( \@checkouts ) } );
    };
    my $err = $@;
    my @stuck;
    for my $made (@made) {
        next if eval { $made->{spoke}->remove_worktree( $made->{dir} ); 1 };
        warn "could not remove $made->{dir}: $@";
        push @stuck, $made->{spoke};
    }
    $root->remove_tree;
    $_->prune_worktrees for @stuck;
    die $err if $err;
    return @out;
}

=func slug

C<($text)>.  A branch-name form of a title: lowercase ASCII letters and digits,
with a dash for each run of anything else, and at most forty characters, so
that the branch reads well in the lists of GitHub.  Empty when the title has no
such letter or digit, or there is no title.

=cut

sub slug ($text) {
    my $slug = lc( $text // q{} ) =~ s/[^[:lower:][:digit:]]+/-/gr;
    $slug =~ s/\A-+|-+\z//g;
    return substr( $slug, 0, 40 ) =~ s/-+\z//r;
}

=func reviewers

C<($config, $who)>.  Whom a pull request that the hub opens is assigned to, so
that it reaches somebody's notifications: C<$who>, the person who asked for
it, if that login is in C<authorized_users>, else every one of them.  The
login of the dashboard need not be one of GitHub.

=cut

sub reviewers ( $config, $who ) {
    return authorized( $config, $who ) ? ($who) : @{ $config->{authorized_users} };
}

=func assign_to

C<($job, $gh, $repo, $number, @logins)>.  Assigns the issue or pull request to
C<@logins>.  A failure goes to the log of the job and does not fail it,
because what it assigns is open by then.

=cut

sub assign_to ( $job, $gh, $repo, $number, @logins ) {
    return                                                                                   if !@logins;
    log_note( $job, "could not assign $repo#$number to @logins: " . ( split m{\n}, $@ )[0] ) if !eval { $gh->assign( $repo, $number, @logins ); 1 };
    return;
}

=func kept_ref

C<($job)>.  The ref in the bare clone that holds the commits of the job while
its push waits for a retry: F<refs/clod/kept/E<lt>idE<gt>>.  A fetch prunes
only F<refs/remotes>, so it keeps them.

=cut

sub kept_ref ($job) { return 'refs/clod/kept/' . $job->id }

=func kept

C<($job, $spoke)>.  The work that an earlier try of the job kept when its push
failed, as L</push_or_keep> noted it.  Undef if there is none, or if its commit
is gone from the bare clone.

=cut

sub kept ( $job, $spoke ) {
    my $kept = $job->info->{notes}{kept} // return;
    return if !eval { $spoke->git( q{-C}, $spoke->mirror->to_string, qw{rev-parse --verify --quiet}, kept_ref($job) . '^{commit}' ); 1 };
    return $kept;
}

=func push_or_keep

C<($job, $spoke, $tree, $branch, \%work)>.  Pushes the worktree HEAD to
C<$branch>.  If the push fails, the commits stay under L</kept_ref>, and the
note C<kept> of the job holds C<%work> and C<sha>, the commit.  Then it dies
with the error of the push, so the job fails, and a retry of it can push the
same work without a second claude run.  C<%work> holds what the job needs
after the push: the C<answer> of the run, C<commits> and C<usage>.  The work
of an answer to a review also has C<onto>, the head of the branch on GitHub
that the work started from.  After a push that works, it drops what an earlier
try kept.

=cut

sub push_or_keep ( $job, $spoke, $tree, $branch, $work ) {
    if ( eval { $spoke->push_branch( $tree, $branch ); 1 } ) {
        if ( $job->info->{notes}{kept} ) {
            $spoke->git( q{-C}, $spoke->mirror->to_string, qw{update-ref -d}, kept_ref($job) );
            $job->note( kept => undef );
        }
        return;
    }
    my $error = $@;
    my $sha   = $spoke->git( q{-C}, "$tree", qw{rev-parse HEAD} );
    $spoke->git( q{-C}, "$tree", 'update-ref', kept_ref($job), $sha );
    $job->note( kept => { %$work, sha => $sha } );
    log_note( $job, "kept $sha for a retry, because the push failed" );
    die $error;
}

=func branch_packages

C<($job, $config, $tree)>.  What the host lacks of the system packages that the
branch in C<$tree> declares, as L</lacks_of> finds it.  The declaration comes
from the worktree, so a change that adds a dependency gets it before the
branch merges.  Undef when C<system_packages> is not configured, and when
the host has every package and archive that the branch declares.  A
declaration that cannot be read or resolved is not a missing package: the job
notes why, and this returns undef.  Otherwise its C<missing> is not empty.

=cut

sub branch_packages ( $job, $config, $tree ) {
    return if !$config->{system_packages};
    my $lacks;
    my $read = eval {
        my $declared = Dist::Conformance::Check::SystemPackages->declared("$tree");
        $lacks = lacks_of( $config, $declared, { App::Clod::Packages::os_release() } );
        1;
    };
    my $why = $read ? ( $lacks // {} )->{error} : $@;
    if ( defined $why ) {
        log_note( $job, 'cannot tell whether the host has the system packages of the branch: ' . ( split m{\n}, $why )[0] );
        return;
    }
    return $lacks && @{ $lacks->{missing} } ? $lacks : undef;
}

=func declared_programs

C<($job, $config, $tree)>.  The programs that a run in C<$tree> may run with
any arguments, once each.  L</fix_run> and L</address_run> read them before
the run, and give the run the rule C<Bash(PROGRAM:*)> for each one, as
L</change_tools> makes it.  A program is the first word of the C<test> of a
system package that the branch declares and that resolves on this host, as
L</resolved> resolves it.  It gets a rule only when all of these hold:

=over

=item *

It is a bare name, as C<$BARE_NAME> matches it: no C</>, and nothing that
Claude Code reads in a rule, or splits C<--allowedTools> at.

=item *

It is not a word of the shell, a key of C<%SHELL_WORDS>.  The shell of the run
runs a builtin or a keyword such as C<eval> or C<source> in place of a file of
that name, and many of them run other commands.

=item *

The dependency names a package for this host, and the host has it installed.

=item *

It is an executable file on the C<PATH> of the run, as
L<App::Clod::Packages/program_file> finds it.

=item *

That file belongs to the package of the same dependency, as
L<App::Clod::Packages/owners> says.  So C<bash -c ...> as the test of
C<ffmpeg> gives no rule for C<bash>.

=back

The rule lets the run do whatever the program can do with any arguments.  The
package is one that the dependency names.  If the host lacked it, a person
confirmed it in the dialog of the dashboard before the hub installed it.  A
package that the host had before was confirmed by nobody, so a dependency
C<bash> with the test C<bash --version> gives C<Bash(bash:*)>.  That is no
more than the default C<allowed_tools> give, because they already let the run
run C<perl> and C<make> with any arguments.  A rule allows a command alone.
Claude Code checks each command of a pipe or a list of commands on its own.

For each program that fails a condition, the job notes which.  None without
C<system_packages>.  A declaration that cannot be read or resolved gives none,
and the job notes why.

=cut

our $BARE_NAME = qr{\A \w [\w.+-]* \z};

# The builtins and the keywords of bash, as its manual lists them, that are bare names.
our %SHELL_WORDS = map { $_ => 1 } qw{
  alias bg bind break builtin caller case cd command compgen complete compopt continue coproc declare dirs disown do done
  echo elif else enable esac eval exec exit export false fc fg fi for function getopts hash help history if in jobs kill
  let local logout mapfile popd printf pushd pwd read readarray readonly return select set shift shopt source suspend
  test then time times trap true type typeset ulimit umask unalias unset until wait while
};

sub declared_programs ( $job, $config, $tree ) {
    return if !$config->{system_packages};
    my $resolved = eval { resolved( $config, Dist::Conformance::Check::SystemPackages->declared("$tree"), { App::Clod::Packages::os_release() } ) };
    if ( !$resolved ) {
        log_note( $job, 'gives the run no rule for the programs of the system packages of the branch, because they cannot be read: ' . ( split m{\n}, $@ )[0] );
        return;
    }
    my $claude = claude($config);
    my @programs;
    for my $need ( grep { defined $_->{test} } @{ $resolved->{needs} } ) {
        my ($program) = Text::ParseWords::shellwords( $need->{test} );
        my $why = eval { program_refusal( $config->{system_packages}{packager}, $claude, $need, $program ) // q{} } // ( split m{\n}, $@ )[0];
        if ( $why eq q{} ) { push @programs, $program }
        else               { log_note( $job, "gives the run no rule for the program of the test of $need->{name}, because $why" ) }
    }
    return List::Util::uniq(@programs);
}

=func program_refusal

C<($packager, $claude, $need, $program)>.  Why C<$program>, the first word of
the C<test> of C<$need>, a need as L</resolved> gives it, gets no rule, as
L</declared_programs> lists the conditions.  Undef when it gets one.  Dies
when the packager cannot say.

=cut

sub program_refusal ( $packager, $claude, $need, $program ) {
    return 'its test names no program'                    if !defined $program;
    return "$program is not the bare name of a program"   if $program !~ $BARE_NAME;
    return "$program is a word of the shell"              if $SHELL_WORDS{$program};
    return "$need->{name} names no package for this host" if !defined $need->{package};
    return "$need->{package} is not installed"            if !App::Clod::Packages::installed( $packager, $need->{package} );
    my $file = App::Clod::Packages::program_file( $claude, $program ) // return "$program is no executable file on the PATH of the run";
    return "$file is not a file of the package $need->{package}" if List::Util::none { $_ eq $need->{package} } App::Clod::Packages::owners( $packager, $file );
    return;
}

=func waits_for_packages

C<($lacks)>, from L</branch_packages>.  The part of the result of a job whose
branch needs packages that the host lacks: C<needs_packages>, and
C<packages>, C<sources> and C<needs>, as L</packages_install> and the
dashboard take them.

=cut

sub waits_for_packages ($lacks) {
    return ( needs_packages => 1, packages => $lacks->{missing}, sources => $lacks->{sources}, needs => $lacks->{needs} );
}

=func packages_note

C<($lacks)>, from L</branch_packages>.  The paragraph for the pull request
that says what the host lacks, and what a person does next.

=cut

sub packages_note ($lacks) {
    my @archives = map { $_->{name} } @{ $lacks->{sources} };
    return join q{ }, 'This pull request is a draft, because the change needs system packages that the host of the bot does not have:', join( q{, }, @{ $lacks->{missing} } ) . q{.},
      ( @archives ? 'An install also adds the apt archives ' . join( q{, }, @archives ) . q{.} : () ),
      'So the tests that call them failed here. A person must read the change to `metamerge.yml`, and then install the packages from the dashboard of the bot. Then the bot finishes the work here, and runs the tests again.';
}

=func spoke_fix

Works on a new branch in a worktree of one spoke.  The spoke commits, and the
job pushes, opens the pull request, and assigns it to the L</reviewers> of the
requester.  If the spoke asks a question instead,
the job gives the origin to a person through C<hand_back>.  A job whose parent
asked a question, or waits for one, does not run the spoke, and waits too.
When C<created> is in its arguments, the hub made the repository for this
change, and the prompt says so.  If an earlier try kept its work because the
push failed, see L</push_or_keep>, the job pushes that work and opens the pull
request without running the spoke again.

If the branch declares system packages that the host lacks, as
L</branch_packages> finds them, the job does not fail.  It opens the pull
request as a draft, which says what is missing, and its result has what
L</waits_for_packages> gives.  The dashboard then offers to install the
packages and to resume the work, as L</packages_install> does with
C<resume>.

A run can commit and still say in C<blocked> that something kept it from
finishing.  Then the job pushes the commits and opens the pull request, and
its body says what the run said, as L</unfinished_note> gives it.  The result
has C<blocked> and C<denied>.  The work that the run did is on the branch,
where a person can read it and finish it.

=cut

sub spoke_fix ( $job, $config, $args ) {
    my $item      = $args->{item};
    my $repo      = $args->{repo};
    my @prior     = parent_results($job);
    my ($waiting) = grep { $_->{question} || $_->{waiting} } @prior;
    return $job->finish( { repo => $repo, waiting => 1, summary => "Waits for the answer to the question from $waiting->{repo}." } ) if $waiting;

    my $gh     = github($config);
    my $base   = default_branch( $gh, $repo );
    my $branch = join q{-}, grep { $_ ne q{} } 'clod/' . $job->id, slug( $item->{title} );
    my $prior  = @prior ? join( "\n", 'Earlier spokes in this change:', map { "- $_->{repo}: " . ( $_->{branch} ? "branch $_->{branch}" : 'no change' ) . ( $_->{pr_url} ? ", $_->{pr_url}" : q{} ) . "\n  " . ( $_->{summary} // q{} ) } @prior ) : q{};

    my $kept = kept( $job, spoke( $config, $repo ) );
    return in_worktree(
        $job, $config, $repo,
        $kept ? { at => $kept->{sha} } : { branch => $branch, base => $base },
        sub ( $spoke, $tree, $tools ) {
            my $work = $kept // fix_run( $job, $config, $gh, $args, $spoke, $tree, $tools, branch => $branch, base => $base, prior => $prior ) // return;
            log_note( $job, "pushes $work->{sha}, which an earlier try kept" ) if $kept;
            push_or_keep( $job, $spoke, $tree, $branch, $work );

            my $answer = $work->{answer};
            my $lacks  = branch_packages( $job, $config, $tree );
            my $body   = join "\n\n", $answer->{summary} // q{}, 'For ' . origin_url( $config, $item ), ( map { "Follows $_->{pr_url}" } grep { $_->{pr_url} } @prior ), unfinished_note($work), ( $lacks ? packages_note($lacks) : () );
            my $pull   = $gh->create_pull( $repo, { title => $answer->{title} || $item->{title}, head => $branch, base => $base, body => $body, ( $lacks ? ( draft => Mojo::JSON::true ) : () ) } );
            log_note( $job, "opened $pull->{html_url}" . ( $lacks ? ' as a draft, because the host lacks ' . join( q{ }, @{ $lacks->{missing} } ) : q{} ) );
            assign_to( $job, $gh, $repo, $pull->{number}, reviewers( $config, $item->{requester} ) );
            return $job->finish( { repo => $repo, branch => $branch, pr => $pull->{number}, pr_url => $pull->{html_url}, summary => $answer->{summary}, commits => $work->{commits}, ( $lacks ? waits_for_packages($lacks) : () ), %{ $work->{refusals} // {} }, %{ $work->{usage} } } );
        }
    );
}

=func fix_run

C<($job, $config, $gh, $args, $spoke, $tree, $tools, %fix)>.  The claude run of
L</spoke_fix>, in C<$tree>, where C<%fix> has C<branch>, C<base> and C<prior>.
If the run asked a question, changed nothing, or failed, it finishes or fails
the job and returns undef.  If it committed, it returns the work for
L</push_or_keep>, with C<refusals>, as L</refusals> gives them.

A run that made no commit and was L</stopped> fails the job, as L</refused>
says.  That is a run that says in C<blocked> what kept it from finishing,
whether or not claude refused calls.  A run that made no commit, and says in
C<blocked> that it finished, finishes as C<no_change>, also when claude
refused some of its calls.  Its result keeps them in C<denied>.

=cut

sub fix_run ( $job, $config, $gh, $args, $spoke, $tree, $tools, %fix ) {
    my ( $item, $repo ) = @$args{qw{item repo}};
    my @programs = declared_programs( $job, $config, $tree );
    my $outcome  = run_claude(
        $job, $config,
        dir      => $tree,
        prompt   => prompt( fix => repo => $repo, branch => $fix{branch}, origin => origin_url( $config, $item ), instructions => $args->{instructions}, created => $args->{created} ? prompt( 'fix-created', repo => $repo ) : q{}, prior => $fix{prior}, packages => packages_prompt( $config, @programs ), tools => $tools->{note}, context => context( $config, $gh, $item ) ),
        tools    => change_tools( $config, @programs ),
        add_dirs => $tools->{add_dirs},
        schema   => {
            type       => 'object',
            required   => [qw{title summary blocked}],
            properties => { title => { type => 'string' }, summary => { type => 'string' }, blocked => { type => 'string' }, question => { type => 'string' }, path => { type => 'string' } },
        },
    ) // return;
    my %usage   = usage_of($outcome);
    my $answer  = $outcome->{structured} // {};
    my $commits = $spoke->commits_since( $tree, "origin/$fix{base}" );
    if ( !$outcome->{ok} && !$commits ) {
        $job->fail( { repo => $repo, error => "the run failed: $outcome->{stderr}", %usage } );
        return;
    }
    if ( !$commits && ( $answer->{question} // q{} ) ne q{} ) {
        my $asked = hand_back(
            $job, $config, $gh, $item, $answer->{path},
            "I need an answer before I can change $repo. I changed nothing.",
            $answer->{question}, ( $answer->{path} ? "This concerns `$answer->{path}` in $repo." : () ), how_to_resume($config),
        );
        $job->finish( { repo => $repo, question => $answer->{question}, summary => $answer->{question}, %$asked, %usage } );
        return;
    }
    if ( !$commits && stopped($outcome) ) {
        $job->fail( { repo => $repo, error => refused($outcome), %{ refusals($outcome) }, summary => $answer->{summary}, %usage } );
        return;
    }
    if ( !$commits ) {
        $job->finish( { repo => $repo, no_change => 1, summary => $answer->{summary}, %{ refusals($outcome) }, %usage } );
        return;
    }
    return { answer => $answer, commits => $commits, usage => \%usage, refusals => refusals($outcome) };
}

our %REVIEW_SCHEMA = (
    type       => 'object',
    required   => [qw{event body comments}],
    properties => {
        event    => { type => 'string', enum => [qw{APPROVE REQUEST_CHANGES COMMENT}] },
        body     => { type => 'string' },
        comments => {
            type  => 'array',
            items => { type => 'object', required => [qw{path line body}], properties => { path => { type => 'string' }, line => { type => 'integer' }, body => { type => 'string' } } },
        },
    },
);

=func spoke_review

Reviews the pull request head with read-only tools and posts one review.

=cut

sub spoke_review ( $job, $config, $args ) {
    my $item    = $args->{item};
    my $repo    = $args->{repo};
    my $gh      = github($config);
    my $pull    = $gh->pull( $repo, $item->{number} );
    my @related = map { spoke( $config, $_ )->reference->to_string } @{ $args->{related} // [] };
    my $related = @{ $args->{related} // [] } ? "Triage says the change also concerns these spokes, checked out at their default branch: @{ $args->{related} }." : q{};

    return in_worktree(
        $job, $config, $repo,
        { pull => $item->{number} },
        sub ( $, $tree, $tools ) {
            my $outcome = run_claude(
                $job, $config,
                dir             => $tree,
                prompt          => prompt( review => origin => origin_url( $config, $item ), base => $pull->{base}{ref}, instructions => $args->{instructions}, related => $related, tools => $tools->{note}, context => context( $config, $gh, $item ) ),
                tools           => $config->{claude}{read_tools},
                permission_mode => 'default',
                add_dirs        => [ @related, @{ $tools->{add_dirs} } ],
                schema          => \%REVIEW_SCHEMA,
            ) // return;
            my %usage  = usage_of($outcome);
            my $answer = $outcome->{structured};
            return $job->fail( { repo => $repo, error => "no review: $outcome->{stderr}", %usage } ) if !$outcome->{ok} || ref $answer ne 'HASH';

            my @comments = map { { path => $_->{path}, line => $_->{line}, side => 'RIGHT', body => $_->{body} } } @{ $answer->{comments} };
            my %review   = ( event => $answer->{event}, body => $answer->{body}, commit_id => $pull->{head}{sha} );

            # A line outside the diff makes GitHub refuse the whole review.
            my $posted = eval { $gh->review( $repo, $item->{number}, { %review, comments => \@comments } ) } // $gh->review(
                $repo,
                $item->{number},
                { %review, body => join( "\n\n", $answer->{body}, map { "`$_->{path}:$_->{line}`: $_->{body}" } @comments ) }
            );
            log_note( $job, "posted a $answer->{event} review" );
            return $job->finish( { repo => $repo, event => $answer->{event}, review_url => $posted->{html_url}, summary => $answer->{body}, %usage } );
        }
    );
}

=func pending_threads

C<($config, \@comments)>.  The review threads whose last message is from an
authorized user, each with C<id>, C<path>, C<line> and C<messages>.

=cut

# The review threads whose last word is not the bot's.
sub pending_threads ( $config, $comments ) {
    my %thread;
    for my $c ( sort { $a->{id} <=> $b->{id} } @$comments ) {
        my $root = $c->{in_reply_to_id} // $c->{id};
        push @{ $thread{$root} }, $c;
    }
    my @pending;
    for my $root ( sort { $a <=> $b } keys %thread ) {
        my @messages = @{ $thread{$root} };
        my $last     = $messages[-1];
        next if $last->{user}{login} eq $config->{bot};
        next if !authorized( $config, $last->{user}{login} );
        push @pending, { id => 0 + $root, path => $messages[0]{path}, line => $messages[0]{line} // $messages[0]{original_line}, messages => [ map { { by => $_->{user}{login}, body => $_->{body} } } @messages ] };
    }
    return \@pending;
}

=func pending_comments

C<($config, \@conversation)>.  The entries of a L</conversation> since the last
one of the bot, from authorized users, each with C<id>, C<by> and C<body>, and
C<review> for the body of a review.

=cut

sub pending_comments ( $config, $conversation ) {
    my @after;
    for my $c (@$conversation) {
        my $by = $c->{user}{login} // q{};
        if ( $by eq $config->{bot} ) { @after = (); next }
        push @after, { id => 0 + $c->{id}, by => $by, body => $c->{body} // q{}, $c->{review} ? ( review => 1 ) : () } if authorized( $config, $by );
    }
    return \@after;
}

=func own_pull

C<($config, $pull, $repo)>.  True if the pull request C<$pull> is the bot's
own, from a branch of C<$repo>, so that the bot can push to it.

=cut

sub own_pull ( $config, $pull, $repo ) {
    return ( $pull->{user}{login} // q{} ) eq $config->{bot} && ( $pull->{head}{repo}{full_name} // q{} ) eq $repo;
}

=func pending

C<($config, $gh, $item)>.  What waits for an answer on the pull request
C<$item>: the L</pending_threads> and the L</pending_comments>, as two array
references.

=cut

sub pending ( $config, $gh, $item ) {
    return ( pending_threads( $config, $gh->review_comments( $item->@{qw(repo number)} ) ), pending_comments( $config, conversation( $gh, $item ) ) );
}

=func sort_review

C<($job, $config, $item)>.  Sorts what waits for an answer on the bot's own
pull request, the L</pending> threads and comments, into questions and
requests for a change.  One claude run reads a detached worktree of the branch
with C<read_tools>, so it cannot change it.  It gives each thread, and the
comments as one, a verdict:

=over 4

=item answer

The job posts the answer: in the thread, or as one comment for the comments.
The bot then has the last word there, so the thread is no longer pending.

=item change

A change in the pull request.  The job enqueues a C<spoke_address>, with the
C<instructions> of the run, which answers what is still pending.

=item elsewhere

A change that another spoke needs as well.  The job enqueues a C<triage> for
C<address_review>, which can plan work across spokes.

=back

A thread or the comments with no verdict, or an answer with no body, is a
change.  If some verdict is C<elsewhere>, the triage takes all that is left.
Its result has C<answered>, the ids of the threads it answered, C<comment_url>
when it answered the comments, and C<next>, the task and id of the job after
it, if there is one.

=cut

my %VERDICT = ( type => 'string', enum => [qw{answer change elsewhere}] );
my %SORTED  = (
    type       => 'object',
    required   => [qw{summary threads comments}],
    properties => {
        summary => { type => 'string' },
        threads => {
            type  => 'array',
            items => { type => 'object', required => [qw{id verdict}], properties => { id => { type => 'integer' }, verdict => \%VERDICT, body => { type => 'string' } } },
        },
        comments     => { type => 'object', required => ['verdict'], properties => { verdict => \%VERDICT, body => { type => 'string' } } },
        instructions => { type => 'string' },
    },
);

sub sort_review ( $job, $config, $item ) {
    my $repo = $item->{repo};
    my $gh   = github($config);
    my $pull = $gh->pull( $repo, $item->{number} );
    return $job->fail( { error => 'the pull request is not the bot\'s own, from this repository' } ) if !own_pull( $config, $pull, $repo );

    my ( $threads, $comments ) = pending( $config, $gh, $item );
    return $job->finish( { nothing => 1 } ) if !@$threads && !@$comments;

    my $branch = $pull->{head}{ref};
    return in_worktree(
        $job, $config, $repo,
        { detach => $branch },
        sub ( $spoke, $tree, $tools ) {
            my $outcome = run_claude(
                $job, $config,
                dir    => $tree,
                prompt => prompt(
                    sort    => repo => $repo,
                    branch  => $branch,
                    origin  => origin_url( $config, $item ),
                    tools   => $tools->{note},
                    history => context( $config, $gh, $item ),
                    context => Mojo::JSON::encode_json( { threads => $threads, comments => $comments } ),
                ),
                tools           => $config->{claude}{read_tools},
                permission_mode => 'default',
                add_dirs        => $tools->{add_dirs},
                schema          => \%SORTED,
            ) // return;
            my %usage  = usage_of($outcome);
            my $answer = $outcome->{structured};
            return $job->fail( { error => "no answer: $outcome->{stderr}", %usage } ) if ref $answer ne 'HASH';

            my %verdict = map { $_->{id} => $_ } grep { ref $_ eq 'HASH' } @{ $answer->{threads} // [] };
            my ( @answered, @left );
            for my $thread (@$threads) {
                my $said = $verdict{ $thread->{id} } // {};
                if ( answers($said) ) {
                    $gh->reply_review_comment( $repo, $item->{number}, $thread->{id}, $said->{body} );
                    push @answered, $thread->{id};
                }
                else { push @left, $said->{verdict} // 'change' }
            }
            my $said = ref $answer->{comments} eq 'HASH' ? $answer->{comments} : {};
            my $comment_url;
            if    ( @$comments && answers($said) ) { $comment_url = $gh->comment( $repo, $item->{number}, $said->{body} )->{html_url} }
            elsif (@$comments)                     { push @left, $said->{verdict} // 'change' }

            my %result = ( answered => \@answered, ( $comment_url ? ( comment_url => $comment_url ) : () ), summary => $answer->{summary}, %usage );
            return $job->finish( \%result ) if !@left;

            my %notes = ( origin => origin_of($item), sort_job => $job->id );
            my $task  = ( List::Util::any { $_ eq 'elsewhere' } @left ) ? 'triage' : 'spoke_address';
            my $args  = $task eq 'triage'                               ? $item    : { item => $item, repo => $repo, instructions => $answer->{instructions} // q{} };
            my $id    = $job->minion->enqueue( $task => [$args], { notes => { %notes, $task eq 'triage' ? ( kind => 'address_review' ) : ( repo => $repo ) } } );
            log_note( $job, "queued $task job $id for what is not answered on " . origin_of($item) );
            return $job->finish( { %result, next => { task => $task, id => $id } } );
        }
    );
}

# True if a verdict of sort_review answers, with something to post.
sub answers ($said) {
    return ( $said->{verdict} // q{} ) eq 'answer' && ( $said->{body} // q{} ) ne q{};
}

=func spoke_address

Answers what authorized users said on the bot's own pull request since the bot
last answered: the review threads whose last message is theirs, and the plain
comments and review bodies after the last comment of the bot.  It pushes the
fixes, replies in each thread, and answers the plain comments in one comment.
The prompt also holds the whole conversation of the pull request, and the base
branch of the pull request, which a rebase that names no branch goes onto.  The
push is forced with a lease, so a rebase reaches the pull request.

If an earlier try kept its work because the push failed, see
L</push_or_keep>, the job pushes that work and replies without running the
spoke again.  It does so only if the head of the pull request is still the one
that the work started from.  If someone pushed to the branch since, a forced
push of the kept work would undo their commits, so the job drops it and runs
the spoke again.

If the branch declares system packages that the host lacks, as
L</branch_packages> finds them, the job makes the pull request a draft, says
in its comment what is missing, and its result has what
L</waits_for_packages> gives, as L</spoke_fix> does.  It does so also when
the run made no commit because claude refused some of its calls, as
L</address_run> says.  Then the job posts no reply and no comment of the run,
because they can say that a change was made.  Its comment says only what the
host lacks, and its result has C<denied>, the refused calls.

A run that made no commit, and says in C<blocked> that it finished, goes on as
if claude had refused nothing: the replies, the draft state, and the comment.
Its result keeps the refused calls in C<denied>.  A run that made no commit
and says in C<blocked> what kept it from finishing fails the job, as
L</address_run> says, also when claude refused nothing.  A run that committed
and says in C<blocked> that something kept it from finishing pushes its
commits, and the comment of the job says what the run said, as
L</unfinished_note> gives it.

With C<resume> in its arguments, L</packages_install> queued the job after it
installed those packages.  Then the job runs even when nothing waits for an
answer, posts the C<summary> of the run as its comment when there is no
comment to answer, and makes the pull request ready for review when the host
lacks nothing more.

=cut

sub spoke_address ( $job, $config, $args ) {
    my $item = $args->{item};
    my $repo = $args->{repo};
    my $gh   = github($config);
    my $pull = $gh->pull( $repo, $item->{number} );
    return $job->fail( { repo => $repo, error => 'the pull request is not the bot\'s own, from this repository' } )
      if !own_pull( $config, $pull, $repo );

    my ( $pending, $comments ) = pending( $config, $gh, $item );
    return $job->finish( { repo => $repo, nothing => 1 } ) if !@$pending && !@$comments && !$args->{resume};

    my $branch = $pull->{head}{ref};
    my $spoke  = spoke( $config, $repo );
    my $kept   = kept( $job, $spoke );
    if ( $kept && ( $kept->{onto} // q{} ) ne ( $pull->{head}{sha} // q{} ) ) {
        log_note( $job, "drops the work that an earlier try kept, because $branch moved since" );
        $spoke->git( q{-C}, $spoke->mirror->to_string, qw{update-ref -d}, kept_ref($job) );
        $job->note( kept => undef );
        undef $kept;
    }
    return in_worktree(
        $job, $config, $repo,
        $kept ? { at => $kept->{sha} } : { existing => $branch },
        sub ( $spoke, $tree, $tools ) {
            my $work = $kept // address_run( $job, $config, $gh, $args, $spoke, $tree, $tools, pull => $pull, pending => $pending, comments => $comments ) // return;
            log_note( $job, "pushes $work->{sha}, which an earlier try kept" ) if $kept;
            push_or_keep( $job, $spoke, $tree, $branch, $work )                if $work->{commits};

            my $answer = $work->{answer};
            my %open   = map { $_->{id} => 1 } @$pending;
            my @replied;
            my $held = $work->{lacks};
            for my $reply ( $held ? () : grep { $open{ $_->{id} } } @{ $answer->{replies} } ) {
                $gh->reply_review_comment( $repo, $item->{number}, $reply->@{qw(id body)} );
                push @replied, $reply->{id};
            }
            my $lacks = $held // branch_packages( $job, $config, $tree );
            draft_state( $job, $gh, $pull, $lacks ? 1 : 0 ) if $lacks || $args->{resume};
            my $said     = $held ? undef : @$comments ? $answer->{comment} : $args->{resume} ? $answer->{summary} : undef;
            my @said     = grep { ( $_ // q{} ) ne q{} } $said, $held ? undef : unfinished_note($work), $lacks ? packages_note($lacks) : undef;
            my $answered = @said ? $gh->comment( $repo, $item->{number}, join "\n\n", @said )->{html_url} : undef;
            return $job->finish( { repo => $repo, branch => $branch, pr => $item->{number}, pr_url => $pull->{html_url}, commits => $work->{commits}, replied => \@replied, ( $answered ? ( comment_url => $answered ) : () ), summary => $answer->{summary}, ( $lacks ? waits_for_packages($lacks) : () ), %{ $work->{refusals} // {} }, %{ $work->{usage} } } );
        }
    );
}

=func draft_state

C<($job, $gh, $pull, $draft)>.  Makes the pull request C<$pull> a draft when
C<$draft> is true, and ready for review when it is false, if it is not that
already.  A failure goes to the log of the job and does not fail it, because
the work is pushed by then, and the comment of the job says what is missing.

=cut

sub draft_state ( $job, $gh, $pull, $draft ) {
    return if ( $pull->{draft} ? 1 : 0 ) == ( $draft ? 1 : 0 );
    my $done = eval {
        if   ($draft) { $gh->mark_draft( $pull->{node_id} ) }
        else          { $gh->mark_ready( $pull->{node_id} ) }
        1;
    };
    return log_note( $job, $draft ? 'made the pull request a draft' : 'made the pull request ready for review' ) if $done;
    return log_note( $job, 'could not change whether the pull request is a draft: ' . ( split m{\n}, $@ )[0] );
}

=func address_run

C<($job, $config, $gh, $args, $spoke, $tree, $tools, %address)>.  The claude
run of L</spoke_address>, in C<$tree>, where C<%address> has C<pull>,
C<pending> and C<comments>.  If the run failed, it fails the job and returns
undef.  Otherwise it returns the work for L</push_or_keep>, with C<onto>, the
head of the pull request that the run started from.

The work has C<refusals>, as L</refusals> gives them.  A run can commit
nothing while claude refused some of its calls.  Then it asks
L</branch_packages> what the host lacks.  A missing package can be the cause,
because a program that the host does not have gets no rule.  If the host
lacks a package, the work also has C<lacks>, as L</branch_packages> gives it,
and the job notes it and the refused calls.  Otherwise, a run that made no
commit and was L</stopped> fails the job, as L</refused> says, and this
returns undef.  That is a run that says in C<blocked> what kept it from
finishing, whether or not claude refused calls.  If the run says that it
finished, the work goes on as if claude had refused nothing.

=cut

sub address_run ( $job, $config, $gh, $args, $spoke, $tree, $tools, %address ) {
    my ( $item, $repo ) = @$args{qw{item repo}};
    my $pull     = $address{pull};
    my $branch   = $pull->{head}{ref};
    my @programs = declared_programs( $job, $config, $tree );
    my $outcome  = run_claude(
        $job, $config,
        dir    => $tree,
        prompt => prompt(
            address      => repo => $repo,
            branch       => $branch,
            base         => $pull->{base}{ref},
            origin       => origin_url( $config, $item ),
            instructions => $args->{instructions},
            packages     => packages_prompt( $config, @programs ),
            tools        => $tools->{note},
            history      => context( $config, $gh, $item ),
            context      => Mojo::JSON::encode_json( { threads => $address{pending}, comments => $address{comments} } ),
        ),
        tools    => change_tools( $config, @programs ),
        add_dirs => $tools->{add_dirs},
        schema   => {
            type       => 'object',
            required   => [qw{summary blocked replies}],
            properties => {
                summary => { type => 'string' },
                blocked => { type => 'string' },
                replies => { type => 'array', items => { type => 'object', required => [qw{id body}], properties => { id => { type => 'integer' }, body => { type => 'string' } } } },
                comment => { type => 'string' },
            },
        },
    ) // return;
    my %usage  = usage_of($outcome);
    my $answer = $outcome->{structured};
    if ( ref $answer ne 'HASH' ) {
        $job->fail( { repo => $repo, error => "the run failed: $outcome->{stderr}", %usage } );
        return;
    }
    my $commits = $spoke->commits_since( $tree, "origin/$branch" );

    my %work = ( answer => $answer, commits => $commits, usage => \%usage, onto => $pull->{head}{sha}, refusals => refusals($outcome) );

    # Before the replies, which can say that a change was made.
    if ( !$commits && @{ $outcome->{denied} // [] } ) {
        if ( my $lacks = branch_packages( $job, $config, $tree ) ) {
            log_note( $job, 'waits for ' . join( q{ }, @{ $lacks->{missing} } ) . ", which the branch declares and the host lacks.\n" . refused($outcome) );
            return { %work, lacks => $lacks };
        }
    }
    if ( !$commits && stopped($outcome) ) {
        $job->fail( { repo => $repo, error => refused($outcome), %{ refusals($outcome) }, summary => $answer->{summary}, %usage } );
        return;
    }
    return \%work;
}

=func blocked

C<($outcome)>.  What the answer of a fix run or of an answer to a review says
in C<blocked>: what kept the run from finishing, such as a refused call, and
what it kept the run from doing.  An empty string when C<blocked> is empty, which
means that the run finished its work, also when claude refused some of its
calls.  Undef when the answer has no C<blocked>, because claude did not keep
to the schema.

=cut

sub blocked ($outcome) {
    my $answer = $outcome->{structured};
    my $said   = ref $answer eq 'HASH' ? $answer->{blocked} : undef;
    return if !defined $said;
    return $said =~ m{\S} ? $said : q{};
}

=func stopped

C<($outcome)>.  True when the run says in C<blocked> that something kept it
from finishing, such as a refused call or a fetch that failed.  This does not
depend on whether claude refused calls.  A run can be refused one call and get
the same thing with other calls.  Then it leaves C<blocked> empty, and this is
false.

An answer that has no C<blocked> at all counts as stopped when claude refused
a call, and as not stopped when claude refused nothing.  Before C<blocked>
existed, each refused call stopped a run that made no commit, and this keeps
that for a claude that does not keep to the schema.

=cut

sub stopped ($outcome) {
    my $why = blocked($outcome);
    return $why ne q{} if defined $why;
    return @{ $outcome->{denied} // [] } ? 1 : 0;
}

=func refusals

C<($outcome)>.  The part of the result of a job that says what claude refused,
as a hash reference: C<denied>, the refused calls, when there are any, and
C<blocked>, what the run says kept it from finishing, when it says
something.  A job that finished keeps them too, so that a person can see them.

=cut

sub refusals ($outcome) {
    my $why = blocked($outcome) // q{};
    return { ( @{ $outcome->{denied} // [] } ? ( denied => $outcome->{denied} ) : () ), ( $why ne q{} ? ( blocked => $why ) : () ) };
}

=func refused

C<($outcome)>.  The error of a run that made no commit and was L</stopped>.
It names each refused call, when claude refused some, and what the run says
in C<blocked>, when it says something.  A run that made no commit and was not
stopped changed nothing on purpose, and is not an error.

=cut

sub refused ($outcome) {
    my $why    = blocked($outcome) // q{};
    my @denied = @{ $outcome->{denied} // [] };
    my @calls  = @denied ? ( ', and claude refused these calls, which nobody can approve in -p:', map { "\n  $_" } @denied ) : ();
    return join q{}, 'the run made no commit', @calls, ( $why ne q{} ? "\nThe run says: $why" : () );
}

=func unfinished_note

C<(\%work)>.  The paragraph for the pull request when the run committed, but
says in C<blocked> that something kept it from finishing.  It says what the
run said, and names the refused calls, when there are some.  An empty list when the run says
that nothing kept it from finishing.

=cut

sub unfinished_note ($work) {
    my $refusals = $work->{refusals}    // {};
    my $why      = $refusals->{blocked} // return;
    my @denied   = map { "`$_`" } @{ $refusals->{denied} // [] };
    return join q{ }, "The run did not finish this change. It says: $why", ( @denied ? 'Claude refused these calls of the run: ' . join( q{, }, @denied ) . q{.} : () ),
      'A person must finish the change, or ask the bot here to finish it.';
}

=func reply

Answers a mention on an issue, or on a pull request that is not the bot's own.
If the person asked for a change, it also enqueues triage for a fix.  The bot
cannot push to the branch of that pull request, so the fix is a pull request of
its own.  A mention on the bot's own pull request goes to L</sort_review>.

=cut

sub reply ( $job, $config, $item ) {
    my $gh = github($config);
    my ( $hub, $ref ) = prepare_hub( $config, $gh, spokes( $job->minion, $config ), $item->{repo} );
    my $outcome = run_claude(
        $job, $config,
        dir             => $hub,
        prompt          => prompt( reply => requester => $item->{requester}, origin => origin_url( $config, $item ), context => context( $config, $gh, $item ) ),
        tools           => $config->{claude}{read_tools},
        permission_mode => 'default',
        add_dirs        => [ map { "$_" } values %$ref ],
        schema          => { type => 'object', required => [qw{action body}], properties => { action => { type => 'string', enum => [qw{reply fix}] }, body => { type => 'string' } } },
    ) // return;
    my %usage  = usage_of($outcome);
    my $answer = $outcome->{structured};
    return $job->fail( { error => "no answer: $outcome->{stderr}", %usage } ) if ref $answer ne 'HASH';

    $gh->comment( $item->@{qw(repo number)}, $answer->{body} );
    my %result = ( action => $answer->{action}, summary => $answer->{body}, %usage );
    if ( $answer->{action} eq 'fix' ) {
        my %next = ( %$item, kind => 'fix' );
        $result{triage_job} = $job->minion->enqueue( triage => [ \%next ], { notes => { origin => origin_of( \%next ), kind => $next{kind} } } );
    }
    return $job->finish( \%result );
}

=func report

Comments on the origin with every pull request of the change, and links the
pull requests to each other.  It runs even if a spoke failed.  If a spoke asked
a question and none opened a pull request, the question is the last word, and
it posts nothing.  An answer on the bot's own pull request that touched no
other spoke posts nothing either, because that pull request is the origin and
the answer is already on it.

=cut

sub report ( $job, $config, $args ) {
    my $item    = $args->{item};
    my $gh      = github($config);
    my @results = parent_results($job);
    my @done    = grep { $_->{pr_url} } @results;
    my $asked   = grep { $_->{question} || $_->{waiting} } @results;
    my $total   = scalar @{ $job->info->{parents} // [] };
    return $job->finish( { prs => [], of => $total, waiting => 1 } ) if $asked && !@done;
    my @elsewhere = grep { $_->{repo} ne $item->{repo} || ( $_->{pr} // 0 ) != $item->{number} } @done;
    return $job->finish( { prs => [ map { $_->{pr_url} } @done ], of => $total, quiet => 1 } ) if $item->{kind} eq 'address_review' && !@elsewhere;

    my @lines = map { "- $_->{repo}: $_->{pr_url}" } @done;
    my $rest  = $asked         ? 'the rest wait for the answer to the question above'                                     : 'see the jobs for the rest';
    my $note  = @done < $total ? sprintf( "\n\n%d of %d spokes opened a pull request; %s.", scalar @done, $total, $rest ) : q{};
    $gh->comment( $item->@{qw(repo number)}, @lines ? join( "\n", 'The change is in these pull requests:', @lines ) . $note : "No pull request came of this.$note" );

    if ( @done > 1 ) {
        for my $pr (@done) {
            my $pull     = $gh->pull( $pr->@{qw(repo pr)} );
            my @siblings = map { "- $_->{pr_url}" } grep { $_->{pr_url} ne $pr->{pr_url} } @done;
            $gh->update_pull( $pr->@{qw(repo pr)}, { body => join( "\n", $pull->{body} // q{}, q{}, 'Merge together with:', @siblings ) } );
        }
    }
    return $job->finish( { prs => [ map { $_->{pr_url} } @done ], of => $total } );
}

=func hand_back

C<($job, $config, $gh, $item, $path, @paragraphs)>.  Gives the origin to a
person, assigns it to them, and removes the bot.  Then it posts the paragraphs
as one comment that mentions that person and every team that owns C<$path>.

The person is the author of a pull request, unless that is the bot.  Otherwise
it is the requester on a pull request.  On an issue, it is the first user who
owns C<$path> in CODEOWNERS, then the repository owner if that owner is a user,
then the requester.

Returns C<{person, assigned, teams}>.  C<assigned> is false when GitHub dropped
the assignment.  It drops it without an error for a user who cannot be
assigned, and the mention still reaches that user.

=cut

sub hand_back ( $job, $config, $gh, $item, $path, @paragraphs ) {
    my ( $repo, $number ) = @{$item}{qw{repo number}};
    my $owners = [];
    if ( ( $path // q{} ) ne q{} ) {
        my ($text) = grep { defined } map { $gh->file( $repo, $_ ) } @App::Clod::CodeOwners::LOCATIONS;
        $owners = App::Clod::CodeOwners::owners( App::Clod::CodeOwners::parse($text), $path ) if defined $text;
    }
    my @teams = grep { m{/} } @$owners;

    my $person;
    if ( $item->{is_pr} ) {
        my $author = $gh->pull( $repo, $number )->{user}{login} // q{};
        $person = $author ne q{} && $author ne $config->{bot} ? $author : $item->{requester};
    }
    ($person) = grep { !m{/} } @$owners if !$person;
    if ( !$person ) {
        my $info = $gh->repo($repo);
        $person = $info->{owner}{type} eq 'User' ? $info->{owner}{login} : $item->{requester};
    }

    my $assigned = assigned( $gh->assign( $repo, $number, $person ), $person );
    $gh->unassign( $repo, $number, $config->{bot} );
    $gh->comment( $repo, $number, join( q{ }, map { "\@$_" } $person, @teams ) . q{: } . join( "\n\n", @paragraphs ) );
    log_note( $job, "gave $repo#$number to $person" . ( $assigned ? q{} : ', but GitHub did not assign them; the mention still reaches them' ) );
    return { person => $person, assigned => $assigned ? 1 : 0, teams => \@teams };
}

=func how_to_resume

C<($config)>.  The paragraph that tells a person how to give the work back to
the bot.

=cut

sub how_to_resume ($config) {
    return "When you have answered, mention \@$config->{bot} here or assign this to \@$config->{bot} again, and the work starts over.";
}

=func kickback

Gives the origin back to a person, through C<hand_back>, when triage answered
C<upstream> or C<clarify>.  For C<upstream> it explains why the fix is
upstream, and how to fix it there by hand.  For C<clarify> it asks the
question.

=cut

sub kickback ( $job, $config, $args ) {
    my ( $item, $triage ) = @{$args}{qw{item triage}};
    my $gh = github($config);

    if ( $triage->{scope} eq 'clarify' ) {
        my $q     = $triage->{question};
        my $asked = hand_back(
            $job, $config, $gh, $item, $q->{path},
            'I need an answer before I can plan this. I changed nothing.',
            $q->{text}, ( $q->{path} ? "This concerns `$q->{path}`." : () ), how_to_resume($config),
        );
        return $job->finish( { %$asked, scope => 'clarify', question => $q->{text}, summary => $q->{text} } );
    }

    my $up    = $triage->{upstream};
    my $asked = hand_back(
        $job, $config, $gh, $item, $up->{path},
        "triage found that the best fix for this is upstream, in $up->{project}, which we do not own. I changed nothing.",
        $up->{explanation}, ( $up->{path} ? "The affected path here is `$up->{path}`." : () ), "Why not here: $triage->{reason}",
        "To fix it there, run claude yourself in a clone of $up->{project}, with perl-slop:pull-requests, and open the pull request. Then mention \@$config->{bot} here with a link to it, so that this issue records it.",
    );
    return $job->finish( { %$asked, scope => 'upstream', project => $up->{project}, summary => $up->{explanation} } );
}

=func create_repo

Makes one repository that triage planned, as the bot, and is a parent of the
first spoke job of the change.  Its arguments are C<item>, and C<org>,
C<name>, C<description>, C<module>, C<private> and C<asked_by> from the entry
of C<new_repos>.

First it asks L</refusal> whether it may.  If not, it makes nothing and gives
the origin to a person through C<hand_back>, with the reason.  Its result then
has C<question>, so the spoke jobs after it wait, as they do after a spoke
that asked.

Otherwise it makes a public repository with C<auto_init>, opens its
L</release_issue>, and comments on the origin with both.  It notes C<created>
as soon as GitHub has made the repository, and C<release_issue> as soon as
the issue is open, so a retry after a failure later on makes neither again.
Its result has C<created>, C<created_at>, C<repo_url> and C<release_url>, and
from then on the repository is a spoke, see L</made_repos>.

If GitHub refuses to make the repository, for example because a private
repository that the bot cannot see has the name, the job fails with GitHub's
reason, and the spoke jobs after it wait for a person.

=cut

sub create_repo ( $job, $config, $args ) {
    my ( $item, $org, $name ) = @{$args}{qw{item org name}};
    my $repo = "$org/$name";
    my $gh   = github($config);
    my $made = $job->info->{notes}{created};
    if ( !$made ) {
        if ( my $why = refusal( $job, $config, $gh, $args ) ) {
            log_note( $job, "did not make $repo: $why" );
            my $asked = hand_back(
                $job, $config, $gh, $item, undef,
                "I did not make the repository $repo, because $why. I changed nothing.",
                'Say which repository the work belongs in, or ask for one with another name.',
                how_to_resume($config),
            );
            return $job->finish( { repo => $repo, refused => $why, question => $why, summary => "Did not make $repo: $why.", %$asked } );
        }
        my $new = $gh->create_org_repo( $org, { name => $name, description => $args->{description}, visibility => 'public', auto_init => Mojo::JSON::true } );
        $made = { url => $new->{html_url}, at => time };
        $job->note( created => $made );
        log_note( $job, "made $repo" );
    }
    my $release = $job->info->{notes}{release_issue};
    if ( !$release ) {
        $release = release_issue( $config, $gh, $args );
        $job->note( release_issue => $release );
        log_note( $job, "opened $release->{url} for $release->{assignee}" . ( $release->{assigned} ? q{} : ', but GitHub did not assign them' ) );
    }
    $gh->comment(
        $item->@{qw(repo number)},
        join "\n\n", "I made the repository $repo for this: $made->{url}",
        "The work on it follows, in a pull request there. Its first release is $release->{url}, for $release->{assignee}."
    );
    return $job->finish( { repo => $repo, created => 1, created_at => $made->{at}, repo_url => $made->{url}, release_url => $release->{url}, summary => "Made $repo: $args->{description}" } );
}

=func refusal

C<($job, $config, $gh, \%args)>.  Why the C<create_repo> job must not make its
repository, or undef when it may.  This is the guard of the hub, whatever
triage said: the repository must not be asked for as private, the
C<create_repos> must be true and the organization in C<spoke_orgs>, the name
must be L<App::Clod::Triage/repo_name>, the origin must have made no
repository so far, counted by L</made_for>, and the repository must not
exist.  The bot never takes over a repository that it did
not make, even one of the same organization: it was not asked to change that
one.  Why it makes no private repository is in L<App::Clod/CAVEATS>.

=cut

sub refusal ( $job, $config, $gh, $args ) {
    my ( $org, $name ) = @{$args}{qw{org name}};
    return 'it is to be private, and I make public repositories only: a bot that serves public and private repositories at once can leak what is in one into the other' if $args->{private};
    return "the configuration does not let me make repositories in $org"                                                                                                if !$config->{create_repos} || !List::Util::any { $_ eq $org } @{ $config->{spoke_orgs} };
    return 'its name does not fit the rule for a new repository'                                                                                                        if !App::Clod::Triage::repo_name($name);
    my $made = made_for( $job->minion, origin_of( $args->{item} ), $job->id );
    return 'this request has made a repository already, and I make one per request'             if $made;
    return "$org/$name exists already, and I do not take over a repository that I did not make" if $gh->repo_exists("$org/$name");
    return;
}

=func release_issue

C<($config, $gh, \%args)>.  Opens the issue "Release I<Module>" in the new
repository, where the module is L<App::Clod::Triage/module_of> the arguments,
and assigns it to C<asked_by>, the person who asked for the repository.  The
assignment puts it in that person's notifications, and the body mentions them
as well, for the case that GitHub drops the assignment.  Returns C<{url,
number, module, assignee, assigned}>.

The module is the one that triage named, else the one that the name of the
repository gives.  The issue is opened before the spoke run, so a module name
that the run settles on later does not change it.

=cut

sub release_issue ( $config, $gh, $args ) {
    my $item   = $args->{item};
    my $repo   = "$args->{org}/$args->{name}";
    my $module = App::Clod::Triage::module_of($args);
    my $who    = $args->{asked_by};
    my $body   = join "\n\n",
      "\@$who: I made $repo at your request, on " . origin_url( $config, $item ) . ": $args->{description}",
      "It is to hold $module. The work on it comes in pull requests here. The first release of $module is yours to make, once they have merged.";
    my $issue = $gh->create_issue( $repo, { title => "Release $module", body => $body, assignees => [$who] } );
    return { url => $issue->{html_url}, number => $issue->{number}, module => $module, assignee => $who, assigned => assigned( $issue, $who ) ? 1 : 0 };
}

=func assigned

C<($issue, $login)>.  True when the issue, as GitHub returned it, is assigned
to the login.  GitHub drops an assignee who cannot be assigned without an
error, so this is how to tell.

=cut

sub assigned ( $issue, $login ) {
    return List::Util::any { ( $_->{login} // q{} ) eq $login } @{ $issue->{assignees} // [] };
}

=func file_issues

Files the follow-up issues that triage planned, as the bot.  Its arguments are
C<item>, and C<issues>, the entries of C<follow_ups>, each with C<repo>,
C<title>, C<body> and C<asked_by>.  Its parents are the C<create_repo> jobs of
the change, if there are any; if one of them refused, it files nothing and
waits, as a spoke does after a question.

First it asks L</filing_refusal> whether it may.  If not, it files nothing and
gives the origin to a person through C<hand_back>, with the reason.
Otherwise it opens each issue in its repository, assigned to C<asked_by>, and
comments on the origin with a link to each.  It notes each issue in C<filed>
as soon as it is open, so a retry after a failure later on files none twice.
Its result has C<filed>, each a C<{repo, title, url, number, assignee,
assigned}>, and C<issues>, their URLs.

=cut

sub file_issues ( $job, $config, $args ) {
    my $item      = $args->{item};
    my @issues    = @{ $args->{issues} };
    my ($waiting) = grep { $_->{question} || $_->{waiting} } parent_results($job);
    return $job->finish( { waiting => 1, summary => "Waits for the answer about $waiting->{repo}." } ) if $waiting;

    my $gh    = github($config);
    my $filed = $job->info->{notes}{filed} // {};
    if ( !%$filed && ( my $why = filing_refusal( $job, $config, $item, \@issues ) ) ) {
        log_note( $job, "filed no follow-up issue: $why" );
        my $asked = hand_back( $job, $config, $gh, $item, undef, "I filed none of the follow-up issues, because $why. I changed nothing.", how_to_resume($config) );
        return $job->finish( { refused => $why, question => $why, summary => "Filed no follow-up issue: $why.", %$asked } );
    }
    for my $n ( 0 .. $#issues ) {
        next if $filed->{$n};
        my $want  = $issues[$n];
        my $who   = $want->{asked_by};
        my $body  = join "\n\n", $want->{body}, "\@$who asked for this on " . origin_url( $config, $item ) . q{.};
        my $issue = $gh->create_issue( $want->{repo}, { title => $want->{title}, body => $body, assignees => [$who] } );
        $filed->{$n} = { repo => $want->{repo}, title => $want->{title}, url => $issue->{html_url}, number => $issue->{number}, assignee => $who, assigned => assigned( $issue, $who ) ? 1 : 0 };
        $job->note( filed => $filed );
        log_note( $job, "filed $issue->{html_url} for $who" );
    }
    my @done = map { $filed->{$_} } 0 .. $#issues;
    $gh->comment( $item->@{qw(repo number)}, join "\n", 'I filed these follow-up issues:', map { "- $_->{repo}: $_->{url} ($_->{title})" } @done );
    return $job->finish( { filed => \@done, issues => [ map { $_->{url} } @done ], summary => 'Filed ' . scalar(@done) . ' follow-up issue(s).' } );
}

=func filing_refusal

C<($job, $config, $item, \@issues)>.  Why the C<file_issues> job must not file its
issues, or undef when it may.  This is the guard of the hub, whatever triage
said: the origin must have filed no more than C<follow_up_max> follow-up
issues with these, counted by L</filed_for>, and each repository must be a
spoke, which a repository that this change made is by now.

=cut

sub filing_refusal ( $job, $config, $item, $issues ) {
    my $filed = filed_for( $job->minion, origin_of($item), $job->id );
    return "this request has filed $filed already, and the configuration allows $config->{follow_up_max} in all" if $filed + @$issues > $config->{follow_up_max};
    my @strangers = grep { !is_spoke( $job->minion, $config, $_ ) } List::Util::uniq( map { $_->{repo} } @$issues );
    return "@strangers is not a spoke" if @strangers;
    return;
}

=func harness_scan

Hourly.  Runs L<App::Clod::Harness> over every spoke and checks the
marketplace pin.  The result of each spoke has its flavor, whether the spoke
chose it, and its checks, and for a spoke that fails a check, C<fix_pr>, the
URL of the pull request of an earlier L</harness_fix> that is still open.
C<checks> names every check of any spoke, sorted, for the columns of the page.  The clones of the standards are in
F<conformance> of the workspace.

With C<system_packages> in the configuration, C<system_packages> of the result
has the declaration of each spoke, as
L<Dist::Conformance::Check::SystemPackages/declared> reads it, and
C<system_package_errors> the error of each spoke whose declaration is not
valid.  The declaration comes from the default branch, as the checks do, and
never from a branch that the bot pushed, so that what the Install packages
button installs is what a person merged.  It is read before the checks, so a
spoke whose checks fail to run still has it.  A branch of the bot can declare
packages too: see L</branch_packages>.  What it declares is installed only
when a person confirms it for that pull request.

=cut

sub harness_scan ( $job, $config ) {
    prune_history( $job->minion, q{harness_scan} );
    my $gh       = github($config);
    my $settings = $config->{harness};

    my %options = ( cache => "$config->{workspace}/conformance" );
    $options{source} = App::Clod::Harness::standards( $settings, %options );

    my ( %repos, %errors, %checks, %packages, %package_errors );
    for my $repo ( @{ spokes( $job->minion, $config ) } ) {
        my $ok = eval {
            my $branch   = default_branch( $gh, $repo );
            my $snapshot = App::Clod::Harness::snapshot( $gh->tree( $repo, $branch ), sub ($path) { $gh->file( $repo, $path, $branch ) } );
            if ( $config->{system_packages} ) {
                my $declared = eval { Dist::Conformance::Check::SystemPackages->declared($snapshot) };
                if   ($declared) { $packages{$repo}       = $declared }
                else             { $package_errors{$repo} = $@ =~ s{\s+\z}{}r }
            }
            my $result = App::Clod::Harness::check( $snapshot, $settings, %options );
            $checks{ $_->{check} } = 1 for @{ $result->{checks} };
            $repos{$repo} = { branch => $branch, %$result };
            if ( List::Util::any { $_->{status} eq 'fail' } @{ $result->{checks} } ) {
                my $open = open_harness_pull( $config, $gh, $repo );
                $repos{$repo}{fix_pr} = $open->{html_url} if $open;
            }
            1;
        };
        $errors{$repo} = $@ if !$ok;
    }
    my $marketplace = App::Clod::Harness::marketplace_check(
        $gh->file( $settings->{plugin_repo},      '.claude-plugin/plugin.json' ),
        $gh->file( $settings->{marketplace_repo}, '.claude-plugin/marketplace.json' ),
        $settings->{plugin},
    );
    my %declared = $config->{system_packages} ? ( system_packages => \%packages, system_package_errors => \%package_errors ) : ();
    return $job->finish( { checked_at => time, repos => \%repos, errors => \%errors, marketplace => $marketplace, checks => [ sort keys %checks ], %declared } );
}

=func harness_fix

C<($job, $config, $args)>, where C<$args> has C<repo>, C<checks>, the failing
checks of the last harness scan, each with C<check> and C<detail>, and C<by>,
who pressed the button.  The issue and the pull request go to L</reviewers> of
C<by>.
Brings the spoke to the harness standards with no claude run, from the
dashboard.  It files an issue that names the failing checks, and runs the
update of L<App::Clod::Harness/update> on a new branch.  If that changes a
file, it commits, through the hooks of the spoke, pushes, and opens a pull
request that closes the issue.  The pull request and the issue say what is
left for a person.  If the update changes nothing, it says so on the issue.

If the bot already has such a pull request open, the job does nothing, so a
second press of the button cannot make a second one.  The issue is in the
notes of the job, so a retry does not file it again.

=cut

my $HARNESS_TITLE = 'Meet the harness standards';

=func open_harness_pull

C<($config, $gh, $repo)>.  The open pull request of the bot in C<$repo> that a
L</harness_fix> opened, or undef.

=cut

sub open_harness_pull ( $config, $gh, $repo ) {
    my ($open) = grep { $_->{title} eq $HARNESS_TITLE && ( $_->{user}{login} // q{} ) eq $config->{bot} } @{ $gh->open_pulls($repo) };
    return $open;
}

sub harness_fix ( $job, $config, $args ) {
    my $repo = $args->{repo};
    my $gh   = github($config);
    my $open = open_harness_pull( $config, $gh, $repo );
    return $job->finish( { repo => $repo, pr_url => $open->{html_url}, open_already => 1 } ) if $open;

    my @failing = map { "- `$_->{check}`: " . ( $_->{detail} // q{} ) } @{ $args->{checks} // [] };
    my $issue   = $job->info->{notes}{issue} // do {
        my $made = $gh->create_issue( $repo, { title => $HARNESS_TITLE, body => join( "\n", 'The harness scan finds that this repository fails these checks:', q{}, @failing, q{}, 'Asked for on the dashboard of the bot.' ), assignees => [ reviewers( $config, $args->{by} ) ] } );
        my %made = ( number => $made->{number}, url => $made->{html_url} );
        $job->note( issue => \%made );
        \%made;
    };

    my $base   = default_branch( $gh, $repo );
    my $branch = 'clod/' . $job->id . '-harness';
    return in_worktree(
        $job, $config, $repo,
        { branch => $branch, base => $base },
        sub ( $spoke, $tree, $tools ) {
            my $results = App::Clod::Harness::update( $tree, $config->{harness}, cache => "$config->{workspace}/conformance" );
            my @changes = map {
                my $check = $_->{check};
                map { "- `$check`: $_->{action} `$_->{path}`" } @{ $_->{changes} }
            } @$results;
            my @manual = map {
                my $check = $_->{check};
                map { "- `$check`: $_" } @{ $_->{manual} }
            } @$results;
            my $left = @manual ? join( "\n", 'Left for a person:', q{}, @manual ) : 'Nothing is left for a person.';

            $spoke->git( q{-C}, "$tree", qw{add -A} );
            if ( $spoke->git( q{-C}, "$tree", qw{status --porcelain} ) eq q{} ) {
                $gh->comment( $repo, $issue->{number}, "The update of the harness changes no file here.\n\n$left" );
                return $job->finish( { repo => $repo, issue_url => $issue->{url}, no_change => 1, manual => \@manual } );
            }
            my $what = join "\n", 'The update of the harness standards, run by the bot.', q{}, @changes;
            $spoke->git( q{-C}, "$tree", qw{commit --quiet -m}, "Meet the harness standards\n\n$what" );
            $spoke->push_branch( $tree, $branch );
            my $pull = $gh->create_pull( $repo, { title => $HARNESS_TITLE, head => $branch, base => $base, body => join( "\n\n", $what, $left, "Closes #$issue->{number}" ) } );
            log_note( $job, "opened $pull->{html_url}" );
            assign_to( $job, $gh, $repo, $pull->{number}, reviewers( $config, $args->{by} ) );
            return $job->finish( { repo => $repo, issue_url => $issue->{url}, branch => $branch, pr => $pull->{number}, pr_url => $pull->{html_url}, changes => \@changes, manual => \@manual } );
        }
    );
}

=func self_check

Every half hour.  Says whether the bot is up to date: C<running>, the commit
that the worker runs, from the helper C<running> of L<App::Clod>, and
C<checkout>, the L<App::Clod/checkout> after a fetch, with C<head>,
C<upstream>, its upstream branch, and C<behind> and C<ahead>, the commits
between the two.  And C<plugins>, from L<App::Clod::Claude/plugins>, for the
account that claude runs as.  With an C<agent_lib>, C<agent_deps>: the tools
of L</agent_tools> that it lacks, and the programs of
L<App::Clod::Deps/stale_programs>, as C<missing>, and those with a newer
release, as C<outdated>.  With a C<local_lib>, C<deps>, the modules there
that have a newer release, from L<App::Clod::Deps/outdated>.  A part that
fails has its error in place of its result, as C<checkout> with C<error>,
C<plugin_error>, C<deps_error> or C<agent_deps_error>.  With no checkout, there is no C<checkout>.
With C<system_packages>, C<system_packages> from L</host_packages>, and
C<system_host>, the distribution of the host that it resolved for, from
L<App::Clod::Packages/os_release>, or C<system_packages_error>.

=cut

sub self_check ( $job, $config ) {
    prune_history( $job->minion, q{self_check} );
    my %result = ( checked_at => time, running => $job->app->running );
    if ( my $dir = App::Clod::checkout() ) {
        my $git = spoke( $config, 'App-Clod' );
        $result{checkout} = eval {
            $git->git_remote( q{-C}, "$dir", qw{fetch --quiet origin} );
            my %at = map { $_ => $git->git( q{-C}, "$dir", 'rev-parse', $_ eq 'head' ? 'HEAD' : '@{upstream}' ) } qw{head upstream};
            my ( $behind, $ahead ) = split m{\s+}, $git->git( q{-C}, "$dir", qw{rev-list --count --left-right}, '@{upstream}...HEAD' );
            +{ %at, behind => 0 + $behind, ahead => 0 + $ahead };
        } // { error => ( split m{\n}, $@ )[0] };
    }
    $result{plugins} = eval { claude($config)->plugins } // do { $result{plugin_error} = ( split m{\n}, $@ )[0]; [] };
    if ( my $lib = $config->{local_lib} ) {
        $result{deps} = eval { App::Clod::Deps::outdated($lib) } // do { $result{deps_error} = ( split m{\n}, $@ )[0]; [] };
    }
    if ( my $lib = $config->{agent_lib} ) {
        $result{agent_deps} = eval {
            my @tools = agent_tools($config);
            +{ missing => [ App::Clod::Deps::missing( $lib, @tools ), App::Clod::Deps::stale_programs($lib) ], outdated => App::Clod::Deps::outdated($lib) };
        } // do { $result{agent_deps_error} = ( split m{\n}, $@ )[0]; { missing => [], outdated => [] } };
    }
    if ( $config->{system_packages} ) {
        $result{system_packages} = eval {
            my %host = App::Clod::Packages::os_release();
            $result{system_host} = \%host;
            host_packages( $config, last_result( $job->minion, 'harness_scan' ), %host );
        } // do { $result{system_packages_error} = ( split m{\n}, $@ )[0]; {} };
    }
    return $job->finish( \%result );
}

=func host_packages

C<($config, $scan, %host)>, with C<$scan> the result of the last L</harness_scan>.
What the host lacks of what each spoke declares there, as L</lacks_of> finds
it, for C<%host>, the distribution of the host from
L<App::Clod::Packages/os_release>.  A hash of each spoke that lacks something
to what L</lacks_of> returns for it.  It asks once about a package that two
spokes declare.

The scan reads the declarations, because it fetches each spoke anyway, and
this check finds what the host has, because it is cheap, and runs again after
L</packages_install>, as L</recheck> queues it.  So an install clears its item
without a new scan of every spoke.

=cut

sub host_packages ( $config, $scan, %host ) {
    my %has;
    my $declared = ( $scan // {} )->{system_packages} // {};
    my %lacks    = map {
        my $lacks = lacks_of( $config, $declared->{$_}, \%host, \%has );
        $lacks ? ( $_ => $lacks ) : ();
    } sort keys %$declared;
    return \%lacks;
}

=func resolved

C<($config, $declared, \%host)>.  The declaration C<$declared>, as
L<Dist::Conformance::Check::SystemPackages/declared> reads it, resolved for the
C<packager> of C<system_packages> and C<%host>, as
L<Dist::Conformance::Check::SystemPackages/resolve> resolves it.  Dies when
C<resolve> dies.

=cut

sub resolved ( $config, $declared, $host ) {
    return Dist::Conformance::Check::SystemPackages->resolve( $declared, packager => $config->{system_packages}{packager}, %$host );
}

=func lacks_of

C<($config, $declared, \%host, \%has)>.  What the host lacks of one
declaration, C<$declared>, as L</resolved> resolves it.  C<%has>
keeps whether the host has each package that it asked about, so a caller that
passes the same hash for several declarations asks once about each package.
Undef when the host lacks nothing, and else a hash of:

=over

=item needs

Each dependency whose package is not installed, a C<{name, package}>, and
C<archive>, the source that the package comes from, when the host does not
have it yet, as L<App::Clod::Packages/has_source> asks.

=item missing

The packages of C<needs>, which an install installs.

=item sources

The archives of C<needs>, once each, which an install adds.

=item unresolved

The names of the dependencies that the spoke declares no package for on this
host.

=item failing

Each a C<{program, dependency, error}>: the test of a dependency that fails,
as L<App::Clod::Packages/program_error> runs it, as the account of
L</claude>.  The tests run only when no package of the spoke is missing,
because a test of a package that is not installed fails anyway.

=back

A declaration that does not resolve for this host has only C<error>, why, and
empty lists.

=cut

sub lacks_of ( $config, $declared, $host, $has = {} ) {
    my $packager = $config->{system_packages}{packager};
    my $resolved = eval { resolved( $config, $declared, $host ) };
    return { needs => [], missing => [], sources => [], unresolved => [], failing => [], error => $@ =~ s{\s+\z}{}r } if !$resolved;
    my %source = map { $_->{name} => $_ } grep { !App::Clod::Packages::has_source( $packager, $_ ) } @{ $resolved->{sources} };
    my @needs  = map {
        my $archive = defined $_->{source} ? $source{ $_->{source} } : undef;
        +{ name => $_->{name}, package => $_->{package}, archive => $archive };
    } grep { defined $_->{package} && !( $has->{ $_->{package} } //= App::Clod::Packages::installed( $packager, $_->{package} ) ? 1 : 0 ) } @{ $resolved->{needs} };
    my $claude  = claude($config);
    my @failing = @needs ? () : map {
        my $error = App::Clod::Packages::program_error( $claude, $_->{test} );
        defined $error ? { program => $_->{test}, dependency => $_->{name}, error => $error } : ();
    } grep { defined $_->{test} } @{ $resolved->{needs} };
    my @unresolved = @{ $resolved->{unresolved} };
    return if !@needs && !@failing && !@unresolved;
    return {
        needs   => \@needs,
        missing => [ List::Util::uniq( map { $_->{package} } @needs ) ],
        sources => [
            do {
                my %seen;
                grep { defined && !$seen{ $_->{name} }++ } map { $_->{archive} } @needs;
            }
        ],
        unresolved => \@unresolved,
        failing    => \@failing,
    };
}

=func self_update

From the dashboard.  Pulls the L<App::Clod/checkout> from its upstream, fast
forward only, and restarts the units of C<restart_units> when the worker runs
another commit than the checkout then has, as L</restart_and_finish> does.
With a C<local_lib>, it first installs there what the new commit needs, as
L<App::Clod::Deps/install> does, and with an C<agent_lib>, the programs of
L<App::Clod::Deps/install_programs>.  It queues a L</recheck>.  Its result has
C<from> and C<to>, the head before and after the pull, and C<restarted>, the
units.

=cut

our $CGROUP = '/proc/self/cgroup';

=func recheck

C<($job)>.  Queues a L</self_check>, so that the action items of the dashboard
show what the button of C<$job> changed.  It waits C<$RECHECK_DELAY> seconds,
so that it does not start in the worker that the job then restarts.  No second
one, while one waits.

=cut

our $RECHECK_DELAY = 60;

sub recheck ($job) {
    my $minion = $job->minion;
    return if $minion->jobs( { tasks => ['self_check'], states => ['inactive'] } )->total;
    $minion->enqueue( self_check => [] => { delay => $RECHECK_DELAY } );
    return;
}

sub self_update ( $job, $config ) {
    my $dir    = App::Clod::checkout() // return $job->fail( { error => 'the bot does not run from a git checkout' } );
    my $git    = spoke( $config, 'App-Clod' );
    my %result = ( from => $git->git( q{-C}, "$dir", qw{rev-parse HEAD} ) );
    $git->git_remote( q{-C}, "$dir", qw{fetch --quiet origin} );
    $git->git( q{-C}, "$dir", qw{merge --ff-only --quiet}, '@{upstream}' );
    $result{to} = $git->git( q{-C}, "$dir", qw{rev-parse HEAD} );
    recheck($job);
    return $job->finish( { %result, restarted => [] } ) if $result{to} eq ( ( $job->app->running // {} )->{sha} // q{} );

    App::Clod::Deps::install( $config->{local_lib}, App::Clod::Deps::listdeps($dir) ) if $config->{local_lib};
    App::Clod::Deps::install_programs( $config->{agent_lib} )                         if $config->{agent_lib};
    return restart_and_finish( $job, $config, \%result );
}

=func restart_and_finish

C<($job, $config, \%result)>.  Restarts the units of C<restart_units>, and
finishes the job with C<%result> and C<restarted>, the units.  It restarts
its own unit, the one that its process runs in, last, after it finishes,
because the restart stops it.  With no C<restart_units>, it restarts nothing,
and C<restart> in the result says that a person must.

=cut

sub restart_and_finish ( $job, $config, $result ) {
    my @units = @{ $config->{restart_units} };
    return $job->finish( { %$result, restarted => [], restart => 'restart_units names no unit, so a person must restart the bot' } ) if !@units;
    my $own    = own_unit() // q{};
    my @others = grep { $_ ne $own } @units;
    restart_unit($_) for @others;
    my @mine = grep { $_ eq $own } @units;
    $job->finish( { %$result, restarted => [ @others, @mine ] } );
    restart_unit($_) for @mine;
    return;
}

=func agent_tools

C<($config)>.  The modules that the agent lib must hold: the tools of
C<@App::Clod::Deps::TOOLS>, and the policy of each critic profile of the
standards, as L<App::Clod::Harness/critic_profiles> finds them.  So a policy
that the standards add reaches the agent with the next install, and no
provision.

=cut

sub agent_tools ($config) {
    my @profiles = App::Clod::Harness::critic_profiles( $config->{harness}, cache => "$config->{workspace}/conformance" );
    return ( @App::Clod::Deps::TOOLS, App::Clod::Deps::policies(@profiles) );
}

=func deps_upgrade

From the dashboard.  Upgrades the modules in C<local_lib> that have a newer
release, as L<App::Clod::Deps/upgrade> does, and then restarts the units, as
L</restart_and_finish> does, so the bot loads them.  With an C<agent_lib>, it
also installs the tools of L</agent_tools> that it lacks, and upgrades those
there with a newer release.  The next claude run loads them, so they restart
nothing.  It queues a L</recheck>.  Its result has C<upgraded> and
C<agent_upgraded>, what it found outdated, and C<agent_installed>.

=cut

sub deps_upgrade ( $job, $config ) {
    my ( $lib, $agent ) = @$config{qw{local_lib agent_lib}};
    return $job->fail( { error => 'clod.conf names no local_lib and no agent_lib' } ) if !$lib && !$agent;
    my %result = ( upgraded => [] );
    if ($agent) {
        my @missing = App::Clod::Deps::missing( $agent, agent_tools($config) );
        App::Clod::Deps::install( $agent, @missing );
        App::Clod::Deps::install_programs($agent);
        @result{qw{agent_installed agent_upgraded}} = ( \@missing, App::Clod::Deps::upgrade($agent) );
    }
    $result{upgraded} = App::Clod::Deps::upgrade($lib) if $lib;
    recheck($job);
    return $job->finish( \%result ) if !@{ $result{upgraded} };
    return restart_and_finish( $job, $config, \%result );
}

=func own_unit

The systemd unit that this process runs in, from F</proc/self/cgroup>, such as
C<clod-worker-example.test.service>.  Undef outside a unit.

=cut

sub own_unit {
    open my $fh, '<', $CGROUP or return;
    my ($unit) = map { m{/([^/]+[.]service)$} } <$fh>;
    close $fh or return;
    return $unit;
}

=func restart_unit

C<($unit)>.  Restarts the unit with C<sudo -n /usr/bin/systemctl restart>,
which is the command that servicesudo grants, as it is written.  Dies with
what sudo or systemctl said if it fails.

=cut

sub restart_unit ($unit) {
    my $err = q{};
    IPC::Run::run( [ qw{sudo -n /usr/bin/systemctl restart}, $unit ], '<', \undef, '>', \my $out, '2>', \$err ) or die "restart $unit: $err\n";
    return;
}

=func plugin_update

From the dashboard.  Updates each plugin that L<App::Clod::Claude/is_behind>
finds behind its marketplace, with C<claude plugin update>, for the account
that claude runs as.  The next run of claude loads the new version, so
nothing restarts.  It queues a L</recheck>.  Its result has C<updated>, the
ids.

=cut

sub plugin_update ( $job, $config ) {
    my $claude  = claude($config);
    my @updated = map { $claude->cli( qw{plugin update}, $_->{id} ); $_->{id} } grep { App::Clod::Claude::is_behind($_) } @{ $claude->plugins };
    recheck($job);
    return $job->finish( { updated => \@updated } );
}

=func packages_install

C<($job, $config, $args)>, where C<$args> has C<repo>, C<packages>, the
names that the last L</self_check> found missing for that spoke, and
C<sources>, the archives that it found missing for them, from the dashboard.
Runs the C<installer> of C<system_packages> with sudo, as
L<App::Clod::Packages/install> does.  With sources, it writes them, one JSON
object on each line, to F<sources.jsonl> in the directory of the job under
F<work> of the workspace, passes that file, and removes the directory
afterwards.  It queues a L</recheck>, so that the
item clears, or shows what still fails.  Its result has C<repo>,
C<packages>, C<sources>, the names of the archives, and C<output>, what the installer printed.  When the installer
fails, the job fails with that as C<error>.

With C<resume>, the id of a job whose branch needs these packages, as
L</waits_for_packages> says, an install that works also L</resume>s the work
of that job.  Then the result has C<resumed>, the id of the job that goes on
with it.

=cut

sub packages_install ( $job, $config, $args ) {
    my $how      = $config->{system_packages} // return $job->fail( { error => 'clod.conf has no system_packages' } );
    my @packages = @{ $args->{packages} // [] };
    return $job->fail( { error => 'there is no package to install' } ) if !@packages;
    my @sources = @{ $args->{sources} // [] };
    my %result  = ( repo => $args->{repo}, packages => \@packages, sources => [ map { $_->{name} } @sources ] );
    my $dir     = Mojo::File->new( $config->{workspace}, 'work', $job->id );
    my $output  = eval {
        my $file = @sources ? $dir->make_path->child('sources.jsonl')->spew( join q{}, map { Mojo::JSON::encode_json($_) . "\n" } @sources ) : undef;
        App::Clod::Packages::install( $how->{installer}, $file ? "$file" : undef, @packages );
    };
    my $error = $@;
    $dir->remove_tree;
    recheck($job);
    return $job->fail( { %result, error => $error } ) if !defined $output;
    my $resumed = defined $args->{resume} ? resume( $job, $args->{resume} ) : undef;
    return $job->finish( { %result, output => $output, ( $resumed ? ( resumed => $resumed ) : () ) } );
}

=func resume

C<($job, $from)>.  Queues a L</spoke_address> with C<resume> on the pull
request of the job C<$from>, whose branch needed system packages that the
host has now.  Its instructions, F<share/prompts/resume.md>, say that the
packages are installed, and that the run must finish the work and run the
tests.  It notes C<resumed>, the id of the new job, on the job C<$from>.
Returns that id.

A Minion lock named after C<$from> lets the work of one job resume once, so a
second install for it resumes nothing, and returns undef.  So does a job
C<$from> that is gone, or whose result needs no packages.

=cut

sub resume ( $job, $from ) {
    my $minion = $job->minion;
    my $source = $minion->job($from);
    my $info   = $source                       ? $source->info   : {};
    my $result = ref $info->{result} eq 'HASH' ? $info->{result} : {};
    return log_note( $job, "job $from waits for no system package, so nothing resumes" ) if !$result->{needs_packages};
    return log_note( $job, "the work of job $from has resumed already" )                 if !$minion->lock( "resume:$from", $CLAIM_SECONDS );

    my $item = { %{ $info->{args}[0]{item} }, number => $result->{pr}, is_pr => 1, kind => 'address_review' };
    my $args = { item => $item, repo => $result->{repo}, resume => 1, instructions => prompt( resume => packages => join q{, }, @{ $result->{packages} } ) };
    my $id   = $minion->enqueue( spoke_address => [$args], { notes => { origin => origin_of($item), repo => $result->{repo}, resumes => 0 + $from } } );
    $source->note( resumed => $id );
    log_note( $job, "queued spoke_address job $id to finish " . origin_of($item) );
    return $id;
}

=func refresh_references

After each L</spoke_sweep>.  Refreshes the reference worktree of every spoke,
one after another, which L</prepare_hub> reads.  A spoke that fails does not
stop the rest.  Its result has C<refreshed>, the count, and C<errors>, a hash of
repository to error.

=cut

sub refresh_references ( $job, $config ) {
    prune_history( $job->minion, q{refresh_references} );
    my $gh = github($config);
    my ( $refreshed, %errors ) = (0);
    for my $repo ( @{ spokes( $job->minion, $config ) } ) {
        if ( eval { spoke( $config, $repo )->refresh_reference( default_branch( $gh, $repo ) ); 1 } ) {
            $refreshed++;
        }
        else { $errors{$repo} = ( split m{\n}, $@ )[0] }
    }
    return $job->finish( { checked_at => time, refreshed => $refreshed, errors => \%errors } );
}

=func assigned_sweep

Every fifteen minutes.  Lists the open issues and pull requests assigned to the
bot in every spoke.

=cut

sub assigned_sweep ( $job, $config ) {
    prune_history( $job->minion, q{assigned_sweep} );
    my $gh = github($config);
    my ( @issues, %errors );
    for my $repo ( @{ spokes( $job->minion, $config ) } ) {
        my $list = eval { $gh->assigned_issues( $repo, $config->{bot} ) };
        if ( !$list ) { $errors{$repo} = $@; next }
        push @issues, map { { repo => $repo, number => $_->{number}, title => $_->{title}, url => $_->{html_url}, is_pr => $_->{pull_request} ? 1 : 0, updated_at => $_->{updated_at} } } @$list;
    }
    return $job->finish( { checked_at => time, issues => \@issues, errors => \%errors } );
}

=func activity_sweep

Every fifteen minutes.  Counts, over the hub and every spoke, the open issues
that nobody is assigned to, the issues opened in the last seven days, and the
pull requests merged in the last seven days.  Pull requests are not issues.
It makes one search for each count and each owner of a spoke, and keeps the
items of the spokes, because GitHub allows 30 searches a minute, and a search
for each spoke went over that.  Its result has C<checked_at>, C<unassigned>,
C<opened_7d>, C<merged_7d>, and C<errors>, a hash of owner to error.  An owner
that fails adds nothing to any of the three counts.

=cut

sub activity_sweep ( $job, $config ) {
    prune_history( $job->minion, q{activity_sweep} );
    my $gh    = github($config);
    my $since = POSIX::strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime( time - 7 * $DAY ) );
    my %query = ( unassigned => 'is:issue is:open no:assignee', opened_7d => "is:issue created:>=$since", merged_7d => "is:pr is:merged merged:>=$since" );
    my %spoke = map { $_ => 1 } @{ spokes( $job->minion, $config ) };
    my ( %total, %errors );
    for my $owner ( List::Util::uniq( map { ( split m{/} )[0] } sort keys %spoke ) ) {
        my %count;
        my $ok = eval {
            for my $what ( sort keys %query ) {
                $count{$what} = grep { $spoke{ ( $_->{repository_url} // q{} ) =~ s{\A.*/repos/}{}r } } @{ $gh->search_issues("user:$owner $query{$what}") };
            }
            1;
        };
        if ( !$ok ) {
            $errors{$owner} = $@;
            next;
        }
        $total{$_} += $count{$_} for keys %count;
    }
    return $job->finish( { checked_at => time, unassigned => $total{unassigned} // 0, opened_7d => $total{opened_7d} // 0, merged_7d => $total{merged_7d} // 0, errors => \%errors } );
}

=func spoke_sweep

Every fifteen minutes, also when C<spoke_orgs> is empty.  When it is done, it
queues L</refresh_references>, unless one waits or runs already.  Lists the public
repositories of each organization of C<spoke_orgs>, without forks and archived
ones.  Its result has C<started_at>, the time before the first listing, so
that L</made_repos> can tell whether it saw a repository made since.  If
listing an organization fails, its repositories from the sweep before stay
spokes, so one failed request does not drop them.

It also asks GitHub for the visibility of each repository in C<spokes>.  The
C<dropped> hash of the result maps each one that is not public to the reason,
and L</spokes> leaves those out, so that what a private repository holds does
not reach a public pull request.  If the lookup of a repository fails, the
verdict of the sweep before stands.  That includes a 404, which GitHub also
answers for a private repository that the token cannot see: such a repository
stays a spoke, because treating every failed lookup as private would drop each
spoke during an outage.

=cut

sub spoke_sweep ( $job, $config ) {
    my $minion  = $job->minion;
    my $started = time;
    my $before  = last_result( $minion, 'spoke_sweep' ) // {};
    prune_history( $minion, q{spoke_sweep} );
    my $gh = github($config);
    my %dropped;
    for my $repo ( @{ $config->{spokes} } ) {
        my $info = eval { $gh->repo($repo) };
        if ( !$info ) {
            $dropped{$repo} = $before->{dropped}{$repo} if $before->{dropped}{$repo};
            next;
        }
        my $visibility = $info->{visibility} // ( $info->{private} ? 'private' : 'public' );
        $dropped{$repo} = "its visibility is $visibility, and a spoke must be public" if $visibility ne 'public';
    }
    my ( %by_org, %errors );
    for my $org ( @{ $config->{spoke_orgs} } ) {
        my $list = eval { $gh->org_repos($org) };
        if ( !$list ) {
            $errors{$org} = $@;
            $by_org{$org} = ( $before->{by_org} // {} )->{$org} // [];
            next;
        }
        $by_org{$org} = [ sort map { $_->{full_name} } grep { !$_->{fork} && !$_->{archived} } @$list ];
    }
    $job->finish( { started_at => $started, checked_at => time, by_org => \%by_org, dropped => \%dropped, repos => [ sort map { @$_ } values %by_org ], errors => \%errors } );
    $minion->enqueue('refresh_references') if !$minion->jobs( { tasks => ['refresh_references'], states => [qw{inactive active}] } )->total;
    return;
}

1;

=head1 SYNOPSIS

    use 5.040;
    use App::Clod::Tasks;

    # In the startup of the Mojolicious app, with the validated configuration.
    sub add_tasks ( $app, $config ) {
        App::Clod::Tasks::register( $app, $config );
        App::Clod::Tasks::schedule( $app->minion );
        return;
    }

=head1 DESCRIPTION

Every task takes the configuration first, then the job's arguments.  Each
task is documented at its sub.

An item is the hash that L</inbox_thread> makes from one notification.  Every
job of the change carries it unchanged: C<triage> and C<reply> get it as their
argument, and the jobs that triage plans get it as C<item>, beside C<repo> and
C<instructions> for a spoke job.  Its keys:

=over

=item repo

The C<Owner/Name> of the issue or pull request that the notification is about:
the origin.  A spoke job works in its own C<repo>, which can be another one.

=item number

The number of the issue or pull request in C<repo>.

=item kind

C<fix>, C<review>, C<address_review> or C<reply>, from the reason of the
notification.  A C<reply> that finds a request for a change hands triage a copy
with C<fix>, or C<address_review> on a pull request.

=item is_pr

1 when the origin is a pull request, else 0.

=item title

The title of the origin, for the name of the branch.

=item requester

The authorized user who caused the notification.

=item thread

The id of the notification.  No task reads it.  It is there so that a job in
F</minion> can be traced back to its notification.

=item comment_url

The API URL of the latest comment when the notification came.  No task reads
it either, for the same reason.

=back

The spoke tasks, C<spoke_fix>, C<spoke_review> and C<spoke_address>, work in
L</in_worktree>, which also checks out the C<tool_spokes> for the run, and
their runs get C<spoke_prompt> through L</system_text>.

=cut
