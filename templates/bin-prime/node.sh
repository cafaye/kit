#!/usr/bin/env bash
#
# kit template — prime a Node worktree. Copy to bin/prime in the service repo
# and run it after `git clone`, `git worktree add`, or `git pull --rebase`.
#
#   bin/prime            # npm ci, lint, then the full test suite
#   bin/prime --fast     # npm ci only
#
# WHAT IT PROMISES
#   Exit 0: the lockfile installs, the linter is clean, and every test passes.
#   Anything else: nonzero, with the failing step named. `set -euo pipefail` is
#   the whole mechanism — no error handling to forget.
#
# STRICTNESS NOTES
#   - No `mise install` here. mise.toml pins node; this script only primes
#     dependencies and fails loudly (127) if the toolchain is missing.
#   - `npm ci` (never `npm install`): ci installs exactly package-lock.json and
#     fails when the lock and the manifest disagree. `npm install` would quietly
#     rewrite the lock and make two worktrees disagree about one commit.
#   - `npm test` runs the repo's own script, not `npx jest` or `node --test`.
#     The script is what CI runs; a prime that runs something else proves
#     nothing about CI.
#   - Lint runs before tests: a style offense should cost a second, not a suite.

set -euo pipefail

FAST=0
for arg in "$@"; do
  case "$arg" in
    --fast) FAST=1 ;;
    -h | --help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "bin/prime: unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "bin/prime: $1 not found on PATH — run 'mise install' in this worktree" >&2
    exit 127
  fi
}

step() {
  printf '\n== %s\n' "$1"
}

# Never fails the prime. The toolchain check above is the gate; a banner must
# not be able to turn a green prime red.
version_of() {
  "$@" --version 2>/dev/null | head -n 1 || true
}

require node
require npm

step "npm ci"
npm ci

if [ "$FAST" -eq 1 ]; then
  step "skipping lint and tests (--fast)"
  exit 0
fi

# Probed rather than assumed: a repo with no lint script yet is a day-one repo,
# not a broken one. A repo that HAS the script must pass it.
if node -e 'process.exit(require("./package.json").scripts?.lint ? 0 : 1)' \
  >/dev/null 2>&1; then
  step "npm run lint"
  npm run lint
else
  echo "bin/prime: no 'lint' script in package.json — skipping lint" >&2
fi

step "npm test"
npm test

version="$(version_of node)"
step "prime ok (node ${version:-unknown})"