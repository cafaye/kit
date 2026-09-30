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
#   self_test  breaks a throwaway copy of this tree once per kind of check and asserts the
#              gate goes red each time. A gate that cannot fail is not a gate.
#
# One line per check: PASS, FAIL, or SKIP. Any FAIL exits 1. A SKIP is always
# reported in the summary — never hidden.
#
# Dependencies: PyYAML and yamllint (tests/requirements.txt) and hadolint, all
# three REQUIRED and all three bootstrapped by tests/bootstrap.sh on first run,
# so this one command is the whole procedure on a clean clone.
#
# node, the shellcheck binary, and the six language toolchains run when present
# and skip when they are not; the artifact-presence and static checks always
# run, so a deleted template is a failure on a machine with no toolchains at all.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/kit-validate.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# The one path the whole repo agrees on, read by every check that looks at the
# reusable workflow. It is a variable rather than a literal repeated in a dozen
# heredocs because the path being wrong is exactly the defect this packet
# exists to fix — see the `callable path` check below.
WORKFLOW='.github/workflows/ci.reusable.yml'

# The three files that make the secret scanner one decision rather than three.
# Paths as variables for the same reason WORKFLOW is: the path being wrong is the
# class of defect this file exists to catch, and a literal repeated in a dozen
# heredocs is a dozen chances to spell it three ways.
GITLEAKS_CONFIG='.gitleaks.toml'
GITLEAKS_GATE='tests/gitleaks_gate.sh'
ZIZMOR_CONFIG='.github/zizmor.yml'

# The one `language` option that is not a language. `none` means "this
# repository has no service manifest": no go.mod, no Gemfile, no
# pyproject.toml. It exists because the repository that defines the workflow
# is itself such a repository, and without it kit cannot call its own
# standard — the file was uncallable by the only repo that had any business
# calling it. A real Dockerfile, a `bin/prime` and a mise pin are meaningless
# for it, so the four-artifacts rule deliberately does not apply.
CONFIG_ONLY='none'

# Arguments are parsed BEFORE anything is installed, so `--help` answers on a
# machine with no python and no network. A `--help` that bootstraps a virtualenv
# is a help message with a side effect.
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

# The gate installs its own dependencies. Not `shellcheck` and not `node` —
# those stay optional and reported as SKIPs when absent — but PyYAML, without
# which not one check in this file can run, and yamllint, which kit's own
# configs are linted with.
#
# This is the second time this has been a problem. It was a two-line manual
# step in AGENTS.md that every fresh clone and every CI runner missed, and the
# gate exited 1 with `no python with PyYAML` before checking anything. A
# prerequisite that is documented and not automated is a prerequisite that will
# be skipped by exactly the machine you most wanted to hear from.
#
# The resolved interpreter is exported so `tests/self_test.sh`, and every
# throwaway copy of the gate it spawns, uses the same one instead of each
# re-deriving it. That is not only speed: eighteen copies each bootstrapping
# their own virtualenv is eighteen chances to fail for a reason that has nothing
# to do with the breakage under test.
if [ ! -r "$ROOT/tests/bootstrap.sh" ]; then
  echo "validate.sh: tests/bootstrap.sh is missing — the gate cannot install its own dependencies" >&2
  exit 1
fi
# shellcheck source=tests/bootstrap.sh
. "$ROOT/tests/bootstrap.sh"
kit_bootstrap_python "$ROOT"
export KIT_PYTHON="$PY"

# gitleaks' pinned version, for the check messages below. Read from bootstrap.sh
# rather than re-declared, because two places holding a version number is how the
# binary that gets sha256-verified and the version the gate claims to have run
# stop being the same one. `:-unknown` so the gate still runs against a
# bootstrap.sh older than the secret-scanner checks, rather than dying on an
# unbound variable in its own bookkeeping.
KIT_GITLEAKS_VERSION="${KIT_GITLEAKS_VERSION:-unknown}"

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

# check_verbose — `check`, but it shows the proof on success too.
#
# `check` swallows a passing run's output, which is right for most checks: a
# suite that prints nothing is a suite whose output is a summary. It is wrong for
# the canary harness, whose output is the RED PROOF lines — the evidence that
# each of the five detectors actually fired rather than quietly asserting nothing.
#
# So those lines are echoed when the check passes, and the whole output when it
# fails. The first version of this used `check` and shipped with the proofs
# invisible on a green run, which is precisely the "a proof nobody can see is a
# proof nobody ran" failure the harness's own comments argue against.
check_verbose() { # check_verbose <label> <proof-regex> <command...>
  local label="$1" proof="$2" out ec=0
  shift 2
  out="$("$@" 2>&1)" || ec=$?
  if [ "$ec" -eq 0 ]; then
    report PASS "$label"
    printf '%s\n' "$out" | grep -E "$proof" | sed 's/^/       /' || true
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
  # Dockerfile rules hadolint does not cover. Defined here rather than inline so
  # the section above reads as a list of assertions.
  docker_rules() {
    "$PY" - "$ROOT" <<'PY'
import os
import re
import sys

root = sys.argv[1]
docker_dir = os.path.join(root, "docker")

problems = []
for name in sorted(os.listdir(docker_dir)):
    if not name.startswith("Dockerfile."):
        continue
    rel = f"docker/{name}"
    body = open(os.path.join(docker_dir, name), encoding="utf-8").read()
    lines = body.splitlines()

    # `USER` after the LAST `FROM` is the runtime user. Everything before it is
    # build-time and runs as root by design — that is what a builder stage is.
    last_from = max(
        (i for i, ln in enumerate(lines) if re.match(r"^\s*FROM\s", ln, re.I)),
        default=None,
    )
    if last_from is None:
        problems.append(f"{rel}: no FROM — nothing to run")
        continue

    final_stage = lines[last_from:]
    users = [
        ln.strip()[len("USER "):].strip()
        for ln in final_stage
        if re.match(r"^\s*USER\s+\S", ln, re.I)
    ]
    if not users:
        problems.append(
            f"{rel}: the final stage sets no USER, so it runs as root — "
            f"a container running as root is a container where a bug is a host "
            f"compromise"
        )
    elif any(u.split(":")[0] in ("root", "0", "0:0") for u in users):
        problems.append(f"{rel}: the final stage's USER is root ({users[-1]})")

    # Every FROM carries an explicit tag, and never `latest`.
    for i, ln in enumerate(lines, 1):
        m = re.match(r"^\s*FROM\s+(\S+)(.*)$", ln, re.I)
        if not m:
            continue
        image, rest = m.group(1), m.group(2)
        # An ARG-interpolated tag still has to end in a real tag, so the last
        # colon-separated component is what carries it: `python:${V}-slim` ends
        # in `-slim`, `golang:${V}` ends in `${V}`. Neither is `latest`.
        tail = re.split(r"[ \t]", rest.strip())[0] if rest.strip() else ""
        if not tail and ":" not in image:
            problems.append(f"{rel}:{i}: FROM {image} has no tag; an untagged base is a moving target")
        if tail in ("latest",) or image.rsplit(":", 1)[-1] == "latest":
            problems.append(f"{rel}:{i}: FROM {image} is :latest")

    # ADD pulls a URL as easily as a file, so it is a way to put unverified
    # content in an image without a hash. COPY cannot do that. The four kit
    # artifacts a service inherits should not hand a reader that option.
    for i, ln in enumerate(lines, 1):
        if re.match(r"^\s*ADD\s", ln, re.I):
            problems.append(f"{rel}:{i}: ADD — use COPY, which cannot fetch a URL")

if problems:
    sys.exit("; ".join(problems))
PY
  }

  # Every template's STRICTNESS NOTES must state the non-root guarantee, in the
  # final stage, in the file itself. Parsed as the leading comment block rather
  # than grepped for a keyword: all seven files mention "root" somewhere in
  # prose, so a grep was satisfied by a line about root-owned directories while
  # the actual guarantee went unstated.
  docker_notes() {
    "$PY" - "$ROOT" <<'PY'
import os
import re
import sys

root = sys.argv[1]
docker_dir = os.path.join(root, "docker")

problems = []
for name in sorted(os.listdir(docker_dir)):
    if not name.startswith("Dockerfile."):
        continue
    rel = f"docker/{name}"
    lines = open(os.path.join(docker_dir, name), encoding="utf-8").read().splitlines()

    # The leading comment block, stopping at the first instruction.
    head = []
    for ln in lines:
        if not ln.lstrip().startswith("#"):
            break
        head.append(ln)

    if not head:
        problems.append(f"{rel}: no STRICTNESS NOTES header comment")
        continue

    body = "\n".join(head).lower()
    # `non-root`, `nonroot`, or `uid 1000`-style: the claim is that the process
    # is not uid 0, however the file happens to word it. What it must NOT accept
    # is a note that only talks about root-owned files.
    claims_non_root = re.search(r"non-?root", body) is not None
    if not claims_non_root:
        problems.append(
            f"{rel}: its STRICTNESS NOTES do not state that the final stage runs "
            f"non-root. Every one of these templates does run non-root (the check "
            f"above proves it), but a reader deciding whether to adopt the file "
            f"reads the notes, not the gate"
        )
    if "strictness" not in body:
        problems.append(
            f"{rel}: the header comment has no STRICTNESS NOTES block, so a future "
            f"contributor has nothing saying what is enforced and why"
        )

if problems:
    sys.exit("; ".join(problems))
PY
  }

  section 'static: every artifact parses'

  for f in "$ROOT"/.github/workflows/* "$ROOT"/lint/* "$ROOT"/docker/* \
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
      "$ROOT"/docker/Dockerfile.*)
        # Linted by hadolint in the section below, and by `docker_rules` for the
        # two properties hadolint does not cover. Deliberately not reported
        # here: "no parser for this file type" was the seven-line SKIP this
        # packet exists to remove, and printing it next to a real hadolint
        # result would say both "unchecked" and "checked" in the same run.
        ;;
      *)
        # A new file type with no parser is a gap, so it is loud rather than
        # quiet. It is still a SKIP, because the honest report matters more
        # than a red gate on an unknown extension — but a SKIP is counted and
        # printed in the summary, which is how the seven Dockerfiles were found.
        report SKIP "$path  (no parser for this file type)"
        ;;
    esac
  done

  # Every script kit hands out is executable. `chmod -x bin/dev` in a commit is
  # a one-character diff that silently breaks six repos the next they adopt.
  #
  # tests/ is in this list and not an afterthought: tests/gitleaks_gate.sh and
  # tests/zizmor_gate.sh are run BY the reusable workflow, from a service's
  # repository, against that service's tree. A gate script that is not executable
  # is a `secrets` job that dies at the first step in thirteen repos.
  # The two gate scripts are in this list and not an afterthought: they are run
  # BY the reusable workflow, from a service's repository, against that service's
  # tree. A gate script that is not executable is a `secrets` job that dies at
  # its first step in thirteen repos.
  #
  # `tests/bootstrap.sh` is deliberately NOT in the list: it is sourced, never
  # executed, and it says so at the top. A check that required it to be
  # executable would be asking a file to claim a contract it does not have.
  section 'static: handed-out scripts are executable'
  for f in "$ROOT"/templates/bin-prime/* "$ROOT"/templates/bin/* \
    "$ROOT/$GITLEAKS_GATE" "$ROOT/tests/zizmor_gate.sh"; do
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

  # -------------------------------------------------------------------------
  # The canary harness's Go sources must PARSE, and must parse in Go's own
  # parser rather than in a regex.
  #
  # The gate executes the suite (telemetry phase), so a syntax error is caught
  # there — but only on a machine with Go installed, where it would be reported
  # as a telemetry SKIP's opposite and a developer would read it as "the canary
  # is fine". A parse here runs with no toolchain at all, so a missing template
  # or a bad edit is a static failure on any machine, which is the property the
  # otel snippets were given for the same reason.
  section 'static: the canary harness parses in Go'
  if have gofmt; then
    # gofmt is a real parser: it exits non-zero on a file it cannot parse, and
    # unlike `go build` it needs no module, no resolver and no network.
    for f in "$ROOT"/templates/secrets/go/*.go "$ROOT"/templates/secrets/go/internal/*/*.go; do
      [ -f "$f" ] || continue
      path="${f#"$ROOT"/}"
      check "$path  (gofmt parses)" gofmt -e "$f"
    done
  else
    report SKIP 'templates/secrets/go  (gofmt not installed — cannot parse)'
  fi

  # Every snippet must PARSE in its own language. This is not a style check and
  # not a stretch: a snippet is the file a service copies, so a syntax error in
  # one ships as a service that does not boot.
  #
  # It already happened. rack_middleware.rb.snippet contained
  # `c.use_all, :auto_instrumentation`, which is not valid Ruby, and no check in
  # this file looked at it — the artifact-presence table only asked whether the
  # file existed, and `node --check` refuses a `.snippet` extension outright.
  #
  # Snippets are copied to a real extension before parsing, because
  # `ruby -c foo.snippet` fails on the extension alone and `node --check` throws
  # ERR_UNKNOWN_FILE_EXTENSION.
  section 'static: every otel snippet parses in its own language'

  snippet_dir="$TMP/snippets"
  rm -rf "$snippet_dir"
  mkdir -p "$snippet_dir"

  # <lang>|<file>|<extension>|<command...>
  while IFS='|' read -r lang file ext cmd; do
    [ -n "$lang" ] || continue
    src="$ROOT/templates/otel/$lang/$file"
    [ -f "$src" ] || continue
    copy="$snippet_dir/$lang$ext"
    cp "$src" "$copy"
    if out=$($cmd "$copy" 2>&1); then
      report PASS "otel/$lang/$file  (parses as $ext)"
    else
      report FAIL "otel/$lang/$file  (parses as $ext)"
      printf '%s\n' "$out" | head -8 | sed 's/^/       /'
    fi
  done <<'SNIPPETS'
go|otelhttp.go.snippet|.go|gofmt -e -l
ruby|rack_middleware.rb.snippet|.rb|ruby -c
python|fastapi.py.snippet|.py|python3 -m py_compile
SNIPPETS

  # rustc needs its own treatment: --emit=metadata on a file importing
  # opentelemetry fails on unresolved crates (E0432/E0433), which is not a
  # syntax error and is exactly what a dependency-free kit should produce. So
  # the check is "no error other than an unresolved-crate error", which still
  # catches every parse error.
  if have rustc; then
    rust_copy="$snippet_dir/otel_client.rs"
    cp "$ROOT/templates/otel/rust/otel_client.rs.snippet" "$rust_copy"
    rust_out="$(rustc --edition 2021 --crate-type lib --emit=metadata \
      -o /dev/null "$rust_copy" 2>&1 || true)"
    # Compare ERROR CODES, not lines. rustc's trailing
    # `error: aborting due to 16 previous errors` carries no code, so a
    # line-based "is any line not E0432/E0433" test reports that summary as a
    # syntax error. Which is what the first version of this check did.
    rust_codes="$(printf '%s\n' "$rust_out" | grep -oE '^error\[E[0-9]+\]' | sort -u)"
    rust_unexpected="$(printf '%s\n' "$rust_codes" | grep -vE 'E0432|E0433|E0463' || true)"
    if [ -n "$rust_unexpected" ]; then
      report FAIL 'otel/rust/otel_client.rs.snippet  (parses as .rs)'
      printf '%s\n' "$rust_unexpected" | sed 's/^/       /'
    elif [ -z "$rust_codes" ]; then
      report PASS 'otel/rust/otel_client.rs.snippet  (parses; crates resolved)'
    else
      report PASS 'otel/rust/otel_client.rs.snippet  (parses; crates unresolved, as expected)'
    fi
  else
    report SKIP 'otel/rust/otel_client.rs.snippet  (rustc not installed)'
  fi

  # TypeScript: node's own type stripper is a parser, and it is in the node
  # already running this gate. No typescript-eslint, no install.
  if have node; then
    ts_copy="$snippet_dir/hono.ts"
    cp "$ROOT/templates/otel/node/hono.ts.snippet" "$ts_copy"
    # The ExperimentalWarning goes to stderr and is not a parse failure, so it
    # is filtered rather than allowed to fail a clean parse.
    ts_out="$(node --experimental-strip-types --check "$ts_copy" 2>&1 |
      grep -vE 'ExperimentalWarning|trace-warnings' || true)"
    if [ -z "$ts_out" ]; then
      report PASS 'otel/node/hono.ts.snippet  (parses as .ts)'
    else
      report FAIL 'otel/node/hono.ts.snippet  (parses as .ts)'
      printf '%s\n' "$ts_out" | head -8 | sed 's/^/       /'
    fi
  else
    report SKIP 'otel/node/hono.ts.snippet  (node not installed)'
  fi

  # A template must not declare a dependency. kit is config-only; if these
  # files can `require` something, kit has a lockfile and a supply chain.
  section 'static: templates declare no third-party dependency'
  check 'templates/otel/go/go.mod  (no require)' bash -c \
    "! grep -qE '^[[:space:]]*require' '$ROOT/templates/otel/go/go.mod'"
  # The canary harness is the other stdlib-only template, and the same rule
  # applies for a sharper reason: a canary test that pulls in a dependency is a
  # canary test whose own output has to be trusted not to contain the thing it
  # is sweeping for. kit has no dependencies, and neither does a thing kit hands
  # out.
  check 'templates/secrets/go/go.mod  (no require)' bash -c \
    "! grep -qE '^[[:space:]]*require' '$ROOT/templates/secrets/go/go.mod'"
  if [ -f "$ROOT/templates/otel/node/package.json" ]; then
    check 'templates/otel/node/package.json  (no dependencies)' bash -c \
      "$PY -c \"import json,sys; d=json.load(open(sys.argv[1])); sys.exit(1 if (d.get('dependencies') or d.get('devDependencies')) else 0)\" \
      '$ROOT/templates/otel/node/package.json'"
  else
    report PASS 'templates/otel/node/package.json  (not needed: node:test + stdlib)'
  fi

  # -------------------------------------------------------------------------
  # The seven Dockerfiles.
  #
  # These are one of the four artifacts every adopting service inherits, and
  # until now they received NO lint at all: the artifact-presence loop above
  # reached the `*)` branch and printed
  #
  #     SKIP docker/Dockerfile.go  (no parser for this file type)
  #
  # seven times. A skip is honest, which is how it was found, and honest is not
  # the same as covered: a Dockerfile that does not build ships unverified, and
  # a service that adopts one finds out on its own first deploy.
  #
  # hadolint is the real parser and it is required, not optional. It is a
  # single static binary, so `kit_bootstrap_binary` fetches a pinned release and
  # verifies its published sha256 rather than trusting whatever is on PATH —
  # a linter that is silently absent, or silently different, is the same
  # SKIP wearing a PASS.
  section 'static: every Dockerfile is hadolint clean'
  if kit_bootstrap_binary hadolint \
    "https://github.com/hadolint/hadolint/releases/download/v${KIT_HADOLINT_VERSION}" \
    "$KIT_HADOLINT_SHA256S" "$ROOT"; then
    for f in "$ROOT"/docker/Dockerfile.*; do
      [ -f "$f" ] || continue
      rel="${f#"$ROOT"/}"
      # `--no-color`: the gate's output is read by humans and by CI log
      # scrapers, and an ANSI escape in a FAIL block is noise in both.
      if out=$("$BIN" -c "$ROOT/lint/hadolint.yaml" --no-color "$f" 2>&1); then
        report PASS "$rel  (hadolint)"
      else
        report FAIL "$rel  (hadolint)"
        printf '%s\n' "$out" | sed 's/^/       /'
      fi
    done
  else
    # Not a SKIP. hadolint is the only thing standing between a template and a
    # broken build, and a gate that reports "I could not check" and exits 0 is
    # the exact shape PLAN.md §1 calls a gate that is not green. It is also the
    # shape that let seven Dockerfiles go unlinted in the first place.
    report FAIL 'hadolint (required: could not be installed — see the note above)'
  fi

  # hadolint is a syntax-and-practice linter. It will happily pass a Dockerfile
  # whose final stage runs as root, and root in a container is a container where
  # a bug is a host compromise. So the two properties kit's own STRICTNESS NOTES
  # claim for all seven — a non-root final stage, and a pinned (never `:latest`)
  # base image — are asserted here rather than assumed from the prose.
  #
  # Read from the file as text, not from a Dockerfile parser: these templates
  # use `ARG` interpolation, so a base image is `python:${PYTHON_VERSION}-slim`
  # and the claim to check is that the tag exists and is not `latest`, not that
  # it is a literal. hadolint is the parser for everything it can parse; this is
  # the two claims that outlive it.
  section 'static: every Dockerfile runs non-root on a pinned base'
  check 'docker/Dockerfile.*  (non-root final stage, no :latest, no ADD)' docker_rules

  # A Dockerfile with no USER in its final stage is a real defect, and the check
  # above proves that claim can fail. So the claim is written down where the
  # reader is: in each template's own STRICTNESS NOTES, the block a person
  # deciding whether to adopt this file actually reads.
  #
  # The note is required to be about the non-root final stage specifically, not
  # merely to contain the word "root" — every one of the seven already mentions
  # running non-root SOMEWHERE in passing, in prose no check read. A check that
  # the claim is documented where the reader looks, and the check that the claim
  # is true, are different checks; this is the first.
  section 'static: each Dockerfile documents its own non-root guarantee'
  check 'docker/Dockerfile.*  (STRICTNESS NOTES state the non-root stage)' docker_notes

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
    #
    # `$2` is the option that means "no language" and so ships no artifacts.
    # It is skipped here rather than being special-cased out of the workflow,
    # because a hardcoded name in two places is exactly how the two drift.
    #
    # The path arrives as argv[3] rather than being written out again here: a
    # second copy of this string is a second thing to forget to move.
    "$PY" - "$ROOT" "$CONFIG_ONLY" "$WORKFLOW" <<'PY'
import sys

import yaml

skip = sys.argv[2]
with open(sys.argv[3], encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
triggers = doc.get("on") or doc.get(True) or {}
call = (triggers.get("workflow_call") or {}).get("inputs") or {}
for lang in ((call.get("language") or {}).get("options") or []):
    if lang != skip:
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
    "$PY" - "$ROOT" "$CONFIG_ONLY" "$WORKFLOW" <<'PY'
import re
import sys

root = sys.argv[1]
config_only = sys.argv[2]
with open(sys.argv[3], encoding="utf-8") as fh:
    import yaml

    doc = yaml.safe_load(fh)
triggers = doc.get("on") or doc.get(True) or {}
call = (triggers.get("workflow_call") or {}).get("inputs") or {}
# `none` is the absence of a toolchain; there is no mise tool to pin for it.
langs = [x for x in ((call.get("language") or {}).get("options") or []) if x != config_only]

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
#
# Read from the PARSED document's `ports:` lists rather than by grepping lines.
# A line-based scan flags anything shaped like `host:container`, which includes
# the collector's bind addresses (`0.0.0.0:4317` under `environment:`) — those
# are endpoints inside the network, not published ports, and a check that cannot
# tell the two apart is a check everyone learns to ignore.
published = []
for name, svc in services.items():
    for entry in (svc or {}).get("ports") or []:
        if isinstance(entry, dict):
            # long form: {target: 5432, published: "5432"}
            host = str(entry.get("published", ""))
            target = str(entry.get("target", ""))
        else:
            host, _, target = str(entry).partition(":")
        if not host or not target:
            continue
        if "${" not in host:
            published.append(f"{name}: published host port {host} is not a ${{KIT_*}} substitution")

if published:
    problems.extend(published)

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

  # The wiring check that YAML parsing cannot do, and the one that caught a real
  # bug. otel-collector.yml interpolates ${env:NAME}, which the collector
  # resolves from ITS OWN process environment. Docker Compose reads .env to
  # expand ${KIT_*:default} in the compose file, and does NOT inject those into
  # containers. So a collector config full of ${env:...} against a compose file
  # with no `environment:` block parses perfectly, passes every check above, and
  # then the collector exits at startup with an error naming a memory limiter
  # rather than the missing environment.
  #
  # It did. That stack had never run. Asserting the wiring is cheaper than
  # running docker in the gate, and it fails with a message that names the cause.
  collector_wiring_check() {
    "$PY" - "$ROOT" <<'PY'
import re
import sys

import yaml

root = sys.argv[1]
with open(f"{root}/templates/compose/otel-collector.yml", encoding="utf-8") as fh:
    yaml.safe_load(fh)
with open(f"{root}/templates/compose/docker-compose.yml", encoding="utf-8") as fh:
    compose = yaml.safe_load(fh)

problems = []

# Every env-substituted name the collector reads, over the whole document
# rather than a fixed path: the value can sit at any depth (a processor arg, an
# exporter's verbosity, an extension endpoint), and a check that only knew the
# three it was written against would miss the fourth.
#
# Comment lines are excluded. A prose example of the syntax — which this file
# needs, because the whole point of the rule is to state it — otherwise
# registers as a variable the collector needs, and a check that fails on its own
# documentation is a check people delete.
raw = "\n".join(
    line
    for line in open(
        f"{root}/templates/compose/otel-collector.yml", encoding="utf-8"
    ).read().splitlines()
    if not line.lstrip().startswith("#")
)
needed = set(re.findall(r"\$\{env:([A-Z0-9_]+)\}", raw))

svc = (compose.get("services") or {}).get("otel-collector")
if not isinstance(svc, dict):
    problems.append("no otel-collector service to carry the environment")
else:
    provided = set(svc.get("environment") or {})
    for name in sorted(needed - provided):
        # Assembled rather than an f-string: `${env:NAME}` is not a valid Python
        # f-string expression, and a check whose failure message raises is a
        # check that reports the wrong thing at the exact moment it matters.
        placeholder = "$" + "{env:" + name + "}"
        problems.append(
            f"otel-collector.yml reads {placeholder} but docker-compose.yml does "
            f"not pass {name} into the container; it resolves empty and the "
            f"collector refuses to start"
        )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'otel-collector env  (every ${env:} reaches the container)' collector_wiring_check

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

  # Dogfood lint/yamllint.yml on every YAML in the tree, not just the two
  # compose templates. kit ships the config and a repo that copies it lints its
  # own CI against it on day one, so a YAML that breaks the config is a YAML
  # that greets the first adopting repo with a failure nobody authored.
  #
  # Required, not optional: it is in tests/requirements.txt and the bootstrap
  # above has already installed it, so a machine that reaches this line has
  # yamllint. A SKIP here would hide a broken config behind a missing tool on
  # exactly the machine that has not run the gate before.
  #
  # The check that used to skip when it was absent is now a FAIL, and says so —
  # the absence is a defect in the environment, not a neutral fact, and it is
  # the difference between "this YAML is bad" and "I did not look".
  section 'static: every YAML in the tree is yamllint clean'
  if [ -z "${KIT_YAMLLINT:-}" ]; then
    if ! kit_bootstrap_console_script yamllint yamllint "$ROOT"; then
      exit 1
    fi
    YAMLLINT="$CONSOLE"
  else
    YAMLLINT="$KIT_YAMLLINT"
  fi
  if [ ! -x "$YAMLLINT" ]; then
    report FAIL "yamllint (KIT_YAMLLINT=$YAMLLINT is not executable)"
  else
    # Lint the tree, not a hand-kept list. `git ls-files` rather than `find` so
    # the gate lints exactly what a caller clones, and so a .venv full of
    # somebody else's YAML never enters the report. Falls back to `find` in a
    # throwaway copy from self_test, which is not a git repository.
    #
    # `while read` rather than `mapfile` into an array: mapfile is a bash 4
    # builtin and kit's gate is also run by whatever `bash` a slim container
    # ships. A loop over a pipeline needs no array, and no `set -u`-safe empty
    # expansion.
    yamls_of_the_tree() {
      if [ -d "$ROOT/.git" ] || [ -f "$ROOT/.git" ]; then
        git -C "$ROOT" ls-files '*.yml' '*.yaml' 2>/dev/null
      else
        (cd "$ROOT" && find . -name .venv -prune -o -type f \( -name '*.yml' -o -name '*.yaml' \) -print |
          sed 's|^\./||' | sort)
      fi
    }
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      [ -f "$ROOT/$rel" ] || continue
      check "$rel  (yamllint -c lint/yamllint.yml)" \
        "$YAMLLINT" -c "$ROOT/lint/yamllint.yml" "$ROOT/$rel"
    done < <(yamls_of_the_tree)
  fi

  # The CI workflow gains a job; assert the job exists, is opt-in, and that the
  # default call still runs exactly the six original jobs. A kit change that
  # breaks every consumer's CI is a kit change that does not ship.
  #
  # The secrets and zizmor jobs are asserted separately, below, because they are
  # the two jobs whose absence is silent in a way `option has no job` does not
  # make silent: a repo without a secrets job has no secret scanning, and every
  # other check in this file is still green.
  ci_check() {
    "$PY" - "$ROOT" "$CONFIG_ONLY" "$WORKFLOW" <<'PY'
import re
import sys

import yaml

config_only = sys.argv[2]
with open(sys.argv[3], encoding="utf-8") as fh:
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
# reach. The two lists are the same list — plus the one option that names the
# absence of a language, which has a job of its own.
options = ((call.get("language") or {}).get("options")) or []
if sorted(options) != sorted(languages + [config_only]):
    problems.append(
        f"`language` options {sorted(options)} do not match the job set "
        f"{sorted(languages + [config_only])}"
    )

# `none` is what lets a repository with no service manifest adopt this
# workflow at all, and kit is such a repository. It gets the same treatment as
# every other option: a job, and a guard on the input. An option whose job has
# no `if` would run in all thirteen consumer repos on day one.
cjob = jobs.get(config_only)
if not isinstance(cjob, dict):
    problems.append(
        f"job {config_only} disappeared: without it a repository with no service "
        f"manifest cannot call this workflow, which is why kit never called its own"
    )
else:
    cond = cjob.get("if")
    if cond is None or f"inputs.language == '{config_only}'" not in cond:
        problems.append(f"job {config_only} is not gated on its language input")

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
source = open(sys.argv[3], encoding="utf-8").read()
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
  check "$WORKFLOW  (opt-in telemetry job, defaults intact)" ci_check

  # -------------------------------------------------------------------------
  # The `secrets` job, asserted as a job rather than as a config file.
  #
  # Three things, and each is a distinct way this job could stop being a gate
  # while every other check in the file stayed green:
  #
  #   1. it could stop existing — a repo with no secret scanning is a repo that
  #      has never been scanned, and nothing else here notices
  #   2. it could become advisory — `continue-on-error` at the job or step level
  #      is the single most common way a security job is neutralised, and it is
  #      invisible in a green build. A secret scanner that only warns is a report
  #   3. it could lose its full history — `fetch-depth` reverting to the
  #      default shallow clone is a one-line diff that turns a history scan into
  #      a HEAD scan, and a HEAD scan cannot see a deleted secret
  secrets_job_check() {
    "$PY" - "$ROOT" "$WORKFLOW" "$GITLEAKS_GATE" <<'PY'
import sys

import yaml

workflow, gate = sys.argv[2], sys.argv[3]
with open(workflow, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
jobs = doc.get("jobs") or {}
problems = []

job = jobs.get("secrets")
if not isinstance(job, dict):
    problems.append(
        "no `secrets` job. Every other job in this file is a test the repo asked "
        "for; this one is the one a repo must not have to ask for, and a "
        "repository with no secret scanning has never been scanned while every "
        "other check here is green"
    )
else:
    # Advisory is the failure mode, so it is checked at both levels. A job-level
    # `continue-on-error: true` makes the whole job non-blocking; a step-level one
    # makes the scan non-blocking and leaves the job green.
    if job.get("continue-on-error") is True:
        problems.append(
            "the `secrets` job sets continue-on-error: true. That is what makes a "
            "secret scanner a report: the build goes green having found nothing, "
            "and a green badge is a claim"
        )

    steps = job.get("steps") or []
    # Full history. `fetch-depth: 0` on the checkout, not merely its absence —
    # an explicit 0 and an absent key look identical to a grep.
    checkout_depths = []
    for step in steps:
        if not isinstance(step, dict):
            continue
        if str(step.get("uses", "")).startswith("actions/checkout@"):
            checkout_depths.append((step.get("with") or {}).get("fetch-depth"))
    if not checkout_depths:
        problems.append("the `secrets` job has no actions/checkout step")
    elif not any(str(d) == "0" for d in checkout_depths):
        problems.append(
            f"the `secrets` job checks out with fetch-depth {checkout_depths}. The "
            f"runner default is a SHALLOW clone — one commit. A shallow scan is a "
            f"diff scan with extra steps, and a diff scan cannot see a secret that "
            f"was committed and deleted, which is the finding that matters most: it "
            f"is on every fork and in the packfile of anyone who cloned. fetch-depth "
            f"must be 0"
        )

    # The scan must be the shared script, so CI and `bash tests/validate.sh` are
    # the same scan. A workflow that inlines its own gitleaks command line is two
    # scanners, and the one that goes red is whichever nobody runs.
    runs = "\n".join(
        str(s.get("run", "")) for s in steps if isinstance(s, dict)
    )
    if gate not in runs:
        problems.append(
            f"the `secrets` job does not run {gate}. kit's gate runs that script and "
            f"this job inlines its own command line instead, which means the scan a "
            f"developer runs and the scan CI runs have already drifted, and the one "
            f"that goes red is whichever nobody runs"
        )

    # Every step must be blocking.
    for i, step in enumerate(steps, 1):
        if isinstance(step, dict) and step.get("continue-on-error") is True:
            problems.append(
                f"the `secrets` job step {i} ({step.get('name', step.get('uses', '?'))}) "
                f"sets continue-on-error: true, which makes the scan advisory"
            )

    # No `if: always()` or `if: failure()` on the scan step: a scan that only
    # runs when something else already failed is a report about the failure.
    for step in steps:
        if not isinstance(step, dict):
            continue
        cond = str(step.get("if", ""))
        if "always()" in cond or "failure()" in cond or "success()" in cond:
            problems.append(
                f"a `secrets` step is conditional on {cond!r}. A secret scan that runs "
                f"only under some conditions is a report about those conditions"
            )

    # And the job must not be opt-in, which is the opposite of every other job
    # in this file and the one deliberate exception.
    cond = str(job.get("if", ""))
    if "inputs." in cond:
        problems.append(
            f"the `secrets` job is gated on {cond!r}. It is the one job in this file "
            f"with no opt-in, deliberately: an opt-in security control is not a "
            f"control, and a secret scanner that only warns is a report"
        )

# The zizmor job is opt-in and must say so with a STRING comparison, for the
# reason every other opt-in input in this file does: GitHub coerces a bare
# `false` to a boolean in some positions, and `if: inputs.zizmor` is a trap.
zjob = jobs.get("zizmor")
if not isinstance(zjob, dict):
    problems.append(
        "no `zizmor` job. The audit reads the adopting repo's OWN workflows, which "
        "kit did not write, so it is opt-in — but a job that has quietly stopped "
        "existing and an input that is quietly never passed are the same silence"
    )
else:
    cond = str(zjob.get("if", ""))
    if "inputs.zizmor" not in cond:
        problems.append(
            f"the `zizmor` job is not gated on its input ({cond!r}), so it would run "
            f"in every adopting repo on day one and turn them red for findings in "
            f"workflows kit did not write"
        )
    elif "'true'" not in cond:
        problems.append(
            f"the `zizmor` job's condition is {cond!r}; it must compare to the STRING "
            f"'true'. A bare boolean coerces unpredictably in some positions, which is "
            f"the exact trap the `telemetry` input exists to avoid"
        )

# Both new inputs must exist and default to 'false', for the same reason
# `telemetry` does — a kit change that breaks every consumer's CI does not ship.
triggers = doc.get("on") or doc.get(True) or {}
call = (triggers.get("workflow_call") or {}).get("inputs") or {}
for name in ("zizmor",):
    declared = call.get(name)
    if not isinstance(declared, dict):
        problems.append(f"no `{name}` workflow_call input")
    else:
        if str(declared.get("default", "")) not in ("false", "False"):
            problems.append(
                f"the `{name}` input defaults to {declared.get('default')!r}; it must "
                f"default to 'false'"
            )
        if str(declared.get("type")) != "string":
            problems.append(f"the `{name}` input must be type: string (booleans coerce badly)")

# `secrets` must NOT be an input at all: it takes no opt-in, and an input named
# `secrets` with a default of false would be a way to turn the secret scanner off
# without anyone noticing the flag.
if "secrets" in call:
    problems.append(
        "the workflow declares a `secrets` input. The secret scanner is the one job "
        "with no opt-in, and an input is an off switch — a `secrets: false` in a "
        "caller would be a way to disable secret scanning that looks like "
        "configuration"
    )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check "$WORKFLOW  (secrets job: not advisory, full history, not opt-in)" \
    secrets_job_check

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

  # The README's own examples must call the workflow the README says it does.
  #
  # Every yaml block in the README that contains `uses: cafaye/kit/` is a
  # caller. A caller passing an input the workflow does not declare fails at
  # run time on the adopting repo's first push — thirteen repos, one stale
  # sentence in this file. So the examples are parsed and checked against the
  # workflow's real inputs, and a doc that lies fails the gate.
  caller_check() {
    "$PY" - "$ROOT" "$WORKFLOW" <<'PY2'
import re
import sys

import yaml

root = sys.argv[1]
readme = open(f"{root}/README.md", encoding="utf-8").read()

# Fenced yaml blocks only, and only the ones that are actually calling kit.
blocks = re.findall(r"```yaml\n(.*?)```", readme, re.S)
callers = [b for b in blocks if "uses: cafaye/kit/" in b]
if not callers:
    sys.exit("no documented caller of the reusable workflow found in README.md")

with open(sys.argv[2], encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
triggers = doc.get("on") or doc.get(True) or {}
declared = ((triggers.get("workflow_call") or {}).get("inputs")) or {}
required = {k for k, v in declared.items() if (v or {}).get("required")}

def _find_with_keys(node):
    """Every key set under a `with:` mapping, at any depth."""
    found = []
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "with" and isinstance(value, dict):
                found.append(value.keys())
            else:
                found.extend(_find_with_keys(value))
    elif isinstance(node, list):
        for item in node:
            found.extend(_find_with_keys(item))
    return found


def _find_telemetry(node):
    """Every value assigned to a `telemetry` key, at any depth.

    The examples are fragments, so the key can sit under `with:`, under a `job`,
    or under nothing at all. A depth-limited walk would miss the case that
    matters.
    """
    found = []
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "telemetry":
                found.append(value)
            else:
                found.extend(_find_telemetry(value))
    elif isinstance(node, list):
        for item in node:
            found.extend(_find_telemetry(item))
    return found


problems = []
for n, block in enumerate(callers, 1):
    try:
        doc_n = yaml.safe_load(block)
    except Exception as exc:
        problems.append(f"documented caller #{n} is not valid YAML: {exc}")
        continue
    for job_name, job in (doc_n.get("jobs") or {}).items():
        if not isinstance(job, dict) or "cafaye/kit/" not in str(job.get("uses", "")):
            continue
        passed = set(job.get("with") or {})
        unknown = sorted(passed - set(declared))
        missing = sorted(required - passed)
        if unknown:
            problems.append(
                f"documented caller #{n} job {job_name}: passes {unknown}, which "
                f"the workflow does not declare"
            )
        if missing:
            problems.append(
                f"documented caller #{n} job {job_name}: omits required {missing}"
            )

# Any documented `with:` block names workflow inputs, whether or not the block
# also carries a `uses:` line. The adoption steps and the telemetry opt-in are
# both bare `with:` fragments under prose, and they are the two a reader copies
# line by line — so restricting the input check to complete caller blocks checks
# the example nobody copies and skips the ones everybody does.
for n, block in enumerate(blocks, 1):
    if "with:" not in block:
        continue
    try:
        parsed = yaml.safe_load(block)
    except Exception:
        continue
    for keys in _find_with_keys(parsed):
        unknown = sorted(set(keys) - set(declared))
        if unknown:
            problems.append(
                f"yaml block #{n}: a `with:` names {unknown}, which the workflow "
                f"does not declare as an input"
            )

# `telemetry` must be shown as a STRING everywhere it appears, not only in a
# full caller block. The input exists precisely because GitHub coerces the bare
# word `false` to a boolean in some positions, so a README example that writes
# `telemetry: true` teaches the one spelling that does not work — and a reader
# who copies it gets an opt-in job running that they did not intend to switch
# on, in a repo that was green a moment earlier.
#
# Checked on every yaml block, including the `with:` fragments that have no
# `uses:` line to key off. The first version of this check only looked at
# callers and therefore missed exactly the fragment most likely to be copied.
for n, block in enumerate(blocks, 1):
    if "telemetry" not in block:
        continue
    try:
        parsed = yaml.safe_load(block)
    except Exception:
        continue  # reported by the caller loop if it is a caller at all
    found = _find_telemetry(parsed)
    for value in found:
        if not isinstance(value, str):
            problems.append(
                f"yaml block #{n}: telemetry must be the string 'true' or "
                f"'false', not {value!r} — a bare boolean is the trap this input "
                f"type exists to avoid"
            )

if problems:
    sys.exit("; ".join(problems))
PY2
  }
  check 'README.md  (its documented callers match the workflow inputs)' caller_check

  # -------------------------------------------------------------------------
  # The check this packet exists for.
  #
  # kit-02 shipped a reusable workflow at `workflows/ci.reusable.yml`, a README
  # telling every reader to write
  #
  #     uses: cafaye/kit/workflows/ci.reusable.yml@master
  #
  # and GitHub, which does not support subdirectories of the workflows
  # directory, resolving that to nothing. Every check in this file was green
  # for the whole of that time. A layout bug and a documentation bug that agree
  # with each other are invisible to any check that reads only one of them, and
  # the file they disagreed about is the one thirteen repos were told to depend
  # on.
  #
  # So this asserts the agreement directly, in the places it can drift:
  #
  #   1. the file is at the path callers are told to use
  #   2. it declares `on: workflow_call` (parseable, and actually callable)
  #   3. every real `uses:` that names kit — in the docs' fenced yaml blocks and
  #      in this repo's own workflow files — is exactly that path, cross-repo
  #      with a ref, or local with `./` for kit calling itself
  #   4. kit's own CI calls it with the LOCAL form, so the self-proof is a
  #      self-proof and not a network fetch of some other ref
  #   5. there is exactly one copy of it in the tree
  #
  # Point 5 is not paranoia. A mirror — canonical file here, callable copy
  # there — is one of the two layouts the packet offered, and it is only
  # acceptable with a check that fails when the copies differ. kit chose the
  # move, so this walks the tree and refuses to find a second one. Same
  # reasoning as the outbox/`registries` duplication this repo already refuses.
  #
  # Only *executable* call sites are read: the `uses:` keys of parsed yaml.
  # Prose that quotes a wrong path to explain why it is wrong — which README
  # and AGENTS.md both now do — is not a call site, and a check that flags its
  # own explanation is a check people delete.
  callable_check() {
    "$PY" - "$ROOT" "$WORKFLOW" <<'PY3'
import os
import re
import sys

import yaml

root = sys.argv[1]
workflow = sys.argv[2]
remote = "cafaye/kit/" + workflow
local = "./" + workflow

problems = []

# --- 1 and 2: the file is where callers are told it is, and it is callable ----
path = os.path.join(root, workflow)
if not os.path.isfile(path):
    problems.append(
        f"callers are documented to write `uses: cafaye/kit/{workflow}@<ref>`, and "
        f"{workflow} does not exist — GitHub resolves a reusable workflow only "
        f"from .github/workflows/, so nothing can call kit"
    )
else:
    with open(path, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
    # `on:` is read by PyYAML 1.1 as the boolean True.
    triggers = doc.get("on") or doc.get(True) or {}
    if not isinstance(triggers, dict) or "workflow_call" not in triggers:
        problems.append(
            f"{workflow} does not declare `on: workflow_call`; GitHub rejects the "
            f"call before it reads a single input, so a caller gets a red build "
            f"with no explanation"
        )


def uses_values(node):
    """Every value assigned to a `uses:` key, at any depth."""
    found = []
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "uses" and isinstance(value, str):
                found.append(value)
            else:
                found.extend(uses_values(value))
    elif isinstance(node, list):
        for item in node:
            found.extend(uses_values(item))
    return found


# --- 3: every real call site resolves to the one path ------------------------
call_sites = []  # (where, value)

# 3a. the fenced yaml blocks in the two documents a reader copies from.
for doc_name in ("README.md", "AGENTS.md"):
    body = open(os.path.join(root, doc_name), encoding="utf-8").read()
    found_remote = 0
    for n, block in enumerate(re.findall(r"```yaml\n(.*?)```", body, re.S), 1):
        try:
            parsed = yaml.safe_load(block)
        except Exception:
            continue  # not a workflow fragment; another check reports real yaml
        for value in uses_values(parsed):
            if "cafaye/kit" not in value and not value.startswith("./"):
                continue
            call_sites.append((f"{doc_name} yaml block #{n}", value))
            if value.startswith("cafaye/kit"):
                found_remote += 1
    # Both documents must show the call. AGENTS.md is not decoration: it is the
    # file a contributor reads before touching the workflow, and it was the one
    # telling people to edit `workflows/ci.reusable.yml` for six months.
    if found_remote == 0:
        problems.append(
            f"{doc_name} shows no `uses: cafaye/kit/{workflow}@<ref>` example, so "
            f"a reader of that file has no call to copy"
        )

# 3b. this repo's own workflow files. Comments are not yaml and are skipped by
#     parsing, so the header of the reusable workflow — which shows the same
#     call as an example — is documentation, not a call site, and is not
#     double-counted here.
live_dir = os.path.join(root, ".github", "workflows")
for name in sorted(os.listdir(live_dir)) if os.path.isdir(live_dir) else []:
    if not name.endswith((".yml", ".yaml")):
        continue
    with open(os.path.join(live_dir, name), encoding="utf-8") as fh:
        try:
            parsed = yaml.safe_load(fh)
        except Exception as exc:
            problems.append(f".github/workflows/{name} is not valid YAML: {exc}")
            continue
    for value in uses_values(parsed):
        if "cafaye/kit" in value or value.startswith("./"):
            call_sites.append((f".github/workflows/{name}", value))

if not call_sites:
    problems.append(
        "no `uses:` anywhere calls kit, so nothing in this repository exercises "
        "the callable path"
    )

for where, value in call_sites:
    if value.startswith("./"):
        if value != local:
            problems.append(
                f"{where}: `uses: {value}` does not resolve; kit's own copy is at "
                f"`{local}`"
            )
        continue
    if not value.startswith("cafaye/kit/"):
        problems.append(f"{where}: `uses: {value}` is not a reference to kit")
        continue
    # Split the ref off before comparing. Comparing the whole string to the
    # path made every correct `...@master` look wrong, which is the check
    # failing on the very line it exists to bless.
    ref_path, _, ref = value.partition("@")
    if ref_path != remote:
        # It names kit, and it is not the path. Say what the right one is,
        # because the reader of this message is a person who is about to paste
        # a `uses:` line into thirteen repositories.
        problems.append(
            f"{where}: `uses: {value}` is not a path GitHub can resolve; callers "
            f"must write `uses: {remote}@<ref>`"
        )
    elif not ref:
        problems.append(
            f"{where}: `uses: {value}` has an empty @ref, which resolves to nothing"
        )

# --- 4: kit's own CI calls it locally ---------------------------------------
self_call = os.path.join(root, ".github", "workflows", "ci.yml")
if not os.path.isfile(self_call):
    problems.append(
        "no .github/workflows/ci.yml, so the repository defining the standard is "
        "not held to it and the callable path is never exercised in CI"
    )
else:
    with open(self_call, encoding="utf-8") as fh:
        parsed = yaml.safe_load(fh)
    jobs = (parsed or {}).get("jobs") or {}
    # Both spellings count: the cross-repo one, and the local `./` form kit is
    # the only repository that can legitimately write. Filtering on
    # `cafaye/kit` alone read kit's own self-call as "no reusable workflow at
    # all", which is the same class of false negative this check exists to
    # remove.
    kit_jobs = {
        name: job
        for name, job in jobs.items()
        if isinstance(job, dict)
        and ("cafaye/kit" in str(job.get("uses", "")) or str(job.get("uses", "")).startswith("./"))
    }
    if not kit_jobs:
        problems.append(
            ".github/workflows/ci.yml calls no reusable workflow: kit does not run "
            "its own gate in CI"
        )
    for name, job in kit_jobs.items():
        if job.get("uses") != local:
            problems.append(
                f".github/workflows/ci.yml job {name}: `uses: {job.get('uses')}` — "
                f"kit must call its own workflow with `{local}`, so the job proves "
                f"the local path resolves instead of fetching some other ref from "
                f"the network"
            )

# --- 5: one copy, at the reachable path -------------------------------------
# Walked rather than globbed, because the whole failure mode is a file parked
# somewhere the documented path does not point. `.git` and the gate's own
# gitignored `.venv` are the only trees skipped; everything else is fair game.
copies = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [
        # tests/.bin is the gate's own fetched scanners (hadolint, gitleaks).
        # It is gitignored and a throwaway copy carries it, and a 15MB binary is
        # not a file to read the first 64KB of looking for a YAML key.
        d for d in dirnames if d not in (".git", ".venv", ".bin", "__pycache__")
    ]
    for filename in filenames:
        full = os.path.join(dirpath, filename)
        rel = os.path.relpath(full, root)
        if rel == workflow:
            continue
        # shell scripts are excluded for the same reason, and because the
        # walker's own self_test.sh names `workflow_call` in a comment explaining
        # breakage 8 — which this check reported as a second copy of the CI
        # standard. A check that fires on the file proving it wrong is a check
        # that gets deleted.
        if filename.endswith((".sh", ".toml", ".md", ".pyc")):
            continue
        try:
            with open(full, encoding="utf-8") as fh:
                head = fh.read(65536)
        except (OSError, UnicodeDecodeError):
            continue
        if "workflow_call" not in head:
            continue
        # A third-party reference in a comment is not a copy.
        if re.search(r"^\s*workflow_call\s*:", head, re.M):
            copies.append(rel)

if copies:
    problems.append(
        f"a second workflow declaring `workflow_call` exists at {copies}. Two copies "
        f"of the CI standard is the drift kit exists to prevent, and only "
        f"{workflow} is reachable by a caller"
    )

if problems:
    sys.exit("; ".join(problems))
PY3
  }
  check "$WORKFLOW  (callable: exists, on: workflow_call, docs agree)" callable_check

  # -------------------------------------------------------------------------
  # Secrets. Two scanners and two different questions, and this section is the
  # part of the gate that proves both of them can fail.
  #
  # gitleaks answers "was a secret committed"; the canary harness answers "does
  # one leave the process while the tests run". Neither is a substitute for the
  # other, and the second has no off-the-shelf implementation at all — see
  # templates/secrets/README.md for the measurement behind that.
  #
  # The scanner runs in `secrets` / `zizmor`-style jobs in the reusable workflow,
  # and ALSO here, because a check that only runs in a CI runner is a check whose
  # first execution is on a stranger's commit. `bash tests/validate.sh` is the
  # whole procedure on a clean clone, and this is part of it.
  # The gitleaks config check needs tomllib (python 3.11+). Resolved ONCE, here,
  # so that a machine without it gets one honest FAIL that names the cause rather
  # than five separate "could not parse" failures that read as five defects.
  HAVE_TOMLLIB=1
  if ! "$PY" -c 'import tomllib' >/dev/null 2>&1; then
    HAVE_TOMLLIB=0
  fi

  section 'static: secrets — the scanner is present, configured, and can fail'

  # The scanner is RESOLVED FIRST, before any check that executes it.
  #
  # Ordering, and it is not cosmetic: the behavioural check below runs the scan
  # against a throwaway repository, so it needs a binary. Resolving afterwards
  # meant the check read an unset variable and reported "unbound variable" —
  # which is a FAIL for the wrong reason, and a FAIL nobody can act on.
  #
  # A FAIL and not a SKIP when gitleaks cannot be installed, for the reason the
  # hadolint check gives: a gate that reports "I could not check" and exits 0 is
  # the exact shape PLAN.md §1 calls a gate that is not green. It is also the
  # shape that let seven Dockerfiles go unlinted.
  GITLEAKS_BIN=''
  if [ -n "${KIT_GITLEAKS:-}" ]; then
    GITLEAKS_BIN="$KIT_GITLEAKS"
  elif kit_bootstrap_binary gitleaks \
    "https://github.com/gitleaks/gitleaks/releases/download/v${KIT_GITLEAKS_VERSION}" \
    "$KIT_GITLEAKS_SHA256S" "$ROOT" \
    "gitleaks_${KIT_GITLEAKS_VERSION}_@ros@_@arch@.tar.gz" gitleaks; then
    GITLEAKS_BIN="$BIN"
    # Exported so the twenty-odd throwaway copies self_test makes share this
    # binary instead of each downloading its own 15MB archive. Same reasoning as
    # KIT_PYTHON, one level down: twenty downloads is twenty chances to fail for
    # a reason that has nothing to do with the breakage under test.
    export KIT_GITLEAKS="$BIN"
  else
    report FAIL 'gitleaks (required: could not be installed — see the note above)'
  fi

  gitleaks_config() {
    "$PY" - "$ROOT" "$GITLEAKS_CONFIG" "$HAVE_TOMLLIB" <<'PY'
import os
import sys

root, rel, have_tomllib = sys.argv[1], sys.argv[2], sys.argv[3]
path = os.path.join(root, rel)
problems = []

if not os.path.isfile(path):
    sys.exit(
        f"{rel} does not exist. gitleaks then runs on its DEFAULT rules with no "
        f"cafaye allowlist, which is a scan that looks configured and is not — "
        f"and the allowlist is the only part of it anyone wrote"
    )

# Parsed as TOML, not grepped. Resolved by the caller so a machine without
# tomllib gets one honest message instead of several that read as several
# defects — and a config nobody parsed is a config nobody is reading.
if have_tomllib != "1":
    sys.exit(
        f"{rel} could not be parsed: this python has no tomllib (3.11+). The file "
        f"exists and gitleaks will read it, but nothing in this gate has, and a "
        f"secret-scanner allowlist that no tool ever parses is not an allowlist"
    )
import tomllib

with open(path, "rb") as fh:
    try:
        doc = tomllib.load(fh)
    except Exception as exc:
        sys.exit(f"{rel} is not valid TOML: {exc}")

# The rules must be gitleaks' own. A repo that redefines a rule has taken
# responsibility for the regex, and the reason kit can be thirty lines instead of
# six thousand is that it does not.
if "rules" in doc:
    problems.append(
        f"{rel} defines its own [[rules]]. kit extends gitleaks' defaults "
        f"(extend.useDefault) so a new provider detection reaches thirteen repos "
        f"the day gitleaks ships it. A vendored rule set is a rule set that stops "
        f"receiving providers, which is a secret scanner that has stopped working"
    )

extend = doc.get("extend") or {}
if extend.get("useDefault") is not True:
    problems.append(
        f"{rel} does not set extend.useDefault = true, so the rules it runs are "
        f"whatever this file happens to declare — which is none of them"
    )

# R3: every allowlist entry carries a reason, and an entry with no reason is a
# failure. This is the ESLint reportUnusedDisableDirectives property and it is
# the load-bearing one: an allowlist that grows monotonically and is never pruned
# is not an allowlist, it is a deferred disclosure.
#
# A VAGUE reason fails too, and the minimum length is the whole mechanism. The
# failure mode this rule exists to prevent is not "someone forgot" — it is
# "someone typed `false positive` and moved on", and a presence check accepts
# that without noticing. 40 characters is short enough that every honest reason
# clears it and long enough that every non-reason does not.
MIN_REASON = 40
allowlists = doc.get("allowlists") or []
if not isinstance(allowlists, list):
    problems.append(f"{rel}: `allowlists` is not a list of tables")
    allowlists = []

for i, entry in enumerate(allowlists, 1):
    desc = (entry or {}).get("description") or ""
    if not desc.strip():
        problems.append(
            f"{rel}: allowlist entry #{i} has no description. Every entry is a "
            f"decision to accept that a scanner will keep reporting something, and "
            f"the decision needs a name on it — otherwise the next reader cannot "
            f"tell an accepted false positive from an accepted secret"
        )
    elif len(desc.strip()) < MIN_REASON:
        problems.append(
            f"{rel}: allowlist entry #{i} has a description of {len(desc.strip())} "
            f"characters, which is not a reason. State what is allowed AND why, in "
            f"at least {MIN_REASON} characters. `false positive` is not a reason: "
            f"it is the absence of one, and a presence check accepts it silently"
        )
    # An entry with nothing to allowlist is a no-op that reads like a decision.
    has_scope = any(
        entry.get(k) for k in ("paths", "pathsRegex", "regexes", "commits", "stopwords", "targetRules")
    )
    if not has_scope:
        problems.append(
            f"{rel}: allowlist entry #{i} has a description but no paths, "
            f"regexes, commits or stopwords — it allows nothing and says why, "
            f"which is the shape of a comment that will be mistaken for a rule"
        )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check "$GITLEAKS_CONFIG  (allowlist only, every entry reasoned)" gitleaks_config

  # R3's other half: an allowlist that also exists inline is an allowlist
  # nobody reviews. gitleaks takes `-i <file>`, and .gitleaksignore is the file
  # it reads. Neither may exist in the tree, because a scanner finding in a
  # throwaway copy would be silenced by a file the reviewer never saw.
  gitleaks_ignore_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import sys

root = sys.argv[1]
found = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in (".git", ".venv", "__pycache__")]
    for name in filenames:
        if name == ".gitleaksignore":
            found.append(os.path.relpath(os.path.join(dirpath, name), root))
if found:
    sys.exit(
        f"a .gitleaksignore exists at {found}. That is the inline allowlist: it "
        f"lives beside the scanner rather than in {os.path.basename(sys.argv[0])}'s "
        f"committed config, so it is invisible in review, unversioned, and gone the "
        f"next time someone runs the scanner by hand. Entries go in the committed "
        f"config, one per finding, each with a reason"
    )
PY
  }
  check 'no .gitleaksignore  (the allowlist is the committed config)' gitleaks_ignore_check

  # R1: --redact is load-bearing, and so is the scan's coverage.
  #
  # Asserted on the SOURCE of the scan script rather than on the workflow,
  # because the workflow does not contain the gitleaks command line — it calls
  # tests/gitleaks_gate.sh, which is the same script this gate runs. Asserting
  # on the workflow would be asserting that a comment mentions a flag.
  #
  # The check is that the flag is UNCONDITIONAL. A `--redact` that appears
  # inside an `if`, or behind a variable that a caller can set, is not
  # redaction; it is a default.
  # R1: --redact is load-bearing, and so is the scan's coverage.
  #
  # Asserted by EXECUTING the scan, not by reading it.
  #
  # The first version of this check grepped the script for `--redact`, and the
  # first version of that grep was defeated by a comment: `#   - --redact, always`
  # satisfies `grep -- --redact`, and the comment is a sentence explaining that
  # the flag is mandatory. A check that a comment satisfies is a check that
  # reports the comment. Self_test breakage 15 proved it — the flag removed, the
  # check still green — which is the only reason this is a behavioural assertion.
  #
  # So: run the scan against a tree that contains a detectable credential, and
  # read the OUTPUT. `--redact` is proven by the output not containing the secret
  # even though the scan found it.
  #
  # This is the reason the probe below is assembled from parts rather than
  # written out. The scan runs over the whole tree, and a probe committed as a
  # literal would make tests/validate.sh itself a gitleaks finding — so the real
  # tree's own scan goes red for a reason that has nothing to do with the tree.
  # That is not hypothetical: it is what happened the first time, and the gate
  # reported four leaks in the file that was planting them.
  probe_secret() {
    # GitLab's published PAT format sample — gitleaks' `gitlab-pat` rule, and a
    # documented example value rather than a live credential. Assembled from two
    # halves, neither of which is a credential on its own.
    printf 'glpat-%s' 'ABC123def456GHI789jkl012'
  }

  scan_behaviour_check() {
    "$PY" - "$ROOT" "$GITLEAKS_GATE" "${GITLEAKS_BIN:-}" <<'PY'
import os
import subprocess
import sys
import tempfile

root, gate, gitleaks = sys.argv[1], sys.argv[2], sys.argv[3]
problems = []

if not gitleaks or not os.access(gitleaks, os.X_OK):
    # Resolved above; reported there as its own FAIL. Nothing to add here, and
    # saying so is better than a second message about the same missing file.
    sys.exit(0)

work = tempfile.mkdtemp(prefix="kit-redact-")
try:
    # A throwaway git repository, because the history requirement needs one and a
    # directory scan would not exercise the same code path.
    def run(*cmd, **kw):
        return subprocess.run(cmd, capture_output=True, text=True, **kw)

    run("git", "init", "-q", work)
    run("git", "-C", work, "config", "user.email", "t@example.invalid")
    run("git", "-C", work, "config", "user.name", "t")

    secret = "glpat-" + "ABC123def456GHI789jkl012"
    with open(os.path.join(work, "config.toml"), "w", encoding="utf-8") as fh:
        fh.write('private_token = "%s"\n' % secret)
    run("git", "-C", work, "add", "-A")
    run("git", "-C", work, "commit", "-qm", "add")

    # The scan, exactly as the gate runs it, plus --verbose.
    #
    # --verbose is here for one reason: gitleaks names the rule that fired only
    # in verbose output, and a check that cannot say WHICH rule fired cannot
    # distinguish "the scanner works" from "the scanner failed for a reason
    # nobody has diagnosed yet". It is also the more dangerous output — verbose
    # prints the finding, the fingerprint and the entropy — so it is the right
    # place to prove that --redact holds when there is the most to redact.
    def scan():
        return run(
            "bash", os.path.join(root, gate), work, gitleaks, "--verbose"
        )

    res = scan()
    combined = res.stdout + res.stderr

    # 1. It must FIND the secret. Without this, everything below is vacuous: a
    #    scanner that finds nothing would pass a redaction assertion.
    if res.returncode == 0:
        problems.append(
            "the scan over a tree containing a GitLab-PAT-shaped string exited 0, "
            "so it did not detect it. The redaction assertions below would then be "
            "satisfied by a scanner that scans nothing"
        )
    if "gitlab-pat" not in combined:
        problems.append(
            "the scan exited non-zero but did not name the gitlab-pat rule. A scan "
            "that fails for an unstated reason is a scan whose next failure will be "
            "a mystery"
        )

    # 2. It must NOT PRINT it. This is the property. The exit code says the
    #    secret was found; the absence of the secret from the output says the
    #    report is safe to paste into an issue.
    if secret in combined:
        problems.append(
            "THE SCAN PRINTED THE SECRET IT FOUND. --redact is not being applied: "
            "a CI log is a place secrets go to be read, and the scanner finding a "
            "credential must never be the reason the credential is printed. The "
            "value is a format sample, not a live credential, so this run proves "
            "the mechanism and not a disclosure"
        )
    # And the verbose output specifically, which is where gitleaks prints the
    # finding and the fingerprint and would print the value if redaction were off.
    if "Secret:" in combined and "REDACTED" not in combined:
        problems.append(
            "the verbose scan printed a `Secret:` line with no REDACTED marker on "
            "it. --redact is meant to replace the value, not merely suppress the "
            "summary line"
        )

    # 3. It must read the FULL HISTORY. A secret that was committed and then
    #    deleted is the case that matters, and it is invisible to a HEAD-only or
    #    shallow scan.
    os.remove(os.path.join(work, "config.toml"))
    run("git", "-C", work, "add", "-A")
    run("git", "-C", work, "commit", "-qm", "remove")
    res = scan()
    combined = res.stdout + res.stderr
    if res.returncode == 0:
        problems.append(
            "after the credential was committed and then DELETED, the scan exited "
            "0. It is not reading history, or is reading only the last commit. A "
            "secret that was added and removed in one PR is still in the history "
            "and still on every fork — that is the finding that matters most"
        )
    if secret in combined:
        problems.append("the history scan printed the secret it found; --redact is not applied")
finally:
    subprocess.run(["rm", "-rf", work], capture_output=True)

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check "$GITLEAKS_GATE  (finds a real secret, never prints it, reads history)" \
    scan_behaviour_check

  # R2: `pull_request`, never `pull_request_target`.
  #
  # The trigger, not the prose. This reads the PARSED trigger keys of every
  # workflow in the tree, so the explanation in the header comment — which has
  # to exist, and which names the string — is not a violation. A grep would fail
  # on the file that documents why the thing is forbidden, which is how a check
  # gets deleted.
  #
  # The whole tree is read, not just the reusable workflow: kit's own ci.yml
  # chooses its triggers, and a service adopting kit writes its own caller. A
  # job is one click from being a credential-theft primitive, and the trigger is
  # the only thing that makes it one.
  trigger_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import sys

import yaml

root = sys.argv[1]
# `pull_request_target` runs in the context of the BASE repository, with that
# repository's secrets and a writable token, executing code proposed by a FORK.
# `workflow_run` and `issue_comment` have the same property for the same reason.
FORBIDDEN = {
    "pull_request_target": (
        "runs with the base repository's secrets and a writable token in the "
        "context of a FORK's code. Any job under it is a credential-theft "
        "primitive waiting for a reason, and the secret scanner is the job that "
        "most invites 'let me just pull the base branch in so the scan sees the "
        "real history'"
    ),
    "workflow_run": (
        "runs with the base repository's secrets, triggered by a run a FORK can "
        "cause. Same property as pull_request_target"
    ),
    "issue_comment": (
        "runs with repository secrets on an attacker-controlled payload — a "
        "comment body is not code, but it is input, and issue_comment handlers "
        "read it"
    ),
}

problems = []
workflows = os.path.join(root, ".github", "workflows")
if not os.path.isdir(workflows):
    problems.append("no .github/workflows directory, so no trigger was checked")

for name in sorted(os.listdir(workflows)) if os.path.isdir(workflows) else []:
    if not name.endswith((".yml", ".yaml")):
        continue
    rel = f".github/workflows/{name}"
    with open(os.path.join(workflows, name), encoding="utf-8") as fh:
        try:
            doc = yaml.safe_load(fh)
        except Exception as exc:
            problems.append(f"{rel} is not valid YAML: {exc}")
            continue
    if not isinstance(doc, dict):
        continue
    # `on:` is read by PyYAML 1.1 as the boolean True.
    triggers = doc.get("on") or doc.get(True) or {}
    if isinstance(triggers, str):
        found = {triggers}
    elif isinstance(triggers, list):
        found = set(triggers)
    elif isinstance(triggers, dict):
        found = set(triggers)
    else:
        found = set()
    for trigger in sorted(found & FORBIDDEN.keys()):
        problems.append(f"{rel} declares `on: {trigger}`. {FORBIDDEN[trigger]}")

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check '.github/workflows/*  (no dangerous trigger, on parsed keys)' trigger_check

  # R4: unpinned-uses is recorded, never baselined.
  #
  # The finding is real, the trade is real, and the costed options are in
  # DECISIONS.md under MD10. What must NOT happen is the trade being made
  # invisibly, in a file that looks like routine configuration — which is what
  # adding it to zizmor's ignore list would be.
  #
  # So: zizmor's config must not ignore or disable it, and must not disable
  # audits wholesale. `tests/zizmor_gate.sh` counts it instead, and prints the
  # count on every run.
  unpinned_check() {
    "$PY" - "$ROOT" "$ZIZMOR_CONFIG" <<'PY'
import os
import sys

import yaml

root, rel = sys.argv[1], sys.argv[2]
path = os.path.join(root, rel)
problems = []

if not os.path.isfile(path):
    # Absent is the preferred state, and is asserted as one below.
    print(f"note: no {rel}; nothing is baselined, which is the correct state")
    sys.exit(0)

with open(path, encoding="utf-8") as fh:
    try:
        doc = yaml.safe_load(fh)
    except Exception as exc:
        sys.exit(f"{rel} is not valid YAML: {exc}")

rules = (doc or {}).get("rules") or {}
rule = rules.get("unpinned-uses") or {}
if rule.get("disable") is True:
    problems.append(
        f"{rel} DISABLES unpinned-uses. The trade it would be suppressing is real "
        f"and is costed in DECISIONS.md under MD10 — pinning thirteen repositories "
        f"to SHAs and owning the bump is not free, and not pinning means a change "
        f"to kit's workflow lands in six services' CI without review. Suppressing "
        f"it HERE makes that trade invisibly, in a file whose only other purpose "
        f"is a different trade. Record it instead: tests/zizmor_gate.sh counts "
        f"and prints every unpinned-uses finding on every run"
    )
if rule.get("ignore"):
    problems.append(
        f"{rel} IGNORES specific unpinned-uses findings ({rule['ignore']}). Same "
        f"reason as above: a per-line allowlist for this audit is a baseline with "
        f"a diff, and a diff is easier to extend than a decision is to revisit"
    )

# A blanket baseline is the thing that turns a scanner into a report. Three of
# them, because a blanket can be spelled three ways.
for audit, conf in (rules or {}).items():
    if not isinstance(conf, dict):
        continue
    if conf.get("ignore") == "*" or conf.get("ignore") == ["*"]:
        problems.append(
            f"{rel}: rule {audit} ignores `*`. A blanket baseline means the audit "
            f"can never report anything again, which is not a stricter check — it "
            f"is the absence of one"
        )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check "$ZIZMOR_CONFIG  (unpinned-uses recorded, never baselined)" unpinned_check

  # Every zizmor ignore entry carries a reason.
  #
  # zizmor's own ignore syntax is `file.yml[:line[:column]]` with no place for a
  # reason, so the reason lives in an adjacent comment and this check is what
  # makes that a rule rather than a convention. A baseline with no reason is how a
  # scanner becomes a report one commit at a time.
  zizmor_reason_check() {
    "$PY" - "$ROOT" "$ZIZMOR_CONFIG" <<'PY'
import os
import re
import sys

root, rel = sys.argv[1], sys.argv[2]
path = os.path.join(root, rel)
if not os.path.isfile(path):
    sys.exit(0)

lines = open(path, encoding="utf-8").read().splitlines()
problems = []

# A list item under a `rules.<id>.ignore:` block.
in_ignore = False
item_indent = None
for i, line in enumerate(lines, 1):
    stripped = line.strip()
    if re.match(r"^ignore:\s*$", stripped):
        in_ignore = True
        continue
    if in_ignore:
        if not stripped or stripped.startswith("#"):
            # A comment is the reason, or part of it. Looked at below, not here.
            continue
        if stripped.startswith("- "):
            indent = len(line) - len(line.lstrip())
            if item_indent is None:
                item_indent = indent
            if indent != item_indent:
                # Dedented out of the list.
                in_ignore = False
                continue
            # Does this entry have a reason? Any of: a comment on the same line,
            # or one or more comment lines directly above with nothing between.
            above = []
            j = i - 2
            while j >= 0:
                prev = lines[j].strip()
                if not prev:
                    break
                if not prev.startswith("#"):
                    break
                above.append(prev)
                j -= 1
            if "#" in line.split("- ", 1)[1]:
                continue  # trailing comment
            if not above:
                problems.append(
                    f"{rel}:{i}: ignore entry {stripped!r} has no reason. A "
                    f"baseline with no stated reason is how a scanner becomes a "
                    f"report one commit at a time: the next reader cannot tell an "
                    f"accepted false positive from a deferred one"
                )
        else:
            in_ignore = False

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check "$ZIZMOR_CONFIG  (every ignore entry carries a reason)" zizmor_reason_check

  # The scanner itself, executed over kit's own tree and full history. The
  # behaviour is asserted by the check above; this is the real scan of the real
  # repository, which is the only one that can report a secret that is actually
  # in this repository's history.
  if [ -n "$GITLEAKS_BIN" ]; then
    if out=$(bash "$ROOT/$GITLEAKS_GATE" "$ROOT" "$GITLEAKS_BIN" 2>&1); then
      report PASS "gitleaks  ($KIT_GITLEAKS_VERSION, full history, --redact)"
    else
      report FAIL "gitleaks  ($KIT_GITLEAKS_VERSION, full history, --redact)"
      printf '%s\n' "$out" | sed 's/^/       /'
    fi
  fi

  # -------------------------------------------------------------------------
  # The canary harness: the artifacts, and the contract they implement.
  section 'static: the canary harness — contract, adapter, and every artifact'
  secrets_readme_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import re
import sys

root = sys.argv[1]
problems = []

# The contract. Language-neutral and in the tree, because a canary test that
# only exists for Go protects one of six services — so the thing every adapter
# must implement is kit's to own, and it is a document rather than an
# implementation.
contract = os.path.join(root, "templates", "secrets", "README.md")
if not os.path.isfile(contract):
    problems.append(
        "templates/secrets/README.md does not exist. The contract is language-"
        "neutral on purpose: without it there is nothing for a second adapter to "
        "implement, and six adapters invent six different checks"
    )
else:
    body = open(contract, encoding="utf-8").read()
    # All five vectors, named. Not "at least five" — the names are the contract,
    # and a rename that left one behind would otherwise be invisible.
    for vector in (
        "canary",
        "unknown-field",
        "stringified-error",
        "absent-field",
        "type coverage",
    ):
        if vector not in body:
            problems.append(f"templates/secrets/README.md does not name the {vector!r} vector")

    # The safety property. A canary that is not safe to commit is worse than no
    # canary, so the contract has to say how this one is safe — and the reason is
    # not "it is obviously fake", it is that the value is BUILT.
    if "cafaye_canary_" not in body:
        problems.append(
            "templates/secrets/README.md never states the canary prefix, so a "
            "reader cannot tell a planted canary from a real credential in a log"
        )
    if "assembled" not in body and "built at run time" not in body:
        problems.append(
            "templates/secrets/README.md does not say the canary is assembled at "
            "run time. That is the property that makes it safe to commit, and it "
            "is the reason .gitleaks.toml needs no entry for it"
        )

    # The honesty requirement. A harness whose limits are undocumented is a
    # harness whose limits are discovered in production.
    for phrase, why in (
        ("not covered", "a harness that does not say what it cannot see"),
        ("type check, not a call-graph check", "vector 5's real limitation"),
    ):
        if phrase not in body.lower():
            problems.append(
                f"templates/secrets/README.md does not say {why!r} "
                f"(looked for {phrase!r})"
            )

# The Go adapter's artifacts. Presence only — the suite is EXECUTED in the
# telemetry phase below, which is the check that can catch a broken one.
go_dir = os.path.join(root, "templates", "secrets", "go")
for rel in (
    "canary.go",
    "sweep.go",
    "typecover.go",
    "canary_test.go",
    "typecover_test.go",
    "print_shape_test.go",
    "go.mod",
    "README.md",
    os.path.join("internal", "safe", "creds.go"),
    os.path.join("internal", "leaky", "creds.go"),
):
    if not os.path.isfile(os.path.join(go_dir, rel)):
        problems.append(f"templates/secrets/go/{rel} is missing")

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'templates/secrets  (contract names all five vectors, states its limits)' \
    secrets_readme_check

  # The canary itself, asserted from OUTSIDE the Go suite as well as inside it.
  #
  # Two checks of one property is not redundancy here: the Go suite proves the
  # value is not committed as a literal *in the template*, and this proves it is
  # not committed as a literal *anywhere in the tree*, which is the property the
  # scanner depends on. A future file outside the template is exactly where it
  # would appear.
  canary_literal_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import sys

root = sys.argv[1]

# The same assembly the Go adapter performs, reproduced here rather than
# imported. If the two ever disagree, one of them is wrong and the gate says so
# instead of a canary being half-planted in CI and half in the gate.
prefix = "cafaye_canary_"
body = "notarealsecret"
canary = prefix + (body * 3)[:32]

hits = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in (".git", ".venv", "__pycache__")]
    for name in filenames:
        full = os.path.join(dirpath, name)
        rel = os.path.relpath(full, root)
        try:
            with open(full, encoding="utf-8") as fh:
                body_text = fh.read()
        except (OSError, UnicodeDecodeError):
            continue
        if canary in body_text:
            hits.append(rel)

if hits:
    sys.exit(
        f"the assembled canary appears as a literal in {hits}. Build it, do not "
        f"write it: a committed credential-shaped string is a finding every "
        f"scanner in the world will make, and allowlisting it teaches the next "
        f"reader that allowlisting a credential is normal. The Go suite asserts "
        f"the same property for templates/secrets/go; this catches it anywhere "
        f"else in the tree"
    )
PY
  }
  check 'the canary  (never committed as a literal, anywhere)' canary_literal_check

  # The canary is safe to commit, which means it must never be a plausible real
  # credential. The prefix is the first half of that; this is the second, and it
  # is checked against the scanner itself rather than against a regex: if
  # gitleaks does not flag it, it is not a plausible real credential as far as
  # anything in this repository is concerned.
  canary_safety_check() {
    "$PY" - "$ROOT" "$KIT_GITLEAKS_VERSION" <<'PY'
import sys

version = sys.argv[1]
prefix = "cafaye_canary_"
canary = prefix + ("notarealsecret" * 3)[:32]

# Structural properties, asserted here because they are properties of the VALUE
# rather than of any Go code, and the gate should not have to run Go to know
# whether the thing it is sweeping for is safe to commit.
if not canary.startswith(prefix):
    sys.exit("the canary does not carry its prefix")
if len(canary) != len(prefix) + 32:
    sys.exit(f"the canary is {len(canary)} bytes; the contract says prefix + 32")
if "notarealsecret" not in canary:
    sys.exit(
        "the canary has no human-readable 'this is fake' component. A value that "
        "merely LOOKS random is one a reader mistakes for a real credential"
    )

# The shape a real credential does not have, and the one thing that would make
# this dangerous: high entropy. A real 32-byte token is indistinguishable from
# random; this is 32 bytes of one repeated word, which no real token ever is and
# which no entropy-based detector will ever score.
# The property that makes it safe to commit: the body is ONE REPEATED WORD.
#
# Not "low entropy" — an entropy THRESHOLD is the wrong instrument, and the
# first version of this check used one (8 distinct bytes) and failed on its own
# canary, which has 9. A threshold is also a number somebody will tune upwards
# the first time it is inconvenient, and a fake credential tuned to pass an
# entropy filter is not a fake credential.
#
# The property is structural and there is nothing to tune: the body must BE the
# repeated word, so no detector that scores entropy can score it as random, and
# so it is obvious to a human reading a CI log at 3am.
body_expected = ("notarealsecret" * 3)[:32]
if canary[len(prefix):] != body_expected:
    sys.exit(
        "the canary body is not the repeated word the contract specifies, so it "
        "is no longer unmistakably fake. A high-entropy canary is "
        "indistinguishable from a real credential to any detector that scores "
        "entropy, which is most of them"
    )
print(f"gitleaks {version}: the canary is prefixed, low-entropy, and self-describing")
PY
  }
  check 'the canary  (unmistakably fake: prefixed, low-entropy, self-describing)' \
    canary_safety_check

  # The gate's own output, swept for the canary.
  #
  # Not paranoia: it happened. `TestTheReferenceTypeLeaksUnderBadVerbs` logs an
  # example of what a leaking format verb produces, and the example contained the
  # canary — on every green run, in the line that exists to document a leak. It
  # is the fake canary, so nothing was disclosed, and that is exactly why it
  # needs a check: the day this harness is pointed at a real credential, the same
  # habit is a disclosure, and a habit is what survives a refactor.
  #
  # The check runs the canary suite, captures EVERYTHING it writes — stdout and
  # stderr, pass and fail — and asserts the value is in none of it. It is a
  # separate check from the suite's own rather than a line inside it because the
  # suite cannot observe its own output: `go test` buffers it.
  canary_output_check() {
    local out ec=0
    if ! have go; then
      echo "go is not installed, so there is no output to sweep" >&2
      return 1
    fi
    out="$(cd "$ROOT/templates/secrets/go" &&
      GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local go test -v -count=1 ./... 2>&1)" || ec=$?

    local needle
    needle="$("$PY" -c '
prefix = "cafaye_canary_"
print(prefix + ("notarealsecret" * 3)[:32])
')"
    if [ -n "$needle" ] && printf '%s\n' "$out" | grep -qF -- "$needle"; then
      echo "the canary suite printed the value it planted. The harness must never print the" >&2
      echo "thing it is sweeping for: a report of a leak that carries the leak is a leak." >&2
      echo "The offending lines, with the value redacted:" >&2
      printf '%s\n' "$out" | grep -F -- "$needle" |
        sed "s|$needle|cafaye_canary_REDACTED|g" | sed 's/^/  /' >&2
      return 1
    fi

    # The suite's own status, restated. Running it twice is cheap (stdlib, no
    # network) and the alternative is a check that passes because the suite
    # crashed before producing output — which is a check that cannot fail.
    if [ "$ec" -ne 0 ]; then
      printf '%s\n' "$out" | tail -20 | sed 's/^/       /' >&2
      return 1
    fi
    return 0
  }
  check 'the canary suite  (never prints the value it planted)' canary_output_check
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

  # -------------------------------------------------------------------------
  # The canary harness, EXECUTED.
  #
  # Same reasoning as the traceparent suites above, and it is the reason this is
  # in the telemetry phase rather than only in the static one: a canary harness
  # that is only grepped is a harness that has never run a detector.
  #
  # `-v` is not decoration. Every vector prints a RED PROOF line, and a proof
  # nobody can see is a proof nobody ran — the same argument the self_test phase
  # makes, applied to the harness instead of to the gate.
  section 'telemetry: runtime credential-leak canary, executed'

  run_canary() {
    (
      cd "$ROOT/templates/secrets/go"
      GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local go test -v -count=1 ./...
    )
  }
  if have gofmt; then
    if [ -z "$(gofmt -l "$ROOT"/templates/secrets/go/*.go "$ROOT"/templates/secrets/go/internal/*/*.go 2>&1)" ]; then
      report PASS 'templates/secrets/go/*.go  (gofmt clean)'
    else
      report FAIL 'templates/secrets/go/*.go  (gofmt clean)'
      gofmt -l "$ROOT"/templates/secrets/go/*.go "$ROOT"/templates/secrets/go/internal/*/*.go | sed 's/^/       /'
    fi
  else
    report SKIP 'gofmt (not installed)'
  fi

  if have go; then
    # `check_verbose`, not `check`: the five RED PROOF lines are the evidence
    # that each detector fired. On a green run they are the ONLY output, and a
    # gate that proves the gate can fail while hiding the proofs is making the
    # argument in one file and breaking it in the next.
    check_verbose 'templates/secrets/go  (five vectors, each with a red proof)' \
      'RED PROOF|known and accepted' run_canary
  else
    report SKIP 'templates/secrets/go  (go not installed)'
  fi
fi

# ===========================================================================
# phase: self_test — prove the gate can go red
# ===========================================================================

if [ "$RUN_SELF_TEST" -eq 1 ]; then
  section 'self_test: this gate is able to fail'
  # The label deliberately does not name a count. It used to say "eighteen
  # breakages, eighteen reds", and that number was a literal in two files that
  # had to be kept in step by hand — so the first packet to add a breakage
  # without updating both printed a claim that was no longer true while every
  # check stayed green. self_test derives the count from the breakages it
  # actually ran and prints it; this label points at that.
  #
  # `check_verbose` for the same reason as the canary suite: the list of
  # breakages that went red IS the evidence, and on a green run a plain `check`
  # would print one line and throw the rest away. A self_test whose output nobody
  # reads is a self_test that could be printing four breakages and the badge
  # would be exactly the same green.
  check_verbose 'tests/self_test.sh  (every breakage red, unbroken tree green)' \
    '^PASS self_test:' bash "$ROOT/tests/self_test.sh"
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
