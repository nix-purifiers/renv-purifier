# SPDX-License-Identifier: MIT
#
# The renv cellar of a lockfile: a directory renv reads source packages from
# before it downloads anything. renv takes its path from the environment
# variable `RENV_PATHS_CELLAR`. It looks a package up in the cellar as
# `<package>/<package>_<RemoteSha or Version>.tar.gz`, for every source a
# lockfile record can have, so a restore from the cellar downloads nothing.
#
# The output holds
#
#   cellar/<package>/<name>   one source tarball per locked package
#   bioconductor/config.yaml  the Bioconductor configuration of the lock run,
#                             for BiocManager, when the lock names a
#                             Bioconductor release
#
# A downloaded tarball is linked as it is. A git checkout, an unpacked zip
# file or a local package outside the project is packed into a tarball.
# Packages in a directory of the project need no entry, because renv
# installs them from the project itself.
{
  lib,
  runCommand,
  fetchgit,
  gnutar,
  gzip,
  unzip,
}:
{
  lockFile,
  # Packages whose renv.lock record names a directory outside the project,
  # by package name.
  localPackages ? { },
  # Replaces the built-in fetcher; see fetch.nix.
  fetchurl ? null,
}:
let
  lock = import ./lock.nix { inherit lockFile; };
  fetch = import ./fetch.nix { inherit lock fetchgit fetchurl; };

  # Packs the package directory named by the shell word `directory` into a
  # tarball whose single top-level directory is the package name, as
  # R CMD INSTALL expects.
  pack = package: directory: ''
    mkdir -p "$out/cellar/${package.name}" work
    cp -r --no-preserve=mode ${directory} "work/${package.name}"
    tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner \
      -C work -cf - "${package.name}" | gzip -n > "$out/cellar/${package.name}/${package.cellarName}"
    rm -rf work
  '';

  entry =
    package:
    if package.convert == "none" && package.download != null then
      ''
        mkdir -p "$out/cellar/${package.name}"
        ln -s ${fetch package.download} "$out/cellar/${package.name}/${package.cellarName}"
      ''
    else if package.convert == "git" then
      pack package "${fetch package.download}"
    else if package.convert == "zip" then
      ''
        mkdir -p unpacked
        unzip -q ${fetch package.download} -d unpacked
        # A zip file of a package holds the package directory at its top.
        shopt -s nullglob
        descriptions=(unpacked/*/DESCRIPTION)
        if [ ''${#descriptions[@]} -ne 1 ]; then
          echo "renv-purifier: the zip file of ${package.name} does not hold one package directory" >&2
          exit 1
        fi
        directory=$(dirname "''${descriptions[0]}")
        ${pack package ''"$directory"''}
        rm -rf unpacked
      ''
    else if package.convert == "external" then
      pack package "${localPackages.${package.name}
        or (throw "renv-purifier: renv.lock installs ${package.name} from a directory outside the project; pass it as `localPackages.${package.name}`.")
      }"
    else
      "";

  inline = lib.concatMapStrings (file: ''
    mkdir -p "$out/$(dirname ${lib.escapeShellArg file.path})"
    cp ${builtins.toFile (lock.storeName (baseNameOf file.path)) file.contents} "$out/"${lib.escapeShellArg file.path}
  '') lock.inline;
in
runCommand "renv-cellar"
  {
    nativeBuildInputs = [
      gnutar
      gzip
      unzip
    ];
    passthru = { inherit lock; };
  }
  ''
    mkdir -p "$out/cellar"
    ${lib.concatMapStrings entry lock.packages}
    ${inline}
  ''
