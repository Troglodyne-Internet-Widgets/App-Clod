package App::Clod::Spoke;

# ABSTRACT: Clones, worktrees and pushes for one spoke repository

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Mojo::Base -base, -signatures;

use IPC::Run     ();
use List::Util   ();
use Mojo::File   ();
use Mojo::Util   ();
use Mutex::Flock ();

use App::Clod::Retry ();

=attr repo

The spoke, as C<Owner/Name>.

=attr workspace

The directory that holds the clones and worktrees.

=cut

has [qw{repo workspace}];

=attr github_web

The base URL that clone URLs start with.

=cut

has github_web => 'https://github.com';

=attr token

The token that git sends to GitHub.  Default C<GH_TOKEN>.

=cut

has token => sub { $ENV{GH_TOKEN} // die "GH_TOKEN is not set\n" };

=attr author_email

=attr author_name

The name and address that commits in a worktree carry.

=cut

has [qw{author_name author_email}];

=method mirror

The bare clone, as a L<Mojo::File>.

=cut

sub mirror ($self) { return Mojo::File->new( $self->workspace, 'mirrors', $self->repo . '.git' ) }

=method reference

The worktree at the default branch, which triage reads.

=cut

sub reference ($self) { return Mojo::File->new( $self->workspace, 'ref', $self->repo ) }

=method git

Runs git with the arguments as a list and returns its output.  Dies with the
error output on failure.

=cut

sub git ( $self, @args ) {
    my $basic = Mojo::Util::b64_encode( 'x-access-token:' . $self->token, q{} );
    local $ENV{GIT_TERMINAL_PROMPT} = 0;
    local $ENV{GIT_CONFIG_COUNT}    = 1;
    local $ENV{GIT_CONFIG_KEY_0}    = 'http.' . $self->github_web . '/.extraheader';
    local $ENV{GIT_CONFIG_VALUE_0}  = "AUTHORIZATION: basic $basic";
    my ( $out, $err ) = ( q{}, q{} );
    my $ok = IPC::Run::run( [ 'git', @args ], '>', \$out, '2>', \$err, IPC::Run::timeout(600) );
    chomp $err;
    die "git @args: $err\n" if !$ok;
    chomp $out;
    return $out;
}

=method git_remote

Runs git as L</git> does, for a command that talks to GitHub, such as a fetch
or a push.  A failure that L</transient> calls a moment's trouble at GitHub
gets more tries, through L<App::Clod::Retry/attempt>.

=cut

sub git_remote ( $self, @args ) {
    return ( App::Clod::Retry::attempt( "git @args", \&transient, sub { $self->git(@args) } ) )[0];
}

=func transient

C<($error)>.  True if the error of a git command is a server error or a lost
connection.  A push gets the same tries: C<--force-with-lease> refuses a second
push over a branch that the first one did move.

=cut

my @TRANSIENT = (
    qr{Internal\ Server\ Error}, qr{Bad\ Gateway},              qr{Service\ Unavailable},   qr{Gateway\ Time-?out},
    qr{returned\ error:\ 5\d\d}, qr{Could\ not\ resolve\ host}, qr{Connection\ timed\ out}, qr{Connection\ reset},
    qr{Failed\ to\ connect},     qr{early\ EOF},                qr{unexpected\ disconnect}, qr{RPC\ failed},
);

sub transient ($error) {
    return List::Util::any { $error =~ $_ } @TRANSIENT;
}

=method fetch

Clones the spoke if there is no bare clone yet, then fetches.  Returns the bare
clone.  It holds L</locked> while it works, so two jobs never clone or fetch
one bare clone at once.

=cut

sub fetch ($self) {
    return $self->locked( sub { $self->fetch_unlocked } );
}

=method locked

C<($code)>.  Runs C<$code> and returns what it returns, while it holds an
exclusive lock of the bare clone: a lock of F<E<lt>bare cloneE<gt>.lock> beside
it, which every process that works on the clone takes.  A second job that
wants it waits until the first is done.  Without it, a job could see the
directory of a clone that another job had only begun, and fetch no
remote-tracking refs, and two fetches could refuse each other's ref locks.

A process must not take it twice, because the second lock waits for the first.
So L</fetch> and L</refresh_reference> take it, and call
L</fetch_unlocked>, which does not.  The lock is the C<synchronize> of
L<Mutex::Flock>, which lets go of it when C<$code> returns or dies.

=cut

sub locked ( $self, $code ) {
    my $mirror = $self->mirror;
    my $file   = $mirror->dirname->make_path->child( $mirror->basename . '.lock' );
    return Mutex::Flock->new( path => "$file" )->synchronize($code);
}

=method fetch_unlocked

What L</fetch> does, for a caller that holds L</locked> already.  It sets the
fetch refspec on every fetch, not only after the clone, so a clone whose first
fetch died gets its remote-tracking refs with the next one.

=cut

# A bare clone, with remote-tracking refs so that worktrees can start from origin.
sub fetch_unlocked ($self) {
    my $mirror = $self->mirror;
    if ( !-d $mirror ) {
        $mirror->dirname->make_path;
        $self->git_remote( 'clone', '--bare', $self->github_web . '/' . $self->repo . '.git', "$mirror" );
    }
    $self->git( q{-C}, "$mirror", qw{config remote.origin.fetch +refs/heads/*:refs/remotes/origin/*} );
    $self->git( q{-C}, "$mirror", qw{config core.sharedRepository group} );
    $self->git_remote( q{-C}, "$mirror", qw{fetch --prune origin} );
    return $mirror;
}

=method install_hooks

C<($tree)>.  Copies F<git-hooks/pre-commit> and F<git-hooks/post-commit> of
that checkout into the bare clone, where every worktree finds them.

=cut

# The hooks live in the shared git dir, so every worktree gets the repo's own.
sub install_hooks ( $self, $tree ) {
    my $hooks = $self->mirror->child('hooks')->make_path;
    for my $name (qw{pre-commit post-commit}) {
        my $hook = Mojo::File->new( $tree, 'git-hooks', $name );
        next if !-e $hook;
        my $installed = $hook->copy_to( $hooks->child($name) );
        chmod 0755, $installed or die "chmod $installed: $!\n";
    }
    return;
}

=method refresh_reference

C<($branch)>.  Fetches, then resets the reference worktree to
C<origin/$branch>, under L</locked>.  Returns it.  A reference whose directory
is gone is made again, after git forgets the worktree that it still has
registered there, which it would otherwise refuse to add a second time.

=cut

sub refresh_reference ( $self, $branch ) {
    return $self->locked(
        sub {
            my $mirror = $self->fetch_unlocked;
            my $ref    = $self->reference;
            if ( !-d $ref ) {
                $ref->dirname->make_path;
                $self->git( q{-C}, "$mirror", qw{worktree prune} );
                $self->git( q{-C}, "$mirror", qw{worktree add --detach}, "$ref", "origin/$branch" );
            }
            $self->git( q{-C}, "$ref", 'reset', '--hard', "origin/$branch" );
            return $ref;
        }
    );
}

=method worktree

C<($dir, %opt)>: C<< branch => ..., base => ... >> for a new branch,
C<< existing => $branch >> for a branch already on the remote,
C<< pull => $number >> for the head of a pull request, detached,
C<< detach => $branch >> for a branch on the remote, detached, to read and to
run what is in it, or C<< at => $commit >> for a commit of the bare clone,
detached, to push it.

A C<detach> or C<at> worktree gets no author and no hooks, because nothing
commits in it.  So making one writes nothing to the bare clone but the fetch and its own
worktree entry, and it holds no branch, so any number of them can be at one
branch at once.

=cut

sub worktree ( $self, $dir, %opt ) {
    my $mirror = $self->fetch;
    $dir = Mojo::File->new($dir);
    $dir->dirname->make_path;
    if ( defined $opt{detach} || defined $opt{at} ) {
        $self->git( q{-C}, "$mirror", qw{worktree add --detach}, "$dir", $opt{at} // "origin/$opt{detach}" );
        return $dir;
    }
    if ( $opt{pull} ) {
        $self->git_remote( q{-C}, "$mirror", 'fetch', 'origin', "+pull/$opt{pull}/head:refs/remotes/origin/pr/$opt{pull}" );
        $self->git( q{-C}, "$mirror", qw{worktree add --detach}, "$dir", "origin/pr/$opt{pull}" );
    }
    elsif ( $opt{existing} ) {
        $self->git( q{-C}, "$mirror", qw{worktree add -B}, $opt{existing}, "$dir", "origin/$opt{existing}" );
    }
    else {
        $self->git( q{-C}, "$mirror", qw{worktree add -B}, $opt{branch}, "$dir", "origin/$opt{base}" );
    }
    $self->git( q{-C}, "$dir", 'config', 'user.name',  $self->author_name )  if $self->author_name;
    $self->git( q{-C}, "$dir", 'config', 'user.email', $self->author_email ) if $self->author_email;
    $self->install_hooks($dir);
    return $dir;
}

=method commits_since

C<($dir, $base)>.  The number of commits in the worktree that C<$base> does not
have.

=cut

sub commits_since ( $self, $dir, $base ) {
    return 0 + $self->git( q{-C}, "$dir", 'rev-list', '--count', "$base..HEAD" );
}

=method push_branch

C<($dir, $branch)>.  Pushes the worktree HEAD to C<$branch> with
C<--force-with-lease>, and returns the SHA it pushed.  If the push fails but
the branch on GitHub is at HEAD anyway, the push is done: GitHub can answer a
server error to a push that it did take, and the lease then refuses the next
try.

=cut

sub push_branch ( $self, $dir, $branch ) {
    my $head = $self->git( q{-C}, "$dir", 'rev-parse', 'HEAD' );
    return $head if eval { $self->git_remote( q{-C}, "$dir", qw{push --force-with-lease origin}, "HEAD:refs/heads/$branch" ); 1 };
    my $error   = $@;
    my ($there) = split m{\s}, $self->git_remote( q{-C}, "$dir", qw{ls-remote origin}, "refs/heads/$branch" );
    die $error if ( $there // q{} ) ne $head;
    return $head;
}

=method remove_worktree

C<($dir)>.  Removes the worktree, if it is there.

=cut

sub remove_worktree ( $self, $dir ) {
    return if !-d $dir;
    $self->git( q{-C}, $self->mirror->to_string, qw{worktree remove --force}, "$dir" );
    return;
}

=method prune_worktrees

Forgets each worktree of the bare clone whose directory is gone.  Such a
worktree still holds its branch, so no other worktree can check it out.

=cut

sub prune_worktrees ($self) {
    $self->git( q{-C}, $self->mirror->to_string, qw{worktree prune} );
    return;
}

=head1 SYNOPSIS

    use 5.040;
    use App::Clod::Spoke;

    my $dir   = '/var/lib/clod';
    my $spoke = App::Clod::Spoke->new( repo => 'Owner/Name', workspace => $dir );
    my $tree  = $spoke->worktree( "$dir/work/42/Owner/Name", branch => 'clod/42-fix', base => 'main' );
    $spoke->push_branch( $tree, 'clod/42-fix' ) if $spoke->commits_since( $tree, 'origin/main' );
    $spoke->remove_worktree($tree);

=head1 DESCRIPTION

Each spoke has one bare clone under F<mirrors/> in the workspace, and a
worktree for each job that changes it.  A second worktree under F<ref/> follows
the default branch, so that triage can read every spoke.

It runs the git program through L<IPC::Run>, with a timeout, rather than a
library.  L<Git::Raw> builds a bundled copy of an old libgit2 rather than the
one on the host, and L<Git::Repository> can wait on a stalled fetch or push
forever.  The claude run in the same worktree uses the git program too.

The token goes to git as an HTTP header through C<GIT_CONFIG_*> variables.  It
is never in a remote URL or in the clone's configuration.

The repository's own F<git-hooks/pre-commit> and F<git-hooks/post-commit> are
installed into the bare clone, so a commit in any worktree runs them.

Each fetch sets C<core.sharedRepository> to C<group> in the bare clone, so git
makes what it writes there writable by the group.  That is for
L<App::Clod::Claude/run_as>: claude commits as another account, into the bare
clone of the worker, and the worker then pushes and removes the worktree.  It
also needs three things that this module cannot do:

=over

=item * The workspace belongs to a group of both accounts, and has the setgid
bit, so that everything in it gets that group.

=item * The worker and claude run with the umask C<0007>, so that the files of
a worktree are writable by the group too.  sudo combines its own umask with
the umask of the worker, so sudo needs C<umask=0007> as well.

=item * The gitconfig of the other account names the worktrees in
C<safe.directory>, because git refuses to work in a repository that another
account owns.

=back

=cut
