# AGENTS.md — <service-name>

> kit template. Copy to `AGENTS.md` in a service repo, replace every `<...>`
> placeholder, and delete the sections that do not apply. This file is the
> contract an agent (or a new hire) reads before touching the repo: if a rule
> is not written here, it is not a rule.

## What this service is

- **Name:** `<service-name>`
- **Language / toolchain:** `<go | ruby | elixir | python | node | rust>` — pinned in `mise.toml`
- **Owns:** `<the one responsibility, in one sentence>`
- **Does not own:** `<the neighbouring services it must not grow into>`
- **Upstream specs:** `core`'s `cafaye.yml` manifest, OpenAPI, and event
  schemas. The spec is the source of truth; the code follows it, never the
  reverse.

## Layout

```
<service-name>/
├── mise.toml            # toolchain pins — the only place a version is written
├── bin/prime            # from kit: templates/bin-prime/<lang>.sh
├── docker/Dockerfile    # from kit: docker/Dockerfile.<lang>
├── .golangci.yml        # from kit: lint/*.yml, whichever apply
├── .github/workflows/ci.yml   # one caller; all the work lives in kit
└── <src layout>
```

## Commands

Run these; do not improvise equivalents.

| Task | Command |
|------|---------|
| Prime the worktree | `bin/prime` |
| Prime without tests | `bin/prime --fast` |
| Run tests | `<the suite command>` |
| Run the linter | `<the lint command>` |
| Coverage gate | `<the coverage command>` |
| Everything CI runs | `bin/prime` — CI runs the same steps in the same order |

## Conventions

- **Never** edit a lockfile as a side effect (`go.sum`, `Gemfile.lock`,
  `mix.lock`, `uv.lock`, `package-lock.json`, `Cargo.lock`). A lockfile change
  is its own commit with its own reason.
- **Never** weaken a linter, add an inline disable, or raise a threshold to
  make a build green. Fix the code, or open a PR that says why the rule is
  wrong.
- **Never** copy code from `moon/refs/` into this repo. Those trees are
  behavioral references only; every line here is written from scratch.
- Errors are wrapped at the boundary (`errorlint`, `Error` structs) and carry
  the identifier needed to find the failing row, not just a message.
- Money is integer minor units. Time is UTC. IDs are opaque strings.

## The local stack

**You do not copy kit's stack.** There is no `docker-compose.yml` of kit's in this
repository, no `otel-collector.yml`, and no `tempo/`, `loki/`, `mimir/` or
`grafana/`. `bin/dev` fetches all of it from a **pinned** ref and runs it beside
your own `docker-compose.yml`, which is an **override** — the second `-f`, so what
is in it wins and everything you did not mention still comes from kit.

- **`kit.ref`, one committed line at the repository root, is the pin.** A
  40-character commit sha, or a `v<MAJOR>.<MINOR>.<PATCH>` tag. **Never a branch**,
  and never a variable in `.env`: `.env` is git-ignored, so a pin there exists on
  one machine and on no CI runner. `bin/dev` refuses a branch loudly, before any
  network call. `bin/dev pin <ref>` moves it deliberately and prints the stack diff
  first.
- **Your `docker-compose.yml` may** set `image:`, add keys to `environment:`, add
  a `depends_on`, declare your own services, and change a published port **by
  changing the variable in `.env`**.
- **Your `docker-compose.yml` may not** touch `otel-collector` — not its `image:`,
  not its `command:`, and above all not the `volumes:` entry that mounts
  `otel-collector.yml`. That file carries the redaction allowlist, and it is
  **derived from core's schemas**; owning it means shipping a telemetry boundary
  nobody derived, and prompt content leaves the process inside it. Nor may you
  override the four AGPL backends, set `allow_all_keys`, or add an exporter.
- **A `ports:` entry for a service kit ships is a bug, and a quiet one.** Compose
  **appends** a second file's `ports:` list rather than replacing it, so writing
  one publishes postgres on kit's port *and* on yours. Move the port in `.env`.
  This is measured, not folklore, and kit's gate fails on it.
- **Pointing at your own database is an override, not a second container:**
  `services.postgres.environment.POSTGRES_DB`. `environment:` merges by key, so
  kit's healthcheck, volume and port survive.

## Observability

On by default. Not opt-in, and not something a developer turns on to see traces
(PLAN.md §7b, user directive 2026-09-30).

- **`<SERVICE>_OTEL_ENDPOINT` is the only contract** — `MUSE_OTEL_ENDPOINT`,
  `CAF_OTEL_ENDPOINT`, `DARKSROOM_OTEL_ENDPOINT`, whatever this service is
  called, uppercase, no `OTEL_EXPORTER_` prefix and no `_EXPORTER_` infix. Its
  DEFAULT is the collector that ships with `bin/dev`, which is why a developer
  sees real traces with nothing configured.
- **A self-hoster who already runs Datadog, Honeycomb or Grafana Cloud sets that
  variable** and the shipped stack goes quiet for this service. Bring-your-own
  is a supported deployment, documented as carefully as the default, not a
  degraded mode.
- **Turning telemetry off is one variable.** Unset it and the exporter is a
  genuine no-op: no queue, no retry loop against a dead endpoint, no warning per
  request, no dial at boot. Implement that with `OTEL_SDK_DISABLED` — the
  OpenTelemetry spec's own switch — rather than a cafaye reimplementation, and
  check `OTEL_TRACES_EXPORTER`, `OTEL_METRICS_EXPORTER` and
  `OTEL_LOGS_EXPORTER` too. A no-op that only covers traces still phones home
  for metrics, and that is the failure a customer's invoice finds first.
- **Telemetry is NEVER in a readiness path.** Not in `/healthz`, not in
  `/readyz`, not in a `depends_on`, not in a compose healthcheck. A service that
  waits for the collector serves no traffic while the collector is down, which
  is strictly worse than serving traffic with no traces. `kit`'s
  `tests/no_telemetry_in_readiness.sh` proves this against a real collector;
  a service that breaks it will not be caught there, so it is written down here.
- **`error.type` is a bounded class, never a message.** snake_case, 64
  characters, from the fleet vocabulary. `error.message` and
  `error.stacktrace` are prohibited by name: a provider's content-policy
  rejection quotes the offending content back at you, so the message is a
  prompt by another route. The predicate for "this is an error" is span STATUS,
  not `error.type`.
- **Exceptions are LOG RECORDS.** The `exception` span event is deprecated; an
  exception log record with a severity chosen by expected impact replaces it.
- **The collector enforces the redaction allowlist** (core's
  `redaction.schema.json`, `enforcedAt: collector`). The per-service SDK
  allowlist is defence in depth, not the only line — and a service pointing
  `*_OTEL_ENDPOINT` at a vendor backend is exactly the case where the collector
  is the only line.

## Testing

- Tests are written **first**, and shown failing before the implementation.
- No sleeps, no raised retries, no loosened assertions. A flaky test is
  attributed before it is fixed: failing test → can this diff reach that
  surface → measure the baseline at a clean HEAD.
- Coverage is gated in CI (see `COVERAGE_FAIL_UNDER` in the CI caller). Raising
  the gate is allowed; lowering it is not.

## Contracts

- Every endpoint and event this service exposes or consumes is generated from
  `core`'s specs and validated in CI. Never hand-write a response shape.
- Breaking a contract is a major version plus a migration note in `README.md`
  and `CHANGELOG.md`, reviewed by a human — not a patch.

## Before you open a PR

- [ ] `bin/prime` is green from a clean worktree
- [ ] New behavior has a test that fails without it
- [ ] Lint and coverage gates are green, and nothing was disabled to get there
- [ ] `AGENTS.md` still describes the repo as it now is
- [ ] `CHANGELOG.md` has an entry
