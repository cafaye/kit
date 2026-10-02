# DECISIONS.md — the trades this repository has **not** made

> A decision document records what was **deliberately not done**, and what it
> costs. Anything here is reversible, and saying so is the point: a trade with no
> stated cost is a preference someone will re-litigate in six months with no
> evidence.

**Referenced from** `AGENTS.md`, `README.md`, `.github/zizmor.yml`,
`.github/workflows/ci.reusable.yml`, and three of the gate's own scripts. It did
not exist until kit-21, and every one of those references pointed at nothing. A
reference to a decision document that is not there tells the reader the trade was
made and then leaves them with nothing to read, which is worse than not claiming
it — the absence looks like they have not looked hard enough.
`tests/validate.sh`'s `DECISIONS.md` check asserts the file exists, records real
entries, and that every reference to it resolves.

---

## MD10 — `unpinned-uses` is counted, not baselined

**Not made:** adding zizmor's `unpinned-uses` finding to `.github/zizmor.yml`'s
ignore list, which is the one-line change that would make the finding disappear.

**What it costs:** thirty-three findings on every run, every time. They are
counted and printed by `tests/zizmor_gate.sh`, never suppressed.

**Why not:** a baseline is a trade made invisibly, in a file that looks like
routine configuration. Pinning thirteen repositories to SHAs and owning the bump
is not free — the diff would be about the pin, not about the thing the pin is
for — and *not* pinning means a change to kit's workflow lands in six services'
CI without review. Both are real costs. The trade-off is a decision, and a
decision belongs in this file rather than in a config key.

**Enforced by:** `tests/validate.sh`'s `unpinned_check`, which fails if
`unpinned-uses` is ever disabled, and `zizmor_reason_check`, which fails if any
ignore entry appears without a reason beside it.

---

## MD10a — no fleet-wide SHA pinning (superseded by MD10)

Recorded because kit-04 costed it in three options under this heading and the
surviving decision is MD10. Kept so a reader looking for the original reasoning
finds it rather than a dangling reference.

---

## MD12 — no second copy of the reusable workflow

**Not made:** mirroring `.github/workflows/ci.reusable.yml` at a convenient
subpath so the `uses:` string reads nicely.

**What it costs:** nothing, and that is the argument. GitHub documents that
subdirectories of the workflows directory are not supported, so
`cafaye/kit/workflows/ci.reusable.yml@master` resolves to nothing and every
caller who copied it has a red build. The file lives where GitHub can call it.

**Enforced by:** the `callable path` check in `tests/validate.sh`, which fails
when the documented `uses:` string and the file's real location disagree.

---

## MD13 — one secret scanner, invoked two ways

**Not made:** a CI-only invocation with a local convenience wrapper that drifted
from it.

**What it costs:** nothing measurable.

**Why not:** a scanner whose CI invocation and local invocation have drifted is
two scanners, and the one that goes red is whichever nobody runs. `tests/
validate.sh` and `tests/gitleaks_gate.sh` are the same script for this reason.

---

## MD21 — **no PgBouncer. One cluster, direct connections, a stated budget.**

This is the trade kit-21 was dispatched to decide, and it is the largest one in
this file.

**Not made:** putting PgBouncer in transaction mode between the fleet and the
shared cluster.

**What it costs:**

- Nine services' connections all land on one server, so a memory-hungry backend
  in one service is a memory-hungry backend on the box. Mitigated by a per-role
  `CONNECTION LIMIT` and per-role timeouts, not prevented.
- The connection budget is a real ceiling: 200 `max_connections`, 10 per role. A
  service that genuinely needs more must raise its share in **two** places and
  say why in the PR.
- No multiplexing. A service with 3 concurrent requests and a pool of 10 holds
  connections it is not using. Free at this scale; not free at ten times it.
- We lose the standard safety valve for connection storms. If the fleet outgrows
  the budget, the answer is a pooler **plus** the per-language flags **plus** the
  `RECONNECT` step — a much bigger decision than it looks today.

**Why not, with the measurements:**

1. **The remedy for the pooler's worst failure mode is a manual operator
   command.** From PgBouncer's own configuration documentation, on
   `max_prepared_statements` (<https://www.pgbouncer.org/config.html>):

   > If the return or argument types of a prepared statement changes across
   > executions then PostgreSQL currently throws an error such as
   > `ERROR: cached plan must not change result type` … One of the most common
   > ways of running into this issue is during a DDL migration where you add a
   > new column or change a column type on an existing table. In those cases you
   > can run `RECONNECT` on the PgBouncer admin console after doing the migration
   > to force a re-prepare of the query and make the error go away.

   A migration is the single most common time this fires. Nine services, nine
   independent migration schedules, one forgotten console command each — and the
   symptom is an application error that looks like a code bug.

2. **PgBouncer 1.21 does track named prepared statements, and that does not fix
   it.** `max_prepared_statements` (default 200) makes PgBouncer track and
   re-prepare protocol-level named statements. It also states plainly that
   "this tracking and rewriting of prepared statement commands does not work for
   SQL-level prepared statement commands, so `PREPARE`, `EXECUTE` and
   `DEALLOCATE` are forwarded straight to Postgres." So the version that makes
   the standard advice sound reasonable is the same version whose documentation
   still prescribes `RECONNECT` after a migration.

3. **The per-language flags are the recurring cost, and their failure is late.**
   `prepare: :unnamed` (Postgrex), `default_query_exec_mode=simple_protocol`
   (pgx), and each language's own equivalent. A service that omits one fails only
   after a DDL migration — not at boot, not in CI, not in a smoke test. That is
   the worst possible shape: the config is wrong for weeks and the first symptom
   is a production error four layers from the thing that is wrong.

4. **Transaction pooling withdraws session state, and says so.** On
   `server_reset_query`: "When transaction pooling is used, the `server_reset_query`
   is not used, because in that mode, clients must not use any session-based
   features, since each transaction ends up in a different connection and thus
   gets a different session state." Every setting in the contract is a
   session-scoped GUC. PgBouncer's `track_extra_parameters` does not include
   `statement_timeout`, and the same page warns "Most parameters cannot be fully
   tracked this way."

5. **The arithmetic does not need a pooler yet.** Nine services × the per-role
   limit of 10 = 90, plus reserves, against a raised `max_connections` of 200.
   Postgres's default of 100 genuinely is too low for this topology — raising a
   number is a five-minute change, and a pooler is an architectural change across
   seven languages.

**How the decision stays visible:** the pooler workarounds are **forbidden** in
`templates/database/contract.json`, and the gate fails the build if one appears
in any generated config. A service carrying `prepare: :unnamed` looks correct, is
wrong, is measurably slower, and the only way anyone would notice is by looking
for the flag — so something looks for it.

**What would reverse it:** the connection budget being outgrown, or a service
whose workload genuinely needs multiplexing. Either is a real trigger, and
reversing it means changing `contract.json`, all six snippets, and this entry
together — which is why the check is a list in one file rather than six greps.

---

## MD21b — **pgvector via pglayers on a Debian base**

**Not made:** staying on `postgres:17-alpine`, which is what the stack pinned
until kit-21.

**What it costs:** the Debian base image is larger than alpine.

**Why not:** pgvector is not available on the alpine base at all. pglayers
publishes each extension as a layer built from the PGDG **Debian** packages, so it
is glibc-linked. Measured, on the alpine base:

```
$ # FROM postgres:17-alpine  +  COPY --from=ghcr.io/pglayers/pgx-pgvector:17 / /
$ psql -c 'CREATE EXTENSION vector;'
ERROR:  extension "vector" is not available
$ ldd /usr/lib/postgresql/17/lib/vector.so
Error loading shared library ld-linux-aarch64.so.1: No such file or directory
Error relocating …/vector.so: palloc0: symbol not found
```

Two independent failures, either fatal: the musl loader cannot resolve a glibc
binary, and alpine's PostgreSQL looks under
`/usr/local/share/postgresql/extension` while pglayers writes to
`/usr/share/postgresql/17/extension`. On `postgres:17` the same layer answers a
real query (`'[1,2,3]'::vector <=> '[1,2,4]'::vector < 1` → `t`).

**And the alternative was rejected too.** `ghcr.io/pglayers/pglayers-full:17` is
one line instead of four and carries 80+ extensions. It was not adopted because
it *replaces* the official `postgres` image with a community build, permanently,
for every service — and because "full" means 80 extensions and a raised
`max_worker_processes` on the cluster whether or not any is used. Composing one
layer onto the official image keeps the base official and the extension list to
the one cafaye uses.

**What this depends on:** pglayers is a community project, **not** a PostgreSQL
project. It layers onto the *official* images, which is a weaker claim than being
published by postgres.org, and it carries no PostgreSQL guarantee. That is the
real risk in this entry, and it is why the version is pinned to `17-0.8.6` rather
than tracking `17`. Note that pglayers' own README documents the pin format as
`17-v0.8.3`, which exists but is a **stale** build — the live series is `17-0.8.4`,
`17-0.8.5`, `17-0.8.6`, with no `v`.

---

## MD21c — **extensions are a cluster decision, created by the admin role**

**Not made:** letting a service role `CREATE EXTENSION` in its own database.

**What it costs:** a service needing an extension that is not in
`KIT_POSTGRES_EXTENSIONS` requires an operator to add it and recreate the
volume. That is a deliberate delay rather than a self-service path.

**Why not:** it cannot work anyway. pgvector's control file is not marked
`trusted` (a PostgreSQL 13+ classification), so `CREATE EXTENSION` by a
non-superuser is refused with `HINT: Must be superuser to create this extension`.
Verified against pglayers' layer **and** against upstream pgvector v0.8.6, whose
`vector.control` is byte-identical — so this is pgvector's own classification,
not something the packaging drops.

The shape is right anyway: an extension's binaries live in the image, so they are
available to every service on the cluster whether or not anybody creates one. A
per-service grant would only ever have governed who pays the disk cost, and that
is an operator's call.

---

## MD21d — **the boundary is `REVOKE CONNECT`, not table grants**

**Not made:** relying on "nobody granted this role SELECT on that table" as the
isolation mechanism, which is what a cluster with one database per service gets
for free.

**What it costs:** four statements per database instead of none, and a cluster
that refuses to start if they cannot be applied.

**Why not:** it fails open. Measured on the same cluster shape:

| | with the `REVOKE` | without it |
|---|---|---|
| `SELECT` on another service's table | `FATAL: permission denied for database` | `ERROR: permission denied for table invoices` |
| reach the other database at all | no | **yes** |

Without the revoke the *rows* are still protected — by the accident that nobody
granted `SELECT`. The *database* is completely open: catalog enumeration, temp
tables, visibility of other services' GUCs, and any future `GRANT` anywhere in
the cluster. One careless grant makes it fail and nothing warns you at the time.

**Enforced by:** `tests/isolation_test.sh`, whose fourth assertion builds a
**control** cluster of the same shape without the `REVOKE` and requires it to let
service A in. Without that control a check asserting "A cannot SELECT from B"
would also pass on a cluster with no isolation at all.

---

## MD22 — PostgreSQL 15 is the floor, and the floor is measured not assumed

**Not made:** supporting PostgreSQL 14, which is what several services ran before
kit-21.

**What it costs:** a service that cannot move off 14 has nowhere to go.

**Why not:** PG15 removed the default `CREATE` grant on the `public` schema, and
that change is what makes database-per-service an actual boundary rather than a
naming convention. On PG14 a role that is not the database owner can create
objects in a database it does not own.

**Enforced by:** the schema revoke in `initdb/10-cluster.sh` is stated explicitly
rather than inherited from a version's behaviour, and the cluster image pins a
major.

---

## Things deliberately left to the operator

- **A database added after the cluster was provisioned.** `bin/dev db grant <name>`
  prints the statements rather than running them, and prints the `REVOKE ALL ON
  DATABASE … FROM PUBLIC` among them. That is not a convenience: a database
  created outside `initdb/10-cluster.sh` gets Postgres's default, which grants
  `CONNECT` to `PUBLIC`, so **an operator who creates a database by hand and
  forgets the revoke has opened it to every role in the cluster** — a cluster
  that is now, by the accident of one omitted line, exactly the no-isolation
  cluster MD21d is about.

  This is the one part of the boundary that is genuinely operator-side, and the
  reason is worth stating rather than hiding: `docker-entrypoint-initdb.d` runs
  once per volume, so the sweep at the end of that script cannot re-apply itself
  to a database that does not exist yet. There is no way to make this airtight
  from inside the init script — the only fully automatic version is a periodic
  sweep over `pg_database`, which is a scheduled job and a new thing to operate.

  So the honest position is: **the boundary holds by construction for everything
  declared in `KIT_POSTGRES_DATABASES` on a fresh volume, and a database added
  afterwards is the operator's to close.** `tests/isolation_test.sh` proves the
  first half against a real cluster; the second half is a documented step, not a
  claim. A reader who adopts this should decide now whether that step is
  acceptable, because "we will remember" is the only thing holding it.
- **Credentials in production.** Every dev role takes `POSTGRES_PASSWORD`.
  Isolation is by privilege and never by secret — which is exactly what lets
  `tests/isolation_test.sh` demonstrate the boundary while knowing every password
  in the cluster. Production roles carry distinct passwords from the deployment
  secret store.
- **Backup and restore.** Owned by `templates/kamal/` (kamal + kamal-backup), not
  by this packet. The topology here is one cluster with N databases, and
  kamal-backup's `databases:` is a list, so one job covers all of them.