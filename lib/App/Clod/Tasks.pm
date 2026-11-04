package App::Clod::Tasks;

# ABSTRACT: The Minion tasks: inbox, triage, the spokes, and the scans

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';

use List::Util  ();
use Mojo::File  ();
use Mojo::JSON  ();
use Time::HiRes qw{time};

use App::Clod::Budget();
use App::Clod::Claude();
use App::Clod::CodeOwners();
use App::Clod::GitHub();
use App::Clod::Harness();
use App::Clod::Outage();
use App::Clod::Spoke();
use App::Clod::Triage();

# What each kind of notification asks the bot to do.
our %KIND = (
    assign           => 'fix',
    review_requested => 'review',
    author           => 'address_review',
    mention          => 'reply',
);

our %TASKS = (
    inbox_poll     => \&inbox_poll,
    triage         => \&triage,
    spoke_fix      => \&spoke_fix,
    spoke_review   => \&spoke_review,
    spoke_address  => \&spoke_address,
    reply          => \&reply,
    report         => \&report,
    kickback       => \&kickback,
    harness_scan   => \&harness_scan,
    assigned_sweep => \&assigned_sweep,
    spoke_sweep    => \&spoke_sweep,
    create_repo    => \&create_repo,
    file_issues    => \&file_issues,
);

# Each Minion schedule: its cron line and its task.
our %SCHEDULES = (
    inbox    => [ '* * * * *',    'inbox_poll' ],
    harness  => [ '17 * * * *',   'harness_scan' ],
    assigned => [ '*/15 * * * *', 'assigned_sweep' ],
    spokes   => [ '*/15 * * * *', 'spoke_sweep' ],
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
C<harness_scan>, C<assigned_sweep> and C<spoke_sweep>.

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
telemetry.  Its default tools, which the runs that change a repository get,
are C<allowed_tools> and then C<extra_tools>.  A read-only run passes
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
their system prompt: C<spoke_prompt> for a spoke task, then the
C<system_prompts> text of the task, a blank line between them.  Undef when
there is neither.

=cut

sub system_text ( $config, $task ) {
    my @parts = grep { ( $_ // q{} ) ne q{} } ( $SPOKE_TASKS{$task} ? $config->{spoke_prompt} : undef ), $config->{system_prompts}{$task};
    return @parts ? join( "\n\n", @parts ) : undef;
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

C<($minion, $config)>.  The spokes: C<spokes> from the configuration, the
repositories that the last C<spoke_sweep> found in C<spoke_orgs>, and the
L</made_repos>, sorted and each once.  Before the first sweep finishes, only
the configured ones and the made ones.

=cut

sub spokes ( $minion, $config ) {
    my $swept = @{ $config->{spoke_orgs} // [] } ? last_result( $minion, 'spoke_sweep' ) // {} : {};
    return [ sort( List::Util::uniq( @{ $config->{spokes} }, @{ $swept->{repos} // [] }, made_repos( $minion, $swept ) ) ) ];
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
    $gh->react( $repo, $number, 'eyes' );
    my $id = $minion->enqueue( ( $kind eq 'reply' ? 'reply' : 'triage' ) => [ \%item ], { notes => { origin => $origin, kind => $kind } } );
    $gh->mark_read( $thread->{id} );
    log_note( $job, "queued job $id for $kind on $origin" );
    return $id;
}

=func queued_address

C<($minion, $origin)>.  The id of a job that has yet to read the conversation of
the pull request C<$origin> and answer it: a C<triage> of it for
C<address_review> that waits or runs, or a C<spoke_address> of it that waits.
Undef if there is none.  A C<spoke_address> that runs does not count: it read
what was pending when it started, so it does not answer a later comment.

=cut

sub queued_address ( $minion, $origin ) {
    my $jobs = $minion->jobs( { tasks => [qw{triage spoke_address}], states => [qw{inactive active}] } );
    while ( my $info = $jobs->next ) {
        next if ( $info->{notes}{origin} // q{} ) ne $origin;
        next if $info->{task} eq 'triage' && ( $info->{notes}{kind} // q{} ) ne 'address_review';
        next if $info->{task} eq 'spoke_address' && $info->{state} ne 'inactive';
        return $info->{id};
    }
    return;
}

=func requester

Who caused the notification: the actor of the assignment or review request, or
the author of the latest comment.

=cut

sub requester ( $config, $gh, $repo, $number, $reason, $subject ) {
    my $bot = $config->{bot};
    if ( $reason eq 'assign' || $reason eq 'review_requested' ) {
        my $wanted  = $reason eq 'assign' ? 'assigned' : 'review_requested';
        my $field   = $reason eq 'assign' ? 'assignee' : 'requested_reviewer';
        my ($event) = grep { ( $_->{event} // q{} ) eq $wanted && ( $_->{$field}{login} // q{} ) eq $bot } reverse @{ $gh->issue_events( $repo, $number ) };
        return $event ? $event->{actor}{login} : undef;
    }
    return if !$subject->{latest_comment_url};
    return $gh->get( $subject->{latest_comment_url} )->{user}{login};
}

=func context

C<($config, $gh, $item)>.  The issue or pull request and the last twenty
entries of its L</conversation>, as Markdown for a prompt.

=cut

sub context ( $config, $gh, $item ) {
    my $issue = $gh->issue( $item->{repo}, $item->{number} );
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
    my @said = @{ $gh->issue_comments( $item->{repo}, $item->{number} ) };
    if ( $item->{is_pr} ) {
        push @said, map { { id => $_->{id}, user => $_->{user}, body => $_->{body}, created_at => $_->{submitted_at}, review => 1 } }
          grep { ( $_->{body} // q{} ) ne q{} } @{ $gh->reviews( $item->{repo}, $item->{number} ) };
    }
    return [ sort { ( $a->{created_at} // q{} ) cmp ( $b->{created_at} // q{} ) || $a->{id} <=> $b->{id} } @said ];
}

=func default_branch

C<($gh, $repo)>.

=cut

sub default_branch ( $gh, $repo ) { return $gh->repo($repo)->{default_branch} }

=func prepare_hub

C<($config, $gh, \@spokes)>.  Refreshes the reference worktree of every spoke
and writes the hub CLAUDE.md.  Returns the hub directory and a hash of
repository to reference worktree.

=cut

# Every spoke at its default branch, and the hub workspace that describes them.
sub prepare_hub ( $config, $gh, $spokes ) {
    my %ref;
    for my $repo (@$spokes) {
        $ref{$repo} = spoke( $config, $repo )->refresh_reference( default_branch( $gh, $repo ) );
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
    my $issue = $gh->issue( $item->{repo}, $item->{number} );
    my @lines = $item->{is_pr} ? @{ $gh->review_comments( $item->{repo}, $item->{number} ) } : ();
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
    my ( $hub, $ref ) = prepare_hub( $config, $gh, $spokes );
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
    for ( 1 .. 2 ) {
        my $outcome = run_claude(
            $job, $config,
            dir             => $hub,
            prompt          => prompt( triage => %vars, retry => $error ? "\nYour last answer was rejected: $error\n" : q{} ),
            tools           => $config->{claude}{read_tools},
            permission_mode => 'default',
            add_dirs        => [ map { "$_" } values %$ref ],
            schema          => App::Clod::Triage::schema( $spokes, %create ),
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

=func spoke_fix

Works on a new branch in a worktree of one spoke.  The spoke commits, and the
job pushes and opens the pull request.  If the spoke asks a question instead,
the job gives the origin to a person through C<hand_back>.  A job whose parent
asked a question, or waits for one, does not run the spoke, and waits too.
When C<created> is in its arguments, the hub made the repository for this
change, and the prompt says so.

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

    return in_worktree(
        $job, $config, $repo,
        { branch => $branch, base => $base },
        sub ( $spoke, $tree, $tools ) {
            my $outcome = run_claude(
                $job, $config,
                dir      => $tree,
                prompt   => prompt( fix => repo => $repo, branch => $branch, origin => origin_url( $config, $item ), instructions => $args->{instructions}, created => $args->{created} ? prompt( 'fix-created', repo => $repo ) : q{}, prior => $prior, tools => $tools->{note}, context => context( $config, $gh, $item ) ),
                add_dirs => $tools->{add_dirs},
                schema   => {
                    type       => 'object',
                    required   => [qw{title summary}],
                    properties => { title => { type => 'string' }, summary => { type => 'string' }, question => { type => 'string' }, path => { type => 'string' } },
                },
            ) // return;
            my %usage   = usage_of($outcome);
            my $answer  = $outcome->{structured} // {};
            my $commits = $spoke->commits_since( $tree, "origin/$base" );
            return $job->fail( { repo => $repo, error => "the run failed: $outcome->{stderr}", %usage } ) if !$outcome->{ok} && !$commits;

            if ( !$commits && ( $answer->{question} // q{} ) ne q{} ) {
                my $asked = hand_back(
                    $job, $config, $gh, $item, $answer->{path},
                    "I need an answer before I can change $repo. I changed nothing.",
                    $answer->{question}, ( $answer->{path} ? "This concerns `$answer->{path}` in $repo." : () ), how_to_resume($config),
                );
                return $job->finish( { repo => $repo, question => $answer->{question}, summary => $answer->{question}, %$asked, %usage } );
            }
            return $job->finish( { repo => $repo, no_change => 1, summary => $answer->{summary}, %usage } ) if !$commits;

            $spoke->push_branch( $tree, $branch );
            my $body = join "\n\n", $answer->{summary} // q{}, 'For ' . origin_url( $config, $item ), ( map { "Follows $_->{pr_url}" } grep { $_->{pr_url} } @prior );
            my $pull = $gh->create_pull( $repo, { title => $answer->{title} || $item->{title}, head => $branch, base => $base, body => $body } );
            log_note( $job, "opened $pull->{html_url}" );
            return $job->finish( { repo => $repo, branch => $branch, pr => $pull->{number}, pr_url => $pull->{html_url}, summary => $answer->{summary}, commits => $commits, %usage } );
        }
    );
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

=func spoke_address

Answers what authorized users said on the bot's own pull request since the bot
last answered: the review threads whose last message is theirs, and the plain
comments and review bodies after the last comment of the bot.  It pushes the
fixes, replies in each thread, and answers the plain comments in one comment.
The prompt also holds the whole conversation of the pull request.

=cut

sub spoke_address ( $job, $config, $args ) {
    my $item = $args->{item};
    my $repo = $args->{repo};
    my $gh   = github($config);
    my $pull = $gh->pull( $repo, $item->{number} );
    return $job->fail( { repo => $repo, error => 'the pull request is not the bot\'s own, from this repository' } )
      if $pull->{user}{login} ne $config->{bot} || $pull->{head}{repo}{full_name} ne $repo;

    my $pending  = pending_threads( $config, $gh->review_comments( $repo, $item->{number} ) );
    my $comments = pending_comments( $config, conversation( $gh, $item ) );
    return $job->finish( { repo => $repo, nothing => 1 } ) if !@$pending && !@$comments;

    my $branch = $pull->{head}{ref};
    return in_worktree(
        $job, $config, $repo,
        { existing => $branch },
        sub ( $spoke, $tree, $tools ) {
            my $outcome = run_claude(
                $job, $config,
                dir    => $tree,
                prompt => prompt(
                    address      => repo => $repo,
                    branch       => $branch,
                    origin       => origin_url( $config, $item ),
                    instructions => $args->{instructions},
                    tools        => $tools->{note},
                    history      => context( $config, $gh, $item ),
                    context      => Mojo::JSON::encode_json( { threads => $pending, comments => $comments } ),
                ),
                add_dirs => $tools->{add_dirs},
                schema   => {
                    type       => 'object',
                    required   => [qw{summary replies}],
                    properties => {
                        summary => { type => 'string' },
                        replies => { type => 'array', items => { type => 'object', required => [qw{id body}], properties => { id => { type => 'integer' }, body => { type => 'string' } } } },
                        comment => { type => 'string' },
                    },
                },
            ) // return;
            my %usage  = usage_of($outcome);
            my $answer = $outcome->{structured};
            return $job->fail( { repo => $repo, error => "the run failed: $outcome->{stderr}", %usage } ) if ref $answer ne 'HASH';

            my $commits = $spoke->commits_since( $tree, "origin/$branch" );
            $spoke->push_branch( $tree, $branch ) if $commits;
            my %open = map { $_->{id} => 1 } @$pending;
            my @replied;
            for my $reply ( grep { $open{ $_->{id} } } @{ $answer->{replies} } ) {
                $gh->reply_review_comment( $repo, $item->{number}, $reply->{id}, $reply->{body} );
                push @replied, $reply->{id};
            }
            my $answered = @$comments && ( $answer->{comment} // q{} ) ne q{} ? $gh->comment( $repo, $item->{number}, $answer->{comment} )->{html_url} : undef;
            return $job->finish( { repo => $repo, branch => $branch, pr => $item->{number}, pr_url => $pull->{html_url}, commits => $commits, replied => \@replied, ( $answered ? ( comment_url => $answered ) : () ), summary => $answer->{summary}, %usage } );
        }
    );
}

=func reply

Answers a mention.  If the person asked for a change, it also enqueues triage.

=cut

sub reply ( $job, $config, $item ) {
    my $gh = github($config);
    my ( $hub, $ref ) = prepare_hub( $config, $gh, spokes( $job->minion, $config ) );
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

    $gh->comment( $item->{repo}, $item->{number}, $answer->{body} );
    my %result = ( action => $answer->{action}, summary => $answer->{body}, %usage );
    if ( $answer->{action} eq 'fix' ) {
        my %next = ( %$item, kind => $item->{is_pr} ? 'address_review' : 'fix' );
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
    $gh->comment( $item->{repo}, $item->{number}, @lines ? join( "\n", 'The change is in these pull requests:', @lines ) . $note : "No pull request came of this.$note" );

    if ( @done > 1 ) {
        for my $pr (@done) {
            my $pull     = $gh->pull( $pr->{repo}, $pr->{pr} );
            my @siblings = map { "- $_->{pr_url}" } grep { $_->{pr_url} ne $pr->{pr_url} } @done;
            $gh->update_pull( $pr->{repo}, $pr->{pr}, { body => join( "\n", $pull->{body} // q{}, q{}, 'Merge together with:', @siblings ) } );
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
        $item->{repo}, $item->{number},
        join "\n\n",   "I made the repository $repo for this: $made->{url}",
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
    $gh->comment( $item->{repo}, $item->{number}, join "\n", 'I filed these follow-up issues:', map { "- $_->{repo}: $_->{url} ($_->{title})" } @done );
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
chose it, and its checks.  C<checks> names every check of any spoke, sorted,
for the columns of the page.  The clones of the standards are in
F<conformance> of the workspace.

=cut

sub harness_scan ( $job, $config ) {
    prune_history( $job->minion, q{harness_scan} );
    my $gh       = github($config);
    my $settings = $config->{harness};

    my %options = ( cache => "$config->{workspace}/conformance" );
    $options{source} = App::Clod::Harness::standards( $settings, %options );

    my ( %repos, %errors, %checks );
    for my $repo ( @{ spokes( $job->minion, $config ) } ) {
        my $ok = eval {
            my $branch   = default_branch( $gh, $repo );
            my $snapshot = App::Clod::Harness::snapshot( $gh->tree( $repo, $branch ), sub ($path) { $gh->file( $repo, $path, $branch ) } );
            my $result   = App::Clod::Harness::check( $snapshot, $settings, %options );
            $checks{ $_->{check} } = 1 for @{ $result->{checks} };
            $repos{$repo} = { branch => $branch, %$result };
            1;
        };
        $errors{$repo} = $@ if !$ok;
    }
    my $marketplace = App::Clod::Harness::marketplace_check(
        $gh->file( $settings->{plugin_repo},      '.claude-plugin/plugin.json' ),
        $gh->file( $settings->{marketplace_repo}, '.claude-plugin/marketplace.json' ),
        $settings->{plugin},
    );
    return $job->finish( { checked_at => time, repos => \%repos, errors => \%errors, marketplace => $marketplace, checks => [ sort keys %checks ] } );
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

=func spoke_sweep

Every fifteen minutes, when C<spoke_orgs> names any.  Lists the public
repositories of each one, without forks and archived ones.  Its result has
C<started_at>, the time before the first listing, so that L</made_repos> can
tell whether it saw a repository made since.  If listing an
organization fails, its repositories from the sweep before stay spokes, so one
failed request does not drop them.

=cut

sub spoke_sweep ( $job, $config ) {
    my $minion  = $job->minion;
    my $started = time;
    my $before  = last_result( $minion, 'spoke_sweep' ) // {};
    prune_history( $minion, q{spoke_sweep} );
    my $gh = github($config);
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
    return $job->finish( { started_at => $started, checked_at => time, by_org => \%by_org, repos => [ sort map { @$_ } values %by_org ], errors => \%errors } );
}

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
