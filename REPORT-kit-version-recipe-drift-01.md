# REPORT — kit-version-recipe-drift-01

**Branch** `worker/kit-version-recipe-drift-01` · **worktree** `cafaye/wt-m39-kit-version-recipe-drift-01`
**Base** `2202689` (master) · `VERSION` and `CHANGELOG.md` left at `2.0.0` — this packet is not a release.

> **This branch is based on `2202689`, and master has since advanced to `c8ac544`**
> (`567864e`, `c8ac544` — the live-tier packet's report). `git diff master HEAD`
> therefore shows `REPORT-kit-selftest-live-tier-01.md` as removed. It is not: the
> file postdates my base. My own diff is `git diff 2202689 HEAD` — five files, no
> deletions (`git log --diff-filter=D 2202689..HEAD` is empty). Re-base before
> merging.

Four commits. Nothing pushed, nothing merged, no tag. No time bound was widened.

| | |
| --- | --- |
| `30b1708` | breakages 96/97/98/99 derive their version from the copy |
| `c858158` | stability rule (4) compared a Breaking heading against the wrong neighbour, and vacuously |
| `ab8114e` | no recipe may spell a version; a check says so before the sixth one is written |
| `9a13b7e` | the sweep result, written down: one literal left, on the replacement side |

---

## 1. The red, first, on unmodified master

One shard per breakage so each measurement is that recipe and nothing else.

```
$ KIT_SELF_TEST_SHARD=96/103 bash tests/self_test.sh
self_test: breakage no longer applies to .../kit-96/kit/VERSION: '1.0.0' not found
FAIL self_test: breakage 96: a MAJOR bump ships without the MIGRATION the tier owes — the recipe no longer applies to its copy:
FAIL: self_test — 1 breakage(s) the gate did not catch.
```

Identical for **97** (`VERSION: '1.0.0' not found`) and **99** (`VERSION: '1.0.0' not found`).

**98 failed too, for a second and different reason** — this is the finding the
packet's own framing would have missed:

```
self_test: breakage no longer applies to .../kit-98/kit/CHANGELOG.md: '## Unreleased\n\n### Added' not found
```

Its anchor was not a version at all. It was `## Unreleased\n\n### Added`, and
`a5f8746` inserted `### Changed` as the first subsection under Unreleased. So
98 carried **two** independent fuses: the version sweep found neither, because
the version sweep only looked for versions.

**Count, verbatim:** `FAIL: self_test — 1 breakage(s) the gate did not catch.` per
shard, with the recipe's own line naming it. On a full unsharded run the packet
reports `105 recipes: 100 PASS, 5 FAIL` with 23b (a separate, already-diagnosed
packet) alongside these four; **I did not re-run the full suite to reproduce that
number** — see §7.

## 2. The green, and the half that matters more

All four shards green after the change:

```
[96] PASS self_test: breakage 96: a MAJOR bump ships without the MIGRATION the tier owes — caught by `stability gate`
[97] PASS self_test: breakage 97: a MINOR bump declares a breaking change — caught by `stability gate`
[98] PASS self_test: breakage 98: a breaking change sits under Unreleased, where no version covers it — caught by `stability gate`
[99] PASS self_test: breakage 99: a prerelease version string is tiered instead of refused — caught by `stability gate`
[99] PASS: self_test — shard 99/103 ran 1 of 107 breakages and every one it ran held.
```

An exit status proves nothing about whether a mutation landed, so each was applied
**by text** and the bytes shown before the gate was run. `2.0.0` in this table is
the copy's version; the derived destination is in brackets.

| recipe | mutation, as applied | gate verdict |
| --- | --- | --- |
| 96 | `VERSION` → `3.0.0` [major], changelog grows `## 3.0.0` + `### Breaking` | `the bump to 3.0.0 is a MAJOR, so it owes a consumer a MIGRATION, and MIGRATIONS.md has no "## 3.0.0" section.` |
| 97 | `VERSION` → `2.1.0` [minor], changelog grows `## 2.1.0` + `### Breaking` | `the bump to 2.1.0 is a MINOR, which derives the tier \`additive\`, and its section declares a breaking change.` |
| 98 | `### Breaking` inserted under the copy's own version-less section | `CHANGELOG.md declares a breaking change under \`## Unreleased\`, which is covered by no version at all.` |
| 99 | `VERSION` → `2.0.0-rc1` | `VERSION reads 2.0.0-rc1, which is not MAJOR.MINOR.PATCH.` |

Every finding quotes the **derived** version. That is the second half of the proof:
the mutation is visible in the message the check produced, so a recipe that
quietly mutated nothing could not produce this output.

`bash tests/validate.sh --static-only` → `PASS: every check passed.`, exit `0`,
measured after every commit.

## 3. The forward test — the one that matters

Simulate the release on a copy, then require each recipe to apply **and** bite.
Both shapes a release leaves behind, because one shape would have been enough to
pass and the other is the one `92a1127` actually produced.

**Each baseline is verified GREEN before any recipe runs.** This is not
fastidiousness: my first version of this harness produced a red baseline and I
could not tell which findings belonged to the recipe. (The cause was my own
harness — `open(m,"w").write(open(m).read()…)` truncates before it reads, so it
emptied `MIGRATIONS.md` and then blamed the gate. Fixed, and noted because a
measurement harness that manufactures its own red is exactly the hazard the
packet is about.)

### `minor` — Unreleased released as `2.1.0`, an ordinary additive release

```
baseline: PASS  VERSION 2.1.0, tier `additive` from 2.0.0
  96  (2.1.0 -> 3.0.0 MAJOR)  FAIL  the bump to 3.0.0 is a MAJOR … no "## 3.0.0" section
  97  (2.1.0 -> 2.2.0 MINOR)  FAIL  the bump to 2.2.0 is a MINOR … declares a breaking change
                                      CHANGELOG.md declares a breaking change under 2.2.0, which was released against 2.1.0
  98  (anchor heading [2.1.0]: CREATED a version-less section)
                                 FAIL  declares a breaking change under `## Unreleased`
  99  (2.1.0 -> 2.1.0-rc1)     FAIL  VERSION reads 2.1.0-rc1, which is not MAJOR.MINOR.PATCH
```

Note 98: with `## Unreleased` gone, the recipe **created** the section rather
than failing to find it. That branch is the one the literal hid.

### `first` — `92a1127`'s own shape: `## 2.0.0` renamed to `## 3.0.0`

```
baseline: PASS  VERSION 3.0.0, tier `breaking` from 1.0.0; a MAJOR owes a MIGRATION, and one is there
  96  (3.0.0 -> 4.0.0 MAJOR)  FAIL  the bump to 4.0.0 is a MAJOR … no "## 4.0.0" section
  97  (3.0.0 -> 3.1.0 MINOR)  FAIL  declares a breaking change under 3.1.0, which was released against 3.0.0
  98  (anchor heading [Unreleased]: inserted under the existing one)
                                 FAIL  declares a breaking change under `## Unreleased`
  99  (3.0.0 -> 3.0.0-rc1)     FAIL  VERSION reads 3.0.0-rc1, which is not MAJOR.MINOR.PATCH
```

All four applied and all four bit, in both shapes. **The bomb is disarmed.**

## 4. The check, and its own red proof

`self_test_no_version_literal` in `tests/validate.sh`, registered beside
`self_test_live_tier` and `self_test_claims` — i.e. inside phase 60, which
`--static-only` skips. Chosen over the packet's alternative (a suite-start guard
that resolves each anchor against a copy): it speaks at **authoring** time rather
than after the copy exists, costs one text pass rather than a set of throwaway
copies, and can name *which* recipe and *why* at the moment the decision is cheap.
The comparison is tabulated in `DECISIONS.md` (MD31).

The files in scope are **derived** — every path `edit` is handed that resolves to
`VERSION` or `CHANGELOG.md` — so a version recipe written next year covers itself.

Eight mutations, one property each. Exercised by sourcing the function out of
`validate.sh` (asserted non-empty) rather than by running eight full gates, which
would be 8 × 107 child gates:

| | mutation | expected | measured |
| --- | --- | --- | --- |
| control | as committed | GREEN | **GREEN** — `69 mutation(s) in 7 recipe(s); 0 anchors a bare version literal` |
| A | literal as the **anchor** | RED | **RED** — names `2.0.0` (*the tree is at 2.0.0*) and `3.0.0` (*a version this tree has never been at*) |
| B | literal as the **destination**, anchor derived | RED | **RED** — names `3.0.0` |
| C | literal in a `CHANGELOG.md` edit (98's old shape) | RED | **RED** — names `2.0.0` |
| D | same literal in `docker-compose.yml` | GREEN | **GREEN** — a pinned value is a different class |
| E | `1.0.0-rc1` / `v1.4.0` / `01.4.0` in a `VERSION` edit | GREEN | **GREEN** — `stability_parse` refuses all three, so no recipe can assert one |
| F | every version recipe rewritten away | RED | **RED** — *"no recipe edits VERSION or CHANGELOG.md any more, so this check is asserting over nothing"* |
| G | literal moved into a **comment** | GREEN | **GREEN** — comments excluded on purpose |

**F is the property that keeps A–G honest.** A rule that covers nothing reports
nothing, so its own emptiness is a finding.

## 5. A second defect, found by the forward test, in the gate itself

The simulation's baseline was red on a tree correct in every respect. That was not
the harness, and chasing it found **two** defects in rule (4) of
`stability_gate_check` — in the same seven lines.

**(a) The wrong neighbour.** `grep -B1` reads the section **above**. The claim "a
breaking change moves MAJOR" is about the bump that *produced* the version, and
the changelog is newest-first, so that is the section **below**.

> The clause **had never executed.** The only `### Breaking` in the tree is under
> `## 2.0.0`; the section above is `## Unreleased`, which `stability_parse`
> refuses, so the comparison short-circuited every time. A rule this file calls
> "the load-bearing one" had never once run.

> And it went **red on a correct tree**. Rename `## Unreleased` → `## 2.1.0`, set
> `VERSION` = `2.1.0`, change nothing else:
> ```
> FAIL stability gate  (a version bump pays for the tier it derives)
>        CHANGELOG.md declares a breaking change under 2.0.0, and the section above it is 2.1.0.
> ```
> `2.0.0`'s `### Breaking` is **legal** — released against `1.0.0`, MAJOR moved.
> The check was punishing a section for a release written after it.

Also: `-B1` on the first entry of a list returns that entry **itself**, so the
newest section was compared against its own MAJOR and `MAJOR <= MAJOR` was true by
construction — visible in the first forward run as breakage 96 reporting *"the
section above it is 4.0.0"* about `4.0.0`.

**(b) The comparison was vacuous, independently.** `stability_parse` returns no
value; it sets globals and **unsets them first**. Parsing the neighbour therefore
**overwrote** `STAB_MAJOR` before the test read it, so the test was
`[ neighbour_major -le neighbour_major ]` — true whenever it ran at all.

**They hid each other.** (a) resolved to `Unreleased`, which fails to parse, so
`&&` short-circuited and an always-true clause never ran. Dead *and* vacuous.
Fixing only (a) turns a dead clause into one that fires forever — and did: with
the neighbour correct and the aliasing left alone, **this repository's own legal
`### Breaking` went red**. I hit that, printed it, and fixed both together. The
message now reads *"which was released against"*, because that is the fact.

**Red proof, one property per tree, each with exactly one cause:**

| | tree | result |
| --- | --- | --- |
| control | master; `2.0.0`'s Breaking legal (MAJOR 2 vs 1) | **PASS** `tier \`breaking\` from 1.0.0` |
| 1 | `### Breaking` under a MINOR buried mid-history (`1.1.0` vs `1.0.0`), `VERSION` left at `2.0.0` so the tier clause cannot fire | **FAIL** `under 1.1.0, which was released against 1.0.0` |
| 2 | `3.0.0` MAJOR with a legal Breaking on top, `2.0.0` keeping its own, `MIGRATIONS.md` grown — must stay quiet | **PASS** `tier \`breaking\` from 2.0.0` |
| 3 | `### Breaking` under the **newest** MINOR — breakage 97's shape, the one `-B1` got right *by accident* | **FAIL** `under 2.1.0, which was released against 2.0.0` |
| 4 | `### Breaking` under a MINOR with a newer MINOR above it — the tree where `-B1` resolved "below" to itself | **FAIL** `under 2.1.0, which was released against 2.0.0` |

My first draft of case 1 fired for **two** reasons, so I rebuilt it around
`1.1.0` with `VERSION` untouched: a fixture that can go red two ways proves the
gate can go red and says nothing about which half fired.

`AGENTS.md` asserted the false claim — *"That rule needs no predecessor"* — and
that claim is load-bearing, so it is corrected in place.

## 6. The sweep

All **69** `edit` statements, against every class the packet nominated. Counts,
from the sweep:

| class | hits |
| --- | --- |
| version literal `N.N.N` | **0** |
| prerelease / leading-v | **0** |
| `## <version>` heading | **0** |
| `### <subsection>` name | **0** |
| port | 2 (`5432:5432`, `65532:65532`) |
| template path | 29 |
| `## Unreleased` | **1** |

**A sweep that finds nothing is a result**, so the four zeroes are recorded as
zeros. The single `## Unreleased` is breakage 98's **create** branch, and it is
left written down deliberately:

> a literal in an **anchor** kills the recipe at the next release; a literal in a
> **replacement** only makes it write an out-of-date name.

Only the first is a lost proof. A heading name derived from nothing would be
derived from the convention it *is*, which is circular.

Ports and template paths are not this class and were not given one: neither moves
with a release, and `edit` already refuses both loudly by name — a moved port or a
retired template surfaces as a `FAIL` naming its own copy, which is the machinery
working.

## 7. What is still not proved

- **No full unsharded `bash tests/validate.sh` run.** The backstop was 60 minutes
  and a full run is 107 throwaway gates. What I ran, each measured:
  `--static-only` (exit 0) after every commit; the four shards individually; the
  two forward simulations; five rule-(4) trees; nine check mutations. **Phase 60's
  three source checks, including the new one, therefore have not been observed
  inside a full gate** — they were exercised by sourcing the function, which runs
  the same Python the gate runs. A successor should run one full gate before
  trusting the merged state.
- **`self_test_live_tier` and `self_test_claims` were not re-verified** after the
  `self_test.sh` edit, for the same reason.
- **Two measured holes in the new check** (§4), both left open on purpose and both
  in `DECISIONS.md` (MD31):
  ```
  v_part="2.0"; edit "$baseNN/VERSION" "$v_part" "$v_part.0.0"   -> GREEN
  v96_major="2.0"."0.0"                                           -> GREEN
  ```
  The scan reads *arguments*, so a literal arriving through a variable is
  invisible. Closing them means re-implementing bash expansion (fires on correct
  code) or brace/backslash-counting recipe blocks (the fragility
  `self_test_live_tier` already removed an assertion over).
- **What a reader can no longer see.** All four recipes used to *state* the
  version they exercise. That is derived now, so it is not on the page. The
  numbers are still in the tree — `VERSION` and `CHANGELOG.md` of the copy — and
  the check quotes the derived version in every message in §2 and §3. 99's label
  still says "a prerelease version string" and no longer names `1.0.0-rc1`
  specifically; the concrete string is `$(copy_version …)-rc1`.
- **The recipe's meaning is now partly implicit.** "MAJOR of whatever the copy
  carries" is a smaller claim to read than "1.0.0 → 2.0.0", and it is the
  *right* smaller claim. The cost is that a reader can no longer see the version
  under test without running the recipe.
- **`edit` and the live-tier report's defect.** The packet asks whether the claim
  "`edit` fails loudly on an unmatched anchor under `set -uo pipefail` without
  `-e`" still holds. **It no longer applies**: `tests/self_test.sh:565` is
  `set -euo pipefail`, and `edit` was reworked to *record* rather than exit, with
  the loudness moved into `expect_red*` specifically so one stale recipe cannot
  abort every other shard. Measured on master: it prints
  `self_test: breakage no longer applies to <path>: <literal> not found` **and** the
  owning recipe reports `FAIL … the recipe no longer applies to its copy`. **My fix
  does not depend on `edit` exiting non-zero** — `bump`'s refusals are read from
  output, and `copy_version` cannot fail silently because `bump` refuses a
  non-`N.N.N` string.

## 8. What a successor should do first

1. Run one full `bash tests/validate.sh` on the merged branch — §7's first item.
2. Read `DECISIONS.md` (MD31) before touching `stability_gate_check` rule (4) or
   the four recipes; both now carry a reasoning that is easy to undo by accident.
3. On the next release, expect the four recipes to name a version you have not
   seen in this report. That is the point.