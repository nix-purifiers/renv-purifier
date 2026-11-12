# SPDX-License-Identifier: MIT
#
# buildRenvProject: the sandboxed build of an R project from its renv.lock
# and the renv-purifier.lock.json that `renv-purifier lock` writes, as the
# purifier contract (github:nix-purifiers/purifier, CONTRACT.md) describes.
#
# The file is a package for callPackage: the first argument set is what it
# takes from the package set, and the result is the builder. The
# renv-purifier overlay (`overlays.default`) adds the scope `renv-purifier`
# to the package set, and the scope holds the builder as
# `buildRenvProject`, so a package written for callPackage takes the scope
# by name:
#
#   { renv-purifier }: (renv-purifier.buildRenvProject { src = ./.; }).packages.env
#
# `renv-purifier.overrideScope` replaces what the scope shares, and
# `renv-purifier.buildRenvProject.override` replaces what the builder takes
# from the set, such as `R`.
#
# The builder fetches every locked package into an renv cellar
# (cellar.nix), a directory renv reads source packages from before it
# downloads anything, and runs renv's own renv::restore() from it with no
# network. The result has:
#
#   packages.env        R and Rscript in bin/, with the library, and the
#                       project's own package when the project is one, on
#                       their library path
#   packages.<package>  for a project that is an R package: the package,
#                       installed in library/
#   tests               for a package, R CMD check of its release; for a
#                       project that is not a package, a load of every
#                       locked package
#   release             for a package, the source tarball that
#                       `renv-purifier publish` adds to a repository, by
#                       file name in `.artifacts`; null otherwise
#   fetches             the download entries of the purifier library that
#                       the build fetches
#   library             every locked package, installed by renv::restore()
#                       in library/
#   cellar              the source tarball of every locked package, in the
#                       layout of an renv cellar
#   interactive         what `renv-purifier prefetch` installs the project
#                       library from
{
  lib,
  stdenv,
  makeWrapper,
  pkg-config,
  runCommand,
  linkFarm,
  gnutar,
  gzip,
  unzip,
  fetchurl,
  fetchgit,
  # What the purifier library builds with after a fetch.
  zstd,
  python3,
  writeText,
  writeShellScriptBin,
  # The R that installs and runs the packages.
  R,
  # nixpkgs' R packages: the renv that runs the restore, and the system
  # libraries each locked package needs.
  rPackages,
  # The shared library of the nix-purifiers (github:nix-purifiers/purifier),
  # which checks the lock and fetches download entries. The overlay passes
  # it.
  purifier,
}:
{
  # The project root, which holds renv.lock and renv-purifier.lock.json
  # unless `renvLock` or `lockFile` names another path.
  src,
  # The purifier lockfile. A file outside `src` replaces any copy in it,
  # so a packaging flake can build a project its author does not change.
  lockFile ? src + "/renv-purifier.lock.json",
  # renv.lock. A file outside `src` replaces the copy in it.
  renvLock ? src + "/renv.lock",
  # The fetchers of the shared library's fetchEntry, such as a `fetchurl`
  # that sends credentials or uses a company mirror.
  fetchers ? { },
  # Packages whose renv.lock record names a directory outside the project,
  # by package name, each a path that holds the package. Without an entry
  # here, the builder looks for the package at the recorded path from
  # `src`.
  localPackages ? { },
  # More libraries and tools for compiling packages, beside the ones the
  # builder takes from nixpkgs' R packages.
  extraBuildInputs ? [ ],
  extraNativeBuildInputs ? [ ],
  # Filters the project root before it is copied into the store, as the
  # `filter` of builtins.path. The default leaves out renv's project library
  # and the project's build outputs.
  srcFilter ? null,
}:
let
  read = import ../../lib-overlays/default/lock.nix {
    inherit
      lib
      src
      lockFile
      renvLock
      ;
  };
  lock = purifier.checkLock {
    purifier = "renv-purifier";
    inherit (read) entries outputs problems;
  };
  entries = purifier.entriesFor stdenv.hostPlatform.system lock;

  fetch = purifier.fetchEntry (
    {
      inherit
        fetchurl
        fetchgit
        runCommand
        unzip
        zstd
        python3
        writeText
        ;
    }
    // fetchers
  );

  # A package from a directory outside the project is found at the path its
  # renv.lock record names, from the project root, when `src` is a path
  # that reaches it. `localPackages` replaces any of them.
  outside = lib.mapAttrs (
    name: path:
    let
      found = if lib.hasPrefix "/" path then /. + path else src + "/${path}";
    in
    {
      version = read.records.${name}.Version;
      path =
        localPackages.${name} or (
          if builtins.pathExists found then
            found
          else
            throw "renv-purifier: renv.lock installs ${name} from ${path}, a directory outside the project; pass it as `localPackages.${name}`."
        );
    }
  ) read.outside;

  cellar = import ./cellar.nix {
    inherit
      lib
      runCommand
      gnutar
      gzip
      unzip
      fetch
      entries
      outside
      ;
    inherit (read) bioconductor;
    rVersion = R.version;
  };

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
        ".renv-purifier"
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
        name:
        lib.filter (drv: lib.isDerivation drv && !isRPackage drv) (
          (rPackages.${name} or { }).${attribute} or [ ]
        )
      ) (lib.attrNames read.records)
    );

  # The libraries to link against, each with the output that holds its
  # shared objects. nixpkgs often names only the dev output of a library,
  # such as openssl.dev for openssl.
  linkedInputs =
    let
      inputs = systemInputs "buildInputs" ++ systemInputs "propagatedBuildInputs" ++ extraBuildInputs;
    in
    lib.unique (inputs ++ map libraryOutput inputs);

  nativeInputs = systemInputs "nativeBuildInputs" ++ extraNativeBuildInputs;

  # A runtime path to the library directory of every system input, the ones
  # nixpkgs lists as native inputs included: nixpkgs lists openssl among
  # the native inputs of its R package openssl. A package's configure script
  # often links with the flags pkg-config gives, such as `-l:libssl.so.3`
  # for openssl, for which the compiler wrapper records no runtime path, and
  # the shared object then does not load. The fixup phase drops the paths a
  # package does not use.
  runtimePaths = toString (
    map (drv: "-rpath ${libraryOutput drv}/lib") (lib.unique (linkedInputs ++ nativeInputs))
  );

  # R and pkg-config, for the builds that install packages. On macOS the
  # configure scripts of r-lib packages, such as textshaping and ragg, ask
  # pkg-config for the flags of a static link (`pkg-config --static`), the
  # way CRAN's binary packages link. A static link needs the pkg-config file
  # of every private dependency, such as glib for harfbuzz, which nixpkgs'
  # R packages do not list, so the flags come back empty and the package
  # does not load. The builds link shared libraries, so on darwin a
  # pkg-config first on the PATH leaves out `--static` and answers as on
  # Linux. nixpkgs' pkg-config still sets the search path.
  buildTools =
    lib.optional stdenv.hostPlatform.isDarwin (
      writeShellScriptBin "pkg-config" ''
        args=()
        for arg in "$@"; do
          [ "$arg" = --static ] || args+=("$arg")
        done
        exec ${pkg-config}/bin/pkg-config "''${args[@]}"
      ''
    )
    ++ [
      R
      pkg-config
    ];

  majorMinor = version: lib.versions.majorMinor version;

  # R CMD INSTALL writes the install time into the Built field of each
  # package, and nixpkgs fixes it the same way for its own R packages.
  installFlags = "--built-timestamp='1970-01-01 00:00:00 UTC'";

  # R CMD INSTALL compiles each package in a randomly named directory, which
  # the debug information records. The library keeps its shared objects
  # under library/, where the default strip list does not look.
  stripDebugList = [ "library" ];

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
    # Kept source records the randomly named directory each package is
    # compiled in, so the library would differ from build to build.
    export RENV_CONFIG_INSTALL_KEEP_SOURCE=FALSE
    export RENV_PURIFIER_INSTALL_OPTS=${lib.escapeShellArg installFlags}
    ${lib.optionalString (read.bioconductor != null) ''
      export BIOCONDUCTOR_CONFIG_FILE="${cellar}/bioconductor/config.yaml"
    ''}
    mkdir -p "$HOME"
  '';

  library = stdenv.mkDerivation {
    name = "renv-library";
    src = filteredSrc;
    nativeBuildInputs = buildTools ++ nativeInputs;
    buildInputs = linkedInputs;
    env.NIX_LDFLAGS = runtimePaths;
    dontConfigure = true;
    # renv::restore() runs with the renv of nixpkgs, whatever renv version
    # the lock records: older renv releases fail their own offline restore.
    # The renv record of the lock installs into the library from the cellar
    # like any other package.
    buildPhase = ''
      runHook preBuild
      ${restoreEnvironment}
      mkdir -p "$out/library"
      R --vanilla --no-echo -e '
        .libPaths(c("${rPackages.renv}/library", .libPaths()))
        options(install.opts = Sys.getenv("RENV_PURIFIER_INSTALL_OPTS"))
        renv::restore(
          project = getwd(),
          lockfile = "${renvLock}",
          library = file.path(Sys.getenv("out"), "library"),
          prompt = FALSE,
          clean = FALSE
        )
      '
      runHook postBuild
    '';
    dontInstall = true;
    inherit stripDebugList;
    passthru = { inherit cellar runtimePaths; };
  };

  # The project's own package, when the project is one.
  outputName = lib.findFirst (_: true) null (lib.attrNames lock.outputs);
  output = if outputName == null then null else lock.outputs.${outputName} // { name = outputName; };

  release =
    if output == null then
      null
    else
      stdenv.mkDerivation (finalAttrs: {
        pname = "${output.name}-release";
        inherit (output) version;
        src = filteredSrc;
        nativeBuildInputs = buildTools ++ nativeInputs;
        buildInputs = linkedInputs;
        dontConfigure = true;
        buildPhase = ''
          runHook preBuild
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          export R_LIBS_SITE="${library}/library"
          R CMD build --no-build-vignettes --no-manual .
          if [ ! -f ${output.tarball} ]; then
            echo "renv-purifier: R CMD build did not produce ${output.tarball}, which DESCRIPTION names" >&2
            exit 1
          fi
          # R CMD build writes the build time into the Packaged field and the
          # tarball, so the release is repacked with fixed times and owners.
          mkdir "$TMPDIR/release"
          tar -xzf ${output.tarball} -C "$TMPDIR/release"
          sed -i 's/^Packaged: .*/Packaged: 1970-01-01 00:00:00 UTC; nixbld/' \
            "$TMPDIR/release/${output.name}/DESCRIPTION"
          tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
            -C "$TMPDIR/release" -cf - ${output.name} | gzip -n > ${output.tarball}
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          mkdir -p "$out"
          cp ${output.tarball} "$out/"
          runHook postInstall
        '';
        passthru = {
          # The files of the release by file name, such as
          # artifacts."hello_1.0.0.tar.gz". They are known at evaluation,
          # before the release is built.
          artifacts.${output.tarball} = "${finalAttrs.finalPackage}/${output.tarball}";
        };
      });

  package =
    if output == null then
      null
    else
      stdenv.mkDerivation {
        pname = output.name;
        inherit (output) version;
        src = release;
        nativeBuildInputs = buildTools ++ nativeInputs;
        buildInputs = linkedInputs;
        env.NIX_LDFLAGS = runtimePaths;
        # R CMD INSTALL unpacks a tarball into a randomly named directory,
        # which the help pages record, so the package installs from a fixed
        # one.
        unpackPhase = ''
          mkdir -p "$TMPDIR/unpacked"
          tar -xzf $src/${output.tarball} -C "$TMPDIR/unpacked"
        '';
        dontConfigure = true;
        dontBuild = true;
        installPhase = ''
          runHook preInstall
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME" "$out/library"
          export R_LIBS_SITE="${library}/library"
          R CMD INSTALL ${installFlags} --library="$out/library" "$TMPDIR/unpacked/${output.name}"
        ''
        # The help pages record that fixed directory, in the path of each Rd
        # file and in its source reference. The Linux sandbox always builds
        # in /build, but on darwin the build directory is
        # /nix/var/nix/builds/nix-<pid>-<n>, new for every build, so the
        # paths are written again as under /build, as on Linux.
        + lib.optionalString stdenv.hostPlatform.isDarwin ''
          R --vanilla --no-echo -e '
            help <- file.path(Sys.getenv("out"), "library", "${output.name}", "help")
            if (file.exists(file.path(help, "paths.rds"))) {
              from <- normalizePath(Sys.getenv("TMPDIR"))
              rewrite <- function(path) sub(from, "/build", path, fixed = TRUE)
              paths <- readRDS(file.path(help, "paths.rds"))
              first <- attr(paths, "first") - nchar(from) + nchar("/build")
              saveRDS(structure(rewrite(paths), first = first), file.path(help, "paths.rds"))
              base <- file.path(help, "${output.name}")
              names <- as.character(names(readRDS(paste0(base, ".rdx"))$variables))
              db <- new.env()
              lazyLoad(base, envir = db)
              db <- lapply(mget(names, envir = db), function(rd) {
                attr(rd, "Rdfile") <- rewrite(attr(rd, "Rdfile"))
                srcfile <- attr(attr(rd, "srcref"), "srcfile")
                srcfile$filename <- rewrite(srcfile$filename)
                srcfile$wd <- rewrite(srcfile$wd)
                rd
              })
              tools:::makeLazyLoadDB(db, base)
            }
          '
        ''
        + ''
          runHook postInstall
        '';
        inherit stripDebugList;
        passthru = { inherit library release; };
        meta.description = "${output.name} ${output.version}, built by renv-purifier";
      };

  libraryPath = lib.concatStringsSep ":" (
    lib.optional (package != null) "${package}/library" ++ [ "${library}/library" ]
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
    passthru = { inherit library; };
    meta.mainProgram = "Rscript";
  };

  tests =
    if release != null then
      stdenv.mkDerivation {
        name = "${output.name}-check";
        src = release;
        nativeBuildInputs = buildTools ++ nativeInputs;
        buildInputs = linkedInputs;
        env.NIX_LDFLAGS = runtimePaths;
        dontUnpack = true;
        buildPhase = ''
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          export R_LIBS_SITE="${library}/library"
          # glibc provides C.UTF-8 without a locale archive, and R CMD check
          # wants a UTF-8 locale.
          export LC_ALL=C.UTF-8
          _R_CHECK_FORCE_SUGGESTS_=false R CMD check --no-manual --no-build-vignettes \
            --ignore-vignettes $src/${output.tarball}
        '';
        installPhase = "touch $out";
      }
    else
      runCommand "renv-project-check" { } ''
        export HOME="$TMPDIR"
        ${env}/bin/Rscript -e '
          for (package in commandArgs(TRUE))
            if (!requireNamespace(package, quietly = TRUE))
              stop("renv-purifier: the locked package ", package, " does not load")
        ' ${lib.escapeShellArgs (lib.attrNames read.records)}
        touch $out
      '';

  # The R a developer starts in the project after `renv-purifier prefetch`.
  # It is the R the library was built with, and it points BiocManager at the
  # Bioconductor configuration of the cellar, which renv reads when it loads
  # a project with Bioconductor packages, and renv at the cellar, so that
  # renv::restore() reinstalls a locked package with no network.
  interactiveR = stdenv.mkDerivation {
    name = "renv-interactive-R";
    nativeBuildInputs = [ makeWrapper ];
    dontUnpack = true;
    installPhase = ''
      mkdir -p "$out/bin"
      for program in R Rscript; do
        makeWrapper ${R}/bin/$program "$out/bin/$program" \
          --set-default RENV_PATHS_CELLAR ${cellar}/cellar ${
            lib.optionalString (
              read.bioconductor != null
            ) "\\
          --set-default BIOCONDUCTOR_CONFIG_FILE ${cellar}/bioconductor/config.yaml"
          }
      done
    '';
  };

  # What `renv-purifier prefetch` reads: the library it copies into the
  # project's renv library, the R to start in the project, the renv that
  # finds the path of that renv library, and the cellar.
  interactive = linkFarm "renv-interactive" {
    library = "${library}/library";
    R = interactiveR;
    renv = "${rPackages.renv}/library";
    cellar = "${cellar}/cellar";
  };
in
# renv-purifier builds every package from source with the R it is given,
# so a lock made with another R release builds as long as its packages
# compile with this one. Old package versions sometimes do not.
lib.warnIf (read.rVersion != null && majorMinor R.version != majorMinor read.rVersion)
  "renv-purifier: renv.lock was made with R ${read.rVersion}, and the packages build with R ${R.version}. If a package fails to compile, pass an `R` of version ${majorMinor read.rVersion} through renv-purifier.buildRenvProject.override, or update the package with `renv-purifier update`."
  {
    packages = {
      inherit env;
    }
    // lib.optionalAttrs (package != null) { ${output.name} = package; };
    inherit
      tests
      release
      library
      cellar
      interactive
      ;
    fetches = lock.entries;
  }
