# Commands

Run every command from the repository root.

- `nix flake check -L` builds the command, runs the unit tests of the lock
  run's record planning (`pkgs/renv-purifier/test-records.R`), builds the
  fixtures under `tests/fixtures` in the sandbox and runs them, builds the
  library of the pinned real-world project r-hub/cransays
  (`tests/real/cransays`), runs the sandboxed conformance checks of the
  purifier contract (stale, tampered, missing, malformed, offline and
  external), and checks the formatting.
- `tests/cli.sh` tests what runs outside the sandbox on copies of the
  fixtures: the lock run reproduces the committed lockfiles byte for byte,
  `prefetch` installs a project library that loads with every network
  request refused, a lockfile kept outside the project works, adding a
  dependency and relocking works, the common mistakes stop with a message
  that names the fix, and `publish` makes a repository that
  `install.packages()` installs the package from. It needs network access.
- `tests/relock-fixtures.sh` relocks every fixture and the cransays
  lockfile in place. The conformance-relock job of CI runs it and fails on
  a difference. Commit the new lockfiles after a fixture's `renv.lock` or
  the lock format changes.
- `tests/conformance-update.sh` runs `renv-purifier update glue` on a copy
  of the `update` fixture and checks both lockfiles afterwards. It needs
  network access.
- The conformance-rebuild job of CI builds the `rebuild-release` and
  `rebuild-package` checks twice, the second time with `--rebuild`.

The fixtures' `renv.lock` files were written with `renv::record()` from
repository metadata, so nothing was installed to make them:

- `hello` is an R package with dependencies from CRAN (current, archived,
  and packages that link libxml2 and openssl), GitHub, a git repository, a
  URL, a local directory and Bioconductor.
- `sources` is a project with no DESCRIPTION, a package locked as a zip
  file, and a local package outside the project
  (`tests/fixtures/shared/greeter`).
- `editor` holds the R language server, languageserver, and its
  dependencies.
- `old-renv` pins renv 1.2.3.
- `update` pins glue 1.6.2, for conformance-update.
