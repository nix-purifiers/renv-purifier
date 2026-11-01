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
#   bioconductor/config.yaml  for a lock that names a Bioconductor release,
#                             a Bioconductor configuration file that pairs
#                             the release with the R of the build, which is
#                             what BiocManager reads from it
#
# Every package is unpacked and packed again with its scripts' interpreter
# lines pointing into the store, as nixpkgs' own R builder does: configure
# scripts often start with `#!/usr/bin/env sh`, and the Nix sandbox has no
# /usr/bin/env. A git checkout, a zip file or a local package outside the
# project is packed the same way. Packages in a directory of the project
# need no entry, because renv installs them from the project itself.
{
  lib,
  pkgs,
  runCommand,
  gnutar,
  gzip,
  unzip,
  # The fetcher of download entries, from the shared purifier library.
  fetchEntry,
}:
{
  lockFile,
  # The version of the R that installs the packages.
  rVersion,
  # Packages whose renv.lock record names a directory outside the project,
  # by package name.
  localPackages ? { },
  # Replaces nixpkgs' fetchurl for the file downloads, as the place for
  # credentials or mirrors. It takes the arguments of nixpkgs' fetchurl.
  fetchurl ? null,
}:
let
  lock = import ./lock.nix { inherit lockFile; };
  fetch = fetchEntry (
    { inherit pkgs; } // lib.optionalAttrs (fetchurl != null) { inherit fetchurl; }
  );

  # Packs the tree under work/ into the cellar tarball of `package`, keeping
  # its top-level entries, with interpreter lines patched.
  packWork = package: ''
    patchShebangs work > /dev/null
    mkdir -p "$out/cellar/${package.name}"
    tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner \
      -C work -cf - $(ls -A work) | gzip -n > "$out/cellar/${package.name}/${package.cellarName}"
    rm -rf work
  '';

  # Packs the package directory named by the shell word `directory` into a
  # tarball whose single top-level directory is the package name, as
  # R CMD INSTALL expects.
  pack = package: directory: ''
    mkdir -p work
    cp -r --no-preserve=mode ${directory} "work/${package.name}"
    ${packWork package}
  '';

  entry =
    package:
    if package.convert == "none" && package.download != null then
      ''
        mkdir -p work
        tar -xzf ${fetch package.download} -C work
        chmod -R u+w work
        ${packWork package}
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

  # BiocManager checks that the Bioconductor release suits the running R.
  # It reads `r_ver_for_bioc_ver`, `release_version` and `devel_version`
  # from Bioconductor's configuration file, which changes with every
  # release, so the cellar writes those three entries for the locked release
  # and the R of the build. BiocManager also wants an out-of-date release
  # and a devel release in the map, so the release before the locked one
  # and the release after it go in too, with the same R.
  bioconductorConfig =
    let
      release = lock.bioconductor;
      parts = lib.splitVersion release;
      major = lib.toInt (builtins.elemAt parts 0);
      minor = lib.toInt (builtins.elemAt parts 1);
      previous =
        if minor > 0 then "${toString major}.${toString (minor - 1)}" else "${toString (major - 1)}.99";
      devel = "${toString major}.${toString (minor + 1)}";
      r = lib.versions.majorMinor rVersion;
    in
    builtins.toFile "config.yaml" ''
      release_version: "${release}"
      devel_version: "${devel}"
      r_ver_for_bioc_ver:
        "${previous}": "${r}"
        "${release}": "${r}"
        "${devel}": "${r}"
    '';
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
    ${lib.optionalString (lock.bioconductor != null) ''
      mkdir -p "$out/bioconductor"
      cp ${bioconductorConfig} "$out/bioconductor/config.yaml"
    ''}
  ''
