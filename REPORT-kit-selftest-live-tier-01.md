# REPORT-kit-selftest-live-tier-01

**The question the packet asked, and the number:** of the 105 labelled recipe
invocations in `tests/self_test.sh`, **0** name `canary_test.sh`,
`no_telemetry_in_readiness.sh` or `stack_live_test.sh`. The count is derived by a
check (`tests/validate.sh`, label `tests/self_test.sh  (0 of the recipes name a
live tier; …)`) that reads the live tier's own three `live_check` invocations, so
it cannot name a script that has been renamed and it cannot rot.

**The fix:** `--no-live` (and `KIT_NO_LIVE=1`) in `tests/validate.sh`, which turns
those three tiers into `report SKIP` rows naming the flag, and one wrapper in
`tests/self_test.sh` that sets it for every child gate. No bound was widened.

**The result:** 23b's dependency on three docker stacks is gone. Its own gate run
was executed **six times before and seven times after**: three of the six before
came back `exit 1`, none of the seven after did. The gate is **`exit 0`** — 108 of
108, all 107 breakages hold. The saving is **~130 s per whole suite**, measured
twice, and §5 says why the 760 s difference between the two *suites* is not
evidence of anything.

---

## 1. The number, counted three ways

The packet asked for the count of recipes whose needle names a live check. Three
counts, all derived, all agreeing:

| what | count | how it is derived |
| --- | --- | --- |
| recipe invocations in `tests/self_test.sh` | 107 | statements beginning with an `expect_*` call, `\` continuations joined |
| invocations carrying a `breakage N:` label | **105** | the same expression `validate.sh` uses for its own label |
| **invocations naming a live tier** | **0** | the new check, against the three `live_check` invocations |
| invocations that run the gate at all | 93 | 6 `expect_red_lang` + 8 `_script` invocations never do |
| …of those, passing `--static-only` | 84 | argument of the invocation |
| …narrowed to one check by `--only` | 8 | `expect_red_check` adds `--only=$want` unless the caller passed one |
| …**unfiltered** | **1** | breakage 23b, whose helper cannot be filtered |

The gate prints the 105 itself:

```
PASS tests/self_test.sh  (0 of the recipes name a live tier; every child gate opts out through one wrapper)
       0 of 107 recipe invocations name a live tier; 1 child-gate spawn, opted out of all 3
```

**So the answer to "do any of the breakage recipes need the live tier at all?"
is no, and it is no twice over**: not one of them *names* a live check, and only
one of them ever *reached* it.

### Why only one reached it

`expect_red_check` narrows every child gate to the single check the recipe is
about (`--only=$want`), and `bounded_check` honours `--only`. So the live tiers
were already excluded from all 92 filtered gate runs. The exception is
`expect_skip_check`, which is **deliberately unfiltered** and for a documented
reason: the string breakage 23b must find is a SKIP's *verdict text*
(`templates/otel/ruby  (ruby 2.6.10 is below the template's 2.7 floor)`) rather
than a check's *label*, and filtering on the verdict text selects no check, which
`validate.sh` turns into `exit 1`. That is the whole exposure: **one whole gate
out of 93.**

### And it is worth half that gate

Profiled on this branch (`KIT_PROFILE=…`, `--language=ruby --no-self-test`, an
otherwise green run), 23b's own gate run:

| tier | seconds |
| --- | --- |
| `tests/no_telemetry_in_readiness.sh` | 63.406 |
| `tests/stack_live_test.sh` | 44.504 |
| `tests/canary_test.sh` | 19.212 |
| **live tier, total** | **127.122** |
| `tests/isolation_test.sh` | 13.437 |
| `tests/tenancy_test.sh` | 10.307 |

The live tier is **50.5%** of that run and the two cluster tiers are **9.4%** of
it, which is the measurement behind scoping `--no-live` to the three rather than
reusing `--no-observability`: they are a different claim ("the collector works"
vs "a service cannot read another service's rows") at a tenth of the cost, and
the two have to stay separable.

---

## 2. What actually failed, measured rather than taken

The packet reported the failure as contention and asked for it to be established
independently. **It reproduces, and it also reproduces standalone**, which is a
stronger result than the packet's.

### 2.1 Inside the deep tier, on pristine `master`

`git archive master` → a directory of its own → `bash tests/self_test.sh`,
timed, exit 1:

```
FAIL self_test: breakage 23b: an interpreter below the floor is a named skip, not a silent pass — the gate exited 1, so the skip was not clean
       FAIL tests/stack_live_test.sh  (the fetched stack runs; a trace and a metric land)
       FAIL: 1 check(s) failed.
```

Byte-for-byte the packet's failure. Five failures in that run; 23b is one of them
(§7 has the other four).

### 2.2 Standalone, on pristine `master`, the same command four times

A byte copy of `master` in a directory of its own, the same `ruby` stub reporting
2.6.10, and the recipe's own invocation
`bash tests/validate.sh --language=ruby --no-self-test`:

| sample | wall | verdict |
| --- | --- | --- |
| 1 | 241 s | **RED** — `canary_test.sh` **and** `stack_live_test.sh` FAIL |
| 2 | 282 s | green — all three live tiers PASS |
| 3 | 231 s | green — all three live tiers PASS |
| 4 | 239 s | live tiers green; `exit 1` on `tenancy_test.sh` (leftover docker network, §5) |

So the packet's premise ("green standalone, red at position 23 of 104") held on
the manager's box and **does not hold on this one**: inside the deep tier 23b is
red in 1 of 2 runs, and of four standalone runs one is red on the live tier and
one more is red on a *different* docker tier's leftover state. Nothing else of
this session's was running for samples 2, 3 and 4.

### 2.3 And it is not a timeout

The packet's hypothesis was contention on a 900 s bound. **It is not.** The
failures are content assertions, not deadlines:

```
FAIL tests/canary_test.sh  (a canary secret reaches no exporter)
       FAIL  OTLP/traces rejected with HTTP 400
       FAIL  allowed data was destroyed by the boundary: gpt-4o-mini
       FAIL: canary — 2 assertion(s) failed.
FAIL tests/stack_live_test.sh  (the fetched stack runs; a trace and a metric land)
       FAIL  a high-cardinality dimension reached an exporter as a metric label — the ingest deny set did not run
       FAIL: stack live — 1 assertion(s) failed.
```

`bounded_check` prints `BOUND <label>` when the bound is reached and
`FAIL <label>` otherwise; every one of these is a `FAIL`, so the gate's 900 s
ceiling was never the binding constraint. Which makes the packet's instruction
sharper rather than redundant: widening the 900 s would have changed **nothing**
about either failure.

**What this changes about the argument, and what it does not.** The fix is the
same either way — 0 recipes need the tier, 1 gate reached it, and that gate's
verdict is not reproducible. But the reason to reach for a *bound* in the first
place was a theory about contention, and the theory is not what the measurement
shows. There is an intermittent failure inside the collector tiers themselves,
and it is a different defect in a different place. It is named here so the next
reader does not inherit it as part of this packet.

---

## 3. The fix

The design is the packet's, with three deliberate differences, each argued in
place: `--no-live` is **scoped to the three** rather than reusing
`--no-observability` (§1, measured 127.1 s vs 23.7 s); it is set through **one
wrapper** that every helper goes through rather than in each helper, so a check
can enforce it (§3, §3-mutations); and `expect_skip_check` gained a **third
assertion** (§4.2). Nothing else was changed, and **no bound was touched**.

### `tests/validate.sh`

* `--no-live`, and `KIT_NO_LIVE=1` (truthy values only; `--no-live` cannot be
  un-set from the environment).
* `live_check <label> <bound> <command…>` wraps the three tiers. With the opt-out
  it publishes `KIT_CACHE_LAST_EXIT=$SKIP_EXIT` — **not 0**, because a tier that
  did not run has no verdict and `0` would be a green for a run that never
  happened — and emits one `report SKIP` per tier.
* A summary note on **both** exit paths, because three `SKIP` rows and a reader
  who reads only `PASS: every check passed.` is the gap this repository keeps
  naming.
* `--only` is applied on the skip branch only. On the run branch `bounded_check`
  applies it; applying it twice would count every selected tier twice in
  `ONLY_RAN`. Measured both ways: ran/excluded counts are identical with and
  without the flag.
* Two incidental repairs in the same two files, both pre-existing on `master`:
  `--help` no longer prints `kit_phase: command not found` (the `EXIT` trap is
  armed ~120 lines before `kit_phase` is *defined*), and `--help` prints the whole
  leading comment block instead of a hand-counted `sed -n '2,35p'` range that
  already cut a sentence in half.

### `tests/self_test.sh`

* `kit_child_gate <dir> <args…>` is the **only** place the file spawns the gate,
  and it sets `KIT_NO_LIVE=1`.
* `expect_skip_check` gained a **third** assertion: a `SKIP` **row** that names
  `--no-live`.

### The new check, and six mutations

`tests/self_test.sh  (0 of the recipes name a live tier; every child gate opts
out through one wrapper)` fails on a recipe that names a live tier, on a second
spawn of the gate outside the wrapper, and on that spawn losing `KIT_NO_LIVE=1`.
Every one proved red by mutation, each naming its line:

| | mutation | verdict |
| --- | --- | --- |
| A | a recipe's needle becomes `tests/stack_live_test.sh  (…)` | **FAIL** — `1 recipe invocation(s) name a live tier out of canary_test.sh, no_telemetry_in_readiness.sh, stack_live_test.sh: line 2472 names 'stack_live_test.sh'` |
| B | the wrapper loses `KIT_NO_LIVE=1` | **FAIL** — `line 1013 spawns the gate without KIT_NO_LIVE=1` |
| C | a sixth helper spawns the gate | **FAIL** — `appears 2 time(s) outside comments (line 1011, line 1017)` |
| D | …the same, naming the gate by path | **FAIL** — `appears 2 time(s) … (line 1011, line 1017)` |
| E | a helper runs `bash -n tests/validate.sh` | **PASS** — not a spawn |
| F | `kit_child_gate` is renamed | **FAIL** — `defines no kit_child_gate()` |

**One of those six is a check that went red on correct work while it was being
written**, and it is worth recording. Containment ("the spawn is inside
`kit_child_gate`") was first located by brace counting and then by "the nearest
function definition above it". Both are wrong the moment a definition is written
inside another definition's body — which bash accepts, no linter here flags, and
a mutation did exactly that. It reported:

```
FAIL tests/self_test.sh
       - line 1018 spawns the gate from `syntax_only`, not from `kit_child_gate`
```

blaming a function that spawns nothing. So containment is deliberately not
asserted. The property is the one that cannot go wrong on an innocent edit: one
spawn, and it carries the opt-out.

---

## 4. The red proof, in the packet's four requirements

### (1) With `--no-live`, a green gate still exits 0 and prints the higher skip count

```
$ bash tests/validate.sh --no-self-test --no-live
EXIT=0
…
PASS: every check passed.
note: 8 check(s) skipped — reported above, never hidden.
note: 4 tier(s) ran under a time bound; none was reached.

$ bash tests/validate.sh --no-self-test          # no flag
EXIT=0
…
PASS: every check passed.
note: 5 check(s) skipped — reported above, never hidden.
note: 7 tier(s) ran under a time bound; none was reached.
```

**5 → 8 skips: exactly the three live tiers**, and 7 bounded tiers → 4. The three
tier rows disappear from `KIT_PROFILE` too (6 rows → 3), so the work is genuinely
not done rather than reported as not done.

### (2) `--no-live` must not suppress the `SKIP` line — quoted

```
SKIP tests/canary_test.sh  (a canary secret reaches no exporter)  (NOT RUN — --no-live, or KIT_NO_LIVE=1: the observability live tier was opted out and this claim is UNEXERCISED)
SKIP tests/no_telemetry_in_readiness.sh  (collector killed, service still serves)  (NOT RUN — --no-live, or KIT_NO_LIVE=1: the observability live tier was opted out and this claim is UNEXERCISED)
SKIP tests/stack_live_test.sh  (the fetched stack runs; a trace and a metric land)  (NOT RUN — --no-live, or KIT_NO_LIVE=1: the observability live tier was opted out and this claim is UNEXERCISED)
```

and, in the same run's summary:

```
note: --no-live: the observability live tier (canary, collector-killed, fetched stack)
       did NOT run. Three claims are UNEXERCISED by this run and no gate that a
       human or CI runs sets this flag; it exists for the throwaway gates in
       tests/self_test.sh, none of which asserts anything about those three.
```

**This is asserted, not asserted-about.** `expect_skip_check` now requires a line
that *begins* with `SKIP ` and *names* `--no-live` (`skip_row_naming`). A patch
that deleted the three `bounded_check` calls satisfies 23b's other two assertions
perfectly — greener than ever, still honest about the ruby floor — and fails
this one. `--no-live` is not fatal on a skip, unlike the lint phase, and that is
a decision rather than an omission: 23b asserts the gate is **green** while
naming a skip, so a fatal `--no-live` skip would red the one proof this exists to
keep green.

### (3) The top-level gate, no flag, still executes all three

From the gate's own output, and from its own profile — not inferred from the code:

```
PASS tests/canary_test.sh  (a canary secret reaches no exporter)
PASS tests/no_telemetry_in_readiness.sh  (collector killed, service still serves)
PASS tests/stack_live_test.sh  (the fetched stack runs; a trace and a metric land)
PASS tests/isolation_test.sh  (service A cannot reach service B's database)
PASS tests/tenancy_test.sh  (no identity, another tenant and its own tenant — …)

tier	tests/canary_test.sh  (a canary secret reaches no exporter)	19.212
tier	tests/no_telemetry_in_readiness.sh  (collector killed, service still serves)	63.406
tier	tests/stack_live_test.sh  (the fetched stack runs; a trace and a metric land)	44.504
tier	tests/isolation_test.sh  (service A cannot reach service B's database)	13.437
tier	tests/tenancy_test.sh  (no identity, another tenant and its own tenant — …)	10.307
tier	tests/shard_test.sh  (the n shards partition the suite, shard n/n included)	29.440
```

### (4) 23b goes green, and stays green

§6.

---

## 5. Wall clock, before and after

Whole `tests/self_test.sh`, end to end, on this machine. Each run is a tree of
its own: `fresh_copy`'s rule that a copy's **parent** is its fleet, learned the
hard way when a scratch parent made a copy's `lint drift` check read my own
scratch directories as a fleet.

| run | tree | started | wall | PASS | FAIL |
| --- | --- | --- | --- | --- | --- |
| BEFORE-1 | pristine `master` `ec13376` | 08:12:38 | 1774 s = 29 m 34 s | 100 | 5 — **23b** + 96–99 |
| BEFORE-2 | pristine `master` `ec13376` | 10:05 | 2071 s = 34 m 31 s | 101 | 4 — 96–99 |
| AFTER-1 | this branch | 09:14:29 | 1189 s = 19 m 49 s | 101 | 4 — 96–99 |
| AFTER-2 | this branch | 09:34:18 | 1137 s = 18 m 57 s | 101 | 4 — 96–99 |
| **AFTER-3** | this branch **as it now stands** | 11:00 | 1825 s = 30 m 25 s | **108** | **0 — exit 0** |

AFTER-3 is the run that can answer "is the gate green", because a sibling packet
(`kit-version-recipe-drift-01`) landed the §7 fix while this session was
measuring. It is not comparable to AFTER-1/AFTER-2 by wall clock — it is a
different tree doing four more recipes' worth of work — and it is not comparable
to BEFORE-1/BEFORE-2 for the same reason.

Its closing line, which is the one worth having:

```
PASS: self_test — all 107 breakages hold (103 assert red, 3 assert a green gate
with a named skip, 1 assert a green gate with a named finding), and the unbroken
tree is green.
       Every recipe above was EVALUATED — 108 ran against 108 declared (107
breakages and the unbroken-tree control), and the two are compared rather than
assumed: 0 environment failures, 0 skipped for a missing toolchain.
```

### The honest reading, and why the headline number is not the headline

Naively: 1923 s mean before, 1163 s mean after, a 40% saving. **Do not believe
it, and here is the arithmetic that says so.**

The saving the change can possibly account for is bounded by the three tiers'
cost in the **one** gate of 93 that ran them, and the gate's own profiler puts
that at **127.1 s**. The whole-suite differences between the pairs (760 s, 660 s,
and −90 s for AFTER-3 against the *same branch*) are all larger than, or of the
opposite sign to, the attributable saving. So the instrument is not fine enough:
on a shared box, a whole-suite duration measures the box as much as the tree.

The attributable number, measured back to back on the same box state with
nothing else of this session's running, is one gate:

```
BEFORE  pristine master, live tier ON     EXIT=1  239 s
AFTER   this branch, KIT_NO_LIVE=1         EXIT=0  108 s
                                        delta = 131 s
```

against the profiler's 127.1 s for the three tiers. **130 s, twice measured,
two ways.**

Standalone samples of the same gate across the session, for the spread:

| | samples (wall) |
| --- | --- |
| before | 241 s (red), 282 s, 231 s, 239 s |
| after | 147 s, 102 s, 102 s, 108 s |

### One datum about the tiers themselves, not about this packet

In BEFORE-4 — the live tiers all green — the gate still exited 1:

```
FAIL tests/tenancy_test.sh  (no identity, another tenant and its own tenant — …)
       FAIL: the shared cluster did not come up. Last lines:
               Network kit-tenancy_platform Error Error response from daemon:
               network with name kit-tenancy_platform already exists
```

Leftover docker state from the run immediately before it. `tenancy_test.sh` is
not idempotent against a network a previous run left behind, which is a second
reason this box needs one gate at a time and a third reason 23b should not be
carrying a docker tier it does not assert.

---

## 6. 23b, before and after

**Recipe invocation in both cases:**
`bash tests/validate.sh --language=ruby --no-self-test` with a `ruby` stub
reporting 2.6.10 — on `master` directly, and on this branch through
`kit_child_gate`, which is the only difference.

### Before — the deep tier, run 1 of 2

```
FAIL self_test: breakage 23b: an interpreter below the floor is a named skip, not a silent pass — the gate exited 1, so the skip was not clean
       FAIL tests/stack_live_test.sh  (the fetched stack runs; a trace and a metric land)
       FAIL: 1 check(s) failed.
```

### Before — the deep tier, run 2 of 2

```
PASS self_test: breakage 23b: an interpreter below the floor is a named skip, not a silent pass — reported as `templates/otel/ruby  (ruby 2.6.10 is below the template's 2.7 floor)`
```

### Before — the same scenario standalone, four times

```
sample 1  EXIT=1  241s  FAIL tests/canary_test.sh  / FAIL tests/stack_live_test.sh
sample 2  EXIT=0  282s  PASS ×3
sample 3  EXIT=0  231s  PASS ×3
sample 4  EXIT=1  239s  live tiers PASS; FAIL tests/tenancy_test.sh (leftover docker network, §5)
```

### After — the same scenario standalone, four times

```
sample 1  EXIT=0  147s
sample 2  EXIT=0  102s
sample 3  EXIT=0  102s
sample 4  EXIT=0  108s
```

each carrying **two kinds of skip, both named**:

```
SKIP templates/otel/ruby  (ruby 2.6.10 is below the template's 2.7 floor)
SKIP tests/canary_test.sh  (a canary secret reaches no exporter)  (NOT RUN — --no-live, or KIT_NO_LIVE=1: the observability live tier was opted out and this claim is UNEXERCISED)
SKIP tests/no_telemetry_in_readiness.sh  (collector killed, service still serves)  (NOT RUN — --no-live, or KIT_NO_LIVE=1: the observability live tier was opted out and this claim is UNEXERCISED)
SKIP tests/stack_live_test.sh  (the fetched stack runs; a trace and a metric land)  (NOT RUN — --no-live, or KIT_NO_LIVE=1: the observability live tier was opted out and this claim is UNEXERCISED)
```

```
PASS: every check passed.
note: 12 check(s) skipped — reported above, never hidden.
```

### After — inside the deep tier, three times

```
PASS self_test: breakage 23b: an interpreter below the floor is a named skip, not a silent pass — reported as `templates/otel/ruby  (ruby 2.6.10 is below the template's 2.7 floor)`, and named the --no-live skips too
```

**Runs actually performed.** Two deep tiers on `master`, three on this branch,
four standalone before-samples, four standalone after-samples, one paired
before/after sample, one `--no-live` and one unflagged whole gate for §4(1)–(3),
six mutations of the new check, and three earlier probe runs.

**23b's own gate run was executed six times before and seven times after: three
of the six before exited 1, none of the seven after did.** Three of the seven
after are whole-suite runs, which is what the packet asked for twice.

---

## 7. Four failures in the BEFORE run that are not this packet's

The pre-fix deep tier is **red on four other recipes**, and they are not mine:

```
FAIL self_test: breakage 96: a MAJOR bump ships without the MIGRATION the tier owes — the recipe no longer applies to its copy:
       …/kit-96/kit/VERSION: '1.0.0' not found
FAIL self_test: breakage 97: a MINOR bump declares a breaking change — the recipe no longer applies to its copy:
       …/kit-97/kit/VERSION: '1.0.0' not found
FAIL self_test: breakage 98: a breaking change sits under Unreleased, where no version covers it — the recipe no longer applies to its copy:
       …/kit-98/kit/CHANGELOG.md: '## Unreleased\n\n### Added' not found
FAIL self_test: breakage 99: a prerelease version string is tiered instead of refused — the recipe no longer applies to its copy:
       …/kit-99/kit/VERSION: '1.0.0' not found
```

**Cause:** commit `92a1127` ("revert my own regression: a breaking change may not
sit under `## Unreleased`") moved `VERSION` from `1.0.0` to `2.0.0`. Breakages
96–99 each `edit` `1.0.0` out of `VERSION`, and `edit` refuses an unmatched
string — so `this breakage no longer exists`, and the harness reports it as a
failure, which is the correct behaviour and the reason anyone found out at all.
98 additionally anchors on `## Unreleased\n\n### Added`, and the changelog now
leads with `### Changed`.

**I did not fix it, deliberately.** It is another packet's regression and the fix
is not mechanical: it needs a decision about what 96–99 should assert now that
the tree is at 2.0.0, and whether `2.0.0` owes a `## 2.0.0` section in
`MIGRATIONS.md` at all. Guessing at that from a live-tier packet is how a second
unrelated change ends up in one commit. It is loud rather than silent — which is
the only reason leaving it is defensible — and it is recorded here with the exact
lines so whoever owns the version string has it.

**These four were unchanged by this packet**, and appear in AFTER-1, AFTER-2 and
one of the two BEFORE runs.

### …and then a sibling packet fixed them, and the gate went green

While this session was measuring, `kit-version-recipe-drift-01` landed
`30b1708 breakages 96/97/98/99 derive their version from the copy, not from
1.0.0` plus `ab8114e no recipe may spell a version; a check says so before the
sixth one is written`. **AFTER-3 was run afterwards, on purpose, and the gate is
`exit 0` with `--no-live` in place** (§5):

```
PASS: self_test — all 107 breakages hold (103 assert red, 3 assert a green gate
with a named skip, 1 assert a green gate with a named finding), and the unbroken
tree is green.
```

So the two things this report needed to say about the gate's colour are: on
`master` it was red on 96–99 *and* intermittently on 23b; on this branch, as it
now stands, it is green. Two of the five AFTER-1/AFTER-2 failures in this report's
own tables are already history, and saying so is more useful than quietly
leaving the tables to imply otherwise.

---

## 8. What was rejected, and what each rejection costs

Recorded in full in `DECISIONS.md` (MD30); summarised because the packet asked.

| rejected | cost of rejecting it | why |
| --- | --- | --- |
| widen the three 900 s bounds | nothing measurable — **and nothing fixed**: §2.3 shows the failures were never `BOUND`, so the ceiling was never binding | a bound widened until it stops firing on a loaded machine stops answering the question it was written to answer, and does so invisibly: the tier still prints `PASS` |
| widen `bin/dev`'s deadline, or `stack_live_test`'s internal 420 s / 300 s | the same, one layer down | same sentence; `stack_live_test.sh` already writes this argument out about its own numbers |
| make the live tier contention-proof | 23b becomes a coin flip with a longer fuse | tuning three stacks against a machine kit does not control; the measurement in §2.2 says the problem is not even contention |
| run the recipes concurrently | a collision is indistinguishable from a real failure | the recipes share the docker daemon and kit's 15000–15999 block |
| drop breakage 23b | the suite loses the only proof that a skip is named | it is the assertion that a green gate can still be an honest one — and §4(2) is the demonstration |

---

## 9. What this does **not** prove, and what it costs

* **`self_test` no longer exercises the live tier at all.** A defect in
  `canary_test.sh`, `no_telemetry_in_readiness.sh` or `stack_live_test.sh` is no
  longer caught by the self-test; it is caught by the top-level gate, which still
  runs all three and whose green is the claim. That is a real reduction in what
  the suite proves, and it is the right reduction: those three are integration
  tests against a docker daemon, and a suite that runs 93 copies of one recipe's
  gate is asserting that the machine is quiet, which is a property of the machine.
* **§2.3 is a live, unexplained defect and this packet does not fix it.** The
  collector tiers fail intermittently on *content* assertions —
  `the ingest deny set did not run`, `allowed data was destroyed by the
  boundary: gpt-4o-mini`, `OTLP/traces rejected with HTTP 400` — on an
  otherwise idle box, with the stack verified to have come from the pinned ref
  and the fetched collector config verified byte for byte. This packet removes
  the self-test's exposure to it and does nothing about its cause. It deserves
  its own.
* **One deep tier is one data point, and the packet says so.** §5 carries two on
  this branch and two on `master`, and the honest reading of them is in §5: the
  whole-suite wall clock varies by ~300 s between runs of the *same* tree, which
  is larger than the effect, so the reliability claim rests on the six
  before/after executions of 23b's own gate rather than on the suite totals.
* **`self_test` on this branch as it now stands is `exit 0`** — 108 of 108,
  `all 107 breakages hold`, 0 environment failures, 0 skipped for a missing
  toolchain (§5, AFTER-3). It was red on 96–99 when this report's other AFTER
  runs were taken, and those four were fixed by a sibling packet mid-session
  (§7).
* **`--no-live` is set in exactly one place.** That is enforced by a check, but
  the check is a reader, not a type system: a spawn the regex does not recognise
  is a spawn the check cannot see. It is deliberately loose about the path and
  deliberately excludes `bash -n`; those are the two edges worth knowing about.

---

## 10. Reproducing all of it

```sh
# the count, and the three ways the opt-out can rot
bash tests/validate.sh --only="0 of the recipes name a live tier"

# (1)+(2): exit 0, higher skip count, the SKIP row present
bash tests/validate.sh --no-self-test --no-live; echo "EXIT=$?"

# (3): the top-level gate still runs all three, and what they cost
KIT_PROFILE=/tmp/p.tsv bash tests/validate.sh --no-self-test
grep -E '^tier\ttests/(canary_test|no_telemetry|stack_live)' /tmp/p.tsv

# §2: 23b's scenario, standalone, on pristine master vs this branch
#     (a copy needs a parent of its own, or it reads the parent's directories as a fleet)
git archive master | tar -x -C /tmp/solo/kit     # /tmp/solo must contain ONLY kit
cd /tmp/solo/kit && KIT_NO_LIVE=1 bash tests/validate.sh --language=ruby --no-self-test

# §5: the deep tier, timed
time bash tests/self_test.sh
```