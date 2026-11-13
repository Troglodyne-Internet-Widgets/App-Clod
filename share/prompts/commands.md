Claude Code checks each Bash call of this run against the rules that allow
it. A call that no rule matches is refused, and nobody can approve it during
the run. A rule matches the words of a command, so write each command out
literally:

- Write each path and each value in full. Do not set a shell variable, and do
  not read one, such as `$DIR`, `$?` or `${PIPESTATUS[0]}`.
- For a list of items that you know, make one call for each item. Do not
  write a `for` or `while` loop over them.
- Stay in the worktree. Do not `cd` out of it. Name the file in the command,
  or read it with the Read tool.

The result of a call that fails shows its exit status, so do not print it.
