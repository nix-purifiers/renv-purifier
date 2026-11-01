# SPDX-License-Identifier: MIT
#
# The renv-purifier command: `renv-purifier lock` writes a project's
# renv-purifier.lock.json, `restore` installs the project library offline
# from the locked downloads, `build` builds the project with Nix, and
# `publish` adds the project's package to a CRAN-like repository. It calls
# the nix-build and nix-hash of the Nix installation it runs on.
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
    # lock.R and the urls.R it reads, from this directory.
    RENV_PURIFIER_SCRIPTS = ./.;
    RENV_PURIFIER_NIXPKGS = path;
    RENV_PURIFIER_FORMAT = toString (import ../../nix/lib/lock-version.nix);
  };
  text = builtins.readFile ./renv-purifier.sh;
  meta.description = "Locks the downloads of an renv project for sandboxed Nix builds";
}
