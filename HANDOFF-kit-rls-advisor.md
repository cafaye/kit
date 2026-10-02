# HANDOFF — kit-rls-advisor-01

> **SUPERSEDED by kit-rls-advisor-02, which fixed this packet's successor move.**
> The "successor's first move" section at the bottom pointed at
> `cafaye.credential_tables()` returning zero rows to the `cafaye` role. That is
> **fixed, committed and proven able to fail** — three further commits below, and
> `moon/logs/REPORT-kit-rls-advisor-02.md`. Do not go and do it.
>
> Everything above this line is kit-rls-advisor-01's, unchanged.

**State: DONE and verified.** Nothing is half-done and nothing is left failing.
The hour is over; the work is not. Read the report first:
`moon/logs/REPORT-kit-rls-advisor-01.md`.

Branch `worker/kit-rls-advisor-01`, three commits on `6a6fa29`:

```
5df2230  feat(kit-tenancy): the database grades its own account boundary
88d0bfc  test(kit-tenancy): the advisor runs here, and every rule is proven able to fire
5583d5d  docs(kit): what the advisor proves, what it does not, and the gate's three reds
```

**Not pushed. Not merged. Not tagged** — per the packet.

## Done and verified

- `templates/database/tenancy/advisor.sql` — eight RLS rules as one function,
  `cafaye.advisor_findings(p_schemas text[])`, the advisor's nine-column row
  shape. Nothing vendored from `moon/refs/`; every substitution from the source is
  a comment at the point of the difference.
- `tests/tenancy_test.sh` assertion **6** (zero `ERROR`/`WARN` on the two tables
  the substrate writes, over a scope derived from its own policies),
  **6b** (the MD24 exemption released by one hand-written policy, naming it, and
  clean again after), **7** (all eight rules, each on a fixture built to trip it,
  each naming itself and its table).
- `tests/validate.sh` — the `.sql` parse-loop arm and the presence check.
- `tests/artifacts.json` — `database/tenancy/advisor`.
- `README.md`, `templates/database/tenancy/README.md`, `CHANGELOG.md`.
- **`bash tests/tenancy_test.sh` → EXIT 0**, standalone.
- `assertions.txt` and `substrate.sql` **untouched**, deliberately — reasons in
  report §5.

## The currently-failing command, and its real output

`bash tests/validate.sh` exits 1 on this branch with **three reds, none of them
this branch's**. Measured on untouched master at `6a6fa29` to establish that:

```
FAIL tests/canary_test.sh  (a canary secret reaches no exporter)
       canary: the metrics pipeline points at ['debug'], expected ['file/capture']
FAIL tests/stack_live_test.sh  (the fetched stack runs; a trace and a metric land)
       tests/stack_live_test.sh: line 266: detailed: command not found
       ... EXIT=1 on master too, byte-identical PASS count, and
       `git diff master -- tests/stack_live_test.sh` is EMPTY
FAIL tests/self_test.sh  (94 breakages: 92 red, 2 green-expecting)
       FAIL self_test: breakage 23b ... the gate exited 1, so the skip was not clean
              FAIL tests/canary_test.sh
              FAIL tests/stack_live_test.sh
              FAIL tests/isolation_test.sh
              FAIL tests/tenancy_test.sh
FAIL: 3 check(s) failed.
```

23b is a GREEN-expecting breakage: it asserts a gate run with an interpreter below
the floor exits **cleanly**. Its throwaway copy ran on a busy box where four docker
suites went red, so the exit was 1 and the skip was not clean. The mutation is
correct; the environment was not.

**Do not "fix" these three.** They are not in this packet's files, and
`stack_live_test.sh`'s `line 266` is a pre-existing unquoted-heredoc expansion in
a file this branch does not touch.

## Half-done, and why

Nothing. Every gate-shaped consequence of the new file was found and closed —
the `.sql` parse arm, the presence check, the artifact table, both READMEs, the
CHANGELOG. The two files the packet told me not to touch were not touched.

## The successor's first move

**DONE, by kit-rls-advisor-02. Read the rest of this file for what it cost and
what it did not do.**

**`cafaye.credential_tables()` returns zero rows in a session whose `"$user"`
schema is `cafaye`.** Found while porting, recorded in report §1, and NOT fixed
because `substrate.sql` was out of scope and MD24 had just landed on it.

The mechanism: `pg_get_expr` deparses a name unqualified whenever the **reader's**
`search_path` resolves it, and `"$user"` is a `search_path` entry. Measured on this
kit, same database, same policy:

```
as role alpha    -> (account_id = ( SELECT cafaye.current_account_id() AS current_account_id))
                    credential_tables() returns: public|api_keys|token_digest
as role cafaye   -> (account_id = ( SELECT current_account_id() AS current_account_id))
                    credential_tables() returns: (no rows)
```

`credential_tables()`'s regexp requires the qualified spelling, so an admin auditing
credentials as the cluster's own admin role is told there are none. That function's
own comment already warns that *"an audit query that returns an empty column forever
looks exactly like an audit query that found nothing"* — this is that.

The fix is the treatment `advisor.sql` already applies to its own regexps:
`(cafaye\.)?`, with the `"$user"` reason in a comment. Its consumer is MD24's audit,
so this is an audit gap, not a cosmetic one. `advisor.sql`'s block above
`substrate_written` states the reasoning in full — read it rather than reinventing
it, and note that the advisor deliberately accepts *more* forms than the substrate's
function does, because over-recognising a substrate policy still leaves a
hand-written one reported.

> **The paragraph above recommends the wrong fix, and kit-rls-advisor-02 took the
> other one.** `(cafaye\.)?` is a regexp over a pretty-printer's output: it accepts
> two spellings of one name, stays silent on a third, and the next reader cannot
> tell which spelling the audit saw. The audit now reads `pg_depend` — OIDs, not
> spelling — and `advisor.sql` keeps `(cafaye\.)?` because its rules are about what
> a predicate *says*, with the residual reader-dependence listed under that file's
> own "what this does not find". The advisor still accepts more forms than the
> substrate's audit now does, for the opposite reason: the substrate's no longer
> reads text at all.

---

# HANDOFF — kit-rls-advisor-02 (appended here, same branch)

**State: DONE and verified.** Report: `moon/logs/REPORT-kit-rls-advisor-02.md`.

Same branch `worker/kit-rls-advisor-01`, three commits on `1863264`:

```
f205be7  docs(kit-tenancy): four places described the audit's old behaviour, and three of them were wrong
26d4bdd  test(kit-tenancy): the credential audit is read as three roles, and required to give one answer
efa49e5  fix(kit-tenancy): the credential audit stops reading a spelling, so it stops depending on the reader
```

**Not pushed. Not merged. Not tagged.**

## Done and verified

- `templates/database/tenancy/substrate.sql` — `cafaye.credential_tables()` only.
  It resolves the digest function and the column it is compared against from
  `pg_depend`, which records them as **OIDs**, instead of matching a regexp
  against `pg_get_expr`'s output.
- `tests/tenancy_test.sh` assertion **8** — the audit read as `alpha`, as
  `cafaye` and as `alpha_app`; one answer, **non-empty**, with a control that
  asserts the two renderings still differ so the property cannot pass vacuously.
- The four docs places that described the old behaviour: `advisor.sql` (three
  sentences that had become false, plus one honest limitation added to that
  file's own "what this does not find"), `templates/database/tenancy/README.md`,
  `DECISIONS.md` MD24 limit 5, `templates/database/contract.json`'s `why`, and a
  `CHANGELOG.md` entry.
- **`bash tests/tenancy_test.sh` → EXIT 0** — 39 assertions all pass, FORCE
  control 11 red, advisor 0 ERROR / 0 WARN, 8/8 rules fire, assertion 8 green.
- **`bash tests/validate.sh --static-only` → EXIT 0** — 318 PASS lines, 6 skips
  reported, no FAIL and no BOUND.
- **Assertion 8 is proven able to fail**: with only the pre-fix
  `credential_tables()` body restored, the same suite exits 1 at assertion 8 with
  `as cafaye … the audit says : (no rows)`, and every assertion above it is still
  green.
- `assertions.txt`, `isolation.sql`, `artifacts.json` untouched. No advisor rule
  renamed, updated or relaxed.

## Half-done, and why

Nothing. The one gap is **measured and written down rather than closed**: the
`pg_depend` shape is verified on Postgres **16.15 and 17.x** and **not on 15**,
kit's floor, because no `postgres:15` image was on this machine. The substrate's
comment says so in those words.

## The currently-failing command, and its real output

`bash tests/validate.sh` (full) still exits 1 with the **same three reds** this
handoff already recorded — `tests/canary_test.sh`, `tests/stack_live_test.sh`
(`line 266: detailed: command not found`) and `tests/self_test.sh`. None is this
packet's file, and the predecessor measured all three on untouched master at
`6a6fa29`. **I did not re-measure master**: its `self_test` tier is 94 whole
gates in sequence and the box was busy, so that claim is inherited from
kit-rls-advisor-01 rather than re-run. `--static-only`, which is the gate this
packet asks for, is green.

## The successor's first move

**Measure the `pg_depend` shape on `postgres:15`.** Everything in `efa49e5` rests
on `CREATE POLICY` recording a `pg_proc` row per function called and a `pg_class`
row with `refobjsubid > 0` per referenced column. It is measured on 16.15 and
17.x. Report §7 has the exact commands. If the shape holds, one comment line
changes; if it does not, the substrate needs a version guard on the audit rather
than the trust it now has.

Second, if the hour is longer than that: `templates/database/tenancy/advisor.sql`
has the same class of defect in a smaller body — every rule reads the reader's
rendering — and it **cannot** be fixed with `pg_depend`, because
`rls_policy_always_true` is a predicate the catalogs record as a boolean. The
decision is what a rule claims when it cannot see the text, and that belongs to
whoever owns the rules.