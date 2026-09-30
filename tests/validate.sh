#!/usr/bin/env bash
#
# kit's entire test suite. kit is config-only — no runtime code, no library —
# so there is nothing to exercise. The test is that every artifact a service
# repo copies or calls actually parses.
#
#   bash tests/validate.sh
#
# One line per file: PASS, FAIL, or SKIP. Any FAIL exits 1.
# Needs a python with PyYAML (tests/requirements.txt). node is used when
# present and skipped when not.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PY="${KIT_PYTHON:-$ROOT/.venv/bin/python}"
[ -x "$PY" ] || PY=python3
"$PY" -c 'import yaml' 2>/dev/null || {
  echo "no python with PyYAML: pip install -r tests/requirements.txt" >&2
  exit 1
}

# A parse error is one line, not a traceback: the gate is read by humans.
yaml_ok() {
  "$PY" - "$1" <<'PY'
import sys

import yaml

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        yaml.safe_load(fh)
except Exception as exc:
    sys.exit(f"yaml: {exc}")
PY
}

fails=0

report() {
  printf '%-4s %s\n' "$1" "$2"
  if [ "$1" = FAIL ]; then fails=$((fails + 1)); fi
}

check() { # check <path> <label> <command...>
  local path="$1" label="$2" out
  shift 2
  if out="$("$@" 2>&1)"; then
    report PASS "$path  ($label)"
  else
    report FAIL "$path  ($label)"
    printf '%s\n' "$out" | sed 's/^/       /'
  fi
}

for f in "$ROOT"/workflows/* "$ROOT"/lint/* "$ROOT"/docker/* "$ROOT"/templates/bin-prime/*; do
  [ -f "$f" ] || continue
  path="${f#"$ROOT"/}"
  case "$f" in
    *.sh) check "$path" 'bash -n' bash -n "$f" ;;
    *.yml | *.yaml) check "$path" 'yaml.safe_load' yaml_ok "$f" ;;
    *.mjs)
      if command -v node >/dev/null 2>&1; then
        check "$path" 'node --check' node --check "$f"
      else
        report SKIP "$path  (node not installed)"
      fi
      ;;
    *) report SKIP "$path  (no parser for this file type)" ;;
  esac
done

echo
if [ "$fails" -eq 0 ]; then
  echo "PASS: every artifact parses."
else
  echo "FAIL: $fails file(s) do not parse."
  exit 1
fi
