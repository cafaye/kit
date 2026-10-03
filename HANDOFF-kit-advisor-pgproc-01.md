# HANDOFF — kit-advisor-pgproc-01

Read `REPORT-kit-advisor-pgproc-01.md` first. **This page is the first move, not
the summary.**

**Status:** the measurement, the rule and the fixture are in. `helper_routed`
fires, `direct_policy` is green with `via_functions` empty, `helper_opaque` is
silent — all three asserted by `tests/tenancy_test.sh` assertion 7c, which
passes. Not pushed; the manager merges and pushes.

---

## Your first move, exactly this

**Run `bash tests/tenancy_test.sh`.** 39 assertions, and the one to read is 7c —
assertion 7's control half for this change. It prints three lines and all three
matter:

```
   rls_references_user_metadata -> helper_routed
   helper_routed -> via_functions may_read_admin on the SAME table
   direct_policy -> via_functions '(empty, the control)' on the SAME table
   helper_opaque -> silent, and that is the rule's measured limit: …
```

**If `helper_routed` is silent, the hop is gone.** Nothing else in the suite
notices: rule 4 still fires on `admin_only` and `direct_policy` through hop 1,
so a dead recursive arm looks exactly like a working rule.

**Tear the cluster down first if a previous run left one:**
`docker compose -p kit-tenancy -f tests/.tenancy-work/compose/docker-compose.yml down -v && docker rm -f kit-tenancy-postgres-1`.
A stale container makes `docker compose up --wait` fail with
`No such container: <sha>`, which is *not* what it looks like — it cost this
packet a whole run.

---

## The one thing to know before you touch the rule

**The answer to "does `pg_depend` record it" is SPLIT, and the split is the
design.** Re-measured on PostgreSQL 17.11, script and rows in
`measure-advisor-pgproc.sql` / `measurement-pgproc.out` at the repository root:

| body kind | `pg_depend` on the function | |
|---|---|---|
| `language sql`, **string** body (`as $$ … $$`) | `pg_namespace` only | **not recorded** |
| `language plpgsql` | `pg_language`, `pg_namespace` | **not recorded** |
| `language sql`, **`BEGIN ATOMIC`** | `pg_proc → pg_class → <relation>` | **RECORDED** |

`prosrc` is **empty** for the ATOMIC body — PG14+ parses it at `CREATE FUNCTION`
and the parse is what records the dependency. So `probin IS NOT NULL` and
`prosrc <> ''` partition the two cases exactly, in the catalog.

**So the honest position is: the hop closes one body kind and not the other,
and `helper_opaque` is the shape a hand-written helper actually takes.** The
next packet's helper will be a string body. Do not let anyone read
`BEGIN ATOMIC` as a recommendation — see the report's §4.

---

## Do not

- **Do not ship a `prosrc` scan.** It fires on a table named in a comment, on a
  table name inside a string literal, and on a table that has since been
  dropped — `prosrc` is text, not a dependency, so its misses are silent. It is
  aimed at the one rule an adopter trusts about *who may edit what*. The gap is
  named in `advisor.sql`'s **first screen** instead, on purpose: a reader meets
  it before they trust a row.
- **Do not change `isolation.sql`, `assertions.txt` or `protect_table`.**
  Nothing in the tenancy proof was touched and nothing in it needed to be. The
  packet explicitly forbids it: `identity` embeds a copy of `isolation.sql` and
  migrations are append-only, so a template edit does not reach a deployed
  service by itself.
- **Do not widen `helper_opaque` into a rule.** The tempting move — "the advisor
  should at least *report* that it cannot see through `helper_opaque`" — needs a
  `tenancy.rls-*` id in `core/docs/tenancy.md` and an entry in `core`'s
  in-process table, both outside this worktree. A half-wired rule is worse than
  a documented gap. See "where it belongs" below.
- **Do not push.** Three commits on `worker/kit-advisor-pgproc-01`. The manager
  merges and pushes.

---

## The breakage this packet did NOT add, and the recipe for it

The packet's predecessor is explicit: **do not add a breakage you have not run
red.** The mutation is written down so the next person does not have to derive
it. It is one added clause, it leaves the CTE syntactically valid, and it kills
the recursive arm while leaving hop 1 intact — which is the point, because a
dead hop looks exactly like a working rule:

```
# in templates/database/tenancy/advisor.sql, policy_reaches, the recursive arm
      where r.ref_class = 'pg_proc'::regclass
        and r.depth < 16
+       and false          -- the pg_proc hop, deleted
```

Then `bash tests/tenancy_test.sh` must go red **naming**
`helper_routed`, and the needle is the assertion's own FAIL text — not a
`FAIL <label>` line, because assertion 7c is a `fail`/`say` pair rather than a
gate check. (That distinction is why this packet could not write it as
`expect_red_check`: that helper matches `FAIL $want`, and 7c is not a
`FAIL`-labelled check.)

---

## Where the residual belongs: `core`, not here

`core/harness/tenancy_check.py` already has `tenancy.rls-view-invoker` with a
fixture pair and breakage 26, and it reads migration **TEXT**. That is the
layer that *can* see a string-body helper in a migration — which is precisely
the case the catalog cannot reach at all. Do not port the catalog walk into
`core`; add the mapping-table sentence saying why both exist (catalog vs. text),
as `kit-advisor-view-01`'s handoff concluded for its own rule.

---

## Commits

| commit | what |
|---|---|
| `21ab701` | the measurement — three body kinds, three `pg_depend` dumps, rule 4's blind spot |
| `a354a8a` | `policy_reaches` + rule 4's `pg_proc` hop; the residual named in the first screen |
| `b39bd8f` | the fixture — one writable table, three routes — and assertion 7c |

## What is NOT done, and is not a surprise

- No `self_test` breakage (see the recipe above; run it before you add it).
- No machine-readable finding for the unmeasurable shape — deliberate, and the
  report says which repo it belongs in.
- No rule name was added, so `tenancy_contract_check` needed no edit and the
  trip list is unchanged. I verified the one way this could have gone red: the
  new loop is written `for pair in 'helper_routed:may_read_admin' …` and that
  check's trip-pair regex is **anchored** (`^ *'…'`), so the loop does not read
  as a trip pair. Running the check's own regex against the file: ten rules,
  no stray pairs.