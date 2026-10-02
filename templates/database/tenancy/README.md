# `templates/database/tenancy/` — the account boundary, enforced by Postgres

> The substrate a service applies once, the assertion set that proves it works, and
> the two roles between them. Read
> [`../README.md`](../README.md) first for the cluster-level boundary: this
> directory is the OTHER one — inside one service's own database, between two
> accounts of the same customer.

## What this is

Two roles, one GUC, one function that protects a table, one sweep that says
whether the service is still isolated, and one assertion set that proves all of
it.

```
substrate.sql     apply once, as the OWNER role.  the identity seam,
                  protect_table/2, the credential seam
                  (protect_credential_table/3, begin_credential/1,
                  current_credential_digest/0), the credential audit, and the
                  sweep.
assertions.txt    the manifest. What the proof is supposed to assert, by name.
isolation.sql     the assertion set. Run it; it answers with one row per
                  assertion, and a driver compares the NAMES against the manifest.
README.md         this file.
<lang>/tenancy_test.*   six drivers, one per language, that run the assertion
                  set and check it against the manifest.
```

The drivers live in `templates/database/<lang>/` rather than here because a
service copies `templates/database/<lang>/` — that is where its connection config
lives, and the tenancy test goes beside it.

## The two boundaries, and why this is the second

| | what it stops | how |
|---|---|---|
| `templates/database/README.md` | service A reading service B | one database and one role per service, and `REVOKE … FROM PUBLIC` |
| this directory | account 1 reading account 2 | row-level security on every account-scoped table, forced |

Measured, on the cluster kit ships, both directions:

```
$ psql -U courier -d billing -c 'select * from deliveries;'
FATAL:  permission denied for database "billing"          # refused before a query is parsed
```

```
# as courier, carrying a DELIVERY row's account id, on a table whose policies are in place
select count(*) from deliveries where account_id = '…beta…';   ->  0
```

The second is what this directory exists for, and the first is what it exists
*beside*: a fleet where one cluster holds nine databases and every one of them
holds many accounts has two boundaries, and the inner one was the one nobody had.

## Adopting this

1. Copy `substrate.sql` and `isolation.sql` and `assertions.txt` into your
   migrations and your test fixtures, and call `cafaye.protect_table` from the
   migration that creates each account-scoped table:

   ```sql
   select cafaye.protect_table('assets');
   ```

   That is the only call. There is no second, weaker entry point, because a
   template that offers one is a template the weaker one gets chosen from.

2. Point your application at the **`<service>_app`** role rather than
   `<service>`. `templates/compose/postgres/initdb/10-cluster.sh` provisions both
   and grants the first to the second, so impersonating the weaker role works and
   the reverse membership does not exist. A service that has not adopted these
   templates is unaffected: `<service>` is unchanged and still owns everything it
   always did.

3. Call `cafaye.begin_account/1` once per request, inside your transaction, from
   whatever already authenticates the request:

   ```sql
   begin;
   select cafaye.begin_account($1);   -- the account your token resolved to
   select * from assets;              -- scoped, whether or not the query says so
   commit;
   ```

4. Copy `templates/database/<lang>/tenancy_test.*` beside `isolation.sql` and
   `assertions.txt` in your test tree, and make sure your gate demands the tier:
   `REQUIRED_DB=1`. The driver turns a missing `TEST_DATABASE_URL` into a
   **failure** rather than a skip, because a skip here is a green run that
   proved nothing.

5. Keep your queries' own `where account_id = ?`. RLS is defence in depth, not a
   licence to delete the predicate: the predicate is what makes the query
   indexable, and core's `tenancy.yml` still requires it. **This directory does
   not change core's `schemas/tenant-isolation.schema.json`** — the declaration
   half already existed and is unaffected.

6. **If a table is resolved by an unguessable value** — an API key, an invitation
   token — call `cafaye.protect_credential_table('<table>', '<digest_column>')`
   *instead of* `protect_table`, and open the resolution with
   `cafaye.begin_credential($1)` in the same transaction as the lookup. One call,
   same size as `protect_table`'s, and it is not an extra step: without it every
   scoped credential in the service authenticates as 401 "not found". Read
   [the section below](#the-third-trap-a-credential-table-cannot-be-scoped-by-an-account-it-does-not-have-yet)
   first, including the list of what it cannot do.

## THE THIRD TRAP: a credential table cannot be scoped by an account it does not have yet

A **credential table** — `api_keys`, `account_invitations`, `oidc_clients` — is
scoped by an account like every other table, and it still does not work. Its access
path is *"find the row by an unguessable value and learn the account from it"*, so
the account is **what the query is for**, and a query cannot be scoped by the thing
it is trying to compute. `identity` measured this against its real protected
`api_keys` table, as the OWNER:

| | rows seen |
|---|---|
| **no identity — the state a request presenting a scoped token is in** | **0** |
| identity = the credential's own account | 1 |
| identity = another tenant's identity | 0 |

The first line is the finding. A request presenting `cafaye_…` has not resolved
the token yet, so it has no account, so the lookup authenticating it reads nothing,
`ErrNoRows` becomes "not found", and the HTTP layer answers **401**. Every machine
credential, refused as though it did not exist — the quietest possible failure, and
one a green suite cannot see, because a test fixture built with `LIKE … INCLUDING
ALL` has no policies at all.

### The mechanism: one policy whose qualifier is the digest you presented

```sql
select cafaye.protect_credential_table('api_keys', 'token_digest');
```

One call, the same size as `protect_table`'s. It protects the table exactly as
`protect_table` does — same four policies, same `ENABLE`, same `FORCE`, same index
on `account_id` — and then adds a fifth:

```sql
create policy api_keys_cafaye_resolve on api_keys
  for select to <owner>, <service>_app
  using (token_digest = (select cafaye.current_credential_digest()))
```

and the caller opens the resolution the way it opens the account:

```sql
begin;
select cafaye.begin_credential($1);          -- the digest it already computed
select … from api_keys where token_digest = $1;   -- the row returns
commit;                                     -- the digest expires with it
```

The caller passes the value it was going to query with anyway. Postgres is given a
string to compare against a column: it never learns the secret, never learns how it
was derived, and gains no ability to compute one.

**The predicate is in the policy, not only in the caller's query, and that is the
whole design.** Policies combine permissively, so a policy that merely said *"a
credential session may select this table"* would be the defect: a table-wide
`SELECT`, and every key in the database browsable with the one query this mechanism
exists to prevent. So the honest semantics are:

> **A resolution session may read exactly the credential row whose digest it
> presented, and nothing else in the database.**

`select * from api_keys` inside one of these sessions returns **that one row**.
Every other table reads zero rows.

### What it cannot do — all five, so nobody finds them

1. **It cannot tell a secret from a label.** It widens a read to the row whose
   value you presented; whether that value is *unguessable* is the service's
   knowledge, not the substrate's. On `oidc_clients`, where `client_id` is an
   identifier rather than a secret, **this is the wrong mechanism** — do not apply
   it there on the strength of the invitation case. The invariant that keeps this
   from becoming a general bypass is exactly the limitation: *you can only widen a
   read to a row you could already name.*
2. **It cannot write.** `for select`, and no write counterpart: a resolution session
   meets the ordinary write policies, whose `with check` still demands an account
   identity. A service cannot mint a credential while resolving one.
3. **It does not open any other table.** It is a policy on one named table.
   `account_users` still reads zero rows.
4. **It is a second GUC.** `begin_credential/1` is transaction-local for the same
   reason `begin_account/1` is — the six drivers hold pools, and a session-level
   digest survives the pool and hands one resolution's credential to the next
   connection. It is set in exactly one function, so a service has exactly one
   place that writes it.
5. **It is not audited at runtime, and does not claim to be.** The digest is
   transaction-local and leaves nothing behind. What *is* auditable is the scope:

   ```sql
   select * from cafaye.credential_tables();
   --  table_schema | table_name | digest_column
   ```

   which answers *"which tables in this database can be read with no account"* in
   one query rather than by searching the source. It reads the policies, not a
   list, so it cannot be satisfied by a mechanism that records nothing.

### What it was instead of, and why — `DECISIONS.md` (MD24)

- **A `BYPASSRLS` role.** This is Supabase's answer, and it is right for Supabase's
  topology: `service_role` is created `nologin noinherit bypassrls`, granted only
  to `authenticator`, and holds **no policies of its own** — what bounds it is who
  may assume it and what it has been granted. kit has neither half of that
  structure: there is **one** per-request role and no separate service layer, so a
  bypass role here is a bypass over the whole service database, held by the role
  every request already authenticates as. Read the reference; do not copy the shape.
- **A `SECURITY DEFINER` function.** Does not work under `FORCE` — `FORCE` applies
  to the *definer*, and only `BYPASSRLS` skips RLS. A proposal of this shape is
  the `BYPASSRLS` option wearing a friendlier hat.
- **Dropping `FORCE` on credential tables.** The table above, on the one table
  holding every machine credential.
- **Leaving `api_keys` unprotected.** The boundary stops covering credentials.

## THE TRAP: `FORCE ROW LEVEL SECURITY`

Postgres exempts a table's **owner** from its own row-level-security policies.
`ALTER TABLE … FORCE ROW LEVEL SECURITY` removes that exemption, and
`protect_table` issues it.

Without it, a service that has shipped policies, enabled RLS, and declared victory
is **silently wrong on exactly the tables it owns** — which, in this fleet, is all
of them, because every service runs its migrations as its own role and so owns
every table in its database. Measured on this kit, a protected three-row table,
read as the owner carrying another tenant's identity:

| | rows returned |
|---|---|
| with `FORCE ROW LEVEL SECURITY` | **1** — its own |
| without it | **3** — every tenant's |

It is not in Supabase's row-level-security guide, and **no lint anywhere in this
fleet checked for it** before this directory existed (verified across all nine
account-scoped services: zero occurrences of `ROW LEVEL SECURITY`, zero
`CREATE POLICY`). `tests/tenancy_test.sh` deletes the FORCE statement and requires
the assertion set to go red — and requires the red to be on the **owner** half
only. That specificity is the point: the login half passes on a substrate with no
FORCE at all, so an isolation suite written only against the application role
proves nothing about it.

## THE OTHER TRAP: `(select …)` costs nothing to get right

```sql
using (      cafaye.current_account_id() = account_id )      -- per ROW
using ( (select cafaye.current_account_id()) = account_id )  -- per STATEMENT
```

Postgres hoists an uncorrelated scalar subquery into an **InitPlan** and evaluates
it once per statement; a bare call is evaluated once per candidate row. Measured
by `tests/tenancy_test.sh` on every run, five rows and one query:

```
(select …) wrapped:  1 call
bare call:           5 calls
```

Same policy, same rows, order-of-magnitude difference on any account-scoped table
that is more than a handful of rows. `protect_table` only writes the wrapped form,
`isolation.sql` asserts it structurally (both forms return identical rows, so no
denial can detect it), and the measurement above is what stops that assertion
being a comment.

## What the assertion set asserts, and why it is four and not one

The shape, run **twice** — once as the `<service>_app` login role and once as the
owner:

| assertion | expected |
|---|---|
| `no-identity-reads-no-rows` | a request with **no** account set reads **zero** rows |
| `another-tenants-rows-read-as-none` | a request with **another tenant's valid** identity reads **zero** of that tenant's rows |
| `own-rows-are-visible` | a request with **its own** identity reads **its** rows |
| `own-identity-reads-only-its-own-rows` | …and an unqualified read returns only its own |

A test that asserts only the first is satisfied by a table with no policy at all,
which is the bug. A test that asserts only the third is satisfied by a policy that
permits everything. Only the four together are the property — and the reason the
owner half is separate is that those four pass on a substrate with no FORCE.

Around them, twenty more: the write side (each denied write paired with a read
proving the row is intact, because a `using` denial raises nothing and "matched
zero rows" is only a proof once you can see the row), the three refusals that make
the login role's non-ownership real, two assertions about how the policies are
*written*, and three about the sweep — **one of which is the sweep's positive
control**, because an empty sweep result is otherwise satisfied by a sweep that
reports nothing.

And **fifteen more for the credential half**, which is the same dual-role shape
over the one table whose access path is *"find the row by an unguessable value and
learn the account from it"*: six per role — no resolution context reads nothing, a
resolution by digest works **with no account identity at all**, the resolution
**cannot browse**, a digest you did not present resolves nothing, it **does not
open another table**, and it **cannot write** — plus three that no denial can see,
which are the audit query naming the table, the resolve policy naming its roles,
and the resolve policy being written wrapped.

Two of those fifteen are the ones a permissive implementation fails.
`resolution-cannot-browse` is satisfied by nothing except a policy carrying the
digest predicate, and it needs a credential fixture with **two** rows: with one,
"the table" and "that row" are the same set and a table-wide `SELECT` passes it.
`resolution-does-not-open-another-table` is satisfied by nothing except a mechanism
scoped to one table — a `BYPASSRLS` role returns `probe_things`' rows from inside a
resolution session, which is the ambient bypass this directory exists to prevent.

`assertions.txt` is the manifest, and every driver compares the names it got back
against it **in both directions**. A count would not do: 39 is compatible with 39
of the wrong 39.

## Cross-tenant access is absence, not refusal

`cafaye.current_account_id()` returns NULL when no account has been set, so every
policy reads zero rows rather than raising. A `403` tells an attacker the id
exists; `nil`/`[]`/an empty result tells them nothing. This is core's D33
(`core/docs/tenancy.md`) arriving from the other end, and the one place a
synchronous error is correct is `insert`, whose policy has no `using` to filter
with and whose `with check` therefore returns `42501` — about the INSERT, not
about the account.

## Two consequences to know before the first migration runs

1. **The owner reads zero rows from a protected table until it sets an identity.**
   `FORCE` removed its exemption and no policy names it without one. That is the
   correct posture and it is the adoption cost: a migration that backfills rows
   sets the identity (`set local role <service>_app; select
   cafaye.begin_account(…)`) and reads exactly one account's rows. It fails loudly
   and immediately, which is the good direction.

   **It does not get better with a `SECURITY DEFINER` function**, which is the
   natural next thought and is wrong: `FORCE` applies to the **definer** too, so a
   function owned by the table's owner is subject to that table's policies and
   reads zero rows as well. Only `BYPASSRLS` skips RLS, and no service role has
   one. The identity is the whole answer.

2. **`begin_account/1` is transaction-local.** Outside an explicit transaction it
   expires at the end of the statement that set it, so a caller reaching the
   database in autocommit reads zero rows. That cannot leak and it is loud.

## What this does not prove

- **That a service sets the identity.** `begin_account/1` is one call in one place
  and nothing here can tell a service that never calls it from one that calls it
  in every request. A service that forgets reads zero rows: safe, and extremely
  visible.
- **That a table is account-scoped.** The sweep defines that as "has an
  `account_id` column", which is the fleet's vocabulary (core's D7) and misses a
  service that spells it `tenant_id`. A service holding no customer rows is core's
  **honest zero** and needs none of this.
- **That the six drivers run.** kit's gate PARSES them and runs the assertion set
  they run; executing each driver needs that language's driver library resolving,
  which is a service's gate's job. The drivers are deliberately thin, which is
  what makes the residual gap small.
- **That the login role is not a MEMBER of the owner role.** The cluster grants
  `<service>_app` TO `<service>` so a proof can impersonate the weaker role; the
  reverse membership would undo the whole design and is asserted where it can be
  — `tests/tenancy_test.sh` checks the cluster's direction, and a service's own
  membership is its `tenancy.yml`'s business.