# REPORT — kit-13: the observability stack ships in kit and runs in zero services

**Branch** `worker/kit-13-observe` · **Base** `41f8bcb` (master) · **Never pushed, never merged.**

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
| **stale copy** — runs an image kit already ships | **4** | billing, courier, darkroom, identity |
| **no pin, or a pin that moves** | **6** | all six |
| **a published port on a kit service** | **2** | darkroom, identity |
| **unreadable compose file** | **1** | muse |
| weakened boundary | 0 | nobody |
| dead / service-owned collector config | 0 | nobody |

**13 findings, 6 repositories. It is red, and it stays red.** The first gate in
the packet's list is red against the current fleet, and softening it to make
master green is exactly what the packet refuses.

Three details worth stating:

- **The stale-copy check keys on the IMAGE, not the service name.** Five of the
  six call their database `db`, not `postgres`. A name-based check reports the
  fleet clean while every copy of the platform stands right there — and that is
  what the recovered version did.
- **muse is counted as carrying a copy, but its file cannot be read to tell.**
  Its `docker-compose.yml` **does not parse**. Line 65 puts a `: ` inside an
  unquoted YAML scalar:
  `MUSE_VAULT_KEY: ${MUSE_VAULT_KEY:?set MUSE_VAULT_KEY, or run: uv run python -m muse.vault}`.
  Verified by two independent parsers — `docker compose config` exits 1, and
  PyYAML raises `ScannerError`. **That stack cannot start at all**, and no check
  in kit could have found it, because nothing in kit reads the fleet. That is
  the argument for this gate existing, in one example.
- **`guard` is correctly NOT caught by the stale-copy rule.** It declares one
  service, its own, and no database. A gate that flagged it would be flagging a
  repository for being correct. It is caught by the pin rule, because it has no
  `kit.ref`.

### 5.2 Gate results, reported separately

| Phase | PASS | FAIL | SKIP |
|---|---|---|---|
| `tests/validate.sh --static-only` | **138** | **1** | **2** |

The single FAIL is `fleet (no stale copy, no weakened boundary, no dead config,
every ref pinned)`, by design. The two SKIPs are the two known-correct ones on
master — `templates/tier/bun/tier.test.ts` and `templates/tier/node/tier.test.ts`,
both because `node --check` cannot read TypeScript. **My change adds no skip
and removes none.**

Where a skip is unavoidable — no fleet, as on a CI runner — it is reported as a
SKIP with the `FLEET-ABSENT` marker, because "no fleet was found" is not "the
fleet is clean". That is the same `unknown` vs `current` confusion
`tests/staleness.py` exists to avoid.

---

## 6. Every gate proven able to fail

`tests/self_test.sh` breaks a throwaway copy once per check and asserts it goes
red. **Fifteen of the 29 assert the NAMED check**, because "the gate went red" is
a weak claim when a hundred checks can make it red.

Breakages **23–26** are the four failure modes, each against a **fixture
fleet**. That is not a convenience: the real fleet is red by design, so "the
gate went red" there is satisfied by two clean repositories. Each fixture is two
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

---

## 9. What I could not verify

1. **The network fetch path.** Every fetch here is `file://`. `git fetch
   --depth 1 <https-url> <sha>` against github.com is untested.
2. **No service was migrated.** The brief forbids touching other repositories, so
   the before/after in §3 was measured on a throwaway sandbox holding
   `identity`'s real compose file — not by landing a PR. The adoption path is
   proven; the fleet is unmigrated.
3. **`muse` could not be checked for a stale copy**, only for being unreadable.
   Its findings are 2 of 13 for that reason, not because it is cleaner.
4. **A single uninterrupted `tests/self_test.sh` run on this machine.** The box
   is running eight concurrent workers at a load average above 100, and the
   self-test — 29 breakages plus a control, each a nested gate — was `SIGTERM`ed
   twice by memory pressure partway through. Every breakage it reached before
   that had passed, the control passes standalone, and I verified all seven new
   breakages directly (§10). What is unverified is the *whole suite in one
   process*, which is a statement about this machine rather than about the code.
5. **`kit.ref` against a real GitHub remote**, including whether GitHub serves a
   `--depth 1` fetch of an arbitrary sha without `uploadpack.allowReachableSHA1InWant`.
6. **Nothing was rebased.** Master was still `41f8bcb`, this branch's base, when
   I finished; the dispatch told me not to rebase or merge it myself.

---

## 10. A note on the environment

The machine OOM'd once already, killing the previous worker mid-run. It was
still oversubscribed when this ran (load average 106, eight `opencode run`
processes). Two consequences are recorded because they look like defects and are
not:

- The self-test's **control** failed once with
  `cd: /tmp/kit-self-test.XXXX/base: No such file or directory` — not a red gate
  but a **vanished throwaway tree**, with every worker `mktemp`-ing under one
  shared `TMPDIR`. Standalone it passes. `expect_green` no longer re-runs the
  gate to print its diagnostic (that was a second chance to lose the tree, and
  it is what destroyed the diagnosis), and a missing tree is now reported as an
  environment failure rather than as a red gate.
- The self-test was `SIGTERM`ed mid-run on memory pressure. Every breakage it
  reached before that had passed.

**What I did instead, and what it does and does not prove.** I ran the seven new
breakages directly against the real gate, with a fresh throwaway copy each:

- **23, 24, 25, 26, 29** — `expect_red_check` against a **fixture fleet**, run
  **in sequence** with one fixture shape, so a leak between them would show. All
  five went red via the named `fleet` check. A clean fixture fleet left the gate
  green, which is the control that makes the other five mean anything.
- **27 and 28** — the two kit-side checks, each mutation applied to a tree with
  everything else held constant:

  | tree | `stack_mount_check` | `pin_contract_check` |
  |---|---|---|
  | unbroken | PASS | PASS |
  | breakage 27 (mount reverted to `./`) | **FAIL** | PASS |
  | breakage 28 (`KIT_STACK_REF=master` back in `.env.example`) | PASS | **FAIL** |

  Each mutation is caught by its own check and **not** by the other, which is
  the discipline `expect_red_check` exists to enforce.

That is the same assertion the recipes make, run outside the one harness the
machine could not finish. It is not the same as a full green self-test, and this
report does not claim it is.

### 10.1 The defect that fix found

Running the four fleet breakages **in sequence** is what exposed a bug in the
recovered recipes. `fixture_fleet` built `$WORK/fleet-<name>/{alpha,beta}` with a
`.git` in each, and `fresh_copy` built `$WORK/<name>`. So every
`expect_red_check` ran a gate whose fleet question — `$ROOT/..` — was **every
fixture an earlier breakage had built, including breakage 23's still-broken
`alpha`**. Breakages 24, 25 and 26 assert `FAIL fleet` and would have matched it
whether or not the mutation they applied was the defect they name: **three proofs
asserting nothing**, from a directory one level too high. `copies/` and
`fixtures/` now separate them, and the sequence above is the check that it is
fixed.