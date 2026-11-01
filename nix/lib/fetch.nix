# SPDX-License-Identifier: MIT
#
# The fetcher for locked downloads, in the shapes of the shared purifier
# library.
#
# A file entry, `{ path, url, mirrors, hash }`, is a fixed-output derivation
# on Nix's built-in fetcher, which tries `url` and then each mirror. CRAN
# moves a superseded version's tarball to its archive, so the mirrors keep a
# locked file reachable. A fixed-output store path depends only on its name
# and hash, so the built-in fetcher and nixpkgs' fetchurl produce the same
# paths.
#
# A git entry, `{ path, git = { url, rev, submodules, leaveDotGit }, hash }`,
# is nixpkgs' fetchgit, whose hash is the one nix-prefetch-git reports.
#
# `fetchurl` and `fetchgit`, when given, replace the defaults. They take the
# arguments of nixpkgs' functions of the same names, and are the place for
# credentials.
{
  lock,
  fetchgit,
  fetchurl ? null,
}:
download:
let
  name = lock.downloadName download;
in
if download ? git then
  fetchgit {
    inherit name;
    inherit (download.git) url rev leaveDotGit;
    fetchSubmodules = download.git.submodules;
    inherit (download) hash;
  }
else if fetchurl != null then
  fetchurl {
    inherit name;
    urls = [ download.url ] ++ download.mirrors;
    inherit (download) hash;
  }
else
  derivation {
    inherit name;
    builder = "builtin:fetchurl";
    system = "builtin";
    inherit (download) url;
    urls = [ download.url ] ++ download.mirrors;
    outputHash = download.hash;
    outputHashAlgo = "sha256";
    outputHashMode = "flat";
    unpack = false;
    executable = false;
    preferLocalBuild = true;
    impureEnvVars = [
      "http_proxy"
      "https_proxy"
      "ftp_proxy"
      "all_proxy"
      "no_proxy"
    ];
  }
