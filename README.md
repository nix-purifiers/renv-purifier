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
fields) an online restore records.

`renv-purifier lock` reads `renv.lock` and builds each package's download URL
the way renv's retrieval code does:

| `renv.lock` source | Download |
|---|---|
| CRAN or another CRAN-like repository | `src/contrib/<file>`, with the repository's `Archive/` URLs as mirrors, because CRAN moves a superseded version there |
| Bioconductor | the release's repositories, and the commit the package was built from when Bioconductor no longer serves the version |
| GitHub, GitLab, Bitbucket | the host's tarball of the locked commit |
| git | a checkout of the locked commit, packed into a tarball by Nix |
| URL | the file, with a zip file repacked into a tarball by Nix |
| a directory in the project | none: renv installs it from the project |
| a directory outside the project | none: Nix packs it into a tarball (see `localPackages` below) |

It downloads each file and records its hash. It installs nothing: every
package is compiled later, in the Nix sandbox. For a project that uses
Bioconductor, it also holds the Bioconductor configuration file, which
BiocManager reads to check the release offline.

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

We recommend following the nixpkgs input of renv-purifier, as above. A
package built for one R minor release does not load in another, so the
builder refuses a lockfile whose `renv.lock` names another R minor release
than the package set has. Pass an `R` of that release through
`buildRenvProject.override`.

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

## Credit

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo), and renv-purifier
follows the design of
[sbt-purifier](https://github.com/nix-purifiers/sbt-purifier).

## License

MIT.
