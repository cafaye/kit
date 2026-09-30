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
