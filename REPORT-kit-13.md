# kit-13 — the observability stack gets a live path

**Worktree:** `worker/kit-13-observe` · **Base:** `master` at `41f8bcb`

The brief's premise, checked rather than assumed: `kit/templates/compose/` ships a
complete observability platform, and **no service used it**. No repository had an
`otel-collector.yml`. Six of the twelve carried a bespoke 44–86 line
`docker-compose.yml` whose only infrastructure was a Postgres. One of the nine
adopted `bin/dev`. This packet gives the stack a callable path and a gate that
says, loudly, which repositories are not on it.

---

## 1. The fetch mechanism, and its pinning

**A compose file cannot be `uses:`-ed.** That is the whole reason the mechanism is
`bin/dev` and not something cleaner: GitHub resolves a reusable *workflow*, and
there is no equivalent for a `docker-compose.yml`, a collector config, and four
vendor config trees. So `bin/dev` fetches them.

```
bin/dev  →  git init + fetch --depth 1 <remote> <ref> + checkout --detach FETCH_HEAD
         →  docker compose --project-directory . \
                          -f <fetched>/templates/compose/docker-compose.yml \
                          -f ./docker-compose.yml up -d --wait
```

**Why `git init` + `fetch` rather than `git clone --branch`.** `--branch` takes a
branch or a tag and **cannot take a commit sha**, so cloning cannot express the
stricter of the two pin forms. Three lines do, and they also make the checkout
disposable: the cache directory is keyed by the ref, so an upgrade is a new
directory rather than an in-place mutation, and there is no state to get into.

**The pin is `kit.ref`** — one committed line at the service root. The first
version put it in `KIT_STACK_REF` in `.env`, and that was wrong in a way worth
recording: **`.env` is git-ignored**, so a pin there exists on exactly one
machine — the laptop of whoever ran the command last — and on no CI runner and no
teammate's checkout. "One command, always current" then resolved to "one command,
whatever this checkout last fetched", which is the opposite of what a pin is for.
`bin/dev` still reads `KIT_STACK_REF`, but only from the **environment**, as an
explicit one-run override for someone working on kit itself.

**A pin is a 40-character commit sha, or a `v<MAJOR>.<MINOR>.<PATCH>` tag.**
Accepted: semver's own grammar including pre-release and build suffixes, because
`v1.0.0-rc.1` is a tag real projects cut and a rule that refused it would be
routed around — a developer told "that is not a pin" writes `master`, which is the
failure the pin exists to prevent. Refused, **before any network call**:

| refused | why |
|---|---|
| `master`, `main`, any branch | a MOVING reference; the allowlist and port block your dev loop runs change between two runs of the same command |
| a 7-character sha | a moving reference wearing a sha costume; `git fetch` resolves it happily and it is ambiguous across remotes |
| empty / a blank file | not a pin |
| a non-numeric tag part | not semver |

**Upgrading is a command, not an edit**, because the interesting question is never
"can I write this sha" but "what changes if I do":

```sh
bin/dev pin v0.4.0        # prints the stack diff between the two refs, THEN writes kit.ref
```

It writes the pin and nothing else. It does not touch `.env` beyond nothing, does
not run compose, and does not upgrade images — the containers that come up next are
a separate, visible step.

**Proven by `tests/fetch_test.sh`, 14 assertions, all executed.** The remote is a
bare repository built from this tree and fetched over `file://`, so the suite needs
no network — a CI runner and a laptop on a train get the same answer, and a flaky
network can never be mistaken for a broken gate.

---

## 2. Offline mode, and how it was tested

**The decision: use only what is on the machine, and fail loudly when none of it
holds the pin.** `KIT_STACK_OFFLINE=1` skips the network entirely. Four sources,
in this order, and the order is the argument:

1. `KIT_STACK_DIR` — an explicit directory (read from `.env` too; the first version
   read it from the process environment only, so the documented escape hatch
   written in the file a developer is told to write it in was silently ignored and
   the script went to the network anyway).
2. `<cache>/<ref>`, with the ref **recorded inside it**.
3. `.kit/stack`, vendored, **also with the ref recorded inside it** in
   `.kit-stack-ref`.
4. a fetch — the only one that touches the network.

**Sources 2 and 3 must record their ref, and that is the load-bearing detail.** A
directory that merely *contains* `templates/compose/` is not a kit checkout at a
known version; it is a directory. A mismatched record is a refusal, a **missing**
record is a refusal, and only a matching one is used. That is what makes the
offline mode real rather than decorative: a vendored copy at some other ref is
refused by name, with both refs printed.

**Four offline cases, all executed:**

| case | asserted |
|---|---|
| warm cache, **remote deleted from disk** | runs, and says it came from the cache |
| cold cache, no remote | exits nonzero, naming `KIT_STACK_DIR`, `KIT_STACK_HOME` and `.kit/stack` |
| vendored copy **declaring the pinned ref** | accepted, and named as the source |
| vendored copy at a **different** ref | **refused**, not silently used |

The first case removes the remote rather than unsetting a variable: a URL that
404s is a different failure from a URL that is not there, and only one of them is
a network.

**What offline mode deliberately does NOT do:** fall back to whatever is in the
working directory. That is the one behaviour that cannot be allowed, because it
makes `bin/dev` report success while running a stack nobody pinned.

---

## 3. What stays in the service, measured

The service's own `docker-compose.yml` is the **second** `-f`, so it is an
override: what is in it wins, everything it does not mention still comes from kit.

**`muse`, the largest adopter. Measured on a read-only copy — the house rules
forbid touching other repositories.**

| | total lines | non-comment |
|---|---|---|
| before — `muse/docker-compose.yml` verbatim | 86 | 52 |
| after — the same service as an override | 59 | **22** |

The 30 lines the "after" is *longer* in are comments explaining the override
rules, which is where a service author reads them. The code shrank 58%.

Merged against kit's 538-line stack, with the observability profile on:

```
AFTER  declares            : ['muse', 'postgres']
MERGED has                 : 9 services            (8 from kit + muse)
postgres POSTGRES_DB (muse's override won): muse
postgres healthcheck is kit's, untouched   : CMD-SHELL pg_isready -U cafaye -d cafaye_platform
postgres published ports (count)           : 1
otel-collector config mount is kit's       : ['otel-collector.yml']
tempo/loki/mimir/grafana still present    : ['tempo', 'loki', 'mimir', 'grafana']
```

**The check found a live defect in `muse` on the way.** `muse/docker-compose.yml`
**does not parse as YAML**:

```
mapping values are not allowed here — line 65, column 67
```

`MUSE_VAULT_KEY: ${MUSE_VAULT_KEY:?set MUSE_VAULT_KEY, or run: uv run python -m muse.vault}`
— the `: ` inside the shell expansion is a YAML mapping indicator. Every line of
that file is what was meant, it reads correctly, and `docker compose up` answers
with a line number and no explanation. It is **not** fixed here (out of bounds);
it is reported to muse, and the fix is to quote the value.

---

## 4. Override rules

Each was run through `docker compose config`; none is assumed. They are written
into the compose template's own header, which is where a service author reads.

**MAY**
- `image:` on any service, wholesale. A different tag is a different Postgres
  major, which is a real thing a service needs.
- add keys to `environment:` — it **merges by key**.
- add a `depends_on` with `condition: service_healthy`, and declare new services.
- change a published port **by changing the variable in `.env`**.

**MAY NOT**
- touch `otel-collector` — not `image:`, not `command:`, and above all not the
  `volumes:` entry that mounts `otel-collector.yml`. That file carries the
  redaction allowlist, **derived from core's schemas**; a service that overrides
  the mount is shipping a telemetry boundary nobody derived, and prompt content
  leaves the process inside it. This is the answer to the brief's question about
  what may not be overridden.
- override the four AGPL backends. `build:` is a fork, which is the licence
  condition; a retagged image is the same fork by another route.
- set `allow_all_keys`, or add an exporter, by any route.

### The trap worth the whole section: `ports:` APPENDS

A second file's `ports:` list is **concatenated** with the first, not substituted.
A service that writes

```yaml
services:
  postgres:
    ports: ["15433:5432"]
```

gets postgres listening on **15500 _and_ 15433**. Measured:

```
=== override published 15433, kit default 15500 ===
    ports:
      - published: "15500"     ← kit's
      - published: "15433"     ← and the override's
```

`KIT_POSTGRES_PORT=15433` in `.env` is the only way to move it, and the gate
fails on a `ports:` entry in a service file for that reason. This is why the
"after" file above shows exactly one published port.

Other measured behaviours: `volumes:` merge **by mount target** (same target
replaces, different target appends); `command:`, `image:` and `entrypoint:`
replace; a service joining `networks: [platform]` lands on the *same* network as
kit's without redeclaring it.

---

## 5. Proving it works

**`tests/stack_live_test.sh` — 15 assertions, all passing.** A compose file that
has never been `docker compose config`-validated is a YAML file; this brings the
whole thing up, sends it real OTLP, and reads the data back out of the stores.

```
PASS  the fetched stack came up healthy, and only then did bin/dev look for migrations
PASS  every service that declares a healthcheck reports healthy (8 of them)
PASS  the running stack came from the fetched tree at the pinned ref (b25bdff2…)
PASS  the collector's config is the FETCHED otel-collector.yml, byte for byte (per docker inspect)
PASS  the tree the collector is reading declares the pinned ref (b25bdff2…)
PASS  OTLP/traces accepted by the running collector
PASS  OTLP/metrics accepted by the running collector
PASS  the trace is in Tempo, found by service.name
PASS  Tempo returns the trace, and error.type survived the boundary
PASS  the canary reached no exporter on the live stack (Tempo checked by trace id)
PASS  the direct OTLP metric is in Mimir under the kit_probe_ namespace
PASS  the spanmetrics connector minted cafaye_duration_count — the fleet dashboard's source
PASS  the canary reached no exporter on the live stack (Mimir checked by label scan)
PASS  the service's own service joined the fetched stack rather than replacing it
```

Two of those are worth naming. The collector's config is checked by
**`docker inspect .Mounts`** — the daemon's own record of the bind it set up — not
by asking the collector (distroless: no shell) and not by asking the host (that is
what we *think* we mounted). And the canary assertions are *absences against a
search that first proved the data is there*, so a store holding nothing cannot
satisfy them.

**Three real defects the run found, and the one fix I did not make.**

1. **`${KIT_COMPOSE_DIR:-.}`** — with the stack fetched, a bare `./` in the compose
   file resolves against the project directory, which is the *service*, where
   `otel-collector.yml` no longer is. Docker's answer to a missing bind source is
   to **create a directory**, so all four backends died with
   `read /etc/tempo/tempo.yaml: is a directory` — naming a file type rather than
   the thing that is wrong. `docker compose config` renders the same project and
   every static check was green. Fixed by anchoring the mounts to the compose
   directory, and gated (breakage 27).

2. **Grafana's first boot downloads a plugin.** Grafana 11.3 ships
   `[plugins] preinstall = grafana-lokiexplore-app` and installs it on first boot,
   which holds the sqlite lock its own migrations want. Cold-volume cold-start
   time for `/api/health` measured anywhere from **26s to over 180s** — a network
   call in a dev loop, and an air-gapped developer could not start the stack at
   all. Fixed by `GF_INSTALL_PLUGINS_PREINSTALL_DISABLED=true`, which is
   *configuration* (the AGPL condition is about not building a `grafana/*` image),
   and which nothing kit ships uses: both dashboards read Loki through the
   provisioned datasource, and the alert rules are PromQL. Measured after: Grafana
   ready at ~26s, **whole stack up and healthy in 76s**.

   **The wrong fix was available and looked entirely reasonable.** A cold start
   failing against a 65s budget reads exactly like a flake, and the obvious
   response is to raise the retries. I did that first, then reverted it once the
   evidence showed the slowness was a network call rather than a tight budget —
   and left the healthcheck at its shipped `6 × 10s + 5s`, which the fixed cause
   now clears with room to spare. Widening the budget would have hidden the
   network dependency and left the loop unusable offline, which is the one thing
   this packet exists to make true.

3. **`muse/docker-compose.yml` does not parse** — section 3. Not mine to fix.

---

## 6. The gates

`tests/fleet_check.py`, wired into `tests/validate.sh` as
`fleet  (no stale copy, no weakened boundary, no dead config, every ref pinned)`.
Four failure modes, one check each, and a SKIP (never a silent pass) when there
is no fleet — "no fleet was found" is not "the fleet is clean", the same
`unknown` vs `current` confusion `tests/staleness.py` exists to avoid.

### **The stale-compose check is RED on master, and that is correct.**

```
FAIL fleet: 11 problem(s) across 6 repository(ies).
```

| repository | what the check catches |
|---|---|
| **billing** | `db: postgres:17` — its own copy; no `kit.ref` |
| **courier** | `db: postgres:17` — its own copy; no `kit.ref` |
| **darkroom** | `postgres: postgres:17-alpine` — its own copy; no `kit.ref` |
| **identity** | `postgres: postgres:17-alpine` — its own copy; no `kit.ref` |
| **muse** | `postgres:18-alpine` + `cafaye/muse:dev`; **`docker-compose.yml` does not parse**; no `kit.ref` |
| **guard** | no `kit.ref`. It has no database in v0, so there is no copy to catch — its file declares one service and it is genuinely its own |

**Five repositories carry a stale copy of the shared stack; six have no pin.**
`caf`, `cafaye-rb`, `cafaye-ts`, `core`, `pantry` and `parlor` ship no compose
file at all and are reported as out of scope rather than as clean — five of them
have no `kit.ref` either, which is the honest state of a service that has not
adopted anything.

The predicate is an **image**, not a service name, and that is the whole
subtlety: five of the six name their database `db` rather than `postgres`, so a
check looking for the NAME would find nothing and report the fleet clean while
five copies of the platform stood right there. The set of images is read out of
**kit's own compose file** rather than written down, because a hand-kept list is a
list that must be edited every time kit adds a service, and a check that must be
edited is a check that gets skipped — which is how this state survived.

**I have not softened it.** The same shape as D4: three repositories not spelling
their gate the same way is invisible to any check that reads only one of them, so
kit's gate reads the *other* repositories. Red here is the deliverable.

**The other three gates are green on master**, which is correct: no repository
overrides the collector, none carries a collector config, and none has a pin to be
unpinned. They are proven able to fail by breakages 24, 25 and 26.

---

## 7. Breakages

`tests/self_test.sh` now carries **29** (was 23). Six are new, each asserting the
**named** check rather than "the gate went red" — and for the four fleet gates
that distinction is the whole proof, because the real fleet is red by design, so
"the gate went red" would be satisfied by a fleet of two clean repositories. They
run against a **fixture fleet** built by `fixture_fleet` for that reason.

| # | breakage | caught by |
|---|---|---|
| 23 | a service carrying its own copy of the shared stack (the real `db: postgres:17` shape) | the stale-copy check |
| 24 | a service re-pointing the collector's config mount at its own `otel-collector.yml` | the boundary check |
| 25 | an `otel-collector.yml` that exists and that **nothing mounts** | the dead-config check |
| 26 | a `kit.ref` holding `master` | the pin check |
| 27 | a vendor config mount that stopped resolving from the fetched tree | `every vendor config mounts from the fetched tree` |
| 28 | the pin moved back into `.env`, where nothing reads it | `the pin is kit.ref, and the gate reads the same file` |

---

## 8. What I could not verify

- **The network path to `github.com/cafaye/kit` is not in the gate.** I confirmed
  by hand that `git fetch --depth 1 https://github.com/cafaye/kit.git <sha>`
  resolves a commit, and every test uses a local `file://` remote instead. A gate
  that depends on github.com is a gate that goes red when github is down.
- **`bin/dev up` was never observed reaching its `migrate`/`seed` steps.** The live
  fixture has neither, and `bin/dev` correctly refuses to pretend otherwise — the
  test asserts the stack came up *and* that the migration lookup happened after.
  The migration path is unchanged by this packet and is covered elsewhere.
- **The 180s `bin/dev` deadline is a laptop figure.** Measured 76s cold on an
  otherwise-idle 8-CPU VM. This machine is shared — other cafaye workers were
  running their own stacks throughout — so `stack_live_test.sh` sets
  `KIT_DEV_TIMEOUT=420`, the escape hatch `bin/dev` itself prints. Raising the
  shipped default would make every developer wait longer for a stack that starts
  in 76s on their machine.
- **No repository was migrated.** The before/after in section 3 is measured on a
  read-only copy. Turning `muse` over needs a `kit.ref`, an `AGENTS.md` edit and a
  compose rewrite, and the house rules put other repositories out of bounds here.
- **The fleet gate is only as good as its discovery.** It enumerates immediate
  subdirectories that are their own git checkouts, skipping worktrees — the same
  rule `tests/staleness.py` uses, so the two cannot disagree about how many
  repositories there are. A fleet in a different layout needs `--repos-dir`.
- **The redaction allowlist's continued agreement with core's schemas is
  unchanged and still gated** by the pre-existing `core`-derived check. What is new
  is that a service can no longer *override* the file that carries it.
