# SPDX-License-Identifier: MIT
#
# buildRenvProject: the sandboxed build of an R project, from its renv.lock
# and the renv-purifier.lock.json that `renv-purifier lock` writes beside
# it.
#
# The file is a package for callPackage: the first argument set is what it
# takes from the package set, and the result is the builder. The
# renv-purifier overlay (`overlays.default`) adds it to the package set as
# `buildRenvProject`, so a package written for callPackage takes it like any
# other dependency:
#
#   { buildRenvProject }: (buildRenvProject { src = ./.; }).env
#
# and `buildRenvProject.override` replaces what it takes from the set, such
# as `R`. The builder returns
#
#   cellar           the source tarball of every locked package, in the
#                    layout of an renv cellar (cellar.nix)
#   library          every locked package, installed by renv::restore() from
#                    the cellar, in library/
#   env              R and Rscript in bin/, with the library (and the
#                    project's own package, when the project is one) on
#                    their library path
#   package          for a project that is an R package: the source tarball
#                    R CMD build makes, and the package installed in
#                    library/
#   packages.<name>  the same package, under its name
#   lock             the purifier lockfile, as lock.nix reads it
{
  lib,
  stdenv,
  callPackage,
  makeWrapper,
  pkg-config,
  R,
  # nixpkgs' R packages, read only for the system libraries each package
  # needs.
  rPackages,
  # The fetcher of download entries, from the shared purifier library
  # (github:nix-purifiers/purifier).
  fetchEntry,
}:
{
  # The project root, which holds renv.lock.
  src,
  # The purifier lockfile. The default is the one `renv-purifier lock` writes
  # at the project root.
  lockFile ? src + "/renv-purifier.lock.json",
  # Packages whose renv.lock record names a directory outside the project,
  # by package name.
  localPackages ? { },
  # More libraries and tools for compiling packages, beside the ones the
  # builder takes from nixpkgs' R packages.
  extraBuildInputs ? [ ],
  extraNativeBuildInputs ? [ ],
  # Runs R CMD check on the project's package.
  doCheck ? false,
  # Replaces nixpkgs' fetchurl for the file downloads, as the place for
  # credentials or mirrors. It takes the arguments of nixpkgs' fetchurl.
  fetchurl ? null,
  # Filters the project root before it is copied into the store, as the
  # `filter` of builtins.path. The default leaves out renv's project library
  # and the project's build outputs.
  srcFilter ? null,
}:
let
  lock = import ./lock.nix { inherit lockFile; };

  # A package from a directory outside the project is found at the path its
  # renv.lock record names, from the project root, when `src` is a path
  # that reaches it. `localPackages` replaces any of them.
  outsidePackages = lib.listToAttrs (
    lib.concatMap (
      package:
      let
        path =
          if lib.hasPrefix "/" package.outside then /. + package.outside else src + "/${package.outside}";
      in
      lib.optional (package.convert == "external" && builtins.pathExists path) {
        inherit (package) name;
        value = path;
      }
    ) lock.packages
  );

  cellar = callPackage ./cellar.nix { inherit fetchEntry; } {
    inherit lockFile fetchurl;
    rVersion = R.version;
    localPackages = outsidePackages // localPackages;
  };

  # The lock records a hash of renv.lock. A renv.lock changed after locking
  # would name packages the cellar does not hold, so the build stops before
  # it starts.
  renvLockHash = builtins.hashFile "sha256" (src + "/renv.lock");

  # Every package renv.lock names needs an entry in the purifier lock. The
  # packages of priority "base" ship with R, and the lock run skips them.
  basePackages = [
    "base"
    "compiler"
    "datasets"
    "graphics"
    "grDevices"
    "grid"
    "methods"
    "parallel"
    "splines"
    "stats"
    "stats4"
    "tcltk"
    "tools"
    "utils"
  ];
  renvLockPackages =
    builtins.attrNames
      (builtins.fromJSON (builtins.readFile (src + "/renv.lock"))).Packages;
  lockedNames = map (package: package.name) lock.packages;
  missingPackages = lib.filter (
    name: !(lib.elem name lockedNames || lib.elem name basePackages)
  ) renvLockPackages;

  defaultSrcFilter =
    path: type:
    let
      name = baseNameOf path;
      relative = lib.removePrefix (toString src + "/") (toString path);
    in
    !(
      lib.elem relative [
        "renv/library"
        "renv/staging"
        "renv/cellar"
        "renv/local"
        "renv/sandbox"
      ]
      || name == ".git"
      || name == ".Rproj.user"
      || name == ".Rhistory"
      || lib.hasPrefix "result" name
    );

  filteredSrc = builtins.path {
    path = src;
    name = "renv-source";
    filter = if srcFilter != null then srcFilter else defaultSrcFilter;
  };

  # The system libraries and tools of the locked packages, as nixpkgs' R
  # packages of the same names declare them. The R packages among their
  # inputs are left out, because renv installs those from the cellar.
  # nixpkgs names an R package `r-<name>-<version>`, with the bare R name as
  # its pname, so the test reads the full name.
  isRPackage = drv: lib.hasPrefix "r-" (drv.name or "") || lib.getName drv == "R";

  # The output that holds the shared objects of a library, from any of its
  # outputs: the `lib` output when it has one, and `out` otherwise.
  libraryOutput = drv: lib.getLib (drv.out or drv);
  systemInputs =
    attribute:
    lib.unique (
      lib.concatMap (
        package:
        lib.filter (drv: lib.isDerivation drv && !isRPackage drv) (
          (rPackages.${package.name} or { }).${attribute} or [ ]
        )
      ) lock.packages
    );

  # The libraries to link against, each with the output that holds its
  # shared objects. nixpkgs often names only the dev output of a library,
  # such as openssl.dev for openssl.
  linkedInputs =
    let
      inputs = systemInputs "buildInputs" ++ systemInputs "propagatedBuildInputs" ++ extraBuildInputs;
    in
    lib.unique (inputs ++ map libraryOutput inputs);

  # A runtime path to the library directory of every system input, the ones
  # nixpkgs lists as native inputs included: nixpkgs lists openssl among
  # the native inputs of its R package openssl. A package's configure script
  # often links with the flags pkg-config gives, such as openssl's
  # `-l:libssl.so.3`, for which the compiler wrapper records no runtime path,
  # and the shared object then does not load. The fixup phase drops the
  # paths a package does not use.
  runtimePaths = toString (
    map (drv: "-rpath ${libraryOutput drv}/lib") (
      lib.unique (linkedInputs ++ systemInputs "nativeBuildInputs" ++ extraNativeBuildInputs)
    )
  );

  renvPackage = lib.findFirst (package: package.name == "renv") null lock.packages;
  renvTarball =
    if renvPackage != null then
      "${cellar}/cellar/renv/${renvPackage.cellarName}"
    else
      throw "renv-purifier: renv.lock has no record for renv itself; run renv::snapshot() in the project.";

  majorMinor = version: lib.versions.majorMinor version;

  # renv::restore() reads the cellar and the Bioconductor configuration of
  # the lock, and nothing else, so it runs offline.
  restoreEnvironment = ''
    export HOME="$TMPDIR/home"
    export RENV_PATHS_ROOT="$TMPDIR/renv-root"
    export RENV_PATHS_CELLAR="${cellar}/cellar"
    export RENV_CONFIG_CACHE_ENABLED=FALSE
    export RENV_CONFIG_PAK_ENABLED=FALSE
    export RENV_CONFIG_SANDBOX_ENABLED=FALSE
    export RENV_CONFIG_AUTOLOADER_ENABLED=FALSE
    ${lib.optionalString (lock.bioconductor != null) ''
      export BIOCONDUCTOR_CONFIG_FILE="${cellar}/bioconductor/config.yaml"
    ''}
    mkdir -p "$HOME"
  '';

  library = stdenv.mkDerivation {
    name = "renv-library";
    src = filteredSrc;
    nativeBuildInputs = [
      R
      pkg-config
    ]
    ++ systemInputs "nativeBuildInputs"
    ++ extraNativeBuildInputs;
    buildInputs = linkedInputs;
    env.NIX_LDFLAGS = runtimePaths;
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      ${restoreEnvironment}
      mkdir -p "$TMPDIR/renv-lib" "$out/library"
      R CMD INSTALL --no-test-load --library="$TMPDIR/renv-lib" ${renvTarball}
      R --vanilla --no-echo -e '
        .libPaths(c(file.path(Sys.getenv("TMPDIR"), "renv-lib"), .libPaths()))
        renv::restore(
          project = getwd(),
          library = file.path(Sys.getenv("out"), "library"),
          prompt = FALSE,
          clean = FALSE
        )
      '
      runHook postBuild
    '';
    dontInstall = true;
    # R packages carry no build references worth stripping, and their
    # compiled code keeps the runtime paths the linker gave it.
    dontStrip = true;
    passthru = { inherit cellar lock; };
  };

  outputPackage = lock.outputs.package or null;

  package = stdenv.mkDerivation (finalAttrs: {
    pname = outputPackage.name;
    inherit (outputPackage) version;
    src = filteredSrc;
    nativeBuildInputs = [
      R
      pkg-config
    ]
    ++ systemInputs "nativeBuildInputs"
    ++ extraNativeBuildInputs;
    buildInputs = linkedInputs;
    env.NIX_LDFLAGS = runtimePaths;
    dontConfigure = true;
    inherit doCheck;
    buildPhase = ''
      runHook preBuild
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME"
      export R_LIBS_SITE="${library}/library"
      R CMD build --no-build-vignettes --no-manual .
      if [ ! -f ${outputPackage.tarball} ]; then
        echo "renv-purifier: the lock names ${outputPackage.tarball}, which R CMD build did not produce; run renv-purifier lock" >&2
        exit 1
      fi
      runHook postBuild
    '';
    checkPhase = ''
      runHook preCheck
      # glibc provides C.UTF-8 without a locale archive, and R CMD check
      # wants a UTF-8 locale.
      export LC_ALL=C.UTF-8
      _R_CHECK_FORCE_SUGGESTS_=false R CMD check --no-manual --no-build-vignettes --ignore-vignettes ${outputPackage.tarball}
      runHook postCheck
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/library"
      cp ${outputPackage.tarball} "$out/"
      R CMD INSTALL --library="$out/library" ${outputPackage.tarball}
      runHook postInstall
    '';
    dontStrip = true;
    passthru = {
      inherit library cellar lock;
      # The files of the package by file name, such as
      # artifacts."hello_1.0.0.tar.gz". They are known from the lock alone,
      # before the package is built.
      artifacts.${outputPackage.tarball} = "${finalAttrs.finalPackage}/${outputPackage.tarball}";
    };
    meta.description = "${outputPackage.name} ${outputPackage.version}, built by renv-purifier";
  });

  libraryPath = lib.concatStringsSep ":" (
    lib.optional (outputPackage != null) "${package}/library" ++ [ "${library}/library" ]
  );

  env = stdenv.mkDerivation {
    name = "renv-env";
    nativeBuildInputs = [ makeWrapper ];
    dontUnpack = true;
    installPhase = ''
      mkdir -p "$out/bin"
      for program in R Rscript; do
        makeWrapper ${R}/bin/$program "$out/bin/$program" \
          --set R_LIBS_SITE ${libraryPath} \
          --set RENV_CONFIG_AUTOLOADER_ENABLED FALSE
      done
    '';
    passthru = { inherit library lock; };
    meta.mainProgram = "Rscript";
  };
in
assert
  renvLockHash == lock.renvLock
  || throw "renv-purifier: renv.lock in ${toString src} changed after ${toString lockFile} was made; run `renv-purifier lock`.";
assert
  missingPackages == [ ]
  || throw "renv-purifier: renv.lock names ${lib.concatStringsSep ", " missingPackages}, which ${toString lockFile} has no entry for; run `renv-purifier lock`.";
# renv-purifier builds every package from source with the R of the package
# set, so a lock made with another R release builds as long as its packages
# compile with this one. Old package versions sometimes do not.
lib.warnIf (majorMinor R.version != majorMinor lock.r)
  "renv-purifier: renv.lock was made with R ${lock.r}, and the packages build with R ${R.version}. If a package fails to compile, pass an `R` of version ${majorMinor lock.r} through buildRenvProject.override, or update the package with renv."
  {
    inherit
      lock
      cellar
      library
      env
      ;
  }
// lib.optionalAttrs (outputPackage != null) {
  inherit package;
  packages.${outputPackage.name} = package;
}
