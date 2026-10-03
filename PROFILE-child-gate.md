# Where a CHILD gate spends its time — the profile `PROFILE-gate.md` could not take

> **WHY THIS FILE EXISTS.** `PROFILE-gate.md` §"What this profile does NOT tell
> you" says, in its own words, that it does not know *where the time goes inside a
> child gate* — it profiled the OUTER gate's own rows, and a child's rows are
> attributed by breakage. It named the exact command a successor should run and
> said **DO NOT GUESS**. This file is that measurement.

Date: 2026-10-03. Branch: `worker/kit-cache-rollout-01`, base `470dbfb`.
Command (the one the packet names, run through the harness that produces the rows):

```sh
unset KIT_PYTHON
KIT_SELF_TEST_SHARD=1/101 KIT_PROFILE=/tmp/p-child.tsv bash tests/self_test.sh
```

Shard 1/101 runs **two** child gates and tags their rows separately, so this is
**two independent samples of the same thing**, not one number twice.
`tests/self_test.sh`'s `expect_green` control runs the WHOLE gate; breakage 1 is
`expect_red … --static-only`, which is the shape every whole-gate copy has.

**Read every number as carrying the profiler's own overhead.** Each timed region
costs two extra process spawns, and the outer gate spawns ~230 regions per child.
Same command, profiler off: `--static-only` unfiltered measured **82.16 s**
against the profiled child gate's **103.2 s** — about 25% overhead. Ratios
below are the claim; absolute seconds are the profiler's, not the gate's.

---

## 1. One whole-gate copy: where the 103.2 s is

`tests/self_test.sh` breakage 1's child gate — the clean sample, `--static-only`.

| region | seconds | share | can a fingerprint cache reach it? |
|---|---:|---:|---|
| `tests/shard_test.sh` — a `tier` | **31.09** | 30.1% | yes — `kit_cached_check` wraps exactly this shape |
| `tests/fetch_test.sh` — a `tier` | **12.82** | 12.4% | **already wired**, and it is a `tier` |
| `tests/staleness_test.sh` | 8.30 | 8.0% | yes, one declaration |
| `kamal_test` — 24 cases against the real binaries | 4.74 | 4.6% | yes, one declaration |
| `tests/fingerprint_test.sh` — the 22 counterexamples | 4.43 | 4.3% | yes, one declaration |
| `tests/multi_tenant_split_test.sh` | 4.33 | 4.2% | yes, one declaration |
| `tests/provenance_test.sh` | 3.58 | 3.5% | yes, one declaration |
| the canary suite | 1.75 | 1.7% | yes, one declaration |
| **the other 110 `check` rows** | ~10.8 | 10.4% | yes — **110 declarations for a tenth** |
| 101 `cpu` rows (`check_par`, overlapping) | 13.2 summed | — | **NO.** `check_par` has no cache path at all |
| fixed overhead, measured directly | **11.07** | 10.7% | **NO.** startup, filter, summary |

**The floor is measured, not inferred.** One child gate that runs **zero**
checks — `--only=__no_such_check__`, which the gate refuses and exits 1 on, as it
should — took **11.07 s**. That is the `cp -R`, the bootstrap, the `--only`
evaluation across every registered check, and the summary. No declaration can
touch it.

### `tests/shard_test.sh` is 30% of a child gate, and nothing had said so

It proves the self-test's own `1..n` shard arithmetic partitions the suite — and
`self_test` is the phase that spends the most wall clock in the whole gate. It
runs in full, inside a copy, to check arithmetic that `tests/shard_test.sh`
itself contains. It was not in `PROFILE-gate.md`'s outer table at all, because on
that run the outer gate's own rows never included a child's.

---

## 2. The distribution is NOT a handful — and it is not a long tail either

Counted from breakage 1's 118 `check` rows:

| band | checks |
|---|---:|
| 4.0 s and above | 1 |
| 1.0 – 3.9 s | 6 |
| 0.1 – 0.99 s | 15 |
| **under 0.1 s** | **96** |

**96 of 118 checks are under a tenth of a second.** The packet's worry was the
opposite shape — a cost smeared so thin no handful of declarations could reach
it — and **that worry is not what the tree looks like**. The top **seven** checks
are **69.3 s of 103.2 s: 67%**, from seven declarations.

The other side of the same coin: the bottom 96 are worth about 4 s together, so
"cheapest-value first" is the *right ordering and the wrong target*. Wiring
checks in ascending order of cost spends its whole budget on the 4 s.

---

## 3. And now the finding that changes the rollout's SIZE

Counted from the recipes on this tree, not quoted from `PROFILE-gate.md` §4
(which measured a suite numbered up to 93):

| helper | count | what the copy actually runs |
|---|---:|---|
| `expect_red_check` | **86** | `validate.sh --only=<ONE check>` |
| `expect_red_script` | 8 | `bash <the script>` — **no child gate at all** |
| `expect_red_lang` | 6 | the whole gate, `--language=<lang>` |
| `expect_red` | 1 | the whole gate, `--static-only` |
| `expect_green_check` | 1 | the whole gate, and now `KIT_FINGERPRINT=0` |
| `expect_skip_check` | 1 | the whole gate, and now `KIT_FINGERPRINT=0` |
| **total recipes** | **103** | |

**NINE of 103 copies run a whole gate. Eighty-six run exactly one check.**

So the packet's premise — *"the cost is 94 throwaway COPIES of the whole static
phase, one per breakage"* — **is false on this tree, by a factor of about
eleven.** It was true when `PROFILE-gate.md` was written. `kit-gate-speed-02`
converted 73 `expect_red` recipes to `expect_red_check` and took the full static
phase out of three quarters of the suite; the profile that recorded the premise
was never re-derived, and its own header says its table should be.

**What that does to a rollout sized on the premise.** The seven declarations above
buy 67% of a whole-gate copy. Whole-gate copies are 9 of 103, so:

| population | ceiling from the 7 declarations |
|---|---|
| 9 whole-gate copies | ~67% of each — the whole point |
| 86 single-check copies | **only the seconds of the one check named**, and only if that check is one of the seven |
| 8 script-only copies | nothing; there is no gate to skip inside |

On the 86, the fixed 11.07 s floor is the dominant term and the named check is
usually a fraction of a second. **A per-check cache cannot make a one-check copy
cheap**, because the copy's cost is not the check.

**So the honest ceiling for the whole rollout is roughly a third of `self_test`,
not the two-thirds-to-a-half the packet's framing implies** — and that is a
ceiling, not an estimate. The successor should size the next packet against this
table and not against the packet that briefed it.

---

## 4. What is NOT addressable, named rather than hidden

- **`check_par` — 101 rows, no cache path.** Every `cpu` row is a `check_par`,
  and `kit_cached_check` wraps `bounded_check` and nothing else. shellcheck over
  `tests/validate.sh` alone is 1.68 s in one copy. A rollout that wants the tail
  needs a *second* mechanism for parallel checks, and this packet did not build
  one.
- **The 11.07 s floor.** `cp -R` of the tree, the interpreter resolution, the
  `--only` evaluation, the summary. Four fixable things, none of them a cache:
  a shared `$WORK` copy-on-write, a resolved-once interpreter, and hoisting the
  `--only` test out of the per-check path. **That is where the next packet's
  minutes are, and none of them are declarations.**
- **The 8 `expect_red_script` copies.** They already skip the gate entirely.
- **Two copies, deliberately.** `expect_green_check` and `expect_skip_check` run
  with `KIT_FINGERPRINT=0` because a replayed cache hit is a green no check ran
  to produce. See `DECISIONS.md` (MD28).

---

## 5. Reproduce

```sh
unset KIT_PYTHON
KIT_SELF_TEST_SHARD=1/101 KIT_PROFILE=/tmp/p-child.tsv bash tests/self_test.sh

# the whole-gate copy, tagged by breakage:
awk -F'\t' '$4 ~ /breakage 1/' /tmp/p-child.tsv | sort -t"$(printf '\t')" -k3 -rn

# the fixed floor — a gate that runs zero checks, and refuses to:
unset KIT_PYTHON; time bash tests/validate.sh --static-only --only=__no_such_check__

# the recipe census, counted rather than quoted:
for h in expect_red expect_red_check expect_red_lang expect_red_script \
         expect_green_check expect_skip_check; do
  printf '%-22s %s\n' "$h" "$(grep -cE "^ *$h +.breakage" tests/self_test.sh)"
done
```