# REPORT — kit-12: stop shipping lint configs to be copied

Branch `worker/kit-12-lint`. Base `master` at `41f8bcb`.

## The ruling, and what it changed

**Ship the step, not the config file.** `lint/` is no longer distributed by `cp`.
The go, ruby and node jobs check `lint/` out of kit **at run time** and pass
`--config` at it, so a service inherits kit's lint policy with no file in its
tree and no action. Adoption goes from 0/9 to 9/9 by construction rather than by
a decision nine teams have to make.

---

## 1. The mechanism, per language, measured

Everything in this table was **run**, not read from documentation. The fixtures
live in `tests/lint_test.sh`, which builds a throwaway service containing a
violation only that linter would catch, runs the same command the workflow runs,
and asserts the linter rejects it — plus a control that must answer differently.

| linter | mechanism | what was measured |
|---|---|---|
| **golangci-lint** | `--config=<repo>/.kit/lint/golangci.yml` | With no config present it does **not** fail and does **not** run nothing: it falls back to its own five-linter default set (`errcheck govet ineffassign staticcheck unused`) and **exits 0 on a file kit's config rejects** (a comment misspelling). |
| **RuboCop** | `--config=<repo>/.kit/lint/rubocop.yml` | A 13-line method is **green** under kit (`Max: 15`) and **red** on RuboCop's default (`Max: 10`). The pair is what proves the flag is read: 13 lines sits *between* the two thresholds, so the two runs can only agree if the second one is not using kit's config at all. |
| **ESLint** | `--config=<repo>/.kit/lint/eslint.config.mjs` | Works **only** because kit is checked out *inside* the repo. Node resolves an ESM import from the config file's own directory upward; beside the repository the config finds no `@eslint/js` and the run dies `ERR_MODULE_NOT_FOUND` — asserted as a breakage, not a comment. |
| **yamllint** | `yamllint -c <path> --strict` | Both of kit's retuned rules (`truthy`, `document-start`) are **warnings** by default, so without `--strict` the exit code is 0 and the finding is invisible. `--strict` is load-bearing and asserted. |

### Two specific questions the brief asked, answered by running them

**`GOLANGCI_LINT_CONFIG` — does it work?** **No.** Measured on v2.6.2: set the
variable, pass no `--config`, and the run proceeds on the same five-linter default
set and exits 0 on a file kit's config rejects. The variable is read by nothing.
So the missing flag is not "a slower lint", it is **a different and much weaker
policy that still goes green** — which is why `lint/golangci.yml` argues the flag
in its own header.

**What actually happens when `.golangci.yml` is not there?** Discovery walks up
from the repo and finds nothing, and golangci-lint does **not** error. It applies
its default set. That is the finding that makes the flag load-bearing rather than
decorative, and it is the opposite of what most people expect from a missing
config.

**And the reverse, which is what `lint drift` rests on:** a repo-root
`.golangci.yml` does **not** beat `--config`. Both are asserted in
`tests/lint_test.sh`: a local file that disables `misspell` is *inert* under
kit's config, and governs the run the moment the flag is gone. So a stale copy
does not hijack CI — it **splits** the policy, with CI reading kit's and every
other invocation in that repository reading the copy. Full detail and the
correction it forced are in §7(a).

---

## 2. What could not be done, and the cost

### ESLint cannot be configured from a remote, at all

Not "we chose not to" — **the mechanism does not exist**:

```
Error [ERR_UNSUPPORTED_ESM_URL_SCHEME]: Only URLs with a scheme in: file and data
are supported by the default ESM loader. Received protocol 'https:'
```

and the flag that once permitted it is gone in Node 22:

```
$ node --experimental-network-imports ...
node: bad option: --experimental-network-imports
```

**Cost and the least-bad alternative.** A flat config must exist as a real file on
disk, so the alternative is *materialisation* rather than *reference*: a sparse
`actions/checkout` of `lint/` into `<working-dir>/.kit`. It is offline,
deterministic, versioned by `kit-lint-ref`, and costs one checkout per push. The
one non-obvious requirement — it must be **inside** the repository, because node
resolves the config's own imports upward from the config's directory — is measured
above and asserted as a breakage.

### RuboCop *does* have a remote path, and it works

A three-line service `.rubocop.yml` is genuinely applied:

```yaml
inherit_from:
  - https://raw.githubusercontent.com/cafaye/kit/master/lint/rubocop.yml
```

Measured: a 17-line method is reported `Metrics/MethodLength: Method has too many
lines. [17/15]` — kit's `Max: 15`, fetched over the network. A bad URL **fails
loudly** (exit 2, `404 "Not Found" while downloading remote config file`) rather
than silently falling back, which is the right direction for a gate.

It is **not** what the workflow uses, and the reason is worth recording: it needs
the network on every lint run, it re-downloads an artifact we version in a
repository we control, and it puts a per-service file back — the exact shape this
packet exists to remove. `--config` against a checkout is deterministic, offline,
and moves with the workflow that uses it. The remote form is documented in
README.md as the honest alternative for a repo that cannot take a checkout.

### hadolint was left alone

`lint/hadolint.yaml` runs in kit's own gate on kit's own Dockerfiles, which is
already "the step, not the copy" — there is no service-side hadolint step for
this to replace. Not rearchitected.

---

## 3. The deviation seam

One input, deliberately narrow:

```yaml
    with:
      language: go
      lint-args: "-E gosec"      # appended AFTER kit's own flags
```

- It comes **last** — a service can add flags, cannot remove the `--config`.
- It is a **string, not a path** — so there is no service-side config file for a
  linter to read, and therefore none to rot. A seam that reintroduces the file
  reinstates the failure this packet exists to end.
- It **may not change which config is read, what is linted, or whether a finding
  fails the build** — enforced by a `lint-args guard` step in the workflow, not by
  kit's gate, because `lint-args` is the caller's value and kit has never got it.
  It refuses 15 flags: `--config`/`-c`/`--no-config`/`--no-config-lookup`/
  `--force-default-config` (which config), the four `--new*` forms (what is
  linted), `--issues-exit-code`/`--fail-level`/`--quiet`/
  `--no-error-on-unmatched-pattern` (whether it fails), and
  `--auto-gen-config`/`--regenerate-todo`, which *write a config file into the
  tree* and are this packet's own reason to refuse them. Each was read out of the
  linter's own `--help` on the pinned version, not remembered.
  `lint_args_seam_check` asserts the guard is in all three lint jobs, the copies
  are byte-identical, it runs **before** the linter, the linter receives
  `$KIT_LINT_ARGS`, and the refused list is the one written in the gate — so
  deleting a token is a red build rather than a quiet widening of the seam.
- A stricter *rule* has no seam at all, and that is the intended pressure: the
  rule belongs in `lint/`, where nine services get it and one allowlist entry is
  replaced by a change everyone receives.

`kit-lint-ref` is the second input and it is **not** a second independent pin: it
must be set to the same ref the caller pinned `uses:` to. A caller who pins one
and not the other gets that SHA's workflow with today's lint policy. Nothing
detects it automatically, so it is documented in the input description and in
README.md rather than pretended to be automatic.

---

## 4. The gate

### `lint_wiring_check` — the lint steps are gates on kit's config

Asserted on the **parsed** workflow, with shell and YAML comments stripped first
(this file's own prose names every one of these flags while explaining why each
is load-bearing, so a naive substring test is satisfied by the documentation of
the step it is meant to police). It requires, for `go`, `ruby` and `node`: the
step is named `lint`; it names its linter; it passes `--config`; it reads the
config through `$KIT_LINT_DIR` rather than a path inside the service's own tree;
the `cafaye/kit` checkout that fills that variable exists, is pinned to
`inputs.kit-lint-ref`, and sets `persist-credentials: false`; and the step is not
advisory — neither `continue-on-error: true` on the parsed step nor `|| true` in
the run body. Kit's own linter and formatter lists are asserted **by value**,
parsed as YAML, so a comment cannot satisfy them.

### `lint drift` — reads BOTH files and reports the DIFFERENCE

Preferred over "the file must be absent", as the brief asked. A service whose
`.golangci.yml` agrees with kit's **passes**; one that disagrees is told exactly
which linters it dropped or added. Self-test breakage 27b asserts the agreeing
copy passes, so the check cannot be satisfied by deleting it.

`lint/drift-allowlist` carries a difference you cannot delete yet: reason, owner,
`since`, `until`, and four rules — the fourth being that **an entry which no
longer describes a real difference fails**, modelled on ESLint's
`reportUnusedDisableDirectives`. Two entries are live, both for one repository:
`identity`, which carries a `.golangci.yml` that enables no linter at all because
it exists only to exclude one generated file. Migrating it is `identity`'s change
to make; kit does not touch other repositories.

---

## 5. Breakages added — nine, plus a green control

| # | breakage | caught by |
|---|---|---|
| 23 | a language job's `lint` step deleted | `lint_wiring_check` |
| 24 | it is made advisory — `continue-on-error: true` | `lint_wiring_check` |
| 24b | the same defect as `\|\| true` in the run body | `lint_wiring_check` |
| 25 | the kit checkout deleted, so `--config` names nothing | `lint_wiring_check` |
| 26 | the config weakened in place (three linters dropped) | `lint_wiring_check` |
| 27 | a service carries a config INCONSISTENT with kit's | `lint drift` |
| 27b | a service config that **matches** kit's | *green control* |
| 28 | one lint job's `lint-args guard` deleted | `lint_args_seam_check` |
| 28b | the guard kept, one refused token removed | `lint_args_seam_check` |
| 28c | the guard moved **after** the linter | `lint_args_seam_check` |

24 is the one the brief called out, and it is the one most worth having: the step
still runs, still prints every finding, and the job is green.

---

## 6. What I ran, and what I only reasoned about

Kept separate on purpose, because merging them into one number is how a
measurement becomes a claim.

### Ran, and it passes

- **`tests/lint_test.sh` — 14 assertions, 0 skips.** All four linters
  (golangci-lint 2.6.2, rubocop 1.91.0, ESLint 9 + typescript-eslint 8 on
  Node 22.12.0, yamllint from `tests/requirements.txt`). Every linter ran with
  kit's config, rejected a fixture built to violate it, and its control — same
  command, config removed — answered differently.
- **The whole gate, `bash tests/validate.sh`, twice: once in an isolated clone
  and once in the real worktree, both `exit 0`.** In the worktree — where the
  fleet is the real one and `lint drift` therefore actually runs —
  `lint_wiring_check`, `lint_args_seam_check` and `lint drift` all pass, and the
  drift line reads `11 service repo(s) compared against kit's golangci policy;
  1 carried their own config; 2 divergence(s) recorded in
  lint/drift-allowlist, none expired, none unused`. The allowlist entry is
  consumed by a real divergence rather than being tolerated, and rule 4 is
  evaluated against a repository that was actually read.
- **`tests/self_test.sh`** — the result is in the commit message. All six new
  breakages are caught by the check they name.
- **The `--config`-wins measurement** (A–H, §1 and the correction below),
  including the `[config_reader] Used config file` line from `run -v`.
- **The RuboCop remote `inherit_from` measurement**, positive and negative.
- **The `lint-args guard` itself, run.** The step body was extracted from the
  parsed workflow and executed with a table of values: every *stricter* setting
  is accepted — including the empty string, which is the fleet's state — and
  every one of the 14 escape hatches tested is refused, in both the
  `--flag=value` and the `--flag value` forms, and in a mixed list where one
  forbidden token is enough. The three copies were also compared and are
  byte-identical. A guard that is only ever read is a comment; this one was
  executed.
- **The sparse-checkout mechanics**, as tabulated in §6.
- **The adoption numbers in README.md.** Counted rather than carried over: a
  non-worktree directory beside this one whose workflows call the reusable
  workflow. That is **11**, and **1** of the eleven carries its own
  `.golangci.yml` (`identity`). The brief this packet came from recorded `8/8`
  and `0/9`; the second figure is stale, because identity's file has since
  landed on its `master`. Asserting `0/9` in the README would have been a
  number this work had measured and known to be wrong.

### Reasoned about, not run

- **The workflow itself has never executed on a GitHub runner.** The YAML parses
  and the wiring is asserted, but no service has run these jobs. The first real
  run is a CI event, not a test.
- **`sparse-checkout: lint` — the git half is measured, the action half is not.**
  Run against a throwaway repository laid out like kit's:

  | mode | resulting worktree |
  |---|---|
  | `--no-cone` (what the workflow passes) | `lint/golangci.yml`, `lint/rubocop.yml` — **exactly** the `lint/` tree, no root files |
  | cone mode (the default) | the same two files **plus `README.md`**, and `warning: unrecognized pattern: 'lint'` on every run |

  So `sparse-checkout-cone-mode: false` is load-bearing rather than tidy: without
  it git rejects the pattern as a cone pattern, warns on every push, and widens
  the checkout to the root files. What is **not** measured is that
  `actions/checkout@v7` maps those two inputs onto exactly those two git
  commands, or what its `path:` does when the target directory does not exist. If
  the checkout ever failed to produce `lint/`, the first symptom would be a
  golangci-lint run that falls back to its five defaults — which breakage 25 is
  written to catch, and which the wiring and drift checks cannot see.
- **`persist-credentials: false` on a second checkout** was not run in a runner
  with a real token.
- **The `kit-lint-ref` / `uses:`-ref mismatch** is documented, not detected.
  Nothing in kit can see the caller's `uses:` ref from inside the workflow.
- **Node's `ERR_UNSUPPORTED_ESM_URL_SCHEME` result was measured on Node 22.12.0**
  locally, not on the runner's Node, and not on every future Node. The claim
  "a remote ESLint config is not possible" is a claim about Node's ESM loader,
  and it is the kind of thing a future Node could change.
- **Windows/macOS/Linux**: the tests were run on macOS with bash 3.2. The
  canonicalising of `$TMPDIR` in `lint_test.sh` is there because of a measured
  macOS symlink failure, but nothing here has been run on a Linux runner.

---

## 7. Three corrections to the work this packet inherited

Both were claims in the tree that the tree's own evidence contradicted once the
tools were actually run. Recording them because the second one is the more
interesting shape of mistake.

**(a) golangci-lint discovery does not beat `--config` — the opposite.** The
drift check was written on the belief that a repo-root `.golangci.yml` is
discovered "ahead of any flag the workflow passes", so a stale copy silently
hijacked CI. Measured, `--config` **wins**: `golangci-lint run -v` prints exactly
one `[config_reader] Used config file`, and with the flag it names kit's. A local
config that disables `misspell` does not survive it. RuboCop agrees. A copy does
not hijack the build — it **splits** the policy, because every other invocation in
that repository reads it while CI reads kit's, and it becomes live again the
instant the flag is lost. Still a finding; the honest one.


**(b) An allowlist rule that was red on a correct tree.** "An entry that no longer
describes a difference" treated a repository *absent from this checkout's fleet*
as one that had stopped differing. Since `self_test.sh` runs the gate against a
throwaway copy of kit, which has no fleet beside it, **every entry was reported
as dead on a correct tree** — and the gate was red before anything else was
checked. Rule 4 is now scoped to repositories the run actually looked at; an
entry naming one that was not looked at is reported as **unverified**, which is
neither a pass nor a failure. A rule that cries wolf in its own test suite is a
rule people learn to bypass with `--no-`.

Fixing (b) also required giving each self-test copy its own parent directory, since
`fleet_repos` finds a fleet by globbing `$ROOT/..` — otherwise all twenty-nine
copies were each other's fleet, and a breakage could be "caught" by a defect it
did not introduce.

**(c) A promise in a comment with no control behind it.** The `lint-args` input
description said `lint_wiring_check` "fails on exactly that string" for
`--no-config`. It did not — and, structurally, it could not, because
`lint-args` is the **caller's** value and kit's gate never sees it. This is the
one inherited claim that was not merely wrong but *unimplementable where it was
claimed*, and it is the reason the seam's control lives in the workflow. A
comment promising a check is worse than no comment: the second one stops the
reader looking for the first.

---

## 8. The merge this packet is going to have, named in advance

`master` had not moved off `41f8bcb` when this was written, so the rebase the
brief asks for was a no-op and `master` is an ancestor of `HEAD`. That will not
be true for long, and `worker/kit-04` (the secrets work, being landed on master's
behalf) is based on `4fe04fd9` and edits **four of the same files this packet
does**. So the collision is not hypothetical and it is worth writing down rather
than discovering:

| file | kit-12 | kit-04 | what the merge needs |
|---|---|---|---|
| `.github/workflows/ci.reusable.yml` | +212: the `lint-args guard` step ×3, the `kit-lint-ref`/`lint-args` inputs, three `kit (lint config)` checkouts, three `--config` lint steps | +153 (secrets) | both sets of steps; the ordering constraint that matters is `lint-args guard` **before** `lint`, which `lint_args_seam_check` enforces — so if the merge reorders them the gate says so rather than a reader having to notice |
| `tests/validate.sh` | +654: `lint_wiring_check`, `lint_args_seam_check`, `lint_drift_check`, the `lint` phase, the `--no-lint` flag | +1129: gitleaks and zizmor gates | four new checks and two new gate scripts; the phase list in the file header and the `--help` range are both hand-maintained and will need re-reading, not merging |
| `tests/self_test.sh` | 32 breakages + 1 green control, numbered 23–28c, with the header rewritten to match | +313, its own breakages | **both packets numbered their first new entry from 23.** `self_test_claims` will go red on the collision rather than letting a claim drift from its recipe — that is the check earning its keep — and the header count and the `Seven…/Fourteen…`-style tallies have to be recounted from the union |
| `AGENTS.md`, `CHANGELOG.md`, `README.md` | phase list, layout, the new README section | its own entries | `## Unreleased` sections and the adoption table both want edits from each side; `README.md` is checked against the workflow inputs, so a merged workflow with both sets of inputs must still match the documented callers |

The self-test numbering is the sharpest of these and it is not a merge problem so
much as a **counting** one: after the union there will be more breakages than
either packet's header claims, and the header/recipe check compares them
mechanically. Whoever lands this second should expect that check to be the thing
that fails first, and should treat it as information rather than as an obstacle.

## 9. A live defect in the branch this packet merges with, found by this packet's method

`worker/kit-08-merge` (the branch being landed on `master`'s behalf) uses
`${GITHUB_ACTION_PATH}` **five times** inside `ci.reusable.yml`:

```
826:  dir="${GITHUB_ACTION_PATH}/templates/otel/…"
895:  . "${GITHUB_ACTION_PATH}/tests/bootstrap.sh"
898:  … "$KIT_GITLEAKS_SHA256S" "$GITHUB_ACTION_PATH" …
914:  run: bash "${GITHUB_ACTION_PATH}/tests/gitleaks_gate.sh" …
953:  run: bash "${GITHUB_ACTION_PATH}/tests/zizmor_gate.sh" …
```

GitHub's variables reference states that `GITHUB_ACTION_PATH` "is only supported
in composite actions", and a reusable workflow is not one. This packet depends
on the same fact from the other direction — it measures, in `tests/lint_test.sh`,
that node resolves an ESM config's imports from the config file's own directory
upward, and that a config outside the service tree therefore cannot work at all
— so the lint mechanism here is a `uses: actions/checkout` and never
`$GITHUB_ACTION_PATH`.

So the expectation is that on a real runner those paths expand to nothing and the
`secrets` and `zizmor` jobs read a file that is not there. **I have not run a
GitHub runner and cannot confirm it**, so it is filed as a finding rather than a
verdict — but it is worth more than a note, because those two new jobs are the
kit-04 deliverable and the whole point of kit is that a gate which cannot fail is
not a gate. Line 826 is pre-existing in this branch: the `telemetry` job's
fallback to kit's own copy of the conformance suite has the same problem and has
had it since kit-02. Nobody noticed for the same reason nobody noticed `lint/`:
every check in the repository parses YAML, and a variable that expands to the
empty string parses.

## 10. What I could not verify

- The two claims in `ci.reusable.yml` that only a GitHub runner can settle: the
  sparse checkout's resulting tree, and the action's `args` space-splitting.
- Whether any of the eight service repos has a `.rubocop.yml` or an
  `eslint.config.mjs` that disagrees with kit's. `lint drift` only reads
  `.golangci.yml`/`.golangci.yaml`, deliberately — a repo's own `eslint.config.mjs`
  is a legitimate thing to own, and unlike `.golangci.yml` it is only read by
  something that points at it. If that judgement is wrong, the gap is a widening
  of `SERVICE_CONFIGS`, and nothing here would notice.
- Whether the fleet's `.golangci.yml` files are what the brief described. The
  brief said the only one was on an unlanded branch; on this machine `identity`
  is on `master` and carries one. That is the single live allowlist entry, and it
  is `identity`'s migration to make, not kit's.
- I did not run the full gate concurrently with the other nine workers sharing
  this machine. Two runs of `--static-only` were interleaved with another process
  rewriting `tests/validate.sh` underneath them, which produced two phantom
  `syntax error near unexpected token` reports that were **not** defects in the
  script — `bash -n` was clean, and the same tree ran green. Worth knowing if a
  future worker sees those.
