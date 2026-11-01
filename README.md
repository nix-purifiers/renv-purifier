# renv-purifier

A command and a Nix library that build R projects managed with
[renv](https://rstudio.github.io/renv/) in the Nix sandbox. renv's own
`renv.lock` names every package with its version and source. The command
records, in a second lockfile, the hashes of the downloads and the URLs that
`renv.lock` cannot give, and Nix builds the project from the two, offline.
You commit the lockfile, and no generated Nix files.

renv-purifier is one of the [nix-purifiers](https://nix-purifiers.github.io),
and meets their contract
([CONTRACT.md](https://github.com/nix-purifiers/purifier/blob/main/CONTRACT.md)).

## Quickstart

Lock the project from its root, where `renv.lock` is, and commit the
lockfile:

```zsh
nix run github:nix-purifiers/renv-purifier -- lock
```

Build it with the library's builder:

```nix
{
  inputs.renv-purifier.url = "github:nix-purifiers/renv-purifier";
  inputs.nixpkgs.follows = "renv-purifier/nixpkgs";

  outputs = { nixpkgs, renv-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      project = renv-purifier.lib.renv-purifier.buildRenvProject {
        inherit pkgs;
        src = ./.;
      };
    in
    {
      packages.${system}.default = project.packages.env;
      checks.${system}.default = project.tests;
    };
}
```

`buildRenvProject` returns these attributes:

- `packages.env` holds `R` and `Rscript` in `bin`, with every locked
  package, and the project's own package when there is one, on their library
  path.
- `packages.<name>`, for a project that is an R package, holds the package
  installed in `library/`.
- `tests` runs `R CMD check` on the release of a package. For a project
  that is not a package, it loads every locked package.
- `release`, for a package, holds the tarball `R CMD build` made, which
  `renv-purifier publish` adds to a repository.
  `release.artifacts."<name>_<version>.tar.gz"` names it at evaluation. It
  is null for a project that is not a package.
- `fetches` lists the download entries of the
  [purifier library](https://github.com/nix-purifiers/purifier) that the
  build fetches, for SBOM, license and vulnerability tools.
- `library` holds every locked package, `cellar` their source tarballs, and
  `interactive` what `renv-purifier prefetch` installs.

`lib.renv-purifier.readLock { src, lockFile ? ... }` reads `renv.lock` and
the purifier lockfile into the lock shape every purifier shares: `entries`,
`outputs` and `problems`.

The arguments, documented in `nix/lib/build-renv-project.nix`, are
`lockFile`, `fetchers` (passed to the purifier library's `fetchEntry`, for
credentials or a company mirror), `R`, `localPackages`, `extraBuildInputs`,
`extraNativeBuildInputs` and `srcFilter`.

A packaging flake can build a project whose author does not use
renv-purifier: it keeps the purifier lockfile itself and passes it as
`lockFile`, and the project's `src` holds only renv's files. The commands
take that lockfile through `--lockfile <path>` or the environment variable
`RENV_PURIFIER_LOCKFILE`.

## Everyday loop

The everyday loop is renv's own: R in the project, with `renv/activate.R`
loading the project library, `library()` calls, `renv::status()` and
`renv::snapshot()`. renv-purifier adds four commands, which take
`--project <dir>`, the current directory by default:

| Command | What it does |
|---|---|
| `renv-purifier lock` | Writes `renv-purifier.lock.json` for `renv.lock` as it is. A relock of an unchanged project writes the same file byte for byte. |
| `renv-purifier update [<package>...]` | Updates the packages named, or every package, with `renv::update()`, records them in `renv.lock` with `renv::snapshot()`, and relocks. |
| `renv-purifier prefetch` | Builds the locked library with Nix and installs it as the project library (below). |
| `renv-purifier publish <repository>` | Adds the release Nix built to the CRAN-like repository directory `<repository>`, and rewrites its `PACKAGES` index. |

After `renv::install()` and `renv::snapshot()` change `renv.lock`, rerun
`renv-purifier lock`. Until then, Nix and `prefetch` refuse the stale
lockfile and name that command.

A published repository directory works with `install.packages()` when it is
served over HTTP or pushed to a host such as a drat repository on GitHub
Pages. CRAN itself takes packages through a web form, followed by a
confirmation email to the maintainer, so a CRAN submission cannot be
automated. Submit the tarball from `release`.

## Offline work

`renv-purifier prefetch` builds every locked package in the Nix sandbox and
copies the result into the project library that `renv/activate.R` reads. It
keeps the build alive with a garbage-collector root at
`.renv-purifier/prefetch`, beside the purifier lockfile, in a directory that
leaves itself out of git. Nothing compiles on the developer's machine.

Afterwards, start R in the project from `.renv-purifier/prefetch/R/bin/R`,
the R release the library was built with. That R points BiocManager at the
Bioconductor configuration of the build, so a project with Bioconductor
packages loads without asking Bioconductor online, and it points renv at the
locked source tarballs, so `renv::restore()` works offline too. With it,
loading the project, its packages and the language server needs no network.

## Editor

R's language server is the R package languageserver, which editors such as
VS Code, Emacs and Neovim start for completion and diagnostics. Add it to the
project with renv like any other package. `prefetch` then installs it with
the rest of the library: point the editor's R at
`.renv-purifier/prefetch/R/bin/R`. The checks load it offline in a
prefetched project, and start it from `packages.env` and answer an LSP
`initialize` request. RStudio and Emacs Speaks Statistics run an ordinary R session,
which works the same way.

## Errors and fixes

Each common mistake stops `nix build` or the command with a message that
names the fix:

| Mistake | Message |
|---|---|
| `renv.lock` changed after locking | `… was made for another renv.lock: renv.lock changed after renv-purifier lock ran. Run renv-purifier lock.` |
| a package of `renv.lock` missing from the purifier lockfile | `renv.lock names <package>, which … has no entry for. Run renv-purifier lock.` |
| the purifier lockfile edited by hand | `… was changed after renv-purifier lock wrote it. Run renv-purifier lock to write it again.` |
| no purifier lockfile | `… does not exist. Run renv-purifier lock.` |
| a malformed purifier lockfile | `… is not valid JSON; if it was edited by hand or merged with conflicts, rewrite it with renv-purifier lock` |
| a lockfile of another format version | `… has lock format version <n>, and this library reads version 2. Run renv-purifier lock …` |
| `renv.lock` with merge conflict markers | `… renv.lock, which is not valid JSON; look for merge conflict markers, fix it, or run renv::snapshot() again` |
| a package from outside the project that the build cannot reach | `renv.lock installs <package> from <path>, a directory outside the project; pass it as localPackages.<package>.` |
| `renv.lock` made with another R minor release | a warning: the build goes ahead with the R it is given, and names the `R` argument and `renv-purifier update` for a package that fails to compile |

## Sources supported and refused

renv installs a package from its *cellar* before it downloads anything. The
cellar is a directory named by the environment variable
`RENV_PATHS_CELLAR`, in which renv looks for
`<package>/<package>_<version>.tar.gz`, or `<package>_<commit>.tar.gz` for a
package from a git host. renv checks the cellar for every source a
`renv.lock` record can have. The builder fetches every locked package into a
cellar and runs renv's own `renv::restore()` from it, with the renv release
of nixpkgs, so renv installs every package with its usual logic and records
the same provenance (`RemoteType`, `RemoteSha` and the other `Remote`
fields) an online restore records. Like nixpkgs' own R builder, the cellar
points the interpreter lines of package scripts into the store, because
configure scripts often start with `#!/usr/bin/env sh`, and the Nix sandbox
has no `/usr/bin/env`.

Nix derives each download from `renv.lock`, the way renv's retrieval code
does, and the purifier lockfile adds what `renv.lock` cannot give:

| `renv.lock` source | Download | The purifier lockfile records |
|---|---|---|
| CRAN or another CRAN-like repository | the source tarball. The lock run tries the repository the record names, then every repository `renv.lock` lists, current and `Archive/` URLs, as renv does: records often name the repository a package was first installed from, such as `RSPM`, which `renv.lock` does not list. | the URL that served it, and its hash |
| Bioconductor | the release's repositories, or, when Bioconductor no longer serves the version, the commit the package was built from | the URL and hash, or `fallback: "git"` and the hash of the checkout |
| GitHub, GitLab, Bitbucket | the host's tarball of the locked commit | its hash |
| git | a checkout of the locked commit, packed into a tarball by Nix | its hash |
| URL | the file, with a zip file repacked into a tarball by Nix | its hash |
| a directory in the project | none: renv installs it from the project | nothing |
| a directory outside the project | none: Nix packs it into a tarball, from the recorded path or `localPackages` | nothing |

renv-purifier refuses a source renv-purifier does not know, naming the
package. The lock run downloads each file and records its hash. It installs
nothing, and it runs R with `--vanilla`, so the project's `.Rprofile` does
not run. It takes about a minute for a project of a hundred packages. For a
project that uses Bioconductor, the cellar also holds a Bioconductor
configuration file that pairs the locked release with the R of the build,
which BiocManager reads in place of the file Bioconductor publishes.

Packages with compiled code get their system libraries from nixpkgs: for
each locked package, the builder takes the inputs nixpkgs' R package of the
same name declares, such as libxml2 for xml2, and gives every compiled
package a runtime path to them. A package that nixpkgs does not have, or one
that needs more than nixpkgs declares, takes them through
`extraBuildInputs`. A package whose build needs a system library at an exact
version builds only when nixpkgs has that version. The R package arrow is
one: arrow 25.0.0 needs libarrow 25.0.0, and when nixpkgs has another
version, its configure script falls back to building its bundled C++
sources, which download third-party libraries and fail offline. Lock a
version of the package that matches nixpkgs, or pass the matching library
through `extraBuildInputs`.

The release and the project's package rebuild bit for bit. The library of
dependencies does not: R and renv unpack each package into a randomly named
temporary directory, and the help pages R installs record that path.

## Real-world projects

renv-purifier was tried on these open-source projects, each pinned to a
commit:

- [r-hub/cransays](https://github.com/r-hub/cransays) at `aeaa139`: 67 CRAN
  packages, among them curl, openssl, xml2, stringi and ragg, which link
  system libraries. Most of its records name `RSPM`, a repository its
  `renv.lock` does not list, which is why the lock run tries every listed
  repository. It is the integration test in `tests/default.nix`, with its
  purifier lockfile kept outside the project. At this commit cransays is a
  Quarto dashboard whose `DESCRIPTION` names a package with no R code left,
  so the check builds its environment and loads every package. It found
  three problems that renv-purifier fixes: openssl links with
  `-l:libssl.so.3`, which needs a runtime path the compiler wrapper does not
  add; the renv 1.2.3 it pins fails its own offline restore, so the builder
  restores with the renv of nixpkgs; and repository preference.
- [langcog/wordbankr](https://github.com/langcog/wordbankr) at `86df76f`:
  107 packages from R 4.5.3, from Posit Package Manager and CRAN. The lock
  run took 68 seconds. It locks arrow 25.0.0, which does not build against
  the libarrow 24.0.0 of nixpkgs (see above).
- [pharmaverse/sdtm.oak](https://github.com/pharmaverse/sdtm.oak) at
  `6b5d887`: its committed `renv.lock` holds unresolved merge conflict
  markers, which `renv-purifier lock` reports as such.

## Credits

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo), and renv-purifier
follows the design of
[sbt-purifier](https://github.com/nix-purifiers/sbt-purifier) and the
layout of [uv-purifier](https://github.com/nix-purifiers/uv-purifier). It
is MIT-licensed.
