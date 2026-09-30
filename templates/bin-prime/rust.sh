#!/usr/bin/env bash
#
# kit template — prime a Rust worktree. Copy to bin/prime in the service repo
# and run it after `git clone`, `git worktree add`, or `git pull --rebase`.
#
#   bin/prime            # fetch, fmt, clippy, then the full test suite
#   bin/prime --fast     # fetch only
#
# WHAT IT PROMISES
#   Exit 0: the lockfile resolves, the formatter and clippy are clean, and
#   every test passes. Anything else: nonzero, with the failing step named.
#   `set -euo pipefail` is the whole mechanism — no error handling to forget.
#
# STRICTNESS NOTES
#   - No `mise install` here. mise.toml pins the toolchain; this script only
#     primes dependencies and fails loudly (127) if the toolchain is missing.
#   - `cargo fetch`, not `cargo build` as the first step: fetching the whole
#     dependency graph first is what makes a fresh worktree's slow step the
#     network step, and it is resumable.
#   - fmt and clippy run before tests, matching the CI job exactly. They need
#     the rustfmt and clippy components (mise.toml pins them; CI installs them).
#     Without them the prime is not the CI run, so this does not skip on
#     missing components — it fails and names the missing piece.
#   - `cargo test` (not `--locked`): the prime proves the tree compiles and the
#     suite passes in the state you just pulled, which is exactly when a stale
#     lockfile must be visible. Builds that ship use `--locked` (see
#     docker/Dockerfile.rust).

set -euo pipefail

FAST=0
for arg in "$@"; do
  case "$arg" in
    --fast) FAST=1 ;;
    -h | --help)
      sed -n '2,23p' "$0"
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

require cargo

step "cargo fetch"
cargo fetch

if [ "$FAST" -eq 1 ]; then
  step "skipping fmt, clippy, and tests (--fast)"
  exit 0
fi

step "cargo fmt --check"
cargo fmt --check

step "cargo clippy"
cargo clippy --all-targets -- -D warnings

step "cargo test"
cargo test

version="$(version_of cargo)"
step "prime ok (cargo ${version:-unknown})"