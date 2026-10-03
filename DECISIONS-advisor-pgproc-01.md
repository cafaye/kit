# DECISIONS — kit-advisor-pgproc-01

Three decisions this packet made that a later reader could reasonably have made
differently. Each says what was chosen, what was not, and why.

---

## MD27 — The unmeasurable half is NAMED, not SCANNED

**The measurement, on PostgreSQL 17.11** (`measure-advisor-pgproc.sql`,
`measurement-pgproc.out`). `pg_depend` on a `SECURITY DEFINER` function:

| body kind | carries | |
|---|---|---|
| `language sql`, string body (`as $$ … $$`) | `pg_namespace` only | not recorded |
| `language plpgsql` | `pg_language`, `pg_namespace` | not recorded |
| `language sql`, `BEGIN ATOMIC` | `pg_proc → pg_class → <relation>`, `deptype 'n'` | **recorded** |

`prosrc` is empty for the ATOMIC body — PG14+ parses it at `CREATE FUNCTION` and
the parse is what records the edge.

**Chosen:** ship the `pg_proc` hop for the one body kind the catalog carries,
and state the residual in `advisor.sql`'s **first screen** (§"what this does not
find"). **Not chosen:** a `prosrc` scan.

**Why.** The unrecorded edge exists only as SQL text. A substring match fires on
a table named in a **comment**, on a name inside a **string literal**, and on a
table that has since been **dropped** — `prosrc` is text, not a dependency, so
nothing tracks DDL and its misses are silent. It would be aimed at the one rule
an adopter trusts about *who may edit what*. The gap is more valuable than the
false positives: a reader who knows the advisor cannot see through a string-body
helper reads `prosrc` by hand in review, and a reader who does not know is being
told, by a regexp, that somebody looked.

**Where the gap is stated matters.** Not in rule 4's comment — in the first
screen, because a reader meets it *before* trusting a row rather than after
wondering why one is missing. `security_definer_view`'s residual limits are
already in that position and this is the same convention.

**The consequence, stated plainly:** the helper the *next* packet builds will be
a string body, and this advisor will not see through it. `BEGIN ATOMIC` is the
only spelling that is visible, and it is a poor fit for a hand-written helper (an
`END`-terminated body cannot be generated without knowing the column list). So
the honest position is that **the catalog cannot express this**, and the remedy
has to be review-time rather than catalog-time.

---

## MD28 — No new rule name, because a half-wired rule is worse than a gap

**Chosen:** extend rule 4 in place. Same name, same `cache_key`, same ERROR
level. No eleventh rule, no `tenancy.rls-*` id, no trip-list entry.

**Why.** The alternative — a second rule reporting "this policy calls a
`SECURITY DEFINER` helper whose body the catalog does not record" — is a true
statement and was seriously considered. It was rejected on wiring, not on merit:
a new `tenancy.rls-*` finding needs an id in `core/docs/tenancy.md`, a case in
`core`'s in-process table, and the finding-count words in that doc to learn the
new number — all in a repository this worktree cannot reach. And the packet's own
rule is that *a rule proved only in CI is a rule a developer running the gate
locally has learned nothing about*. A rule that fires but is not discoverable
where a reader looks is not that.

**The trade:** the advisor emits **no row** for `helper_opaque`. A reader running
it sees nothing about a string-body helper. That is a real cost, and it is why
the gap is documented in the artifact itself rather than only in a report.

**Where it belongs.** `core/harness/tenancy_check.py` reads migration **TEXT**
and already owns `tenancy.rls-view-invoker`. It is the layer that *can* see a
string-body helper in a migration — the case the catalog cannot reach at all. The
catalog walk and the text walk should coexist and the mapping table should say
why, exactly as `kit-advisor-view-01` concluded for its own rule. **Not** a
duplicate to be merged.

---

## MD29 — `policy_reaches` is `view_reads`, not a second walk

`security_definer_view` already does a transitive `pg_depend`/`pg_class` walk for
views. `policy_reaches` is that walk applied to rule 4's subject: same shape,
same depth bound (16, `view_reads`' bound for `view_reads`' reason), same
`min(depth)` + `group by` — that aggregation exists because `pg_depend` records
one row per (object, reference), measured on `view_reads` as `{plain, plain}`.

**Why one walk.** A second walk written a second way is a second thing to keep
correct, and nothing in this repository would notice when the two drifted.

**Two shape decisions that are not tidiness:**

- **Hop 2 is taken only from a `pg_proc` ref.** A relation reached in hop 1 is a
  relation and nothing depends on relations from here; taking the hop from
  `pg_class` too would drag every index of every reached table into the walk and
  report them all.
- **`through_proc` is carried, not recovered.** Recovering the helper means
  matching `pg_depend` from the relation — the **reverse** direction — which names
  every function that *reads* the table rather than every function the policy
  *called* to reach it. Carrying it is what lets the finding say "reached through
  function X" instead of only naming the table.

**And the trip list did not need editing, which is worth checking rather than
assuming.** `tenancy_contract_check` compares advisor rule names to the trip
list **both ways**, so a new rule name would have required a same-commit update.
Extending a rule is not adding a name. The one way this could have gone red
silently is the new assertion loop: it is written
`for pair in 'helper_routed:may_read_admin' …`, and that check's trip-pair regex
is **anchored** (`^ *'([a-z0-9_]+):([a-z0-9_]+)'`), so a line beginning
`for pair in` does not read as a trip pair. Verified by running the check's own
regex against the file: ten rules, no stray pairs.