#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Relocks every fixture, and the pinned real-world project, in place with
# `renv-purifier lock`. The conformance-relock job of CI runs it and then
# fails when a lockfile differs from the committed one. It needs the
# network and runs from the repository root:
#
#   tests/relock-fixtures.sh
set -euo pipefail

cli=$(nix build --no-link --print-out-paths '.#cli')/bin/renv-purifier

for fixture in hello sources editor old-renv update; do
  start=$(date +%s)
  "$cli" lock --project "tests/fixtures/$fixture"
  echo "relocked $fixture in $(($(date +%s) - start))s" >&2
done

# r-hub/cransays at the commit tests/default.nix pins. The lock run reads
# its renv.lock and runs none of its code; the purifier lockfile is kept
# outside the project.
cransays=$(mktemp -d)
trap 'rm -rf "$cransays"' EXIT
nix shell --inputs-from . 'nixpkgs#curl' -c curl -sSfL -o "$cransays/renv.lock" \
  https://raw.githubusercontent.com/r-hub/cransays/aeaa1397fdb453e0a5b710ddc03a3fa04a89cf39/renv.lock
"$cli" lock --project "$cransays" --lockfile tests/real/cransays/renv-purifier.lock.json
