# HANDOFF — kit-advisor-view-01

**Packet:** add `security_definer_view` to kit's RLS advisor, prove it fires and
does not misfire, add a self_test breakage.
**Status:** COMPLETE. 5 commits on `worker/kit-advisor-view-01`, base `4982b2a`.
**Not pushed.** The manager merges and pushes.

Full write-up: `/Users/kaka/Code/any/moon/logs/REPORT-kit-advisor-view-01.md`.

---

## The one thing to know before you touch this

**`core` already has a check for this exact hole.** `core/harness/tenancy_check.py:335`
— `tenancy.rls-view-invoker`, severity `fail`, with fixture pair and breakage 26.
Read `core/docs/tenancy.md:320` before you go further.

It is **not** a duplicate of what landed here, and the difference is the whole
point:

- core reads migration **TEXT** and has no database. It cannot see a hand-written
  view, a view created by a migration core does not own, an option dropped by a
  later `ALTER VIEW … RESET`, or whether a login role can actually reach the view.
- kit's advisor reads the **live catalog**. It answers all four.

So this rule **complements** core's; it does not replace it, and I did not
suppress anything or try to merge them. If you extend this work, extend it
*around* that split rather than across it.

---

## What landed

| commit | what |
|---|---|
| `66026c3` | the rule: `views` CTE, recursive `view_reads`, `rule_security_definer_view`; header nine→ten |
| `6af0463` | ten fixture views (2 positives, 6 negatives, 2 spelling variants); PG-version branch on the remediation |
| `606c516` | the unreachable fixture, and the three measurements that produced it |
| `eadf97d` | `tenancy_contract_check` compares advisor rule names ↔ trip fixtures, both ways; `self_test` breakage 93 + header entry |
| `7280606` | `CHANGELOG.md`, `DECISIONS.md` MD25 |

`DECISIONS.md` MD25 records the two trades this made and is the file to read
first if you want the reasoning rather than the result.

---

## Verification you can re-run, and what I did NOT run

```sh
# green — full account boundary against a real cluster
bash tests/tenancy_test.sh                    # EXIT 0, 39 assertions

# green — the shard my breakage lands in (93 % 8 == 5)
KIT_SELF_TEST_SHARD=5/8 bash tests/self_test.sh   # EXIT 0, 12 of 97

# green — full static gate. SEE THE PATH NOTE BELOW.
bash tests/validate.sh --static-only          # EXIT 0
```

**I did not run the unsharded `self_test`** — 97 whole gates, and the packet said
not to. 85 breakages are unevaluated by me.

**PATH NOTE, and it will bite you.** In the packet's worktree
(`cafaye/kit/cafaye/wt-m39-kit-advisor-view-01`) the static gate reports **one**
failure:

```
FAIL lint drift  (a service config is compared to kit, not merely forbidden)
       no cafaye service checkout was found beside this one…
```

That is **environmental, not mine.** The worktree is nested *inside* the repo, so
its parent directory holds no service checkouts and the drift check has nothing to
compare. `KIT_FLEET` does not help. I proved it: the identical tree, checked out
into a worktree placed **beside** the fleet, gives `EXIT 0 — "PASS: every check
passed."` If you see that one FAIL, do not go looking in my diff.

---

## The successor's first move

**In order, and the first is the one that would have saved me the most time:**

1. **Grep the siblings before you finish the rule, not after.** The single most
   valuable thing this packet found — that `pg_class.reloptions` stores
   `security_invoker = on` **verbatim**, uncanonicalised, and that this is the
   spelling `core`'s own fixture uses — came from grepping `core` for `CREATE
   VIEW` while checking blast radius. It was already fixed by then, but only
   because I had time to notice. Doing the sweep in **Q1** would have found it
   before the rule was written. Cross-repo idiom beats cross-repo correctness.

2. **Install the advisor into a live `identity` or `billing` database and run it
   once.** My blast-radius claim is a **source** sweep ("no first-party
   `CREATE VIEW` exists in any sibling"), which is *not* the same claim as "the
   rule is clean on their live clusters". I expect zero findings; I did not test
   it and neither should you assume it.

3. **Decide whether a `materialized_view` rule follows.** It is a **bigger** hole
   than this one and it is currently unwatched: a matview holds a copy refreshed
   by its owner, and RLS is not enforced on reads from it at all. I excluded it
   (`relkind = 'v'` only) on purpose — reporting it under `security_definer_view`
   would be reporting the wrong hole. Read `core`'s `tenancy.rls-unprotectable`
   first; it folds matviews in with foreign tables, and the two must not disagree.

---

## Things that will bite you, all measured

- **`CREATE VIEW v AS select … WITH (security_invoker = true)` is a syntax
  error.** The option precedes `AS`. First thing anyone writing this hits.
- **`pg_class.reloptions` is verbatim.** `= true` → `true`, `= on` → `on`,
  `= off` → `off`. Never compare reloptions to a canonical string.
- **`pg_depend` has one row per *(rewrite rule, reference)*.** A view naming a
  table twice reported it twice.
- **Ownership is not a grant.** `revoke all … from public` does nothing to a view
  the creating role owns.
- **Membership carries privileges.** Making the view's owner `NOLOGIN` is not
  enough to make it unreachable: reaching the owner needs
  `grant <owner> to alpha`, and then `has_table_privilege('alpha', …)` is `TRUE`
  through the membership. A genuinely unreachable fixture must be owned by a
  **superuser** — which `api_roles` already excludes, via the same `not rolsuper`
  predicate every other rule uses. This cost three failed fixture iterations; the
  rule was correct every time.
- **`alpha` has no `CREATEROLE`**, so a fixture role must be created by the
  cluster admin, and `SET ROLE` needs **membership**, not merely existence. The
  unreachable fixture is a **separate script applied after** the main one — applied
  before, it fails with `schema does not exist`.

---

## Honest loose ends

- **`security_invoker` needs PG15 and the fleet floors there**, so the sub-15
  remediation branch in the rule is **unexercised**. It is written from the
  version table, not measured. Closing it needs a PG14 container for one
  assertion; I spent the remaining minutes on the report instead. If you want it
  tested, that is the cheapest open item here.
- **The rule has never run against a real sibling cluster** — see move 2.
- **The static check cannot see a rule that goes from selective to
  indiscriminate.** Measured: deleting the rule's `having` clause leaves
  `--static-only` **green**, because the check compares rule *names*. That is why
  the mutation in breakage 93 renames the rule instead, and why MD25 exists. The
  two properties are proved by two different files on purpose — the cluster suite
  proves the rule fires and does not misfire; the static check proves the advisor
  and its proof agree. **Do not collapse them into one claim.**
- **Whether `core`'s mapping table should learn about this rule** is a `core`
  decision, not this packet's. My read: add a sentence saying why both exist
  (catalog vs. text), do not merge them.