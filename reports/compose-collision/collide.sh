#!/usr/bin/env bash
#
# Two concurrent runs of one docker tier, started ON PURPOSE, so the collision is
# observed rather than argued.
#
#   bash reports/compose-collision/collide.sh <tier> <outdir>
#
# WHAT THIS IS FOR. `tests/isolation_test.sh` and `tests/tenancy_test.sh` both
# hardcoded `docker compose --project-name kit-isolation` / `kit-tenancy`, which
# is a shared namespace: one project name is one set of containers, networks and
# volumes, so two runs are not two stacks but one stack with two owners. The
# claim is easy to make from reading the file and worth nothing. This script is
# how the claim is checked.
#
# WHY A MARKER AND NOT A SLEEP. A fixed `sleep N` between the two launches is a
# guess, and on these tiers the guess is bad. Measured on this box: the tenancy
# tier spends ~60s building the image and then ~4s running its assertions, so a
# stagger that lands at 12s is nowhere near the assertion phase and both runs
# quietly SHARE one cluster and both report PASS — the collision hiding behind a
# green. Syncing on a line the tier itself prints is the only way to put the
# second launch inside the window the packet describes: one run's teardown
# landing on the other run's assertions.
#
# WHAT IT REPORTS. Both logs verbatim, both exit codes, and whether the second
# run's launch disturbed the first. Exit status is 0 when both runs passed and 1
# otherwise, so it can be read as a check.
#
# NOT PART OF THE GATE. This brings up two clusters at once on purpose, which is
# the thing the fix exists to stop doing. It is evidence, kept next to the logs
# it produced.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TIER="${1:?usage: collide.sh <tier> <outdir>}"
OUT="${2:?usage: collide.sh <tier> <outdir>}"
SCRIPT="$ROOT/tests/$TIER"

[ -r "$SCRIPT" ] || { printf 'no such tier: %s\n' "$SCRIPT" >&2; exit 2; }
mkdir -p "$OUT"

# The line each tier prints once its cluster is up and it is about to start
# asserting. Derived per tier rather than listed, because a line that does not
# exist is a script that syncs on nothing and reports a collision that never
# happened.
MARKER='== the cluster, provisioned by'

LOG_A="$OUT/$TIER-A.log"
LOG_B="$OUT/$TIER-B.log"

printf '== collide.sh: %s, two concurrent runs\n' "$TIER"

bash "$SCRIPT" >"$LOG_A" 2>&1 &
PID_A=$!

# Wait for A to be PAST bring-up, so B's launch lands inside A's assertions.
waited=0
while ! grep -q "$MARKER" "$LOG_A" 2>/dev/null; do
  if ! kill -0 "$PID_A" 2>/dev/null; then
    printf '== A finished before it printed the marker; nothing to collide with\n'
    wait "$PID_A"; printf '== A exit=%s\n' "$?"
    exit 1
  fi
  sleep 1
  waited=$((waited + 1))
  [ "$waited" -lt 600 ] || { printf '== A never reached the marker in 600s\n' >&2; kill "$PID_A"; exit 1; }
done
printf '== A reached the marker after %ss; launching B now\n' "$waited"

bash "$SCRIPT" >"$LOG_B" 2>&1 &
PID_B=$!

wait "$PID_A"; EC_A=$?
wait "$PID_B"; EC_B=$?
printf '== A exit=%s   B exit=%s\n' "$EC_A" "$EC_B"

# The interference, stated as a fact rather than left in the logs. B's own bring-up
# either failed to start a cluster (it found A's), or it succeeded on top of A's
# namespace and both runs then shared one cluster. Either is the collision.
if [ "$EC_B" -ne 0 ] && grep -qiE 'already in progress|port is already allocated|name .* is already in use' "$LOG_B"; then
  printf '== COLLISION: B could not bring up its own cluster; it collided with A in the shared project namespace\n'
  COLLIDED=1
elif [ "$EC_A" -ne 0 ] || [ "$EC_B" -ne 0 ]; then
  printf '== one or both runs failed; see the logs for whether the cause is the shared namespace\n'
  COLLIDED=1
else
  printf '== both runs passed; they did NOT collide\n'
  COLLIDED=0
fi

printf '== logs: %s %s\n' "$LOG_A" "$LOG_B"
exit "$COLLIDED"