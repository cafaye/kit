#!/usr/bin/env bash
#
# Prove the docker-tier guard sees a TIER, not only a call site.
#
#   bash reports/wrapper-tier-scope/mutations.sh
#
# WHY A SEPARATE HARNESS AND NOT A BREAKAGE IN tests/self_test.sh. self_test.sh
# runs whole gates in sequence, so a recipe here would cost a full gate run per
# mutation and this file exists to be runnable in seconds against a text scan
# with no docker anywhere in it. What it borrows from that suite is the part that
# matters: the guard's OWN source is extracted from `tests/validate.sh` on every
# run, never copied into a file beside this one, so a harness cannot outlive the
# check it is proving.
#
# TWO THINGS ARE ASSERTED PER MUTATION, and the second is the one this repository
# has already been bitten by:
#
#   1. that the mutation is IN THE FILE — by text, not by exit status. A mutation
#      that silently failed to apply produces a guard that reports NOT BITTEN and
#      a harness that reports a clean tree, which is a passing recipe that proves
#      nothing. `git diff --quiet` is the assertion; it cannot be satisfied by a
#      `sed` that matched nothing.
#   2. that the guard names the file afterwards, and stops naming it once the
#      mutation is reverted.
#
# The guard is run by extracting its python heredoc. If that extraction ever
# returns nothing the run STOPS rather than reporting six clean cases: a harness
# measuring nothing is the same defect as a guard measuring nothing, and this
# file exists because of one.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1

TMP="$(mktemp -d "${TMPDIR:-/tmp}/kit-wrapper-scope.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

passes=0
failures=0
cases=0

# --------------------------------------------------------------------------
# the guard's own source, extracted rather than copied
# --------------------------------------------------------------------------
extract_guard() {
  awk '
    /^[[:space:]]*docker_tier_project_name\(\)[[:space:]]*\{/ { infn = 1 }
    infn && /<<.PY.$/ { body = 1; next }
    body && /^PY$/ { exit }
    body { print }
  ' tests/validate.sh
}

GUARD="$TMP/guard.py"
extract_guard >"$GUARD"
if [ ! -s "$GUARD" ] || ! grep -q 'BRING_UP' "$GUARD"; then
  echo "STOP: could not extract docker_tier_project_name's python out of tests/validate.sh."
  echo "      A run that measures nothing reports six clean cases and proves nothing."
  exit 1
fi
# Named so a reader can see which revision of the guard produced the numbers.
echo "guard: $(wc -l <"$GUARD" | tr -d ' ') lines extracted from tests/validate.sh"
echo

restore() { git checkout -- tests/ 2>/dev/null || true; }
trap 'restore; rm -rf "$TMP"' EXIT

if ! git diff --quiet -- tests/; then
  echo "STOP: tests/ is dirty. A mutation run measures the diff, not the guard."
  git diff --stat -- tests/
  exit 1
fi

scan() {
  # Bounded on purpose: this is a text scan and must finish in well under a
  # second, so a hang here is a finding and not something to wait out.
  timeout 60 python3 "$GUARD" "$ROOT/tests" >"$TMP/out" 2>&1
  echo $? >"$TMP/ec"
}

# count_names <file> — how many findings name this file.
#
# `grep -c` on a FILE, never `printf … | grep -q`. That is this repository's own
# recorded rule: `grep -q` closes the pipe on its first match, `printf` dies of
# SIGPIPE and `pipefail` promotes 141, so the verdict flips on the SIZE of the
# output rather than on what is in it. Measured there at 2000 lines returning 0
# and a 239KB report returning 141 with the match present.
count_names() {
  # `grep -c` prints 0 AND exits 1 on no match, so a `|| echo 0` after it yields
  # the two-line string "0\n0" and every comparison downstream reads as a shell
  # error rather than as a count. Assign first, fall back on the exit status.
  local n
  n="$(grep -c -- "$1" "$TMP/out" 2>/dev/null)" || n=0
  printf '%s' "$n"
}

# mutate <label> <file> <from> <to>
#
# The edit is applied with `python3`, which REFUSES to write when the anchor is
# absent — so a mutation that stopped matching the tree stops the run instead of
# silently testing nothing. That is the first half of the assertion; `git diff`
# below is the second, and it is the one that would still catch a writer that
# reported success while changing nothing.
mutate() {
  local label="$1" file="$2" from="$3" to="$4"
  cases=$((cases + 1))
  restore

  if ! timeout 60 python3 - "$file" "$from" "$to" <<'PY'
import sys
path, frm, to = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as fh:
    body = fh.read()
if body.count(frm) != 1:
    print(f"    anchor appears {body.count(frm)} times in {path}, expected exactly 1")
    sys.exit(1)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(body.replace(frm, to))
PY
  then
    printf 'NO ANCHOR   %s\n' "$label"
    failures=$((failures + 1))
    return
  fi

  # ASSERTION 1, BY TEXT: the mutation is really in the file.
  if git diff --quiet -- "$file"; then
    printf 'NO MUTATION  %s — the edit reported success and left the file byte-identical\n' "$label"
    failures=$((failures + 1))
    return
  fi
  if ! grep -q -- "$to" "$file"; then
    printf 'NO MUTATION  %s — `%s` is not in %s after the edit\n' "$label" "$to" "$file"
    failures=$((failures + 1))
    return
  fi

  scan
  base="$(basename "$file")"
  local after
  after="$(count_names "$base")"

  restore
  scan
  local before
  before="$(count_names "$base")"

  if [ "$before" -eq 0 ] && [ "$after" -ge 1 ]; then
    printf 'BITTEN       %-52s before=%s after=%s  (exit %s)\n' "$label" "$before" "$after" "$(cat "$TMP/ec")"
    passes=$((passes + 1))
  else
    printf 'NOT BITTEN   %-52s before=%s after=%s\n' "$label" "$before" "$after"
    failures=$((failures + 1))
  fi
}

echo "--- TIER SCOPE: a tier reached through a wrapper must still be a tier ---"
echo

# (1) The packet's mutation. `PROJECT="kit-canary-$$"` is the derived name every
#     wrapper tier on this tree already uses; removing the `$$` is exactly the
#     defect the whole chain exists to kill, reintroduced in one character.
mutate 'canary: PROJECT loses its $$' \
  tests/canary_test.sh 'PROJECT="kit-canary-$$"' 'PROJECT="kit-canary"'

mutate 'no_telemetry: PROJECT loses its $$' \
  tests/no_telemetry_in_readiness.sh 'PROJECT="kit-readiness-$$"' 'PROJECT="kit-readiness"'

mutate 'stack_live: PROJECT loses its $$' \
  tests/stack_live_test.sh 'PROJECT="kit-stack-$$"' 'PROJECT="kit-stack"'

# (2) The same defect spelled at the USE SITE rather than the declaration, because
#     a use site is what the four rules actually read. For the two wrapper tiers
#     the use site is INSIDE the wrapper's own body — the literal `compose()`
#     hides the flag, which is the half of the shape a call-site pattern cannot
#     see.
mutate 'canary: wrapper hardcodes -p' \
  tests/canary_test.sh \
  'compose() { docker compose -p "$PROJECT" -f "$WORK/compose.yml" "$@"; }' \
  'compose() { docker compose -p kit-canary -f "$WORK/compose.yml" "$@"; }'

mutate 'no_telemetry: wrapper hardcodes -p' \
  tests/no_telemetry_in_readiness.sh \
  'compose() { docker compose -p "$PROJECT" -f "$WORK/compose.yml" "$@"; }' \
  'compose() { docker compose -p kit-readiness -f "$WORK/compose.yml" "$@"; }'

# (3) The third shape: no wrapper at all — `docker compose` called directly with
#     a subcommand that is not `up`. The original pattern matched `… up`, so a
#     file whose only compose calls are `ps`, `exec`, `port` and `logs` was
#     invisible even though every one of them names the shared project.
mutate 'stack_live: direct docker compose -p hardcoded' \
  tests/stack_live_test.sh \
  "docker compose -p \"\$PROJECT\" ps --format '{{.Service}}|{{.Health}}'" \
  "docker compose -p kit-stack ps --format '{{.Service}}|{{.Health}}'"

echo
echo "--- THE FIFTH EMPTINESS FINDING: a docker script outside the tier set ---"
echo

# A rule that fires on nothing is not yet proven to be able to fire, and that is
# the whole subject of this packet: four emptiness findings were unreachable for
# the same reason the tiers were invisible. No script under tests/ is uncovered
# today, so this case BUILDS one — it drops a bare `docker volume rm` into a script
# that is not a tier and asserts the guard names it rather than dropping it.
#
# `docker volume rm` rather than `docker compose` because the inserted line must
# not become a tier by the bring-up arms: it names a bare volume, which is exactly
# a shared namespace reached with no `-p` at all. The finding has to arrive from
# the TIERSET rule, so the case fails if that rule is deleted and passes if it is
# there.
mutate 'lint_test: a bare docker volume rm makes it uncovered' \
  tests/lint_test.sh \
  'set -euo pipefail' \
  $'set -euo pipefail\ndocker volume rm shared-vol'

# The fifth namespace, mutated at the declaration. The tag this fixes was a
# literal in the tree before this packet and no rule could see it, because the
# file brought no stack up; it is asserted here so a future widening that drops
# TAKES_A_SHARED_NAME takes this red with it rather than silently reaching 8 tiers
# and reporting green.
mutate 'provenance: image tag loses its $$' \
  tests/provenance_test.sh \
  'GOOD_IMAGE="kit-provenance-test-$$:good"' \
  'GOOD_IMAGE="kit-provenance-test:good"'

echo
echo "--- BASELINE: the clean tree ---"
restore
scan
cat "$TMP/out"
echo "exit=$(cat "$TMP/ec")"

echo
printf '%d/%d cases bit, %d failed\n' "$passes" "$cases" "$failures"
[ "$failures" -eq 0 ] || exit 1
exit 0