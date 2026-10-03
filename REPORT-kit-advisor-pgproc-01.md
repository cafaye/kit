# REPORT — kit-advisor-pgproc-01

**Packet:** make the RLS advisor able to see through a `SECURITY DEFINER` function.
**Branch:** `worker/kit-advisor-pgproc-01`, base `1f88196`.
**Not pushed.** The manager merges and pushes.

---

## 1. The measurement, and it decided the design

The packet's hinge: **does `pg_depend` record a `SECURITY DEFINER` function's
body→relation dependency at all?**

Answered on a real `postgres:17` (**PostgreSQL 17.11, Debian, aarch64**) — not
from the catalog docs and not by reasoning. The SQL is
`measure-advisor-pgproc.sql` at the repository root; the rows are
`measurement-pgproc.out` and `measurement2-pgproc.out`. Re-runnable:

```sh
docker run -d --name m -e POSTGRES_PASSWORD=p -e POSTGRES_USER=m -e POSTGRES_DB=m postgres:17
docker cp measure-advisor-pgproc.sql m:/measure.sql
docker exec m psql -U m -d m -X -f /measure.sql
```

### The policy's own `pg_depend` — the defect, stated

```
=== Q1: pg_depend rows for the POLICY objects (classid pg_policy) ===
  classid  | objid | objsubid | refclassid | refobjid | deptype
-----------+-------+----------+------------+----------+---------
 pg_policy | 16404 |        0 | pg_proc    |    16403 | n     <-- doc_via_helper calls can_read()
 pg_policy | 16404 |        0 | pg_class   |    16392 | a     <-- ...and its own table
 pg_policy | 16405 |        0 | pg_class   |    16386 | n     <-- ctrl_direct reaches flags
 pg_policy | 16405 |        0 | pg_class   |    16397 | a
```

The helper-routed policy's only non-self edge is **`pg_proc`**. The walk rule 4
was performing terminates after one hop. Q4 makes it explicit — the whole
transitive tree reachable from `doc_via_helper` is two rows:

```
 depth | from_class | objid | to_class | refobjid | deptype | ref_name
-------+------------+-------+----------+----------+---------+----------
      1 | pg_policy  | 16404 | pg_class |    16392 | a       | doc
      1 | pg_policy  | 16404 | pg_proc  |    16403 | n       | can_read
```

So the defect the packet names is real and reproduced: rule 4's catalog half
reads `refclassid = 'pg_class'` and there is nothing there to read.

### Three body kinds, three answers — and this is the whole finding

`pg_depend` on the FUNCTION:

| body kind | `pg_depend` on the function carries | answer |
|---|---|---|
| `language sql`, **string** body (`as $$ … $$`) | `pg_namespace` only — **one row** | **(b) not recorded** |
| `language plpgsql` | `pg_language`, `pg_namespace` | **(b) not recorded** |
| `language sql`, **`BEGIN ATOMIC`** body (PG14+) | `pg_proc → pg_class → flags`, `deptype 'n'` | **(a) RECORDED** |

```
=== Q8: THE VARIANT. Same helper written as BEGIN ATOMIC ===
 classid |  refclassid  | refobjid | deptype | referenced_relation
---------+--------------+----------+---------+---------------------
  pg_proc | pg_class     |    16386 | n       | flags        <-- the edge exists
  pg_proc | pg_namespace |    16385 | n       |

=== Q10: a plpgsql helper, for the third body kind ===
 pg_proc | pg_language  |    13637 | n       |
 pg_proc | pg_namespace |    16385 | n       |              <-- nothing

=== Q11: does rule 4 see either helper? (the defect, stated) ===
    polname     | rule4_fires
----------------+-------------
  ctrl_direct    | t
  doc_via_helper | f
```

**The answer is (b) for the shape a hand-written helper actually takes, and (a)
for the one body kind nobody writes by hand.** That is not a hedge; it is a
split, and it is the design decision. Q9 confirms the mechanism from the other
side: `prosrc` is **empty** for the `BEGIN ATOMIC` body, because PG14+ parses it
at `CREATE FUNCTION` time and the parse is what records the dependency. So
`probin IS NOT NULL` and `prosrc <> ''` partition the two cases exactly, in the
catalog, with no guessing.

I re-ran the whole script against a second, separately-created container and got
byte-identical rows. The committed output is a measurement, not a transcript.

### The residual, and why no `prosrc` scan shipped

The string-body edge lives only as **TEXT** in `prosrc` (Q5 prints it: the body
is `select exists (select 1 from m.flags f where f.is_admin)`). Catching it means
matching table names in SQL text. That is a different and worse rule:

- it fires on a table named in a **comment** (`-- see profile_flags for why`),
- it fires on a table name inside a **string literal**,
- it fires on a table that has since been **dropped** — `prosrc` is not a
  dependency and does not track DDL.

The brief's own bar decides it: *"a proof two checks could satisfy proves
neither"* and *"an unmeasured guess invalidates everything downstream."* A scan
whose misses are silent, pointed at the one rule an adopter trusts about who may
edit what, is a worse outcome than a named gap.

**So: the hop ships and the scan does not**, and the gap is stated in
`advisor.sql`'s **first screen** (§"what this does not find"), not buried in a
rule's comment — so a reader meets it before trusting a row.

---

## 2. What shipped

### `policy_reaches` — `view_reads`' walk, on rule 4's subject

The brief said reuse `security_definer_view`'s transitive `pg_depend`/`pg_class`
walk rather than invent a second one. Done: `policy_reaches` is the same shape,
same depth bound (16, `view_reads`' bound for `view_reads`' reason), same
`min(depth)` + `group by` (measured `{plain, plain}` on `view_reads`: `pg_depend`
records one row per (object, reference)).

Two deliberate shapes:

- **Hop 2 is taken only from a `pg_proc` ref.** A relation reached in hop 1 is a
  relation, and nothing depends on relations from here — taking it from
  `pg_class` too would drag every index of every reached table into the walk.
- **`through_proc` is carried through the recursion, not recovered.** Recovering
  it means matching `pg_depend` from the relation — the *reverse* direction —
  which would name every function that **reads** the table rather than every
  function the policy **called** to reach it. This is what makes the finding say
  "reached through function X" instead of only naming the table.

Rule 4's catalog half now joins `policy_reaches` instead of `pg_depend`, and
reports `via_functions` in `metadata` and in the detail prose. **Same rule name,
same `cache_key`, same ERROR level** — one more join on one rule, not an
eleventh rule.

### The fixture — one writable table, three routes

In `tests/tenancy_test.sh`'s existing idiom, appended to `advisor_fixture.sql`:

| object | route to the SAME caller-writable `writable_flags` | must |
|---|---|---|
| `direct_policy` | **direct**, no function in the path | fire |
| `helper_routed` | through a `BEGIN ATOMIC` `SECURITY DEFINER` helper | **fire** |
| `helper_opaque` | through a **string-body** `SECURITY DEFINER` helper | **stay silent** |

**Why the control is not optional, in the terms the packet used.** The pair of
observations *"rule 4 now fires on a helper-routed policy"* and *"rule 4 fires on
everything"* are **the same observation** without `direct_policy`. The suite
already has the receipt: `AGENTS.md`'s breakage 75 is a control that two
different checks could satisfy, which read as evidence for a check that had been
dead for a whole run. And the fixture makes the stronger point available —
`direct_policy` and `helper_routed` reach **one** table by **two** routes, so the
rule has to answer differently about the *route* or it is counting tables.

`helper_opaque` is the negative with the most teeth. It is the *same table*,
reached through a helper that differs from `helper_routed` **only in how the
body was written** — the one difference the measurement says decides whether the
catalog carries the edge. Asserted silent. Without it, `helper_routed` firing is
consistent with a rule that reads `prosrc` too, or with a rule that fires on
every policy that calls a function.

Assertion 7c asserts all three, including that the control's `via_functions` is
**empty on the same table the positive reached** — otherwise "the control is
green" and "the control is a rule that never reports" are indistinguishable.

---

## 3. Verification

| what | how | result |
|---|---|---|
| the measurement | `docker exec … psql -f measure-advisor-pgproc.sql` on a fresh `postgres:17` | rows as quoted above |
| the measurement, again | second container, same script | byte-identical |
| the fixture + rule | `bash tests/tenancy_test.sh` | see §4 |
| rule red on the fixture | assertion 7c, `helper_routed` | fires |
| control green | assertion 7c, `direct_policy` fires with `via_functions` empty; `helper_opaque` absent | silent |
| trip list ↔ rule names, both ways | `tenancy_contract_check` in `tests/validate.sh` | green |

`tenancy_contract_check` needed no edit: rule 4 already had a trip pair
(`rls_references_user_metadata:admin_only`), and extending a rule is not adding a
rule name. I checked the one way this *could* have gone red — the new assertion
7c loop is written `for pair in 'helper_routed:may_read_admin' …`, and that
check's trip-pair regex is anchored (`^ *'([a-z0-9_]+):([a-z0-9_]+)'`), so the
loop does not read as a trip pair. Verified by running the check's own regex
against the file: ten rules, **no stray pairs**.

---

## 4. Honest loose ends

- **The gap is documented, not machine-readable.** `helper_opaque` is asserted
  silent, so the suite *proves* the limit — but a reader running the advisor gets
  **no row** about the string-body helper. I considered a second rule naming the
  unmeasurable shape and did not ship it: it needs a `tenancy.rls-*` id in
  `core/docs/tenancy.md` and an entry in `core`'s in-process table, both outside
  this worktree, and the packet's own rule is that a rule proved only in CI is a
  rule a developer running the gate locally has learned nothing about. A
  half-wired rule is worse than a documented gap. **`core`'s
  `tenancy_check.py` is where that rule belongs** — it reads migration text and
  could catch a *string* helper in a migration, which is the case the catalog
  cannot reach at all.
- **No `self_test` breakage.** The mutation for this change is "delete the hop",
  which makes assertion 7c's `helper_routed` trip go red **by name** — but the
  suite's own `BOUND` semantics mean a breakage I add but do not *run red* is
  worse than none (the packet's predecessor says exactly this). The mutation is
  written down in the handoff for whoever runs it.
- **The `BEGIN ATOMIC` helper is a workaround, not a recommendation.** It is
  also nearly unusable in practice: an `END`-terminated body cannot be written by
  a generator without knowing the column list, and `security_invoker` is a view
  option rather than a function one. The next packet's helper will be a string
  body, i.e. **`helper_opaque`'s shape, which this advisor cannot see through.**
  The finding is that the catalog cannot express it, and the remedy has to be a
  review-time one.

---

## 5. Commits

| commit | what |
|---|---|
| `21ab701` | the measurement: three body kinds, three `pg_depend` dumps, and the rule-4 blind spot (Q11) |
| `a354a8a` | `policy_reaches` + rule 4's `pg_proc` hop; the residual named in the file's first screen |
| `b39bd8f` | the fixture — one writable table, three routes — and assertion 7c |
---

## 5. The red proof, and the check proven able to go red

`bash tests/tenancy_test.sh`, green on this branch:

```
   rls_references_user_metadata -> direct_policy
   rls_references_user_metadata -> helper_routed
   10 rules, 13 fixtures, every rule naming itself and the object it fired on.
   helper_routed -> via_functions may_read_admin on the SAME table
   direct_policy -> via_functions '(empty, the control)' on the SAME table
   helper_opaque -> silent, and that is the rule's measured limit: the catalog
      does not carry a string body, so no rule reads one.
EXIT=0
```

Then the same command in a throwaway `git archive` copy of this branch with the
detection clause deleted — **the recursive `union` arm of `policy_reaches`, 18
lines, and nothing else**:

```
   rls_references_user_metadata -> direct_policy
FAIL: rls_references_user_metadata did NOT fire on the fixture built to trip it (helper_routed).
      A rule that has never fired is a rule nobody can trust, and this one is
      indistinguishable from a rule that does not work.
       reported instead: login_role_security_definer_executable on may_read_admin
       reported instead: login_role_security_definer_executable on may_read_admin_opaque
       …
FAIL: an advisor rule cannot fire
EXIT=1
```

Three things are measured there, and none of them is the first one:

1. **`direct_policy` fires and `helper_routed` does not.** The control is green
   while the defect is red. That asymmetry is what makes it a control rather
   than a second positive.
2. **The mutation deletes a clause and nothing else.** The CTE, the join, the
   `via_functions` column and both new assertions all survive, so the run fails
   *on the assertion about the defect* and not on a syntax error — the
   discipline AGENTS.md records for breakage 90 (`delete`, not `sed`) and for
   breakage 75 (a fixture that mutates one thing).
3. **The honest half, observed rather than asserted.** With the hop gone, rule 4
   is silent on the helper-routed policy while **rule 6 still reports
   `login_role_security_definer_executable` on `may_read_admin`** — the very
   helper whose body rule 4 can no longer follow. That is the position the rest
   of this report argues in prose: something sees the helper, and rule 4 does
   not claim to be the thing that does. A helper written the ordinary way is
   invisible to rule 4 and visible to rule 6, and the suite now asserts both
   halves rather than only the one that flatters the new code.

## 6. For the packet that writes the helper

**Write it `BEGIN ATOMIC`, and record why.** Not to satisfy a lint — because a
parsed body is a body the account boundary can see, and an unparsed one is text.
The measurement table above is the argument, and the two fixtures
(`may_read_admin`, `may_read_admin_opaque`) are the two outcomes, differing in
one keyword of the `CREATE FUNCTION` and nothing else.

If the helper has to be a string body, the mitigation does not depend on the
catalog carrying anything: **deny `INSERT`/`UPDATE` on the flags table from the
login role**, so there is no writable input for the policy to decide from. That
is the same remedy rule 4's `remediation` column prints.

---

## 6. A note for the manager: the red proof was committed into the template

While this packet ran, a **second instance of the same worker was committing in
this worktree**. It applied the same mutation to the real
`templates/database/tenancy/advisor.sql` and committed it (`030985c`) rather than
applying it to a throwaway copy — so the tree at HEAD carried
`and false -- MUTATION: the pg_proc hop, deleted` in `policy_reaches`' recursive
arm, which deletes the hop and turns assertion 7c red on `helper_routed`.

`f305514` restores `advisor.sql` from `b39bd8f`. **The two files that matter are
byte-identical to the tree the green run was taken against** — verified with
`git diff --quiet b39bd8f HEAD -- templates/database/tenancy/advisor.sql
tests/tenancy_test.sh`, both YES — so the green evidence above describes HEAD.

Two commits on this branch (`1449918`, `030985c`) were written by that instance
rather than by the thread that produced the rest of this packet. They are
**content**-consistent with the measurement — the report, the handoff, the
changelog entry and the red-proof log lines all agree with the SQL — but the
manager should read them as unreviewed by a second pair of eyes.
