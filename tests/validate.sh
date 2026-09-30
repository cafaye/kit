#!/usr/bin/env bash
#
# kit's entire test suite. kit is config-only, so "tests" here mean:
# every artifact parses, every language is covered end to end, and every
# bin-prime script both succeeds and fails the way it claims to.
#
# Usage:
#   bash tests/validate.sh                     # full suite (includes self-test)
#   bash tests/validate.sh --no-self-test
#   KIT_PYTHON=/path/to/python bash tests/validate.sh
#
# Exit status: 0 = green, 1 = red with every offender listed.
#
# Optional, skipped (never failed) when absent from PATH: shellcheck, yamllint,
# node. Required: a python with PyYAML, per tests/requirements.txt.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LANGUAGES="go ruby elixir python node rust"

CHECKS_RUN=0
CHECKS_SKIPPED=0
FAILURES=()
SKIPS=()

fail() {
  FAILURES+=("$1")
}

detail() {
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    FAILURES+=("    $line")
  done
}

ok() {
  CHECKS_RUN=$((CHECKS_RUN + 1))
}

skip() {
  CHECKS_SKIPPED=$((CHECKS_SKIPPED + 1))
  SKIPS+=("$1")
}

have() {
  command -v "$1" >/dev/null 2>&1
}

rel() {
  printf '%s' "${1#"$ROOT"/}"
}

# ---------------------------------------------------------------- 1. required
# Every deliverable exists and is non-empty. Missing files are offenders.
required_files() {
  local f
  for f in \
    README.md \
    AGENTS.md \
    .gitignore \
    workflows/ci.reusable.yml \
    lint/yamllint.yml \
    lint/golangci.yml \
    lint/rubocop.yml \
    lint/eslint.config.mjs \
    docker/Dockerfile.go \
    docker/Dockerfile.ruby \
    docker/Dockerfile.elixir \
    docker/Dockerfile.python \
    docker/Dockerfile.node \
    docker/Dockerfile.rust \
    templates/mise.toml \
    templates/AGENTS.md \
    tests/validate.sh \
    tests/requirements.txt
  do
    ok
    if [ ! -f "$ROOT/$f" ]; then
      fail "missing file: $f"
    elif [ ! -s "$ROOT/$f" ]; then
      fail "empty file: $f"
    fi
  done

  local lang
  for lang in $LANGUAGES; do
    ok
    if [ ! -f "$ROOT/templates/bin-prime/$lang.sh" ]; then
      fail "missing file: templates/bin-prime/$lang.sh"
    elif [ ! -s "$ROOT/templates/bin-prime/$lang.sh" ]; then
      fail "empty file: templates/bin-prime/$lang.sh"
    fi
  done
}

# ------------------------------------------------------- 2. shell conformance
# Every .sh in the repo parses under bash -n, is strict-mode, and is executable.
shell_conformance() {
  local f
  for f in "$ROOT"/tests/*.sh "$ROOT"/templates/bin-prime/*.sh; do
    [ -f "$f" ] || continue
    ok
    if ! out="$(bash -n "$f" 2>&1)"; then
      fail "bash -n parse error: $(rel "$f")"
      detail "$out"
      continue
    fi

    ok
    if ! grep -q '^#!.*bash' "$f"; then
      fail "no bash shebang: $(rel "$f")"
    fi

    ok
    if ! grep -qE '^set -euo pipefail$' "$f"; then
      fail "missing 'set -euo pipefail': $(rel "$f")"
    fi

    ok
    if [ ! -x "$f" ]; then
      fail "not executable (chmod +x): $(rel "$f")"
    fi
  done
}

# When shellcheck is installed, lint the shell kit ships to other repos.
shellcheck_if_available() {
  if ! have shellcheck; then
    skip "shellcheck not installed"
    return 0
  fi
  local f out
  for f in "$ROOT"/tests/*.sh "$ROOT"/templates/bin-prime/*.sh; do
    [ -f "$f" ] || continue
    ok
    if ! out="$(shellcheck -s bash -S warning "$f" 2>&1)"; then
      fail "shellcheck: $(rel "$f")"
      detail "$out"
    fi
  done
}

# ------------------------------------------------------------- 3. YAML + TOML
# python yaml.safe_load over every YAML in the repo; tomllib over the TOML.
PYTHON_BIN=""

resolve_python() {
  local c
  for c in "${KIT_PYTHON:-}" "$ROOT/.venv/bin/python" python3 python; do
    [ -n "$c" ] || continue
    if "$c" -c 'import yaml' >/dev/null 2>&1; then
      PYTHON_BIN="$c"
      return 0
    fi
  done
  return 1
}

require_python() {
  if resolve_python; then
    return 0
  fi
  ok
  fail "no python with PyYAML: run 'python3 -m venv .venv && .venv/bin/pip install -r tests/requirements.txt', or set KIT_PYTHON"
  return 1
}

yaml_parses() {
  require_python || return 0

  local f out
  for f in "$ROOT"/workflows/*.yml "$ROOT"/workflows/*.yaml \
    "$ROOT"/lint/*.yml "$ROOT"/lint/*.yaml; do
    [ -f "$f" ] || continue
    ok
    if ! out="$("$PYTHON_BIN" - "$f" 2>&1 <<'PY'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
if not isinstance(doc, dict):
    raise SystemExit("top level is not a mapping")
PY
    )"; then
      fail "yaml.safe_load: $(rel "$f")"
      detail "$out"
    fi
  done

  # Also catch any stray YAML a future commit adds somewhere else.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$(rel "$f")" in
      workflows/* | lint/*) continue ;;
    esac
    ok
    if ! out="$("$PYTHON_BIN" - "$f" 2>&1 <<'PY'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as fh:
    yaml.safe_load(fh)
PY
    )"; then
      fail "yaml.safe_load: $(rel "$f")"
      detail "$out"
    fi
  done <<EOF
$(find "$ROOT" -name '*.yml' -o -name '*.yaml' | grep -v '/\.git/' | grep -v '/\.venv/' | sort)
EOF

  # templates/mise.toml is TOML: tomllib (python >= 3.11).
  ok
  if [ ! -f "$ROOT/templates/mise.toml" ]; then
    fail "tomllib parse: templates/mise.toml (file missing)"
  else
    out="$("$PYTHON_BIN" - "$ROOT/templates/mise.toml" 2>&1 <<'PY'
import sys

import tomllib

with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
if not isinstance(doc.get("tools"), dict):
    raise SystemExit("no [tools] table with entries")
PY
    )" || {
      fail "tomllib parse: templates/mise.toml"
      detail "$out"
    }
  fi

  # lint/eslint.config.mjs is javascript, not yaml.
  if [ ! -f "$ROOT/lint/eslint.config.mjs" ]; then
    ok
    fail "node --check: lint/eslint.config.mjs (file missing)"
  elif have node; then
    ok
    if ! out="$(node --check "$ROOT/lint/eslint.config.mjs" 2>&1)"; then
      fail "node --check: lint/eslint.config.mjs"
      detail "$out"
    fi
  else
    skip "node not installed (skipped eslint.config.mjs syntax check)"
  fi
}

# Dogfood: our own YAML must satisfy the config kit hands to service repos.
yamllint_if_available() {
  local yl=""
  if [ -x "$ROOT/.venv/bin/yamllint" ]; then
    yl="$ROOT/.venv/bin/yamllint"
  elif have yamllint; then
    yl="$(command -v yamllint)"
  fi
  if [ -z "$yl" ]; then
    skip "yamllint not installed (tests/requirements.txt)"
    return 0
  fi
  local f out
  for f in "$ROOT"/workflows/*.yml "$ROOT"/lint/*.yml; do
    [ -f "$f" ] || continue
    ok
    if ! out="$("$yl" -c "$ROOT/lint/yamllint.yml" "$f" 2>&1)"; then
      fail "yamllint with lint/yamllint.yml: $(rel "$f")"
      detail "$out"
    fi
  done
}

# ---------------------------------------------- 4. reusable-workflow contract
# Six repos we do not control consume this file, so its contract is asserted:
# workflow_call inputs, one job per language, and each job installs, tests, and
# gates on coverage.
workflow_shape() {
  local wf="$ROOT/workflows/ci.reusable.yml"
  if [ ! -f "$wf" ]; then
    ok
    fail "missing file: workflows/ci.reusable.yml"
    return 0
  fi
  require_python || return 0

  local out
  ok
  if ! out="$("$PYTHON_BIN" - "$wf" 2>&1 <<'PY'
import sys

import yaml

LANGUAGES = ["go", "ruby", "elixir", "python", "node", "rust"]
problems = []

with open(sys.argv[1], encoding="utf-8") as fh:
    wf = yaml.safe_load(fh)

# YAML 1.1 parses the `on:` key as the boolean True; accept either spelling.
triggers = wf.get("on", wf.get(True))
call = triggers.get("workflow_call") if isinstance(triggers, dict) else None
if not isinstance(call, dict):
    problems.append("not a reusable workflow: on.workflow_call is missing")
    inputs = {}
else:
    inputs = call.get("inputs") or {}

for name in ("language", "working-dir"):
    spec = inputs.get(name)
    if not isinstance(spec, dict):
        problems.append(f"input {name!r} is missing")
        continue
    if not spec.get("description"):
        problems.append(f"input {name!r} has no description")
    if "type" not in spec:
        problems.append(f"input {name!r} has no type")

lang = inputs.get("language") or {}
if sorted(lang.get("options") or []) != sorted(LANGUAGES):
    problems.append(
        f"input 'language' options are {lang.get('options')!r}, expected {sorted(LANGUAGES)!r}"
    )
if not lang.get("required", False):
    problems.append("input 'language' is not required: a caller must pick a path")
if not (inputs.get("working-dir") or {}).get("default"):
    problems.append("input 'working-dir' has no default")

jobs = wf.get("jobs")
if not isinstance(jobs, dict) or not jobs:
    problems.append("no jobs")
    jobs = {}

for name in LANGUAGES:
    job = jobs.get(name)
    if not isinstance(job, dict):
        problems.append(f"no job named {name!r} (one job per language path)")
        continue
    if "runs-on" not in job:
        problems.append(f"job {name}: no runs-on")
    guard = str(job.get("if", ""))
    if f"inputs.language == '{name}'" not in guard:
        problems.append(
            f"job {name}: not guarded by inputs.language == '{name}' (if: {guard!r})"
        )
    steps = job.get("steps")
    if not isinstance(steps, list) or not steps:
        problems.append(f"job {name}: no steps")
        continue
    blob = yaml.safe_dump(job)
    if "actions/checkout" not in blob:
        problems.append(f"job {name}: does not check out the caller's repo")
    if "run:" not in blob:
        problems.append(f"job {name}: no run steps")
    if "coverage" not in blob.lower():
        problems.append(f"job {name}: no coverage step or gate")

for name, job in jobs.items():
    if not isinstance(job, dict):
        problems.append(f"job {name}: not a mapping")
    elif "uses" not in job and "runs-on" not in job:
        problems.append(f"job {name}: neither 'uses' nor 'runs-on'")

if problems:
    print("\n".join(problems))
    raise SystemExit(1)
PY
  )"; then
    fail "contract violations in workflows/ci.reusable.yml:"
    detail "$out"
  fi
}

# ------------------------------------------------- 5. six-way language coverage
# Every language is complete: job + Dockerfile + bin-prime + mise tool.
language_coverage() {
  local mise lang
  mise="$(sed -n '/^\[tools\]/,$p' "$ROOT/templates/mise.toml" 2>/dev/null || true)"
  [ -n "$mise" ] || fail "templates/mise.toml: no [tools] table"

  for lang in $LANGUAGES; do
    ok
    if [ -f "$ROOT/docker/Dockerfile.$lang" ] \
      && ! grep -qE "^ARG .*VERSION=" "$ROOT/docker/Dockerfile.$lang"; then
      fail "docker/Dockerfile.$lang: no 'ARG ..._VERSION=' build arg to override"
    fi

    ok
    if [ -n "$mise" ] && ! printf '%s\n' "$mise" | grep -qiE "^[[:space:]]*(#.*)?\"?$lang\"?[[:space:]]*="; then
      fail "templates/mise.toml: no $lang entry under [tools]"
    fi
  done
}

# ------------------------------------------- 6. Dockerfile structural contract
# Base images and the non-root decision are org-wide, so they are asserted
# rather than trusted: multi-stage, pinned arg, non-root, explicit base.
dockerfile_shape() {
  local lang f stages final
  for lang in $LANGUAGES; do
    f="$ROOT/docker/Dockerfile.$lang"
    [ -f "$f" ] || continue
    stages="$(grep -cE '^[[:space:]]*FROM[[:space:]]' "$f" || true)"
    final="$(grep -E '^[[:space:]]*FROM[[:space:]]' "$f" | tail -n 1)"

    ok
    if [ "$stages" -lt 2 ]; then
      fail "docker/Dockerfile.$lang: not multi-stage ($stages FROM)"
    fi

    ok
    if grep -qE ':latest([[:space:]]|$)' "$f"; then
      fail "docker/Dockerfile.$lang: uses a :latest base image"
    fi

    ok
    if ! grep -qE '^[[:space:]]*USER[[:space:]]' "$f"; then
      fail "docker/Dockerfile.$lang: no USER directive (must not run as root)"
    fi

    ok
    if ! grep -qE '^[[:space:]]*(ENTRYPOINT|CMD)[[:space:]]' "$f"; then
      fail "docker/Dockerfile.$lang: no ENTRYPOINT or CMD"
    fi

    ok
    case "$lang" in
      go | rust)
        if ! printf '%s' "$final" | grep -q 'distroless'; then
          fail "docker/Dockerfile.$lang: final stage must be distroless, got: $final"
        fi
        ;;
      *)
        if ! printf '%s' "$final" | grep -q -- '-slim'; then
          fail "docker/Dockerfile.$lang: final stage must be a *-slim image, got: $final"
        fi
        ;;
    esac
  done
}

# ------------------------------- 7. bin-prime behaviour, with stub toolchains
# The contract is "nonzero exit on failure". A stub toolchain proves it without
# needing the six real languages installed: happy path exits 0, failure path
# exits nonzero, for every language.
prime_script_behaviour() {
  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT

  local stubdir="$tmp/bin"
  mkdir -p "$stubdir"
  {
    printf '#!/bin/sh\n'
    printf 'printf "%%s %%s\\n" "$(basename "$0")" "$*" >>"$STUB_LOG"\n'
    printf 'if [ -n "${STUB_FAIL:-}" ] && [ "$(basename "$0")" = "$STUB_FAIL" ]; then\n'
    printf '  echo "stub: $(basename "$0") failing on purpose" >&2\n'
    printf '  exit 1\n'
    printf 'fi\nexit 0\n'
  } >"$stubdir/_stub"
  chmod +x "$stubdir/_stub"

  # lang | tool to break | command that must appear in the happy-path log
  local spec
  for spec in \
    "go|go|mod download" \
    "ruby|bundle|bundle install" \
    "elixir|mix|mix deps.get" \
    "python|uv|uv sync" \
    "node|npm|npm ci" \
    "rust|cargo|cargo fetch"
  do
    local lang tool expect rest script log t
    lang="${spec%%|*}"
    rest="${spec#*|}"
    tool="${rest%%|*}"
    expect="${rest#*|}"
    script="$ROOT/templates/bin-prime/$lang.sh"
    [ -f "$script" ] || continue

    case "$lang" in
      go) local tools="go" ;;
      ruby) local tools="bundle" ;;
      elixir) local tools="mix" ;;
      python) local tools="uv pip pytest" ;;
      node) local tools="npm" ;;
      rust) local tools="cargo" ;;
    esac
    for t in $tools; do
      cp "$stubdir/_stub" "$stubdir/$t"
    done

    log="$tmp/$lang.log"

    # 1. happy path.
    : >"$log"
    ok
    if ! STUB_LOG="$log" STUB_FAIL="" PATH="$stubdir:$PATH" \
      bash "$script" >/dev/null 2>&1; then
      fail "bin-prime/$lang.sh: expected exit 0 when the toolchain succeeds"
    else
      ok
      if ! grep -q -- "$expect" "$log"; then
        fail "bin-prime/$lang.sh: did not run '$expect' (saw: $(tr '\n' ';' <"$log"))"
      fi
    fi

    # 2. failure path: the toolchain fails, the script must not.
    ok
    if STUB_LOG="$log" STUB_FAIL="$tool" PATH="$stubdir:$PATH" \
      bash "$script" >/dev/null 2>&1; then
      fail "bin-prime/$lang.sh: exited 0 even though $tool failed"
    fi

    # 3. python also has a documented no-uv fallback; it must behave the same.
    if [ "$lang" = "python" ]; then
      ok
      if ! STUB_LOG="$log" STUB_FAIL="" PATH="$stubdir:$PATH" \
        bash "$script" >/dev/null 2>&1; then
        fail "bin-prime/python.sh: expected exit 0 on the no-uv fallback path"
      else
        ok
        if ! grep -q -- 'pip install' "$log"; then
          fail "bin-prime/python.sh: no-uv fallback did not run 'pip install'"
        fi
      fi

      ok
      if STUB_LOG="$log" STUB_FAIL="pip" PATH="$stubdir:$PATH" \
        bash "$script" >/dev/null 2>&1; then
        fail "bin-prime/python.sh: exited 0 even though the pip fallback failed"
      fi
    fi
  done
}

# ------------------------------------------------- 8. lint configs + templates
# Service repos copy these verbatim, so they must be small, commented, loadable.
lint_config_shape() {
  local rel_ lines
  for rel_ in yamllint.yml golangci.yml rubocop.yml eslint.config.mjs; do
    [ -f "$ROOT/lint/$rel_" ] || continue
    lines="$(wc -l <"$ROOT/lint/$rel_" | tr -d ' ')"

    ok
    if [ "$lines" -lt 8 ]; then
      fail "lint/$rel_: too thin ($lines lines) — needs real strictness notes"
    fi

    ok
    if [ "$lines" -gt 80 ]; then
      fail "lint/$rel_: too long ($lines lines) — kit stays boring, split it out"
    fi

    ok
    if ! grep -qE '(^|[[:space:]])(#|//)' "$ROOT/lint/$rel_"; then
      fail "lint/$rel_: no comments explaining the strictness choices"
    fi
  done

  # The eslint flat config must actually default-export an array.
  if [ -f "$ROOT/lint/eslint.config.mjs" ] && have node; then
    ok
    if ! out="$(node --input-type=module -e \
      "import cfg from '$ROOT/lint/eslint.config.mjs'; if (!Array.isArray(cfg)) { throw new Error('default export is not an array') }" 2>&1)"; then
      fail "lint/eslint.config.mjs: does not default-export an array of configs"
      detail "$out"
    fi
  fi
}

doc_shape() {
  ok
  if [ -f "$ROOT/README.md" ] && ! grep -qE '^## ' "$ROOT/README.md"; then
    fail "README.md: no '## ' sections"
  fi

  ok
  if [ -f "$ROOT/README.md" ] && ! grep -qiE '^## .*(adopt|checklist)' "$ROOT/README.md"; then
    fail "README.md: no adoption section or checklist"
  fi

  ok
  if [ -f "$ROOT/README.md" ]; then
    local lang
    for lang in $LANGUAGES; do
      if ! grep -q "$lang" "$ROOT/README.md"; then
        fail "README.md: never mentions $lang"
      fi
    done
  fi

  ok
  if [ -f "$ROOT/templates/AGENTS.md" ] && ! grep -qE '^## ' "$ROOT/templates/AGENTS.md"; then
    fail "templates/AGENTS.md: no '## ' sections"
  fi
}

# ------------------------------------------------------------- 9. the self-test
# A validator that cannot fail is worthless. Break a throwaway copy of the tree
# three ways (bad YAML, bad shell, missing file) and assert the exit status is
# nonzero and each offender is named.
self_test() {
  if [ "${KIT_SKIP_SELF_TEST:-0}" = "1" ]; then
    skip "self-test skipped (KIT_SKIP_SELF_TEST=1)"
    return 0
  fi

  local tmp copy entry out status=0 needle
  tmp="$(mktemp -d)"
  copy="$tmp/repo"
  mkdir -p "$copy"

  for entry in README.md AGENTS.md .gitignore workflows lint docker templates tests; do
    [ -e "$ROOT/$entry" ] && cp -R "$ROOT/$entry" "$copy/"
  done
  mkdir -p "$copy/lint" "$copy/templates/bin-prime" "$copy/docker"
  # .venv is a local test aid, not part of the tree; the interpreter is handed to
  # the child run through KIT_PYTHON so it can still parse YAML.
  ok

  printf -- '---\na: [1,\n  b: :\n' >"$copy/lint/yamllint.yml"
  printf '#!/usr/bin/env bash\nset -euo pipefail\nif [ ; then\n' >"$copy/templates/bin-prime/go.sh"
  rm -f "$copy/docker/Dockerfile.rust"

  out="$(KIT_SKIP_SELF_TEST=1 KIT_PYTHON="$PYTHON_BIN" bash "$copy/tests/validate.sh" 2>&1)" || status=$?

  ok
  if [ "$status" -eq 0 ]; then
    fail "self-test: validate.sh exited 0 on a deliberately broken tree"
  fi

  for needle in "lint/yamllint.yml" "templates/bin-prime/go.sh" "docker/Dockerfile.rust"; do
    ok
    if ! printf '%s\n' "$out" | grep -q -- "$needle"; then
      fail "self-test: broken $needle was not named in the failure output"
    fi
  done

  ok
  if ! printf '%s\n' "$out" | grep -qE 'checks,.*failures'; then
    fail "self-test: broken run printed no failure summary"
  fi

  rm -rf "$tmp"
  trap - EXIT
}

# ------------------------------------------------------------------- 10. main
main() {
  if [ "${1:-}" = "--no-self-test" ]; then
    KIT_SKIP_SELF_TEST=1
    export KIT_SKIP_SELF_TEST
  fi

  resolve_python || true
  if [ -n "$PYTHON_BIN" ]; then
    export KIT_PYTHON="$PYTHON_BIN"
  fi

  required_files
  shell_conformance
  shellcheck_if_available
  yaml_parses
  yamllint_if_available
  workflow_shape
  language_coverage
  dockerfile_shape
  prime_script_behaviour
  lint_config_shape
  doc_shape
  self_test

  echo
  echo "kit validation: $CHECKS_RUN checks, ${#FAILURES[@]} failures, $CHECKS_SKIPPED skipped"
  if [ "$CHECKS_SKIPPED" -gt 0 ]; then
    local s
    for s in "${SKIPS[@]}"; do
      echo "  skip: $s"
    done
  fi

  if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo
    echo "FAIL: ${#FAILURES[@]} offender(s):"
    local f
    for f in "${FAILURES[@]}"; do
      echo "  - $f"
    done
    exit 1
  fi

  echo "PASS: kit is green."
}

main "$@"
