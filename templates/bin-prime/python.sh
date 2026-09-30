#!/usr/bin/env bash
#
# kit template — prime a Python worktree. Copy to bin/prime in the service repo
# and run it after `git clone`, `git worktree add`, or `git pull --rebase`.
#
#   bin/prime            # sync, lint, then the full suite
#   bin/prime --fast     # sync only
#   bin/prime --no-uv    # force the pip fallback even when uv is installed
#
# WHAT IT PROMISES
#   Exit 0: dependencies resolve, the linter is clean, and every test passes.
#   Anything else: nonzero, with the failing step named. `set -euo pipefail` is
#   the whole mechanism — no error handling to forget.
#
# STRICTNESS NOTES
#   - uv is the resolver of record; pip is the documented fallback so a laptop
#     without uv is not a blocked laptop. Both paths run the same commands, so a
#     green prime means the same thing either way.
#   - `uv sync` (not `uv lock --upgrade`): a prime never moves uv.lock. If the
#     lock is stale, fixing it is a deliberate commit.
#   - We prefer `uv run` over a bare `pytest` so the suite runs in the project
#     environment, not whatever happens to be in the caller's virtualenv.

set -euo pipefail

FAST=0
USE_UV=1
for arg in "$@"; do
  case "$arg" in
    --fast) FAST=1 ;;
    --no-uv) USE_UV=0 ;;
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

if [ "$USE_UV" -eq 0 ] || ! command -v uv >/dev/null 2>&1; then
  USE_UV=0
else
  USE_UV=1
fi

# Run a command inside the project environment when uv owns it, else directly.
py_run() {
  if [ "$USE_UV" -eq 1 ]; then
    uv run "$@"
  else
    "$@"
  fi
}

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

require python3

if [ "$USE_UV" -eq 1 ]; then
  step "uv sync"
  uv sync
else
  echo "bin/prime: uv not found — falling back to 'pip install -e .[dev]'" >&2
  step "pip install -e '.[dev]'"
  pip install -e '.[dev]'
fi

if [ "$FAST" -eq 1 ]; then
  step "skipping lint and tests (--fast)"
  exit 0
fi

if py_run ruff --version >/dev/null 2>&1; then
  step "ruff check"
  py_run ruff check .
else
  echo "bin/prime: ruff is not installed — skipping lint (add it to dev deps)" >&2
fi

step "pytest"
py_run pytest

version="$(version_of python3)"
step "prime ok (python ${version:-unknown})"
