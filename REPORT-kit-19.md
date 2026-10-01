# REPORT — kit-19 (sell-license)

kit carries a licence, and a check that keeps the grant unambiguous.

Base for the work: `master` at `a095992` (kit-18's integration, five packets and
one numbering scheme). Branch `worker/sell-license`.

## What the packet is

cafaye's decision is MIT across the fleet. `kit` carried no `LICENSE` at all,
which is not "unlicensed, therefore free" — it is **all rights reserved**, the
default copyright position when a public repository grants nothing. `docs`'
`licensing.md` measured this on 2026-10-01 and named `kit` in the "nothing" row,
alongside `identity`, `billing`, `courier`, `parlor`, `core` and `caf` — three of
which are purchasable units. That page measures committed `master` deliberately
and says so; this packet changes what it will find on the next run.

The interrupted work had already written `LICENSE` and two README paragraphs. What
was missing was the reason this repository would not have shipped a bare file:
nothing held the claim, and nothing proved the check could fail.

## The interesting half is agreement, not existence

A licence is only unambiguous when exactly one place in a repository can declare
one. `license_check` asserts:

1. **the grant, by MIT's own sentences** — `Permission is hereby granted, free of
   charge` and `THE SOFTWARE IS PROVIDED "AS IS"`. Not the string `MIT`, which is
   also how a badge line, a summary, or a note about a *different* repository's
   licence is spelled; matching the identifier passes all three. The warranty
   disclaimer is the sharper of the two, because its absence is how a copied
   identifier is told apart from a real grant.
2. **a copyright holder.** MIT's attribution obligation is that the notice
   travels with the software. A grant with no holder is a grant nobody can
   attribute.
3. **the README, against its own `## License` section** — not the whole document.
   The AGPL paragraph names a licence that is *not* kit's, so a whole-file
   substring search is satisfied by the exact conflation the section split exists
   to prevent. It also asserts the section names AGPL at all: "MIT for kit" and
   "AGPL for the four backends we ship unmodified" are two questions, and the
   section answering the second has to say why it does not change the answer.
4. **every root manifest that can carry a licence field**, and fails on any that
   declares something other than MIT.

Point 4 is root-only on purpose. `templates/` holds `go.mod` files and a service's
`package.json`; a licence in a template is that template's business, and only the
root can be about kit.

**It checks agreement, and does not ban the manifest.** A check satisfied by "kit
has no `package.json`" would be satisfied by deleting one and would be a `FAIL`
the day kit legitimately grew one — the same shape as breakage 31b's green
control. The check requires agreement, so it is a rule rather than a ratchet.

## The two breakages, and why 62 is the one that matters

| # | mutation | named check |
|---|---|---|
| 61 | `LICENSE` deleted | `LICENSE  (MIT, and nothing in the tree can disagree with it)` |
| 62 | root `package.json` declaring `AGPL-3.0-only` | same |

61 is the direction everybody can see: the grant is gone, and the README is still
saying MIT — which is exactly why it needed a check, because the documentation was
true and the repository was not.

62 is the direction nobody looks at. `LICENSE` says MIT, the README says MIT, and
the repository has acquired a *third* statement that a compliance tool reads. A
manifest is easy to add and looks like a build decision rather than a legal one. A
check asserting only that `LICENSE` exists is satisfied by exactly that state, so
62 is what makes this a check rather than a file-presence assertion.

Both verified directly before the self-test, on a throwaway copy of the tree:

```
# package.json with "license": "AGPL-3.0-only"
FAIL LICENSE  (MIT, and nothing in the tree can disagree with it)

# LICENSE removed
FAIL LICENSE  (MIT, and nothing in the tree can disagree with it)

# control, neither mutation
PASS LICENSE  (MIT, and nothing in the tree can disagree with it)
```

62's fixture is **assembled with `printf`**, not written out. Same rule as
breakages 24, 25 and 33: a probe written out is a probe committed, and the
breakage would then be caught by the wrong thing.

## One coupling the harness needed

`fresh_copy` copies an explicit list of what the gate READS, and `LICENSE` was not
on it. Without the addition, `license_check` fails on every throwaway copy for a
reason that has nothing to do with the defect under test — and the two
green-expecting proofs (23b a SKIP, 59 a FINDING) would have gone red for that
reason. A check that cannot run in a copy is a proof that proves nothing while
reporting something.

## Two latent harness bugs this packet exposed, and the fixes

### 1. `expect_green_check` read a MATCH as a non-match

The first full self-test run came back with **one** failure, and it was not one of
mine:

```
FAIL self_test: breakage 59: an UNADOPTED service copies the stack — green, and
  named — the gate stayed GREEN but `fleet  (adopting repositories clean;` did
  not report PASS
tests/self_test.sh: line 589: printf: write error: Broken pipe
```

`expect_green_check` had the SIGPIPE defect this file already documents at length
inside `expect_red_check`: `printf '%s\n' "$out" | grep -qF`, where `grep -q`
exits at the first match, `printf` dies of SIGPIPE, and `set -o pipefail` promotes
that 141 to the pipeline's status — so `! pipeline` reads a **match** as a
non-match.

It was latent because the gate's output had not yet been large enough to overflow
the 64K pipe buffer. `license_check` prints its measurement on PASS, which is what
`check`'s own contract asks of a check reporting which spec it verified, and that
single line was the crossing point. Reproduced outside the suite to confirm the
mechanism rather than the coincidence:

```
contains: MATCH found at 5000 lines
contains: correctly absent
grep -qF at 5000 lines: rc=141 (the SIGPIPE defect)
```

The two candidate fixes were to stop the check printing, or to stop the harness
piping. **Stopping the check printing was the wrong one twice over**: it
contradicts `check`'s documented behaviour, and the threshold it hides behind is a
property of the pipe buffer, so it moves with the machine and the bug returns as a
flake on somebody else's packet. The output was already captured in a variable —
there is no reason to pipe at all.

So the fix is a `contains` helper — a shell `case`, no pipe — and all three
assertion helpers now go through it: `expect_red_check`, `expect_green_check` and
`expect_skip_check`. Sharing one helper rather than three correct copies is the
point, because the failure mode is a property of how the harness READS output and
nothing to do with which check it is reading.

This is a fix to a check, not a weakening of one, and it is the same fix
`expect_red_check` received for breakage 30. No recipe, threshold or pin changed.

### 2. A gate that reported nothing was reported as a red for the wrong check

The **full** gate on the merged tree then came back with a second, unrelated
failure, and this one was a real defect in the harness rather than in the tree:

```
FAIL self_test: breakage 35: kit offers `language: bun` but ships no primer for
  it — the gate went red, but NOT via `tests/artifacts.json  (…)`
```

Breakage 35's mutation is deleting `templates/bin-prime/bun.sh`, and I confirmed
the named check fires on exactly that state:

```
# a copy with templates/bin-prime/bun.sh deleted
FAIL bun  (Dockerfile + bin/prime present)
FAIL tests/artifacts.json  (every declared source exists, for every language)
FAIL: 2 check(s) failed.
```

So the recipe and the check are both sound. What the log shows is that the
failing run printed **no nested `FAIL` line at all** — the inner gate exited
non-zero having reported nothing, and `expect_red_check` had no verdict for that,
so it fell into "red, but not via the named check" and blamed
`tests/artifacts.json` for it.

`validate.sh` exits 1 on a FAIL **and** exits 1 from bootstrap when it cannot
install its own dependencies (lines 132 and 3195), and the second path never
reaches a single check. The two are indistinguishable from the exit status alone.
Load average was 15 on a 16GB box with other workers' gates running.

The fix is a third verdict, `SKIP`, and the deliberate detail is that it uses a
**separate counter** (`env_skips`, against the existing `skips`) because a
missing toolchain and an unevaluated proof are different problems: the first is
a machine you cannot equip, the second is a recipe that could not be evaluated at
all. Both stay fatal, because a proof nobody ran is not a proof — but neither is
reported as a check that failed to catch its defect, which is what would send the
next reader to weaken something that is fine.

Isolating the predicate and running all four cases, so the classification is
measured rather than asserted:

| the nested gate | classified as |
| --- | --- |
| `exit 1`, no output at all | SKIP — environment failure |
| red, naming a **different** check | FAIL — red for the wrong reason (unchanged) |
| the named check fires | PASS (unchanged) |
| green, no finding | FAIL — stayed green (unchanged) |

The last row is the one to read carefully: this widens what counts as an excuse
by **exactly** the case where the gate said nothing, and no further. Same
principle as breakage 39, which asserts the explanation rather than the exit
status for the same reason — a red that misattributes itself is worse than no
red.

`env_skips` deliberately cannot appear in the PASS summary line, because it is
non-zero only on a run that exits 1; the summary states the count on its own line
instead, and says the number of recipes that were *evaluated*.

## Counts, and where they are checked

The self-test is now **67 breakages, 65 of which must go red, 2 green-expecting,
and 47 asserting the named check**. Three places carry those numbers:

- `tests/self_test.sh`'s header, checked against the recipes by
  `self_test_claims` — 67 named, 67 carried, zero disagreement. This one is
  mechanical; it could not have been left at sixty-five.
- the summary label in `tests/validate.sh`, which is **counted** from the recipes
  rather than written down, so it cannot drift.
- README.md and AGENTS.md prose, which is **not** mechanically checked. Updated in
  both, deliberately, and that is the honest description of them: they are the
  sentence a reader believes.

`fresh_copy`'s control ("the gate is green on an unbroken tree") passes, so the
two new breakages are the only reason the new check goes red anywhere.

## The gate, and its real exit status

The full run, `bash tests/validate.sh`, **exit 0**:

| phase | verdict |
| --- | --- |
| static (every check, including `LICENSE`) | PASS |
| telemetry — six traceparent suites, executed | PASS |
| telemetry — the canary harness, five vectors | PASS |
| observability — canary reaches no exporter | PASS (real collector) |
| observability — service serves with the collector killed | PASS |
| observability — the fetched stack runs; trace and metric land | PASS |
| classifier + staleness, executed | PASS (19 + 26 cases) |
| lint — four linters run against failing fixtures | PASS (14 assertions) |
| self_test — 67 breakages | PASS, `0 environment failures, 0 skipped` |

`note: 2 check(s) skipped` — both reported, neither hidden:
`templates/tier/{bun,node}/tier.test.ts`, because `node --check` cannot read
TypeScript and there is no type-stripping parser. That is the honest-skip rule
working as written, not a passing tier.

`note: 4 tier(s) ran under a time bound; none was reached` — the three docker
stacks and the self-test each ran under their ceiling and none hit it, so all
four completed rather than being abandoned.

Getting here took three full runs, and the sequence is the point:

1. red on **breakage 59** — the SIGPIPE bug (fixed: `contains`).
2. red on **breakage 35** — the no-finding misattribution (fixed: the third
   verdict).
3. green, exit 0.

Between runs 2 and 3 a standalone self-test was SIGKILLed at breakage 40 — the
exit-137 case this repository already documents, on a 16GB box that was at load
15 with other workers' gates running. Nothing in the tree changed between that
kill and the green run; only the machine's load did. It is the clearest
demonstration in this packet of why an unevaluated proof is reported as an
environment failure rather than as a check that failed: the evidence for "the
code is fine" is a run that completed, and a killed run is not that.

## Not done, and why

- **`docs`' `licensing.md` still lists `kit` in the "nothing" row.** That page
  measures committed `master` with `git show HEAD:`, and it says so in a caution
  block: it is behind, not wrong, and it updates in its own commit when this
  lands. Editing it from here would be reporting another repository's measurement.
- **No SPDX identifier, no `NOTICE`.** MIT needs neither, and adding one is a
  decision rather than an omission — the check already fails on any *disagreeing*
  licence field, which is the property that matters.
- **The templates were not given a licence.** A manifest in `templates/` is that
  template's business and is deliberately out of the check's scope; if kit later
  wants every shipped template to carry MIT, that is a separate decision with its
  own parity-allowlist consequences.
