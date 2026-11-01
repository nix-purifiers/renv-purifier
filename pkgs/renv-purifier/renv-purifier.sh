# SPDX-License-Identifier: MIT
#
# renv-purifier: locks the downloads of an renv project, and builds and
# installs it from them. See README.md.

usage() {
  cat <<'EOF'
Usage: renv-purifier <command> [arguments]

  lock [project]             Write renv-purifier.lock.json beside renv.lock.
  restore [project]          Install the project library offline from the
                             locked downloads, with renv::restore().
  build [project]            Build the project with Nix: its R environment,
                             and its package when the project is one.
  publish <repository> [project]
                             Add the package Nix built to the CRAN-like
                             repository directory <repository>.

The project defaults to the current directory.
EOF
}

die() {
  echo "renv-purifier: $*" >&2
  exit 1
}

project_dir() {
  local dir="${1:-.}"
  [ -f "$dir/renv.lock" ] || die "$dir has no renv.lock; run renv::init() or renv::snapshot() in the project"
  jq empty "$dir/renv.lock" 2>/dev/null ||
    die "$dir/renv.lock is not valid JSON (look for merge conflict markers); fix it, or run renv::snapshot() again"
  realpath "$dir"
}

require_lock() {
  [ -f "$1/renv-purifier.lock.json" ] || die "$1 has no renv-purifier.lock.json; run renv-purifier lock"
  jq empty "$1/renv-purifier.lock.json" 2>/dev/null ||
    die "$1/renv-purifier.lock.json is not valid JSON; run renv-purifier lock to write it again"
}

# Whether the purifier lock was made from the current renv.lock.
lock_is_fresh() {
  local recorded current
  recorded=$(jq -r .renvLock "$1/renv-purifier.lock.json")
  current=$(nix-hash --type sha256 --flat "$1/renv.lock")
  [ "$recorded" = "$current" ]
}

has_package() {
  jq -e '.outputs.package' "$1/renv-purifier.lock.json" >/dev/null
}

nix_build() {
  local dir="$1"
  shift
  nix-build "$RENV_PURIFIER_LIB/cli.nix" \
    --arg nixpkgs "$RENV_PURIFIER_NIXPKGS" \
    --argstr purifier "$RENV_PURIFIER_LIBRARY" \
    --argstr src "$dir" \
    "$@"
}

command="${1:-}"
[ -n "$command" ] || {
  usage
  exit 1
}
shift

case "$command" in
lock)
  dir=$(project_dir "${1:-}")
  # --vanilla keeps R from reading the .Rprofile of the working directory,
  # which in an renv project activates renv and runs project code.
  Rscript --vanilla "$RENV_PURIFIER_SCRIPTS/lock.R" "$dir" "$RENV_PURIFIER_FORMAT"
  ;;

restore)
  dir=$(project_dir "${1:-}")
  require_lock "$dir"
  if ! lock_is_fresh "$dir"; then
    echo "renv-purifier: renv.lock changed after renv-purifier.lock.json was made; restoring the usual way. Run renv-purifier lock to restore offline again." >&2
    (cd "$dir" && Rscript -e 'renv::restore(prompt = FALSE)')
    exit
  fi
  # A GC root keeps the cellar alive. It lives in renv/local, a directory
  # that renv's own .gitignore leaves out of the project's repository.
  mkdir -p "$dir/renv/local"
  root="$dir/renv/local/renv-purifier"
  nix_build "$dir" -A cellar -o "$root" >/dev/null
  export RENV_PATHS_CELLAR="$root/cellar"
  renv_tarball=$(jq -r '.packages[] | select(.name == "renv") | .cellarName' "$dir/renv-purifier.lock.json")
  if [ -n "$renv_tarball" ]; then
    # renv/activate.R installs renv itself from this tarball.
    export RENV_BOOTSTRAP_TARBALL="$root/cellar/renv/$renv_tarball"
  fi
  if [ -f "$root/bioconductor/config.yaml" ]; then
    export BIOCONDUCTOR_CONFIG_FILE="$root/bioconductor/config.yaml"
  fi
  # Packages with compiled code need the toolchain and the system libraries
  # the sandboxed build has.
  cd "$dir" || die "cannot enter $dir"
  nix-shell "$RENV_PURIFIER_LIB/cli.nix" \
    --arg nixpkgs "$RENV_PURIFIER_NIXPKGS" \
    --argstr purifier "$RENV_PURIFIER_LIBRARY" \
    --argstr src "$dir" \
    -A shell \
    --run "Rscript -e 'renv::restore(prompt = FALSE)'"
  ;;

build)
  dir=$(project_dir "${1:-}")
  require_lock "$dir"
  nix_build "$dir" -A env -o "$dir/result-env"
  if has_package "$dir"; then
    nix_build "$dir" -A package -o "$dir/result-package"
  fi
  ;;

publish)
  [ $# -ge 1 ] || die "publish needs a repository directory"
  repository="$1"
  dir=$(project_dir "${2:-}")
  require_lock "$dir"
  has_package "$dir" || die "$dir has no DESCRIPTION, so it builds no package to publish"
  tarball=$(jq -r '.outputs.package.tarball' "$dir/renv-purifier.lock.json")
  package=$(nix_build "$dir" -A package --no-out-link)
  mkdir -p "$repository/src/contrib"
  install -m 644 "$package/$tarball" "$repository/src/contrib/$tarball"
  name=$(jq -r '.outputs.package.name' "$dir/renv-purifier.lock.json")
  # write_PACKAGES only warns about a tarball it cannot read, so the index
  # is checked for the package afterwards.
  Rscript --vanilla -e '
    contrib <- commandArgs(TRUE)[1]
    tools::write_PACKAGES(contrib, type = "source")
    index <- read.dcf(file.path(contrib, "PACKAGES"))
    if (!commandArgs(TRUE)[2] %in% index[, "Package"]) quit(status = 1)
  ' "$repository/src/contrib" "$name" || die "could not index $tarball in $repository"
  echo "renv-purifier: added $tarball to $repository"
  ;;

-h | --help | help)
  usage
  ;;

*)
  usage
  exit 1
  ;;
esac
