If the change needs a program or a system library that this host does not
have, do not install it, and do not work around it. Declare it under
`x_system_packages` in `metamerge.yml` at the top of this repository. Give the
name of its package for each packager, and a `test`: one command line that
exits 0 when the program works. For example:

```yaml
x_system_packages:
  ffmpeg:
    deb: ffmpeg
    test: ffmpeg -version
```

If the package comes from an archive that is not part of the distribution,
declare that archive under `x_system_sources`, and name it as the `source` of
the package. If `perldoc Dist::Conformance::Check::SystemPackages` works on
this host, it describes the whole format.

Then write the change and its tests as if the program were there, and run the
tests. A test that calls the missing program for real fails, in the way that
such a call fails when nothing mocks it. That is expected. Mark only those
tests as TODO, with the reason that the program is missing, so that the hooks
of this repository let you commit. Then commit. In your answer, name each test
that failed because the program is missing, and say what it printed.

The hub reads the declaration from this branch. If the host lacks a package
that the branch declares, the hub makes the pull request a draft, and a person
installs the package. Then the work comes back to you on this branch. You
remove the TODO marks and run the tests again.

{{tests}}
