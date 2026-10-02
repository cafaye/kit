# HANDOFF — kit-gate-speed-01

**Read `PROFILE-gate.md` first.** It is the deliverable: the timing table, the
three answers, and the caveats. This file is only what a successor needs to know
about the state of the work.

## What the packet was for

`bash tests/validate.sh` takes far longer than ten minutes. Nobody was going to
make it faster until someone said **where the time goes**. This packet built the
measurement and wrote the table. **It optimized nothing**, deliberately: a fix
designed without the profile is a guess, and the profile is the next packet's
input.

## Done and verified

- **`KIT_PROFILE=<file>` instrumentation in `tests/validate.sh`** (commit
  `4ca039f`). Five row kinds — `check`, `cpu`, `tier`, `phase`, `verdict` — plus
  a `total` on the EXIT trap. `report` is the measurement site, so every printed
  verdict has a number beside it.
  - **Verified:** `shellcheck -S warning` clean; `bash -n` clean; and a full
    `--static-only` run's **stdout and stderr are byte-identical** with the
    profiler on and off (`diff` empty in both). That is the load-bearing
    property, because `--only` and `self_test.sh` both read the gate's output by
    position.
  - **Verified:** `bash tests/validate.sh --static-only` → **exit 0** with the
    instrumentation in place.
- **`PROFILE-gate.md`** (commit `b4c9772`) — the table, from one instrumented
  run.

## Half-done, and why

- **The instrumented run was terminated at 569.0 s, inside `self_test` breakage 3
  of 94.** Not a check failure and not a hang: `self_test` is 94 whole gates in
  sequence at 51.63 s each, which is 82 minutes, and the packet's budget was one
  hour. The termination was external (my own shell was killed and took the
  process group with it), and there was no budget left to re-run.
  **Consequence: the "biggest check", "top-three share" and "process count"
  answers rest on a projection from the four child gates that finished**, and are
  labelled as projections everywhere they appear.
- **The next run needs an hour of wall clock and no interference.** The cheapest
  way to get an un-truncated number is `KIT_PROFILE=… bash tests/self_test.sh`
  on a quiet box — that measures the 96% directly instead of projecting it.
- **`tests/self_test.sh` does not set `--only` for 21 of its 94 recipes.** Named
  in the profile, **not fixed** — it is an optimization and this packet does no
  optimizations.

## The numbers that matter

| | |
| --- | --- |
| biggest single cost | **`tests/self_test.sh`, ~96% of the run** (~4,905 s of ~5,103 s) |
| runner-up | `tests/no_telemetry_in_readiness.sh`, 63.2 s (1.24%) |
| third | `tests/stack_live_test.sh`, 43.6 s (0.85%) |
| top three together | **98.2%** projected, 84.0% on the truncated run |
| processes per full run | **~19,650 forks** from the gate's own spawn sites; **~41,000 more** from the profiler when it is on |
| one child gate | **51.63 s mean**, **113.6 timed checks** |

## The next worker's first move

**Build the `--only` reach first, then parallelize `self_test` — in that order.**

1. **`--only` for the other five recipe helpers.** It is a one-line change per
   helper in `tests/self_test.sh` (append `--only=<the check the recipe names>`,
   exactly as `expect_red_check` already does) and it takes the suite from ~47×
   to the ~60× the comments already claim. **21 of 94 recipes pay the full static
   phase today.** Cheapest, lowest-risk, and it needs no architectural argument.
2. **Then overlap the child gates.** They are independent by construction —
   `fresh_copy` already gives each breakage its own parent directory precisely so
   they cannot see each other. That is the 82 minutes.
3. **Only then** look at `no_telemetry_in_readiness.sh` (63 s) and
   `stack_live_test.sh` (44 s). Together they are 2.1% of the run, so they are
   worth doing last and not at all if 1 and 2 land.

**Do not touch `check`/`check_par`/`bounded_check` to make the profiler
cheaper** — the profiler costs ~41,000 processes on a run of ~19,650, which is
the honest price of a measurement, and it is off by default.

## A collision to know about

Three commits by **another session** landed on this branch and worktree while
this packet was running: `66526f4` (added the `KIT_PROFILE` base **and**
`tests/profile_report.py`, **and** the `KIT_PROFILE_TAG` exports in
`tests/self_test.sh` that made per-breakage attribution possible), `38b2e14`
(a `staleness_test.sh` change) and `d32b71c`. Only `4ca039f` and `b4c9772` are
this packet's. `tests/validate.sh` was last modified at 21:09:37, before the
profiled run launched at 21:13:01, so **the script under measurement was not
edited mid-run**; but `tests/staleness_test.sh` changed at 21:15 and
`tests/profile_report.py` appeared at 21:16, so child gates copied after 21:15
ran a slightly different tree than the ones before. The effect is a few seconds
per child gate against a 51.63 s mean, and it does not change any conclusion —
but a successor re-measuring should know the tree was moving.