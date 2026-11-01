# SPDX-License-Identifier: MIT
{ callPackage, ... }:
{
  # The renv-purifier command, with the R of this package set.
  cli = callPackage ./renv-purifier { };
}
