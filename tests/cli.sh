#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Tests what runs outside the Nix sandbox, on copies of the fixtures:
#
# - the lock run reproduces the committed lockfiles, apart from the copy of
#   the Bioconductor configuration file, which changes with every release
# - `renv-purifier build` builds an R environment that runs the project
# - `renv-purifier restore` installs the project library with every network
#   request refused
# - `renv-purifier publish` makes a repository install.packages() installs
#   the package from
#
# It needs Nix and network access for the lock run. Run it from anywhere:
# tests/cli.sh
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cli=$(nix build --no-link --print-out-paths "$root#cli")/bin/renv-purifier
jq() { nix run 'nixpkgs#jq' -- "$@"; }

work=$(mktemp -d)
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
cp -r "$root/tests/fixtures/." "$work/"
chmod -R u+w "$work"
# renv keeps the library of a package project, and its own state, in the
# user's cache directory; the test keeps both in its work directory.
export RENV_PATHS_ROOT="$work/renv-root"
export RENV_PATHS_SANDBOX="$work/renv-sandbox"
export RENV_PATHS_LIBRARY="$work/hello/renv/library"

echo "== lock run"
for fixture in hello sources; do
  "$cli" lock "$work/$fixture"
  diff \
    <(jq 'del(.inline[].contents)' "$root/tests/fixtures/$fixture/renv-purifier.lock.json") \
    <(jq 'del(.inline[].contents)' "$work/$fixture/renv-purifier.lock.json")
done

echo "== build"
"$cli" build "$work/hello"
env="$work/hello/result-env"
"$env/bin/Rscript" -e 'stopifnot(identical(hello::hello("you")$glue, "Hello, you"))'
test -f "$work/hello/result-package/hello_1.0.0.tar.gz"

echo "== restore, offline"
# The build above fetched the cellar, so restoring needs no network: every
# request R or renv makes goes to a closed port.
(
  export http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9
  export HTTP_PROXY=$http_proxy HTTPS_PROXY=$https_proxy
  "$cli" restore "$work/hello"
)
(
  cd "$work/hello"
  # shellcheck disable=SC2016 # R code, expanded by R
  nix run 'nixpkgs#R' -- --no-echo -e '
    source("renv/activate.R")
    for (package in c("praise", "prettyunits", "xml2", "BiocGenerics", "hellohelper"))
      stopifnot(requireNamespace(package, quietly = TRUE))
  '
)

echo "== publish"
"$cli" publish "$work/repository" "$work/hello"
mkdir -p "$work/installed"
# The environment of the build has the package's dependencies.
"$env/bin/Rscript" -e "
  install.packages('hello', repos = 'file://$work/repository', lib = '$work/installed', type = 'source')
  library(hello, lib.loc = '$work/installed')
  stopifnot(identical(hello('you')\$glue, 'Hello, you'))
"

echo "tests/cli.sh: all passed"
