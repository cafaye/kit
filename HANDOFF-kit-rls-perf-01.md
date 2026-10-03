# HANDOFF — kit-rls-perf-01

Read `REPORT-kit-rls-perf-01.md` first if you have not. This page is the first move, not
the summary.

## Your first move, exactly this

**Run `bash tests/tenancy_test.sh` on a clean tree.** Two commits landed whose fixtures and
trip pair have never been executed by the whole suite. The rule itself was proven by hand on
a real `postgres:17` (fires on `correlated_membership`, silent on `inverted_membership` and
`linked_only`) and the trip list was compared to the rule names with the check's own regexes
in both directions — but the suite builds `kit-tenancy-postgres:17` from
`templates/compose/postgres`, which needs ghcr.io, and that build was not reached inside the
hour.

The suite asserts 39 assertions over 10 fixtures and there are now 11 fixtures. Everything
this packet touched is additive, so **the 38 existing assertions should not move**. If one
does, the cause is a fixture in the same schema reaching a rule it did not before — read the
new fixture list before you read the failure.

**Then wire both new gates in, in this order:**

1. `tests/rls_perf_test.sh` into `validate.sh`'s **observability** phase, beside
   `tenancy_test.sh` and `isolation_test.sh`, with the same contract: SKIP(3) without docker,
   naming what is missing, and **`$?`-aware dispatch** so a skip is reported as a skip and a
   FAIL is a FAIL. It runs a docker cluster, so the phase's time bound covers it.
2. **Sequentially, never concurrently.** The suite shares one docker daemon and a collision
   looks exactly like a real failure. The other kit gates on this box are the constraint, not
   the harness.

**Then add the `self_test` breakage for rule 10, and RUN IT RED before you commit it.** The
packet's rule is *do not add a breakage you have not run*. The mutation is the cheapest
correct one:

```
# in templates/database/tenancy/advisor.sql, rule_correlated_membership:
#   delete the `(m[2] ~ ('(^|[^a-z0-9_$])' || po.relname || '\.') ...)` test
```

which makes the rule silent on its own fixture and turns assertion 7's trip pair
`rls_policy_correlated_membership:correlated_membership` red **by name**. `expect_red_check`
matches `FAIL $want`, and `$want` has to be the check's **label**, not the finding's prose —
that is kit-22 breakage 75/76/77, three recipes that could not tell a caught failure from a
missed one.

## The one thing to know before you touch the rule

`postgres_get_expr` output is **not** the text that was executed, and the rule is written
against the rendered form. Three measured facts, all in the rule's comment:

- The self-reference sits **inside** the `IN`'s nested `WHERE (…)` group, so a single regexp
  over the whole qualifier misses it. That is why the subquery is extracted with
  `regexp_matches` first. If you "simplify" it into one regexp, it goes silent on its own
  fixture and the trip pair catches it — but only if the suite runs.
- The schema prefix is **not fixed**: `slow_doc.col` or `perf.slow_doc.col` depending on the
  *reader's* `search_path`. Both are accepted for that reason.
- Postgres' ARE has no word-boundary escape — `\b` is a backspace, and the spelling is
  `[[:<:]]` — and repetition counts cap at **255**. Both cost a run here.

## The three traps, in the order they will bite you

1. **`\b` is not a word boundary in Postgres.** It is a backspace. If you need a boundary,
   write `(^|[^a-z0-9_$])`. The rule already does.
2. **`{0,300}` is a syntax error, not a near-miss.** The cap is 255. A pattern that exceeds it
   fails to install, and a rule that fails to install takes `advisor_findings/1` with it, so
   **every** rule goes silent at once and the trip list is the only thing that notices.
3. **`||` binds tighter than `or` in Postgres.** `'a' || x || '.' or 'b' || y` is a text OR
   and the function will not install. Write `(expr ~ A) or (expr ~ B)`. Cost one run.

## Where Part 2 starts, and why it starts there

The `security definer` helper is **not** in the tree. Read `REPORT-kit-rls-perf-01.md` §3 for
the argument; the operative finding is short:

> Rule 4's catalog half reads `pg_depend` with `refclassid = 'pg_class'`, so it catches a
> policy whose expression reaches a table a login role can write. A policy that calls a
> `SECURITY DEFININER` helper reaches that table through the **function's body**, and
> `pg_depend` on the policy records the FUNCTION, not the relation. So a helper makes rule 4
> go silent on exactly the defect rule 4 exists for, and nothing in the file notices.

**So the next packet should build the advisor's ability to see through a function, not the
helper.** In order:

1. **A `pg_proc` walk**, as the transitive `pg_depend`/`pg_class` walk `security_definer_view`
   already does for views. Measure whether `pg_depend` records a `SECURITY DEFININER` function's
   body→relation dependency **before** designing the rule — if it does not, the rule needs
   `prosrc` and that is a different and worse rule, and the difference decides the design.
2. **A fixture for it**, in the same idiom: a definer helper that reads a table a login role
   can write, a policy that calls it, and a control where the same table is reached directly.
   The control is not optional — the file's own lesson is that a proof two checks could satisfy
   proves neither.
3. **Only then the helper**, with its arguments ignored and its body reading
   `cafaye.current_account_id()`. And the argument list is the whole attack surface: a definer
   that trusts its `org_id` argument is a privilege escalation with a function signature, which
   is rule 6's own wording.
4. **`protect_table` last, and loudly.** `identity` embeds a copy of `isolation.sql` and
   migrations are append-only, so a template change does **not** reach deployed services by
   itself. Any change there needs a migration note and a `MIGRATIONS.md` section if it is a
   MAJOR.

## Do not

- **Do not soften `rls_policy_correlated_membership` to WARN-and-stop.** It is already WARN and
  it is deliberately narrow; widening it to correlation-in-general fires on the 56 ms `EXISTS`
  shape that `rls_perf_test.sh` measures as already fast, which is how a performance rule gets
  switched off.
- **Do not raise the 10x floor** in `rls_perf_test.sh` to the measured 111x. The constant is not
  the claim; the sign is. A fixture too small to separate the two shapes must fail.
- **Do not change `isolation.sql`, `assertions.txt` or `protect_table`.** Nothing in the
  tenancy proof was touched and nothing in it needs to be. If you find yourself editing one,
  you are doing a bigger packet than the one you were handed.
- **Do not add a `self_test` breakage you have not run red.** It is better absent than
  unexecuted, and the report says which one is missing on purpose.
- **Do not push.** `worker/kit-rls-perf-01` has two commits and a report to write on top; the
  manager merges and pushes.

## State of the branch

```
b150100  P1-24: the policy join direction, measured on a real cluster
5cb0a2c  advisor rule 10: an IN (SELECT) correlated to the policy's own row
```

Both leave the tree consistent. Neither has been through `bash tests/validate.sh` in full —
see `REPORT-kit-rls-perf-01.md` §5 and §6 for exactly what was and was not run.