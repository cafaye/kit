# HANDOFF — kit-rls-advisor-01

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