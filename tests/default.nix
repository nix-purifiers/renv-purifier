# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked downloads and of the pinned
# real-world project. The checks named `conformance-*` are those of the
# purifier contract (github:nix-purifiers/purifier, CONTRACT.md).
# conformance-relock, conformance-rebuild and conformance-update need the
# network or a Nix of their own, so they are jobs of
# .github/workflows/check.yml.
{
  pkgs,
  # The renv-purifier command.
  cli,
  # The flake's library: `renv-purifier`, with the builder, and `purifier`.
  lib',
}:
let
  inherit (pkgs) lib runCommand;
  R = pkgs.R;

  # Every fixture builds the way a consumer's flake does: through the
  # library's builder, with a package set.
  build = args: lib'.renv-purifier.buildRenvProject ({ inherit pkgs; } // args);

  # An R package whose dependencies come from every source a lock records:
  # CRAN (current and archived), packages that link libxml2 and openssl,
  # GitHub, a git repository, a URL, a local directory in the project and
  # Bioconductor. Its tests are R CMD check of its release.
  hello = build { src = ./fixtures/hello; };

  # A project that is not an R package, with a package locked as a zip file
  # and one from a directory outside the project, which the builder finds at
  # the path renv.lock records.
  sources = build { src = ./fixtures/sources; };

  # A lock that pins renv 1.2.3. The build restores it with the renv of
  # nixpkgs, whatever renv version the lock records.
  oldRenv = build { src = ./fixtures/old-renv; };

  # A project whose renv.lock holds the R language server, languageserver,
  # and its dependencies, which editors start for completion and diagnostics.
  editor = build { src = ./fixtures/editor; };

  # The hello fixture without its purifier lockfile, built from the copy
  # kept outside the source, as a packaging flake builds a project its
  # author does not change.
  external = build {
    src = lib.fileset.toSource {
      root = ./fixtures/hello;
      fileset = lib.fileset.difference ./fixtures/hello ./fixtures/hello/renv-purifier.lock.json;
    };
    lockFile = ./fixtures/hello/renv-purifier.lock.json;
  };

  # A real-world project, pinned: r-hub/cransays, whose renv.lock holds 67
  # CRAN packages, among them curl, openssl, xml2, stringi and ragg, which
  # link system libraries. Its renv.lock names Posit Package Manager and
  # records most packages as coming from a repository it does not list
  # (RSPM). At this commit cransays is a Quarto dashboard: its DESCRIPTION
  # names a package whose R code was removed, so the check builds its
  # environment, not its package. The purifier lockfile is kept outside the
  # project.
  cransays = build {
    src = pkgs.fetchFromGitHub {
      owner = "r-hub";
      repo = "cransays";
      rev = "aeaa1397fdb453e0a5b710ddc03a3fa04a89cf39";
      sha256 = "031zzdi8sxzwx0xdfhqipk2rcd3hy494ydabgbs0129mbkk6sf55";
    };
    lockFile = ./real/cransays/renv-purifier.lock.json;
  };

  # Runs `renv-purifier prefetch` on a copy of a fixture, with the inputs Nix
  # built for it, in the sandbox, which has no network, then starts R in the
  # project the way a developer does: renv/activate.R loads renv and the
  # project library. `script` runs there.
  offline =
    name: fixture: project: script:
    runCommand "renv-purifier-test-offline-${name}" { nativeBuildInputs = [ cli ]; } ''
      export HOME=$TMPDIR
      cp -r ${fixture} project
      chmod -R u+w project
      cd project
      renv-purifier prefetch --inputs ${project.interactive}
      ${project.interactive}/R/bin/Rscript -e ${lib.escapeShellArg script}
      touch $out
    '';

  negative = import ./negative.nix { inherit pkgs; };
in
{
  inherit cli;

  # The plans of records.R for every source renv.lock can hold.
  records = runCommand "renv-purifier-records" { nativeBuildInputs = [ R ]; } ''
    Rscript --vanilla ${../pkgs/renv-purifier/test-records.R} ${../pkgs/renv-purifier}
    touch $out
  '';

  hello-library = hello.library;
  hello = hello.packages.hello;
  hello-tests = hello.tests;

  # The environment loads the project's package and every dependency.
  hello-runs = runCommand "hello-runs" { } ''
    ${hello.packages.env}/bin/Rscript -e 'result <- hello::hello("you"); cat(result$json, result$glue, result$size, sep = "\n")' > output
    grep -qx '{"hello":"you"}' output
    grep -qx 'Hello, you' output
    grep -qx '1.34 kB' output
    touch $out
  '';

  # The builder names the release tarball at evaluation, and the release
  # holds it.
  hello-release = runCommand "hello-release" { } ''
    test -f ${hello.release.artifacts."hello_1.0.0.tar.gz"}
    test -f ${hello.packages.hello}/library/hello/DESCRIPTION
    touch $out
  '';

  # renv installed the GitHub and git packages from the cellar with the same
  # provenance an online restore records.
  hello-provenance = runCommand "hello-provenance" { } ''
    library=${hello.library}/library
    grep -qx 'RemoteSha: 094469afaf033af00aeb46527970f1db22f4d49d' $library/praise/DESCRIPTION
    grep -qx 'RemoteType: git' $library/prettyunits/DESCRIPTION
    grep -qx 'RemoteSha: a321ec23ea30b904540bb8b0d30f2a519512d90e' $library/prettyunits/DESCRIPTION
    test -f $library/BiocGenerics/DESCRIPTION
    test -f $library/hellohelper/DESCRIPTION
    touch $out
  '';

  # What `renv-purifier publish` does with the release: a CRAN-like
  # repository that install.packages() installs it from.
  hello-publish = runCommand "hello-publish" { nativeBuildInputs = [ R ]; } ''
    mkdir -p repository/src/contrib library
    install -m 644 ${hello.release.artifacts."hello_1.0.0.tar.gz"} repository/src/contrib/
    Rscript --vanilla -e 'tools::write_PACKAGES("repository/src/contrib", type = "source")'
    R_LIBS_SITE=${hello.library}/library Rscript --vanilla -e '
      install.packages("hello", repos = paste0("file://", normalizePath("repository")), lib = "library", type = "source")
      library(hello, lib.loc = "library")
      stopifnot(identical(hello("you")$glue, "Hello, you"))
    '
    touch $out
  '';

  # The download entries the build fetches, for SBOM, license and
  # vulnerability tools: file entries for the repository, GitHub and URL
  # packages, and a git entry for the git package.
  hello-fetches =
    let
      kinds = map (
        entry:
        if entry ? git then
          "git"
        else if entry ? url then
          "file"
        else
          "other"
      ) hello.fetches;
    in
    assert lib.elem "git" kinds && lib.elem "file" kinds && !lib.elem "other" kinds;
    runCommand "hello-fetches" { } "touch $out";

  sources-runs = runCommand "sources-runs" { } ''
    ${sources.packages.env}/bin/Rscript ${./fixtures/sources/greet.R} > output
    grep -qx 'Hi, you' output
    grep -qx 'TRUE' output
    touch $out
  '';
  sources-tests = sources.tests;

  # A lock made with an older renv restores, and the library holds the renv
  # version the lock records.
  old-renv-runs = runCommand "old-renv-runs" { } ''
    ${oldRenv.packages.env}/bin/Rscript -e '
      stopifnot(packageVersion("renv") == "1.2.3")
      stopifnot(nzchar(praise::praise()))
      stopifnot(is.function(BiocGenerics::combine))
    '
    touch $out
  '';

  # The language server starts from the environment and answers an LSP
  # initialize request, as it does for an editor.
  editor-languageserver = runCommand "editor-languageserver" { } ''
    request='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}'
    printf 'Content-Length: %d\r\n\r\n%s' "''${#request}" "$request" > input
    ${editor.packages.env}/bin/Rscript -e 'languageserver::run()' < input > output 2> log || true
    grep -q '"capabilities"' output || { cat log; exit 1; }
    touch $out
  '';

  # The pinned real-world project: its environment loads every locked
  # package.
  cransays = cransays.packages.env;
  cransays-runs = runCommand "cransays-runs" { } ''
    export HOME=$TMPDIR
    ${cransays.packages.env}/bin/Rscript -e '
      packages <- names(jsonlite::read_json(commandArgs(TRUE)[1])$Packages)
      for (package in packages)
        if (!requireNamespace(package, quietly = TRUE))
          stop(package, " does not load")
      cat(length(packages), "packages load\n")
    ' ${cransays.library.src}/renv.lock
    touch $out
  '';

  # After `prefetch`, R started in the project loads the project library with
  # no network: the packages from every source, and the language server an
  # editor starts.
  conformance-offline = offline "hello" ./fixtures/hello hello ''
    source("renv/activate.R")
    for (package in c("praise", "prettyunits", "xml2", "openssl", "BiocGenerics", "hellohelper", "glue"))
      stopifnot(requireNamespace(package, quietly = TRUE))
    stopifnot(packageVersion("glue") == "1.6.2")
  '';
  offline-editor = offline "editor" ./fixtures/editor editor ''
    source("renv/activate.R")
    stopifnot(requireNamespace("languageserver", quietly = TRUE))
  '';

  conformance-external = runCommand "conformance-external" { } ''
    ${external.packages.env}/bin/Rscript -e 'stopifnot(identical(hello::hello("you")$glue, "Hello, you"))'
    touch $out
  '';

  inherit (negative)
    conformance-stale
    conformance-tampered
    conformance-missing
    conformance-malformed
    ;

  # Builds of the hello fixture that the conformance-rebuild job of CI
  # builds twice with `nix build --rebuild`: its release and its package.
  rebuild-release = hello.release;
  rebuild-package = hello.packages.hello;
}
