# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.renv-purifier`, the command among them (`.cli`). A consumer that
# lists this flake in `projects` holds it as `renv-purifier/default`, which
# its package sets apply by default. The builder is in the library, as
# `lib.renv-purifier.buildRenvProject`.
{ closure-lib, ... }:
{
  overlay = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "renv-purifier";
}
