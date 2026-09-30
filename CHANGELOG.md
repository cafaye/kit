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

- **The secret scanner.** A `secrets` job in `ci.reusable.yml` running
  **gitleaks 8.30.1** over the adopting repository's **full history**, with
  `--redact`. It is the one job in the workflow with **no opt-in**: an opt-in
  security control is not a control, and a secret scanner that only warns is a
  report. `fetch-depth: 0` is load-bearing — the runner default is a shallow
  clone, and a secret committed and deleted in one PR is still in the packfile
  of anyone who cloned. **Adopting this can turn a repo's first build red**;
  README says what to do, and the first thing to do is rotate.
  - gitleaks rather than trufflehog: trufflehog is **AGPL-3.0**, and it is the
    only candidate that verifies live credentials against the issuer's API,
    which for a fleet whose CI has network access is the wrong behaviour for a
    scanner. gitleaks is MIT, a static binary, and makes no network call.
  - `tests/gitleaks_gate.sh` is the **one** scan, called by both the `secrets`
    job and `tests/validate.sh`. A scanner whose CI and local invocations have
    drifted is two scanners, and the one that goes red is whichever nobody runs.
  - `.gitleaks.toml` — the allowlist, and **nothing else**. `extend.useDefault`
    so the rules stay gitleaks', and every `[[allowlists]]` entry must carry a
    `description` of at least 40 characters. An allowlist that grows and is never
    pruned is not an allowlist, it is a deferred disclosure. A `.gitleaksignore`
    fails the gate.
- **A `zizmor` job** (opt-in, `zizmor: 'true'`), running the GitHub Actions
  security audit on the adopting repo's own workflows. `tests/zizmor_gate.sh`
  counts `unpinned-uses` and prints the count and the reason on every run, and
  **fails on every other audit**. It is recorded, not baselined: see
  `DECISIONS.md` (MD10a), where the pin trade is costed in three options and none
  of them has been taken.
- **`templates/secrets/`** — the runtime credential-leak canary. A
  **language-neutral contract** (`templates/secrets/README.md`) and the **Go
  adapter**, with five vectors each carrying its own red proof: log/stdout/stderr,
  unknown serialisation fields, the whole error chain, keys present-but-empty,
  and Go type coverage.
  - It exists because **nothing off the shelf does this**. gosec's
    `credentials.Match` has no `*ast.CallExpr` case, so it finds literals and not
    a token passed to a logger. Bandit matches `ast.Constant` only. Brakeman's
    secret check is off by default. Of 268 Semgrep taint rules, **zero** intersect
    CWE-532.
  - The canary is **assembled at run time**, never written as a literal, so it is
    safe to commit and needs no allowlist entry. Two checks enforce that.
- **Ten new checks** in `tests/validate.sh` for the above, including one that
  asserts the scanner's **behaviour** by executing it: over a throwaway git
  repository holding a detectable credential, the scan must find it, must name
  the rule that fired, must not print the value, and must still find it after the
  file is deleted.
- **Eleven new `self_test` breakages** (13–23), each asserting that one *named*
  check went red: a credential in history, a credential in the working tree,
  `--redact` removed, the scan narrowed to the last commit,
  `pull_request_target` added, the `secrets` job made `continue-on-error`, four
  ways of breaking the canary's reference type, the canary committed as a
  literal, and `unpinned-uses` baselined in `.github/zizmor.yml`.
  - `self_test` is now **29 breakages**, and the count is *derived* from the
    breakages that actually ran. It was a literal `18` in two files kept in step
    by hand.
- `tests/gitleaks_gate.sh` and `tests/zizmor_gate.sh`, `chmod +x` and asserted
  executable — they are run by the reusable workflow from a service's repository,
  so a missing executable bit is a `secrets` job that dies in thirteen repos.

### Fixed

- **`artipacked` (9 findings) in `ci.reusable.yml`.** Every `actions/checkout`
  now sets `persist-credentials: false`. No job in the file pushes, so a token
  left on disk after a checkout is a credential that outlives the job for no
  reason — and every job here runs `upload-artifact`, which is the combination
  the audit exists to catch. Found by zizmor, and fixed rather than baselined.
- **`.github/zizmor.yml` is no longer walked for stray copies of the workflow.**
  The `callable path` check reported `tests/self_test.sh` as "a second workflow
  declaring `workflow_call`" — it names the key in a comment explaining breakage
  8. A check that fires on the file proving it wrong is a check people delete.
- **Fetched tools now land in `tests/.bin/`, not `.venv/bin/`.** `.venv` is
  gitignored and `tests/self_test.sh` copies the tree twenty-nine times per run,
  so hadolint and gitleaks were being re-downloaded once per copy. The copy
  carries `tests/.bin`; it does not carry `.venv`.
- **The self_test control run no longer fails on a missing executable bit.**
  `cp -R` does not preserve mode bits on macOS, so every throwaway copy arrived
  with `tests/*.sh` non-executable and the new handed-out-scripts check failed in
  all of them — for a reason that had nothing to do with any breakage under test.

### Changed

- `tests/requirements.txt` pins **`zizmor==1.30.1`**, and an auditor is pinned
  where a parser is not: a new release adds findings, and a gate whose result
  depends on when it last ran is a gate nobody can reason about. zizmor comes
  from PyPI rather than a release archive because it publishes no checksums file,
  and pinning its archives would mean pinning hashes we computed ourselves.
- `kit_bootstrap_binary` takes an asset-name template and an inner-path, so it
  can install a tarball as well as a bare binary, and its sha256 table is keyed
  by **exact asset filename**. It used to be keyed by `macos-arm64`, which forced
  every caller's asset name to be derivable from `<name>-<os>-<arch>` — true for
  hadolint, false for gitleaks, and the reason this function could not install a
  second tool. There are now three spellings of the OS name in play
  (`macos`/`darwin`/`apple-darwin`) and all three are mapped explicitly.
- The `callable path` check's copy-walk skips `.bin` and shell scripts.

### Earlier

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
