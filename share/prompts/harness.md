The hub ran the update of the harness standards in this repository, the
`conformance update` of Dist::Conformance. {{done}}

The update could not do these by itself, so they are yours:

{{left}}

Bring the code to the standards. Most of these are the critic and tidy
standards: a policy that the update added to `.perlcriticrc`, or a change of
`.perltidyrc`, that the code now breaks. Fix the code that perlcritic or
perltidy flags. Turn a policy off with `[-Name]` in `.perlcriticrc` only on
purpose, with the reason in a comment beside it and in the commit message,
and never only to make the code pass. Do not undo the update itself.

Commit through the hooks of this repository. Never use `--no-verify`, and
never change a hook so that a commit gets through.
