# SPDX-License-Identifier: MIT
#
# Reads a renv-purifier lockfile, which `renv-purifier lock` writes at the
# project root beside renv.lock.
{ lockFile }:
let
  lock = builtins.fromJSON (builtins.readFile lockFile);

  supportedVersion = import ./lock-version.nix;

  # A store path name from a file name. Store path names allow
  # [A-Za-z0-9+._?=-], must not start with a dot, and are at most 211
  # characters, so every other character becomes "_".
  storeName =
    fileName:
    let
      # builtins.split alternates the text between matches with a list per
      # match.
      replaced = builtins.concatStringsSep "" (
        map (part: if builtins.isList part then "_" else part) (
          builtins.split "[^A-Za-z0-9+._?=-]" fileName
        )
      );
      undotted = builtins.head (builtins.match "\\.*(.*)" replaced);
      nonEmpty = if undotted == "" then "file" else undotted;
    in
    builtins.substring 0 200 nonEmpty;
in
assert
  lock.version == supportedVersion
  || throw "renv-purifier: ${toString lockFile} has lock format version ${toString lock.version}, and this library reads version ${toString supportedVersion}. Run `renv-purifier lock` with the renv-purifier revision that provides this library.";
lock
// {
  inherit storeName;

  # The fetch name of a download: the last part of its path, made a valid
  # store name.
  downloadName = download: storeName (builtins.baseNameOf download.path);
}
