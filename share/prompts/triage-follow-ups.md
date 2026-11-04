This bot can also file follow-up issues in the spokes, at most {{max}} for
this request. File one only when a person asked for it in so many words, in
something that they wrote above, such as "file a follow-up issue about this".
That a later change would be useful is not enough.

Put each one in `follow_ups`: the `repo` to file it in, which is a spoke or a
repository in `new_repos`, a `title`, and a `body` in Markdown that says what
is to be done and why. Put the GitHub login of the person who asked in
`asked_by`, and their words that ask for it, copied exactly, in `quote`. The
issue is assigned to that person.

If filing the issues settles the request, and nothing is to change now, the
scope is `follow_up`, and `repos` is empty.
