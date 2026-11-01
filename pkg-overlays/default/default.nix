# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.renv-purifier` (`.cli`), and the builder `pkgs.buildRenvProject`
# (nix/lib/build-renv-project.nix) beside them, where nixpkgs keeps its own
# builders, so a package written for callPackage takes it by name. A
# consumer that lists this flake in `projects` holds it as
# `renv-purifier/default`, which its package sets apply by default.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "renv-purifier";
in
{
  overlay =
    final: prev:
    packages final prev
    // {
      buildRenvProject = final.callPackage ../../nix/lib/build-renv-project.nix { };
    };
}
