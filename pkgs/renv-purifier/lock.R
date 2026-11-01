# SPDX-License-Identifier: MIT
#
# The lock run of `renv-purifier lock`. It reads the project's renv.lock,
# plans each package's source download with records.R, downloads and hashes
# it, and writes renv-purifier.lock.json. It installs nothing: every package
# is built later, in the Nix sandbox.
#
# Usage: Rscript lock.R <project directory> <lock format version>

script <- sub("^--file=", "", grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE))
source(file.path(dirname(normalizePath(script)), "records.R"))

args <- commandArgs(trailingOnly = TRUE)
project <- normalizePath(args[[1]], mustWork = TRUE)
formatVersion <- as.integer(args[[2]])

fail <- function(...) {
  message("renv-purifier: ", sprintf(...))
  quit(status = 1)
}

renvLockPath <- file.path(project, "renv.lock")
if (!file.exists(renvLockPath))
  fail("%s has no renv.lock; run renv::snapshot() first", project)
renvLock <- tryCatch(
  jsonlite::read_json(renvLockPath),
  error = function(error) fail("%s is not valid JSON: %s", renvLockPath, conditionMessage(error))
)

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

lockPackage <- function(record) {
  plan <- tryCatch(planRecord(record, context), error = function(error) fail("%s", conditionMessage(error)))
  entry <- entryFor(plan$fetch)
  if (is.null(entry) && !is.null(plan$fallback)) {
    entry <- entryFor(plan$fallback)
    plan$convert <- "git"
  }
  if (!is.null(plan$fetch) && is.null(entry)) {
    # `[[` matches names exactly; `$url` would also match `urls`.
    tried <- if (plan$fetch[["kind"]] == "git") plan$fetch[["url"]] else plan$fetch[["urls"]]
    fail(
      "could not download %s %s (%s) from %s",
      plan$name, plan$version, record$Source, paste(tried, collapse = ", ")
    )
  }
  message(sprintf("- %s %s (%s)", plan$name, plan$version, record$Source))
  list(
    name = plan$name,
    version = plan$version,
    cellarName = plan$cellarName,
    convert = plan$convert,
    download = entry,
    local = plan$local,
    outside = plan$outside
  )
}

records <- renvLock$Packages
records <- records[setdiff(sort(names(records)), basePackages)]
packages <- unname(lapply(records, lockPackage))

# The project's own package, when the project is one.
outputs <- list()
description <- file.path(project, "DESCRIPTION")
if (file.exists(description)) {
  fields <- read.dcf(description, fields = c("Package", "Version"))
  if (!is.na(fields[1, "Package"]) && !is.na(fields[1, "Version"])) {
    outputs$package <- list(
      name = fields[1, "Package"],
      version = fields[1, "Version"],
      tarball = sprintf("%s_%s.tar.gz", fields[1, "Package"], fields[1, "Version"])
    )
  }
}

lock <- list(
  version = formatVersion,
  renvLock = nixHash(renvLockPath, sri = FALSE),
  r = renvLock$R$Version,
  bioconductor = biocVersion,
  packages = packages,
  inline = I(list()),
  outputs = if (length(outputs)) outputs else setNames(list(), character())
)

jsonlite::write_json(
  lock,
  file.path(project, "renv-purifier.lock.json"),
  auto_unbox = TRUE,
  pretty = TRUE,
  null = "null"
)
message(sprintf("renv-purifier: wrote %s", file.path(project, "renv-purifier.lock.json")))
