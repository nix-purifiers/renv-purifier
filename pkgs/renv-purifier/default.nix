# SPDX-License-Identifier: MIT
#
# The renv-purifier command: `renv-purifier lock` writes a project's
# renv-purifier.lock.json, `update` updates packages and relocks,
# `prefetch` installs the project library from the library Nix builds, and
# `publish` adds the project's package to a CRAN-like repository. It calls
# the nix-build, nix-shell, nix-instantiate and nix-hash of the Nix
# installation it runs on.
{
  path,
  writeShellApplication,
  rWrapper,
  rPackages,
  jq,
  nix-prefetch-git,
  coreutils,
  gnutar,
  gzip,
}:
let
  # The lock run reads and writes JSON with jsonlite.
  R = rWrapper.override { packages = [ rPackages.jsonlite ]; };

  # The shared purifier library at the revision this flake locks, as a
  # locked flake reference for cli.nix.
  purifierLock = (builtins.fromJSON (builtins.readFile ../../flake.lock)).nodes.purifier.locked;
  narHash = builtins.replaceStrings [ "+" "/" "=" ] [ "%2B" "%2F" "%3D" ] purifierLock.narHash;
  purifier = "github:${purifierLock.owner}/${purifierLock.repo}/${purifierLock.rev}?narHash=${narHash}";
in
writeShellApplication {
  name = "renv-purifier";
  runtimeInputs = [
    R
    jq
    nix-prefetch-git
    coreutils
    # tools::write_PACKAGES reads package tarballs with them.
    gnutar
    gzip
  ];
  runtimeEnv = {
    RENV_PURIFIER_LIB = ../../nix/lib;
    # lock.R and the records.R it reads, from this directory.
    RENV_PURIFIER_SCRIPTS = ./.;
    RENV_PURIFIER_NIXPKGS = path;
    RENV_PURIFIER_LIBRARY = purifier;
    RENV_PURIFIER_FORMAT = toString (import ../../nix/lib/lock-version.nix);
  };
  text = builtins.readFile ./renv-purifier.sh;
  meta.description = "Locks the downloads of an renv project for sandboxed Nix builds";
}
