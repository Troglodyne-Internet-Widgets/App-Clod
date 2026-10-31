package App::Clod::Controller::Dashboard;

# ABSTRACT: The health page and the JSON behind it

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Time::HiRes qw{time};

use App::Clod::Budget();
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

Item counts by state, the Minion stats, the budget, the outages, and the action items.

=cut

sub overview ($self) {
    my $minion = $self->minion;
    my $budget = App::Clod::Budget::summary($minion);
    my %counts;
    for my $state (qw{inactive active failed}) {
        $counts{$state} = $minion->jobs( { tasks => \@ITEM_TASKS, states => [$state] } )->total;
    }
    my $outages = App::Clod::Outage::summary($minion);
    return $self->render( json => { stats => $minion->stats, items => \%counts, budget => $budget, outages => $outages, actions => $self->action_items( $budget, $outages ) } );
}

=method action_items

C<($budget, $outages)>, from L<App::Clod::Budget/summary> and
L<App::Clod::Outage/summary>.  The things that need a person, each a
C<{level, text}> and sometimes a C<job>.  An outage comes first.

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
            push @actions, { level => 'warning', text => "$repo fails " . scalar(@failing) . ' harness check(s): ' . join( q{, }, map { $_->{check} } @failing ) . q{.} } if @failing;
        }
        push @actions, { level => 'danger', text => "Harness scan of $_ failed: $harness->{errors}{$_}" } for sort keys %{ $harness->{errors} // {} };
    }

    my $inbox = App::Clod::Tasks::last_result( $minion, 'inbox_poll' );

    # During a GitHub outage, the outage says why the inbox is not read.
    if ( !$out{github} && ( !$inbox || time - ( $inbox->{polled_at} // 0 ) > $STALE_INBOX ) ) {
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

    push @actions, { level => 'warning', text => 'Claude work is paused until the quota resets' . ( $budget->{paused_until} ? q{ at } . gmtime( $budget->{paused_until} ) . ' UTC' : q{} ) . q{.} } if $budget->{paused};

    my $failed = $minion->jobs( { states => ['failed'] } );
    my $shown  = 0;
    while ( my $info = $failed->next ) {
        last if ++$shown > 10;
        my $error = ref $info->{result} eq 'HASH' ? $info->{result}{error} : $info->{result};
        push @actions, { level => 'danger', job => $info->{id}, text => "Job $info->{id} ($info->{task}" . ( $info->{notes}{origin} ? " for $info->{notes}{origin}" : q{} ) . ') failed: ' . substr( $error // 'no reason given', 0, 300 ) };
    }
    return \@actions;
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

One child job of an item, as the Work tab shows it.

=cut

sub child_job ( $self, $id ) {
    my $job    = $self->minion->job($id) // return { id => $id, state => 'removed' };
    my $info   = $job->info;
    my $result = ref $info->{result} eq 'HASH' ? $info->{result} : {};
    return {
        id      => $id,
        task    => $info->{task},
        state   => $info->{state},
        repo    => $info->{notes}{repo},
        pr_url  => $result->{pr_url} // $result->{review_url},
        summary => $result->{error}  // $result->{summary},
    };
}

=method harness

The result of the last harness scan.

=cut

sub harness ($self) {
    my $result = App::Clod::Tasks::last_result( $self->minion, 'harness_scan' );
    return $self->render( json => $result // { repos => {}, checks => [] } );
}

=head1 DESCRIPTION

The controller behind F</> and F</api>.  Everything it shows comes from Minion:
the jobs of the items, and the results of the last C<harness_scan>,
C<assigned_sweep> and C<inbox_poll>.

=cut
