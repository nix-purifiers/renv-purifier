# SPDX-License-Identifier: MIT
#
# The `renv-purifier` library namespace of the purifier contract:
# `readLock { src, lockFile ? ... }` (nix/lib/read-lock.nix), renv.lock and
# the purifier lockfile read into the lock in memory. The builder is the
# package `buildRenvProject` that the default package overlay adds.
{ ... }:
{

  overlay = final: prev: {
    renv-purifier = (prev.renv-purifier or { }) // {
      readLock = import ../../nix/lib/read-lock.nix { lib = final; };
    };
  };

}
