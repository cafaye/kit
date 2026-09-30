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
│   ├── yamllint.yml  golangci.yml
│   ├── rubocop.yml   eslint.config.mjs
│   └── hadolint.yaml                      # argues the one rule it ignores
├── docker/                               # Dockerfile.<lang> templates
├── core/                                 # the cafaye/core fan-out standard
│   ├── README.md                           # why, and the three failure modes
│   ├── vendir/                             # vendir.yml per consuming repo
│   ├── renovate/                           # the one shared Renovate policy
│   └── release/                            # what core needs to be taggable
├── templates/
│   ├── bin-prime/<lang>.sh               # the worktree primer
│   ├── bin/dev.sh                        # the local developer loop
│   ├── compose/                          # postgres + nats + redis + collector + LGTM
│   │   ├── grafana/provisioning/         # datasources, dashboards, alert rules (files)
│   ├── otel/<lang>/                      # W3C traceparent: codec, suite, snippet
│   ├── tier/<lang>/                      # the DECLARED tier, per language
│   ├── tier/skip-allowlist               # one file for the fleet; four hygiene rules
│   ├── tier/README.md                    # the format, the rules, and the limits
│   ├── mise.toml                         # toolchain pin template
│   └── AGENTS.md                         # skeleton for a service repo
└── tests/
    ├── validate.sh                       # THE gate
    ├── classify.py  rules.json           # the change classifier, failing closed
    └── staleness.py                      # the fleet staleness reporter
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
  semantic: the collector's redaction allowlist **derived from core's
  schemas** and compared both ways, redaction before every exporter, no literal
  URL, every `${env:...}` the collector reads actually passed into the
  container, every published port a `${KIT_*:default}` inside kit's claimed
  15000-15999 block, telemetry in nobody's readiness path, every language with
  all four artifacts, and every language with a **declared tier** plus a
  documented collector. The skip allowlist's four hygiene rules are enforced
  here too, and **an entry matching nothing is a failure** — modelled on
  ESLint's `reportUnusedDisableDirectives`, because without that rule an
  allowlist is a ratchet that only turns one way.
- **telemetry** — the six W3C traceparent suites are **executed**, one per
  language. Stdlib only and offline on purpose. If they ever need the network,
  a template has grown a dependency and kit has stopped being config-only.

- **observability** — the two claims that are worth nothing unexercised: a
  canary secret in ten leak shapes reaches no exporter (and the allowed data
  survives), and a service starts, serves and reports healthy with the collector
  killed. Both need a real collector, so both SKIP loudly without docker —
  never pass silently.
- **classifier + staleness** — the change classifier and the staleness reporter
  are *executed*, not parsed, and deliberately **outside** the `RUN_STATIC`
  guard: a check that only parsed those two files would pass on a classifier
  that waves every change through. They stay runnable when static analysis is
  skipped, because a gate that skips is not green.
- **self_test** — twenty-three breakages of a throwaway copy, asserting the gate
  goes red each time. Six of them are a semantic mutation of one language each,
  so **every suite is proven able to fail** rather than assumed to. Eight assert
  that one *named* check reported `FAIL`, so a check written for a specific
  defect is proven still load-bearing. Two assert that a *proof* goes red: one
  inverts the classifier's fail-closed property, and one makes the staleness
  reporter call an undeclared pin `current`. A property nobody has tried to
  break is a property nobody has tested.
- Tests are written **first** and watched fail before the artifacts exist. A
  config written from documentation instead of from the pinned image is a config
  that breaks on the first `bin/dev up`: Tempo, Loki and Mimir all reject keys
  with messages that name a Go type rather than a config key. Every vendor
  config in this repo was verified by loading it into its image.
- **Never weaken a check to make the gate green.** If a check is wrong, fix the
  check and say so in the commit message.
- `shellcheck` and `node` run when installed and are skipped when not. A skip is
  reported in the summary, never hidden — and a *skip in self_test* fails the
  run, because a proof nobody ran is not a proof.
- **PyYAML, yamllint and hadolint are required and are bootstrapped, not
  required of you.** `tests/bootstrap.sh` resolves an interpreter, builds
  `.venv`, pip installs `tests/requirements.txt`, and fetches a pinned hadolint
  release verified against hadolint's published `checksums.sha256`. Resolve
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
  because the artifact table only asked whether the file existed. The tier
  templates are parsed the same way — and the tier Go files shipped
  un-gofmt'ed until this packet's own second pass ran `gofmt` over them, which
  is the shape of the same defect one layer down.
- **Run the config against your own files.** Both `Naming/PredicateName` (an
  obsolete RuboCop key that applies nothing) and a duplicate
  `Metrics/MethodLength` block in `lint/rubocop.yml` were invisible until
  rubocop ran on kit's own Ruby with kit's own config. That is the only way an
  obsolete key surfaces before six repos inherit it.
- The suite must be able to fail: `self_test` breaks a throwaway copy of the
  tree nineteen ways and asserts the run goes red. If you change the suite, keep
  that true.

## The classifier fails closed, and that is a rule about code

A difference `classify.py` cannot place is assigned `rules.json`'s
`unrecognisedTier`, which is `FILE`, and is breaking. **Both facts live in
`rules.json` and nowhere else.** An earlier version stated the tier in the Python
*and* in a rule, and the self-test breakage written to invert it left the suite
**green** — because the headline case never reached the line that was broken. A
property stated in two places is a property asserted in zero times.

So:

- Adding a JSON Schema keyword the classifier does not model is a **decision**,
  not an omission. It falls to `unrecognisedTier` deliberately; make it
  deliberate in the same commit.
- The escape hatch is fenced. A rule may set `breaking: false`, and the
  catalogue **refuses to load** if the operation is not in `advisoryOps`.
  Without that rule the one escape hatch is the first place a fail-open
  classifier reappears, and `advisoryOps` is a closed list on purpose: a list
  that grows by a later commit is not a control.
- `advisoryOps` has three entries — a documentation edit, and a reordering of
  `required` or `enum`, both provably non-semantic because JSON Schema defines
  those two keywords as sets. Each had to argue for itself. Widening the list is
  a deliberate, diffable act in one file.

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
  - **The one carve-out, and why it is a carve-out rather than a precedent.**
    `core/` ships a change classifier and a staleness reporter, which are
    programs rather than configuration. They are here because a standard
    without a thing that enforces it is a standard enforced by whoever reads
    it. They stay inside the boundary deliberately: **standard library only,
    no import outside `json`/`os`/`re`/`sys`/`argparse`/`subprocess`**, no
    installable dependency, and **nothing imports them** — the real test of this
    rule is that nothing here is a library, and a classifier is not. The
    reporter prints a table for a scheduled job and **never commits its
    output**, because a committed report is the "generated output" this rule
    forbids and the kind of file that rots. If a third program is proposed, the
    default answer is no.
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
- **A check that a comment can satisfy is not a check.** The `-count=1`
  assertion was a plain substring test, the go step's own comment block names
  the flag twice while explaining why it is mandatory, and deleting the flag
  from the command left the check green. `strip_shell_comments` exists because
  of it. Any check that greps a `run:` body strips comments first.
- **kit ships the convention; `caf` ships the checker.** The declared tier per
  language, the normalised result format, the skip allowlist and its four rules,
  and the `REQUIRED_<TIER>` demand are kit's. The per-language collector
  adapters, the inventory-vs-run set difference, and the production of the
  normalised format are `caf gate`'s — runtime code, in a runtime repo. If you
  find yourself writing a collector here, you have left your scope.
- **A test count is not a tier gate, and a floor is not a tier gate.** The
  machinery can prove "41 tests ran"; only an assertion *inside* the test
  proves "41 tests hit Postgres". A pass-count floor is a decrease detector: it
  is satisfied by any N tests, including the wrong N, and nothing in it knows
  which tier a test belongs to.
- **Never cache a test report.** `restore-keys` matches by PREFIX and the
  default branch's cache is documented as available to other branches, so a key
  built from a lockfile hash restores a report written by a run that *had* the
  dependency into a run that did not. A witness from a different run is not a
  witness. Cache build products — `target/`, `$GOCACHE`, `node_modules`,
  `vendor/bundle` — and never a witness.
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
- [ ] Every claim about a third-party tool is verified against its source or an
      actual run, and anything you could not verify is written down as such
- [ ] You did not add a file type without adding the check that lints it
- [ ] New or changed config is covered by a check that would catch its absence
- [ ] `README.md` still matches the tree (every language, every file)
- [ ] `CHANGELOG.md` has an entry
- [ ] You did not weaken a check, a threshold, or a pin to get green
