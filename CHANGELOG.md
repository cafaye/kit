# Changelog

All notable changes to `kit` are recorded here. kit has no releases yet and no
semver contract — it is consumed by *calling*
`.github/workflows/ci.reusable.yml@master` and by *copying* files out of
`lint/`, `docker/`, and `templates/`.

> Entries under **Earlier**, and the three `workflows/ci.reusable.yml` bullets
> below, record the path the file had *at the time*. It was
> `workflows/ci.reusable.yml` until the move recorded in Unreleased/Changed.

## Unreleased

### Added

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
  closed.** `self_test.sh` proves twenty-one synthetic breakages go red; it
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
- **Three new self-test breakages (18 → 21).** `includePaths` nested under
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
- `AGENTS.md` and `README.md` describe twenty-one breakages rather than
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
  anywhere, by default and by gate.
- `templates/otel/<lang>/` — per language: a stdlib `traceparent.*` codec, an
  executed conformance suite, an SDK wiring snippet with a documented
  "when to use which" README, and a statement of the W3C sections implemented.
- `templates/otel/pins.md` — the OTel versions the snippets reference, at the
  otel root because it covers all six languages. kit vendors nothing.
- `README.md` — sections for the local stack and for trace propagation,
  including a worked example of a service adopting propagation, and an accurate
  description of what the gate actually does.

### Fixed

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

- **The reusable workflow moved to `.github/workflows/ci.reusable.yml`.** It was
  at `workflows/ci.reusable.yml`, and GitHub documents that subdirectories of
  the workflows directory are not supported — so the `uses: cafaye/kit/workflows/
  ci.reusable.yml@master` line in the README resolved to nothing. No repository
  in the fleet was calling it. It is now a **move, not a mirror**: one file, at
  the only path GitHub will resolve, so there is no second copy to diverge.
- `self_test.sh` grew from 5 breakages to 18. Six are per-language semantic
  mutations, each against a different W3C section, so
  **every** suite is proven able to fail rather than assumed to. A mutant that
  fails to compile is its own verdict rather than a pass, a missing toolchain is
  a skip that fails the run, and an unmatched mutation is a hard failure so the
  proof cannot rot into proving nothing.
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
