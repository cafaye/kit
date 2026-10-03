# HANDOFF — kit-cache-rollout-01

Date: 2026-10-03. Branch: `worker/kit-cache-rollout-01`. Base `470dbfb`.
Commits: `0eba1af`, `acfea36`, plus the report, this handoff and MD28/MD29.
Report: `REPORT-kit-cache-rollout-01.md`. **New table: `PROFILE-child-gate.md`.**

## What the packet was for

To make the fingerprint cache pay: share one cache directory across `self_test`'s
copies, measure where a child gate's time actually goes, and write input
declarations for the expensive checks.

## The one-paragraph version

**`tests/shard_test.sh` is 30% of a self-test child gate and nobody knew.** The
**top seven checks are 67% of a copy, from seven declarations** — the cost is
concentrated, not smeared, so the packet's fear was the wrong shape. **But only
9 of 103 copies run a whole gate**: 86 run one check via `--only`, 8 run a script
with no gate. And a child gate that runs **zero** checks still costs **11.07 s**.
So the rollout's real ceiling is about a third of `self_test`, not two-thirds —
and the 86 one-check copies are dominated by a startup no declaration can touch.

## What is here

| file | what it is |
|---|---|
| `tests/self_test.sh` | `export KIT_CACHE_DIR="$WORK/cache"` (the switch), and `KIT_FINGERPRINT=0` on the two GREEN-expecting copies |
| `PROFILE-child-gate.md` | **the table `PROFILE-gate.md` said it could not produce** — measured, two samples, with the floor |
| `DECISIONS.md` | MD28 (the shared directory, and why two proofs stay uncached), MD29 (a stale premise is not a conservative estimate) |
| `REPORT-kit-cache-rollout-01.md` | the full write-up |

## What I learned

- **The measurement the last packet asked for is `PROFILE-child-gate.md`, and it
  is not derivable from `PROFILE-gate.md`.** A child gate's rows are attributed by
  breakage, so the outer profile is blind to them. `KIT_SELF_TEST_SHARD=1/101
  KIT_PROFILE=… bash tests/self_test.sh` gives **two** tagged samples for the price
  of one run, because the shard runs the unbroken-tree control *and* breakage 1.
- **THE FLOOR IS THE NUMBER THAT RESIZES ANY ROLLOUT.** `--only=__no_such_check__`
  — a gate that runs zero checks and refuses — is **11.07 s**. That is `cp -R`,
  interpreter resolution, the `--only` evaluation and the summary. A per-check
  cache addresses none of it, so on the 86 one-check copies it addresses almost
  nothing. **Measure the floor first on any future gate-speed packet.**
- **"Cheapest-value first" is the right ordering and the wrong target.** 96 of 118
  checks are under 0.1 s and worth ~4 s together. Descending order gets 67% from
  seven declarations; ascending order spends the whole budget on a tenth.
- **A green-expecting proof is answered by a cache hit, and nobody notices,
  because it still passes.** That is the direction of false green AGENTS.md warns
  about from the other side. Both green-expecting helpers now pass
  `KIT_FINGERPRINT=0`; the 92 red-expecting ones keep the cache because a stale
  green there is *loud*.
- **`check_par` is a hole in the mechanism.** All 101 `cpu` rows go through it and
  `kit_cached_check` wraps `bounded_check` only. `check_par` needs its own
  mechanism before the tail is reachable.

## What I ruled out, and why

- **Wiring `tests/shard_test.sh`, the single biggest win.** 30% of a copy, and the
  easiest declaration in the tree. I did not, because it is the check that proves
  the *harness's own arithmetic*, breakages 94/95 are already shard breakages, and
  a wrongly-wired proof of the harness is exactly the false green this packet
  exists to prevent. It is the successor's first move, not mine, because I had no
  hour left to trace it input by input. **This is the decision to overturn if you
  disagree** — it is one file away and 30% of a copy.
- **Any declaration at all.** A declaration traced in four minutes is a guess
  wearing a fingerprint, and the packet's bar was "defendable input by input".
  Zero is the honest number.
- **Sizing the rollout from the brief's premise.** "94 copies of the whole static
  phase" is stale — `kit-gate-speed-02` took the full phase out of three quarters
  of the suite and the profile that recorded the premise was never re-derived,
  though its own header says it should be.

## The successor's first three moves

1. **`tests/shard_test.sh`** — 31.09 s, 30% of a whole-gate copy. Read what it
   opens: almost certainly `tests/shard_test.sh` plus the shard arithmetic in
   `tests/self_test.sh`, and nothing else. **Then write the red proof**: mutate a
   byte in one declared input, assert the tier ran uncached. A green control that
   mutates an *undeclared* input and asserts the cache still says HIT is
   `fingerprint_test.sh` proof 7a, and it is the only thing that proves the
   declaration has no hole.
2. **`tests/staleness_test.sh` (8.30 s), `kamal_test` (4.74 s),
   `tests/fingerprint_test.sh` (4.43 s), `tests/multi_tenant_split_test.sh`
   (4.33 s), `tests/provenance_test.sh` (3.58 s)** — descending cost. Each needs
   its own red proof. **`tests/fetch_test.sh` (12.82 s) is already wired**:
   promote it to the strict outputs clause, which is task (4) and is one line of
   declaration.
3. **Then attack the 11.07 s floor**, and it is not the cache: copy-on-write for
   `fresh_copy`, one interpreter resolution instead of 103, and the `--only` test
   hoisted out of the per-check path. **More wall clock lives here than in every
   declaration on this page put together.**

## Open questions

1. **Should `kit_cached_check` learn `check_par`?** 101 parallel rows and no cache
   path. It is the difference between reaching the tail and not, and it is a
   second mechanism rather than a second declaration.
2. **Is `tests/shard_test.sh` cacheable at all?** It is a pure predicate over
   arithmetic that lives in the harness. If a successor concludes it is *not*
   safely cacheable, the right response is to say so in the declaration's place,
   not to leave it silently unwired — an unwired check costs time, and a silently
   unwired one costs the reader.
3. **The 86 one-check copies are where the suite is, and the cache cannot reach
   them.** Either the floor comes down (move 3) or the `--only` conversion is
   undone for the checks worth caching — both are larger decisions than this
   packet's.

## State of the worktree

Green, with the limit stated. `bash -n tests/self_test.sh` clean;
`--static-only` passes (82.16 s measured on this tree);
`KIT_SELF_TEST_SHARD=1/101` passed both of its recipes, and
`KIT_SELF_TEST_SHARD=59/101` passed breakage 59 — one of the two helpers this
packet changed — with `every one it ran held`. **The full 105-recipe
`self_test` was not run** — ~30 min on this box, and the hour is 60 — so the suite
as a whole is not claimed, only the shard. Nothing is half-applied: the switch is
on, no check is wired, and the two green-expecting proofs are pinned to
uncached.