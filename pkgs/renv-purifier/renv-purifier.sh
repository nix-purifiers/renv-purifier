# SPDX-License-Identifier: MIT
#
# renv-purifier: locks the downloads of an renv project, and installs and
# publishes it from them with Nix. See README.md.

usage() {
  cat <<'EOF'
Usage: renv-purifier <command> [--project <dir>] [--lockfile <path>]
                     [--tool-lockfile <path>] [arguments]

  lock                  Write renv-purifier.lock.json for renv.lock as it is.
  update [<package>...] Update the packages with renv::update(), every package
                        when none is named, snapshot renv.lock, and relock.
  prefetch              Build the locked library with Nix, keep it with a
                        garbage-collector root, and install it as the project
                        library, so that R, renv and the editor work offline.
                        --inputs <path> installs from the `interactive`
                        output of buildRenvProject in place of building it.
  publish <repository>  Add the package Nix built to the CRAN-like repository
                        directory <repository>.

--project is the directory that holds renv.lock, the current directory by
default. --lockfile names a purifier lockfile kept outside the project; the
environment variable RENV_PURIFIER_LOCKFILE does the same. --tool-lockfile,
or RENV_PURIFIER_TOOL_LOCKFILE, names a renv.lock kept outside the project:
lock and update write it there, starting from the project's renv.lock when
it does not exist yet, and leave the project's renv.lock as it is.
EOF
}

die() {
  echo "renv-purifier: $*" >&2
  exit 1
}

command="${1:-}"
[ -n "$command" ] || {
  usage
  exit 1
}
shift

project="."
lockfile="${RENV_PURIFIER_LOCKFILE:-}"
renvlock="${RENV_PURIFIER_TOOL_LOCKFILE:-}"
inputs=""
arguments=()
while [ $# -gt 0 ]; do
  case "$1" in
  --project)
    [ $# -ge 2 ] || die "--project needs a directory"
    project="$2"
    shift 2
    ;;
  --lockfile)
    [ $# -ge 2 ] || die "--lockfile needs a path"
    lockfile="$2"
    shift 2
    ;;
  --tool-lockfile)
    [ $# -ge 2 ] || die "--tool-lockfile needs a path"
    renvlock="$2"
    shift 2
    ;;
  --inputs)
    [ $# -ge 2 ] || die "--inputs needs a path"
    inputs="$2"
    shift 2
    ;;
  -h | --help)
    usage
    exit
    ;;
  *)
    arguments+=("$1")
    shift
    ;;
  esac
done

[ -d "$project" ] || die "$project is not a directory"
dir=$(realpath "$project")
if [ -n "$lockfile" ]; then
  lockfile=$(realpath -m "$lockfile")
else
  lockfile="$dir/renv-purifier.lock.json"
fi
if [ -n "$renvlock" ]; then
  renvlock=$(realpath -m "$renvlock")
else
  renvlock="$dir/renv.lock"
fi
# The garbage-collector root of `prefetch`, beside the purifier lockfile.
gcroots="$(dirname "$lockfile")/.renv-purifier"

require_renv_lock() {
  [ -f "$renvlock" ] || die "$renvlock does not exist; run renv::init() or renv::snapshot() in the project, then renv-purifier lock"
  jq empty "$renvlock" 2>/dev/null ||
    die "$renvlock is not valid JSON (look for merge conflict markers); fix it, or run renv::snapshot() again"
}

# A renv.lock kept outside the project starts as a copy of the renv.lock in
# the project.
seed_renv_lock() {
  if [ "$renvlock" != "$dir/renv.lock" ] && [ ! -e "$renvlock" ] && [ -f "$dir/renv.lock" ]; then
    mkdir -p "$(dirname "$renvlock")"
    cp "$dir/renv.lock" "$renvlock"
  fi
}

nix_args=()
nix_setup() {
  nix_args=(
    "$RENV_PURIFIER_LIB/cli.nix"
    --arg nixpkgs "$RENV_PURIFIER_NIXPKGS"
    --argstr purifier "$RENV_PURIFIER_LIBRARY"
    --argstr src "$dir"
    --argstr lockFile "$lockfile"
    --argstr renvLock "$renvlock"
  )
}

# Stops with the problems of the lockfiles, each naming its fix, as the Nix
# library reports them.
require_lock() {
  [ -f "$lockfile" ] || die "$lockfile does not exist; run renv-purifier lock"
  jq empty "$lockfile" 2>/dev/null ||
    die "$lockfile is not valid JSON; run renv-purifier lock to write it again"
  nix_setup
  local problems
  problems=$(nix-instantiate --eval --strict --json "${nix_args[@]}" -A problems) ||
    die "could not read the lockfiles"
  if [ "$problems" != "[]" ]; then
    jq -r '.[]' <<<"$problems" >&2
    exit 1
  fi
}

lock() {
  seed_renv_lock
  require_renv_lock
  mkdir -p "$(dirname "$lockfile")"
  # --vanilla keeps R from reading the .Rprofile of the working directory,
  # which in an renv project activates renv and runs project code.
  Rscript --vanilla "$RENV_PURIFIER_SCRIPTS/lock.R" "$dir" "$renvlock" "$lockfile" "$RENV_PURIFIER_FORMAT"
}

prefetch() {
  require_renv_lock
  if [ -z "$inputs" ]; then
    require_lock
    mkdir -p "$gcroots"
    # The directory belongs to renv-purifier, and leaves itself out of the
    # project's repository.
    echo '*' >"$gcroots/.gitignore"
    inputs="$gcroots/prefetch"
    nix-build "${nix_args[@]}" -A interactive -o "$inputs" >/dev/null ||
      die "Nix could not build the locked library"
  fi
  # renv's project library for the R the library was built with, where
  # renv/activate.R looks for packages.
  # shellcheck disable=SC2016 # R code, expanded by R
  target=$(cd "$dir" && "$inputs/R/bin/Rscript" --vanilla -e '
    .libPaths(c(commandArgs(TRUE)[1], .libPaths()))
    cat(renv::paths$library(project = getwd()))
  ' "$inputs/renv")
  mkdir -p "$target"
  for package in "$inputs/library/"*; do
    name=$(basename "$package")
    rm -rf "${target:?}/$name"
    cp -r --no-preserve=mode,ownership "$package" "$target/$name"
  done
  # shellcheck disable=SC2016 # R code, expanded by R
  version=$("$inputs/R/bin/Rscript" --vanilla -e 'cat(paste(R.version$major, R.version$minor, sep = "."))')
  echo "renv-purifier: installed the locked packages in $target, for R $version"
  echo "renv-purifier: start R $version in the project, such as $inputs/R/bin/R; it needs no network"
}

case "$command" in
lock)
  [ ${#arguments[@]} -eq 0 ] || die "lock takes no arguments"
  lock
  ;;

update)
  seed_renv_lock
  prefetch
  nix_setup
  # renv::update() installs the newer versions into the project library
  # from the repositories renv.lock names, compiling them with the
  # toolchain and system libraries of the locked build, and
  # renv::snapshot() records them in renv.lock, the one kept outside the
  # project when there is one.
  (
    cd "$dir" || die "cannot enter $dir"
    # shellcheck disable=SC2016 # R code, expanded by R
    nix-shell "${nix_args[@]}" -A shell --run "$(printf '%q ' Rscript -e '
      renvLock <- commandArgs(TRUE)[1]
      # renv::lockfile_read() gives the repositories as URLs by name.
      options(repos = unlist(renv::lockfile_read(renvLock)$R$Repositories))
      packages <- commandArgs(TRUE)[-1]
      renv::update(packages = if (length(packages)) packages else NULL, prompt = FALSE)
      renv::snapshot(lockfile = renvLock, prompt = FALSE)
    ' "$renvlock" "${arguments[@]}")"
  ) || die "renv::update() failed"
  lock
  ;;

prefetch)
  [ ${#arguments[@]} -eq 0 ] || die "prefetch takes no arguments"
  prefetch
  ;;

publish)
  [ ${#arguments[@]} -eq 1 ] || die "publish needs one repository directory"
  repository="${arguments[0]}"
  require_renv_lock
  require_lock
  release=$(nix-build "${nix_args[@]}" -A release --no-out-link) || die "Nix could not build the release"
  mkdir -p "$repository/src/contrib"
  for tarball in "$release"/*.tar.gz; do
    install -m 644 "$tarball" "$repository/src/contrib/"
    name=$(basename "$tarball" | sed 's/_.*//')
    # write_PACKAGES only warns about a tarball it cannot read, so the index
    # is checked for the package afterwards.
    Rscript --vanilla -e '
      contrib <- commandArgs(TRUE)[1]
      tools::write_PACKAGES(contrib, type = "source")
      index <- read.dcf(file.path(contrib, "PACKAGES"))
      if (!commandArgs(TRUE)[2] %in% index[, "Package"]) quit(status = 1)
    ' "$repository/src/contrib" "$name" || die "could not index $(basename "$tarball") in $repository"
    echo "renv-purifier: added $(basename "$tarball") to $repository"
  done
  ;;

help)
  usage
  ;;

*)
  usage
  exit 1
  ;;
esac
