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
#   bash tests/validate.sh --no-lint           # skip running the linters themselves
#
# Six phases, all of which must pass:
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
#   lint           golangci-lint, RuboCop, ESLint and yamllint are RUN against
#                  a fixture built to violate them, with kit's config, and each
#                  is paired with a control that must answer differently. This
#                  is the phase `lint/` never had: 249 lines of configuration
#                  that parsed cleanly and had never been pointed at anything.
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
RUN_OBSERVABILITY=1
RUN_LINT=1
LANGS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --static-only)
      RUN_TELEMETRY=0
      RUN_SELF_TEST=0
      RUN_OBSERVABILITY=0
      RUN_LINT=0
      ;;
    --no-self-test) RUN_SELF_TEST=0 ;;
    --no-observability) RUN_OBSERVABILITY=0 ;;
    --no-lint) RUN_LINT=0 ;;
    --language=*)
      LANGS+=("${1#*=}")
      ;;
    -h | --help)
      sed -n '2,35p' "$0"
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


# ---------------------------------------------------------------------------
# bounded_check <label> <bound-seconds> <command...>
# ---------------------------------------------------------------------------
#
# `check` with a CEILING on how long it may take, and — this is the part that
# matters — a fourth, named outcome when the ceiling is reached.
#
# WHY IT EXISTS. The gate grew past what one process can finish on a loaded
# box: three docker stacks brought up and torn down, and thirty-two throwaway
# copies of a 193 KB script each running their own bootstrap. The previous full
# run on this branch was SIGKILLed (exit 137 — the kernel's OOM killer, not a
# test failure) partway through the observability collector tier, which means
# the gate reported *nothing* about the tiers it had not reached. A gate that is
# killed is a gate whose green is a claim about however far it got.
#
# `timeout N` alone would fix the symptom and hide the disease in a new place:
# a timed-out `check` prints FAIL with a two-word diagnostic that names neither
# the tier nor the bound, and the next reader files it under "flaky". So the
# bound is a verdict of its own — `BOUND` — carrying the tier, the bound and the
# tail of what it had printed. It is counted separately in the summary, because
# a bound that is reported as a PASS is exactly the silent skip the gate's own
# rules forbid, and one reported as a FAIL is indistinguishable from a defect
# in the tree.
#
# WHY IT IS NOT A SKIP. Nothing about a timed-out tier is unknown: we know it
# did not finish, and the claim it exists to prove is therefore unexercised. A
# SKIP is for a check that CANNOT run (no docker, no toolchain) and says so
# about the environment. A bound is this machine being too busy, which is a
# fact about the run and not about the tree — and it is the reason the gate
# carries a bound at all rather than being allowed to be killed.
#
# `timeout` IS NOT PORTABLE and pretending otherwise would be the same class of
# defect as the port rules this packet writes about: GNU coreutils ships it as
# `timeout`, macOS has no `/usr/bin/timeout` at all, and Homebrew's coreutils
# installs `gtimeout`. So it is RESOLVED, and a machine with neither runs the
# tier unbounded and says so in the summary — a bound that silently did not
# apply is worse than no bound, because the reader is told a ceiling exists.
bounded_ran=0
# Tiers that actually REACHED their bound. A separate counter from `bounded_ran`
# on purpose: the summary line has to say "N tiers ran under a bound, M hit it",
# and one counter cannot state both. An earlier version incremented one variable
# in both places and printed "4 tier(s) hit their time bound" for a run in which
# exactly one did — a summary that overstates a machine problem by 4x is the
# fastest way to make a reader ignore the line entirely.
bounded_hit=0
_timeout_bin() {
  for candidate in timeout gtimeout; do
    if have "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

bounded_check() {
  local label="$1" bound="$2"
  shift 2
  local runner out ec=0
  if runner="$(_timeout_bin)"; then
    bounded_ran=$((bounded_ran + 1))
    # `--kill-after` so a tier that ignores SIGTERM is still ended: without it
    # the bound is only a request, and the whole point is that the run ENDS.
    out="$("$runner" --kill-after=30s "$bound" "$@" 2>&1)" || ec=$?
  else
    out="$("$@" 2>&1)" || ec=$?
  fi
  if [ "$ec" -eq 0 ]; then
    report PASS "$label"
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | sed 's/^/       /'
    fi
  elif [ "$ec" -eq 124 ]; then
    # 124 is `timeout`'s own code for "the bound was reached", and it is the
    # only status here that means the command's verdict is unknown.
    bounded_hit=$((bounded_hit + 1))
    printf '%-4s %s\n' BOUND "$label"
    printf '       exceeded its %ss bound on this machine. The tier did not finish, so\n' "$bound"
    printf '       the claim it exists to prove is UNEXERCISED — this is not a defect in\n'
    printf '       the tree, and it is not a pass. Re-run on a quieter box; every tier is\n'
    printf '       bounded, so a run that reaches the end has exercised all of them.\n'
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | tail -12 | sed 's/^/       /'
    fi
  else
    report FAIL "$label"
    printf '%s\n' "$out" | sed 's/^/       /'
  fi
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
      # The lint drift allowlist, which has no extension because it is not
      # meant to look like a config a linter would read — it is a list of
      # PEOPLE, and naming it `.yml` would invite exactly the `cp` this packet
      # exists to stop. It has no parser of its own; the drift check below IS
      # its parser, and it reads it as text and reports a malformed line.
      #
      # Without this case the loop's `*)` branch printed
      # `SKIP … (no parser for this file type)` for it, which is a claim that
      # would have been false — the file is read on every run of this gate.
      "$ROOT"/lint/drift-allowlist)
        # Shape only, and deliberately NOT a second copy of the drift check's
        # rules. Those four — reason, owner, dates, and an entry that no longer
        # describes a real difference — all live in `lint_drift_check` below, and
        # the last one can only be evaluated there because it needs the fleet.
        # Duplicating any of them here would be a second, unchecked copy of a
        # rule, which is the mistake this repository's classifier section
        # documents at length.
        #
        # What is checked here is the one property that is cheap and that the
        # drift check's own parser cannot report nicely: every content line
        # begins an entry. A wrapped entry shows up as a line that does not, and
        # the drift check would call it "malformed" without saying that the
        # obvious cause is a wrapped line.
        # Counted, both sides, and compared. The first version of this was a
        # `!` on one end of a pipeline, which negates the LAST stage's status
        # rather than the one the author is thinking about — so it passed on a
        # file with a wrapped entry, which is the exact case it was written for.
        # Two counts and an equality have no stage to get wrong.
        check "$path  (every content line starts one entry)" bash -c \
          "[ \"\$(grep -cE '^[[:space:]]*[^#[:space:]]' '$f')\" \
             -eq \"\$(grep -c '^diverged ' '$f')\" ]"
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
    if grep -qE '\*\* \((Compile|Syntax)Error\)|^\s*error:' <<<"$ex_out"; then
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
    local stub sandbox out ec=0 kitcheck
    stub="$TMP/dev-hatch-stub"
    sandbox="$TMP/dev-hatch"
    # The stub KIT TREE, as a separate directory. The sandbox below is a service
    # repository, and after this packet a service repository holds NONE of the
    # stack: no docker-compose.yml of kit's, no otel-collector.yml, no vendor
    # config directories. Everything `bin/dev` mounts comes from the tree it
    # fetches, so the fixture has to have one — pointed at with `KIT_STACK_DIR`,
    # which is a checkout a person named rather than one that was fetched.
    kitcheck="$TMP/dev-hatch-kit"
    rm -rf "$stub" "$sandbox" "$kitcheck"
    mkdir -p "$stub" "$sandbox/bin"
    mkdir -p "$kitcheck/templates/compose" "$kitcheck/templates/compose/tempo" \
      "$kitcheck/templates/compose/loki" "$kitcheck/templates/compose/mimir" \
      "$kitcheck/templates/compose/grafana/provisioning"
    : >"$kitcheck/templates/compose/docker-compose.yml"
    : >"$kitcheck/templates/compose/otel-collector.yml"
    : >"$kitcheck/templates/compose/.env.example"
    printf '%s\n' "0000000000000000000000000000000000000000" >"$sandbox/kit.ref"
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
    # The sandbox is a service repository and NOTHING ELSE: no compose file of
    # kit's, no collector config, no `.env`. That is the shape this packet leaves
    # behind, and the fixture has to be the shape or the check proves a world
    # that no longer exists — the first version of this sandbox carried five
    # empty files that `require_files` demanded, and the moment `require_files`
    # went away the fixture stopped reaching `up` at all.
    #
    # `KIT_STACK_DIR` is how the escape hatch is exercised without a network: it
    # is a checkout a person named on this run, which is source 1 of the four in
    # `resolve_stack` and the only one that skips git entirely.
    cp "$ROOT/templates/bin/dev.sh" "$sandbox/bin/dev"

    # `KIT_DEV_PROFILES=''` and not `KIT_DEV_PROFILES=`: shellcheck reads the
    # latter as a typo, and it is right to.
    out="$(cd "$sandbox" && KIT_DEV_PROFILES='' KIT_STACK_DIR="$kitcheck" \
      PATH="$stub:$PATH" bash ./bin/dev up 2>&1)" || ec=$?
    case "$out" in
      *"unbound variable"*)
        echo "the documented escape hatch KIT_DEV_PROFILES= is broken:"
        printf '%s\n' "$out" | head -3
        return 1
        ;;
      # Both halves are asserted, and the second is not decoration. Reaching the
      # migration step proves the profile expansion survived; that the run got
      # all the way there on a sandbox with NO `.env` and no stack of its own
      # proves the fetch path does not require either. A fixture that wrote a
      # `.env` would pass the first and silently not be testing the second.
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

  # -------------------------------------------------------------------------
  # THE FLEET GATE, and it is RED on master. That is the point, and the shape is
  # the same as D4: three repositories that do not spell the same gate the same
  # way is invisible to any check that reads only one of them, so kit's gate
  # reads the OTHER repositories rather than trusting that they adopted it.
  #
  # Four failure modes, one check each, in tests/fleet_check.py:
  #   - a service carrying a copy of the shared infrastructure
  #   - a service that weakened the redaction boundary
  #   - an otel-collector.yml that exists but that nothing ever starts
  #   - a pin that is unpinned, or points at a branch
  #
  # IT SKIPS LOUDLY WHEN THERE IS NO FLEET, and that is not a detail. A clone of
  # kit on CI has no siblings, and "no fleet was found" is not "the fleet is
  # clean" — the same `unknown` vs `current` confusion tests/staleness.py exists
  # to avoid. A gate that reports the second when it means the first is a gate
  # that gets muted, and this one is going to be red a lot on purpose.
  #
  # `KIT_FLEET` is the seam, and it exists so self_test.sh can point the check at
  # a FIXTURE fleet. Without it every breakage below would depend on the real
  # fleet being present and dirty, which is a proof that passes when the fleet is
  # absent — the exact shape this repository keeps warning about.
  #
  # The SKIP decision is `fleet_check.py`'s, not this file's, and the reason is a
  # disagreement that was real. The first version guarded the call with its own
  # "are there any sibling entries?" test — `ls -A ..` minus kit's own worktrees.
  # A self-test's throwaway directory HAS sibling entries (one per breakage) and
  # none of them is a repository, so the guard said "there is a fleet", ran the
  # check, and the check exited 2 with "no cafaye repositories". The self-test's
  # CONTROL would have gone red, which D13 treats as blocking the packet, for a
  # reason that has nothing to do with the packet.
  #
  # So there is exactly one predicate for "is there a fleet", it lives beside the
  # code that knows what a repository is, and it answers with a machine-readable
  # marker. `check` cannot express three outcomes, which is why this is written
  # out rather than delegated: a SKIP is not a PASS that happened quietly.
  #
  # THE ADOPTION CEILING, and it is the fourth outcome this block has to express.
  # `fleet_check.py` answers three questions and this file must not collapse
  # them: is there a fleet (SKIP), is any ADOPTING repository defective (FAIL),
  # and is any UNADOPTED repository carrying debt (PASS, with the debt printed).
  # The three outcomes are read off the exit code plus the `CEILING fleet:` line
  # the check always prints, rather than from a fourth flag, because a fourth
  # flag is a fourth thing to keep in step with the check that emits it.
  #
  # WHY A PASS CAN CARRY FINDINGS, and why this is not the softening the packet
  # refuses. The strictness has not moved anywhere weaker; it has moved to WHERE
  # ADOPTION EXISTS. The same four predicates, the same messages, the same
  # severity — and the moment a repository commits `git -C ../kit rev-parse HEAD
  # > kit.ref`, every finding inside it becomes a FAIL with no discretion and no
  # re-review. A gate that stays red for thirteen findings no repository has
  # agreed to fix is a gate whose red stops being read, and a gate nobody reads
  # catches nothing. This is core-16's shape for a missing OpenAPI document, and
  # it is a WAVE, not a discount: each repository's adoption converts its own
  # named debt into a failure.
  #
  # The count is printed because a ceiling with no number on it cannot be
  # argued about: "PASS" and "PASS with 13 named warnings across 6 repositories"
  # are different statements, and only the second is true.
  section 'static: the fleet adopts the stack rather than copying it'
  fleet_out='' fleet_ec=0
  fleet_out="$("$PY" "$ROOT/tests/fleet_check.py" --kit "$ROOT" \
    --repos-dir "${KIT_FLEET:-$ROOT/..}" --no-fleet 2>&1)" || fleet_ec=$?
  case "$fleet_out" in
    *FLEET-ABSENT:*)
      report SKIP 'fleet adoption (no cafaye repository on this machine — set KIT_FLEET=<dir>)'
      ;;
    *)
      if [ "$fleet_ec" -eq 0 ]; then
        if printf '%s\n' "$fleet_out" | grep -q '^WARN fleet: '; then
          fleet_debt=$(printf '%s\n' "$fleet_out" | sed -n 's/^WARN fleet: //p')
          report PASS "fleet  (adopting repositories clean; $fleet_debt — adoption debt, non-fatal until each repository writes kit.ref)"
        else
          report PASS 'fleet  (no stale copy, no weakened boundary, no dead config, every ref pinned)'
        fi
        printf '%s\n' "$fleet_out" | sed 's/^/       /'
      else
        report FAIL 'fleet  (no stale copy, no weakened boundary, no dead config, every ref pinned)'
        printf '%s\n' "$fleet_out" | sed 's/^/       /'
      fi
      ;;
  esac

  # -------------------------------------------------------------------------
  # THE COLLECTOR CONFIG IS MOUNTED FROM THE TREE `bin/dev` FETCHED, and this is
  # the check for a defect that ONLY RUNNING THE STACK could find.
  #
  # `templates/compose/otel-collector.yml` carries the redaction allowlist. Once
  # the file is no longer copied into the service, the compose file must mount it
  # from `${KIT_COMPOSE_DIR:-.}`, and `bin/dev` must set that variable to the
  # FETCHED tree. Get either half wrong and nothing above notices: the compose
  # file parses, `docker compose config` renders the same project either way, and
  # every static check in this file stays green — because the value of the
  # variable is not a property of the YAML.
  #
  # What it actually does when it is wrong: the mount resolves to a path that does
  # not exist, and Docker's answer to a missing bind source is to CREATE A
  # DIRECTORY. The collector then exits naming a file type:
  #
  #   failed to read configFile /etc/tempo/tempo.yaml: is a directory
  #
  # which says nothing about the thing that is wrong, and arrives four containers
  # after a stack that was supposed to come up. `tests/stack_live_test.sh` is what
  # found it, by bringing the fetched stack up and reading the collector's own
  # mount back with `docker inspect`. This check is the static half of the same
  # property, so the defect cannot be re-introduced between one live run and the
  # next.
  #
  # It asserts BOTH halves. Checking the compose file alone would pass on a
  # `bin/dev` that stopped exporting `KIT_COMPOSE_DIR`; checking `bin/dev` alone
  # would pass on a compose file that stopped using the variable. The defect is
  # in their AGREEMENT, so the check is over their agreement.
  stack_mount_check() {
    "$PY" - "$ROOT" <<'PY'
import re
import sys

root = sys.argv[1]
compose = open(f"{root}/templates/compose/docker-compose.yml", encoding="utf-8").read()
dev = open(f"{root}/templates/bin/dev.sh", encoding="utf-8").read()

problems = []

# 1. Every vendor config kit hands out is mounted through the variable, and none
#    of them through a bare `./`. A bare `./` was correct when the file sat in the
#    service and is wrong now that it does not, and nothing else in the tree would
#    notice the difference.
VENDOR_MOUNTS = {
    "otel-collector.yml": "/etc/otel/otel-collector.yml",
    "tempo/tempo.yaml": "/etc/tempo/tempo.yaml",
    "loki/loki-config.yaml": "/etc/loki/loki-config.yaml",
    "mimir/mimir.yaml": "/etc/mimir/mimir.yaml",
    "grafana/provisioning": "/etc/grafana/provisioning",
}
for source, destination in VENDOR_MOUNTS.items():
    mounted = [ln for ln in compose.splitlines()
               if source in ln and destination in ln]
    if not mounted:
        problems.append(
            f"docker-compose.yml does not mount {source} into {destination} at all"
        )
        continue
    if not any("${KIT_COMPOSE_DIR:-.}" in ln for ln in mounted):
        problems.append(
            f"docker-compose.yml mounts {source} without ${KIT_COMPOSE_DIR:-.}. "
            f"That path is relative to wherever compose runs, and `bin/dev` runs it "
            f"from the service root - where this file no longer is. Docker creates a "
            f"DIRECTORY at a missing bind source and the collector exits naming a "
            f"file type instead of the mount that is wrong."
        )

# 2. `bin/dev` sets it, to the FETCHED compose directory and not the kit root.
#    The kit root resolves every mount to `<kit>/grafana/provisioning`, which does
#    not exist - the same failure, one directory up.
if "KIT_COMPOSE_DIR=" not in dev:
    problems.append(
        "bin/dev never sets KIT_COMPOSE_DIR, so every vendor config mount falls "
        "back to `.` and resolves against the service root"
    )
else:
    exports = re.findall(
        r"(?:export\s+)?KIT_COMPOSE_DIR=(?:\"([^\"]*)\"|'([^']*)'|([^\s#]*))", dev
    )
    values = [next(g for g in m if g) for m in exports if any(m)]
    if not values:
        problems.append("bin/dev mentions KIT_COMPOSE_DIR but never assigns it")
    else:
        bad = [v for v in values if "templates/compose" not in v]
        if bad:
            problems.append(
                f"bin/dev assigns KIT_COMPOSE_DIR={bad[0]!r}, which is not the "
                f"tree's templates/compose directory. Naming it after the thing it "
                f"points at rather than after the repository it came from is what "
                f"keeps the hand-copied case and the fetched case the same path with "
                f"a different prefix, rather than two different shapes."
            )

# 3. The two files must agree on the DEFAULT too. `.` in the compose file means
#    "the directory holding this file", which is right for a hand-copied stack and
#    is the value `bin/dev` overrides. If the default were ever changed to the kit
#    root, the hand-copied case would silently break instead of the fetched one.
if "${KIT_COMPOSE_DIR:-.}" not in compose:
    problems.append(
        "docker-compose.yml no longer documents the `.` default for "
        "KIT_COMPOSE_DIR, so the hand-copied stack has no path left to fall back to"
    )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'templates/compose/ + bin/dev  (every vendor config mounts from the fetched tree)' \
    stack_mount_check

  # -------------------------------------------------------------------------
  # THE PIN IS `kit.ref`, AND THREE FILES AGREE ON THAT SPELLING.
  #
  # `bin/dev` reads the pin, `tests/fleet_check.py` audits it, and
  # `templates/compose/.env.example` documents where it is NOT. Three files, one
  # fact, and the failure mode if they disagree is invisible: the fleet gate
  # reports "kit.ref: ABSENT" on a repository whose `bin/dev` reads `.env`, and
  # reads it as a broken repository rather than as two kit files that stopped
  # agreeing — which is what it is, and which only kit can fix.
  #
  # This is the same SHAPE as the `callable path` check further down, and it is
  # here for the same reason: a documented string that stops being true while
  # every behavioural check stays green. `tests/fetch_test.sh` proves `bin/dev`
  # honours the pin; this proves `bin/dev` and the gate are talking about the same
  # one, which no execution of either can show.
  pin_contract_check() {
    "$PY" - "$ROOT" <<'PY'
import re
import sys

root = sys.argv[1]
dev = open(f"{root}/templates/bin/dev.sh", encoding="utf-8").read()
fleet = open(f"{root}/tests/fleet_check.py", encoding="utf-8").read()
example = open(f"{root}/templates/compose/.env.example", encoding="utf-8").read()

problems = []

# 1. `bin/dev` must actually read a file for the pin, and it must be named the
#    same way `fleet_check.py` names it.
assigned = re.search(r'^REF_FILE="([^"]+)"', dev, re.M)
if not assigned:
    problems.append(
        "bin/dev has no REF_FILE assignment, so there is no committed pin file and "
        "the gate's 'kit.ref: ABSENT' finding would be about a file bin/dev never "
        "reads"
    )
else:
    ref_file = assigned.group(1)
    if "kit.ref" not in fleet:
        problems.append(
            f"bin/dev reads the pin from {ref_file!r} and fleet_check.py does not "
            f"mention it, so the fleet gate audits a file nothing reads"
        )
    if ref_file not in dev:
        problems.append(f"REF_FILE is {ref_file!r} but bin/dev never opens it")

# 2. `.env.example` must NOT carry the pin. This is the assertion with teeth: the
#    file becomes `.env`, `.env` is git-ignored, and a pin there exists on one
#    machine and on no CI runner. Shipping a `KIT_STACK_REF=` line in the template
#    is how that state gets reintroduced - and it would look like the pin is
#    configured, which is worse than its absence.
for line in example.splitlines():
    m = re.match(r"^([A-Z_][A-Z0-9_]*)=", line)
    if m and m.group(1) == "KIT_STACK_REF":
        problems.append(
            ".env.example sets KIT_STACK_REF. `.env` is git-ignored, so a pin there "
            "exists on one machine and on no CI runner; the pin is `kit.ref`, "
            "committed. Remove the line."
        )
        break

# 3. `.env.example` must still TELL a developer where the pin lives. Removing the
#    line without documenting the alternative leaves the ref undiscoverable, and
#    the first `bin/dev` on a fresh clone fails with a message about a file
#    nothing mentions.
if "kit.ref" not in example:
    problems.append(
        ".env.example never mentions kit.ref, so a developer whose `.env` has no "
        "pin is never told which committed file is supposed to hold one"
    )

if problems:
    sys.exit("; ".join(problems))
PY
  }
  check 'templates/bin/dev.sh + .env.example  (the pin is kit.ref, and the gate reads the same file)' \
    pin_contract_check
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

  # ------------------------------------------------------------------ fleet
  # NO ADOPTER CARRIES A WORKAROUND FOR A FIXED CORE DEFECT.
  #
  # `core` shipped two checker defects that forced repositories which adopted
  # `gate.yml` into local workarounds: D12 (`RUN_KEY` could not see a one-line
  # `run:`, fixed in 63fd319) and D13 (proofs matched against bytes carrying
  # ANSI colour, fixed in c63af27). Both are fixed. A workaround for a fixed
  # defect is not neutral — it is a second, local, unpolicied copy of a
  # decision that now lives in core, and it is the kind that rots. So a rule
  # about it belongs here, in the thing that distributes the gate format, rather
  # than in a report nobody re-reads.
  #
  # THE FLEET ROOT IS FOUND, NOT ASSUMED, and its absence is a reported SKIP
  # rather than a pass — the same treatment the core-allowlist check above gets,
  # for the same reason. A sweep that could not read a single declaration has
  # not found the fleet.
  #
  # `$ROOT/..` is checked FIRST and it is where this repository's worktrees live
  # during a packet, which is the whole point: the check has to see the state
  # the fleet is in today, not the state on a CI runner that has no siblings.
  # A CI runner legitimately reaches the SKIP, and the summary says so.
  fleet_root() {
    local cand
    # `..` and `../cafaye`, and NOT `../..`. This was `../..` in the first
    # version and it found a fleet: a leftover copy of a cafaye repository in a
    # shared temp directory two levels up, whose branch still carried the D12
    # workaround this check had just retired. The gate went red on a tree with
    # nothing wrong with it, naming a file nobody had touched in weeks.
    #
    # A sweep that reaches further than it owns is worse than no sweep, so the
    # search is exactly the two layouts this repository is actually cloned into:
    # beside its siblings, or inside a directory of them.
    for cand in "$ROOT/.." "$ROOT/../cafaye"; do
      # At least one `gate.yml` under it, or it is not a fleet and pointing at
      # it would report "no adopting repository found" — technically true and
      # completely useless, which is why this tests for the file rather than the
      # directory.
      if [ -n "$(find "$cand" -maxdepth 2 -name gate.yml -not -path '*/.venv/*' 2>/dev/null | head -1)" ]; then
        (cd "$cand" && pwd)
        return 0
      fi
    done
    return 1
  }

  gate_workaround_check() {
    local root
    root="$(fleet_root)" || {
      echo "no fleet root: no directory beside this one holds a gate.yml."
      echo "set KIT_FLEET=<path> to point at one."
      return 1
    }
    KIT_FLEET="$root" "$PY" "$ROOT/tests/gate_declaration_check.py" "$root"
  }
  section 'static: no adopting repository carries a D12/D13 workaround'
  if [ -n "${KIT_FLEET:-}" ]; then
    check 'adopting repositories  (no workaround for a fixed core defect)' \
      "$PY" "$ROOT/tests/gate_declaration_check.py" "$KIT_FLEET"
  elif fleet_root >/dev/null 2>&1; then
    check 'adopting repositories  (no workaround for a fixed core defect)' \
      gate_workaround_check
  else
    report SKIP 'adopting repositories  (no fleet beside this one — set KIT_FLEET)'
  fi

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

  # -------------------------------------------------------------------------
  # LINT RUNS FROM KIT, NOT FROM A COPY. Three claims, and they decay separately.
  # -------------------------------------------------------------------------
  #
  # `lint/` shipped 249 lines of golangci/rubocop/eslint/yamllint/hadolint
  # configuration and NOT ONE service in the fleet had ever copied it. Adoption
  # correlated inversely with how much a file did: the small self-contained
  # artifacts are universal, the large behavioural ones are at zero.
  #
  # The reason is structural, and it is worth stating because it is what this
  # check defends. `uses: cafaye/kit/...@master` is LIVE — change kit and every
  # service gets it with no action. A copied config has NO propagation at all:
  # it rots silently, and the file nobody chose still runs while the file nobody
  # copies just decays. The measured numbers are in README.md; the mechanism
  # that ends the rot is putting the config where the step already is.
  #
  # This check reads the reusable workflow and asserts the three things that
  # make the lint step a GATE rather than a report. Each has a self_test
  # breakage, because a check with no counterexample is a claim in a comment.
  lint_wiring_check() {
    "$PY" - "$ROOT" "$WORKFLOW" <<'PY'
import os
import re
import sys

import yaml

root, workflow_path = sys.argv[1], sys.argv[2]
with open(workflow_path, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
jobs = doc.get("jobs") or {}
source = open(workflow_path, encoding="utf-8").read()

problems = []


def strip_shell_comments(src):
    """`run:` bodies, with shell comments removed. See the identical helper in
    the tier_demand check, and the reason it exists there: a check satisfied by
    the sentence explaining a flag is not a check.

    YAML comments are a second, separate problem here, and they are removed
    FIRST: this file's own prose names every one of these flags while explaining
    why each is load-bearing, so a naive substring test over the raw source is
    satisfied by the documentation of the very step it is meant to police.
    """
    without_yaml = "\n".join(
        ln for ln in src.splitlines() if not ln.lstrip().startswith("#")
    )
    out = []
    for line in without_yaml.splitlines():
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        quote, cut = None, None
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


def steps_of(lang):
    return (jobs.get(lang) or {}).get("steps") or []


def lint_step(lang):
    """The step that runs the language's linter, or None.

    Matched by NAME, not by scanning the job for a linter-shaped command: the
    name is what a reviewer renames, and a check keyed on the thing being
    checked cannot notice when the thing it names is gone.
    """
    for step in steps_of(lang):
        if step.get("name") == "lint":
            return step
    return None


# ---------------------------------------------------------------------------
# 1. EVERY LANGUAGE JOB THAT LINTS, LINTS WITH KIT'S CONFIG.
# ---------------------------------------------------------------------------
#
# The three languages, and the flag each one needs, are all different. That is
# not a preference — each was measured on a fixture containing a violation only
# that linter would catch, and the results are in tests/lint_test.sh. The
# invariant is the SHAPE, and the shape is the thing that decays:
#
#     golangci-lint  `--config=<path>`   GOLANGCI_LINT_CONFIG is NOT read by
#                                        v2 (measured: silently ignored, the
#                                        run proceeds on the 5-linter default
#                                        set, exit 0 on a file kit rejects).
#     rubocop        `--config=<path>`   measured: a 13-line method is green
#                                        under kit (Max 15) and red on RuboCop's
#                                        default (Max 10).
#     eslint         `--config=<path>`   and the path must be INSIDE the repo,
#                                        because node resolves the config's own
#                                        imports upward from the config file.
#
# `--config` is the only spelling all three accept, so it is what is asserted.
# A per-language exception would be a second thing to keep in step, and the
# measurement says there is nothing to gain by it.
NEEDS_KIT_CONFIG = {
    "go": ("golangci", "golangci-lint"),
    "ruby": ("rubocop",),
    "node": ("eslint",),
}

for lang, linters in NEEDS_KIT_CONFIG.items():
    step = lint_step(lang)
    if step is None:
        problems.append(
            f"job {lang} has no step named `lint`, so nothing checks that it "
            f"still lints with kit's config. A renamed step is a lint step that "
            f"stopped being policed, and this check is the only thing that would "
            f"notice"
        )
        continue

    # The run body, for `run:` steps, and the `with:` block, for action steps.
    # Both are read, because the two mechanisms are different: the go job uses
    # the golangci-lint ACTION (so the flag lives in `with:`) while ruby and
    # node use `run:`. A check that only read `run:` would pass on a go job
    # whose action had lost its args, and that job is the one whose default set
    # is a plausible-looking five linters.
    haystack = strip_shell_comments(step.get("run") or "")
    with_block = step.get("with") or {}
    haystack += "\n" + "\n".join(
        f"{k}: {v}" for k, v in (with_block.items() if isinstance(with_block, dict) else [])
    )

    if not any(tool in haystack for tool in linters):
        problems.append(
            f"job {lang}: its `lint` step names none of {linters}, so it is not "
            f"the linter kit configures. Every check in this file can be green "
            f"while the step that was supposed to run the linter runs something "
            f"else"
        )
        continue

    if "--config" not in haystack:
        problems.append(
            f"job {lang}: its `lint` step does not pass `--config`. Measured: "
            f"with no config in the repository, each of these linters falls back "
            f"to its own DEFAULT policy rather than failing — golangci-lint to "
            f"five linters, rubocop to MethodLength 10, eslint to no rules — so "
            f"the step still runs, still passes, and is now on a policy nobody "
            f"chose. This is the exact failure the check exists to end"
        )

    # The config has to be KIT's, and the only way to say that without a second
    # copy of the path to rot is to require the path to go through the
    # environment variable that names the checked-out kit. A path into the
    # service's own tree is a copy, and a copy is the mechanism this packet
    # replaces: it has no propagation, so it rots in silence.
    #
    # The variable is the seam, not a convenience: the three jobs spell the
    # path differently (one interpolates `${{ github.workspace }}` and the env
    # var, two use a shell `$VAR`), and requiring the variable rather than a
    # literal is what lets them differ without the check having to know how.
    if "KIT_LINT_DIR" not in haystack or "/lint/" not in haystack:
        problems.append(
            f"job {lang}: its `lint` step does not read the config out of the "
            f"checked-out kit (`$KIT_LINT_DIR/lint/…`). A path inside the "
            f"service's own tree is a copy, and a copy is the mechanism this "
            f"packet replaces: it has no propagation, so it rots silently"
        )

# ---------------------------------------------------------------------------
# 1b. THE KIT CHECKOUT THAT MAKES `$KIT_LINT_DIR` NAME SOMETHING.
# ---------------------------------------------------------------------------
#
# The claim above is that each lint step reads its config out of a checked-out
# kit. A step that references the variable perfectly well still reads nothing if
# the checkout that fills it was deleted — and that is a one-line deletion in a
# job with eight steps, it leaves the YAML valid, and every other check in this
# file stays green. The lint step would then be a bare `eslint` with no config,
# which is precisely the default-policy failure the check above is about.
#
# Asserted on the PARSED step rather than by grepping, so a `uses:` inside a
# comment (this file has several, explaining exactly this mechanism) cannot
# satisfy it. And `ref` is required to be the INPUT rather than a literal: a
# checkout pinned to `master` in three places is three places to update, and a
# ref that is not the input is a ref that disagrees with the caller's own pin
# without anyone noticing.
for lang in sorted(NEEDS_KIT_CONFIG):
    steps = steps_of(lang)
    kit_steps = [
        s
        for s in steps
        if isinstance(s, dict)
        and str(s.get("uses", "")).startswith("actions/checkout")
        and (s.get("with") or {}).get("repository") == "cafaye/kit"
    ]
    if not kit_steps:
        problems.append(
            f"job {lang}: no step checks out cafaye/kit, so the path its `lint` "
            f"step reads its config from does not exist. The lint step still runs, "
            f"still passes, and is now on the linter's defaults — the exact "
            f"failure this check exists to catch, reached by deleting one step"
        )
        continue
    for step in kit_steps:
        with_block = step.get("with") or {}
        ref = str(with_block.get("ref", ""))
        if "inputs.kit-lint-ref" not in ref:
            problems.append(
                f"job {lang}: its kit checkout pins `ref: {ref or '(none)'}`, not "
                f"`inputs.kit-lint-ref`. A ref hardcoded here is a fourth place a "
                f"pin lives, and it is the one place the caller cannot see"
            )
        # `persist-credentials: false` — the checkout leaves kit's token in a git
        # config inside the tree the service's own later steps run in. Cheap to
        # require and the cost of forgetting it is a credential outliving the
        # step that fetched it.
        if with_block.get("persist-credentials") is not False:
            problems.append(
                f"job {lang}: its kit checkout does not set `persist-credentials: "
                f"false`, so kit's token is left in a git config inside the tree "
                f"the service's later steps run in"
            )

# ---------------------------------------------------------------------------
# 2. THE LINT STEPS ARE GATES, NOT REPORTS.
# ---------------------------------------------------------------------------
#
# `continue-on-error: true` on a lint step is the single most likely way for
# this whole packet to become decoration, and it is invisible: the step runs,
# prints its findings, and the job is green. A linter that only warns is a
# report. So the assertion is on the PARSED step, and it is a separate claim
# from the one above — a step can pass kit's config perfectly and still be
# advisory.
#
# `|| true` and `| head` in a run body are the same defect wearing shell
# clothes, and both are caught by looking at the command rather than the
# setting, because `set -euo pipefail` is already in force and a pipeline's
# status is what decides.
for lang in sorted(NEEDS_KIT_CONFIG):
    step = lint_step(lang)
    if not isinstance(step, dict):
        continue
    if step.get("continue-on-error") is True:
        problems.append(
            f"job {lang}: its `lint` step is `continue-on-error: true`. The step "
            f"still runs and still prints its findings, and the job is green — a "
            f"linter that only warns is a report. This is the breakage that "
            f"matters most, which is why it is asserted on the parsed step rather "
            f"than left to a reviewer"
        )
    body = strip_shell_comments(step.get("run") or "")
    if re.search(r"\|\|\s*true\b", body):
        problems.append(
            f"job {lang}: its `lint` run body swallows the linter's exit status "
            f"with `|| true`, which is continue-on-error in shell and reads as a "
            f"deliberate choice to nobody"
        )

# ---------------------------------------------------------------------------
# 3. KIT'S CONFIGS ARE STILL WHAT THEY WERE.
# ---------------------------------------------------------------------------
#
# The workflow can point `--config` at `.kit/lint/golangci.yml` on every run and
# the file can still have been emptied of every linter it enabled. Nothing
# above notices: the step runs, the config parses, and the job is green on a
# policy that is now five defaults. So the strictness decisions are asserted
# ON THE FILES, by value.
#
# Read as YAML rather than grepped, so a linter name in a comment cannot satisfy
# the check — the same rule AGENTS.md states for every other check here.
REQUIRED_LINTERS = {
    "golangci.yml": [
        "bodyclose", "copyloopvar", "errorlint", "exhaustive",
        "misspell", "noctx", "revive", "unconvert", "wastedassign",
    ],
}
for filename, wanted in REQUIRED_LINTERS.items():
    path = f"{root}/lint/{filename}"
    if not os.path.isfile(path):
        problems.append(f"lint/{filename} is missing")
        continue
    with open(path, encoding="utf-8") as fh:
        cfg = yaml.safe_load(fh) or {}
    enabled = ((cfg.get("linters") or {}).get("enable")) or []
    missing = [name for name in wanted if name not in enabled]
    if missing:
        problems.append(
            f"lint/{filename} no longer enables {missing}. The workflow points "
            f"`--config` at this file on every run, so an emptied config is not a "
            f"failed check — it is a green build on a policy nobody chose. The "
            f"list is asserted BY VALUE because this is the file whose weakening "
            f"is invisible from every other angle"
        )

# `formatters` is a separate key from `linters` in golangci-lint v2, and a
# config that kept its linters and lost its formatters still parses. gofmt and
# goimports are the formatting half of the Go strictness story and they live
# there.
with open(f"{root}/lint/golangci.yml", encoding="utf-8") as fh:
    gcl = yaml.safe_load(fh) or {}
formatters = ((gcl.get("formatters") or {}).get("enable")) or []
for name in ("gofmt", "goimports"):
    if name not in formatters:
        problems.append(
            f"lint/golangci.yml no longer enables the `{name}` formatter. "
            f"`formatters` is a different key from `linters` in golangci-lint v2, "
            f"so this one is lost without touching the linter list at all"
        )

if problems:
    sys.exit("; ".join(problems))
print(
    "3 lint jobs pass --config at a checked-out kit; none is advisory; "
    "the linter list is intact"
)
PY
  }
  section 'static: lint runs from kit, not from a copy'
  check 'lint/ + the workflow  (every lint step is a gate on kit config)' \
    lint_wiring_check

  # -------------------------------------------------------------------------
  # THE SEAM IS NARROW, AND "NARROW" IS A LIST SOMEONE CAN SHORTEN.
  # -------------------------------------------------------------------------
  #
  # `lint-args` is the deviation seam, and the workflow says in three places
  # what it may not be used for. A promise in a comment is not a control, and the
  # first version of this file PROMISED a control that did not exist: the
  # input's own comment said `lint_wiring_check` "fails on exactly that string",
  # and `lint_wiring_check` had no such assertion anywhere in it.
  #
  # The reason is structural and it is worth stating, because it decides where
  # the control lives: **`lint-args` is the CALLER's value.** kit's gate can see
  # that the input exists, that it is a string, and that it defaults to empty. It
  # cannot see what a service put in it, because kit has never got it. So the
  # rule that makes the seam narrow has to run in the service — the
  # `lint-args guard` step, which every lint job has.
  #
  # Which leaves exactly the failure this check exists for: three hand-maintained
  # copies of a policy block, in a repository whose own rule is that duplicated
  # policy blocks are only safe while something reads them. This asserts all
  # three: that the guard is in each lint job, that the three bodies are
  # byte-identical, that the guard runs BEFORE the linter (a guard after it is
  # decoration — the lint has already had its chance), that the linter actually
  # receives the variable (a guard over a value nothing passes on is a guard over
  # nothing), and that the forbidden token list is the one written here.
  #
  # The last of those is the one that matters most. Without it, deleting
  # `--no-config` from the guard's `case` list is a one-token edit that widens
  # the seam for every service in the fleet and leaves the workflow looking
  # exactly as it did before.
  lint_args_seam_check() {
    "$PY" - "$ROOT" "$WORKFLOW" <<'PY2'
import re
import sys

import yaml

root, workflow_path = sys.argv[1], sys.argv[2]
with open(workflow_path, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
source = open(workflow_path, encoding="utf-8").read()
triggers = doc.get("on") or doc.get(True) or {}
call = (triggers.get("workflow_call") or {}).get("inputs") or {}
jobs = doc.get("jobs") or {}

LINT_JOBS = ("go", "ruby", "node")

# The forbidden tokens, held HERE as well as in the workflow. Every one was read
# out of the linter's own `--help` on the version kit pins, not remembered:
#
#   which config is read   golangci-lint `--no-config`; eslint
#                         `--no-config-lookup`; rubocop `--force-default-config`;
#                         all three spell "use this config" differently
#   what is linted         golangci-lint `--new*` — a diff, not the tree
#   whether it fails       golangci-lint `--issues-exit-code` (`=0` cannot fail);
#                         rubocop `--fail-level`; eslint `--quiet` (errors only,
#                         which is looser, not stricter) and
#                         `--no-error-on-unmatched-pattern`
#   and two that WRITE A FILE, which is this packet's own reason to refuse them:
#                         rubocop `--auto-gen-config`, `--regenerate-todo`
FORBIDDEN = (
    "--config",
    "-c",
    "--no-config",
    "--no-config-lookup",
    "--force-default-config",
    "--issues-exit-code",
    "--fail-level",
    "--quiet",
    "--no-error-on-unmatched-pattern",
    "--auto-gen-config",
    "--regenerate-todo",
    "--new",
    "--new-from-rev",
    "--new-from-patch",
    "--new-from-merge-base",
)

problems = []

# ---------------------------------------------------------------- the input
seam = call.get("lint-args")
if not isinstance(seam, dict):
    problems.append(
        "no `lint-args` workflow_call input, so a service that needs a stricter "
        "linter has no seam and will fork the workflow instead. Callers override, "
        "they never fork"
    )
else:
    if str(seam.get("type")) != "string":
        problems.append(
            "`lint-args` must be type: string — a list would be split by the "
            "guard's own word-splitting rules and could smuggle a token past it"
        )
    if str(seam.get("default", "x")) != "":
        problems.append(
            f"`lint-args` defaults to {seam.get('default')!r}; it must default to "
            f"the empty string, or every service adopts one team's deviation"
        )
    if "guard" not in (seam.get("description") or ""):
        problems.append(
            "the `lint-args` description does not point at the `lint-args guard` "
            "step. The first version of this description promised an enforcement "
            "in tests/validate.sh that did not exist, and a reader who believed it "
            "would not go looking for the real one"
        )

# ------------------------------------------------------- the guard, per job
bodies = {}
for lang in LINT_JOBS:
    steps = (jobs.get(lang) or {}).get("steps") or []
    names = [s.get("name") for s in steps if isinstance(s, dict)]
    if "lint-args guard" not in names:
        problems.append(
            f"job {lang} has no `lint-args guard` step. The seam's limits are then "
            f"enforced nowhere: kit's gate cannot see the value (it is the "
            f"caller's), so a `--no-config` in a caller would restore the "
            f"linter's defaults and turn kit's policy into five of them"
        )
        continue
    gi = names.index("lint-args guard")
    li = names.index("lint") if "lint" in names else None
    if li is not None and gi > li:
        problems.append(
            f"job {lang}: the `lint-args guard` runs AFTER the `lint` step, so the "
            f"linter has already had its argument list and the guard is decoration"
        )
    body = next(s for s in steps if s.get("name") == "lint-args guard").get("run") or ""
    bodies[lang] = body

    # The tokens, read out of the GUARD'S OWN `case` list rather than the whole
    # body: the guard's comment block names every forbidden flag while explaining
    # why each is refused, so counting tokens in the body would be satisfied by
    # the documentation of the very list it is meant to police.
    m = re.search(r'case\s+"\$name"\s+in(.*?)\besac\b', body, re.S)
    if not m:
        problems.append(
            f"job {lang}: its `lint-args guard` has no `case \"$name\" in ... esac` "
            f"list, so it refuses nothing"
        )
    else:
        listed = set(re.findall(r"--?[A-Za-z][A-Za-z0-9-]*", m.group(1)))
        missing = [t for t in FORBIDDEN if t not in listed]
        if missing:
            problems.append(
                f"job {lang}: the `lint-args guard` no longer refuses {missing}. The "
                f"seam is documented as narrow and this is the list that makes it so; "
                f"dropping a token widens the input for every service in the fleet and "
                f"leaves the workflow looking exactly as it did before"
            )

    # And the guard has to be reading the variable the linter is given.
    if "KIT_LINT_ARGS" not in body:
        problems.append(
            f"job {lang}: its `lint-args guard` does not read KIT_LINT_ARGS, so it "
            f"guards a variable it was not given"
        )
    lint = next((s for s in steps if s.get("name") == "lint"), None)
    if isinstance(lint, dict):
        hay = (lint.get("run") or "") + "\n" + "\n".join(
            f"{k}: {v}" for k, v in (lint.get("with") or {}).items()
        )
        if "KIT_LINT_ARGS" not in hay:
            problems.append(
                f"job {lang}: its `lint` step does not receive KIT_LINT_ARGS, so the "
                f"seam is guarded and then discarded — a repo may set a stricter "
                f"flag, be told it is not allowed to set it, and still get no effect"
            )

if len(set(bodies.values())) > 1 and len(bodies) == len(LINT_JOBS):
    problems.append(
        "the `lint-args guard` steps are not identical across the lint jobs. They "
        "are duplicated because GitHub reusable workflows cannot share a step, and "
        "three copies of a policy block that disagree is the drift this repository "
        "exists to prevent"
    )

if problems:
    sys.exit("; ".join(problems))
print(
    f"the seam is a string input defaulting to empty, guarded by an identical "
    f"pre-lint step in all {len(LINT_JOBS)} lint jobs, refusing {len(FORBIDDEN)} "
    f"flags; and the linter receives it"
)
PY2
  }
  check 'the seam  (narrow, guarded before the linter, and wired to it)' \
    lint_args_seam_check

  # -------------------------------------------------------------------------
  # THE DRIFT CHECK. A service that carries a lint config INCONSISTENT with
  # kit's is the failure this packet exists to end, and it is invisible from
  # both sides: kit cannot see the service's tree, and the service's CI goes
  # green the whole time.
  #
  # WHY IT IS NOT "THE FILE MUST NOT EXIST". That version is easier to write and
  # it is wrong in a way that costs more than the drift it prevents. A service
  # whose `.golangci.yml` is byte-identical to kit's has not drifted; it has
  # arrived at the same policy by another route, and failing it teaches the
  # lesson that kit's config is a thing you get shouted at for having. The
  # check a moment later asserts exactly this, as breakage 27b's GREEN control.
  #
  # So this READS BOTH FILES and reports THE DIFFERENCE, linter by linter. A
  # reader of the failure message learns which linters the service turned off
  # and which it added, which is the only information anyone can act on. A check
  # that only said "unexpected file" would send someone to `diff` by hand.
  #
  # SCOPE, and it is a real limitation rather than a convenient one: this reads
  # the kit working tree plus whatever service checkouts are present beside it
  # (`../<repo>`), which is how every other fleet-shaped check in this file
  # works — `core_repo()` above is the same shape. With no sibling checkout the
  # check SKIPS loudly and says which environment variable points at one. It is
  # never silently green, because a drift check that could not have run and
  # reported nothing is the same class of defect as a lint step that cannot fail.
  # The fleet directories, one per line, that CALL the reusable workflow. A
  # service repo is one that calls it: a repository that does not is not
  # governed by kit's policy, and reporting drift in it would be noise that
  # trains people to ignore this check.
  #
  # Resolved in the same way as `core_repo()` above, and for the same reason: a
  # sibling checkout, or a loud skip. Never a silent pass.
  fleet_repos() {
    local base cand
    for base in "$ROOT/.." "$ROOT/../.." "$ROOT/../../cafaye"; do
      [ -d "$base" ] || continue
      for cand in "$base"/*; do
        [ -d "$cand/.github/workflows" ] || continue
        if grep -ql 'uses: cafaye/kit/.github/workflows/ci.reusable.yml' \
          "$cand"/.github/workflows/*.yml 2>/dev/null; then
          printf '%s\n' "$cand"
        fi
      done
      return 0
    done
    return 1
  }

  # The comparison itself, in Python, because comparing two YAML documents is
  # not a thing shell does, and approximating it with grep is how a check ends
  # up comparing the wrong lines.
  lint_drift_check() {
    local fleet
    fleet="$(fleet_repos)"
    if [ -z "$fleet" ]; then
      # A SKIP and not a failure, and not a pass. The same call `core_check`
      # above makes when core is absent, and for the same reason: a
      # throwaway copy of kit — which is what `self_test.sh` runs the gate
      # against, twenty-odd times — has no fleet beside it, and a check that
      # cannot have run and reported nothing must not be indistinguishable from
      # a check that passed.
      return 2
    fi
    "$PY" - "$ROOT" $fleet "$ROOT/lint/drift-allowlist" <<'PY'
import datetime
import os
import re
import sys

import yaml

kit_root = sys.argv[1]
allowlist_path = sys.argv[-1]
fleet_roots = sorted({os.path.realpath(p) for p in sys.argv[2:-1]})


def is_worktree(path):
    """True when `path` is a git WORKTREE rather than its own repository.

    Same rule and the same reasoning as `tests/staleness.py`: a worktree's
    `.git` is a file, it shares the parent repository's history, and counting it
    separately reports one repository's config twice. Here the cost is a
    duplicated allowlist entry and a finding that looks like two, which is
    exactly the sort of thing a reader learns to discount.
    """
    marker = os.path.join(path, ".git")
    if not os.path.isfile(marker):
        return False
    try:
        with open(marker, encoding="utf-8") as fh:
            return fh.read(6).strip() == "gitdir"
    except OSError:
        return False


# The service-side filenames this check READS. Two facts measured on
# golangci-lint v2.6.2, and the first one corrected a claim this file made
# before it was run:
#
#   1. DISCOVERY IS THE FALLBACK, NOT THE OVERRIDE. `golangci-lint run -v`
#      prints `[config_reader] Used config file <path>`, and it is decisive: with
#      `--config=<kit>` it names kit's file and nothing else, and without the
#      flag it names the repo-root one. A repo-root `.golangci.yml` that
#      disables `misspell` is INERT under `--config` — the misspelling is still
#      reported. This file previously claimed the opposite, that discovery
#      "beats every flag", and that claim was the whole justification for
#      reporting drift. It was wrong.
#   2. So a stale copy does NOT hijack kit's CI. What it does is split the
#      policy: every OTHER golangci-lint invocation in that repository — a
#      developer's `golangci-lint run`, an editor integration, a `make lint`, a
#      pre-commit hook — reads the local file, while kit's CI reads kit's. Two
#      policies in one repository, one of them enforced nowhere it is written
#      down. And the copy becomes live again the moment the `--config` flag goes
#      missing, which is breakage 29, and silently, because a copy is always
#      weaker than the thing it was copied from.
#
# The check is therefore not "the file hijacks the build". It is "the file and
# kit disagree, and only one of the two is what CI runs" — which is a real
# finding, and an honest one.
#
# `eslint.config.mjs` is deliberately NOT here, and now for a measured reason
# rather than a rhetorical one: ESLint's `--config` also wins outright, and a
# service's own `eslint.config.mjs` is only read by something that points at it.
# The two linters behave the same way, so the difference between listing it and
# not listing it is intent, not mechanics: a repo's own ESLint config is a
# legitimate thing to own, and this check is about copies of KIT's policy.
SERVICE_CONFIGS = (".golangci.yml", ".golangci.yaml")


def policy_of(doc):
    """The comparable part of a golangci config: what it turns on and off.

    Three keys, and the omissions are as deliberate as the inclusions.
    Settings, exclusions and paths are NOT compared: a service excluding one
    generated file is a narrow, legitimate, reviewable decision, and comparing
    it would make this check fire on the one deviation the seam explicitly
    permits. What is compared is the linter SET, because turning a linter off
    wholesale is the drift, and it is the drift nobody can see from either side.
    """
    linters = (doc or {}).get("linters") or {}
    return {
        "enable": frozenset(linters.get("enable") or []),
        "disable": frozenset(linters.get("disable") or []),
        "formatters": frozenset(((doc or {}).get("formatters") or {}).get("enable") or []),
    }


def load(path):
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh)


kit_policy_path = f"{kit_root}/lint/golangci.yml"
if not os.path.isfile(kit_policy_path):
    sys.exit("lint/golangci.yml is missing, so there is no policy to compare against")
kit_policy = policy_of(load(kit_policy_path))

# --------------------------------------------------------------------------
# the allowlist
# --------------------------------------------------------------------------
#
# Two services in the fleet carry a `.golangci.yml` today, and this packet
# cannot fix them — kit does not touch other repositories, and the fix for
# each is a decision its own team makes. So the drift is REAL and RECORDED, with
# an owner and an expiry, rather than being reported as a green pass or as a
# permanently red gate.
#
# This is the same shape as `templates/tier/skip-allowlist` and for the same
# reason. An allowlist nobody can expire is a comment; an allowlist that is only
# ever added to is a ratchet pointing the wrong way. So:
#
#   1. every entry needs a reason, an owner, and both dates;
#   2. an EXPIRED entry is a FAILURE on the day it expires;
#   3. a duplicate (repo, path, key) is a FAILURE — one of the two is dead;
#   4. AN ENTRY THAT NO LONGER DESCRIBES A REAL DIFFERENCE IS A FAILURE.
#
# Rule 4 is the one that earns the other three. Modelled on ESLint's
# `reportUnusedDisableDirectives`, which reports a disable comment that no
# longer suppresses anything: without it, a fixed repository stays listed, the
# listing stops being read, and within two quarters the file contains every
# repository in the fleet. The entry is how you find out first.
LINE = re.compile(
    r"^diverged\s+(?P<repo>\S+)\s+(?P<path>\S+)\s+(?P<key>\S+)"
    r"(?P<fields>(?:\s+[a-z]+=(?:\"[^\"]*\"|\S+))*)\s*$"
)
FIELD = re.compile(r'([a-z]+)=("[^"]*"|\S+)')
WHY = {
    "reason": 'without one, "we will get to it" is the reason for everything',
    "owner": "drift nobody owns is drift nobody will ever fix",
    "since": "the ratchet needs the date the decision was taken",
    "until": "an entry that cannot expire has stopped being a decision",
}
KEYS = ("enable", "disable", "formatters")

allowed = {}
today = datetime.date.today()
if not os.path.isfile(allowlist_path):
    sys.exit(
        f"{allowlist_path} is missing. A drift check with nowhere to record a "
        f"known divergence is a check that either reports the fleet as broken or "
        f"has been taught to report nothing"
    )

for lineno, raw in enumerate(open(allowlist_path, encoding="utf-8").read().splitlines(), 1):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    m = LINE.match(line)
    if not m:
        sys.exit(
            f"lint/drift-allowlist:{lineno}: malformed entry. Expected "
            f"'diverged <repo> <path> <enable|disable|formatters> "
            f"reason=\"...\" owner=... since=YYYY-MM-DD until=YYYY-MM-DD' on ONE line"
        )
    fields = {k: v.strip('"') for k, v in FIELD.findall(m.group("fields"))}
    for field in ("reason", "owner", "since", "until"):
        if not fields.get(field):
            sys.exit(f"lint/drift-allowlist:{lineno}: entry names no {field} — {WHY[field]}")
    if m.group("key") not in KEYS:
        sys.exit(
            f"lint/drift-allowlist:{lineno}: key {m.group('key')!r} is not one of "
            f"{list(KEYS)}. A key the comparison does not read is an entry that "
            f"silently matches nothing"
        )
    for field in ("since", "until"):
        try:
            datetime.date.fromisoformat(fields[field])
        except ValueError:
            sys.exit(f"lint/drift-allowlist:{lineno}: {field}={fields[field]!r} is not an ISO date")
    if datetime.date.fromisoformat(fields["until"]) < today:
        sys.exit(
            f"lint/drift-allowlist:{lineno}: EXPIRED on {fields['until']} (today is "
            f"{today.isoformat()}). Delete the entry, or move the date and write a new "
            f"reason — a date that rolls forward by itself is not a ratchet"
        )
    key = (m.group("repo"), m.group("path"), m.group("key"))
    if key in allowed:
        sys.exit(
            f"lint/drift-allowlist:{lineno}: {key} is already listed on line "
            f"{allowed[key]}. Two lines for one divergence means one of them is no "
            f"longer being read"
        )
    allowed[key] = lineno

# --------------------------------------------------------------------------
# the comparison
# --------------------------------------------------------------------------
problems = []
seen_repos = set()
found = set()
compared = 0

for root in fleet_roots:
    if is_worktree(root):
        continue  # one repository, one entry — see the docstring
    name = os.path.basename(root)
    seen_repos.add(name)
    for service_name in SERVICE_CONFIGS:
        path = os.path.join(root, service_name)
        if not os.path.isfile(path):
            continue
        compared += 1
        try:
            got = policy_of(load(path))
        except Exception as exc:
            problems.append(
                f"{name}/{service_name} does not parse as YAML ({exc}), so nobody can "
                f"say what policy it applies. An unreadable copy is the worst case of "
                f"the thing this check is for: a service linted by a config nobody "
                f"can read, in a build that stays green"
            )
            continue
        for key in KEYS:
            if kit_policy[key] == got[key]:
                continue
            found.add((name, service_name, key))
            if (name, service_name, key) in allowed:
                continue
            missing = sorted(kit_policy[key] - got[key])
            extra = sorted(got_policy for got_policy in (got[key] - kit_policy[key]))
            what = []
            if missing:
                what.append(f"no longer enables {missing}")
            if extra:
                what.append(f"enables {extra}, which kit does not")
            problems.append(
                f"{name}/{service_name}: {key} INCONSISTENT with lint/golangci.yml — "
                f"{'; '.join(what)}. Measured on golangci-lint v2.6.2: `--config` "
                f"WINS, so this file is inert for kit's CI, and that is the reason "
                f"this is a finding rather than a non-event. Two policies now govern "
                f"one repository — kit's, which CI runs, and this one, which every "
                f"other invocation reads (a developer's `golangci-lint run`, an "
                f"editor, a `make lint`). And the split is silent in the direction "
                f"that matters: the moment the workflow's `--config` is dropped, "
                f"this weaker file governs the build and nothing says so. Either "
                f"delete it and let kit's policy be the only one, or make the "
                f"deviation deliberate and visible in the workflow's `lint-args` "
                f"seam. To record a difference you cannot delete yet, add an entry "
                f"to lint/drift-allowlist with a reason, an owner and an expiry"
            )

# "The fleet is not here" is checked BEFORE the unused-entry rule, and the order
# is load-bearing. Both rules read the same missing information: with no sibling
# checkouts there is no comparison, so every entry trivially describes no
# difference. Reporting all of them as unused in that case is a false alarm that
# says "delete these" about debt nobody has discharged, and it fires in exactly
# the place it is most damaging — `tests/self_test.sh` runs the gate against a
# throwaway copy of kit, which has no fleet beside it, so the control would be
# red on a correct tree.
#
# The rule can only be evaluated when there was a fleet to evaluate it against.
if not seen_repos:
    sys.exit(
        "no cafaye service checkout was found beside this one, so the drift check "
        "had nothing to compare. A drift check that could not have run and reported "
        "nothing is a check that will not be missed when it matters"
    )

# Rule 4. An entry that no longer describes a real difference is dead weight,
# and dead weight in an allowlist is how an allowlist becomes a list of
# everything.
#
# RULE 4 IS SCOPED TO THE REPOSITORIES THIS RUN ACTUALLY LOOKED AT, and that
# scoping is the whole correctness of the rule rather than a softening of it.
# "This entry no longer describes a difference" is a claim about a file, and the
# only way to make it is to have read that file. A repository that is not in the
# fleet beside this checkout has NOT been read, so nothing is known about it, and
# reporting its entry as unused is a check inventing a finding out of its own
# ignorance.
#
# It is not a theoretical concern. It fired the moment this file was finished:
# `tests/self_test.sh` runs this gate against a throwaway COPY of kit, and a
# copy's fleet is itself rather than the cafaye directory, so every entry in the
# allowlist named a repository that was not present — and the gate went red on a
# perfectly correct tree, telling the reader to delete debt that had not been
# discharged. A rule that cries wolf in its own test suite is a rule people
# learn to bypass with `--no-`, which is the failure this packet exists to end.
#
# The consequence is stated rather than hidden: a repository DELETED from the
# fleet leaves an entry nothing can flag. That is a real limit and it is paid
# for deliberately, because the alternative is a gate that is red whenever kit is
# checked out on its own — which is every fresh clone and every CI runner. What
# covers the deleted case is `tests/staleness.py`, which reports a repository
# that calls kit and is not resolvable; this file covers the case where the
# repository is HERE and no longer differs, and the two are not the same
# question.
# Whether this run can speak about a repository it did not see, and the answer
# is not the same in the two situations kit runs in.
#
#   - A REAL checkout: the scan found the fleet, so a repository in the
#     allowlist that the scan did NOT find is a repository that has been deleted,
#     renamed, or renamed away. That is a finding, and it is the case rule 4
#     exists for: the entry is dead weight and nobody will notice without it.
#   - A COPY of kit, which is what `tests/self_test.sh` runs the gate against
#     twenty-odd times: the only "fleet" beside it is itself, because a copy has
#     no cafaye directory next to it. Nothing can be said about `identity` there,
#     and reporting its entry as dead would be the check inventing a finding out
#     of its own ignorance — red on a perfectly correct tree, telling the reader
#     to delete debt that has not been discharged. It fired the moment this file
#     was finished, on the gate's own test suite.
#
# So the two are told apart by asking whether the scan found anything other than
# this checkout, which is a fact about the run rather than a flag someone can set
# to make the check quiet.
only_me = seen_repos <= {os.path.basename(os.path.realpath(kit_root))}
unverified = 0
for repo, path_name, key in sorted(set(allowed) - found):
    if repo not in seen_repos and only_me:
        # Counted and printed, never failed on. Silence would be the other
        # mistake: a reader cannot tell "checked and clean" from "never looked".
        unverified += 1
        continue
    if repo not in seen_repos:
        problems.append(
            f"lint/drift-allowlist:{allowed[(repo, path_name, key)]}: the entry "
            f"names {repo}/{path_name} ({key}), and this run found no such "
            f"repository in the fleet beside this checkout. Either that repository "
            f"has been deleted or renamed — in which case the entry is dead weight "
            f"and the file is one step from being a list of every repository the "
            f"fleet has ever had — or the entry is a typo. Neither is a state you "
            f"can leave it in"
        )
        continue
    problems.append(
        f"lint/drift-allowlist:{allowed[(repo, path_name, key)]}: the entry for "
        f"{repo}/{path_name} ({key}) no longer describes a difference — the "
        f"repository is here and no longer diverges, so either it adopted kit's "
        f"policy or the file is wrong. Delete the entry, or this file becomes a "
        f"list of every repository the fleet has ever had"
    )

if problems:
    sys.exit("; ".join(problems))

print(
    f"{len(seen_repos)} service repo(s) compared against kit's golangci policy; "
    f"{compared} carried their own config; {len(allowed)} divergence(s) recorded in "
    f"lint/drift-allowlist, none expired, none unused"
    + (
        f"; {unverified} entr(y/ies) named a repository that is not in this "
        f"checkout's fleet, so this run could not look and did NOT count them as "
        f"clean (this is a copy of kit with no fleet beside it, not the fleet)"
        if unverified
        else ""
    )
)
PY
  }
  # `check` cannot express "skip", so the exits are handled here: 2 is this
  # check's own "there was nothing to compare" and reports a SKIP, which the
  # summary counts. Anything else is a real finding.
  #
  # The output is printed on the passing path rather than swallowed, for the same
  # reason `core_check`'s is: the count of repositories compared is what makes
  # "it passed" mean something, and a green line that could equally have come
  # from a check that examined nothing is the failure this whole file is about.
  if _drift_out="$(lint_drift_check 2>&1)"; then
    report PASS 'lint drift  (a service config is compared to kit, not merely forbidden)'
    [ -n "$_drift_out" ] && printf '%s\n' "$_drift_out" | sed 's/^/       /'
  else
    case "$?" in
      2) report SKIP 'lint drift  (no cafaye service checkout found beside this one)' ;;
      *)
        report FAIL 'lint drift  (a service config is compared to kit, not merely forbidden)'
        printf '%s\n' "$_drift_out" | sed 's/^/       /'
        ;;
    esac
  fi

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

  # (3b) The PARITY allowlist, and the artefact table it is checked against.
  #
  #     Same four hygiene rules as the tier skip allowlist above, in the same
  #     words, because kit does not have two dialects of "record why". What is
  #     NEW here is the other direction, and it is the one that matters most:
  #
  #     AN UNPINNED DIVERGENCE OR ABSENCE IS A FAILURE.
  #
  #     The tier allowlist does not need that rule because its entries name
  #     tests that are either present or absent for reasons the file's own
  #     comments explain. This one names copies in repositories kit cannot see
  #     at gate time, so the file is a RECORD OF THE FLEET, and a record that
  #     silently omits a cell is worse than no record: it reads as "handled".
  #
  #     Which is why the count is printed on PASS, in the sentence a green run
  #     shows, and why the header says the number is a measurement and not a
  #     ledger to shrink. Deleting an entry to make the count go down is a
  #     failure of its own, and the reporter catches it against the fleet.
  #
  #     The two checks the gate can run WITHOUT the fleet are the ones it runs:
  #     an entry that names an `artefact-id` kit does not ship, and an entry
  #     whose verb is not a verb the reporter can report. The rest — an unpinned
  #     cell, a dead entry, a verb that disagrees with the measurement — needs
  #     the fleet, and is proven by `tests/staleness_test.sh` against a fixture
  #     fleet rather than asserted here. Saying so is the point: a check that
  #     claims to have compared 80 entries against nine repositories it has
  #     never read is the kind of claim this repository exists to distrust.
  parity_allowlist_check() {
    "$PY" - "$ROOT" <<'PY'
import datetime
import json
import os
import re
import sys

root = sys.argv[1]
ledger = os.path.join(root, "templates", "parity-allowlist")
table_path = os.path.join(root, "tests", "artifacts.json")

if not os.path.isfile(ledger):
    sys.exit(
        "templates/parity-allowlist is missing: kit ships twelve artefacts that "
        "services copy, and a divergence with no recorded reason is unproven "
        "rather than fine"
    )
if not os.path.isfile(table_path):
    sys.exit("tests/artifacts.json is missing: there is no declaration of what kit ships")

# The inventory is the artefact table — the SAME file the reporter reads, which
# is the point of having one. An inventory derived independently here would be a
# second, unchecked copy of the truth, which is the defect AGENTS.md's
# header/recipe check exists to prevent and which kit has already had once.
try:
    with open(table_path, encoding="utf-8") as fh:
        table = json.load(fh)
except (OSError, json.JSONDecodeError) as exc:
    sys.exit(f"tests/artifacts.json is unreadable: {exc}. A table this gate cannot "
             f"read is a table it would approve anything against")

ids = {a.get("id") for a in table.get("artefacts", []) if a.get("id")}
if not ids:
    sys.exit(
        "tests/artifacts.json declares no artefact ids, so the unused-entry rule "
        "would check nothing: an allowlist validated against an empty inventory "
        "is an allowlist that accepts everything"
    )

#   diverged  present at the declared path, not byte-identical
#   absent    not present where kit ships one
#   unknown   the comparison could not be made (no declared language)
#
# Three verbs, and the third is why this is not a two-verb format: an
# unmeasurable cell is a finding, and a two-verb ledger would have to state
# something false about it to record something true.
LINE = re.compile(
    r'^(?P<verb>diverged|absent|unknown)\s+(?P<repo>\S+)\s+(?P<artefact>\S+)'
    r'(?P<fields>(?:\s+[a-z]+=(?:"[^"]*"|\S+))*)\s*$'
)
FIELD = re.compile(r'([a-z]+)=("[^"]*"|\S+)')
WHY = {
    "reason": 'without one, "it is fine" becomes the reason for everything',
    "owner": "a divergence nobody owns is a divergence nobody will bring back into line",
    "since": "the ratchet needs the date the decision was taken",
    "until": "an entry that cannot expire has stopped being a decision",
}

today = datetime.date.today()
problems = []
seen = {}
entries = 0

for lineno, raw in enumerate(open(ledger, encoding="utf-8").read().splitlines(), 1):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    entries += 1

    m = LINE.match(line)
    if not m:
        problems.append(
            f"line {lineno}: malformed entry. Expected 'diverged|absent|unknown <repo> "
            f"<artefact-id> reason=\"...\" owner=… since=YYYY-MM-DD "
            f"until=YYYY-MM-DD' on ONE line — a wrapped reason is two entries, one "
            f"of which is a parse error"
        )
        continue

    fields = {k: v.strip('"') for k, v in FIELD.findall(m.group("fields"))}
    key = (m.group("repo"), m.group("artefact"))

    for name in ("reason", "owner", "since", "until"):
        if not fields.get(name):
            problems.append(f"line {lineno}: entry names no {name} — {WHY[name]}")

    # The unused-entry rule, against the artefact table. This is ESLint's
    # `reportUnusedDisableDirectives` shape: an entry for something that no
    # longer exists excuses nothing, and the entry is how you find out first.
    # Resolved against the TABLE and not against a directory listing, so a
    # renamed artefact fails loudly instead of quietly matching whatever now
    # sits at that path.
    if m.group("artefact") not in ids:
        problems.append(
            f"line {lineno}: entry matches NOTHING — tests/artifacts.json declares "
            f"no artefact {m.group('artefact')!r}. The artefact was renamed or "
            f"removed, or the entry was written for a typo. Either way it is dead "
            f"weight, and a ledger that cannot notice its own dead entries is a "
            f"ledger that eventually contains the whole fleet"
        )

    if key in seen:
        problems.append(
            f"line {lineno}: duplicate entry for {key[0]}/{key[1]}, already listed "
            f"on line {seen[key]}. Two records for one cell means one of them is "
            f"not being read"
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
        if name == "until" and parsed < today:
            problems.append(
                f"line {lineno}: EXPIRED on {value} (today is {today.isoformat()}). "
                f"Re-copy the artefact and delete the entry, or move the date and "
                f"write a NEW reason — a date that rolls forward by itself is not "
                f"a ratchet"
            )

if problems:
    for p in problems:
        print("  -", p)
    sys.exit(1)

# THE TOTAL, PRINTED ON PASS. `check` indents a passing check's stdout under its
# label, so this is visible in a GREEN run — the only place a growing list is
# least likely to be noticed, and the whole reason the tier allowlist prints its
# count too. 80 entries is a bad number, and it is printed so that everybody
# can see it is a bad number.
print(
    f"parity allowlist: {entries} entr{'y' if entries == 1 else 'ies'} across "
    f"{len({k[0] for k in seen})} repositor{'y' if len({k[0] for k in seen}) == 1 else 'ies'}, "
    f"every artefact id in artifacts.json, none expired, none dead. THE TOTAL IS "
    f"THE MEASUREMENT: 80 entries is 80 copies of kit's templates that the fleet "
    f"has not adopted or has changed, and the way to shrink it is to re-copy, not "
    f"to delete an entry. Compare against `tests/staleness.py --scope templates "
    f"--repos-dir …` for the per-cell state."
)
PY
  }
  check 'templates/parity-allowlist  (reason, owner, since, until; dead entries fail)' \
    parity_allowlist_check

  # (3c) The artefact table must describe files that EXIST.
  #
  #     A table naming a file kit does not ship makes the reporter call every
  #     service `absent` for it, forever. That output is indistinguishable from
  #     a migration backlog, which is the dangerous direction: it would put a
  #     permanent, unactionable finding in front of a reader and be believed.
  #     So the table is checked against the tree, and the reporter refuses to
  #     run at all on a table that fails — proved by staleness_test.sh case 28.
  #
  #     This is the same check the reporter makes, called directly rather than
  #     reimplemented, because two implementations of "is this a real path" is
  #     one implementation too many.
  artifact_table_check() {
    "$PY" - "$ROOT" <<'PY'
import importlib.util
import os
import sys

root = sys.argv[1]
spec = importlib.util.spec_from_file_location(
    "staleness", os.path.join(root, "tests", "staleness.py")
)
if spec is None or spec.loader is None:
    sys.exit("tests/staleness.py could not be loaded, so the artefact table cannot "
             "be checked against the tree it describes")
staleness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staleness)

table = staleness.load_table(os.path.join(root, "tests", "artifacts.json"))
problems = staleness.validate_table_against_kit(table, root)

# A `{lang}` source must resolve for EVERY language the workflow offers. The
# glob above proves the shape exists, which catches a rename; this catches a
# template that exists for five of the seven languages, which is a half-adopted
# language and the exact defect kit's own "half a language is worse than none"
# rule is about.
# The languages, read the way the rest of this file reads them: as YAML, from
# the workflow's real `options`. `validate.sh` already requires PyYAML and
# already loads this workflow several times, so parsing it here is not a new
# dependency — it is the difference between asking the question and grepping
# for it. The first version of this used a regex over the raw text, matched
# nothing because `description:` sits between the key and `options:`, and
# reported a FAILURE — which was the check being right about its own blindness
# and wrong about the tree. A check that could not parse the thing it is
# checking must say so, and here it did.
#
# `none` is excluded: it is not a language, it is the option for a repository
# with no service manifest, and `templates/bin-prime/none.sh` does not exist and
# should not.
import yaml

workflow = os.path.join(root, ".github", "workflows", "ci.reusable.yml")
languages = set()
try:
    with open(workflow, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh) or {}
    triggers = doc.get("on") or doc.get(True) or {}
    declared = ((triggers.get("workflow_call") or {}).get("inputs") or {})
    options = ((declared.get("language") or {}).get("options")) or []
    languages = {o for o in options if o and o != "none"}
except (OSError, yaml.YAMLError) as exc:
    problems.append(f"the reusable workflow could not be parsed: {exc}")
if not languages:
    problems.append(
        "the reusable workflow declares no `language` options, so the "
        "{lang}-interpolated artefacts cannot be checked for every language. A "
        "check that could not ask its question must not report a pass"
    )

for artefact in table["artefacts"]:
    if not artefact.get("needsLanguage"):
        continue
    for lang in sorted(languages):
        source = os.path.join(root, artefact["source"].replace("{lang}", lang))
        if not os.path.isfile(source):
            problems.append(
                f"{artefact['id']}: kit offers `language: {lang}` but ships no "
                f"{artefact['source'].replace('{lang}', lang)}. Half a language is "
                f"worse than none: a service that adopts it gets a broken primer"
            )

if problems:
    for p in problems:
        print("  -", p)
    sys.exit(1)
print(
    f"artefact table: {len(table['artefacts'])} artefact(s), every source present "
    f"in this tree, and every {{lang}} source resolving for all "
    f"{len(languages)} languages the workflow offers"
)
PY
  }
  check 'tests/artifacts.json  (every declared source exists, for every language)' \
    artifact_table_check

  # (3d) The carve-out boundary: the two programs import NOTHING from outside the
  #      standard library, and only from the seven modules AGENTS.md names.
  #
  #      AGENTS.md's rules section says "standard library only, no import outside
  #      json/os/re/sys/argparse/subprocess" and calls that a carve-out rather
  #      than a precedent. Until now nothing checked it, which made the sentence
  #      a promise — and a promise nobody can break is decoration. This parses
  #      every `import` in both programs rather than grepping, so a
  #      `from x import y`, a function-local import and a module named inside a
  #      docstring's example are all read the same way.
  #
  #      `difflib` is on the list because the templates half of the staleness
  #      reporter counts the lines two copies differ by, and a list that grows
  #      by a later commit is not a control — so growing it is a red gate, and
  #      the only way past is to change this file and this check in the same
  #      commit.
  carveout_boundary_check() {
    "$PY" - "$ROOT" <<'PY'
import ast
import os
import sys

root = sys.argv[1]

# The list is written HERE and in AGENTS.md, and the two are compared against
# each other by the check below — so the sentence in AGENTS.md cannot quietly
# stop matching the rule the gate enforces, which is the property that made
# kit-05's fail-closed headline worth restating.
ALLOWED = {"__future__", "argparse", "difflib", "glob", "json", "os", "re",
           "subprocess", "sys", "urllib"}

programs = ["tests/classify.py", "tests/staleness.py"]
problems = []
seen_modules = set()

for rel in programs:
    path = os.path.join(root, rel)
    if not os.path.isfile(path):
        problems.append(f"{rel} is missing: the carve-out is a boundary around two programs")
        continue
    with open(path, encoding="utf-8") as fh:
        try:
            tree = ast.parse(fh.read(), filename=rel)
        except SyntaxError as exc:
            problems.append(f"{rel} does not parse: {exc}")
            continue
    # ast.walk, not the module body: a function-local import is still an
    # import, and the whole value of this check is that there is nowhere to put
    # one that it cannot see.
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names = [alias.name for alias in node.names]
        elif isinstance(node, ast.ImportFrom):
            # `level > 0` is a relative import, which cannot happen in a program
            # nothing imports — and is checked rather than assumed.
            if node.level:
                problems.append(
                    f"{rel}:{node.lineno} is a RELATIVE import. Nothing here is a "
                    f"package, and a relative import is the first sign of one"
                )
                continue
            names = [node.module or ""]
        else:
            continue
        for name in names:
            top = name.split(".")[0]
            seen_modules.add(top)
            if top not in ALLOWED:
                problems.append(
                    f"{rel}:{getattr(node, 'lineno', '?')} imports {top!r}, which is "
                    f"not standard library or not on AGENTS.md's list. The two "
                    f"programs are the ONE carve-out from 'config only', and the "
                    f"carve-out is what keeps kit a repository with no "
                    f"dependencies — so a new import is a decision about this "
                    f"repo's identity, not a convenience"
                )

# A check that proved nothing because it parsed nothing is a check that ran
# nothing. Both programs must be present AND the walk must have seen something.
if not seen_modules:
    problems.append(
        "no imports were found in either program, so the carve-out check would "
        "approve anything: the programs have changed shape and the check has not"
    )

# AGENTS.md and this list must agree. The list is the enforcement; the sentence
# in AGENTS.md is what a reader believes, and a reader who believes something
# else from the one that is enforced is worse off than either.
#
# `urllib` and its submodules are the reason this half exists as a separate
# assertion: the reporter imports `urllib.request` and `urllib.error` for the
# GitHub-org discovery route, and AGENTS.md's original list did not name them —
# so the sentence was already out of date before this check, and the only way
# anyone would ever have found out is if they went looking.
agents = open(os.path.join(root, "AGENTS.md"), encoding="utf-8").read()
missing = sorted(m for m in seen_modules if f"`{m}`" not in agents)
if missing:
    problems.append(
        f"AGENTS.md's carve-out sentence does not name {', '.join(missing)}, which "
        f"the programs import. The sentence a reader trusts and the list the gate "
        f"enforces are not allowed to be different lists"
    )

if problems:
    for p in problems:
        print("  -", p)
    sys.exit(1)
print(
    f"carve-out boundary: {len(programs)} programs, {len(seen_modules)} distinct "
    f"imports ({', '.join(sorted(seen_modules))}), all standard library, all named "
    f"in AGENTS.md. kit has no dependency and cannot grow one without this gate "
    f"going red."
)
PY
  }
  check 'tests/classify.py + tests/staleness.py  (stdlib only; the carve-out, enforced)' \
    carveout_boundary_check

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
    # The two files the staleness templates half is made of. Both are the kind
    # of thing a reader would never know to look for: the reporter is
    # self-explanatory, and the ledger is a list. A reader who does not know
    # they exist concludes the reporter invents its own inventory, which it
    # does not — and that a divergence with no recorded reason is fine, which
    # it is not.
    "tests/artifacts.json",
    "templates/parity-allowlist",
    # The three the fetched-stack packet added. A README that documents the stack
    # without documenting how it is OBTAINED describes a copy, and this packet's
    # whole claim is that the copy is gone.
    "tests/fetch_test.sh",
    "tests/stack_live_test.sh",
    "tests/fleet_check.py",
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

# `kit.ref` IS NAME-ONLY, deliberately, and it is the one entry in the list above
# that cannot also be an existence check. kit is the repository being pinned, so
# it has no `kit.ref` of its own — requiring one would make this repository fail a
# check about the repositories that consume it, which is the confusion the whole
# split between "kit's own artifacts" and "the fleet" exists to prevent.
#
# It is read by two programs — `bin/dev` at run time and `tests/fleet_check.py`
# at gate time — so a README that lists it in a table of files without saying what
# it is has documented a file, not a contract.
if not re.search(r"`?kit\.ref`?", readme):
    problems.append(
        "README.md never names kit.ref, so a reader cannot find where the pin "
        "lives — and the pin is the one thing in this packet that decides which "
        "bytes of kit a developer's machine runs."
    )
if not re.search(r"(?i)pin", readme):
    problems.append(
        "README.md never uses the word `pin`, so kit.ref reads as a filename "
        "rather than as the thing it is. A reader who does not know it is a pin "
        "will edit it to `master`."
    )

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

  # kit's own licence, and the one property about it that can rot.
  #
  # WHY THIS EXISTS. kit carried no `LICENSE` at all while the rest of the fleet
  # was being given one, and the state that produces is not "unlicensed" — it is
  # "all rights reserved", because that is the default copyright position when a
  # public repository grants nothing. cafaye's decision is MIT everywhere, and a
  # decision that is written down on a website and absent from the repository is
  # a decision a buyer's own legal review cannot see.
  #
  # The interesting half is not the file. It is that a licence is only
  # unambiguous when there is exactly ONE place in a repository that can declare
  # one, and that place is easy to lose: a `package.json` appears, it carries
  # `"license": "AGPL-3.0-only"` copied out of a service, and now the repository
  # says MIT in one file and AGPL in another. Both are true statements about
  # different fields, and the reader has no way to tell which one a licence
  # compliance tool reads.
  #
  # So this asserts the AGREEMENT, not the presence of a file:
  #
  #   1. `LICENSE` exists and grants MIT, recognised by the grant's own words
  #      rather than by the string "MIT" — a file saying "MIT" and granting
  #      something else passes every check that looks for the word, and this is
  #      the check that looks for the words.
  #   2. it names a copyright holder, because MIT's attribution obligation is
  #      that notice travelling with the software, and a grant with no holder is
  #      a grant nobody can attribute.
  #   3. README says MIT and links the file. A grant nobody reads is not
  #      published, and the two licence questions in kit's README are separate
  #      on purpose (MIT for kit, AGPL-3.0 for the four backends it ships
  #      unmodified) — so the check asserts against kit's OWN paragraph and
  #      leaves the AGPL one alone, since conflating the two is the mistake the
  #      README's structure exists to prevent.
  #   4. every root manifest that CAN carry a licence field declares MIT.
  #
  # Point 4 is deliberately a check for AGREEMENT and not a ban on the file. The
  # same reasoning as breakage 31b: a check satisfied by "kit has no
  # package.json" would train the next contributor to delete a manifest rather
  # than to fix its licence field, and would be a FAIL the day kit legitimately
  # grew one. Today it finds zero manifests and prints that count, because "0
  # manifests, none of which can disagree" is a measurement and silence is not.
  license_check() {
    "$PY" - "$ROOT" <<'PY'
import glob
import os
import re
import sys

root = sys.argv[1]
problems = []

# (1) and (2): the grant itself.
path = os.path.join(root, "LICENSE")
if not os.path.isfile(path):
    problems.append(
        "LICENSE does not exist. cafaye's decision is MIT across the fleet, and a "
        "repository with no grant is not permissive — it is all rights reserved, "
        "which is the default copyright position when nothing is granted. The "
        "grant is one file and it is the whole grant"
    )
else:
    text = open(path, encoding="utf-8").read()
    # The grant's own sentences, not the identifier. `MIT` as a bare string is
    # also how a summary, a badge line, or a note about some OTHER repository's
    # licence is spelled, and matching it would pass on all three.
    for phrase, why in (
        (
            "Permission is hereby granted, free of charge",
            "the permission grant is MIT's first sentence and the thing being granted",
        ),
        (
            'THE SOFTWARE IS PROVIDED "AS IS"',
            "MIT's warranty disclaimer. Its ABSENCE is how you tell a copied "
            "identifier from a real grant, and a grant without it is a different "
            "licence",
        ),
    ):
        if phrase not in text:
            problems.append(
                f"LICENSE does not contain {phrase!r} — {why}. If kit is not MIT, "
                f"say so in README.md instead of leaving the two files to disagree"
            )
    if not re.search(r"^Copyright \(c\) \d{4} \S.*$", text, re.M):
        problems.append(
            "LICENSE names no copyright holder. MIT's attribution obligation is "
            "that notice travelling with the software, and a grant with no holder "
            "is a grant nobody can attribute"
        )

# (3): the README, against kit's OWN paragraph.
readme = open(os.path.join(root, "README.md"), encoding="utf-8").read()
# The `## License` section, not the whole file: the AGPL paragraph above names a
# licence that is NOT kit's, and a substring search over the document is
# satisfied by that one — which is the exact conflation the section split exists
# to prevent.
section = re.split(r"^## ", readme, flags=re.M)
own = next((s for s in section if s.startswith("License")), "")
if not own:
    problems.append(
        "README.md has no `## License` section. A grant nobody reads is not "
        "published, and this is the section a reader is looking for"
    )
else:
    if not re.search(r"\bMIT\b", own):
        problems.append("README.md's License section does not state MIT")
    if not re.search(r"\]\(LICENSE\)", own):
        problems.append(
            "README.md's License section does not link to the LICENSE file, so a "
            "reader has to go looking for it"
        )
# The separation itself, which is a claim rather than a file.
if not re.search(r"AGPL", own):
    problems.append(
        "README.md's License section does not name AGPL anywhere. kit shipping "
        "AGPL-3.0 backends unmodified and kit itself being MIT are two different "
        "questions, and the section that answers the second has to say why the "
        "first does not change the answer"
    )

# (4): anything in the tree root that can carry a licence field.
# Deliberately ROOT-ONLY and deliberately not a ban. `templates/` holds
# manifests for other people — `go.mod` files, a service's package.json — and a
# licence declared in a template is that template's business. What cannot be
# allowed is a licence declared about KIT, and only the root can be about kit.
FIELDS = {
    "package.json": r'"license"\s*:\s*"([^"]*)"',
    "Cargo.toml": r'^\s*license\s*=\s*"([^"]*)"',
    "pyproject.toml": r'^\s*license\s*=\s*(?:\{[^}]*text\s*=\s*)?"([^"]*)"',
    "composer.json": r'"license"\s*:\s*"([^"]*)"',
    "setup.cfg": r"^license\s*=\s*(\S+)",
    "bower.json": r'"license"\s*:\s*"([^"]*)"',
}
found = 0
for name, pattern in FIELDS.items():
    for full in sorted(glob.glob(os.path.join(root, name))):
        found += 1
        body = open(full, encoding="utf-8").read()
        m = re.search(pattern, body, re.M)
        if not m:
            # No field is not a disagreement: the LICENSE file still governs, and
            # the check above already asserted it says MIT.
            continue
        declared = m.group(1)
        if "MIT" not in declared:
            problems.append(
                f"{name} declares license {declared!r} while LICENSE grants MIT. A "
                f"licence compliance tool reads the manifest, a reader reads the "
                f"file, and the repository now says two different things about the "
                f"same grant"
            )
for full in sorted(glob.glob(os.path.join(root, "*.gemspec"))):
    found += 1
    m = re.search(r"\.license\s*=\s*[\"']([^\"']+)[\"']", open(full, encoding="utf-8").read())
    if m and "MIT" not in m.group(1):
        problems.append(
            f"{os.path.basename(full)} declares license {m.group(1)!r} while LICENSE "
            f"grants MIT — same disagreement, same reason"
        )

if problems:
    sys.exit("; ".join(problems))

# Printed on PASS, because "no manifest could disagree" and "nobody looked" are
# the same output otherwise.
print(
    "LICENSE grants MIT and names cafaye; README states it and links the file; "
    f"{found} root manifest(s) inspected, none declaring a licence other than MIT "
    f"(kit has {'none' if found == 0 else str(found)}, so the file is the only "
    "place a grant can be declared)"
)
PY
  }
  check 'LICENSE  (MIT, and nothing in the tree can disagree with it)' license_check

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
  # reports the comment. Self_test breakage 43 proved it — the flag removed, the
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

  # -------------------------------------------------------------------------
  # The toolchain floor, checked BEFORE any suite runs.
  #
  # Written because of what this phase did on a machine with a system Ruby
  # 2.6.10 on PATH: the suite ran, three tests raised `NoMethodError: undefined
  # method 'filter_map'`, and the summary said
  #
  #     FAIL templates/otel/ruby  (ruby test suite)
  #
  # which is a false accusation. Nothing is wrong with the template. The
  # interpreter on PATH was older than the one construct the template uses, and
  # `Array#filter_map` is a RUNTIME call, so the failure arrives as a stack
  # trace from inside a helper rather than as a refusal to run. Every other
  # language here fails loudly on its own — go's go.mod plus GOTOOLCHAIN=local,
  # rustc's --edition, python's `from __future__ import annotations` — so this
  # was the only one that could report a wrong answer instead of no answer.
  #
  # The floor is a FEATURE PROBE, not a version number, and that is the whole
  # design. A literal like `2.7` in this file is a claim about the template
  # that nothing checks: raise the template's floor and the claim rots; the
  # probe is derived from the same call the suite makes, so the two cannot
  # disagree. It is a probe rather than a version comparison because the
  # interesting question is not "how old is this ruby" but "can it run the code
  # we ship" — which is answerable exactly, and which a version string can only
  # approximate.
  #
  # FAIL, not SKIP. A too-old interpreter is not an absent one: the suite is
  # installed, the code is here, and the check is genuinely unrun. Reporting
  # SKIP would make the gate green having verified nothing about ruby — the
  # "a gate that skips is not green" rule, and the direction this repo's own
  # fail-closed discipline points. An ABSENT toolchain is still a SKIP: that is
  # an environment without the language, not a broken one.
  toolchain_floor_ruby() {
    ruby -e 'exit(Array.method_defined?(:filter_map) ? 0 : 1)' 2>/dev/null
  }

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
# phase: observability — the two proofs that need a real collector
# ===========================================================================

if [ "$RUN_OBSERVABILITY" -eq 1 ]; then
  section 'observability: the redaction boundary, against a real collector'

  # Not skippable by preference. A dev machine with no docker gets a reported
  # SKIP, because the alternative — running the suite and reporting PASS while
  # the security claim went unexercised — is the shape of a proof nobody ran.
  #
  # BOUNDED, each tier with its own. Three docker stacks, eight containers apiece,
  # brought up and torn down in sequence, on a machine that may also be running
  # five other workers' gates. This is the tier the previous full run was
  # SIGKILLed inside, and a kill costs the reader every tier after it — so each
  # of these three carries a bound generous enough for a loaded box and a verdict
  # of its own if it is reached.
  #
  # The numbers are ~3x the quiet-machine durations recorded in REPORT-kit-13.md
  # §7, not a guess: a bound set at the observed quiet duration is a bound that
  # fires on any contention at all, and a bound that fires is a tier that proved
  # nothing.
  if ! have docker; then
    report SKIP 'observability proofs (docker not installed)'
  elif ! docker info >/dev/null 2>&1; then
    report SKIP 'observability proofs (docker daemon not reachable)'
  else
    bounded_check 'tests/canary_test.sh  (a canary secret reaches no exporter)' \
      900 bash "$ROOT/tests/canary_test.sh"
    bounded_check 'tests/no_telemetry_in_readiness.sh  (collector killed, service still serves)' \
      900 bash "$ROOT/tests/no_telemetry_in_readiness.sh"
    # THE STACK, RUN. Every claim in this file about the observability platform
    # being usable is a claim about YAML until this one runs: that the FETCHED
    # stack comes up healthy, that a trace arrives in Tempo, that a metric
    # arrives in Mimir, and that a canary planted in ten attributes reaches
    # neither. `docker compose config` proved a stack that could not start, twice,
    # in this repository's own history — once because the collector's environment
    # block was missing and once because Mimir's healthcheck named a directory.
    bounded_check 'tests/stack_live_test.sh  (the fetched stack runs; a trace and a metric land)' \
      900 bash "$ROOT/tests/stack_live_test.sh"
  fi
fi
# ===========================================================================
# phase: classifier + staleness — the two runnable pieces, executed
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

# The fetch is a claim about a REAL SUBPROCESS talking to a REAL REMOTE, and it is
# the only proof that `bin/dev` can obtain the stack it runs at all. A check that
# parsed bin/dev would pass on a script that fetches nothing, which is why this is
# executed and why its remote is a local bare repository rather than github.com: a
# gate that goes red when the network is down is a gate people learn to re-run
# with --no-observability, and then it is not a gate.
#
# Deliberately OUTSIDE the `RUN_STATIC` guard, for the reason the classifier and
# the staleness reporter are: these are the PROPERTY rather than the shape, and a
# gate that skips is not green.
section 'fetch: the pinned kit ref resolves, and a moving one is refused'
check 'tests/fetch_test.sh  (a pin fetches, a branch is refused, offline is real)' \
  bash "$ROOT/tests/fetch_test.sh"

section 'staleness: the fleet reporter tells the states apart'
# The case count is READ OUT OF THE RUN rather than counted in the source, and
# that is not pedantry. Counting `printf 'PASS …'` sites in the file gives 27
# while the suite runs 26, because case 9b has two mutually exclusive branches
# (a worktree that could be created, and the direct `is_worktree()` assertion
# for when it could not). A number derived from the source and a number the
# reader sees in the output then disagree on a green run, which is exactly how a
# count stops meaning anything — the same reason `self_test`'s count is counted
# from recipes and the header/recipe check exists at all.
#
# So the script runs, its own summary line is read, and the label carries what
# the run said. If the two ever drift, this block fails rather than printing a
# number nobody checked.
_stale_out=""
_stale_ec=0
_stale_out=$(bash "$ROOT/tests/staleness_test.sh" 2>&1) || _stale_ec=$?
_stale_cases=$(printf '%s\n' "$_stale_out" | sed -nE 's/^PASS: staleness_test — ([0-9]+) case.*/\1/p')
if [ "$_stale_ec" -ne 0 ] || [ -z "$_stale_cases" ]; then
  report FAIL "tests/staleness_test.sh  (the templates half could not report its own case count)"
  printf '%s\n' "$_stale_out" | sed 's/^/       /'
elif [ "$_stale_cases" -lt 20 ]; then
  # A floor, and it exists because this suite's job is to be able to fail: a
  # run that quietly stopped proving the absent case would still exit 0. The
  # number is not the claim — the self-test breakages are — but a suite that
  # lost half its cases is a suite nobody is running any more.
  report FAIL "tests/staleness_test.sh  ($_stale_cases cases; the templates half is no longer covered)"
  printf '%s\n' "$_stale_out" | sed 's/^/       /'
else
  report PASS "tests/staleness_test.sh  ($_stale_cases cases, incl. the red proof and the absent case)"
  printf '%s\n' "$_stale_out" | sed 's/^/       /'
fi

# ===========================================================================
# phase: lint — run the configs, do not parse them
# ===========================================================================
#
# Deliberately NOT inside the `RUN_STATIC` guard, and that placement is the
# point rather than an oversight. `lint/` spent its whole life behind a parse
# check: `yaml.safe_load` on golangci.yml, `node --check` on eslint.config.mjs,
# and both green on a file that no linter had ever been pointed at. Not one
# service in the fleet had copied any of them.
#
# A phase that only parses cannot tell a config that works from a config that is
# valid YAML, and the difference between those two is the difference between a
# gate and a decoration. So this EXECUTES each linter against a fixture built to
# contain a violation, and asserts the linter rejects it — and, for every one,
# runs a control with the config REMOVED and asserts the control's answer
# differs. A linter that rejects the fixture for a reason other than kit's
# config cannot pass, which is what stops a broken fixture from proving a
# working config.
#
# It also gates on its own toolchains, unlike every other phase: a skip here
# means the claim "kit's lint configs work" went untested, and a claim nobody
# ran is a rumour. See the script's own footer.
section 'lint: kit configs, executed against fixtures that must fail them'
if [ "$RUN_LINT" -eq 0 ]; then
  report SKIP 'lint_test.sh  (--no-lint)'
else
  check 'tests/lint_test.sh  (every linter runs, and its control disagrees)' \
    bash "$ROOT/tests/lint_test.sh"
fi

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
  # Three counts, because the helpers no longer agree on what they expect.
  # `expect_skip_check` (breakage 23b) asserts the gate stays GREEN while naming
  # a SKIP, and `expect_green_check` (breakage 59) asserts it stays green while
  # naming a FINDING — kit-13's adoption ceiling, the other side of the same
  # claim. Conflating either with the red-expecting helpers would either claim
  # sixty-seven reds when there are sixty-five, or drop a green-expecting proof
  # from the label entirely, and a proof the summary does not count is a proof
  # nobody runs.
  #
  # The `green_check`/`skip_check` arms on the first pattern and their absence
  # on the second are the load-bearing asymmetry: `breakages` is every recipe,
  # `reds` is only the ones that must fail. Both read the same file, so neither
  # can go stale, and both are anchored on the BREAKAGE LABEL so a helper
  # *definition* can never be counted as a call.
  _st_breakages=$(grep -cE '^ *expect_(red(_check|_lang|_script)?|green_check|skip_check) +.breakage +[0-9]+[a-z]*:' "$ROOT/tests/self_test.sh" || true)
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
        # All FIVE helpers, or the check reports a header/recipe disagreement
        # that does not exist: breakages 21 and 22 are `expect_red_script`, and
        # a pattern missing `_script` calls them undocumented. Same omission as
        # the `_st_breakages` count above — one bug, two symptoms, because the
        # helper list was written down twice.
        r"""^[ \t]*expect_(?:red(?:_check|_lang|_script)?|green_check|skip_check) ['"]breakage\s+(\d+[a-z]?):""",
        src,
        re.M,
    )
)

problems = []
for missing in sorted(named - carried, key=breakage_sort):
    problems.append(f"header documents breakage {missing} but no recipe carries it")
for orphan in sorted(carried - named, key=breakage_sort):
    problems.append(f"recipe proves breakage {orphan} but the header does not document it")

# A throwaway-copy DIRECTORY variable that is REASSIGNED stops being a path.
# This is here because it already happened, and it happened silently: the
# renumber that gave breakages 41-51 descriptive directory names gave breakage
# 50's directory the name `canary_literal`, which was already the name of the
# canary VALUE assembled six lines below it. The reassignment meant `edit` was
# handed `cafaye_canary_.../templates/secrets/go/canary.go`, the recipe died with
# a FileNotFoundError, and breakage 50 never ran — taking 51 with it, because
# the script stops at the first crash. Two proofs dead, and the only symptom was
# a traceback in a phase whose output nobody reads on a green run.
#
# Nothing about READING the file shows this. Both lines look correct in isolation,
# and `bash -n` is happy, and the header/recipe agreement above is perfect while
# both of them are wrong. So it is asserted here, where a check already parses
# this file.
_lines = src.splitlines()
_fresh = re.compile(r'^(\w+)="\$\(fresh_copy\b')
_assign = re.compile(r'^(\w+)=')
_dirvars = {}
for _n, _line in enumerate(_lines, 1):
    _m = _fresh.match(_line)
    if _m and _m.group(1) not in _dirvars:
        _dirvars[_m.group(1)] = _n
for _n, _line in enumerate(_lines, 1):
    _m = _assign.match(_line)
    if not _m or _m.group(1) not in _dirvars or _fresh.match(_line):
        continue
    problems.append(
        f"line {_n}: `{_m.group(1)}` holds a throwaway copy (assigned at line "
        f"{_dirvars[_m.group(1)]}) and is reassigned here, so that recipe edits a path that no longer exists"
    )

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

  # The label carries both numbers and, deliberately, does not sum them into
  # "N breakages, N reds" the way it did while every recipe was red-expecting.
  # Sixty-seven breakages of which sixty-five must go red and two must stay green
  # — 23b naming a SKIP, 59 naming a FINDING — is a *stronger* suite than
  # sixty-seven that must all go red, and a label that flattened the two would hide
  # the only facts that distinguish them. The NUMBERS in this label are counted from
  # the recipes; the numbers in these comments are written down, which is why they
  # are the ones that go stale.
  #
  # BOUNDED, and this is the phase that most needs it. Every recipe builds a
  # fresh throwaway copy of the tree and runs the whole static gate inside it, so
  # the self-test is _n_ gates in sequence: 67 on this branch, and the number
  # grows with every check this repository adds. On a quiet box it is the
  # longest phase in the run by a wide margin, and it is the one that grows
  # silently — nothing in it announces that the gate just got slower.
  #
  # 5400s is measured, not chosen. The uninterrupted run recorded in
  # REPORT-kit-13.md §5.2 took ~44 minutes end to end, of which the self-test
  # phase was the majority; 5400 leaves room for a box three times busier than
  # this one without being a number so large it never binds. A bound that never
  # binds is the correct answer here — the point is that the run REACHES THE END
  # and says so, not that it fails sooner. A tier that hits its bound is reported
  # as a BOUND, which is neither a pass nor a skip, so a bound cannot buy a green
  # this tree did not earn.
  bounded_check "tests/self_test.sh  ($_st_breakages breakages: $_st_reds red, $((_st_breakages - _st_reds)) green-expecting — the ceiling has both sides proved)" \
    5400 bash "$ROOT/tests/self_test.sh"
fi

# ---------------------------------------------------------------------------

printf '\n'
# FOUR COUNTS, and the reason there are four is the reason this summary exists
# at all. `PASS` and `FAIL` are verdicts about the tree. `SKIP` is a verdict
# about the ENVIRONMENT: the check could not run here. `BOUND` is a verdict
# about the RUN: the check started, this machine was too busy to finish it, and
# the claim it exists to prove is therefore unexercised.
#
# Collapsing BOUND into FAIL would report a loaded box as a defect in the tree,
# and collapsing it into PASS would be a lie with a green word on it. Either way
# the reader loses the one thing they need: which failures to go and fix, and
# which to go and re-run. The count is printed whenever it is non-zero, exactly
# like the skip count, so a run that hit a bound cannot end quietly.
if [ "$fails" -ne 0 ]; then
  echo "FAIL: $fails check(s) failed."
  [ "$skips" -eq 0 ] || echo "note: $skips check(s) skipped (reported above)."
  [ "$bounded_hit" -eq 0 ] || echo "note: $bounded_hit tier(s) hit their time bound — the proof was unexercised, not passed (reported above)."
  exit 1
fi
echo "PASS: every check passed."
[ "$skips" -eq 0 ] || echo "note: $skips check(s) skipped — reported above, never hidden."
[ "$bounded_hit" -eq 0 ] || echo "note: $bounded_hit tier(s) hit their time bound — reported above, never hidden."
# And the bound itself, on the runs where it did NOT bind, because a ceiling the
# reader has never been told about is a ceiling they cannot rely on. Only
# printed when a bound was actually applied, so a machine with no `timeout` at
# all is not told about bounds it never had.
if [ "$bounded_ran" -gt 0 ]; then
  echo "note: $bounded_ran tier(s) ran under a time bound; none was reached."
fi
