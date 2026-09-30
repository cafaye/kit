#!/usr/bin/env bash
#
# kit's proof that `tests/validate.sh` is able to fail.
#
#   bash tests/self_test.sh
#
# WHAT THIS IS FOR
#   A gate that only ever goes green is a report, not a gate. This script copies
#   the tree to a throwaway directory, breaks it once per kind of check, and
#   asserts the gate goes RED each time. Each breakage must be caught by a
#   *different* check, so a passing self_test means the checks are independent
#   and not one lucky assertion standing in for all of them.
#
# THE TWENTY-THREE BREAKAGES   (20 from the tier work, 21 from the
#                               fan-out work, 18 of them shared)
#   1. delete a language template   -> the artifact-presence check goes red
#   2. add a collector exporter    -> the privacy check goes red
#   2b. DELETE the tempo exporter   -> the same check goes red from the other
#        side. A set difference only catches the extra; this catches the
#        missing, which is the mistake that ships a stack that collects
#        everything and prints it.
#   3. corrupt the python codec    -> the executed test suite goes red
#   4. hardcode a compose port     -> the parameterization check goes red
#   5. flip the CI input default   -> the "consumers stay green" check goes red
#   6. ungate the `none` job       -> the option/job agreement check goes red
#   7-10. break the agreement between the documented `uses:` string and the
#         real path, in the four ways it can break -> the callable-path check
#         goes red
#   11-12. break a Dockerfile -> the hadolint check, and the non-root check that
#         exists because hadolint has no rule for a missing USER
#   13-18. one semantic mutation per language implementation -> THAT language's
#         suite goes red. A suite that has never failed has never been proven to
#         test anything, and six suites that only one language's mutation covers
#         is five suites that might assert nothing at all.
#   19. an allowlist entry that matches nothing -> the unused-entry check goes
#         red. This is the sharpest property kit owns, and it is the one with
#         the most room to be decorative: an allowlist rule that has never
#         rejected anything is a comment in a file with a `.gitignore`-shaped
#         name. Modelled on ESLint's reportUnusedDisableDirectives, which
#         reports a disable comment that no longer suppresses anything —
#         without that rule a skip list is a ratchet that only turns one way,
#         and within two quarters it contains every test in the repository.
#
#   Breakages 2 and 4 were both REWRITTEN in kit-03, for the same reason and it
#   is worth recording: their recipes named strings that no longer exist. 2
#   mutated `exporters: [debug]`, which the traces pipeline stopped being when
#   it began fanning out to three backends; 4 replaced a literal
#   `${KIT_POSTGRES_PORT:-5432}`, which stopped existing when the stack moved
#   into kit's 15000-15999 port block. In both cases `edit` refused to apply the
#   mutation — correct behaviour, since a stale recipe must not silently pass —
#   and the gate went red on that breakage and never reached the next one. A
#   self_test whose recipe no longer applies is a self_test that has stopped
#   testing the thing it names.
#   20. nest `includePaths` under `git:` -> the core fan-out check goes red. The
#         shape reads correctly, syncs successfully, and vendors the entire
#         upstream repository; it was run before it was written down.
#   21. make the change classifier FAIL OPEN -> classify_test.sh goes red. This
#         is the sharpest proof here: it inverts the fail-closed property and
#         asserts the suite notices, so the property is a counterexample rather
#         than a claim in a comment.
#   22. report an undeclared core pin as `current` -> staleness_test.sh goes red.
#         Two real repositories are in that state today, which is what makes the
#         difference between `undeclared` and `current` load-bearing.
#   23. a parity-allowlist entry naming an artefact kit does not ship -> the
#         dead-entry check goes red. The ESLint direction, and the mutation is
#         well-formed in every other respect, so a shape-only check passes it.
#   24. an EXPIRED parity-allowlist entry -> the same check goes red. The gate
#         reads the clock, and this is the first time anything in kit has
#         actually watched the ratchet fire rather than reading that it exists.
#   25. `tests/artifacts.json` naming a `{lang}` source kit does not ship for
#         every language -> the artefact-table check goes red. Half a language is
#         worse than none, and the table is what says so.
#   26. report an ABSENT artefact as `current` -> staleness_test.sh goes red.
#         This is the breakage the packet is for: the reporter treating the
#         commonest state in the fleet as the one that means everything is fine.
#   27. grade a copy by RESEMBLANCE rather than by equality -> staleness_test.sh
#         goes red. The failure mode the packet names: a file that looks like
#         kit's is not evidence it is kit's.
#   28. give one of the two programs a third-party import -> the carve-out check
#         goes red. "Standard library only" was a sentence in AGENTS.md for the
#         whole life of the rule and nothing checked it; a boundary nobody can
#         cross is not a boundary.
#   29. remove one fixture service's `.git`, so the reporter cannot see it ->
#         staleness_test.sh goes red AND blames the FIXTURE. Observed for real at
#         load average 160 before it was written: one case failed, 25 passed, and
#         the failure text named the reporter when the reporter had simply been
#         handed a smaller fleet. A red that misattributes itself is worse than
#         no red, so this asserts the EXPLANATION, not only the exit status.
#
#   These are numbered 20-22 rather than 19-21 because 19 is the allowlist
#   breakage above, from the tier work. Both packets numbered their first entry
#   independently and the collision is only visible in the union — which is what
#   the header/recipe check in validate.sh is for.
#
#   23-27 continue that numbering from the same two packets: 23-25 are the
#   parity-allowlist, artefact-table and carve-out checks (kit-14), 26-27 break
#   the staleness reporter's templates half, and 28 is the third-party import.
#   The reason the copy-is-gone case gets TWO breakages and not one is that
#   "report absent as current" and "grade by resemblance" are opposite mistakes
#   that a single mutation cannot both produce: one removes a finding, the
#   other invents one, and a gate that can only do one of them is half a gate.
#
#   Twelve of them (7-10, 11, 12, 19, 20, 23-25, 28) additionally assert WHICH
#         check went red. Every other breakage only proves the gate can fail;
#         those prove the check written for that defect is still load-bearing,
#         which is a different claim and the one that decays silently. 21, 22,
#         26 and 27 assert the same thing about the two scripts that are
#         themselves proofs, and 29 asserts it about the WORDING: a red that
#         blames the reporter when the fixture is at fault is a red that sends
#         the next reader to the wrong file.
#
#   The counts here were wrong twice and both times a check caught it rather
#   than a reader: the header said "seven" over a four-wide range, and it
#   numbered a second entry 19 while the recipes numbered it 20. A header that
#   drifts from the recipes is not documentation, it is a second, unchecked copy
#   of the truth — which is the entire thing validate.sh's header/recipe check
#         exists to prevent.
#
# WHAT IT IS NOT
#   This is not exhaustive mutation testing. Each implementation gets exactly one
#   mutant, chosen to be the bug a reviewer would not see: a dropped bit mask, an
#   alphabet that quietly grows a second case, a limit raised until it never
#   fires. One mutant per language proves the suite bites; it does not prove the
#   suite is complete, and nothing here should be read as claiming that is.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Standalone runs bootstrap too, and `validate.sh` exports KIT_PYTHON so the
# nested copies use the same interpreter. Self-bootstrapping here is not
# redundancy: `bash tests/self_test.sh` is a documented command, and a
# documented command that only works after a different documented command has
# been run is two commands wearing one name.
if [ ! -r "$ROOT/tests/bootstrap.sh" ]; then
  echo "self_test.sh: tests/bootstrap.sh is missing — cannot resolve a python" >&2
  exit 1
fi
# shellcheck source=tests/bootstrap.sh
. "$ROOT/tests/bootstrap.sh"
kit_bootstrap_python "$ROOT"
export KIT_PYTHON="$PY"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kit-self-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

failures=0
skips=0
copy_name=""

# A fresh throwaway copy per breakage: one breakage must never mask the next,
# and no breakage may touch the worktree this script was invoked from.
fresh_copy() {
  copy_name="$1"
  local dst="$WORK/$copy_name"
  mkdir -p "$dst"
  # `.github` is in this list and not an afterthought: the reusable workflow it
  # holds is the artifact every check that reads the workflow's inputs reads by
  # path, so a copy without it cannot fail the same way the real tree does.
  # `core` is here for the same reason `.github` is: the breakages below mutate
  # files in it, and a copy without it would fail on a missing path rather than
  # on the defect under test — which is a self_test that proves nothing.
  # `templates` is here for the parity-allowlist breakages below, and the copy
  # is useless without it: a copy missing the file the mutation edits would fail
  # on a missing path rather than on the defect, which is the failure mode
  # `edit` exists to prevent and the reason the failure is silent.
  for entry in .github AGENTS.md README.md CHANGELOG.md core docker lint templates tests; do
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

# expect_red_check <label> <dir> <check-label> <validate.sh args...>
#
# The stronger form of expect_red, and the one the layout/documentation checks
# need. `the gate went red` is a weak proof when forty checks can make it red:
# a breakage can be caught by the wrong check and still read as a pass, and the
# check it was written for can be dead code forever. This asserts that ONE
# named check reported FAIL, so a check that stops being load-bearing fails
# here rather than being discovered months later by the defect it missed.
#
# The check label is matched as a literal prefix of the FAIL line, so it is the
# exact label validate.sh prints. A rename on either side breaks this loudly,
# which is the intended behaviour: a renamed check and a stale proof are the
# same defect.
expect_red_check() {
  local label="$1" dir="$2" want="$3"
  shift 3
  local out ec=0
  out=$(cd "$dir" && KIT_PYTHON="$PY" bash tests/validate.sh "$@" 2>&1) || ec=$?
  if printf '%s\n' "$out" | grep -qF "FAIL $want"; then
    printf 'PASS self_test: %s — caught by `%s`\n' "$label" "$want"
  elif [ "$ec" -eq 0 ]; then
    printf 'FAIL self_test: %s — the gate stayed GREEN\n' "$label"
    failures=$((failures + 1))
  else
    printf 'FAIL self_test: %s — the gate went red, but NOT via `%s`\n' "$label" "$want"
    printf '%s\n' "$out" | grep '^FAIL' | sed 's/^/       /'
    failures=$((failures + 1))
  fi
}

# expect_red_script <label> <dir> <script> <args...>
#
# For the two scripts that ARE a proof rather than a gate over a tree:
# classify_test.sh asserts the classifier fails closed, staleness_test.sh asserts
# the reporter tells the states apart. Breaking one of them and asserting THAT
# script goes red is the same claim expect_red_check makes — the check written
# for this defect is still load-bearing — expressed over a script.
expect_red_script() {
  local label="$1" dir="$2" script="$3" want="${5:-}"
  shift 3
  # The optional 4th argument (always pass an empty one) is where a script's own
  # arguments go; the optional 5th is a string the output MUST contain. A proof
  # that goes red for the wrong reason is not a proof, and the one case that
  # needs the stronger claim is a red that would otherwise be MISREPORTED — so
  # the name is unchanged and the pattern in validate.sh still matches, rather
  # than a new helper that would read as an undocumented breakage.
  if (cd "$dir" && KIT_PYTHON="$PY" bash "$script" "$@" >/dev/null 2>&1); then
    printf 'FAIL self_test: %s — the proof stayed GREEN\n' "$label"
    failures=$((failures + 1))
  elif [ -n "$want" ]; then
    local out
    out=$(cd "$dir" && KIT_PYTHON="$PY" bash "$script" "$@" 2>&1) || true
    if printf '%s\n' "$out" | grep -qF "$want"; then
      printf 'PASS self_test: %s — the proof went red, and said why\n' "$label"
    else
      printf 'FAIL self_test: %s — the proof went red but did NOT say %s\n' "$label" "$want"
      printf '%s\n' "$out" | grep -E '^(FAIL|PASS)' | sed 's/^/       /'
      failures=$((failures + 1))
    fi
  else
    printf 'PASS self_test: %s — the proof went red\n' "$label"
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

# expect_red_lang <label> <dir> <lang> <file> <old> <new>
#
# The per-language mutation. Copies one implementation out, breaks one spec rule
# in it, and asserts THAT language's suite goes red — not the whole gate, and
# certainly not a neighbouring language's. A green result here means the suite
# for that language asserts nothing about that rule.
#
# Each mutant is semantic: it compiles, it parses, it runs. Replacing a call with
# a syntax error would prove only that the toolchain is installed, which is not
# in question.
expect_red_lang() {
  local label="$1" dir="$2" lang="$3" file="$4" old="$5" new="$6"
  local work="$WORK/mutant-$lang"

  rm -rf "$work"
  cp -R "$dir/templates/otel/$lang" "$work"

  if ! edit "$work/$file" "$old" "$new" 2>/dev/null; then
    # `edit` fails when the source has moved past the mutation. That is a real
    # failure: the proof this breakage was written to provide no longer exists.
    printf 'FAIL self_test: %s — the mutation no longer applies\n' "$label"
    printf '       %s\n' "$file"
    failures=$((failures + 1))
    return
  fi

  # A missing toolchain is a SKIP, reported as such. It is not a pass: an
  # unexecuted mutation proves nothing, and the summary counts it.
  local runner
  case "$lang" in
    go) runner=go ;;
    ruby) runner=ruby ;;
    elixir) runner=elixir ;;
    python) runner=python3 ;;
    node) runner=node ;;
    rust) runner=rustc ;;
  esac
  if ! command -v "$runner" >/dev/null 2>&1; then
    printf 'SKIP self_test: %s — %s not installed\n' "$label" "$runner"
    skips=$((skips + 1))
    return
  fi

  # Captured immediately, with no `&&` between the run and the read, and each
  # capture guarded by `|| ec=$?`.
  #
  # Both halves of that matter, and the first version of this function got the
  # first one wrong in a way that made the whole self_test exit 1 silently at
  # breakage 6, printing nothing at all:
  #
  #   - `out=$(cmd)` on its own line is an ASSIGNMENT. When `cmd` fails, the
  #     assignment's status is `cmd`'s status, so `set -e` kills the script on
  #     that line — before the `ec=$?` beneath it ever runs. The failing suite
  #     was never observed; the harness simply vanished. Guarding with `||`
  #     makes the command part of a list, which `set -e` does not apply to, so
  #     the run completes and its status can be read. This is the same failure
  #     PLAN.md's gate-discipline rule is about, one level down: a gate whose
  #     exit code was not observed is unrun, not green.
  #   - `&& ec=0 || ec=$?` is the obvious wrong fix: it reports the status of
  #     the `||` branch rather than the run's.
  local out ec=0
  case "$lang" in
    go)
      out=$(cd "$work" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local go test ./... 2>&1) || ec=$?
      ;;
    ruby) out=$(ruby "$work/test_traceparent.rb" 2>&1) || ec=$? ;;
    elixir) out=$(elixir -r "$work/traceparent.ex" "$work/test_traceparent.exs" 2>&1) || ec=$? ;;
    python) out=$(python3 "$work/test_traceparent.py" 2>&1) || ec=$? ;;
    node) out=$(node --test "$work/traceparent.test.mjs" 2>&1) || ec=$? ;;
    rust)
      if rustc --test --edition 2021 -o "$work/kit-mutant-rust" "$work/traceparent.rs" \
        >"$work/build.log" 2>&1; then
        out=$("$work/kit-mutant-rust" 2>&1) || ec=$?
      else
        # A mutant that does not compile proves NOTHING. The suite went red
        # without running, which is indistinguishable from a green suite to any
        # harness that only reads the exit code — and a mutation that breaks the
        # build instead of the behaviour means the spec rule under test was
        # never reached. This is its own verdict, not a pass.
        printf 'FAIL self_test: %s — the mutant did not compile, so the suite never ran\n' "$label"
        sed 's/^/       /' "$work/build.log"
        failures=$((failures + 1))
        return
      fi
      ;;
  esac

  if [ "$ec" -eq 0 ]; then
    printf 'FAIL self_test: %s — the suite stayed GREEN on a broken codec\n' "$label"
    # Printed here and nowhere else, because this is the one branch where the
    # output is the diagnosis: a green run tells you the rule is unasserted, and
    # the run tells you which test file claims to assert it.
    printf '%s\n' "$out" | tail -20 | sed 's/^/       /'
    failures=$((failures + 1))
  else
    printf 'PASS self_test: %s\n' "$label"
  fi
}

printf -- '-- self_test: a gate that cannot fail is not a gate\n'

# The control. If the unbroken tree is already red, the breakages below
# prove nothing, so this runs first and the run is meaningless without it.
base="$(fresh_copy base)"
expect_green 'unbroken tree' "$base" --static-only

# 1. a deleted language template. Caught by the artifact-presence check, which
#    runs with no toolchains at all — so "nobody had Go installed" can never be
#    the reason a missing template passes.
one="$(fresh_copy missing-template)"
rm -f "$one/templates/otel/go/traceparent.go"
expect_red 'breakage 1: templates/otel/go/traceparent.go deleted' "$one" --static-only

# 2. the privacy boundary, in the shape the check actually forbids. This recipe
#    mutated `exporters: [debug]` -> `exporters: [debug, otlp]`, which was the
#    traces pipeline as it stood before the collector fanned out to three
#    backends. The pipeline now reads `[spanmetrics, otlp/tempo, debug]`, the
#    string is gone, and `edit` refused to apply it — which is the right
#    behaviour (a stale mutation recipe must not silently pass) and is also why
#    the gate went red on breakage 2 and never reached 3.
#
#    The mutation below therefore ADDS the exporter the check warns about by
#    name: a bare `otlp` with an endpoint a developer could paste, sitting
#    beside the three backends it has no business next to.
two="$(fresh_copy exporting-collector)"
edit "$two/templates/compose/otel-collector.yml" \
  '  otlp/tempo:
' \
  '  otlp:
    endpoint: ${env:KIT_TEMPO_OTLP_ENDPOINT}
  otlp/tempo:
'
edit "$two/templates/compose/otel-collector.yml" \
  'exporters: [spanmetrics, otlp/tempo, debug]' \
  'exporters: [spanmetrics, otlp/tempo, debug, otlp]'
expect_red 'breakage 2: collector gains an exporter nobody read' "$two" --static-only

# 2b. THE OTHER HALF OF THE SAME CLAIM, and the one a set difference never
#     checked. Breakage 2 above proves the gate objects to an exporter that
#     should not be there; this proves it objects to a BACKEND THAT IS MISSING.
#     A config whose only exporter is `debug` satisfies "nothing unexpected"
#     while shipping no observability at all — a stack that collects everything
#     and prints it. Deleting the whole tempo exporter block takes out the
#     definition and the pipeline reference together, which is what deleting it
#     in review would actually look like.
two_b="$(fresh_copy missing-backend)"
edit "$two_b/templates/compose/otel-collector.yml" \
  '      exporters: [spanmetrics, otlp/tempo, debug]' \
  '      exporters: [spanmetrics, debug]'
"$PY" - "$two_b/templates/compose/otel-collector.yml" <<'PY'
import re
import sys

# Drop the whole `otlp/tempo:` block by indentation, the same way the canary
# test removes one — a regex anchored on the next key does not survive the
# comment block that sits between the exporters.
path = sys.argv[1]
lines = open(path, encoding="utf-8").read().splitlines(keepends=True)
start = next(i for i, line in enumerate(lines) if line.rstrip("\n") == "  otlp/tempo:")
end = start + 1
while end < len(lines) and (not lines[end].strip() or lines[end].startswith("    ")):
    end += 1
open(path, "w", encoding="utf-8").write("".join(lines[:start] + lines[end:]))
PY
expect_red 'breakage 2b: the collector ships no exporter for tempo at all' "$two_b" --static-only

# 3. a template that compiles, parses, and silently drops the sampled flag.
#    Only an executed suite catches this; no grep would.
three="$(fresh_copy broken-codec)"
edit "$three/templates/otel/python/traceparent.py" \
  'flags & SAMPLED' '0 & SAMPLED'
expect_red 'breakage 3: python codec stops preserving trace-flags' "$three" \
  --language=python --no-self-test

# 4. a hardcoded host port. The kind of edit nobody notices in review and every
#    second service on a laptop hits.
#
#    The default this one used to pin was 5432. That was correct when
#    docker-compose.yml was the only compose file in kit; the observability work
#    moved every published port into the 15000-15999 block, so the literal this
#    replaced no longer exists and `edit` refused — which is why the gate went
#    red here having passed 1, 2, 2b and 3. The recipe is now pinned to the port
#    actually shipped, so this breakage is the one a reviewer would really make:
#    taking the default out of the substitution.
four="$(fresh_copy hardcoded-port)"
edit "$four/templates/compose/docker-compose.yml" \
  '"${KIT_POSTGRES_PORT:-15500}:5432"' '"5432:5432"'
expect_red 'breakage 4: docker-compose.yml hardcodes a published port' "$four" --static-only

# 5. a kit change that would break every consumer's CI. The opt-in job must stay
#    opt-in and the six original jobs must stay gated on their language.
five="$(fresh_copy ci-not-opt-in)"
edit "$five/.github/workflows/ci.reusable.yml" "default: 'false'" "default: 'true'"
expect_red "breakage 5: the telemetry CI job is no longer opt-in" "$five" --static-only

# 6. the option with no job. A caller can pass `language: none` — the value
#    that lets a repository with no service manifest (kit among them) call this
#    workflow at all — and get a green build that ran nothing, because the job
#    is no longer guarded by the input that selects it. The drift AGENTS.md
#    calls out for any new `language` option, proven on the one option whose
#    absence is a broken call rather than a missing toolchain.
six="$(fresh_copy ungated-config-job)"
edit "$six/.github/workflows/ci.reusable.yml" \
  "if: \${{ inputs.language == 'none' }}" \
  "if: \${{ inputs.language == 'go' }}"
expect_red 'breakage 6: the `none` job is no longer gated on its own input' "$six" --static-only

# 7-10. The four ways the layout and the documentation can drift apart. These
#      are the class of defect this packet exists to make detectable: a stated
#      fact — "callers write `uses: cafaye/kit/.github/workflows/...`" — that
#      stops being true while every other check stays green. Each names the
#      specific check that must catch it, because "the gate went red" is a weak
#      claim when the callable check is one of forty that could have gone red.
CALLABLE='.github/workflows/ci.reusable.yml  (callable: exists, on: workflow_call, docs agree)'

# 7. The documented call points at a file that EXISTS. `ci.yml` is right there
#    in the same directory, so a typo that resolves to a real path is invisible
#    to any check that only asks "is there a file at the documented path" — and
#    a `uses:` line naming `ci.yml` gets a caller a workflow that is not
#    reusable at all. Only a comparison against the real path catches it.
seven="$(fresh_copy doc-points-elsewhere)"
edit "$seven/README.md" \
  'uses: cafaye/kit/.github/workflows/ci.reusable.yml@master' \
  'uses: cafaye/kit/.github/workflows/ci.yml@master'
expect_red_check 'breakage 7: README documents a `uses:` path that is not the reusable workflow' \
  "$seven" "$CALLABLE" --static-only

# 8. The file is in the right place and still cannot be called. `on:
#    workflow_call` removed is a legal-looking workflow that GitHub rejects
#    before it reads one input, so every caller gets a red build with no
#    explanation. Parseable is not callable.
eight="$(fresh_copy not-callable)"
edit "$eight/.github/workflows/ci.reusable.yml" \
  '  workflow_call:' '  workflow_dispatch:'
expect_red_check 'breakage 8: the workflow no longer declares `on: workflow_call`' \
  "$eight" "$CALLABLE" --static-only

# 9. A second copy, parked where the documented path does not point. This is the
#    other layout the packet offered — canonical file plus a thin callable
#    copy — and it is only acceptable with a check that fails when the copies
#    differ. kit chose the move, so the gate refuses to find a second one at
#    all. Two CI standards is the drift this repository exists to prevent.
nine="$(fresh_copy divergent-copy)"
mkdir -p "$nine/workflows"
cp "$nine/.github/workflows/ci.reusable.yml" "$nine/workflows/ci.reusable.yml"
expect_red_check 'breakage 9: a second copy of the reusable workflow, out of reach' \
  "$nine" "$CALLABLE" --static-only

# 10. kit's own CI stops calling itself locally, and reaches across the network
#     to some other ref instead. The job still runs and still goes green, so
#     this is invisible — but the job was the proof. A self-proof that fetches
#     `master` proves that master's path works, not that this commit's does.
#
#     The `edit` anchor includes the job name, and not because the job name is
#     interesting. The bare `uses:` line occurs twice in that file — once in the
#     comment explaining why the self-call exists, once in the job — and a
#     first-match replacement hit the comment, left the job alone, and reported
#     the gate stayed GREEN. Which was the check being right and the mutation
#     being sloppy: a `uses:` line inside a comment is documentation, and the
#     callable check deliberately does not read it.
ten="$(fresh_copy self-call-not-local)"
edit "$ten/.github/workflows/ci.yml" \
  '    name: gate
    uses: ./.github/workflows/ci.reusable.yml' \
  '    name: gate
    uses: cafaye/kit/.github/workflows/ci.reusable.yml@master'
expect_red_check 'breakage 10: kit CI calls a remote ref instead of its own local copy' \
  "$ten" "$CALLABLE" --static-only

# 11-12. The Dockerfiles. These are one of the four artifacts every adopting
#       service inherits, and until this packet they were the only artifact in
#       the tree with no parser at all — seven `SKIP ... (no parser for this
#       file type)` lines that nobody had to look at twice because the summary
#       said "note: 7 skipped".
#
#       A skipped check proves nothing (PLAN.md §1), so each breakage asserts a
#       NAMED check went red, and the two breakages target the two different
#       claims: the linter, and the rules the linter does not cover.
DOCKERLINT='docker/Dockerfile.*  (non-root final stage, no :latest, no ADD)'

# 11. A Dockerfile defect only hadolint can see. `pip install uv` with no
#     version is DL3013, and it was in the tree the whole time — a resolver
#     whose version silently decides what your lockfile resolves to.
eleven="$(fresh_copy unpinned-pip)"
edit "$eleven/docker/Dockerfile.python" \
  'RUN pip install "uv==${UV_VERSION}" \' 'RUN pip install uv \'
expect_red_check 'breakage 11: a Dockerfile pins nothing (hadolint DL3013)' \
  "$eleven" 'docker/Dockerfile.python  (hadolint)' --static-only

# 12. A Dockerfile defect hadolint does NOT see: the final stage dropped its
#     USER, so the image would run as root. hadolint has no rule for this —
#     DL3002 ("last USER should not be root") only fires when a USER is
#     present and wrong, and a missing USER is silence. This is the check that
#     has to exist precisely because the real parser cannot cover it.
twelve="$(fresh_copy dockerfile-as-root)"
edit "$twelve/docker/Dockerfile.go" 'USER nonroot:nonroot' '# USER removed'
expect_red_check 'breakage 12: a Dockerfile final stage runs as root' \
  "$twelve" "$DOCKERLINT" --static-only

# 13-18. One semantic mutation per language implementation, each against a
# different spec rule, and each asserting THAT language's suite goes red.
#
# These all read from the same throwaway copy as breakage 1 rather than taking a
# fresh one each: the copy is only mutated inside a per-language temp dir, so no
# language can see another's breakage.
base="$(fresh_copy language-mutants)"

#   go    §3.2.2.5  stop masking trace-flags on read. Still compiles, still runs,
#                  and quietly forwards reserved bits to the next service.
expect_red_lang 'breakage 13: go stops masking trace-flags (§3.2.2.5)' \
  "$base" go traceparent.go \
  'Flags:      tp.Flags & sampledFlag,' \
  'Flags:      tp.Flags,'

#   ruby  §3.2.2  widen the alphabet to accept uppercase hex. The classic bug:
#                one service folds case, the next rejects the header, and a trace
#                breaks at the hop between them.
expect_red_lang 'breakage 14: ruby accepts uppercase hex (§3.2.2)' \
  "$base" ruby traceparent.rb \
  '!str.empty? && str.match?(/\A[0-9a-f]+\z/)' \
  '!str.empty? && str.match?(/\A[0-9a-fA-F]+\z/)'

#   elixir §3.2.2.2  stop rejecting trailing data on a version-00 header. Nothing
#                   crashes; the header is just no longer the format we claim to
#                   implement.
expect_red_lang 'breakage 15: elixir accepts trailing junk on version 00 (§3.2.2.2)' \
  "$base" elixir traceparent.ex \
  'defp check_trailing(value, 0), do: if(byte_size(value) == @min_header_len, do: :ok, else: {:error, :invalid})' \
  'defp check_trailing(_value, 0), do: :ok'

#   node  §3.3.1.5  raise the tracestate limit until truncation never fires. A
#                   limit nobody enforces is a limit nobody wrote on purpose.
expect_red_lang 'breakage 16: node never truncates tracestate (§3.3.1.5)' \
  "$base" node traceparent.mjs \
  'const TRACESTATE_LIMIT = 512;' \
  'const TRACESTATE_LIMIT = 100000;'

#   rust  §3.2.2.3  accept an all-zero trace-id. The spec forbids it outright; a
#                   codec that allows it merges unrelated traces into one.
expect_red_lang 'breakage 17: rust accepts an all-zero trace-id (§3.2.2.3)' \
  "$base" rust traceparent.rs \
  'if trace_id == ZERO_TRACE_ID || parent_id == ZERO_SPAN_ID {' \
  'if parent_id == ZERO_SPAN_ID {'

#   python §3.2.2.5  the same dropped mask as go, in a different language, on
#                   purpose: a rule asserted in one suite and not the other is a
#                   rule two services will disagree about.
expect_red_lang 'breakage 18: python stops masking trace-flags (§3.2.2.5)' \
  "$base" python traceparent.py \
  'flags=parsed.flags & SAMPLED,' \
  'flags=parsed.flags,'

# 19. THE UNUSED ALLOWLIST ENTRY. The rule that stops the skip allowlist from
#     becoming a list of every test in the repository, and the one most likely to
#     be decorative — a hygiene rule in a data file, which is exactly the shape
#     of a check nobody has ever seen fail.
#
#     The mutation is the realistic one: somebody fixed the skip, or renamed the
#     test, and left the entry behind. The entry it appends is well-formed in
#     every OTHER respect — it has a reason, an owner, a since, an until, and it
#     is not a duplicate. It is only unused, which is precisely the failure the
#     rule exists to catch and precisely the one a shape-only check would pass.
#
#     This asserts the NAMED check, because a tree can go red for a dozen
#     unrelated reasons and "the gate went red" would not prove that the unused
#     -entry rule is what rejected it.
ALLOWLIST='templates/tier/skip-allowlist  (reason, owner, since, until; unused entries fail)'

nineteen="$(fresh_copy unused-allowlist-entry)"
cat >>"$nineteen/templates/tier/skip-allowlist" <<'ENTRY'
skipped db go/tier_db_test.go TestTierDBRenamedAway reason="the test this was written for was renamed; the entry outlived it" owner=kit since=2026-09-30 until=2026-12-31
ENTRY
expect_red_check 'breakage 19: an allowlist entry that matches nothing' \
  "$nineteen" "$ALLOWLIST" --static-only
# 20-22. The core fan-out. Three breakages, and the middle one is the sharpest
#       proof in this file: it INVERTS the fail-closed property and asserts the
#       suite notices. Every other breakage proves a check can fail; this one
#       proves the property is load-bearing rather than asserted in a comment.

# 20. The trap that is not loud. `includePaths` nested under `git:` is dropped
#     silently by vendir's unmarshalling, and the sync then vendors the ENTIRE
#     upstream repository while exiting 0. It was run before it was written down;
#     see core/vendir/README.md. A config that reads correctly and does the
#     opposite of what it says is the worst class of defect to ship, so the gate
#     names the specific check.
COREFANOUT='core/vendir/ + core/renovate/  (structurally what Renovate and vendir need)'

twenty="$(fresh_copy include-paths-under-git)"
edit "$twenty/core/vendir/vendir.yml.pantry" \
  '        newRootPath: schemas
        git:
          url: https://github.com/cafaye/core.git
          ref: master' \
  '        newRootPath: schemas
        git:
          url: https://github.com/cafaye/core.git
          ref: master
          includePaths:
          - schemas/cafaye.manifest.schema.json'
expect_red_check 'breakage 20: includePaths nested under `git:` (vendors everything, exits 0)' \
  "$twenty" "$COREFANOUT" --static-only

# 21. THE SHARPEST ONE. Break the classifier so an UNRECOGNISED change is
#     reported as WIRE instead of FILE — that is, make it fail OPEN. Every test
#     in classify_test.sh that asserts a failure is now asserting nothing, and
#     the suite must go red rather than quietly reporting 16 passes.
#
#     This is the difference between "the classifier fails closed" as a claim in
#     a README and as a property with a counterexample. The counterexample is
#     here, in the gate, and it is one line long: which is the point. The
#     fail-closed property is one `if` returning `"FILE"`, and the only thing
#     standing between that `if` and a fleet-wide silent break is this test.
#
#     It edits `unrecognisedIsBreaking` in tests/rules.json rather than a string in
#     Python, and that is the entire reason the value lives there. The first
#     version of this breakage inverted a hardcoded "FILE" inside classify.py and
#     the suite stayed GREEN - because the same tier was ALSO a rule in
#     rules.json, so the headline case never reached the line that was broken.
#     A property stated in two places is a property stated in neither, and the
#     duplication was invisible until something tried to break it.
twentyone="$(fresh_copy classifier-fails-open)"
edit "$twentyone/tests/rules.json" \
  '"unrecognisedIsBreaking": true' '"unrecognisedIsBreaking": false'
expect_red_script 'breakage 21: the classifier FAILS OPEN on an unrecognised change' \
  "$twentyone" tests/classify_test.sh

# 22. The opposite error, and it is the expensive direction. Reporting a
#     repository with no recorded core pin as `current` makes the fleet look
#     clean. Two of the real repositories are in exactly that state today —
#     `caf` and `pantry` hold vendored bytes with no recorded origin — so the
#     difference between `undeclared` and `current` is the difference between a
#     report and a rumour.
twentytwo="$(fresh_copy undeclared-reads-current)"
edit "$twentytwo/tests/staleness.py" '    return UNDECLARED' '    return CURRENT'
expect_red_script 'breakage 22: the staleness reporter calls an undeclared pin current' \
  "$twentytwo" tests/staleness_test.sh

# 23-25. The parity allowlist and the artefact table.
#
#     23 is the ESLint shape — an entry naming an artefact kit does not ship.
#     24 is the ratchet firing. 25 is half a language.
#
#     All three entries are well-formed in every OTHER respect. That is the
#     point: a shape-only check passes all three, and a hygiene rule in a data
#     file is exactly the shape of a check nobody has ever seen fail.
#
#     WHAT THE GATE CANNOT CHECK, AND THE RECIPE THAT CLAIMED IT COULD. An
#     entry naming a repository that does not exist IS a real failure, and the
#     REPORTER catches it — it is handed `--repos-dir` and can see what is
#     there — and `tests/staleness_test.sh` proves it in three shapes, one of
#     which is exactly that. The first version of this recipe asserted it
#     against the GATE, which stayed green and the breakage failed: kit's CI has
#     no sibling checkouts, so no gate in this repository can know which
#     repositories exist. A recipe that asserts a check which does not exist is
#     a proof of nothing, and the fix is to re-point it at a property the gate
#     really has rather than to add a fleet roster to kit so the gate could
#     answer a question it was never asked.
PARITY='templates/parity-allowlist  (reason, owner, since, until; dead entries fail)'
ARTTABLE='tests/artifacts.json  (every declared source exists, for every language)'

# 23. An entry for an artefact kit does not ship. The realistic version is a
#     rename: `lint/eslint.config.mjs` becomes `lint/eslint.config.ts`, the
#     entry keeps the old id, and it is now exempting nothing.
#
#     The id below is checked against `tests/artifacts.json` FIRST, and the
#     first version of this recipe used `lint/eslint.config.mjs` — a real id —
#     so the gate stayed GREEN and the breakage proved nothing. A mutation that
#     has silently stopped breaking the thing it names is the same defect as a
#     stale test, and the fix is to make the recipe assert its own premise
#     rather than to trust that the string looks like an id.
twentythree="$(fresh_copy dead-parity-entry)"
if grep -q 'lint/eslint.config.ts' "$twentythree/tests/artifacts.json"; then
  echo "FAIL self_test: breakage 23's dead artefact id is REAL — the recipe no longer mutates anything" >&2
  failures=$((failures + 1))
fi
cat >>"$twentythree/templates/parity-allowlist" <<'ENTRY'
diverged billing lint/eslint.config.ts reason="this artefact was renamed in artifacts.json, so this entry exempts nothing" owner=kit since=2026-09-30 until=2026-12-31
ENTRY
expect_red_check 'breakage 23: a parity entry naming an artefact kit does not ship' \
  "$twentythree" "$PARITY" --static-only

# 24. AN EXPIRED ENTRY — THE RATCHER FIRING.
#
#     The first recipe here asserted that a parity entry naming a repository
#     that does not exist takes the gate red. It does not, and it cannot: kit's
#     CI has no sibling checkouts, so the gate has no way to know which
#     repositories exist. The reporter knows (it is handed `--repos-dir`) and
#     `tests/staleness_test.sh` proves it in three shapes, including this one;
#     asserting it again against a check that does not exist would be a proof of
#     nothing. So the recipe is spent on a property the gate really has and
#     nothing has yet tried to break: **the gate reads the clock**.
#
#     The tier skip-allowlist has had that rule for a packet and nothing has
#     ever watched it fire — its own header says "a gate that has never gone
#     red is a report", and this is the first time anything in kit has actually
#     made the statement true. The date is in the past on purpose, and the
#     entry is well-formed in every other respect: a real artefact, a real
#     repository, a reason, an owner and a `since`. Only the `until` is wrong.
twentyfour="$(fresh_copy expired-parity-entry)"
cat >>"$twentyfour/templates/parity-allowlist" <<'ENTRY'
diverged billing mise.toml reason="this entry is well formed in every other respect; only the date is wrong, which is the point" owner=billing since=2020-01-01 until=2020-12-31
ENTRY
expect_red_check 'breakage 24: an expired parity entry — the gate reads the clock' \
  "$twentyfour" "$PARITY" --static-only

# 25. A `{lang}` source kit does not ship for one language. `bun` is the one
#     that matters: it was added late and for a service that had been
#     hand-rolling a whole workflow for want of it, so it is the language most
#     likely to be half-adopted again.
#
#     The mutation DELETES the source rather than corrupting it, because that is
#     the defect: not a broken primer, a missing one, which is the one shape
#     every existing check would sail past.
twentyfive="$(fresh_copy half-a-language)"
rm -f "$twentyfive/templates/bin-prime/bun.sh"
expect_red_check 'breakage 25: kit offers `language: bun` but ships no primer for it' \
  "$twentyfive" "$ARTTABLE" --static-only

# 26. AN ABSENCE REPORTED AS `current`.
#
#     This is the breakage the packet exists for. The templates half's commonest
#     state in the real fleet is `absent` — 0 of 9 services hold the collector,
#     1 of 9 holds `bin/dev` — and the one-line way to make all of that
#     disappear is to grade a path that is not there as fine.
#
#     The mutation is in the state table, not in the comparison, because the
#     comparison is not what is wrong: reading a missing file as "no
#     difference" is a one-word change in the classification and it turns the
#     most alarming column of the report into a green one.
twentysix="$(fresh_copy absent-reads-current)"
edit "$twentysix/tests/staleness.py" \
  '    if missing:
        cell["state"] = TPL_ABSENT' \
  '    if missing:
        cell["state"] = TPL_CURRENT'
expect_red_script 'breakage 26: the staleness reporter calls an ABSENT artefact current' \
  "$twentysix" tests/staleness_test.sh

# 27. GRADE BY RESEMBLANCE.
#
#     The packet's third requirement: never infer a pin from content. The
#     realistic bug is a well-intentioned threshold — a future reader decides
#     99.9% identical is close enough, because the alternative (a flag on every
#     re-copy) is annoying.
#
#     `difflib.SequenceMatcher(...).quick_ratio()` is exactly that threshold,
#     already imported, and it is the shape a helpful patch would take. The
#     assertion it has to break is the one asserting a ONE-BYTE difference is
#     `diverged`, which is the property in its smallest form.
twentyseven="$(fresh_copy grade-by-resemblance)"
edit "$twentyseven/tests/staleness.py" \
  '        if pair_kit == repo_bytes:' \
  '        if pair_kit == repo_bytes or matcher_ratio(pair_kit, repo_bytes) > 0.99:'
cat >>"$twentyseven/tests/staleness.py" <<'PY'


def matcher_ratio(a: bytes, b: bytes) -> float:
    """The resemblance threshold the packet forbids. Added by self_test 27."""
    import difflib

    return difflib.SequenceMatcher(None, a, b, autojunk=False).quick_ratio()
PY
expect_red_script 'breakage 27: the reporter grades a copy by resemblance, not equality' \
  "$twentyseven" tests/staleness_test.sh

# 28. THE CARVE-OUT BOUNDARY.
#
#     `core/` ships two programs and AGENTS.md says they are "standard library
#     only, no import outside json/os/re/sys/argparse/subprocess". Nothing
#     checked that sentence for the whole life of the rule, which made it a
#     promise — and a promise nobody can break is decoration. kit is a
#     configuration repository; a `pip install` in one of these files is a
#     dependency, and the whole argument for the carve-out is that there are
#     none.
#
#     The mutation is a function-local import, because a function-local import is
#     what a contributor actually writes when they are being careful about
#     looking tidy, and it is the shape a grep-based check would miss. The check
#     walks the AST, so there is nowhere to put one that it cannot see.
twentyeight="$(fresh_copy a-third-party-import)"
"$PY" - "$twentyeight/tests/staleness.py" <<'PY'
import sys

path = sys.argv[1]
body = open(path, encoding="utf-8").read()
# Appended at the end, at module scope, so the file still parses and still runs:
# a mutation that broke the program would prove only that Python exists.
with open(path, "a", encoding="utf-8") as fh:
    fh.write("\n\ndef _third_party():\n    import requests  # self_test breakage 28\n")
PY
expect_red_check 'breakage 28: one of the two programs gains a third-party import' \
  "$twentyeight" 'tests/classify.py + tests/staleness.py' --static-only

# 29. A HARNESS THAT LIES ABOUT ITS OWN FLEET.
#
#     Observed for real before it was written here. Under load average 160 the
#     suite failed one case and passed 25, the reporter having measured 8 repos
#     and 96 cells where the fixture holds 9 and 108 — and the failing case's
#     text named the reporter, which is precisely what it must not do when the
#     reporter was reading a smaller fleet rather than misreading a full one.
#
#     So the fixture is now checked before any case asserts on it: every service
#     the cases name must have a cell the reporter measured. This breakage
#     removes one service's `.git` — the shape a transient `git init` failure
#     leaves behind — and asserts the suite goes red AND says the failure is in
#     the fixture rather than in the reporter. A check that only proved the
#     script exits non-zero would pass on a suite that reported the same
#     misleading red, so the assertion is on the message.
twentynine="$(fresh_copy a-fixture-service-the-reporter-cannot-see)"
edit "$twentynine/tests/staleness_test.sh" \
  'mksvc absent-svc node' \
  'mksvc absent-svc node
rm -rf "$TPL/absent-svc/.git"'
expect_red_script 'breakage 29: the suite cannot tell a broken FIXTURE from a broken reporter' \
  "$twentynine" tests/staleness_test.sh '' 'this is NOT a reporter result'

printf '\n'
if [ "$failures" -ne 0 ]; then
  echo "FAIL: self_test — $failures breakage(s) the gate did not catch."
  [ "$skips" -eq 0 ] || echo "note: $skips breakage(s) skipped (no toolchain) — reported above."
  exit 1
fi
if [ "$skips" -ne 0 ]; then
  echo "FAIL: self_test — $skips breakage(s) skipped for a missing toolchain. A skipped proof is not a proof."
  exit 1
fi
# The count is COUNTED, not written down. Every breakage above calls exactly one
# of the three red-expecting helpers, so this cannot drift from the recipes the
# way a hardcoded "all N breakages" does — and the header's list is checked
# against it by `tests/validate.sh`, so a breakage added without a header entry
# (or a header entry with no recipe) is a red gate rather than a doc that lies.
counted=$(grep -cE '^expect_red(_check|_lang|_script)? ' "$0" || true)
echo "PASS: self_test — all $counted breakages went red, and the unbroken tree is green."
