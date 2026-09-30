# kit

**kit is the shared CI, lint, and toolchain layer every cafaye service repo
adopts.** It contains no runtime code and no dependencies — only conventions
that would otherwise be retyped, and slightly differently, in each of the six
services.

```
github.com/cafaye/caf     Go       github.com/cafaye/billing  Ruby
github.com/cafaye/identity Go      github.com/cafaye/courier  Elixir
github.com/cafaye/guard   TypeScript  github.com/cafaye/muse   Python
github.com/cafaye/darkroom Rust    github.com/cafaye/parlor   TypeScript
```

Every one of those repos **calls** the same workflow. A change to how we build
lands in kit once, and reaches the next service on its next run.

Every one of those repos also *copies* the same linter configs and the same
scripts — and **how much they actually match is measured, not assumed.** See
[what the fleet actually adopted](#what-the-fleet-actually-adopted) below.

## What the fleet actually adopted

Measured on 2026-09-30 against `41f8bcb`, by `tests/staleness.py --scope
templates --repos-dir …`, over the nine services (the fleet the packet counts;
`docs` and `cafaye-{py,rb,ts}` are toolchain repos, not services, and
`pantry` is a registry that has not called kit's workflow). **Nine of 108 cells are
byte-identical.** One of them, `guard/bin/prime`, is the only copy in the fleet
that matches kit exactly — and it matches because `guard` is the service that
caused kit's `bun` job to exist, so it is the one service that copied a template
*after* it was written rather than before. That is the whole adoption story in
one cell.

| artefact | byte-identical | diverged | absent | unknown | not applicable |
| --- | --- | --- | --- | --- | --- |
| `ci.reusable.yml` | **8/9** | 0 | 1 | 0 | 0 |
| `bin/prime` | 1/9 | 7 | 0 | 1 | 0 |
| `docker/Dockerfile` | 0 | 7 | 1 | 1 | 0 |
| `mise.toml` | 0 | **9/9** | 0 | 0 | 0 |
| `AGENTS.md` | 0 | **9/9** | 0 | 0 | 0 |
| `bin/dev` | 0 | 1 | **8/9** | 0 | 0 |
| `compose` (12 files) | 0 | 7 | 2 | 0 | 0 |
| `lint/yamllint.yml` | 0 | 0 | **9/9** | 0 | 0 |
| `lint/hadolint.yaml` | 0 | 0 | **9/9** | 0 | 0 |
| `lint/golangci.yml` | 0 | 1 | 1 | 1 | 6 |
| `lint/rubocop.yml` | 0 | 1 | 0 | 1 | 7 |
| `lint/eslint.config.mjs` | 0 | 1 | 1 | 1 | 6 |
| **all twelve** | **9/108** | **43** | **32** | **5** | **19** |

Three findings the packet's brief did not contain, and all three changed what
was built:

1. **`mise.toml` and `AGENTS.md` are 9/9 *diverged*, and the two divergences
   mean opposite things.** `mise.toml` is adoption working: the template is
   kit's **union of every language's tool pins** (19 tools, 74 code lines), so a
   service keeping two of them and raising the versions reads as 80–110 lines of
   divergence by construction — `muse` keeps `python` and `uv` out of nineteen.
   `AGENTS.md` is the opposite: the template is 121 lines and each service
   wrote its own 281–664 line document, keeping only **12–40** of the
   template's lines. `## Observability` — the template's largest section, and
   the one recording the telemetry convention — **survives in none of the
   nine**, including the eight that adopted that convention through kit's own
   workflow. The template was superseded, not filled in.
2. **`lint/*.yml` is not 0/9. It is 3 diverged, 3 absent.** `billing`,
   `parlor` and `identity` each hold their own linter config, all three
   differing from kit's, and none of the three carrying kit's STRICTNESS NOTES
   block — which is where a config records *what* it enforces and why. The
   honest sentence is "nobody lints with kit's rules", not "nobody lints".
3. **The local stack is not "drifted", it is *not there*.** Of the twelve files
   in `templates/compose/`, the fleet holds `docker-compose.yml` in six
   services and `.env.example` in two, and seven services hold at least one
   member. The collector, Tempo, Loki, Mimir and
   the Grafana provisioning are **0 of 12, in all nine services**. Those six
   compose files are each ~420 lines different from kit's, and the number is
   the least interesting thing about them. They are also **replacements rather
   than broken copies**: none of them mounts a single one of kit's stack files
   (`grep -cE '\./(otel-collector|tempo|loki|mimir|grafana)'` is 0 in all
   six), each declares one or two services of its own, and
   `docker compose config` is **green on five of the six** — so they are valid
   stacks that are simply not this one. The reporter calls the state `diverged`
   and reports the member breakdown; it does not claim the stack is broken,
   because comparing bytes cannot tell those two situations apart.

`templates/parity-allowlist` carries all 80 findings — every diverged copy,
every absence and every unmeasurable cell — as one line each, with a reason, an
owner, a `since` and an `until`. **80 is a bad number and it is meant to be
read as one.** The way to shrink the file is to re-copy an artefact and delete
the entry; deleting the entry to shrink the file is a hard failure of its own.

## What is in here

| Path | What it is | Who uses it |
|------|-----------|-------------|
| `.github/workflows/ci.reusable.yml` | One reusable GitHub Actions workflow. Input `language` picks one of seven jobs — install, lint, test, coverage gate. Opt-in `telemetry` input adds the traceparent conformance job; opt-in `required-tier` demands a tier by gate-variable name. No job builds or pushes an image. | Every service, via a 6-line `.github/workflows/ci.yml` |
| `lint/yamllint.yml` | YAML style, with the three rules Actions forces us to retune. | Any repo that lints its own YAML; kit's gate uses it on itself |
| `lint/golangci.yml` | golangci-lint v2, correctness linters on, `errcheck` excluded only for `Close`/`Flush`. | Go services |
| `lint/rubocop.yml` | RuboCop, `NewCops: enable`, Metrics left on. | Ruby services |
| `lint/eslint.config.mjs` | ESLint 9 flat config, type-checked rules on. | Node/TypeScript/Bun services |
| `docker/Dockerfile.<lang>` | Seven multi-stage templates. `go` and `rust` finish on distroless; the rest finish on `*-slim`. All run non-root. Linted by `hadolint -c lint/hadolint.yaml`, plus a non-root/no-`:latest`/no-`ADD` check the linter does not cover. | Every service |
| `lint/hadolint.yaml` | hadolint config, with the one ignored rule (DL3008) argued rather than assumed. | Any repo that ships a Dockerfile |
| `templates/bin-prime/<lang>.sh` | The worktree primer: one script per language, exit 0 only when the tree is genuinely ready. | Every service, as `bin/prime` |
| `templates/bin/dev.sh` | The local developer loop: bring the stack up, wait for health, migrate, seed an admin, print the URLs. Idempotent, fails loudly. | Every service, as `bin/dev` |
| `templates/compose/docker-compose.yml` | Postgres, NATS+JetStream, Redis, the OTel collector, and the four LGTM backing services. Every port parameterized inside kit's claimed `15000-15999` block, every image pinned, every service healthchecked and memory-bounded. | Every service, as `docker-compose.yml` |
| `templates/compose/otel-collector.yml` | The collector: OTLP + container-stderr receivers, the redaction allowlist **derived from core's schemas**, the `spanmetrics` connector, and fan-out to Tempo/Loki/Mimir. Every endpoint a `${env:}`. | Every service, as `otel-collector.yml` |
| `templates/compose/{tempo,loki,mimir}/` | Vendor **configuration** for the three stores: retention, limits, paths. Read-only mounts over stock images. | Every service, beside its compose file |
| `templates/compose/grafana/provisioning/` | Datasources, the dashboard provider, the fleet error dashboard and the alert rules — all files, working on first load. Nothing to click together by hand. | Every service, beside its compose file |
| `templates/compose/.env.example` | Every `${KIT_*}` the stack interpolates, each with a default. | Every service, as `.env.example` |
| `tests/canary_test.sh` | Plants a canary in ten leak shapes against a real collector and asserts it reaches no exporter. | kit |
| `tests/no_telemetry_in_readiness.sh` | Kills the collector and proves a service still starts, still serves and still reports healthy. | kit |
| `templates/otel/<lang>/` | W3C traceparent: a stdlib codec, an executed conformance suite, an SDK snippet, and a README. | Every service, per language |
| `templates/tier/<lang>/` | The **declared tier**, per language — the tests that need a real dependency, declared in the test source and read by the runner's own collector. Never grepped for a sentinel: a sentinel fails open. | Every service, per language |
| `templates/tier/skip-allowlist` | One file for the fleet. Four hygiene rules — reason, owner, `since`, `until` — and **an entry matching nothing is a failure**. | Every service; the file itself lives here |
| `templates/tier/README.md` | The normalised result format, the allowlist rules, and what a tier gate **cannot** catch. | Every service |
| `templates/parity-allowlist` | Why each service's copy of a kit template is **not** kit's bytes. Same four rules, same one-line dialect, and it adds the rule the tier file does not need: **an unpinned divergence or absence is a failure too**. The count is printed on every green run. | The whole fleet; the file itself lives here |
| `templates/mise.toml` | Toolchain pins, one per language, commented. | Every service, as `mise.toml` |
| `templates/AGENTS.md` | Skeleton repo-conventions file. | Every service, as `AGENTS.md` |
| `core/` | The `cafaye/core` fan-out: a `vendir.yml` per consuming repo, the one shared Renovate policy, and what `core` needs to publish semver tags. | Any repo that consumes core's schemas |
| `tests/classify.py` | Classifies a change to a vendored schema set into `FILE`/`PACKAGE`/`WIRE_JSON`/`WIRE`, and **fails closed** on anything `tests/rules.json` does not name. Stdlib only. | Any repo that vendors core |
| `tests/staleness.py` | Two scopes. `--scope core` reads every consuming repo's recorded pin and prints the distance. `--scope templates` reports whether each service's copy of a kit template is `current`, `diverged`, **`absent`**, `unknown` or `n/a`, and whether the reason for it is recorded. | Scheduled, fleet-wide |
| `tests/artifacts.json` | The ONE place kit says what it ships and where a service puts it. Read by the reporter *and* by the gate — a table written down twice is a table that is right in one of the two places. | kit |
| `tests/validate.sh` | kit's own suite — the gate. | kit |

## The core fan-out — `core/`

Six repositories copy bytes out of `cafaye/core` and nothing in the fleet makes
that copy reach them. `core/` is the standard that does, and — as much as
anything else — the record of what is still unproven about it.

**Start at [`core/README.md`](core/README.md).** It opens with what was
*measured* rather than what was assumed, and the measurement is not what the
design was briefed on: one repository declares a core pin at all, two hold
vendored bytes with no recorded origin, and two fetch core at test time on
purpose.

| file | what it is |
| --- | --- |
| [`core/vendir/vendir.yml.{muse,pantry,caf}`](core/vendir/) | The three real consumers, in three languages. `muse` and `pantry` are proven byte-identical (sha256) to what those repos have committed today; `caf` cannot migrate without a rename and its banner says so. |
| [`core/vendir/vendir.yml.template`](core/vendir/) | What a fourth repository copies. Four things to change, each marked. |
| [`core/renovate/renovate.json5`](core/renovate/) | The single `inheritConfig` policy for the whole fleet. |
| [`core/renovate/SETUP.md`](core/renovate/) | The ordered steps to stand the policy repo up, **and what to verify before onboarding a second repository**. |
| [`core/release/release.yml`](core/release/) | The workflow `core` needs before any of it can move. Ships here; belongs in `core/.github/workflows/`. |

## The templates half — `templates/`

Everything in `templates/`, `lint/` and `docker/` is adopted **by copy**, which
means a fix in kit reaches a service only when somebody copies the file again.
Nothing in the fleet made that happen, and the reporter that now measures it is
`tests/staleness.py --scope templates`.

```sh
tests/staleness.py --repos-dir .. --scope templates
```

A **pin** is a record that a copy is deliberately not kit's bytes. Without one,
a divergence is not "fine", it is **unproven** — and an unproven cell is a
finding, the same way an undeclared `core` pin is. `templates/parity-allowlist`
is the file those records live in, and it uses the tier skip-allowlist's format
exactly:

```
<verb> <repo> <artefact-id> reason="…" owner=… since=YYYY-MM-DD until=YYYY-MM-DD
```

with three verbs — `diverged` (held, and different), `absent` (kit ships it,
the service holds nothing) and `unknown` (kit cannot say what the service would
have copied). **The verb is checked against what the reporter measured**, so an
entry cannot excuse a different finding than the one that exists.

Two directions, and the tier allowlist only needs one:

- **an entry that matches nothing is a failure** — ESLint's
  `reportUnusedDisableDirectives` shape. The artefact is now byte-identical, or
  the entry names an artefact kit does not ship, or a repository that is gone.
- **an unpinned cell is a failure** — the reverse. `pantry`'s
  `ci.reusable.yml` is the example that pays for the rule: it is a real design
  decision (its CI is a workspace-drift job over thirteen repositories, not a
  per-language service build) and it is invisible to every reader of that
  repository until it is written down somewhere.

**A copy is never inferred from content.** There is no similarity threshold and
no search for a file that hashes to kit's: a copy is `current` when the bytes
at the declared path are equal and the path is a real file in the service's own
tree, and at no other time. A symlink to an identical file is `unknown`, not
`current` — the bytes are right today and the arrangement is a bet that the
target never moves. `tests/self_test.sh` breakage 27 is that rule written as
the patch someone would write to relax it, and it has to be tried to be
believed.

Two things worth knowing before you read any of it, because both were found by
running the tools rather than by reading about them:

- **`includePaths` nested under `git:` is silently ignored.** vendir drops keys
  its schema does not declare, the filter ends up empty, and `vendir sync`
  vendors the *entire* upstream repository while exiting **0**. It reads
  correctly. `tests/validate.sh` has a check for exactly this shape and
  `self_test.sh` breaks it on purpose.
- **`renovate.json5` uses `constraints.vendir`, not `installTools`.** The first is
  what the vendir manager actually reads; the second is scoped to
  `postUpgradeTasks` and is *also* wrong in shape — it is an object keyed by tool
  name, not an array. Both checked in Renovate's source; see the comments in the
  file.

The change classifier and the staleness reporter are the two things here that
are programs rather than configuration, and they are the reason the standard is
enforceable. Both are standard-library only and neither is imported by anything.
Their conventions are in [`AGENTS.md`](AGENTS.md#the-classifier-fails-closed-and-that-is-a-rule-about-code).

The one that reads `core/`'s consumers is `--scope core`, and it is documented in
[`core/README.md`](core/README.md). The one that reads **this** repository's
consumers is `--scope templates`, and the difference is not cosmetic: a pin can
be stale and a file can be **gone**, and `templates/` has drifted far enough
that gone is the commonest answer. The seven stacks above are the worked
example — the fleet holds `docker-compose.yml` in six services and none of the
other eleven files each one needs, which is the finding a drift-only reporter
has no word for.

## The local stack — `templates/compose/`

Postgres, NATS with JetStream, Redis, the OpenTelemetry collector, and the four
services that make a developer's traces, metrics and errors visible: **Grafana,
Loki, Tempo and Mimir**. One stack, one set of credentials, one command, for
every service.

```sh
cp <kit>/templates/compose/docker-compose.yml ./docker-compose.yml
cp <kit>/templates/compose/otel-collector.yml  ./otel-collector.yml
cp -R <kit>/templates/compose/tempo  ./tempo
cp -R <kit>/templates/compose/loki   ./loki
cp -R <kit>/templates/compose/mimir  ./mimir
cp -R <kit>/templates/compose/grafana ./grafana
cp <kit>/templates/compose/.env.example        ./.env
cp <kit>/templates/bin/dev.sh                  ./bin/dev && chmod +x bin/dev

bin/dev            # up, wait for health, migrate, seed, print URLs
bin/dev status     # what is running
bin/dev logs nats  # tail one service
bin/dev down       # stop, keep the data
bin/dev nuke       # stop and DELETE the data
```

It is a **template with placeholders**, not a fixed stack. Every published port
is `${KIT_*:default}` inside kit's claimed block, every image is pinned to an
exact tag, and every service has a healthcheck so `up --wait` can mean
something. A service joins by adding a `depends_on` and copying the connection
URLs into its own `.env`.

`bin/dev` is idempotent — run it twice and nothing changes — and it fails loudly
rather than half-starting: if the stack does not become healthy it prints what is
unhealthy and its logs, and stops *before* migrating, so a failed `up` cannot
leave a half-migrated database behind.

### Observability is on by default

You did not have to install anything. `bin/dev up` brings up the collector and
the four stores behind it, and a service with nothing configured exports into
them, because `<SERVICE>_OTEL_ENDPOINT` **defaults to the collector that ships
with this stack**. Open <http://localhost:15000> and the fleet error dashboard is
already there.

That is on-by-default-and-worked-on-in-dev, not on-by-default-and-mandatory. The
escape hatches are first-class:

| You want | You do | What happens |
|---|---|---|
| **Your own backend** | set `MUSE_OTEL_ENDPOINT` (or `CAF_OTEL_ENDPOINT`, `BILLING_OTEL_ENDPOINT`, … — `<SERVICE>_OTEL_ENDPOINT`, the name derived from the service) to your Datadog / Honeycomb / Grafana Cloud OTLP endpoint | this service exports there and the shipped stack goes quiet for it. **Bring your own backend is a supported deployment, not a degraded mode** |
| **No telemetry at all** | unset the variable | a genuine no-op: no queue, no retry loop, no warning per request, no dial at boot |
| **Still on, quieter** | `KIT_OTEL_DEBUG_VERBOSITY=basic` | the `debug` exporter stops printing every span to the terminal |

`<SERVICE>_OTEL_ENDPOINT` is the ONLY contract. The shipped collector is just
that variable's default value, which is what makes on-by-default possible without
making it obligatory. All six language templates implement it — see
[`templates/otel/README.md`](templates/otel/README.md).

### The port block: 15000-15999

kit claims this range for the whole stack, one hundred per service, and the gate
asserts every published port is inside it and that no two services reuse one.

| Port | Service | | Port | Service |
|---|---|---|---|---|
| 15000 | Grafana | | 15700 | NATS (monitoring) |
| 15500 | Postgres | | 15800 | Redis |
| 15600 | NATS (client) | | 15900 | Tempo (traces) |
| | | | 15901 | Loki (logs + crash layer) |
| | | | 15902 | Mimir (metrics) |

Not 5432, 4222 or 6379, and that is the point: those are the two or three most
likely things already listening on a developer's machine. `bin/dev` is the first
command a new person runs on a repo they just cloned, which is the worst possible
moment to find out somebody else owns 5432.

The four backends sit in a compose profile named `observability` so a constrained
machine can opt out; `bin/dev up` includes the profile, so the **default** path
still gets the whole stack. The collector is deliberately NOT in that profile: it
is the default value of the endpoint variable, and a service with nothing
switched on needs somewhere to send.

**Cold `bin/dev up` on a laptop: ~50 seconds**, eight containers, volumes
deleted. Measured, not estimated, and `bin/dev` prints the wall-clock itself so
"the dev loop is slow" is a number in the output rather than a feeling.

**If a port in that block is already taken — by another repo's scratch
container, say — move it in `.env`, not in the template.** That is what `.env` is
for, `bin/dev` prints the URLs it read from `.env` rather than hardcoded ones,
and this is the documented escape hatch rather than a workaround:

```sh
sed -i '' 's/^KIT_POSTGRES_PORT=15500/KIT_POSTGRES_PORT=15501/' .env
bin/dev up
```

Note the block is claimed *fleet-wide*, and nothing coordinates it across repos.
Six services each running their own stack need six of these blocks. See the DECISION
NEEDED in kit-03's report before a second repo adopts it.

### The licence, stated plainly

**Grafana, Loki, Tempo and Mimir are AGPL-3.0, and kit ships them UNMODIFIED.**
Stock `grafana/*` images, pinned, with read-only *configuration* mounted over
them. Nothing is forked, patched or rebranded — that is the condition the licence
cares about, and the gate fails on a `build:` stanza on any of the four.

AGPL attaches to the Grafana **server**, not to the applications it observes, so
this is compatible with cafaye being MIT/Apache. The obligation runs one way: we
may use these; a self-hoster using our code is not thereby offered a modified
Grafana. If you believe a change to one of these is necessary, that is a
`DECISION NEEDED`, not something to do quietly.

Every image is pinned to an exact tag. `latest` for a log store means a
self-hoster's upgrade path is whatever happened to be cached when their disk
filled.

### Telemetry is never in a readiness path

A service that hangs on startup because telemetry is down is worse than no
telemetry at all. So:

- nothing in the compose file `depends_on` the collector or a store, and no
  healthcheck probes an OTLP port — the gate fails on both;
- `bin/dev` does not wait on the collector before migrating;
- the collector's `health_check` reports healthy with all three backends absent,
  because a collector that has lost spans is not an unhealthy collector;
- every exporter sets `sending_queue` and `retry_on_failure` to **false**, so a
  dead Tempo costs you spans rather than a background thread and a queue.

`tests/no_telemetry_in_readiness.sh` proves it against a real collector: it
starts the collector with Tempo, Loki and Mimir all refusing connections and
checks it is still healthy, has not restarted, and has not entered a retry loop;
then it stands up a service whose `/readyz` **really** checks a dependency, stops
that dependency, confirms `/readyz` has gone 503 — so the probe is known to be
capable of failing — and only then checks the service is still serving, with a
dead dependency and an OTLP endpoint that does not exist. A readiness test
whose `/readyz` cannot fail is not a readiness test.

### If you edit a provisioned dashboard

The shipped dashboards were correct on arrival and were not correct on the first
attempt, in three ways that are all invisible until you look at the backend. The
gate now holds all of them, but the rules are worth stating because the next
person to add a panel will hit them:

- **Name the datasource on every panel.** A panel with `"datasource": null` goes
  to Grafana's *default* datasource, which is Mimir. That is how a LogQL panel
  ends up asking a Prometheus API for `{service_name=~"..."} |= "error"` and
  getting `parse error: unexpected character: '|'`. The panel renders red, not
  empty, and every datasource still shows green.
- **Label names lose their dots.** OTLP ingestion mangles `.` in a label name to
  `_`, so the collector's `otel.status_code` reaches Prometheus as
  `otel_status_code`. A matcher on the dotted spelling is a *parse error*, and an
  alert rule that cannot be parsed never fires and never says so.
- **The counter carries `_total` because the collector adds it.**
  `transform/cafaye_metrics_labels` renames a metric whose name ends in `calls`
  to `calls_total`, which is what Prometheus reserves for counters and what stops
  a `rate()` warning banner on every panel. Query `cafaye_calls_total`, not
  `cafaye.calls` and not `cafaye_calls`.

**Where `tenant_id` is visible.** It is a *resource* attribute, so it arrives on
`target_info` and on the resource of every span and log record — and never as a
label on a measurement, which is what keeps core's 2000-combination cap
meaningful. Per-tenant metric totals are a `group by (tenant_id)` **joined
against `target_info`**, not a label on the series. See the DECISION NEEDED in
kit-03's report.

### The redaction boundary, derived from core and proved by canary

The collector applies the allowlist **once, before anything leaves the process**,
and the allowlist is not written here — it is **derived from core's schemas**, and
`tests/validate.sh` reads `core/schemas/telemetry/*.json` off disk and compares
**both** ways:

- every attribute core allows on a signal must be in that signal's
  `allowed_keys` (a missing one is a span that arrives uselessly and nobody
  notices);
- nothing may be in it that core does not allow (an extra one is a leak with a
  check attached);
- no allowed name may contain a word core's redaction schema forbids;
- no resource attribute may appear as a measurement attribute.

The check prints the core commit it compared against, because "it passed" against
a spec from six weeks ago is a different statement from "it passed".

`tests/canary_test.sh` then proves it **behaves**, not that it is configured. A
canary string is planted in ten shapes a leak could take — a banned key, an
SDK-default key, the deprecated `exception` span event, a near-miss key, an
*allowlisted* key's value, a resource attribute, a bearer token, a metric data
point, a log attribute, a log body — and the test asserts the canary reaches no
exporter **and that the allowed data survived**. The second half is the half
that is easy to fake: a collector that drops everything passes a "no canary" test
and is useless.

Two things that test found, both of which are in the config because of it:

- **span events are not attributes**, and the redaction processor does not visit
  them, so `exception.message` on a span event bypassed the allowlist entirely;
- **`ignored_keys` is one flat list** applied to resource and measurement
  attributes alike, so exempting `tenant_id` on the resource would also exempt it
  on every data point — the exact cardinality bomb core's metrics schema exists
  to prevent. The config therefore stashes and restores the two identity
  attributes around the redaction processor, and the gate asserts the ordering.

**The log body is the one place free text is expected, and it is NOT scrubbed.**
core requires a body and bounds it at 2048 characters; the redaction processor is
specified over attributes. The canary test reports this rather than quietly
passing, because a reader who assumes the body is scrubbed is exactly the reader
who puts a prompt in one.

## Trace propagation — `templates/otel/`

Every service speaks the same trace context, so a request crossing four cafaye
services reads as one trace.

Each language ships four files:

| File | Use it when |
|------|-------------|
| `traceparent.*` | You need the header handling on its own: a queue consumer, a webhook signer, a background task, a test that asserts propagation without an SDK. Stdlib only. |
| `test_traceparent.*` | Always. It is the contract. |
| `*.snippet` | You serve HTTP. The upstream OTel SDK already does this and also gives you spans and metrics. Versions in [`templates/otel/pins.md`](templates/otel/pins.md); kit vendors nothing. |
| `README.md` | When you are deciding. |

The contract, identical in all six languages:

- a valid inbound `traceparent` is **continued** — same trace-id, sampled flag
  preserved, parent-id replaced with this hop's span id (§3.4);
- a missing or malformed `traceparent` starts a **new** trace and never throws,
  never 4xxs, never panics — a request is not an error because its trace header
  was garbage (§3.2.2.3, §4.2);
- `tracestate` travels with the trace, capped at 512 characters, truncated on
  whole-entry boundaries only (§3.3.1.5);
- a `traceparent` that fails to parse is **not** rescued by a `tracestate`
  alongside it (§3.3).

Reference: [W3C Trace Context, W3C Recommendation 23 November 2021](https://www.w3.org/TR/trace-context/).
Start at [`templates/otel/README.md`](templates/otel/README.md) for the six-way
comparison and the reason there are six implementations of one algorithm.

### Worked example — `courier` adopting propagation

A service that fans a delivery out to `parlor` and publishes to NATS. Three
steps, in this order.

**1. Copy the codec and its suite.** Keep both. The suite is what makes
propagation a build failure instead of a claim in a README.

```sh
cp -R <kit>/templates/otel/elixir/. lib/courier/telemetry/
cp <kit>/templates/otel/elixir/test_traceparent.exs test/
```

**2. Read the trace at the edge.** In a plug, before the controller:

```elixir
def read_trace(conn, _opts) do
  hop = KitOtel.Traceparent.server_hop(conn.req_headers, KitOtel.Traceparent.new_span_id())
  conn
  |> assign(:trace_id, hop.trace_id)
  |> assign(:outbound_trace, hop.outbound_headers())
end
```

`server_hop/2` cannot fail. That is the design, not an omission — see
[`templates/otel/elixir/README.md`](templates/otel/elixir/README.md).

**3. Put it on the wire outbound.** On the `Req` call to `parlor`:

```elixir
Req.post!("#{parlor_url}/deliveries", json: payload, headers: outbound_trace)
```

`outbound_trace` is `{"traceparent" => "00-<trace-id>-<this hop's span id>-01"}`.
The trace-id is the same one that came in, the parent-id is this hop's span, and
`parlor` continues it. That is §3.4, and it is the whole mechanism.

**4. Turn the suite into a build failure:**

```yaml
    with:
      language: elixir
      telemetry: 'true'
```

`bin/dev` then shows the trace locally, because the collector prints spans to
stdout and the service points at it:

```sh
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318 bin/dev
```

## How a service repo adopts kit

A service repo does **not** copy the workflow. It calls it, so a fix in kit
reaches every service on the next run without a per-repo PR.

**1. Call the workflow.** Create `.github/workflows/ci.yml`:

```yaml
---
name: ci
on: [push, pull_request]
permissions:
  contents: read
jobs:
  ci:
    uses: cafaye/kit/.github/workflows/ci.reusable.yml@master
    with:
      language: go          # go | ruby | elixir | python | node | bun | rust | none
      working-dir: .        # the dir holding go.mod / Gemfile / pyproject.toml
```

That path is the whole contract. GitHub resolves a reusable workflow at
`{owner}/{repo}/.github/workflows/{file}@{ref}` and documents that
**subdirectories of the workflows directory are not supported** — so the file
lives at `.github/workflows/ci.reusable.yml` and nowhere else, and `kit`'s gate
asserts that the `uses:` line above is the path the file is actually at, that
the file declares `on: workflow_call`, and that there is no second copy of it
anywhere in the tree. A `uses:` line that does not resolve fails at run time on
the adopting repo's first push, which is thirteen repos and one stale sentence
away.

`{owner}/{repo}/.github/workflows/{file}@{ref}` resolves in **private**
repositories too, so a repo that adopts kit before kit is public is not
blocked; `secrets: inherit` in a caller reaches a private kit from inside the
organization.

Two jobs for two languages? Call it twice with two different `language` values.

`bun` is a first-class `language` value: frozen install from `bun.lock`,
`typecheck`, `bun test`. It exists because `guard` was hand-rolling an entire
workflow for want of one — a repo that has adopted `bun` here can delete that
file and collapse it to the `uses:` above.

`none` is the eighth value, for a repository with **no service manifest at all**
— no `go.mod`, no `Gemfile`, no `pyproject.toml`. The other seven jobs each
open by reading one, so there was no way for such a repository to call this
workflow; in practice that excluded `kit` itself, which is why `kit`'s own CI is
a `uses: ./.github/workflows/ci.reusable.yml` with `language: none`, and why
the repository that defines the standard is the first one held to it. That job
runs your repository's own `tests/validate.sh` and **fails if it is missing** —
a config gate with no gate in it is the same defect as a coverage threshold left
at `0`.

**2. Copy the linter config** that matches your language into the repo root, so
the config is part of the code review that changes the code:

```sh
cp <kit>/lint/golangci.yml  .golangci.yml     # go
cp <kit>/lint/rubocop.yml    .rubocop.yml      # ruby
cp <kit>/lint/eslint.config.mjs eslint.config.mjs   # node / typescript / bun
cp <kit>/lint/yamllint.yml   .yamllint.yml     # any repo with YAML
```

**3. Copy the Dockerfile and the two scripts.** Rename the Dockerfile to
`docker/Dockerfile`, the primer to `bin/prime`, and the dev loop to `bin/dev`:

```sh
cp <kit>/docker/Dockerfile.go          docker/Dockerfile
cp <kit>/templates/bin-prime/go.sh     bin/prime
cp <kit>/templates/bin/dev.sh          bin/dev
chmod +x bin/prime bin/dev
```

Set `SERVICE_NAME` (Go, Rust) or the `:app` release name (Elixir) to your real
binary or application name. `bin/dev` needs `docker-compose.yml`,
`otel-collector.yml` and `.env` beside it — see
[the local stack](#the-local-stack--templatescompose).

**4. Copy `templates/mise.toml` to `mise.toml`** and raise every placeholder to
the version you actually deploy. kit's values are placeholders, not an org-wide
lockfile — see the comments at the top of that file.

**5. Copy `templates/AGENTS.md` to `AGENTS.md`** and fill in the placeholders.

**6. Provide a coverage command.** The gate is a placeholder (`0`) on day one so
adoption never blocks a repo, but a gate that can never fail is not a gate. Each
language already has the expected command:

| Language | Coverage command the job runs |
|----------|-------------------------------|
| go | `go test -coverprofile=coverage.out ./...` then `go tool cover -func` against `COVERAGE_FAIL_UNDER` |
| rust | `cargo llvm-cov --fail-under-lines` |
| ruby | `bundle exec rake coverage` (add a `coverage` task to the Rakefile) |
| elixir | `mix coveralls --minimum-coverage` (declare the `coveralls` hex dep) |
| python | `pytest --cov --cov-report=xml` then `coverage report --fail-under` |
| node | `npm run coverage` |

Then raise `COVERAGE_FAIL_UNDER` in your CI caller:

```yaml
    with:
      language: go
      coverage-fail-under: '80'   # passed through as an env override
```

**7b. Opt into trace propagation**, once you have copied
`templates/otel/<lang>/`:

```yaml
    with:
      language: go
      telemetry: 'true'          # runs the W3C conformance suite on every push
```

It is opt-in and defaults to `'false'`, so adopting kit never turns a green repo
red. It is a string rather than a boolean on purpose: GitHub coerces the bare
word `false` to a boolean in some positions, and `if: inputs.telemetry` is a trap
as a result.

**7c. Declare your tiers, then demand one.** Copy
`templates/tier/<lang>/` into your test tree and copy the `REQUIRED_<TIER>=1`
gate variable into the suite — a tier that cannot fail is a skip wearing a
green checkmark. Then name it in the caller:

```yaml
    with:
      language: go
      required-tier: 'REQUIRED_DB'   # exported as 1; zero tests then fails
```

Setting it commits you to the normalised result format
(`templates/tier/README.md`) — the `tier demand` step reads a `ran` line out of
the run log and fails **naming the variable** when the tier ran nothing. It is
opt-in and defaults to `''`, so adopting it never turns a green repo red.

**7. Run kit's own gate before you open the PR that adopts it:**

```sh
bash <kit>/tests/validate.sh
```

### Adoption checklist

- [ ] `.github/workflows/ci.yml` calls `cafaye/kit/.github/workflows/ci.reusable.yml@master`
- [ ] `working-dir` points at the dir holding the manifest
- [ ] Linter config copied to the repo root, unmodified
- [ ] `docker/Dockerfile` copied, binary/application name set
- [ ] `bin/prime` copied, `chmod +x`, green on a fresh clone
- [ ] `bin/dev` copied, `chmod +x`, `bin/dev up` green on a fresh clone
- [ ] `docker-compose.yml` + `otel-collector.yml` copied, ports parameterized
- [ ] `mise.toml` copied, every placeholder raised to a shipped version
- [ ] `AGENTS.md` copied and filled in
- [ ] A coverage command exists and `COVERAGE_FAIL_UNDER` is above 0
- [ ] If you propagate traces: `templates/otel/<lang>/` copied **with its suite**, `telemetry: 'true'`
- [ ] If you have a tier: `templates/tier/<lang>/` copied, `REQUIRED_<TIER>=1` honoured,
      `required-tier` named in the caller
- [ ] No `actions/cache` step caches a test report
- [ ] `CHANGELOG.md` has an entry
- [ ] The workflow is green on the adoption PR

## Test tiers — `templates/tier/`

A **tier** is a class of test that needs a real dependency to mean anything: a
database, Redis, a broker. The failure this exists to prevent has already
happened in this fleet — **a green run in which the whole database tier never
executed once**, because the suite reported `ok`, and `ok` is the only thing
anybody read.

Tier membership is **declared in the test source** and read by **the runner's
own collector**. It is never grepped for a sentinel, because a sentinel fails
*open*: Identity derives its database tier by grepping for
`dbtest.Pool|Schema|EnvVar|TEST_DATABASE_URL`, and a test that reaches Postgres
through a helper two files away, or through a fixture, does not match — so its
package never enters the required list, and the run is never required to contain
it. The test is written. It is not gated. Nobody finds out.

| `language` | Declaration | Collector | Adapter? |
|---|---|---|---|
| `rust` | `#[ignore = "cafaye:tier=db reason=…"]` | `cargo test -- --list` | none |
| `go` | `//go:build tier_db` | `go test -tags tier_db -list '.*' ./...` | none |
| `python` | `@pytest.mark.tier_db` | `pytest --collect-only -q -m tier_db` | none |
| `elixir` | `@tier :db` | none — needs one | ~15 lines |
| `node` | `export const TIER` | none — needs one | ~15 lines |
| `bun` | `export const TIER` | `bun test --reporter=junit` (partial) | ~15 lines |
| `ruby` | `tier :db` class macro | none — needs one | ~15 lines |

Two results here were **measured rather than assumed**, and both corrected the
prior claim:

- `cargo test -- --list --format json` is **nightly-only** (`-Z
  unstable-options`, rustc 1.95.0). On stable, `--list` includes ignored tests
  and `--list --ignored` gives the ignored subset — which between them carry
  everything the JSON would have. `--list --include-ignored` lists *everything*
  and filters nothing; it is a trap, and the Rust template says so.
- `bun test --reporter=junit` **does** emit a full inventory — a filtered-out
  test is still present as a `<testcase>` — so the absent-testcase failure mode
  does not occur there. What it lacks is a declared *reason*: `test.skip` takes
  none.

The normalised result format, the skip allowlist and its four hygiene rules, the
`REQUIRED_<TIER>` demand, and **what a tier gate cannot catch** are all in
[`templates/tier/README.md`](templates/tier/README.md). The short version of the
last one: the machinery can prove *"41 tests ran"*; only an assertion **inside**
the test proves *"41 tests hit Postgres"*. A gate whose documentation overstates
it is worse than no gate.

**Floors are decrease detectors, not tier gates.** Identity's
`1254/1166`-style floors are cheap and they catch deletion — keep them. But a
floor is satisfied by *any* 1254 tests, including the wrong 1254, and nothing
about it knows which tier a test belongs to.

### Never cache a test report

`actions/cache` `restore-keys` restores **stale** caches by **prefix match**,
and GitHub documents that the default branch's cache is available to other
branches. So a cache key built from `hashFiles('**/lockfile')` — which does not
contain the gate variable — restores a test report written by a run that **had**
the database into a run that does not.

**A witness restored from a different run is not a witness.**

Cache `target/`, `$GOCACHE`, `node_modules`, `vendor/bundle`. Those are build
products. Do not cache `junit.xml`, `test-results/`, `coverage.*`, or anything
else a gate would read as evidence. `tests/validate.sh` fails when an
`actions/cache` step names one.

There is a second, sharper version of this that no check in a single repo can
catch: **fork pull requests get read-only cache access**, so a workflow using
`actions/cache` lets a fork restore a trusted run's cached report into its own
run. That is a cross-trust-boundary path into the gate, and it exists today in
any workflow that caches at all. Treat a cached report as untrusted input.

## Design rules

These are the rules that keep kit from becoming the thing it exists to prevent.

- **Config only.** No runtime code, no library, no build step. If kit grows a
  dependency, it has stopped being conventions.
- **A caller overrides, it never forks.** Values that differ per service —
  versions, coverage thresholds, service names — are inputs or build args, not
  copies. Six repos that each hold their own copy of a workflow is the drift
  this repo exists to prevent.
- **Boring beats clever.** Flat layout, no framework, no generator. `grep` finds
  everything here.
- **Strictness is documented, not implied.** Every config carries comments
  explaining what is enforced and why, so a future contributor relaxes it
  deliberately instead of by accident.
- **The gate is the contract.** `tests/validate.sh` is the definition of done
  for every artifact here, and it fails on any file that does not parse.

## Working on kit

```sh
bash tests/validate.sh
```

That is the entire procedure on a clean clone. The gate installs its own
dependencies — PyYAML and yamllint — into the gitignored `.venv/` on first run
and prints a `note:` line saying so. There is no prerequisite step, because a
prerequisite that is documented rather than automated is one that gets skipped
by exactly the machine you most wanted to hear from.

This bit twice. It used to exit 1 with `no python with PyYAML` because it
preferred `.venv/bin/python` and fell back to `python3`, and `.venv` is
gitignored — so **every fresh clone and every CI runner** hit it, including the
CI job this repository now runs on itself.

`tests/validate.sh` runs in three phases and prints one line per check.

**static** — every artifact parses, and the strictness decisions are still what
we wrote them down to be:

- `.sh` → `bash -n`, plus `shellcheck -S warning` when shellcheck is installed
- `.yml` / `.yaml` → `python` `yaml.safe_load`
- **every** `.yml` / `.yaml` in the tree → `yamllint -c lint/yamllint.yml`,
  enumerated by `git ls-files` rather than a hand-kept list. Required, not
  optional: a repo that copies `lint/yamllint.yml` lints its own CI against it
  on day one, so a YAML that breaks the config greets the first adopter with a
  failure nobody authored
- `.mjs` → `node --check`
- `templates/tier/<lang>/*` → parsed in **their own language**, because they are
  files a service copies: `rustc --test` (Rust, and `--list` proves the
  inventory the allowlist reads), `compile()` (Python), `ruby -c`,
  `Code.string_to_quoted!` (Elixir), `gofmt` (Go). TypeScript is a loud `SKIP`
  naming its reason — stock `node --check` cannot read it, and a type-stripping
  parser is a dependency this repo does not have
- `docker/Dockerfile.*` → `hadolint -c lint/hadolint.yaml`, **plus** the
  non-root / no-`:latest` / no-`ADD` rules hadolint does not cover, **plus** a
  requirement that each template's own STRICTNESS NOTES state the non-root
  guarantee. Required, not optional: see
  [what the gate lints the Dockerfiles with](#what-the-gate-lints-the-dockerfiles-with-and-why)
- handed-out scripts → must be executable
- every language in the CI workflow must have a Dockerfile, a `bin/prime` and a
  `[tools]` pin — "half a language is worse than none"
- the collector must have no exporter but `debug`, no literal URL, and every
  `${env:...}` it reads must actually be passed into the container
- every published compose port must be a `${KIT_*:default}` substitution
- the reusable workflow must be **callable**: at the path the docs tell
  callers to use, declaring `on: workflow_call`, with every documented
  `uses:` matching it exactly, `kit`'s own CI calling it with the local `./`
  form, and no second copy anywhere in the tree
- the `telemetry` CI job must stay opt-in and the six original jobs must stay
  gated on their language, or adopting kit breaks every consumer
- every language with a CI job must also ship a **tier declaration** in
  `templates/tier/<lang>/` and have a row in that directory's README naming the
  collector that reads it — see [Test tiers](#test-tiers--templatestier)
- the `required-tier` input must stay opt-in (default `''`), be exported by
  every language job, and be checked by an identical `tier demand` step in each
  one. The six copies are byte-compared, because hand-maintained copies of a
  policy block is the drift this repo exists to prevent
- the skip allowlist must satisfy four rules — **reason, owner, `since`,
  `until`** — and **an entry matching nothing is a failure**. The total is
  printed on every run, green included
- no `actions/cache` step may cache a test report

**telemetry** — the W3C traceparent suites are **executed**, one per language:

```sh
bash tests/validate.sh --language=go     # one language
bash tests/validate.sh --static-only     # no toolchains needed
```

Stdlib only and offline on purpose: no `go mod download`, no `bundle install`,
no `npm ci`, no `cargo fetch`. If these ever need the network, a template has
grown a dependency and kit has stopped being config-only.

**self_test** — `tests/self_test.sh` breaks a throwaway copy of this tree
**twenty** ways and asserts the gate goes red each time. Fourteen breakages are
for the static checks; one is a semantic mutation of each of the six language
implementations, so **every suite is proven able to fail** rather than assumed
to. A skip fails the run — a self_test that skips half its proofs and exits 0 is
the "0 passed, 14 ignored" shape that verifies nothing. Seven of the static
ones go further and assert that one *named* check reported `FAIL`, so the check
written for a given defect is proven still load-bearing rather than being one
of fifty checks that could have gone red for an unrelated reason.

Breakage 19 is the allowlist one: an entry naming a test that does not exist,
well-formed in every other respect. It is the rule most able to be decorative —
a hygiene rule in a data file is exactly the shape of a check nobody has ever
seen fail.

Any `FAIL` exits 1. A `SKIP` is always reported in the summary, never hidden.
PyYAML, yamllint and hadolint are required and are **bootstrapped by the gate
itself**; the six language toolchains and `shellcheck` run when present.

### What the gate lints the Dockerfiles with, and why

`docker/Dockerfile.*` is the one artifact here that used to have **no parser at
all** — seven lines reading `SKIP ... (no parser for this file type)`, honest,
and completely uncovered. It now has two layers:

- **`hadolint -c lint/hadolint.yaml`** — a real parser, required, pinned to
  2.15.1 and verified against hadolint's published `checksums.sha256`. Not
  optional: hadolint is a single static binary the gate fetches on first run, so
  "it was not installed" is not an excuse available to anyone, and a linter that
  is silently a different version is the same skip wearing a pass.
  `failure-threshold: warning` — hadolint's `info` tier is advisory style, and a
  gate people run with `--no-fail` is not a gate. The **one** ignored rule is
  DL3008 ("pin apt versions"), and the argument for it is written out in
  `lint/hadolint.yaml`: these are templates thirteen repos copy, so a hardcoded
  `build-essential=12.9` is a version thirteen people must remember to bump,
  and the day Debian drops that build every one of them fails at once — a
  correlated outage caused by a security patch landing.
- **`docker/Dockerfile.*  (non-root final stage, no :latest, no ADD)`** — the
  two properties hadolint does **not** cover. DL3002 only fires when a `USER` is
  present and wrong; a *missing* `USER` is silence, and silence is how an image
  ships running as root. `ADD` is refused because it can fetch a URL, so it is a
  way to put unverified content in an image without a hash.

A third check requires each template's `STRICTNESS NOTES` to state the non-root
guarantee in the file itself. All seven do run non-root, and the check above
proves it; this one is about the reader deciding whether to adopt the file, who
reads the notes and not the gate.

hadolint found one real defect on its first run, which is the argument for
having run it: `docker/Dockerfile.python` did `pip install uv` with no version,
so the resolver's own version silently decided what a build resolved. It is now
`ARG UV_VERSION=0.5.11`, in step with the `uv` pin in `templates/mise.toml`.

It also found a documentation bug, which is the argument for the third check:
`Dockerfile.bun`'s notes said *"The official image has no unprivileged user, so
we create one."* The official `oven/bun:1.3.12-slim` image ships `bun` at uid
1000 (verified against the running container), and the `useradd` that note
described was never in the file — so the note described a different Dockerfile
than the one being read.
