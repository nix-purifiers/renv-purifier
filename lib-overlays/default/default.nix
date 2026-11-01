# SPDX-License-Identifier: MIT
#
# The `renv-purifier` library namespace. It holds nothing, because the
# builder needs a package set: it is the package `buildRenvProject` that
# the default package overlay adds.
{ ... }:
{

  overlay = final: prev: {
    renv-purifier = prev.renv-purifier or { };
  };

}
