# REPORT — kit-13: the observability stack ships in kit and runs in zero services

**Branch** `worker/kit-13-observe` · **Base** `41f8bcb` (master) · **Never pushed, never merged.**

---

## 0a. The finish pass: the adoption ceiling

The dispatch for this packet's second half was one sentence: *the fleet gate is
red because the fleet has not adopted; give it the adoption ceiling.* The gate
was red with **13 findings across 6 repositories**, and every single one of them
was a repository that had adopted nothing.

### What was wrong with a permanently red gate

Nothing, for about a release. Then it decays, and the decay is silent:

- A red that means the same thing every day is **not information**. The day a
  repository adopts and then breaks something new, the red is
  indistinguishable from the standing noise.
- A gate that cannot go green is a gate people learn to re-run without reading,
  which is precisely how the state this packet exists to remove survived a full
  round of CI the first time.
- The 13 findings are true and they are **nobody's agreed work**. `identity` has
  adopted and still runs its own `postgres:17-alpine` — that is a defect in a
  repository that accepted the standard. `billing` has adopted nothing and runs
  the same image — that is the cost of a fleet that has not taken it up.

So the two are separated by **who owns the debt**, not by how bad it is.

### The ceiling

| | has a `kit.ref` | has no `kit.ref` |
|---|---|---|
| stale copy | **FAIL** | **WARN** + adoption path |
| weakened redaction boundary | **FAIL** | **WARN** + adoption path |
| dead / service-owned collector config | **FAIL** | **WARN** + adoption path |
| published port in a merging file | **FAIL** | **WARN** + adoption path |
| pin absent, branch, abbreviated, empty, multi-valued | **FAIL** | **WARN** + adoption path |

**The same four checks, the same predicates, the same messages, the same
severity. Nothing was deleted and nothing was relaxed — the strictness MOVED to
where adoption exists.** It is a **wave, not a discount**: the first repository
to commit one line finds its own findings are failures, with no change to this
repository and no re-review.

> **A warning is a debt with a name. The adoption wave turns them into failures
> one repository at a time.**

The ceiling is stated in three places on purpose, because a ceiling that exists
only in an exit code is a ceiling nobody knows is there: in `fleet_check.py`'s
own output (a `CEILING fleet:` line printed on **every** run, including a clean
one), in `tests/validate.sh`'s PASS label (which carries the debt's count and
names the six repositories), and here.

### The six named repositories

| repository | findings | what they are |
|---|---|---|
| **billing** | 2 | no `kit.ref`; own `postgres:17-alpine` |
| **courier** | 2 | no `kit.ref`; own `postgres:17-alpine` |
| **darkroom** | 3 | no `kit.ref`; own `postgres:17-alpine`; **publishes `5432:5432`** on a service kit already ships |
| **guard** | 1 | no `kit.ref` only — **correctly not caught by the stale-copy rule**; it declares one service, its own, and no database |
| **identity** | 3 | no `kit.ref`; own `postgres:17-alpine`; **publishes `${POSTGRES_PORT:-5432}:5432`** |
| **muse** | 2 | no `kit.ref`; own `postgres:17-alpine` |

**13 findings, 6 repositories, and every one is currently a warning. Zero
failures.** That is the state to beat, and it is a state the gate is now *able to
leave*: the first commit of a `kit.ref` moves that repository's row.

### The adoption path, as the gate prints it

```
  the adoption path, for every repository named above:
    1. git -C ../kit rev-parse HEAD > kit.ref      # ONE committed line, and the only thing that decides which bytes of kit your machine runs
    2. your docker-compose.yml becomes an OVERRIDE beside the fetched stack, not a copy of it: delete your own postgres service and point at kit's by overriding its environment (POSTGRES_DB / POSTGRES_USER). The collector config is never yours to own.
    3. move a published port with its VARIABLE (KIT_POSTGRES_PORT=…), because a second compose file's `ports:` list is APPENDED rather than substituted, so a `ports:` block buys you both ports
```

### Three decisions inside it, each argued

**Adoption is read from `read_kit_ref` — the same function every finding message
already assumes — and only `absent` counts as unadopted.** An empty,
multi-valued or unreadable `kit.ref` is a repository that **adopted and wrote
the pin wrong**, and it fails. Reading adoption from "the file exists" is
simpler and wrong in one specific way: it would make a broken pin a *warning* in
exactly the case where somebody was trying to fix the previous warning. That is
a ratchet that turns one way, which is the failure mode `breakage 19` exists to
catch in a different file.

**Findings are collected per repository and routed once, at the end.** A check
that appended straight into the failure list would be choosing its own severity.
A check that short-circuited on an unreadable compose file would be **exempt
from the ceiling in precisely the case where the file is most wrong** — and
`muse`'s did-not-parse compose file is the reason that matters, because it is
the one time this fleet has had an unreadable stack.

**The ceiling is printed by the CHECK.** A caller that decides whether to print
the rule is a caller that can be pointed at a fixture fleet where it does not,
and the rule stops being a property of the check. It prints on every run
including a clean one, and it prints **above** the findings — a rule stated after
the thing it governs reads as an epilogue.

One wording was corrected after reading the first output: the failure summary
counted *adopting* repositories rather than *defective* ones, so
`FAIL fleet: 1 problem(s) across 2 adopting repository(ies)` described two
repositories when one was clean. A summary that overstates the blast radius is
the first thing a reader stops trusting.

### Proved from both sides, over one mutation

A ceiling with only one side proved is a deleted check. So:

| | fixture | expected | result |
|---|---|---|---|
| **breakage 30** | the stale copy, **no `kit.ref` anywhere in the fleet** | gate stays **GREEN**, finding still **PRINTED** | `PASS self_test: breakage 30: an UNADOPTED service copies the stack — green, and named` |
| **breakage 31** | the identical mutation, **`kit.ref` committed** | gate goes **RED** on the identical finding | `PASS self_test: breakage 31: the same copy in an ADOPTING service is a hard FAIL` |

**Breakage 31 is breakage 23 plus one committed line.** That single diff is the
entire argument for the ceiling, and it is why the mutation is factored into one
`break_stale_copy` helper shared by 23, 30 and 31 — two hand-written copies of a
nine-line YAML mutation would drift, and the drift would read as "31 proved the
ceiling is airtight" when 31 had stopped testing the same thing 23 tests.

Breakage 30's assertion is a **literal substring of the finding**
(`which is the image kit's stack already ships`), not the word `WARN`. A gate
that printed `WARN` and nothing else would satisfy the weaker assertion; so
would a gate that deleted the finding and left the string in a comment. That is
the assertion that catches a **removed** ceiling rather than a missing one.

`unadopt` removes `kit.ref` from **every** repository in the fixture, not just
`alpha`: the ceiling is per-repository, and a half-adopted fixture cannot tell a
failure of the unadopted side from a failure of the clean-adopting side.

Both verified directly before the suite was run, over the same mutation:

```
30  exit 0   PASS fleet  (adopting repositories clean; 3 finding(s) across 2 repository(ies) ...)
             the finding's own words present in the output
31  exit 1   FAIL fleet  (no stale copy, no weakened boundary, no dead config, every ref pinned)
```

### What the ceiling does NOT do

It does not make the fleet clean, and it does not make the checks smaller. It
does not weaken anything inside an adopting repository — that is what breakage 31
is for. And it is **not permanent**: this is the deliberate, named, temporary
state core-16 applied to a missing OpenAPI document, for the same reason and with
the same exit condition — the fleet adopts, and the debt becomes a failure
without anyone editing this repository.

---

## 0. What was inherited, and what I changed about it

The dispatch said the previous worker was killed by an OOM restart and that its
conclusions are void. Re-running its own proofs found real defects in the
recovered work, and this report says which are which rather than presenting the
branch as a clean sweep.

| Recovered artifact | State on arrival | What I did |
|---|---|---|
| `templates/bin/dev.sh` (fetch + pin) | Worked, but required `KIT_STACK_REF` in a **git-ignored `.env`** | Moved the pin to a committed `kit.ref`; reworked `pin_cmd` |
| `tests/fetch_test.sh` | Passed (14 assertions) | Re-pointed at `kit.ref`; wired into the gate |
| `tests/stack_live_test.sh` | **Failed 2 of 12** | Both failures fixed; wired into the gate |
| `tests/fleet_check.py` | **Crashed on the first repository**, never run | Fixed, scoped, de-duplicated; 13 findings against the real fleet |
| `tests/self_test.sh` breakages 23–26 | Present, unverified | Verified each, and added 27–29 |
| `tests/validate.sh` fleet wiring | Present; would have made the **self-test control go red** | Reworked the SKIP seam |

The last row matters most. The recovered wiring guarded the fleet call with its
own "are there any sibling entries?" predicate. A self-test throwaway directory
*has* sibling entries — one per breakage — and none is a repository. So the
control ran the check, the check exited 2, and **D13 would have blocked the
packet** for a reason unrelated to it.

---

## 1. The fetch mechanism, and its pinning

### The ruling, kept

A compose file cannot be `uses:`-ed, so the live path is `bin/dev` itself. It
fetches `templates/compose/` from a pinned kit ref and runs it *beside* the
service's own `docker-compose.yml`.

```
docker compose --project-directory . \
  -f "$CACHE/$REF/templates/compose/docker-compose.yml" \
  -f ./docker-compose.yml up -d --wait
```

The service's file is the **second** one, so it is an override. `--project-directory .`
is not tidiness: compose resolves a relative path in a `-f` file against the
*first* file's directory, and the first file is now in a cache directory outside
the repository — so a service's `build: context: .` would otherwise build from
kit's tree, producing an image and therefore no complaint.

### The four sources, in this order

1. `KIT_STACK_DIR` — a checkout named on this run. Highest precedence, ref not
   checked, because naming a directory is a person saying "this one" and it is
   the case a kit contributor runs.
2. `<KIT_STACK_HOME>/<ref>` — the per-ref cache.
3. `.kit/stack` — a vendored copy, **which must record its ref** in
   `.kit-stack-ref`.
4. A fetch. The only source that touches the network.

Sources 2 and 3 are checked *against the ref*, and that is the load-bearing
detail: a directory that merely contains `templates/compose/` is not a kit
checkout at a known version. A mismatched record is a refusal; a missing record
is a refusal; only a matching one is used.

### The fetch itself

`git init` + `remote add origin <url>` + `git fetch --depth 1 origin <ref>` +
`git checkout --detach FETCH_HEAD`, then `.kit-stack-ref` is written, and the
whole thing is built as `<dest>.tmp.$$` and `mv`'d into place. Not
`git clone --branch`, because `--branch` takes a branch or a tag and **cannot
take a commit sha** — so cloning cannot express the stricter of the two pin
forms. The `mv` is atomic, so a second `bin/dev` in another terminal never sees
a half-populated cache directory.

### Pinning, and how a developer moves it

`KIT_STACK_REF` must be a **40-character lowercase-hex commit sha**, or a
**`v<MAJOR>.<MINOR>.<PATCH>` tag** with semver's optional pre-release/build
suffix. `bin/dev` refuses anything else **before any network call**. The check
is `case`, not `[[ =~ ]]`, on purpose: it runs before any tooling beyond POSIX
shell has been located.

**The pin lives in `kit.ref`, one committed line at the service root.** Not in
`.env`. `.env` is git-ignored, so a pin kept there exists on exactly one
machine — the laptop of whoever ran the command last — and on no CI runner and
no teammate's checkout. "One command, always current" would then resolve to
"one command, whatever this checkout last fetched", which is the opposite of
what a pin is for. In `kit.ref` the bump is a line in `git diff`.

`bin/dev pin <ref>` moves it, and prints the stack diff **first** — a
`diff -rq` of `templates/compose` between the two trees, fetching both sides if
neither is on the machine, because a first `bin/dev pin` is the use most likely
to *be* the upgrade and it was the one case that could not print a diff.

---

## 2. Offline mode, and how it was tested

`KIT_STACK_OFFLINE=1` skips source 4 and **fails loudly**, naming each of 1–3,
if none holds the pinned ref. It never falls back to whatever is in the working
directory: *"the stack came up"* is a claim, and a claim about **which bytes**
is the entire point.

`tests/fleet_check.py`'s sibling proof is `tests/fetch_test.sh`, which runs
against a **bare repository built from this tree over `file://`** — the same
`git fetch --depth 1 <remote> <ref>` command, no network, so CI and a laptop on
a train get the same answer. Executed, **17 assertions, every one run**:

| # | Assertion | Result |
|---|---|---|
| 1 | a pinned commit resolves, and says **where** it resolved to | PASS |
| 2 | the fetched compose file is **byte-identical** to the tree it was pinned to | PASS |
| 3 | the fetched tree carries the collector config and the vendor config trees | PASS |
| 4 | a `v<semver>` tag resolves to the same bytes a commit does | PASS |
| 5 | `v1.0.0-rc.1` is accepted — semver's own grammar admits it, and a rule that refused it would be routed around by writing `master` | PASS |
| 6 | `master` refused, **and the message says why** | PASS |
| 7 | a real branch name refused, same | PASS |
| 8 | an empty ref refused (the fresh-clone case) | PASS |
| 9 | a 7-char abbreviated sha refused — ambiguous across remotes | PASS |
| 10 | **offline with a warm cache runs with the remote `mv`'d away**, and says it came from the cache | PASS |
| 11 | **offline with a cold cache and no remote fails**, and names `KIT_STACK_DIR`, `.kit/stack` or `KIT_STACK_HOME` | PASS |
| 12 | a **vendored** copy declaring the pinned ref is accepted, and is named as the source | PASS |
| 13 | a vendored copy at a **different** ref is refused | PASS |
| 14 | `bin/dev pin` **fetches both refs and prints a real diff from a cold cache** | PASS |
| 15 | the sha it writes is the last line of `kit.ref` | PASS |
| 16 | the comment header is **one `#` per line** — asserted on shape, not wording | PASS |
| 17 | pinning to the ref already pinned is a **no-op, and says so** | PASS |

The strongest of these is #10: the remote is not unset, it is **moved**, so a URL
that 404s (a different failure) cannot stand in for a URL that is not consulted.

**Not verified:** `git fetch --depth 1 <https-url> <sha>` against a real GitHub
remote. Everything above is `file://`. It is one `git ls-remote` away, and a gate
that depends on github.com is a gate that goes red when github is down.

---

## 3. What stays in the service — measured, on `identity`

`identity` was chosen because it is the service that *has* to override kit's
`postgres` to have its own database, so the residue is non-trivial rather than
a demonstration that deleting lines is easy.

**Before — 52 lines, 1683 bytes.** `services: postgres:` (image, environment,
ports, volumes, healthcheck), `services: identity:` (build, environment, ports,
depends_on), and a top-level `volumes: postgres-data:`.

**After — 29 lines, 899 bytes.** A 47% reduction. What the service's file
contains is its own image, its own port, its own environment, its own volume if
it needs one, and its own service entry. What it no longer contains:

| Dropped from the service file | Because |
|---|---|
| `postgres.image` | kit ships it, pinned |
| `postgres.ports` | a `ports:` list in a second file **appends** — see §4 |
| `postgres.volumes` | kit's `postgres-data` is the one that gets migrated |
| `postgres.healthcheck` | kit's, and kit's is now a real query (§8.1) |
| top-level `volumes: postgres-data:` | kit declares it |

What is left, and the whole of it:

```yaml
services:
  postgres:                 # kit's service, overridden — NOT a second one
    environment:
      POSTGRES_USER: identity
      POSTGRES_PASSWORD: identity
      POSTGRES_DB: identity

  identity:
    build: { context: ., args: { GO_VERSION: "1.26" } }
    environment: { PORT: "8080", LOG_LEVEL: debug, DATABASE_URL: … }
    ports: ["8080:8080"]
    depends_on: { postgres: { condition: service_healthy } }
```

**The merged project was rendered, not assumed.** `docker compose --project-directory . -f <kit> -f ./docker-compose.yml config`
produced nine services (grafana, identity, loki, mimir, nats, otel-collector,
postgres, redis, tempo), six volumes, and a `postgres` whose environment is
`identity` while its healthcheck names `$POSTGRES_USER`/`$POSTGRES_DB`.

---

## 4. Override semantics

The merge is per-key and **not symmetric**. Every rule below was measured
against `docker compose config` rather than inferred.

| | Rule | Why |
|---|---|---|
| MAY | set `image:` on a kit service | a different postgres major is a real need |
| MAY | add to `environment:` | a per-service database name is the case that matters |
| MAY | add `depends_on: {…, condition: service_healthy}` | |
| MAY | **change a published port — only through the variable in `.env`** | a `ports:` list in the second file **appends**, so `ports: ["15433:5432"]` yields postgres on 15500 **and** 15433 |
| MAY NOT | override `otel-collector` — not `volumes:`, `command:`, `image:`, `build:` | that mount carries the redaction allowlist, **derived from core's schemas**; a service that re-points it ships a boundary nobody derived |
| MAY NOT | `build:` or retag `tempo`/`loki`/`mimir`/`grafana` | AGPL-3.0's condition is unmodified distribution; a `build:` is a fork |
| MAY NOT | set `allow_all_keys`, or add an exporter, by any route | same reason; same check that already fails on kit's own file |

The `ports:` rule was the one the shipped documentation promised and the gate
did not implement. It is implemented now, and breakage 29 proves it. **It fires
on the real fleet: `darkroom` and `identity`**, the two that name their service
`postgres:` *and* publish a port on it.

---

## 5. The gates

Four failure modes, one check each, in `tests/fleet_check.py`, plus two
kit-side checks. Every one is **proven able to fail** (§6).

### 5.1 Which repositories the stale-compose check catches

Scope is by **declaration**: a repository is checked when it has a root compose
file or a root collector config. `core` and `docs` will never run a stack;
`parlor/e2e/docker-compose.yml` is a harness, not a developer's loop. The
out-of-scope count is **printed**, never dropped.

> **6 repositories in scope, 9 out of scope: billing, courier, darkroom,
> guard, identity, muse.**

| Rule | Count | Which |
|---|---|---|
| **stale copy** — runs an image kit already ships | **5** | billing, courier, darkroom, identity, muse |
| **no pin, or a pin that moves** | **6** | all six |
| **a published port on a kit service** | **2** | darkroom, identity |
| unreadable compose file | 0 | nobody |
| weakened boundary | 0 | nobody |
| dead / service-owned collector config | 0 | nobody |

**13 findings, 6 repositories.** Under the adoption ceiling (§0a) every one of
them is currently a **warning**, because every one of those six repositories has
no `kit.ref` — so the gate is **0 failures and 13 named debts**, and the debt
count is printed in the gate's own summary line rather than buried here. The
checks are unchanged and the fleet is unmigrated; what changed is that the gate
is now red about a repository that has *accepted* the standard, and merely loud
about one that has not.

That is the difference between this run and the run the dispatch handed me, and
it is worth being precise about, because "the fleet gate went green" is the
sentence that would be written by somebody skimming: **the gate went green
without any finding being deleted, and the findings are all still there.** The
first repository to commit `git -C ../kit rev-parse HEAD > kit.ref` puts two or
three of them back into FAIL.

Three details worth stating:

- **The stale-copy check keys on the IMAGE, not the service name.** Three of the
  five call their database `db`, not `postgres`. A name-based check reports the
  fleet clean while every copy of the platform stands right there — and that is
  what the recovered version did.
- **`muse` was unreadable, and this is the whole argument for the gate in one
  example.** When the numbers above were first measured, muse's
  `docker-compose.yml` **did not parse at all**: line 65 put a `: ` inside an
  unquoted YAML scalar,
  `MUSE_VAULT_KEY: ${MUSE_VAULT_KEY:?set MUSE_VAULT_KEY, or run: uv run python -m muse.vault}`,
  and both parsers agreed — `docker compose config` exited 1, PyYAML raised
  `ScannerError`. **That stack could not start**, and nothing in kit could have
  found it, because nothing in kit read the fleet.

  It was fixed by muse's own packet (`muse-08`, which moved muse to Postgres 17),
  and this gate reported it as a finding first. Muse is now caught by the
  stale-copy rule instead — the same repository, one rule further along, which is
  what "the gate reads the callers" buys. **The finding is recorded rather than
  deleted** because the sequence is the evidence: a check that reads other
  repositories found a stack that could not boot, and the fix came from the
  repository that owned it.
- **`guard` is correctly NOT caught by the stale-copy rule.** It declares one
  service, its own, and no database. A gate that flagged it would be flagging a
  repository for being correct. It is caught by the pin rule, because it has no
  `kit.ref`.

### 5.2 Gate results, reported separately

**Pass, skip and bound counted separately, because conflating them is how a gap
survives.** They are three different claims: a verdict about the tree, a verdict
about the environment, and a verdict about the run.

| Run | PASS | FAIL | SKIP | BOUND |
|---|---|---|---|---|
| `tests/validate.sh --static-only` | **140** | **0** | **2** | **0** |
| `tests/validate.sh` (everything, self-test included) | **153** | **0** | **2** | **0** |

**The full run is the one that matters and the one the earlier partial runs were
not.** The dispatch handed me a run that died with exit 137 partway through the
observability collector tier; the run in the row above **reached the end**,
printed `PASS: every check passed.`, and exercised every tier:

| Phase | Result |
|---|---|
| static (artifacts, YAML, shellcheck, hadolint, compose, fleet, core, tiers) | green |
| telemetry — six W3C suites, executed | green |
| observability — the redaction boundary against a real collector | green |
| readiness — a service with a dead dependency and a dead OTLP endpoint | green |
| `stack_live_test.sh` — the fetched stack, **all 15** | green |
| `fetch_test.sh` — **all 17** | green |
| `classify_test.sh` (19) · `staleness_test.sh` (12) | green |
| `self_test.sh` — **32 breakages (31 red, 1 green-expecting), unbroken tree green** | green |

**What the full uninterrupted run showed that the partial runs did not** — the
question the dispatch actually asked:

1. **It reached the tiers the killed run never got to.** The exit-137 run had
   142 PASS lines and died in the observability collector tier. This run has
   **153** and printed a verdict, so the fetch tier, the staleness tier and the
   entire self-test are now *measured* rather than inferred.
2. **The self-test's self-test ran.** `self_test_claims` — the check that
   compares the header's breakage list against the recipes the file carries — is
   inside the `RUN_SELF_TEST` block, so it had never executed in any partial run
   this branch produced. It is green, which is the check saying the two halves
   of `self_test.sh` cannot have drifted apart.
3. **Two breakages exist that no previous run had.** 30 and 31 are the adoption
   ceiling's two sides; a run that stops before the self-test proves neither, and
   in particular cannot distinguish "the ceiling holds" from "the checks are
   gone".
4. **The gate can finish on this machine**, which the exit-137 run said it could
   not. That turned out to be true and was about contention rather than about
   size — but it is not a claim anyone could make from a killed log, which is
   why the bounds in §5.3 exist at all.
5. **No tier was skipped.** Two SKIPs, the same two `node --check` TypeScript
   files, unchanged by this pass. Nothing new was skipped and nothing was
   un-skipped.

**The two SKIPs are the two known-correct ones on master**, unchanged by this
packet: `templates/tier/bun/tier.test.ts` and `templates/tier/node/tier.test.ts`,
both because `node --check` cannot read TypeScript. **This change adds no skip
and removes none** — the count is 2 before and 2 after, and they are the same
two files.

Where a skip is unavoidable — no fleet, as on a CI runner — it is reported as a
SKIP with the `FLEET-ABSENT` marker, because "no fleet was found" is not "the
fleet is clean". That is the same `unknown` vs `current` confusion
`tests/staleness.py` exists to avoid.

### 5.3 The bound: the tier that was killed, and the verdict for a tier that times out

The run I inherited **died with exit 137** — the kernel's OOM killer, not a test
failure — partway through the observability collector tier. Exit 137 means the
gate reported **nothing** about every tier it never reached, so its 142 PASS
lines were a claim about how far it got rather than a verdict on the tree. That
is a worse failure than a red gate, because it looks like a pass in a log.

Four tiers now carry a time bound, and a bound is **its own verdict**:

| verdict | about | meaning |
|---|---|---|
| `PASS` / `FAIL` | the tree | as before |
| `SKIP` | the **environment** | no docker, no toolchain — nothing ran |
| **`BOUND`** | **the run** | the tier started, this box was too busy to finish it, and the claim it exists to prove is **unexercised** |

| tier | bound | quiet-machine cost |
|---|---|---|
| `tests/canary_test.sh` | 900s | ~1 min |
| `tests/no_telemetry_in_readiness.sh` | 900s | ~2 min |
| `tests/stack_live_test.sh` | 900s | ~2 min |
| `tests/self_test.sh` | 5400s | ~25 min (32 whole gates in sequence) |

**Why `BOUND` and not one of the two verdicts that already exist.** A bound
reported as a PASS is the silent skip this repository's own rules forbid — it is
the `SKIP` case that does not announce itself, which is the one shape of skip
that survives. A bound reported as a FAIL is worse in a different way: it puts a
loaded machine into the same bucket as a defect in the tree, and the reader who
goes looking for a defect that is not there stops reading the summary line at
all. So it carries the tier, the bound, and the tail of what it had printed, and
the summary states **how many tiers ran under a bound** and **how many reached
one** — two counters, because one line cannot say both, and the first version of
this used one counter for both and printed "4 tier(s) hit their time bound" for a
run in which exactly one did.

**`timeout` is resolved, not assumed.** GNU coreutils ships `timeout`; macOS has
no `/usr/bin/timeout` at all; Homebrew's coreutils installs `gtimeout`. A
machine with neither runs the tier unbounded and says so, because a bound that
silently did not apply is worse than no bound — the reader is told a ceiling
exists and there is not one. `--kill-after=30s`, because a bound that is only a
SIGTERM is a request.

**On this run, no bound was reached** — `BOUND` is 0 and the summary says
`4 tier(s) ran under a time bound; none was reached`. That line is printed
*because* none was reached. A ceiling the reader has never been told about is a
ceiling they cannot rely on, and a bound report that only appears when it fires
is indistinguishable, from the outside, from not having one.

---

## 6. Every gate proven able to fail

`tests/self_test.sh` breaks a throwaway copy once per check and asserts it goes
red. **Thirty-two breakages: thirty-one red, one green-expecting.**
**Sixteen assert the NAMED check**, because "the gate went red" is a weak claim
when a hundred checks can make it red.

**One does not assert red at all**, and that is the load-bearing one for this
pass: **breakage 30 asserts the gate stays GREEN while still printing the
finding** (§0a). A suite made only of red-expecting recipes cannot tell a ceiling
from a deletion — every one of them would still pass if the whole fleet check
had been reduced to printing the word `WARN`.

Breakages **23–26** are the four failure modes, each against a **fixture
fleet**. That is not a convenience: the real fleet's findings are warnings, so
"the gate went red" there would have to be distinguished from the ceiling, and a
fixture fleet is what makes the distinction unnecessary. Each fixture is two
repositories, `alpha` (correct) and `beta` (correct), and the breakage mutates
only `alpha` — so a check that only ever looks at the first repository is caught,
and a check that reported *everything* as broken would fail the control.

| # | Mutation | Caught by |
|---|---|---|
| 23 | `alpha` gains a second `postgres:17` of its own | `fleet` |
| 24 | the collector's config mount re-pointed at a service-owned file | `fleet` |
| 25 | an `otel-collector.yml` nothing mounts | `fleet` |
| 26 | `kit.ref` holding `master` | `fleet` |
| 27 | `${KIT_COMPOSE_DIR:-.}/tempo/tempo.yaml` → `./tempo/tempo.yaml` | `every vendor config mounts from the fetched tree` |
| 28 | `KIT_STACK_REF=<sha>` added to `.env.example` (and `kit.ref` removed, which is a no-op on kit's own root — the pin belongs to the adopting service) | `the pin is kit.ref, and the gate reads the same file` |
| 29 | `alpha` publishes a port on `postgres`, which kit already ships | `fleet` |
| 30 | the same stale copy, **with every `kit.ref` removed** | **must stay GREEN** and print the finding — the ceiling |
| 31 | that same mutation, **`kit.ref` committed** | `fleet` — the same finding, back to a hard FAIL |

Breakages 30 and 31 are argued in full in §0a, because they are the only two
recipes in this file that are about the **gate's policy** rather than about a
defect in a repository — and a policy proved from one side is not proved.

Breakage 28's shape is the one that reads like an improvement: shipping
`KIT_STACK_REF=<sha>` in `.env.example` means a fresh clone looks configured and
needs no setup. It also puts the pin in a file that becomes `.env`, which is
git-ignored, so it **decides nothing** in CI and nothing on anyone else's
checkout — `bin/dev` reads `KIT_STACK_REF` from the environment only, as a one-run
override. A gate that asked "is the pin pinned?" would still be green; it has to
ask **where the pin lives**, which is a different question and a different check.

Breakage 29 deliberately omits `image:`, so it fires the ports rule alone and
the stale-copy rule stays quiet: a breakage that reddened both would not say
which of the two is load-bearing.

---

## 7. It runs

`tests/stack_live_test.sh` is in the gate's observability phase, not on a shelf.
Measured, in this gate run:

- `bin/dev` fetched kit at the pinned ref from a local bare remote and brought
  up **eight containers**, all healthy, `--wait`, no sleeps.
- The collector's config mount was read back with **`docker inspect`** — the
  daemon's own record of the bind, which is the only one of the three possible
  answers that cannot be a self-report — and diffed against the fetched file.
- A trace was sent, and **found in Tempo**; `error.type` survived the boundary.
- A metric was sent, and **found in Mimir**; and the `spanmetrics` connector
  minted `cafaye_duration_count`, which is the fleet error dashboard's source.
- A canary in ten attributes reached **neither** store.

**All 15 assertions, in one gate run, with no sleeps and no retries.** That
count matters here more than usual: the postgres healthcheck was rewritten in
this same packet (§8.1), and a probe that is now a real `psql` query rather than
a `pg_isready` with unused flags could easily have broken the readiness the whole
stack waits on. It did not — `postgres` reported healthy, `--wait` returned, and
the eight containers came up on the shipped `6 × 5s + 10s` budget.

Two assertions in this file failed on my first run and both were **test** bugs,
not stack bugs:

1. `probe` (the test's own curl container) has no healthcheck, so
   `{{.Health}}` is empty, and `grep -v ' healthy$'` read that as unhealthy.
2. The collector image is distroless, so `docker compose exec … cat` fails — and
   the test compared compose's **error string** against the config and reported
   that the boundary was not the fetched one. *The error string was the
   evidence.*

A third defect the same work exposed, and the one that started this report's
worst thread: `STACK_NAME="kit-stack-$PROJECT"` while `PROJECT="kit-stack-$$"`,
so every `docker compose -p "$PROJECT"` in the file addressed a project the
test had not created. One name, now.

---

## 8. Two defects found by measuring what the packet asked me to measure

### 8.1 The postgres probe was a decoration

Rendering `identity`'s merge showed a container initialised as `identity` and
health-checked as `cafaye`, because kit's probe interpolated
`${KIT_POSTGRES_USER:-cafaye}` at **compose render time**. I wrote that up as
"never becomes healthy, so `up --wait` fails".

**Then I ran it, and it reported healthy.** Measuring instead of asserting is
what caught it:

```
$ pg_isready -U identity -d nosuchdb -q ; echo $?
0
$ psql -U identity -d nosuchdb -tAc 'select 1' >/dev/null ; echo $?
2
```

`pg_isready` reports whether the server is **accepting connections**. Its `-U`
and `-d` do not authenticate and do not select — they are diagnostics, and the
readiness answer is 0 either way. So the pair kit shipped bought nothing, and
the comment above it — *"`pg_isready` alone returns true before the init scripts
finish … The -U/-d pair makes it check the real thing"* — was asserting a
strengthening that does not exist. The probe had been reporting postgres ready
on a container whose named database did not exist: the precise flake the comment
says it exists to prevent.

The probe is now a real query against the database the container actually has:

```yaml
healthcheck:
  test:
    - CMD-SHELL
    - pg_isready -q -U "$$POSTGRES_USER" -d "$$POSTGRES_DB" &&
      psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB" -tAc 'select 1' >/dev/null
```

`$$` because compose interpolates `$VAR` **before YAML is parsed**, so quoting
does not protect it. Two wrong answers on the way there, both caught by rendering
rather than reading; the second was `\$`, which is not a valid escape in a YAML
double-quoted scalar and made PyYAML reject the whole file. **A value three
parsers read is worth rendering three times.**

All three forms rendered here, against a service that renames its database to
`identity` — `docker compose config`, so this is the daemon's own answer and not
a reading of the file:

| written in the compose file | rendered, for a service whose database is `identity` |
|---|---|
| `pg_isready -U "$POSTGRES_USER"` | `-U "" -d ""` — nothing outside a container sets it |
| `pg_isready -U "${KIT_POSTGRES_USER:-cafaye}"` | `-U cafaye -d cafaye_platform` — kit's defaults, inside *someone else's* container |
| `pg_isready -U "$$POSTGRES_USER"` | `$$POSTGRES_USER` in `config` output, which is compose re-escaping the single literal `$` it will hand the container |

The middle row is the shipped defect: no error, no empty string, a green
container and the wrong database. `config` re-escapes on output precisely so its
result can be fed back in as a compose file, which is why the third row reads
`$$` and not `$`.

Measured on a **cold volume** with a service that renames its database:
**healthy in 16s**, and `psql` inside the container confirms it checked
`identity`, not kit's `cafaye_platform`.

### 8.2 `bin/dev pin` wrote a broken `kit.ref`

Running it produced `# …a 40-character commit# sha, or a v<semver> tag…` — three
comment lines run together by a missing newline in the `printf`. Found by
running the command and reading the file it wrote, which is the only way.

### 8.3 `FAIL templates/otel/ruby` — not this packet, re-attributed on a clean clone

The dispatch listed two FAILs. One was mine (§0a). The second was
`FAIL templates/otel/ruby (ruby test suite)`, which kit-14 attributed as H1 and
which the dispatch told me to attribute in writing again. Doing that again, and
**reproducing it rather than inheriting the attribution:**

```
$ /usr/bin/ruby templates/otel/ruby/test_traceparent.rb
13 runs, 1370 assertions, 0 failures, 3 errors, 0 skips
   NoMethodError: undefined method `filter_map' for #<Array:…>
     traceparent.rb:278:in 'usable_tracestate_entries'
```

Three errors, one cause: `traceparent.rb` calls `Array#filter_map`, which is
Ruby 2.7+. `/usr/bin/ruby` on this machine is **2.6.10**; the pinned toolchain
(**4.0.1**, behind a mise shim) passes the same suite **13 runs, 1407 assertions,
0 failures, 0 errors**.

Reproduced on a clean clone, because the attribution is only worth anything if it
does not depend on this branch:

```
$ git clone … && git checkout 41f8bcb        # master's own commit
$ git diff --stat 41f8bcb -- templates/otel/ruby   # (empty — byte-identical to master)
$ /usr/bin/ruby templates/otel/ruby/test_traceparent.rb
13 runs, 1370 assertions, 0 failures, 3 errors, 0 skips
```

**Master's own files, master's own commit, no work of mine present — same three
errors.** The template is correct; the interpreter is not.

And reproduced *through this branch's gate*, with the shim directory off `PATH`
so the system interpreter wins:

```
$ PATH=/usr/bin:/bin:/usr/sbin:/sbin bash tests/validate.sh --no-self-test --no-observability
FAIL templates/otel/ruby  (ruby test suite)
```

which is exactly what the manager's run saw, and is why the run I did on this
machine shows ruby **green**: `ruby` here resolves to the 4.0.1 shim.

**So it is not reproduced by the standard invocation, it is reproduced by an
old interpreter, and it is not mine.** kit-14 owns the fix — a toolchain floor
consulted before the suite runs, since ruby is the one language where an old
toolchain makes the suite **run and lie** rather than refusing to parse
(`go.mod` refuses go, `rustc --edition` refuses rust, `from __future__` refuses
python). I have not taken that fix: it is kit-14's file to change, and two
packets editing one gate is how each half can be wrong.

---

## 9. What I could not verify

1. **The network fetch path.** Every fetch here is `file://`. `git fetch
   --depth 1 <https-url> <sha>` against github.com is untested.
2. **No service was migrated.** The brief forbids touching other repositories, so
   the before/after in §3 was measured on a throwaway sandbox holding
   `identity`'s real compose file — not by landing a PR. The adoption path is
   proven; the fleet is unmigrated.
3. **Whether the fleet's shape holds as the other packets land.** The numbers in
   §5.1 are measured, and they moved while this report was written: muse's
   `docker-compose.yml` did not parse when the gate was first run and parses now,
   because muse's own packet fixed it. A gate that reads other repositories is
   reading repositories that are **actively being edited by other workers**, so
   this report states a measurement and its moment rather than a property of the
   fleet. Re-running `tests/fleet_check.py` is the only way to know the current
   answer.
4. **That the bounds in §5.3 are the right numbers.** They are ~3x the durations
   measured on *this* machine, which is evidence and not proof: no bound was
   reached on this run, so nothing here demonstrates that 900s is enough for a
   slower box. What it does demonstrate is that a bound that is reached is
   **reported as its own verdict** rather than killing the run, which was the
   actual failure.
5. **`kit.ref` against a real GitHub remote**, including whether GitHub serves a
   `--depth 1` fetch of an arbitrary sha without `uploadpack.allowReachableSHA1InWant`.
6. **Nothing was rebased.** Master was still `41f8bcb`, this branch's base, when
   I finished; the dispatch told me not to rebase or merge it myself.
7. **Whether the ruby failure will be seen again.** §8.3 reproduces it only with
   an old interpreter on `PATH`. On the documented invocation, with the pinned
   toolchain, it does not occur — which means the manager's run and mine disagree
   about the same tree, and the disagreement is `PATH`, not code. kit-14's floor
   is the durable answer and it is not mine to land.

---

## 10. A note on the environment

The machine OOM'd once already, killing the previous worker mid-run, and it was
oversubscribed for most of this one (load average above 100 at times, eight
concurrent `opencode run` processes). Two things came out of that which look like
defects and are not, and both are recorded because the next reader will hit them:

- The self-test's **control** failed once with
  `cd: /tmp/kit-self-test.XXXX/base: No such file or directory` — not a red gate
  but a **vanished throwaway tree**, with every worker `mktemp`-ing under one
  shared `TMPDIR`. `expect_green` used to run the gate a *second* time to print
  its diagnostic, which is a second chance to lose the tree, and it lost it on
  exactly the run where the diagnosis mattered — so the reported failure was a
  diagnosis of the diagnostic. One run, captured. And a missing tree is now
  reported as the environment failure it is, distinct from a red gate.
- Under that pressure the whole suite was eventually run to completion on an idle
  machine: **32 breakages — 31 red, 1 green-expecting while naming its finding —
  unbroken tree green, exit 0**. The claims in §6 do not rest on partial runs.
- The self-test was `SIGTERM`ed mid-run on memory pressure twice before this.
  It was then run to completion on an idle machine, so the partial-run caveat is
  retired rather than argued around.
- **This pass inherited an exit-137 run and did not reproduce it.** The manager's
  run died inside the observability collector tier with 142 PASS lines and no
  verdict. The full run here reached the end: **153 PASS, 0 FAIL, 2 SKIP,
  0 BOUND**, `PASS: every check passed.` — on a machine with load average 3–5
  and, at the time, four other packets' workers live. So the kill was
  contention, not size, and the gate finishes. The bounds in §5.3 are still
  there, because "it finished once here" is not a property of a gate that has to
  finish on a box running eight workers.
- **The `timeout` resolution is a real portability question on this machine, not
  a hypothetical one.** `/usr/bin/timeout` does not exist on macOS; `timeout` here
  comes from Homebrew's coreutils, and the same package installs `gtimeout`.
  Writing `timeout` into the gate unguarded would have made it work on exactly
  the machine it was written on and fail on a clean CI runner — the same class of
  defect as this packet's own port rule.

**Isolation, verified directly and separately.** Each of the seven new breakages
was run against the real gate with a fresh throwaway copy each, because a suite
that only passes when run in sequence has proved less than it appears to:

- **23, 24, 25, 26, 29, 31** — `expect_red_check` against a **fixture fleet**.
  All six went red via the named `fleet` check, and a clean fixture fleet left
  the gate green, which is the control that makes the other six mean anything.
- **30** — `expect_green_check` against a fixture fleet with **no `kit.ref` in
  it**. Verified directly against the real gate before the suite ran, not only
  inside it: exit 0, the `PASS fleet (adopting repositories clean; 3 finding(s)
  across 2 repository(ies) …)` label, and the finding's own sentence present in
  the output. All three are asserted — a green run that named nothing, or a named
  finding under a check that did not report PASS, each fail this recipe
  separately.
- **27 and 28** — the two kit-side checks, each mutation applied to a tree with
  everything else held constant:

  | tree | `stack_mount_check` | `pin_contract_check` |
  |---|---|---|
  | unbroken | PASS | PASS |
  | breakage 27 (mount reverted to `./`) | **FAIL** | PASS |
  | breakage 28 (`KIT_STACK_REF=` back in `.env.example`) | PASS | **FAIL** |

  Each mutation is caught by its own check and **not** by the other, which is
  the discipline `expect_red_check` exists to enforce.

**30 and 31 share one mutation on purpose**, and that is the one isolation
caveat worth stating plainly: they are not independent fixtures, they are the
same fixture with one file changed. That is deliberate — the claim is that the
*only* difference between a warning and a failure is a committed `kit.ref`, and a
claim like that cannot be proved by two different fixtures, only by two states of
one. The cost is that a defect in `break_stale_copy` would move both recipes
together, which is why the helper is a single definition and why breakage 23
(the fixture's own red proof) runs the same mutation: if the helper broke, 23 goes
green first and says so.

### 10.1 The defect that fix found

Running the fleet breakages **in sequence** is what exposed a bug in the
recovered recipes. `fixture_fleet` built `$WORK/fleet-<name>/{alpha,beta}` with a
`.git` in each, and `fresh_copy` built `$WORK/<name>`. So every
`expect_red_check` ran a gate whose fleet question — `$ROOT/..` — was **every
fixture an earlier breakage had built, including breakage 23's still-broken
`alpha`**. Breakages 24, 25 and 26 assert `FAIL fleet` and would have matched it
whether or not the mutation they applied was the defect they name: **three proofs
asserting nothing**, from a directory one level too high.

Fixed by giving each a directory of its own — `$WORK/copies/<name>` and
`$WORK/fixtures/<name>` — so a copy's parent holds exactly one entry, itself, and
that entry has no `.git`. `beta` exists for the same reason from the other side:
a check that only ever reads the first repository of a fleet is a check that has
not been tested.

There is a second, quieter instance of this shape that the fix does **not**
address, and it is worth naming because the same reasoning applies elsewhere: the
fleet breakages all mutate `alpha` and assert against `$base`, which is the
control copy. That is deliberate — a breakage must never touch the tree the next
breakage reads — but it means 23–26 and 29 prove five mutations of one fixture,
not five independent fixtures.