# REPORT — kit-18-integrate

Five finished packets, one numbering scheme.

Base for the work: `master` at `d59b0a1` (kit-16's deploy reference and
kit-17's ruby floor, which had already taken 23 and 23b). Every packet branched
from the common ancestor `41f8bcb`, which carries 1–22 including `2b`.

## The mapping

Every breakage, old number → new number → which packet it came from → what it
asserts. Nothing was dropped, merged, or deduplicated.

| old | new | packet | asserts |
|---|---|---|---|
| 1 | 1 | tier | `templates/otel/go/traceparent.go` deleted → artifact-presence check red |
| 2 | 2 | fan-out | collector gains an exporter nobody read → privacy check red |
| 2b | 2b | fan-out | the collector ships **no** exporter for tempo → same check, other side |
| 3 | 3 | tier | python codec stops preserving trace-flags → that suite red |
| 4 | 4 | tier | compose hardcodes a published port → parameterization check red |
| 5 | 5 | telemetry | the telemetry CI job is no longer opt-in |
| 6 | 6 | telemetry | the `none` job is no longer gated on its own input |
| 7 | 7 | docs | README documents a `uses:` path that is not the reusable workflow |
| 8 | 8 | docs | the workflow no longer declares `on: workflow_call` |
| 9 | 9 | docs | a second copy of the reusable workflow, out of reach |
| 10 | 10 | docs | kit CI calls a remote ref instead of its own local copy |
| 11 | 11 | lint | a Dockerfile pins nothing (hadolint DL3013) |
| 12 | 12 | lint | a Dockerfile final stage runs as root |
| 13 | 13 | telemetry | go stops masking trace-flags (§3.2.2.5) |
| 14 | 14 | telemetry | ruby accepts uppercase hex (§3.2.2) |
| 15 | 15 | telemetry | elixir accepts trailing junk on version 00 (§3.2.2.2) |
| 16 | 16 | telemetry | node never truncates tracestate (§3.3.1.5) |
| 17 | 17 | telemetry | rust accepts an all-zero trace-id (§3.2.2.3) |
| 18 | 18 | telemetry | python stops masking trace-flags (§3.2.2.5) |
| 19 | 19 | tier | an allowlist entry that matches nothing |
| 20 | 20 | core | `includePaths` nested under `git:` (vendors everything, exits 0) |
| 21 | 21 | classifier | the classifier FAILS OPEN on an unrecognised change |
| 22 | 22 | staleness | the staleness reporter calls an undeclared pin `current` |
| **23** | **23** | **kit-17** | **the interpreter floor is defined but never consulted** — the floor guard deleted, a stub `ruby` reporting 2.6.10 on PATH |
| **23b** | **23b** | **kit-17** | **floor INTACT, same stub** — the gate stays **green** and names the skip |
| 23 | **24** | kit-15-fleet | D12 — the gate step is a `run:` block scalar, justified |
| 24 | **25** | kit-15-fleet | D12 — a *correct* step carrying a justification for a fixed defect |
| 25 | **26** | kit-15-fleet | D13 — a proof pattern carries escape tolerance |
| 23 | **27** | kit-12-lint | a language job's `lint` step deleted → the job no longer lints |
| 24 | **28** | kit-12-lint | the lint step is advisory (`continue-on-error`) — a report, not a gate |
| 24b | **28b** | kit-12-lint | the same defect written `\|\| true` in the run body |
| 25 | **29** | kit-12-lint | the kit checkout deleted, so `--config` names nothing |
| 26 | **30** | kit-12-lint | kit config silently drops correctness linters the policy names |
| 27 | **31** | kit-12-lint | a service carries a lint config INCONSISTENT with kit's |
| 27b | **31b** | kit-12-lint | *(green control, not counted)* a service config that MATCHES kit is not a failure |
| 28 | **32** | kit-12-lint | one lint job no longer guards the `lint-args` seam |
| 28b | **32b** | kit-12-lint | the guard is kept and its refused-flag list is shortened by one token |
| 28c | **32c** | kit-12-lint | the seam guard runs AFTER the linter it guards |
| 23 | **33** | kit-14-stale | a parity-allowlist entry naming an artefact kit does not ship |
| 24 | **34** | kit-14-stale | an EXPIRED parity-allowlist entry — the gate reads the clock |
| 25 | **35** | kit-14-stale | `tests/artifacts.json` naming a `{lang}` source kit does not ship |
| 26 | **36** | kit-14-stale | the reporter calls an ABSENT artefact `current` |
| 27 | **37** | kit-14-stale | the reporter grades a copy by resemblance, not equality |
| 28 | **38** | kit-14-stale | one of the two programs gains a third-party import |
| 29 | **39** | kit-14-stale | a fixture service's `.git` removed — asserts the *explanation*, not the exit status |
| 30 | **40** | kit-14-stale | the ruby toolchain floor is defined but never consulted (see the note below) |
| 24 | **41** | kit-08-merge | a credential in history, since removed |
| 25 | **42** | kit-08-merge | a credential in the working tree |
| 26 | **43** | kit-08-merge | the scan stops redacting |
| 27 | **44** | kit-08-merge | the scan narrows to the last commit |
| 28 | **45** | kit-08-merge | a dangerous trigger (`pull_request_target`) appears in the workflow |
| 29 | **46** | kit-08-merge | the secret scanner is made non-blocking |
| 30 | **47** | kit-08-merge | the reference type hides its credential in an unexported field |
| 31 | **48** | kit-08-merge | the credential type stops redacting when printed |
| 32 | **49** | kit-08-merge | the reference type marshals its credential |
| 33 | **50** | kit-08-merge | the canary is committed as a literal |
| 34 | **51** | kit-08-merge | the zizmor config baselines `unpinned-uses` |
| 23 | **52** | kit-13-observe | a service carries its own copy of the shared stack |
| 24 | **53** | kit-13-observe | a service re-points the collector's config mount |
| 25 | **54** | kit-13-observe | an `otel-collector.yml` that no compose file ever mounts |
| 26 | **55** | kit-13-observe | a service pins a BRANCH rather than a ref |
| 27 | **56** | kit-13-observe | a vendor config mount stopped resolving from the fetched tree |
| 28 | **57** | kit-13-observe | the pin is back in `.env`, where nothing reads it |
| 29 | **58** | kit-13-observe | a service publishes a port on a service kit already ships |
| 30 | **59** | kit-13-observe | an UNADOPTED service copies the stack — the gate stays **green** and names the debt |
| 31 | **60** | kit-13-observe | the same copy in an ADOPTING service is a hard FAIL |

**Totals: 65 breakage recipes.** 63 assert red, 2 assert a green gate while
naming what it said (23b names a SKIP, 59 names a FINDING), and kit-12's 31b is
a green *control* that is deliberately outside all three counts.

### Numbers that were already on master and did not move

`1`–`22`, `2b`, `23`, `23b`. `23` and `23b` are kit-17's, and they are why
every packet had to start at 24 rather than 23.

### Nothing was dropped

Two pairs test the same defect and both are kept:

- **23 and 40** both delete the ruby floor guard. They are two recipes over one
  line, differing in how the old interpreter is simulated: 23 plants a stub
  `ruby` script that reports 2.6.10 and refuses the suite; 40 plants a preload
  that `undef_method`s `Array#filter_map`. Both are real proofs, and the
  different fixtures are the reason they are not literally the same test.
- **59 and 60** are kit-13's own design: the two sides of an adoption ceiling,
  where 60 is the fixture of 52 plus one committed line.

Collapsing either pair is a manager's call, not this merge's.

## Merge order and why

One at a time, each committed before the next, cheapest first so the shape of
the conflict was learned on the smallest one:

```
kit-15-fleet → kit-12-lint → kit-14-stale → kit-08-merge → kit-13-observe
```

Each incoming packet's breakages were given fresh numbers **above everything
already in the tree at that moment**, which is why the blocks are contiguous
and in merge order rather than interleaved: 24–26, 27–32c, 33–40, 41–51, 52–60.

## Every place a number appears, and how it was verified

A number changed in some places and not others is a gate that is green and
lying, so the move was verified mechanically rather than by reading.

**1. The header/recipe check, which is the one that cannot be fooled.** It
compares the SET of numbers the header block documents against the SET the
recipes carry. I re-implemented it and ran it after every merge:

```
$ python3 - <<'PY'   # the same comparison tests/validate.sh makes
...
$ named 65 carried 65     header-only: []   recipe-only: []
```

Zero disagreement at 1, 26, 37, 45, 56 and 65 breakages. This is the check
that caught my own mistakes three times (below).

**2. Duplicate labels**, which a set comparison hides:

```
$ grep -oE "^ *expect_(red(_check|_lang|_script)?|skip_check|green_check) +.breakage +[0-9]+[a-z]*" \
    tests/self_test.sh | grep -oE "[0-9]+[a-z]*$" | sort | uniq -d
(no output)
```

**3. The greps I ran for each moved number, across the whole tree:**

```sh
grep -rnE "breakage (2[3-9]|3[0-4])\b|breakages (2[3-9]|3[0-4])\b" AGENTS.md README.md CHANGELOG.md tests/
grep -rnE "breakage (2[4-9]|3[0-4])\b" AGENTS.md README.md templates/AGENTS.md tests/*.sh tests/*.py
grep -rn "27b\|23-25\|23-28c\|52-26\|41-34" AGENTS.md README.md CHANGELOG.md tests/
grep -rnE "copies/\$name|fresh_fleet|fixture_fleet|expect_skip_check|expect_green_check" tests/
```

**4. Places a number lives, all of which were updated:**

| where | what had to move |
|---|---|
| `tests/self_test.sh` header block | the `# N.` / `# N-M.` prose entries, including sub-entries |
| `tests/self_test.sh` labels | the `'breakage N: …'` string on every helper call |
| `tests/self_test.sh` variables | `twentythree`→`fiftytwo`, `twentythree_fixture`→`fiftytwo_fixture`, … |
| `tests/self_test.sh` tail | the counted summary line and its own comment |
| `tests/validate.sh` | `_st_breakages` / `_st_reds` patterns, the summary label, and every prose reference |
| `AGENTS.md` | the `self_test` phase bullet, the gate-tree diagram, the "before you commit" list |
| `README.md` | the gate table, the `self_test` paragraph, the adoption table |
| `CHANGELOG.md` | each packet's entry, including counts that are **not** breakage numbers |
| `tests/fleet_check.py` | a prose reference to kit-13's 30/31 → 59/60 |
| `templates/AGENTS.md` | kit-13 changed the count there; it is in the tree and was checked |

**5. Two audits that caught what shellcheck could not.** `shellcheck -S
warning` passes, but it cannot see `set -u` and it cannot see a *renamed*
variable that is still assigned. I wrote two checks:

```sh
# every $var used by a recipe is assigned BEFORE that recipe runs
#   -> found three collisions the renumber created (see below)

# a variable called `twentyseven` may only be used by breakage 27
#   -> found `thirtytwo` used by both 28 and 32, and `twentyeight_b` by both 28b and 32b
```

## Anything found that was not a numbering problem

### 1. Breakage 31b was red for a reason another test created — FIXED

kit-15 exported `KIT_FLEET` once, at the top of `self_test.sh`, and never put
it back. Its last recipe leaves a **deliberately broken** repository in
`$FLEET` (that is the mechanism — a sweep that cannot go red proves nothing),
so every `validate.sh` run after it inherited that repository. kit-12's
breakage 31b asserts the gate is **green** on a copy whose config matches kit's;
it failed with `FAIL adopting repositories (no workaround for a fixed core
defect)` — a red manufactured by another recipe.

The export now lives inside `fresh_fleet`, so its scope is exactly the one
recipe that needs it, and it is `unset` after the last one. This is the exact
failure mode the harness documents for itself, reached from a different
direction.

### 2. `fresh_copy` did not copy `.gitleaks.toml` — FIXED

kit-08 added a root-level `.gitleaks.toml` that its check reads **by path and
refuses to run without**. `fresh_copy`'s copy list predates it, so every
breakage's copy was missing it and three checks went red at once — all three
reporting the missing file, none reporting anything about the tree. The
control read `FAIL self_test: unbroken tree — the gate is RED on an unbroken
tree`.

It is now in the list, and the comment there says what the list is for: the set
of paths the gate *reads*, which must be re-extended whenever a packet adds a
check that reads a new one.

### 3. The gitleaks allowlist path was repo-relative — FIXED

`.gitleaks.toml`'s entry for kit-16's JWT canary was anchored
`^tests/deploy_test\.sh$`. A **history** scan reports paths relative to the
repository root; the `--no-git` **directory** scan that `gitleaks_gate.sh`
selects for a throwaway copy — which is the mode every one of `self_test.sh`'s
copies uses — reports the **absolute** path. The entry matched one and not the
other, so the copy's scan exited 1.

Both forms are matched now. Measured in both directions rather than reasoned
about:

```
git mode      before: leaks found: 1    after: no leaks found
--no-git mode before: leaks found: 1    after: no leaks found
scoping       a jwt in a second file is still reported (1 leak, not 0)
```

### 4. Breakage 40's `edit` anchor had moved — FIXED

kit-14's recipe deleted
`if [ "$lang" = ruby ] && ! toolchain_floor_ruby; then`. kit-17 replaced that
one-liner with a block form that distinguishes SKIP from FAIL and reads
`RUBY_FLOOR` from the template. `edit` failed closed with "breakage no longer
applies", which is the harness working: the recipe had silently stopped testing
anything. It now edits the block's guard, so the mutation is still the
well-intentioned edit it was meant to be. (kit-14 had already been re-pointed
once for the same reason; this is the second time.)

### 5. Three variable collisions the renumber created — FIXED

A cascading rename collided mid-way and `shellcheck` plus a use-before-assign
audit found all three: `thirtytwo` was used by both breakage 28 and 32,
`twentyeight_b` by both 28b and 32b, and `thirtyone` was referenced by 27
before it was assigned. Every recipe now names its own breakage.

### 6. Counts in prose that were already wrong before I touched them

- **The "which check went red" count was stale on master.** The header said
  "Eight of them (7-10, 11, 12, 19, 20)". The true figure on master was
  already larger, and on the merged tree it is **45** (`expect_red_check`).
  Recounted from the recipes rather than translated from any packet.
- **kit-13's changelog said "Seven breakages (23–29)"** for a block of nine.
  Restated as "Nine breakages (52–60), eight asserting the NAMED check and one
  asserting the gate stays green while naming its finding."
- **A blanket renumber touched two numbers that are not breakage numbers.**
  kit-08's changelog says a textual union "carries **34 recipes**" and that
  `validate.sh` has "45 check sites on master, **34** on kit-04". The same pass
  rewrote those to 51. Both are restated as written. This is the specific
  hazard a mechanical renumber has, and it is why the report above was built
  from the recipes rather than from a diff.
- **kit-12's `27b` is a green control, not a breakage.** Its label carries a
  number but it is an `expect_green`, so it is outside all three counts and
  outside the header's numbered entries — that is kit-12's deliberate design
  and it is preserved exactly. It is now 31b.

### 7. Two structural things I checked rather than assumed

- **`fresh_copy` vs `fresh_fleet` vs `fixture_fleet`.** All three survive.
  `fresh_copy` still gives every copy **its own parent directory** — the tree
  uses kit-12's `$WORK/<name>/kit`, kit-13 chose `$WORK/copies/<name>`, and both
  achieve the same thing, so the shorter form stayed and kit-13's explanation of
  why it is load-bearing came with it. kit-15's `fresh_fleet` rebuilds a
  synthetic fleet; kit-13's `fixture_fleet` builds a throwaway one with a `.git`
  per service. `KIT_FLEET` is exported per-recipe and `unset` at the end.
- **kit-17's `expect_skip_check` is intact and its count is honest.** There are
  now **two** green-asserting proofs, not one: 23b names a SKIP and 59 names a
  FINDING. Both `self_test.sh`'s summary and `validate.sh`'s label count them
  apart rather than collapsing them into "not red". Nothing was converted from
  green to red to make a count tidier.

## What I did not do

- **I did not collapse any two breakages**, including the two pairs that test
  the same defect (23/40, 59/60). Both of each are kept and both are documented
  above.
- **I did not fix the fleet.** `bash tests/validate.sh` reports
  `FAIL adopting repositories (no workaround for a fixed core defect)` because
  two real repositories — `parlor/.github/workflows/ci.yml` and one
  `gate.yml` — still carry the D12 workaround that kit-15 retired. This is
  **pre-existing and outside this repository**: it reproduces identically on
  `worker/kit-15-fleet` with its own commits and nothing of mine applied
  (verified by running the gate there). kit-15's own CHANGELOG records it as
  the check working. Fixing it means editing a cafaye service, which this
  packet does not own.
- **I did not touch any other repository or worktree.** I read
  `worker/kit-15-fleet`'s gate output to establish that the fleet red is
  pre-existing, and ran one command in its worktree for that purpose. Nothing
  was written there.
- **I did not change any assertion, threshold, or retry count.** The only
  behavioural changes are the three fixes above, each of which makes a check
  *more* honest. kit-13's `bounded_check` (5400s) around the self-test phase is
  kit-13's own mechanism and was kept: a tier that hits its bound is reported
  as a BOUND, which is neither a pass nor a skip, so it cannot buy a green.
- **I did not fix kit-13's stale recipes or docs beyond the renumbering** —
  e.g. its changelog still describes its own era in kit-13's numbers where that
  is a historical record, and its `REPORT-kit-13.md` is unmodified.
- **I did not resolve the `collectors` fleet reds in `self_test`'s copies**,
  which is kit-13's own reported state.

## The gate

Both run on this branch, on `worker/kit-18-integrate`.

```
$ export PATH="$HOME/.local/share/mise/shims:$PATH"
$ ruby -v
ruby 4.0.1 (2026-01-13 revision e04267a14b) +PRISM [arm64-darwin23]

$ bash tests/self_test.sh
...
PASS: self_test — all 65 breakages hold (63 assert red, 1 assert a green gate
with a named skip, 1 assert a green gate with a named finding), and the
unbroken tree is green.
exit 0

$ bash tests/validate.sh
exit 1  — one check fails: `adopting repositories (no workaround for a fixed
          core defect)`, for the reason given above (the real fleet).
          Every other check passed.
```

**On the interpreter.** Both runs used the mise shim's **ruby 4.0.1**, not
`/usr/bin/ruby` 2.6.10. The mise shims come first on `PATH` via
`export PATH="$HOME/.local/share/mise/shims:$PATH"`, so the ruby template runs
on a conforming interpreter and the kit-17 floor SKIP does not fire. The two
breakages that exercise the floor (23 and 23b) do not depend on this: they
plant their own stub `ruby` on `PATH` and are the reason both directions of the
floor are proved on any interpreter.

**`validate.sh` does not exit 0, and I am not claiming that it does.** It exits
1 on a red that belongs to the fleet, not to this tree, and that was true of
kit-15's own branch before I touched it. `self_test.sh` — the gate the brief
calls the one that matters most, and the one that asserts every documented
breakage has a recipe and every recipe is documented — **exits 0**.
