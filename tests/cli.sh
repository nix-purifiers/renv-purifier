#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Tests what runs outside the Nix sandbox, on copies of the fixtures:
#
# - the lock run reproduces the committed lockfiles byte for byte
# - `renv-purifier build` builds an R environment that runs the project
# - `renv-purifier restore` installs the project library with every network
#   request refused
# - adding a dependency to renv.lock, relocking and building works
# - every common mistake stops with a message that names the fix: a
#   renv.lock with merge conflict markers, a malformed purifier lockfile, a
#   stale lock, a package missing from the lock, and an edited hash
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

# Runs a command that must fail, and checks that its output names the fix.
fails_with() {
  local expected="$1"
  shift
  local output
  if output=$("$@" 2>&1); then
    echo "expected a failure: $*" >&2
    exit 1
  fi
  if ! grep -qF -- "$expected" <<<"$output"; then
    echo "expected \"$expected\" from: $*" >&2
    echo "$output" >&2
    exit 1
  fi
}

# A copy of the hello fixture under a new name.
copy_hello() {
  cp -r "$work/hello" "$work/$1"
  rm -rf "$work/$1/renv/library" "$work/$1/result-"*
}

echo "== lock run reproduces the lockfiles"
for fixture in hello sources editor old-renv; do
  start=$(date +%s)
  "$cli" lock "$work/$fixture"
  echo "relocked $fixture in $(($(date +%s) - start))s"
  cmp "$root/tests/fixtures/$fixture/renv-purifier.lock.json" "$work/$fixture/renv-purifier.lock.json"
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

echo "== add a dependency, relock and build"
# renv::record() adds crayon to renv.lock from repository metadata, as
# renv::install() and renv::snapshot() would after installing it. With
# `enrich = FALSE`, the record holds the package, its version and its
# repository.
copy_hello added
renv=$(nix build --no-link --print-out-paths 'nixpkgs#rPackages.renv')
(
  cd "$work/added"
  R_LIBS_SITE="$renv/library" nix run 'nixpkgs#R' -- --vanilla --no-echo -e 'renv::record("crayon@1.5.3", enrich = FALSE)'
)
fails_with "changed after" "$cli" build "$work/added"
"$cli" lock "$work/added"
"$cli" build "$work/added"
"$work/added/result-env/bin/Rscript" -e 'stopifnot(packageVersion("crayon") == "1.5.3")'

echo "== mistakes name their fix"
copy_hello conflict
sed -i '0,/"Packages": {/s//"Packages": {\n<<<<<<< Updated upstream/' "$work/conflict/renv.lock"
fails_with "is not valid JSON (look for merge conflict markers)" "$cli" lock "$work/conflict"

copy_hello malformed
head -c 200 "$root/tests/fixtures/hello/renv-purifier.lock.json" > "$work/malformed/renv-purifier.lock.json"
fails_with "renv-purifier.lock.json is not valid JSON; run renv-purifier lock" "$cli" build "$work/malformed"

copy_hello missing
jq '.packages |= map(select(.name != "glue"))' "$root/tests/fixtures/hello/renv-purifier.lock.json" > "$work/missing/renv-purifier.lock.json"
fails_with "renv.lock names glue, which" "$cli" build "$work/missing"

copy_hello tampered
jq '(.packages[] | select(.name == "glue") | .download.hash) = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="' \
  "$root/tests/fixtures/hello/renv-purifier.lock.json" > "$work/tampered/renv-purifier.lock.json"
fails_with "hash mismatch" "$cli" build "$work/tampered"

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
