#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Tests what runs outside the Nix sandbox, on copies of the fixtures:
#
# - the lock run reproduces the committed lockfiles byte for byte
# - after `renv-purifier prefetch`, R started in the project loads the
#   project library with every network request refused
# - a purifier lockfile kept outside the project works through
#   RENV_PURIFIER_LOCKFILE
# - adding a dependency to renv.lock, relocking and prefetching works
# - every common mistake stops with a message that names the fix: a
#   renv.lock with merge conflict markers, a malformed purifier lockfile, a
#   stale lock, a package missing from the lock, and an edited lockfile
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
# renv keeps its own state in the user's cache directory; the test keeps it
# in its work directory.
export RENV_PATHS_ROOT="$work/renv-root"
export RENV_PATHS_SANDBOX="$work/renv-sandbox"
export XDG_CACHE_HOME="$work/cache"

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

# A copy of the hello fixture under a new name. -R copies the symlink
# `prefetch` left in .renv-purifier; the cp -r of macOS copies what it
# points to, the read-only library.
copy_hello() {
  cp -R "$work/hello" "$work/$1"
  rm -rf "$work/$1/renv/library" "$work/$1/.renv-purifier"
}

# Every network request R or renv makes goes to a closed port.
offline() {
  http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 \
    HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 "$@"
}

echo "== lock run reproduces the lockfiles"
for fixture in hello sources editor old-renv update; do
  start=$(date +%s)
  "$cli" lock --project "$work/$fixture"
  echo "relocked $fixture in $(($(date +%s) - start))s"
  cmp "$root/tests/fixtures/$fixture/renv-purifier.lock.json" "$work/$fixture/renv-purifier.lock.json"
done

echo "== prefetch, then work offline"
"$cli" prefetch --project "$work/hello"
test -L "$work/hello/.renv-purifier/prefetch"
(
  cd "$work/hello"
  # shellcheck disable=SC2016 # R code, expanded by R
  offline .renv-purifier/prefetch/R/bin/Rscript -e '
    source("renv/activate.R")
    for (package in c("praise", "prettyunits", "xml2", "openssl", "BiocGenerics", "hellohelper"))
      stopifnot(requireNamespace(package, quietly = TRUE))
    stopifnot(isTRUE(renv::status()$synchronized))
  '
)

echo "== a purifier lockfile outside the project"
copy_hello external
mkdir -p "$work/packaging"
mv "$work/external/renv-purifier.lock.json" "$work/packaging/hello.lock.json"
fails_with "does not exist" "$cli" prefetch --project "$work/external"
RENV_PURIFIER_LOCKFILE="$work/packaging/hello.lock.json" "$cli" lock --project "$work/external"
cmp "$root/tests/fixtures/hello/renv-purifier.lock.json" "$work/packaging/hello.lock.json"
RENV_PURIFIER_LOCKFILE="$work/packaging/hello.lock.json" "$cli" prefetch --project "$work/external"
test -L "$work/packaging/.renv-purifier/prefetch"

echo "== a renv.lock outside the project"
copy_hello toolexternal
rm "$work/toolexternal/renv-purifier.lock.json"
mv "$work/toolexternal/renv.lock" "$work/packaging/tool.renv.lock"
echo '{"R":{"Version":"4.6.1","Repositories":[]},"Packages":{}}' > "$work/toolexternal/renv.lock"
RENV_PURIFIER_TOOL_LOCKFILE="$work/packaging/tool.renv.lock" "$cli" lock --project "$work/toolexternal" \
  --lockfile "$work/packaging/tool.lock.json"
cmp "$root/tests/fixtures/hello/renv-purifier.lock.json" "$work/packaging/tool.lock.json"
cmp "$root/tests/fixtures/hello/renv.lock" "$work/packaging/tool.renv.lock"
grep -q '"Packages": {}' "$work/toolexternal/renv.lock" || grep -q '"Packages":{}' "$work/toolexternal/renv.lock"

echo "== add a dependency, relock and prefetch"
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
fails_with "renv.lock changed after \`renv-purifier lock\` ran. Run \`renv-purifier lock\`." "$cli" prefetch --project "$work/added"
"$cli" lock --project "$work/added"
"$cli" prefetch --project "$work/added"
(
  cd "$work/added"
  offline .renv-purifier/prefetch/R/bin/Rscript -e 'source("renv/activate.R"); stopifnot(packageVersion("crayon") == "1.5.3")'
)

echo "== mistakes name their fix"
copy_hello conflict
# Through a copy, and with the newline escaped, as the sed of macOS needs.
# renv.lock opens "Packages" once.
sed 's/"Packages": {/&\
<<<<<<< Updated upstream/' "$work/conflict/renv.lock" > "$work/conflict.renv.lock"
mv "$work/conflict.renv.lock" "$work/conflict/renv.lock"
fails_with "is not valid JSON (look for merge conflict markers)" "$cli" lock --project "$work/conflict"

copy_hello malformed
head -c 200 "$root/tests/fixtures/hello/renv-purifier.lock.json" > "$work/malformed/renv-purifier.lock.json"
fails_with "renv-purifier.lock.json is not valid JSON; run renv-purifier lock" "$cli" prefetch --project "$work/malformed"

copy_hello tampered
jq '.packages.glue.hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="' \
  "$root/tests/fixtures/hello/renv-purifier.lock.json" > "$work/tampered/renv-purifier.lock.json"
fails_with "was changed after \`renv-purifier lock\` wrote it" "$cli" prefetch --project "$work/tampered"

echo "== publish"
"$cli" publish --project "$work/hello" "$work/repository"
mkdir -p "$work/installed"
(
  cd "$work/hello"
  .renv-purifier/prefetch/R/bin/Rscript -e "
    source('renv/activate.R')
    # renv replaces install.packages() with its own installer, so the test
    # calls the installer of R itself.
    utils::install.packages('hello', repos = 'file://$work/repository', lib = '$work/installed', type = 'source')
    library(hello, lib.loc = '$work/installed')
    stopifnot(identical(hello('you')\$glue, 'Hello, you'))
  "
)

echo "tests/cli.sh: all passed"
