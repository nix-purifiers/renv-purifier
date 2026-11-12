# SPDX-License-Identifier: MIT
#
# The mistakes a developer makes with the lockfiles, each of which must
# fail with an error that says what went wrong and which command fixes it:
# the conformance-stale, conformance-tampered, conformance-missing and
# conformance-malformed checks of the purifier contract. Each case copies
# tests/fixtures/hello, breaks it, and evaluates readLock on it with
# nix-instantiate, raising its problems as the purifier library's checkLock
# does, which shows the error text that a `nix build` shows.
# builtins.tryEval cannot test this: it does not catch every error, and it
# hides the message.
{ pkgs }:
let
  inherit (pkgs) lib;

  # Each check's cases: a shell command run in the copy, and a text the
  # error must contain. The case `unchanged` checks that the unbroken
  # fixture evaluates.
  checks = {
    conformance-stale = {
      unchanged = {
        break = "true";
        expect = null;
      };
      renv-lock-changed = {
        break = "sed -i 's/\"Version\": \"1.6.2\"/\"Version\": \"1.7.0\"/' renv.lock";
        expect = "was made for another renv.lock: renv.lock changed after `renv-purifier lock` ran. Run `renv-purifier lock`.";
      };
    };
    conformance-tampered = {
      tampered-hash = {
        break = edit false "lock['packages']['glue']['hash'] = 'sha256-' + 'A' * 43 + '='";
        expect = "was changed after `renv-purifier lock` wrote it. Run `renv-purifier lock` to write it again.";
      };
    };
    conformance-missing = {
      # A lockfile that renv-purifier wrote whole, without a package that
      # renv.lock names, as a lock run that skipped it would write.
      missing-entry = {
        break = edit true "del lock['packages']['glue']";
        expect = "renv.lock names glue, which";
      };
      missing-url = {
        break = edit true "del lock['packages']['xml2']['url']";
        expect = "renv.lock names xml2, which";
      };
      missing-lockfile = {
        break = "rm renv-purifier.lock.json";
        expect = "does not exist. Run `renv-purifier lock`.";
      };
    };
    conformance-malformed = {
      malformed = {
        break = "head -c 200 renv-purifier.lock.json > broken && mv broken renv-purifier.lock.json";
        expect = "rewrite it with `renv-purifier lock`";
      };
      merge-conflict-in-renv-lock = {
        break = "sed -i '0,/\"Packages\": {/s//\"Packages\": {\\n<<<<<<< Updated upstream/' renv.lock";
        expect = "look for merge conflict markers";
      };
      other-format-version = {
        break = edit true "lock['version'] = 0";
        expect = "has lock format version 0";
      };
      wrong-shape = {
        break = edit true "lock['packages']['glue'] = 'glue'";
        expect = "has a package entry without a `hash` string";
      };
    };
  };

  # A Python edit of the parsed lockfile, written back. With `rehash`, the
  # content hash is computed again, as a lock run would write it: the
  # SHA-256 of the compact JSON of every other field with sorted keys,
  # which is what Nix's builtins.toJSON writes.
  edit =
    rehash: statement:
    "${pkgs.python3.interpreter} -c ${lib.escapeShellArg ''
      import hashlib, json
      lock = json.load(open("renv-purifier.lock.json"))
      ${statement}
      if ${if rehash then "True" else "False"}:
          rest = {key: value for key, value in lock.items() if key != "contentHash"}
          text = json.dumps(rest, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
          lock["contentHash"] = hashlib.sha256(text.encode()).hexdigest()
      json.dump(lock, open("renv-purifier.lock.json", "w"), indent=2)
    ''}";

  runCase = name: case: ''
    echo "case ${name}"
    cp -r ${./fixtures/hello} ${name}
    chmod -R u+w ${name}
    (cd ${name} && ${case.break})
    if nix-instantiate --eval --strict --expr \
        "let lock = import ${../lib-overlays/default}/read-lock.nix { lib = import ${pkgs.path}/lib; } { src = $PWD/${name}; }; in if lock.problems != [ ] then throw (builtins.concatStringsSep \"\n\" lock.problems) else builtins.length lock.entries" \
        > ${name}.out 2> ${name}.err; then
      ${
        if case.expect == null then
          "true"
        else
          ''
            echo "case ${name} evaluated, but it should fail with: "${lib.escapeShellArg case.expect} >&2
            exit 1
          ''
      }
    else
      ${
        if case.expect == null then
          ''
            cat ${name}.err >&2
            echo "case ${name} failed, but it should evaluate" >&2
            exit 1
          ''
        else
          ''
            if ! grep -qF -- ${lib.escapeShellArg case.expect} ${name}.err; then
              cat ${name}.err >&2
              echo "case ${name} failed without: "${lib.escapeShellArg case.expect} >&2
              exit 1
            fi
          ''
      }
    fi
  '';
in
lib.mapAttrs (
  check: cases:
  pkgs.runCommand "renv-purifier-test-${check}" { nativeBuildInputs = [ pkgs.nix ]; } ''
    # A Nix of its own, with its state in the build directory.
    export NIX_STATE_DIR=$TMPDIR/nix/state NIX_STORE_DIR=$TMPDIR/nix/store \
      NIX_LOCALSTATE_DIR=$TMPDIR/nix/var NIX_LOG_DIR=$TMPDIR/nix/log \
      NIX_CONF_DIR=$TMPDIR/nix/etc HOME=$TMPDIR
    mkdir -p $NIX_CONF_DIR
    ${lib.concatStrings (lib.mapAttrsToList runCase cases)}
    touch $out
  ''
) checks
