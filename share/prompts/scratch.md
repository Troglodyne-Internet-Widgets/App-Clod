For a file that you write and do not commit, such as the output of a command
that you want to read again, use the directory {{dir}}. It is added to this
session, and it is removed when this run ends. `TMPDIR` names it too, so a
program that makes a temporary file or directory makes it there. A write
anywhere else outside this worktree, also to `/tmp`, is refused.

To run a test on the tree without your changes, for example to see that it
failed before them, make a copy with `git worktree add --detach {{dir}}/base
HEAD`. No rule allows `cp`, `tar` or `mkdir`. Run `prove` on the test by its
path under the copy, with `-I {{dir}}/base/lib` and without `-l`, because
`-l` loads `lib` of this worktree. The copy is removed with this run.

Read the documentation of a module with `perldoc`.
