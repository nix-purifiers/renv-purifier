#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# The conformance-update check of the purifier contract: `renv-purifier
# update glue` on a copy of tests/fixtures/update, whose renv.lock pins glue
# at 1.6.2, moves glue to a newer version, and both lockfiles then pass the
# stale check: renv::status() finds renv.lock and the project library in
# step, and readLock has no problems. It needs the network (CRAN) and runs
# from the repository root:
#
#   tests/conformance-update.sh
set -euo pipefail

cli=$(nix build --no-link --print-out-paths '.#cli')/bin/renv-purifier

work=$(mktemp -d)
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
project="$work/update"
cp -r tests/fixtures/update "$project"
chmod -R u+w "$project"
export RENV_PATHS_ROOT="$work/renv-root"
export XDG_CACHE_HOME="$work/cache"

glue_version() {
  nix run 'nixpkgs#jq' -- -r '.Packages.glue.Version' "$project/renv.lock"
}

before=$(glue_version)
"$cli" update --project "$project" glue
after=$(glue_version)
echo "glue: $before -> $after" >&2
if [ "$after" = null ] || [ "$(printf '%s\n' "$before" "$after" | sort -V | tail -1)" != "$after" ] ||
  [ "$before" = "$after" ]; then
  echo "update did not move glue from $before to a newer version (renv.lock has $after)" >&2
  exit 1
fi

(
  cd "$project"
  # shellcheck disable=SC2016 # R code, expanded by R
  .renv-purifier/prefetch/R/bin/Rscript -e '
    source("renv/activate.R")
    stopifnot(isTRUE(renv::status()$synchronized))
  '
)

problems=$(nix eval --impure --json --expr \
  "((builtins.getFlake \"git+file://$PWD\").lib.renv-purifier.readLock { src = /. + \"$project\"; }).problems")
if [ "$problems" != "[]" ]; then
  echo "the updated lockfiles have problems: $problems" >&2
  exit 1
fi
