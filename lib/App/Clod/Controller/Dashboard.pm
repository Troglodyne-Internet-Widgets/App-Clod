package App::Clod::Controller::Dashboard;

# ABSTRACT: The health page and the JSON behind it

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Time::HiRes qw{time};

use App::Clod::Budget();
use App::Clod::Claude();
use App::Clod::Outage();
use App::Clod::Tasks();

our @ITEM_TASKS = qw{triage reply};

# A worker polls every minute; this long without a poll means none is running.
my $STALE_INBOX = 900;

=method page

Renders the health page.

=cut

sub page ($self) { return $self->render( template => 'dashboard', bot => $self->clod_config->{bot} ) }

=method overview

Item counts by state, the Minion stats, the budget, the outages, the action
items, and C<running>, the commit that the page runs, as C<{sha, short}>, or
undef when it runs from no checkout.  C<activity> is the result of the last
L<App::Clod::Tasks/activity_sweep>, with C<unassigned>, C<opened_7d>,
C<merged_7d> and C<checked_at>, and it is undef until one has finished.

=cut

sub overview ($self) {
    my $minion = $self->minion;
    my $budget = App::Clod::Budget::summary($minion);
    my %counts;
    for my $state (qw{inactive active failed}) {
        $counts{$state} = $minion->jobs( { tasks => \@ITEM_TASKS, states => [$state] } )->total;
    }
    my $outages = App::Clod::Outage::summary($minion);
    return $self->render( json => { stats => $minion->stats, items => \%counts, budget => $budget, outages => $outages, running => $self->running, activity => App::Clod::Tasks::last_result( $minion, 'activity_sweep' ), actions => $self->action_items( $budget, $outages ) } );
}

=method action_items

C<($budget, $outages)>, from L<App::Clod::Budget/summary> and
L<App::Clod::Outage/summary>.  The things that need a person, each a
C<{level, text}> and sometimes a C<job>.  An outage comes first.  An item that
a button can settle has C<buttons>, each a C<{label, act}> and sometimes a
C<body>: the dashboard posts C<body> to F</act/E<lt>actE<gt>>.  A failed job
has Retry and Ignore, and a spoke that fails harness checks has Fix, unless a
L<App::Clod::Tasks/harness_fix> of it waits or runs, or its pull request
waits for review.  Then the item has C<link>, a C<{url, label}>, to the pull
request, and no button.  A failed job that
somebody ignored is not an item.

=cut

sub action_items ( $self, $budget, $outages = [] ) {
    my $minion = $self->minion;
    my @actions;
    my %out = map { $_->{service} => $_ } @$outages;
    for my $o (@$outages) {
        my $what = $o->{service} eq 'github' ? 'All work waits' : 'Claude work waits';
        push @actions,
          {
            level => 'danger',
            ( $o->{job} ? ( job => $o->{job} ) : () ),
            text => "$o->{name} refuses the token" . ( $o->{at} ? q{, last at } . gmtime( $o->{at} ) . ' UTC' : q{} ) . ': ' . ( $o->{error} // 'no reason recorded' ) . ". $what, and a job tries the token again every " . ( $App::Clod::Outage::SECONDS / 60 ) . ' minutes.',
          };
    }

    my $harness = App::Clod::Tasks::last_result( $minion, 'harness_scan' );
    if ( !$harness ) {
        push @actions, { level => 'info', text => 'No harness scan has finished yet.' };
    }
    else {
        my $m = $harness->{marketplace} // {};
        push @actions, { level => 'warning', text => "Marketplace: $m->{detail}." } if ( $m->{status} // q{} ) eq 'fail';
        for my $repo ( sort keys %{ $harness->{repos} } ) {
            my @failing = grep { $_->{status} eq 'fail' } @{ $harness->{repos}{$repo}{checks} };
            next if !@failing;
            my $text  = "$repo fails " . scalar(@failing) . ' harness check(s): ' . join( q{, }, map { $_->{check} } @failing ) . q{.};
            my $fixer = pending_harness_fix( $minion, $repo );
            my $pull  = !$fixer && harness_pull( $minion, $repo, $harness );
            push @actions,
                $fixer ? { level => 'warning', job => $fixer, text => "$text A harness fix of it is queued." }
              : $pull  ? { level => 'warning', text => "$text A fix waits for review:", link => { url => $pull, label => pull_label($pull) } }
              :          { level => 'warning', text => $text, buttons => [ { label => 'Fix', act => 'harness/fix', body => { repo => $repo } } ] };
        }
        push @actions, { level => 'danger', text => "Harness scan of $_ failed: $harness->{errors}{$_}" } for sort keys %{ $harness->{errors} // {} };
    }

    my $inbox = App::Clod::Tasks::last_result( $minion, 'inbox_poll' );

    if ( $inbox && $inbox->{no_spokes_since} ) {
        my $waited = time - $inbox->{no_spokes_since};
        push @actions,
          $waited > $STALE_INBOX
          ? { level => 'danger', text => 'No repository has been a spoke for ' . int( $waited / 60 ) . ' minutes, so the inbox is not read. Make sure that spoke_orgs names an organization with public repositories, or name spokes.' }
          : { level => 'info',   text => 'The inbox waits for the first spoke sweep.' };
    }

    # During a GitHub outage, the outage says why the inbox is not read.
    elsif ( !$out{github} && ( !$inbox || time - ( $inbox->{polled_at} // 0 ) > $STALE_INBOX ) ) {
        push @actions, { level => 'danger', text => 'The inbox has not been read in 15 minutes. Is a worker running?' };
    }
    elsif ( $inbox && defined $inbox->{scopes} ) {
        my %have = map { $_ => 1 } split /,\s*/, $inbox->{scopes};

        # GitHub takes repo in place of notifications for the inbox.
        my @missing = grep { !$have{$_} } qw{repo};
        push @actions, { level => 'danger', text => "The token lacks the scopes: @missing." } if @missing;
    }

    my $sweep = App::Clod::Tasks::last_result( $minion, 'spoke_sweep' ) // {};
    push @actions, { level => 'danger', text => "Listing the repositories of $_ failed: $sweep->{errors}{$_}" } for sort keys %{ $sweep->{errors} // {} };

    push @actions, { level => 'danger', text => "$_ is not a spoke: $sweep->{dropped}{$_}" } for sort keys %{ $sweep->{dropped} // {} };

    push @actions, { level => 'warning', text => 'Claude work is paused until the quota resets' . ( $budget->{paused_until} ? q{ at } . gmtime( $budget->{paused_until} ) . ' UTC' : q{} ) . q{.} } if $budget->{paused};

    push @actions, $self->self_items( $minion, App::Clod::Tasks::last_result( $minion, 'self_check' ) );

    my $failed = $minion->jobs( { states => ['failed'] } );
    my $shown  = 0;
    while ( my $info = $failed->next ) {
        next if $info->{notes}{ignored};
        last if ++$shown > 10;
        my $error = ref $info->{result} eq 'HASH' ? $info->{result}{error} : $info->{result};
        push @actions,
          {
            level   => 'danger',
            job     => $info->{id},
            text    => "Job $info->{id} ($info->{task}" . ( $info->{notes}{origin} ? " for $info->{notes}{origin}" : q{} ) . ') failed: ' . substr( $error // 'no reason given', 0, 300 ),
            buttons => [ { label => 'Retry', act => "jobs/$info->{id}/retry" }, { label => 'Ignore', act => "jobs/$info->{id}/ignore" } ],
          };
    }
    return \@actions;
}

=method self_items

C<($minion, $check)>, with C<$check> the result of the last
L<App::Clod::Tasks/self_check>.  The action items that it calls for: a bot
behind its upstream, or a checkout that the bot does not run yet, with an
Update button, and plugins behind their marketplace, with an Update plugins
button, and Perl modules in C<local_lib> with a newer release, with an Upgrade
modules button, and tools that the agent lacks, or that have a newer release,
in C<agent_lib>, with an Install tools button.  While a job for a button waits or runs, the item names it, and has
no button.

=cut

sub self_items ( $self, $minion, $check ) {
    return if !$check;
    my @items;
    my $at      = $check->{checkout} // {};
    my $running = $self->running     // {};
    if ( $at->{error} ) {
        push @items, { level => 'warning', text => "The bot cannot tell whether it is up to date: $at->{error}" };
    }
    elsif ( $at->{head} ) {
        my @why;
        push @why,   "its checkout is $at->{behind} commit(s) behind upstream"                                                                                       if $at->{behind};
        push @why,   'its checkout is at ' . substr( $at->{head}, 0, 7 ) . ', which it does not run yet'                                                             if !$at->{behind} && $at->{head} ne ( $running->{sha} // q{} );
        push @items, button_item( $minion, 'self_update', 'The bot is out of date: ' . join( q{, and }, @why ) . q{.}, { label => 'Update', act => 'self/update' } ) if @why;
    }
    my @behind = grep { App::Clod::Claude::is_behind($_) } @{ $check->{plugins} // [] };
    push @items, button_item( $minion, 'plugin_update', 'Plugins have a newer version: ' . join( q{, }, map { "$_->{id} $_->{version} to $_->{latest}" } @behind ) . q{.}, { label => 'Update plugins', act => 'plugins/update' } ) if @behind;
    push @items, { level => 'warning', text => "The bot cannot tell whether its plugins are up to date: $check->{plugin_error}" } if $check->{plugin_error};
    my @old = @{ $check->{deps} // [] };
    push @items, button_item( $minion, 'deps_upgrade', 'Perl modules have a newer release: ' . join( q{, }, map { "$_->{module} $_->{version} to $_->{latest}" } @old ) . q{.}, { label => 'Upgrade modules', act => 'deps/upgrade' } ) if @old;
    push @items, { level => 'warning', text => "The bot cannot tell whether its Perl modules are up to date: $check->{deps_error}" } if $check->{deps_error};
    my $tools = $check->{agent_deps} // {};
    my @why   = (
        ( @{ $tools->{missing}  // [] } ? 'The agent lacks these tools: ' . join( q{, }, @{ $tools->{missing} } ) . q{.}                                                                   : () ),
        ( @{ $tools->{outdated} // [] } ? 'Tools of the agent have a newer release: ' . join( q{, }, map { "$_->{module} $_->{version} to $_->{latest}" } @{ $tools->{outdated} } ) . q{.} : () ),
    );
    push @items, button_item( $minion, 'deps_upgrade', join( q{ }, @why ), { label => 'Install tools', act => 'deps/upgrade' } ) if @why;
    push @items, { level => 'warning', text => "The bot cannot tell whether the tools of the agent are up to date: $check->{agent_deps_error}" } if $check->{agent_deps_error};
    return @items;
}

=func button_item

C<($minion, $task, $text, \%button)>.  A warning with C<$text>, and the button,
a C<{label, act}>, unless a job of C<$task> waits or runs.  Then it names that
job, and has no button.  The same goes for a L<App::Clod::Tasks/self_check>,
which the job queues when it finishes, because C<$text> comes from the check
before it.

=cut

sub button_item ( $minion, $task, $text, $button ) {
    if ( my $pending = pending_job( $minion, $task ) ) {
        return { level => 'warning', job => $pending, text => "$text It is queued." };
    }
    if ( my $check = pending_job( $minion, 'self_check' ) ) {
        return { level => 'warning', job => $check, text => "$text A new check is queued." };
    }
    return { level => 'warning', text => $text, buttons => [$button] };
}

=func pending_job

C<($minion, $task)>.  The id of a job of C<$task> that waits or runs, or
undef.

=cut

sub pending_job ( $minion, $task ) {
    my $job = $minion->jobs( { tasks => [$task], states => [qw{inactive active}] } )->next // return;
    return $job->{id};
}

=method self_update

Queues an L<App::Clod::Tasks/self_update>, unless one waits or runs, and says
which.

=cut

sub self_update ($self) {
    my $minion = $self->minion;
    return $self->render( json => { queued => pending_job( $minion, 'self_update' ) // $minion->enqueue('self_update') } );
}

=method plugin_update

Queues an L<App::Clod::Tasks/plugin_update>, unless one waits or runs, and says
which.

=cut

sub plugin_update ($self) {
    my $minion = $self->minion;
    return $self->render( json => { queued => pending_job( $minion, 'plugin_update' ) // $minion->enqueue('plugin_update') } );
}

=method deps_upgrade

Queues an L<App::Clod::Tasks/deps_upgrade>, unless one waits or runs, and says
which.

=cut

sub deps_upgrade ($self) {
    my $minion = $self->minion;
    return $self->render( json => { queued => pending_job( $minion, 'deps_upgrade' ) // $minion->enqueue('deps_upgrade') } );
}

=func pending_harness_fix

C<($minion, $repo)>.  The id of a L<App::Clod::Tasks/harness_fix> of C<$repo>
that waits or runs, or undef.

=cut

sub pending_harness_fix ( $minion, $repo ) {
    my $jobs = $minion->jobs( { tasks => ['harness_fix'], states => [qw{inactive active}] } );
    while ( my $info = $jobs->next ) {
        return $info->{id} if ( $info->{notes}{repo} // q{} ) eq $repo;
    }
    return;
}

=func harness_pull

C<($minion, $repo, $scan)>, with C<$scan> the result of the last harness scan.
The URL of the open pull request of a harness fix of C<$repo>: the one that a
L<App::Clod::Tasks/harness_fix> opened after that scan, or else the
C<fix_pr> that the scan found.  Undef when there is none, which is also the
case once the scan finds that one that it saw is closed.

=cut

sub harness_pull ( $minion, $repo, $scan ) {
    my $jobs = $minion->jobs( { tasks => ['harness_fix'], states => ['finished'] } );
    while ( my $info = $jobs->next ) {
        next if ( $info->{notes}{repo} // q{} ) ne $repo;
        last if ( $info->{finished}    // 0 ) < ( $scan->{checked_at} // 0 );
        my $url = ( ref $info->{result} eq 'HASH' ? $info->{result} : {} )->{pr_url} // next;
        return $url;
    }
    return ( $scan->{repos}{$repo} // {} )->{fix_pr};
}

=func pull_label

C<($url)>.  The label of a link to a pull request: C<#12> for its number.

=cut

sub pull_label ($url) {
    my ($number) = $url =~ m{/pull/(\d+)\z};
    return defined $number ? "#$number" : $url;
}

=method retry

Retries the failed job C<id>.  A job that is not there, or did not fail, is a
404.

=cut

sub retry ($self) {
    my $job = $self->failed_job // return;
    $job->retry;
    return $self->render( json => { retried => $job->id } );
}

=method ignore

Marks the failed job C<id> as ignored, with the note C<ignored>, the time.  It
stays in Minion, and stops being an action item.

=cut

sub ignore ($self) {
    my $job = $self->failed_job // return;
    $job->note( ignored => time );
    return $self->render( json => { ignored => $job->id } );
}

=method failed_job

The failed job of the C<id> of the route.  If there is none, it renders a 404
and returns undef.

=cut

sub failed_job ($self) {
    my $job = $self->minion->job( $self->param('id') );
    return $job if $job && $job->info->{state} eq 'failed';
    $self->render( json => { error => 'there is no failed job ' . $self->param('id') }, status => 404 );
    return;
}

=method harness_fix

Queues a L<App::Clod::Tasks/harness_fix> of the C<repo> of the JSON body, with
its failing checks from the last harness scan, and C<by>, the
L<App::Clod/viewer> who pressed the button.  A spoke that fails no check is
a 404.  If one waits or runs already, it queues no second one, and says which.

=cut

sub harness_fix ($self) {
    my $minion  = $self->minion;
    my $repo    = ( $self->req->json // {} )->{repo}                       // q{};
    my $scan    = App::Clod::Tasks::last_result( $minion, 'harness_scan' ) // {};
    my @failing = map { { check => $_->{check}, detail => $_->{detail} } } grep { $_->{status} eq 'fail' } @{ ( $scan->{repos}{$repo} // {} )->{checks} // [] };
    return $self->render( json => { error => "$repo fails no harness check" }, status => 404 ) if !@failing;
    my $id = pending_harness_fix( $minion, $repo ) // $minion->enqueue( harness_fix => [ { repo => $repo, checks => \@failing, by => $self->viewer } ], { notes => { repo => $repo } } );
    return $self->render( json => { queued => $id } );
}

=method work

The last hundred items, each with its child jobs, and the issues assigned to
the bot, marked with whether a job has them.

=cut

sub work ($self) {
    my $minion = $self->minion;
    my $config = $self->clod_config;
    my ( @items, %has_job );
    my $jobs = $minion->jobs( { tasks => \@ITEM_TASKS } );
    while ( my $info = $jobs->next ) {
        last if @items >= 100;
        my $item = $info->{args}[0] // {};
        $has_job{"$item->{repo}#$item->{number}"} = 1 if $item->{repo};
        my @children = map { $self->child_job($_) } @{ $info->{notes}{children} // ( ref $info->{result} eq 'HASH' ? $info->{result}{children} : undef ) // [] };
        push @items,
          {
            id       => $info->{id},
            task     => $info->{task},
            state    => $info->{state},
            created  => $info->{created},
            finished => $info->{finished},
            kind     => $item->{kind},
            origin   => $item->{repo} ? App::Clod::Tasks::origin_of($item)             : undef,
            url      => $item->{repo} ? App::Clod::Tasks::origin_url( $config, $item ) : undef,
            title    => $item->{title},
            scope    => $info->{notes}{scope},
            reason   => ( $info->{notes}{triage} // {} )->{reason},
            children => \@children,
          };
    }
    my $sweep  = App::Clod::Tasks::last_result( $minion, 'assigned_sweep' ) // {};
    my @queued = map { +{ %$_, has_job => $has_job{"$_->{repo}#$_->{number}"} ? 1 : 0 } } @{ $sweep->{issues} // [] };
    return $self->render( json => { items => \@items, assigned => \@queued, swept_at => $sweep->{checked_at} } );
}

=method child_job

One child job of an item, as the Work tab shows it.  A C<create_repo> job
also has C<repo_url>, the repository that it made, and C<release_url>, the
issue for its first release.  A C<file_issues> job has C<issue_urls>, the
follow-up issues that it filed.

=cut

sub child_job ( $self, $id ) {
    my $job    = $self->minion->job($id) // return { id => $id, state => 'removed' };
    my $info   = $job->info;
    my $result = ref $info->{result} eq 'HASH' ? $info->{result} : {};
    return {
        id          => $id,
        task        => $info->{task},
        state       => $info->{state},
        repo        => $info->{notes}{repo},
        pr_url      => $result->{pr_url} // $result->{review_url},
        repo_url    => $result->{repo_url},
        release_url => $result->{release_url},
        issue_urls  => $result->{issues} // [],
        summary     => $result->{error}  // $result->{summary},
    };
}

=method harness

The result of the last harness scan.

=cut

sub harness ($self) {
    my $result = App::Clod::Tasks::last_result( $self->minion, 'harness_scan' );
    return $self->render( json => $result // { repos => {}, checks => [] } );
}

1;

=head1 DESCRIPTION

The controller behind F</> and F</api>.  Everything it shows comes from Minion:
the jobs of the items, and the results of the last C<harness_scan>,
C<assigned_sweep>, C<activity_sweep> and C<inbox_poll>.

=cut
