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
| `.github/workflows/ci.reusable.yml` | One reusable GitHub Actions workflow. Input `language` picks one of seven jobs — install, lint, test, coverage gate. **Plus two security jobs: `secrets` (no opt-in) and `zizmor` (opt-in).** No job builds or pushes an image. | Every service, via a 6-line `.github/workflows/ci.yml` |
| `.gitleaks.toml` | The secret-scanner allowlist, and nothing else. `extend.useDefault = true`, so the rules stay gitleaks'. Every entry carries a `description`. | Copied verbatim by every service |
| `.github/zizmor.yml` | zizmor's reasoned baselines. One entry. `unpinned-uses` is deliberately **absent** — see `DECISIONS.md`. | Every service, copied verbatim |
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
| `templates/secrets/` | The runtime credential-leak canary. A **language-neutral contract** plus the Go adapter. Five vectors, each with its own red proof. | Every service |
| `templates/mise.toml` | Toolchain pins, one per language, commented. | Every service, as `mise.toml` |
| `templates/AGENTS.md` | Skeleton repo-conventions file. | Every service, as `AGENTS.md` |
| `tests/validate.sh` | kit's own suite — the gate. | kit |
| `tests/gitleaks_gate.sh` | The one secret scan. Run by the `secrets` job **and** by the gate. | Every service, copied verbatim |
| `tests/zizmor_gate.sh` | The one zizmor split: `unpinned-uses` recorded, every other audit fatal. | Every service, copied verbatim |

## Secrets — two scanners, two questions

Neither of these substitutes for the other, and the second one has no
off-the-shelf implementation at all.

**`secrets` (no opt-in).** gitleaks over the **full history** of the adopting
repo, with `--redact`. It answers *was a credential committed*.

Why gitleaks and not trufflehog: trufflehog is **AGPL-3.0**, which is a
licensing decision with teeth for a product that sells code, and it is the only
candidate that verifies live credentials against the issuer's API — exactly the
wrong behaviour for a fleet whose CI has network access. gitleaks is MIT, a
single static binary, needs no network, and `--redact` is mandatory so CI never
prints the secret it just found.

It is the one job in the workflow with **no opt-in**, and that is deliberate: an
opt-in security control is not a control. `continue-on-error` is the one setting
that would turn it into a report, and `tests/validate.sh` fails if it appears.

> **Adopting this may make your first build red.** If your repository has a
> credential anywhere in its history, the scanner will find it. That is the
> scanner working. **Rotate the credential first** — a scan finding a secret is
> not a plan for it. Then, if it was a false positive, add an entry to your
> `.gitleaks.toml` with a `description` explaining why. Do not add
> `continue-on-error`, and do not add a `.gitleaksignore`: both fail the gate.

**`zizmor` (opt-in).** The GitHub Actions security audit, on your own workflows.
It answers *what is the shape of your CI*. Off by default because it reads
workflows kit did not write, and a red build for someone else's finding is not a
fair day one.

**`templates/secrets/`** answers the question neither of them does: *does a
credential leave the process while the tests run?* It plants a fake credential
— `cafaye_canary_` plus 32 bytes, assembled at run time so it is safe to commit
— and sweeps five vectors: log/stdout/stderr, unknown serialisation fields, the
whole error chain, keys that are present-but-empty, and Go type coverage. The
contract is in [`templates/secrets/README.md`](templates/secrets/README.md); the
Go adapter is in `templates/secrets/go/`, and only Go has one so far.

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

**Your first build may be red, and it is probably the secret scanner.** The
`secrets` job has no opt-in, and it reads the **full history** of your
repository. If a credential has ever been committed — even one you deleted in
the same PR — it will find it. That is the scanner working, and it is the reason
the scan is not diff-only: a deleted secret is still in the packfile of anyone
who cloned, and still on every fork.

In order:

1. **Treat the credential as compromised and rotate it.** A scanner finding a
   secret is not a plan for it, and nothing below is a substitute for rotating.
2. If it was a false positive, copy `.gitleaks.toml` into your repo root and add
   one `[[allowlists]]` entry with a `description` saying what is allowed and
   why. A description under 40 characters fails the check, and an entry with
   none fails harder: an allowlist that grows and is never pruned is not an
   allowlist, it is a deferred disclosure.
3. **Never** add `continue-on-error` to the `secrets` job, and **never** create a
   `.gitleaksignore`. Both fail `tests/validate.sh`, and both are the two ways a
   security job becomes a report while the badge stays green.

The `zizmor` job is opt-in, and it is the one to turn on once your own
workflows are clean:

```yaml
    with:
      language: go
      working-dir: .
      zizmor: 'true'          # the GitHub Actions security audit
```

`unpinned-uses` is reported and does **not** fail that job. That is not a
baseline — the finding is counted and printed on every run, and the decision it
is waiting on is costed in [`DECISIONS.md`](DECISIONS.md). Every other audit is
fatal.

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

**7c. Adopt the runtime credential-leak canary**, once you have copied
`templates/secrets/<lang>/`:

```sh
cp -R <kit>/templates/secrets/go/internal/canary internal/canary   # go
```

Then, in your test bootstrap, plant the canary and sweep for it. Start by
reading [`templates/secrets/go/README.md`](templates/secrets/go/README.md) —
there are three things to wire up (your credential type, your log sinks, your
public keys) and none of them is automatic, because the harness cannot
enumerate a process's loggers and a harness that guesses is a harness asserting
against the wrong contract.

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
- [ ] **The `secrets` job ran, and anything it found has been ROTATED**
- [ ] `.gitleaks.toml` copied to your repo root if you need an allowlist entry
- [ ] `zizmor: 'true'` set, if your own workflows are clean
- [ ] If you hold credentials: `templates/secrets/<lang>/` copied **with its suite**
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
dependencies into gitignored directories on first run and prints a `note:` line
saying so — PyYAML, yamllint and zizmor into `.venv/`, and hadolint and gitleaks
into `tests/.bin/`. There is no prerequisite step, because a prerequisite that is
documented rather than automated is one that gets skipped by exactly the machine
you most wanted to hear from.

This bit twice. It used to exit 1 with `no python with PyYAML` because it
preferred `.venv/bin/python` and fell back to `python3`, and `.venv` is
gitignored — so **every fresh clone and every CI runner** hit it, including the
CI job this repository now runs on itself.

The binaries go in `tests/.bin/` rather than `.venv/bin/` for the same reason
one level down: `tests/self_test.sh` copies the tree twenty-nine times per gate
run, and a tool in a directory the copy does not carry is re-downloaded once per
copy.

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
- the `secrets` job must exist, must not be `continue-on-error`, must not be
  opt-in, and must check out with `fetch-depth: 0` — the runner default is a
  *shallow clone*, and a shallow scan cannot see a deleted secret
- no workflow may declare `pull_request_target`, `workflow_run` or
  `issue_comment`, read off the **parsed trigger keys** so the comment explaining
  why is not itself a violation
- `.gitleaks.toml` must extend gitleaks' defaults rather than redefine rules, and
  every `[[allowlists]]` entry must carry a `description` of at least 40
  characters. An entry with no reason is a deferred disclosure
- no `.gitleaksignore` may exist — the allowlist is the committed config
- **the scanner's behaviour, executed**: over a throwaway git repository
  containing a detectable credential, the scan must find it, must name the rule
  that fired, must not print the value, and must still find it after the file is
  deleted. This is a behavioural check, not a `grep`, because a `grep
  -- --redact` is satisfied by the comment that explains why the flag is
  mandatory — and `self_test` breakage 15 proved that
- `.github/zizmor.yml` must not ignore or disable `unpinned-uses`, must not carry
  a blanket `ignore: "*"`, and every ignore entry must carry a reason beside it
- the canary must never appear as a literal anywhere in the tree, and must be
  structurally unmistakably fake: prefixed, the right length, and a repeated
  word rather than something a high-entropy detector would score as random

**telemetry** — the W3C traceparent suites are **executed**, one per language,
and so is the canary harness:

```sh
bash tests/validate.sh --language=go     # one language
bash tests/validate.sh --static-only     # no toolchains needed
```

Stdlib only and offline on purpose: no `go mod download`, no `bundle install`,
no `npm ci`, no `cargo fetch`. If these ever need the network, a template has
grown a dependency and kit has stopped being config-only.

The canary suite runs with `-v` so every vector's red proof is visible in the
output. A proof nobody can see is a proof nobody ran — the same argument the
self_test phase makes, applied to the harness rather than to the gate.

**self_test** — `tests/self_test.sh` breaks a throwaway copy of this tree
**twenty-nine** ways and asserts the gate goes red each time. Twenty-three are
for the static and secret-scanner checks; six are a semantic mutation of each of
the six language implementations, so **every suite is proven able to fail** rather
than assumed to. A skip fails the run — a self_test that skips half its proofs
and exits 0 is the "0 passed, 14 ignored" shape that verifies nothing. Fifteen go
further and assert that one *named* check reported `FAIL`, so the check written
for a given defect is proven still load-bearing rather than being one of fifty
checks that could have gone red for an unrelated reason.

The count is **derived** from the breakages that actually ran, not written down.
It used to be a literal `all 18 breakages` in two files that had to be kept in
step by hand, and the first packet to add a breakage without updating both
printed a claim that was no longer true while every check stayed green.

Any `FAIL` exits 1. A `SKIP` is always reported in the summary, never hidden.
PyYAML, yamllint, zizmor, hadolint and gitleaks are required and are
**bootstrapped by the gate itself**; the seven language toolchains and
`shellcheck` run when present.

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
