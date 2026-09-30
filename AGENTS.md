# AGENTS.md — kit

> Conventions for this repo. Read before changing anything here. If a rule is
> not written here, it is not a rule.

## What this repo is

- **Name:** `kit` (`github.com/cafaye/kit`)
- **Purpose:** shared CI, lint, and toolchain conventions that every cafaye
  service repo adopts.
- **Contains:** configuration and documentation only. No runtime code, no
  library, no build step, no dependencies.
- **Not:** a CLI, a package, or a service. Nothing here is imported by anything.

## Layout

```
kit/
├── README.md                             # what kit is, how a repo adopts it
├── .github/workflows/
│   ├── ci.reusable.yml                   # the workflow six repos call
│   └── ci.yml                            # kit calling its own workflow
├── lint/                                 # configs a service copies verbatim
├── docker/                               # Dockerfile.<lang> templates
├── templates/
│   ├── bin-prime/<lang>.sh               # the worktree primer
│   ├── bin/dev.sh                        # the local developer loop
│   ├── compose/                          # postgres + nats + redis + otel collector
│   ├── otel/<lang>/                      # W3C traceparent: codec, suite, snippet
│   ├── mise.toml                         # toolchain pin template
│   └── AGENTS.md                         # skeleton for a service repo
└── tests/validate.sh                     # THE gate
```

Flat on purpose. `grep -r` finds everything; there is no plugin system to
learn.

The reusable workflow is at `.github/workflows/ci.reusable.yml` and nowhere
else. That is not a style choice: GitHub documents that **subdirectories of the
workflows directory are not supported**, so a `uses:` line reading
`cafaye/kit/workflows/ci.reusable.yml@master` resolves to nothing, and every
caller who copied it has a red build. A repo that holds the file in a convenient
place and documents a `uses:` string is a repo whose documentation and layout
have silently disagreed — which is the class of defect the `callable path`
check in `tests/validate.sh` exists to catch. The same reasoning forbids a
second copy: one file, and if you ever mirror it, the gate must fail when the
copies differ.

A caller writes exactly this, and nothing else:

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
      language: go
```

`kit` itself calls it with the local form instead, which is the whole point of
having the file here at all:

```yaml
    uses: ./.github/workflows/ci.reusable.yml
    with:
      language: none
```

## The gate

**`bash tests/validate.sh` must be green before any commit.** It is the whole
test suite — kit has no other tests, because kit has no code.

```sh
python3 -m venv .venv && .venv/bin/pip install -r tests/requirements.txt
bash tests/validate.sh
```

Three phases, and all three must pass:

- **static** — every artifact parses, and the strictness decisions are still
  what we wrote them down to be. A parse is the weakest check; the rest are
  semantic: no collector exporter but `debug`, no literal URL, every
  `${env:...}` the collector reads actually passed into the container, every
  published port a `${KIT_*:default}`, every language with all four artifacts.
- **telemetry** — the six W3C traceparent suites are **executed**, one per
  language. Stdlib only and offline on purpose. If they ever need the network,
  a template has grown a dependency and kit has stopped being config-only.
- **self_test** — sixteen breakages of a throwaway copy, asserting the gate goes
  red each time. Six of them are a semantic mutation of one language each, so
  **every suite is proven able to fail** rather than assumed to. Four assert
  that one *named* check reported `FAIL`, so a check written for a specific
  defect is proven still load-bearing.

- Tests are written **first** and watched fail before the artifacts exist.
- `shellcheck` and `node` run when installed and are skipped when not; PyYAML
  is required. A skip is reported in the summary, never hidden — and a *skip in
  self_test* fails the run, because a proof nobody ran is not a proof.
- When adding an artifact, add the check that would catch its absence. A
  validator nobody extends is a validator that quietly rots.
- **Parse what you hand out.** A file a service copies has to parse in its own
  language, and the extension kit gives it must not stop you checking. This is
  not hypothetical: `rack_middleware.rb.snippet` shipped with
  `c.use_all, :auto_instrumentation`, which is not Ruby, and nothing noticed
  because the artifact table only asked whether the file existed.
- **Run the config against your own files.** Both `Naming/PredicateName` (an
  obsolete RuboCop key that applies nothing) and a duplicate
  `Metrics/MethodLength` block in `lint/rubocop.yml` were invisible until
  rubocop ran on kit's own Ruby with kit's own config. That is the only way an
  obsolete key surfaces before six repos inherit it.
- The suite must be able to fail: `self_test` breaks a throwaway copy of the
  tree sixteen ways and asserts the run goes red. If you change the suite, keep
  that true.

## Adding a language

1. Add `<lang>` to the `language` input's `options` in
   `.github/workflows/ci.reusable.yml` **first**, and watch the suite go red.
   That one edit is the whole trigger: `validate.sh` reads the options out of
   the workflow and, for each one, requires a Dockerfile, a `bin/prime` and a
   `[tools]` pin. There is no second list to keep in step — that is the point.
2. Add the job: `.github/workflows/ci.reusable.yml`, guarded by
   `if: ${{ inputs.language == '<lang>' }}`.
3. Add the other three artifacts: `docker/Dockerfile.<lang>`,
   `templates/bin-prime/<lang>.sh`, and a `[tools]` entry in
   `templates/mise.toml`.
4. Add the language to the README's adoption table and checklist.
5. Re-run the gate until green.

`bun` is the worked example: it was added because `guard` carried a standing
note that it hand-rolled a whole workflow for want of a `bun` job. All four
artifacts landed with it, in one commit.

Half a language is worse than none: the whole point of kit is that every repo
that adopts it gets the same thing.

`none` is not a language and is deliberately exempt from the four-artifacts
rule: it is the option for a repository with no service manifest, and it runs
that repository's own `tests/validate.sh`. It exists because without it `kit`
could not call this workflow — every `language` value named a toolchain this
repository does not have, which left the repository that defines the standard
structurally excluded from using it. If you add a job for a new option, the
`ci_check` block in `tests/validate.sh` must know about it in the same commit:
an `option` with no `job` is a green build that ran nothing.

## Rules

- **Config only.** No runtime code, no dependencies, no generated output. If
  kit grows a dependency it has stopped being conventions.
- **Callers override, they never fork.** Anything that differs per service —
  versions, thresholds, names — is an input or a build arg, never a copy of a
  file. Six repos each holding their own workflow is the drift this repo
  prevents.
- **Boring beats clever.** No frameworks, no generators, no clever YAML. A
  file that needs a paragraph to explain is a file that will be misread.
- **Strictness is documented.** Every config carries comments saying what is
  enforced and why, so it is relaxed deliberately or not at all.
- **Never weaken a check to make the gate green.** If a check is wrong, fix
  the check and say so in the commit message.
- **Never copy code from `moon/refs/`** into this repo or into any cafaye
  repo. Those trees are behavioral references; every line here is ours.
- **Pins are placeholders.** `templates/mise.toml` and the Dockerfiles carry
  placeholder versions on purpose. A service raises them in its own repo; kit
  does not become an org-wide lockfile.
- **No `latest`.** Every base image and action ref is pinned or floating-major
  deliberately, never `latest`.

## Style

- `shellcheck -S warning` clean; `set -euo pipefail` in every shell script;
  `chmod +x` on every script kit hands out.
- `yamllint -c lint/yamllint.yml` clean on every YAML, including this repo's
  own. The config is dogfooded, not aspirational.
- Comments explain *why*, not *what*. A comment restating the line below it is
  noise; a comment recording a decision that would otherwise be relitigated is
  the point.

## Before you commit

- [ ] `bash tests/validate.sh` is green, and you have pasted the output
- [ ] New or changed config is covered by a check that would catch its absence
- [ ] `README.md` still matches the tree (every language, every file)
- [ ] `CHANGELOG.md` has an entry
- [ ] You did not weaken a check, a threshold, or a pin to get green
