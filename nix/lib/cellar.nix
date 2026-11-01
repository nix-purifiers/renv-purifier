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
  # The fetcher of download entries, from the shared purifier library,
  # with the builder's `fetchers` applied.
  fetch,
  # The download entries of the lock, each with its `renv` field
  # (lock.nix).
  entries,
  # The packages renv.lock installs from a directory outside the project,
  # by name, each a path that holds the package.
  outside,
  # The Bioconductor release renv.lock names, or null.
  bioconductor,
  # The version of the R that installs the packages.
  rVersion,
}:
let
  inherit (pkgs)
    runCommand
    gnutar
    gzip
    unzip
    ;

  # Packs the tree under work/ into the cellar tarball `cellarName` of
  # `package`, keeping its top-level entries, with interpreter lines
  # patched.
  packWork = package: cellarName: ''
    patchShebangs work > /dev/null
    mkdir -p "$out/cellar/${package}"
    tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner \
      -C work -cf - $(ls -A work) | gzip -n > "$out/cellar/${package}/${cellarName}"
    rm -rf work
  '';

  # Packs the package directory named by the shell word `directory` into a
  # tarball whose single top-level directory is the package name, as
  # R CMD INSTALL expects.
  pack = package: cellarName: directory: ''
    mkdir -p work
    cp -r --no-preserve=mode ${directory} "work/${package}"
    ${packWork package cellarName}
  '';

  entry =
    download:
    let
      inherit (download.renv) package cellarName convert;
    in
    if convert == "none" then
      ''
        mkdir -p work
        tar -xzf ${fetch download} -C work
        chmod -R u+w work
        ${packWork package cellarName}
      ''
    else if convert == "git" then
      pack package cellarName "${fetch download}"
    else
      ''
        mkdir -p unpacked
        unzip -q ${fetch download} -d unpacked
        # A zip file of a package holds the package directory at its top.
        shopt -s nullglob
        descriptions=(unpacked/*/DESCRIPTION)
        if [ ''${#descriptions[@]} -ne 1 ]; then
          echo "renv-purifier: the zip file of ${package} does not hold one package directory" >&2
          exit 1
        fi
        directory=$(dirname "''${descriptions[0]}")
        ${pack package cellarName ''"$directory"''}
        rm -rf unpacked
      '';

  # renv looks a package from a directory up in the cellar under its
  # version, like a package from a repository.
  local = lib.concatStrings (
    lib.mapAttrsToList (
      package: value: pack package "${package}_${value.version}.tar.gz" "${value.path}"
    ) outside
  );

  # BiocManager checks that the Bioconductor release suits the running R.
  # It reads `r_ver_for_bioc_ver`, `release_version` and `devel_version`
  # from Bioconductor's configuration file, which changes with every
  # release, so the cellar writes those three entries for the locked release
  # and the R of the build. BiocManager also wants an out-of-date release
  # and a devel release in the map, so the release before the locked one
  # and the release after it go in too, with the same R.
  bioconductorConfig =
    let
      release = bioconductor;
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
  }
  ''
    mkdir -p "$out/cellar"
    ${lib.concatMapStrings entry entries}
    ${local}
    ${lib.optionalString (bioconductor != null) ''
      mkdir -p "$out/bioconductor"
      cp ${bioconductorConfig} "$out/bioconductor/config.yaml"
    ''}
  ''
