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
#   23-26. THE FLEET GATE, one breakage per failure mode, each against a FIXTURE
#         fleet rather than the real one. A fixture fleet is what makes these
#         mean anything: the real fleet is red on master BY DESIGN, so "the gate
#         went red" there is satisfied by two clean repositories.
#           23. a service carrying its own copy of the shared stack (a second
#               postgres) -> the stale-copy check goes red. Five of the six
#               repositories that declare local infrastructure are in exactly
#               this state today, and the mutation is their real shape rather
#               than a toy.
#           24. a service that overrides the collector's config mount -> the
#               weakened-boundary check goes red. The mount is where the
#               redaction allowlist lives, so this is the failure that leaks
#               prompt content rather than the one that looks untidy.
#           25. an `otel-collector.yml` nothing ever starts -> the dead-config
#               check goes red. Inert is the worst of the four: the file looks
#               authoritative, every edit to it changes nothing, and a
#               developer has no way to find out.
#           26. a `kit.ref` holding `master` -> the pin check goes red.
#   30-31. THE ADOPTION CEILING, both sides of it, because a ceiling that only has
#         one side proved is not a ceiling — it is a deleted check.
#           30. the SAME stale copy in a repository with NO `kit.ref` -> the gate
#               stays GREEN and the finding is printed as a WARN naming the
#               adoption path. This is the half that could have been quietly
#               wrong: if the unadopted side went red, the ceiling would not
#               exist and this breakage would have caught it.
#           31. that repository's `kit.ref` written -> the gate goes RED on the
#               same defect, same message, same severity. This is the half that
#               proves nothing was weakened: it is the fixture of breakage 23
#               plus one committed line.
#           The pair is also the ratchet proof. 30 and 31 run over the SAME
#           fixture, so a change that softened the adopted side fails 31 and a
#           change that hardened the unadopted side fails 30, and there is no
#           third state in which both pass and the checks are weaker.
#   27-29. the override rules, each against the named check.
#           27. a vendor config mount that stopped resolving from the fetched
#               tree. Found by RUNNING the stack; `docker compose config`
#               renders the same project and every other check stays green.
#           28. the pin moved back into `.env`, where it is git-ignored and so
#               exists on exactly one machine.
#           29. a service publishes a port on a service kit already ships. The
#               merge appends rather than substitutes, so nothing errors and the
#               port the developer meant to move is still bound.
#
#   Fifteen of them (7-12, 19, 20, 23-29) additionally assert WHICH check
#         went red. Every other breakage only proves the gate can fail; those
#         prove the check written for that defect is still load-bearing, which is
#         a different claim and the one that decays silently. 21 and 22 assert
#         the same thing about the two scripts that are themselves proofs, and
#         23-26 assert it over a fixture fleet rather than over the tree — see
#         `break_fleet` below for why that helper exists at all.
#
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
# `copies/$name`, NOT `$WORK/$name`, and the reason is a proof that passes for the
# wrong reason.
#
# Every `expect_red_check` runs `validate.sh` inside a throwaway copy, and
# `validate.sh` asks `fleet_check.py` about `$ROOT/..` — the copy's PARENT. If
# that parent is `$WORK`, then every fixture fleet an earlier breakage built
# (`$WORK/fixtures/<name>/{alpha,beta}`, each with a `.git`) is a repository the
# gate can see, and the first one's `alpha` is still broken. So breakage 23's
# defect makes EVERY LATER breakage go red, and breakages 24-26 would pass on
# `FAIL fleet` whether or not the mutation they applied was the defect they name.
#
# Four proofs asserting nothing, caused by a directory that was one level too
# high. `copies/` is a directory that holds copies and nothing else, so a copy's
# parent contains exactly one entry — itself — and that entry has no `.git`.
fresh_copy() {
  copy_name="$1"
  local dst="$WORK/copies/$copy_name"
  mkdir -p "$dst"
  # `.github` is in this list and not an afterthought: the reusable workflow it
  # holds is the artifact every check that reads the workflow's inputs reads by
  # path, so a copy without it cannot fail the same way the real tree does.
  # `core` is here for the same reason `.github` is: the breakages below mutate
  # files in it, and a copy without it would fail on a missing path rather than
  # on the defect under test — which is a self_test that proves nothing.
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

# expect_green_check <label> <dir> <check-label> <needle> <validate.sh args...>
#
# The mirror of `expect_red_check`, and it exists for exactly one case: a
# finding the gate is supposed to report WITHOUT failing on. "The gate stayed
# green" is necessary but far too weak — the gate is green on a tree where the
# fleet check crashed, or exited 2 and had its SKIP swallowed, or printed
# nothing at all. So this asserts BOTH halves:
#
#   1. the named check reported PASS, and
#   2. `needle` — a literal string from the finding — is in the output.
#
# (1) alone is the "silently skipped" failure this repository keeps warning
# about, and (2) alone would be satisfied by a check that printed the word
# somewhere. Together they are the claim: *this* check passed, and it passed
# while telling you about this specific thing.
expect_green_check() {
  local label="$1" dir="$2" want="$3" needle="$4"
  shift 4
  local out ec=0
  out=$(cd "$dir" && KIT_PYTHON="$PY" bash tests/validate.sh "$@" 2>&1) || ec=$?
  if [ "$ec" -ne 0 ]; then
    printf 'FAIL self_test: %s — the gate went RED (exit %s), so the ceiling is not in force\n' \
      "$label" "$ec"
    printf '%s\n' "$out" | grep -E '^(FAIL|  -|       )' | tail -20 | sed 's/^/       /'
    failures=$((failures + 1))
  elif ! printf '%s\n' "$out" | grep -qF "PASS $want"; then
    printf 'FAIL self_test: %s — the gate stayed GREEN but `%s` did not report PASS\n' \
      "$label" "$want"
    printf '%s\n' "$out" | grep -E '^(FAIL|SKIP)' | tail -20 | sed 's/^/       /'
    failures=$((failures + 1))
  elif ! printf '%s\n' "$out" | grep -qF "$needle"; then
    # The dangerous one. A green run that said nothing is a check that ran
    # nothing, and it is exactly what a deleted ceiling looks like from here.
    printf 'FAIL self_test: %s — GREEN, but the finding was never named (no %q)\n' \
      "$label" "$needle"
    printf '%s\n' "$out" | sed -n '/fleet/,+4p' | sed 's/^/       /'
    failures=$((failures + 1))
  else
    printf 'PASS self_test: %s — stayed green and named the debt\n' "$label"
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

# ONE run, and its output is CAPTURED rather than re-fetched.
#
# The first version ran the gate twice: once discarding the output to read the
# exit status, and again to print the diagnostic. That is a second chance to
# lose the throwaway tree, and on the run where it mattered it lost it — the
# control was reported as
#
#   FAIL self_test: unbroken tree — the gate is RED on an unbroken tree
#   self_test.sh: line 223: cd: /tmp/kit-self-test.XXXX/base: No such file or directory
#
# which is a diagnosis of the DIAGNOSTIC, not of the gate. The gate had already
# said something; nobody could read it. `|| ec=$?` rather than a bare assignment
# is what keeps `set -e` from killing the harness before the status is read —
# the same trap `expect_red_lang` documents, and the reason it is written out
# again here rather than shared: the harness has no library.
expect_green() {
  local label="$1" dir="$2"
  shift 2
  local out ec=0
  if [ -d "$dir" ]; then
    out="$(cd "$dir" && KIT_PYTHON="$PY" bash tests/validate.sh "$@" 2>&1)" || ec=$?
  else
    # Distinct from a red gate, because it is: the tree is gone, not failing.
    printf 'FAIL self_test: %s — the throwaway copy %s does not exist\n' "$label" "$dir"
    printf '       Every worker on this machine mktemps under the same TMPDIR, so a\n'
    printf '       sibling that deleted its own tree broadly can delete this one. That\n'
    printf '       is an environment failure and NOT evidence about the gate.\n'
    failures=$((failures + 1))
    return
  fi
  if [ "$ec" -eq 0 ]; then
    printf 'PASS self_test: %s — the gate is green on an unbroken tree\n' "$label"
  else
    printf 'FAIL self_test: %s — the gate is RED on an unbroken tree (exit %s)\n' "$label" "$ec"
    printf '%s\n' "$out" | grep -E '^(FAIL|note:|  -|       )' | tail -20 | sed 's/^/       /'
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

# fixture_fleet <name> — a throwaway FLEET for the four breakages below.
#
# WHY A FIXTURE AND NOT THE REAL ONE. The fleet gate is red on master, by design
# and on purpose. If these breakages ran against the real sibling checkouts, every
# one of them would be red before it started — and `expect_red_check` answers
# "did THAT NAMED check go red", so a tree that is red for an unrelated reason
# makes the proof meaningless in the one direction that matters. A fixture is
# green, so a red can only have come from the breakage.
#
# It is also what makes the proofs hermetic. They need a fleet-shaped directory
# with two repositories in it, and building two is cheaper and more predictable
# than depending on whoever is checked out next to kit on the machine.
#
# FIXTURE SHAPE, and each part is load-bearing:
#   alpha/  a service that has adopted the stack: a `kit.ref` with a real pin,
#           a compose file that is a genuine OVERRIDE (its own service, no
#           `ports:`, nothing kit ships), and no collector config of its own.
#   beta/   the same, so a breakage aimed at alpha cannot be masked by beta and a
#           check that only ever looks at the first repository is caught.
#
# `.git` is a directory, not a worktree marker file, because fleet_check.py skips
# worktrees — a fixture that looked like a worktree would be skipped and every
# breakage below would pass vacuously.
fixture_fleet() {
  # Two `local`s and not one. `local name="$1" root="…$name"` reads `name` while
  # it is still being assigned, so `root` is built from whatever `name` happened
  # to be — empty on the first call, so every fixture would be written to one
  # directory and the breakages would share it and mask each other. shellcheck
  # says so (SC2318), and the symptom is four proofs that all pass or all fail
  # together.
  local name="$1"
  # `fixtures/`, not `$WORK` directly — for the reason `fresh_copy` writes to
  # `copies/`. A fixture fleet is a fleet of REPOSITORIES, each with a `.git`;
  # anywhere a later `expect_red_check` can discover one, an earlier breakage's
  # still-broken `alpha` makes the next breakage red for the wrong reason. Only
  # the four fleet breakages set `KIT_FLEET`, and they point it here.
  local root="$WORK/fixtures/$name"
  rm -rf "$root"
  mkdir -p "$root/alpha" "$root/beta"
  local svc
  for svc in alpha beta; do
    mkdir -p "$root/$svc/.git"
    printf '# %s: the kit this service runs.\n41f8bcb919e34b14e7c809cbb22e24b74ec25099\n' \
      "$svc" >"$root/$svc/kit.ref"
    cat >"$root/$svc/docker-compose.yml" <<'YAML'
# This service's own file, as an OVERRIDE beside the fetched stack. It owns its
# image and its own database name, and nothing that kit already ships.
services:
  alpha:
    image: cafaye/alpha:dev
    environment:
      POSTGRES_DB: alpha
    depends_on:
      postgres:
        condition: service_healthy
    networks: [platform]
YAML
  done
  printf '%s' "$root"
}

# break_stale_copy <fixture> — give `alpha` a `postgres` of its own.
#
# FACTORED OUT of breakage 23 because breakage 31 needs the identical mutation,
# and the two halves of the adoption-ceiling proof are only a proof if they are
# the SAME defect in the SAME shape. Two hand-written copies of a nine-line
# YAML mutation would drift, and the drift would show up as "31 went green
# because it was mutating something else" — which is indistinguishable from
# "31 proved the ceiling is airtight".
#
# The mutation is the real shape rather than a toy: a service that names its
# database `db` and pins `postgres:17`. The service name is `db` and not
# `postgres` on purpose, because that is what five of the six repositories in
# scope actually do, and the check keys on the IMAGE.
break_stale_copy() {
  "$PY" - "$1/alpha/docker-compose.yml" <<'PYEOF'
import sys

path = sys.argv[1]
body = open(path, encoding="utf-8").read()
old = "  alpha:\n    image: cafaye/alpha:dev"
new = (
    "  db:\n    image: postgres:17\n    environment:\n      POSTGRES_USER: alpha\n"
    "      POSTGRES_DB: alpha\n    ports:\n      - \"15500:5432\"\n"
    "    volumes:\n      - alpha-pg:/var/lib/postgresql/data\n    healthcheck:\n"
    "      test: [\"CMD\", \"pg_isready\", \"-U\", \"alpha\"]\n"
    "      interval: 10s\n      timeout: 5s\n      retries: 5\n"
    "  alpha:\n    image: cafaye/alpha:dev"
)
if old not in body:
    sys.exit(f"self_test: break_stale_copy: {old!r} not in {path}")
open(path, "w", encoding="utf-8").write("volumes:\n  alpha-pg:\n" + body.replace(old, new, 1))
PYEOF
}

# unadopt <fixture> — remove every `kit.ref` in a fixture fleet.
#
# Every repository, not just `alpha`. The ceiling is per-repository, and a
# fixture where `beta` still adopted would be testing two things at once: that
# an unadopted repository warns, and that a clean adopting repository passes.
# Both are worth proving, but not in one recipe, and not when a failure of the
# first cannot be told from a failure of the second.
unadopt() {
  find "$1" -name kit.ref -type f -delete
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

# 23-26. THE FLEET GATE, one breakage per failure mode. Four, because the claim
#        is four separate claims and a check that only proves one of them is a
#        check that has proved nothing about the other three.
#
#        Every one asserts the NAMED check, not merely "the gate went red". The
#        fleet gate is red on master for the whole fleet, so "the gate went red"
#        is the WEAKEST possible assertion here: it would be satisfied by a
#        fixture fleet of two perfectly clean repositories. `expect_red_check`
#        against a green fixture is the only form of this proof that says
#        anything.
FLEETCHECK='fleet  (no stale copy, no weakened boundary, no dead config, every ref pinned)'

# 23. A STALE FULL COPY OF THE STACK. The realistic shape, and the one the packet
#     was written about: a service running its own `postgres` rather than joining
#     kit's. Five of the twelve repositories do exactly this today.
#
#     The mutation is a real service file, not a toy — the same `db:` service with
#     the same `image: postgres:17` that billing, courier, darkroom and identity
#     carry. A fixture that used a name kit does not ship would test a rule nobody
#     broke, which is precisely the bug in the check's first version: five of the
#     six repositories in scope call their database `db`, so a check that matched
#     on the NAME found nothing in any of them.
twentythree_fixture="$(fixture_fleet stale-copy)"
break_stale_copy "$twentythree_fixture"
export KIT_FLEET="$twentythree_fixture"
expect_red_check 'breakage 23: a service carries its own copy of the shared stack' \
  "$base" "$FLEETCHECK" --static-only

# 24. A WEAKENED REDACTION BOUNDARY. The service re-points the collector's config
#     mount at its own `otel-collector.yml` — which is the whole attack: the
#     allowlist is derived from core's schemas by kit's gate, and a service that
#     owns the file owns a boundary nobody derived.
twentyfour_fixture="$(fixture_fleet weakened-boundary)"
cat >"$twentyfour_fixture/alpha/otel-collector.yml" <<'YAML'
# A copy of kit's collector config, with the redaction allowlist thrown away. The
# whole point of the file is that it is DERIVED; a local copy is a boundary
# nobody keeps in step with core.
receivers:
  otlp:
    protocols:
      http:
exporters:
  debug:
    verbosity: detailed
service:
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [debug]
YAML
"$PY" - "$twentyfour_fixture/alpha/docker-compose.yml" <<'PYEOF'
import sys

path = sys.argv[1]
body = open(path, encoding="utf-8").read()
body = body.replace(
    "services:\n  alpha:",
    "services:\n  otel-collector:\n"
    "    volumes:\n"
    "      - ./otel-collector.yml:/etc/otel/otel-collector.yml:ro\n"
    "  alpha:",
    1,
)
open(path, "w", encoding="utf-8").write(body)
PYEOF
export KIT_FLEET="$twentyfour_fixture"
expect_red_check 'breakage 24: a service re-points the collector config mount' \
  "$base" "$FLEETCHECK" --static-only

# 25. A COLLECTOR CONFIG NOTHING STARTS. The file is present, plausible, and
#     inert: nothing mounts it, so the collector that actually runs is reading the
#     pinned ref's copy. A developer edits this file and nothing changes at all,
#     which is strictly worse than the file being absent.
twentyfive_fixture="$(fixture_fleet dead-collector-config)"
cp "$ROOT/templates/compose/otel-collector.yml" \
  "$twentyfive_fixture/alpha/otel-collector.yml"
export KIT_FLEET="$twentyfive_fixture"
expect_red_check 'breakage 25: an otel-collector.yml that no compose file ever mounts' \
  "$base" "$FLEETCHECK" --static-only

# 26. AN UNPINNED REF. `master`, in the committed `kit.ref` — the shape that is
#     one `sed` away from correct and that a gate is the only thing stopping.
#
#     The brief calls this out separately from 23-25 and it earns its own entry:
#     the other three are about a service carrying something it should not, and
#     this one is about the fleet as a whole running a stack that changes between
#     Tuesday and Monday. A gate that proved the first three and this one would
#     still be missing the one that makes "one command, always current" mean
#     something.
twentysix_fixture="$(fixture_fleet unpinned-ref)"
printf '# deliberately unpinned\nmaster\n' >"$twentysix_fixture/alpha/kit.ref"
export KIT_FLEET="$twentysix_fixture"
expect_red_check 'breakage 26: a service pins a BRANCH rather than a ref' \
  "$base" "$FLEETCHECK" --static-only

# 27-29. THE KIT-SIDE AND OVERRIDE RULES. The four above are about the fleet;
#         these are about kit's own tree, and about what a second `-f` file is
#         allowed to do to it. They are the halves that make the fleet half mean
#         anything: a gate that only checks its callers is checking that they call
#         it correctly, not that it works.
#
# 27. A VENDOR CONFIG MOUNT THAT STOPPED RESOLVING FROM THE FETCHED TREE. One
#     `${KIT_COMPOSE_DIR:-.}` prefix dropped from one mount. The stack still
#     parses, `docker compose config` still renders the same project, and the
#     variable's value is not a property of the YAML — so nothing above it in the
#     gate can see it. What it does is resolve the mount to a path that does not
#     exist, and Docker's answer to that is to CREATE A DIRECTORY, so the failure
#     arrives four containers later as
#     `read /etc/tempo/tempo.yaml: is a directory`. Found by running the stack.
MOUNTCHECK='templates/compose/ + bin/dev  (every vendor config mounts from the fetched tree)'

twentyseven="$(fresh_copy mount-not-anchored)"
edit "$twentyseven/templates/compose/docker-compose.yml" \
  '      - ${KIT_COMPOSE_DIR:-.}/tempo/tempo.yaml:/etc/tempo/tempo.yaml:ro' \
  '      - ./tempo/tempo.yaml:/etc/tempo/tempo.yaml:ro'
expect_red_check 'breakage 27: a vendor config mount stopped resolving from the fetched tree' \
  "$twentyseven" "$MOUNTCHECK" --static-only

# 28. THE PIN MOVED BACK INTO `.env`, where it is git-ignored. The shape is
#     subtler than "the pin is wrong": the template ships
#     `KIT_STACK_REF=<sha>` in `.env.example`, so a fresh clone looks configured
#     and needs no setup. It also means the pin lives in a file that becomes
#     `.env`, and `.env` is git-ignored — so the pin exists on the laptop of
#     whoever ran the command last and on no CI runner and no teammate's
#     checkout. "One command, always current" quietly becomes "one command,
#     whatever this checkout last fetched".
#
#     `bin/dev` reads KIT_STACK_REF from the ENVIRONMENT only, as a one-run
#     override, so the shipped line decides nothing at run time. A gate that asked
#     "is the pin pinned?" would still be green; it has to ask WHERE the pin
#     lives, which is a different question and a different check.
#
#     `rm -f kit.ref` is here for the shape a SERVICE sees, not for kit: kit's own
#     root has no `kit.ref` — the pin belongs to the adopting service. Removing it
#     is a no-op on this tree, and the red comes entirely from the `.env.example`
#     line. Kept because the recipe should read as the defect it is proving
#     rather than as the minimum needed to trip a check.
PINCHECK='templates/bin/dev.sh + .env.example  (the pin is kit.ref, and the gate reads the same file)'

twentyeight="$(fresh_copy pin-back-in-env)"
rm -f "$twentyeight/kit.ref"
cat >>"$twentyeight/templates/compose/.env.example" <<'ENTRY'
KIT_STACK_REF=0000000000000000000000000000000000000000
ENTRY
expect_red_check 'breakage 28: the pin is back in .env, where nothing reads it' \
  "$twentyeight" "$PINCHECK" --static-only

# 29. A PORT PUBLISHED ON A SERVICE KIT ALREADY SHIPS. The quietest of the three,
#     because nothing errors. `ports:` is a LIST, a second `-f` file's list is
#     APPENDED rather than substituted, and a service that writes
#
#         services:
#           postgres:
#             ports: ["15433:5432"]
#
#     gets postgres listening on kit's 15500 AND on 15433. `docker compose config`
#     renders both and warns about neither, so the file reads like the override it
#     was written to be while doing something else — and the port it meant to move
#     is still bound. The documented way to move a published port is the VARIABLE
#     in `.env`, which replaces.
#
#     No `image:` on the mutation, deliberately: the rule keys on the service NAME
#     kit ships, not on an image, so this fires the ports rule alone and the
#     stale-copy rule stays quiet. A breakage that reddened both would not say
#     which one is load-bearing.
twentynine_fixture="$(fixture_fleet published-port)"
cat >>"$twentynine_fixture/alpha/docker-compose.yml" <<'YAML'
  postgres:
    ports:
      - "15433:5432"
YAML
export KIT_FLEET="$twentynine_fixture"
expect_red_check 'breakage 29: a service publishes a port on a service kit already ships' \
  "$base" "$FLEETCHECK" --static-only

# 30-31. THE ADOPTION CEILING, both sides of it, and the pair is the proof.
#
# The fleet gate was red on master for six repositories that have adopted
# nothing, which is the same shape as a build that has been red for a quarter:
# the red is true, and it has stopped being information. The ceiling is the
# response core-16 applied to a missing OpenAPI document — absence is a named
# warning with the adoption path attached, and it becomes a failure the moment
# the repository adopts.
#
# A ceiling needs BOTH halves proved, and that is why these are two recipes over
# ONE mutation rather than one recipe over two mutations:
#
#   30  the stale copy, with no kit.ref anywhere in the fleet. The gate stays
#       GREEN, and the finding is PRINTED, with the adoption path. If this one
#       goes red the ceiling does not exist — the gate is failing unadopted
#       repositories, which is the state the packet was dispatched to fix.
#   31  the identical stale copy, with kit.ref committed. The gate goes RED on
#       the identical finding. If this one stays green then the ceiling is not
#       a ceiling but a deletion: the checks no longer decide anything at all.
#
# 31 is breakage 23 plus one committed line, and that is the entire argument in
# one diff. Nothing about the predicate, the message or the severity changed
# between them; what changed is whether the repository has accepted the standard
# it is being measured against.
#
# The needle in 30 is a literal substring of the finding rather than the word
# `WARN`. A check that printed "WARN" and nothing else would satisfy the weaker
# assertion, and a check that deleted the finding entirely and left the string
# in a comment would satisfy it too — which is the shape this repository has
# already been bitten by once, with a policy stated in both the Python and a
# rule.
CEILINGCHECK='fleet  (adopting repositories clean;'
thirty_fixture="$(fixture_fleet ceiling-unadopted)"
break_stale_copy "$thirty_fixture"
unadopt "$thirty_fixture"
export KIT_FLEET="$thirty_fixture"
expect_green_check 'breakage 30: an UNADOPTED service copies the stack — green, and named' \
  "$base" "$CEILINGCHECK" "which is the image kit's stack already ships" --static-only

thirtyone_fixture="$(fixture_fleet ceiling-adopted)"
break_stale_copy "$thirtyone_fixture"
export KIT_FLEET="$thirtyone_fixture"
expect_red_check 'breakage 31: the same copy in an ADOPTING service is a hard FAIL' \
  "$base" "$FLEETCHECK" --static-only

# Cleared, because `export` is not scoped to a command the way `VAR=v cmd` is, and
# the final recipe above would otherwise leave the fixture in the environment for
# whatever runs next. The alternative — a `VAR=v` prefix per call — puts
# `expect_red_check` at column 30, where the breakage counter and validate.sh's
# header/recipe check (both `grep -cE '^expect_red...'`) stop being able to see it,
# and a breakage the counter cannot see is a breakage the header is not proved
# against.
unset KIT_FLEET

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
# of the four red-expecting helpers, so this cannot drift from the recipes the
# way a hardcoded "all N breakages" does — and the header's list is checked
# against it by `tests/validate.sh`, so a breakage added without a header entry
# (or a header entry with no recipe) is a red gate rather than a doc that lies.
counted=$(grep -cE '^expect_red(_check|_lang|_script)? ' "$0" || true)
green=$(grep -cE '^expect_green_check ' "$0" || true)
echo "PASS: self_test — $counted breakages went red, $green stayed green while naming its finding, and the unbroken tree is green."
