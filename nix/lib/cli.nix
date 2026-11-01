# SPDX-License-Identifier: MIT
#
# What the renv-purifier command builds, for a project directory on the
# machine it runs on: the cellar `renv-purifier restore` installs from, and
# the project as buildRenvProject builds it, for `renv-purifier build` and
# `renv-purifier publish`. The command passes the nixpkgs it was built with
# and the locked reference of the shared purifier library, whose flake
# output gives the fetcher of download entries.
{
  nixpkgs,
  # A locked flake reference to github:nix-purifiers/purifier.
  purifier,
  # The project directory, as an absolute path.
  src,
}:
let
  pkgs = import nixpkgs { };
  inherit ((builtins.getFlake purifier).lib.purifier) fetchEntry;
  built = (pkgs.callPackage ./build-renv-project.nix { inherit fetchEntry; }) { src = /. + src; };
in
{
  inherit (built) cellar env;
  # The shell `renv-purifier restore` runs renv::restore() in: R, the C,
  # C++ and Fortran toolchain, make, pkg-config and the system libraries of
  # the locked packages, as the sandboxed build of the library has them.
  shell = pkgs.mkShell {
    inputsFrom = [ built.library ];
    env.NIX_LDFLAGS = built.library.runtimePaths;
  };
  # The project's own package; evaluating it fails for a project that is not
  # an R package.
  package = built.package or (throw "renv-purifier: the project is not an R package");
}
