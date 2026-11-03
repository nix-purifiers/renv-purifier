# SPDX-License-Identifier: MIT
#
# The plan for each renv.lock record: where renv downloads its source from,
# the name renv looks it up under in a cellar, and what Nix does with the
# download. The URLs are built the way renv's own retrieval builds them
# (renv R/retrieve.R). Nothing here touches the network, so test-records.R
# checks it directly. lock.R carries the plans out.

`%||%` <- function(x, y) if (is.null(x)) y else x

# The source tarball URLs of a package in a CRAN-like repository. The first is
# its current place. The others are the two archive layouts renv tries: the
# one CRAN uses, and the one older Artifactory releases use.
repositoryUrls <- function(repository, package, version) {
  file <- sprintf("%s_%s.tar.gz", package, version)
  c(
    file.path(repository, "src/contrib", file),
    file.path(repository, "src/contrib/Archive", package, file),
    file.path(repository, "src/contrib/Archive", package, version, file)
  )
}

# Preserve the recorded location when the freshly downloaded bytes match
# and that location still belongs to this record's native retrieval plan.
repositoryLockEntry <- function(entry, fetch, previous = NULL) {
  url <- entry$url
  if (is.list(previous) && identical(previous$hash, entry$hash) &&
      is.character(previous$url) && length(previous$url) == 1L && previous$url %in% fetch$urls)
    url <- previous$url
  list(hash = entry$hash, url = url)
}

origin <- function(host, default) {
  host <- host %||% default
  if (grepl("://", host, fixed = TRUE)) host else paste0("https://", host)
}

# renv downloads GitHub packages as the API's tarball of the commit.
githubUrl <- function(record) {
  base <- origin(record$RemoteHost, "api.github.com")
  sprintf("%s/repos/%s/%s/tarball/%s", base, record$RemoteUsername, record$RemoteRepo, record$RemoteSha)
}

# renv downloads GitLab packages as the API's archive of the commit, with the
# project path URL-encoded as the project id.
gitlabUrl <- function(record) {
  base <- origin(record$RemoteHost, "gitlab.com")
  id <- URLencode(paste(record$RemoteUsername, record$RemoteRepo, sep = "/"), reserved = TRUE)
  sprintf("%s/api/v4/projects/%s/repository/archive.tar.gz?sha=%s", base, id, record$RemoteSha)
}

# renv asks the Bitbucket API for the repository's web address and downloads
# `<address>/get/<commit>.tar.gz`. For bitbucket.org, the web address is
# https://bitbucket.org/<user>/<repo>.
bitbucketUrl <- function(record) {
  host <- record$RemoteHost %||% "api.bitbucket.org/2.0"
  base <- if (grepl("api.bitbucket.org", host, fixed = TRUE)) "https://bitbucket.org" else origin(host, host)
  sprintf("%s/%s/%s/get/%s.tar.gz", base, record$RemoteUsername, record$RemoteRepo, record$RemoteSha)
}

# An absolute path with its `.` and `..` components resolved from its text
# alone, so it works for paths that do not exist.
lexicalPath <- function(path) {
  parts <- strsplit(path, "/", fixed = TRUE)[[1]]
  kept <- character()
  for (part in parts) {
    if (part == "" || part == ".") next
    if (part == "..") kept <- head(kept, -1) else kept <- c(kept, part)
  }
  paste0("/", paste(kept, collapse = "/"))
}

# The repositories of a renv.lock by name: its own, then the one renv adds
# for R-Forge.
repositoryTable <- function(renvLock) {
  repositories <- list()
  for (repository in renvLock$R$Repositories)
    repositories[[repository$Name]] <- sub("/+$", "", repository$URL)
  if (is.null(repositories[["R-Forge"]]))
    repositories[["R-Forge"]] <- "https://R-Forge.R-project.org"
  repositories
}

# The repositories of a Bioconductor release, by the names renv records.
biocTable <- function(version) {
  if (is.null(version))
    return(list())
  root <- sprintf("https://bioconductor.org/packages/%s", version)
  list(
    BioCsoft = file.path(root, "bioc"),
    BioCann = file.path(root, "data/annotation"),
    BioCexp = file.path(root, "data/experiment"),
    BioCworkflows = file.path(root, "workflows"),
    BioCbooks = file.path(root, "books")
  )
}

# The plan for one record. `context` holds the renv.lock's `repositories`,
# `biocVersion`, `biocRepositories`, the absolute `project` directory and
# `exists`, a function that tells whether a path exists. A record renv
# cannot restore either is an error.
planRecord <- function(record, context) {
  package <- record$Package
  version <- record$Version
  sha <- record$RemoteSha
  source <- tolower(record$Source %||% "unknown")

  plan <- list(
    name = package,
    version = version,
    # renv looks a package up in its cellar under this name (renv
    # R/retrieve.R, renv_retrieve_name).
    cellarName = sprintf("%s_%s.tar.gz", package, sha %||% version),
    convert = "none",
    local = NULL,
    outside = NULL,
    fetch = NULL,
    fallback = NULL
  )
  fileFetch <- function(urls, path = file.path(package, plan$cellarName))
    list(kind = "file", path = path, urls = urls)
  gitFetch <- function(url, rev)
    list(kind = "git", path = file.path("git", package), url = url, rev = rev)

  if (source %in% c("repository", "cran")) {
    # renv treats the recorded repository as a preference: it tries that
    # repository first when renv.lock lists it, or when the record names it
    # by URL, and then every repository renv.lock lists. A record often names
    # the repository the package was first installed from, such as RSPM,
    # which renv.lock does not list.
    name <- record$Repository %||% ""
    preferred <- if (grepl("://", name, fixed = TRUE)) name else context$repositories[[name]]
    ordered <- unique(c(preferred, unlist(context$repositories, use.names = FALSE)))
    urls <- unlist(lapply(ordered, repositoryUrls, package = package, version = version), use.names = FALSE)
    plan$fetch <- fileFetch(urls)
  } else if (source == "bioconductor") {
    if (is.null(context$biocVersion))
      stop(sprintf("%s %s comes from Bioconductor, and renv.lock names no Bioconductor version", package, version))
    # A record that names no repository, or one renv does not know, may come
    # from any of the release's repositories.
    name <- record$Repository %||% ""
    repositories <- context$biocRepositories
    candidates <- if (!is.null(repositories[[name]])) repositories[name] else repositories
    plan$fetch <- fileFetch(unlist(lapply(candidates, repositoryUrls, package = package, version = version), use.names = FALSE))
    # Bioconductor does not archive superseded versions, so renv's last
    # resort is the commit the package was built from.
    if (!is.null(record$git_url) && !is.null(record$git_last_commit))
      plan$fallback <- gitFetch(record$git_url, record$git_last_commit)
  } else if (source == "github") {
    plan$fetch <- fileFetch(githubUrl(record))
  } else if (source == "gitlab") {
    plan$fetch <- fileFetch(gitlabUrl(record))
  } else if (source == "bitbucket") {
    plan$fetch <- fileFetch(bitbucketUrl(record))
  } else if (source == "git") {
    plan$fetch <- gitFetch(record$RemoteUrl, sha)
    plan$convert <- "git"
  } else if (source == "url") {
    url <- record$RemoteUrl
    if (grepl("[.]zip$", url)) {
      plan$fetch <- fileFetch(url, file.path(package, sprintf("%s_%s.zip", package, version)))
      plan$convert <- "zip"
    } else {
      plan$fetch <- fileFetch(url)
    }
  } else if (source %in% c("local", "cellar")) {
    path <- record$RemoteUrl %||% ""
    absolute <- lexicalPath(file.path(context$project, path))
    inside <- startsWith(absolute, paste0(context$project, "/"))
    if (!grepl("^/", path) && inside && context$exists(absolute)) {
      plan$local <- path
    } else {
      # A path outside the project is not part of the source Nix copies.
      # buildRenvProject looks for it at the recorded path from the project,
      # and takes it through `localPackages` otherwise.
      plan$convert <- "external"
      plan$outside <- path
    }
  } else {
    stop(sprintf("%s %s has source %s, which renv-purifier does not know", package, version, record$Source))
  }
  plan
}
