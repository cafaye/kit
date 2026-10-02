# HANDOFF — kit-gate-speed-02

**Read `REPORT-kit-gate-speed-02.md` for the numbers. This file is the state of
the work.** The short version: the change landed and is verified, and the
premise it was handed was wrong by a factor of six — so the next worker should
read §2 of the report before spending an hour on the line of work this one
finished.

## Done and verified

- **`--only` now reaches every recipe in `tests/self_test.sh` that it can reach**
  (commit `c556dda`). Breakages 2, 2b, 3, 4, 5 and 6 moved from `expect_red` to
  `expect_red_check`; `expect_green_check` (59) and `expect_skip_check` (23b)
  grew the same four-line filter block. Gate-running recipes without a filter:
  **9 → 3.**
  - **Verified:** every candidate filter was probed against its own mutation on
    its own tree first, and every one printed `FAIL <the named check>` — table in
    the report §4b, with times.
  - **Verified:** the control. An unbroken tree under breakage 6's filter exits 0
    and prints `PASS .github/workflows/ci.reusable.yml  (opt-in telemetry job,
    defaults intact)`. A filter that only ever fails is not a proof.
  - **Verified:** `timeout 900 bash tests/self_test.sh`, run in the background.
    23 recipes reached, **23 PASS, 0 FAIL** — including the unbroken-tree
    control and all six conversions, each naming its check.
  - **Verified:** `bash -n` clean, `shellcheck -S warning` clean, and the two
    counts `tests/validate.sh` derives from this file are **unchanged** (94
    breakages, 92 reds) because `expect_red_check` was already in both patterns.
  - **Verified:** `tests/validate.sh` is **not modified** by this commit. The
    gate's printed output — the load-bearing part — is byte-for-byte what it was.
- **Six proofs got stronger, not just faster.** `expect_red` asserted only "the
  gate went red"; each of the six now asserts `FAIL <the check it names>`, and
  each label is a variable so a rename on either side breaks the file loudly.

## Measured, and what it says about the plan

| | |
| --- | --- |
| one child gate, unfiltered `--static-only` | **42.70 s** |
| one child gate, `--only` one check | **7.88 s** |
| the 6 converted recipes, each on its own mutated tree | **7.87 s mean** |
| this packet's total saving | **~256 s (~4.3 min)** |
| `self_test` | **~17 min before, ~13 min after** — not the 82 the handoff claimed |

## Half-done, and why

- **The full `bash tests/validate.sh` was not re-run.** It does not fit beside a
  bounded `self_test` in one hour, and the packet allows the committed BEFORE
  numbers as the comparison. The report's full-gate figure is **arithmetic on
  measured parts** and is labelled that way in all four places it appears.
  `logs-profile-after.tsv` was **not** written; there is no AFTER TSV in this
  branch.
- **The bounded `self_test` run did not reach the end.** It reached breakage ~23
  of 94 in 900 s on a box running several gates at once — ~15 s per recipe there
  against 7.87 s measured in isolation. Breakages 24–92 are **unexercised by this
  packet**. They were not touched by the commit (only the three helpers' argument
  handling changed, and `expect_red_check`, which carries 73 of them, is
  untouched), but "unexercised" is the honest word. `AGENTS.md` says what to do
  about a `BOUND` self_test: run the unreached recipes by hand.
- **The worktree's own root gate exits 1**, on two FAILs that name
  `wt-m39-core-rls-scan-01` — another session's live git worktree parked inside
  this one (created 21:46, on `worker/core-rls-scan-01`, still being written to).
  Not mine, not touched; `fresh_copy` copies a fixed path list that excludes it,
  so every child gate and every proof in this packet ran on a clean tree. It
  should disappear when that session ends. **If it is still there, the root gate
  is red for that reason and nothing else.**

## The next worker's first move

**Overlap the child gates. Do not touch `--only` again — it is done.**

1. **The 73 already-filtered child gates are 85% of `self_test`** (73 × 7.87 s of
   ~774 s), and they are independent by construction: `fresh_copy` gives every
   breakage its own parent directory precisely so they cannot see each other.
   `KIT_SELF_TEST_SHARD` already exists (`tests/self_test.sh`, `_shard_claims`)
   and is the natural seam — a bounded pool of `n` parallel workers, one shard
   each. **Four workers is the obvious first number to try**, and the honest
   ceiling is `min(4, cores)`; measure cores before choosing it.
2. **A shard run must not change the summary.** `_shard_ran` and
   `_shard_claimed_total` already exist for this; the risk is a shard reporting
   a number that is true for itself and false for the suite.
3. Only then `no_telemetry_in_readiness.sh` (63 s) and `stack_live_test.sh`
   (44 s) — 2.2% of the corrected run. Worth doing last, as planned.

**Do not make `--only` reach `report`-based verdicts to serve breakage 1.** It
would mean threading a filter through every `report` call site in a 10,554-line
gate, for 35 s. Measured and left alone, and the report says so.

## The measurement to distrust in `PROFILE-gate.md`

Its headline — `self_test` is ~96% of the run, ~4,905 s — is **arithmetic from a
bad mean**. The four child gates that finished before that run was killed were
breakages 1, 2, 2b and 3, and **all four already paid the full static phase**;
the 51.63 s mean was then applied to all 94 as though none were filtered. The
corrected population is two numbers, 42.70 s and 7.88 s, and §2 of the report has
the arithmetic. Its §4 is right and this packet acted on it; its table and its
first three answers should be re-derived before anyone quotes them again.