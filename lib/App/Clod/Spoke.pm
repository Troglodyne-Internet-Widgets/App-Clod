package App::Clod::Spoke;

# ABSTRACT: Clones, worktrees and pushes for one spoke repository

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Mojo::Base -base, -signatures;

use Carp       ();
use IPC::Run   ();
use Mojo::File ();
use Mojo::Util ();

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

has token => sub { $ENV{GH_TOKEN} // Carp::croak('GH_TOKEN is not set') };

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
    IPC::Run::run( [ 'git', @args ], '>', \$out, '2>', \$err, IPC::Run::timeout(600) )
      or Carp::croak("git @args: $err");
    chomp $out;
    return $out;
}

=method fetch

Clones the spoke if there is no bare clone yet, then fetches.  Returns the bare
clone.

=cut

# A bare clone, with remote-tracking refs so that worktrees can start from origin.
sub fetch ($self) {
    my $mirror = $self->mirror;
    if ( !-d $mirror ) {
        $mirror->dirname->make_path;
        $self->git( 'clone', '--bare', $self->github_web . '/' . $self->repo . '.git', "$mirror" );
        $self->git( q{-C}, "$mirror", qw{config remote.origin.fetch +refs/heads/*:refs/remotes/origin/*} );
    }
    $self->git( q{-C}, "$mirror", qw{config core.sharedRepository group} );
    $self->git( q{-C}, "$mirror", qw{fetch --prune origin} );
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
        chmod 0755, $installed or Carp::croak("chmod $installed: $!");
    }
    return;
}

=method refresh_reference

C<($branch)>.  Fetches, then resets the reference worktree to
C<origin/$branch>.  Returns it.

=cut

sub refresh_reference ( $self, $branch ) {
    my $mirror = $self->fetch;
    my $ref    = $self->reference;
    if ( !-d $ref ) {
        $ref->dirname->make_path;
        $self->git( q{-C}, "$mirror", qw{worktree add --detach}, "$ref", "origin/$branch" );
    }
    $self->git( q{-C}, "$ref", 'reset', '--hard', "origin/$branch" );
    return $ref;
}

=method worktree

C<($dir, %opt)>: C<< branch => ..., base => ... >> for a new branch,
C<< existing => $branch >> for a branch already on the remote,
C<< pull => $number >> for the head of a pull request, detached, or
C<< detach => $branch >> for a branch on the remote, detached, to read and to
run what is in it.

A C<detach> worktree gets no author and no hooks, because nothing commits in
it.  So making one writes nothing to the bare clone but the fetch and its own
worktree entry, and it holds no branch, so any number of them can be at one
branch at once.

=cut

sub worktree ( $self, $dir, %opt ) {
    my $mirror = $self->fetch;
    $dir = Mojo::File->new($dir);
    $dir->dirname->make_path;
    if ( defined $opt{detach} ) {
        $self->git( q{-C}, "$mirror", qw{worktree add --detach}, "$dir", "origin/$opt{detach}" );
        return $dir;
    }
    if ( $opt{pull} ) {
        $self->git( q{-C}, "$mirror", 'fetch',                   'origin', "+pull/$opt{pull}/head:refs/remotes/origin/pr/$opt{pull}" );
        $self->git( q{-C}, "$mirror", qw{worktree add --detach}, "$dir",   "origin/pr/$opt{pull}" );
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
C<--force-with-lease>, and returns the SHA it pushed.

=cut

sub push_branch ( $self, $dir, $branch ) {
    $self->git( q{-C}, "$dir", qw{push --force-with-lease origin}, "HEAD:refs/heads/$branch" );
    return $self->git( q{-C}, "$dir", 'rev-parse', 'HEAD' );
}

=method remove_worktree

C<($dir)>.  Removes the worktree, if it is there.

=cut

sub remove_worktree ( $self, $dir ) {
    return if !-d $dir;
    $self->git( q{-C}, $self->mirror->to_string, qw{worktree remove --force}, "$dir" );
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
