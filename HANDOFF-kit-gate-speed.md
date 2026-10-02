# HANDOFF — kit-gate-speed-01

## What this packet is for

`bash tests/validate.sh` in kit takes more than ten minutes, longer than two of
a worker's four quarters, and it runs on every packet that touches templates.
The goal is a full gate that finishes in about a minute on an unchanged tree,
and on a changed tree re-runs only what the change can affect. Same assertions,
same red proofs, same refusal to go green vacuously.

## Where it actually got to

**The profile exists and it is committed: `reports/PROFILE-before.md`.** That is
the asset. Everything else is small next to it. Read it first.

**No speed fix is landed.** That is deliberate and it is the most important
sentence in this file; §3 below says why, with the specific fix named.

**One in-scope defect fixed and red-proofed:** `tests/staleness_test.sh`'s
`_fixture_gone` harness (REPORT-kit-tenancy-02.md §7.1). It died with a
traceback where a sentence belonged. It is now a named FAIL.

## What is done and verified

| what | verification | result |
| --- | --- | --- |
| `KIT_PROFILE` instrumentation, `tests/profile_report.py` | `bash tests/validate.sh --static-only` | `PASS: every check passed.`, 5 skips, exit 0 |
| the before-profile | one full `bash tests/validate.sh`, started 21:12 | stopped at breakage 8 of 94 by the hour; rows in `reports/profile-before.tsv` |
| staleness §7.1, green | `bash tests/staleness_test.sh` | `PASS: staleness_test — 26 case(s), including the red proof.` exit 0 |
| staleness §7.1, red | throwaway copy, `tests/staleness.py` = `sys.exit(0)` | `FAIL staleness_test: the fixture could not be MEASURED, so this is NOT a reporter result` |
| the self-test harness, bounded | `KIT_SELF_TEST_SHARD=7/94 bash tests/self_test.sh` | `PASS: self_test — shard 7/94 ran 1 of 96 breakages and every one it ran held.` exit 0 |

## What did NOT run

- **`bash tests/self_test.sh` unsharded. Never ran.** On the before-measurement
  it reached breakage 8 of 94 in 33 minutes. A sharded run is not that command
  and this handoff does not pretend otherwise.
- **`time bash tests/validate.sh` end to end.** Run once, for the before
  profile, and stopped by the hour. **There is no after-number for the full
  gate**, and the packet asked for one.
- **Any docker tier after 21:20.** See the warning below.

## ⚠ Read this before you run anything

**The docker daemon on this box is DOWN** (`docker info` → `EOF` on the orbstack
socket) and **the concurrent session's gate was killed by my `pkill`**, not by
anything in this branch. `pgrep -fl validate.sh` is empty; if that session's work
is missing, that is why. Kill by PID, never by `pkill -f tests/validate.sh` —
that pattern matches every gate on the machine, and I proved it.

Until docker is back, **every docker tier SKIPs and the gate will still report
green.** Do not read a green run on this box as a claim about observability,
isolation or the tenancy boundary.

## Decisions made, and why

**No speed fix landed.** The profile named the win — the eight unfiltered
breakages — and the fix requires choosing the right `--only` needle for each of
the eight. That changes what those recipes assert, from "the gate went red" to
"check X went red", and AGENTS.md records three past breakages that were wrong
in exactly that way (75/76/77 asserted a check's *wording* rather than its
*label*; 71 asserted a misspelled label). Shipping that edit unverified would
have made the gate faster and less honest. It is the successor's first move, and
it is one judgement per breakage rather than a sweep.

**The `--only` filter was not widened** to cover `fetch`, `tenancy`,
`multi_tenant`, `classify` and `lint`. Those sit deliberately outside the
`RUN_STATIC` guard because a gate that skips is not green, which is right, and
widening the filter changes which claims a run makes about itself.

**The observability tiers were not parallelised** even though they are 71% of the
gate's own time and are independent stacks. AGENTS.md records a previous run
SIGKILLed by the OOM killer inside that tier, and this hour's box lost the docker
daemon outright with two sessions running stacks. That needs its own packet with
a memory budget and probably an opt-in knob beside `KIT_PARALLEL_CHECKS`.

**No env seam was added to staleness_test.sh** to make the §7.1 red proof easy.
`STALE` stays hardcoded: an override for the reporter path would let a caller
point the suite at a stub and get green, which is a weakening wearing a test
aid's clothes. The proof is a throwaway copy instead.

## The next worker's first move

1. `git log --oneline` on `worker/kit-gate-speed-01`; read
   `reports/PROFILE-before.md`.
2. **Do the eight unfiltered breakages.** They are `expect_red … --static-only`
   with no `--only`, at `tests/self_test.sh` around lines 1622–1716 (1, 2, 2b,
   3, 4, 5, 6). For each, find the check label its mutation is *about* —
   `expect_red_check` matches `FAIL <label>`, so the needle is the label exactly
   as `validate.sh` prints it — and convert it. Expect ~370s. **Read each
   mutation before naming its check, and prove the needle matches: run the
   recipe and require `PASS … — caught by \`<label>\``, not a bare red.**
3. Measure with one breakage, not the suite:
   `KIT_SELF_TEST_SHARD=1/94 bash tests/self_test.sh` before and after. The
   before is ~48s per the profile.
4. Then the observability tiers — as a separate change, with `KIT_PARALLEL_*`
   defaulting to off.

The three commands from the packet's own verify block, for the record:

```
cd /Users/kaka/Code/any/moon/cafaye/wt-m39-kit-gate-speed-01
bash tests/validate.sh --static-only ; echo "static=$?"     # -> static=0
bash tests/self_test.sh ; echo "selftest=$?"                # NOT RUN, see above
time bash tests/validate.sh                                 # NOT RUN to completion
```