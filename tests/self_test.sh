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
# THE THIRTY-FOUR BREAKAGES   (master's twenty-three — labels 1-22 and 2b —
#                               plus the eleven secrets breakages at 24-34)
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
#   24-34. The secrets work. Eleven breakages, renumbered from kit-04's own
#         13-23 when it landed on a master that had already taken 13-23:
#
#     24-25. plant a detectable credential, in history and in the working tree ->
#            the secret scanner goes red
#     26-27. remove --redact, then narrow the scan to the last commit -> the
#            scanner's BEHAVIOUR check goes red. Not its source: a `grep -- --redact`
#            is satisfied by the comment above the flag that explains why the flag
#            is mandatory, and that breakage proved exactly that
#     28. add `pull_request_target` -> the dangerous-trigger check goes red
#     29. make the `secrets` job `continue-on-error` -> the not-advisory check goes
#            red. A secret scanner that only warns is a report
#     30-33. break the canary's reference type in the four ways that turn it into
#            the leaky one -> THAT VECTOR's suite goes red
#     34. baseline unpinned-uses in .github/zizmor.yml -> the never-baselined check
#            goes red
#
#   THE RENUMBERING, and it is the whole reason this union was not a textual one.
#   kit-04 numbered its eleven secrets breakages 13-23 and its six language
#   mutants 24-29. Master's 13-18 are those same six language mutants and its
#   19-22 are the fan-out work. So a textual union carries 34 recipes with FOUR
#   labels used twice — 19, 20, 21 and 22 — and `self_test_claims` compares the
#   documented set against the carried set AS SETS. The duplicates collapse
#   silently and the check reports an agreement that does not exist, which is the
#   precise failure this repository exists to prevent arriving through the merge.
#
#   So kit-04's language mutants are DROPPED, not renumbered: they are master's
#   13-18, byte for byte, and keeping a second copy would prove the same six
#   rules twice under two names. Its eleven unique breakages move to 24-34.
#   Master does not move at all.
#
#   THERE IS NO BREAKAGE 23, AND THAT IS THE SCHEME RATHER THAN A LOST RECIPE.
#   A gap in a numbering is the one thing every later renumber script reads as a
#   bug to fix, so it is recorded here instead of being left for the next person
#   to "correct" by shifting eleven recipes. The move is +11 across all eleven —
#   kit-04's 13 became 24, its 14 became 25, and so on to its 23, which became
#   34 — so the block walks off the top of master's range and starts again past
#   it. Master's own labels stop at 22; its twenty-third recipe is `2b`. So
#   24-34 is eleven labels wide and every recipe is present, which is what the
#   `grep -c` at the bottom of this file measures without being told the answer.
#
#   Nothing was overwritten and nothing was dropped. kit-04's breakage 23 — the
#   zizmor `unpinned-uses` baseline — is breakage 34 HERE, and it is the last
#   recipe in the file. Sliding the block down to close the hole would renumber
#   eleven recipes plus every prose reference to them, across three documents,
#   to remove a cosmetic gap; a numbering exists so a number can be cited in a
#   review, a bisect or an incident, and that is worth less than the eleven
#   stable references it would spend.
#
#   The header's own claim about counts was wrong three times before this, and
#   every time a check caught it rather than a reader: it said "seven" over a
#   four-wide range, it numbered a second entry 19 while the recipes numbered
#   it 20, and it attributed thirty-four breakages to "18 from the fan-out work,
#   17 from the tier work, 11 from the secrets work, 12 shared" — 58. A header
#   that drifts from the recipes is not documentation, it is a second, unchecked
#   copy of the truth — which is the entire thing validate.sh's header/recipe
#   check exists to prevent. Note what the check CAN catch: it compares the SET
#   of labels, so it is blind to a count written in prose, and blind to 23 being
#   absent from both sides. Those two are the reader's job, which is why they are
#   argued here rather than left to a rule.
#
#   Nineteen of them (7-10, 11, 12, 19, 20, 24-34) additionally assert WHICH
#         check went red. Every other breakage only proves the gate can fail;
#         those prove the check written for that defect is still load-bearing,
#         which is a different claim and the one that decays silently. 21 and 22
#         assert the same thing about the two scripts that are themselves proofs,
#         which makes twenty-one proofs that name the thing that must reject
#         them.
#
#   13-18 assert which LANGUAGE's suite, which is a third claim: a gate that goes
#         red for an unrelated reason is not a proof that the suite under test
#         asserts anything.
#
# WHAT IT IS NOT
#   This is not exhaustive mutation testing. Each implementation gets exactly one
#   mutant, chosen to be the bug a reviewer would not see: a dropped bit mask, an
#   alphabet that quietly grows a second case, a limit raised until it never
#   fires. One mutant per language proves the suite bites; it does not prove the
#   suite is complete, and nothing here should be read as claiming that is.
#
#   The same applies to breakages 24-34. They prove each check CAN fail; they do
#   not prove the check is complete. A check that fires on the defect it was
#   written for is the floor, and the floor is what a gate nobody runs has.
#
# WHY THE PLANTED PROBES ARE ASSEMBLED RATHER THAN WRITTEN OUT
#   Breakage 24 plants a credential, 25 plants the same one, and 33 plants a
#   canary literal. All three are assembled from parts in a throwaway copy, for
#   one reason: a probe written out is a probe committed, and the scanner and the
#   canary check would then both report THIS FILE — every breakage caught by the
#   wrong thing, and a gate that is red for a reason nobody introduced.
#
#   It happened, twice, while writing these. `tests/validate.sh` reported four
#   leaks in the file that was planting them, and the canary check reported the
#   breakage's own replacement string. Both are recorded in the breakages'
#   comments, because a proof that only ever worked the first time is a proof
#   somebody will trust.

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
  #
  # `.gitleaks.toml` is here for the same reason, and it is the one that is
  # invisible when it is missing: without it, every breakage in this file would
  # still go red — but for the wrong reason. The secret-scanner checks fail on
  # an absent config, so a copy without one cannot demonstrate that the scanner
  # detects a secret, only that the config is there. A red that means the wrong
  # thing is worse than no red, because it is counted.
  for entry in .github .gitleaks.toml AGENTS.md README.md CHANGELOG.md core docker lint templates tests; do
    [ -e "$ROOT/$entry" ] && cp -R "$ROOT/$entry" "$dst/"
  done
  # KIT_GITLEAKS, unlike the other two, must ALSO be resolved before the first
  # copy runs. It is a fetched binary rather than a python script, so the copy's
  # `$root/.venv` — which does not exist, because fresh_copy does not copy the
  # gitignored venv — is not where it would be found. Without this, every copy
  # re-downloads a 15MB archive, and the twenty-odd copies this script makes per
  # gate run turn a 90-second suite into a twenty-minute one.
  #
  # Precedence is deliberately: the developer's own gitleaks, then the one this
  # tree fetched, then PATH. A developer's install may be a different version
  # and that is their business, exactly as it is for hadolint.
  if [ -z "${KIT_GITLEAKS:-}" ] && [ -x "$ROOT/tests/.bin/gitleaks" ]; then
    KIT_GITLEAKS="$ROOT/tests/.bin/gitleaks"
  fi
  export KIT_GITLEAKS="${KIT_GITLEAKS:-}"
  # Every script in tests/, not just the two entry points. `cp -R` does NOT
  # preserve the executable bit on macOS, so a copy arrives with every tests/
  # script non-executable — and the gate has a check for exactly that (the two
  # gate scripts are run BY the reusable workflow, so they must be executable).
  # Without this, every one of the twenty-odd copies fails that check, and the
  # control run reports the tree red for a reason that has nothing to do with
  # any breakage under test.
  chmod +x "$dst"/tests/*.sh 2>/dev/null || true
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
#
# THE MATCH IS A SUBSTRING TEST ON THE VARIABLE, NOT `printf | grep -q`, and it
# has to be. `grep -q` exits at the FIRST match and closes the pipe, so the
# writer takes SIGPIPE and dies 141 — and this script runs under `set -o
# pipefail`, which promotes that 141 to the status of the whole pipeline. The
# `if` then reads a match as a NON-match.
#
# That is not theoretical here; it is what the first run of this merge
# produced. Breakage 11 (hadolint) and breakage 25 (the working-tree
# credential) both produce a gate run larger than the 64KB pipe buffer, and both
# were reported as "the gate went red, but NOT via `<the check that fired>`" —
# while printing that very check among the FAIL lines it had just proven was
# there. Underneath the threshold it matches; at or above it, the proof of the
# best-behaved check in the file failed for a reason that had nothing to do with
# the check. Same defect `tests/canary_test.sh` already records for
# `docker logs | grep -q`, and the same rule answers it here: the output is
# ALREADY captured in a variable, so there is no reason to introduce a pipe at
# all. Matching the variable is not merely safer than the pipe — it makes the
# assertion independent of how much the gate prints, which is a property the
# piped version did not have.
expect_red_check() {
  local label="$1" dir="$2" want="$3"
  shift 3
  local out ec=0
  out=$(cd "$dir" && KIT_PYTHON="$PY" bash tests/validate.sh "$@" 2>&1) || ec=$?
  if [[ $out == *"FAIL $want"* ]]; then
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
  local label="$1" dir="$2" script="$3"
  shift 3
  if (cd "$dir" && KIT_PYTHON="$PY" bash "$script" "$@" >/dev/null 2>&1); then
    printf 'FAIL self_test: %s — the proof stayed GREEN\n' "$label"
    failures=$((failures + 1))
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

  # No counter is incremented here. This function USED to carry its own
  # `breakages=$((breakages + 1))`, and the omission it was written to fix is
  # the reason this file counts by grepping itself at the end instead: a counter
  # incremented in three of four helpers had already under-reported once (the
  # summary said "all 23" while twenty-nine had run), and a count that
  # under-reports is worse than no count, because it reads as though proofs were
  # missing rather than as a bug in the counter.

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

# 24-34. The secret scanner, and the canary harness that answers the question
#         the scanner cannot.
#
#         A scanner that has never gone red is a report, and neither is a
#         detector that has never fired. Breakages 24-29 make the scanner catch
#         things; 30-33 make the canary's five vectors bite. They are in one
#         place because the two answer different questions about the same
#         subject, and a packet that added both is only honest if both are proven
#         able to fail.
SECRETS='gitleaks  (8.30.1, full history, --redact)'

# THE VARIABLES IN THIS BLOCK ARE NAMED FOR WHAT THEY BREAK, NOT FOR THEIR
# LABEL, and that is a merge repair rather than a style preference. The renumber
# that moved these eleven recipes from 13-23 to 24-34 rewrote the labels and left
# the variable names behind, so breakage 30 was still called `canary_unexported` and
# breakage 31 `canary_unredacted`. Master's own 19-22 arrived afterwards and bound those
# same four names to a second directory. It worked only because each is written
# and read before the next write — four pairs of names meaning two different
# things in one file, where a reordering, an inserted breakage or an early exit
# would have pointed a recipe at a copy somebody else had already mutated. The
# names below cannot collide with master's 1-22 because they do not encode a
# number at all, so the next renumber cannot reintroduce the fault by editing a
# label and missing a variable.

# 24-25. A detectable credential, in history and in the tree.
#
#     THE PROBE IS ASSEMBLED, NOT WRITTEN, and that is the whole difficulty of
#     this packet. The obvious thing — paste a sample PAT into this file — makes
#     `tests/self_test.sh` itself a gitleaks finding, so the real tree's own scan
#     goes red and every breakage here is caught by the wrong thing. It was: the
#     first version of these two breakages did exactly that, and the gate
#     reported four leaks in the file that was supposed to be planting them.
#
#     Assembling it from parts means no credential-shaped string is ever
#     committed — which is the same rule the canary harness asserts about itself,
#     applied to the scanner's own proof. The cost is that a reader cannot see
#     the value, so the comment above says what it is.
#
#     The value is GitLab's own published PAT FORMAT SAMPLE (glpat- followed by
#     the documented 31-character sample body), taken from gitleaks' test data.
#     It is a format sample, not a credential, and it has never been a live
#     token. Nothing in this repository is a live secret, and this packet's
#     entire subject is not printing one.
plant_probe() {
  local dir="$1"
  mkdir -p "$dir/.self-test-probe"
  {
    printf 'endpoint = "https://gitlab.example.invalid"\n'
    # Split across the two halves gitleaks matches on: the `glpat-` prefix and
    # the token body. Neither half is a credential on its own, and the
    # concatenation is what the rule fires on.
    printf 'private_token = "glpat-%s"\n' 'ABC123def456GHI789jkl012'
  } >"$dir/.self-test-probe/config.toml"
}

# 24. Committed and then REMOVED — the shape the full-history requirement exists
#     for. A HEAD-only scanner sees a clean tree here, and a diff scanner sees
#     nothing at all, because by the time the commit lands the file is gone.
probe_history="$(fresh_copy committed-secret)"
plant_probe "$probe_history"
expect_red_check 'breakage 24: a credential in history, since removed' \
  "$probe_history" "$SECRETS" --static-only

# 25. The same credential, still in the tree. A separate breakage from 24
#     because it is a different code path in the scanner and a different claim:
#     24 proves the scan reads history, 25 proves it reads uncommitted files. A
#     scanner that only read history would pass 24 and fail 25, and one that only
#     read the working tree would do the reverse — so neither alone establishes
#     that both are covered.
probe_tree="$(fresh_copy working-tree-secret)"
plant_probe "$probe_tree"
expect_red_check 'breakage 25: a credential in the working tree' \
  "$probe_tree" "$SECRETS" --static-only

# 26. --redact removed from the scan script. The build stays GREEN — nothing
#     about a secret being printed makes it non-zero — and the CI log now
#     contains the credential the scanner just found. This is the reason
#     redaction is asserted in the gate and not left to review: a change that
#     reads as a cleanup is a change that exfiltrates.
scan_unredacted="$(fresh_copy scan-without-redact)"
edit "$scan_unredacted/tests/gitleaks_gate.sh" \
  '  --redact \
  --no-banner \' \
  '  --no-banner \'
expect_red_check 'breakage 26: the scan stops redacting' \
  "$scan_unredacted" 'tests/gitleaks_gate.sh  (finds a real secret, never prints it, reads history)' \
  --static-only

# 27. The scan narrowed to the diff. A shallow or HEAD-only scan cannot see
#     breakage 24's shape at all, and the check that asserts full history is
#     what makes narrowing it a failure rather than a quiet reduction in
#     coverage.
scan_shallow="$(fresh_copy scan-head-only)"
edit "$scan_shallow/tests/gitleaks_gate.sh" \
  "  set -- \"\$@\" --log-opts '-p -U0 --full-history --all'" \
  "  set -- \"\$@\" --log-opts '-1'"
expect_red_check 'breakage 27: the scan narrows to the last commit' \
  "$scan_shallow" 'tests/gitleaks_gate.sh  (finds a real secret, never prints it, reads history)' \
  --static-only

# 28. `pull_request_target` added as a trigger. The workflow still parses, still
#     passes every other check, and every job in it now runs with the base
#     repository's secrets and a writable token on a fork's code. The secret
#     scanner is the job that most invites this edit, which is why the trigger
#     is checked on parsed keys rather than left to review.
dangerous_trigger="$(fresh_copy dangerous-trigger)"
edit "$dangerous_trigger/.github/workflows/ci.reusable.yml" \
  '  workflow_call:' \
  '  pull_request_target:
  workflow_call:'
expect_red_check 'breakage 28: a dangerous trigger appears in the workflow' \
  "$dangerous_trigger" '.github/workflows/*  (no dangerous trigger, on parsed keys)' --static-only

# 29. The `secrets` job made advisory. The single most common way a security job
#     is neutralised, and completely invisible in a green build: continue-on-error
#     means the job reports what it found and the badge stays green. A secret
#     scanner that only warns is a report.
CANARYJOB='.github/workflows/ci.reusable.yml  (secrets job: not advisory, full history, not opt-in)'
advisory_secrets_job="$(fresh_copy secrets-job-advisory)"
edit "$advisory_secrets_job/.github/workflows/ci.reusable.yml" \
  '  secrets:
    name: secrets
    runs-on: ubuntu-latest' \
  '  secrets:
    name: secrets
    continue-on-error: true
    runs-on: ubuntu-latest'
expect_red_check 'breakage 29: the secret scanner is made non-blocking' \
  "$advisory_secrets_job" "$CANARYJOB" --static-only

# 30-33. The canary harness. A detector that has never fired is a detector
#         asserting nothing, and these break the SAFE reference type in the four
#         ways that would turn it into the LEAKY one — each caught by a named
#         vector, so a vector that stops biting fails here rather than being
#         discovered when a token reaches a log aggregator.
CANARY='templates/secrets/go  (five vectors, each with a red proof)'

# 30. The exported pointer field becomes an unexported one. This is the shape
#     that LOOKS safest — unexported, so a reviewer reading the type sees nothing
#     worrying — and it leaks under every verb, because fmt prints unexported
#     fields through reflection. The measurement behind that is in
#     print_shape_test.go; this breakage is what proves the measurement is wired
#     into a vector rather than sitting in a comment.
canary_unexported="$(fresh_copy canary-unexported-token)"
edit "$canary_unexported/templates/secrets/go/internal/safe/creds.go" \
  '	Token *Token `json:"-"`' \
  '	token *Token'
expect_red_check 'breakage 30: the reference type hides its credential in an unexported field' \
  "$canary_unexported" "$CANARY" --language=go --no-self-test

# 31. The redacting String method is renamed, so the type stops being a
#     Stringer. Every dispatched verb then prints the value, which is the leak
#     the whole reference shape exists to prevent — and the `json:"-"` tag is
#     untouched, so nothing else in the tree notices.
canary_unredacted="$(fresh_copy canary-no-redaction)"
edit "$canary_unredacted/templates/secrets/go/internal/safe/creds.go" \
  'func (t *Token) String() string { return "Token(redacted)" }' \
  'func (t *Token) Redeemed() string { return "Token(redacted)" }'
expect_red_check 'breakage 31: the credential type stops redacting when printed' \
  "$canary_unredacted" "$CANARY" --language=go --no-self-test

# 32. The `json:"-"` is dropped. The credential reaches the wire under a `token`
#     key, which is vector 2's finding, and an always-present key is vector 4's.
#     Nothing else changes: the type still redacts, still has no String method,
#     and every static check in the gate is still green.
canary_marshals="$(fresh_copy canary-serialises-token)"
edit "$canary_marshals/templates/secrets/go/internal/safe/creds.go" \
  '	Token *Token `json:"-"`' \
  '	Token *Token'
expect_red_check 'breakage 32: the reference type marshals its credential' \
  "$canary_marshals" "$CANARY" --language=go --no-self-test

# 33. The canary committed as a literal instead of assembled. The one breakage
#     whose failure mode is invisible in a CI log: the suite keeps passing,
#     because the value is the SAME value. What changes is that the repository
#     now holds a credential-shaped string — a gitleaks finding, and an
#     allowlist entry somebody will eventually add. The check that catches it is
#     `the canary (never committed as a literal, anywhere)`.
# The DIRECTORY is `canary_as_literal`, not `canary_literal`, and that is not
# taste. `canary_literal` is the name kit-04 used for the assembled VALUE below,
# and the renumber that gave 24-34 descriptive directory names gave this one the
# value's name. The directory variable was then reassigned to the value a few
# lines later, so `edit` was handed
# `cafaye_canary_…/templates/secrets/go/canary.go` and died with a
# FileNotFoundError — which killed breakage 33 AND 34, and the run, before the
# summary printed. Two proofs dead, reported as a crash rather than as a missing
# check. A directory variable and a value variable must never share a name here;
# `validate.sh` now checks that, because a name collision is invisible to review
# and fatal only when the recipe runs.
canary_as_literal="$(fresh_copy canary-committed-as-literal)"
# The replacement is the EXACT value the check looks for: prefix plus 32 bytes,
# and it is ASSEMBLED here for the same reason `plant_probe` assembles its PAT.
#
# This one is the sharper version of that trap. A committed canary literal makes
# this very file a finding for the check it is proving, so the real tree's own
# `the canary (never committed as a literal, anywhere)` goes red — and every
# breakage in this script becomes caught by the wrong thing. The first version of
# this breakage did exactly that: it wrote the literal out, the check fired on
# tests/self_test.sh, and the breakage reported the right failure for entirely
# the wrong reason.
#
# So the value is built in the throwaway copy, at the moment the defect is
# introduced, and never exists in a committed file. The defect being introduced is
# "a contiguous credential-shaped string in a source file" — which is exactly what
# gets written, into a copy that is deleted when the test finishes.
canary_prefix='cafaye_canary_'
canary_body="$(printf 'notarealsecret%.0s' 1 2 3)"
canary_literal="$canary_prefix${canary_body:0:32}"
edit "$canary_as_literal/templates/secrets/go/canary.go" \
  'canary   = CanaryPrefix + strings.Repeat(canaryBody, 3)[:CanaryBytes]' \
  "canary   = \"$canary_literal\""
expect_red_check 'breakage 33: the canary is committed as a literal' \
  "$canary_as_literal" 'the canary  (never committed as a literal, anywhere)' --static-only

# 34. The zizmor config baselines unpinned-uses — the trade made invisibly, in a
#     file that looks like routine housekeeping. Every finding is still
#     accounted for and the build is still green, which is exactly what makes it
#     the failure mode worth a proof.
zizmor_baseline="$(fresh_copy zizmor-baselines-unpinned)"
edit "$zizmor_baseline/.github/zizmor.yml" \
  '  self-repository:' \
  '  unpinned-uses:
    ignore:
      - "**"
  self-repository:'
expect_red_check 'breakage 34: the zizmor config baselines unpinned-uses' \
  "$zizmor_baseline" '.github/zizmor.yml  (unpinned-uses recorded, never baselined)' --static-only

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
# of the four red-expecting helpers, so counting those calls IS the breakage
# count by construction — and it is the same count `tests/validate.sh` computes
# for its own label, so the summary here and the gate's label cannot disagree.
#
# This replaced a runtime `breakages=$((breakages + 1))` counter as well as the
# hardcoded `all 18 breakages` that preceded it. Two mechanisms were in this file
# at merge time, and that is the same defect one layer up: a second, unchecked
# copy of the truth. The counter also had a property the grep does not — it
# decremented itself on a skipped language, so a machine missing a toolchain
# printed a LOWER total than the file contains, which reads as though proofs had
# been dropped rather than as a missing prerequisite.
#
# The header's list is checked against this count by `tests/validate.sh`, so a
# breakage added without a header entry (or a header entry with no recipe) is a
# red gate rather than a doc that lies.
counted=$(grep -cE '^expect_red(_check|_lang|_script)? ' "$0" || true)
echo "PASS: self_test — all $counted breakages went red, and the unbroken tree is green."
