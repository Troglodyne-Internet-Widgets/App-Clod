---
name: inspecting-clod
description: Find out why a job of a running clod failed, from its Minion record and the transcript of its claude runs, without reading a secret.  Use when the user says that a job, a fix or a scan on the bot failed, or asks what a run did.
---

# Inspecting a running clod

A job of the bot keeps what it did in Minion: its arguments, its notes and its
result.  A job that runs claude also keeps the transcript of each run in the
evidence directory, with the output of each tool.  The result says that a run
failed.  The transcript says why.

The examples use these names:

- `$host` is the host that runs the bot.
- `$home` is the application home, `install_dir/domain` in the clod recipe of
  trog-provisioner.
- `$user` is the account of the worker, and `$agent` is the account that
  claude runs as (`agent_user` in that recipe).
- `$id` is the id of a Minion job.

## Run clod as the worker

Run each `clod` command as `$user`, with `CLOD_CONFIG` set to its
`clod.conf`.  The clod recipe of trog-provisioner writes `$home/clod-run.sh`,
which does this:

    ssh $host 'cd $home && sudo $home/clod-run.sh minion job -l 20'

Run it from a directory that `$user` can read, such as `$home`.  The script
keeps the directory of the caller.  From your own home directory, a tool that
looks up its directory fails with "Permission denied".

The script does not load `clod.env`.  So a command that it runs has no GitHub
token and no Claude token.  That does not make every command safe.  A command
that runs jobs still runs them, in the wrong environment.

## Read, do not run

The service already runs the worker of the bot.  These commands are for
reading:

    clod minion job -w                        # the workers
    clod minion job -l 20                     # the jobs, newest first
    clod minion job $id                       # one job

Do not run `clod minion worker`, `clod daemon` or `clod prefork` through the
script.  Each one starts a process that takes jobs from the real queue.  A
job that it takes runs without the tokens and in your directory.  So the job
fails or returns a wrong result, and the dashboard shows that result.
`minion worker` does not list the workers.  It starts one.

A command that changes the queue, such as `minion job -e`, a retry or a
remove, is for the user to decide.  Use the dashboard, or ask the user first.

If you started a worker by mistake, do these steps:

1. List the workers with `clod minion job -w`, and find each process with
   `ps`.  The worker of the service has init as its parent.  Yours has
   `runuser` as its parent and your directory as its directory.  The command
   `readlink /proc/$pid/cwd` shows the directory.
2. Stop yours with `kill -TERM $pid`.  It finishes the job that it holds
   first.
3. Make sure that `clod minion job -w` lists only the worker of the service.
4. Find each job that your worker ran.  `clod minion job $id` names the
   worker of a job.  Tell the user about each one.  If one was a
   `self_check`, ask the user to queue a new one.  The dashboard shows the
   last check that finished until another one finishes.

If the host key of `$host` is not known, stop and ask the user.  Show them the
fingerprint that `ssh-keyscan $host | ssh-keygen -lf -` prints.  Do not accept
the key yourself.

## Find the job

    clod minion job -S failed -l 20           # the failed jobs, newest first
    clod minion job -t harness_fix -l 20      # the jobs of one task
    clod minion job $id                       # one job: args, notes, result

A request starts more than one job.  A `harness_fix` that leaves work for
claude finishes, and then queues a `spoke_fix` or a `spoke_address`.  So when
the user names one task, also list the failed jobs of every task, and match
them by `origin` and `repo` in their notes.

The `result` of a job holds `error`, `blocked` and `summary`.  `denied` holds
each tool call that claude refused, with the reason.  A job that kept its
commit for a retry has `kept` in its notes, with the sha.  A retry then pushes
that commit and does not redo the work.

## Read the transcript

    clod evidence $id

This prints the prompt of each run of each attempt, each tool call with its
input, each result, and the text of the model.  Each line has the seconds
since the run started.  The output is long, so save it to a file, then search
it for the error:

    grep -n -E 'not ok|Failed test|refused|fatal:' evidence.txt

A job that finished with no problem keeps no transcript.

## Read the result of a scan or a sweep

`clod eval` runs perl with the application loaded.  `last_result` returns
what the last job of a scheduled task returned:

    clod eval 'my $s = App::Clod::Tasks::last_result( app->minion, q{harness_scan} ); say for sort keys %{ $s->{repos} }'

The Overview, Work and Harness tabs of the health page show the same results.
The page and its `/api` are behind the `auth` configuration.

## Keep the secrets out of the transcript

Do not print `clod.env` or a value of `clod.conf`.  They hold the tokens of
the bot and the password hash of the page.  To learn which variables
`clod.env` sets, print the names only:

    grep -o '^[A-Za-z_]*' $home/clod.env

## Reproduce a failure as the agent

A run of claude works as `$agent`, in a clone that `$agent` owns, with its own
`TMPDIR`.  A test that passes as `$user` can fail as `$agent`.  For example,
a test can run git in a directory that another account owns.  To reproduce
the failure, run the tests as `$agent`, in the same conditions:

1. Write a short script that makes a directory with `mktemp -d` under `/tmp`,
   clones the repository into it, and runs `prove` there with `TMPDIR` in that
   directory.
2. Put `$home/agent-perl5/lib/perl5` on `PERL5LIB`, and its `bin` on `PATH`.
   `$agent` cannot read the local lib of the worker.
3. Run the script with `sudo -u $agent sh script.sh`.  The directory has mode
   0700, so the script must `cd` into it as `$agent`, and not before the sudo.
4. At the end, remove the directory in the same script.

Apply a patch in the clone before `prove` to test a fix before you commit it.

## When you report

Quote the lines that show the cause, with the names of hosts, accounts and
repositories taken out.  Say which job failed, what its transcript says, and
whether a retry is enough.  A retry is enough when the work is kept and only
a push or a network call failed.
