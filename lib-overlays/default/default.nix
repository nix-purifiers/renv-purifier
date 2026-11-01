# SPDX-License-Identifier: MIT
#
# The `renv-purifier` library namespace of the purifier contract:
# - `buildRenvProject { pkgs, src, fetchers ? { }, ... }`
#   (nix/lib/build-renv-project.nix), the builder;
# - `readLock { src, lockFile ? ... }` (nix/lib/read-lock.nix), the
#   lockfiles read into the lock in memory.
# Both build on the `purifier` library, which this flake lists in its
# projects.
{ ... }:
{

  overlay = final: prev: {
    renv-purifier = (prev.renv-purifier or { }) // {
      readLock = import ../../nix/lib/read-lock.nix { lib = final; };
      buildRenvProject = import ../../nix/lib/build-renv-project.nix {
        inherit (final) purifier;
        lib = final;
      };
    };
  };

}
