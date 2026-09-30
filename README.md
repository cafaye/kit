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
| `workflows/ci.reusable.yml` | One reusable GitHub Actions workflow. Input `language` picks one of six jobs — install, lint, test, coverage gate. No job builds or pushes an image. | Every service, via a 6-line `.github/workflows/ci.yml` |
| `lint/yamllint.yml` | YAML style, with the three rules Actions forces us to retune. | Any repo that lints its own YAML; kit's gate uses it on itself |
| `lint/golangci.yml` | golangci-lint v2, correctness linters on, `errcheck` excluded only for `Close`/`Flush`. | Go services |
| `lint/rubocop.yml` | RuboCop, `NewCops: enable`, Metrics left on. | Ruby services |
| `lint/eslint.config.mjs` | ESLint 9 flat config, type-checked rules on. | Node/TypeScript services |
| `docker/Dockerfile.<lang>` | Six multi-stage templates. `go` and `rust` finish on distroless; `ruby`, `elixir`, `python`, and `node` finish on `*-slim`. All run non-root. | Every service |
| `templates/bin-prime/<lang>.sh` | The worktree primer: one script per language, exit 0 only when the tree is genuinely ready. | Every service, as `bin/prime` |
| `templates/mise.toml` | Toolchain pins, one per language, commented. | Every service, as `mise.toml` |
| `templates/AGENTS.md` | Skeleton repo-conventions file. | Every service, as `AGENTS.md` |
| `tests/validate.sh` | kit's own suite — the gate. | kit |

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
      language: go          # go | ruby | elixir | python | node | rust
      working-dir: .        # the dir holding go.mod / Gemfile / pyproject.toml
```

Two jobs for two languages? Call it twice with two different `language` values.

**2. Copy the linter config** that matches your language into the repo root, so
the config is part of the code review that changes the code:

```sh
cp <kit>/lint/golangci.yml  .golangci.yml     # go
cp <kit>/lint/rubocop.yml    .rubocop.yml      # ruby
cp <kit>/lint/eslint.config.mjs eslint.config.mjs   # node / typescript
cp <kit>/lint/yamllint.yml   .yamllint.yml     # any repo with YAML
```

**3. Copy the Dockerfile and the primer.** Rename the Dockerfile to
`docker/Dockerfile` and the primer to `bin/prime`, then:

```sh
cp <kit>/docker/Dockerfile.go          docker/Dockerfile
cp <kit>/templates/bin-prime/go.sh     bin/prime
chmod +x bin/prime
```

Set `SERVICE_NAME` (Go, Rust) or the `:app` release name (Elixir) to your real
binary or application name.

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
- [ ] `mise.toml` copied, every placeholder raised to a shipped version
- [ ] `AGENTS.md` copied and filled in
- [ ] A coverage command exists and `COVERAGE_FAIL_UNDER` is above 0
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

`tests/validate.sh` walks every file in `workflows/`, `lint/`, `docker/`, and
`templates/bin-prime/` and prints one line per file:

- `.sh` → `bash -n`
- `.yml` / `.yaml` → `python3` `yaml.safe_load`
- `.mjs` → `node --check`, skipped when node is not installed
- anything else (the `Dockerfile.*` templates) → `SKIP`, reported rather than
  silently passed

Any `FAIL` exits 1, so the gate is red until every artifact parses. It is
deliberately the whole suite: kit has no runtime code, so "it parses" is the
strongest check a config repo can make. Semantic review — is the coverage gate
real, is the final base image distroless — is what review and the six consuming
repos' own CI are for.

PyYAML is required (`tests/requirements.txt`); `node` is optional.
