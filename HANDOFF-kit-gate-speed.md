# HANDOFF — kit-gate-speed-03

**Read `REPORT-kit-gate-speed-03.md` for the evidence. This file is the state of
the work.** Short version: the gate is green again, the unclosed breakage was
**59**, and the fix was a revert. The one thing the next worker must not
misread is the handoff-02 warning below — it was **wrong**, and believing it is
what cost this packet an hour.

## Done and verified

- **Breakage 59's `--only` conversion is reverted** (`0399c23`).
  `expect_green_check` appended `--only=$want`; the verdict it names is emitted
  by a **`report`**, and `--only` is applied inside `check`, `check_par`,
  `report_par` and `bounded_check` only. `report()` (`tests/validate.sh:351`)
  has **no filter**: every `PASS`/`FAIL`/`SKIP` it emits is printed and counted
  unconditionally. So no `--only` value could select it, the gate's own
  no-match rule turned that into `exit 1`, and the recipe's **first** assertion
  failed — reporting that **the adoption ceiling is not in force**, with a green
  gate's own findings printed underneath. Measured failure is in the report §1b.
- **Verified both directions on the recipe itself**, same fixture, minutes
  apart: with the conversion, `failures=1` and the failure above; with it
  reverted, `PASS self_test: breakage 59: … stayed green and named the debt` and
  `failures=0`.
- **The six `expect_red_check` conversions (2, 2b, 3, 4, 5, 6) are sound**,
  measured one at a time on their own mutated trees, and independently covered
  by an unsharded run that reached breakage 23 with every recipe a PASS.
  Do not re-open them.
- **`bash tests/validate.sh --static-only` → exit 0**, `PASS: every check
  passed.` The two FAILs handoff-02 §5 recorded are **gone**: both named
  `wt-m39-core-rls-scan-01`, another session's live worktree that was parked
  inside this one and is not there now.
- **The whole suite, sharded, green**: 4/4 shards `PASS`, exit 0, **zero
  `FAIL self_test:` and zero `SKIP self_test:` lines** — including zero
  `SKIP … exited N with NO finding`, the fatal environment verdict.
- `bash -n` clean, `shellcheck -S warning` clean. Counts `tests/validate.sh`
  derives from `tests/self_test.sh` are **unchanged: 94 breakages, 92 reds**.
- **`tests/validate.sh` is not modified in `0399c23`.** The gate's printed
  output is byte-for-byte what it was.

## The correction that matters — handoff-02 §2 was wrong

It said:

> `$want` and the label are only the same string in two of the three helpers.
> `expect_red_check` and `expect_green_check` filter correctly because there
> `$want` is the check's label.

**Both halves of the second sentence are wrong.** `$want` in
`expect_green_check` *is* the label, and that is exactly why the filter fails:
it is a label belonging to a `report`, and no `--only` value selects a
`report`.

The rule that replaces it:

> **`--only` reaches `check`, `check_par`, `report_par` and `bounded_check`, and
> nothing else.** Whether `$want` *is* the label is a necessary condition and not
> a sufficient one. Ask instead **which helper emits the verdict**, because that
> is what decides reachability.

Three sites now say this in the file — breakage 1, `expect_skip_check`,
`expect_green_check`. It was rediscovered once per packet until this one wrote
it down three times.

## Half-done, and why

- **No single unsharded `bash tests/self_test.sh` finished inside the hour, and
  nothing here claims one.** The packet budgets ~13 min; measured here an
  unsharded run reached **breakage 23 in ~15 min** with every recipe a PASS,
  projecting ~55–60 min for all 94 on this box. Full coverage was instead taken
  with the harness's own `KIT_SELF_TEST_SHARD=i/4` × 4 shards — **all four, so
  every recipe ran** — and the numbers are in report §4c. Coverage was verified
  by NAME (96 declared recipes, 96 ran, no gap either way), not by the shards
  summing to 97, because the summing is the arithmetic that can hide a gap.
  That is *sharded* coverage, not one continuous run, and the distinction is the
  whole honesty clause on that feature: a shard's summary cannot claim the suite,
  and four shard summaries concatenated are not the sentence the unsharded run
  prints.
- `no_telemetry_in_readiness.sh` (63 s) and `stack_live_test.sh` (44 s) are
  **still untouched** — 2.2% of the corrected run, last, as planned.

## The next worker's first move

**Overlap the child gates. Do not touch `--only` again — it is done, twice over.**

1. **The filtered child gates are ~85% of `self_test`** (73 × 7.87 s of ~774 s)
   and are independent by construction: `fresh_copy` gives every breakage its own
   parent directory precisely so they cannot see each other.
   `KIT_SELF_TEST_SHARD` already exists (`_shard_claims`) and is the seam.
   **This packet proved the seam works** — four shards ran the whole suite
   inside one hour, which one unsharded run could not. Measure `cores` before
   choosing the pool size; `min(4, cores)` is the first number to try.
2. **The shard key is the breakage NUMBER, not the line number** (`_shard_claims`),
   so adding a recipe does not silently move every later recipe into a different
   shard. Keep it that way.
3. **A shard must not report a number that is true for itself and false for the
   suite.** `_shard_ran` and `_shard_claimed_total` exist for this; a shard that
   ran nothing already fails. A run that executes *all* shards is the one case
   that may claim the whole suite — and it must say it was sharded.
4. Only then `no_telemetry_in_readiness.sh` and `stack_live_test.sh`.

**Do not make `--only` reach `report`-based verdicts** to serve breakage 1 or 59.
It means threading a filter through every `report` call site in a 10,554-line
gate, changing which lines print under a filter, for ~35 s each. Measured and
declined twice now.

**Do not weaken the no-match rule** (`tests/validate.sh:10527`) to make a
converted recipe pass. It is the entire safety net under `--only`: a filter that
names nothing runs nothing and proves nothing. The failure this packet chased was
*caused* by that rule doing its job.

## Still to distrust

**`PROFILE-gate.md`'s headline** — `self_test` is ~96% of the run, ~4,905 s — is
**arithmetic from a bad mean** (see handoff-02, which has the working). Its §4
is right and the earlier packet acted on it; its table and first three answers
should be re-derived before anyone quotes them again. This packet added no TSV.

**`logs-self-test-after.log`** (committed by `ab25775`) is a **truncated** run
that ends `exit 127` mid-line. Every recipe up to breakage 31b in it is valid
evidence; nothing after it exists. Do not read it as a complete suite.