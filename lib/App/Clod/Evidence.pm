package App::Clod::Evidence;

# ABSTRACT: Keep what the claude runs of a job did, until the job turns out fine

use 5.040;
no autovivification;
use warnings FATAL => 'all';
use re '/aasx';
use Mojo::Base -base, -signatures;

use Fcntl       qw{O_WRONLY O_CREAT O_EXCL};
use Mojo::File  ();
use Mojo::JSON  ();
use Time::HiRes qw{time};

# What one user alone may read and write.
my $FILE_MODE = oct 600;

=attr root

The directory of the evidence of every job, C<evidence> of F<clod.conf>.

=cut

has 'root';

=attr job

The id of the job.

=cut

has 'job';

=attr attempt

Which attempt of the job this is, as C<retries> of L<Minion::Job> counts them:
0 for the first.

=cut

has attempt => 0;

=method dir

The directory of this attempt: F<root/job/attempt>.

=cut

sub dir ($self) { return Mojo::File->new( $self->root, $self->job, $self->attempt ) }

=method recorder

C<(%run)>.  Starts the transcript of one claude run of this attempt, and
returns a sub that appends one stream-json event to it.  The first line of
the file is C<< {at, run => \%run} >>, and each event after it is C<< {at,
event} >>, where C<at> is the epoch second when the event arrived.  So the
time between two lines is how long the step between them took.

The runs of an attempt are numbered from 1 in the order that they started,
in F<01.jsonl>, F<02.jsonl> and on.  The file is mode 0600, and L</root> is
made mode 0700, because a transcript holds what a tool printed.  The account
of the agent shares the group of the workspace, and must not read the
evidence.

=cut

sub recorder ( $self, %run ) {
    my $root = Mojo::File->new( $self->root )->make_path;
    chmod 0700, "$root" or die "chmod $root: $!\n";
    my $dir  = $self->dir->make_path;
    my $file = $dir->child( sprintf '%02d.jsonl', $dir->list->size + 1 );
    sysopen my $fh, "$file", O_WRONLY | O_CREAT | O_EXCL, $FILE_MODE or die "$file: $!\n";
    $fh->autoflush(1);
    my $write = sub ($line) { print {$fh} Mojo::JSON::encode_json( { at => time, %$line } ) . "\n" or die "$file: $!\n" };
    $write->( { run => \%run } );
    return sub ($event) { $write->( { event => $event } ) };
}

=method runs

The transcripts of this attempt, oldest first, each the list of its lines as
L</recorder> wrote them.  Empty when the attempt kept none.

=cut

sub runs ($self) {
    my $dir = $self->dir;
    return [] if !-d $dir;
    return [
        map {
            [ map { Mojo::JSON::decode_json($_) } split m{\n}, $_->slurp ]
        } sort { $a cmp $b } $dir->list->grep(qr{[.]jsonl\z})->each
    ];
}

=method attempts

The attempts of L</job> that kept evidence, as numbers, lowest first.  This
ignores L</attempt>.

=cut

sub attempts ($self) {
    my $job = Mojo::File->new( $self->root, $self->job );
    return [] if !-d $job;
    return [ sort { $a <=> $b } grep { m{\A\d+\z} } map { $_->basename } $job->list( { dir => 1 } )->grep( sub { -d $_ } )->each ];
}

=method discard

Removes the transcripts of this attempt, and the directory of the job when no
other attempt kept any.

=cut

sub discard ($self) {
    my $dir = $self->dir;
    $dir->remove_tree if -d $dir;
    my $job = $dir->dirname;
    rmdir "$job" if -d $job && !$job->list( { dir => 1, hidden => 1 } )->size;
    return;
}

=method prune

C<($seconds)>.  Removes the evidence of each job that no run added to for
C<$seconds>, by the modification time of its directory.  Returns the ids of
the jobs whose evidence it removed.

=cut

sub prune ( $self, $seconds ) {
    my $root = Mojo::File->new( $self->root );
    return [] if !-d $root;
    my $before = time - $seconds;
    my @old    = grep { $_->stat->mtime < $before } $root->list( { dir => 1 } )->grep( sub { -d $_ } )->each;
    $_->remove_tree for @old;
    return [ map { $_->basename } @old ];
}

1;

=head1 SYNOPSIS

    use App::Clod::Evidence ();

    my $evidence = App::Clod::Evidence->new( root => $config->{evidence}, job => $job->id, attempt => $job->retries );
    my $record   = $evidence->recorder( prompt => $prompt );
    $record->($_) for @events;

    $evidence->discard if $the_job_turned_out_fine;

=head1 DESCRIPTION

A failed job keeps only what its task put in the result: the summary of the
run, the calls that claude refused, and the cost.  That does not say what the
run did.  So each claude run writes its stream-json transcript here while it
runs, under the job and the attempt, and L<App::Clod::Tasks/perform> discards
it once the job finished with nothing in its way.

The transcript holds what telemetry does not: the text of the model, and the
whole result of each tool call.  Every attempt keeps its own, because what
changed from one attempt to the next is often the finding.

=cut
