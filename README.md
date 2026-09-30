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

Every one of those repos calls the same workflow, copies the same linter
configs, and primes a fresh worktree with the same script. A change to how we
build lands in kit once, and reaches the next service in a pull request.

## What is in here

| Path | What it is | Who uses it |
|------|-----------|-------------|
| `workflows/ci.reusable.yml` | One reusable GitHub Actions workflow. Input `language` picks one of seven jobs — install, lint, test, coverage gate. Opt-in `telemetry` input adds the traceparent conformance job. No job builds or pushes an image. | Every service, via a 6-line `.github/workflows/ci.yml` |
| `lint/yamllint.yml` | YAML style, with the three rules Actions forces us to retune. | Any repo that lints its own YAML; kit's gate uses it on itself |
| `lint/golangci.yml` | golangci-lint v2, correctness linters on, `errcheck` excluded only for `Close`/`Flush`. | Go services |
| `lint/rubocop.yml` | RuboCop, `NewCops: enable`, Metrics left on. | Ruby services |
| `lint/eslint.config.mjs` | ESLint 9 flat config, type-checked rules on. | Node/TypeScript/Bun services |
| `docker/Dockerfile.<lang>` | Seven multi-stage templates. `go` and `rust` finish on distroless; the rest finish on `*-slim`. All run non-root. | Every service |
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
| `templates/mise.toml` | Toolchain pins, one per language, commented. | Every service, as `mise.toml` |
| `templates/AGENTS.md` | Skeleton repo-conventions file. | Every service, as `AGENTS.md` |
| `tests/validate.sh` | kit's own suite — the gate. | kit |

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
then it brings up a service with `*_OTEL_ENDPOINT` pointed at a collector that
does not exist and checks that service comes up healthy, keeps serving, and does
not restart.

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
    uses: cafaye/kit/workflows/ci.reusable.yml@master
    with:
      language: go          # go | ruby | elixir | python | node | bun | rust
      working-dir: .        # the dir holding go.mod / Gemfile / pyproject.toml
```

Two jobs for two languages? Call it twice with two different `language` values.

`bun` is a first-class `language` value: frozen install from `bun.lock`,
`typecheck`, `bun test`. It exists because `guard` was hand-rolling an entire
workflow for want of one — a repo that has adopted `bun` here can delete that
file and collapse it to the `uses:` above.

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

**7. Run kit's own gate before you open the PR that adopts it:**

```sh
bash <kit>/tests/validate.sh
```

### Adoption checklist

- [ ] `.github/workflows/ci.yml` calls `cafaye/kit/workflows/ci.reusable.yml@master`
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
- [ ] `CHANGELOG.md` has an entry
- [ ] The workflow is green on the adoption PR

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
python3 -m venv .venv && .venv/bin/pip install -r tests/requirements.txt
bash tests/validate.sh
```

`tests/validate.sh` runs in three phases and prints one line per check.

**static** — every artifact parses, and the strictness decisions are still what
we wrote them down to be:

- `.sh` → `bash -n`, plus `shellcheck -S warning` when shellcheck is installed
- `.yml` / `.yaml` → `python3` `yaml.safe_load`, plus `yamllint -c lint/yamllint.yml`
- `.mjs` → `node --check`
- handed-out scripts → must be executable
- every language in the CI workflow must have a Dockerfile, a `bin/prime` and a
  `[tools]` pin — "half a language is worse than none"
- the collector must have no exporter but `debug`, no literal URL, and every
  `${env:...}` it reads must actually be passed into the container
- every published compose port must be a `${KIT_*:default}` substitution
- the `telemetry` CI job must stay opt-in and the six original jobs must stay
  gated on their language, or adopting kit breaks every consumer

**telemetry** — the W3C traceparent suites are **executed**, one per language:

```sh
bash tests/validate.sh --language=go     # one language
bash tests/validate.sh --static-only     # no toolchains needed
```

Stdlib only and offline on purpose: no `go mod download`, no `bundle install`,
no `npm ci`, no `cargo fetch`. If these ever need the network, a template has
grown a dependency and kit has stopped being config-only.

**self_test** — `tests/self_test.sh` breaks a throwaway copy of this tree
eleven ways and asserts the gate goes red each time. Five breakages are for the
static checks; one is a semantic mutation of each of the six language
implementations, so **every suite is proven able to fail** rather than assumed
to. A skip fails the run — a self_test that skips half its proofs and exits 0 is
the "0 passed, 14 ignored" shape that verifies nothing.

Any `FAIL` exits 1. A `SKIP` is always reported in the summary, never hidden.
PyYAML and yamllint are required (`tests/requirements.txt`); the six language
toolchains and `shellcheck` run when present.
