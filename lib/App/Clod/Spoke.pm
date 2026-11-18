package App::Clod::Spoke;

# ABSTRACT: Clones, worktrees and pushes for one spoke repository

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Mojo::Base -base, -signatures;

use Fcntl        qw{S_ISVTX S_IWGRP S_IWOTH};
use IPC::Run     ();
use List::Util   ();
use Mojo::File   ();
use Mojo::Util   ();
use Mutex::Flock ();
use POSIX        ();

use App::Clod::Retry ();

# git finds no hook under /dev/null, which is not a directory.
our @NO_HOOKS = ( q{-c}, 'core.hooksPath=/dev/null' );

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

=attr as_agent

A code ref that takes a command, as a list, and returns the list that runs it
as the account that claude runs as, such as L<App::Clod::Claude/as_account>.
Default undef: the worker runs every git command.  See L</THE AGENT ACCOUNT>.

=cut

has 'as_agent';

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
error output on failure.  When the arguments start with C<-C $dir>, git trusts
C<$dir> as L</trust> says, after L</guard> finds that the agent cannot change
how git there is configured.  git runs no hook, as L</HOOKS> says; L</commit>
is the one command of the worker that runs them.

=cut

sub git ( $self, @args ) {
    my $basic = Mojo::Util::b64_encode( 'x-access-token:' . $self->token, q{} );
    local $ENV{GIT_TERMINAL_PROMPT} = 0;
    local $ENV{GIT_CONFIG_COUNT}    = 1;
    local $ENV{GIT_CONFIG_KEY_0}    = 'http.' . $self->github_web . '/.extraheader';
    local $ENV{GIT_CONFIG_VALUE_0}  = "AUTHORIZATION: basic $basic";
    guard(@args);
    return run_git( [ 'git', trust(@args), @NO_HOOKS, @args ], \undef, @args );
}

=method git_as_owner

C<($dir, \$input, @args)>.  Runs git as L</git> does, with C<$input> on its
standard input, as the account that owns C<$dir>: the account of L</as_agent>
when the worker does not own it, and the worker otherwise.  An undef C<$dir>
means the account of L</as_agent>.  So a worktree that the agent made is
changed and removed by the agent, which owns each file in it.  With no
L</as_agent>, the worker runs it.  It gets no token, because sudo passes on no
variable that L</as_agent> does not name, so it is for a command that does not
talk to GitHub.  git runs no hook, as for L</git>, and when the worker runs it,
L</guard> looks at the directory first, as for L</git>.

=cut

sub git_as_owner ( $self, $dir, $input, @args ) {
    my $as  = $self->as_agent;
    my @git = ( 'git', trust(@args), @NO_HOOKS, @args );
    return run_git( [ $as->(@git) ], $input, @args ) if $as && !( defined $dir && is_own($dir) );
    guard(@args);
    return run_git( \@git, $input, @args );
}

=func commit

C<($dir, @args)>.  Runs C<git commit @args> in the worktree C<$dir> as the
worker, with the hooks of that worktree, and returns its output.  Dies as
L</git> does, with an error that names C<-C $dir commit @args>.  git gets no
token header, as L</git> gives it, so neither do the hooks; they do get the
environment of the worker.  It is for a worktree that the worker made and no
claude run has worked in, because the hooks are the files of its branch.  So
it dies, as L</guard> does, also when the agent could change F<git-hooks/> of
the worktree or a file in it.  See L</HOOKS>.

=cut

sub commit ( $dir, @args ) {
    my @shown = ( q{-C}, "$dir", 'commit', @args );
    guard(@shown);
    my $hooks = Mojo::File->new( $dir, 'git-hooks' );
    if ( -d $hooks ) {
        for my $path ( $hooks, $hooks->list->each ) {
            my $why = exposed( $path->realpath ) // next;
            die "git @shown: refused, because $why\n";
        }
    }
    return run_git( [ 'git', trust(@shown), @shown ], \undef, @shown );
}

=func is_own

C<($path)>.  True when the worker owns C<$path>, or when it is not there.

=cut

sub is_own ($path) {
    my @stat = stat $path;
    return !@stat || $stat[4] == $>;
}

=func trust

C<(@args)>.  The arguments that make git trust the directory of C<-C>, when
C<@args> start with C<-C $dir>: C<-c safe.directory=$dir>, with the real path
of C<$dir>, because git compares the real path.  Empty otherwise.  git refuses
to work in a repository that another account owns, and the bare clone and a
worktree can each belong to the other account.  See L</THE AGENT ACCOUNT>.

=cut

sub trust (@args) {
    return () if @args < 2 || $args[0] ne q{-C};
    my $real = eval { Mojo::File->new( $args[1] )->realpath->to_string } // return ();
    return ( q{-c}, "safe.directory=$real" );
}

=func guard

C<(@args)>.  When C<@args> start with C<-C $dir>, dies with the arguments and
the reason unless each file of L</control_files> of C<$dir> is safe from the
agent, as L</exposed> says.  Returns nothing.  See L</THE AGENT ACCOUNT>.

=cut

sub guard (@args) {
    return if @args < 2 || $args[0] ne q{-C};
    for my $path ( control_files( $args[1] ) ) {
        my $why = exposed($path) // next;
        die "git @args: refused, because $why\n";
    }
    return;
}

=func control_files

C<($dir)>.  The files that decide which configuration git reads in C<$dir>,
as L<Mojo::File> objects with their real paths: the F<.git> file of a
worktree, the git directory that it names, the F<commondir> file in that
directory, the common directory that it names, and the F<config> in it.  For a
bare clone, or a checkout whose F<.git> is a directory, the git directory is
the common directory.  Dies when C<$dir> is neither a worktree nor a git
directory, because git would then look for a repository above it.

F<config.worktree> is not among them, because git reads it only when
C<extensions.worktreeConfig> is on in F<config>.

=cut

sub control_files ($dir) {
    my $top = Mojo::File->new($dir)->realpath;
    my $dot = $top->child('.git');
    my @files;
    my $gitdir;
    if    ( -d $dot ) { $gitdir = $dot }
    elsif ( -e $dot ) {
        push @files, $dot;
        $gitdir = named( $top, $dot, qr{\Agitdir:\ ([^\n]+)} );
    }
    elsif ( -e $top->child('HEAD') ) { $gitdir = $top }
    else                             { die "$dir is not a git repository\n" }
    my $common = $gitdir;
    my $link   = $gitdir->child('commondir');
    if ( -e $link ) {
        push @files, $link;
        $common = named( $gitdir, $link, qr{\A([^\n]+)} );
    }
    my $config = $common->child('config');
    return ( @files, $gitdir, $common, -e $config ? $config : () );
}

# The real path of the directory that $file names, by its content, relative to $base.
sub named ( $base, $file, $re ) {
    my ($to) = $file->slurp =~ $re or die "$file names no directory\n";
    my $path = Mojo::File->new($to);
    return ( $path->is_abs ? $path : $base->child($to) )->realpath;
}

=func exposed

C<($path)>.  Why an account other than the worker could change C<$path>, the
real path of a file or a directory, or undef if it cannot.  It can when it
could write C<$path> or a directory above it, all the way up to F</>, which
would let it put another file in its place.  A file or a directory is writable
here when another account than the worker or root owns it, when every account
can write it, or when its group can and that group is not the primary group of
the worker: the agent shares a group with the worker, which owns the
workspace, and never the primary group of the worker.  A directory above
C<$path> with the sticky bit is safe, because it lets no account rename or
remove what the worker owns in it, and the next directory down must be the
worker's.  C<$path> itself does not get that, because an account that can make
a file in a git directory can make F<commondir> there.

=cut

sub exposed ($path) {
    my $why = writable( $path, 0 );
    return $why if defined $why;
    my $up = Mojo::File->new($path);
    while ( "$up" ne q{/} ) {
        $up  = $up->dirname;
        $why = writable( $up, 1 );
        return $why if defined $why;
    }
    return;
}

# Why the agent could write $path, as exposed says, or undef.  $above is true
# for a directory above the file that git reads.
sub writable ( $path, $above ) {
    my ( $mode, $uid, $gid ) = ( stat $path )[ 2, 4, 5 ];
    return "$path is not there"              if !defined $mode;
    return "another account owns $path"      if $uid != $> && $uid != 0;
    return                                   if $above     && $mode & S_ISVTX;
    return "every account can write $path"   if $mode & S_IWOTH;
    return "the group of $path can write it" if $mode & S_IWGRP && $gid != POSIX::getegid();
    return;
}

=method seal

C<($dir)>.  Makes each file of L</control_files> of C<$dir> safe from the agent,
as L</exposed> says, where the worker owns it: no group and no other account
may write the file, and each directory above it in the workspace that they may
write gets the sticky bit.  So the next L</guard> lets the worker run git in
C<$dir>.  It does not look at what the files say: L</fetch> seals the bare clone
before it writes the configuration, and L</worktree> seals a worktree that it
has just made.  Returns nothing.

=cut

sub seal ( $self, $dir ) {
    my $top = Mojo::File->new( $self->workspace )->realpath;
    for my $path ( control_files($dir) ) {
        my ( $mode, $uid ) = ( stat $path )[ 2, 4 ];
        next if $uid != $>;
        chmod $mode & oct('7777') & ~( S_IWGRP | S_IWOTH ), "$path" or die "chmod $path: $!\n";
        for ( my $up = $path->dirname; $up->to_string =~ m{\A\Q$top\E(?:/|\z)}; $up = $up->dirname ) {
            my ( $above, $owner ) = ( stat $up )[ 2, 4 ];
            next if $owner != $> || !defined writable( $up, 1 );
            chmod $above & oct('7777') | S_ISVTX, "$up" or die "chmod $up: $!\n";
        }
    }
    return;
}

=method shared_dir

C<($name, $mode)>.  Makes the directory C<$name> of the bare clone, if it is
not there, and gives it the bits of C<$mode> too, with C<rwx> for the group,
where the worker owns it.  The agent cannot make a directory in the bare clone
itself, because L</seal> takes the right from it, so the worker makes the ones
that git writes to for the agent.  Returns nothing.

=cut

sub shared_dir ( $self, $name, $mode ) {
    my $dir = $self->mirror->child($name);
    mkdir "$dir" or $!{EEXIST} or die "mkdir $dir: $!\n";
    my ( $now, $uid ) = ( stat $dir )[ 2, 4 ];
    return if $uid != $>;
    chmod $now & oct('7777') | oct('2070') | $mode, "$dir" or die "chmod $dir: $!\n";
    return;
}

# git, with $input on its standard input.  @shown is what an error names.
sub run_git ( $cmd, $input, @shown ) {
    my ( $out, $err ) = ( q{}, q{} );
    my $ok = IPC::Run::run( $cmd, '<', $input, '>', \$out, '2>', \$err, IPC::Run::timeout(600) );
    chomp $err;
    die "git @shown: $err\n" if !$ok;
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

It also sets C<user.name> and C<user.email> of the bare clone to
L</author_name> and L</author_email>, when they are set, so every commit in
every worktree carries them.  A worktree shares that configuration, so
writing it from each new worktree would only write the one file again, and
two jobs that did so at once could meet on its lock and fail.

It sets C<core.hooksPath> of the bare clone to C<git-hooks>, as L</HOOKS>
says.

Before it runs git in the bare clone, it seals it, as L</seal> says, and makes
F<logs/> and F<worktrees/>, as L</THE AGENT ACCOUNT> says.

=cut

# A bare clone, with remote-tracking refs so that worktrees can start from origin.
sub fetch_unlocked ($self) {
    my $mirror = $self->mirror;
    if ( !-d $mirror ) {
        $mirror->dirname->make_path;
        $self->git_remote( 'clone', '--bare', $self->github_web . '/' . $self->repo . '.git', "$mirror" );
    }
    $self->seal($mirror);
    $self->shared_dir( 'logs',      0 );
    $self->shared_dir( 'worktrees', S_ISVTX );
    $self->git( q{-C}, "$mirror", qw{config remote.origin.fetch +refs/heads/*:refs/remotes/origin/*} );
    $self->git( q{-C}, "$mirror", qw{config core.sharedRepository group} );
    $self->git( q{-C}, "$mirror", qw{config core.hooksPath git-hooks} );
    $self->git( q{-C}, "$mirror", 'config', 'user.name',  $self->author_name )  if $self->author_name;
    $self->git( q{-C}, "$mirror", 'config', 'user.email', $self->author_email ) if $self->author_email;
    $self->git_remote( q{-C}, "$mirror", qw{fetch --prune origin} );
    return $mirror;
}

=method refresh_reference

C<($branch)>.  Fetches, then resets the reference worktree to
C<origin/$branch>, under L</locked>.  Returns it.  A reference whose directory
is gone is made again, after git forgets the worktree that it still has
registered there, which it would otherwise refuse to add a second time.  It
seals the reference, as L</seal> says, before it resets it.

=cut

sub refresh_reference ( $self, $branch ) {
    return $self->locked(
        sub {
            my $mirror = $self->fetch_unlocked;
            my $ref    = $self->reference;
            if ( !-d $ref ) {
                $ref->dirname->make_path;
                $self->git( q{-C}, "$mirror", qw{worktree prune} );
                $self->shared_dir( 'worktrees', S_ISVTX );
                $self->git( q{-C}, "$mirror", qw{worktree add --detach}, "$ref", "origin/$branch" );
            }
            $self->seal($ref);
            $self->git( q{-C}, "$ref", 'reset', '--hard', "origin/$branch" );
            return $ref;
        }
    );
}

=method files_at

C<($branch, $path)>.  The files at C<$path> on C<origin/$branch> of the bare
clone, as hashes with C<path>, C<mode> and C<object>, the id of the blob.  It
is the file itself, or with a C<$path> that ends in C</>, the files directly in
that directory.  A symbolic link is a file here, and its blob is its target.
Empty when there is no such file.  It does not fetch.

=cut

sub files_at ( $self, $branch, $path ) {
    my @files;
    for my $line ( split m{\0}, $self->git( q{-C}, $self->mirror->to_string, qw{ls-tree -z}, "origin/$branch", q{--}, $path ) ) {
        my ( $meta, $name ) = split m{\t}, $line, 2;
        my ( $mode, $type, $object ) = split q{ }, $meta;
        push @files, { path => $name, mode => $mode, object => $object } if $type eq 'blob';
    }
    return @files;
}

=method blob

C<($object)>.  The content of a blob of the bare clone, without the newline at
its end.

=cut

sub blob ( $self, $object ) {
    return $self->git( q{-C}, $self->mirror->to_string, qw{cat-file blob}, $object );
}

=method worktree

C<($dir, %opt)>: C<< branch => ..., base => ... >> for a new branch,
C<< existing => $branch >> for a branch already on the remote,
C<< pull => $number >> for the head of a pull request, detached,
C<< detach => $branch >> for a branch on the remote, detached, to read and to
run what is in it, or C<< at => $commit >> for a commit of the bare clone,
detached, to push it.

With C<< agent => 1 >>, the account of L</as_agent> makes the worktree, so
that it owns each file in it.  A run of claude edits files in it as that
account, and a tool that it runs, such as C<perltidy -b>, may need to change
the mode or the times of a file, which only its owner may do.  Without an
account it makes no difference.

Making a worktree writes nothing to the bare clone but the fetch and its own
worktree entry.  A C<detach> or C<at> worktree holds no branch, so any number
of them can be at one branch at once.  Every worktree has the author of
L</fetch_unlocked>, which is in the configuration of the bare clone.

It adds the worktree under L</locked>, after the fetch, and the fetch of the
head of a pull request with it.  So a fetch with C<--prune> by another job
cannot remove the ref of that head before the worktree is at it.  The ref is
under F<refs/remotes/origin/>, where the prune keeps only the branches on
GitHub.
And L</prune_worktrees> cannot run while git makes the entry of the worktree.

A new branch tracks nothing (C<--no-track>), because the agent cannot write
the configuration of the bare clone, where git would keep the upstream.  The
worker pushes to a branch that it names.  A worktree that the worker makes
and runs git in, which is one with neither C<agent> nor C<detach>, is sealed,
as L</seal> says.  A C<detach> worktree is not, because a claude run may work
in it, and the worker runs no git in it.

=cut

sub worktree ( $self, $dir, %opt ) {
    my $mirror = $self->fetch;
    $dir = Mojo::File->new($dir);
    $dir->dirname->make_path;
    my $by  = $opt{agent} ? undef : "$mirror";
    my $add = sub (@add) { $self->git_as_owner( $by, \undef, q{-C}, "$mirror", qw{worktree add}, @add ) };
    $self->locked(
        sub {
            # git removes worktrees/ with its last worktree.
            $self->shared_dir( 'worktrees', S_ISVTX );
            return $add->( '--detach', "$dir", $opt{at} // "origin/$opt{detach}" ) if defined $opt{detach} || defined $opt{at};
            if ( $opt{pull} ) {
                $self->git_remote( q{-C}, "$mirror", 'fetch', 'origin', "+pull/$opt{pull}/head:refs/remotes/origin/pr/$opt{pull}" );
                return $add->( '--detach', "$dir", "origin/pr/$opt{pull}" );
            }
            return $add->( '--no-track', '-B', $opt{existing}, "$dir", "origin/$opt{existing}" ) if $opt{existing};
            return $add->( '--no-track', '-B', $opt{branch},   "$dir", "origin/$opt{base}" );
        }
    );
    $self->seal($dir) if !$opt{agent} && !defined $opt{detach};
    return $dir;
}

=method head

C<($dir)>.  The commit at HEAD of the worktree C<$dir>, which git there finds as
the account that owns C<$dir>, as L</git_as_owner> says.  So the worker runs no
git in a worktree of the agent, whose F<.git> the agent can point at a
repository of its own, with a configuration of its own.  It dies when what git
says is not the id of a commit.

=cut

sub head ( $self, $dir ) {
    my $head = $self->git_as_owner( $dir, \undef, q{-C}, "$dir", qw{rev-parse --verify HEAD^{commit}} );
    return $head =~ m{\A([[:xdigit:]]{40}(?:[[:xdigit:]]{24})?)\z} ? $1 : die "HEAD of $dir is not a commit: $head\n";
}

=method commits_since

C<($dir, $base)>.  The number of commits at L</head> of the worktree that
C<$base> does not have, which the bare clone counts.

=cut

sub commits_since ( $self, $dir, $base ) {
    my $head = $self->head($dir);
    return 0 + $self->git( q{-C}, $self->mirror->to_string, 'rev-list', '--count', "$base..$head" );
}

=method push_branch

C<($dir, $branch)>.  Pushes L</head> of the worktree to C<$branch> with
C<--force-with-lease>, from the bare clone, and returns the SHA it pushed.  If
the push fails but the branch on GitHub is at HEAD anyway, the push is done:
GitHub can answer a server error to a push that it did take, and the lease
then refuses the next try.

=cut

sub push_branch ( $self, $dir, $branch ) {
    my $head   = $self->head($dir);
    my $mirror = $self->mirror->to_string;
    return $head if eval { $self->git_remote( q{-C}, $mirror, qw{push --force-with-lease origin}, "$head:refs/heads/$branch" ); 1 };
    my $error   = $@;
    my ($there) = split m{\s}, $self->git_remote( q{-C}, $mirror, qw{ls-remote origin}, "refs/heads/$branch" );
    die $error if ( $there // q{} ) ne $head;
    return $head;
}

=method apply_patch

C<($dir, $patch)>.  Applies C<$patch>, the output of C<git diff --cached
--binary>, to the worktree C<$dir> and to its index, as the account that owns
the worktree, as L</git_as_owner> says.  So each file that the patch writes
belongs to that account too.

=cut

sub apply_patch ( $self, $dir, $patch ) {
    $self->git_as_owner( $dir, \$patch, q{-C}, "$dir", qw{apply --index} );
    return;
}

=method remove_worktree

C<($dir)>.  Removes the worktree, if it is there, as the account that owns
it, as L</git_as_owner> says.  It holds L</locked>, because git removes
F<worktrees/> of the bare clone with its last worktree, and the agent cannot
make it again while L</worktree> adds one.

=cut

sub remove_worktree ( $self, $dir ) {
    return if !-d $dir;
    $self->locked( sub { $self->git_as_owner( $dir, \undef, q{-C}, $self->mirror->to_string, qw{worktree remove --force}, "$dir" ) } );
    return;
}

=method prune_worktrees

Forgets each worktree of the bare clone whose directory is gone.  Such a
worktree still holds its branch, so no other worktree can check it out.  It
holds L</locked>, so it never meets L</worktree> as it adds one.

=cut

sub prune_worktrees ($self) {
    $self->locked( sub { $self->git( q{-C}, $self->mirror->to_string, qw{worktree prune} ) } );
    return;
}

1;

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

=head2 HOOKS

A commit in a worktree runs the hooks of the branch of that worktree: every
hook in its F<git-hooks/>.  The fetch sets C<core.hooksPath> of the bare clone
to C<git-hooks>, and git takes a relative C<core.hooksPath> as relative to the
root of the worktree that it runs a hook in.  So nothing is copied, two
worktrees on branches whose hooks differ each run their own, and a patch or a
commit that changes a hook changes what the next commit of that worktree runs.
git runs only the files whose names are hook names in L<githooks(5)>, so a
helper beside the hooks, such as F<refresh-coverage>, runs only when a hook
runs it, by its path beside the hook (C<${0%/*}>).  A hook that is not
executable in the branch does not run, and git says so.

A hook is a file of the branch, and so a run of claude can change it.  So no
git command of the worker runs a hook: L</git> and L</git_as_owner> give git a
C<core.hooksPath> of F</dev/null>.  Without it, a push of the worker in the
worktree of a run would run the F<pre-push> and F<reference-transaction> that
the run wrote, as the worker.  The one exception is L</commit>, for a worktree
that the worker made and no run has worked in.

=head2 THE AGENT ACCOUNT

Each fetch sets C<core.sharedRepository> to C<group> in the bare clone, so git
makes what it writes there writable by the group.  That is for
L<App::Clod::Claude/run_as>: claude commits as another account, into the bare
clone of the worker.

With L</as_agent>, that account makes the worktree of a claude run, applies a
patch to it and removes it, so that it owns every file in it.  The group lets
the agent write to a file that the worker owns, but not change its mode or its
times, and the hooks of a spoke do both when they tidy a file.  The worker
still fetches, writes the configuration of the bare clone, and pushes.  Every
git command of this module trusts the directory that it works in, with C<-c
safe.directory>, because a worktree and the bare clone have different owners.

The trust is safe only because L</guard> looks first.  A git command reads the
configuration of the repository, and some of its keys name a command that git
runs, such as C<core.fsmonitor>, C<core.sshCommand> or C<diff.external>, or
send the token elsewhere, such as C<http.proxy>.  So an account that can
change that configuration can run a command as the worker, or read the token.
git looks for it through the F<.git> file of a worktree, the F<commondir> file
of its git directory, and the F<config> of the common directory, and the agent
must not be able to change any of them, nor any directory above them.  So:

=over

=item * The worker runs no git in a worktree of the agent, which owns its
F<.git>.  L</head> asks the agent for the commit there, and the worker counts
and pushes it from the bare clone.

=item * L</fetch> seals the bare clone with L</seal>: no group may write its
F<config>, nor the bare clone itself, where an account could make a
F<commondir> or a F<config> of its own.  It makes F<logs/> and F<worktrees/>,
where the agent writes when it commits in a worktree and when it makes one,
writable by the group.  F<worktrees/> also has the sticky bit, so that the
agent cannot rename the entry of a worktree of the worker.  The agent then
cannot delete a branch, pack the refs or drop the last stash, because git rewrites
F<packed-refs> beside F<config> for that.

=item * L</worktree> and L</refresh_reference> seal each worktree that the
worker runs git in.

=item * L</guard> refuses a git command of the worker in a directory that is
not sealed, so that a directory that this list does not reach fails instead of
running what the agent wrote there.

=back

It also needs three things that this module cannot do:

=over

=item * The workspace belongs to a group of both accounts, and has the setgid
bit, so that everything in it gets that group.

=item * The worker and claude run with the umask C<0007>, so that the files of
a worktree are writable by the group too.  sudo combines its own umask with
the umask of the worker, so sudo needs C<umask=0007> as well.

=item * sudo lets the worker run git as the agent, with no password.  And the
gitconfig of the agent names the worktrees that the worker owns, such as the
reference and the tool worktrees, in C<safe.directory>, because claude runs git
in them too.

=back

=cut
