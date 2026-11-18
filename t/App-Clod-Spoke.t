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

    my @detached = map { local ($_) = $_; $spoke->worktree( $tmp->child( 'ws', 'work', $_, 'Test-Org', 'one' ), detach => 'clod/1-test' ) } 2, 3;
    is( [ map { git( '-C', "$_", 'rev-parse', 'HEAD' ) } @detached ], [ $sha, $sha ], 'two detached worktrees can be at one branch at once' );
    is( git( '-C', "$detached[0]", qw{rev-parse --abbrev-ref HEAD} ), 'HEAD',         'and neither holds the branch' );
    foreach my $worktree (@detached) { $spoke->remove_worktree($worktree) }
};

subtest 'the author, in the bare clone' => sub {
    my $fresh  = App::Clod::Spoke->new( repo => 'Test-Org/one', workspace => "$tmp/ws-author", github_web => "file://$tmp/remote", token => 'test-token', author_name => 'test-bot', author_email => 'bot@test.test' );
    my $mirror = $fresh->fetch->to_string;
    is( [ map { git( '--git-dir', $mirror, 'config', $_ ) } qw{user.name user.email} ], [ 'test-bot', 'bot@test.test' ], 'a fetch gives the bare clone the author' );
    my $tree = $fresh->worktree( $tmp->child( 'ws-author', 'work', 1, 'Test-Org', 'one' ), branch => 'clod/1-author', base => 'main' );
    {
        # An author in the environment of git would win over the configuration.
        delete local @ENV{qw{GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL}};
        git( q{-C}, "$tree", qw{commit --quiet --no-verify --allow-empty -m authored} );
    }
    is( git( q{-C}, "$tree", qw{log -1 --format=%an<%ae>} ), 'test-bot<bot@test.test>', 'and a commit in a new worktree carries it' );
    $fresh->remove_worktree($tree);
};

# Pushes $branch to the remote: main with %hooks in git-hooks/, each a shell script.
sub hooks_branch ( $branch, %hooks ) {
    my $dir = $tmp->child( 'hooks-seed', $branch );
    git( q{clone}, '--quiet', "$bare", "$dir" );
    $dir->child('git-hooks')->make_path;
    for my $name ( sort keys %hooks ) {
        my $file = $dir->child( 'git-hooks', $name )->spew("#!/bin/sh\n$hooks{$name}\n");
        chmod 0755, $file or die "chmod $file: $!";
    }
    git( q{-C}, "$dir", qw{add -A} );
    git( q{-C}, "$dir", qw{-c user.name=t -c user.email=t@test.test commit --quiet --no-verify -m}, "hooks of $branch" );
    git( q{-C}, "$dir", qw{push --quiet origin},                                                    "HEAD:refs/heads/$branch" );
    return $dir;
}

subtest 'the hooks of each worktree' => sub {
    my $log = $tmp->child('hooks-ran');
    hooks_branch( 'hooks-a', 'pre-commit' => "echo a-pre-commit >> $log" );
    my $b = hooks_branch(
        'hooks-b',
        'pre-commit'       => "echo b-pre-commit >> $log",
        'post-merge'       => 'exec "${0%/*}/refresh-coverage" b-post-merge',
        'pre-push'         => "echo b-pre-push >> $log",
        'refresh-coverage' => qq{echo "\$1" >> $log},
    );
    git( q{-C}, "$b", qw{-c user.name=t -c user.email=t@test.test commit --quiet --no-verify --allow-empty -m next} );
    git( q{-C}, "$b", qw{push --quiet origin HEAD:refs/heads/hooks-b-next} );

    my $first  = $spoke->worktree( $tmp->child( 'ws', 'work', 7, 'Test-Org', 'one' ), existing => 'hooks-a' );
    my $second = $spoke->worktree( $tmp->child( 'ws', 'work', 8, 'Test-Org', 'one' ), existing => 'hooks-b' );
    my $ran    = sub () { return [ split m{\n}, -e $log ? $log->slurp : q{} ] };
    git( q{-C}, "$first", qw{commit --quiet --allow-empty -m first} );
    is( $ran->(), ['a-pre-commit'], 'a commit runs the pre-commit of its own branch, also after a worktree of another branch was made' );
    git( q{-C}, "$second", qw{commit --quiet --allow-empty -m second} );
    is( $ran->(), [qw{a-pre-commit b-pre-commit}], 'and a commit in the other worktree runs the pre-commit of that branch' );
    git( q{-C}, "$second", qw{reset --quiet --hard origin/hooks-b} );
    git( q{-C}, "$second", qw{merge --quiet --ff-only origin/hooks-b-next} );
    is( $ran->(), [qw{a-pre-commit b-pre-commit b-post-merge}], 'a merge runs the post-merge of the branch, and the helper beside it, which git does not run as a hook' );

    $second->child(qw{git-hooks pre-commit})->spew("#!/bin/sh\necho changed-pre-commit >> $log\n");
    git( q{-C}, "$second", qw{commit --quiet --allow-empty -m changed} );
    is( $ran->()->[-1], 'changed-pre-commit', 'a change to a hook in a worktree is what its next commit runs' );

    my $before = $ran->();
    $spoke->push_branch( $second, 'hooks-b-pushed' );
    is( $ran->(), $before, 'a push of the worker runs no hook of the worktree, which a run of claude could have written' );
    App::Clod::Spoke::commit( $second, qw{--quiet --allow-empty -m}, 'by the worker' );
    is( $ran->()->[-1], 'changed-pre-commit', 'but a commit of the worker through commit runs the hooks of the worktree' );

    $spoke->remove_worktree($_) for $first, $second;
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

subtest 'files_at and blob' => sub {
    my $bin = $seed->child('bin')->make_path;
    my $sub = $bin->child('sub')->make_path;
    $sub->child('deep')->spew("x\n");
    chmod 0755, $bin->child('tool')->spew("#!/bin/sh\n") or die "chmod: $!";
    $bin->child('plain')->spew("text\n");
    symlink 'tool', $bin->child('link') or die "symlink: $!";
    git( '-C',  "$seed", 'add', q{.} );
    git( q{-C}, "$seed", qw{-c user.name=t -c user.email=t@test.test commit --quiet --no-verify -m files} );
    git( '-C',  "$seed", 'push', '--quiet', "$bare", 'main' );
    $spoke->fetch;

    my %mode = map { $_->{path} => $_->{mode} } $spoke->files_at( 'main', 'bin/' );
    is( \%mode,                                                        { 'bin/link' => '120000', 'bin/plain' => '100644', 'bin/tool' => '100755' }, 'a path that ends in / gives the files directly in that directory, with their modes' );
    is( [ map { $_->{path} } $spoke->files_at( 'main', 'bin/tool' ) ], ['bin/tool'],                                                                'a path of a file gives that file' );
    is( [ $spoke->files_at( 'main', 'bin' ) ],                         [],                                                                          'a directory without the / is no file' );
    is( [ $spoke->files_at( 'main', 'bin/none' ) ],                    [],                                                                          'and a path with nothing there gives none' );
    my ($link) = $spoke->files_at( 'main', 'bin/link' );
    is( $spoke->blob( $link->{object} ), 'tool', 'the blob of a symbolic link is its target' );
    like( dies { $spoke->files_at( 'no-such-branch', 'bin/' ) }, qr/no-such-branch/, 'a branch that the bare clone does not have dies' );
};

# git refuses a repository that another account owns, and its own test switch
# makes it take every repository for one.  So the worker can only work in a
# worktree of the agent, or in the bare clone, when it trusts that directory.
# The switch is off for a fetch or a push, because the remote on disk stands
# for GitHub, which no test of ownership reaches.
subtest 'a worktree that the agent owns' => sub {
    my @asked;
    my $link = $tmp->child('ws-link');
    symlink "$tmp/ws", "$link" or die "symlink $link: $!";
    my $agent = App::Clod::Spoke->new(
        repo         => 'Test-Org/one',
        workspace    => "$link",
        github_web   => "file://$tmp/remote",
        token        => 'test-token',
        author_name  => 'test-bot',
        author_email => 'bot@test.test',
        as_agent     => sub (@cmd) { push @asked, [@cmd]; return ( qw{env CLOD_TEST_AS_AGENT=1}, @cmd ) },
    );
    my $mirror = $agent->fetch;
    my $mock   = Test::MockModule->new('App::Clod::Spoke');
    $mock->redefine( fetch  => sub ($self) { return $mirror } );
    $mock->redefine( is_own => sub ($path) { return 0 } );
    my $foreign = sub ($code) {
        local $ENV{GIT_TEST_ASSUME_DIFFERENT_OWNER} = 1;
        return $code->();
    };

    my $tree = $foreign->( sub { $agent->worktree( $link->child( 'work', 5, 'Test-Org', 'one' ), branch => 'clod/5-agent', base => 'main', agent => 1 ) } );
    is( scalar @asked, 1, 'the agent makes the worktree' );
    my $trusts   = qr{\Agit\ -c\ safe\.directory=\Q$tmp\E/ws/mirrors/\S+\ };
    my $hookless = qr{-c\ core\.hooksPath=/dev/null\ };
    my $adds     = qr{-C\ \S+\ worktree\ add\ -B\ clod/5-agent\ };
    like( "@{ $asked[0] // [] }", qr{$trusts$hookless$adds}, 'with git, trusting the real path of the bare clone, and running no hook' );
    is( $foreign->( sub { $agent->git( q{-C}, "$tree", qw{rev-parse --abbrev-ref HEAD} ) } ), 'clod/5-agent', 'and the worker trusts the worktree, through a symbolic link' );

    $tree->child('patched')->spew("old\n");
    git( q{-C}, "$tree", qw{add patched} );
    git( q{-C}, "$tree", qw{-c user.name=t -c user.email=t@test.test commit --quiet --no-verify -m base} );
    $tree->child('patched')->spew("new\n");
    my $patch = git( q{-C}, "$tree", qw{diff --binary} ) . "\n";
    git( q{-C}, "$tree", qw{checkout --quiet -- patched} );
    $foreign->( sub { $agent->apply_patch( $tree, $patch ) } );
    like( "@{ $asked[-1] }", qr{apply\ --index\z}, 'the agent applies a patch to its worktree' );
    is( $tree->child('patched')->slurp,                       "new\n",   'to the file' );
    is( git( q{-C}, "$tree", qw{diff --cached --name-only} ), 'patched', 'and to the index' );

    is( $foreign->( sub { $agent->commits_since( $tree, 'origin/main' ) } ), 1, 'the worker counts the commits of the worktree' );
    my $sha = $agent->push_branch( $tree, 'clod/5-agent' );
    is( git( '--git-dir', "$bare", 'rev-parse', 'clod/5-agent' ), $sha, 'and pushes them' );

    my $asked = @asked;
    $foreign->( sub { $agent->remove_worktree($tree) } );
    is( scalar @asked, $asked + 1, 'the agent removes its worktree' );
    ok( !-d $tree, 'and it is gone' );

    $mock->redefine( is_own => sub ($path) { return 1 } );
    my $own = $foreign->( sub { $agent->worktree( $link->child( 'work', 6, 'Test-Org', 'one' ), detach => 'main' ) } );
    $asked = @asked;
    $foreign->( sub { $agent->remove_worktree($own) } );
    is( scalar @asked, $asked, 'the worker makes and removes a worktree of its own, with no agent' );
    ok( !-d $own, 'and it is gone' );
};

subtest git => sub {
    like( dies { $spoke->git(qw{rev-parse --verify no-such-ref}) }, qr/\Agit\ rev-parse\ --verify\ no-such-ref:\ fatal:\ [^\n]+\n\z/, 'a failing git command dies with its error, on one line, with no file or line' );
    ok( !( grep { m{test-token} } git( '--git-dir', $spoke->mirror->to_string, 'config', '--list' ) ), 'the token is not in the clone\'s configuration' );
};

done_testing;
