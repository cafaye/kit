#!/usr/bin/env bash
#
# kit template — prime a Go worktree. Copy to bin/prime in the service repo and
# run it after `git clone`, `git worktree add`, or `git pull --rebase`.
#
#   bin/prime            # deps, build, then the full test suite
#   bin/prime --fast     # deps and build only (skips tests)
#
# WHAT IT PROMISES
#   Exit 0: the tree builds and every test passes. Anything else: nonzero, with
#   the failing step named, so a worktree that is not ready never looks ready.
#   `set -euo pipefail` is the whole mechanism — no error handling to forget.
#
# STRICTNESS NOTES
#   - No `mise install` here. The toolchain comes from mise (see mise.toml, the
#     one file that pins versions for both this script and CI). If `go` is not
#     on PATH, this script says so and exits nonzero instead of installing
#     something behind your back.
#   - `go test ./...` runs the whole suite on purpose. A worktree that primes
#     green and fails later in the afternoon is a worktree that lied to you.

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

# Never fails the prime. The toolchain checks below are the gate; a banner must
# not be able to turn a green prime red.
version_of() {
  "$@" --version 2>/dev/null | head -n 1 || true
}

require go
require git

step "go mod download"
go mod download

step "go build ./..."
go build ./...

if [ "$FAST" -eq 1 ]; then
  step "skipping tests (--fast)"
  exit 0
fi

# -count=1 defeats the test cache: a prime must prove the tests run now, not
# that they ran at some point today.
step "go test ./..."
go test -count=1 ./...

step "go vet ./..."
go vet ./...

version="$(version_of go)"
step "prime ok (go ${version:-unknown})"
