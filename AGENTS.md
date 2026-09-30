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
├── README.md                     # what kit is, how a repo adopts it
├── workflows/ci.reusable.yml     # the workflow six repos call
├── lint/                         # configs a service copies verbatim
├── docker/                       # Dockerfile.<lang> templates
├── templates/
│   ├── bin-prime/<lang>.sh       # the worktree primer
│   ├── mise.toml                 # toolchain pin template
│   └── AGENTS.md                 # skeleton for a service repo
└── tests/validate.sh             # THE gate
```

Flat on purpose. `grep -r` finds everything; there is no plugin system to
learn.

## The gate

**`bash tests/validate.sh` must be green before any commit.** It is the whole
test suite — kit has no other tests, because kit has no code.

```sh
python3 -m venv .venv && .venv/bin/pip install -r tests/requirements.txt
bash tests/validate.sh
```

- Tests are written **first** and watched fail before the artifacts exist.
- `shellcheck` and `node` run when installed and are skipped when not; PyYAML
  is required. A skip is reported in the summary, never hidden.
- When adding an artifact, add the check that would catch its absence. A
  validator nobody extends is a validator that quietly rots.
- The suite must be able to fail: `self_test` breaks a throwaway copy of the
  tree three ways and asserts the run goes red. If you change the suite, keep
  that true.

## Adding a language

1. Add the language to `LANGUAGES` in `tests/validate.sh` **first** and watch
   the suite go red.
2. Add all four artifacts: `workflows/ci.reusable.yml` (a job guarded by
   `inputs.language == '<lang>'`), `docker/Dockerfile.<lang>`, a
   `templates/bin-prime/<lang>.sh`, and a `[tools]` entry in
   `templates/mise.toml`.
3. Add the language to the README's adoption table and checklist.
4. Re-run the gate until green.

Half a language is worse than none: the whole point of kit is that six repos
get the same thing.

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
