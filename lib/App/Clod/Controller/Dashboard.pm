package App::Clod::Controller::Dashboard;

# ABSTRACT: The health page and the JSON behind it

use 5.040;
no autovivification;
use warnings FATAL => 'all';
use re '/aasx';
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Digest::SHA ();
use Time::HiRes qw{time};

use Dist::Conformance::Check::SystemPackages();

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
C<{level, text}> and sometimes a C<job>.  The page filters them by C<level>
in the browser, so the server sends all of them.  An outage comes first.  An item that
a button can settle has C<buttons>, each a C<{label, act}> and sometimes a
C<body>: the dashboard posts C<body> to F</act/E<lt>actE<gt>>.  A button with
C<confirm> opens a dialog first, see L</waiting_items>.  A failed job
has Retry and Ignore, and a spoke that fails harness checks has Fix, unless a
fix of it waits or runs, as L</harness_job> finds it, or its pull request
waits for review.  Then the item has C<link>, a C<{url, label}>, to the pull
request, and no button.  A spoke whose declaration of system packages is not
valid is an item, as a scan that failed is.  A pull request whose branch
needs system packages that the host lacks is an item of L</waiting_items>.
When a pull request of the last L<App::Clod::Tasks/upstream_sweep> conflicts
with its base, one item counts them, with a C<link> to F<#upstream>, the
Upstream tab.  When the last L<App::Clod::Tasks/release_sweep> found
distributions whose work is not all on CPAN, one item counts them, with a
C<link> to F<#releases>, the Releases tab, and each spoke whose check failed
is an item.
A failed job that somebody ignored is not an item.

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
            my $fixer = harness_job( $minion, $repo );
            my $pull  = !$fixer && harness_pull( $minion, $repo, $harness );
            push @actions,
                $fixer ? { level => 'warning', job => $fixer, text => "$text A harness fix of it is queued." }
              : $pull  ? { level => 'warning', text => "$text A fix waits for review:", link => { url => $pull, label => pull_label($pull) } }
              :          { level => 'warning', text => $text, buttons => [ { label => 'Fix', act => 'harness/fix', body => { repo => $repo } } ] };
        }
        push @actions, { level => 'danger', text => "Harness scan of $_ failed: $harness->{errors}{$_}" }                                                       for sort keys %{ $harness->{errors}                // {} };
        push @actions, { level => 'danger', text => "Harness scan of $_ cannot read the system packages that it needs: $harness->{system_package_errors}{$_}" } for sort keys %{ $harness->{system_package_errors} // {} };
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

    my $activity = App::Clod::Tasks::last_result( $minion, 'activity_sweep' ) // {};
    push @actions, { level => 'warning', text => "The counts of issues and pull requests leave out the spokes of $_, because their search failed: $activity->{errors}{$_}" } for sort keys %{ $activity->{errors} // {} };

    my $upstream  = App::Clod::Tasks::last_result( $minion, 'upstream_sweep' ) // {};
    my $conflicts = grep { ( $_->{mergeable} // q{} ) eq 'CONFLICTING' } @{ $upstream->{pulls} // [] };
    push @actions, { level => 'warning', text => ( $conflicts == 1 ? '1 upstream PR conflicts with its base, and needs' : "$conflicts upstream PRs conflict with their base, and need" ) . ' a rebase:', link => { url => '#upstream', label => 'Upstream' } } if $conflicts;

    my $releases = App::Clod::Tasks::last_result( $minion, 'release_sweep' ) // {};
    my $due      = @{ $releases->{dists} // [] };
    push @actions, { level => 'info', text => ( $due == 1 ? '1 distribution has' : "$due distributions have" ) . ' work that is not on CPAN:', link => { url => '#releases', label => 'Releases' } } if $due;
    push @actions, { level => 'warning', text => "The release check of $_ failed, so the Releases tab keeps what the sweep before found for it: $releases->{errors}{$_}" } for sort keys %{ $releases->{errors} // {} };

    push @actions, { level => 'warning', text => 'Claude work is paused until the quota resets' . ( $budget->{paused_until} ? q{ at } . gmtime( $budget->{paused_until} ) . ' UTC' : q{} ) . q{.} } if $budget->{paused};

    push @actions, $self->self_items( $minion, App::Clod::Tasks::last_result( $minion, 'self_check' ) );
    push @actions, waiting_items($minion);

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
in C<agent_lib>, with an Install tools button, and each spoke that declares
system packages that the host lacks, with an Install packages button, and,
with no button, each spoke that declares no package of this host for a
dependency, and each test of a dependency that fails, with all of the
packages of its spoke there.  While a job for a button waits or runs, the item names it, and has
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
    my $packages = $check->{system_packages}                                   // {};
    my $packager = ( $self->clod_config->{system_packages} // {} )->{packager} // 'system';
    my $host     = join( q{ }, grep { defined } @{ $check->{system_host} // {} }{qw{distro release}} ) || 'this host';
    for my $repo ( sort keys %$packages ) {
        my $lacks      = $packages->{$repo};
        my @needs      = @{ $lacks->{needs}      // [] };
        my @unresolved = @{ $lacks->{unresolved} // [] };
        push @items, button_item( $minion, 'packages_install', "$repo needs " . needed(@needs) . q{.}, { label => 'Install packages', act => 'packages/install', body => { repo => $repo } }, $repo ) if @needs;
        push @items, { level => 'danger',  text => "$repo needs " . listed(@unresolved) . ", and declares no $packager package for " . ( @unresolved > 1 ? 'them' : 'it' ) . " on $host." } if @unresolved;
        push @items, { level => 'warning', text => "The bot cannot tell what $repo needs on this host: $lacks->{error}" }                                                                   if $lacks->{error};
        push @items, map { { level => 'warning', text => "$_->{program} fails, and $repo needs it for $_->{dependency}: " . substr( $_->{error}, 0, 300 ) } } @{ $lacks->{failing} // [] };
    }
    push @items, { level => 'warning', text => "The bot cannot tell whether it has the system packages of the spokes: $check->{system_packages_error}" } if $check->{system_packages_error};
    return @items;
}

=func listed

C<(@words)>.  The words as a list in a sentence: C<a>, C<a and b>, or
C<a, b and c>.

=cut

sub listed (@words) {
    my $last = pop @words;
    return @words ? join( q{, }, @words ) . " and $last" : $last;
}

=func needed

C<(@needs)>, the C<needs> of a spoke from L<App::Clod::Tasks/host_packages>.
Each dependency with its package, and the archive that an install adds for
it, with the fingerprint of its key, shortened, as in
C<libxml2 (libxml2-dev) and ffmpeg (ffmpeg, from the archive jellyfin, key 0123...4567)>,
so that the person who presses the button sees whom it gives the trust of
root.

=cut

sub needed (@needs) {
    return listed(
        map {
            my $archive = $_->{archive};
            my $key     = $archive ? $archive->{fingerprint} // q{} : q{};
            "$_->{name} ($_->{package}" . ( $archive ? ", from the archive $archive->{name}, key " . substr( $key, 0, 4 ) . "\N{HORIZONTAL ELLIPSIS}" . substr( $key, -4 ) : q{} ) . ')';
        } @needs
    );
}

=func button_item

C<($minion, $task, $text, \%button, $repo)>.  A warning with C<$text>, and the
button, a C<{label, act}>, unless a job of C<$task> waits or runs, of C<$repo>
when it is given, as L</pending_job> finds it.  Then it names that job, and has
no button.  The same goes for a L<App::Clod::Tasks/self_check>,
which the job queues when it finishes, because C<$text> comes from the check
before it.

=cut

sub button_item ( $minion, $task, $text, $button, $repo = undef ) {
    if ( my $pending = pending_job( $minion, $task, $repo ) ) {
        return { level => 'warning', job => $pending, text => "$text It is queued." };
    }
    if ( my $check = pending_job( $minion, 'self_check' ) ) {
        return { level => 'warning', job => $check, text => "$text A new check is queued." };
    }
    return { level => 'warning', text => $text, buttons => [$button] };
}

=func pending_job

C<($minion, $task, $repo, $note)>.  The id of a job of C<$task> that waits or
runs, or undef.  With C<$repo>, only a job with that value in its notes counts:
in the note C<$note>, which is C<repo> unless it is given.

=cut

sub pending_job ( $minion, $task, $repo = undef, $note = 'repo' ) {
    my $jobs = $minion->jobs( { tasks => [$task], states => [qw{inactive active}] } );
    while ( my $info = $jobs->next ) {
        return $info->{id} if !defined $repo || ( $info->{notes}{$note} // q{} ) eq $repo;
    }
    return;
}

=func harness_job

C<($minion, $repo)>.  The id of a job that brings C<$repo> to the harness
standards and waits or runs: a L<App::Clod::Tasks/harness_fix>, or the claude
run that it queued for what the update left for a person, which has the note
C<harness>.  Undef when there is none.

=cut

sub harness_job ( $minion, $repo ) {
    return pending_job( $minion, 'harness_fix', $repo ) // pending_job( $minion, 'spoke_fix', $repo, 'harness' ) // pending_job( $minion, 'spoke_address', $repo, 'harness' );
}

=func waiting_items

C<($minion)>.  An action item for each pull request whose branch needs system
packages that the host lacks, as the result of a
L<App::Clod::Tasks/spoke_fix> or L<App::Clod::Tasks/spoke_address> says,
from L<App::Clod::Tasks/waits_for_packages>.  Only the newest finished job of
each pull request counts, so a later run that needs nothing clears the item.
A job that somebody ignored is not an item.

The item has two buttons.  Install and resume posts the job to
F</act/packages/install>, and carries C<confirm>, which the page shows in a
dialog before it posts: C<pr_url>, C<diff_url>, the change to
F<metamerge.yml> in the diff of the pull request, C<packages>, and
C<sources>, each with C<name>, C<uri>, C<key> and C<fingerprint>.  Ignore
takes the item off the list.

While an install for the job waits or runs, the item names it and has no
button.  After the install, the item names the job that resumes the work
while that job waits or runs, and then is gone.

=cut

my %PENDING = map { $_ => 1 } qw{inactive active};

sub waiting_items ($minion) {
    my $jobs = $minion->jobs( { tasks => [qw{spoke_fix spoke_address}], states => ['finished'] } );
    my ( %seen, @items );
    while ( my $info = $jobs->next ) {
        my $result = ref $info->{result} eq 'HASH' ? $info->{result} : next;
        my $url    = $result->{pr_url} // next;
        next if $seen{$url}++ || !$result->{needs_packages} || $info->{notes}{ignored};
        my $id   = $info->{id};
        my $text = "$result->{repo}#$result->{pr} needs " . needed( @{ $result->{needs} // [] } ) . ' to test its change.';
        if ( my $resumed = $info->{notes}{resumed} ) {
            my $next = $minion->job($resumed);
            push @items, { level => 'warning', job => $resumed, text => "$text The packages are installed, and the work resumes." } if $next && $PENDING{ $next->info->{state} };
            next;
        }
        if ( my $install = pending_job( $minion, 'packages_install', $id, 'resume' ) ) {
            push @items, { level => 'warning', job => $install, text => "$text It is queued." };
            next;
        }
        my %confirm = (
            pr_url   => $url,
            diff_url => "$url/files#diff-" . Digest::SHA::sha256_hex($Dist::Conformance::Check::SystemPackages::FILE),
            packages => $result->{packages} // [],
            sources  => [ map { { name => $_->{name}, uri => $_->{uri}, key => $_->{key}, fingerprint => $_->{fingerprint} } } @{ $result->{sources} // [] } ],
        );
        push @items,
          {
            level   => 'warning',
            job     => $id,
            text    => $text,
            link    => { url => $url, label => pull_label($url) },
            buttons => [ { label => 'Install and resume', act => 'packages/install', body => { job => $id }, confirm => \%confirm }, { label => 'Ignore', act => "jobs/$id/ignore" } ],
          };
    }
    return @items;
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

Marks the job C<id> as ignored, with the note C<ignored>, the time.  It
stays in Minion, and stops being an action item.  The job must have failed, or
its branch must need system packages, as L</waiting_job> finds.  Any other job
is a 404.

=cut

sub ignore ($self) {
    my $id  = $self->param('id');
    my $job = waiting_job( $self->minion, $id ) ? $self->minion->job($id) : ( $self->failed_job // return );
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
a 404.  If a fix waits or runs already, as L</harness_job> finds it, it
queues no second one, and says which.

=cut

sub harness_fix ($self) {
    my $minion  = $self->minion;
    my $repo    = ( $self->req->json // {} )->{repo}                       // q{};
    my $scan    = App::Clod::Tasks::last_result( $minion, 'harness_scan' ) // {};
    my @failing = map { { check => $_->{check}, detail => $_->{detail} } } grep { $_->{status} eq 'fail' } @{ ( $scan->{repos}{$repo} // {} )->{checks} // [] };
    return $self->render( json => { error => "$repo fails no harness check" }, status => 404 ) if !@failing;
    my $id = harness_job( $minion, $repo ) // $minion->enqueue( harness_fix => [ { repo => $repo, checks => \@failing, by => $self->viewer } ], { notes => { repo => $repo } } );
    return $self->render( json => { queued => $id } );
}

=method packages_install

Queues a L<App::Clod::Tasks/packages_install> for the C<repo> of the JSON
body, with the packages that the last L<App::Clod::Tasks/self_check> found
it missing, and the archives that they come from.  Nothing else of the body is read, so the button installs what a
spoke declares on its default branch, and no name that a request names.  A
spoke that misses no package is a 404.  If one waits or runs for it already,
it queues no second one, and says which.

With C<job> in the body in place of C<repo>, it is the button Install and
resume of L</waiting_items>.  Then the packages and the archives come from
the result of that job, which L</waiting_job> must find, and the install has
C<resume>, the job, as L<App::Clod::Tasks/packages_install> takes it.  Any
other job is a 404.  So the button installs what the hub read from the
branch of that job, and no name that a request names.  If an install for the
job waits or runs already, it queues no second one, and says which.

=cut

sub packages_install ($self) {
    my $minion = $self->minion;
    my $body   = $self->req->json // {};
    return $self->resume_install( $body->{job} ) if exists $body->{job};
    my $repo    = $body->{repo}                                          // q{};
    my $check   = App::Clod::Tasks::last_result( $minion, 'self_check' ) // {};
    my $lacks   = ( $check->{system_packages} // {} )->{$repo}           // {};
    my @missing = @{ $lacks->{missing} // [] };
    return $self->render( json => { error => "$repo misses no system package" }, status => 404 ) if !@missing;
    my $id = pending_job( $minion, 'packages_install', $repo ) // $minion->enqueue( packages_install => [ { repo => $repo, packages => \@missing, sources => $lacks->{sources} // [] } ], { notes => { repo => $repo } } );
    return $self->render( json => { queued => $id } );
}

=method resume_install

C<($id)>.  The part of L</packages_install> for C<job>: it queues the install
of the packages of job C<$id>, with C<resume>.

=cut

sub resume_install ( $self, $id ) {
    my $minion = $self->minion;
    my $info   = waiting_job( $minion, $id ) // return $self->render( json => { error => 'job ' . ( $id // q{} ) . ' waits for no system package' }, status => 404 );
    my $result = $info->{result};
    my $queued = pending_job( $minion, 'packages_install', $info->{id}, 'resume' ) // $minion->enqueue(
        packages_install => [ { repo => $result->{repo}, packages => $result->{packages}, sources => $result->{sources} // [], resume => $info->{id} } ],
        { notes => { resume => $info->{id}, origin => "$result->{repo}#$result->{pr}" } }
    );
    return $self->render( json => { queued => $queued } );
}

=func waiting_job

C<($minion, $id)>.  The info of the job C<$id> when it finished with a branch
that needs system packages, as L<App::Clod::Tasks/waits_for_packages> says,
and its work has not resumed.  Undef for any other job, and for an C<$id>
that is not a number.

=cut

sub waiting_job ( $minion, $id ) {
    return if ( $id // q{} ) !~ m{\A\d+\z};
    my $job    = $minion->job($id) // return;
    my $info   = $job->info;
    my $result = ref $info->{result} eq 'HASH' ? $info->{result} : return;
    return if $info->{state} ne 'finished' || !$result->{needs_packages} || !@{ $result->{packages} // [] } || $info->{notes}{resumed};
    return $info;
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

=method upstream

The result of the last L<App::Clod::Tasks/upstream_sweep>: the open pull
requests of the authorized users in repositories that are not ours.  Before
the first sweep, no pull request, no error, and no C<checked_at>.

=cut

sub upstream ($self) {
    my $result = App::Clod::Tasks::last_result( $self->minion, 'upstream_sweep' );
    return $self->render( json => $result // { pulls => [], errors => {} } );
}

=method releases

The result of the last L<App::Clod::Tasks/release_sweep>: the distributions
among the spokes whose work is not all on CPAN.  Before the first sweep, no
distribution, no error, and no C<checked_at>.

=cut

sub releases ($self) {
    my $result = App::Clod::Tasks::last_result( $self->minion, 'release_sweep' );
    return $self->render( json => $result // { dists => [], errors => {} } );
}

1;

=head1 DESCRIPTION

The controller behind F</> and F</api>.  Everything it shows comes from Minion:
the jobs of the items, and the results of the last C<harness_scan>, C<self_check>,
C<assigned_sweep>, C<activity_sweep>, C<upstream_sweep>, C<release_sweep> and
C<inbox_poll>.

=cut
