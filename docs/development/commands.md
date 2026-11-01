# Commands

Run every command from the repository root.

- `nix flake check -L` builds the command, runs the unit tests of the lock
  run's record planning (`pkgs/renv-purifier/test-records.R`), builds the
  three fixtures under `tests/fixtures` in the sandbox and runs them, builds
  the pinned real-world project r-hub/cransays (`tests/real/cransays`),
  checks that stale, edited and unreachable lockfiles are refused, and
  checks the formatting.
- `tests/cli.sh` tests what runs outside the sandbox on copies of the
  fixtures: the lock run reproduces the committed lockfiles byte for byte,
  `build` builds a working environment, `restore` installs the project
  library with every network request refused, adding a dependency and
  relocking works, the common mistakes stop with a message that names the
  fix, and `publish` makes a repository that `install.packages()` installs
  the package from. It needs network access.
- `nix run .#cli -- lock tests/fixtures/hello` relocks a fixture after its
  `renv.lock` changes. Commit the new `renv-purifier.lock.json`.

The fixtures' `renv.lock` files were written with `renv::record()` from
repository metadata, so nothing was installed to make them:

- `hello` is an R package with dependencies from CRAN (current, archived,
  and one that links libxml2), GitHub, a git repository, a URL, a local
  directory and Bioconductor.
- `sources` is a project with no DESCRIPTION, a package locked as a zip
  file, and a local package outside the project
  (`tests/fixtures/shared/greeter`).
- `editor` holds the R language server, languageserver, and its
  dependencies.

`tests/real/cransays/renv-purifier.lock.json` is the purifier lockfile of
r-hub/cransays at the commit `tests/default.nix` pins. Relock it with
`nix run .#cli -- lock` on a checkout of that commit when the lock format
changes.
