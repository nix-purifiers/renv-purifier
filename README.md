# renv-purifier

A command and a Nix library that build R projects managed with
[renv](https://rstudio.github.io/renv/) in the Nix sandbox. The command
records the files renv wants to download for a project's `renv.lock` in a
second lockfile, and Nix builds the project from the two, offline. You
commit the lockfile, and no generated Nix files.

renv-purifier is one of the [nix-purifiers](https://nix-purifiers.github.io).

- **A lockfile.** `renv-purifier lock` writes `renv-purifier.lock.json`
  beside `renv.lock`. It holds the source tarball of every locked package,
  by URL and SHA-256, and names the package the project builds when the
  project is an R package.
- **Sandboxed builds.** `buildRenvProject` installs every locked package
  with renv's own `renv::restore()`, offline, and gives an R environment
  for the project. It builds the project's package with `R CMD build`, and
  runs `R CMD check` on request.
- **Offline restores.** `renv-purifier restore` runs `renv::restore()` in the
  project, with every package installed from the locked downloads.
- **Publishing what Nix built.** `renv-purifier publish` adds the package
  tarball Nix built to a CRAN-like repository.

## How it works

renv installs a package from its *cellar* before it downloads anything. The
cellar is a directory named by the environment variable
`RENV_PATHS_CELLAR`, in which renv looks for
`<package>/<package>_<version>.tar.gz`, or `<package>_<commit>.tar.gz` for a
package from a git host. renv checks the cellar for every source a
`renv.lock` record can have. renv-purifier builds a cellar from its
lockfile, so renv installs every package with its normal logic, and records
the same provenance (`RemoteType`, `RemoteSha` and the other `Remote`
fields) an online restore records. Like nixpkgs' own R builder, the cellar
points the interpreter lines of package scripts into the store, because
configure scripts often start with `#!/usr/bin/env sh`, and the Nix sandbox
has no `/usr/bin/env`.

`renv-purifier lock` reads `renv.lock` and builds each package's download URL
the way renv's retrieval code does:

| `renv.lock` source | Download |
|---|---|
| CRAN or another CRAN-like repository | `src/contrib/<file>`, with the repository's `Archive/` URLs as mirrors, because CRAN moves a superseded version there. The repository the record names comes first, then every repository `renv.lock` lists, as in renv: records often name the repository a package was first installed from, such as `RSPM`, which `renv.lock` does not list. |
| Bioconductor | the release's repositories, and the commit the package was built from when Bioconductor no longer serves the version |
| GitHub, GitLab, Bitbucket | the host's tarball of the locked commit |
| git | a checkout of the locked commit, packed into a tarball by Nix |
| URL | the file, with a zip file repacked into a tarball by Nix |
| a directory in the project | none: renv installs it from the project |
| a directory outside the project | none: Nix packs it into a tarball (see `localPackages` below) |

It downloads each file and records its hash. It installs nothing, and it
runs R with `--vanilla`, so the project's `.Rprofile` does not run: every
package is compiled later, in the Nix sandbox. A relock writes the same file
byte for byte. It takes about a minute for a project of a hundred packages.

For a project that uses Bioconductor, the cellar also holds a Bioconductor
configuration file that pairs the locked release with the R of the build.
BiocManager reads it to check the release, where it would otherwise download
the file Bioconductor publishes.

The lockfile is current while `renv.lock` is unchanged. Rerun
`renv-purifier lock` after `renv::snapshot()`.

## Use

Lock the project from its root and commit the lockfile:

```zsh
nix run github:nix-purifiers/renv-purifier -- lock
```

The flake's `overlays.default` adds `buildRenvProject` to a package set,
and a package written for `callPackage` takes it by name, like any other
builder:

```nix
# package.nix
{ buildRenvProject }:
(buildRenvProject { src = ./.; }).env
```

```nix
{
  inputs.renv-purifier.url = "github:nix-purifiers/renv-purifier";
  inputs.nixpkgs.follows = "renv-purifier/nixpkgs";

  outputs = { nixpkgs, renv-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          renv-purifier.overlays.default
          (final: prev: { analysis = final.callPackage ./package.nix { }; })
        ];
      };
    in
    {
      packages.${system}.default = pkgs.analysis;
    };
}
```

`buildRenvProject` returns these attributes:

- `env` holds `R` and `Rscript` in `bin`, with every locked package, and
  the project's own package when there is one, on their library path.
- `library` holds every locked package, installed in `library/`.
- `package` and `packages.<name>`, for a project that is an R package, hold
  the tarball `R CMD build` made, and the package installed in `library/`.
  `package.artifacts."<name>_<version>.tar.gz"` names the tarball, known
  from the lockfile before anything is built.
- `cellar` holds the source tarball of every locked package.

`nix/lib/build-renv-project.nix` documents the arguments: `doCheck` (runs
`R CMD check` on the project's package), `localPackages`,
`extraBuildInputs` and `extraNativeBuildInputs`, `fetchurl` (for
credentials or mirrors) and `srcFilter`.

Packages with compiled code get their system libraries from nixpkgs: for
each locked package, the builder takes the inputs nixpkgs' R package of the
same name declares, such as libxml2 for xml2. A package that nixpkgs does
not have, or one that needs more than nixpkgs declares, takes them through
`extraBuildInputs`.

A package whose build needs a system library at an exact version can only
build when nixpkgs has that version. The R package arrow is one: arrow
25.0.0 needs libarrow 25.0.0, and when nixpkgs has another version, its
configure script falls back to building its bundled C++ sources, which
download third-party libraries and fail offline. Lock a version of the
package that matches nixpkgs, or pass the matching library through
`extraBuildInputs`.

We recommend following the nixpkgs input of renv-purifier, as above. The
builder compiles every package from source with the R of the package set.
When `renv.lock` names another R minor release, the build goes ahead with a
warning, because old package versions sometimes do not compile with a newer
R. Then pass an `R` of the locked release through
`buildRenvProject.override`, or update the package with renv.

### Mistakes and their messages

Each common mistake stops the build or the command with a message that
names the fix:

| Mistake | Message |
|---|---|
| `renv.lock` changed after locking | `renv.lock in … changed after … was made; run renv-purifier lock.` |
| a package of `renv.lock` missing from the purifier lockfile | `renv.lock names <package>, which … has no entry for; run renv-purifier lock.` |
| `renv.lock` with merge conflict markers | `renv.lock is not valid JSON (look for merge conflict markers); fix it, or run renv::snapshot() again` |
| a malformed purifier lockfile | `renv-purifier.lock.json is not valid JSON; run renv-purifier lock to write it again` |
| an edited hash in the purifier lockfile | Nix's `hash mismatch in fixed-output derivation`, for that file |
| a package from outside the project that the build cannot reach | `renv.lock installs <package> from a directory outside the project; pass it as localPackages.<package>.` |

### Editors

R's language server is the R package languageserver, which editors such as
VS Code, Emacs and Neovim start for completion and diagnostics. Add it to the
project with renv like any other package. Then `env/bin/R` and an offline
`renv-purifier restore` provide it, and the tests start it from a
purifier-built environment and answer an LSP `initialize` request. RStudio
and Emacs Speaks Statistics run an ordinary R session, which works with
either.

### Packages outside the project

A `renv.lock` record for a package installed from a directory outside the
project, such as `../shared/greeter`, names that path. The builder finds the
package there when `src` reaches it. Otherwise, pass the directory as
`localPackages.<name>`:

```nix
buildRenvProject {
  src = ./.;
  localPackages.greeter = ../shared/greeter;
}
```

### Without Nix files

The command builds a project with the nixpkgs it was built with, without any
Nix files in the project:

```zsh
renv-purifier build        # result-env, and result-package for a package
renv-purifier restore      # renv::restore(), offline
```

`restore` runs `renv::restore()` in a shell with the compilers and system
libraries the sandboxed build has. It keeps the downloads alive with a GC
root in `renv/local`, which renv's own `.gitignore` excludes. renv may still
try to reach a git remote or a repository index before it installs, and it
carries on when that fails. When `renv.lock` changed after locking, it
restores the usual way and says so.

## Publishing

```zsh
renv-purifier publish path/to/repository
```

builds the project's package in the sandbox and adds its tarball to the
CRAN-like repository directory `path/to/repository`, then rewrites the
repository's `PACKAGES` index. Serve that directory over HTTP, or push it
to a repository host such as a drat repository on GitHub Pages, and
`install.packages()` installs from it.

CRAN itself takes packages through a web form, followed by a confirmation
email to the maintainer, so the submission cannot be automated. Submit the
tarball Nix built, from `package.artifacts`.

## Projects tried

renv-purifier was tried on these open-source projects, each pinned to a
commit:

- [r-hub/cransays](https://github.com/r-hub/cransays) at `aeaa139`: an R
  package with 67 CRAN packages, among them curl, openssl, xml2, stringi
  and ragg, which link system libraries. The lock run took 49 seconds. Most
  of its records name `RSPM`, a repository its `renv.lock` does not list,
  which is why the lock run tries every listed repository. It is the
  integration test in `tests/default.nix`.
- [langcog/wordbankr](https://github.com/langcog/wordbankr) at `86df76f`:
  107 packages from R 4.5.3, from Posit Package Manager and CRAN. The lock
  run took 68 seconds. It locks arrow 25.0.0, which does not build against
  the libarrow 24.0.0 of nixpkgs (see above).
- [pharmaverse/sdtm.oak](https://github.com/pharmaverse/sdtm.oak) at
  `6b5d887`: its committed `renv.lock` holds unresolved merge conflict
  markers, which `renv-purifier lock` reports as such.

## Credit

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo), and renv-purifier
follows the design of
[sbt-purifier](https://github.com/nix-purifiers/sbt-purifier).

## License

MIT.
