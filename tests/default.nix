# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked downloads.
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

  # A copy of the hello lock with some fields changed.
  helloLockWith =
    attrs:
    builtins.toFile "renv-purifier.lock.json" (
      builtins.toJSON (
        builtins.fromJSON (builtins.readFile ./fixtures/hello/renv-purifier.lock.json) // attrs
      )
    );

  # Whether buildRenvProject refuses the hello project with this lockfile
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

  # The download URLs the lock run builds are the ones renv builds.
  urls = pkgs.runCommand "renv-purifier-urls" { nativeBuildInputs = [ R ]; } ''
    Rscript ${../pkgs/renv-purifier/test-urls.R} ${../pkgs/renv-purifier}
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
    Rscript -e 'tools::write_PACKAGES("repository/src/contrib", type = "source")'
    R_LIBS_SITE=${hello.library}/library Rscript -e '
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

  # A lock made from another renv.lock, for another R minor release or in
  # another format would not match what the build installs, so the builder
  # refuses it at evaluation. So does a lock with a package from outside the
  # project that `src` does not reach.
  stale-lock-refused =
    assert refuses {
      lockFile = helloLockWith { renvLock = "0000"; };
    };
    assert refuses {
      lockFile = helloLockWith { r = "3.6.3"; };
    };
    assert refuses {
      lockFile = helloLockWith { version = 0; };
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
