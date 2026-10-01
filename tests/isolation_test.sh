#!/usr/bin/env bash
#
# THE PROOF that one cluster, database-per-service, actually isolates.
#
#   bash tests/isolation_test.sh
#
# WHAT THIS IS, AND WHY IT IS A SEPARATE SCRIPT.
#
#   kit's other suites parse configuration. This one brings up a real Postgres
#   from the stack kit ships, creates two service databases and two service
#   roles, and then asserts that service A is refused at the door of service B's
#   database — printing the query that was refused and the server's answer.
#
#   It exists because "a service that reaches into another's database is a bug
#   in review, not a config problem to solve here" is a claim about a *running*
#   system, and the compose file asserting the right words proves nothing about
#   whether Postgres honours them. AGENTS.md's rule is that a config written from
#   documentation rather than from the pinned image is a config that breaks on
#   the first `bin/dev up`; this file is the answer to that for the one property
#   that cannot be checked any other way.
#
# FOUR ASSERTIONS, and the last three are what make the first one mean something:
#
#   1. A reaches its own database.                     (positive control)
#   2. A is refused B's database, with the query and the server's answer.
#   3. B is refused A's database.                     (not one lucky direction)
#   4. A is refused on a SECOND cluster built WITHOUT the REVOKE, and gets in.
#      (negative control — proves assertion 2 is load-bearing)
#
#   Assertion 4 is the expensive one, and it is the one this repository's rules
#   insist on: a control that never runs differently proves nothing. Without it,
#   a check that asserted "A cannot read B" would also pass on a cluster with no
#   boundary at all, because the table grants would refuse the SELECT anyway.
#
# SKIPS LOUDLY, NEVER SILENTLY. No docker, no image, no network to GHCR: this is
# a SKIP that names what it needed, and `validate.sh` counts it. A skip is
# honest; a skip reported as a pass is the thing this repository forbids.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Two services. `alpha` and `beta` rather than real names, because the point is
# that the harness does not know or care what the services are called.
ALPHA=alpha
BETA=beta

# Where the state goes. A named container and a named volume rather than
# `docker run --rm`, because assertion 4 needs a SECOND cluster that survives
# long enough to be queried and the first one has to still exist.
WORK="${TMPDIR:-/tmp}/kit-isolation.$$"
IMAGE_TAG="17"
# The pgvector layer pin, matching templates/compose/postgres/Dockerfile. It is
# repeated here rather than read out of that file because the file is a
# Dockerfile for BuildKit and parsing ARGs out of it in bash would be a second
# place for the pin to drift — which is the same defect as the .env.example
# version skew this packet fixes. `tests/validate.sh` asserts the two agree.
PGVECTOR_TAG="17-0.8.6"

say() { printf '%s\n' "$*"; }
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  # `docker compose down -v`, not `docker rm -f` plus a guessed volume name.
  #
  # This was a real bug and it is worth naming: the first version removed
  # containers and two volumes it had named itself, and missed the one that
  # mattered. `docker-entrypoint-initdb.d` runs ONLY on a fresh volume, so the
  # second run of the suite reused an already-provisioned cluster, the init
  # script never ran, and the suite failed on an assertion about a database that
  # the previous run had created — which reads exactly like a broken boundary and
  # is in fact a leaked volume.
  #
  # `down -v` is what removes the project volume AND the project network, and it
  # derives the volume name from the project name rather than from a string
  # duplicated here.
  if [ -f "$WORK/compose/docker-compose.yml" ]; then
    docker compose --project-name kit-isolation -f "$WORK/compose/docker-compose.yml" \
      down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  docker rm -f kit-isolation-control >/dev/null 2>&1 || true
  docker volume rm kit-isolation-control-vol >/dev/null 2>&1 || true
  # The image is shared between runs and rebuilds in seconds from cache, so it is
  # deliberately NOT removed: removing it would make every run pay a full pull.
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Environment. Everything missing is named, because "SKIP (docker)" tells a
# reader nothing about which of three things was absent.
if ! command -v docker >/dev/null 2>&1; then
  say "SKIP tests/isolation_test.sh: docker is not installed, so the shared-cluster boundary is unexercised."
  exit 3
fi
if ! docker info >/dev/null 2>&1; then
  say "SKIP tests/isolation_test.sh: the docker daemon is not reachable, so the shared-cluster boundary is unexercised."
  exit 3
fi

mkdir -p "$WORK"

# The container name compose derives: <project>-<service>-<index>. Defined here,
# before the first use, because `set -u` treats a shell variable that is read
# before it is assigned as fatal — and the wait below needs it.
C="kit-isolation-postgres-1"

# psql_in <role> <db> <sql>
psql_in() {
  docker exec -e PGPASSWORD=cafaye "$C" psql -U "$1" -d "$2" -tAX -c "$3"
}

# Wait for the INIT SCRIPT to finish, not for the server to answer.
#
# This is the trap kit's own compose healthcheck comment records, reached from
# the other direction. During `docker-entrypoint-initdb.d` the image runs a
# TEMPORARY server: `pg_isready` returns 0 against it, and `docker compose up
# --wait` is satisfied by the healthcheck, which is a query against a database
# that exists before the first init statement runs. Polling either of those
# returns while the cluster is still half-provisioned — and this suite's control
# cluster failed exactly that way, reporting "database beta does not exist",
# because it asked a question two statements too early.
#
# So the wait is for the EVIDENCE the script produces: the database has to exist.
# Bounded, and it reports which condition never became true rather than hanging.
wait_for_provisioning() { # wait_for_provisioning <container> <role> <db>
  local container="$1" role="$2" db="$3" out
  for _ in $(seq 1 90); do
    out="$(docker exec -e PGPASSWORD=cafaye "$container" \
      psql -U "$role" -d cafaye_platform -tAX -c \
      "SELECT count(*) FROM pg_database WHERE datname = '$db'" 2>/dev/null || true)"
    if [ "$out" = "1" ]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# The WHOLE of templates/compose, not just the postgres directory.
# The point of bringing this up through compose rather than `docker run` is that
# the thing under test is the STACK kit ships: the init script's bind mount, the
# `build:` args and the environment block are all in that one file, and a test
# that re-declared them here would be testing the copy. Compose validates the
# whole document even when only `postgres` is started, so the vendor config
# directories have to be present too.
cp -R "$ROOT/templates/compose" "$WORK/compose"

# Build the cluster image ONCE, exactly as the compose file builds it. If this
# cannot build — no network to ghcr.io, a moved pin — the whole test is a SKIP
# naming the build failure, never a pass.
if ! docker build \
  --build-arg "POSTGRES_TAG=$IMAGE_TAG" \
  --build-arg "PGVECTOR_TAG=$PGVECTOR_TAG" \
  -f "$WORK/compose/postgres/Dockerfile" \
  -t "kit-isolation-postgres:$IMAGE_TAG" \
  "$WORK/compose/postgres" >"$WORK/build.log" 2>&1; then
  say "SKIP tests/isolation_test.sh: could not build the cluster image from templates/compose/postgres/Dockerfile."
  say "       (needs network access to ghcr.io for the pglayers layer). Last lines:"
  tail -5 "$WORK/build.log" | sed 's/^/       /'
  exit 3
fi

# Start the stack the way `bin/dev` does: the shipped compose file, the init
# script mounted from the tree, and the service names declared in .env.
#
# The port and the database list are overridden because this suite must not
# collide with a developer's own running stack. It moves the port in `.env`
# rather than in an override, which is exactly what AGENTS.md prescribes — and
# note that compose APPENDS a second file's `ports:` list rather than replacing
# it, so an override here would publish postgres on kit's port as well.
cp "$ROOT/templates/compose/.env.example" "$WORK/compose/.env"
{
  echo "KIT_POSTGRES_PORT=15521"
  echo "KIT_POSTGRES_DATABASES=$ALPHA,$BETA"
  echo "KIT_POSTGRES_EXTENSIONS=vector"
} >>"$WORK/compose/.env"

if ! docker compose --project-name kit-isolation -f "$WORK/compose/docker-compose.yml" \
  up -d --wait postgres >"$WORK/up.log" 2>&1; then
  say "FAIL: the shared cluster did not come up. Last lines:"
  tail -20 "$WORK/up.log" | sed 's/^/       /'
  fail "cluster bring-up"
fi

# `--wait` is necessary and not sufficient — see wait_for_provisioning.
if ! wait_for_provisioning "$C" cafaye "$BETA"; then
  say "FAIL: the cluster came up but initdb/10-cluster.sh never created a database named $BETA."
  say "      Container log:"
  docker logs "$C" 2>&1 | tail -25 | sed 's/^/       /'
  fail "init script did not complete"
fi

say ""
say "== the cluster, provisioned by templates/compose/postgres/initdb/10-cluster.sh =="
# `|| true` and a message rather than a bare grep: this is informational, and
# under `set -o pipefail` an empty grep result — a cluster that provisioned
# nothing, because the volume was reused — would take the whole script down
# before it reached the assertions that would have explained why.
docker logs "$C" 2>&1 | grep -E '\[cluster\]' | sed 's/^/   /' \
  || say "   (no [cluster] lines — the init script did not run on this volume)"

# ---------------------------------------------------------------------------
# ASSERTION 0 — the topology itself. Before asking whether isolation works, ask
# whether the cluster is the shape the contract claims: one database and one
# non-superuser role per service, and the extension present in each.
#
# Without this, assertions 1 and 2 pass on a cluster that has no `beta` database
# at all, because a connection to a database that does not exist is also refused.
# That is the "assert the agreement, not the presence" rule applied to a running
# system: the refusal in assertion 2 has to be attributable to the boundary and
# not to a missing database.
for svc in "$ALPHA" "$BETA"; do
  got="$(psql_in cafaye cafaye_platform \
    "SELECT count(*) FROM pg_database WHERE datname = '$svc'")"
  [ "$got" = "1" ] || fail "expected a database named $svc; found $got"
  got="$(psql_in cafaye cafaye_platform \
    "SELECT count(*) FROM pg_roles WHERE rolname = '$svc' AND NOT rolsuper")"
  [ "$got" = "1" ] || fail "expected one non-superuser role named $svc; found $got"
  got="$(psql_in cafaye cafaye_platform \
    "SELECT count(*) FROM pg_roles WHERE rolname = '$svc' AND rolconnlimit > 0")"
  [ "$got" = "1" ] || fail "$svc has no per-role CONNECTION LIMIT; blast radius is unbounded"
done
say "   topology: 2 databases, 2 non-superuser roles, both with a per-role connection limit"

# The extension, in each database. A real vector query rather than a count, for
# the reason AGENTS.md gives about vendor configs: `CREATE EXTENSION` succeeding
# and the extension working are different claims.
for svc in "$ALPHA" "$BETA"; do
  got="$(psql_in cafaye "$svc" \
    "SELECT '[1,2,3]'::vector <=> '[1,2,4]'::vector < 1")"
  [ "$got" = "t" ] || fail "$svc: pgvector is not answering a real query (got '$got')"
done
say "   pgvector: a real similarity query answers in both databases"

# ---------------------------------------------------------------------------
# ASSERTION 1 — the positive control. A reaches its own database and can write.
say ""
say "== assertion 1: $ALPHA reaches its OWN database =="
psql_in "$ALPHA" "$ALPHA" \
  "CREATE TABLE IF NOT EXISTS deliveries(id int)" >/dev/null
psql_in "$ALPHA" "$ALPHA" \
  "INSERT INTO deliveries VALUES (1) ON CONFLICT DO NOTHING" >/dev/null
own="$(psql_in "$ALPHA" "$ALPHA" "SELECT count(*) FROM deliveries")"
[ "$own" = "1" ] || fail "$ALPHA wrote $own rows into its own database, expected 1"
say "   $ALPHA wrote 1 row into its own database"

# ---------------------------------------------------------------------------
# ASSERTION 2 — the isolation, with the failing query printed.
#
# The query is printed BEFORE it runs, and so is the server's answer, because the
# value of this test is a reader being able to see exactly what was refused. An
# assertion that reports "cross-database read refused: PASS" is a claim; the
# command and the error message are the evidence.
say ""
say "== assertion 2: $ALPHA must NOT read $BETA's database =="
readonly CROSS_QUERY="SELECT * FROM deliveries;"
say "   \$ psql -U $ALPHA -d $BETA -c \"$CROSS_QUERY\""
cross_out="$(psql_in "$ALPHA" "$BETA" "$CROSS_QUERY" 2>&1)" && cross_ec=0 || cross_ec=$?
printf '%s\n' "$cross_out" | sed 's/^/   /'
say "   psql exit: $cross_ec"

[ "$cross_ec" -ne 0 ] || fail "$ALPHA READ $BETA's database. Isolation is not in place."
case "$cross_out" in
  *'permission denied for database'*) ;;
  *) fail "$ALPHA was refused, but not by the database boundary: $cross_out" ;;
esac
say "   REFUSED at the door: permission denied for database \"$BETA\""

# ---------------------------------------------------------------------------
# ASSERTION 3 — the other direction. One direction could be an accident: a
# mis-ordered provisioning loop, or a database that simply was never created.
say ""
say "== assertion 3: $BETA must NOT read $ALPHA's database either =="
back_out="$(psql_in "$BETA" "$ALPHA" "$CROSS_QUERY" 2>&1)" && back_ec=0 || back_ec=$?
printf '%s\n' "$back_out" | sed 's/^/   /'
[ "$back_ec" -ne 0 ] || fail "$BETA READ $ALPHA's database. Isolation is one-directional."
case "$back_out" in
  *'permission denied for database'*) ;;
  *) fail "refused, but not by the database boundary: $back_out" ;;
esac
say "   REFUSED at the door: permission denied for database \"$ALPHA\""

# And PUBLIC itself, which is the mechanism rather than one of its symptoms. If
# this is the only row that says true, the boundary is not being applied by
# construction and is relying on the grant list above it.
leaks="$(psql_in cafaye cafaye_platform \
  "SELECT string_agg(datname, ',') FROM pg_database
    WHERE NOT datistemplate AND has_database_privilege('public', datname, 'CONNECT')")"
[ -z "$leaks" ] || fail "PUBLIC still holds CONNECT on: $leaks. The boundary is not exhaustive."
say ""
say "   PUBLIC holds CONNECT on no database in the cluster (including 'postgres')"

# ---------------------------------------------------------------------------
# ASSERTION 4 — THE NEGATIVE CONTROL. The same query, on a cluster of the same
# shape with the REVOKE removed, must SUCCEED at reaching the database.
#
# This is the assertion that makes assertion 2 mean something, and it is here
# because of the rule AGENTS.md states about allowlists and this repository
# applies to proofs: an assertion that cannot be shown to fail is not known to be
# load-bearing. Measured, the difference between the two clusters is:
#
#   with the REVOKE:     FATAL: permission denied for database "beta"
#   without it:          the connection succeeds; only the SELECT on `beta`'s
#                        table is refused, because nobody granted it
#
# So a check that asserted only "A cannot SELECT from B's table" would pass on a
# cluster with NO isolation at all. That is why the boundary asserted here is the
# CONNECT revoke and not the table grant, and why this control exists.
say ""
say "== assertion 4: the CONTROL — same shape, REVOKE removed =="
mkdir -p "$WORK/norevoke"
cat >"$WORK/norevoke/10-norevoke.sh" <<'CONTROL'
# The same provisioning, minus the boundary. Roles and databases, no REVOKE.
set -e
for db in "$KIT_ALPHA" "$KIT_BETA"; do
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 \
    -c "CREATE ROLE $db LOGIN PASSWORD '$POSTGRES_PASSWORD'" >/dev/null
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 \
    -c "CREATE DATABASE $db OWNER $db" >/dev/null
done
psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 \
  -c "CREATE TABLE IF NOT EXISTS deliveries(id int)" >/dev/null
psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 \
  -c "INSERT INTO deliveries VALUES (1)" >/dev/null
psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 \
  -c "GRANT ALL ON SCHEMA public TO $KIT_BETA" >/dev/null
psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 \
  -c "GRANT SELECT ON ALL TABLES IN SCHEMA public TO $KIT_BETA" >/dev/null
CONTROL

docker rm -f kit-isolation-control >/dev/null 2>&1 || true
docker volume rm kit-isolation-control-vol >/dev/null 2>&1 || true
docker run -d --name kit-isolation-control \
  -e POSTGRES_PASSWORD=cafaye -e POSTGRES_USER=cafaye -e POSTGRES_DB=cafaye_platform \
  -e KIT_ALPHA="$ALPHA" -e KIT_BETA="$BETA" \
  -v "$WORK/norevoke/10-norevoke.sh:/docker-entrypoint-initdb.d/10-norevoke.sh:ro" \
  -v kit-isolation-control-vol:/var/lib/postgresql/data \
  "kit-isolation-postgres:$IMAGE_TAG" >/dev/null

for _ in $(seq 1 90); do
  docker exec kit-isolation-control pg_isready -q -U cafaye -d cafaye_platform 2>/dev/null \
    || { sleep 1; continue; }
  # pg_isready is satisfied by the TEMPORARY server the entrypoint runs during
  # initdb, so it is only the first half of the wait. The second half is the
  # database this control needs to have created.
  if wait_for_provisioning kit-isolation-control cafaye "$BETA"; then
    break
  fi
  sleep 1
done

if ! wait_for_provisioning kit-isolation-control cafaye "$BETA"; then
  say "FAIL: the control cluster never provisioned a database named $BETA."
  docker logs kit-isolation-control 2>&1 | tail -20 | sed 's/^/       /'
  fail "control cluster did not come up"
fi

ctl_connect="$(docker exec -e PGPASSWORD=cafaye kit-isolation-control \
  psql -U "$ALPHA" -d "$BETA" -tAX -c 'SELECT current_database()' 2>&1)" \
  && ctl_ec=0 || ctl_ec=$?
say "   \$ psql -U $ALPHA -d $BETA -c 'SELECT current_database()'   (no REVOKE applied)"
printf '%s\n' "$ctl_connect" | sed 's/^/   /'
say "   psql exit: $ctl_ec"

if [ "$ctl_ec" -ne 0 ]; then
  fail "the control cluster REFUSED the connection too. The two clusters are supposed to differ, and a control that agrees with the thing it controls proves nothing. Check that the control really omits the REVOKE."
fi
[ "$ctl_connect" = "$BETA" ] || fail "control connected somewhere unexpected: $ctl_connect"
say "   the control cluster let $ALPHA INTO $BETA's database — so assertion 2 is load-bearing,"
say "   and the difference between the two clusters is the REVOKE, not the table grants."

docker rm -f kit-isolation-control >/dev/null 2>&1 || true
docker volume rm kit-isolation-control-vol >/dev/null 2>&1 || true

say ""
say "PASS: one cluster, one database and one role per service, and the database is the boundary."
say "      $ALPHA -> $BETA refused: permission denied for database \"$BETA\" (exit 2)"
say "      $BETA -> $ALPHA refused: permission denied for database \"$ALPHA\""
say "      control without the REVOKE: allowed in, which is what makes the refusals above mean something."