# Changelog

All notable changes to `kit` are recorded here. kit has no releases yet and no
semver contract — it is consumed by *calling*
`.github/workflows/ci.reusable.yml@master` and by *copying* files out of
`lint/`, `docker/`, and `templates/`.

> Entries under **Earlier**, and the three `workflows/ci.reusable.yml` bullets
> below, record the path the file had *at the time*. It was
> `workflows/ci.reusable.yml` until the move recorded in Unreleased/Changed.

## Unreleased

### Fixed

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
