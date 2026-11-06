#!/usr/bin/env perl
use 5.040;
no autovivification;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use FindBin::libs;
use File::Temp       ();
use IPC::Run         ();
use Mojo::File       ();
use List::Util       ();
use Test::MockModule ();

use App::Clod::Spoke();

my $tmp = Mojo::File->new( File::Temp->newdir( CLEANUP => 1 )->dirname )->child("clod-spoke-$$")->make_path;
END { $tmp->remove_tree if $tmp }

sub git (@args) {
    my ( $out, $err );
    IPC::Run::run( [ 'git', @args ], '>', \$out, '2>', \$err ) or die "git @args: $err";
    chomp $out;
    return $out;
}

# A spoke on disk that has its own hooks, as the scaffold gives it.
my $bare = $tmp->child(qw{remote Test-Org one.git});
$bare->dirname->make_path;
git( qw{init --quiet --bare --initial-branch=main}, "$bare" );
my $seed = $tmp->child('seed')->make_path;
git( q{-C}, "$seed", qw{init --quiet --initial-branch=main} );
$seed->child( 'git-hooks', 'pre-commit' )->dirname->make_path;
my $hook = $seed->child(qw{git-hooks pre-commit})->spew("#!/bin/sh\ntouch hook-ran\n");
chmod 0755, $hook or die "chmod $hook: $!";
git( '-C',  "$seed", 'add', q{.} );
git( q{-C}, "$seed", qw{-c user.name=t -c user.email=t@test.test commit --quiet --no-verify -m seed} );
git( '-C',  "$seed", 'push', '--quiet', "$bare", 'main' );

my $spoke = App::Clod::Spoke->new( repo => 'Test-Org/one', workspace => "$tmp/ws", github_web => "file://$tmp/remote", token => 'test-token', author_name => 'test-bot', author_email => 'bot@test.test' );

subtest refresh_reference => sub {
    my $ref = $spoke->refresh_reference('main');
    ok( -e $ref->child( 'git-hooks', 'pre-commit' ), 'the reference worktree has the default branch' );
    $seed->child('new')->spew('x');
    git( '-C',  "$seed", 'add', 'new' );
    git( q{-C}, "$seed", qw{-c user.name=t -c user.email=t@test.test commit --quiet --no-verify -m more} );
    git( '-C',  "$seed", 'push', '--quiet', "$bare", 'main' );
    ok( -e $spoke->refresh_reference('main')->child('new'), 'and follows it on the next refresh' );
};

subtest 'the bare clone, shared with its group' => sub {
    my $umask = umask oct '0077';
    my $tree  = $spoke->worktree( $tmp->child( 'ws', 'work', 2, 'Test-Org', 'one' ), branch => 'clod/2-shared', base => 'main' );
    git( q{-C}, "$tree", qw{commit --quiet --no-verify --allow-empty -m shared} );
    my $mode = ( stat $spoke->mirror->child(qw{refs heads clod 2-shared}) )[2] // 0;
    is( $mode & oct '0660', oct '0660', 'a branch that the worktree commits is writable by the group, whatever the umask' ) or diag sprintf '%04o', $mode & oct '7777';
    $spoke->remove_worktree($tree);
    umask $umask;
};

subtest worktree => sub {
    my $dir  = $tmp->child( 'ws', 'work', 1, 'Test-Org', 'one' );
    my $tree = $spoke->worktree( $dir, branch => 'clod/1-test', base => 'main' );
    is( git( q{-C}, "$tree", qw{rev-parse --abbrev-ref HEAD} ), 'clod/1-test',   'a new branch, checked out' );
    is( git( '-C', "$tree", 'config', 'user.email' ),           'bot@test.test', 'with the bot as the author' );
    is( $spoke->commits_since( $tree, 'origin/main' ),          0,               'and no commits of its own yet' );

    git( q{-C}, "$tree", qw{commit --quiet --allow-empty -m work} );
    ok( -e $tree->child('hook-ran'), 'a commit in the worktree runs the repository\'s own pre-commit hook' );
    is( $spoke->commits_since( $tree, 'origin/main' ), 1, 'the commit counts' );

    my $sha = $spoke->push_branch( $tree, 'clod/1-test' );
    is( git( '--git-dir', "$bare", 'rev-parse', 'clod/1-test' ), $sha, 'the push puts the commit on the remote branch' );

    $spoke->remove_worktree($tree);
    ok( !-d $tree, 'the worktree can be removed' );
    my $again = $spoke->worktree( $dir, existing => 'clod/1-test' );
    is( git( '-C', "$again", 'rev-parse', 'HEAD' ), $sha, 'and made again from the pushed branch' );
    $again->remove_tree;
    like( dies { $spoke->worktree( $tmp->child( 'ws', 'work', 4, 'Test-Org', 'one' ), existing => 'clod/1-test' ) }, qr/already\ used\ by\ worktree/, 'a worktree deleted behind the back of git still holds its branch' );
    $spoke->prune_worktrees;
    my $freed = $spoke->worktree( $tmp->child( 'ws', 'work', 4, 'Test-Org', 'one' ), existing => 'clod/1-test' );
    is( git( '-C', "$freed", 'rev-parse', 'HEAD' ), $sha, 'until the bare clone is pruned' );
    $spoke->remove_worktree($freed);

    my @detached = map { $spoke->worktree( $tmp->child( 'ws', 'work', $_, 'Test-Org', 'one' ), detach => 'clod/1-test' ) } 2, 3;
    is( [ map { git( '-C', "$_", 'rev-parse', 'HEAD' ) } @detached ], [ $sha, $sha ], 'two detached worktrees can be at one branch at once' );
    is( git( '-C', "$detached[0]", qw{rev-parse --abbrev-ref HEAD} ), 'HEAD',         'and neither holds the branch' );
    $spoke->remove_worktree($_) for @detached;
};

subtest 'a push when GitHub fails for a moment' => sub {
    local @App::Clod::Retry::DELAYS = ( 0, 0, 0 );
    my $dir  = $tmp->child( 'ws', 'work', 5, 'Test-Org', 'one' );
    my $tree = $spoke->worktree( $dir, branch => 'clod/5-retry', base => 'main' );
    my $mock = Test::MockModule->new('App::Clod::Spoke');
    my $real = $mock->original('git');
    my @pushes;

    # Each push runs the next of @plan: 'fail' dies before it reaches the
    # remote, 'took' pushes and then dies as if the answer was lost.
    my @plan;
    $mock->redefine(
        git => sub ( $self, @args ) {
            return $real->( $self, @args ) if !List::Util::any { $_ eq 'push' } @args;
            push @pushes, 1;
            my $step = shift @plan // 'push';
            die "git push: remote: Internal Server Error\n"                  if $step eq 'fail';
            die "git push: ! [remote rejected] (permission denied)\n"        if $step eq 'refuse';
            die "git push: ! [rejected] HEAD -> clod/5-retry (stale info)\n" if $step eq 'stale';
            my $out = $real->( $self, @args );
            die "git push: remote: Internal Server Error\n" if $step eq 'took';
            return $out;
        }
    );

    git( q{-C}, "$tree", qw{commit --quiet --allow-empty -m first} );
    @plan = qw{fail push};
    my $sha;
    my $said = warnings { $sha = $spoke->push_branch( $tree, 'clod/5-retry' ) };
    is( scalar @pushes, 2, 'a push that GitHub answers with a server error is tried again' );
    like( $said, [qr/push\ .*\ in\ 0s:\ .*Internal\ Server\ Error/], 'and the try says why, in the log of the worker' );
    is( git( '--git-dir', "$bare", 'rev-parse', 'clod/5-retry' ), $sha, 'and lands' );

    git( q{-C}, "$tree", qw{commit --quiet --allow-empty -m second} );
    @pushes = ();
    @plan   = qw{took stale};
    my $took;
    my $once = warnings { $took = $spoke->push_branch( $tree, 'clod/5-retry' ) };
    is( scalar @$once,                                                       1,                                                     'once' );
    is( scalar @pushes,                                                      2,                                                     'a push that GitHub took, but answered with a server error, is tried again' );
    is( [ $took, git( '--git-dir', "$bare", 'rev-parse', 'clod/5-retry' ) ], [ ( git( q{-C}, "$tree", qw{rev-parse HEAD} ) ) x 2 ], 'and when the lease refuses that try, the branch is already at HEAD, so the push is done' );

    git( q{-C}, "$tree", qw{commit --quiet --allow-empty -m third} );
    @pushes = ();
    @plan   = qw{refuse};
    like( dies { $spoke->push_branch( $tree, 'clod/5-retry' ) }, qr/permission\ denied/, 'a push that GitHub refuses dies' );
    is( scalar @pushes, 1, 'without another try' );

    @pushes = ();
    @plan   = qw{fail fail fail fail};
    my $error;
    my $each = warnings {
        $error = dies { $spoke->push_branch( $tree, 'clod/5-retry' ) }
    };
    is( scalar @$each, 3, 'and says so for each try after the first' );
    like( $error, qr/Internal\ Server\ Error/, 'and so does one that fails on every try' );
    is( scalar @pushes, 4, 'after four tries' );
    $mock->unmock_all;
    $spoke->remove_worktree($tree);
};

subtest 'one process at a time works on a bare clone' => sub {
    $spoke->fetch;

    # A child that fetches, given three seconds, says how it ended: 0 when the
    # fetch went through, 9 when it was still waiting for the lock.
    my $fetch_in_child = sub {
        my $pid = fork // die "fork: $!";
        if ( !$pid ) {
            local $SIG{ALRM} = sub { POSIX::_exit(9) };
            Time::HiRes::alarm(3);
            POSIX::_exit( eval { $spoke->fetch; 1 } ? 0 : 1 );
        }
        waitpid $pid, 0;
        return $? >> 8;
    };
    is( $spoke->locked($fetch_in_child), 9, 'a fetch waits while another process holds the lock of the clone' );
    is( $fetch_in_child->(),             0, 'and goes through when it is free' );
    ok(
        dies {
            $spoke->locked( sub { die "inside the lock\n" } )
        },
        'code that dies under the lock dies'
    );
    is( $fetch_in_child->(), 0, 'and lets go of the lock' );

    # A clone that died before its refspec was set has no remote-tracking refs.
    my $broken = App::Clod::Spoke->new( repo => 'Test-Org/one', workspace => "$tmp/ws-broken", github_web => "file://$tmp/remote", token => 'test-token' );
    $broken->mirror->dirname->make_path;
    git( qw{clone --quiet --bare}, "$bare", $broken->mirror->to_string );
    $broken->fetch;
    my $refs = git( '--git-dir', $broken->mirror->to_string, qw{for-each-ref --format=%(refname) refs/remotes/origin/} );
    like( $refs, qr{^refs/remotes/origin/main$}m, 'a fetch gives such a clone its remote-tracking refs' );
};

subtest git => sub {
    like( dies { $spoke->git(qw{rev-parse --verify no-such-ref}) }, qr/\Agit\ rev-parse\ --verify\ no-such-ref:\ fatal:\ [^\n]+\n\z/, 'a failing git command dies with its error, on one line, with no file or line' );
    ok( !( grep { m{test-token} } git( '--git-dir', $spoke->mirror->to_string, 'config', '--list' ) ), 'the token is not in the clone\'s configuration' );
};

done_testing;
