# Changelog

All notable changes to `kit` are recorded here. kit has no releases yet and no
semver contract — it is consumed by *calling*
`.github/workflows/ci.reusable.yml@master` and by *copying* files out of
`docker/` and `templates/`. `lint/` is the exception and no longer belongs to
that sentence: the reusable workflow reads it at run time, so a service inherits
it without a copy (see kit-12 below).

> Entries under **Earlier**, and the three `workflows/ci.reusable.yml` bullets
> below, record the path the file had *at the time*. It was
> `workflows/ci.reusable.yml` until the move recorded in Unreleased/Changed.

## Unreleased

### Changed

- **kit-12 — lint runs from kit. The `cp` is gone.**
  `lint/` was 249 lines of golangci, rubocop, eslint, yamllint and hadolint
  configuration that **not one service in the fleet had ever copied**, and every
  check in this repository was green the whole time. Adoption correlated
  *inversely* with how much a file did: `uses: cafaye/kit/...@master` is 11/11
  because it is live, and `cp lint/golangci.yml` is 1/11 because a snapshot has
  no propagation and rots silently. So the config moved to where the step already
  is, and adoption becomes 11/11 with no per-service action.

  (The brief this packet answered put those at 8/8 and 0/9. The second is
  stale — `identity` has since landed a `.golangci.yml` of its own on `master`,
  for a reason recorded in `lint/drift-allowlist`. Writing `0/9` here would have
  been a number this work had measured and known to be wrong.)

  - **`kit-lint-ref` and a sparse `lint/` checkout, in the go, ruby and node
    jobs.** The workflow file and the configs are two different things:
    `uses: cafaye/kit/...@X` pins the *workflow*, and a reusable workflow is not
    handed its own ref — so the configs are fetched by name, and the name has to
    be an input. Pin it to the **same** ref you pinned `uses:` to; a caller who
    pins one and not the other gets that SHA's workflow with today's lint
    policy, which nothing detects automatically and is therefore documented in
    the input and in README.md rather than pretended to be automatic.
  - **The ESLint config is checked out *inside* the repository, at
    `<working-dir>/.kit`.** Measured, not preferred: node resolves an ESM import
    from the config file's own directory upward, so a config beside the
    repository finds no `@eslint/js` and the run dies with
    `ERR_MODULE_NOT_FOUND` — a red build that has linted nothing. One location
    serves all three linters.
  - **`lint/eslint.config.mjs` ignores `.kit/**`.** Without it the run is red
    with a parse error about *kit's own* config file, in a service that did
    nothing wrong, on a file the service never wrote.
  - **`lint-args` is the deviation seam**, and it is deliberately narrow: it is
    appended *after* kit's flags, so a service can add and cannot remove the
    `--config`; and it is a string rather than a path, so there is no
    service-side file to rot. What it may not do — change which config is read,
    what is linted, or whether a finding fails the build — is a list of 15
    refused flags enforced by a **`lint-args guard` step in the workflow**, not
    by kit's gate, because `lint-args` is the caller's value and kit has never
    got it. `lint_args_seam_check` asserts the guard is in all three lint jobs,
    that the copies are byte-identical, that it runs *before* the linter, and
    that its token list is the one written in the gate.
  - **ESLint runs directly, not `npm run lint`.** `npm run lint` is whatever
    script the repository happens to define — a repository that defines none gets
    a confusing "Missing script" rather than a lint, and one that defines it is
    running its own config, which is the copy this packet exists to end.

### Added

- **kit-12 — the gate now knows whether a linter ran.**
  - **`tests/lint_test.sh` (a sixth phase, `lint`, deliberately outside the
    `RUN_STATIC` guard).** Four linters are **executed** against a throwaway
    service built to violate exactly one rule, with kit's config, each paired
    with a control that must answer differently. `lint/` spent its whole life
    behind a parse check — `yaml.safe_load` on `golangci.yml`, `node --check` on
    the eslint config — and both are green on a file no linter has ever been
    pointed at. This phase is the only thing that tells a working config from a
    valid one, and it is **fatal on a skip**: the claim under test is "kit's
    configs work", and a run in which no linter executed has not tested it.
  - **`lint drift`, which reads BOTH files and reports the DIFFERENCE.** A
    service carrying a `.golangci.yml` that disagrees with kit's is told which
    linters it dropped or added. Banning the file was the first version and it is
    worse than the drift: a config that agrees with kit's has reached the same
    policy by another route, and failing it teaches the lesson that kit's config
    is a thing you get shouted at for having. Self-test breakage 27b asserts the
    agreeing copy **passes**, so the check cannot be satisfied by deleting it.
  - **`lint/drift-allowlist`**, for a difference that cannot be deleted yet:
    reason, owner, `since`, `until`, and four rules of which the fourth is the
    load-bearing one — **an entry that no longer describes a real difference
    fails**, modelled on ESLint's `reportUnusedDisableDirectives`. One entry is
    live: `identity`, whose `.golangci.yml` enables no linter and exists only to
    exclude one generated file.

### Fixed

- **A promise this repository made in a comment, with no control behind it.**
  The `lint-args` input's own description said `lint_wiring_check` "fails on
  exactly that string" for `--no-config`, and `lint_wiring_check` had no such
  assertion anywhere in it. The reason it *could* not have one is worth
  recording: `lint-args` is the **caller's** value, and kit's gate never sees
  it. So the control moved to where the value is — a `lint-args guard` step in
  every lint job — and kit's gate now asserts the guard exists, is identical in
  all three jobs, runs before the linter, is handed the variable, and still
  refuses all 15 flags. A comment promising a check is worse than no comment:
  the second one stops the reader looking for the first.
- **A claim this repository made about golangci-lint, before running it.** The
  drift check was written on the belief that a repo-root `.golangci.yml` is
  discovered "ahead of any flag the workflow passes", so a stale copy silently
  hijacked CI. **That is backwards.** `golangci-lint run -v` prints exactly one
  `[config_reader] Used config file`, and with `--config` it names kit's; a local
  config that disables `misspell` does not survive it, and RuboCop agrees. A copy
  does not hijack the build — it **splits** the policy, because every other
  invocation in that repository reads it while CI reads kit's, and it becomes
  live again the instant the flag is lost. That is still a finding, and it is the
  honest one. `GOLANGCI_LINT_CONFIG` **is** confirmed unread in v2, as claimed.
- **An allowlist rule that was red on a correct tree.** "An entry that no longer
  describes a difference" treated a repository that was *not in this checkout's
  fleet* as one that had stopped differing, so every run on a copy of kit — which
  is what `self_test.sh` does, twenty-odd times — reported the whole allowlist as
  dead. The rule is now scoped to repositories the run actually looked at; an
  entry naming one that was not looked at is reported as **unverified**, which is
  neither a pass nor a failure.


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
