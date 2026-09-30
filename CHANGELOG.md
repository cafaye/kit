# Changelog

All notable changes to `kit` are recorded here. kit has no releases yet and no
semver contract — it is consumed by *calling*
`.github/workflows/ci.reusable.yml@master` and by *copying* files out of
`lint/`, `docker/`, and `templates/`.

> Entries under **Earlier**, and the three `workflows/ci.reusable.yml` bullets
> below, record the path the file had *at the time*. It was
> `workflows/ci.reusable.yml` until the move recorded in Unreleased/Changed.

## Unreleased

### Changed

- **The stack is fetched from a pinned kit ref. A service no longer carries a
  copy of it.** `templates/compose/` shipped a complete local observability
  platform — the collector with a redaction allowlist **derived from core's
  schemas**, plus Tempo, Loki, Mimir and a provisioned Grafana — and **no
  service used it**. Six repositories shipped a bespoke 52–158 line
  `docker-compose.yml` carrying a Postgres and little else, each hundreds of
  lines from kit's, and **none** of them adopted `bin/dev`. (billing's `bin/dev`
  is Rails' `bin/rails server`; the brief's "1 of 9" is 0 of 6 by measurement.
  The line counts are a measurement, not a range that holds — other workers are
  editing these files.)

  A compose file cannot be `uses:`-ed, so `bin/dev` is the only callable path:
  it fetches `templates/compose/` from the ref in **`kit.ref`** and runs it
  *beside* the service's own file, which is therefore an override rather than a
  fork. A service with nothing to add needs no compose file at all.

  - **`kit.ref` — the pin, in a COMMITTED file, not in `.env`.** A 40-character
    commit sha or a `v<semver>` tag; a branch is refused **before any network
    call**, because `bin/dev` decides whether a redaction allowlist is in force
    and a service whose gate resolves differently on Tuesday than on Monday has
    a telemetry boundary nobody can state. It is committed because `.env` is
    git-ignored: a pin there exists on one laptop and on no CI runner, so "one
    command, always current" resolves to "one command, whatever this checkout
    last fetched". `bin/dev pin <ref>` prints the stack diff **first**.
  - **Offline is real.** `KIT_STACK_OFFLINE=1` uses only `KIT_STACK_DIR`, the
    per-ref cache, or a vendored `.kit/stack` that **records its ref**. A
    directory that merely contains `templates/compose/` is refused; a mismatched
    or missing record is refused; with none available it fails loudly, naming
    each. It never falls back to the working directory.
  - **`templates/compose/docker-compose.yml` mounts every vendor config through
    `${KIT_COMPOSE_DIR:-.}`,** which `bin/dev` sets to the *fetched* tree.
    Without it the mount resolves to a path that does not exist, Docker creates a
    **directory** there, and the collector exits naming a file type.
    `docker compose config` renders the same project either way, because the
    variable's *value* is not a property of the YAML.
  - **The postgres healthcheck was a decoration, and is now a real query.**
    `pg_isready -U identity -d nosuchdb` exits **0** against a database that does
    not exist; `psql … -tAc 'select 1'` exits **2**. The shipped probe used
    `pg_isready` with `${KIT_POSTGRES_USER:-cafaye}`, interpolated at *compose
    render* time, so a service that renamed its own database was health-checked
    for a role that did not exist — and the comment above it claimed the `-U/-d`
    pair "makes it check the real thing". The probe now runs a query, against
    the database the container actually has (`$$` escapes compose's own
    interpolation). Measured cold: healthy in 16s.
  - **`bin/dev pin` fetches both refs before printing its diff.** It used the ref
    already on disk, so on a machine that had never run `bin/dev` it said the
    diff "cannot be computed here" and wrote the pin anyway — the command's
    entire reason for existing was absent on the run most likely to *be* the
    upgrade. Offline is honoured rather than attempted, and when one side
    genuinely cannot be obtained it names the `git diff` to run by hand instead
    of reporting a success it cannot back. It also no longer writes a malformed
    `kit.ref`: a missing newline ran three comment lines together. Pinning to the
    ref already pinned is a no-op and says so.

### Added

- **`tests/fleet_check.py` — the gate on the FLEET, and it names the fleet's
  adoption debt.** It reads the *other* repositories, because nothing else in kit
  does: a stale copy of the stack, a weakened redaction boundary, a collector
  config nothing ever starts, an unpinned ref, and a published port on a service
  kit already ships. Against this fleet: **6 repositories in scope, 13
  findings** — the stale-copy rule catches **billing, courier, darkroom,
  identity, muse**, the pin rule catches **all six**, and the port rule catches
  **darkroom, identity**.

  **The adoption ceiling.** A finding inside a repository that HAS a `kit.ref`
  is a **FAIL**, every time, with no discretion. A finding inside a repository
  that has adopted nothing is a **WARN** naming the adoption path — the exact
  `git -C ../kit rev-parse HEAD > kit.ref`, the override-not-copy rule, and the
  port-variable rule — and it does not turn the build red. Same four predicates,
  same messages, same severity: **the strictness MOVES to where adoption
  exists, it does not disappear.** A repository that adopts converts its own
  named debt into a failure with no re-review, which is what makes this a wave
  rather than a discount.

  The judgement is about **who owns the debt**, not about how bad it is:
  `identity` has adopted and still runs its own `postgres:17-alpine` — a defect
  in an adopting repository, and a failure. `billing` has adopted nothing and
  runs the same image, which is the cost of a fleet that has not taken up the
  standard. A gate that stays red for thirteen findings no repository has agreed
  to fix is a gate whose red stops being read within one release, and a gate
  nobody reads catches nothing. The ceiling is printed by the check, carried in
  the gate's own summary line, and argued in `REPORT-kit-13.md`; a ceiling that
  exists only in an exit code is a ceiling nobody knows is there.

  Adoption is read from `read_kit_ref` — the same function every finding message
  already assumes — and only `absent` counts as unadopted. An empty,
  multi-valued or unreadable `kit.ref` is a repository that **adopted and wrote
  the pin wrong**, and it fails; reading adoption from "the file exists" would
  have made a broken pin a warning in exactly the case where somebody was
  fixing the previous warning.

  It also found something no check in kit could have: **`muse/docker-compose.yml`
  did not parse.** Line 65 put a `: ` inside an unquoted YAML scalar and
  `docker compose config` exited 1 on it, so that stack could not start at all.
  Fixed by muse's own packet; the gate reported it first, and muse now shows up
  under the stale-copy rule instead. Recorded because the sequence is the
  evidence that a gate reading other repositories is worth having.

  The stale-copy rule keys on the **image**, not the service name — three of the
  five call their database `db`, and a name-based check reports the fleet clean
  while every copy stands right there.

- **`tests/fetch_test.sh` — the fetch path, executed.** 17 assertions against a
  local bare remote over `file://`: a pin resolves and the fetched bytes are
  **byte-identical** to the tree pinned; a branch, an abbreviated sha and a
  missing pin are each refused with a message that says why; offline works from
  a warm cache **with the remote moved away**, fails loudly from a cold one, and
  accepts a vendored copy that declares its ref while refusing one that does not.
  The last four cover `bin/dev pin` — that it fetches **both** refs so its diff
  is real from a cold cache (the first use, and the one most likely to *be* the
  upgrade), that the sha is the last line of `kit.ref`, that the comment header
  is one `#` per line, and that pinning to the current ref is a no-op which says
  so.

- **`tests/stack_live_test.sh` — the fetched stack, run.** Brings up all eight
  containers, reads the collector's config mount back with `docker inspect`, and
  proves a trace reaches Tempo, a metric reaches Mimir, the `spanmetrics`
  connector mints the fleet dashboard's source, and a canary in ten attributes
  reaches neither. Two assertions failed on the first run and both were bugs in
  the test: a container with no healthcheck read as unhealthy, and a distroless
  image's failed `exec` was compared against the config — *the error string was
  the evidence*.

- **Two kit-side gates.** Every vendor config mounts from the fetched tree (a
  check over the **agreement** of the compose file and `bin/dev`, because the
  defect is in their agreement); and the pin is `kit.ref` and the fleet gate
  reads the same file — three files, one fact, and their disagreeing is invisible
  from any one of them.

- **Two new self-test breakages (30–31), and they are the adoption ceiling
  proved from BOTH sides.** 30 is the same stale copy as 23 in a fleet with no
  `kit.ref` anywhere: the gate **stays green** and the finding is still printed,
  asserted with a literal substring of the finding rather than the word `WARN`,
  so a gate that printed `WARN` and nothing else cannot satisfy it. 31 is that
  identical mutation with `kit.ref` committed: the gate goes **red** on the
  identical finding. Now **31 breakages in all — 30 red, 1 green-expecting**,
  15 of them name-specific — and the summary line counts the two separately
  rather than summing them, because "31 breakages, 31 reds" would hide the only
  fact that distinguishes them.

  One mutation, factored into `break_stale_copy`, shared by all three recipes:
  two hand-written copies of a nine-line YAML mutation would drift, and the drift
  would read as "31 proved the ceiling is airtight" when 31 had stopped testing
  the same thing 23 tests. `unadopt` removes `kit.ref` from **every** repository
  in the fixture, because the ceiling is per-repository and a half-adopted
  fixture cannot tell a failure of the unadopted side from a failure of the
  clean-adopting side.

- **Seven new self-test breakages (23–29), each asserting the NAMED check.**
  The four failure modes against **fixture** fleets (the real fleet is red by
  design, so "the gate went red" there is satisfied by two clean repositories),
  plus the mount regression, the pin moved back into `.env.example`, and the
  `ports:` append rule the compose file's own comment promised and the gate did
  not implement.

  Breakage 28's shape is the one that reads like an improvement: shipping
  `KIT_STACK_REF=<sha>` in the template means a fresh clone looks configured and
  needs no setup, and it also puts the pin in a file that becomes `.env` — which
  is git-ignored, so it decides nothing on any other machine.

### Fixed

- **`tests/validate.sh` — the fleet gate's SKIP decision is now the script's.**
  The first wiring guarded the call with its own "are there any sibling
  entries?" test. A self-test throwaway directory *has* sibling entries and none
  is a repository, so the control ran the check, the check exited 2, and the
  self-test's control went red for a reason unrelated to the packet. One
  predicate now, answering with a machine-readable `FLEET-ABSENT` marker.
- **`dev_escape_hatch_check` was red.** Its fixture carried five empty files that
  `require_files` demanded; this packet deleted `require_files`, so the fixture
  stopped reaching `up` at all and the check died on the pin lookup before the
  trap it exists to catch could fire. It now builds a service sandbox with no
  stack of its own and a stub kit tree behind `KIT_STACK_DIR`.
- **`tests/fetch_test.sh` and `tests/stack_live_test.sh` ran by nothing.** Both
  are in the gate now — the fetch test outside the `RUN_STATIC` guard with the
  classifier and the staleness reporter, because it is a property and not a shape.
- **`expect_green` no longer re-runs the gate to print its diagnostic.** That was
  a second chance to lose the throwaway tree, and on the run where it mattered
  it lost it — the control was reported as a `cd:` error, which is a diagnosis of
  the diagnosis. One run, captured.


- **kit-13 — the observability stack gets a live path, and a gate that says which
  repositories are not on it.** `templates/compose/` shipped a complete local
  observability platform and **no service used it**: no repository had an
  `otel-collector.yml`, six carried a bespoke 52–158 line
  `docker-compose.yml` whose only infrastructure was a Postgres, and **none**
  adopted `bin/dev`. The stack was built, gated, and running nowhere.

  - **`bin/dev` fetches the stack from a PINNED kit ref** and runs it beside the
    service's own `docker-compose.yml`, which is an override. A compose file
    cannot be `uses:`-ed — GitHub resolves reusable *workflows* and nothing else —
    so `bin/dev` is the callable path and the pin is what makes it one.
    `git init` + `fetch --depth 1` rather than `clone --branch`, because
    `--branch` cannot take a commit sha and so cannot express the stricter of the
    two pin forms.

  - **The pin is `kit.ref`, a committed one-liner — and it was `.env` first.**
    `.env` is git-ignored, so a pin there exists on exactly one machine and on no
    CI runner or teammate's checkout, which turns "one command, always current"
    into "one command, whatever this checkout last fetched". `bin/dev pin <ref>`
    moves it deliberately and prints the stack diff first. A 40-char sha or a
    `v<semver>` tag; a branch is refused **before any network call**, because by
    the time a fetch has returned it has already changed under you.

  - **`KIT_STACK_OFFLINE=1` is a real mode.** It uses only `KIT_STACK_DIR`, the
    cache, or a copy vendored at `.kit/stack` — and fails loudly, naming each,
    when none holds the pin. A cached or vendored tree must RECORD its ref in
    `.kit-stack-ref`; a directory that merely contains `templates/compose/` is
    refused, because accepting one silently is how an offline loop stops matching
    what the team runs.

  - **`tests/fetch_test.sh`** — 14 assertions, executed. A pinned ref resolves and
    the fetched bytes are byte-identical to the tree; a branch, a short sha and
    an empty pin are each refused with a message that says why; offline runs from
    a cache with the remote deleted from disk, fails loudly with a cold one, and
    accepts or refuses a vendored copy by whether it declares the pin. The remote
    is a local `file://` bare repository built from this tree, so the suite needs
    no network.

  - **`tests/stack_live_test.sh`** — 15 assertions, executed, and the reason the
    packet is not "a compose file that parses". It brings the **fetched** stack up
    (all eight containers healthy), sends real OTLP, and reads a trace out of
    Tempo and a metric out of Mimir — including the `spanmetrics` connector's
    `cafaye_duration_count`, which is what the fleet dashboard is built on. The
    canary reaches no exporter, asserted as an absence against a search that first
    proved the data is there. The collector's config is checked by
    `docker inspect .Mounts`: the daemon's own record of the bind, not the host's
    idea of it and not the container's (the image is distroless).

  - **`tests/fleet_check.py`, wired into the gate as `fleet`.** Four failure
    modes, one check each: a service carrying a copy of the shared stack, a
    service that re-points the collector's config mount (the redaction allowlist,
    derived from core's schemas), an `otel-collector.yml` nothing ever mounts, and
    a pin that is a branch. It reads the **sibling repositories**, not kit's own
    files, because the defect is in the callers — the same shape as D4.
    **It is red against the current fleet and that is the deliverable**: five
    repositories carry their own copy of the shared stack, six have no pin, and
    two publish a port on a service kit already ships. The predicate is the
    image, not the service name, and the image set is read out of kit's own
    compose file rather than a hand-kept list — three of the five copies name
    their database `db` rather than `postgres`, so a name-keyed check would report
    the fleet clean while five copies stood right there.

  - **Seven breakages** (23–29), each asserting the **named** check. The five
    fleet ones run against a **fixture fleet** rather than the real one — which is
    what makes the assertion mean anything when the real fleet is red by design.
    Breakage 29 covers the `ports:` append rule and carries **no `image:`**, so
    it fires the port rule alone: a breakage that reddened two rules at once
    would not say which of them is load-bearing.


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
### Changed

- **`templates/compose/docker-compose.yml` — the vendor config mounts are anchored
  to `${KIT_COMPOSE_DIR:-.}`.** The file is no longer copied into the service, so
  a bare `./` resolves against the service, where `otel-collector.yml` no longer
  is; and Docker's answer to a missing bind source is to **create a directory**, so
  all four backends died with `read /etc/tempo/tempo.yaml: is a directory` —
  naming a file type rather than the thing that is wrong. `docker compose config`
  renders the same project either way, and every static check was green. The
  default `.` is the directory holding this file, so a hand-copied stack is
  unchanged; `bin/dev` sets the variable to the fetched tree.

- **`templates/compose/docker-compose.yml` — Grafana no longer downloads a plugin
  on first boot** (`GF_INSTALL_PLUGINS_PREINSTALL_DISABLED=true`). Grafana 11.3
  preinstalls `grafana-lokiexplore-app` and holds the sqlite lock its own
  migrations want, so a cold start took anywhere from 26s to over **180s** to
  answer `/api/health` — a network call in a dev loop, and one that made the stack
  unstartable for an air-gapped developer. Nothing kit ships uses that plugin:
  both dashboards read Loki through the provisioned datasource and the alert rules
  are PromQL. It is *configuration*, not a modification — the AGPL condition is
  about not building a `grafana/*` image. **The Grafana healthcheck budget was
  left at its shipped value**: the wrong fix, raising the retries, would have hidden
  the network dependency and left the loop unusable offline. With the cause
  removed, Grafana answers at ~26s against a 65s budget and the whole stack is up
  in 76s.

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
