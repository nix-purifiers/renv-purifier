# SPDX-License-Identifier: MIT
#
# Checks the download URLs of urls.R against the ones renv builds for the
# same records.
#
# Usage: Rscript test-urls.R <directory of urls.R>

source(file.path(commandArgs(trailingOnly = TRUE)[[1]], "urls.R"))

sha <- "094469afaf033af00aeb46527970f1db22f4d49d"

stopifnot(identical(
  repositoryUrls("https://cloud.r-project.org", "glue", "1.6.2"),
  c(
    "https://cloud.r-project.org/src/contrib/glue_1.6.2.tar.gz",
    "https://cloud.r-project.org/src/contrib/Archive/glue/glue_1.6.2.tar.gz",
    "https://cloud.r-project.org/src/contrib/Archive/glue/1.6.2/glue_1.6.2.tar.gz"
  )
))

stopifnot(identical(
  githubUrl(list(RemoteUsername = "rladies", RemoteRepo = "praise", RemoteSha = sha)),
  paste0("https://api.github.com/repos/rladies/praise/tarball/", sha)
))

# GitHub Enterprise records name their API host.
stopifnot(identical(
  githubUrl(list(RemoteHost = "github.example.com/api/v3", RemoteUsername = "team", RemoteRepo = "pkg", RemoteSha = sha)),
  paste0("https://github.example.com/api/v3/repos/team/pkg/tarball/", sha)
))

stopifnot(identical(
  gitlabUrl(list(RemoteUsername = "group/subgroup", RemoteRepo = "pkg", RemoteSha = sha)),
  paste0("https://gitlab.com/api/v4/projects/group%2Fsubgroup%2Fpkg/repository/archive.tar.gz?sha=", sha)
))

stopifnot(identical(
  gitlabUrl(list(RemoteHost = "gitlab.example.com", RemoteUsername = "team", RemoteRepo = "pkg", RemoteSha = sha)),
  paste0("https://gitlab.example.com/api/v4/projects/team%2Fpkg/repository/archive.tar.gz?sha=", sha)
))

stopifnot(identical(
  bitbucketUrl(list(RemoteUsername = "team", RemoteRepo = "pkg", RemoteSha = sha)),
  paste0("https://bitbucket.org/team/pkg/get/", sha, ".tar.gz")
))

cat("urls.R: all URLs match\n")
