# SPDX-License-Identifier: MIT
#
# Checks records.R: the plan for a record of every source renv.lock can hold,
# the download URLs renv builds for each, the cellar names, and the records
# renv cannot restore.
#
# Usage: Rscript test-records.R <directory of records.R>

source(file.path(commandArgs(trailingOnly = TRUE)[[1]], "records.R"))

sha <- "094469afaf033af00aeb46527970f1db22f4d49d"

renvLock <- list(
  R = list(Repositories = list(list(Name = "CRAN", URL = "https://cloud.r-project.org/"))),
  Bioconductor = list(Version = "3.23")
)
context <- list(
  repositories = repositoryTable(renvLock),
  biocVersion = "3.23",
  biocRepositories = biocTable("3.23"),
  project = "/work/project",
  # Only the project's local/helper directory exists.
  exists = function(path) identical(path, "/work/project/local/helper")
)
plan <- function(...) planRecord(list(...), context)
fails <- function(expr, pattern) {
  message <- tryCatch({ force(expr); "" }, error = conditionMessage)
  grepl(pattern, message, fixed = TRUE)
}

stopifnot(
  identical(lexicalPath("/work/project/./local/helper"), "/work/project/local/helper"),
  identical(lexicalPath("/work/project/../shared/greeter"), "/work/shared/greeter"),
  identical(lexicalPath("/a//b/"), "/a/b")
)

# The repository table drops trailing slashes and adds R-Forge.
stopifnot(
  identical(context$repositories$CRAN, "https://cloud.r-project.org"),
  identical(context$repositories[["R-Forge"]], "https://R-Forge.R-project.org"),
  identical(biocTable(NULL), list()),
  identical(context$biocRepositories$BioCann, "https://bioconductor.org/packages/3.23/data/annotation")
)

# CRAN: the current place first, the archive layouts as mirrors, and the
# cellar name from the version. Every other listed repository follows.
cran <- plan(Package = "glue", Version = "1.6.2", Source = "Repository", Repository = "CRAN")
stopifnot(
  identical(cran$cellarName, "glue_1.6.2.tar.gz"),
  identical(cran$convert, "none"),
  identical(cran$fetch$kind, "file"),
  identical(cran$fetch$path, "glue/glue_1.6.2.tar.gz"),
  identical(head(cran$fetch$urls, 3), c(
    "https://cloud.r-project.org/src/contrib/glue_1.6.2.tar.gz",
    "https://cloud.r-project.org/src/contrib/Archive/glue/glue_1.6.2.tar.gz",
    "https://cloud.r-project.org/src/contrib/Archive/glue/1.6.2/glue_1.6.2.tar.gz"
  )),
  identical(cran$fetch$urls[[4]], "https://R-Forge.R-project.org/src/contrib/glue_1.6.2.tar.gz")
)

# A repository recorded by URL comes first, before the listed ones.
byUrl <- plan(Package = "pkg", Version = "1.0", Source = "Repository", Repository = "https://r.example.com")
stopifnot(
  identical(byUrl$fetch$urls[[1]], "https://r.example.com/src/contrib/pkg_1.0.tar.gz"),
  identical(byUrl$fetch$urls[[4]], "https://cloud.r-project.org/src/contrib/pkg_1.0.tar.gz")
)

# A recorded repository renv.lock does not list, such as RSPM, and a record
# with none, try every listed repository in order, as renv does.
for (record in list(
  list(Package = "askpass", Version = "1.2.1", Source = "Repository", Repository = "RSPM"),
  list(Package = "askpass", Version = "1.2.1", Source = "Repository")
)) {
  rspm <- planRecord(record, context)
  stopifnot(
    identical(rspm$fetch$urls[[1]], "https://cloud.r-project.org/src/contrib/askpass_1.2.1.tar.gz"),
    identical(rspm$fetch$urls[[4]], "https://R-Forge.R-project.org/src/contrib/askpass_1.2.1.tar.gz")
  )
}

# R-Forge, which renv adds on its own.
rforge <- plan(Package = "pkg", Version = "1.0", Source = "Repository", Repository = "R-Forge")
stopifnot(identical(rforge$fetch$urls[[1]], "https://R-Forge.R-project.org/src/contrib/pkg_1.0.tar.gz"))

# Bioconductor: the recorded repository, and the commit as a fallback.
bioc <- plan(
  Package = "BiocGenerics", Version = "0.58.1", Source = "Bioconductor", Repository = "BioCsoft",
  git_url = "https://git.bioconductor.org/packages/BiocGenerics", git_last_commit = "abc1234"
)
stopifnot(
  identical(bioc$fetch$urls[[1]], "https://bioconductor.org/packages/3.23/bioc/src/contrib/BiocGenerics_0.58.1.tar.gz"),
  identical(bioc$fallback$kind, "git"),
  identical(bioc$fallback$rev, "abc1234"),
  identical(bioc$fallback$path, "git/BiocGenerics")
)
# Without a recorded repository, every Bioconductor repository is a candidate.
stopifnot(length(plan(Package = "x", Version = "1", Source = "Bioconductor")$fetch$urls) == 15)
stopifnot(fails(
  planRecord(list(Package = "x", Version = "1", Source = "Bioconductor"), modifyList(context, list(biocVersion = NULL))),
  "renv.lock names no Bioconductor version"
))

# GitHub: the API tarball of the commit, and the cellar name from the commit.
github <- plan(Package = "praise", Version = "1.0.0", Source = "GitHub", RemoteUsername = "rladies", RemoteRepo = "praise", RemoteSha = sha)
stopifnot(
  identical(github$cellarName, paste0("praise_", sha, ".tar.gz")),
  identical(github$fetch$urls, paste0("https://api.github.com/repos/rladies/praise/tarball/", sha))
)
# GitHub Enterprise records name their API host.
enterprise <- plan(
  Package = "pkg", Version = "1", Source = "GitHub",
  RemoteHost = "github.example.com/api/v3", RemoteUsername = "team", RemoteRepo = "pkg", RemoteSha = sha
)
stopifnot(identical(enterprise$fetch$urls, paste0("https://github.example.com/api/v3/repos/team/pkg/tarball/", sha)))

# GitLab: the project path, URL-encoded, as the project id.
gitlab <- plan(Package = "pkg", Version = "1", Source = "GitLab", RemoteUsername = "group/subgroup", RemoteRepo = "pkg", RemoteSha = sha)
stopifnot(identical(gitlab$fetch$urls, paste0("https://gitlab.com/api/v4/projects/group%2Fsubgroup%2Fpkg/repository/archive.tar.gz?sha=", sha)))
selfHosted <- plan(
  Package = "pkg", Version = "1", Source = "GitLab",
  RemoteHost = "gitlab.example.com", RemoteUsername = "team", RemoteRepo = "pkg", RemoteSha = sha
)
stopifnot(identical(selfHosted$fetch$urls, paste0("https://gitlab.example.com/api/v4/projects/team%2Fpkg/repository/archive.tar.gz?sha=", sha)))

# Bitbucket.
bitbucket <- plan(Package = "pkg", Version = "1", Source = "Bitbucket", RemoteUsername = "team", RemoteRepo = "pkg", RemoteSha = sha)
stopifnot(identical(bitbucket$fetch$urls, paste0("https://bitbucket.org/team/pkg/get/", sha, ".tar.gz")))

# git: a checkout, packed by Nix.
git <- plan(Package = "prettyunits", Version = "1.2.0.9000", Source = "git", RemoteUrl = "https://github.com/r-lib/prettyunits.git", RemoteSha = sha)
stopifnot(
  identical(git$fetch$kind, "git"),
  identical(git$fetch$url, "https://github.com/r-lib/prettyunits.git"),
  identical(git$fetch$rev, sha),
  identical(git$convert, "git"),
  identical(git$cellarName, paste0("prettyunits_", sha, ".tar.gz"))
)

# URL: a tarball as it is, and a zip file repacked by Nix.
tarball <- plan(Package = "rematch", Version = "1.0.1", Source = "URL", RemoteUrl = "https://example.com/rematch_1.0.1.tar.gz")
stopifnot(identical(tarball$convert, "none"), identical(tarball$fetch$path, "rematch/rematch_1.0.1.tar.gz"))
zip <- plan(Package = "praise", Version = "1.0.0", Source = "URL", RemoteUrl = "https://example.com/praise.zip")
stopifnot(
  identical(zip$convert, "zip"),
  identical(zip$fetch$path, "praise/praise_1.0.0.zip"),
  identical(zip$cellarName, "praise_1.0.0.tar.gz")
)

# Local: a directory in the project needs no download; one outside it, or
# missing, or absolute, is packed from `localPackages`.
inside <- plan(Package = "helper", Version = "0.1", Source = "Local", RemoteUrl = "./local/helper")
stopifnot(identical(inside$local, "./local/helper"), is.null(inside$fetch), identical(inside$convert, "none"))
outside <- plan(Package = "greeter", Version = "0.2", Source = "Local", RemoteUrl = "../shared/greeter")
stopifnot(identical(outside$convert, "external"), identical(outside$outside, "../shared/greeter"), is.null(outside$fetch))
absolute <- plan(Package = "x", Version = "1", Source = "Local", RemoteUrl = "/work/project/local/helper")
stopifnot(identical(absolute$convert, "external"))
missing <- plan(Package = "x", Version = "1", Source = "Local", RemoteUrl = "./local/missing")
stopifnot(identical(missing$convert, "external"))

# A source renv-purifier does not know.
stopifnot(fails(plan(Package = "x", Version = "1", Source = "Mystery"), "has source Mystery, which renv-purifier does not know"))

cat("records.R: all plans match\n")
