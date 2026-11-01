# SPDX-License-Identifier: MIT
#
# `lib.renv-purifier.readLock { src, lockFile ? ... }`: renv.lock and
# renv-purifier.lock.json read into the lock in memory of the purifier
# contract (github:nix-purifiers/purifier, CONTRACT.md):
#
#   {
#     purifier = "renv-purifier";
#     entries  = [ <download entry> ];
#     outputs  = { <package> = { version; tarball; }; };
#     problems = [ <string> ];
#   }
#
# `entries` holds a download entry for every locked package that renv
# downloads: a file entry for a package from a repository, GitHub, GitLab,
# Bitbucket or a URL, and a git entry for a package from git. R source
# packages build on every system, so no entry carries `systems`. Each entry
# also carries an `renv` field: the package name, the name renv looks it up
# under in a cellar, and how the cellar turns the download into a source
# tarball.
#
# `outputs` holds the project's own package, when the project is one, and
# is empty otherwise.
{ lib }:
{
  src,
  lockFile ? src + "/renv-purifier.lock.json",
}:
let
  lock = import ./lock.nix { inherit lib src lockFile; };
in
{
  purifier = "renv-purifier";
  inherit (lock) entries outputs problems;
}
