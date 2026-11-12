# SPDX-License-Identifier: MIT
#
# The lock run of `renv-purifier lock`. It reads the project's renv.lock,
# plans each package's source download with records.R, downloads and hashes
# it, and writes renv-purifier.lock.json. It installs nothing: every package
# is built later, in the Nix sandbox.
#
# Usage: Rscript lock.R <project directory> <renv.lock> <lockfile> <lock format version>

script <- sub("^--file=", "", grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE))
source(file.path(dirname(normalizePath(script)), "records.R"))

args <- commandArgs(trailingOnly = TRUE)
project <- normalizePath(args[[1]], mustWork = TRUE)
renvLockPath <- args[[2]]
lockPath <- args[[3]]
formatVersion <- as.integer(args[[4]])

fail <- function(...) {
  message("renv-purifier: ", sprintf(...))
  quit(status = 1)
}

if (!file.exists(renvLockPath))
  fail("%s does not exist; run renv::snapshot() first", renvLockPath)
renvLock <- tryCatch(
  jsonlite::read_json(renvLockPath),
  error = function(error) fail("%s is not valid JSON: %s", renvLockPath, conditionMessage(error))
)
previous <- if (file.exists(lockPath))
  tryCatch(jsonlite::read_json(lockPath), error = function(error) NULL) else NULL
previousPackages <- if (is.list(previous) && is.list(previous$packages)) previous$packages else list()

workdir <- tempfile("renv-purifier-")
dir.create(workdir)
on.exit(unlink(workdir, recursive = TRUE), add = TRUE)

# The packages of priority "base" ship with R itself.
basePackages <- rownames(installed.packages(priority = "base"))

biocVersion <- renvLock$Bioconductor$Version
context <- list(
  repositories = repositoryTable(renvLock),
  biocVersion = biocVersion,
  biocRepositories = biocTable(biocVersion),
  project = project,
  exists = file.exists
)

nixHash <- function(path, sri) {
  args <- c("--type", "sha256", "--flat", if (sri) "--sri", shQuote(path))
  hash <- system2("nix-hash", args, stdout = TRUE)
  if (!length(hash) || !nzchar(hash[[1]]))
    fail("nix-hash failed on %s", path)
  hash[[1]]
}

# Downloads the first URL that works, and returns a file entry with the hash
# of what it served; NULL when none works.
fileEntry <- function(fetch) {
  destination <- file.path(workdir, "download")
  for (url in fetch$urls) {
    unlink(destination)
    status <- tryCatch(
      suppressWarnings(download.file(url, destination, mode = "wb", quiet = TRUE, method = "libcurl")),
      error = function(error) 1L
    )
    if (identical(status, 0L) && file.exists(destination) && file.size(destination) > 0)
      return(list(
        path = fetch$path,
        url = url,
        mirrors = I(setdiff(fetch$urls, url)),
        hash = nixHash(destination, sri = TRUE)
      ))
  }
  NULL
}

gitEntry <- function(fetch) {
  output <- suppressWarnings(system2(
    "nix-prefetch-git",
    c("--url", shQuote(fetch$url), "--rev", shQuote(fetch$rev), "--quiet"),
    stdout = TRUE,
    stderr = FALSE
  ))
  prefetched <- tryCatch(jsonlite::fromJSON(paste(output, collapse = "\n")), error = function(error) NULL)
  if (is.null(prefetched$hash))
    return(NULL)
  list(
    path = fetch$path,
    # renv's git fetch runs no submodule step and keeps no .git, so neither
    # does the checkout, and it needs no commit object to rebuild one.
    git = list(url = fetch$url, rev = fetch$rev, submodules = FALSE, leaveDotGit = FALSE, commitObject = NULL),
    hash = prefetched$hash
  )
}

entryFor <- function(fetch) {
  if (is.null(fetch)) NULL else if (fetch$kind == "git") gitEntry(fetch) else fileEntry(fetch)
}

# What the lockfile records for one package: the hash of its download,
# which renv.lock cannot give, and, for a package from a repository, the URL
# the download came from, which depends on where the package was found. Nix
# derives every other download location from renv.lock (lib-overlays/default/lock.nix).
# A package from a directory has no download and no entry.
lockPackage <- function(record, previous = NULL) {
  plan <- tryCatch(planRecord(record, context), error = function(error) fail("%s", conditionMessage(error)))
  if (is.null(plan$fetch))
    return(NULL)
  entry <- entryFor(plan$fetch)
  fallback <- FALSE
  if (is.null(entry) && !is.null(plan$fallback)) {
    entry <- entryFor(plan$fallback)
    fallback <- !is.null(entry)
  }
  if (is.null(entry)) {
    # `[[` matches names exactly; `$url` would also match `urls`.
    tried <- if (plan$fetch[["kind"]] == "git") plan$fetch[["url"]] else plan$fetch[["urls"]]
    fail(
      "could not download %s %s (%s) from %s",
      plan$name, plan$version, record$Source, paste(tried, collapse = ", ")
    )
  }
  message(sprintf("- %s %s (%s)", plan$name, plan$version, record$Source))
  source <- tolower(record$Source %||% "")
  if (fallback)
    list(fallback = "git", hash = entry$hash)
  else if (source %in% c("repository", "cran", "bioconductor"))
    repositoryLockEntry(entry, plan$fetch, previous)
  else
    list(hash = entry$hash)
}

records <- renvLock$Packages
# The radix method sorts in byte order whatever the locale, so the lockfile
# is the same on every machine.
names <- setdiff(sort(names(records), method = "radix"), basePackages)
packages <- setNames(list(), character())
for (name in names) {
  entry <- lockPackage(records[[name]], previousPackages[[name]])
  if (!is.null(entry))
    packages[[name]] <- entry
}

lock <- list(
  packages = packages,
  renvLock = nixHash(renvLockPath, sri = FALSE),
  version = formatVersion
)

# The hash of the lockfile's own content: the SHA-256 of the JSON that Nix's
# builtins.toJSON writes for every field but contentHash. Nix computes it,
# so the hash is the one the Nix library checks. The expression names the
# file with a Nix path, so its physical path: on macOS, TMPDIR ends in a
# slash and goes through the /var symlink, and a "//" ends a Nix path.
unhashed <- file.path(normalizePath(workdir), "unhashed.json")
jsonlite::write_json(lock, unhashed, auto_unbox = TRUE)
expression <- sprintf(
  'builtins.hashString "sha256" (builtins.toJSON (builtins.fromJSON (builtins.readFile %s)))',
  unhashed
)
contentHash <- system2("nix-instantiate", c("--eval", "--expr", shQuote(expression)), stdout = TRUE)
contentHash <- gsub('"', "", contentHash[length(contentHash)])
if (!grepl("^[0-9a-f]{64}$", contentHash))
  fail("nix-instantiate could not hash the lockfile")

lock <- c(list(contentHash = contentHash), lock)
jsonlite::write_json(lock, lockPath, auto_unbox = TRUE, pretty = TRUE)
message(sprintf("renv-purifier: wrote %s", lockPath))
