# Commands

Run every command from the repository root.

- `nix flake check -L` builds the command, runs the URL unit test
  (`pkgs/renv-purifier/test-urls.R`), builds both fixtures under
  `tests/fixtures` in the sandbox, runs them, and checks the formatting.
- `tests/cli.sh` tests what runs outside the sandbox on copies of the
  fixtures: the lock run reproduces the committed lockfiles, `build` builds a
  working environment, `restore` installs the project library with every
  network request refused, and `publish` makes a repository that
  `install.packages()` installs the package from. It needs network access.
- `nix run .#cli -- lock tests/fixtures/hello` relocks a fixture after its
  `renv.lock` changes. Commit the new `renv-purifier.lock.json`.

The fixtures' `renv.lock` files were written with `renv::record()` from
repository metadata, so nothing was installed to make them. `hello` is an R
package with dependencies from CRAN (current, archived, and one that links
libxml2), GitHub, a git repository, a URL, a local directory and
Bioconductor. `sources` is a project with no DESCRIPTION, a package locked
as a zip file, and a local package outside the project
(`tests/fixtures/shared/greeter`).
