# Changelog

All notable changes to `kit` are recorded here. kit has no releases yet and no
semver contract — it is consumed by *calling*
`.github/workflows/ci.reusable.yml@master` and by *copying* files out of
`lint/`, `docker/`, and `templates/`.

> Entries under **Earlier**, and the three `workflows/ci.reusable.yml` bullets
> below, record the path the file had *at the time*. It was
> `workflows/ci.reusable.yml` until the move recorded in Unreleased/Changed.

## Unreleased

### Added

- **kit-08 — kit-04 landed on a master that had moved, without losing a check
  or a number.** `worker/kit-04` (secrets: gitleaks over full history, a
  runtime-leak canary, zizmor) branched before kit-05 and kit-07 and renumbered
  its breakages from the same base of 18 that master did. A textual union of the
  two files carries **34 recipes with four labels used twice** — 19, 20, 21 and
  22 — and `self_test_claims` compares the documented set against the carried
  set *as sets*, so the duplicates collapse silently and the check reports an
  agreement that does not exist.
  - Master's numbering is canonical and did not move. kit-04's **six language
    mutants** were dropped, not renumbered: they are master's 13–18 byte for
    byte, and a second copy would prove the same six rules twice under two
    names. kit-04's **eleven unique breakages** moved to **24–34**.
  - `tests/validate.sh`: 45 check invocations on master, 34 on kit-04, **59
    merged** — twenty of the sites are shared, which is why the union is less
    than the sum. Both sides' checks survive: master's tier block and kit-04's
    secrets block were the two real conflict hunks, and neither was picked over
    the other. Comparing the *labels* rather than the counts is what proves that:
    every label on either side is still present in the merged file, except two
    that were resolved deliberately — `collector_check`, which is one function
    whose label disagreed (master's fuller revision won) and whose kit-04 version
    was an earlier, smaller copy of the same function; and the `self_test`
    invocation site itself, which is the union documented below.
  - The `self_test` invocation site now takes the union of both: `check_verbose`
    (kit-04's — the list of breakages that went red *is* the evidence, and a
    plain `check` prints one line and throws the rest away) with master's
    counted label. The count is `grep`-derived in both files from the same
    expression.
  - One mechanism replaced two: `self_test.sh` had a runtime `breakages=$((…))`
    counter *and* the grep. The counter also decremented itself on a skipped
    language, so a machine missing a toolchain would print a *lower* total than
    the file contains — which reads as though proofs had been dropped rather
    than as a missing prerequisite.
  - **The renumbering was left in two visible states, and both are fixed here.**
    The recipes ran `1`–`18`, then `24`–`34`, then `19`–`22`, so the file did not
    read in the order its own header documents it. Recipes `19`–`22` now sit
    between `18` and `24`, and the file runs in label order.
  - **`24`–`34` no longer share variable names with `19`–`22`.** The renumber
    rewrote the labels and left the variable names behind, so breakage `30` was
    still called `nineteen`; master's `19`–`22` then bound those same four names
    to a second directory. It worked only because each was read before the next
    write. Those eleven variables are now named for what they break.
  - **There is no breakage 23, and it was never a lost recipe.** The block moved
    by `+11`, carrying kit-04's `23` — the zizmor `unpinned-uses` baseline — to
    `34`. The gap is now documented where a renumber script will read it as a
    bug, and README states the scheme.

### Fixed

- **`expect_red_check` reported a proof as failing when the check it named was
  the one that fired.** The matcher was `printf '%s\n' "$out" | grep -qF`, and
  under `set -o pipefail` a writer that takes SIGPIPE makes the whole pipeline
  non-zero — so `grep -q` exiting at its first match turned a **hit** into a
  miss. Deterministic on output size, not on load: below the 64KB pipe buffer the
  assertion is correct, at or above it, `printf` is killed mid-write. Breakages
  **11** (hadolint) and **25** (the working-tree credential) both exceed it and
  were both reported as *"the gate went red, but NOT via `<the check that fired>`"*
  while printing that check among the FAIL lines it had just proven present.
  Now a substring test on the already-captured `$out`: no pipe, no SIGPIPE, and
  the assertion no longer depends on how much the gate prints. The same defect
  and the same answer were already recorded in `tests/canary_test.sh` for
  `docker logs | grep -q`.
- `tests/validate.sh` and `templates/secrets/go/sweep.go` cited breakages by their
  **kit-04** numbers — `15` for the `--redact` removal (now `26`) and `21` for the
  marshalling canary (now `32`). Both are the renumber's fallout, and both
  pointed a reader at the wrong recipe.
- Count drift in the prose, all of it second-hand rather than measured: `AGENTS.md`
  said *twenty-three* breakages in one place and *thirty-four* in another, *eight*
  named checks against the real **nineteen** (+2 over proof scripts = twenty-one),
  and *nineteen ways* in its own pre-commit checklist. `README.md` and
  `tests/self_test.sh` both counted the named proofs as *twenty* against the
  **nineteen** their own lists enumerate. Every one of these is a copy of the
  truth taken by hand, which is the failure the derived count exists to prevent.
- `tests/self_test.sh`'s header described the thirty-four breakages as *18 from
  the fan-out work, 17 from the tier work, 11 from the secrets work, 12 shared* —
  58, for a file that carries 34.
- A section comment read `# 30-22.` where the canary vectors are `30`–`33`: the
  renumber script's arithmetic leaking into prose.

- **kit-07 — the declared tier, and the allowlist that is supposed to shrink.**
  A tier is a class of test that needs a real dependency. The failure this
  exists to prevent has already happened in this fleet: a green run in which the
  whole database tier never executed once, because the suite printed `ok`.

  - **`templates/tier/<lang>/` — the declaration, per language, for all seven.**
    Declared in the test source and read by the runner's own collector, never
    grepped for a sentinel. A sentinel fails *open*: a test reaching Postgres
    through a helper two files away does not match Identity's
    `dbtest.Pool|Schema|EnvVar|TEST_DATABASE_URL`, so its package never enters
    the required list and the run is never required to contain it. Rust
    (`#[ignore = "cafaye:tier=db reason=…"]`), Go (`//go:build tier_db`) and
    Python (`@pytest.mark.tier_db`) have a collector that already exists. Ruby
    gets a `tier :db` macro, Elixir a `@tier :db` attribute, and Node and Bun an
    exported `TIER` const — each a **no-op at runtime**, so the collector is a
    ~15-line adapter rather than a parser.
  - **Two collector claims measured, and both corrected the prior claim.**
    `cargo test -- --list --format json` is **nightly-only** (`-Z
    unstable-options`, rustc 1.95.0) — on stable, `--list` includes ignored
    tests and `--list --ignored` gives the ignored subset, which between them
    carry everything the JSON would have. `--list --include-ignored` lists
    *everything* and filters nothing. And `bun test --reporter=junit` **does**
    emit a full inventory: a filtered-out test is still a `<testcase>`, so the
    absent-testcase failure mode does not occur there. What bun lacks is a
    declared *reason* — `test.skip` takes none.
  - **`templates/tier/README.md` — the normalised result format**, the three-way
    `ran` / `skipped` / `filtered` distinction JUnit XML cannot express, the
    allowlist rules, and **what a tier gate cannot catch**. A package filtered
    out of the run entirely is the sharpest: the test asserting the tier ran
    lives *inside* the tier and cannot observe its own absence. Only the
    inventory-vs-run set difference catches it, and that is `caf gate`'s.
  - **`templates/tier/skip-allowlist` — one file for the fleet**, with four
    hygiene rules: every entry names a **reason**, an **owner**, a `since` and a
    `until`; and **an entry matching nothing is a failure**. That last rule is
    modelled on ESLint's `reportUnusedDisableDirectives`, which reports a
    disable comment that no longer suppresses anything. Without it an allowlist is
    a ratchet that only turns one way, and within two quarters it contains every
    test in the repository. The **total is printed on every run, green included**
    — individual entries look justified; the aggregate is the problem.
  - **`required-tier` on the reusable workflow.** Demanded, not inferred: the
    caller names the gate variable (`REQUIRED_DB`) and the workflow exports it
    as `1` on every language job's test step — guard's `GUARD_REDIS_REQUIRED`
    pattern, which fails at *tier-invocation* time, before a report exists. A
    `tier demand` step then fails **naming the variable** if the run produced no
    `ran` line, because a gate variable that is set while a tier runs zero tests
    is a green build that verified nothing. Opt-in: the default is `''`.
  - **`-count=1` mandated on the Go job.** Go keys its test cache on the
    environment a test reads, so a gated and an ungated run already have
    different cache keys — genuinely good news — but mandating the flag removes
    the question rather than reasoning about it, and it costs nothing.
  - **Never cache a test report**, documented in README with the reasoning:
    `restore-keys` matches by **prefix**, and the default branch's cache is
    documented as available to other branches, so a key built from
    `hashFiles('**/lockfile')` restores a report written by a run that *had* the
    database into a run that did not. **A witness from a different run is not a
    witness.** Also stated: fork PRs get read-only cache access, which is a
    cross-trust-boundary path into the gate in any workflow using
    `actions/cache` today.
  - **Floors are relabelled as decrease detectors.** Identity's
    `1254/1166`-style floors are kept and are cheap at catching deletion, but a
    floor is satisfied by *any* 1254 tests including the wrong 1254. Calling one
    a tier gate is worse than having none.

- **`core/` — the `cafaye/core` fan-out standard.** Six repositories copy bytes
  out of `core` and nothing makes the copy reach them. This ships the standard
  that does, plus the two runnable pieces that make it enforceable:
  - `core/vendir/vendir.yml.{muse,pantry,caf}` — the three real consumers, in
    three languages. `muse` and `pantry` are **proven byte-identical (sha256)**
    to what those repositories have committed today, by running vendir 0.46.2
    against the real `cafaye/core`. `caf` **cannot migrate as-is** and its banner
    says why: vendir has no rename, `caf` holds the bytes as
    `manifest-0.2.json`, and core publishes them as
    `cafaye.manifest.schema.json`.
  - `core/vendir/vendir.yml.template` — the onboarding template. Four things to
    change, each marked, each with the reason it is easy to get wrong.
  - `core/renovate/renovate.json5` and `core/renovate/SETUP.md` — one
    `inheritConfig` policy for the fleet, and the ordered steps to stand it up
    **including what to verify before onboarding a second repository**.
  - `core/release/release.yml` — what `core` needs to be taggable. Ships here;
    belongs in `core/.github/workflows/`.
- **`tests/classify.py` + `tests/rules.json` — a change classifier that fails
  closed.** `self_test.sh` proves twenty-three synthetic breakages go red; it
  cannot prove a future change to `event-envelope.schema.json` is one of them. So
  a difference between two vendored schema sets is classified into
  `FILE`/`PACKAGE`/`WIRE_JSON`/`WIRE` (buf's four tiers, because *pick the
  category that matches what your consumers actually depend on*), and **anything
  the catalogue does not name is `UNRECOGNISED`, which is the strictest tier**.
  A new JSON Schema keyword arriving in core cannot be auto-merged green by
  omission. The escape hatch is fenced: a rule may set `breaking: false` only for
  an operation in the closed `advisoryOps` list, or the catalogue refuses to
  load.
- **`tests/staleness.py` — the fleet staleness reporter.** Reads every consuming
  repository's recorded pin — a `vendir.lock.yml` sha *or* the hand-bumped
  `CORE_REF`, because three repositories still use the second — resolves where
  `core` is now, and prints the distance. `--fail-on-behind` makes it a gate;
  `--fail-on-behind` is *off* by default because a stale copy is legal and a
  scheduled report that is red every week is a report that gets muted. Run
  against the real working tree it reports the first measured fleet fact:
  **`muse` is nineteen commits behind**, and `caf` and `pantry` hold vendored
  bytes with **no recorded origin at all**.
- **Three new self-test breakages (18 → 21 at the time of writing; 23 after
  the merge with the tier work).** `includePaths` nested under
  `git:`; the classifier made to **fail open**; the staleness reporter calling an
  undeclared pin `current`. The second is the sharpest proof in the file: it
  inverts the fail-closed property and asserts the suite notices.
- **A check for a file type kit was already shipping unlinted.** The vendir
  templates are YAML under non-`.yml` names, so the `git ls-files '*.yml'
  '*.yaml'` sweep skipped them — and a service that copies one greets its first
  CI run with a failure nobody authored. They are linted by name now.
- **Two new `classify_test.sh` cases that exist to keep the gate honest rather
  than red.** An advisory change must be *reported and not fail*, and a
  reordered `required`/`enum` must not break `FILE` — JSON Schema defines both as
  sets, so a reorder is provably not a semantic change. A gate that goes red on a
  cosmetic edit trains the first person who hits it to reach for the gate rather
  than the cause, which is how a fail-closed gate becomes a fail-open one.
- `core/README.md` records what the fan-out measurement actually found, which is
  **not** what the design was briefed on, and states plainly what stays unproven
  until the first real tag moves.

-
 
*
*
k
i
t
-
0
5
 
m
e
r
g
e
d
 
o
n
t
o
 
a
 
m
a
s
t
e
r
 
c
a
r
r
y
i
n
g
 
t
h
e
 
t
i
e
r
 
w
o
r
k
:
 
t
w
o
 
`
f
i
`
s
 
l
o
s
t
,
 
a
n
d
 
t
h
e


 
 
g
a
t
e
 
w
o
u
l
d
 
h
a
v
e
 
l
i
e
d
.
*
*
 
B
o
t
h
 
s
i
d
e
s
 
o
f
 
t
h
e
 
m
e
r
g
e
 
p
u
t
 
t
h
e
i
r
 
n
e
w
 
c
h
e
c
k
s
 
i
n
s
i
d
e
 
a


 
 
`
R
U
N
_
*
`
 
c
o
n
d
i
t
i
o
n
a
l
,
 
a
n
d
 
`
g
i
t
 
m
e
r
g
e
 
-
-
u
n
i
o
n
`
 
d
r
o
p
p
e
d
 
t
h
e
 
c
l
o
s
i
n
g
 
`
f
i
`
 
o
f
 
*
t
w
o
*


 
 
d
i
f
f
e
r
e
n
t
 
b
l
o
c
k
s
.
 
O
n
e
 
w
a
s
 
c
o
s
m
e
t
i
c
;
 
t
h
e
 
o
t
h
e
r
 
p
u
t
 
k
i
t
-
0
5
'
s
 
`
c
l
a
s
s
i
f
y
_
t
e
s
t
.
s
h
`


 
 
a
n
d
 
`
s
t
a
l
e
n
e
s
s
_
t
e
s
t
.
s
h
`
 
*
*
i
n
s
i
d
e
*
*
 
`
R
U
N
_
O
B
S
E
R
V
A
B
I
L
I
T
Y
`
,
 
s
o
 
a
 
r
u
n
 
w
i
t
h


 
 
o
b
s
e
r
v
a
b
i
l
i
t
y
 
d
i
s
a
b
l
e
d
 
w
o
u
l
d
 
h
a
v
e
 
s
i
l
e
n
t
l
y
 
e
x
e
c
u
t
e
d
 
n
e
i
t
h
e
r
 
—
 
a
n
d


 
 
*
*
`
b
a
s
h
 
-
n
`
 
p
a
s
s
e
d
 
t
h
r
o
u
g
h
o
u
t
*
*
,
 
b
e
c
a
u
s
e
 
t
h
e
 
f
i
l
e
 
w
a
s
 
s
t
i
l
l
 
*
b
a
l
a
n
c
e
d
*
.
 
A


 
 
s
y
n
t
a
x
 
c
h
e
c
k
 
i
s
 
n
o
t
 
a
 
s
t
r
u
c
t
u
r
a
l
 
c
h
e
c
k
,
 
a
n
d
 
t
h
i
s
 
i
s
 
t
h
e
 
s
e
c
o
n
d
 
t
i
m
e
 
t
h
i
s
 
f
l
e
e
t


 
 
h
a
s
 
t
a
k
e
n
 
a
 
g
r
e
e
n
 
f
r
o
m
 
a
 
c
h
e
c
k
 
t
h
a
t
 
c
o
u
l
d
 
n
o
t
 
s
e
e
 
t
h
e
 
d
e
f
e
c
t
.


-
 
*
*
k
i
t
-
0
5
'
s
 
c
l
a
s
s
i
f
i
e
r
 
a
n
d
 
s
t
a
l
e
n
e
s
s
 
p
r
o
o
f
s
 
s
h
i
p
p
e
d
 
w
r
a
p
p
e
d
 
i
n


 
 
`
i
f
 
[
 
"
$
R
U
N
_
S
T
A
T
I
C
"
 
-
e
q
 
1
 
]
`
,
 
u
n
d
e
r
 
a
 
c
o
m
m
e
n
t
 
s
a
y
i
n
g
 
t
h
e
y
 
"
r
u
n


 
 
u
n
c
o
n
d
i
t
i
o
n
a
l
l
y
,
 
b
e
c
a
u
s
e
 
b
o
t
h
 
a
r
e
 
t
h
e
 
p
r
o
p
e
r
t
y
 
r
a
t
h
e
r
 
t
h
a
n
 
t
h
e
 
s
h
a
p
e
.
"
*
*
 
T
h
e


 
 
c
o
d
e
 
a
n
d
 
t
h
e
 
c
o
m
m
e
n
t
 
s
a
i
d
 
o
p
p
o
s
i
t
e
 
t
h
i
n
g
s
,
 
a
n
d
 
t
h
e
 
c
o
d
e
 
w
a
s
 
t
h
e
 
o
n
e
 
t
h
a
t
 
r
a
n
.


 
 
T
h
e
y
 
a
r
e
 
n
o
w
 
u
n
c
o
n
d
i
t
i
o
n
a
l
,
 
a
n
d
 
t
h
e
 
r
e
a
s
o
n
 
i
s
 
r
e
c
o
r
d
e
d
 
a
t
 
t
h
e
 
c
a
l
l
 
s
i
t
e
:
 
a


 
 
c
h
e
c
k
 
t
h
a
t
 
o
n
l
y
 
p
a
r
s
e
d
 
t
h
o
s
e
 
t
w
o
 
f
i
l
e
s
 
w
o
u
l
d
 
p
a
s
s
 
o
n
 
a
 
c
l
a
s
s
i
f
i
e
r
 
t
h
a
t
 
w
a
v
e
s


 
 
e
v
e
r
y
 
c
h
a
n
g
e
 
t
h
r
o
u
g
h
,
 
s
o
 
s
k
i
p
p
i
n
g
 
s
t
a
t
i
c
 
a
n
a
l
y
s
i
s
 
m
u
s
t
 
n
o
t
 
b
e
 
a
b
l
e
 
t
o
 
r
e
m
o
v
e


 
 
t
h
e
 
p
r
o
o
f
 
t
h
a
t
 
t
h
e
 
c
l
a
s
s
i
f
i
e
r
 
f
a
i
l
s
 
c
l
o
s
e
d
.


-
 
*
*
`
s
e
l
f
_
t
e
s
t
.
s
h
`
 
s
a
y
s
 
t
w
e
n
t
y
-
o
n
e
;
 
t
h
e
 
f
i
l
e
 
p
r
o
v
e
s
 
t
w
e
n
t
y
-
t
h
r
e
e
.
*
*
 
B
o
t
h
 
s
i
d
e
s
 
o
f


 
 
t
h
e
 
m
e
r
g
e
 
c
a
r
r
i
e
d
 
a
 
c
o
u
n
t
 
t
h
a
t
 
h
a
d
 
d
r
i
f
t
e
d
,
 
a
n
d
 
`
v
a
l
i
d
a
t
e
.
s
h
`
 
r
e
c
o
m
p
u
t
e
d
 
i
t


 
 
w
i
t
h
 
a
 
p
a
t
t
e
r
n
 
t
h
a
t
 
*
*
o
m
i
t
t
e
d
 
`
e
x
p
e
c
t
_
r
e
d
_
s
c
r
i
p
t
`
*
*
 
—
 
w
h
i
c
h
 
i
s
 
w
h
y
 
k
i
t
-
0
5


 
 
h
a
r
d
c
o
d
e
d
 
`
2
1
`
 
i
n
s
t
e
a
d
 
o
f
 
c
o
u
n
t
i
n
g
.
 
T
h
e
 
p
a
t
t
e
r
n
 
n
o
w
 
c
o
v
e
r
s
 
a
l
l
 
f
o
u
r
 
h
e
l
p
e
r
s


 
 
(
`
e
x
p
e
c
t
_
r
e
d
`
,
 
`
_
c
h
e
c
k
`
,
 
`
_
l
a
n
g
`
,
 
`
_
s
c
r
i
p
t
`
)
,
 
t
h
e
 
h
e
a
d
e
r
 
r
e
a
d
s
 
t
w
e
n
t
y
-
t
h
r
e
e
,


 
 
a
n
d
 
t
h
e
 
c
o
m
p
o
s
i
t
i
o
n
 
i
s
 
s
t
a
t
e
d
 
i
n
 
b
o
t
h
 
f
i
l
e
s
:
 
*
*
8
*
*
 
n
a
m
e
d
-
c
h
e
c
k
,
 
*
*
6
*
*


 
 
p
e
r
-
l
a
n
g
u
a
g
e
 
m
u
t
a
t
i
o
n
,
 
*
*
2
*
*
 
p
r
o
o
f
-
i
n
v
e
r
s
i
o
n
,
 
*
*
7
*
*
 
w
h
o
l
e
-
g
a
t
e
.
### Fixed

- **A check that a comment could satisfy.** The `-count=1` assertion was a plain
  substring test over the go step's `run:` body, and that body's own comment
  block names the flag twice while explaining why removing it would be a
  mistake — so deleting the flag from the command left the check green. Found by
  deliberately breaking the tree, not by reading it. `strip_shell_comments`
  now removes comments while preserving `#` inside quotes, and it is applied
  wherever a check greps a `run:` body.
- **`templates/tier/go/*.go` was never gofmt'ed, and nothing checked it.** The
  gofmt check covered `templates/otel/go/*.go` only, so the new tree shipped
  with doc headings Go 1.19 would rewrite. It is checked now, over both trees.
- **`python3 -m py_compile` wrote `__pycache__/` into the template tree**, and
  the two checks that walk `templates/tier/<lang>/` then died with
  `IsADirectoryError` — a gate that went red on its own artefacts. The parse is
  now `compile()`, which is the same check with no filesystem side effect, and
  both checks skip non-files and *report* a stray directory rather than
  crashing on it.

- **kit-03 rebased onto a master that moved nine commits underneath it.** The
  branch point was `badcc2a`; master gained the move of the reusable workflow to
  `.github/workflows/` (`d42aebb`), kit calling its own workflow (`fb664a9`), a
  real Dockerfile parser and two real Dockerfile bugs (`9a8c3d7`), the gate
  bootstrapping its own dependencies (`a1cad0d`), and the hadolint asset rename
  from `darwin-*` to `macos-*` (`9b3dbeb`). Five files conflicted and all five
  were resolved as unions rather than as a choice between sides:
  - `tests/self_test.sh` — the breakage list is **19**, not master's 18 and not
    kit-03's 12. Master's 7-10 (four ways to break the documented `uses:` string
    against the real path), 11-12 (the two Dockerfile defects) and 13-18 (one
    semantic mutation per language) are intact, and kit-03's `2b` and its
    rewritten recipes for 2 and 4 are kept. Picking a side would have deleted a
    check that currently works, and the self-test's claim is that every breakage
    is caught by a *different* one.
  - `tests/validate.sh` — kit-03's `observability` phase, the `dev_escape_hatch`
    execution check, the eleven observability checks, and master's `callable path`
    check, `tests/bootstrap.sh` wiring and the whole-tree `yamllint` are all
    present. kit-03's own walk of `templates/compose` was **dropped as
    redundant**: master's `yamls_of_the_tree` enumerates by `git ls-files` and
    reaches the same files plus the rest of the repo, and two loops over one set
    of files report every problem twice and disagree about which is
    authoritative.
  - `AGENTS.md`, `README.md`, `CHANGELOG.md` — both sides' entries, with the
    breakage counts updated to 19 and the CHANGELOG's two `### Added` sections
    folded into one.
  - The collector and compose work was re-pointed at `.github/workflows/`
    rather than reintroducing the old path, and `fb664a9`'s local self-call is
    untouched.
- **The self_test count was a hardcoded string in two places, and both were
  wrong the moment either side added a breakage.** `self_test.sh`'s summary line
  and `validate.sh`'s check label now both **count** the recipes, so the number
  cannot drift from what the file proves. A new check asserts that every
  breakage the header documents has a recipe and every recipe has a header
  entry — the union requirement stated as an assertion, so the next packet that
  adds a breakage without documenting it (or documents one without writing it)
  gets a red gate instead of a stale sentence.

### Added

- **The observability stack** (PLAN.md §7b). Observability is ON BY DEFAULT and
  worked on in dev: `bin/dev up` brings up the OTel collector and the four LGTM
  backing services, and a service with nothing configured exports into them
  because `<SERVICE>_OTEL_ENDPOINT` *defaults* to the collector that ships with
  the stack. `<SERVICE>_OTEL_ENDPOINT` is the only contract (core D16); the
  shipped collector is just its default value, and unsetting it is a genuine
  no-op implemented with `OTEL_SDK_DISABLED`.
  - `templates/compose/otel-collector.yml` — OTLP **and** container-stderr
    receivers, the redaction allowlist **derived from core's schemas**, the
    `spanmetrics` connector, and fan-out to Tempo/Loki/Mimir. Every endpoint is
    a `${env:...}`; the gate fails on a literal.
  - `templates/compose/{tempo,loki,mimir}/` and
    `templates/compose/grafana/provisioning/` — vendor **configuration** and
    Grafana provisioning as files: three datasources, the dashboard provider, two
    dashboards and three alert rules, all working on first load.
  - `templates/compose/docker-compose.yml` — the four backing services, pinned
    to exact tags, healthchecked, memory-bounded, in an `observability` profile.
    **Grafana, Loki, Tempo and Mimir are AGPL-3.0 and ship UNMODIFIED**;
    `tests/validate.sh` fails on a `build:` stanza on any of them.
  - `templates/compose/.env.example` — every `${KIT_*}` the stack reads, with
    the port block documented.
  - `tests/canary_test.sh` — plants a canary in ten shapes a leak could take
    against a real collector and asserts it reaches no exporter, **and** that the
    allowed data survived.
  - `tests/no_telemetry_in_readiness.sh` — proves a service starts, serves and
    reports healthy with the collector killed, and that a collector whose three
    backends all refuse connections stays healthy, does not restart and does not
    enter a retry loop.
  - The six `templates/otel/<lang>/*.snippet` files now honour
    `<SERVICE>_OTEL_ENDPOINT`, default to the shipped collector, implement the
    free no-op with `OTEL_SDK_DISABLED`, record `error.type` and never
    `error.message`, and emit **exception log records** rather than the
    deprecated `exception` span event.
  - `templates/AGENTS.md` — an Observability section, so the endpoint contract
    and "telemetry is never in a readiness path" reach the service repo where a
    probe would actually be written.

- **The secret scanner.** A `secrets` job in `ci.reusable.yml` running
  **gitleaks 8.30.1** over the adopting repository's **full history**, with
  `--redact`. It is the one job in the workflow with **no opt-in**: an opt-in
  security control is not a control, and a secret scanner that only warns is a
  report. `fetch-depth: 0` is load-bearing — the runner default is a shallow
  clone, and a secret committed and deleted in one PR is still in the packfile
  of anyone who cloned. **Adopting this can turn a repo's first build red**;
  README says what to do, and the first thing to do is rotate.
  - gitleaks rather than trufflehog: trufflehog is **AGPL-3.0**, and it is the
    only candidate that verifies live credentials against the issuer's API,
    which for a fleet whose CI has network access is the wrong behaviour for a
    scanner. gitleaks is MIT, a static binary, and makes no network call.
  - `tests/gitleaks_gate.sh` is the **one** scan, called by both the `secrets`
    job and `tests/validate.sh`. A scanner whose CI and local invocations have
    drifted is two scanners, and the one that goes red is whichever nobody runs.
  - `.gitleaks.toml` — the allowlist, and **nothing else**. `extend.useDefault`
    so the rules stay gitleaks', and every `[[allowlists]]` entry must carry a
    `description` of at least 40 characters. An allowlist that grows and is never
    pruned is not an allowlist, it is a deferred disclosure. A `.gitleaksignore`
    fails the gate.
- **A `zizmor` job** (opt-in, `zizmor: 'true'`), running the GitHub Actions
  security audit on the adopting repo's own workflows. `tests/zizmor_gate.sh`
  counts `unpinned-uses` and prints the count and the reason on every run, and
  **fails on every other audit**. It is recorded, not baselined: see
  `DECISIONS.md` (MD10a), where the pin trade is costed in three options and none
  of them has been taken.
- **`templates/secrets/`** — the runtime credential-leak canary. A
  **language-neutral contract** (`templates/secrets/README.md`) and the **Go
  adapter**, with five vectors each carrying its own red proof: log/stdout/stderr,
  unknown serialisation fields, the whole error chain, keys present-but-empty,
  and Go type coverage.
  - It exists because **nothing off the shelf does this**. gosec's
    `credentials.Match` has no `*ast.CallExpr` case, so it finds literals and not
    a token passed to a logger. Bandit matches `ast.Constant` only. Brakeman's
    secret check is off by default. Of 268 Semgrep taint rules, **zero** intersect
    CWE-532.
  - The canary is **assembled at run time**, never written as a literal, so it is
    safe to commit and needs no allowlist entry. Two checks enforce that.
- **Ten new checks** in `tests/validate.sh` for the above, including one that
  asserts the scanner's **behaviour** by executing it: over a throwaway git
  repository holding a detectable credential, the scan must find it, must name
  the rule that fired, must not print the value, and must still find it after the
  file is deleted.
- **Eleven new `self_test` breakages**, each asserting that one *named* check
  went red: a credential in history, a credential in the working tree,
  `--redact` removed, the scan narrowed to the last commit,
  `pull_request_target` added, the `secrets` job made `continue-on-error`, four
  ways of breaking the canary's reference type, the canary committed as a
  literal, and `unpinned-uses` baselined in `.github/zizmor.yml`.
  - These were numbered 13–23 on `worker/kit-04` and are **24–34** here.
    kit-04's other six breakages (its 24–29) were its copies of the six language
    mutants, which master already carried as 13–18; those copies are dropped
    rather than renumbered, so no rule is proved twice under two numbers. The
    union is **34 breakages**, master's 1–23 unmoved.
  - `self_test` counts itself by grepping its own recipe calls, the same
    expression `validate.sh` uses for its label, so the summary and the gate
    label cannot disagree. It was a literal `18` in two files kept in step by
    hand, and for one commit a second runtime counter beside it.
- `tests/gitleaks_gate.sh` and `tests/zizmor_gate.sh`, `chmod +x` and asserted
  executable — they are run by the reusable workflow from a service's repository,
  so a missing executable bit is a `secrets` job that dies in thirteen repos.

### Fixed

- **`artipacked` (9 findings) in `ci.reusable.yml`.** Every `actions/checkout`
  now sets `persist-credentials: false`. No job in the file pushes, so a token
  left on disk after a checkout is a credential that outlives the job for no
  reason — and every job here runs `upload-artifact`, which is the combination
  the audit exists to catch. Found by zizmor, and fixed rather than baselined.
- **`.github/zizmor.yml` is no longer walked for stray copies of the workflow.**
  The `callable path` check reported `tests/self_test.sh` as "a second workflow
  declaring `workflow_call`" — it names the key in a comment explaining breakage
  8. A check that fires on the file proving it wrong is a check people delete.
- **Fetched tools now land in `tests/.bin/`, not `.venv/bin/`.** `.venv` is
  gitignored and `tests/self_test.sh` copies the tree twenty-nine times per run,
  so hadolint and gitleaks were being re-downloaded once per copy. The copy
  carries `tests/.bin`; it does not carry `.venv`.
- **The self_test control run no longer fails on a missing executable bit.**
  `cp -R` does not preserve mode bits on macOS, so every throwaway copy arrived
  with `tests/*.sh` non-executable and the new handed-out-scripts check failed in
  all of them — for a reason that had nothing to do with any breakage under test.

### Changed

- `tests/requirements.txt` pins **`zizmor==1.30.1`**, and an auditor is pinned
  where a parser is not: a new release adds findings, and a gate whose result
  depends on when it last ran is a gate nobody can reason about. zizmor comes
  from PyPI rather than a release archive because it publishes no checksums file,
  and pinning its archives would mean pinning hashes we computed ourselves.
- `kit_bootstrap_binary` takes an asset-name template and an inner-path, so it
  can install a tarball as well as a bare binary, and its sha256 table is keyed
  by **exact asset filename**. It used to be keyed by `macos-arm64`, which forced
  every caller's asset name to be derivable from `<name>-<os>-<arch>` — true for
  hadolint, false for gitleaks, and the reason this function could not install a
  second tool. There are now three spellings of the OS name in play
  (`macos`/`darwin`/`apple-darwin`) and all three are mapped explicitly.
- The `callable path` check's copy-walk skips `.bin` and shell scripts.

### Earlier

- A **`callable path` check** in `tests/validate.sh`: the reusable workflow
  exists at the path callers are documented to use, it declares
  `on: workflow_call`, every real `uses:` that names kit — in `README.md`,
  `AGENTS.md` and this repo's own workflow files — is exactly that path,
  `kit`'s own CI calls it with the local `./` form, and there is exactly one
  copy of it in the tree. The failure it exists for: for six months the file
  sat at `workflows/ci.reusable.yml`, the README told every reader to call
  `cafaye/kit/workflows/ci.reusable.yml@master`, GitHub resolved that to
  nothing, and **every check in the suite was green throughout**. A layout bug
  and a documentation bug that agree with each other are invisible to any check
  that reads only one of them.
- `tests/bootstrap.sh` — the gate now installs its own dependencies.
  `bash tests/validate.sh` is the **whole procedure on a clean clone**: it
  resolves an interpreter, builds `.venv` and pip installs
  `tests/requirements.txt` on first run, printing a `note:` line. `AGENTS.md`
  and the README no longer instruct anyone to run a two-line step first.

  This was the second time the gate failed on arrival. It exited 1 with
  `no python with PyYAML: pip install -r tests/requirements.txt` on every fresh
  clone and every CI runner, because it preferred the gitignored `.venv` and
  fell back to a `python3` that has no PyYAML. The prerequisite was documented,
  which is exactly why it got skipped: by every runner, and by anyone who
  cloned without reading the file first.
- `yamllint` now lints **every** YAML in the tree, enumerated by `git ls-files`
  rather than a hand-kept list of the two compose templates, and a missing
  yamllint is a `FAIL` instead of a `SKIP`. kit ships the config and a repo
  that copies it lints its own CI against it on day one, so a YAML that breaks
  the config greets the first adopting repo with a failure nobody authored. A
  skip here would hide a broken config behind a missing tool on precisely the
  machine that had not run the gate before.
- **`lint/hadolint.yaml`, and real lint on all seven Dockerfiles.** They were
  the only artifact in the tree with no parser at all — seven `SKIP ... (no
  parser for this file type)` lines, honest and completely uncovered, on a file
  every adopting service inherits. They now get three layers: hadolint
  (required, pinned to 2.15.1, verified against hadolint's published
  `checksums.sha256`); a non-root / no-`:latest` / no-`ADD` check for the two
  properties hadolint cannot see; and a check that each template's own
  STRICTNESS NOTES state the non-root guarantee to the reader deciding whether
  to adopt the file.

  **hadolint found a real defect on its first run.** `docker/Dockerfile.python`
  ran `pip install uv` with no version, so the resolver's own version decided
  what every build resolved to — an unpinned build input in the one image whose
  whole point is a frozen resolution. Now `ARG UV_VERSION=0.5.11`, in step with
  the `uv` pin in `templates/mise.toml`.

  **The third check found a documentation bug in the same run.**
  `Dockerfile.bun`'s STRICTNESS NOTES said *"The official image has no
  unprivileged user, so we create one."* `oven/bun:1.3.12-slim` ships `bun` at
  uid 1000 (verified against the running container) and the `useradd` that note
  described was never in the file — the note described a different Dockerfile
  than the one being read. Three of the seven said nothing about non-root at
  all; all seven say so now.
- The one ignored hadolint rule is DL3008 ("pin apt versions"), argued in
  `lint/hadolint.yaml` rather than assumed: a hardcoded `build-essential=12.9`
  in a template thirteen repos copy is a version thirteen people must remember
  to bump, and the day Debian drops that build every one of them fails at once —
  a correlated outage caused by a security patch landing. A service that wants
  reproducible apt resolution pins in its own repo, which is the
  "callers override, they never fork" rule.
- `expect_red_check` in `tests/self_test.sh`, which asserts that one *named*
  check reported `FAIL` rather than merely that the gate went red. Breakages
  7-10 use it, so the check written for each layout/documentation drift is
  proven load-bearing instead of being one of forty checks that could have
  gone red for an unrelated reason.
- `.github/workflows/ci.yml` — kit calling its own reusable workflow with
  `uses: ./.github/workflows/ci.reusable.yml`. The repository that defines the
  standard is now the first repository held to it, and if the callable path ever
  breaks again it is red on kit's own commit rather than discovered by the
  first service that adopts it.
- A `none` value for the `language` input, and a `none` job that runs the
  calling repository's own `tests/validate.sh`. **This is a bug fix, not a
  feature.** The workflow was uncallable by any repository without a service
  manifest — which includes `kit`. `language` is `required: true` and every
  value in `options` named a toolchain, so `uses: ./.github/workflows/ci.reusable.yml`
  had no input that could make it resolve. The job fails when `tests/validate.sh`
  is absent, because a config gate with no gate in it is the same defect as a
  coverage threshold left at `0`.
- `workflows/ci.reusable.yml` — a `bun` job: `bun install --frozen-lockfile` →
  `bun run typecheck` → `bun test`, with an opt-in coverage step. Exists because
  `guard` was hand-rolling a whole workflow for want of one; a repo that adopts
  it can collapse that file to a `uses:` call.
- `workflows/ci.reusable.yml` — an opt-in `telemetry` input (string, default
  `'false'`) and a `telemetry` job that runs the W3C traceparent conformance
  suite for all six languages in a matrix. Opt-in so that adopting kit never
  turns a green repo red.
- `docker/Dockerfile.bun` and `templates/bin-prime/bun.sh` — the other two
  artifacts a language ships, so `bun` is a first-class `language` value.
- `templates/bin/dev.sh` — the local developer loop. `up --wait`, migrate, seed
  an admin, print the URLs. Idempotent; fails loudly and stops *before*
  migrating rather than half-starting.
- `templates/compose/otel-collector.yml` — receiver, batch processor, and a
  `debug` exporter that writes to the collector's own stdout. Sends nothing
  anywhere, by default and by gate. **Superseded by kit-03** below: the
  collector now fans out to Tempo, Loki and Mimir, because observability is on
  by default. The `debug` exporter and the "no literal endpoint" rule stay.
- `templates/otel/<lang>/` — per language: a stdlib `traceparent.*` codec, an
  executed conformance suite, an SDK wiring snippet with a documented
  "when to use which" README, and a statement of the W3C sections implemented.
- `templates/otel/pins.md` — the OTel versions the snippets reference, at the
  otel root because it covers all six languages. kit vendors nothing.
- `README.md` — sections for the local stack and for trace propagation,
  including a worked example of a service adopting propagation, and an accurate
  description of what the gate actually does.


### Fixed

- **`tenant_id` was silently stripped from every trace and log resource.** The
  `redaction/cafaye_metrics` processor listed the private stash names
  (`cafaye.stashed.tenant_id`, `cafaye.stashed.account_id`) in its
  `ignored_keys`; `redaction/cafaye_traces` and `redaction/cafaye_logs` did not.
  The redaction processor deletes every attribute it does not exempt, so on
  traces and logs it deleted the carrier the restore was about to read, and the
  restore put `tenant_id` back from an empty source. Per-tenant metric totals
  worked; per-tenant trace and log identity did not, with no error anywhere.
  **Every static check passed on the broken tree** — being *stashed* and being
  *exempted* are different questions and only the second survives contact with a
  running collector. Two assertions added: every private stash name must be
  exempted in all three processors, and the three `ignored_keys` lists must be
  equal.
- **The collector's `_total` rename never fired, so every dashboard panel
  rendered "No data".** `transform/cafaye_metrics_labels` matched
  `IsMatch(name, "\\.calls$")` inside a YAML *single-quoted* scalar, where a
  backslash is not an escape — so OTTL received a regex requiring a literal
  backslash and it matched no metric, ever. The processor was wired in and
  documented at length. The pattern now avoids escapes entirely.
- **Every Grafana panel had `"datasource": null`**, which Grafana resolves to the
  *default* datasource — Mimir. All LogQL panels and the TraceQL panel were being
  sent to a Prometheus API and rejected (`parse error: unexpected character:
  '|'`); 12 of 15 panel queries were invalid. The alert rules grouped on
  `otel.status_code`, which is a parse error in PromQL because OTLP ingestion
  mangles dots in label names to underscores. Both fixed, and a check now holds
  it: every query must name the backend that can answer it, and every PromQL
  expr must use the underscored spelling.
- **`tests/self_test.sh` had two breakages whose recipes no longer applied.**
  `edit` correctly refuses a stale pattern, so the gate went red on breakage 2
  and never reached 3, and then again on 4. Both recipes rewritten against the
  shipped config; a twelfth breakage added covering a *missing* backend
  exporter, which the set-difference check could never have seen.
- **`tests/no_telemetry_in_readiness.sh` proved less than it claimed.** It passed
  bare `host:port` to the `otlphttp` exporters, which made the collector exit(1)
  with `endpoint must be a valid URL` — indistinguishable from the bug the test
  exists to catch. Its stand-in service was `traefik/whoami`, which ships no
  `wget` (so the probe never ran) and answers every path with 200 (so its
  `/readyz` could never fail). Replaced with a real two-service stack whose
  `/readyz` is proven to go 503 before the "still serving" claim means anything.
- **The canary's redaction receipt was flaky, 1 pass in 3.**
  `docker logs ... | grep -qi` under `set -o pipefail` is a SIGPIPE race: `grep -q`
  exits at the first match, so `docker logs` dies with 141 whenever the log is
  large enough to still be writing. The log is now captured to a file. The
  spanmetrics assertion had the same shape — the connector flushes on its own
  interval — and is now polled with a deadline. Both are PASSes, not NOTEs.
- **The local compose stack could not start.** `otel-collector.yml` resolves its
  values from the collector's own process environment, and Docker Compose does
  not inject the `.env` values it substitutes into containers. Every one resolved
  empty and the collector exited with `processors::memory_limiter: ... must be
  greater than zero`, which names a memory limiter rather than the missing
  environment. The nine `KIT_OTEL_*` values are now passed into the collector
  container. The stack parses, passed every check kit had, and did not work.
- The compose **port check** flagged the collector's in-network bind addresses
  (`0.0.0.0:4317`) as hardcoded published ports. It now reads the parsed
  `ports:` lists, so it can tell a published port from a bind address, and its
  failure message names the service and the value.
- The elixir conformance suite failed 2/13 on two tests that called
  `.outbound_headers` as map access on a struct with no such field, where the
  rest of the file uses the local `outbound/1` helper.
- The elixir "new identifiers are random" test rebound its `seen` set inside a
  `for` comprehension, shadowing the outer binding. The uniqueness assertion
  compared 256 draws against an empty set and could never fail.


### Changed

- **The port block.** Every published host port moved into **15000-15999**,
  one hundred per service: 15000 Grafana, 15500 Postgres, 15600 NATS client,
  15700 NATS monitoring, 15800 Redis, 15900 Tempo, 15901 Loki, 15902 Mimir. Not
  5432/4222/6379, which are the two or three most likely things already
  listening on a developer's machine — and `bin/dev` is the first command a new
  person runs. The gate asserts membership of the block and no reuse, as a RANGE
  rather than a list, so adding a service does not mean editing a check.
  **Unverified against the rest of the fleet**: the block is claimed
  fleet-wide and nothing coordinates it across repos. A sibling repo's scratch
  container was observed holding 15500 during kit-03's own verification.
- **`templates/compose/otel-collector.yml` no longer ships `debug` only.** It
  fans out to three backends now, so the privacy boundary is restated as what it
  can actually be: every endpoint a `${env:}`, the exporter set exactly those
  three plus the local `debug`, and a `redaction/*` processor in every pipeline
  before `batch` and therefore before every exporter.
- `templates/bin/dev.sh` — `STACK_TIMEOUT` 120s → 180s (five more containers,
  four with a real initialisation), brings up the `observability` profile by
  default, prints the wall-clock, and prints the observability URLs. The
  escape hatch is `KIT_DEV_PROFILES=`.
- `templates/compose/docker-compose.yml` — the collector's healthcheck probes
  its real `health_check` endpoint instead of printing its component list, and
  the four stores' healthcheck budgets were raised after measuring them.
- `tests/validate.sh` gained an `observability` phase and a `--no-observability`
  flag; both docker-requiring proofs SKIP loudly when docker is absent.

- **The reusable workflow moved to `.github/workflows/ci.reusable.yml`.** It was
  at `workflows/ci.reusable.yml`, and GitHub documents that subdirectories of
  the workflows directory are not supported — so the `uses: cafaye/kit/workflows/
  ci.reusable.yml@master` line in the README resolved to nothing. No repository
  in the fleet was calling it. It is now a **move, not a mirror**: one file, at
  the only path GitHub will resolve, so there is no second copy to diverge.
- `self_test.sh` grew from 5 breakages to **19** — master's 18 plus kit-03's
  `2b`, which deletes a backend exporter entirely. A set-difference check on the
  exporter set catches an exporter that should not be there and is silent about
  one that is *missing*, and a missing exporter ships a stack that collects
  everything and prints nothing. Six are per-language semantic mutations, each
  against a different W3C section, so
  **every** suite is proven able to fail rather than assumed to. A mutant that
  fails to compile is its own verdict rather than a pass, a missing toolchain is
  a skip that fails the run, and an unmatched mutation is a hard failure so the
  proof cannot rot into proving nothing.
  Both sides' recipes for breakages **2** and **4** were kept, and they are not
  the same recipe: kit-03's rewrote them because they named strings that no
  longer exist — `exporters: [debug]` stopped being the traces pipeline when it
  fanned out to three backends, and a literal `${KIT_POSTGRES_PORT:-5432}`
  stopped existing when the stack moved into the 15000-15999 port block.
  `edit` refuses an unmatched pattern, so a stale recipe fails loudly instead of
  passing silently; that is correct, and it is also how a self_test stops testing
  the thing it names.
  The count in the summary line is now **counted from the recipes** rather than
  written down, and a check asserts that every breakage the header documents has
  a recipe and every recipe has a header entry — so the two cannot drift.
- `validate.sh` reads the CI workflow's `language` options and requires a
  Dockerfile, a `bin/prime` and a `[tools]` pin for each — "half a language is
  worse than none", enforced rather than trusted. It also requires `language`
  options and the job set to be the same list, a ref on every `uses:`, no
  branch refs, and every `${{` to close.
- New checks: the otel-collector environment wiring, that every `*.snippet`
  carries an install line and a pinned version, that every snippet **parses in
  its own language**, and that the README's documented callers only pass inputs
  the workflow actually declares.
- The `telemetry` CI job is a matrix while the seven language jobs stay one-per-
  language: a matrix is right for six stdlib test suites that share nothing, and
  wrong for six toolchains that install different things.
- The `telemetry` input is a string rather than a boolean, because GitHub
  coerces the bare word `false` in some positions and `if: inputs.telemetry` is
  a trap as a result.

### Fixed

- A `pipefail` bug in the new staleness test, where a successful `grep` was
  masked by the classifier command's own deliberate non-zero exit. The output is
  captured to a variable and the status read from the command, never from a pipe:
  **a piped exit code is the exit of the last stage.** The same trap, one level
  down from the one `self_test.sh` already documents at breakage 6.
- The fail-closed tier was stated in **two** places — a string in `classify.py`
  and a rule in `rules.json` — and the self-test breakage written to invert it
  left the suite **green**, because the headline case never reached the line that
  was broken. A property asserted in two places is asserted in zero. Both facts
  now live in `rules.json` alone, and the counterexample is one token.
- A `current`-at-head pin was reported as `unknown`. That is the state a reader
  learns to ignore, which makes it the expensive direction to get wrong.

### Changed

- `AGENTS.md` records that the classifier **fails closed** as a rule about code
  and not about data, and carves `core/`'s two programs out of the config-only
  rule explicitly — stdlib only, nothing imports them, no committed output — so
  that the exception is bounded rather than the start of a trend.
- `AGENTS.md` and `README.md` describe twenty-three breakages rather than
  eighteen, and the phase list gains the classifier and staleness phases.

### Not done, and why

- **No repository was migrated.** `vendir.yml` files for `muse`, `pantry` and
  `caf` are shipped as templates with the exact steps in
  `core/renovate/SETUP.md`; applying them is thirteen pull requests in thirteen
  repositories, and this change is scoped to `kit`.
- **`oasdiff` is not wired in.** It is the right tool for the OpenAPI half — a
  static Go binary, a live GitHub Action, and **755 level-tagged checks** measured
  by running `oasdiff checks changelog` at v1.32.1 — but `core`'s fan-out is raw
  JSON Schema, and adding a pinned binary would make `kit` a repository with a
  dependency, which `AGENTS.md` forbids.
- **`expectOperations` is untouched and stays in `cafaye-ts`.** vendir has no
  opinion about whether a copy should have been allowed to change size, and a
  guard moved into a tool that cannot enforce it is a guard deleted.
- **Three of the fleet's five parity guards still skip** when the core checkout
  they compare against is absent. Fixing that is independent of vendir, more
  urgent than vendir, and belongs to the repositories that own them.


### Earlier (kit-01)

- `README.md` — what kit is, how a service repo adopts it, adoption checklist.
- `AGENTS.md` — conventions for this repo.
- `workflows/ci.reusable.yml` — reusable GitHub Actions workflow. Inputs
  `language` (go|ruby|elixir|python|node|rust), `working-dir`, `versions`, and
  `coverage-fail-under`; one job per language, each install → lint → test →
  coverage. No job builds or pushes an image.
- `lint/` — `yamllint.yml`, `golangci.yml`, `rubocop.yml`, `eslint.config.mjs`,
  each with its strictness decisions written down.
- `docker/Dockerfile.{go,rust}` — multi-stage, distroless final.
  `docker/Dockerfile.{ruby,elixir,python,node}` — multi-stage, `*-slim` final.
  All non-root, none on `:latest`, all versioned through build args.
- `templates/bin-prime/{go,ruby,elixir,python,node,rust}.sh` — worktree
  primers; exit 0 only when the tree is genuinely ready.
- `templates/mise.toml` — per-language tool sections with placeholder versions.
- `templates/AGENTS.md` — skeleton repo-conventions file.
- `tests/validate.sh` + `tests/requirements.txt` — the gate, and its deps.
