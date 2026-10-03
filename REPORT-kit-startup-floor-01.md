# REPORT — kit-startup-floor-01: the floor's composition, and the one check that was running 86 times

Date: 2026-10-03. Branch: `worker/kit-startup-floor-01`, base `1f88196`.
Commits: `f652f03` (the measurement), `ba60001` (the change), plus this report
and the handoff.

For someone who has not seen the packet: kit's gate caches verdicts by content
fingerprint. The previous packet found that a **child gate running ZERO checks
still costs 11.07 s**, and concluded that for the 86 self-test copies that run
exactly one check, *"the cost is the startup, not the check."* It named four
suspects for that startup — `cp -R`, the bootstrap, the `--only` evaluation, the
summary — **and measured none of them.** This packet measured all four, attacked
the largest item, and found it was neither a probe nor a venv.

---

## 1. The headline

**55.6% of the startup floor was one check that did not answer `--only`.**
`tests/kamal_test.sh` — 24 cases against the real `kamal` and `kamal-backup`
binaries — was invoked by a bare `bash`, not through `bounded_check`, so it ran
on **every** invocation of the gate: the 86 self-test copies that were asked for
one cheap check and had already been told, by name, to run one, included.

| | before | after |
|---|---:|---:|
| child gate running **zero** checks | **6.84 s** | **2.85 s** |
| removed | — | **3.99 s (58%)** |
| over 86 one-check copies | — | **≈ 343 s ≈ 5 min 43 s** |

**The bootstrap is 0.040 s and is not the floor.** Yesterday's next-steps list
offered *"interpreter resolution → resolved once"* as one of three fixes. It is
**6 milliseconds** of a 6.85-second floor — **0.6%**. It cannot be made to
matter, and this packet withdraws it by measurement rather than leaving it
standing.

## 2. The measurement, and it is a closed decomposition

```sh
unset KIT_PYTHON
bash tests/validate.sh --static-only --only=__no_such_check__
```

The gate **refuses** the filter and exits 1, which is what makes it a zero-check
run. Profiling with the gate's own `KIT_PROFILE`, the `phase` rows **sum to the
run's own `total`** — nothing is unattributed, so this is a decomposition rather
than a sample. Full table in **`PROFILE-startup-floor.md`**.

| section | seconds | share |
|---|---:|---:|
| `static: templates/kamal` — mostly `tests/kamal_test.sh`, 24 real binaries | **3.805** | **55.6%** |
| `static: templates declare no third-party dependency` | 0.648 | 9.5% |
| `static: the canary harness — contract, adapter, artifacts` | 0.626 | 9.1% |
| `static: the fleet adopts the stack rather than copying it` | 0.522 | 7.6% |
| `static: every Dockerfile runs non-root on a pinned base` | 0.394 | 5.8% |
| … 13 further sections | 0.709 | 10.4% |
| `00 bootstrap: resolve the interpreter and install deps` | **0.040** | **0.6%** |

**Attribution proved, not inferred:** `bash tests/kamal_test.sh` standalone is
**3.97 s** against the **3.805 s** the profile attributes to that section.

**6.85 s here against the 11.07 s recorded yesterday, same command, same tree,
same base commit.** That difference is machine load — `AGENTS.md` already says
this box runs several kit gates at once and that `self_test` hits its bound here.
**The ratio is the claim; the absolute seconds are this box's.**

## 3. What the measurement got wrong about the packet's premise

The packet framed the floor as *"the `cp -R`, the bootstrap, the `--only`
evaluation across every registered check, and the summary."* Two of those four
are not in the floor at all, and the third is the wrong shape:

- **The `cp -R` is the harness's, not the gate's.** The reproduction command in
  `PROFILE-child-gate.md` §5 has no copy in it.
- **The bootstrap is 0.6%.**
- **"The `--only` evaluation" is not a cost — it is a *filter that does not
  reach most of the gate*.** The filter selected nothing and was refused, yet
  6.8 s of Python and of `kamal` binaries still ran. The floor is not the price
  of *evaluating* the filter; it is the price of ~20 sections that never consult
  `ONLY_MATCH`. **`--only` gates the verdict, not the work.**

## 4. The change, and what it costs

One helper (`only_wanted`, the filter's accounting in one place rather than a
fifth copy of the `case`) and one guard on the `kamal_test` invocation, so it
answers `--only` the way `check`, `check_par`, `report_par` and `bounded_check`
already did.

**The cost, stated rather than hidden.** On a **filtered** copy
`tests/kamal_test.sh` does not run — exactly as the other four helpers already
did not run. `ONLY_SKIPPED` counts it and the summary prints the exclusion, so
the gap is loud; a filter that still matches nothing is still a hard `FAIL`.
**On an unfiltered run — the gate itself, and all nine whole-gate copies —
nothing changes at all:** same command, same output, same verdict. No check was
weakened and none was made to skip silently; `expect_skip_check` was not needed
because this is `--only`'s existing, already-audited contract, not a new skip.

### Proven, paired, on this box, same tree

| arm | seconds |
|---|---:|
| before (committed `f652f03`), 3 runs | 7.85 / **6.73** / 6.84 |
| after, 3 runs | 2.85 / **2.84** / 2.86 |

**6.84 → 2.85 s.** Whole-tree regression check: `bash tests/validate.sh
--static-only` unfiltered → **EXIT=0, `PASS: every check passed.`**

### Every new behaviour has a proof I ran

| proof | result |
|---|---|
| **green control** — unmutated copy, `--only=kamal_test` | EXIT=0, `PASS kamal_test — 24 case(s)`, `1 check(s) ran, 94 excluded` |
| **RED** — breakage 78's exact mutation (`builder.arch` deleted), `--only=kamal_test` | **EXIT=1, `FAIL kamal_test  (the generated config is accepted by the real binaries)`**, 1 ran |
| **before-arm** — the *pre-change* gate on that same mutated copy | also `FAIL kamal_test` — the red is pre-existing and not manufactured |
| **the real harness** — `KIT_SELF_TEST_SHARD=78/102` | **EXIT=0**, 3 of 106 recipes, `breakage 78 … caught by \`kamal_test\`` |

## 5. A latent defect this found, which is worth more than the seconds

The before-arm printed **two** failures for one defect:

```
FAIL kamal_test  (the generated config is accepted by the real binaries)
FAIL: --only='kamal_test' selected NO check out of the suite.
```

`--only=kamal_test` selected **nothing**, because the check incremented
`ONLY_RAN` nowhere — the label it filters on was **derived from the script's own
output**, so it did not exist until after the work was done. Breakages 78, 79
and 82 passed anyway, and only because `expect_red_check` greps for
`FAIL kamal_test` and ignores the second line. **Three recipes have been
printing a spurious "your own needle selected no check" failure on every run**,
which is the exact failure mode that check exists to catch, pointed at the
recipe that was using it correctly. After the change: `1 check(s) ran, 94
excluded` — one failure, the right one.

## 6. What I did NOT do, and the honest gaps

- **The remaining 2.85 s is not attacked.** The next three items (third-party
  dependency 0.648, canary harness 0.626, fleet adoption 0.522) are all inline
  Python that runs **whether or not `--only` matches**, for the same structural
  reason as `kamal_test`: the filter is consulted at the verdict, not before the
  work that produces it. That is a bigger and more delicate change — it means
  moving the guard *above* each section's preamble — and it is not a
  20-minute edit.
- **`cp -R` is still unmeasured here.** It is the harness's cost, not the gate's,
  and it belongs to a `--only`-independent question: whether 86 copies of the
  tree need to exist at all. Not started.
- **The full 106-recipe `self_test` was NOT run** (~30 min on this box; the hour
  is 60). The suite as a whole is **not claimed** — one shard was run, and its
  own summary line says so.
- **Pre-existing, not mine, and named because it is a trap:** `lint drift`
  **FAILs in every self-test copy**, because `fresh_copy` places copies in
  `$WORK/<name>/kit` and no cafaye checkout sits beside them. No recipe notices,
  because `expect_red_check` only requires its own needle to appear. Observed on
  a hand-made copy *before* the change was applied to it. **This worktree must
  stay beside the fleet** for the same reason.

## 7. State of the worktree

Green. `bash -n` clean. Full `--static-only` **EXIT=0**. Shard 78/102 **EXIT=0**.
The throwaway proof copy under `cafaye/` is deleted. Nothing half-applied.

## 8. The compound effect, which is the point

**86 copies × 3.99 s ≈ 343 s ≈ 5 min 43 s off the suite** — larger than
everything the fingerprint-cache rollout can reach on this tree, and it needed no
declaration, no fingerprint, and no cache. The general lesson, and it is the one
worth carrying: **before wiring a check into a cache, find out whether the copy
is running it at all.** A check that ignores the filter is charged to every copy
that asked for something else, and no number of input declarations touches that.