# SPDX-License-Identifier: MIT
#
# What the renv-purifier command builds for a project directory on the
# machine it runs on, with the nixpkgs the command was built with and the
# locked reference of the shared purifier library:
#
#   problems     the problems of readLock, which the command shows before
#                it builds anything
#   interactive  what `renv-purifier prefetch` installs the project library
#                from
#   release      the source tarball `renv-purifier publish` adds to a
#                repository
#   shell        the shell `renv-purifier update` runs renv::update() in
#
# `lockFile` and `renvLock`, when given, are the purifier lockfile and the
# renv.lock to read in place of the ones in the project.
{
  nixpkgs,
  # A locked flake reference to github:nix-purifiers/purifier.
  purifier,
  # The project directory, as an absolute path.
  src,
  # The purifier lockfile, as an absolute path, or null for the one in the
  # project.
  lockFile ? null,
  # renv.lock, as an absolute path, or null for the one in the project.
  renvLock ? null,
}:
let
  pkgs = import nixpkgs { };
  inherit (pkgs) lib;
  purifierLib = (builtins.getFlake purifier).lib.purifier;
  root = /. + src;
  lockArgs =
    lib.optionalAttrs (lockFile != null) { lockFile = /. + lockFile; }
    // lib.optionalAttrs (renvLock != null) { renvLock = /. + renvLock; };
  readLock = import ./read-lock.nix { inherit lib; };
  buildRenvProject = pkgs.callPackage ./build-renv-project.nix { purifier = purifierLib; };
  built = buildRenvProject ({ src = root; } // lockArgs);
in
{
  inherit (readLock ({ src = root; } // lockArgs)) problems;
  inherit (built) interactive;
  release =
    if built.release == null then
      throw "renv-purifier: ${src} has no DESCRIPTION naming a package, so it has no release to publish"
    else
      built.release;
  # R, the C, C++ and Fortran toolchain, make, pkg-config and the system
  # libraries of the locked packages, as the sandboxed build of the library
  # has them, with the same runtime paths.
  shell = pkgs.mkShell {
    inputsFrom = [ built.library ];
    env.NIX_LDFLAGS = built.library.runtimePaths;
  };
}
