# SPDX-License-Identifier: MIT
#
# What the renv-purifier command builds, for a project directory on the
# machine it runs on: the cellar `renv-purifier restore` installs from, and
# the project as buildRenvProject builds it, for `renv-purifier build` and
# `renv-purifier publish`. The command passes the nixpkgs it was built with.
{
  nixpkgs,
  # The project directory, as an absolute path.
  src,
}:
let
  pkgs = import nixpkgs { };
  built = (pkgs.callPackage ./build-renv-project.nix { }) { src = /. + src; };
in
{
  inherit (built) cellar env;
  # The shell `renv-purifier restore` runs renv::restore() in: R, the C,
  # C++ and Fortran toolchain, make, pkg-config and the system libraries of
  # the locked packages, as the sandboxed build of the library has them.
  shell = pkgs.mkShell { inputsFrom = [ built.library ]; };
  # The project's own package; evaluating it fails for a project that is not
  # an R package.
  package = built.package or (throw "renv-purifier: the project is not an R package");
}
