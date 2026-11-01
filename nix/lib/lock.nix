# SPDX-License-Identifier: MIT
#
# Reads a project's renv.lock and its renv-purifier.lock.json together.
# renv.lock names every package with its version and source, and Nix
# derives from it where each package downloads from, the way renv's own
# retrieval does (pkgs/renv-purifier/records.R plans the same locations for
# the lock run). The purifier lockfile adds what renv.lock cannot give:
#
#   {
#     "contentHash": the SHA-256 of builtins.toJSON of the other fields,
#     "packages": {
#       <name>: {
#         "hash":     the SRI hash of the download,
#         "url":      for a package from a repository, the URL it was found
#                     at, which depends on the repository that had it and
#                     on whether the version was current or archived,
#         "fallback": "git", for a Bioconductor package whose tarball was
#                     gone, so that it builds from the commit renv.lock names
#       }
#     },
#     "renvLock": the SHA-256 of the renv.lock it was made from,
#     "version":  the lock format version
#   }
#
# The result holds `problems`, the reasons the lockfiles cannot be used,
# each naming the command that fixes it; `entries`, a download entry of the
# purifier library for each package, with an `renv` field that tells the
# cellar what to do with it; `outputs`, the project's own package; and what
# the builder reads from renv.lock.
{
  lib,
  src,
  # The purifier lockfile.
  lockFile,
  # renv.lock, the copy in `src` or one kept outside it.
  renvLock,
}:
let
  supportedVersion = import ./lock-version.nix;

  renvLockPath = renvLock;
  hasRenvLock = builtins.pathExists renvLockPath;
  hasLockFile = builtins.pathExists lockFile;

  # A JSON file that does not parse fails evaluation here: builtins.fromJSON
  # raises an error that no Nix expression can catch, so this message is the
  # context of that error rather than one of `problems`.
  renvLockData =
    if hasRenvLock then
      builtins.addErrorContext "while reading ${toString renvLockPath}, which is not valid JSON; look for merge conflict markers, fix it, or run renv::snapshot() again" (
        builtins.fromJSON (builtins.readFile renvLockPath)
      )
    else
      { };
  purifier =
    if hasLockFile then
      builtins.addErrorContext "while reading ${toString lockFile}, which is not valid JSON; if it was edited by hand or merged with conflicts, rewrite it with `renv-purifier lock`" (
        builtins.fromJSON (builtins.readFile lockFile)
      )
    else
      { };

  # The packages of priority "base" ship with R, and the lock run skips
  # them.
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
  records = removeAttrs (renvLockData.Packages or { }) basePackages;

  rVersion = renvLockData.R.Version or null;
  bioconductor = renvLockData.Bioconductor.Version or null;

  isEntry =
    entry:
    builtins.isAttrs entry
    && builtins.isString (entry.hash or null)
    && builtins.isString (entry.url or "")
    && lib.elem (entry.fallback or "git") [ "git" ];

  shapeProblem =
    if !builtins.isString (purifier.renvLock or null) then
      "has no `renvLock` string"
    else if !builtins.isString (purifier.contentHash or null) then
      "has no `contentHash` string"
    else if !builtins.isAttrs (purifier.packages or null) then
      "has no `packages` object"
    else if !lib.all isEntry (lib.attrValues purifier.packages) then
      "has a package entry without a `hash` string, or with a `url` or `fallback` of the wrong kind"
    else
      null;

  contentHash = builtins.hashString "sha256" (
    builtins.toJSON (removeAttrs purifier [ "contentHash" ])
  );
  renvLockHash = builtins.hashFile "sha256" renvLockPath;

  # The problems of the files as a whole. When there is one, nothing else
  # is read from the purifier lockfile.
  fileProblems =
    if !hasRenvLock then
      [
        "renv-purifier: ${toString renvLockPath} does not exist. Run renv::snapshot() in the project, then `renv-purifier lock`."
      ]
    # renv.lock is parsed before anything else is compared, so a renv.lock
    # with merge conflict markers fails with its own message.
    else if !builtins.isAttrs renvLockData then
      [
        "renv-purifier: ${toString renvLockPath} is not a renv lockfile. Fix it, or run renv::snapshot() again, then `renv-purifier lock`."
      ]
    else if !hasLockFile then
      [ "renv-purifier: ${toString lockFile} does not exist. Run `renv-purifier lock`." ]
    else if !builtins.isAttrs purifier || !(purifier ? version) then
      [
        "renv-purifier: ${toString lockFile} is not a renv-purifier lockfile; rewrite it with `renv-purifier lock`."
      ]
    else if purifier.version != supportedVersion then
      [
        "renv-purifier: ${toString lockFile} has lock format version ${builtins.toJSON purifier.version}, and this library reads version ${toString supportedVersion}. Run `renv-purifier lock` with the renv-purifier that provides this library."
      ]
    else if shapeProblem != null then
      [
        "renv-purifier: ${toString lockFile} ${shapeProblem}; rewrite it with `renv-purifier lock`."
      ]
    else if contentHash != purifier.contentHash then
      [
        "renv-purifier: ${toString lockFile} was changed after `renv-purifier lock` wrote it. Run `renv-purifier lock` to write it again."
      ]
    else if renvLockHash != purifier.renvLock then
      [
        "renv-purifier: ${toString lockFile} was made for another renv.lock: renv.lock changed after `renv-purifier lock` ran. Run `renv-purifier lock`."
      ]
    else
      [ ];

  origin =
    host: default:
    let
      chosen = if host == null then default else host;
    in
    if lib.hasInfix "://" chosen then chosen else "https://${chosen}";

  # renv downloads GitHub packages as the API's tarball of the commit,
  # GitLab packages as the API's archive of the commit with the project
  # path URL-encoded as the project id, and Bitbucket packages from
  # `<web address>/get/<commit>.tar.gz`.
  githubUrl =
    record:
    "${
      origin (record.RemoteHost or null) "api.github.com"
    }/repos/${record.RemoteUsername}/${record.RemoteRepo}/tarball/${record.RemoteSha}";
  gitlabUrl =
    record:
    "${
      origin (record.RemoteHost or null) "gitlab.com"
    }/api/v4/projects/${lib.escapeURL "${record.RemoteUsername}/${record.RemoteRepo}"}/repository/archive.tar.gz?sha=${record.RemoteSha}";
  bitbucketUrl =
    record:
    let
      host = record.RemoteHost or "api.bitbucket.org/2.0";
      base = if lib.hasInfix "api.bitbucket.org" host then "https://bitbucket.org" else origin host host;
    in
    "${base}/${record.RemoteUsername}/${record.RemoteRepo}/get/${record.RemoteSha}.tar.gz";

  # A local package inside the project needs no download: renv installs it
  # from the project itself.
  isInside =
    path:
    !(lib.hasPrefix "/" path || path == ".." || lib.hasPrefix "../" path)
    && builtins.pathExists (src + "/${path}");

  # The plan for one record: `kind` is "download", "local" or "outside",
  # or "unknown" for a source renv-purifier does not know.
  plan =
    name: record:
    let
      source = lib.toLower (record.Source or "unknown");
      entry = purifier.packages.${name} or null;
      cellarName = "${name}_${record.RemoteSha or record.Version}.tar.gz";
      file = url: path: convert: {
        kind = "download";
        needsUrl = false;
        entry = {
          inherit path url;
          mirrors = [ ];
          hash = entry.hash;
          renv = {
            package = name;
            inherit cellarName convert;
          };
        };
      };
      git = url: rev: {
        kind = "download";
        needsUrl = false;
        entry = {
          path = "git/${name}";
          git = {
            inherit url rev;
            # renv's git fetch runs no submodule step and keeps no .git.
            submodules = false;
            leaveDotGit = false;
            commitObject = null;
          };
          hash = entry.hash;
          renv = {
            package = name;
            inherit cellarName;
            convert = "git";
          };
        };
      };
      fromRepository = (file (entry.url or null) "${name}/${cellarName}" "none") // {
        needsUrl = true;
      };
      localPath = record.RemoteUrl or "";
    in
    if
      lib.elem source [
        "repository"
        "cran"
      ]
    then
      fromRepository
    else if source == "bioconductor" then
      if (entry.fallback or null) == "git" then
        git (record.git_url or null) (record.git_last_commit or null)
      else
        fromRepository
    else if source == "github" then
      file (githubUrl record) "${name}/${cellarName}" "none"
    else if source == "gitlab" then
      file (gitlabUrl record) "${name}/${cellarName}" "none"
    else if source == "bitbucket" then
      file (bitbucketUrl record) "${name}/${cellarName}" "none"
    else if source == "git" then
      git record.RemoteUrl record.RemoteSha
    else if source == "url" then
      if lib.hasSuffix ".zip" record.RemoteUrl then
        file record.RemoteUrl "${name}/${name}_${record.Version}.zip" "zip"
      else
        file record.RemoteUrl "${name}/${cellarName}" "none"
    else if
      lib.elem source [
        "local"
        "cellar"
      ]
    then
      if isInside localPath then
        { kind = "local"; }
      else
        {
          kind = "outside";
          outside = localPath;
        }
    else
      {
        kind = "unknown";
        inherit (record) Source;
      };

  plans = lib.mapAttrs plan records;
  downloads = lib.filterAttrs (_: p: p.kind == "download") plans;

  # A download whose entry the lockfile lacks, or a repository package
  # whose entry has no URL.
  isMissing =
    name: p:
    let
      entry = purifier.packages.${name} or null;
    in
    entry == null || (p.needsUrl && (p.entry.url == null));
  missing = lib.attrNames (lib.filterAttrs isMissing downloads);
  unknown = lib.filterAttrs (_: p: p.kind == "unknown") plans;

  problems =
    if fileProblems != [ ] then
      fileProblems
    else
      lib.mapAttrsToList (
        name: p:
        "renv-purifier: renv.lock installs ${name} from ${builtins.toJSON p.Source}, a source renv-purifier does not know."
      ) unknown
      ++
        lib.optional (missing != [ ])
          "renv-purifier: renv.lock names ${lib.concatStringsSep ", " missing}, which ${toString lockFile} has no entry for. Run `renv-purifier lock`.";

  entries =
    if fileProblems != [ ] then
      [ ]
    else
      lib.mapAttrsToList (_: p: p.entry) (lib.filterAttrs (name: p: !isMissing name p) downloads);

  # The packages renv.lock installs from a directory outside the project, by
  # name, with the path the record names.
  outside = lib.mapAttrs (_: p: p.outside) (lib.filterAttrs (_: p: p.kind == "outside") plans);

  # The project's own package, when its DESCRIPTION names one: the tarball
  # R CMD build makes of it.
  descriptionPath = src + "/DESCRIPTION";
  descriptionField =
    field:
    let
      lines = lib.splitString "\n" (builtins.readFile descriptionPath);
      matches = lib.concatMap (
        line:
        let
          m = builtins.match "${field}:[ \t]*(.*[^ \t\r])[ \t\r]*" line;
        in
        lib.optional (m != null) (builtins.head m)
      ) lines;
    in
    if matches == [ ] then null else builtins.head matches;
  packageName = if builtins.pathExists descriptionPath then descriptionField "Package" else null;
  packageVersion = if builtins.pathExists descriptionPath then descriptionField "Version" else null;
  outputs = lib.optionalAttrs (packageName != null && packageVersion != null) {
    ${packageName} = {
      version = packageVersion;
      tarball = "${packageName}_${packageVersion}.tar.gz";
    };
  };
in
{
  inherit
    problems
    entries
    outputs
    outside
    records
    rVersion
    bioconductor
    ;
}
