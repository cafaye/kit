#!/usr/bin/env bash
#
# kit's proof that `tests/validate.sh` is able to fail.
#
#   bash tests/self_test.sh
#
# WHAT THIS IS FOR
#   A gate that only ever goes green is a report, not a gate. This script copies
#   the tree to a throwaway directory, breaks it once per kind of check — and
#   asserts the gate goes RED each time. Each breakage must be caught by a
#   *different* check, so a passing self_test means the checks are independent
#   and not one lucky assertion standing in for all of them.
#
# THE TWENTY-NINE BREAKAGES
#   1. delete a language template   -> the artifact-presence check goes red
#   2. ship a collector exporter   -> the privacy check goes red
#   3. corrupt the python codec    -> the executed test suite goes red
#   4. hardcode a compose port     -> the parameterization check goes red
#   5. flip the CI input default   -> the "consumers stay green" check goes red
#   6. ungate the `none` job       -> the option/job agreement check goes red
#   7-10. break the agreement between the documented `uses:` string and the
#         real path, in the four ways it can break -> the callable-path check
#         goes red
#   11-12. break a Dockerfile -> the hadolint check, and the non-root check that
#         exists because hadolint has no rule for a missing USER
#   13-14. plant a detectable credential, in history and in the working tree ->
#         the secret scanner goes red
#   15-16. remove --redact, then narrow the scan to the last commit -> the
#         scanner's BEHAVIOUR check goes red. Not its source: a `grep -- --redact`
#         is satisfied by the comment above the flag that explains why the flag
#         is mandatory, and breakage 15 proved exactly that
#   17. add `pull_request_target` -> the dangerous-trigger check goes red
#   18. make the `secrets` job `continue-on-error` -> the not-advisory check goes
#         red. A secret scanner that only warns is a report
#   19-22. break the canary's reference type in the four ways that turn it into
#         the leaky one -> THAT VECTOR's suite goes red
#   23. baseline unpinned-uses in .github/zizmor.yml -> the never-baselined check
#         goes red
#   24-29. one semantic mutation per language implementation -> THAT language's
#         suite goes red. A suite that has never failed has never been proven to
#         test anything, and six suites that only one language's mutation covers
#         is five suites that might assert nothing at all.
#
#   7-10, 11-12, 15-18 and 19-23 additionally assert WHICH check went red. Every
#         other breakage only proves the gate can fail; those prove the check
#         written for that defect is still load-bearing, which is a different
#         claim and the one that decays silently.
#
#   24-29 assert which LANGUAGE's suite, which is a third claim: a gate that goes
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
#   The same applies to breakages 13-23. They prove each check CAN fail; they do
#   not prove the check is complete. A check that fires on the defect it was
#   written for is the floor, and the floor is what a gate nobody runs has.
#
# WHY THE PLANTED PROBES ARE ASSEMBLED RATHER THAN WRITTEN OUT
#   Breakage 13 plants a credential, 14 plants the same one, and 22 plants a
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
breakages=0
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
  #
  # `.gitleaks.toml` is here for the same reason, and it is the one that is
  # invisible when it is missing: without it, every breakage in this file would
  # still go red — but for the wrong reason. The secret-scanner checks fail on
  # an absent config, so a copy without one cannot demonstrate that the scanner
  # detects a secret, only that the config is there. A red that means the wrong
  # thing is worse than no red, because it is counted.
  for entry in .github .gitleaks.toml AGENTS.md README.md CHANGELOG.md docker lint templates tests; do
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
  breakages=$((breakages + 1))
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
  breakages=$((breakages + 1))
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

  # Counted here as well as in the other two expectations. It used to be counted
  # only in expect_red and expect_red_check, so the summary said "all 23
  # breakages" while twenty-nine had run — and a count that under-reports is
  # worse than no count, because it reads as though six proofs are missing rather
  # than as a bug in the counter.
  breakages=$((breakages + 1))

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
    breakages=$((breakages - 1))
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

# 2. the privacy boundary. The one check that must never be satisfiable by
#    anything a developer is likely to paste.
two="$(fresh_copy exporting-collector)"
edit "$two/templates/compose/otel-collector.yml" \
  'exporters: [debug]' \
  'exporters: [debug, otlp]'
expect_red 'breakage 2: collector traces pipeline exports over the network' "$two" --static-only

# 3. a template that compiles, parses, and silently drops the sampled flag.
#    Only an executed suite catches this; no grep would.
three="$(fresh_copy broken-codec)"
edit "$three/templates/otel/python/traceparent.py" \
  'flags & SAMPLED' '0 & SAMPLED'
expect_red 'breakage 3: python codec stops preserving trace-flags' "$three" \
  --language=python --no-self-test

# 4. a hardcoded host port. The kind of edit nobody notices in review and every
#    second service on a laptop hits.
four="$(fresh_copy hardcoded-port)"
edit "$four/templates/compose/docker-compose.yml" \
  '"${KIT_POSTGRES_PORT:-5432}:5432"' '"5432:5432"'
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

# 13-18. The secret scanner, and the canary harness that answers the question
#         the scanner cannot.
#
#         A scanner that has never gone red is a report, and neither is a
#         detector that has never fired. Breakages 13-17 make the scanner catch
#         things; 18-22 make the canary's five vectors bite. They are in one
#         place because the two answer different questions about the same
#         subject, and a packet that added both is only honest if both are proven
#         able to fail.
SECRETS='gitleaks  (8.30.1, full history, --redact)'

# 13-14. A detectable credential, in history and in the tree.
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
#     the documented 20-character sample body), taken from gitleaks' test data.
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

# 13. Committed and then REMOVED — the shape the full-history requirement exists
#     for. A HEAD-only scanner sees a clean tree here, and a diff scanner sees
#     nothing at all, because by the time the commit lands the file is gone.
thirteen="$(fresh_copy committed-secret)"
plant_probe "$thirteen"
expect_red_check 'breakage 13: a credential in history, since removed' \
  "$thirteen" "$SECRETS" --static-only

# 14. The same credential, still in the tree. A separate breakage from 13
#     because it is a different code path in the scanner and a different claim:
#     13 proves the scan reads history, 14 proves it reads uncommitted files. A
#     scanner that only read history would pass 13 and fail 14, and one that only
#     read the working tree would do the reverse — so neither alone establishes
#     that both are covered.
fourteen="$(fresh_copy working-tree-secret)"
plant_probe "$fourteen"
expect_red_check 'breakage 14: a credential in the working tree' \
  "$fourteen" "$SECRETS" --static-only

# 15. --redact removed from the scan script. The build stays GREEN — nothing
#     about a secret being printed makes it non-zero — and the CI log now
#     contains the credential the scanner just found. This is the reason
#     redaction is asserted in the gate and not left to review: a change that
#     reads as a cleanup is a change that exfiltrates.
fifteen="$(fresh_copy scan-without-redact)"
edit "$fifteen/tests/gitleaks_gate.sh" \
  '  --redact \
  --no-banner \' \
  '  --no-banner \'
expect_red_check 'breakage 15: the scan stops redacting' \
  "$fifteen" 'tests/gitleaks_gate.sh  (finds a real secret, never prints it, reads history)' \
  --static-only

# 16. The scan narrowed to the diff. A shallow or HEAD-only scan cannot see
#     breakage 13's shape at all, and the check that asserts full history is
#     what makes narrowing it a failure rather than a quiet reduction in
#     coverage.
sixteen="$(fresh_copy scan-head-only)"
edit "$sixteen/tests/gitleaks_gate.sh" \
  "  set -- \"\$@\" --log-opts '-p -U0 --full-history --all'" \
  "  set -- \"\$@\" --log-opts '-1'"
expect_red_check 'breakage 16: the scan narrows to the last commit' \
  "$sixteen" 'tests/gitleaks_gate.sh  (finds a real secret, never prints it, reads history)' \
  --static-only

# 17. `pull_request_target` added as a trigger. The workflow still parses, still
#     passes every other check, and every job in it now runs with the base
#     repository's secrets and a writable token on a fork's code. The secret
#     scanner is the job that most invites this edit, which is why the trigger
#     is checked on parsed keys rather than left to review.
seventeen="$(fresh_copy dangerous-trigger)"
edit "$seventeen/.github/workflows/ci.reusable.yml" \
  '  workflow_call:' \
  '  pull_request_target:
  workflow_call:'
expect_red_check 'breakage 17: a dangerous trigger appears in the workflow' \
  "$seventeen" '.github/workflows/*  (no dangerous trigger, on parsed keys)' --static-only

# 18. The `secrets` job made advisory. The single most common way a security job
#     is neutralised, and completely invisible in a green build: continue-on-error
#     means the job reports what it found and the badge stays green. A secret
#     scanner that only warns is a report.
CANARYJOB='.github/workflows/ci.reusable.yml  (secrets job: not advisory, full history, not opt-in)'
eighteen="$(fresh_copy secrets-job-advisory)"
edit "$eighteen/.github/workflows/ci.reusable.yml" \
  '  secrets:
    name: secrets
    runs-on: ubuntu-latest' \
  '  secrets:
    name: secrets
    continue-on-error: true
    runs-on: ubuntu-latest'
expect_red_check 'breakage 18: the secret scanner is made non-blocking' \
  "$eighteen" "$CANARYJOB" --static-only

# 19-22. The canary harness. A detector that has never fired is a detector
#         asserting nothing, and these break the SAFE reference type in the four
#         ways that would turn it into the LEAKY one — each caught by a named
#         vector, so a vector that stops biting fails here rather than being
#         discovered when a token reaches a log aggregator.
CANARY='templates/secrets/go  (five vectors, each with a red proof)'

# 19. The exported pointer field becomes an unexported one. This is the shape
#     that LOOKS safest — unexported, so a reviewer reading the type sees nothing
#     worrying — and it leaks under every verb, because fmt prints unexported
#     fields through reflection. The measurement behind that is in
#     print_shape_test.go; this breakage is what proves the measurement is wired
#     into a vector rather than sitting in a comment.
nineteen="$(fresh_copy canary-unexported-token)"
edit "$nineteen/templates/secrets/go/internal/safe/creds.go" \
  '	Token *Token `json:"-"`' \
  '	token *Token'
expect_red_check 'breakage 19: the reference type hides its credential in an unexported field' \
  "$nineteen" "$CANARY" --language=go --no-self-test

# 20. The redacting String method is renamed, so the type stops being a
#     Stringer. Every dispatched verb then prints the value, which is the leak
#     the whole reference shape exists to prevent — and the `json:"-"` tag is
#     untouched, so nothing else in the tree notices.
twenty="$(fresh_copy canary-no-redaction)"
edit "$twenty/templates/secrets/go/internal/safe/creds.go" \
  'func (t *Token) String() string { return "Token(redacted)" }' \
  'func (t *Token) Redeemed() string { return "Token(redacted)" }'
expect_red_check 'breakage 20: the credential type stops redacting when printed' \
  "$twenty" "$CANARY" --language=go --no-self-test

# 21. The `json:"-"` is dropped. The credential reaches the wire under a `token`
#     key, which is vector 2's finding, and an always-present key is vector 4's.
#     Nothing else changes: the type still redacts, still has no String method,
#     and every static check in the gate is still green.
twentyone="$(fresh_copy canary-serialises-token)"
edit "$twentyone/templates/secrets/go/internal/safe/creds.go" \
  '	Token *Token `json:"-"`' \
  '	Token *Token'
expect_red_check 'breakage 21: the reference type marshals its credential' \
  "$twentyone" "$CANARY" --language=go --no-self-test

# 22. The canary committed as a literal instead of assembled. The one breakage
#     whose failure mode is invisible in a CI log: the suite keeps passing,
#     because the value is the SAME value. What changes is that the repository
#     now holds a credential-shaped string — a gitleaks finding, and an
#     allowlist entry somebody will eventually add. The check that catches it is
#     `the canary (never committed as a literal, anywhere)`.
twentytwo="$(fresh_copy canary-committed-as-literal)"
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
edit "$twentytwo/templates/secrets/go/canary.go" \
  'canary   = CanaryPrefix + strings.Repeat(canaryBody, 3)[:CanaryBytes]' \
  "canary   = \"$canary_literal\""
expect_red_check 'breakage 22: the canary is committed as a literal' \
  "$twentytwo" 'the canary  (never committed as a literal, anywhere)' --static-only

# 23. The zizmor config baselines unpinned-uses — the trade made invisibly, in a
#     file that looks like routine housekeeping. Every finding is still
#     accounted for and the build is still green, which is exactly what makes it
#     the failure mode worth a proof.
twentythree="$(fresh_copy zizmor-baselines-unpinned)"
edit "$twentythree/.github/zizmor.yml" \
  '  self-repository:' \
  '  unpinned-uses:
    ignore:
      - "**"
  self-repository:'
expect_red_check 'breakage 23: the zizmor config baselines unpinned-uses' \
  "$twentythree" '.github/zizmor.yml  (unpinned-uses recorded, never baselined)' --static-only

# 24-29. One semantic mutation per language implementation, each against a
# different spec rule, and each asserting THAT language's suite goes red.
#
# These all read from the same throwaway copy as breakage 1 rather than taking a
# fresh one each: the copy is only mutated inside a per-language temp dir, so no
# language can see another's breakage.
base="$(fresh_copy language-mutants)"

#   go    §3.2.2.5  stop masking trace-flags on read. Still compiles, still runs,
#                  and quietly forwards reserved bits to the next service.
expect_red_lang 'breakage 24: go stops masking trace-flags (§3.2.2.5)' \
  "$base" go traceparent.go \
  'Flags:      tp.Flags & sampledFlag,' \
  'Flags:      tp.Flags,'

#   ruby  §3.2.2  widen the alphabet to accept uppercase hex. The classic bug:
#                one service folds case, the next rejects the header, and a trace
#                breaks at the hop between them.
expect_red_lang 'breakage 25: ruby accepts uppercase hex (§3.2.2)' \
  "$base" ruby traceparent.rb \
  '!str.empty? && str.match?(/\A[0-9a-f]+\z/)' \
  '!str.empty? && str.match?(/\A[0-9a-fA-F]+\z/)'

#   elixir §3.2.2.2  stop rejecting trailing data on a version-00 header. Nothing
#                   crashes; the header is just no longer the format we claim to
#                   implement.
expect_red_lang 'breakage 26: elixir accepts trailing junk on version 00 (§3.2.2.2)' \
  "$base" elixir traceparent.ex \
  'defp check_trailing(value, 0), do: if(byte_size(value) == @min_header_len, do: :ok, else: {:error, :invalid})' \
  'defp check_trailing(_value, 0), do: :ok'

#   node  §3.3.1.5  raise the tracestate limit until truncation never fires. A
#                   limit nobody enforces is a limit nobody wrote on purpose.
expect_red_lang 'breakage 27: node never truncates tracestate (§3.3.1.5)' \
  "$base" node traceparent.mjs \
  'const TRACESTATE_LIMIT = 512;' \
  'const TRACESTATE_LIMIT = 100000;'

#   rust  §3.2.2.3  accept an all-zero trace-id. The spec forbids it outright; a
#                   codec that allows it merges unrelated traces into one.
expect_red_lang 'breakage 28: rust accepts an all-zero trace-id (§3.2.2.3)' \
  "$base" rust traceparent.rs \
  'if trace_id == ZERO_TRACE_ID || parent_id == ZERO_SPAN_ID {' \
  'if parent_id == ZERO_SPAN_ID {'

#   python §3.2.2.5  the same dropped mask as go, in a different language, on
#                   purpose: a rule asserted in one suite and not the other is a
#                   rule two services will disagree about.
expect_red_lang 'breakage 29: python stops masking trace-flags (§3.2.2.5)' \
  "$base" python traceparent.py \
  'flags=parsed.flags & SAMPLED,' \
  'flags=parsed.flags,'

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
# The count is derived from the breakages that were actually run, not written
# down. It used to be a literal `all 18 breakages`, which is a claim that goes
# stale the moment a nineteenth is added — and it is exactly the kind of number
# that a reader trusts instead of counting, so it was the worst place to put it.
echo "PASS: self_test — all $breakages breakages went red, and the unbroken tree is green."
