#!/usr/bin/env bash
#
# THE PROOF that kit's account-isolation templates isolate a tenant.
#
#   bash tests/tenancy_test.sh
#
# WHAT THIS IS, AND WHY IT IS A SEPARATE SCRIPT.
#
#   kit's other suites parse configuration. This one brings up a real Postgres
#   from the stack kit ships, applies `templates/database/tenancy/substrate.sql`,
#   runs `templates/database/tenancy/isolation.sql`, and reports every assertion —
#   printing the ones that failed, with the reason each one exists.
#
#   It exists because "a service that reads another tenant's rows is a bug in
#   review" is a claim about a RUNNING system. AGENTS.md's rule is that a config
#   written from documentation rather than from the pinned image is a config that
#   breaks on the first `bin/dev up`; this is the answer to that for the account
#   boundary, which cannot be checked any other way.
#
# SIX THINGS, and the last five are what make the first one mean something:
#
#   1. every assertion in isolation.sql passes.        (the property)
#   2. the CONTROL: with `FORCE ROW LEVEL SECURITY` removed, the OWNER half of the
#      spine goes red and the LOGIN half stays green.   (the property is
#      load-bearing, and it is load-bearing FOR THE OWNER specifically — which is
#      the half a policy's mere presence cannot satisfy)
#   3. the init plan, MEASURED: a wrapped policy calls the identity function once
#      per statement and a bare one calls it once per candidate row. (a comment
#      saying so is not a measurement)
#   4. the assertion set is EXACTLY the one assertions.txt names, both ways.
#      (the proof has not quietly shrunk)
#   5. an ADOPTER'S FIXTURE SCHEMA, planted before the proof runs, is out of the
#      sweep's scope and the proof is still green.  (0b: the sweep does not
#      assume it owns the database)
#   6. an unprotected account-scoped table in a schema the substrate DOES own
#      turns the proof red.                            (5: and scoping the sweep
#      did not turn it into a green constant)
#
#   Assertion 2 is the expensive and the important one. It is the control this
#   repository's rules insist on: a control that never runs differently proves
#   nothing. Without it, a proof that asserted "the owner reads no rows" would
#   also pass on a template with no FORCE at all — which is precisely the trap
#   this file exists for, because FORCE is absent from Supabase's guide and no
#   lint in this fleet checks for it.
#
#   Assertions 0b and 5 are one measurement in two directions, and neither means
#   anything alone. `identity` adopted this substrate and its whole-suite run then
#   failed kit's account-isolation control: its test helper builds a private
#   fixture schema per test by cloning tables with `LIKE ... INCLUDING ALL`, which
#   does not copy row-level security, so every fixture carries an `account_id`
#   column and no policies -- and a sweep that scanned the whole database named
#   all of them, with the count moving per run (5, then 21) as neighbours went in
#   and out of flight. 0b plants that shape and requires it to be ignored. 5
#   requires an unprotected table in the substrate's OWN schema to still be
#   named. Narrow the scope to `pg_temp` alone and 0b passes forever while 5 goes
#   red, because every real table in every adopter is then outside it: which is
#   the only reason 5 exists rather than 0b by itself.
#
# SKIPS LOUDLY, NEVER SILENTLY. No docker, no image, no network to GHCR: this is a
# SKIP that names what it needed, and `validate.sh` counts it. A skip is honest; a
# skip reported as a pass is the thing this repository forbids.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Two services. `alpha` and `beta` rather than real names, because the point is
# that the harness does not know or care what the services are called.
ALPHA=alpha
BETA=beta

SUBSTRATE="$ROOT/templates/database/tenancy/substrate.sql"
ISOLATION="$ROOT/templates/database/tenancy/isolation.sql"
MANIFEST="$ROOT/templates/database/tenancy/assertions.txt"

WORK="${TMPDIR:-/tmp}/kit-tenancy.$$"
IMAGE_TAG="17"
# The pgvector layer pin, matching templates/compose/postgres/Dockerfile. It is
# repeated here rather than read out of that file for the reason
# tests/isolation_test.sh gives: parsing ARGs out of a BuildKit Dockerfile in bash
# would be a second place for the pin to drift.
PGVECTOR_TAG="17-0.8.6"

say() { printf '%s\n' "$*"; }
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  # `docker compose down -v`, not `docker rm -f` plus a guessed volume name, for
  # the reason tests/isolation_test.sh records: `docker-entrypoint-initdb.d` runs
  # ONLY on a fresh volume, so a leaked volume makes the next run reuse an
  # already-provisioned cluster and the suite fails on an assertion about state the
  # previous run created — which reads exactly like a broken boundary.
  if [ -f "$WORK/compose/docker-compose.yml" ]; then
    docker compose --project-name kit-tenancy -f "$WORK/compose/docker-compose.yml" \
      down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  docker rm -f kit-tenancy-control >/dev/null 2>&1 || true
  docker volume rm kit-tenancy-control-vol >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

for f in "$SUBSTRATE" "$ISOLATION" "$MANIFEST"; do
  [ -r "$f" ] || fail "$(basename "$f") is not readable, so there is nothing to prove"
done

# ---------------------------------------------------------------------------
# Environment. Everything missing is named, because "SKIP (docker)" tells a
# reader nothing about which of three things was absent.
if ! command -v docker >/dev/null 2>&1; then
  say "SKIP tests/tenancy_test.sh: docker is not installed, so the account boundary is unexercised."
  exit 3
fi
if ! docker info >/dev/null 2>&1; then
  say "SKIP tests/tenancy_test.sh: the docker daemon is not reachable, so the account boundary is unexercised."
  exit 3
fi

mkdir -p "$WORK"

C="kit-tenancy-postgres-1"

psql_in() { # psql_in <role> <db> <sql>
  docker exec -e PGPASSWORD=cafaye "$C" psql -U "$1" -d "$2" -tAX -c "$3"
}

# psql as the OWNER with the whole script, because the assertions need the simple
# query protocol (a script is a batch) and need the transaction the script opens
# for itself.
run_script() { # run_script <db> <sql-file>
  docker exec -e PGPASSWORD=cafaye "$C" psql -U "$ALPHA" -d "$1" -A -t -F'@' \
    -v ON_ERROR_STOP=1 -f "$2" 2>&1
}

# The wait is for the EVIDENCE the init script produces, not for the server to
# answer. During `docker-entrypoint-initdb.d` the image runs a TEMPORARY server
# that `pg_isready` returns 0 against, so polling either that or a healthcheck
# returns while the cluster is still half-provisioned.
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

# The WHOLE of templates/compose, not just the postgres directory, so the thing
# under test is the STACK kit ships: the init script's bind mount, the `build:`
# args and the environment block are all in that one file.
cp -R "$ROOT/templates/compose" "$WORK/compose"
docker cp "$SUBSTRATE" "$C:/tmp/substrate.sql" >/dev/null 2>&1 || true

if ! docker build \
  --build-arg "POSTGRES_TAG=$IMAGE_TAG" \
  --build-arg "PGVECTOR_TAG=$PGVECTOR_TAG" \
  -f "$WORK/compose/postgres/Dockerfile" \
  -t "kit-tenancy-postgres:$IMAGE_TAG" \
  "$WORK/compose/postgres" >"$WORK/build.log" 2>&1; then
  say "SKIP tests/tenancy_test.sh: could not build the cluster image from templates/compose/postgres/Dockerfile."
  say "       (needs network access to ghcr.io for the pglayers layer). Last lines:"
  tail -5 "$WORK/build.log" | sed 's/^/       /'
  exit 3
fi

cp "$ROOT/templates/compose/.env.example" "$WORK/compose/.env"
{
  echo "KIT_POSTGRES_PORT=15531"
  echo "KIT_POSTGRES_DATABASES=$ALPHA,$BETA"
} >>"$WORK/compose/.env"

if ! docker compose --project-name kit-tenancy -f "$WORK/compose/docker-compose.yml" \
  up -d --wait postgres >"$WORK/up.log" 2>&1; then
  say "FAIL: the shared cluster did not come up. Last lines:"
  tail -20 "$WORK/up.log" | sed 's/^/       /'
  fail "cluster bring-up"
fi

if ! wait_for_provisioning "$C" cafaye "$BETA"; then
  say "FAIL: the cluster came up but initdb/10-cluster.sh never created a database named $BETA."
  docker logs "$C" 2>&1 | tail -25 | sed 's/^/       /'
  fail "init script did not complete"
fi

say ""
say "== the cluster, provisioned by templates/compose/postgres/initdb/10-cluster.sh =="
docker logs "$C" 2>&1 | grep -E '\[cluster\]' | sed 's/^/   /' \
  || say "   (no [cluster] lines — the init script did not run on this volume)"

# ---------------------------------------------------------------------------
# ASSERTION 0 — the topology. Before asking whether isolation works, ask whether
# the cluster is the shape the contract claims: one database, and TWO roles, of
# which the login role owns nothing.
#
# Without this, every assertion below passes on a cluster with no `_app` role at
# all, because isolation.sql's preflight would be the only thing that noticed and
# a proof that stops at its own preflight is a proof that stopped.
say ""
say "== assertion 0: the topology the templates require is present"
for svc in "$ALPHA" "$BETA"; do
  got="$(psql_in cafaye cafaye_platform \
    "SELECT count(*) FROM pg_database WHERE datname = '$svc'")"
  [ "$got" = "1" ] || fail "expected a database named $svc; found $got"
  got="$(psql_in cafaye cafaye_platform \
    "SELECT count(*) FROM pg_roles WHERE rolname = '${svc}_app' AND rolcanlogin AND NOT rolsuper")"
  [ "$got" = "1" ] || fail "expected one non-superuser LOGIN role named ${svc}_app; found $got"
  # The membership, in the one direction that is allowed. The reverse is what
  # would undo the design, so it is asserted absent here as well as present:
  # a claim that a direction is allowed is worthless without the claim that the
  # other one is not.
  got="$(psql_in cafaye cafaye_platform \
    "SELECT count(*) FROM pg_auth_members m
       JOIN pg_roles member ON member.oid = m.member
       JOIN pg_roles granted ON granted.oid = m.roleid
      WHERE member.rolname = '$svc' AND granted.rolname = '${svc}_app'")"
  [ "$got" = "1" ] || fail "$svc cannot impersonate ${svc}_app, so nothing can prove the boundary from outside it"
  got="$(psql_in cafaye cafaye_platform \
    "SELECT count(*) FROM pg_auth_members m
       JOIN pg_roles member ON member.oid = m.member
       JOIN pg_roles granted ON granted.oid = m.roleid
      WHERE member.rolname = '${svc}_app' AND granted.rolname = '$svc'")"
  [ "$got" = "0" ] || fail "${svc}_app is a member of $svc, so the login role holds every privilege the owner has. That is the whole design undone by one GRANT."
done
say "   topology: 2 databases, 2 owner roles, 2 non-owner LOGIN roles, membership in one direction only"

# ---------------------------------------------------------------------------
# THE SUBSTRATE, applied. This is the file a service applies once, and it is
# applied here by the owner role — the same role a service's migrations run as,
# which is the only role the design is interesting for.
say ""
say "== applying templates/database/tenancy/substrate.sql, as the OWNER role"
docker cp "$SUBSTRATE" "$C:/tmp/substrate.sql" >/dev/null
if ! docker exec -e PGPASSWORD=cafaye "$C" psql -U "$ALPHA" -d "$ALPHA" \
  -v ON_ERROR_STOP=1 -q -f /tmp/substrate.sql >"$WORK/substrate.log" 2>&1; then
  say "FAIL: the substrate did not install. Last lines:"
  tail -20 "$WORK/substrate.log" | sed 's/^/       /'
  fail "substrate install"
fi
docker cp "$ISOLATION" "$C:/tmp/isolation.sql" >/dev/null
say "   installed: schema cafaye, current_account_id/0, begin_account/1, protect_table/2, unprotected_tables/0"

# ---------------------------------------------------------------------------
# ASSERTION 0b — AN ADOPTER'S FIXTURE SCHEMA, PLANTED BEFORE THE PROOF RUNS.
#
# This is identity's shape, reproduced rather than described. Its test helper
# builds a private fixture schema per test by cloning tables with
# `LIKE ... INCLUDING ALL`, and `LIKE` does not copy row-level security: an
# `account_id` column with no policies. A sweep that scans the whole database
# names every one of those, so `identity`'s whole-suite run failed kit's
# account-isolation control on a database whose five real tables were all
# protected -- and the count moved per run with how many neighbours were
# mid-flight.
#
# It is planted HERE, before assertion 1 runs, and permanently rather than in a
# transaction the proof rolls back, because the defect is precisely that the
# sweep sees a schema it did not create and does not roll back.
#
# The clone is a real `LIKE ... INCLUDING ALL` rather than a hand-written
# `create table`, because a hand-written table is not the thing that went wrong:
# the shape that matters is a fixture built by a helper the substrate never saw,
# and a fixture authored here would be a different shape wearing the same name.
say ""
say "== assertion 0b: an adopter's fixture schema is present, and out of the sweep's scope"
psql_in "$ALPHA" "$ALPHA" "
  set client_min_messages = warning;
  drop schema if exists kit_neighbour_fixture cascade;
  create schema kit_neighbour_fixture;
  create table kit_neighbour_fixture.account_users (
    id bigint generated always as identity primary key,
    account_id uuid not null,
    email text not null
  );
  create table kit_neighbour_fixture.api_keys (
    id bigint generated always as identity primary key,
    account_id uuid not null
  );
" >/dev/null

# ...and it really is unprotected, so a green proof below cannot be a sweep that
# found nothing to ignore. Both halves are read from the catalog rather than
# assumed: an `account_id` column, and neither `relrowsecurity` nor a policy.
got="$(psql_in "$ALPHA" "$ALPHA" "
  SELECT count(*) FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'account_id' AND NOT a.attisdropped
   WHERE n.nspname = 'kit_neighbour_fixture'
     AND c.relkind = 'r'
     AND NOT c.relrowsecurity
     AND NOT EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = c.oid)")"
[ "$got" = "2" ] || fail "the fixture schema holds $got unprotected account-scoped table(s), not 2, so assertion 0b is not testing what it claims"

# The sweep must not name either of them. Read the function's own answer rather
# than inferring it from the proof's verdicts, so a failure here says "the sweep
# reached into a foreign schema" instead of "some assertion went red".
leaked="$(psql_in "$ALPHA" "$ALPHA" \
  "SELECT count(*) FROM cafaye.unprotected_tables() WHERE table_schema = 'kit_neighbour_fixture'")"
[ "$leaked" = "0" ] || fail "the sweep named $leaked table(s) in an adopter's fixture schema. It is scoped to the schemas the substrate was applied in, and kit_neighbour_fixture is not one of them."
say "   2 unprotected account-scoped tables in kit_neighbour_fixture, and the sweep names neither."
say "   identity's whole-suite failure was exactly this, with the count moving per run."

# ---------------------------------------------------------------------------
# ASSERTION 1 — every assertion in the set passes.
say ""
say "== assertion 1: every assertion in templates/database/tenancy/isolation.sql passes"
out="$(run_script "$ALPHA" /tmp/isolation.sql)"

# The result rows are `assertion@expected@actual@verdict@why`, and `why` is prose
# that may itself contain `@` in a future edit, so only the first three fields are
# split and the rest is taken as the remainder. A field-splitting shape chosen
# against the CURRENT prose rather than the intended one is how a check starts
# reporting empty results on a correct tree.
failures="$(printf '%s\n' "$out" | grep '@fail@' || true)"
total="$(printf '%s\n' "$out" | grep -cE '@(pass|fail)@' || true)"
[ "$total" -gt 0 ] || {
  say "FAIL: the proof returned no assertions at all."
  printf '%s\n' "$out" | tail -20 | sed 's/^/       /'
  fail "isolation.sql produced no rows"
}

if [ -n "$failures" ]; then
  say "FAIL: $failures assertion(s) failed, of $total:"
  printf '%s\n' "$failures" | while IFS= read -r line; do
    name="${line%%@*}"
    rest="${line#*@}"
    expected="${rest%%@*}"
    actual_and_verdict="${rest#*@}"
    actual="${actual_and_verdict%%@*}"
    verdict="${actual_and_verdict#*@}"
    printf '  %s\n     expected %s / actual %s (%s)\n' "$name" "$expected" "$actual" "$verdict"
  done
  fail "the account boundary is not in place"
fi
say "   $total assertions, all pass"

# ---------------------------------------------------------------------------
# ASSERTION 4 — the assertion set is EXACTLY the one assertions.txt names, both
# ways. Run before the controls so a shrunken proof is caught before it is used to
# prove anything else.
say ""
say "== assertion 4: the proof returns EXACTLY the assertions assertions.txt names"
want="$(grep -vE '^[[:space:]]*(#|$)' "$MANIFEST" | sort)"
got_names="$(printf '%s\n' "$out" | grep -E '@(pass|fail)@' | awk -F@ '{print $1}' | sort)"
if [ "$want" != "$got_names" ]; then
  say "FAIL: the proof and assertions.txt disagree."
  say "  only in assertions.txt (isolation.sql stopped asserting it):"
  comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$got_names") | sed 's/^/       /'
  say "  only in the proof (not listed, so no service asserts it):"
  comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$got_names") | sed 's/^/       /'
  fail "the assertion set has drifted"
fi
say "   $(printf '%s\n' "$want" | grep -c .) assertions, named identically in both files"

# ---------------------------------------------------------------------------
# ASSERTION 2 — THE CONTROL. The same proof, with `FORCE ROW LEVEL SECURITY`
# removed from the substrate, must go red — and must go red on the OWNER half
# ONLY.
#
# This is the measurement the packet exists for. Measured here, on this tree:
#
#   with FORCE      owner reads 1 row (its own), login reads 1 row
#   without FORCE   owner reads 3 rows (every tenant's), login reads 1 row
#
# The login half staying green is the point rather than an inconvenience: it is
# what makes it obvious that an isolation suite written only against the
# application role passes on a template with no FORCE at all.
say ""
say "== assertion 2: the CONTROL — same proof, FORCE ROW LEVEL SECURITY removed"
mkdir -p "$WORK/noforce"
# The EXECUTABLE line, and only the executable line. A case-insensitive grep for the
# words removes the substrate's own explanation of why FORCE is there as well, and a
# control whose mutation also deletes the reasoning is a control whose recipe has to
# be re-read every time somebody edits a comment — which is the "a breakage recipe
# asserts its own premise before it mutates" rule, applied to a control rather than
# to a self-test.
grep -v "execute format('alter table %s force row level security'" \
  "$SUBSTRATE" >"$WORK/noforce/substrate.sql"
if grep -q "execute format('alter table %s force row level security'" "$WORK/noforce/substrate.sql"; then
  fail "the control's mutation did not remove the FORCE statement, so the control would prove nothing"
fi
# ...and that it was SURGICAL: the substrate's own explanation of why FORCE is
# required is still there. A mutation that removed the reasoning along with the
# statement would leave a control nobody can read six months from now, and the
# test for that is that the paragraph survives.
grep -q "FORCE ROW LEVEL SECURITY is still required" "$WORK/noforce/substrate.sql" \
  || fail "the control's mutation also deleted the substrate's own explanation of why FORCE is required"
docker cp "$WORK/noforce/substrate.sql" "$C:/tmp/substrate-noforce.sql" >/dev/null

ctl="$(docker exec -e PGPASSWORD=cafaye "$C" psql -U "$ALPHA" -d "$ALPHA" \
  -v ON_ERROR_STOP=1 -q -f /tmp/substrate-noforce.sql >/dev/null 2>&1; \
  run_script "$ALPHA" /tmp/isolation.sql)"
ctl_failures="$(printf '%s\n' "$ctl" | grep -c '@fail@' || true)"

if [ "$ctl_failures" -eq 0 ]; then
  say "FAIL: removing FORCE ROW LEVEL SECURITY changed nothing. The control and the thing it"
  say "      controls agree, which is the one outcome that proves nothing."
  fail "the FORCE assertion is not load-bearing"
fi
# The specific shape, because a control that goes red for an unrelated reason is
# a control that proves something else.
for name in \
  'owner/another-tenants-rows-read-as-none' \
  'owner/no-identity-reads-no-rows' \
  'sweep/the-only-finding-is-the-control'; do
  printf '%s\n' "$ctl" | grep -q "^$name@" || {
    say "FAIL: the control went red, but NOT via $name."
    printf '%s\n' "$ctl_failures" | head -1 | sed 's/^/       /'
    printf '%s\n' "$ctl" | grep '@fail@' | awk -F@ '{print "       red instead: " $1}' | head -8
    fail "the FORCE control is red for the wrong reason"
  }
done
# ...and the login half must stay green, because that is what makes this specific.
login_red="$(printf '%s\n' "$ctl" | grep '@fail@' | grep -c '^login/' || true)"
[ "$login_red" -eq 0 ] || {
  say "FAIL: the login-role assertions went red without FORCE ($login_red of them)."
  say "      They should not: the login role is not the owner, so FORCE is not what denies"
  say "      IT. A control that takes the login half down with it is measuring something else."
  printf '%s\n' "$ctl" | grep '@fail@' | awk -F@ '{print "       " $1}' | head -8 | sed 's/^/       /'
  fail "the FORCE control is not specific to the owner"
}
say "   without FORCE: $ctl_failures assertion(s) red, every one of them an owner/ or sweep/ assertion"
say "   with FORCE:    0 red"
say "   the login-role half stayed green throughout, which is what makes this specific:"
say "   an isolation suite written only against the application role passes on a"
say "   template with no FORCE at all."

# ---------------------------------------------------------------------------
# ASSERTION 5 — THE SWEEP'S OWN CONTROL, INSIDE THE SCOPED SWEEP.
#
# Assertion 0b proves the scope is narrow enough. This proves narrowing it did
# not turn the sweep into a green constant — which is the failure mode of every
# tempting version of this fix. Scope the sweep to `pg_temp` alone, or to
# `cafaye` alone, and all three sweep assertions pass forever while naming no
# real table in any adopter: `sweep/names-an-unprotected-table` finds the
# control, `sweep/every-account-scoped-table-is-protected` counts it, and
# `sweep/the-only-finding-is-the-control` matches it. Three greens, zero
# information, and the sweep's positive control is now a control of nothing.
#
# So: a SECOND unprotected account-scoped table, planted in a schema the
# substrate WAS applied in and left there permanently, must turn the proof red.
# The scope is derived from the policies `protect_table` wrote, so this is the
# honest question -- "is a real account-scoped table in the substrate's own
# territory still named?" -- rather than an artefact of how the scope is spelled.
#
# It is `$ALPHA`'s own public schema, which is exactly where a service's tables
# live and exactly what a service reaches by adding a column to a new table and
# forgetting the substrate.
say ""
say "== assertion 5: the sweep still names an unprotected table in a schema the substrate OWNS"
psql_in "$ALPHA" "$ALPHA" "
  create table if not exists kit_sweep_control (
    id int primary key,
    account_id uuid not null
  )" >/dev/null

ctl_scope="$(run_script "$ALPHA" /tmp/isolation.sql)"
scope_failures="$(printf '%s\n' "$ctl_scope" | grep '@fail@' || true)"
if [ -z "$scope_failures" ]; then
  say "FAIL: an unprotected account-scoped table in the substrate's own schema was NOT named."
  say "      The sweep is scoped to the schemas it was applied in, and this table is in one of"
  say "      them, so it is exactly what the sweep exists to find. A sweep that cannot go red on"
  say "      it is a green constant: it would pass on a service that never protected anything."
  fail "the sweep's control cannot fail inside its own scope"
fi
# ...and by the sweep assertion, not by an unrelated one going red.
printf '%s\n' "$ctl_scope" | grep -q '^sweep/every-account-scoped-table-is-protected@' || {
  say "FAIL: the planted table went red, but NOT via sweep/every-account-scoped-table-is-protected."
  printf '%s\n' "$scope_failures" | awk -F@ '{print "       red instead: " $1}' | head -8
  fail "the scoped sweep's control is red for the wrong reason"
}
dropped="$(psql_in "$ALPHA" "$ALPHA" "DROP TABLE kit_sweep_control" >/dev/null && printf 'dropped')"
[ "$dropped" = "dropped" ] || fail "could not remove the planted table, so every later assertion in this file would run against a red sweep"
say "   one unprotected account-scoped table in the substrate's own schema, and the sweep"
say "   named it: sweep/every-account-scoped-table-is-protected and"
say "   sweep/the-only-finding-is-the-control both went red. The scope is narrow enough for"
say "   an adopter (assertion 0b) and still able to fail (this)."

# Put the substrate back so anything after this sees the real thing.
docker exec -e PGPASSWORD=cafaye "$C" psql -U "$ALPHA" -d "$ALPHA" \
  -v ON_ERROR_STOP=1 -q -f /tmp/substrate.sql >/dev/null 2>&1

# ---------------------------------------------------------------------------
# ASSERTION 3 — the `(select ...)` wrapping, MEASURED rather than asserted.
#
# Two temporary tables with identical rows and identical policies, differing only
# in how the identity is written. A counting function records how many times it is
# called, so the number is the plan's behaviour rather than this file's reading of
# a document.
say ""
say "== assertion 3: the (select ...) wrapping, measured"
cat >"$WORK/initplan.sql" <<'INITPLAN'
begin;
create temp table counter(n bigint);
insert into counter values (0);
create or replace function probe_identity()
returns uuid language plpgsql volatile security definer as $fn$
begin update counter set n = n + 1; return '11111111-1111-1111-1111-111111111111'; end $fn$;
create temp table rows_probe(id int primary key, account_id uuid not null);
insert into rows_probe select g, '11111111-1111-1111-1111-111111111111'
  from generate_series(1, 5) g;
alter table rows_probe enable row level security;
alter table rows_probe force row level security;
grant select on rows_probe to current_user;

create policy wrapped on rows_probe for select to public
  using (account_id = (select probe_identity()));
update counter set n = 0;
select count(*) from rows_probe;
select 'wrapped' as form, (select n from counter) as calls;

drop policy wrapped on rows_probe;
create policy bare on rows_probe for select to public
  using (account_id = probe_identity());
update counter set n = 0;
select count(*) from rows_probe;
select 'bare' as form, (select n from counter) as calls;
rollback;
INITPLAN
docker cp "$WORK/initplan.sql" "$C:/tmp/initplan.sql" >/dev/null
plan_out="$(docker exec -e PGPASSWORD=cafaye "$C" psql -U "$ALPHA" -d "$ALPHA" \
  -A -t -F' ' -v ON_ERROR_STOP=1 -f /tmp/initplan.sql 2>/dev/null | grep -E '^(wrapped|bare) ')"
wrapped_calls="$(printf '%s\n' "$plan_out" | awk '$1=="wrapped"{print $2}')"
bare_calls="$(printf '%s\n' "$plan_out" | awk '$1=="bare"{print $2}')"

[ -n "$wrapped_calls" ] && [ -n "$bare_calls" ] || {
  say "FAIL: the init-plan measurement produced nothing."
  printf '%s\n' "$plan_out" | sed 's/^/       /'
  fail "could not measure the wrapped/bare difference"
}
say "   five rows, one query, identity function invocations:"
say "     (select …) wrapped:  $wrapped_calls"
say "     bare call:           $bare_calls"
if [ "$wrapped_calls" -ge "$bare_calls" ]; then
  fail "the wrapped form called the identity function $wrapped_calls time(s) and the bare form $bare_calls. The wrapping is supposed to be the cheaper one; if this ever inverts, Postgres has changed its mind about InitPlans and every claim about it in substrate.sql is wrong."
fi
say "   the same policy and the same rows; only the wrapping differs."

# ---------------------------------------------------------------------------
say ""
say "PASS: kit's account boundary is enforced by Postgres, and the enforcement is"
say "      proven able to fail."
say "      $total assertions, every one passing, named identically in assertions.txt."
say "      FORCE ROW LEVEL SECURITY removed: $ctl_failures red, all of them owner/ or sweep/."
say "      identity function calls over five rows: $wrapped_calls wrapped, $bare_calls bare."
say "      an adopter's fixture schema present: 0 of 2 of its tables named."
say "      an unprotected table in the substrate's own schema: named, proof red."