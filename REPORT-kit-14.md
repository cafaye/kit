# REPORT — kit-14: the staleness reporter, pointed at `templates/`

**Worktree:** `worker/kit-14-stale` · **Base:** `41f8bcb` (master) · **Date:** 2026-09-30

**The three things the packet asked for, and where they are:**

1. the three states and the vocabulary for the missing one — §2, and
   `tests/staleness.py --scope templates`
2. a pin or an admission, in kit's existing dialect — §4, and
   `templates/parity-allowlist`
3. never infer a pin from content — §3, with the counterexample that proves it

**The measured result** is §6. **What I could not verify** is §7, and it is
longer than any other section here, which is the honest proportion.

---

## 1. What the packet actually asked for, restated honestly

The brief says this is not "detect drift in `templates/`", and it is right.
Drift detection compares two copies. In `templates/` there is often only one,
and the interesting question is not *how far has it moved* but *is it there at
all*.

Measured before anything was written, across the nine services:

| | |
| --- | --- |
| services holding a `docker-compose.yml` | 7/9 |
| services holding `otel-collector.yml` | **0/9** |
| services holding Tempo, Loki, Mimir or the Grafana provisioning | **0/9** |
| services holding `bin/dev` | 1/9, and that copy predates kit's observability profile |
| artefacts byte-identical to kit | **9 of 108 cells** |

So the reporter needed a state for "kit ships this and the service holds
nothing", and it needed that state to be a **finding with a number on it**
rather than a gap in a table. That is the whole design.

---

## 2. The three states, and how each is reported

`tests/staleness.py --scope templates` reports **five**. Three of them are the
ones the packet asked for; the other two exist so the three can mean what they
say.

| state | what the reporter saw | how it is reported |
| --- | --- | --- |
| `current` | the bytes at the declared path equal kit's, and the path is a real file in the service's own tree | a counted row; `current` cells are **omitted from the table** and counted in the summary, because a report that prints all 108 cells buries the 80 that are not fine |
| `diverged` | present at the declared path, not byte-identical | a row with `+N -M` lines, the first differing line number, a three-way breakdown for bundles, and the pin that explains it — reason, owner, expiry |
| **`absent`** | kit ships it; nothing at the declared path | **its own row, its own number in the summary, and its own verb in the ledger.** This is the state the reporter had no word for. |
| `unknown` | the comparison could not be made | a row, a pin, and a reason in words — never a pass |
| `n/a` | kit ships no variant of this artefact for that service's language | counted, never a row, **never needs a pin** |

### Why `unknown` and `n/a` are both needed

`AGENTS.md` says the classifier fails closed, and that is a rule about code.
This reporter inherits it rather than restating it: **an input it cannot place
is a finding, never a pass.** Four things land in `unknown` —

- the service declares no `language`, so the `{lang}` source is unresolvable
  (measured: `pantry`, all five cells);
- the path is a **symlink**;
- the path is not a regular file, or cannot be read;
- kit no longer ships the artefact, so there is nothing to compare against.

`n/a` is the escape from the other end. A Go service has no `.rubocop.yml`
because it is not a Ruby service, and that is a *settled fact*, not a failed
measurement. The first version reported it as `unknown` and the consequence was
immediate and measurable: **every service in the fleet carried three permanent
findings that nobody could fix.** A word that always fires is a word nobody
reads, and that is the same failure as a check that is always green.

### Bundles: `compose` is one artefact, not twelve

`docker-compose.yml` mounts the other eleven files **by path**. A service holding
eight of them has adopted kit's stack badly, and eleven separately-pinned cells
would report that as eight successes and three absences. So `compose` is graded
as one artefact with twelve members, and the note says which shape it is:

```
billing  compose  diverged  partially adopted: 1 of 12 member(s) held
                               (every member it holds is its own), 11 missing
```

`artifacts.json` may also carry `destAlternatives` — declared paths a service is
documented as using instead. Six of the nine Dockerfiles sit at the repository
root rather than at kit's documented `docker/Dockerfile`, and grading that
`absent` is crying wolf over a working placement. Resolution is by **existence
among a declared list**, never by content and never by a search, and `absent`
still means absent of every one of them.

**A correction to what I first wrote here, because it is the kind of error a
measurement makes and a reader repeats.** The first draft of this report — and
of eight `parity-allowlist` reasons — said a partially-adopted stack "cannot
start". I checked it, and it is **wrong for this fleet**:

```
$ grep -cE '\./(otel-collector|tempo|loki|mimir|grafana)' */docker-compose.yml
billing 0   courier 0   darkroom 0   guard 0   identity 0   muse 0
$ grep -cE '^\s+- \./' templates/compose/docker-compose.yml
5
```

None of the seven services' compose files mounts a single one of kit's eleven
files. They declare **one or two services** (`db`, `app`, `postgres`,
`guard`, `identity`) and they are not kit's stack with pieces missing — they are
**replacements**, which is exactly what the packet said and exactly what
`diverged` is the right word for. `docker compose config` is **green on five of
them**, so they are valid, runnable stacks; they are just not this one. The
"cannot start" wording is gone from the ledger, and §6 has the corrected
sentence.

---

## 3. Never infer a pin from content

The packet names the failure exactly: a reporter that computes a hash, finds it
matches, and calls the artefact current, while the artefact in the service is
something else.

The rules, and each one is load-bearing:

1. **Identity is positional.** A cell is resolved at the path
   `tests/artifacts.json` declares — or at one of that artefact's *declared*
   `destAlternatives`, resolved by which of them exists. There is no search, no
   nearest match, and no hunting for a file that hashes to kit's artefact. A
   reporter that went looking would eventually find a plausible file in a
   directory nobody meant. (A glob appears once in this script and it is not
   here: it is in the check that asks *does this tree still ship the file the
   table names*, where a `*` in place of `{lang}` is the question being asked.)
2. **No similarity threshold.** No percentage, no `quick_ratio()`, no
   "close enough". `current` means the bytes are **equal**.
3. **A symlink is not a copy.** A symlink at the declared path whose target is
   byte-identical is `unknown`, not `current`. The bytes are right today and the
   arrangement is a bet that the target never moves — and it is a shape a
   service adopts by accident.
4. **The language is DECLARED, never sniffed.** It is read from the service's
   own `with: language:` in its CI caller — the same field the build uses, so the
   reporter and CI cannot disagree. A `go.mod` is a guess about intent; an input
   is a statement of it. No declaration means `unknown`, not a default language.
5. **The `uses:` line is anchored on the first token.** `docs`'s workflow
   contains `echo "    uses: cafaye/kit/…@master"` inside a `run:` block and a
   `grep` for the same prefix. A substring search calls that a call and reports
   a service as pinned at a ref it never pinned — a `current` backed by a quoted
   echo argument, which is the same failure in a new costume.

**And the rule has a counterexample, because a rule nobody has tried to break is
a rule nobody has tested.** `tests/self_test.sh` breakage 27 rewrites the
comparison to `pair_kit == repo_bytes or matcher_ratio(...) > 0.99` — the
well-intentioned patch a helpful contributor would write, since `difflib` is
already imported — and asserts the suite notices. The property it breaks is the
one asserting a **one-byte** difference is `diverged`, which is the rule in its
smallest form.

---

## 4. The pin format and its hygiene rules

`templates/parity-allowlist`. **The same dialect as
`templates/tier/skip-allowlist` — same four rules, same words, one entry per
line.** kit does not have two dialects of "record why", and two dialects is how
one of them goes stale.

```
<verb> <repo> <artefact-id> reason="…" owner=… since=YYYY-MM-DD until=YYYY-MM-DD
```

Three verbs, and the third is why this is not a two-verb format:

| verb | meaning |
| --- | --- |
| `diverged` | the service holds the file and it is not kit's bytes |
| `absent` | kit ships it and the service holds nothing at that path |
| `unknown` | kit cannot say what the service would have copied — no declared `language` |

`unknown` needs its own verb because it is a finding like the others, and a
two-verb ledger would have to **state something false** about it to record
something true. A ledger that must lie to record a fact is a ledger that gets
left alone.

### Rules 1–4, inherited verbatim

1. every entry names a **reason**; 2. every entry names an **owner**;
3. every entry has **both** `since` and `until`, and the gate reads the clock —
   an expired entry is a FAILURE on the day it expires; 4. an entry that
   **matches nothing** is a failure, ESLint's `reportUnusedDisableDirectives`
   shape.

`until` on every one of the 80 entries is `2026-12-31`, so this file is expected
to go red four times a year and each time the correct response is to re-copy the
artefact and delete the entry. That is the ratchet, and it is why the entries
that record "nobody has written down why" are worth writing down at all: they
expire.

### What is NEW, and why this ledger needed it and the tier one did not

**An unpinned divergence or absence is also a failure.** The tier allowlist does
not need that rule: its entries name tests that are either present or absent for
reasons the file's own comments explain. This one names copies in repositories
the gate cannot read, so the file is a **record of the fleet** — and a record
that silently omits a cell is worse than no record, because it reads as
"handled".

Two directions, and the same rule seen from two ends:

| direction | failure it prevents |
| --- | --- |
| an entry that excuses nothing | the file empties itself silently |
| an unpinned finding | the file grows without ever expiring |

### The verb is CHECKED AGAINST THE MEASUREMENT

An entry is a record of a decision, so a well-formed entry whose verb disagrees
with what the reporter found is **worse than a wrong one**, because it looks
maintained. Measured: `identity`'s `.golangci.yml` appeared in the working tree
between two runs of the reporter, the entry said `absent`, and the reporter
reported the disagreement by name rather than accepting a well-formed line. That
is a third, distinct failure shape — not a dead entry and not a correct one —
and it is why the verb is not taken on trust.

### The count is a measurement, printed on green

```
parity allowlist: 80 entries across 9 repositories, every artefact id in
artifacts.json, none expired, none dead. THE TOTAL IS THE MEASUREMENT: 80
entries is 80 copies of kit's templates that the fleet has not adopted or has
changed, and the way to shrink it is to re-copy, not to delete an entry.
```

It is printed on **PASS**, indented under the check's label, so it is visible in
a green run — the only place a growing list is least likely to be noticed, which
is why the tier allowlist prints its count too. And because that sentence is a
claim, it is enforced: deleting an entry to shrink the file is caught by the
dead-entry rule.

---

## 5. Gates and breakages

### `tests/validate.sh` — three new checks

| check | what it proves |
| --- | --- |
| `templates/parity-allowlist (reason, owner, since, until; dead entries fail)` | the four hygiene rules, plus an entry naming an artefact `artifacts.json` does not declare, plus duplicates, plus expiry. Inventory is read from **`artifacts.json` — the same file the reporter reads**, because a second unchecked copy of the truth is the defect kit already has had once. |
| `tests/artifacts.json (every declared source exists, for every language)` | every declared source is a real file in this tree, and every `{lang}` source resolves for **all seven** languages the workflow offers. A table with a typo makes every service `absent` forever, which reads as a migration backlog and is actually a typo. |
| `tests/classify.py + tests/staleness.py (stdlib only; the carve-out, enforced)` | the two programs import nothing outside the standard library, and every module they import is **named in `AGENTS.md`**. New in this packet — see §7.8. |

The first two are read, not reimplemented: the artefact-table check calls
`staleness.validate_table_against_kit` directly, because two implementations of
"is this a real path" is one implementation too many.

### `tests/self_test.sh` — breakages 23–28

| # | mutation | caught by |
| --- | --- | --- |
| 23 | a parity entry naming an artefact kit does not ship (the rename case) | the named dead-entry check |
| 24 | a parity entry naming a repository that does not exist | the same check, the **other** direction |
| 25 | `templates/bin-prime/bun.sh` deleted | the named artefact-table check |
| 26 | `absent` reported as `current` | `staleness_test.sh` |
| 27 | graded by `quick_ratio() > 0.99` instead of equality | `staleness_test.sh` |
| 28 | a function-local `import requests` in `tests/staleness.py` | the named carve-out check |

**26 is the packet's own case, and it is the one that matters.** One line
changed in the classification turns the commonest column of the report green.

**26 and 27 are separate breakages** because they are opposite mistakes — one
removes a finding, the other invents one — and a gate that can only do one of
them is half a gate.

**28 is a check I added because I had just claimed a rule in `AGENTS.md` that
nothing enforced.** "Standard library only" had been a sentence for the whole
life of the carve-out with no check behind it. Writing the check immediately
found the rule out of date: the reporter imports `glob` (mine, from this
packet), and it has always imported `urllib` without `AGENTS.md` naming it. The
check walks the **AST**, not the text, so a function-local import — which is what
a careful contributor actually writes — is read the same as a top-level one, and
it asserts that every module it finds is named in the sentence. A boundary
nobody can cross is not a boundary.

### `tests/staleness_test.sh` — 26 cases, up from 12

New cases, and what each is really for:

- `current` / `diverged` / `absent` told apart (the control)
- an absence is a **counted** finding, not silence; and a **half-adopted stack**
  is `diverged`, not two successes
- a divergence carries the pin that explains it, and a missing pin is **named**
- a **one-byte** difference is `diverged`, never `current`
- a **symlink** to an identical file is not a copy
- undeclared language → `unknown`; not-applicable → `n/a`; and the two do not
  contaminate each other
- `--fail-on-unpinned` is **red**, naming the unpinned absence, and **green** on
  a fully pinned service — a flag that cannot go green is a constant `exit 1`
- three kinds of dead pin fail, and a pin for a repository merely **out of
  scope** does not
- a `uses:` string inside a `run:` block is not a call
- a declared alternative path is graded, not called absent
- the two scopes do not interfere
- a table naming a file kit does not ship is **refused**

The fixture copies kit's **real** artefacts byte for byte, so a `current` cell
in the fixture means what it means in the fleet, and a renamed artefact turns the
control red rather than quietly making the suite green. It builds eight
services — one fully adopted, one deliberately edited, one that adopted nothing,
one that declares no language, one whose only divergence is pinned, one holding
a symlink, one holding half a stack, one whose Dockerfile is at the repository
root — because each of those is a different answer and the point of the suite is
that the reporter gives a different one.

Two things in the suite exist only because a check was *found* to be wrong rather
than because they were planned:

- **`KIT_KEEP_WORK=1`** leaves the fixtures on disk. Debugging a state table by
  re-reading the shell recipe is guessing; the difference between the two is one
  directory.
- The suite's case count is **read out of its own run** and the gate fails if it
  falls below 20. Counting `printf 'PASS …'` sites in the source gives 27 while
  the suite runs 26, because case 9b has two mutually exclusive branches. A
  number derived from the source and a number the reader sees in the output that
  disagree on a green run is how a count stops meaning anything.

---

## 6. The measured fleet result

Run against the real working tree at `41f8bcb`, the nine services. Reproduce:

```sh
tests/staleness.py --repos-dir .. --scope templates \
  --repo billing --repo caf --repo courier --repo darkroom --repo guard \
  --repo identity --repo muse --repo pantry --repo parlor
```

### By artefact — all 108 cells

| artefact | current | diverged | absent | unknown | n/a |
| --- | --- | --- | --- | --- | --- |
| `ci.reusable.yml` | **8** | 0 | 1 | 0 | 0 |
| `bin/prime` | 1 | 7 | 0 | 1 | 0 |
| `docker/Dockerfile` | 0 | 7 | 1 | 1 | 0 |
| `mise.toml` | 0 | **9** | 0 | 0 | 0 |
| `AGENTS.md` | 0 | **9** | 0 | 0 | 0 |
| `bin/dev` | 0 | 1 | **8** | 0 | 0 |
| `compose` | 0 | 7 | 2 | 0 | 0 |
| `lint/yamllint.yml` | 0 | 0 | **9** | 0 | 0 |
| `lint/hadolint.yaml` | 0 | 0 | **9** | 0 | 0 |
| `lint/golangci.yml` | 0 | 1 | 1 | 1 | 6 |
| `lint/rubocop.yml` | 0 | 1 | 0 | 1 | 7 |
| `lint/eslint.config.mjs` | 0 | 1 | 1 | 1 | 6 |
| **total** | **9** | **43** | **32** | **5** | **19** |

**9 current, 43 diverged, 32 absent, 5 unknown, 19 not applicable.** All 80
findings are pinned; `--fail-on-unpinned` exits 0 per service and per fleet.

**Nine of 108 cells are byte-identical to kit, and eight of the nine are the same
artefact** — the workflow call. `guard/bin/prime` is the tenth, and it is the
only file in the fleet that matches a kit template exactly. It matches because
`guard` is the service kit's own CHANGELOG credits with causing the `bun` job to
exist: it is the one service that copied a template *after* it was written rather
than before. That is the whole adoption story in one cell, and it is the proof
that the pipeline works when it is run in the right order.

### What is current — nine cells, and eight of them are the workflow call

`ci.reusable.yml` is 8/9 current: every service that calls kit's workflow calls
it at `@master` at the documented path. That is the fleet's best result and it
is the artefact the packet's `8/8` refers to.

The one that is not is `pantry`. It has no caller, and the reason is not a
shrug: its CI is a `workspace-drift` job over thirteen repositories, not a
per-language service build, and calling kit's workflow would be the wrong shape.
It is a real decision and it was invisible until the ledger made somebody write
it down.

The ninth current cell is `guard/bin/prime`, covered above.

### What is diverged — and three of the four groups are adoption *working*

**`mise.toml`, 9/9.** README step 4: raise every placeholder. Nine services did
it, 8–32 code lines apart once comments are stripped.

**`AGENTS.md`, 9/9.** README step 5: fill in the placeholders, delete the
sections that do not apply. **The raw diff is 258–624 lines per service, and
that number is the most misleading figure in this packet.** With markdown
comments stripped the difference is **8–19 lines**: nine filled-in forms. A
reporter that printed only the raw number would make the best-behaved artefact
in the fleet look like the worst, and would send somebody to re-copy a file that
was never broken. The reporter prints the raw count *and* the breakdown, and the
pin for each of the nine says what the divergence is.

**`docker/Dockerfile`, 7 diverged + 1 absent + 1 unknown.** The template carries
`SERVICE_NAME` as a slot the adopter is **required** to fill, so a byte-identical
copy is not a thing that can exist. This divergence is the convention working.
`caf` holds no Dockerfile at all (it builds with the host toolchain and
goreleaser); `pantry` declares no language, so kit cannot say which one it would
have shipped.

**`bin/prime`, 7 diverged + 1 current + 1 unknown.** These are **not** filled-in
placeholders: with comments stripped they differ by 32–63 lines of script, the
fleet's versions begin `#!/bin/sh` where kit's begin `#!/usr/bin/env bash`, and
they lack the STRICTNESS NOTES block. They predate kit's. **Nobody has written
down why any individual one diverged**, and the ledger says so in those words
rather than inventing a justification — an entry that says "nobody has recorded
this" is a backlog item with a name on it, which is the most an honest first
ledger can be.

**`compose`, 7 diverged (partially) + 2 absent.** The headline is not the ~420
line diff the brief mentions. It is that of the twelve files kit ships, the
fleet holds `docker-compose.yml` in seven services and `.env.example` in two,
and **the collector, Tempo, Loki, Mimir and the Grafana provisioning are 0 of 12
in all nine services.** None of the seven mounts one of kit's eleven files, so
they are **replacements that kept a filename**, and `docker compose config` is
green on five of the six that have one at all — they are valid stacks that are
not this one. `pantry` holds `.env.example` and **no compose file**, which the
reporter reports as `partially adopted` with one of twelve members held rather
than rounding it to a clean "absent".

**One real defect a byte-comparison cannot see, found while checking the
sentence above:** `muse/docker-compose.yml` **does not parse**.

```
$ cd muse && docker compose config
yaml: line 65, column 67: mapping values are not allowed in this context
```

An unquoted `${MUSE_VAULT_KEY:?set MUSE_VAULT_KEY, or run: uv run python -m
muse.vault}` — the error message contains a colon, and YAML reads the value as
the start of a mapping. The reporter calls that cell `diverged`, which is true
and is not the interesting thing about it, and the ledger entry for `muse` now
says so. This is the limit of the approach stated honestly: **comparing bytes
tells you a file is not kit's, and nothing about whether it is any good.**

**`lint/*`, 3 diverged + 3 absent — and the brief's "0/9" needs correcting.**
Not one service is byte-identical, but **three do hold a linter config**:
`billing/.rubocop.yml`, `parlor/eslint.config.mjs`, `identity/.golangci.yml`.
All three are their own files, and none carries kit's **STRICTNESS NOTES** block
— the part of a kit config that records *what* it enforces and why. So the
honest sentence is **"nobody lints with kit's rules"**, not "nobody lints", and
the two are different findings with different fixes. The two
language-independent configs, `lint/yamllint.yml` and `lint/hadolint.yaml`, are
absent from all nine.

### What is absent — 32 cells, and this is the state that had no word

- **`bin/dev`: 8 of 9 absent.** The one adopter, `billing`, diverges by
  **+2 −358** — a *shorter* script than kit's, because it is the
  pre-observability-profile one. The copy is not wrong, it is **earlier**, and
  that is exactly what drift detection is for.
- **`compose`: 2 absent** (`caf` builds with the host toolchain; `parlor` runs
  its own Next.js dev server).
- **`docker/Dockerfile`: 1** (`caf`), **`ci.reusable.yml`: 1** (`pantry`).
- **All 18 `lint/yamllint.yml` and `lint/hadolint.yaml` cells absent.** Two
  configs that apply to *every* service regardless of language, adopted by none.

### What is unknown — 5 cells, all `pantry`

`pantry` calls no kit workflow, so it declares no language, so kit cannot resolve
the `{lang}` source for `bin/prime` or `docker/Dockerfile`, and cannot say
whether the three language-keyed linter configs apply at all. Each is a pin with
a real reason. The alternative — sniffing `Cargo.toml` — would have made `pantry`
report `rust` and graded a guess, which is the fail-open direction this reporter
is forbidden from taking.

---

## 7. What I could not verify

Stated here rather than in a footnote.

1. **The fleet is a moving target and this measurement is a snapshot.** Between
   two runs, `identity/.golangci.yml` appeared in the working tree. The reporter
   caught the ledger disagreeing with it (see §4), but the numbers in §6 are for
   `41f8bcb` and whatever was on disk at the time. Re-run before acting on them.
2. **The gate cannot check the fleet half, by construction.** kit's CI has no
   sibling checkouts, so the unpinned / dead / verb-mismatch rules are proven
   against a **fixture fleet** in `tests/staleness_test.sh`, not against the real
   one. Running the reporter against the real fleet is a manual, scheduled act.
   The gate checks the ledger's own consistency and the table against the tree —
   and says so rather than claiming a comparison it did not make.
3. **The 80 pins are a first pass, and the reasons are partly inferred.** I wrote
   them from the measurement. Where a divergence has a documented cause
   (`SERVICE_NAME`, README steps 4 and 5) the reason states that cause. Where it
   does not — the seven `bin/prime` copies, the eight `bin/dev` absences — the
   reason says **"nobody has recorded why"**, which is what I could verify. Those
   entries are a backlog with an owner and a date, not a set of decisions
   somebody made, and the `owner=` field is the repository name rather than a
   person, because I have no way to know who owns what and inventing a
   distribution list is what the tier allowlist's own rule 2 forbids. Every one
   expires 2026-12-31, and the gate reads the clock.
4. **I did not run the fleet's stacks, and my first sentence about them was
   wrong.** The first draft said a partially-adopted stack "cannot start". I
   checked it with `docker compose config` and it does not: five of the six
   services that have a compose file at all pass it, and none of the seven mounts
   any of kit's eleven files. The corrected claim is in §6, and the wrong one is
   quoted next to the correction rather than deleted. **The lesson is recorded
   because it generalises**: the reporter's `partially adopted` note had already
   learned the same lesson in code ("a stack missing members does not start" was
   cut from it for exactly this reason) and I wrote the sentence into the prose
   anyway. What the reporter measures is bytes; what it must not do is imply more
   than it measured.
5. **`compose` bundle membership is a judgement.** It follows `bin/dev`'s own
   copy list (six `cp` lines in its `not_found` message) plus every file
   `docker-compose.yml` mounts. Adding a thirteenth file to the stack means
   adding it to `artifacts.json`; nothing detects a file that became required and
   was not declared, because "which files does this compose file mount" is not
   checked.
6. **Not attempted, and deliberately: `templates/tier/` and
   `templates/otel/<lang>/`.** Both are **merged** into a service's own test tree
   or source tree rather than copied to a path, so there is no declared
   destination to compare. Adding them would have required a heuristic, and a
   heuristic is the thing this packet exists to refuse. They remain unwatched.
7. **`docs`, `cafaye-py`, `cafaye-rb` and `cafaye-ts` are excluded from the
   table above** as toolchain repositories rather than services. The reporter
   does not exclude them — it reports them too, and they are the bulk of the
   findings in an unscoped run. Scoping to the nine is a deliberate reading of
   "the fleet", and it is stated here because a reader comparing the two numbers
   would otherwise think one of them was wrong.
8. **The `carve-out boundary` check is new, and writing it found the rule it
   checks was out of date.** `AGENTS.md` has said "standard library only" since
   the carve-out was made and nothing verified it; the reporter has always
   imported `urllib` for GitHub-org discovery, and `AGENTS.md` never named it.
   The check now asserts both halves — the import list *and* the sentence — so
   they cannot drift apart again. That is the only change in this packet to a
   file that is not part of the templates story, and it is here because a rule I
   was relying on turned out to be unenforceable.
9. **A byte-comparison says nothing about whether a file is any good**, and §6
   has the demonstration: `muse/docker-compose.yml` does not parse and the
   reporter calls it `diverged`. The two gates that would catch it — yamllint
   and `hadolint` — run inside **kit**, over **kit's** files; nothing in the
   fleet runs them over a service's copies, which is a gap this packet does not
   close and should not pretend to.

---

## 8. Files

| file | |
| --- | --- |
| `tests/artifacts.json` | **new** — the twelve artefacts, their destinations, their languages, the `compose` bundle |
| `templates/parity-allowlist` | **new** — 80 pins, four hygiene rules, count printed on green |
| `tests/staleness.py` | `--scope templates`, five states, `--fail-on-unpinned`, `difflib` diff summaries |
| `tests/staleness_test.sh` | 12 → 26 cases |
| `tests/validate.sh` | three new named checks; the header/recipe check picks up 23–28 automatically |
| `tests/self_test.sh` | 23 → 29 breakages |
| `AGENTS.md` | the layout tree, the count of breakages, a new section on the reporter and the ledger, `difflib`/`glob` added to the allowed-import list and the sentence made enforceable |
| `README.md` | [what the fleet actually adopted](#what-the-fleet-actually-adopted) at the top, the templates half, the pin format |
| `CHANGELOG.md` | the entry, and the three corrections to the brief's numbers |
