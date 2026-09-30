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
| `.github/workflows/ci.reusable.yml` | One reusable GitHub Actions workflow. Input `language` picks one of seven jobs — install, lint, test, coverage gate. Opt-in `telemetry` input adds the traceparent conformance job. No job builds or pushes an image. | Every service, via a 6-line `.github/workflows/ci.yml` |
| `lint/yamllint.yml` | YAML style, with the three rules Actions forces us to retune. | Any repo that lints its own YAML; kit's gate uses it on itself |
| `lint/golangci.yml` | golangci-lint v2, correctness linters on, `errcheck` excluded only for `Close`/`Flush`. | Go services |
| `lint/rubocop.yml` | RuboCop, `NewCops: enable`, Metrics left on. | Ruby services |
| `lint/eslint.config.mjs` | ESLint 9 flat config, type-checked rules on. | Node/TypeScript/Bun services |
| `docker/Dockerfile.<lang>` | Seven multi-stage templates. `go` and `rust` finish on distroless; the rest finish on `*-slim`. All run non-root. Linted by `hadolint -c lint/hadolint.yaml`, plus a non-root/no-`:latest`/no-`ADD` check the linter does not cover. | Every service |
| `lint/hadolint.yaml` | hadolint config, with the one ignored rule (DL3008) argued rather than assumed. | Any repo that ships a Dockerfile |
| `templates/bin-prime/<lang>.sh` | The worktree primer: one script per language, exit 0 only when the tree is genuinely ready. | Every service, as `bin/prime` |
| `templates/bin/dev.sh` | The local developer loop: bring the stack up, wait for health, migrate, seed an admin, print the URLs. Idempotent, fails loudly. | Every service, as `bin/dev` |
| `templates/compose/docker-compose.yml` | Postgres, NATS+JetStream, Redis and the OTel collector. Every port parameterized, every image pinned, every service healthchecked. | Every service, as `docker-compose.yml` |
| `templates/compose/otel-collector.yml` | The collector: OTLP receiver, batch processor, and a `debug` exporter that writes to stdout. **Ships nothing.** | Every service, as `otel-collector.yml` |
| `templates/compose/.env.example` | Every `${KIT_*}` the stack interpolates, each with a default. | Every service, as `.env.example` |
| `templates/otel/<lang>/` | W3C traceparent: a stdlib codec, an executed conformance suite, an SDK snippet, and a README. | Every service, per language |
| `templates/mise.toml` | Toolchain pins, one per language, commented. | Every service, as `mise.toml` |
| `templates/AGENTS.md` | Skeleton repo-conventions file. | Every service, as `AGENTS.md` |
| `core/` | The `cafaye/core` fan-out: a `vendir.yml` per consuming repo, the one shared Renovate policy, and what `core` needs to publish semver tags. | Any repo that consumes core's schemas |
| `tests/classify.py` | Classifies a change to a vendored schema set into `FILE`/`PACKAGE`/`WIRE_JSON`/`WIRE`, and **fails closed** on anything `tests/rules.json` does not name. Stdlib only. | Any repo that vendors core |
| `tests/staleness.py` | Reads every consuming repo's recorded pin, resolves where `core` is now, prints the distance. `--fail-on-behind` turns it into a gate. | Scheduled, fleet-wide |
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

## The local stack — `templates/compose/`

Postgres, NATS with JetStream, Redis, and an OpenTelemetry collector. One stack,
one set of credentials, one command, for every service.

```sh
cp <kit>/templates/compose/docker-compose.yml ./docker-compose.yml
cp <kit>/templates/compose/otel-collector.yml  ./otel-collector.yml
cp <kit>/templates/compose/.env.example        ./.env
cp <kit>/templates/bin/dev.sh                  ./bin/dev && chmod +x bin/dev

bin/dev            # up, wait for health, migrate, seed, print URLs
bin/dev status     # what is running
bin/dev logs nats  # tail one service
bin/dev down       # stop, keep the data
bin/dev nuke       # stop and DELETE the data
```

It is a **template with placeholders**, not a fixed stack. Every published port
is `${KIT_*:default}`, every image is pinned to an exact tag, and every service
has a healthcheck so `up --wait` can mean something. A service joins by adding a
`depends_on` and copying the connection URLs into its own `.env`.

`bin/dev` is idempotent — run it twice and nothing changes — and it fails loudly
rather than half-starting: if the stack does not become healthy it prints what is
unhealthy and its logs, and stops *before* migrating, so a failed `up` cannot
leave a half-migrated database behind.

**The collector ships nothing.** Its only exporter is `debug`, which writes spans
to the collector's own stdout on the machine already running it. It publishes no
host port, so it is reachable by service name over the compose network and from
nowhere else. To send spans to a backend you add an exporter block yourself and
point it at a `${env:...}` endpoint; a literal endpoint fails kit's gate, so it
cannot reach a repo by accident. This is a privacy boundary, not a preference:
traces carry request paths, user identifiers, and occasionally a token in a span
attribute.

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

**telemetry** — the W3C traceparent suites are **executed**, one per language:

```sh
bash tests/validate.sh --language=go     # one language
bash tests/validate.sh --static-only     # no toolchains needed
```

Stdlib only and offline on purpose: no `go mod download`, no `bundle install`,
no `npm ci`, no `cargo fetch`. If these ever need the network, a template has
grown a dependency and kit has stopped being config-only.

**self_test** — `tests/self_test.sh` breaks a throwaway copy of this tree
eighteen ways and asserts the gate goes red each time. Twelve breakages are for
the static checks; one is a semantic mutation of each of the six language
implementations, so **every suite is proven able to fail** rather than assumed
to. A skip fails the run — a self_test that skips half its proofs and exits 0 is
the "0 passed, 14 ignored" shape that verifies nothing. Six of the static ones
go further and assert that one *named* check reported `FAIL`, so the check
written for a given defect is proven still load-bearing rather than being one
of fifty checks that could have gone red for an unrelated reason.

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
