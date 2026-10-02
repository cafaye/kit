# HANDOFF — kit-gate-trust-01

**Worktree:** `/Users/kaka/Code/any/moon/cafaye/wt-m39-kit-gate-trust-01`
**Branch:** `worker/kit-gate-trust-01` (base `2d5a99b`)
**Commits:** `bad1391` (defect 1 arithmetic + `tests/shard_test.sh`), plus a second
commit carrying defect 2 and the two new breakages — see "Commits" below.
**Not pushed. Not merged. That is the manager's.**

---

## What the packet was for

Two defects in kit's own gate, both the same species: **a check that reports
something it did not do.**

1. `KIT_SELF_TEST_SHARD=n/n` ran **zero** breakages and reported **PASS**.
2. `tests/canary_test.sh` was **red on master** and nobody had traced why.

---

## What I did

### Defect 1 — the last shard verified nothing (FIXED, measured)

**Cause, confirmed by reading the code:** `tests/self_test.sh` computed
`idx = num % _shard_n` and compared it to `_shard_i`, which the caller supplies
**1-based** (`1/4` … `4/4`). `num % n ∈ 0..n-1`; `i ∈ 1..n`. Shard `n/n` asked
for a residue class nobody is in. It matched nothing, ran nothing, and — because
someone had already added a `ran ZERO of the suite's N breakages` guard — it at
least *printed* that. The false green came from the guard not existing when the
four-shard merge gate ran.

**Fix:** `idx = $(( (num - 1) % _shard_n + 1 ))` — 1-based at both ends.

Also, decided and justified as the packet asked:

| case | decision | why |
| --- | --- | --- |
| `i` outside `1..n` | **refused, exit 2** | `0/n` used to be the sentinel for the unnumbered controls. `0/23` answered "ran 4 of 97" and read like a shard. Those controls now run on shard `1/n`, which is never empty. A refused shard is loud; a shard covering a different set than asked for is the false green. |
| `n` over-provisioned | **refused at the door, exit 2** | `n` above the suite's highest number makes some shard empty *by construction*, and an empty shard must not be indistinguishable from one the arithmetic emptied by mistake. That indistinguishability **is** the defect. Refused before a single recipe runs, with both numbers. |
| `n` in the numbering's gaps | **left to the end-of-run FAIL** | see the gap finding below. |

**New proof — `tests/shard_test.sh`.** It exists because *no* `expect_red_check`
can reach this: every other recipe proves the **gate** goes red, and the gate is
not what shards. It extracts the real `_shard_claims` out of `tests/self_test.sh`
and `eval`s it (a second copy of the modulo would be a second thing to be
wrong), enumerates breakages with the **same grep the suite's own summary uses**,
and asserts three properties for `n ∈ {1,2,3,4,5,7,8,62}`:

- **non-empty** — every shard in `1..n` claims ≥ 1 breakage, shard `n/n` named first
- **exactly once** — no breakage claimed twice
- **complete** — no breakage claimed by no shard

Plus the five refusals (`0/n`, `i>n`, over-provisioned, `n=0`, `n=x`) and one
end-to-end `bash tests/self_test.sh` with an over-provisioned shard.
**41 assertions, exit 0, ~23s.** Wired into `tests/validate.sh` phase 40 as a
`bounded_check` (300s), deliberately not behind `RUN_STATIC`.

**MEASUREMENT (the packet asked for this explicitly).** Suite after this packet:
**99 breakages, numbered 1..95, 90 distinct numbers. Numbers 63–67 are unused**
(left by a renumbering).

| n | total | min | max | empty shards |
| --- | --- | --- | --- | --- |
| 4 | 99 | 23 | 26 | none |
| 8 | 99 | 11 | 14 | none |
| 62 | 99 | 1 | 4 | none |
| 64 | 99 | 0 | 4 | **63, 64** |

**They partition evenly to within the ±3 that residue-sharding 99 by 4 necessarily
has** (`26/25/25/23`), and **no shard is empty for any n ≤ 62.** Under the old
arithmetic `n=4` gave `25/24/24/0` — and that `0` is the shard that reported PASS.

**A finding I did not expect: the largest gap-free `n` is 62, not 95.**
Because numbers 63–67 do not exist, for any `n ∈ 63..95` the shards numbered
63…67 ask for residue classes no breakage is in — at `n=64`, **shards 63 and 64 are
empty**, and a gate asked for 90 shards would run fewer recipes than it was told and
never say so. Same defect as the packet's, one level up: an `n` that is
arithmetically legal and covers less than it appears to. Measured and printed by the
check rather than assumed, and left to the summary's existing `ran ZERO` FAIL — the
startup guard refuses only the provably-impossible case (`n` above the highest
number).

**Two new breakages** (`94`, `95`), the only two in the suite that mutate
`self_test.sh` itself:

- `94` — `idx=$(( (num - 1) % _shard_n + 1 ))` → `idx=$(( num % _shard_n ))`,
  i.e. the shipped defect in one line. Asserts `shard_test.sh` goes red **and**
  prints `THE SHIPPED DEFECT` — the needle is the sentence naming shard `n/n`,
  so the recipe cannot pass on a mutation that emptied a *different* shard.
- `95` — the over-provision refusal `if [ "$_shard_n" -gt … ]` → `if false;`.
  Proves the safety net is still load-bearing, separately from the arithmetic.

**Both verified to fire, by hand**, on throwaway copies rather than by waiting for
a 99-gate suite: 94 exits 1 with `FAIL  2 shard(s): 2 ran ZERO … and shard 2/n is
one of them -- THE SHIPPED DEFECT`; 95 exits 1 with `FAIL  an over-provisioned
shard count: KIT_SELF_TEST_SHARD=1/96 was ACCEPTED`. `edit` replaces only the
**first** occurrence (`body.replace(old, new, 1)`), which matters because both
recipes' search strings also appear inside the recipes themselves and the code line
precedes them.

### Defect 2 — the canary was red on master (FIXED, measured green)

**Cause, confirmed not assumed.** The packet's hypothesis was right. I read
`templates/compose/otel-collector.yml` and the shipped pipelines are:

```
traces:  [spanmetrics, otlp/tempo,  debug]
metrics: [debug]                      <-- no backend to substitute
logs:    [otlphttp/loki]
```

The dev profile removed the metrics store (130s readiness budget, 384m, for a
fleet with no series), and **removing it removed the exporter**, as that file's
own comment says it must. `BACKENDS = {"tempo","loki"}` is a *filter* over what
may be substituted, so `mimir` being absent was inert by design — but the
**metrics pipeline then had nothing left to substitute**, and the assertion four
hundred lines later reported `points at ['debug'], expected ['file/capture']`
with no cause. That is how a red gets "fixed" by deletion.

**The fix, and it is a strengthening rather than a relaxation.** The substitution
is now per-pipeline and derived: an exporter becomes `file/capture` when it is a
known backend **or when it is its pipeline's only exporter**. So `metrics`'s
`debug` → `file/capture`.

This matters more than the red did. `debug` writes to the collector's **stdout,
which this test never reads** — so on master the canary had **never observed the
metrics signal at all**. Its `llm.prompt`, `error.message` and
`tenant_id`-on-a-measurement assertions were passing **vacuously**. Those are
precisely the cardinality and content-leak cases core's schemas exist for. The
canary is now testing all three signals instead of two.

`debug` is **kept** on `traces` (its shipped local escape hatch) and `file/capture`
is de-duplicated per pipeline, since the collector refuses a pipeline naming an
exporter twice.

**The assertion is now the property, not three literals:** *every* pipeline must
export to `file/capture`, must export to something, and must not name an exporter
twice. Nothing in it names a container kit does not ship, so the next store
removal cannot make it red.

**Measured:** `bash tests/canary_test.sh` → **exit 0**, 13 PASS / 0 FAIL,
including `no tenant_id reached a measurement attribute` and
`the spanmetrics connector emitted derived metrics from redacted spans`.

**Nothing was deleted, no assertion was relaxed, no backend was re-added.**

---

## What I ran, and what I did not

**Ran**
- `bash tests/shard_test.sh` — **41 assertions, 0 FAIL, exit 0**, ~23s
- `bash tests/canary_test.sh` — **exit 0**, 13 PASS / 0 FAIL, green end to end
- `bash tests/validate.sh --static-only` — **`PASS: every check passed.`, exit 0**,
  **230 PASS / 0 FAIL / 6 SKIP**
- Both new breakages, by hand, on mutated throwaway copies

**A process failure worth recording, because it is this packet's own subject.**
The first `validate.sh --static-only` run exited **127** with
`line 10538: second: command not found`. That was **mine**, not the tree's: I
edited `tests/validate.sh` while it was running, and bash reads a script
incrementally by byte offset, so it resumed mid-word. Re-run against an untouched
file: green. A gate reporting a status that is about the *run* rather than the
tree — which is exactly what a `BOUND` verdict exists to distinguish, and exactly
what I produced by accident.

**Deliberately did NOT run**
- **The whole unsharded `self_test.sh`** (99 whole gates; would not fit the hour)
- **Any two shards in parallel.** `tests/canary_test.sh` and
  `tests/stack_live_test.sh` share the docker daemon and network, and the packet
  records shard 7 failing on that collision alone. I ran everything sequentially.
- A real multi-shard measurement of *recipes executed*, which would have needed
  several shard runs. **The partition is proved over all 99 labels without running
  them**, and the per-shard counts above are derived from the same `_shard_claims`
  that decides the partition — stated as derivation, not dressed up as a run.

**Known red, not mine:** `TestTheCoverageExclusionIsOnlyGeneratedCode` in
`identity`, a separate repository.

---

## Learned the hard way (four bugs in my own new check, all recorded in-file)

Every one of these is a `set -euo pipefail` or enumeration trap, and every one
killed the check silently or with a misleading message:

1. **Bare `[ … ] && x` outside a condition context is a `set -e` exit.** Twice —
   it died on the first non-empty shard and on breakage 1, printing nothing. `if`
   is the only correct form outside an `if`/`&&` condition.
2. **`$0` is the caller.** The extracted block counts the suite's size from `"$0"`;
   evaluated in a subshell of `shard_test.sh` that is `shard_test.sh`, and the
   count is zero. Fixed with `bash -c "$block" "$SELF"`.
3. **Enumerate with the suite's own rule or you are checking your own.** My grep
   matched only single-quoted labels and omitted `expect_skip_check`: 96 against
   the suite's 97, dropping **breakage 5** (the one labelled with `"`), with no
   finding. The check now asserts its own count equals the summary's.
4. **Re-parsing per shard inside the loop re-ran a grep+`sort` over 5,000 lines
   93 times.** One second became two minutes. The block is now `eval`'d once.

---

## The one paragraph the packet asked for

`tests/self_test.sh` opens by saying a gate that cannot fail is not a gate, and
both halves of this packet are that sentence failing in opposite directions.
Defect 1 is a gate that *could not fail loudly enough to be noticed*: a shard
asked for a residue class that does not exist, ran nothing, and said PASS, so a
four-way merge gate reported all four shards green having covered three quarters
of the suite — a false green produced by the one mechanism this suite exists to
make trustworthy. Defect 2 is a gate that *could not pass*, and had been red since
a merge earlier that day, for a cause four hundred lines from the assertion that
reported it. A red nobody traced is how a check gets deleted instead of fixed,
and a green nobody earned is how a suite stops being evidence. The two share a
shape: both are a check whose output describes an intention rather than a
measurement — `i % n == index` written in a comment while the code computed
something else, and a `BACKENDS` filter that was inert by design and therefore
silent when the thing it named stopped existing. Neither was caught by a reader,
because the comments were accurate about what the code was supposed to do. What
catches that class is the boring part: run the thing, count what it did, and
print the count.

---

## Commits

1. `bad1391` — **defect 1**: the shard arithmetic, the `i`/`n` refusals, and
   `tests/shard_test.sh`.
2. **defect 2 + the two new breakages + `validate.sh` wiring + CHANGELOG** — see
   `git log` for the sha; it is the tip of `worker/kit-gate-trust-01`.

## Open questions

1. **`n ∈ 64..93` leaves shard 64 empty by arithmetic, not by bug.** It is
   reported as a FAIL, which is correct, but it is a sharp edge for anyone who
   computes a shard count from the *breakage count* (97) rather than from the
   gap-free bound (62). Worth a sentence in `AGENTS.md` next to the sharding
   block. **I did not do it** — it is prose in a file I was not asked to widen,
   and the packet's hour was spent on the two defects.
2. **The startup guard refuses only the provably-empty case.** A gap-induced empty
   shard is caught at the *end* of a run, by the pre-existing `ran ZERO` FAIL.
   Computing the exact gap-free bound at startup is possible (it is ~10 lines of
   the same arithmetic `shard_test.sh` already does) but it would move a cheap
   parse-time check into an enumeration; I judged that the wrong trade and left
   it. Flagging it rather than burying it.
3. **`shard_test.sh` costs ~23s on every gate run** and grows with the largest
   safe `n` (62 forks-worth of work today). If it becomes a complaint, the fix is
   to run the per-`n` cases concurrently — they are independent — rather than to
   sample fewer `n`, which would weaken the proof.
4. **The canary's metrics path had never been observed.** Now it is, and it is
   green. But that means every *previous* green canary run — including the ones
   that certified this boundary in earlier packets — proved less than it claimed.
   Nothing else in the fleet needs re-running for this; I mention it because
   "the canary was green" was evidence in a dozen reports and was worth less than
   it looked.

## Successor's first move

1. Read `bad1391` and the tip commit; run `bash tests/shard_test.sh` (~23s) and
   `bash tests/canary_test.sh` (~90s, docker) to reproduce both greens.
2. `KIT_SELF_TEST_SHARD=4/4 bash tests/self_test.sh` — the shard that used to lie
   — and confirm the summary reads `shard 4/4 ran 24 of 99`. That single line is
   the packet's whole claim, made visible.
3. Do **not** run two shards in parallel.
