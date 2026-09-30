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
├── .gitleaks.toml                        # the allowlist, and nothing else
├── DECISIONS.md                          # the trades this repo has NOT made
├── .github/
│   ├── workflows/
│   │   ├── ci.reusable.yml               # the workflow six repos call
│   │   └── ci.yml                        # kit calling its own workflow
│   └── zizmor.yml                        # reasoned baselines, one per finding
├── lint/                                 # configs a service copies verbatim
│   ├── yamllint.yml  golangci.yml
│   ├── rubocop.yml   eslint.config.mjs
│   └── hadolint.yaml                      # argues the one rule it ignores
├── docker/                               # Dockerfile.<lang> templates
├── templates/
│   ├── bin-prime/<lang>.sh               # the worktree primer
│   ├── bin/dev.sh                        # the local developer loop
│   ├── compose/                          # postgres + nats + redis + otel collector
│   ├── otel/<lang>/                      # W3C traceparent: codec, suite, snippet
│   ├── secrets/                          # runtime credential-leak canary
│   │   ├── README.md                       # the CONTRACT, language-neutral
│   │   └── go/                            # the Go adapter + its five vectors
│   ├── mise.toml                         # toolchain pin template
│   └── AGENTS.md                         # skeleton for a service repo
└── tests/
    ├── validate.sh                       # THE gate
    ├── self_test.sh                      # proves the gate can go red
    ├── gitleaks_gate.sh                  # the one secret scan, for CI and here
    ├── zizmor_gate.sh                    # the one zizmor split, ditto
    └── bootstrap.sh                      # the gate installs its own tools
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
bash tests/validate.sh
```

**One command, on a clean clone, is the whole procedure.** The gate installs its
own dependencies into the gitignored `.venv/` on first run and prints a `note:`
line saying so. There is no prerequisite step, and a prerequisite step that is
documented rather than automated is a prerequisite that gets skipped by exactly
the machine you most wanted to hear from — a CI runner, or anyone who cloned
without reading this file.

That was the second time this bit. It used to exit 1 with `no python with
PyYAML` because it preferred `.venv/bin/python`, fell back to `python3`, and
`.venv` is gitignored, so **every fresh clone and every CI runner** hit it.

Three phases, and all three must pass:

- **static** — every artifact parses, and the strictness decisions are still
  what we wrote them down to be. A parse is the weakest check; the rest are
  semantic: no collector exporter but `debug`, no literal URL, every
  `${env:...}` the collector reads actually passed into the container, every
  published port a `${KIT_*:default}`, every language with all four artifacts.
  Plus the secret scanner: the allowlist is an allowlist and nothing else, every
  entry has a reason, no `.gitleaksignore` exists, the scan redacts and reads
  full history, no workflow declares a dangerous trigger, and the `secrets` job
  is neither advisory nor opt-in.
- **telemetry** — the six W3C traceparent suites are **executed**, one per
  language, and the canary harness is **executed** with all five vectors, each
  printing its own red proof. Stdlib only and offline on purpose. If they ever
  need the network, a template has grown a dependency and kit has stopped being
  config-only.
- **self_test** — twenty-nine breakages of a throwaway copy, asserting the gate
  goes red each time. Six of them are a semantic mutation of one language each,
  so **every suite is proven able to fail** rather than assumed to. Fifteen
  assert that one *named* check reported `FAIL`, so a check written for a
  specific defect is proven still load-bearing. The count is derived from the
  breakages that actually ran, never written down.

## Secrets

**`bash tests/validate.sh` scans this repository's full history, and so does
`bash tests/gitleaks_gate.sh`.** They are the same script, because they are the
same scan — a scanner whose CI invocation and its local invocation have drifted
is two scanners, and the one that goes red is whichever nobody runs.

Four things about it that are not negotiable, and each has a check that fails
without them:

- **Full history, not the diff.** A secret committed and deleted in one PR is
  still in the history and still on every fork. The default checkout is a
  *shallow clone*; `fetch-depth: 0` is in the `secrets` job for that reason.
- **`--redact`, unconditionally.** A CI log is a place secrets go to be read. The
  scanner finding a secret must never be why the secret is printed. There is no
  flag to turn it off, and `self_test` breakage 15 removes it and proves the
  gate notices.
- **The allowlist is `.gitleaks.toml` and nothing else.** No `-i` flags, no
  `.gitleaksignore`, and every `[[allowlists]]` entry carries a `description` of
  at least 40 characters. `extend.useDefault = true` means the rules stay
  gitleaks'; a repo that redefines a rule has taken responsibility for the regex.
- **No `pull_request_target`, anywhere.** It runs with the base repository's
  secrets and a writable token on a *fork's* code. The scanner is the job that
  most invites "just pull the base branch in so the scan sees the real history",
  and that edit is how a secret scanner becomes the way secrets are taken.

**`DECISIONS.md` records a trade this repository has NOT made.** zizmor's
`unpinned-uses` fires thirty-three times and is **not** baselined: it is counted
and printed on every run, and `tests/validate.sh` fails if anyone adds it to
`.github/zizmor.yml`. A baseline there would be making the trade invisibly, in a
file that looks like routine configuration. If you add *any* zizmor ignore
entry, it needs a reason in a comment beside it, and the gate checks.

**`templates/secrets/` is the other half, and it is not gitleaks.** gitleaks
answers "was a secret committed". Nothing off the shelf answers "does a secret
leave the process while the tests run" — gosec's `credentials.Match` has no
`*ast.CallExpr` case, Bandit matches `ast.Constant` only, Brakeman's check is
off by default, and of 268 Semgrep taint rules zero intersect CWE-532. So the
canary harness plants a fake credential and sweeps for it in five vectors. The
contract is in `templates/secrets/README.md`; the Go adapter is in
`templates/secrets/go/`.

**The canary is assembled, never written out, and that is checked.** A committed
`cafaye_canary_…` literal is a credential-shaped string in a public repository,
which is what this repository's own scanner reports, and allowlisting it teaches
the next reader that allowlisting a credential is normal. Two checks enforce it:
one inside the Go suite, one over the whole tree.

- Tests are written **first** and watched fail before the artifacts exist.
- `shellcheck` and `node` run when installed and are skipped when not. A skip is
  reported in the summary, never hidden — and a *skip in self_test* fails the
  run, because a proof nobody ran is not a proof.
- **PyYAML, yamllint, zizmor and hadolint are required and are bootstrapped, not
  required of you.** `tests/bootstrap.sh` resolves an interpreter, builds
  `.venv`, pip installs `tests/requirements.txt`, and fetches pinned hadolint
  and gitleaks releases verified against their published checksums. zizmor is
  pinned in `requirements.txt` and comes from PyPI, because it publishes no
  checksums file and pinning its archives would mean pinning hashes we computed
  ourselves. Resolve
  order: `$KIT_PYTHON` (an override is a promise — if it cannot import yaml
  the gate says so rather than silently substituting a different one), then
  `.venv`, then any `python3` on PATH that already has PyYAML, then bootstrap.
  A required check whose tool path is hardcoded to a directory the resolver may
  have skipped is a gate that fails on arrival; that is a bug this file has
  already had once.
- **A skip is a gap, and the summary line is how you find it.** The seven
  Dockerfiles sat behind `SKIP ... (no parser for this file type)` for the whole
  life of kit-02, and the only reason anyone knew is that the summary printed
  `note: 7 check(s) skipped`. A skip that is honest is still a check that ran
  nothing — and a new file type with no parser is reported, never quietly
  ignored. If you add a file type, add the parser in the same commit.
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
  tree eighteen ways and asserts the run goes red. If you change the suite, keep
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
- [ ] If you touched the secret scanner, you did not add an allowlist entry
      without a reason, and you did not add one to `continue-on-error`
