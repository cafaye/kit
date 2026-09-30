#!/usr/bin/env bash
#
# kit template — prime an Elixir worktree. Copy to bin/prime in the service repo
# and run it after `git clone`, `git worktree add`, or `git pull --rebase`.
#
#   bin/prime            # deps, compile, format check, then the full suite
#   bin/prime --fast     # deps and compile only
#
# WHAT IT PROMISES
#   Exit 0: dependencies resolve, the project compiles, the formatter is clean,
#   and every test passes. Anything else: nonzero, with the failing step named.
#   `set -euo pipefail` is the whole mechanism.
#
# STRICTNESS NOTES
#   - No `mise install` here. mise.toml pins elixir and erlang; this script only
#     primes dependencies and fails loudly (127) if the BEAM is missing.
#   - `mix deps.get` never updates mix.lock: a prime that moves the lockfile is a
#     prime that can make two worktrees disagree about the same commit.
#   - `mix format --check-formatted` runs before the tests. A tree that needs
#     `mix format` is not a tree whose test result means anything yet.

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

# Never fails the prime. The toolchain check below is the gate; a banner must
# not be able to turn a green prime red.
version_of() {
  "$@" --version 2>/dev/null | head -n 1 || true
}

require mix

step "mix deps.get"
mix deps.get

step "mix compile"
mix compile

if [ "$FAST" -eq 1 ]; then
  step "skipping format check and tests (--fast)"
  exit 0
fi

if [ -f .formatter.exs ]; then
  step "mix format --check-formatted"
  mix format --check-formatted
else
  echo "bin/prime: no .formatter.exs — skipping the format check" >&2
fi

step "mix test"
mix test

version="$(version_of mix)"
step "prime ok (elixir ${version:-unknown})"
