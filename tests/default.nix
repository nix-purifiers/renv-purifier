# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked downloads and of the pinned
# real-world project.
{
  pkgs,
  # The flake's default package overlay, which adds buildRenvProject.
  overlay,
  # The renv-purifier command.
  cli,
}:
let
  # Every fixture builds the way a consumer's package does: through
  # buildRenvProject of a package set the overlay applies to.
  withOverlay = pkgs.extend overlay;
  inherit (withOverlay) buildRenvProject R;

  # An R package whose dependencies come from every source a lock records:
  # CRAN (current and archived), a package that links libxml2, GitHub, a git
  # repository, a URL, a local directory in the project and Bioconductor.
  # R CMD check runs its tests in the build.
  hello = buildRenvProject {
    src = ./fixtures/hello;
    doCheck = true;
  };

  # A project that is not an R package, with a package locked as a zip file
  # and one from a directory outside the project, which the builder finds at
  # the path renv.lock records.
  sources = buildRenvProject { src = ./fixtures/sources; };

  # A lock that pins renv 1.2.3. The build restores it with the renv of
  # nixpkgs, whatever renv version the lock records.
  oldRenv = buildRenvProject { src = ./fixtures/old-renv; };

  # A project whose renv.lock holds the R language server, languageserver,
  # and its dependencies, which editors start for completion and diagnostics.
  editor = buildRenvProject { src = ./fixtures/editor; };

  # A real-world project, pinned: r-hub/cransays, an R package with 67 CRAN
  # packages, among them curl, openssl, xml2, stringi and ragg, which link
  # system libraries. Its renv.lock names Posit Package Manager and records
  # most packages as coming from a repository it does not list (RSPM).
  cransays = buildRenvProject {
    src = pkgs.fetchFromGitHub {
      owner = "r-hub";
      repo = "cransays";
      rev = "aeaa1397fdb453e0a5b710ddc03a3fa04a89cf39";
      sha256 = "031zzdi8sxzwx0xdfhqipk2rcd3hy494ydabgbs0129mbkk6sf55";
    };
    lockFile = ./real/cransays/renv-purifier.lock.json;
  };

  helloLock = builtins.fromJSON (builtins.readFile ./fixtures/hello/renv-purifier.lock.json);

  # A copy of the hello lock, with `f` applied.
  helloLockWith = f: builtins.toFile "renv-purifier.lock.json" (builtins.toJSON (f helloLock));

  # Whether buildRenvProject refuses the hello project with these arguments
  # when the library is evaluated.
  refuses =
    args:
    !(builtins.tryEval
      (buildRenvProject (
        {
          src = ./fixtures/hello;
        }
        // args
      )).library.drvPath
    ).success;
in
{
  inherit cli;

  # The plans of records.R for every source renv.lock can hold.
  records = pkgs.runCommand "renv-purifier-records" { nativeBuildInputs = [ R ]; } ''
    Rscript --vanilla ${../pkgs/renv-purifier/test-records.R} ${../pkgs/renv-purifier}
    touch $out
  '';

  hello-library = hello.library;
  hello = hello.package;

  # The environment loads the project's package and every dependency.
  hello-runs = pkgs.runCommand "hello-runs" { } ''
    ${hello.env}/bin/Rscript -e 'result <- hello::hello("you"); cat(result$json, result$glue, result$size, sep = "\n")' > output
    grep -qx '{"hello":"you"}' output
    grep -qx 'Hello, you' output
    grep -qx '1.34 kB' output
    touch $out
  '';

  # The lock names the package tarball before it is built, and it is in the
  # package.
  hello-artifacts = pkgs.runCommand "hello-artifacts" { } ''
    test -f ${hello.package.artifacts."hello_1.0.0.tar.gz"}
    test -f ${hello.package}/library/hello/DESCRIPTION
    touch $out
  '';

  # renv installed the GitHub and git packages from the cellar with the same
  # provenance an online restore records.
  hello-provenance = pkgs.runCommand "hello-provenance" { } ''
    library=${hello.library}/library
    grep -qx 'RemoteSha: 094469afaf033af00aeb46527970f1db22f4d49d' $library/praise/DESCRIPTION
    grep -qx 'RemoteType: git' $library/prettyunits/DESCRIPTION
    grep -qx 'RemoteSha: a321ec23ea30b904540bb8b0d30f2a519512d90e' $library/prettyunits/DESCRIPTION
    test -f $library/BiocGenerics/DESCRIPTION
    test -f $library/hellohelper/DESCRIPTION
    touch $out
  '';

  # What `renv-purifier publish` does with the tarball: a CRAN-like
  # repository that install.packages() installs it from.
  hello-publish = pkgs.runCommand "hello-publish" { nativeBuildInputs = [ R ]; } ''
    mkdir -p repository/src/contrib library
    install -m 644 ${hello.package.artifacts."hello_1.0.0.tar.gz"} repository/src/contrib/
    Rscript --vanilla -e 'tools::write_PACKAGES("repository/src/contrib", type = "source")'
    R_LIBS_SITE=${hello.library}/library Rscript --vanilla -e '
      install.packages("hello", repos = paste0("file://", normalizePath("repository")), lib = "library", type = "source")
      library(hello, lib.loc = "library")
      stopifnot(identical(hello("you")$glue, "Hello, you"))
    '
    touch $out
  '';

  sources-runs = pkgs.runCommand "sources-runs" { } ''
    ${sources.env}/bin/Rscript ${./fixtures/sources/greet.R} > output
    grep -qx 'Hi, you' output
    grep -qx 'TRUE' output
    touch $out
  '';

  # A lock made with an older renv restores, and the library holds the renv
  # version the lock records.
  old-renv-runs = pkgs.runCommand "old-renv-runs" { } ''
    ${oldRenv.env}/bin/Rscript -e '
      stopifnot(packageVersion("renv") == "1.2.3")
      stopifnot(nzchar(praise::praise()))
      stopifnot(is.function(BiocGenerics::combine))
    '
    touch $out
  '';

  # The language server starts from the environment and answers an LSP
  # initialize request, as it does for an editor.
  editor-languageserver = pkgs.runCommand "editor-languageserver" { } ''
    request='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}'
    printf 'Content-Length: %d\r\n\r\n%s' "''${#request}" "$request" > input
    ${editor.env}/bin/Rscript -e 'languageserver::run()' < input > output 2> log || true
    grep -q '"capabilities"' output || { cat log; exit 1; }
    touch $out
  '';

  # The pinned real-world project: its package builds, and its environment
  # loads it with every dependency.
  cransays = cransays.package;
  cransays-runs = pkgs.runCommand "cransays-runs" { } ''
    ${cransays.env}/bin/Rscript -e '
      library(cransays)
      for (package in c("curl", "openssl", "xml2", "stringi", "ragg", "dplyr", "reactable"))
        stopifnot(requireNamespace(package, quietly = TRUE))
    '
    touch $out
  '';

  # A lockfile the builder must refuse at evaluation: one made from another
  # renv.lock, one in another format, one with a package of renv.lock
  # deleted by hand, and one with a package from outside the project that
  # `src` does not reach. A lock made with another R release builds, with a
  # warning.
  stale-lock-refused =
    assert refuses {
      lockFile = helloLockWith (lock: lock // { renvLock = "0000"; });
    };
    assert refuses {
      lockFile = helloLockWith (lock: lock // { version = 0; });
    };
    assert refuses {
      lockFile = helloLockWith (
        lock: lock // { packages = builtins.filter (package: package.name != "glue") lock.packages; }
      );
    };
    assert
      !refuses {
        lockFile = helloLockWith (lock: lock // { r = "4.5.3"; });
      };
    assert
      !(builtins.tryEval
        (buildRenvProject {
          src = builtins.path {
            path = ./fixtures/sources;
            name = "sources";
          };
        }).library.drvPath
      ).success;
    pkgs.runCommand "stale-lock-refused" { } "touch $out";
}
