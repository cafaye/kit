#!/usr/bin/env bash
#
# kit's proof that `tests/validate.sh` is able to fail.
#
#   bash tests/self_test.sh
#
# WHAT THIS IS FOR
#   A gate that only ever goes green is a report, not a gate. This script copies
#   the tree to a throwaway directory, breaks it four ways — once per kind of
#   check — and asserts the gate goes RED each time. Each breakage must be
#   caught by a *different* check, so a passing self_test means the checks are
#   independent and not one lucky assertion standing in for all of them.
#
# THE FOUR BREAKAGES
#   1. delete a language template   -> the artifact-presence check goes red
#   2. ship a collector exporter   -> the privacy check goes red
#   3. corrupt the python codec    -> the executed test suite goes red
#   4. hardcode a compose port     -> the parameterization check goes red
#   5. flip the CI input default   -> the "consumers stay green" check goes red
#
# WHAT IT IS NOT
#   It is not mutation testing of the six language implementations; a full
#   mutation run is a tool kit does not have and would not trust. It proves the
#   gate can fail and that its checks are not interchangeable.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PY="${KIT_PYTHON:-$ROOT/.venv/bin/python}"
[ -x "$PY" ] || PY=python3

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kit-self-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

failures=0
copy_name=""

# A fresh throwaway copy per breakage: one breakage must never mask the next,
# and no breakage may touch the worktree this script was invoked from.
fresh_copy() {
  copy_name="$1"
  local dst="$WORK/$copy_name"
  mkdir -p "$dst"
  for entry in AGENTS.md README.md CHANGELOG.md docker lint templates tests workflows; do
    [ -e "$ROOT/$entry" ] && cp -R "$ROOT/$entry" "$dst/"
  done
  chmod +x "$dst"/tests/validate.sh "$dst"/tests/self_test.sh 2>/dev/null || true
  printf '%s' "$dst"
}

# edit <file> <old> <new> — a textual breakage that FAILS LOUDLY if the source
# has been refactored past it. A self_test that silently stops breaking
# anything is worse than no self_test, so an unmatched edit is an error here.
edit() {
  "$PY" - "$1" "$2" "$3" <<'PY'
import sys

path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
body = open(path, encoding="utf-8").read()
if old not in body:
    sys.exit(f"self_test: breakage no longer applies to {path}: {old!r} not found")
open(path, "w", encoding="utf-8").write(body.replace(old, new, 1))
PY
}

# expect_red <label> <dir> <validate.sh args...>
expect_red() {
  local label="$1" dir="$2"
  shift 2
  if (cd "$dir" && KIT_PYTHON="$PY" bash tests/validate.sh "$@" >/dev/null 2>&1); then
    printf 'FAIL self_test: %s — the gate stayed GREEN\n' "$label"
    failures=$((failures + 1))
  else
    printf 'PASS self_test: %s — the gate went red\n' "$label"
  fi
}

expect_green() {
  local label="$1" dir="$2"
  shift 2
  if (cd "$dir" && KIT_PYTHON="$PY" bash tests/validate.sh "$@" >/dev/null 2>&1); then
    printf 'PASS self_test: %s — the gate is green on an unbroken tree\n' "$label"
  else
    printf 'FAIL self_test: %s — the gate is RED on an unbroken tree\n' "$label"
    (cd "$dir" && KIT_PYTHON="$PY" bash tests/validate.sh "$@" 2>&1 | tail -20 | sed 's/^/       /')
    failures=$((failures + 1))
  fi
}

printf -- '-- self_test: a gate that cannot fail is not a gate\n'

# The control. If the unbroken tree is already red, the four breakages below
# prove nothing, so this runs first and the run is meaningless without it.
base="$(fresh_copy base)"
expect_green 'unbroken tree' "$base" --static-only

# 1. a deleted language template. Caught by the artifact-presence check, which
#    runs with no toolchains at all — so "nobody had Go installed" can never be
#    the reason a missing template passes.
one="$(fresh_copy missing-template)"
rm -f "$one/templates/otel/go/traceparent.go"
expect_red 'breakage 1: templates/otel/go/traceparent.go deleted' "$one" --static-only

# 2. the privacy boundary. The one check that must never be satisfiable by
#    anything a developer is likely to paste.
two="$(fresh_copy exporting-collector)"
edit "$two/templates/compose/otel-collector.yml" \
  'exporters: [debug]' \
  'exporters: [debug, otlp]'
expect_red 'breakage 2: collector traces pipeline exports over the network' "$two" --static-only

# 3. a template that compiles, parses, and silently drops the sampled flag.
#    Only an executed suite catches this; no grep would.
three="$(fresh_copy broken-codec)"
edit "$three/templates/otel/python/traceparent.py" \
  'flags & SAMPLED' '0 & SAMPLED'
expect_red 'breakage 3: python codec stops preserving trace-flags' "$three" \
  --language=python --no-self-test

# 4. a hardcoded host port. The kind of edit nobody notices in review and every
#    second service on a laptop hits.
four="$(fresh_copy hardcoded-port)"
edit "$four/templates/compose/docker-compose.yml" \
  '"${KIT_POSTGRES_PORT:-5432}:5432"' '"5432:5432"'
expect_red 'breakage 4: docker-compose.yml hardcodes a published port' "$four" --static-only

# 5. a kit change that would break every consumer's CI. The opt-in job must stay
#    opt-in and the six original jobs must stay gated on their language.
five="$(fresh_copy ci-not-opt-in)"
edit "$five/workflows/ci.reusable.yml" "default: 'false'" "default: 'true'"
expect_red "breakage 5: the telemetry CI job is no longer opt-in" "$five" --static-only

printf '\n'
if [ "$failures" -ne 0 ]; then
  echo "FAIL: self_test — $failures breakage(s) the gate did not catch."
  exit 1
fi
echo "PASS: self_test — all 5 breakages went red, and the unbroken tree is green."
