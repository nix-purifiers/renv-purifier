# SPDX-License-Identifier: MIT
#
# The lock run of `renv-purifier lock`. It reads the project's renv.lock,
# finds every package's source download the way renv's own retrieval does
# (renv R/retrieve.R), downloads and hashes it, and writes
# renv-purifier.lock.json. It installs nothing: every package is built later,
# in the Nix sandbox.
#
# Usage: Rscript lock.R <project directory> <lock format version>

script <- sub("^--file=", "", grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE))
source(file.path(dirname(normalizePath(script)), "urls.R"))

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
renvLock <- jsonlite::read_json(renvLockPath)

workdir <- tempfile("renv-purifier-")
dir.create(workdir)
on.exit(unlink(workdir, recursive = TRUE), add = TRUE)

# The packages of priority "base" ship with R itself.
basePackages <- rownames(installed.packages(priority = "base"))

# The repositories by name: the lockfile's own, then the ones renv adds for
# R-Forge and for the Bioconductor release the lockfile names.
repositories <- list()
for (repository in renvLock$R$Repositories)
  repositories[[repository$Name]] <- sub("/+$", "", repository$URL)
if (is.null(repositories[["R-Forge"]]))
  repositories[["R-Forge"]] <- "https://R-Forge.R-project.org"

biocVersion <- renvLock$Bioconductor$Version
biocRepositories <- list()
if (!is.null(biocVersion)) {
  root <- sprintf("https://bioconductor.org/packages/%s", biocVersion)
  biocRepositories <- list(
    BioCsoft = file.path(root, "bioc"),
    BioCann = file.path(root, "data/annotation"),
    BioCexp = file.path(root, "data/experiment"),
    BioCworkflows = file.path(root, "workflows"),
    BioCbooks = file.path(root, "books")
  )
}

nixHash <- function(path, sri) {
  args <- c("--type", "sha256", "--flat", if (sri) "--sri", shQuote(path))
  hash <- system2("nix-hash", args, stdout = TRUE)
  if (!length(hash) || !nzchar(hash[[1]]))
    fail("nix-hash failed on %s", path)
  hash[[1]]
}

# Downloads the first URL that works, and returns it with the hash of what it
# served; NULL when none works.
download <- function(urls) {
  destination <- file.path(workdir, "download")
  for (url in urls) {
    unlink(destination)
    status <- tryCatch(
      suppressWarnings(download.file(url, destination, mode = "wb", quiet = TRUE, method = "libcurl")),
      error = function(error) 1L
    )
    if (identical(status, 0L) && file.exists(destination) && file.size(destination) > 0)
      return(list(url = url, hash = nixHash(destination, sri = TRUE)))
  }
  NULL
}

fileEntry <- function(path, urls) {
  result <- download(urls)
  if (is.null(result))
    return(NULL)
  list(
    path = path,
    url = result$url,
    mirrors = I(setdiff(urls, result$url)),
    hash = result$hash
  )
}

gitEntry <- function(path, url, rev) {
  output <- system2(
    "nix-prefetch-git",
    c("--url", shQuote(url), "--rev", shQuote(rev), "--quiet"),
    stdout = TRUE
  )
  prefetched <- tryCatch(jsonlite::fromJSON(paste(output, collapse = "\n")), error = function(error) NULL)
  if (is.null(prefetched$hash))
    fail("nix-prefetch-git could not fetch %s at %s", url, rev)
  list(
    path = path,
    # renv's git fetch runs no submodule step and keeps no .git, so neither
    # does the checkout, and it needs no commit object to rebuild one.
    git = list(url = url, rev = rev, submodules = FALSE, leaveDotGit = FALSE, commitObject = NULL),
    hash = prefetched$hash
  )
}

lockPackage <- function(record) {
  package <- record$Package
  version <- record$Version
  sha <- record$RemoteSha
  source <- tolower(record$Source %||% "unknown")
  # renv looks a package up in its cellar under this name (renv
  # R/retrieve.R, renv_retrieve_name).
  cellarName <- sprintf("%s_%s.tar.gz", package, sha %||% version)
  entry <- NULL
  convert <- "none"
  local <- NULL
  outside <- NULL

  if (source %in% c("repository", "cran")) {
    name <- record$Repository %||% "CRAN"
    repository <- if (grepl("://", name, fixed = TRUE)) name else repositories[[name]]
    if (is.null(repository))
      fail("%s %s comes from repository %s, which renv.lock does not list", package, version, name)
    entry <- fileEntry(file.path(package, cellarName), repositoryUrls(repository, package, version))
  } else if (source == "bioconductor") {
    if (is.null(biocVersion))
      fail("%s %s comes from Bioconductor, and renv.lock names no Bioconductor version", package, version)
    name <- record$Repository %||% "BioCsoft"
    candidates <- if (!is.null(biocRepositories[[name]])) biocRepositories[name] else biocRepositories
    urls <- unlist(lapply(candidates, repositoryUrls, package = package, version = version), use.names = FALSE)
    entry <- fileEntry(file.path(package, cellarName), urls)
    # Bioconductor does not archive superseded versions, so renv's last
    # resort is the commit the package was built from.
    if (is.null(entry) && !is.null(record$git_url) && !is.null(record$git_last_commit)) {
      entry <- gitEntry(file.path("git", package), record$git_url, record$git_last_commit)
      convert <- "git"
    }
  } else if (source == "github") {
    entry <- fileEntry(file.path(package, cellarName), githubUrl(record))
  } else if (source == "gitlab") {
    entry <- fileEntry(file.path(package, cellarName), gitlabUrl(record))
  } else if (source == "bitbucket") {
    entry <- fileEntry(file.path(package, cellarName), bitbucketUrl(record))
  } else if (source == "git") {
    entry <- gitEntry(file.path("git", package), record$RemoteUrl, sha)
    convert <- "git"
  } else if (source == "url") {
    url <- record$RemoteUrl
    if (grepl("[.]zip$", url)) {
      entry <- fileEntry(file.path(package, sprintf("%s_%s.zip", package, version)), url)
      convert <- "zip"
    } else {
      entry <- fileEntry(file.path(package, cellarName), url)
    }
  } else if (source %in% c("local", "cellar")) {
    path <- record$RemoteUrl %||% ""
    absolute <- normalizePath(file.path(project, path), mustWork = FALSE)
    inside <- startsWith(absolute, paste0(project, "/"))
    if (!grepl("^/", path) && inside && file.exists(absolute)) {
      local <- path
    } else {
      # A path outside the project is not part of the source Nix copies.
      # buildRenvProject looks for it at the recorded path from the project,
      # and takes it through `localPackages` otherwise.
      convert <- "external"
      outside <- path
    }
  } else {
    fail("%s %s has source %s, which renv-purifier does not know", package, version, record$Source)
  }

  if (convert != "external" && is.null(local) && is.null(entry))
    fail("could not download %s %s (%s)", package, version, record$Source)

  message(sprintf("- %s %s (%s)", package, version, record$Source))
  list(
    name = package,
    version = version,
    cellarName = cellarName,
    convert = convert,
    download = entry,
    local = local,
    outside = outside
  )
}

records <- renvLock$Packages
records <- records[setdiff(sort(names(records)), basePackages)]
packages <- unname(lapply(records, lockPackage))

# BiocManager validates the Bioconductor version against the configuration
# file Bioconductor publishes, which changes with every release, so the lock
# holds its contents.
inline <- list()
if (!is.null(biocVersion)) {
  config <- file.path(workdir, "config.yaml")
  status <- tryCatch(download.file("https://bioconductor.org/config.yaml", config, quiet = TRUE), error = function(error) 1L)
  if (!identical(status, 0L))
    fail("could not download https://bioconductor.org/config.yaml")
  inline[[1]] <- list(
    path = "bioconductor/config.yaml",
    contents = paste(readLines(config, warn = FALSE), collapse = "\n")
  )
}

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
  inline = I(inline),
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
