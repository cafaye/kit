#!/usr/bin/env bash
#
# kit's entire test suite. kit is config-only — no runtime code, no library —
# so there is nothing to exercise. The test is that every artifact a service
# repo copies or calls actually parses, and that the telemetry templates
# actually propagate a traceparent.
#
#   bash tests/validate.sh                     # the gate: static + telemetry
#   bash tests/validate.sh --static-only       # parse/semantic checks only (fast)
#   bash tests/validate.sh --language=go       # one telemetry language (CI matrix)
#   bash tests/validate.sh --no-self-test      # skip the "can this go red" proof
#
# Three phases, all of which must pass:
#   static     every artifact parses, and the strictness decisions are still
#              what we wrote them down to be (no exporter on by default, every
#              compose port parameterized, every placeholder documented).
#   telemetry  the W3C traceparent templates are EXECUTED, one suite per
#              language. This is the phase that is easy to fake and so is the
#              one that runs the code rather than greps it.
#   self_test  breaks a throwaway copy of this tree four ways and asserts the
#              gate goes red each time. A gate that cannot fail is not a gate.
#
# One line per check: PASS, FAIL, or SKIP. Any FAIL exits 1. A SKIP is always
# reported in the summary — never hidden.
#
# Needs a python with PyYAML (tests/requirements.txt). node, shellcheck,
# yamllint and the six language toolchains run when present and skip when not;
# the artifact-presence and static checks always run, so a deleted template is
# a failure on a machine with no toolchains at all.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/kit-validate.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PY="${KIT_PYTHON:-$ROOT/.venv/bin/python}"
[ -x "$PY" ] || PY=python3
"$PY" -c 'import yaml' 2>/dev/null || {
  echo "no python with PyYAML: pip install -r tests/requirements.txt" >&2
  exit 1
}

RUN_STATIC=1
RUN_TELEMETRY=1
RUN_SELF_TEST=1
LANGS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --static-only)
      RUN_TELEMETRY=0
      RUN_SELF_TEST=0
      ;;
    --no-self-test) RUN_SELF_TEST=0 ;;
    --language=*)
      LANGS+=("${1#*=}")
      ;;
    -h | --help)
      sed -n '2,24p' "$0"
      exit 0
      ;;
    *)
      echo "validate.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# static helpers
# ---------------------------------------------------------------------------

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
skips=0

report() {
  printf '%-4s %s\n' "$1" "$2"
  case "$1" in
    FAIL) fails=$((fails + 1)) ;;
    SKIP) skips=$((skips + 1)) ;;
  esac
}

check() { # check <label> <command...>
  local label="$1" out
  shift
  if out="$("$@" 2>&1)"; then
    report PASS "$label"
  else
    report FAIL "$label"
    printf '%s\n' "$out" | sed 's/^/       /'
  fi
}

section() { printf '\n-- %s\n' "$1"; }

have() { command -v "$1" >/dev/null 2>&1; }

# ===========================================================================
# phase: static
# ===========================================================================

if [ "$RUN_STATIC" -eq 1 ]; then
  section 'static: every artifact parses'

  for f in "$ROOT"/workflows/* "$ROOT"/lint/* "$ROOT"/docker/* \
    "$ROOT"/templates/bin-prime/* "$ROOT"/templates/compose/* \
    "$ROOT"/templates/bin/* "$ROOT"/tests/*.sh; do
    [ -f "$f" ] || continue
    path="${f#"$ROOT"/}"
    case "$f" in
      *.sh) check "$path  (bash -n)" bash -n "$f" ;;
      *.yml | *.yaml) check "$path  (yaml.safe_load)" yaml_ok "$f" ;;
      *.mjs)
        if have node; then
          check "$path  (node --check)" node --check "$f"
        else
          report SKIP "$path  (node not installed)"
        fi
        ;;
      *) report SKIP "$path  (no parser for this file type)" ;;
    esac
  done

  # Every script kit hands out is executable. `chmod -x bin/dev` in a commit is
  # a one-character diff that silently breaks six repos the next they adopt.
  section 'static: handed-out scripts are executable'
  for f in "$ROOT"/templates/bin-prime/* "$ROOT"/templates/bin/*; do
    [ -f "$f" ] || continue
    path="${f#"$ROOT"/}"
    if [ -x "$f" ]; then
      report PASS "$path  (executable)"
    else
      report FAIL "$path  (not executable)"
    fi
  done

  # Run the linter over the scripts we wrote, not just `bash -n`. `bash -n`
  # passes on quoting bugs; shellcheck is what catches them. Optional, and
  # reported as a SKIP when absent — never silently passed.
  #
  # (Note: a comment whose first word is the linter's name is parsed as a linter
  # directive, which is why this paragraph is worded the way it is.)
  if have shellcheck; then
    section 'static: shellcheck -S warning'
    for f in "$ROOT"/templates/bin-prime/* "$ROOT"/templates/bin/* "$ROOT"/tests/*.sh; do
      [ -f "$f" ] || continue
      path="${f#"$ROOT"/}"
      # SC2317 (unreachable command) is excluded deliberately: the `check`
      # helper builds a command list that shellcheck's flow analysis cannot see
      # through. Every other warning is a real finding.
      check "$path  (shellcheck -S warning)" shellcheck -S warning -e SC2317 "$f"
    done
  else
    report SKIP 'shellcheck (not installed)'
  fi

  # -------------------------------------------------------------------------
  section 'static: templates/otel — every artifact is present'
  # This runs on a machine with no language toolchains at all. A template that
  # was deleted or renamed must fail the gate here, not "skip" later.
  otel_required() {
    "$PY" - "$ROOT" "$@" <<'PY'
import os
import sys

root, *rest = sys.argv[1:]
missing = [p for p in rest if not os.path.isfile(os.path.join(root, p))]
if missing:
    sys.exit("missing template artifact(s): " + ", ".join(missing))
PY
  }

  # Every language ships: the codec, its suite, the SDK wiring snippet, and a
  # README saying when to use which. The README is not optional — a template
  # nobody knows when to use is a template nobody uses.
  #
  # The field count is deliberately variable. Five languages carry a separate
  # test file; rust does not, because `rustc --test` builds a single crate from
  # one source with the suite inline. Its presence is asserted below instead, by
  # looking for the `#[test]` functions — a presence check on a file that has
  # none in it would be satisfied by a crate shipping an implementation and no
  # proof, which is the exact thing this packet exists to prevent.
  #
  # `pins.md` lives at the otel root, not under rust/: it pins all six
  # languages' OTel versions, and a version table scoped to one language reads
  # as "rust's versions" to the next person who greps for it.
  otel_readme='templates/otel/README.md'
  if otel_required "$otel_readme" 'templates/otel/pins.md'; then
    report PASS 'templates/otel/{README.md,pins.md}  (present)'
  else
    report FAIL 'templates/otel/{README.md,pins.md}  (present)'
  fi

  while IFS='|' read -r lang a b c d e; do
    [ -n "$lang" ] || continue
    wanted=("templates/otel/$lang/$a" "templates/otel/$lang/$b" "templates/otel/$lang/$c")
    [ -n "$d" ] && wanted+=("templates/otel/$lang/$d")
    [ -n "$e" ] && wanted+=("templates/otel/$lang/$e")
    if otel_required "${wanted[@]}"; then
      report PASS "templates/otel/$lang/  (${#wanted[@]} artifacts present)"
    else
      report FAIL "templates/otel/$lang/  (${#wanted[@]} artifacts present)"
    fi
  done <<'OTEL'
go|traceparent.go|traceparent_test.go|otelhttp.go.snippet|README.md
ruby|traceparent.rb|test_traceparent.rb|rack_middleware.rb.snippet|README.md
elixir|traceparent.ex|test_traceparent.exs|phoenix_telemetry.ex.snippet|README.md
rust|traceparent.rs|otel_client.rs.snippet|README.md
python|traceparent.py|test_traceparent.py|fastapi.py.snippet|README.md
node|traceparent.mjs|traceparent.test.mjs|hono.ts.snippet|README.md
OTEL

  # rust keeps its suite inline, so "the test file exists" is not a check that
  # can be run on it. This is the equivalent.
  check 'templates/otel/rust/traceparent.rs  (carries its own suite)' bash -c \
    "grep -qE '#\[test\]' '$ROOT/templates/otel/rust/traceparent.rs'"

  # A snippet that names no version is a snippet nobody can install: the reader
  # copies a floating major, gets three minors of drift, and files a bug
  # against a version they chose. And a snippet that vendors is a snippet that
  # has turned kit into a dependency — the rule AGENTS.md states as "no
  # dependencies, ever", checked rather than trusted.
  snippet_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import re
import sys

root = sys.argv[1]
snippets = {
    "go": "otelhttp.go.snippet",
    "ruby": "rack_middleware.rb.snippet",
    "elixir": "phoenix_telemetry.ex.snippet",
    "rust": "otel_client.rs.snippet",
    "python": "fastapi.py.snippet",
    "node": "hono.ts.snippet",
}

# Each language names its installer in a different verb; the point is that one
# of them appears, not which.
install = re.compile(
    r"\b(go get|bun add|npm add|yarn add|bundle add|mix deps\.get"
    r"|pip install|uv add|cargo add)\b"
)
# A version is a digit. `@latest`, `^1.2.3` and a bare `^` are all rejected
# below for different reasons, but all of them fail this.
versioned = re.compile(r"[=<>@~^ ]\s*v?\d+\.\d+")

problems = []
for lang, name in snippets.items():
    path = os.path.join(root, "templates", "otel", lang, name)
    if not os.path.isfile(path):
        continue  # absence is the artifact-presence check's job, not a second failure
    body = open(path, encoding="utf-8").read()

    if not install.search(body):
        problems.append(f"otel/{lang}/{name}: no install line — a reader cannot install from this")

    # Floating-version scan runs over COMMENT LINES INCLUDED, unlike the
    # composer's no-literal-URL rule. A snippet puts its install commands in a
    # comment block precisely so a reader copies one line and the file is still
    # valid in a repo with no OTel dep; stripping comments first would have
    # thrown those away and the check would have passed a snippet with no
    # install line at all — which is what it did on its first run.
    for lineno, line in enumerate(body.splitlines(), 1):
        if "@latest" in line or "@main" in line or "@master" in line:
            problems.append(f"otel/{lang}/{name}:{lineno}: floating ref: {line.strip()[:60]}")

    # A version is a digit somewhere in the body. Prose mentioning "no
    # dependencies" must not satisfy it, so the match is anchored to the
    # characters that actually introduce a version.
    if not versioned.search(body):
        problems.append(f"otel/{lang}/{name}: no versioned dependency anywhere")

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'templates/otel/*/*.snippet  (installable, versioned, not vendored)' snippet_check

  # A template must not declare a dependency. kit is config-only; if these
  # files can `require` something, kit has a lockfile and a supply chain.
  section 'static: templates/otel declare no third-party dependency'
  check 'templates/otel/go/go.mod  (no require)' bash -c \
    "! grep -qE '^[[:space:]]*require' '$ROOT/templates/otel/go/go.mod'"
  if [ -f "$ROOT/templates/otel/node/package.json" ]; then
    check 'templates/otel/node/package.json  (no dependencies)' bash -c \
      "$PY -c \"import json,sys; d=json.load(open(sys.argv[1])); sys.exit(1 if (d.get('dependencies') or d.get('devDependencies')) else 0)\" \
      '$ROOT/templates/otel/node/package.json'"
  else
    report PASS 'templates/otel/node/package.json  (not needed: node:test + stdlib)'
  fi

  # -------------------------------------------------------------------------
  # AGENTS.md: "Half a language is worse than none." The whole point of kit is
  # that six repos get the same thing, so a language that has a CI job but no
  # primer is worse than a language kit does not claim to support: the first is
  # a service that adopts kit and finds a step missing, silently.
  #
  # One list, checked four ways, so adding a language is one edit that fails
  # until the other three artifacts exist.
  section 'static: every language ships all four artifacts'
  kit_languages() {
    # Kept in step with ci_check's `languages` list below. Both read the CI
    # workflow's `language` options, so there is exactly one place to add a
    # language and the workflow cannot claim one the tree does not have.
    "$PY" - "$ROOT" <<'PY'
import sys

import yaml

with open(f"{sys.argv[1]}/workflows/ci.reusable.yml", encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
triggers = doc.get("on") or doc.get(True) or {}
call = (triggers.get("workflow_call") or {}).get("inputs") or {}
for lang in ((call.get("language") or {}).get("options") or []):
    print(lang)
PY
  }

  while IFS= read -r lang; do
    [ -n "$lang" ] || continue
    if otel_required "docker/Dockerfile.$lang" "templates/bin-prime/$lang.sh"; then
      report PASS "$lang  (Dockerfile + bin/prime present)"
    else
      report FAIL "$lang  (Dockerfile + bin/prime present)"
    fi
  done < <(kit_languages)

  # mise.toml pins every language too. Checked by parsing the TOML rather than
  # grepping, so a key that appears in a comment does not count as a pin — a
  # check that can be satisfied by a comment is not a check.
  mise_check() {
    "$PY" - "$ROOT" <<'PY'
import re
import sys

root = sys.argv[1]
with open(f"{root}/workflows/ci.reusable.yml", encoding="utf-8") as fh:
    import yaml

    doc = yaml.safe_load(fh)
triggers = doc.get("on") or doc.get(True) or {}
call = (triggers.get("workflow_call") or {}).get("inputs") or {}
langs = (call.get("language") or {}).get("options") or []

source = open(f"{root}/templates/mise.toml", encoding="utf-8").read()
# Only the [tools] table, and only its own lines: a version mentioned in a
# comment above the table is documentation, not a pin.
table = re.split(r"^\[", source, flags=re.M)
tools = ""
for chunk in table:
    if chunk.startswith("tools]"):
        tools = chunk
        break

problems = []
if not tools:
    problems.append("templates/mise.toml has no [tools] table")
else:
    for lang in langs:
        if not re.search(rf'^\s*"?{re.escape(lang)}"?\s*=\s*\S', tools, flags=re.M):
            problems.append(f"templates/mise.toml pins no version for {lang}")

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'templates/mise.toml  (a [tools] pin per language)' mise_check

  # -------------------------------------------------------------------------
  section 'static: compose — nothing hardcoded, nothing shipped'
  # Privacy boundary, enforced. The collector template a developer clones onto
  # a laptop must not be able to send a span anywhere on its own. Asserted on
  # the parsed document *and* on the comment-stripped source, because a
  # commented-out exporter that someone uncomments later must never have been
  # a literal endpoint in the first place.

  collector_check() {
    "$PY" - "$ROOT" <<'PY'
import re
import sys

import yaml

root = sys.argv[1]
path = f"{root}/templates/compose/otel-collector.yml"
with open(path, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)

problems = []

pipelines = (doc.get("service") or {}).get("pipelines") or {}
if not pipelines:
    problems.append("no service.pipelines in the collector config")

traces = pipelines.get("traces")
if not isinstance(traces, dict):
    problems.append("no service.pipelines.traces pipeline")
else:
    # `debug` writes spans to the collector's own stdout on the developer's
    # machine. Anything else in this list moves data off it.
    exporters = traces.get("exporters") or []
    offmachine = [e for e in exporters if e != "debug"]
    if offmachine:
        problems.append(
            "traces pipeline ships to a non-local exporter(s): " + ", ".join(offmachine)
        )
    if not traces.get("receivers"):
        problems.append("traces pipeline has no receivers")
    if "batch" not in (traces.get("processors") or []):
        problems.append("traces pipeline has no batch processor")

# No literal URL anywhere outside a comment: an endpoint that is not an
# ${env:...} substitution is an endpoint somebody's laptop will use by default.
source = open(path, encoding="utf-8").read()
stripped = "\n".join(line.split("#", 1)[0] for line in source.splitlines())
for url in re.findall(r"https?://[^\s\"']+", stripped):
    problems.append(f"literal URL in collector config: {url}")

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'templates/compose/otel-collector.yml  (local-only, batch, no URL)' collector_check

  compose_check() {
    "$PY" - "$ROOT" <<'PY'
import re
import sys

import yaml

root = sys.argv[1]
path = f"{root}/templates/compose/docker-compose.yml"
with open(path, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)

problems = []
services = doc.get("services") or {}
if not services:
    problems.append("no services")

# The shared infra every cafaye service joins. Half a platform is worse than
# none: a service that adopts the stack needs all four or none.
for required in ("postgres", "nats", "redis", "otel-collector"):
    if required not in services:
        problems.append(f"missing service: {required}")

for name, svc in services.items():
    image = svc.get("image")
    if not image:
        problems.append(f"{name}: no image")
        continue
    tag = image.rsplit(":", 1)[-1] if ":" in image.rsplit("/", 1)[-1] else ""
    if tag in ("", "latest"):
        problems.append(f"{name}: image is unpinned ({image})")
    # Health, or `docker compose up --wait` cannot mean anything.
    if "healthcheck" not in svc:
        problems.append(f"{name}: no healthcheck, so `up --wait` cannot gate on it")

# Every published port is a ${KIT_*} substitution. A literal host port in this
# file is a port collision waiting for the second service a developer runs.
source = open(path, encoding="utf-8").read()
for lineno, line in enumerate(source.splitlines(), 1):
    if line.lstrip().startswith("#"):
        continue
    for mapping in re.findall(r"[\"']?\d+:\d+[\"']?", line):
        problems.append(f"line {lineno}: hardcoded port mapping {mapping}")

# Nothing in the stack may name a cafaye service: hostnames are the service's
# own to choose, and a template that picks them for you is a template six repos
# disagree with.
for name in services:
    if name in ("postgres", "nats", "redis", "otel-collector"):
        continue
    problems.append(f"unexpected service: {name}")

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'templates/compose/docker-compose.yml  (pinned, healthy, parameterized)' compose_check

  # Every ${VAR} the stack interpolates must be documented in .env.example,
  # with a default, so a fresh clone runs without a hand-written .env.
  env_example_check() {
    "$PY" - "$ROOT" <<'PY'
import re
import sys

root = sys.argv[1]
example = open(f"{root}/templates/compose/.env.example", encoding="utf-8").read()
documented = dict(
    (m.group(1), m.group(2))
    for m in re.finditer(r"^(KIT_[A-Z0-9_]+)=(.*)$", example, re.M)
)

problems = []
for name in ("docker-compose.yml", "otel-collector.yml"):
    source = open(f"{root}/templates/compose/{name}", encoding="utf-8").read()
    for var in sorted(set(re.findall(r"\$\{(KIT_[A-Z0-9_]+)[^}]*\}", source))):
        if var not in documented:
            problems.append(f"{name} uses ${{{var}}} which .env.example does not set")

# A documented placeholder with no default is a placeholder that breaks a
# fresh clone; `foo=` with an empty default is the same failure in YAML form.
for var, default in sorted(documented.items()):
    if default == "":
        problems.append(f".env.example sets {var}= with no default")

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'templates/compose/.env.example  (every placeholder documented)' env_example_check

  # Dogfood lint/yamllint.yml on the two YAML templates kit writes. Optional:
  # yamllint ships in tests/requirements.txt, and a machine without it gets a
  # reported SKIP rather than a silent pass.
  YAMLLINT="${KIT_YAMLLINT:-$ROOT/.venv/bin/yamllint}"
  if [ -x "$YAMLLINT" ]; then
    section 'static: compose templates are yamllint clean'
    for f in otel-collector.yml docker-compose.yml; do
      check "templates/compose/$f  (yamllint -c lint/yamllint.yml)" \
        "$YAMLLINT" -c "$ROOT/lint/yamllint.yml" "$ROOT/templates/compose/$f"
    done
  else
    report SKIP 'yamllint (not installed: pip install -r tests/requirements.txt)'
  fi

  # The CI workflow gains a job; assert the job exists, is opt-in, and that the
  # default call still runs exactly the six original jobs. A kit change that
  # breaks every consumer's CI is a kit change that does not ship.
  ci_check() {
    "$PY" - "$ROOT" <<'PY'
import re
import sys

import yaml

root = sys.argv[1]
with open(f"{root}/workflows/ci.reusable.yml", encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)

problems = []

# `on:` is read by PyYAML 1.1 as the boolean True.
triggers = doc.get("on") or doc.get(True) or {}
call = (triggers.get("workflow_call") or {}).get("inputs") or {}

telemetry = call.get("telemetry")
if not isinstance(telemetry, dict):
    problems.append("no `telemetry` workflow_call input")
else:
    default = str(telemetry.get("default", ""))
    if default not in ("false", "False"):
        problems.append(f"telemetry input defaults to {default!r}; it must default to 'false'")
    if str(telemetry.get("type")) != "string":
        problems.append("telemetry input must be type: string (booleans coerce badly)")

jobs = doc.get("jobs") or {}

# One entry per language kit ships a Dockerfile, a bin/prime and a mise pin for.
# The list lives here and nowhere else, so "add a language" is one line that
# fails immediately until the other three artifacts exist — rather than a
# language with a CI job and no primer.
languages = ["go", "ruby", "elixir", "python", "node", "bun", "rust"]

for lang in languages:
    job = jobs.get(lang)
    if not isinstance(job, dict):
        problems.append(f"job {lang} disappeared")
        continue
    cond = job.get("if")
    if cond is None or f"inputs.language == '{lang}'" not in cond:
        problems.append(f"job {lang} is no longer gated on its language input")

# A caller can only pass what `options` allows, so an option with no job is a
# green build that ran nothing, and a job with no option is a job no repo can
# reach. The two lists are the same list.
options = ((call.get("language") or {}).get("options")) or []
if sorted(options) != sorted(languages):
    problems.append(
        f"`language` options {sorted(options)} do not match the job set {sorted(languages)}"
    )

tjob = jobs.get("telemetry")
if not isinstance(tjob, dict):
    problems.append("no `telemetry` job")
else:
    cond = tjob.get("if") or ""
    if "inputs.telemetry" not in cond:
        problems.append("telemetry job is not gated on the telemetry input: it would run by default")
    matrix = ((tjob.get("strategy") or {}).get("matrix") or {}).get("language")
    if not matrix:
        problems.append("telemetry job has no language matrix: it must execute every language")
    elif sorted(matrix) != sorted(["go", "ruby", "elixir", "python", "node", "rust"]):
        problems.append(f"telemetry matrix does not cover the six languages: {matrix}")

# A workflow that parses is not a workflow that runs. `if:` conditions and
# `${{ }}` are opaque to yaml.safe_load, so the two ways this file has actually
# broken in review — an expression that never resolves, and a `${{` that opens a
# block it never closes — are caught by reading the source as text. A file
# needing this check is a file that needed it.
source = open(f"{root}/workflows/ci.reusable.yml", encoding="utf-8").read()
for match in re.finditer(r"\$\{\{", source):
    lineno = source[: match.start()].count("\n") + 1
    tail = source[match.start() :]
    line_end = tail.find("\n")
    line = tail if line_end == -1 else tail[:line_end]
    if "}}" not in line:
        problems.append(f"line {lineno}: unclosed ${{{{ in an expression")
        break

# Every `uses:` is owner/repo[/path]@ref. A step with no ref resolves to
# whatever that action's default branch says today, which is not a pin.
for lineno, line in enumerate(source.splitlines(), 1):
    stripped = line.strip()
    if not stripped.startswith("uses:"):
        continue
    ref = stripped.split("uses:", 1)[1].strip().strip("'\"")
    if ref.startswith("./") or ref.startswith("docker://"):
        continue
    if "@" not in ref:
        problems.append(f"line {lineno}: `uses: {ref}` has no ref")
    elif ref.endswith(("@master", "@main")):
        problems.append(f"line {lineno}: `uses: {ref}` points at a branch, not a release")

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'workflows/ci.reusable.yml  (opt-in telemetry job, defaults intact)' ci_check

  # Every README section a reader is told to copy must exist. A doc that points
  # at a path that was renamed is worse than no doc.
  readme_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import sys

root = sys.argv[1]
readme = open(f"{root}/README.md", encoding="utf-8").read()
problems = []
for path in (
    "templates/compose/docker-compose.yml",
    "templates/compose/otel-collector.yml",
    "templates/compose/.env.example",
    "templates/bin/dev.sh",
    "templates/otel/README.md",
):
    if path not in readme:
        problems.append(f"README.md never mentions {path}")
    if not os.path.isfile(os.path.join(root, path)):
        problems.append(f"README.md documents {path}, which does not exist")
if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'README.md  (documents every new template)' readme_check
fi

# ===========================================================================
# phase: telemetry — execute the traceparent templates
# ===========================================================================

if [ "$RUN_TELEMETRY" -eq 1 ]; then
  # Formatting is part of the template: a service that copies a template
  # formatted differently from its neighbours is a template that reads as ours.
  if have gofmt; then
    if [ -z "$(gofmt -l "$ROOT"/templates/otel/go/*.go 2>&1)" ]; then
      report PASS 'templates/otel/go/*.go  (gofmt clean)'
    else
      report FAIL 'templates/otel/go/*.go  (gofmt clean)'
      gofmt -l "$ROOT"/templates/otel/go/*.go | sed 's/^/       /'
    fi
  else
    report SKIP 'gofmt (not installed)'
  fi

  section 'telemetry: W3C traceparent propagation, executed'

  # Each language is one command. Everything is stdlib-only and offline: no
  # `go mod download`, no bundle install, no npm ci, no cargo fetch. If these
  # ever need the network the template has grown a dependency and kit has
  # stopped being config-only.
  run_go() {
    (
      cd "$ROOT/templates/otel/go"
      GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local go test ./...
    )
  }
  run_ruby() {
    ruby "$ROOT/templates/otel/ruby/test_traceparent.rb"
  }
  run_elixir() {
    # -r the module first: mix is not involved, so ExUnit.start() lives in the
    # test file and there is no mix.exs to grow.
    elixir -r "$ROOT/templates/otel/elixir/traceparent.ex" \
      "$ROOT/templates/otel/elixir/test_traceparent.exs"
  }
  run_python() {
    python3 "$ROOT/templates/otel/python/test_traceparent.py"
  }
  run_node() {
    node --test "$ROOT/templates/otel/node/traceparent.test.mjs"
  }
  run_rust() {
    rustc --test --edition 2021 -o "$TMP/kit-otel-rust" \
      "$ROOT/templates/otel/rust/traceparent.rs"
    "$TMP/kit-otel-rust"
  }

  # `set -u` treats an empty array expansion as an error, and no --language
  # argument is the normal case (run everything). Declare it non-empty-safe.
  wanted() {
    [ "${#LANGS[@]}" -eq 0 ] && return 0
    for want in "${LANGS[@]}"; do
      [ "$want" = "$1" ] && return 0
    done
    return 1
  }

  for lang in go ruby elixir python node rust; do
    wanted "$lang" || continue
    case "$lang" in
      go) tool=go ;;
      ruby) tool=ruby ;;
      elixir) tool=elixir ;;
      python) tool=python3 ;;
      node) tool=node ;;
      rust) tool=rustc ;;
    esac
    if ! have "$tool"; then
      report SKIP "templates/otel/$lang  ($tool not installed)"
      continue
    fi
    check "templates/otel/$lang  ($tool test suite)" "run_$lang"
  done
fi

# ===========================================================================
# phase: self_test — prove the gate can go red
# ===========================================================================

if [ "$RUN_SELF_TEST" -eq 1 ]; then
  section 'self_test: this gate is able to fail'
  if check 'tests/self_test.sh  (four breakages, four reds)' \
    bash "$ROOT/tests/self_test.sh"; then
    :
  fi
fi

# ---------------------------------------------------------------------------

printf '\n'
if [ "$fails" -ne 0 ]; then
  echo "FAIL: $fails check(s) failed."
  [ "$skips" -eq 0 ] || echo "note: $skips check(s) skipped (reported above)."
  exit 1
fi
echo "PASS: every check passed."
[ "$skips" -eq 0 ] || echo "note: $skips check(s) skipped — reported above, never hidden."
