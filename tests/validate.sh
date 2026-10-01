#!/usr/bin/env bash
#
# kit's entire test suite. kit is config-only — no runtime code, no library —
# so there is nothing to exercise. The test is that every artifact a service
# repo copies or calls actually parses, and that the telemetry templates
# actually propagate a traceparent.
#
#   bash tests/validate.sh                     # the gate: every phase
#   bash tests/validate.sh --static-only       # parse/semantic checks only (fast)
#   bash tests/validate.sh --language=go       # one telemetry language (CI matrix)
#   bash tests/validate.sh --no-self-test      # skip the "can this go red" proof
#   bash tests/validate.sh --no-observability  # skip the two docker-requiring proofs
#
# Four phases, all of which must pass:
#   static         every artifact parses, and the strictness decisions are still
#                  what we wrote them down to be (env-substituted endpoints, every
#                  compose port parameterized, every placeholder documented, and
#                  the collector's redaction allowlist DERIVED FROM core's
#                  schemas rather than transcribed beside them).
#   telemetry      the W3C traceparent templates are EXECUTED, one suite per
#                  language. This is the phase that is easy to fake and so is
#                  the one that runs the code rather than greps it.
#   observability  the two claims that are worth nothing unexercised: that a
#                  canary secret in a prompt-shaped attribute reaches no
#                  exporter, and that a service starts and serves with the
#                  collector killed. Both need a real collector, so both SKIP
#                  loudly without docker — never pass silently.
#   self_test      breaks a throwaway copy of this tree once per kind of check
#                  and asserts the gate goes red each time. A gate that cannot
#                  fail is not a gate.
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
RUN_OBSERVABILITY=1
LANGS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --static-only)
      RUN_TELEMETRY=0
      RUN_SELF_TEST=0
      RUN_OBSERVABILITY=0
      ;;
    --no-self-test) RUN_SELF_TEST=0 ;;
    --no-observability) RUN_OBSERVABILITY=0 ;;
    --language=*)
      LANGS+=("${1#*=}")
      ;;
    -h | --help)
      sed -n '2,26p' "$0"
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
    # A check that reports WHICH SPEC it verified is a different statement from
    # one that only reports that it passed. core_check prints the resolved core
    # commit and the spec version precisely so "it passed" is anchored to
    # something a future reader can re-run — and swallowing its output on PASS
    # made that line unreachable in the only case it matters. Most checks print
    # nothing when they succeed, so this is silent for everything else.
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | sed 's/^/       /'
    fi
  else
    report FAIL "$label"
    printf '%s\n' "$out" | sed 's/^/       /'
  fi
}

section() { printf '\n-- %s\n' "$1"; }

have() { command -v "$1" >/dev/null 2>&1; }

# The ruby interpreter floor, read FROM THE TEMPLATE it applies to.
#
# `templates/otel/ruby` calls `Enumerable#filter_map`, which arrived in ruby 2.7.
# The macOS system interpreter at /usr/bin/ruby is 2.6, so a gate that runs the
# suite on whatever `ruby` happens to be first on PATH gets three
# NoMethodErrors and reports them as `FAIL templates/otel/ruby` — blaming the
# template for an interpreter it chose. That is not a cosmetic mislabel: the red
# it printed was attributed to three unrelated packets, and none of them could
# fix it, because none of them touched the template either.
#
# The floor comes from `KitOtel::RUBY_FLOOR` rather than a literal here. A
# version restated in the runner is a second place for it to rot, and the artifact
# is the thing that actually knows. Reading it also means the file and the gate
# cannot disagree about what the file needs — the same reason the classifier's
# tier lives in rules.json and nowhere else.
#
# Empty output means the template could not be loaded far enough to be asked, and
# the caller treats that as a template defect rather than an absent interpreter.
ruby_floor() {
  ruby -e 'require ARGV[0]; print KitOtel::RUBY_FLOOR' \
    "$ROOT/templates/otel/ruby/traceparent.rb" 2>/dev/null
}

# Is dotted version $1 at least dotted version $2?
#
# Hand-rolled rather than `sort -V`, and that choice is load-bearing rather than
# fussy: `-V` is a GNU coreutils extension that older BSD sort does not have,
# and a gate whose floor comparison degrades to a *string* compare on the sort
# shipped with macOS is a gate that reads "2.10" < "2.9" on one machine and not
# on another. Two of the six toolchains here are only ever run by developers, so
# "worked on my sort" is not a portability story.
#
# Refuses on an unparseable field instead of assuming the version is new enough:
# fail-closed is the whole lesson of this repo's classifier, and it applies to a
# shell comparison just as much.
version_at_least() {
  local have_v="$1" want_v="$2" i a b
  for i in 1 2 3; do
    a="$(printf '%s' "$have_v" | cut -d. -f"$i")"; a="${a:-0}"
    b="$(printf '%s' "$want_v" | cut -d. -f"$i")"; b="${b:-0}"
    case "$a$b" in
      '' | *[!0-9]*) return 1 ;;
    esac
    if [ "$a" -eq "$b" ]; then
      continue
    fi
    if [ "$a" -gt "$b" ]; then
      return 0
    fi
    return 1
  done
  return 0
}

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
    "$ROOT"/templates/bin/* "$ROOT"/templates/tier/*/* "$ROOT"/tests/*.sh; do
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
      # The tier templates. Each of these is a file a service COPIES, so each
      # has to parse in its own language — the rule is "parse what you hand
      # out", and `rack_middleware.rb.snippet` shipped with syntax that was not
      # Ruby because nothing checked the extension kit gave it.
      #
      # Rust is compiled rather than parsed, and that is deliberate: `tier.rs`
      # is one self-contained crate, exactly like `templates/otel/rust/`, so
      # `rustc --test` is both the parse and the strongest check available
      # without inventing a module layout kit has no use for.
      "$ROOT"/templates/tier/rust/*.rs)
        if have rustc; then
          check "$path  (rustc --test)" bash -c \
            "rustc --test --edition 2021 -o \"$TMP/kit-tier-rust\" '$f' && '$TMP/kit-tier-rust' --list >/dev/null"
        else
          report SKIP "$path  (rustc not installed)"
        fi
        ;;
      "$ROOT"/templates/tier/python/*.py)
        if have python3; then
          # `compile()`, not `python3 -m py_compile`. The module form writes a
          # `__pycache__/` into the SOURCE tree, and that directory is then
          # picked up by two other checks that iterate this one — which is how a
          # gate that started green went red on its own artefacts. `compile()`
          # is the same parse with no filesystem side effect at all.
          check "$path  (compile)" python3 -c \
            'import sys; compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec")' "$f"
        else
          report SKIP "$path  (python3 not installed)"
        fi
        ;;
      "$ROOT"/templates/tier/ruby/*.rb)
        if have ruby; then
          check "$path  (ruby -c)" ruby -c "$f"
        else
          report SKIP "$path  (ruby not installed)"
        fi
        ;;
      "$ROOT"/templates/tier/elixir/*.ex)
        if have elixir; then
          # `elixir -c` is not a thing. `Code.string_to_quoted/1` is the
          # stdlib parse, it is offline, and it reports the same syntax errors
          # the compiler would — which is the property being asserted.
          check "$path  (Code.string_to_quoted!)" elixir -e \
            'case Code.string_to_quoted(File.read!(hd(System.argv()))) do
               {:error, e} -> IO.puts("syntax: #{inspect e}"); System.halt(1)
               {:ok, _} -> :ok
             end' "$f"
        else
          report SKIP "$path  (elixir not installed)"
        fi
        ;;
      "$ROOT"/templates/tier/go/*.go)
        # gofmt is run over the whole tree's Go templates in the telemetry phase
        # below, so it is deliberately not reported twice here. `go build` would
        # need a module kit does not have, and `go vet` needs one too — the
        # format check is the real check, and it is where Go's own parser is
        # unhappy.
        ;;
      "$ROOT"/templates/tier/*/*.ts)
        # Stock `node --check` does not read TypeScript, and a service copying
        # this file gets TypeScript. Reported as a SKIP with its reason rather
        # than passed over: a skip nobody can see is a gap nobody fixes, and the
        # summary line is how this class of gap is found. The fix is a
        # type-stripping parser, which is a dependency, and kit is config-only.
        report SKIP "$path  (node --check cannot read TypeScript; needs a type-stripping parser)"
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

  # Elixir, which kit-02 did not check and should have. A `.ex` file compiles at
  # LOAD time, so `Code.require_file` is a parser for it — and it is the only
  # thing that could have caught what this packet's rewrite actually contained
  # before it shipped: a `Logger.log` call with a keyword list followed by a
  # `"key" => value` pair, which is a hard SyntaxError in Elixir and an entirely
  # ordinary-looking line in every other language.
  #
  # The traceparent codec is required first so the file has no cross-file
  # dependency, and a load that reports *warnings* about the OTel modules it
  # cannot find is a PASS: kit has no mix.exs and no deps, and a warning about a
  # missing `:opentelemetry` is exactly what a dependency-free kit should
  # produce. Only a real compile error fails — and the two shapes are counted
  # rather than grepped for the word "error", because the warnings above contain
  # that word too and a check that cannot tell a warning from an error is a
  # check that fails on a clean file.
  if have elixir; then
    ex_copy="$snippet_dir/phoenix_telemetry.ex"
    cp "$ROOT/templates/otel/elixir/phoenix_telemetry.ex.snippet" "$ex_copy"
    ex_out="$(elixir -r "$ROOT/templates/otel/elixir/traceparent.ex" "$ex_copy" 2>&1 || true)"
    if printf '%s\n' "$ex_out" | grep -qE '\*\* \((Compile|Syntax)Error\)|^\s*error:'; then
      report FAIL 'otel/elixir/phoenix_telemetry.ex.snippet  (parses as .ex)'
      printf '%s\n' "$ex_out" | head -8 | sed 's/^/       /'
    else
      report PASS 'otel/elixir/phoenix_telemetry.ex.snippet  (parses as .ex)'
    fi
  else
    report SKIP 'otel/elixir/phoenix_telemetry.ex.snippet  (elixir not installed)'
  fi

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
  section 'static: compose — the observability chokepoint'
  # Privacy boundary, enforced. REWRITTEN in kit-03, and the change is recorded
  # here rather than smuggled. The boundary used to be "the only exporter is
  # `debug`, which cannot leave the machine". Observability being ON BY DEFAULT
  # (PLAN.md §7b) means the shipped collector now fans out to Tempo, Loki and
  # Mimir, so "ships nothing" is no longer the claim this file can make.
  #
  # The claim that CAN be made, and is asserted on the parsed document:
  #
  #   1. every exporter endpoint is a ${env:...} substitution, never a literal.
  #      A literal endpoint is an endpoint some laptop will use by default, and
  #      it is the one shape that turns a privacy boundary into an incident.
  #   2. every pipeline runs a redaction processor, BEFORE batch and therefore
  #      before every exporter. Filter before export, never after: a redaction
  #      step that runs after an exporter has already handed the data off is a
  #      comment, and the comment is what a future reader trusts.
  #   3. the exporter set is exactly the three backends plus the local `debug`.
  #
  # (1) is kit-02's rule and is unchanged. (2) and (3) are new, and (3) is why
  # a self-hoster's bring-your-own backend is a variable they set rather than an
  # exporter a reviewer has to read: <SERVICE>_OTEL_ENDPOINT points their service
  # somewhere else entirely and this stack goes quiet.
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

exporters = doc.get("exporters") or {}
for name, cfg in exporters.items():
    if not isinstance(cfg, dict):
        continue
    for key in ("endpoint", "traces_endpoint", "metrics_endpoint", "logs_endpoint"):
        value = cfg.get(key)
        if isinstance(value, str) and "${env:" not in value:
            problems.append(f"exporter {name}.{key} is a literal endpoint, not an ${{env:}} substitution")

# The shipped stack is EXACTLY the three backends plus the local `debug`. Anything
# else is an exporter a reviewer did not read, and `otlp` with a *defaulted*
# endpoint is the exact shape of that mistake.
#
# The backend set and the component type are asserted SEPARATELY, and the second
# one was wrong as first written. This check originally pinned the literal set
# {"otlp/tempo", "otlp/loki", "otlp/mimir", "debug"} — all three gRPC — and went
# red against a correct config, because the three backends do NOT agree on wire
# protocol: Tempo accepts OTLP over gRPC on :4317, while Loki's and Mimir's native
# OTLP receivers are HTTP-only, mounted at `/otlp` on :3100 and :8080. A gRPC
# exporter pointed at either of them fails to connect, which is a broken stack
# that still satisfies "the only exporter is debug".
#
# So the claim under test is "these three backends and nothing else", and the
# transport is a property of the backend rather than part of the name. Asserting
# `(otlp|otlphttp)/<one of the three>` keeps that claim exactly as tight while
# letting each backend be spoken to in the dialect it speaks.
BACKENDS = {"tempo", "loki", "mimir"}
unknown = []
for name in exporters:
    if name == "debug":
        continue
    kind, sep, backend = name.partition("/")
    if not sep or kind not in ("otlp", "otlphttp") or backend not in BACKENDS:
        unknown.append(name)
if unknown:
    problems.append(
        "unexpected exporter(s): "
        + ", ".join(unknown)
        + " — the shipped stack is tempo, loki, mimir and the local debug. A "
        "bring-your-own backend is an ${env:} endpoint, never a new exporter."
    )

# ...and the converse, which the literal set above never checked. A config whose
# exporters are only `debug` satisfies "nothing unexpected" while shipping no
# observability at all, so a check written as a set difference alone passes on a
# stack that collects everything and prints it. Asserted per signal below that
# every pipeline has exporters, but that is a different claim: a pipeline can
# point at `debug` alone and still be a pipeline. This is the one that says the
# three backends are actually wired.
for backend in sorted(BACKENDS):
    if not any(n.partition("/")[2] == backend for n in exporters):
        problems.append(
            f"no exporter for {backend}: the shipped stack is three backends, and a "
            "config with only `debug` is a stack that collects everything and "
            "prints it rather than storing it"
        )

# The ordering, per pipeline. "The config has a redaction processor somewhere"
# is exactly the check that passes while the metrics pipeline ships unredacted,
# so the assertion is per pipeline and positional.
for signal, pipe in pipelines.items():
    if not isinstance(pipe, dict):
        continue
    if not pipe.get("receivers"):
        problems.append(f"{signal} pipeline has no receivers")
    raw = pipe.get("processors") or []
    if "memory_limiter" not in raw:
        problems.append(f"{signal} pipeline has no memory_limiter")
    elif raw[0] != "memory_limiter":
        problems.append(
            f"{signal} pipeline starts with {raw[0]!r}, not memory_limiter"
        )
    if "batch" not in raw:
        problems.append(f"{signal} pipeline has no batch processor")
    redactions = [i for i, p in enumerate(raw) if p.startswith("redaction/")]
    if not redactions:
        problems.append(
            f"{signal} pipeline has no redaction processor: a signal with no "
            f"boundary reads as a signal that has one"
        )
    if redactions and "batch" in raw and min(redactions) > raw.index("batch"):
        problems.append(
            f"{signal} pipeline redacts after batching, which is after the data "
            f"has already left the process"
        )
    # 3. SPAN EVENTS ARE OUT OF REACH. The redaction processor is specified over
    #    span/log/datapoint ATTRIBUTES; a span event carries its own attribute map
    #    at a different depth which it does not visit. So a service still writing
    #    the DEPRECATED `exception` span event ships `exception.message` and
    #    `exception.stacktrace` straight through a boundary with neither on its
    #    allowlist. Found by the canary test failing, not by reading the docs.
    if signal == "traces" and not any("span_event" in p for p in raw):
        problems.append(
            "the traces pipeline has no span-event transform, so exception.message "
            "and exception.stacktrace on a span EVENT bypass the redaction "
            "processor entirely — it does not visit event attributes"
        )
    if not pipe.get("exporters"):
        problems.append(f"{signal} pipeline has no exporters: it collects and drops")

# All three signals. Traces and metrics without logs means no crash layer, and
# logs without metrics means a log store nobody has a dashboard for.
for signal in ("traces", "metrics", "logs"):
    if signal not in pipelines:
        problems.append(f"no {signal} pipeline: the stack is a partial observability story")

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
  check 'templates/compose/otel-collector.yml  (redaction first, env endpoints, no URL)' collector_check

  # -------------------------------------------------------------------------
  # THE REDACTION BOUNDARY, DERIVED FROM core's SCHEMAS.
  #
  # This is the check that makes "kit's collector is the enforcement point" a
  # fact rather than an intention. core owns the allowlist
  # (schemas/telemetry/traces.schema.json, metrics.schema.json, logs.schema.json
  # and redaction.schema.json); this repo's collector config is supposed to be a
  # projection of it. A projection that disagrees is not a style difference: it
  # is either an attribute core says may not be recorded, shipping anyway, or an
  # attribute a service is allowed to record being dropped on the floor.
  #
  # The comparison is BIDIRECTIONAL on purpose, and that is the part worth
  # defending:
  #
  #   core -> kit   every attribute name core allows on a signal appears in that
  #                 signal's `redaction/*` allowed_keys. A missing one is a
  #                 silently-attribute-less span, which is the failure nobody
  #                 notices because the span still arrives.
  #   kit -> core   every name in allowed_keys is either on core's list for that
  #                 signal or on core's fleet-wide redaction allowlist, and
  #                 carries no word core's schema forbids. An extra one is a
  #                 leak with a check attached to it.
  #
  # One direction would be a check that passes on an empty allowlist. Both
  # directions together is a check that fails on a wrong one.
  #
  # A DERIVED rather than a hand-maintained claim: the comparison is computed
  # from core's files on disk at gate time, so the day core changes an allowlist
  # the gate goes red here and names the name. The resolved core commit is
  # printed, because "it passed" against a spec from six weeks ago is not the
  # same statement as "it passed".
  #
  # core is a sibling checkout, not a vendored copy (AGENTS.md: `../core` is a
  # read-only reference; kit does not depend on it). When it is absent this
  # check SKIPs loudly and the summary says so — a security check that is
  # silently absent is worse than one that is loudly absent, and hiding the skip
  # is what makes it silently absent.
  core_repo() {
    local cand
    if [ -n "${KIT_CORE:-}" ]; then
      printf '%s' "$KIT_CORE"
      return 0
    fi
    for cand in "$ROOT/../core" "$ROOT/../../core" "$ROOT/../cafaye/core"; do
      if [ -f "$cand/schemas/telemetry/traces.schema.json" ]; then
        (cd "$cand" && pwd)
        return 0
      fi
    done
    return 1
  }

  core_check() {
    local core
    core="$(core_repo)" || {
      echo "core not found: set KIT_CORE=<path to a core checkout>"
      return 1
    }
    "$PY" - "$ROOT" "$core" <<'PY'
import json
import os
import re
import subprocess
import sys

root, core = sys.argv[1], sys.argv[2]

def load(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def core_commit(path):
    try:
        return subprocess.run(
            ["git", "-C", path, "rev-parse", "--short", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    except Exception:
        return "unknown"


sch = f"{core}/schemas/telemetry"
traces = load(f"{sch}/traces.schema.json")
metrics = load(f"{sch}/metrics.schema.json")
logs = load(f"{sch}/logs.schema.json")
redaction = load(f"{core}/examples/valid/telemetry/redaction.json")

# core's per-signal attribute sets, read out of the schemas rather than
# transcribed here. A transcription is a second copy of a contract, and the
# whole point of this check is that there is only one.
core_traces = set(traces["$defs"]["tracesAttributes"]["properties"])
core_metrics = set(metrics["$defs"]["measurementAttributes"]["properties"])
core_logs = set(logs["$defs"]["logsAttributes"]["properties"])
core_resource = set(traces["$defs"]["resource"]["properties"])
core_fleet = set(redaction["allowed"])
core_prohibited = set(redaction.get("prohibited", []))
# The content-word vocabulary is a `not.pattern` list inside
# redaction.schema.json, not prose. Read it out of the schema itself so the
# vocabulary this check enforces is core's and cannot drift from it.
rs = load(f"{sch}/redaction.schema.json")
# core writes each pattern as `(?i)word`. Concatenated as-is they would be
# `(?i)a|(?i)b`, and Python rejects a global flag anywhere but position 0 — so
# the flag is stripped and applied once, which is also what it means.
core_content_words = [
    re.sub(r"^\(\?i\)", "", p["pattern"])
    for p in rs["properties"]["allowed"]["items"]["not"]["anyOf"]
    if "pattern" in p
]
content_re = re.compile("|".join(f"(?:{w})" for w in core_content_words), re.I)

import yaml

with open(f"{root}/templates/compose/otel-collector.yml", encoding="utf-8") as fh:
    col = yaml.safe_load(fh)

problems = []
# The per-signal allowlists, and the pipelines that carry each signal.
allowed = {
    name.rsplit("/", 1)[-1].replace("cafaye_", ""): set(cfg.get("allowed_keys") or [])
    for name, cfg in (col.get("processors") or {}).items()
    if name.startswith("redaction/")
}
expected = {"traces": core_traces, "metrics": core_metrics, "logs": core_logs}
for signal, core_set in expected.items():
    got = allowed.get(signal)
    if got is None:
        problems.append(f"no redaction/cafaye_{signal} processor: signal is not allowlisted")
        continue
    missing = sorted(core_set - got)
    if missing:
        problems.append(
            f"redaction/cafaye_{signal} drops attributes core allows on {signal}: "
            + ", ".join(missing)
        )
    extra = sorted(got - core_set)
    if extra:
        # An extra name is only legitimate if core's fleet-wide redaction
        # allowlist carries it — that is the `llm.*` half, which core's
        # redaction schema allows and whose absence from the per-signal schema
        # is core's own gap (raised in kit's report as a DECISION NEEDED).
        unbacked = [n for n in extra if n not in core_fleet]
        if unbacked:
            problems.append(
                f"redaction/cafaye_{signal} allows attributes core does not: "
                + ", ".join(unbacked)
            )
    for name in sorted(got):
        if content_re.search(name):
            problems.append(
                f"redaction/cafaye_{signal} allows {name!r}, whose name contains a "
                f"word core's redaction schema forbids on an allowed name"
            )
    for name in sorted(got & core_prohibited):
        problems.append(
            f"redaction/cafaye_{signal} allows {name!r}, which core's redaction "
            f"schema names as prohibited"
        )

# The three signals must all be present. Two of three is a partial boundary and
# a partial boundary reads as a whole one.
if sorted(allowed) != ["logs", "metrics", "traces"]:
    problems.append(f"redaction processors are {sorted(allowed)}; a signal with no boundary reads as one with")

# `allow_all_keys: true` disables the allowlist entirely while still looking
# configured. It is the single most dangerous line in the file and it is worth
# its own check rather than a footnote.
for name, cfg in (col.get("processors") or {}).items():
    if name.startswith("redaction/") and cfg.get("allow_all_keys") is not False:
        problems.append(
            f"{name}: allow_all_keys must be explicitly false — true disables the "
            f"allowlist while still looking configured"
        )

# A resource attribute is NOT a span attribute. core's whole cardinality
# argument is that identity lives on the resource and is exempt from the 2000
# cap; a resource name smuggled into allowed_keys is identity moved back onto
# the measurement. core asserts the two lists are disjoint, and so does this.
resource_leaks = sorted((allowed.get("metrics") or set()) & core_resource)
if resource_leaks:
    problems.append(
        "redaction/cafaye_metrics allows resource attributes as measurement "
        "attributes: " + ", ".join(resource_leaks)
    )

# THE RESOURCE EXEMPTION, and this check is the reason the config carries a
# stash/restore pair at all.
#
# The redaction processor's `allowed_keys` and `ignored_keys` are BOTH flat
# lists, and they are applied to resource attributes and measurement attributes
# by the same rule - so `ignored_keys: [tenant_id]` exempts the resource AND
# every data point, and the data point is exactly what core's metrics schema
# prohibits. Verified against the pinned image rather than assumed, because this
# is the one place an assumption is completely invisible: the pipeline runs, the
# dashboard renders, and the breakdown quietly undercounts.
#
# WHICH resource attributes can safely go in `ignored_keys` is DERIVED from
# core, not declared here. A name is safe exactly when core does not also list it
# on a signal's allowlist. `service.name` qualifies: it is never a measurement
# attribute, so exempting it cannot weaken the metrics boundary. `tenant_id` and
# `account_id` are the names core puts in BOTH places, and they are the ones
# that have to go through the stash.
#
# Four things are asserted, and (2) and (3) are the ones that stop the exemption
# being the bug:
#   1. every resource attribute core defines is either safely ignorable or
#      stashed - otherwise it is stripped and the per-tenant totals are lost;
#   2. no name core lists on BOTH a resource and a signal allowlist appears in
#      ignored_keys - that single entry is what exempts a data point too;
#   3. an ignored name core does not define anywhere is reported, because an
#      exemption nobody reasoned about is how a prohibited identifier gets back
#      onto a measurement in six months;
#   4. the stash/restore bracket the redaction processor, positionally.
pipelines = (col.get("service") or {}).get("pipelines") or {}

# The names that are BOTH a resource attribute and PROHIBITED on a measurement,
# read out of the `not` clause core already wrote for exactly this purpose.
#
# The first version derived this as "appears in the resource schema AND in any
# signal's allowlist", and that put `service.name` in the set — because core's
# log schema permits `service.name` as an ATTRIBUTE (a log store fanning several
# services into one stream needs it as a label). Which is not the hazard at all.
# The hazard is a name core REFUSES on a measurement, and core refuses those by
# name in a `not` clause: tenant_id, user_id, account_id, request_id, trace_id,
# span_id, session_id, message_id, notification_id, email, error.message,
# error.stacktrace, url.full, url.path. Read from there, so the answer is core's
# list rather than an inference from file layout.
prohibited_on_measurement = set()
for clause in metrics["$defs"]["measurementAttributes"]["not"]["anyOf"]:
    for key in clause.get("required", []):
        prohibited_on_measurement.add(key)
both_places = core_resource & prohibited_on_measurement

# The stash is read out of the config's OWN transform statements rather than
# assumed to cover a fixed list, so a stash that stops handling `account_id`
# fails here instead of quietly stripping it.
stash_src = ""
for cfg in (col.get("processors") or {}).values():
    if not isinstance(cfg, dict):
        continue
    for key in ("trace_statements", "log_statements", "metric_statements"):
        for group in cfg.get(key) or []:
            stash_src += " ".join(str(s) for s in (group or {}).get("statements") or [])
stashed = {name for name in both_places if f'attributes["{name}"]' in stash_src}
# `cafaye.stashed.<name>` is a PRIVATE name this config invents, and it is the
# one entry in ignored_keys that core has never heard of. It is allowed, and
# only because the stash/restore pair is asserted to bracket the redaction
# processor below and the restore deletes it — a private name that outlived the
# restore would be an attribute in every export, and the unknown-ignored-keys
# check below would otherwise (correctly) report it.
private_stash = {f"cafaye.stashed.{n}" for n in both_places}

for signal in ("traces", "metrics", "logs"):
    proc = f"redaction/cafaye_{signal}"
    cfg = (col.get("processors") or {}).get(proc) or {}
    ignored = set(cfg.get("ignored_keys") or [])

    missing = sorted(core_resource - ignored - stashed)
    if missing:
        problems.append(
            f"{proc}: resource attributes core defines are neither ignored nor "
            f"stashed, so they are stripped: {', '.join(missing)}. Strip "
            f"service.name and the fleet dashboard has nothing to partition by; "
            f"strip tenant_id and the per-tenant totals core requires are lost, "
            f"silently."
        )
    if not stashed:
        problems.append(
            f"{proc}: no resource attribute core PROHIBITS on a measurement is "
            f"stashed, so tenant_id/account_id are either stripped from every "
            f"resource or exempted on every data point. core's metrics schema "
            f"requires the first to happen not to and the second not to happen "
            f"at all."
        )
    both_in_ignored = sorted(ignored & both_places)
    if both_in_ignored:
        problems.append(
            f"{proc}: ignored_keys contains {', '.join(both_in_ignored)}, which "
            f"core lists as a resource attribute AND as a prohibited measurement "
            f"attribute. ignored_keys is one flat list applied to both, so this "
            f"exempts the data point too - the cardinality bomb core's metrics "
            f"schema exists to prevent. Use the stash/restore pair instead."
        )
    unknown = sorted(ignored - core_resource - private_stash)
    if unknown:
        problems.append(
            f"{proc}: ignored_keys names {', '.join(unknown)}, which core's "
            f"resource schema does not define. An exemption nobody reasoned "
            f"about is how a prohibited identifier gets back onto a measurement."
        )

    # THE CARRIER HAS TO SURVIVE THE PROCESSOR THAT READS IT, and this is the
    # check that says so. Being *stashed* is not the same as being *exempted*:
    # the stash writes `cafaye.stashed.tenant_id`, the redaction processor
    # deletes every attribute it does not exempt, and the restore then reads a
    # name that no longer exists. The pipeline runs, the trace arrives, the
    # dashboard renders — and every trace is missing the tenant_id on its
    # resource, which is per-tenant totals core's metrics schema exists to
    # produce.
    #
    # The three processors are one idea written out three times, and they had
    # drifted: metrics carried the private names and traces and logs did not.
    # The consequence was that the metric view had per-tenant totals and the
    # trace and log views silently did not. Found by running the stack and
    # reading a span back out of Tempo — every other check passed, because from
    # the config alone `tenant_id` genuinely is stashed.
    unexempted = sorted(private_stash - ignored)
    if unexempted:
        problems.append(
            f"{proc}: ignored_keys is missing {', '.join(unexempted)}, which is "
            f"the carrier the stash writes and the restore reads. The redaction "
            f"processor DELETES every attribute it does not exempt, so the stash "
            f"is undone before the restore can act on it: tenant_id and "
            f"account_id arrive on no resource at all, silently, while the "
            f"pipeline reports success."
        )

# ...and the three lists must agree, because three hand-copied lists are three
# places for one of them to drift. Equality across all three, reported against
# the union so the message names what is missing and what is extra without
# having to first work out which of the three is the odd one out — and without
# that subtlety, since picking a reference list to compare against is exactly
# how a check like this comes to ignore the very case it was added for.
_ignored_by_signal = {
    signal: set(
        ((col.get("processors") or {}).get(f"redaction/cafaye_{signal}") or {}).get(
            "ignored_keys"
        )
        or []
    )
    for signal in ("traces", "metrics", "logs")
}
_union = set().union(*_ignored_by_signal.values())
_intersection = set.intersection(*_ignored_by_signal.values())
if _union != _intersection:
    detail = "; ".join(
        f"{signal} {'lacks' + repr(sorted(_union - keys)) if _union - keys else 'extras' + repr(sorted(keys - _union))}"
        for signal, keys in sorted(_ignored_by_signal.items())
        if keys != _union
    )
    problems.append(
        f"the three redaction processors disagree on ignored_keys: {detail}. All "
        "three signals get the same resource exemption; one of them drifting is "
        "how a signal ends up quietly partitioned differently from the other two, "
        "which is the bug this assertion was added for."
    )

# The stash and the restore must bracket the redaction processor in EVERY
# pipeline, in that order. Checked positionally, because a pipeline that
# restores first is a pipeline that exports the private name.
for signal, pipe in pipelines.items():
    procs = pipe.get("processors") or []
    try:
        stash = procs.index("transform/cafaye_resource_stash")
        restore = procs.index("transform/cafaye_resource_restore")
        # Named `boundary_at`, not `redaction`: `redaction` is the loaded
        # core policy document, and shadowing it with an integer means the
        # summary line at the end of this script dies with a TypeError on
        # `redaction['version']` — after every check has already reported. A
        # check whose failure mode is a traceback is a check that reports the
        # wrong thing at the worst possible moment.
        boundary_at = next(i for i, p in enumerate(procs) if p.startswith("redaction/"))
    except (ValueError, StopIteration):
        problems.append(
            f"{signal} pipeline: the resource stash/restore pair is missing or "
            f"incomplete — without it, tenant_id is stripped from the resource"
        )
        continue
    if not (stash < boundary_at < restore):
        problems.append(
            f"{signal} pipeline: order is {procs}. It must be stash < redaction < "
            f"restore; the other way round exports the private stash name instead "
            f"of tenant_id."
        )

# Every spanmetrics dimension is a trace attribute the allowlist keeps. A
# dimension the redaction processor has already stripped produces a metric with
# an always-empty label: a dashboard column that is permanently blank, which
# looks like "no traffic" and is really "your filter ran first".
conn = (col.get("connectors") or {}).get("spanmetrics") or {}
for dim in conn.get("dimensions") or []:
    name = dim.get("name") if isinstance(dim, dict) else dim
    if name not in (allowed.get("traces") or set()):
        problems.append(
            f"spanmetrics dimension {name!r} is not in redaction/cafaye_traces' "
            f"allowed_keys, so the metric's label will always be empty"
        )

commit = core_commit(core)
if problems:
    sys.exit("; ".join(problems))
print(f"derived from core@{commit} (spec {redaction['version']})")
PY
  }
  if core_repo >/dev/null 2>&1; then
    check 'otel-collector allowlist  (derived from core schemas/telemetry)' core_check
  else
    report SKIP 'otel-collector allowlist vs core (core checkout not found — set KIT_CORE)'
  fi

  # exceptions-as-logs. PLAN.md §7b and the semconv: the `exception` span-event
  # convention is Deprecated, the replacement is an exception LOG RECORD, and
  # the switch is OTEL_SEMCONV_EXCEPTION_SIGNAL_OPT_IN=logs. The collector half
  # of that is: the spanmetrics connector must not mint the deprecated
  # exceptions counter, and there must be a logs pipeline for the record to
  # arrive on. Checked, because "we migrated" is a claim and a connector that
  # still counts span events is a migration that did not happen.
  exception_signal_check() {
    "$PY" - "$ROOT" <<'PY'
import sys

import yaml

root = sys.argv[1]
with open(f"{root}/templates/compose/otel-collector.yml", encoding="utf-8") as fh:
    col = yaml.safe_load(fh)

problems = []
conn = (col.get("connectors") or {}).get("spanmetrics") or {}
events = conn.get("events")
if not isinstance(events, dict) or events.get("enabled") is not False:
    problems.append(
        "spanmetrics events.enabled must be explicitly false: the `exceptions` "
        "counter it mints is the DEPRECATED exception span-event convention, and "
        "the replacement is an exception log record on the logs pipeline"
    )

pipelines = ((col.get("service") or {}).get("pipelines") or {})
logs = pipelines.get("logs") or {}
if not logs.get("receivers"):
    problems.append(
        "no logs pipeline, so there is nowhere for an exception log record to "
        "arrive — migrating from span events to logs means having the logs half"
    )
if not logs.get("exporters"):
    problems.append("no logs exporter: the crash layer would be collected and dropped")

# The signal that receives exceptions has to receive them from somewhere other
# than a span. `otlp` is how an SDK sends a log record; `syslog`/`filelog` is
# how a container's stderr becomes one with no per-language SDK (PLAN.md §7b
# layer 2). Neither alone is the whole contract.
if "otlp" not in (logs.get("receivers") or []):
    problems.append("the logs pipeline does not receive otlp, so an SDK cannot send an exception log record")
if not any(r.startswith(("syslog", "filelog")) for r in (logs.get("receivers") or [])):
    problems.append(
        "the logs pipeline tails no container stdout/stderr, so PLAN.md §7b's "
        "zero-SDK crash layer is not implemented"
    )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'otel-collector signals  (exceptions as logs, not span events)' exception_signal_check

  # No buffering, no retry, no warning storm. Same three properties core's
  # otel-endpoint.schema.json pins to `none` for a service's own SDK, asserted
  # here for the collector that every service exports into. A queue with
  # retry_on_failure is a background thread waking on a timer for the life of
  # the process while Tempo is down, and it is invisible in every dashboard
  # because nothing is being recorded.
  degrade_honestly_check() {
    "$PY" - "$ROOT" <<'PY'
import sys

import yaml

root = sys.argv[1]
with open(f"{root}/templates/compose/otel-collector.yml", encoding="utf-8") as fh:
    col = yaml.safe_load(fh)

problems = []
for name, cfg in (col.get("exporters") or {}).items():
    cfg = cfg or {}
    queue = cfg.get("sending_queue")
    if isinstance(queue, dict) and queue.get("enabled") is not False:
        problems.append(
            f"exporter {name}: sending_queue must be explicitly disabled — a queue "
            f"that accepts spans while Tempo is down is a memory leak with a "
            f"telemetry-shaped trigger"
        )
    retry = cfg.get("retry_on_failure")
    if isinstance(retry, dict) and retry.get("enabled") is not False:
        problems.append(
            f"exporter {name}: retry_on_failure must be explicitly disabled — a "
            f"retry loop against a dead endpoint is a thread waking on a timer "
            f"for the life of the process"
        )

pipelines = ((col.get("service") or {}).get("pipelines") or {})
for signal, pipe in pipelines.items():
    procs = pipe.get("processors") or []
    if procs and procs[0] != "memory_limiter":
        problems.append(
            f"{signal} pipeline starts with {procs[0]!r}, not memory_limiter: "
            f"without a limiter a runaway service takes the collector down and "
            f"every other service loses its telemetry at the same moment"
        )

if not ((col.get("extensions") or {}).get("health_check")):
    problems.append(
        "no health_check extension, so the compose healthcheck has nothing real "
        "to probe and `up --wait` cannot mean anything"
    )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'otel-collector degradation  (no queue, no retry, limiter first, health_check)' degrade_honestly_check

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
# none: a service that adopts the stack needs all of these or none of them.
# The four backing services are in the required set because observability is ON
# BY DEFAULT (PLAN.md §7b) — they are the answer to "what does this look like
# when it breaks", and the answer must not be "install four more services
# first". They are in a compose PROFILE so a constrained machine can opt out;
# the default `bin/dev up` path brings them up, and that is a property of
# bin/dev, which the readiness and profile checks below hold to account.
for required in ("postgres", "nats", "redis", "otel-collector", "tempo", "loki", "mimir", "grafana"):
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

# Nothing in the stack may name a cafaye SERVICE: hostnames are the service's
# own to choose, and a template that picks them for you is a template six repos
# disagree with. Infrastructure is fine — that is what this file is — and the
# observability backends are infrastructure, which is why they are named
# explicitly rather than allowed through by the exclusion below.
INFRASTRUCTURE = (
    "postgres",
    "nats",
    "redis",
    "otel-collector",
    "tempo",
    "loki",
    "mimir",
    "grafana",
)
for name in services:
    if name not in INFRASTRUCTURE:
        problems.append(f"unexpected service: {name}")

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'templates/compose/docker-compose.yml  (pinned, healthy, parameterized)' compose_check

  # The four backing services. Grafana, Loki, Tempo and Mimir are AGPL-3.0 and
  # are shipped UNMODIFIED, which is the condition the licence cares about and
  # the one this check can actually hold: no `build:` (a build is a fork), no
  # image from a cafaye-owned registry, no volume overlaying anything into the
  # vendor's own tree. Configuration is fine and is what the flags are; a
  # modified binary is not, and `build:` is the only way that gets here.
  #
  # They are also bounded, because a dev machine running six services plus four
  # more needs bounded memory or the whole thing gets killed and blamed on
  # something else.
  backing_check() {
    "$PY" - "$ROOT" <<'PY'
import sys

import yaml

root = sys.argv[1]
with open(f"{root}/templates/compose/docker-compose.yml", encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
services = doc.get("services") or {}

BACKING = {
    "grafana": "grafana/grafana",
    "loki": "grafana/loki",
    "tempo": "grafana/tempo",
    "mimir": "grafana/mimir",
}
problems = []

for name, upstream in BACKING.items():
    svc = services.get(name)
    if not isinstance(svc, dict):
        problems.append(f"missing service: {name}")
        continue
    if "build" in svc:
        problems.append(
            f"{name}: has a build: stanza, which is a fork. AGPL-3.0 covers the "
            f"Grafana SERVER; shipping it unmodified is the condition, and "
            f"rebuilding the image is how that condition gets broken quietly."
        )
    image = svc.get("image") or ""
    if not image.startswith(upstream + ":"):
        problems.append(
            f"{name}: image {image!r} is not an unmodified upstream {upstream} image"
        )
    if not svc.get("healthcheck"):
        problems.append(f"{name}: no healthcheck, so `up --wait` cannot gate on it")
    if not svc.get("mem_limit"):
        problems.append(
            f"{name}: no mem_limit. Six services plus four more on one laptop "
            f"needs a bound, or the stack is killed and the cause is attributed "
            f"to whatever was running when the machine ran out of memory."
        )
    profiles = svc.get("profiles") or []
    if "observability" not in profiles:
        problems.append(
            f"{name}: not in the `observability` profile. The four backends are "
            f"the expensive half of the stack, and an escape hatch that does not "
            f"exist is not an escape hatch — but they must still be what the "
            f"DEFAULT bin/dev path brings up, which is a property of bin/dev, "
            f"not of the profile."
        )

# The collector is NOT in that profile, deliberately: it is the default value
# of <SERVICE>_OTEL_ENDPOINT, so a service with nothing switched on has
# somewhere to send. Without the collector running, a service's exporter has a
# dead endpoint, and the collector is what makes that dead endpoint cheap.
if "observability" in ((services.get("otel-collector") or {}).get("profiles") or []):
    problems.append(
        "otel-collector is in the `observability` profile, so a developer who "
        "turns the backends off also loses the endpoint every service points at "
        "by default"
    )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'docker-compose.yml  (four AGPL backends, unmodified, pinned, bounded)' backing_check

  # The port range. kit-02 was moving the stack onto a high range so two
  # checkouts — or a developer's own postgres — do not collide; this check is
  # what makes that a rule rather than an intention.
  #
  # Asserted as a RANGE and as UNIQUENESS, not as a list of approved ports: a
  # list would have to be edited every time a service is added, and a check
  # that must be edited is a check that gets skipped. Every published host port
  # must sit in the documented block, must be a ${KIT_*:default} (the existing
  # check covers that) and must not be used twice.
  port_range_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import sys

import yaml

root = sys.argv[1]
# The block kit claims for the whole stack, one hundred per service. Declared
# here and in .env.example; the check reads the declared block so widening it is
# a deliberate edit in two visible places.
LOW, HIGH = 15000, 15999
BLOCK = f"{LOW}-{HIGH}"

with open(f"{root}/templates/compose/docker-compose.yml", encoding="utf-8") as fh:
    services = (yaml.safe_load(fh).get("services") or {})

problems = []
seen = {}
for name, svc in services.items():
    for entry in (svc or {}).get("ports") or []:
        if isinstance(entry, dict):
            host = str(entry.get("published", ""))
        else:
            host = str(entry).partition(":")[0]
        if "${" in host:
            # Read the DEFAULT, which is what a fresh clone binds.
            host = host.split(":-", 1)[1].rstrip("}") if ":-" in host else host
        if not host.isdigit():
            continue
        port = int(host)
        if not (LOW <= port <= HIGH):
            problems.append(
                f"{name}: published host port {port} is outside the {BLOCK} block "
                f"kit claims. 5432 and 6379 are the two most likely things on a "
                f"developer machine already, and a dev stack that loses to them "
                f"is a dev stack nobody runs."
            )
        if port in seen:
            problems.append(f"{name}: host port {port} is already published by {seen[port]}")
        seen[port] = name

# The block has to be written down, or "claim" means nothing to the next person.
example = open(f"{root}/templates/compose/.env.example", encoding="utf-8").read()
if BLOCK not in example:
    problems.append(
        f"templates/compose/.env.example does not state the {BLOCK} block this "
        f"check enforces: a port range nobody can read is a range nobody respects"
    )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check "docker-compose.yml  (host ports all in the 15000-15999 block, no reuse)" port_range_check

  # TELEMETRY IS NEVER IN THE READINESS PATH.
  #
  # A service that hangs on startup because the collector is down is worse than
  # no telemetry at all, and the way it happens is always the same shape: one
  # `depends_on: [otel-collector]` added for convenience, then a readiness probe
  # that transitively waits on it, then a deploy that will not roll out because
  # a dev-local collector is not running in the cluster.
  #
  # This is the static half of the proof; tests/no_telemetry_in_readiness.sh is
  # the live half. Neither alone is enough: the static check cannot see a probe
  # that checks a collector over the network, and the live check only sees the
  # one topology it builds.
  readiness_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import re
import sys

import yaml

root = sys.argv[1]
with open(f"{root}/templates/compose/docker-compose.yml", encoding="utf-8") as fh:
    services = (yaml.safe_load(fh).get("services") or {})

problems = []
for name, svc in services.items():
    if name == "otel-collector":
        continue
    depends = svc.get("depends_on") or []
    if isinstance(depends, dict):
        depends = list(depends)
    for dep in depends:
        if "otel" in str(dep):
            problems.append(
                f"{name}: depends_on {dep!r}. Telemetry must never be in anyone's "
                f"readiness path: a service that waits for the collector serves "
                f"no traffic while the collector is down, which is strictly worse "
                f"than serving traffic with no traces."
            )
    probe = svc.get("healthcheck") or {}
    test = " ".join(str(probe.get("test", [])))
    for target in ("otel-collector", "4317", "4318", "13133"):
        if target in test:
            problems.append(
                f"{name}: its healthcheck probes {target}. core's probes schema "
                f"wants /healthz to consult NOTHING and /readyz to check real "
                f"dependencies — the collector is not one."
            )

# bin/dev is the other half: if it waits on the collector before migrating, then
# a dead collector is a dead dev machine even though nothing depends on it.
dev = open(f"{root}/templates/bin/dev.sh", encoding="utf-8").read()
up_body = dev.split("\nup() {", 1)[-1].split("\n}\n", 1)[0]
for needle, why in (
    ("healthz", "bin/dev must not probe a telemetry endpoint"),
    ("4317", "bin/dev must not wait on an OTLP port"),
    ("4318", "bin/dev must not wait on an OTLP port"),
):
    if needle in up_body:
        problems.append(f"{why} (found {needle!r} in bin/dev's up path)")

# And the rule has to reach the service repos, not just this file: a service
# adopting kit is where a probe would actually be written.
agents = open(f"{root}/templates/AGENTS.md", encoding="utf-8").read()
if "OTEL" not in agents and "telemetry" not in agents:
    problems.append(
        "templates/AGENTS.md says nothing about telemetry and readiness, so the "
        "rule never reaches the service repo where a probe would be written"
    )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'compose + bin/dev  (telemetry is never in a readiness path)' readiness_check

  # The escape hatch is first-class, so it is checked like one. `<SERVICE>_
  # OTEL_ENDPOINT` is the ONLY contract (core D16) and the shipped collector is
  # its default value — not a requirement. The second half is the property that
  # is easy to lose: a "disabled" path that still dials out is worse than no
  # telemetry support at all.
  escape_hatch_check() {
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

# Comments are removed before anything is asserted, and the marker is
# PER LANGUAGE. The first version of this check stripped on `#` only, which
# does nothing to a Go, Rust or TypeScript comment — and every one of those
# snippets explains *why* `error.message` is prohibited in a comment, so the
# check reported all six languages for mentioning the very attribute it exists
# to keep out. A check whose fix is to delete the explanation is a check that
# trains people to delete explanations.
LINE_COMMENT = {"go": "//", "rust": "//", "node": "//", "ruby": "#", "elixir": "#", "python": "#"}

# Docstring syntaxes, per language. A docstring is prose wearing code's
# punctuation, and a check that reads one as code reports a file for explaining
# itself.
DOCSTRINGS = {
    "python": (('"""', '"""'), ("'''", "'''")),
    "elixir": (('"""', '"""'),),
    "ruby": (),
    "go": (),
    "rust": (),
    "node": (("`", "`"),),
}


def strip_comments(body, marker):
    out, in_block = [], False
    for line in body.splitlines():
        cleaned, i = [], 0
        while i < len(line):
            if in_block:
                end = line.find("*/", i)
                if end == -1:
                    i = len(line)
                else:
                    in_block, i = False, end + 2
                continue
            if line.startswith("/*", i):
                in_block, i = True, i + 2
                continue
            if line.startswith(marker, i):
                break
            cleaned.append(line[i])
            i += 1
        out.append("".join(cleaned))
    return "\n".join(out)


def strip_prose(code, lang):
    """Remove docstrings, so a check cannot fail on a file's own explanation."""
    pairs = DOCSTRINGS.get(lang, ())
    if not pairs:
        return code
    out = code
    for open_q, close_q in pairs:
        out = re.sub(
            rf"{re.escape(open_q)}.*?{re.escape(close_q)}", "", out, flags=re.S
        )
    return out


problems = []
for lang, name in snippets.items():
    path = os.path.join(root, "templates", "otel", lang, name)
    if not os.path.isfile(path):
        continue  # artifact presence is another check's job
    body = open(path, encoding="utf-8").read()
    stripped = strip_comments(body, LINE_COMMENT[lang])
    where = f"otel/{lang}/{name}"

    # 1. It must read the cafaye variable, not only the OTel standard one.
    #    core D16: `<SERVICE>_OTEL_ENDPOINT`, derived from the service name so
    #    it is knowable without reading any code.
    if not re.search(r'"?[A-Z][A-Z0-9]*_OTEL_ENDPOINT"?', stripped):
        problems.append(
            f"{where}: reads no *_OTEL_ENDPOINT variable. That variable is the "
            f"only contract (core D16) and the shipped collector is just its "
            f"default value."
        )

    # 2. On by default. The default endpoint is the collector that ships with
    #    the stack, NOT "no exporter". A snippet that returns a no-op provider
    #    when the variable is absent has made telemetry opt-in, which is the
    #    exact thing the user directive reversed.
    if not re.search(r"OTEL_EXPORTER_OTLP_ENDPOINT|otel-collector:431", stripped):
        problems.append(
            f"{where}: does not name the shipped collector as the default value "
            f"of the endpoint variable, so telemetry is opt-in rather than on by "
            f"default (PLAN.md §7b)"
        )

    # 3. The free no-op is pinned to the OpenTelemetry spec's own switch, not to
    #    a cafaye reimplementation. Six reimplementations of "disabled" is how
    #    six services acquire six definitions of it, and the difference between
    #    them is somebody's production incident.
    if "OTEL_SDK_DISABLED" not in stripped:
        problems.append(
            f"{where}: does not honour OTEL_SDK_DISABLED. core pins the no-op to "
            f"the OTel spec's own switch; a cafaye-specific one is the thing D16 "
            f"was decided against."
        )

    # 4. The four negatives from otel-endpoint.schema.json, asserted on the
    #    CODE and not on the prose.
    #
    #    This took a second pass to get right, and the first version is worth
    #    recording because it is the same mistake the artifact-presence check
    #    made: it looked for the WORD `retry`, and every one of these snippets
    #    has to EXPLAIN why there is no retry — so all six were reported for
    #    containing the sentence "a retry loop against a dead endpoint is a
    #    background thread". A check whose fix is to delete the explanation is a
    #    check that trains people to delete explanations.
    #
    #    So it matches retry and queue CONFIGURATION — an identifier a runtime
    #    reads — and nothing else. `max_queue_size` is a number in a struct
    #    literal; the sentence about a memory leak is not.
    #
    #    Docstrings are stripped too, for the same reason comments are: Python's
    #    `"""…"""` and Elixir's `@moduledoc` are prose, and treating a docstring
    #    as code is how a snippet ends up with a check that fails on its own
    #    documentation.
    code = strip_prose(stripped, lang)
    for pat, why in (
        (r"retry_on_failure|RetryConfig|retry_after|retry_delay|max_retries|retries\s*[:=]\s*\d|retry\s*:", "no retry loop against a dead endpoint"),
        (r"sending_queue|max_queue_size|queue_size|enqueue|Enqueue|batch_size\s*[:=]", "no buffering"),
    ):
        hit = re.search(pat, code)
        if hit:
            problems.append(
                f"{where}: {why} on the disabled path (matched {hit.group(0)!r})"
            )
    for pat in (r"console\.warn\b", r"log\.warning\b", r"Logger\.warn\b", r"logger\.warn\b", r"Rails\.logger\.warn\b", r"log\.Warn\b"):
        hit = re.search(pat, code)
        if hit:
            problems.append(
                f"{where}: no warning spam on the disabled path (matched {hit.group(0)!r})"
            )

    # 5. `error.message` is prohibited by name. An SDK adds it by default, so a
    #    snippet that does not say so ships a leak by default rather than by
    #    decision — and core's metrics schema refuses the OTel spelling as well
    #    as the dotted one for exactly that reason.
    if re.search(r"error[._]message", stripped):
        problems.append(
            f"{where}: records error.message. core prohibits it BY NAME: a "
            f"provider's content-policy rejection quotes the offending content "
            f"back at you, so the message is a prompt by another route."
        )
    if "error.type" not in stripped and "error_type" not in stripped:
        problems.append(
            f"{where}: never records error.type, which is the bounded class that "
            f"answers 'one place to see all errors' (PLAN.md §7b, core D14)"
        )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'templates/otel/*/*.snippet  (cafaye endpoint, on by default, free no-op)' escape_hatch_check

  # -------------------------------------------------------------------------
  # Grafana provisioning. "A dashboard a self-hoster has to rebuild is not a
  # dashboard we shipped" (PLAN.md §7b), so everything is a file and the files
  # are parsed here rather than clicked together by hand.
  #
  # The second check is the research constraint, and it is the one that matters:
  # the predicate for "this is an error" is span STATUS, not error.type. The
  # semconv expects high cardinality in error.type when no filter is applied, so
  # a fleet-wide breakdown grouped by error.type is wrong however good it looks.
  grafana_provisioning_check() {
    "$PY" - "$ROOT" <<'PY'
import json
import os
import sys

import yaml

root = sys.argv[1]
base = f"{root}/templates/compose/grafana"
problems = []

if not os.path.isdir(base):
    sys.exit("templates/compose/grafana/ is missing: a dashboard a self-hoster has to rebuild is not a dashboard we shipped")

ds_path = f"{base}/provisioning/datasources/datasources.yml"
if not os.path.isfile(ds_path):
    sys.exit(f"missing {ds_path}")
with open(ds_path, encoding="utf-8") as fh:
    datasources = (yaml.safe_load(fh).get("datasources") or [])

uids = {}
for ds in datasources:
    uid = ds.get("uid")
    if not uid:
        problems.append(f"datasource {ds.get('name')!r} has no uid; a dashboard that points at a datasource by uid cannot survive a rename")
        continue
    uids[uid] = ds.get("type")
for need, kind in (("tempo", "tempo"), ("loki", "loki"), ("mimir", "prometheus")):
    if need not in uids:
        problems.append(f"no {kind} datasource with uid {need!r}: traces, logs and metrics are the three layers of §7b")
    elif uids[need] != kind:
        problems.append(f"datasource uid {need!r} is type {uids[need]!r}, expected {kind!r}")

dash_dir = f"{base}/provisioning/dashboards"
provider = f"{dash_dir}/dashboards.yml"
if not os.path.isfile(provider):
    problems.append(f"missing {provider}: without a provider stanza Grafana loads no dashboard at all")
else:
    with open(provider, encoding="utf-8") as fh:
        opts = ((yaml.safe_load(fh).get("providers") or [{}])[0]).get("options") or {}
    path = opts.get("path")
    if not path:
        problems.append(f"{provider} names no path, so the provider watches nothing")
    elif not os.path.isabs(path):
        # Grafana resolves a relative path against its own working directory,
        # which in the image is /var/lib/grafana and nowhere a reader expects.
        problems.append(f"{provider} path {path!r} is relative; Grafana resolves it against its own cwd and finds nothing")

dashboards = sorted(
    f for f in os.listdir(dash_dir) if f.endswith(".json") if os.path.isdir(dash_dir)
) if os.path.isdir(dash_dir) else []
if not dashboards:
    problems.append("no dashboard JSON under provisioning/dashboards: the fleet error view is the centrepiece of §7b and it is a file")

seen_uids = set()
for name in dashboards:
    with open(f"{dash_dir}/{name}", encoding="utf-8") as fh:
        try:
            dash = json.load(fh)
        except Exception as exc:
            problems.append(f"{name}: not valid JSON ({exc})")
            continue
    uid = dash.get("uid")
    if not uid:
        problems.append(f"{name}: no uid, so it is unaddressable and unlinkable")
    elif uid in seen_uids:
        problems.append(f"{name}: duplicate dashboard uid {uid!r}")
    seen_uids.add(uid)
    blob = json.dumps(dash)
    for target in uids:
        if f'"datasource": {{"type": "prometheus", "uid": "{target}"}}' in blob or f'"{target}"' in blob:
            break
    else:
        problems.append(f"{name}: references none of the provisioned datasource uids {sorted(uids)}")

# At least one alert rule, as a file.
alerting = f"{base}/provisioning/alerting"
if not os.path.isdir(alerting) or not [f for f in os.listdir(alerting) if f.endswith(".yml")]:
    problems.append("no alert rule file: a stack that can render a dashboard but cannot page is half a stack")

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'grafana provisioning  (3 datasources, dashboards, alerting — all files)' grafana_provisioning_check

  # The error predicate. PLAN.md §7b and the semconv, verbatim:
  #
  #   The predicate for "this is an error" is span status Error, not error.type.
  #   error.type is a classification BENEATH the predicate, never the predicate.
  #   Consumers are explicitly expected to see high cardinality in error.type
  #   when no filter is applied, so a fleet-wide breakdown grouped by error.type
  #   is valid only under a service.name filter.
  #
  # That is a sentence a dashboard author reads once and forgets, so it is
  # asserted on the dashboard JSON: every panel that groups by an error class
  # must be scoped to a service, and at least one panel must filter on status.
  # A "fix" that makes this go red is a dashboard that looks better and answers
  # the wrong question.
  error_predicate_check() {
    "$PY" - "$ROOT" <<'PY'
import json
import os
import re
import sys

root = sys.argv[1]
dash_dir = f"{root}/templates/compose/grafana/provisioning/dashboards"
if not os.path.isdir(dash_dir):
    sys.exit("no dashboard directory")

problems = []
grouped_by_class_globally = 0
status_filtered = 0
service_partitioned = 0

def walk_targets(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key in ("expr", "query", "rawSql", "definition", "jsonData"):
                yield value
            yield from walk_targets(value)
    elif isinstance(node, list):
        for item in node:
            yield from walk_targets(item)

for name in sorted(f for f in os.listdir(dash_dir) if f.endswith(".json")):
    with open(f"{dash_dir}/{name}", encoding="utf-8") as fh:
        dash = json.load(fh)
    targets = [t for t in walk_targets(dash) if isinstance(t, str)]
    blob = "\n".join(targets)

    # `by (error_type)` / `group by ... error.type` with no service filter is
    # the exact failure the research named. Note the `service_name` allowance
    # below: the rule is "error.type is a drill-down INSIDE a service", and a
    # template variable that selects the service is that drill-down.
    for match in re.finditer(r"by\s*\(([^)]*)\)", blob):
        clause = match.group(1)
        if "error_type" in clause or "error\\.type" in clause:
            window = blob[max(0, match.start() - 400) : match.end() + 200]
            if not re.search(r"service_name\s*[=!~]+", window):
                grouped_by_class_globally += 1
                problems.append(
                    f"{name}: groups by an error class with no service filter. The "
                    f"predicate for 'this is an error' is span STATUS; error.type is "
                    f"a drill-down inside a service, and the semconv expects high "
                    f"cardinality there when no filter is applied."
                )

    if re.search(r"status(_\.?code)?\s*[=!]+\s*\"?STATUS_CODE_ERROR", blob) or \
       re.search(r'status\s*=\s*error', blob) or re.search(r"\{\s*status\s*=", blob):
        status_filtered += 1
    if re.search(r"by\s*\(\s*service_name\s*\)", blob) or "service_name" in blob:
        service_partitioned += 1

if not status_filtered:
    problems.append(
        "no panel filters on span status error. Grouping by error.type without "
        "the status predicate answers 'which classes exist' rather than 'what "
        "failed' — a request that failed without an error.type is invisible to it."
    )
if not service_partitioned:
    problems.append(
        "no panel partitions by service.name. §7b's answer is 'partition by "
        "resource.service.name, filter on status = error'; a single undifferentiated "
        "total is the wall of ungrouped text the user asked whether cafaye could avoid."
    )
if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'grafana dashboards  (status is the predicate, error.type is a drill-down)' error_predicate_check

  # -------------------------------------------------------------------------
  # EVERY PANEL NAMES THE BACKEND IT QUERIES, and the name is the one it means.
  #
  # Both dashboards shipped with `"datasource": null` on all 15 query targets.
  # A null datasource in Grafana means "use the DEFAULT datasource", and the
  # default is Mimir — so every LogQL panel and the TraceQL panel were being
  # sent to a Prometheus API:
  #
  #     Mimir, given {service_name=~"$service"} |= `log.severity` |~ "..."
  #       parse error: unexpected character: '|'
  #
  # The panels provision, the dashboards render, the datasource health checks
  # are green, and the crash layer — the panel the user explicitly asked for —
  # is structurally incapable of drawing anything. Found by sending each panel's
  # query to the backend it was actually bound to and reading the replies; 12 of
  # 15 were rejected. No static check in this file could have seen it, because
  # the JSON is perfectly valid and every datasource really was reachable.
  #
  # The language is classified from the query's own grammar, not the panel's
  # title: PromQL never opens an expression with a bare `{`, and Grafana's own
  # `queryType` hint says `range` for a log query and `nativeSearch` for a trace
  # search.
  datasource_binding_check() {
    "$PY" - "$ROOT" <<'PY'
import json
import os
import re
import sys

import yaml

root = sys.argv[1]
base = f"{root}/templates/compose/grafana/provisioning"

# Read the uids and types from the PROVISIONING FILE rather than repeating them,
# so renaming a uid in one file does not leave this check asserting against a
# name nothing uses.
with open(f"{base}/datasources/datasources.yml", encoding="utf-8") as fh:
    provisioned = {
        d["uid"]: d["type"]
        for d in (yaml.safe_load(fh).get("datasources") or [])
        if isinstance(d, dict) and d.get("uid")
    }

# Which query language each backend can serve, and which of those Grafana type
# strings mean what. Kept as a table so an unlisted backend is a FAILURE rather
# than a panel nobody has an opinion about.
LANGUAGES = {
    "prometheus": {"lang": "promql", "grafana_type": "prometheus"},
    "loki": {"lang": "logql", "grafana_type": "loki"},
    "tempo": {"lang": "traceql", "grafana_type": "tempo"},
}

problems = []
dash_dir = f"{base}/dashboards"


def classify(target):
    """The query language a target's text is, by its own grammar."""
    kind = str(target.get("queryType") or "").lower()
    if kind in ("range", "instant"):
        return "logql"
    if kind == "nativesearch":
        return "traceql"
    text = target.get("expr") or target.get("query") or ""
    if isinstance(text, str) and text.strip().startswith("{"):
        return "logql"
    return "promql"


def walk(node):
    """Yield (panel_title, target) for every panel, at any nesting depth."""
    if isinstance(node, dict):
        for panel in node.get("panels") or []:
            for target in panel.get("targets") or []:
                yield panel.get("title", "(row)"), target
            yield from walk(panel)
    elif isinstance(node, list):
        for item in node:
            yield from walk(item)


for entry in sorted(os.listdir(dash_dir)):
    if not entry.endswith(".json"):
        continue
    with open(f"{dash_dir}/{entry}", encoding="utf-8") as fh:
        doc = json.load(fh)
    for title, target in walk(doc):
        text = target.get("expr") or target.get("query") or ""
        if not isinstance(text, str) or not text.strip():
            continue
        ds = target.get("datasource")
        want = classify(target)

        if not ds or not isinstance(ds, dict) or not ds.get("uid"):
            problems.append(
                f"{entry} / {title}: the query has no datasource, so Grafana sends "
                f"it to the DEFAULT one — which is Mimir. This is a {want} query; "
                f"bound to a Prometheus API it returns a parse error, which is a "
                f"red panel rather than an empty one. Name the uid explicitly."
            )
            continue

        uid = ds["uid"]
        if uid not in provisioned:
            problems.append(
                f"{entry} / {title}: datasource uid {uid!r} is not in "
                f"datasources.yml ({', '.join(sorted(provisioned)) or 'none'}), so "
                f"the panel renders with no data and no error"
            )
            continue
        if ds.get("type") != provisioned[uid]:
            problems.append(
                f"{entry} / {title}: says type={ds.get('type')!r} for uid {uid!r}, "
                f"but datasources.yml provisions it as {provisioned[uid]!r}"
            )
        if provisioned[uid] not in LANGUAGES:
            problems.append(
                f"{entry} / {title}: datasource type {provisioned[uid]!r} is not a "
                f"backend this check knows how to route "
                f"({', '.join(sorted(LANGUAGES))})"
            )
            continue
        if LANGUAGES[provisioned[uid]]["lang"] != want:
            problems.append(
                f"{entry} / {title}: a {want} query bound to {uid!r}, which "
                f"serves {LANGUAGES[provisioned[uid]]['lang']}. Bound to the wrong "
                f"backend this is a parse error, not an empty result."
            )

# The alert rules are dashboards with a different trigger, and they carried the
# same class of mistake: the status predicate grouped on `otel.status_code`,
# which is a PARSE ERROR in PromQL because OTLP ingestion mangles the dot to an
# underscore. A rule that cannot be parsed never fires and never reports that it
# cannot be parsed.
#
# Scoped to the `expr` strings, not the whole file. The rules DOCUMENT these
# names in their descriptions — "`error.type` is a bounded class" is correct
# English about the OTLP attribute and must not be rewritten — and a scan over
# the serialised document cannot tell a sentence from a query. It can also only
# see what it was given, which is why the earlier version of this regex was
# matching the word "error" out of a description and reporting that a label
# called `error` should be `error`.
with open(f"{base}/alerting/rules.yml", encoding="utf-8") as fh:
    rules = yaml.safe_load(fh) or {}
exprs = []
for holder in [rules, *(rules.get("groups") or [])]:
    if not isinstance(holder, dict):
        continue
    for rule in holder.get("rules") or []:
        for source in [rule, *(rule.get("data") or [])]:
            if not isinstance(source, dict):
                continue
            model = source.get("model")
            expr = model.get("expr") if isinstance(model, dict) else source.get("expr")
            if isinstance(expr, str):
                exprs.append((rule.get("title", "(rule)"), expr))
for title, expr in exprs:
    for dotted in set(re.findall(r"\b(?:otel|error|http|service|span|messaging|db)\.[a-z_]+", expr)):
        problems.append(
            f"alerting/rules.yml rule {title!r} uses {dotted!r} in a PromQL expr. "
            f"OTLP ingestion mangles a dot in a label name to an underscore, so "
            f"what the backend holds is '{dotted.replace('.', '_')}'. A matcher on "
            f"the dotted spelling is a parse error, and an alert that cannot be "
            f"parsed never fires and never says so."
        )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'grafana panels  (every query names the backend that can answer it)' \
    datasource_binding_check

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

  # bin/dev's escape hatch must actually WORK, and "must work" is a claim only
  # running it settles.
  #
  # `set -u` plus an empty array is a portable-shell trap: macOS ships bash 3.2,
  # where `"${a[@]}"` on an empty array is an "unbound variable" ERROR rather
  # than nothing. kit-03 shipped `local profile_args=()` and expanded it
  # unconditionally, so `KIT_DEV_PROFILES= bin/dev up` — the DOCUMENTED way to
  # run the stack without the observability backends — died on line one with
  #
  #   bin/dev: line 120: profile_args[@]: unbound variable
  #
  # The failure is spectacular precisely because the default path works, so
  # nothing else in the suite noticed. Here the script is actually executed with
  # the variable empty and is only required to get past argument parsing, which
  # is where the trap bites; a stub `docker` on PATH keeps the test hermetic and
  # fast, because what is under test is the shell, not compose.
  dev_escape_hatch_check() {
    local stub sandbox out ec=0
    stub="$TMP/dev-hatch-stub"
    sandbox="$TMP/dev-hatch"
    rm -rf "$stub" "$sandbox"
    mkdir -p "$stub" "$sandbox/bin" "$sandbox/grafana" "$sandbox/tempo" \
      "$sandbox/loki" "$sandbox/mimir"
    cat >"$stub/docker" <<'STUB'
#!/usr/bin/env bash
# Reports readiness so `bin/dev up` believes the stack came up, and does
# nothing else. What is under test is the SHELL, not compose.
case "$*" in
  *" version"*) echo "Docker Compose version v2.0.0"; exit 0 ;;
esac
case "$1" in
  --profile) shift 2 ;;
esac
exit 0
STUB
    chmod +x "$stub/docker"
    # A compose file and the vendor config trees, so `require_files` passes and
    # the run reaches `up`, which is where the trap fires. They are empty files
    # on purpose: nothing here parses them.
    : >"$sandbox/docker-compose.yml"
    : >"$sandbox/otel-collector.yml"
    : >"$sandbox/.env.example"
    cp "$ROOT/templates/bin/dev.sh" "$sandbox/bin/dev"

    # `KIT_DEV_PROFILES=''` and not `KIT_DEV_PROFILES=`: shellcheck reads the
    # latter as a typo, and it is right to.
    out="$(cd "$sandbox" && KIT_DEV_PROFILES='' PATH="$stub:$PATH" \
      bash ./bin/dev up 2>&1)" || ec=$?
    case "$out" in
      *"unbound variable"*)
        echo "the documented escape hatch KIT_DEV_PROFILES= is broken:"
        printf '%s\n' "$out" | head -3
        return 1
        ;;
      *"no migration command found"*) return 0 ;;
      *)
        echo "bin/dev with KIT_DEV_PROFILES= exited $ec without reaching the"
        echo "migration step; expected the clean 'no migration command' exit."
        printf '%s\n' "$out" | head -6
        return 1
        ;;
    esac
  }
  check 'templates/bin/dev.sh  (KIT_DEV_PROFILES= escape hatch actually runs)' dev_escape_hatch_check
  # ------------------------------------------------------------------ core
  # The fan-out standard: vendir templates, the shared Renovate policy, and the
  # two runnable pieces (the change classifier and the staleness reporter).
  #
  # `core_fanout_check` is a real parser over four file types and its failure
  # modes are specific enough to be worth reading in one place, so it lives in
  # tests/core_fanout_check.py rather than inlined here.
  section 'static: the core fan-out standard'
  core_fanout_check() {
    "$PY" "$ROOT/tests/core_fanout_check.py" "$ROOT"
  }
  check 'core/vendir/ + core/renovate/  (structurally what Renovate and vendir need)' \
    core_fanout_check

  # Dogfood lint/yamllint.yml on every YAML in the tree, not just the two
  # compose templates. kit ships the config and a repo that copies it lints its
  # own CI against it on day one, so a YAML that breaks the config is a YAML
  # that greets the first adopting repo with a failure nobody authored.
  #
  # This also subsumes kit-03's own walk of `templates/compose`, which existed
  # because the provisioning tree is three directories deep and a glob of
  # `templates/compose/*` reaches none of it. `yamls_of_the_tree` below finds
  # those files for the same reason and covers the rest of the repo too, so the
  # narrower walk is gone rather than kept alongside: two loops over the same
  # files report every problem twice and disagree about which is authoritative.
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

    # The glob above only reaches `*.yml` and `*.yaml`, and kit now ships YAML
    # under other names: the vendir templates are `vendir.yml.<service>` so that
    # a repository that copies one to `vendir.yml` gets a file Renovate's
    # `managerFilePatterns` can find, while kit's own tree is never itself a
    # vendir target.
    #
    # A file a service copies that breaks kit's own lint config greets its first
    # CI run with a failure nobody authored, which is the `rack_middleware.rb.snippet`
    # defect in AGENTS.md arriving in a different costume. So they are linted
    # here by name, and the name list is explicit: a glob over
    # `core/vendir/vendir.yml.*` would also catch a backup file.
    for rel in core/vendir/vendir.yml.template core/vendir/vendir.yml.muse \
               core/vendir/vendir.yml.pantry core/vendir/vendir.yml.caf; do
      [ -f "$ROOT/$rel" ] || continue
      check "$rel  (yamllint -c lint/yamllint.yml, under a non-.yml name)" \
        "$YAMLLINT" -c "$ROOT/lint/yamllint.yml" "$ROOT/$rel"
    done
  fi

  # The CI workflow gains a job; assert the job exists, is opt-in, and that the
  # default call still runs exactly the six original jobs. A kit change that
  # breaks every consumer's CI is a kit change that does not ship.
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
  # The tier convention. Three claims, three checks, split because they decay
  # separately: the templates drift, the wiring drifts, the allowlist rots. One
  # check covering all three would keep passing while two of them rotted.
  # -------------------------------------------------------------------------
  section 'static: every language declares a tier, and says how it is collected'

  # (1) The declaration, per language, in the templates.
  #
  # Read out of the workflow's `language` options, so there is still exactly one
  # place to add a language — the same rule as the four-artifacts check above.
  # For each: a `templates/tier/<lang>/` directory, the declared form inside it,
  # and a row in the tier README naming the collector that reads it.
  #
  # The README row is required rather than nice-to-have, because a tier nobody
  # can collect is a comment — and a comment is what this whole packet exists to
  # stop being. A language with a declaration and no named collector is a
  # language whose tier can never be required of anything.
  tier_declaration_check() {
    "$PY" - "$ROOT" "$CONFIG_ONLY" "$WORKFLOW" <<'PY'
import os
import re
import sys

import yaml

root, config_only, workflow = sys.argv[1], sys.argv[2], sys.argv[3]
with open(workflow, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
triggers = doc.get("on") or doc.get(True) or {}
call = (triggers.get("workflow_call") or {}).get("inputs") or {}
langs = [x for x in ((call.get("language") or {}).get("options") or []) if x != config_only]

tier_readme = os.path.join(root, "templates", "tier", "README.md")
if not os.path.isfile(tier_readme):
    sys.exit("templates/tier/README.md is missing: a convention with no document is a rumour")
readme = open(tier_readme, encoding="utf-8").read()

# The first column of every markdown table row in that file, backticks stripped.
# Restored to a set and compared by membership, so a row is found wherever it
# sits in the document rather than at a guessed line.
declared_rows = {
    cell.strip().strip("`")
    for line in readme.splitlines()
    if line.strip().startswith("|")
    for cell in [line.strip().strip("|").split("|")[0]]
}

# The declaration itself, per language: the token a service author actually
# writes, and in every case a no-op at runtime — a build tag, an attribute
# libtest already prints, a marker, a const, a macro. Asserting the token is
# PRESENT in the shipped template is what stops a declaration being described in
# a README and absent from the file a service copies. Prose is not a
# declaration; only the template is.
DECLARED = {
    "go": r"^//go:build tier_db$",
    "rust": r'#\[ignore = "cafaye:tier=',
    "python": r"^@pytest\.mark\.tier_db$",
    "bun": r'^export const TIER = "db" as const;$',
    "node": r'^export const TIER = "db" as const;$',
    "ruby": r"^\s*tier :db$",
    "elixir": r"^  @tier :db$",
}

problems = []
for lang in langs:
    d = os.path.join(root, "templates", "tier", lang)
    if not os.path.isdir(d):
        problems.append(
            f"{lang}: no templates/tier/{lang}/ — a language with a CI job and no tier "
            f"declaration is a language whose tier can never be required"
        )
        continue

    files = [
        f
        for f in sorted(os.listdir(d))
        # isfile, because a directory in a template tree is a problem to
        # REPORT, not a crash. Reading it raised IsADirectoryError and took two
        # checks down with a traceback, which is the least useful way a gate
        # can fail. `__pycache__` got in here for real.
        if not f.startswith(".") and os.path.isfile(os.path.join(d, f))
    ]
    if not files:
        problems.append(f"templates/tier/{lang}/ holds no files")
        continue
    strays = [
        f
        for f in sorted(os.listdir(d))
        if not f.startswith(".") and not os.path.isfile(os.path.join(d, f))
    ]
    if strays:
        problems.append(
            f"templates/tier/{lang}/ holds {strays}, which is not a file a service "
            f"can copy. kit hands out files; a build artefact in this tree is "
            f"something a previous run left behind"
        )

    bodies = [open(os.path.join(d, f), encoding="utf-8").read() for f in files]
    token = DECLARED.get(lang)
    if token is None:
        problems.append(
            f"{lang}: this check knows no declared form for it. Add one — a language "
            f"whose declaration nothing can assert is a check that cannot fail"
        )
    elif not any(re.search(token, b, re.M) for b in bodies):
        problems.append(
            f"templates/tier/{lang}/: none of {files} carries the declared form. The "
            f"README describes a declaration the template does not have"
        )

    # The collector, named in the README's per-language table.
    #
    # The table is PARSED rather than substring-searched, because the rows are
    # written as `| `go` |` — the option value in backticks, since it is the
    # literal a caller types into `language:`. A `f"| {lang} |" in readme` test
    # does not match a backticked cell, and the first version of this check
    # failed on a table that was correct in every way a reader could check. A
    # check that is right about the rule and wrong about the syntax is still
    # wrong, and the fix belongs in the check.
    if lang not in declared_rows:
        problems.append(
            f"templates/tier/README.md has no table row for {lang}: a service author "
            f"cannot learn how their language's tier is collected"
        )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'templates/tier/<lang>/  (a declared tier, and a README row naming the collector)' \
    tier_declaration_check

  # (2) The demand, wired. `REQUIRED_<TIER>=1` must be exported by every language
  #     job and checked by every language job, or naming a variable in a caller
  #     is a promise no job keeps.
  #
  #     The demand steps are byte-identical on purpose — GitHub reusable
  #     workflows cannot share a step — so this asserts they STAY identical. Six
  #     hand-maintained copies of a policy block is the drift kit exists to
  #     prevent, and the only defence against hand-maintained copies is a check
  #     that reads them.
  #
  #     `-count=1` is asserted on the Go job alone: no other language kit ships
  #     has a test cache keyed on the environment, and mandating a flag that does
  #     not exist is a check nobody could satisfy honestly.
  tier_demand_check() {
    "$PY" - "$ROOT" "$CONFIG_ONLY" "$WORKFLOW" <<'PY'
import sys

import yaml

root, config_only, workflow = sys.argv[1], sys.argv[2], sys.argv[3]
with open(workflow, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
triggers = doc.get("on") or doc.get(True) or {}
call = (triggers.get("workflow_call") or {}).get("inputs") or {}
jobs = doc.get("jobs") or {}
langs = [x for x in ((call.get("language") or {}).get("options") or []) if x != config_only]


def strip_shell_comments(src):
    """Remove shell comments from a `run:` body, keeping quoted `#` intact.

    AGENTS.md: "a check that can be satisfied by a comment is not a check."
    That is not a hypothetical here — this function exists because the
    `-count=1` assertion was written as a substring test, the go step's own
    comment block explains WHY the flag is mandated and names the flag twice,
    and deleting the flag from the command left the check green. It was
    satisfied by the sentence explaining that removing it would be a mistake.

    Only a `#` at the start of a word begins a comment, and a `#` inside
    single or double quotes is content. So `grep -qE '^ran[[:space:]]'` and
    `echo "::error::#1"` both survive intact, and `# -count=1 is mandated`
    does not.
    """
    out = []
    for line in src.splitlines():
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        # Walk the line tracking quote state, and cut at the first `#` that
        # follows a space outside quotes — the shell's own rule, near enough.
        quote = None
        cut = None
        for i, ch in enumerate(line):
            if quote:
                if ch == quote:
                    quote = None
                continue
            if ch in ("'", '"'):
                quote = ch
            elif ch == "#" and (i == 0 or line[i - 1] in " \t"):
                cut = i
                break
        out.append(line if cut is None else line[:cut])
    return "\n".join(out)


problems = []

# Opt-in by an EMPTY default, not by "0". "0" would be a tier named 0 demanded
# at a value that is neither true nor false, and every caller would have to know
# that. Same reasoning as the `telemetry` input, and the same string type.
demand = call.get("required-tier")
if not isinstance(demand, dict):
    problems.append("no `required-tier` workflow_call input")
elif str(demand.get("default", "x")) != "":
    problems.append(
        f"`required-tier` defaults to {demand.get('default')!r}; it must default to the "
        f"empty string, or adopting kit turns a green repo red on day one"
    )
elif str(demand.get("type")) != "string":
    problems.append("`required-tier` must be type: string, for the reason telemetry is")

bodies = {}
for lang in langs:
    steps = (jobs.get(lang) or {}).get("steps") or []
    if "tier demand" not in [s.get("name") for s in steps]:
        problems.append(
            f"job {lang} has no `tier demand` step: naming a required-tier in a caller "
            f"would be a promise no step keeps, and a gate variable that is set while "
            f"a tier runs zero tests is a green build that verified nothing"
        )
    for s in steps:
        if s.get("name") == "tier demand":
            # The identity comparison below is on the RAW body: it is the
            # duplication that is being compared, comments included, because two
            # copies of a policy block that differ only in their commentary are
            # two copies a reader has to diff by hand.
            bodies[lang] = s.get("run") or ""
            # The `^ran` assertion is on the body with comments stripped. The
            # step's own comment block says "a `ran` line is the evidence that
            # something executed", so an unstripped substring test is satisfied
            # by the sentence describing the check rather than by the check.
            if "^ran" not in strip_shell_comments(bodies[lang]):
                problems.append(
                    f"job {lang}: its `tier demand` step does not look for a 'ran' "
                    f"line, so it cannot tell a tier that ran from one that did not"
                )

    # Both halves of the test step, because either alone is a dead gate:
    # exporting without capturing cannot be checked, and capturing without
    # exporting checks a variable nothing set.
    test = next((s for s in steps if s.get("name") == "test"), None)
    if not isinstance(test, dict):
        problems.append(f"job {lang} has no `test` step to demand a tier from")
        continue
    body = strip_shell_comments(test.get("run") or "")
    if 'export "$REQUIRED_TIER=1"' not in body:
        problems.append(
            f"job {lang}: its test step does not export the demanded gate variable. "
            f"guard's GUARD_REDIS_REQUIRED fails at tier-INVOCATION time, before a "
            f"report exists; a variable applied after the run cannot do that"
        )
    if "kit-tier.log" not in body:
        problems.append(
            f"job {lang}: its test step does not tee to kit-tier.log, so `tier demand` "
            f"has nothing to read and exits green on an empty log"
        )

if len(set(bodies.values())) > 1:
    problems.append(
        "the `tier demand` steps are not identical across language jobs. They are "
        "duplicated because GitHub reusable workflows cannot share a step, and the "
        "duplication is only safe while a check reads them: change all of them or none"
    )

# `-count=1` on the gated tier, for the one language with an env-keyed cache.
go_body = ""
for s in ((jobs.get("go") or {}).get("steps") or []):
    if s.get("name") == "test":
        go_body = strip_shell_comments(s.get("run") or "")
if go_body and "-count=1" not in go_body:
    problems.append(
        "the go test step does not pass -count=1. Go keys its test cache on the "
        "environment a test reads, so a gated and an ungated run already differ — but "
        "mandating the flag removes the question instead of reasoning about it"
    )

if problems:
    sys.exit("; ".join(problems))
print(
    f"required-tier is opt-in (default ''), exported by all {len(langs)} language jobs, "
    f"and checked by {len(bodies)} identical demand steps"
)
PY
  }
  check "$WORKFLOW  (required-tier is declared, demanded by every language job, and identical)" \
    tier_demand_check

  # (3) The skip allowlist and its four hygiene rules. This is the load-bearing
  #     check of the packet, and rule 4 is the sharpest property in the repo:
  #     AN ENTRY THAT MATCHES NOTHING IS A FAILURE.
  #
  #     The inventory is derived from `templates/tier/` — the declarations kit
  #     ships — because that is the only inventory kit can see. Applying the same
  #     rule over a service's real run is `caf gate`'s job, and that boundary is
  #     written down in templates/tier/README.md rather than blurred here.
  #
  #     Note what this inventory is NOT. It is not a grep for a sentinel that
  #     guesses whether a test "looks like" a database test, which is what fails
  #     open. It reads ids the author DECLARED. That difference is the whole
  #     distance between a derivation that misses new tests and one that cannot.
  skip_allowlist_check() {
    "$PY" - "$ROOT" <<'PY'
import datetime
import os
import re
import sys

root = sys.argv[1]
path = os.path.join(root, "templates", "tier", "skip-allowlist")
if not os.path.isfile(path):
    sys.exit("templates/tier/skip-allowlist is missing: a skipped test needs a recorded reason")

# ---------------------------------------------------------------- the inventory
#
# One regex per language, reading the id the author declared. Deliberately
# simple, and deliberately the only place kit looks at a language at all. A
# language with no pattern here simply cannot have an allowlist entry, which is
# the safe direction: an unresolvable entry is a failure, never a silent pass.
ID_PATTERNS = {
    "go": r"^func (Test\w+)\(",
    "rust": r"^\s*fn (\w+)\(",
    "python": r"^def (test_\w+)\(",
    "ruby": r"^\s*def (test_\w+)\b",
    "elixir": r'^\s*test "([\w.]+)"',
    "bun": r'^test\("([\w]+)"',
    "node": r'^test\("([\w]+)"',
}

inventory = set()
tier_root = os.path.join(root, "templates", "tier")
for lang, pattern in ID_PATTERNS.items():
    d = os.path.join(tier_root, lang)
    if not os.path.isdir(d):
        continue
    for name in sorted(os.listdir(d)):
        # isfile, and a non-file is the declaration check's problem to report
        # rather than this one's to crash on. See the note there.
        if name.startswith(".") or name == "README.md":
            continue
        if not os.path.isfile(os.path.join(d, name)):
            continue
        body = open(os.path.join(d, name), encoding="utf-8").read()
        for tid in re.findall(pattern, body, re.M):
            inventory.add(f"{lang}/{name} {tid}")

# A check that proved nothing because it looked at nothing is a check that ran
# nothing. An empty inventory would make rule 4 either reject every entry or —
# far worse — invite someone to relax it into a no-op that always passes.
if not inventory:
    sys.exit(
        "no test ids were derived from templates/tier/, so the unused-entry rule "
        "would be checking nothing: every ID_PATTERNS entry has stopped matching "
        "its own template"
    )

# ---------------------------------------------------------------- the entries
#
#   skipped <tier> <suite-id> <test-id> reason="…" owner=… since=… until=…
#
# The first four fields are the normalised result line verbatim, so a result and
# its exemption share one shape and a reader only has to learn one format.
LINE = re.compile(
    r'^skipped\s+(?P<tier>\S+)\s+(?P<suite>\S+)\s+(?P<test>\S+)'
    r'(?P<fields>(?:\s+[a-z]+=(?:"[^"]*"|\S+))*)\s*$'
)
FIELD = re.compile(r'([a-z]+)=("[^"]*"|\S+)')
WHY = {
    "reason": 'without one, "flaky" becomes the reason for everything',
    "owner": "a skip nobody owns is a skip nobody will ever remove",
    "since": "the ratchet needs the date the decision was taken",
    "until": "an entry that cannot expire has stopped being a decision",
}

today = datetime.date.today()
problems = []
seen = {}
entries = 0

for lineno, raw in enumerate(open(path, encoding="utf-8").read().splitlines(), 1):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    entries += 1

    m = LINE.match(line)
    if not m:
        problems.append(
            f"line {lineno}: malformed entry. Expected 'skipped <tier> <suite-id> "
            f"<test-id> reason=\"...\" owner=... since=YYYY-MM-DD until=YYYY-MM-DD' on "
            f"ONE line — a wrapped reason is two entries, one of which is a parse error"
        )
        continue

    fields = {k: v.strip('"') for k, v in FIELD.findall(m.group("fields"))}
    key = (m.group("tier"), m.group("suite"), m.group("test"))

    # Rules 1, 2 and 3: a reason, an owner, and both dates. Each message says
    # why the rule exists, because a bare "missing field" reads like a nit.
    for name in ("reason", "owner", "since", "until"):
        if not fields.get(name):
            problems.append(f"line {lineno}: entry names no {name} — {WHY[name]}")

    if key in seen:
        problems.append(
            f"line {lineno}: duplicate entry, already listed on line {seen[key]}. Two "
            f"lines for one test means one of them is no longer being read"
        )
    seen[key] = lineno

    for name in ("since", "until"):
        value = fields.get(name)
        if not value:
            continue
        try:
            parsed = datetime.date.fromisoformat(value)
        except ValueError:
            problems.append(f"line {lineno}: {name}={value!r} is not an ISO date (YYYY-MM-DD)")
            continue
        # The gate reads the clock. An expired entry is a FAILURE on the day it
        # expires, and the file's own header says so, so nobody is surprised by
        # a red build in January: that is the ratchet working.
        if name == "until" and parsed < today:
            problems.append(
                f"line {lineno}: EXPIRED on {value} (today is {today.isoformat()}). "
                f"Delete the entry, or move the date and write a new reason — a date "
                f"that rolls forward by itself is not a ratchet"
            )

    # Rule 4. Modelled on ESLint's `reportUnusedDisableDirectives`, which reports
    # a disable comment that no longer suppresses anything. Without this rule an
    # allowlist is a ratchet that only turns one way: fixed tests stay listed,
    # listed tests stop being checked, and within two quarters the file contains
    # every test in the repository. The unused entry is how you find out first.
    lookup = f"{m.group('suite')} {m.group('test')}"
    if lookup not in inventory:
        problems.append(
            f"line {lineno}: entry matches NOTHING — no test id {m.group('test')!r} in "
            f"{m.group('suite')}. The test was renamed, or the skip was fixed and the "
            f"entry left behind. Either way it is dead weight, and dead entries are "
            f"how an allowlist becomes a list of every test in the repository"
        )

if problems:
    for p in problems:
        print("  -", p)
    sys.exit(1)

# THE TOTAL, PRINTED ON PASS. The `check` helper prints a passing check's stdout
# indented under its label, so this shows up in a GREEN run — the only place a
# growing list is least likely to be noticed. Individual entries look justified;
# the aggregate is the problem, and an aggregate nobody is shown is an aggregate
# nobody watches. Conftest reports exceptions as a separate tally for this reason.
print(
    f"skip allowlist: {entries} entr{'y' if entries == 1 else 'ies'}, all matched "
    f"against {len(inventory)} declared test ids — none unused, none expired. "
    f"The total is the number to watch."
)
PY
  }
  check 'templates/tier/skip-allowlist  (reason, owner, since, until; unused entries fail)' \
    skip_allowlist_check

  # (4) Never cache a test report.
  #
  #     `actions/cache` `restore-keys` restores STALE caches by PREFIX MATCH, and
  #     GitHub documents that the default branch's cache is available to other
  #     branches. So a key built from `hashFiles('**/lockfile')` — which does not
  #     contain the gate variable — restores a test report written by a run that
  #     HAD the database into a run that does not. A witness restored from a
  #     different run is not a witness.
  #
  #     Build products (target/, $GOCACHE, node_modules, vendor/bundle) are
  #     cacheable and deliberately not caught here. Test reports are.
  #
  #     The cross-trust-boundary half — fork PRs get read-only cache access, so
  #     any workflow using actions/cache can restore a trusted run's report — is
  #     stated in README.md rather than checked here, because it is a property of
  #     GitHub's cache and not of this repository.
  no_cached_report_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import re
import sys

root = sys.argv[1]

# A path that is a test RESULT, not a build product. The alternation is
# anchored on a path segment or the string start, so `reports/coverage.xml` is
# caught and `internal/report.go` is not.
REPORT = re.compile(
    r"(?:^|/)(?:junit|test-?results?|coverage|coverage\.\w+|report\.xml"
    r"|pytest\.xml|nextest\.xml|gotestsum\.xml|karma[\w-]*\.xml)(?:$|[/\s'\"])"
)

problems = []
checked = 0
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in (".git", ".venv", "node_modules")]
    for name in sorted(filenames):
        if not name.endswith((".yml", ".yaml")):
            continue
        full = os.path.join(dirpath, name)
        rel = os.path.relpath(full, root)
        try:
            src = open(full, encoding="utf-8").read()
        except OSError:
            continue
        if "actions/cache" not in src:
            continue
        checked += 1
        # Read as text rather than through yaml: `path:` is a scalar in every
        # shape a cache step takes, and the case that matters most is a
        # multi-line list, which safe_load would flatten into something no error
        # message could quote back at a reader.
        for m in re.finditer(r"^\s*(?:-\s*)?path:\s*(.+)$", src, re.M):
            value = m.group(1).strip().strip("'\"")
            if REPORT.search(value):
                lineno = src[: m.start()].count("\n") + 1
                problems.append(
                    f"{rel}:{lineno}: actions/cache path {value!r} is a test report. "
                    f"restore-keys matches by PREFIX, so a report written by a run "
                    f"that HAD the dependency is restored into a run that did not. "
                    f"Cache build products (target/, GOCACHE, node_modules, "
                    f"vendor/bundle); never a witness"
                )

if problems:
    sys.exit("; ".join(problems))
# The PASS line is written carefully, because the obvious phrasing of it is
# wrong in a way that would mislead the next reader. kit's workflows DO cache —
# `actions/setup-go`, `ruby/setup-ruby` with `bundler-cache`, `setup-node` with
# `cache: npm` and `setup-uv` with `enable-cache` all keep dependency caches —
# and every one of those is a build product. Saying "kit caches nothing" would
# be false; saying what is actually true is the whole point of this check.
print(
    f"{checked} workflow file(s) use actions/cache; none caches a test report. "
    f"Dependency caches (GOCACHE, vendor/bundle, ~/.npm, the uv cache) are build "
    f"products and are not in scope"
    if checked
    else "no actions/cache step in this repo; the rule is for the adopters, and the "
    f"dependency caches kit's own workflows do use (GOCACHE, vendor/bundle, ~/.npm) "
    f"are build products"
)
PY
  }
  check '.github/workflows/*  (no test report is ever cached)' no_cached_report_check

  # Every README section a reader is told to copy must exist. A doc that points
  # at a path that was renamed is worse than no doc.
  readme_check() {
    "$PY" - "$ROOT" <<'PY'
import os
import re
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
    # Directory paths, and checked with exists() rather than isfile() — these are
    # trees, and asking isfile() about a directory reports a missing doc for a
    # directory that is right there.
    #
    # The grafana tree is one entry, not three. Three entries with a file inside
    # each would make the README carry three near-identical table rows so that a
    # check could be satisfied by pasting the paths in, and the thing a reader
    # needs is the tree, not its leaves.
    "templates/compose/grafana/provisioning",
    "templates/compose/loki",
    "templates/compose/tempo",
    "templates/compose/mimir",
    "tests/canary_test.sh",
    "tests/no_telemetry_in_readiness.sh",
):
    if path not in readme:
        problems.append(f"README.md never mentions {path}")
    if not os.path.exists(os.path.join(root, path)):
        problems.append(f"README.md documents {path}, which does not exist")

# The licence condition is the kind of sentence that gets edited away by a
# copy-paste, and it is the one sentence in this file that is a legal statement
# rather than a technical one. Asserted, because "ship them unmodified" only
# helps anybody if the README says it.
for phrase, why in (
    ("AGPL", "the licence of the four backing services must be named"),
    ("unmodified", "the unmodified condition is the whole point of the licence note"),
    ("bring your own", "bring-your-own is a supported deployment, not a degraded mode"),
    ("not a degraded mode", "the phrase itself is the claim being made"),
):
    if phrase.lower() not in readme.lower():
        problems.append(f"README.md does not state {why} (looked for {phrase!r})")

# The escape hatch, and the ports. A self-hoster reads the README and not the
# code, so the variable name has to be in the README and so does the block.
#
# The pattern requires a real service-shaped prefix before `_OTEL_ENDPOINT`.
# `_OTEL_ENDPOINT` on its own is the shape of a variable that has not been
# derived from anything, and the whole point of core's D16 is that the name
# comes from the service name so it is knowable without reading code.
if not re.search(r"`?[A-Z][A-Z0-9]*_OTEL_ENDPOINT`?", readme):
    problems.append(
        "README.md never names the <SERVICE>_OTEL_ENDPOINT contract. A reader who "
        "has to grep the source to learn the variable name is a reader who never "
        "sets it, and a self-hoster who never sets it runs with the shipped stack "
        "by accident."
    )
if "15000" not in readme or "15999" not in readme:
    problems.append("README.md does not state the host port range the stack claims")

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
        d for d in dirnames if d not in (".git", ".venv", "__pycache__")
    ]
    for filename in filenames:
        full = os.path.join(dirpath, filename)
        rel = os.path.relpath(full, root)
        if rel == workflow:
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
fi

# ===========================================================================
# phase: telemetry — execute the traceparent templates
# ===========================================================================

if [ "$RUN_TELEMETRY" -eq 1 ]; then
  # Formatting is part of the template: a service that copies a template
  # formatted differently from its neighbours is a template that reads as ours.
  #
  # BOTH Go template trees, not just otel's. The tier tree was added without
  # this, and `gofmt -d` on it wanted a `#` on every ALL-CAPS doc heading — Go
  # 1.19 reformatted doc comments, and a heading without the marker is one
  # gofmt rewrites. It was found by running gofmt over the new files by hand,
  # which is the part that was actually wrong: a new template tree that no
  # existing check reads is a tree that can be malformed in silence, and the
  # house rule is that a new file type gets its parser in the same commit.
  if have gofmt; then
    for tree in otel tier; do
      if [ -z "$(gofmt -l "$ROOT"/templates/"$tree"/go/*.go 2>&1)" ]; then
        report PASS "templates/$tree/go/*.go  (gofmt clean)"
      else
        report FAIL "templates/$tree/go/*.go  (gofmt clean)"
        gofmt -l "$ROOT"/templates/"$tree"/go/*.go | sed 's/^/       /'
      fi
    done
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
    # ruby only, because ruby is the only one of the six that can fail
    # *silently*: the other five refuse on their own — an old go, an old node
    # or an old rustc fails at build time with a message naming its own
    # requirement — whereas ruby 2.6 loads this template happily and then dies
    # on the first method call, which reads as a behavioural failure. A floor
    # check for a toolchain that already refuses would be a second place to be
    # wrong.
    if [ "$lang" = ruby ]; then
      ruby_seen="$(ruby -e 'print RUBY_VERSION' 2>/dev/null || true)"
      ruby_need="$(ruby_floor || true)"
      if [ -z "$ruby_need" ]; then
        # The template could not be loaded far enough to be asked. That is a
        # defect in the artifact, not an absent interpreter, so it is a FAIL.
        report FAIL "templates/otel/$lang  ($tool test suite)"
        printf '%s\n' \
          "       Could not read KitOtel::RUBY_FLOOR from" \
          "       templates/otel/ruby/traceparent.rb, so the interpreter floor" \
          "       is unknown and the suite cannot be run knowingly. This is a" \
          "       template defect: the constant is how the gate asks the" \
          "       template what interpreter it needs."
        continue
      fi
      if ! version_at_least "$ruby_seen" "$ruby_need"; then
        # A SKIP, not a FAIL, and the distinction is the whole point of this
        # check. The template is correct; the interpreter is too old to run it.
        # Reporting that as a FAIL would keep three landed-or-landing packets
        # blocked by a red that names a file none of them touched. Reporting it
        # as a PASS would be worse — it would claim the suite passed having
        # never run a single test. So: a loud, counted SKIP that names both
        # versions and the one command that fixes it, which is exactly the
        # treatment every other absent toolchain in this file already gets.
        report SKIP "templates/otel/$lang  (ruby $ruby_seen is below the template's $ruby_need floor)"
        printf '%s\n' \
          "       templates/otel/ruby declares KitOtel::RUBY_FLOOR = $ruby_need and the" \
          "       ruby first on PATH is $ruby_seen, so the suite did NOT run. On a" \
          "       conforming interpreter it is green; this is a toolchain fact wearing" \
          "       a template's clothes, not a finding about trace propagation." \
          "       Fix: put a pinned ruby first on PATH — mise exec -- bash tests/validate.sh," \
          "       or any PATH whose ruby is >= $ruby_need. kit's own pin is templates/mise.toml (3.4)."
        continue
      fi
    fi
    check "templates/otel/$lang  ($tool test suite)" "run_$lang"
  done
fi

# ===========================================================================
# phase: observability — the two proofs that need a real collector
# ===========================================================================

if [ "$RUN_OBSERVABILITY" -eq 1 ]; then
  section 'observability: the redaction boundary, against a real collector'

  # Not skippable by preference. A dev machine with no docker gets a reported
  # SKIP, because the alternative — running the suite and reporting PASS while
  # the security claim went unexercised — is the shape of a proof nobody ran.
  if ! have docker; then
    report SKIP 'observability proofs (docker not installed)'
  elif ! docker info >/dev/null 2>&1; then
    report SKIP 'observability proofs (docker daemon not reachable)'
  else
    check 'tests/canary_test.sh  (a canary secret reaches no exporter)' \
      bash "$ROOT/tests/canary_test.sh"
    check 'tests/no_telemetry_in_readiness.sh  (collector killed, service still serves)' \
      bash "$ROOT/tests/no_telemetry_in_readiness.sh"
  fi
fi
# phase: classifier + staleness — the two runnable pieces, executed
# ===========================================================================
#
# Separate from `static` and run unconditionally, because both are the property
# rather than the shape: classify_test asserts that the classifier FAILS on an
# unrecognised change, and staleness_test asserts that the reporter tells
# `current` from `unknown` from `undeclared`. A check that only parses those two
# files would pass on a classifier that waves every change through.
#
# Both scripts build their own fixtures in a temp directory, so neither depends
# on a repository being checked out or on the network.

  # NOTE: deliberately not guarded by RUN_STATIC. kit-05's own comment
  # called these "the property rather than the shape", but the block shipped
  # wrapped in `if [ "$RUN_STATIC" -eq 1 ]`, which would let a static-analysis
  # skip silently drop the fail-closed proof. A gate that skips is not green.
check 'tests/classify_test.sh  (19 cases, incl. the fail-closed property)' \
  bash "$ROOT/tests/classify_test.sh"

section 'staleness: the fleet reporter tells the states apart'
check 'tests/staleness_test.sh  (12 cases, incl. the red proof)' \
  bash "$ROOT/tests/staleness_test.sh"

# ===========================================================================
# phase: self_test — prove the gate can go red
# ===========================================================================

if [ "$RUN_SELF_TEST" -eq 1 ]; then
  section 'self_test: this gate is able to fail'
  # The numbers in this label are COUNTED from self_test.sh's recipes rather than
  # written down. Every breakage calls exactly one of the four red-expecting
  # helpers, so counting those calls is the breakage count by construction — and
  # a hardcoded number is exactly the kind of thing that goes stale quietly when
  # the next packet adds a check. The wording follows from the counts so the two
  # cannot disagree.
  #
  # Two numbers, not one, because breakage 23b asserts something the other
  # twenty-three do not: that a check can report SKIP and still be load-bearing.
  # Counting only reds would have made "24 breakages, 24 reds" a false summary
  # of twenty-four red-assertions plus one green one — the same claim, wearing a
  # number, that nobody would have checked.
  #
  # Both patterns anchor on the BREAKAGE LABEL, not on the helper name. An
  # earlier version anchored on `^expect_` and counted 28 over 23 recipes: the
  # four helper *definitions* are `expect_red() {` and match a bare `^expect_`
  # exactly as well as a call does. Counting the labels cannot hit that, because
  # a function definition never carries one — and a count that over-reports is
  # worse than none, since it is indistinguishable from a correct one.
  _st_breakages=$(grep -cE '^ *expect_(red(_check|_lang|_script)?|skip_check) +.breakage +[0-9]+[a-z]*:' "$ROOT/tests/self_test.sh" || true)
  _st_reds=$(grep -cE '^ *expect_red(_check|_lang|_script)? +.breakage +[0-9]+[a-z]*:' "$ROOT/tests/self_test.sh" || true)

  # The header is a promise about what the file proves, and a promise nobody
  # reads is decoration. Compare the breakage numbers the header NAMES against
  # the numbers the recipes CARRY, so the two cannot drift:
  #
  #   - a recipe with no header entry is a breakage the file proves but does not
  #     claim, which is how a proof quietly stops being one;
  #   - a header entry with no recipe is worse — a claim the file does not
  #     deliver, and the summary line above would be counting the recipes while
  #     the documentation advertises something else.
  #
  # `2b` is parsed as a letter-suffixed continuation of 2 and is expected to
  # appear on both sides, so it is compared literally rather than dropped.
  #
  # EVERYTHING IS A STRING. The first version of this check expanded `7-10` with
  # `range(int(lo), int(hi) + 1)`, so those entries entered the set as `int` while
  # the single entries arrived from the regex as `str`. `named - carried` then
  # reported 7, 8, 9, 10 and every two-digit breakage as both documented-without-
  # a-recipe AND proven-without-being-documented — which is the check reporting a
  # disagreement that did not exist, on a tree that was correct. Normalising to
  # `str` at every point of entry is the whole fix, and the reason it is worth
  # stating: a set difference over two representations of the same number is
  # never empty, so the failure mode is a permanently red check, not a missed one.
  self_test_claims() {
    "$PY" - "$ROOT/tests/self_test.sh" <<'PY'
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()

# Sort by (number, suffix) so 2b lands next to 2 rather than at the end. The
# labels are strings so that `2` and `2b` can be told apart at all.
def breakage_sort(label):
    m = re.fullmatch(r"(\d+)([a-z]?)", label)
    return (int(m.group(1)), m.group(2)) if m else (0, label)


# The header block, up to the first `set -euo`.
header = src.split("set -euo pipefail", 1)[0]

# Breakage numbers as WRITTEN, all as `str`. A header line like `7-10.` is one
# entry naming a range; it is expanded, not counted, so `7-10` in the header is
# matched by breakages 7, 8, 9 and 10 in the recipes.
named = set()
for lo, hi in re.findall(r"^#\s+(\d+)-(\d+)\.", header, re.M):
    named.update(str(n) for n in range(int(lo), int(hi) + 1))
# Individually named entries, optionally letter-suffixed (`2b.`).
named.update(re.findall(r"^#\s+(\d+[a-z]?)\.", header, re.M))

# Breakage numbers as LABELLED, from the recipe invocations.
carried = set(
    re.findall(
        # Either quoting style. Breakage 5's label has always been double-quoted
        # and breakage 4's single; matching one of them would have reported a
        # disagreement that does not exist, and the fix belongs in the pattern
        # rather than in rewriting a working recipe to suit a new check.
        # All FOUR helpers, or the check reports a header/recipe disagreement
        # that does not exist: breakages 21 and 22 are `expect_red_script`, and
        # a pattern missing `_script` calls them undocumented. Same omission as
        # the `_st_breakages` count above — one bug, two symptoms, because the
        # helper list was written down twice.
        #
        # `^ *` and not `^`, and this is the third time this pattern has needed
        # it. Breakages 23 and 23b sit inside a `command -v ruby` guard because
        # their fixture is a stub `ruby`, so their calls are INDENTED — and a
        # column-0 pattern reported two documented breakages as carrying no
        # recipe. The check was right about the disagreement and wrong about the
        # cause: the recipes exist, at column 2. A pattern tight enough to
        # reject a real recipe is not a stricter check, it is a broken one, and
        # the failure it produces looks exactly like missing documentation.
        #
        # `[ \t]*`, not `\s*`: under re.M `\s` matches a newline, so `\s*` could
        # span from the end of one line onto the next and match a `breakage 23:`
        # label belonging to a call that is not a recipe at all. One permissive
        # character here would trade a false negative for a false positive on the
        # very check that exists to catch drift.
        r"""^[ \t]*expect_(?:red(?:_check|_lang|_script)?|skip_check) ['"]breakage\s+(\d+[a-z]?):""",
        src,
        re.M,
    )
)

problems = []
for missing in sorted(named - carried, key=breakage_sort):
    problems.append(f"header documents breakage {missing} but no recipe carries it")
for orphan in sorted(carried - named, key=breakage_sort):
    problems.append(f"recipe proves breakage {orphan} but the header does not document it")

# `sys.exit` rather than `return`: this is a top-level script, not a function
# body, and the other checks in this file use the same shape. A `return` here is
# a SyntaxError at import time — which is exactly how this check first failed.
if problems:
    for p in problems:
        print("  -", p)
    sys.exit(1)
PY
  }
  check 'tests/self_test.sh  (every documented breakage has a recipe, and vice versa)' \
    self_test_claims

  if check "tests/self_test.sh  ($_st_breakages breakages, $_st_reds reds, $((_st_breakages - _st_reds)) skip-proofs)" \
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
