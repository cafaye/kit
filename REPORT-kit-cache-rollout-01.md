# REPORT — kit-cache-rollout-01: the switch, the measurement, and the rollout that turned out to be wrong-sized

Date: 2026-10-03. Branch: `worker/kit-cache-rollout-01`. Base: `470dbfb`.
Commits: `0eba1af` (the shared cache directory), `acfea36` (the child gate's own
profile), plus this report, the handoff and `DECISIONS.md` MD28/MD29.

For someone who has not seen the packet: kit's gate caches its verdicts by
content fingerprint, so an unchanged check can be skipped. The previous packet
built that and wired it to **one** tier. This packet was the part that makes it
pay: point the self-test's 94 copies at one shared cache, measure where a copy's
time actually goes, and write input declarations for the expensive checks.

**It did the first thing. The measurement said the rest was the wrong size, and
the measurement is the packet.** That is the outcome the brief named as a
success: *"if the whole rollout turns out to need something you did not expect,
that is a successful packet — a wrong-sized rollout is not."*

---

## 1. The headline, in one paragraph

**`tests/shard_test.sh` is 30% of a self-test child gate and nothing had ever
said so.** It proves the self-test's own `1..n` shard arithmetic partitions the
suite, and it runs in full, inside a copy, to do it. Next to it,
`tests/fetch_test.sh` — the one tier the previous packet wired — is 12%, and the
**top seven checks are 69.3 s of 103.2 s: 67%, from seven declarations.** The
distribution is not smeared; the packet's fear was not the shape of this tree.
But **nine of 103 copies run a whole gate at all.** Eighty-six run exactly one
check, and eight run a script with no gate. So the seven declarations reach
roughly a third of the suite, not two-thirds — and the dominant cost of the 86 is
an **11.07-second startup floor no declaration can touch.**

---

## 2. The before/after numbers, on this box, same tree, paired

Everything below is measured in this worktree at `acfea36` and its parent, with
the tree unchanged between arms. Profiler overhead is stated rather than hidden:
each timed region costs two process spawns, so profiled seconds run ~25% above
wall clock (measured: 103.2 s profiled against 82.16 s unprofiled for the same
gate).

### The precondition — (1) one shared cache directory

`export KIT_CACHE_DIR="${KIT_CACHE_DIR:-$WORK/cache}"`, one line in
`tests/self_test.sh`. Placement is the whole decision: `$WORK/cache` is a
**sibling** of every copy (`$WORK/<name>/kit`) inside the directory the existing
`trap` already sweeps. A cache inside a copy is deleted with the copy — the bug.
A cache in the real tree is neither shared with the copies nor swept.

**What it is worth right now: nothing, and the code says so.** No check is wired
by this commit, so the line changes no verdict. A green light with nothing
connected to it is not a saving. The switch is on; the declarations are what
close it.

### The measurement — (2) what a child gate actually costs

`unset KIT_PYTHON; KIT_SELF_TEST_SHARD=1/101 KIT_PROFILE=/tmp/p-child.tsv bash
tests/self_test.sh`. Shard 1/101 runs **two** child gates and tags their rows
separately, so these are two independent samples. Full table and reproduction in
**`PROFILE-child-gate.md`**; the three numbers that decide everything:

| | measured | how |
|---|---:|---|
| **the fixed floor** — a child gate that runs **zero** checks | **11.07 s** | `--only=__no_such_check__`, which the gate refuses and exits 1 on |
| one whole-gate copy, unprofiled | **82.16 s** | `--static-only` |
| the same, profiled | 103.2 s | the profile the packets asked for |
| **top seven `check`/`tier` rows** | **69.3 s = 67%** | breakage 1's tagged rows |
| **96 of 118 `check` rows under 0.1 s** | ~4 s together | counted, not estimated |

The floor is the number that rearranges the rollout. **A one-check copy's cost is
its startup, not its check**, and no declaration changes that.

### The resizing — the recipe census, counted

`PROFILE-gate.md` §4 measured a suite numbered up to 93 and found 73 of 94
filtered. Counted on this tree, which now has 103 recipes:

| helper | count | what the copy runs |
|---|---:|---|
| `expect_red_check` | **86** | `validate.sh --only=<ONE check>` |
| `expect_red_script` | 8 | `bash <the script>` — **no child gate** |
| `expect_red_lang` | 6 | the whole gate, `--language=<lang>` |
| `expect_red` | 1 | the whole gate, `--static-only` |
| `expect_green_check` | 1 | the whole gate, now `KIT_FINGERPRINT=0` |
| `expect_skip_check` | 1 | the whole gate, now `KIT_FINGERPRINT=0` |
| **total** | **103** | **9 whole-gate copies** |

**The packet's premise — "94 throwaway COPIES of the whole static phase" — is
false on this tree by a factor of about eleven.** It was true when
`PROFILE-gate.md` was written. `kit-gate-speed-02` converted 73 recipes to
`expect_red_check` and took the full static phase out of three quarters of the
suite; the profile that recorded the premise was never re-derived, and **its own
header says it should be.** This is the finding the packet asked for, and it is
recorded as `DECISIONS.md` MD29: a number a later commit made false is a stale
premise, not a conservative estimate, and it is paid for in declarations nobody
needed to write.

---

## 3. What I did NOT do, and why — the honest list

**(3) is not started. Not one check is wired.** The packet ranks (3) below (2)
and says an unwired check costs time while a wrongly-wired one costs correctness.
The measurement landed at minute 57; there was no hour left to trace a
declaration input by input, and a declaration traced in four minutes is a guess
wearing a fingerprint. **This is the right place to stop and it is also the
cheapest place**, because the measurement says which seven to do and in what
order.

**(4) is not started** — `tests/fetch_test.sh` is still wired with no declared
outputs. It was next in the priority order and (3) is a precondition for
calling a promotion meaningful.

**I did not wire `tests/shard_test.sh` even though it is 30% of a copy and its
declaration is the easiest in the tree.** That is the finding a successor should
check me on, so here is the reasoning: it is the check that proves the *harness*
correct, it is the check most likely to be reached by a future breakage recipe
(94 and 95 are already shard breakages), and a wrongly-wired proof of the
harness's own arithmetic is precisely the failure this packet exists to prevent.
Thirty percent of a copy is not worth a false green, and the packet's own bar —
*"at least one check wired whose declaration you can defend input by input"* —
was not reachable in the time left, so nothing was claimed in its place.

---

## 4. Two things I found that were not asked for

**A green-expecting proof is answered by a cache hit.** `expect_green_check`
(breakage 59) and `expect_skip_check` (breakage 23b) assert the gate **stays**
green and names what it said. Under one shared cache directory, both could be
satisfied by a record an *earlier* copy wrote, on a tree the recipe had not yet
mutated — a control that goes green for a reason it did not introduce, which
AGENTS.md refuses in the same breath as a control that goes red for one. Both now
run their copies with `KIT_FINGERPRINT=0`. Two tokens each; the 92 red-expecting
helpers deliberately **keep** the cache, because for them a stale green is loud
(*"the gate went red, but NOT via `<check>`"*), never silent. MD28.

**`check_par` has no cache path at all.** All 101 `cpu` rows are `check_par`, and
`kit_cached_check` wraps `bounded_check` and nothing else. shellcheck over
`tests/validate.sh` alone is 1.68 s in one copy. A rollout that wants the tail
needs a **second mechanism**, and this packet did not build one. Named in
`PROFILE-child-gate.md` §4 rather than left as an absence.

---

## 5. What is next, in the order the measurement gives

1. **Wire `tests/shard_test.sh`** — 31.09 s, 30% of a copy, and a declaration
   that is two files: `tests/shard_test.sh` and the shard arithmetic in
   `tests/self_test.sh`. Trace the reads; `grep` for every path it opens.
2. **Then `tests/staleness_test.sh`** (8.30 s), **`kamal_test`** (4.74 s),
   **`tests/fingerprint_test.sh`** (4.43 s),
   **`tests/multi_tenant_split_test.sh`** (4.33 s),
   **`tests/provenance_test.sh`** (3.58 s). **Descending cost**, not ascending —
   the 96 checks under 0.1 s are worth 4 s together and are the wrong target.
   `tests/fetch_test.sh` (12.82 s) is **already wired**; promote it to declared
   outputs (task 4) while the others go in.
3. **Every declaration needs a red proof** — mutate an input the declaration
   names, assert the tier ran uncached. Proof 7a is the shape: a GREEN control is
   the only thing that proves the declaration has a hole.
4. **Then, and separately: the 11.07 s floor.** `cp -R` → copy-on-write;
   interpreter resolution → resolved once; the `--only` test → hoisted out of the
   per-check path. **That is where the next packet's minutes are, and not one of
   them is a declaration.**

## 6. State of the worktree

Green, and honest about what green covers. `bash -n tests/self_test.sh` clean.
`--static-only` was measured at **82.16 s** on this tree and passes.
`KIT_SELF_TEST_SHARD=1/101` passed both of its recipes. And the changed line was
proved **on the recipe that uses it**:

```
$ KIT_SELF_TEST_SHARD=59/101 bash tests/self_test.sh
PASS self_test: breakage 59: an UNADOPTED service copies the stack — green, and
  named — stayed green and named the debt
PASS: self_test — shard 59/101 ran 1 of 105 breakages and every one it ran held.
```

Breakage 59 is `expect_green_check`, one of the two helpers this packet gave
`KIT_FINGERPRINT=0`, and it is the one whose verdict is a whole gate's — so it is
the strongest of the two available proofs.

**The full 105-recipe `self_test` was NOT run**: ~30 minutes on this box and the
hour is 60. So the suite as a whole is **not claimed** — only the two shards that
were run, and the summary line of a shard says so itself. Nothing is
half-applied: the switch is on, no check is wired, and the two green-expecting
proofs are pinned to uncached.

`DECISIONS.md` carries MD28 (the shared directory and the two uncached proofs)
and MD29 (a stale premise is not a conservative estimate).
`PROFILE-child-gate.md` is new and is the successor's table.