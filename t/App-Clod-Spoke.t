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

# The workspace is shared with the group of the agent, but the configuration of
# the bare clone names commands that git runs, and the worker runs git there.
sub mode ($path) { return ( stat $path )[2] & oct '7777' }

subtest 'the configuration of the bare clone, sealed from the agent' => sub {
    my $umask  = umask oct '0007';
    my $mirror = $spoke->fetch;
    my $config = $mirror->child('config');
    chmod oct '2770', "$mirror" or die "chmod $mirror: $!";
    chmod oct '0660', "$config" or die "chmod $config: $!";
    $spoke->fetch;
    is( mode($config) & oct '0022', 0, 'after a fetch, no group and no other account can write the configuration of the bare clone' ) or diag sprintf '%04o', mode($config);
    is( mode($mirror) & oct '0022', 0, 'nor the bare clone, where they could make a configuration of their own' )                     or diag sprintf '%04o', mode($mirror);

    my $tree = $spoke->worktree( $tmp->child( 'ws', 'work', 9, 'Test-Org', 'one' ), branch => 'clod/9-sealed', base => 'main' );
    my ($gitdir) = $tree->child('.git')->slurp =~ m{\Agitdir:\ ([^\n]+)};
    is( [ map { mode($_) & oct '0022' } $tree->child('.git'), $gitdir, "$gitdir/commondir" ], [ 0, 0, 0 ], 'a worktree that the worker runs git in is sealed too' );
    $spoke->remove_worktree($tree);
    umask $umask;
};

subtest 'git refuses what the agent could change' => sub {
    my $mirror = $spoke->fetch;
    my $config = $mirror->child('config');
    my $was    = mode($config);
    chmod $was | oct '0002', "$config" or die "chmod $config: $!";
    like( dies { $spoke->git( q{-C}, "$mirror", qw{rev-parse HEAD} ) }, qr{refused,\ because\ every\ account\ can\ write\ \Q$config\E}, 'the worker runs no git in a bare clone whose configuration another account can write' );
    chmod $was, "$config" or die "chmod $config: $!";

    my $owner = $mirror->dirname;
    my $above = mode($owner);
    chmod $above | oct '0002', "$owner" or die "chmod $owner: $!";
    like( dies { $spoke->git( q{-C}, "$mirror", qw{rev-parse HEAD} ) }, qr{refused,\ because\ every\ account\ can\ write\ \Q$owner\E}, 'nor in one that another account could put in its place' );
    chmod $above | oct '1002', "$owner" or die "chmod $owner: $!";
    ok( lives { $spoke->git( q{-C}, "$mirror", qw{rev-parse HEAD} ) }, 'unless the directory above has the sticky bit' ) or diag $@;
    chmod $above, "$owner" or die "chmod $owner: $!";

    my $tree = $spoke->worktree( $tmp->child( 'ws', 'work', 10, 'Test-Org', 'one' ), existing => 'main' );
    my $open = $tree->child(qw{git-hooks pre-commit});
    chmod mode($open) | oct '0002', "$open" or die "chmod $open: $!";
    like( dies { App::Clod::Spoke::commit( $tree, qw{--quiet --allow-empty -m}, 'by the worker' ) }, qr{refused,\ because\ every\ account\ can\ write\ \Q$open\E}, 'a commit of the worker runs no hook that another account can write' );
    like( dies { $spoke->git( q{-C}, "$tmp", 'status' ) },                                           qr{is\ not\ a\ git\ repository},                              'nor git in a directory that is no repository, where git would look above it' );
    $spoke->remove_worktree($tree);
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
    is( $spoke->commits_dropped( $tree, $sha ),                  0,    'a head drops no commit of itself' );
    git( q{-C}, "$tree", qw{checkout --quiet --detach HEAD^} );
    is( $spoke->commits_dropped( $tree, $sha ), 1, 'and a head before it drops the commit' );

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

    foreach my $worktree ( $first, $second ) { $spoke->remove_worktree($worktree) }
};

subtest 'the secrets of the worker, kept from the hooks of its commit' => sub {
    my $seen = $tmp->child('hook-env');
    hooks_branch( 'hooks-env', 'pre-commit' => qq{env > $seen} );
    my $tree   = $spoke->worktree( $tmp->child( 'ws', 'work', 11, 'Test-Org', 'one' ), existing => 'hooks-env' );
    my %secret = map { $_ => "secret-$_" } qw{GH_TOKEN GITHUB_TOKEN CLAUDE_CODE_OAUTH_TOKEN};
    {
        local @ENV{ keys %secret } = values %secret;
        App::Clod::Spoke::commit( $tree, qw{--quiet --allow-empty -m}, 'by the worker' );
        is( [ grep { exists $ENV{$_} } sort keys %secret ], [ sort keys %secret ], 'the worker keeps its secrets after the commit' );
    }
    my %env = map { split m{=}, $_, 2 } grep { m{=} } split m{\n}, $seen->slurp;
    is( [ grep { exists $env{$_} } sort keys %secret ], [], 'but the hooks of the commit get none of them, as they need none' );
    $spoke->remove_worktree($tree);
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
# makes it take every repository for one.  So the agent can only clone the
# bare clone, and push to it, when it trusts it.  The switch is off for a
# fetch or a push of the worker, because the remote on disk stands for GitHub,
# which no test of ownership reaches.  The agent is the same account here, so
# a command of the agent is one that starts with env CLOD_TEST_AS_AGENT=1.
my @AS_AGENT = qw{env CLOD_TEST_AS_AGENT=1};

# A spoke whose agent is recorded in @$asked, in a workspace that is a
# symbolic link, and a sub that runs code as if each repository were another
# account's.
sub agent_spoke ($asked) {
    my $link = $tmp->child('ws-link');
    if ( !-l $link ) { symlink "$tmp/ws", "$link" or die "symlink $link: $!" }
    my $agent = App::Clod::Spoke->new(
        repo         => 'Test-Org/one',
        workspace    => "$link",
        github_web   => "file://$tmp/remote",
        token        => 'test-token',
        author_name  => 'test-bot',
        author_email => 'bot@test.test',
        as_agent     => sub (@cmd) { push @$asked, [@cmd]; return ( @AS_AGENT, @cmd ) },
    );
    my $foreign = sub ($code) {
        local $ENV{GIT_TEST_ASSUME_DIFFERENT_OWNER} = 1;
        return $code->();
    };
    return ( $agent, $link, $foreign );
}

subtest 'a clone that the agent owns' => sub {
    my @asked;
    my ( $agent, $link, $foreign ) = agent_spoke( \@asked );
    my $mirror = $agent->fetch;
    my $mock   = Test::MockModule->new('App::Clod::Spoke');
    $mock->redefine( fetch  => sub ($self) { return $mirror } );
    $mock->redefine( is_own => sub ($path) { return 0 } );

    # Each git command of the worker that names a directory of the agent.
    my $tree = $link->child( 'work', 5, 'Test-Org', 'one' );
    my $real = $tmp->child( 'ws', 'work', 5, 'Test-Org', 'one' );
    my @intruded;
    my $run_git = $mock->original('run_git');
    $mock->redefine(
        run_git => sub ( $cmd, @rest ) {
            push @intruded, "@$cmd" if $cmd->[0] ne $AS_AGENT[0] && List::Util::any { index( $_, "$tree" ) >= 0 || index( $_, "$real" ) >= 0 } @$cmd;
            return $run_git->( $cmd, @rest );
        }
    );

    $foreign->( sub { $agent->worktree( $tree, branch => 'clod/5-agent', base => 'main', agent => 1 ) } );
    ok( -d $tree->child('.git'), 'the agent makes a clone, whose .git is its own, and no worktree of the bare clone' );
    my $trusts  = qr{\Agit\ -c\ core\.hooksPath=/dev/null\ clone\ };
    my $safe    = qr{safe\.directory='?\Q$tmp\E/ws/mirrors/Test-Org/one\.git'?};
    my $uploads = qr{-u\ git\ -c\ $safe\ upload-pack\ };
    my $from    = qr{\Q$tmp\E/ws/mirrors/Test-Org/one\.git\ \S+\z};
    like( "@{ $asked[0] // [] }", qr{$trusts.*$uploads.*$from}, 'with git, trusting the real path of the bare clone, and running no hook' );
    is( scalar( grep { $_->[0] eq 'git' } @asked ),                                              scalar @asked,                                    'and the agent runs each command of it' );
    is( $tree->child(qw{.git objects info alternates})->slurp,                                   $mirror->realpath->child('objects') . "\n",       'the clone reads the objects of the bare clone, and copies none' );
    is( git( q{-C}, "$tree", qw{rev-parse --abbrev-ref HEAD} ),                                  'clod/5-agent',                                   'a new branch, checked out' );
    is( git( q{-C}, "$tree", qw{rev-parse HEAD} ),                                               git( q{--git-dir}, "$bare", qw{rev-parse main} ), 'at the base on the remote' );
    is( [ map { git( q{-C}, "$tree", 'config', $_ ) } qw{user.name user.email core.hooksPath} ], [qw{test-bot bot@test.test git-hooks}],           'with the author, and the hooks of its branch' );

    $tree->child('patched')->spew("old\n");
    git( q{-C}, "$tree", qw{add patched} );
    git( q{-C}, "$tree", qw{commit --quiet --no-verify -m base} );
    $tree->child('patched')->spew("new\n");
    my $patch = git( q{-C}, "$tree", qw{diff --binary} ) . "\n";
    git( q{-C}, "$tree", qw{checkout --quiet -- patched} );
    $foreign->( sub { $agent->apply_patch( $tree, $patch ) } );
    like( "@{ $asked[-1] }", qr{apply\ --index\z}, 'the agent applies a patch to its clone' );
    is( $tree->child('patched')->slurp,                       "new\n",   'to the file' );
    is( git( q{-C}, "$tree", qw{diff --cached --name-only} ), 'patched', 'and to the index' );

    # The agent owns its clone, and can point its .git anywhere.
    my $dot = $tree->child('.git');
    chmod mode($dot) | oct '0002', "$dot" or die "chmod $dot: $!";
    like( dies { $agent->git( q{-C}, "$tree", qw{rev-parse HEAD} ) }, qr{refused}, 'the worker runs no git in a clone that another account can change' );
    is( $foreign->( sub { $agent->commits_since( $tree, 'origin/main' ) } ), 1, 'but counts the commits of the clone, which the agent pushed to the bare clone' );
    my $sha = $agent->push_branch( $tree, 'clod/5-agent' );
    is( git( '--git-dir', "$bare", 'rev-parse', 'clod/5-agent' ), $sha,                                      'and pushes them, from the bare clone' );
    is( $sha,                                                     git( q{-C}, "$tree", qw{rev-parse HEAD} ), 'and they are the HEAD of the clone' );
    my $ref = App::Clod::Spoke::handback_ref($tree);
    like( $ref, qr{\Arefs/clod/handback/[[:xdigit:]]{40}\z}, 'which the bare clone holds under a ref of the clone' );
    chmod mode($dot) & ~oct('0002'), "$dot" or die "chmod $dot: $!";

    my $asked = @asked;
    $foreign->( sub { $agent->remove_worktree($tree) } );
    is( [ map { "@$_" } @asked[ $asked .. $#asked ] ], ["rm -rf -- $tree"], 'the agent removes its clone' );
    ok( !-d $tree, 'and it is gone' );
    is( git( '--git-dir', "$mirror", qw{for-each-ref --format=%(refname)}, $ref ), q{}, 'and so is its ref in the bare clone' );
    is( \@intruded,                                                                [],  'and the worker ran no git in the clone, nor named it to git' );

    $mock->redefine( is_own => sub ($path) { return 1 } );
    my $own = $foreign->( sub { $agent->worktree( $link->child( 'work', 6, 'Test-Org', 'one' ), detach => 'main' ) } );
    $asked = @asked;
    $foreign->( sub { $agent->remove_worktree($own) } );
    is( scalar @asked, $asked, 'the worker makes and removes a worktree of its own, with no agent' );
    ok( !-d $own, 'and it is gone' );
};

# A rebase that stops on a conflict deletes refs as it goes on, and git locks
# packed-refs for that, beside the configuration of the repository.  The bare
# clone is sealed from the agent, and here a mode of 0555 stands for that.
subtest 'a rebase that stops, in a clone of the agent' => sub {
    my $dir = $tmp->child('rebase-seed');
    git( qw{clone --quiet}, "$bare", "$dir" );
    my @id = qw{-c user.name=t -c user.email=t@test.test};
    $dir->child('conflict')->spew("base\n");
    git( q{-C}, "$dir", qw{add conflict} );
    git( q{-C}, "$dir", @id, qw{commit --quiet --no-verify -m}, 'the base moves' );
    git( q{-C}, "$dir", qw{push --quiet origin HEAD:refs/heads/rebase-base} );
    git( q{-C}, "$dir", qw{reset --quiet --hard HEAD^} );
    $dir->child('conflict')->spew("ours\n");
    git( q{-C}, "$dir", qw{add conflict} );
    git( q{-C}, "$dir", @id, qw{commit --quiet --no-verify -m}, 'a change that conflicts' );
    $dir->child('kept')->spew("kept\n");
    git( q{-C}, "$dir", qw{add kept} );
    git( q{-C}, "$dir", @id, qw{commit --quiet --no-verify -m}, 'a change that does not' );
    git( q{-C}, "$dir", qw{push --quiet origin HEAD:refs/heads/rebase-ours} );

    my @asked;
    my ( $agent, $link, $foreign ) = agent_spoke( \@asked );
    my $fetched = $agent->fetch;
    my $mock    = Test::MockModule->new('App::Clod::Spoke');
    $mock->redefine( fetch  => sub ($self) { return $fetched } );
    $mock->redefine( is_own => sub ($path) { return 0 } );
    my $tree   = $foreign->( sub { $agent->worktree( $link->child( 'work', 12, 'Test-Org', 'one' ), existing => 'rebase-ours', agent => 1 ) } );
    my $mirror = $agent->mirror->realpath;
    my $was    = mode($mirror);
    chmod oct '0555', "$mirror" or die "chmod $mirror: $!";

    ok( dies { git( q{-C}, "$tree", qw{rebase origin/rebase-base} ) }, 'a rebase onto the moved base stops on the conflict' );
    ok( lives { git( q{-C}, "$tree", qw{rebase --skip} ) },            'and the agent can skip the commit that conflicts, and finish the rebase' ) or diag $@;
    ok( !-e $tree->child(qw{.git rebase-merge}),                       'so no rebase is in progress' );
    my $head = $foreign->( sub { $agent->head($tree) } );
    chmod $was, "$mirror" or die "chmod $mirror: $!";

    is( git( q{--git-dir}, "$mirror", qw{rev-parse},        "$head^" ),                    git( q{--git-dir}, "$mirror", qw{rev-parse origin/rebase-base} ), 'the rebased head reaches the bare clone, on the base' );
    is( git( q{--git-dir}, "$mirror", qw{rev-list --count}, "origin/rebase-base..$head" ), 1,                                                                'without the commit that the rebase skipped' );
    $agent->push_branch( $tree, 'rebase-ours' );
    is( git( q{--git-dir}, "$bare", qw{show rebase-ours:kept} ), 'kept', 'and the worker pushes it, with the commit that the rebase kept' );
    $foreign->( sub { $agent->remove_worktree($tree) } );
};

subtest git => sub {
    like( dies { $spoke->git(qw{rev-parse --verify no-such-ref}) }, qr/\Agit\ rev-parse\ --verify\ no-such-ref:\ fatal:\ [^\n]+\n\z/, 'a failing git command dies with its error, on one line, with no file or line' );
    ok( !( grep { m{test-token} } git( '--git-dir', $spoke->mirror->to_string, 'config', '--list' ) ), 'the token is not in the clone\'s configuration' );
};

done_testing;
