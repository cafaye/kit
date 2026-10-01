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
# THE THIRTY-SEVEN BREAKAGES, and one GREEN control   (20 from the tier work,
#                               21 from the fan-out work, 24-26 from the fleet
#                               gate, 27-32c from the lint work; 18 shared
#                               before the lint packet)
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
#   23. delete the interpreter floor from validate.sh -> with a stub ruby older
#         than KitOtel::RUBY_FLOOR on PATH, the ruby suite goes red under its
#         own label. This is the red that three landed-or-landing packets were
#         blocked by, reproduced on purpose.
#  23b. the floor INTACT, same old stub -> the gate stays GREEN and names the
#         skip. The one breakage here that asserts a check while the gate is
#         green: a floor that turns a red into a silent pass is worse than no
#         floor, and only this direction can tell the two apart.
#  24-26. the shapes a workaround for a FIXED core defect takes -> the fleet
#         check goes red. Two are D12 (core 63fd319: `RUN_KEY` could not see a
#         one-line `run:`) and one is D13 (core c63af27: a proof matched against
#         bytes still carrying ANSI colour). Both defects are fixed, so a
#         workaround for either is a second, unversioned copy of a decision that
#         now lives in core, and 26's escape runs make the declaration WEAKER
#         than the same declaration written without them.

# 27-30. the four ways the "lint runs from kit" mechanism stops being a GATE
#         while everything else stays green, all caught by `lint_wiring_check`
#         and all NAMING it, because a check that has quietly stopped being
#         load-bearing should fail here rather than being found months later by
#         the policy it stopped policing:
#           27. a language job's `lint` step DELETED -> the job no longer lints
#           28. that step made ADVISORY — `continue-on-error: true`, the
#                breakage that matters most, because the step still runs, still
#                prints every finding, and the job is green. A linter that only
#                warns is a report, and this is how a report is born without
#                anybody deciding to write one.
#           28b. the same defect written the other way it can be written,
#                `|| true` at the end of the run body. Continue-on-error in
#                shell, and it reads to nobody as anything but a deliberate
#                choice.
#           29. the kit CHECKOUT deleted, so `--config` names a file that is not
#                there and each linter quietly falls back to its own defaults —
#                five linters for golangci-lint, MethodLength 10 for rubocop,
#                no rules at all for eslint. All green, all much weaker, and
#                invisible in the YAML, because the step still says `--config`.
#           30. the config WEAKENED in place. The sharpest of the four, because
#                every other check can be green while it happens: the file still
#                parses, the workflow still points at it, and the policy is now
#                whatever was left. So the linter list is asserted BY VALUE.
#  31. a SERVICE carries a lint config INCONSISTENT with kit's -> the drift
#        check goes red. The failure this whole packet exists to end, at the
#        layer where it lands: a service's own lint config, disagreeing with
#        kit's, in a repository that calls kit.
#
#        The MECHANISM was measured before it was written down, and the first
#        version of this comment was wrong. `--config` WINS: `golangci-lint run
#        -v` prints exactly one `[config_reader] Used config file`, and with the
#        flag it names kit's — a repo-root `.golangci.yml` that disables
#        `misspell` does not survive it, and RuboCop behaves the same way. So a
#        stale copy does NOT hijack kit's CI, and this breakage is not about
#        that. What a copy does is SPLIT the policy: every other invocation in
#        that repository reads it while CI reads kit's, and it becomes live
#        again the instant the flag is lost — silently, because a copy is always
#        weaker than the thing it was copied from. That is the finding, and it is
#        why the check reports the DIFFERENCE rather than banning the file.
# 32-32c. the SEAM, in the three ways `lint_args_seam_check` can stop being a
#         control. The seam is `lint-args`, the one input a service uses to ask
#         for a stricter linter, and its narrowness is a list of refused flags
#         held in a `lint-args guard` step in each lint job:
#           32. the guard DELETED from one job. The other two keep working, so
#                this is the shape of an accident — one merge, one job, no other
#                signal anywhere.
#           32b. the guard KEPT and its list SHORTENED by one token. The edit a
#                well-meaning commit makes when somebody wants `--no-config`:
#                rather than argue about the seam, the token comes out. The
#                build stays green for every service that sets it and the
#                workflow still contains a step called `lint-args guard`. This
#                is the sharpest of the three, and it is only caught because the
#                token list is asserted against a copy held in validate.sh.
#           32c. the guard MOVED after the linter. It still runs, still reads the
#                variable, and still refuses everything it refused — after the
#                linter has been handed `--no-config` and already exited 0. A
#                control that runs after the thing it controls is the most
#                comfortable kind of dead code, because read top to bottom it
#                looks exactly like a live one.
#   ...and one GREEN control, which is the other half of 31's claim: a service
#        config that AGREES with kit's must PASS, because a check that failed on
#        the mere presence of the file would train every service to delete a file
#        it is allowed to keep. It is written here as prose rather than as a
#        numbered entry because it is a control and not a breakage — and because
#        `self_test_claims` counts only the red-expecting helpers, so a numbered
#        entry here would be reported as a header claim with no recipe.
#
#   These are numbered 20-22 rather than 19-21 because 19 is the allowlist
#   breakage above, from the tier work. Both packets numbered their first entry
#   independently and the collision is only visible in the union — which is what
#   the header/recipe check in validate.sh is for.
#
#   Seventeen of them (7-10, 11, 12, 19, 20, 27, 28, 28b, 29, 30, 31, 32, 32b,
#                     32c) additionally
#         assert WHICH check went red. Every other breakage only proves the gate
#         can fail; those prove the check written for that defect is still
#         load-bearing, which is a different claim and the one that decays
#         silently. 21 and 22 assert the same thing about the two scripts that
#         are themselves proofs. The six lint-packet entries all NAME the check
#         they must be caught by, and that is the point of naming it: a deleted
#         checkout and a `continue-on-error` are defects a dozen other checks
#         would also catch, and a proof that cannot tell which one fired is a
#         proof that stops being evidence the moment one of the others moves.
#
#   And one GREEN control, which is a claim the numbered breakages cannot make.
#         31b asserts the gate is green on a copy whose service config MATCHES
#         kit's. A check that failed on the mere presence of a `.golangci.yml`
#         would be satisfied by this packet and would teach every service to
#         delete a file it is allowed to keep — a silent outcome, and a worse one
#         than the drift it was written to catch.
#
#   The counts here were wrong three times and every time a check caught it
#         rather than a reader: the header said "seven" over a four-wide range,
#         it numbered a second entry 19 while the recipes numbered it 20, and it
#         kept saying "twenty-three" after the lint packet added six more. A
#         header that drifts from the recipes is not documentation, it is a
#         second, unchecked copy of the truth — which is the entire thing
#         validate.sh's header/recipe check exists to prevent. That check COUNTS
#         the recipes and diffs them against this header, so the third error was
#         caught the same way as the first two: mechanically, not by reading.
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
#
# EACH COPY GETS ITS OWN PARENT DIRECTORY, and that is load-bearing rather than
# tidiness. `fleet_repos` in tests/validate.sh finds a service fleet by globbing
# `$ROOT/..`, so a copy that sat directly in the shared `$WORK` would see all
# THIRTY of its siblings as the fleet. That is not a tidiness problem, it is a
# correctness one in both directions:
#
#   - every breakage's gate run would be red because a LATER breakage's copy
#     carries a `.golangci.yml`, so a breakage could be "caught" by a defect it
#     did not introduce; and
#   - breakage 31b, which asserts the gate is GREEN on a copy whose config
#     MATCHES kit's, would be red because breakage 31's copy — a sibling, in the
#     same directory — has one that does not.
#
# A control that goes red for a reason another test created is worse than no
# control, because it reads as evidence. One directory per copy makes each
# breakage's fleet exactly itself: deterministic, and each result attributable
# to the breakage under test and nothing else.
fresh_copy() {
  copy_name="$1"
  local dst="$WORK/$copy_name/kit"
  mkdir -p "$dst"
  # `.github` is in this list and not an afterthought: the reusable workflow it
  # holds is the artifact every check that reads the workflow's inputs reads by
  # path, so a copy without it cannot fail the same way the real tree does.
  # `core` is here for the same reason `.github` is: the breakages below mutate
  # files in it, and a copy without it would fail on a missing path rather than
  # on the defect under test — which is a self_test that proves nothing.
  # `lint` is here for the same reason `.github` is: the breakages below mutate
  # files in it and read files in it, and a copy without it would fail on a
  # missing path rather than on the defect under test — which is a self_test
  # that proves nothing.
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
  # A shell pattern, not `printf … | grep -qF`.
  #
  # `grep -q` exits the instant it matches, so a large `$out` gives `printf`
  # SIGPIPE while it is still writing. `set -o pipefail` — which this file sets
  # — then reports 141 for a pipeline that SUCCEEDED, and a passing breakage
  # reads as "the gate went red, but NOT via <the named check>".
  #
  # It hit breakage 29, whose check emits several hundred lines of report and
  # therefore the first output in this file big enough to overflow the 64K pipe
  # buffer. Breakages 7-24 all pass on a small enough output, which is the worst
  # shape a latent defect has: it looks like a failure of the thing under test
  # and is actually a failure of the harness reading it.
  #
  # Measured, not reasoned about: 2000 lines of output still returns 0 and 5000
  # returns 141, on the same match and the same grep. The threshold is a property
  # of the pipe buffer, so it would move with the machine — which is why the fix
  # is to stop piping rather than to bound the output.
  case "$out" in
    *"FAIL $want"*)
      printf 'PASS self_test: %s — caught by `%s`\n' "$label" "$want"
      ;;
    *)
      if [ "$ec" -eq 0 ]; then
        printf 'FAIL self_test: %s — the gate stayed GREEN\n' "$label"
      else
        printf 'FAIL self_test: %s — the gate went red, but NOT via `%s`\n' "$label" "$want"
        printf '%s\n' "$out" | grep '^FAIL' | sed 's/^/       /'
      fi
      failures=$((failures + 1))
      ;;
  esac
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

# expect_skip_check <label> <dir> <check-label> <validate.sh args...>
#
# The other direction, and it exists because 23b asserts something no other
# helper can. `expect_red*` proves a check CATCHES a defect; this proves a check
# can be load-bearing while the gate stays green — which is the interpreter
# floor's whole job. The floor turns a red gate into a skip; "the gate went
# red" says nothing about whether it did, and "the gate went green" is
# satisfied just as well by a check that was deleted entirely.
#
# So this asserts BOTH halves of the honest-reporting claim: the gate exited 0,
# and the named check is what said so. A gate that passed by running nothing and
# mentioning nothing fails here; a gate that failed fails here too.
expect_skip_check() {
  local label="$1" dir="$2" want="$3"
  shift 3
  local out ec=0
  out=$(cd "$dir" && KIT_PYTHON="$PY" bash tests/validate.sh "$@" 2>&1) || ec=$?
  if [ "$ec" -ne 0 ]; then
    printf 'FAIL self_test: %s — the gate exited %s, so the skip was not clean\n' "$label" "$ec"
    printf '%s\n' "$out" | grep '^FAIL' | sed 's/^/       /'
    failures=$((failures + 1))
  elif printf '%s\n' "$out" | grep -qF "SKIP $want"; then
    printf 'PASS self_test: %s — reported as `%s`\n' "$label" "$want"
  else
    printf 'FAIL self_test: %s — the gate stayed green but never said `%s`\n' "$label" "$want"
    printf '%s\n' "$out" | grep '^SKIP' | sed 's/^/       /'
    failures=$((failures + 1))
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

# --------------------------------------------------------------------------
# THE SYNTHETIC FLEET
# --------------------------------------------------------------------------
#
# `tests/gate_declaration_check.py` sweeps a directory of adopting
# repositories — `gate.yml` plus the workflow it names. There is no such
# directory inside kit, for the same reason `tests/staleness_test.sh` builds its
# own: kit is one repository and the fleet is fifteen, and a check that read the
# real working directory would be green on Tuesday and red on Wednesday for a
# reason that has nothing to do with what it checks.
#
# So a clean one is built here, once, and `KIT_FLEET` points every run of
# `validate.sh` in this script at it. Two consequences, both wanted:
#
#   * the control below becomes the fleet check's POSITIVE case. A sweep that
#     only ever runs on a red fleet has proved it can fail and nothing about
#     whether it is right;
#   * a breakage mutates its OWN copy of the fleet and nothing else, so
#     breakages cannot mask each other, exactly as `fresh_copy` guarantees for
#     the rest of this file.
#
# It is a two-file repository on purpose. Both are the real spellings: a
# one-line `run:` in the workflow, and a proof pattern with no escape token —
# which is the state every repository in this fleet is supposed to be in.
FLEET="$WORK/fleet"

synthetic_repo() {
  local root="$FLEET/$1"
  mkdir -p "$root/.github/workflows"
  cat > "$root/gate.yml" <<'YAML'
# gate.yml — the clean shape. One line per proof, no escape tolerance, and a
# `ci` block naming the workflow below.
version: 1
name: synthetic

gate:
  command: [bin/prime]
  entrypoint: bin/prime
  proof:
    - id: suite
      match: '^([0-9]+)/[0-9]+ passed$'
      minimum: 12

external:
  selfContained: true
  requirements: []

ci:
  workflow: .github/workflows/ci.yml
  invokes: [bin/prime]
YAML
  cat > "$root/.github/workflows/ci.yml" <<'YAML'
name: ci
on: [push]
jobs:
  gate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: bin/prime
        run: ./bin/prime
YAML
}

# A second, differently-named repository, so the sweep has to enumerate rather
# than read one hardcoded path — and so a check that only ever saw one name
# could not pass.
synthetic_repo clean
synthetic_repo second-clean

# Exported once, so every `validate.sh` invocation below sweeps THIS fleet
# rather than whatever happens to sit beside the throwaway copy. A prefix
# assignment on a function call would not do: in bash an assignment preceding a
# FUNCTION call persists after it returns, so breakage 24 would silently
# redirect breakage 25's sweep.
#
# THE FLEET IS REBUILT BY `fresh_fleet` FOR EVERY RECIPE, AND RESTORED AFTER
# THE LAST ONE. Both halves are load-bearing, and the second half was a real
# cross-packet failure rather than a hypothetical:
#
#   * `fresh_fleet` is called again after this point, so the *clean* pair below
#     is only the starting state, not the state every later recipe sees.
#   * the last fleet recipe leaves a DELIBERATELY BROKEN repository in `$FLEET`
#     — that is the whole mechanism, a sweep that cannot go red proves nothing.
#     With `KIT_FLEET` still exported, every gate run after it inherits that
#     broken repository. The integration branch hit this exactly: breakage 31b,
#     which asserts the gate is GREEN on a copy whose config matches kit's,
#     failed with `FAIL adopting repositories (no workaround for a fixed core
#     defect)` — a red created by another test, which is the exact failure mode
#     this harness exists to prevent.
#
# So the fleet is put back the way it was found before the file does anything
# else. `unset` rather than a reset value, because the honest state of the
# environment on entry is "unset" — and a recipe that must not see a fleet then
# gets the same behaviour it would get outside this file.
unset KIT_FLEET

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

# 23 and 23b. The interpreter floor, in both directions, and they share one
# fixture: a stub `ruby` that lies about its version.
#
# The stub is the smallest thing that reproduces the real failure. On macOS the
# gate's `ruby` can resolve to /usr/bin/ruby 2.6, which loads
# templates/otel/ruby/traceparent.rb without complaint — every constant and
# method definition parses fine — and then raises NoMethodError on
# `filter_map` at the first tracestate entry. So the *only* honest way to
# reproduce it is a stub that reports 2.6 and refuses the suite. It delegates
# everything else to the real interpreter, because the version probe has to keep
# working: a stub that could not be asked its version would fail the gate in
# the wrong place, and a self_test whose recipe fails for the wrong reason is a
# recipe that stopped testing what it names.
if command -v ruby >/dev/null 2>&1; then
  twentythree="$WORK/old-ruby"
  mkdir -p "$twentythree/stub"
  real_ruby="$(command -v ruby)"
  cat >"$twentythree/stub/ruby" <<STUB
#!/bin/sh
# Reports a ruby older than any cafaye service pins, then refuses to run
# anything. Everything else — `ruby -c`, the RUBY_VERSION probe — is delegated,
# so the only behaviour this fixture changes is "can the suite run here".
case "\$*" in
  *RUBY_VERSION*) printf '2.6.10'; exit 0 ;;
esac
case "\$*" in
  *test_traceparent.rb*) echo 'undefined method \`filter_map' >&2; exit 1 ;;
esac
exec "$real_ruby" "\$@"
STUB
  chmod +x "$twentythree/stub/ruby"

  # PATH is exported rather than prefixed onto the call: `PATH=… expect_red_check`
  # puts something other than `expect_red_check` first, so the count in
  # tests/validate.sh — anchored on `expect_` at the start of a line — would
  # miss this recipe and the summary would report fewer breakages than the file
  # carries. The same reasoning is why both counts allow indentation: the recipe
  # sits inside the `command -v ruby` guard.
  twentythree_old_path="$PATH"
  PATH="$twentythree/stub:$PATH"
  export PATH

  # 23. The floor is defined and never consulted. Removing the guard is the
  #     whole breakage: with the stub on PATH the suite goes red, and it goes
  #     red under the SAME label a genuine template defect uses — which is
  #     precisely why the guard had to exist. Asserted by name, because "the
  #     gate went red" would be satisfied by the unrelated checks in the same
  #     run and would prove nothing about this one.
  twentythree_a="$(fresh_copy old-ruby-no-floor)"
  edit "$twentythree_a/tests/validate.sh" \
    'if [ "$lang" = ruby ]; then' \
    'if false; then'
  expect_red_check 'breakage 23: the interpreter floor is defined but never consulted' \
    "$twentythree_a" 'templates/otel/ruby  (ruby test suite)' --language=ruby --no-self-test

  # 23b. The floor consulted and reported as a skip. Same fixture, guard intact.
  #      This is the assertion that a green gate can still be an honest one: the
  #      suite is NOT run, and the gate says so by name rather than passing on
  #      the strength of thirteen tests it never executed.
  twentythree_b="$(fresh_copy old-ruby-floor-honest)"
  expect_skip_check 'breakage 23b: an interpreter below the floor is a named skip, not a silent pass' \
    "$twentythree_b" "templates/otel/ruby  (ruby 2.6.10 is below the template's 2.7 floor)" \
    --language=ruby --no-self-test

  PATH="$twentythree_old_path"
  export PATH
else
  printf 'SKIP self_test: breakage 23: the interpreter floor is defined but never consulted — ruby not installed\n'
  printf 'SKIP self_test: breakage 23b: an interpreter below the floor is a named skip, not a silent pass — ruby not installed\n'
  skips=$((skips + 2))
fi

# 24-26. THE D12/D13 WORKAROUNDS, in the three shapes they actually took.
#
# `core` shipped two checker defects that forced adopters into local
# workarounds, and both are now fixed: D12 (`RUN_KEY` could not see a one-line
# `run:`) in 63fd319, and D13 (proofs matched against bytes carrying ANSI
# colour) in c63af27. A rule about those lives in `tests/validate.sh` now rather
# than in a report, and these three are that rule's proof.
#
# All three mutate the SYNTHETIC FLEET, not a throwaway copy of the tree: the
# check reads a directory of adopting repositories and kit is not one. Each
# takes its own `fresh_fleet` so one cannot mask the next, which is the same
# discipline `fresh_copy` provides for everything else here.
#
# 24 is the shape `cafaye-rb` shipped for six weeks — a step written `run: |`
# whose entire body is the gate command, plus a comment above it saying the
# one-liner would be invisible. It is the most important of the three because it
# is the only one that is BOTH detectable structurally and invisible in
# behaviour: core reads the step either way, so nothing else in the fleet
# notices.
FLEETWORKAROUND='adopting repositories  (no workaround for a fixed core defect)'

# fresh_fleet <name> — the synthetic fleet, rebuilt clean, with one repository
# added. Not `fresh_copy`, because the unit here is a two-file REPOSITORY inside
# a directory rather than a copy of this tree. A stale repository would make a
# later breakage pass for the wrong reason, so each one starts from clean.
#
# The `export` lives HERE rather than at the top of the file, and that is the
# other half of the fix described at the `unset` above. Exported once at the top
# it would be in force for every gate run in the file, including runs that
# happen after the last fleet recipe has left a broken repository behind; the
# scope this function creates is exactly the one recipe that needs it. A prefix
# assignment would not do — in bash an assignment preceding a FUNCTION call
# persists after it returns, which is the same trap one line up.
fresh_fleet() {
  rm -rf "$FLEET"
  synthetic_repo clean
  synthetic_repo second-clean
  synthetic_repo "$1"
  export KIT_FLEET="$FLEET"
}

# 24. D12, the block-scalar spelling plus its justification.
fresh_fleet d12-block-scalar
edit "$FLEET/d12-block-scalar/.github/workflows/ci.yml" \
  '        run: ./bin/prime
' \
  '        run: |
          ./bin/prime
'
edit "$FLEET/d12-block-scalar/.github/workflows/ci.yml" \
  '      - name: bin/prime
' \
  '      # A block scalar rather than `run: ./bin/prime` on one line. The `run:`
      # key above is invisible to `gate.ci-disagrees` without it.
      - name: bin/prime
'
expect_red_check 'breakage 24: D12 — the gate step is a block scalar, justified' \
  "$base" "$FLEETWORKAROUND" --static-only

# 25. D12 again, and the half that is a false SENTENCE rather than a shape. The
#     step is already correct here; only the comment is wrong. A check that
#     looked for the shape would pass this, and the comment would survive — which
#     is the part that rots, because the next reader cannot tell it is obsolete.
fresh_fleet d12-stale-comment
edit "$FLEET/d12-stale-comment/.github/workflows/ci.yml" \
  '      - name: bin/prime
' \
  '      # `run: ./bin/prime` is invisible to `gate.ci-disagrees`, so this step
      # must be a block scalar. See REPORT-core-10.md.
      - name: bin/prime
'
expect_red_check 'breakage 25: D12 — a correct step with a justification for a fixed defect' \
  "$base" "$FLEETWORKAROUND" --static-only

# 26. D13, and the one that makes a declaration WEAKER rather than merely
#     redundant. The escape runs absorb characters a stricter pattern would
#     reject, so this is not a harmless local convenience: it is a proof that
#     matches lines the author's own gate did not intend to accept. Core strips
#     the escapes in exactly one place (c63af27), so nothing else in the fleet
#     would ever see it.
fresh_fleet d13-escape-tolerant
edit "$FLEET/d13-escape-tolerant/gate.yml" \
  "      match: '^([0-9]+)/[0-9]+ passed$'" \
  "      match: '^(?:[ ]|\\x1b\\[[0-9;]*m)*([0-9]+)/[0-9]+ passed$'"
expect_red_check 'breakage 26: D13 — a proof pattern carries escape tolerance' \
  "$base" "$FLEETWORKAROUND" --static-only

# The fleet goes back to being the environment's business. `$FLEET` still holds
# `d13-escape-tolerant` — deliberately broken, and the whole reason breakage 26
# went red — so leaving `KIT_FLEET` pointed at it would make every gate run from
# here to the end of the file red on a defect this file introduced. See the
# `unset` where the export used to be for what this cost in the integration.
unset KIT_FLEET

# 27-32c. THE LINT GATE. Five ways the "lint runs from kit" mechanism can stop
#       being a gate while every other check in this repository stays green,
#       and the advisory one is the most likely of the five by a wide margin.
#
#       All five name the check that must catch them, because "the gate went red"
#       is a weak claim when a dozen checks could have gone red: a lint step
#       that lost its `--config` would also be caught by, at most, one other
#       thing, and a check that has stopped being load-bearing should fail HERE
#       rather than being discovered months later by the policy it stopped
#       policing.
LINTWIRE='lint/ + the workflow  (every lint step is a gate on kit config)'

# 27. THE LINT STEP DELETED. The crudest form: `ci.reusable.yml` still declares
#     a language, still has a job for it, still runs a build and a test — and
#     nothing in it lints. Everything else about the job is untouched, so this is
#     what "someone removed a step in a hurry" looks like.
#
#     The deletion is done with a parser rather than a text edit, for the same
#     reason breakage 9 was: an `edit` recipe whose anchor no longer matches
#     must FAIL LOUDLY, and one that silently matches the wrong occurrence is
#     worse than no recipe at all. Here the whole step is removed by identity.
twentyseven="$(fresh_copy lint-step-deleted)"
"$PY" - "$twentyseven/.github/workflows/ci.reusable.yml" <<'PY'
import sys

import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
# The go job's lint step, by name. Exactly one must go, or the recipe is stale.
hits = 0
for job in (doc.get("jobs") or {}).values():
    steps = (job or {}).get("steps") or []
    kept = [s for s in steps if not (isinstance(s, dict) and s.get("name") == "lint")]
    hits += len(steps) - len(kept)
    if isinstance(job, dict):
        job["steps"] = kept
if hits < 1:
    sys.exit("self_test: no `lint` step existed to delete — the recipe is stale")
with open(path, "w", encoding="utf-8") as fh:
    yaml.safe_dump(doc, fh, sort_keys=False, default_flow_style=False)
PY
expect_red_check 'breakage 27: a language job no longer lints at all' \
  "$twentyseven" "$LINTWIRE" --static-only

# 28. THE ADVISORY ONE, and the breakage that matters most. `continue-on-error:
#     true` leaves the step running, leaves it printing every finding it found,
#     and turns the job green. Nothing in the YAML is malformed; the build
#     passes; the lint results are on the page where nobody reads them. A linter
#     that only warns is a report, and this is how a report is born without
#     anybody deciding to write one.
#
#     It is asserted on the PARSED step, so it also catches the same defect
#     written the other two ways it can be written: `|| true` at the end of the
#     run body, which is continue-on-error in shell and reads to nobody as
#     anything but a deliberate choice. That one is exercised here too, because
#     the check claims to catch it and a claim nobody has tried to break is a
#     claim nobody has tested.
twentyeight="$(fresh_copy lint-made-advisory)"
edit "$twentyeight/.github/workflows/ci.reusable.yml" \
  '        uses: golangci/golangci-lint-action@v9
        with:' \
  '        uses: golangci/golangci-lint-action@v9
        continue-on-error: true
        with:'
expect_red_check 'breakage 28: the lint step is advisory (continue-on-error) — a report, not a gate' \
  "$twentyeight" "$LINTWIRE" --static-only

twentyeight_b="$(fresh_copy lint-advisory-in-shell)"
edit "$twentyeight_b/.github/workflows/ci.reusable.yml" \
  'run: bundle exec rubocop --parallel --config "$KIT_LINT_DIR/lint/rubocop.yml" ${{ env.KIT_LINT_ARGS }}' \
  'run: bundle exec rubocop --parallel --config "$KIT_LINT_DIR/lint/rubocop.yml" ${{ env.KIT_LINT_ARGS }} || true'
expect_red_check 'breakage 28b: the lint step swallows its exit status with `|| true`' \
  "$twentyeight_b" "$LINTWIRE" --static-only

# 29. THE CONFIG NO LONGER FOUND. The checkout deleted, or the path changed. The
#     step is untouched, it still says `--config`, it still names a file — and
#     the file is not there, so the linter falls back to its defaults: five
#     linters for golangci-lint, MethodLength 10 for rubocop, no rules for
#     eslint. All green, all much weaker. This is the breakage that the
#     `--config` flag's existence is defending against and it is invisible from
#     the YAML alone.
twentynine="$(fresh_copy kit-not-checked-out)"
"$PY" - "$twentynine/.github/workflows/ci.reusable.yml" <<'PY'
import sys

import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
removed = 0
for job in (doc.get("jobs") or {}).values():
    if not isinstance(job, dict):
        continue
    steps = job.get("steps") or []
    kept = [
        s
        for s in steps
        if not (
            isinstance(s, dict)
            and str(s.get("uses", "")).startswith("actions/checkout")
            and (s.get("with") or {}).get("repository") == "cafaye/kit"
        )
    ]
    removed += len(steps) - len(kept)
    job["steps"] = kept
if removed < 1:
    sys.exit("self_test: no kit checkout existed to delete — the recipe is stale")
with open(path, "w", encoding="utf-8") as fh:
    yaml.safe_dump(doc, fh, sort_keys=False, default_flow_style=False)
PY
expect_red_check 'breakage 29: the kit checkout is gone, so `--config` names nothing' \
  "$twentynine" "$LINTWIRE" --static-only

# 30. THE CONFIG WEAKENED. The sharpest of the five, because every check above
#     can be green while it happens. The workflow still points `--config` at
#     `.kit/lint/golangci.yml` on every run, the file still parses, the lint
#     step still exits nonzero on an error — and the policy is now golangci-
#     lint's five defaults, which nobody in the fleet chose.
#
#     A step that lost its flag is a defect a reader can see in a diff. A config
#     that lost three linters is a two-line deletion that looks like tidying,
#     and the build stays green throughout. So the linter list is asserted BY
#     VALUE, parsed as YAML, which also means the three names cannot be
#     satisfied by the comment block that explains why they are enabled.
thirty="$(fresh_copy config-weakened)"
"$PY" - "$thirty/lint/golangci.yml" <<'PY'
import sys

import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
enable = ((doc.get("linters") or {}).get("enable")) or []
before = len(enable)
# Drop the correctness linters one at a time. Each removal is a plausible
# "this is noisy" edit, which is exactly why none of them can be left to review.
doc["linters"]["enable"] = [x for x in enable if x not in ("bodyclose", "noctx", "errorlint")]
if len(doc["linters"]["enable"]) == before:
    sys.exit("self_test: none of the weakened linters was present — the recipe is stale")
with open(path, "w", encoding="utf-8") as fh:
    yaml.safe_dump(doc, fh, sort_keys=False, default_flow_style=False)
PY
expect_red_check 'breakage 30: kit config silently drops correctness linters the policy names' \
  "$thirty" "$LINTWIRE" --static-only

# 31. A SERVICE DRIFTS BACK TO A COPY. The failure this whole packet exists to
#     end, at the layer where it actually lands: a repo that used to lint with
#     kit's config goes back to running its own, and kit has no way to see it
#     from inside its own repository.
#
#     The shape checked here is the one kit CAN see without reading the fleet:
#     a service's own lint config, sitting in a place the reusable workflow's
#     steps never read. A file that nothing points at is not a deviation, it is
#     a copy that has stopped being one — and golangci-lint will still
#     DISCOVER it, because `.golangci.yml` in the repository root beats
#     everything. So a service carrying one is being linted by a policy that
#     kit's CI does not run, and the mismatch is invisible from both sides.
#
#     This is the check the brief asked for in the form it asked for: it reads
#     BOTH files and reports the DIFFERENCE, rather than demanding the file be
#     absent. A repo with no `.golangci.yml` passes; a repo whose file agrees
#     with kit's passes; a repo whose file disagrees is told exactly which
#     linters differ.
LINTDRIFT='lint drift  (a service config is compared to kit, not merely forbidden)'

thirtyone="$(fresh_copy service-drifted-back-to-a-copy)"
# A realistic drift: the service keeps kit's linters but drops the linter that
# was complaining about its generated client, and disables errcheck outright
# rather than excluding one path. Both are real, both are what a team does under
# pressure, and neither is visible in kit's own tree.
cat >"$thirtyone/.golangci.yml" <<'EOF'
---
# A service that went back to owning its lint config.
version: '2'
linters:
  enable:
    - bodyclose
    - copyloopvar
    - errorlint
    - exhaustive
    - misspell
    - noctx
    - revive
    - unconvert
    - wastedassign
  disable:
    - errcheck
EOF
expect_red_check 'breakage 31: a service carries a lint config INCONSISTENT with kit, not merely present' \
  "$thirtyone" "$LINTDRIFT" --static-only

# 31b. The other half of the same claim, and the reason the check reads both
#      files: a config that AGREES with kit's must PASS. A check that fails on
#      the mere presence of a `.golangci.yml` would be satisfied by this packet
#      and would train every service to delete a file it is allowed to keep —
#      which is a worse outcome than the drift, because it is a silent one.
thirtyone_b="$(fresh_copy service-config-agrees-with-kit)"
cp "$thirtyone_b/lint/golangci.yml" "$thirtyone_b/.golangci.yml"
expect_green 'breakage 31b: a service config that MATCHES kit is not a failure' \
  "$thirtyone_b" --static-only

# 32-32c. THE SEAM. Three claims, and each decays on its own: the guard can be
#       deleted, moved, or kept but emptied. The third matters most, because it
#       is the shortest edit in the file and it widens the deviation seam for
#       every service in the fleet while the workflow still reads as it did.
#
#       All three name `lint_args_seam_check`, for the reason 31-31 do: a deleted
#       guard also leaves the YAML valid, the lint step untouched and the build
#       green, and nothing else in this repository has an opinion about it.
SEAM='the seam  (narrow, guarded before the linter, and wired to it)'

# 32. The guard deleted from ONE job. The seam keeps working in the other two,
#     so this is the shape of an accident: one merge, one job, no other signal.
thirtytwo="$(fresh_copy seam-guard-deleted)"
"$PY" - "$thirtytwo/.github/workflows/ci.reusable.yml" <<'PYDEL28'
import sys

import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
job = (doc.get("jobs") or {}).get("ruby") or {}
steps = job.get("steps") or []
kept = [s for s in steps if s.get("name") != "lint-args guard"]
if len(steps) == len(kept):
    sys.exit("self_test: the ruby job had no `lint-args guard` to delete")
job["steps"] = kept
with open(path, "w", encoding="utf-8") as fh:
    yaml.safe_dump(doc, fh, sort_keys=False, default_flow_style=False)
PYDEL28
expect_red_check 'breakage 32: one lint job no longer guards the seam' \
  "$thirtytwo" "$SEAM" --static-only

# 32b. The guard KEPT, and its list shortened by one token. This is the edit a
#      well-meaning commit makes: `--no-config` is a flag somebody wants, and
#      rather than argue about the seam the token comes out. The build stays
#      green for every service that sets it, and the workflow still contains a
#      step called `lint-args guard`.
thirtytwo_b="$(fresh_copy seam-list-shortened)"
edit "$thirtytwo_b/.github/workflows/ci.reusable.yml" \
  '              --config|-c|--no-config|--no-config-lookup|--force-default-config|' \
  '              --config|-c|--no-config-lookup|--force-default-config|'
expect_red_check 'breakage 32b: the guard no longer refuses --no-config' \
  "$thirtytwo_b" "$SEAM" --static-only

# 32c. The guard moved AFTER the linter. It still runs, still reads the variable,
#      and still refuses everything it refused — after the linter has already
#      been handed `--no-config` and already exited 0. A control that runs after
#      the thing it controls is the most comfortable kind of dead code, because
#      reading the workflow top to bottom it looks exactly like a live one.
thirtytwo_c="$(fresh_copy seam-guard-after-the-linter)"
"$PY" - "$thirtytwo_c/.github/workflows/ci.reusable.yml" <<'PYDEL28C'
import sys

import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
for lang in ("go", "ruby", "node"):
    job = (doc.get("jobs") or {}).get(lang) or {}
    steps = job.get("steps") or []
    guard = next((s for s in steps if s.get("name") == "lint-args guard"), None)
    if guard is None:
        sys.exit("self_test: job " + lang + " had no `lint-args guard` to move")
    steps.remove(guard)
    steps.append(guard)
    job["steps"] = steps
with open(path, "w", encoding="utf-8") as fh:
    yaml.safe_dump(doc, fh, sort_keys=False, default_flow_style=False)
PYDEL28C
expect_red_check 'breakage 32c: the seam guard runs AFTER the linter it guards' \
  "$thirtytwo_c" "$SEAM" --static-only

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
#   Anchored on the breakage LABEL, and identical to the `_st_breakages` /
#   `_st_reds` patterns in tests/validate.sh. Both used to anchor on `^expect_`,
#   which also matched the four helper *definitions* — `expect_red() {` looks
#   exactly like a call to a name-only pattern — so this printed 28 over 23
#   recipes for a run. Two files printing two different counts of the same file,
#   side by side, is the defect this repo keeps refusing to ship; the fix is to
#   count something that cannot be a definition.
#
#   Only the reds are counted as reds, and the skip-proofs are named
#   separately. Breakage 23b asserts a green gate on purpose, and a summary
#   claiming it "went red" would be a false statement about a proof that passed.
counted=$(grep -cE '^ *expect_red(_check|_lang|_script)? +.breakage +[0-9]+[a-z]*:' "$0" || true)
total=$(grep -cE '^ *expect_(red(_check|_lang|_script)?|skip_check) +.breakage +[0-9]+[a-z]*:' "$0" || true)
echo "PASS: self_test — all $total breakages hold ($counted assert red, $((total - counted)) assert a green gate with a named skip), and the unbroken tree is green."
