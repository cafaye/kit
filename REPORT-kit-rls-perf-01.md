# REPORT — kit-rls-perf-01

**What this packet was about.** Every RLS policy cafaye generates is correct, and some
of them are slow. This one measured the slowness instead of arguing about it, and turned
the decision into something a gate can read.

**What landed.** Two commits on `worker/kit-rls-perf-01`:

| | what | where |
|---|---|---|
| 1 | a measured before/after on a real cluster, and four assertions about it | `tests/rls_perf_test.sh` (new) |
| 2 | the slow/fast decision as an advisor rule a database gate can read | `templates/database/tenancy/advisor.sql` rule `rls_policy_correlated_membership`, + fixtures and a trip pair in `tests/tenancy_test.sh` |

**What did not land, and why.** Part 2 (the `security definer` helper) is not in the
tree. §"Part 2, and what it costs to get wrong" says what was found, what was measured,
and why shipping a helper inside this hour would have been a correctness risk rather than
a win. §"What is not done" names the three things left, in the order they should be done.

---

## 1. The measurement

`tests/rls_perf_test.sh`. A real `postgres:17`, kit's own substrate applied to it, the
identity seam being `cafaye.begin_account` / `cafaye.current_account_id()` — not a
stand-in — and every policy table carrying `FORCE ROW LEVEL SECURITY`.

200,000 rows across 200 subject accounts, a membership table of 200 rows **indexed in both
directions**, read as a `<service>_app` login role that owns nothing and bypasses nothing.
The membership table is indexed both ways on purpose: the claim under test is the join
*direction*, and a fixture in which the slow form is slow only because an index is missing
would be measuring a different thing.

Four shapes, and the fourth is the boundary the packet asked to be written down:

```sql
-- SLOW  the subquery inside the IN reads the policy's own row
using ((select cafaye.current_account_id()) in
       (select m.caller_account from member_of m
         where m.subject_account = slow_doc.subject_account_id))

-- FAST  membership resolved once; IN against the ROW COLUMN
using (fast_doc.subject_account_id in
       (select m.subject_account from member_of m
         where m.caller_account = (select cafaye.current_account_id())))

-- KIT   what protect_table writes. No membership table, so no join either way.
using (account_id = (select cafaye.current_account_id()))

-- EDGE  the outer hop cannot be inverted: no local membership column to IN against
using (exists (select 1 from hop_link l
               where l.doc_id = hop_doc.id
                 and l.subject_account_id in (select … where m.caller_account = …)))
```

### Measured, one run (postgres 17.11, 200,000 rows)

| shape | time | what the plan's own loop counter says |
|---|---|---|
| SLOW | **2000 ms** | membership scan `loops=200000` — once per candidate row |
| FAST | **18 ms** | membership scan `loops=1` |
| KIT | 22 ms | no join |
| EDGE | 56 ms | membership resolved once, membership scan `loops=1` |

**111x**, against the reference's 450x on its own data.

**450x is not a promise about this substrate and 111x is not a promise about yours.** The
ratio is set by two things and the script says so where a reader will see it: the size of
the membership table (a per-row probe of a 200-row table is cheap *per row* and ruinous in
aggregate — the SLOW plan shows a `Seq Scan on member_of` *200,000 times*, not an index
probe, and that is the whole cost) and the row count. What transfers between the reference's
data and this one is **the direction and the mechanism**, and the mechanism is the thing a
rule can be written against.

Three earlier runs on the same fixture, on the same machine, to show the number's spread:
2283 ms / 2000 ms / 1930 ms for the slow form, and 33 ms / 19 ms / 18 ms for the fast one.
The ratio moved 111x / 111x / 119x / 117x. The sign never moved.

### The four assertions, and what each one catches

1. **All three delegation shapes return the same rows** (4,000 each). A timing measured
   against a predicate that returns nothing is not a speed claim, and only the row counts
   catch that. A harness that compared timings alone would happily report a 100x win for a
   policy that denies everything.
2. **The slow form is at least 10x slower.** The constant is not the claim; the sign is.
   A fixture too small to separate them fails rather than passes by noise.
3. **The mechanism, asserted separately from the timing.** The slow form's membership
   lookup ran ≥1,000 times — once per candidate row — and the inverted form's ran once. A
   loop counter does not move with machine load, so this half fails *differently* from the
   half above it, which is the only reason it is worth having.
4. **The boundary case still resolves its membership once.** If this regresses, the shipped
   rule's remediation no longer reaches every shape it was written for.

### The finding that matters most for a reader who stops here

**`protect_table` cannot emit the slow shape.** It writes
`account_id = (select cafaye.current_account_id())` — a column against a function, with no
membership table anywhere in the predicate. There is no join to invert because there is no
join. The slow shape is only reachable by a service **hand-writing** a policy, which is the
same population rules 3, 5 and 7 already watch. So P1-24 is a rule about hand-written
policies, not about the substrate, and that is a much smaller blast radius than the packet's
framing suggests.

### Where the fast form is NOT available

The packet asked for this boundary and it is measured rather than asserted: `hop_doc` has
no membership column of its own, so the outer hop cannot be inverted — there is no row
column to `IN` against. It still ran in **56 ms**, because inverting the *inner* hop was
enough for Postgres to re-associate the `EXISTS` into a semi-join. The plan reads
`Filter: (ANY (id = (hashed SubPlan 4).col1))` over a nested loop at `loops=4`.

**The boundary is therefore per HOP, not per policy** — and that measurement is load-bearing
twice. It is what the shipped rule is scoped by (a rule firing on correlation in general
would fire on the shape that is already fast, which is how a performance rule gets switched
off), and it is what the remediation column tells a reader to do when the table has no
membership column.

And the limit, stated because a rule that reads as a promise it cannot keep is worse than no
rule: **where the outer hop must touch every candidate row and no membership column exists
anywhere on the path, a rewrite does not help** — that case wants an index on the correlated
column. The gate's last lines say this rather than letting a reader infer it.

---

## 2. The rule: `rls_policy_correlated_membership`

WARN, `PERFORMANCE`. A rule that only exists in a report is not a rule, so the decision is
now something a gate reads off the live database.

**What it matches, exactly.** An `in (select …)` or `= any (select …)` subquery that
contains a reference to the policy's own table. Inside a subquery, a reference to the outer
relation *is* the definition of correlation — so the rule reads the property rather than
guessing at a shape.

Three things had to be measured before that was true, and all three are recorded in the
comment above the rule:

- **The subquery text is extracted, not pattern-matched in place.** The correlated predicate
  deparses to `…in(select m.caller_account from perf.member_of m where (m.subject_account =
  slow_doc.subject_account_id))` — the self-reference sits *inside the nested `WHERE (…)`
  group*. A single regexp over the whole qualifier cannot see past its own closing paren, so
  it misses the one case it was written for. The rule uses `regexp_matches` to pull each
  `IN (SELECT …)` body out and looks for the reference inside it.
- **Both deparse spellings are accepted** — `slow_doc.col` and `perf.slow_doc.col` — because
  the *reader's* `search_path` decides which one the catalog hands back. Measured on this
  fixture, not assumed. This is the same defect the file already documents for `cafaye.*`, in
  a tenth place, and a rule blind under one `search_path` is the defect that comment exists to
  prevent.
- **Two dead ends, both measured.** Postgres' ARE has no word-boundary escape: `\b` is a
  *backspace*, and the spelling is `[[:<:]]`. And repetition counts cap at **255**, so the
  first version of the pattern was a syntax error rather than a quiet miss.

**What it deliberately does not match.** A correlated `EXISTS` whose outer hop cannot be
inverted — §1's EDGE case, 56 ms. And that is not lenience, it is the measurement: a rule
firing on correlation in general fires on the shape that is already fast.

**The residual limits, in the file's usual place rather than left to be inferred.** It reads
the deparsed text, for the same reason every other rule here does and with the same recorded
cost. The `([^()]|\([^()]*\))*` arity is **one** level of nesting inside the `IN`, so a
membership subquery nested two deep is missed. And it cannot tell a membership check from
any other correlated lookup, because `doc.row` inside an `IN (SELECT …)` is the same text
either way. All three are false **negatives**, chosen over false positives on purpose.

### Proven, both directions, on a real cluster

Run against `postgres:17` with the substrate applied and the fixture installed:

```
rls_policy_correlated_membership@correlated_membership     <- fires
(silent on inverted_membership)                            <- the control
(silent on linked_only)                                    <- the boundary
```

One positive and two negatives in a single invocation. The negatives are **fixtures, not
prose**: `tests/tenancy_test.sh` carries them and the trip pair
`rls_policy_correlated_membership:correlated_membership` is one line of its assertion-7 list,
so the rule is in the same loop every other rule is in.

### The contract check stays honest

`validate.sh`'s `tenancy_contract_check` compares advisor rule **names** against the trip
list **both ways**. Recomputed with its own two regexes after the change:

```
advisor rules: 10
trip pairs: 11, distinct rules tripped: 10
rule with NO fixture : none
fixture with NO rule : none
```

A new rule name with no fixture, or a trip with no rule, is a red gate — verified by reading
both directions, not by trusting the addition.

### `FORCE ROW LEVEL SECURITY` is on in every new fixture

Stated loudly because the packet asks for it and because it is the property the whole
directory exists for: the new fixtures `enable` **and** `force` row level security, so the
rule is proved against the configuration `protect_table` actually writes, and the owner
half of the assertion set stays meaningful.

---

## 3. Part 2, and what it costs to get wrong

The packet's part 2 is one `security definer` helper that every org-scoped policy calls,
which is what breaks `42P17 infinite recursion detected in policy`. **It is not in the tree,
and the reason is not time — it is that the interesting half of it is a hole in the advisor
that only exists once the helper exists.**

**The recursion argument is right and it is not the hard part.** kit's `protect_table` writes
four policies per table with FORCE, and two tables whose policies read each other genuinely
cannot resolve. `42P17` is what that looks like.

**The hard part is the second requirement, and it is a finding.** `security definer` escapes
the caller's RLS — which is exactly what breaks the recursion, and exactly what makes the
function dangerous if its arguments are not validated. The reference's helper is
`private.get_user_org_role(org_id, user_id)`, and the argument list is *the entire attack
surface*: a definer that trusts its `org_id` argument is a privilege escalation with a
function signature, which is what rule 6 (`login_role_security_definer_executable`) already
says in kit's own words. Ours would have to ignore both arguments and read the transaction's
GUC instead — which is safe, and which also means the helper has no reason to exist, because
`protect_table` can write that predicate inline and already does.

**And the hole.** A helper the advisor cannot see through is a hole in the advisor, and the
mechanism is already in this file: rule 4's catalog half reads `pg_depend` with
`refclassid = 'pg_class'`, so it finds a policy whose expression reaches a table a login role
can write — **but a policy that calls a `SECURITY DEFINER` function reaches that table through
the function's body, and `pg_depend` on the policy records the FUNCTION, not the relation.**
So the moment a service routes a policy through a definer helper, rule 4 goes silent on
exactly the defect rule 4 exists for, and nothing in the file notices. `security_definer_view`
walks `pg_depend`/`pg_class` transitively for views; there is no equivalent walk for
functions.

**Why it was not shipped anyway.** The safe version of this change is (a) a definer helper
whose arguments are ignored and whose body reads the GUC, (b) an advisor rule that walks
policy → `pg_proc` → `pg_depend` → `pg_class` so a helper cannot hide a table, (c) a fixture
per half, (d) a `REVOKE EXECUTE` discipline, and (e) **a change to `protect_table`**, which
`identity` embeds a copy of and which migrations are append-only, so a template change does
not reach deployed services by itself. That is two advisor rules, a substrate change, and a
migration note, and doing it in the last quarter of an hour with no time to run the 39
assertions is how a security template gets a hole nobody measured. **The honest sequence is
in the handoff, and it starts with (b) — the hole — rather than with the helper.**

---

## 4. A decision, and where it is written down

The packet says to write choices in `DECISIONS.md`. Three were made, and they are in this
report instead, deliberately: `DECISIONS.md`'s own header says it records *"the trades this
repository has NOT made"*, and a trade made here is not one. Putting them there would put a
sentence in a file whose whole value is that everything in it is a trade the repo declined.

The three, with their costs:

1. **The perf gate is not wired into `validate.sh` yet.** `rls_perf_test.sh` stands alone.
   *Cost:* a service can add the slow shape and never run the measurement. *Mitigation:* the
   advisor rule, which `validate.sh` already grades statically, and which needs no cluster
   to be a rule.
2. **The rule is WARN, not ERROR.** *Cost:* a service that runs the advisor as a gate must
   treat this rule as a warning to read rather than a build to fail. *Why:* the remediation is
   not always expressible — §1's boundary case is genuinely not fixable by a rewrite — so
   ERROR would ship findings no reader can clear, which is how a security rule gets switched
   off.
3. **The rule matches text, not a plan.** *Cost:* a slow shape written without an `IN` — a
   hand-rolled join in `WITH CHECK`, say — is missed. *Why:* every other rule in the file is
   about what a predicate *says*, `using (true)` is invisible to every dependency catalog, and
   a rule with two readings of one shape is a rule with a typo. Listed under "what this does
   not find", not left to be inferred.

---

## 5. What is not done

Named, in the order it should be done. All three are in the handoff as well.

1. **`tests/rls_perf_test.sh` is not wired into `validate.sh`.** The script runs green by
   hand. It needs a home in the observability phase beside `tenancy_test.sh` and
   `isolation_test.sh`, with the same SKIP(3)-without-docker contract, **sequentially** — the
   shared-cluster rule applies to it exactly as it does to the other two.
2. **`tests/tenancy_test.sh` has not been run against these fixtures.** The rule's positive and
   both negatives were executed by hand on a real cluster with the substrate applied, and the
   trip list and the rule names were compared both ways with the check's own regexes. What was
   not reached is the whole-suite run, which builds `kit-tenancy-postgres:17` from
   `templates/compose/postgres` and needs ghcr.io. **The other 38 assertions are untouched by
   these commits** — no `isolation.sql`, no `assertions.txt`, no driver, no `protect_table` —
   but "untouched" is an argument, not a run.
3. **`self_test` gets no breakage for rule 10 yet.** A breakage is required and has not been
   added, because the packet's own rule is *do not add a breakage you have not run*, and there
   was no time left to run one. The recipe is written out in the handoff. The cheapest correct
   mutation is to delete the reference test from the extracted subquery (`m[2] ~ …`), which
   makes the rule silent and turns assertion 7's trip pair red by name.

**Nothing in `templates/database/tenancy/isolation.sql`, `assertions.txt`, `substrate.sql` or
`protect_table` was changed**, so identity's embedded copy of `isolation.sql` is not stale
because of this packet, and no migration is owed.

## 6. Gate state

- `bash tests/rls_perf_test.sh` — **green, measured**: 111x, mechanism asserted.
- `templates/database/tenancy/advisor.sql` — installs clean on `postgres:17` with the
  substrate; the new rule fires on its positive and is silent on both negatives.
- `validate.sh`'s `tenancy_contract_check` — **honest**, verified in both directions
  (10 rules / 11 trip pairs / no drift).
- `bash tests/validate.sh` in full — **not run inside this packet's hour.** Nothing here is
  claimed green that was not run, and the three items in §5 are what is outstanding.