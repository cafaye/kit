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

## A latent harness bug this packet exposed, and the fix

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
