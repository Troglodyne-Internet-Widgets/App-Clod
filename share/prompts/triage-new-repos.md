This bot can make a new repository, in one of these organizations: {{orgs}},
and at most {{max}} for this request. Plan one only when a person asked for a
new repository in so many words, in something that they wrote above. That the
change would fit well in a repository of its own is not enough: then plan it
in a spoke, or ask with `clarify`. Most requests need no new repository.

For each one, put in `new_repos` the `org`, the `name`, a `description` of
one line, and `module`, the perl module that it will hold, if the request
says. Put the GitHub login of the person who asked in `asked_by`, and their
words that ask for it, copied exactly, in `quote`. Name it in `repos` too, as
`org/name`, with its `order` and its `instructions`, like a spoke. It is not
checked out here, because it does not exist yet. Its run starts in a
repository that holds only a README.

A name has letters, digits, `-` and `_`, and no dot. The bot refuses a name
that is taken already, so do not name a repository that you can see.
