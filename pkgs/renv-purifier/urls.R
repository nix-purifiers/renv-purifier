# SPDX-License-Identifier: MIT
#
# The download URLs of renv lockfile records, built the way renv's own
# retrieval builds them (renv R/retrieve.R). lock.R uses them, and
# test-urls.R checks them.

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
