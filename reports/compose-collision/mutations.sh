#!/usr/bin/env bash
#
# Prove the guard BITES, one property at a time.
#
#   bash reports/compose-collision/mutations.sh
#
# A guard that has never been seen to fail is a guard whose green means nothing.
# Each case below breaks ONE property of the fixed tree, asserts the gate goes
# red AND names the file and line it broke, then restores the tree and asserts
# the gate is green again. Restoring is part of the proof: a mutation run that
# leaves the tree dirty is not a proof, it is a mess.
#
# The cases are the four namespaces plus the two emptiness findings, and they are
# written as INDEPENDENT edits so each red is attributable to exactly one cause.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1

LABEL='no docker tier hardcodes a project'
passes=0
failures=0

# The tree must be clean before and after, or a mutation is indistinguishable from
# an edit. Recorded up front rather than assumed.
if ! git diff --quiet; then
  echo "STOP: the tree is dirty. A mutation run measures the diff, not the guard."
  git diff --stat
  exit 1
fi

restore() { git checkout -- tests/ 2>/dev/null || true; }

# expect_red <label> <file> <python-mutation>
expect_red() {
  local label="$1" file="$2" mutation="$3" out ec
  out="$(bash tests/validate.sh --only="$LABEL" 2>&1)"; ec=$?
  if [ "$ec" -eq 0 ]; then
    printf 'NOT BITTEN  %s\n' "$label"
    printf '            the gate stayed green on a tree with %s hardcoded\n' "$(basename "$file")"
    failures=$((failures + 1))
    restore
    return
  fi
  if ! printf '%s\n' "$out" | grep -qF "$file:"; then
    printf 'WRONG REASON  %s\n' "$label"
    printf '            red, but did not name %s; a red for the wrong cause is not a proof\n' "$file"
    failures=$((failures + 1))
    restore
    return
  fi
  printf 'BITTEN      %s\n' "$label"
  printf '            %s\n' "$(printf '%s\n' "$out" | grep -F "$file:" | head -2 | sed 's/^ *- //' | tr '\n' ' ')"
  passes=$((passes + 1))
  restore
}

# expect_green <label>
expect_green() {
  local out ec
  out="$(bash tests/validate.sh --only="$LABEL" 2>&1)"; ec=$?
  if [ "$ec" -ne 0 ]; then
    printf 'NOT RESTORED  %s\n' "$1"
    printf '            %s\n' "$(printf '%s\n' "$out" | grep -E '^ *- ' | head -2)"
    failures=$((failures + 1))
    return
  fi
  printf 'GREEN       %s\n' "$1"
}

echo "== mutations: one property broken per case, gate must go red and name the site"
echo

# (1) THE PROJECT NAME. The exact defect this packet is about, reintroduced by
# copy-paste into the bring-up site only — which is the version that is WORSE than
# reintroducing it everywhere, because the tier then queries a namespace it did
# not create.
python3 - <<'PY'
import re
p = "tests/isolation_test.sh"
s = open(p).read()
s = s.replace(
    'docker compose --project-name "$PROJECT" -f "$WORK/compose/docker-compose.yml" \\\n  up -d --wait postgres',
    'docker compose --project-name kit-isolation -f "$WORK/compose/docker-compose.yml" \\\n  up -d --wait postgres',
)
open(p, "w").write(s)
PY
expect_red "project name hardcoded at the bring-up site" "tests/isolation_test.sh"

# (2) THE PROJECT NAME at the TEARDOWN site only. The other half of "twice in
# each file", and the half that is worse to get wrong: bring-up derived, teardown
# literal, so the run deletes a cluster it does not own.
python3 - <<'PY'
p = "tests/tenancy_test.sh"
s = open(p).read()
s = s.replace(
    'docker compose --project-name "$PROJECT" -f "$WORK/compose/docker-compose.yml" \\\n      down -v',
    'docker compose --project-name kit-tenancy -f "$WORK/compose/docker-compose.yml" \\\n      down -v',
)
open(p, "w").write(s)
PY
expect_red "project name hardcoded at the TEARDOWN site" "tests/tenancy_test.sh"

# (3) THE CONTAINER NAME. `docker rm -f` takes a bare name, so this is a run
# reaching into another run's namespace.
python3 - <<'PY'
p = "tests/isolation_test.sh"
s = open(p).read()
s = s.replace('CONTROL_C="$PROJECT-control"', 'CONTROL_C="kit-isolation-control"')
open(p, "w").write(s)
PY
expect_red "control container name hardcoded" "tests/isolation_test.sh"

# (4) THE VOLUME NAME, in the derived assignment so the whole tier uses it — the
# shape a careless edit takes.
python3 - <<'PY'
p = "tests/tenancy_test.sh"
s = open(p).read()
s = s.replace('PROJECT="kit-tenancy-$$"', 'PROJECT="kit-tenancy-$$"\nCONTROL_V="kit-tenancy-control-vol"')
open(p, "w").write(s)
PY
expect_red "control volume name introduced as a literal" "tests/tenancy_test.sh"

# (5) THE HOST PORT. Worse than the rest: it collides with the developer's own
# stack, not only with another run.
python3 - <<'PY'
p = "tests/isolation_test.sh"
s = open(p).read()
s = s.replace('echo "KIT_POSTGRES_PORT=$PGPORT"', 'echo "KIT_POSTGRES_PORT=15521"')
open(p, "w").write(s)
PY
expect_red "host port pinned to a literal" "tests/isolation_test.sh"

# (6) A SIXTH TIER, added on the day it lands. The derivation claim: the guard
# covers a tier nobody added to a list, which is the whole reason the scope is
# read out of the directory rather than written down.
cat > tests/compose_collision_probe.sh <<'TIER'
#!/usr/bin/env bash
set -euo pipefail
PROJECT="kit-probe-$$"
docker compose --project-name "$PROJECT" -f "$WORK/compose.yml" up -d postgres
docker compose --project-name kit-probe -f "$WORK/compose.yml" down -v
TIER
expect_red "a NEW tier with a hardcoded name, added with no edit to validate.sh" "tests/compose_collision_probe.sh"
rm -f tests/compose_collision_probe.sh

# (7) EMPTINESS IS A FINDING. Remove every docker tier and the guard must say it
# is asserting over nothing, rather than reporting nothing and passing. This is
# the case `self_test_no_version_literal` makes its own, applied here.
mkdir -p /tmp/kit-tiers-stash
for f in tests/*_test.sh tests/no_telemetry_in_readiness.sh; do
  grep -ql 'docker compose\|docker run' "$f" 2>/dev/null && mv "$f" /tmp/kit-tiers-stash/ 2>/dev/null
done
out="$(bash tests/validate.sh --only="$LABEL" 2>&1)"; ec=$?
if [ "$ec" -ne 0 ] && printf '%s\n' "$out" | grep -q 'no docker tier found'; then
  printf 'BITTEN      emptiness is a finding, not a silent pass\n'
  passes=$((passes + 1))
else
  printf 'NOT BITTEN  emptiness is a finding, not a silent pass\n'
  failures=$((failures + 1))
fi
mv /tmp/kit-tiers-stash/* tests/ 2>/dev/null
rmdir /tmp/kit-tiers-stash 2>/dev/null

# (8) AND BACK: the tree is the fixed tree, and the gate is green. Without this
# line the six cases above prove only that something can be made red.
echo
expect_green "the fixed tree, restored"

git diff --quiet || {
  echo
  echo "STOP: the tree is dirty after the mutation run."
  git diff --stat
  exit 1
}

echo
echo "== $passes bitten, $failures not"
[ "$failures" -eq 0 ] || exit 1
echo "== every mutation was restored; the tree is exactly as it was"