# Research log — kit-21, one Postgres cluster

Every claim below is from a primary source fetched during this packet, with the
URL and the exact wording that carries it. Anything not verified this way is
marked UNVERIFIED and is not used to justify a decision.

## PgBouncer 1.21+ does track named prepared statements — and still fails on DDL

Source: <https://www.pgbouncer.org/config.html>, `max_prepared_statements`.

Default is 200, and when non-zero "PgBouncer tracks protocol-level named
prepared statements related commands sent by the client in transaction and
statement pooling mode." The client-side name is rewritten to
`PGBOUNCER_{unique_id}` and re-prepared on whichever backend it lands on.

So the brief's caveat is right about the mechanism and, importantly, right about
its limit. The same page says:

> "This tracking and rewriting of prepared statement commands does not work for
> SQL-level prepared statement commands, so `PREPARE`, `EXECUTE` and
> `DEALLOCATE` are forwarded straight to Postgres."

and then, on the downside of reuse:

> "If the return or argument types of a prepared statement changes across
> executions then PostgreSQL currently throws an error such as
> `ERROR: cached plan must not change result type` ... One of the most common
> ways of running into this issue is during a DDL migration where you add a new
> column or change a column type on an existing table. In those cases you can run
> `RECONNECT` on the PgBouncer admin console after doing the migration to force
> a re-prepare of the query and make the error go away."

**This is the finding that decides the packet.** The remedy for the pooler's
worst failure mode is an operator command that must be run after every schema
change. Nine services, each with its own migration schedule, would each need a
deploy step nobody remembers. That is not a configuration concern; it is a
recurring manual operation created by the pooler itself.

Two more facts from the same page, both against a pooler on a shared cluster:

- `server_reset_query`: "The query is supposed to clean any changes made to the
  database session so that the next client gets the connection in a well-defined
  state ... **When transaction pooling is used, the `server_reset_query` is not
  used**, because in that mode, clients must not use any session-based features,
  since each transaction ends up in a different connection and thus gets a
  different session state."
- `track_extra_parameters` tracks `application_name`, `client_encoding`,
  `DateStyle`, `IntervalStyle`, `TimeZone`, `session_authorization`,
  `standard_conforming_strings`, `default_transaction_read_only`,
  `scram_iterations`, and — **only since PostgreSQL 18** — `search_path`.

  `statement_timeout` is NOT in that list. It would need
  `track_extra_parameters`, and even then the page warns "Most parameters cannot
  be fully tracked this way."

## Postgrex's own words

Source: <https://hexdocs.pm/postgrex/Postgrex.html> (v0.22.4), `start_link/1`,
section "PgBouncer":

> "PgBouncer versions 1.21.0 and later support named prepared statements. If you
> are using an older version of PgBouncer with transaction or statement pooling,
> named prepared queries cannot be used ... To force unnamed prepared queries in
> such older versions, set the `:prepare` option to `:unnamed`."

Confirms the brief's Postgrex claim verbatim. Two things this packet uses that
are easy to miss:

- `:parameters` — "Keyword list of connection parameters." This is Postgrex's
  route to `application_name`, and it is **not** `:prepare`. It is what actually
  works against a direct connection on a shared cluster.
- `:pool_size` — "The default `:pool_size` for the default pool is 1." Ecto
  raises it. The number that decides whether one cluster fits nine services is
  this one, per service, and it is a per-service decision, not a kit default.

## pglayers exists, is maintained, and is NOT an official Postgres project

Source: <https://github.com/pglayers/pglayers> README, fetched this session.

The brief calls pglayers "an official Postgres project". **That is wrong, and it
matters.** What the project actually says is that it layers onto *the official
PostgreSQL Docker images* (<https://hub.docker.com/_/postgres>) — a different
claim. pglayers itself is a community project: `ghcr.io/pglayers/*`, MIT
licensed, 163 stars, 291 commits, 2 open issues at fetch time. It is not
published by the PostgreSQL project and carries no PostgreSQL guarantee.

What it genuinely provides, and what we rely on:

- One `FROM scratch` image per extension per PG major, consumed with
  `COPY --from=ghcr.io/pglayers/pgx-pgvector:17 / /`. No compilation, and the
  result is a single ordinary image, so kit's one-image policy survives.
- PG 17 uses the "classic layout" (`/usr/lib/postgresql/17/lib/vector.so` and
  `/usr/share/postgresql/17/extension/vector.control`). One `COPY --from=… / /`
  per extension, no GUC wiring. PG 18+ switches to an "isolated layout" needing
  `extension_control_path` and `dynamic_library_path` — kit is on 17, so this
  does not apply, and that is a reason to pin 17 rather than a reason to
  migrate.
- `pgvector` 0.8.5 and `pg_cron` 1.6.7 both listed for PG 17.
- pgvector needs **no** `shared_preload_libraries` entry. pg_cron does
  (`pg_cron`). The README carries the full table of which extensions need one.
- `CREATE EXTENSION` is still per-database — the page says so directly: "must be
  created in each database where you want to use them."

The per-database half is the part a shared cluster does not solve: the image
makes `CREATE EXTENSION vector` *possible* in every database, and the isolation
contract still has to decide who may run it. kit grants `CREATE` on the database
to the owning role only, so a service can create extensions in its own database
and in nobody else's.

## The facts I could NOT verify, and do not claim

- Whether Ecto's migration advisory lock (`pg_advisory_lock`) is broken by
  transaction pooling. Widely reported, but I did not find a primary source
  stating it, and hexdocs.pm/ecto_sql/Ecto.Adapters.SQL.html returned 404 in
  this session. **Not used as an argument.** The decision stands on the
  `RECONNECT`-after-every-migration finding above, which is from the pooler's own
  documentation.
- `mrts/docker-postgresql-multiple-databases` behaviour. The Postgres docs point
  at it for multi-database init; kit ships its own script rather than vendoring
  that repository, per the never-copy rule, so its behaviour is not load-bearing.