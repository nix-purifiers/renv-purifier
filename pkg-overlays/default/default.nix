# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds one attribute to the package set:
# the scope `pkgs.renv-purifier`, made with lib.makeScope, which holds the
# command (`.cli`) and the builder `.buildRenvProject`
# (nix/lib/build-renv-project.nix), a package for callPackage in the scope.
# A package in an overlay takes the scope by name:
#
#   { renv-purifier }: (renv-purifier.buildRenvProject { src = ./.; }).packages.env
#
# `renv-purifier.overrideScope` replaces what the scope shares, and
# `renv-purifier.buildRenvProject.override` what the builder takes. A
# consumer that lists this flake in `projects` holds the overlay as
# `renv-purifier/default`, which its package sets apply by default.
{ closure-lib, ... }:
{
  overlay = final: prev: {
    renv-purifier = final.lib.makeScope final.newScope (
      self:
      import ../../pkgs { inherit (self) callPackage; }
      // {
        # The builder checks the lock and fetches download entries with the
        # shared purifier library, which this flake lists in its projects.
        buildRenvProject = self.callPackage ../../nix/lib/build-renv-project.nix {
          inherit (closure-lib) purifier;
        };
      }
    );
  };
}
