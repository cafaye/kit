# REPORT-kit-03 — the observability stack, and landing it on a moving master

> **On the file's own history:** the brief for this packet says to re-read this
> report first, and it did not exist — not in the worktree, not in `git log
> --all`, nowhere under `moon/`. The packet's earlier process evidently wrote it
> somewhere that was not committed, or the disk-full recovery (`3533ac7`) lost
> it. The section below is the record the brief asked for, and the rest is
> reconstructed from the eleven commits and from what the tree contains, which
> is the same evidence. It is worth flagging because a report that evaporates
> between packets is the same class of defect as the workflow that sat at a path
> GitHub could not resolve: the work is real, the record of it is gone, and
> nothing checks.

## The rebase (kit-03-rebase)

### What conflicted

Nine commits landed on master after `badcc2a`, including three that moved the
ground under this branch:

| commit | what it changed under kit-03 |
|---|---|
| `d42aebb` | the reusable workflow moved `workflows/` → `.github/workflows/` |
| `fb664a9` | kit began calling its own reusable workflow locally |
| `9a8c3d7` | a real Dockerfile parser, and two real Dockerfile bugs it found |
| `a1cad0d` | the gate bootstraps its own dependencies on a clean clone |
| `9b3dbeb` | hadolint release assets are `macos-*`, not `darwin-*` |

`git merge master` into `worker/kit-03` conflicted in five files:
`tests/self_test.sh` (4 hunks), `tests/validate.sh` (3), and `AGENTS.md`,
`CHANGELOG.md`, `README.md`.

### Merge, not rebase

Both sides had to author the same two test files from the same divergent base,
and the correct resolution is a union rather than a choice. A rebase replays
that authoring decision once per commit — nine times — and arrives at the same
union. A merge makes the decision once, in one reviewable commit, with the
reasoning attached to the conflict rather than smeared across nine replays. The
result is identical; the merge is simply legible.

Consequence, and the thing the brief asked me to check: `master` is now a
**direct ancestor** of this branch, so merging the branch into master is a
fast-forward with zero conflicts by construction. Verified with
`git merge-base --is-ancestor master HEAD`.

### How each file resolved

**`tests/self_test.sh` — union. 19 breakages: master's 18 plus kit-03's `2b`.**
Not a choice. Picking master's side deletes the missing-exporter proof, which is
the one breakage that catches "the stack collects everything and prints nothing";
picking kit-03's deletes the four `uses:`-path drift proofs, the two Dockerfile
proofs, and the six per-language mutants. The file's entire claim is that every
breakage is caught by a *different* check, so a side-pick destroys exactly the
independence the file exists to demonstrate.

Master's prose was kept where it was newer, kit-03's where it was newer:

- master's 7-10 (four ways to break the documented `uses:` string against the
  real path, each asserting *which* check went red), 11-12 (the two Dockerfile
  defects) and 13-18 (one semantic mutation per language) — all intact;
- kit-03's `2b`, and its rewritten recipes for 2 and 4, which named strings that
  no longer exist (`exporters: [debug]` stopped being the traces pipeline when
  it fanned out to three backends; a literal `${KIT_POSTGRES_PORT:-5432}`
  stopped existing when the stack moved into the 15000-15999 port block).

Every one of master's 7-12 recipes applied without modification against the
merged tree. Nothing was dropped to make the self-test pass, and no breakage was
deleted.

**`tests/validate.sh` — union, with one deliberate deletion.** kit-03's
`observability` phase, the `dev_escape_hatch` execution check and the eleven
observability checks all sit alongside master's `callable path` check, its
`tests/bootstrap.sh` wiring and its whole-tree `yamllint`. The collector and
compose checks were re-pointed at `.github/workflows/` by the rename rather than
reintroducing the old path, and `fb664a9`'s local self-call was left alone.

The one thing dropped: **kit-03's own walk of `templates/compose`**. It existed
because the Grafana provisioning tree is three directories deep and a glob of
`templates/compose/*` reaches none of it. Master's `yamls_of_the_tree` enumerates
by `git ls-files` and reaches those same files plus the rest of the repo, so
keeping both would mean two loops over one set of files reporting every problem
twice and disagreeing about which is authoritative. This is redundancy, not a
check: the same YAML is still linted, and now so is everything else.

**`AGENTS.md` / `README.md` / `CHANGELOG.md` — union.** Both sides' entries kept,
counts updated to 19, and the CHANGELOG's two `### Added` sections (one from each
side) folded into one so the file has a single `Added` / `Fixed` / `Changed`
shape. The two contradictory "`self_test.sh` grew from 5 breakages to N"
bullets became one entry stating 19 and why.

Verified no content was lost: every `- ` bullet from both `HEAD` and `master` is
present in the merged CHANGELOG, checked programmatically.

### The count is now derived, not written down

The union had to say "19" in three places, and a literal in three places is a
thing that goes stale the moment the next packet adds a check — it was already
stale in both directions during this merge, once per side. Both runtime numbers
are now counted from the recipes, and a new check asserts the header and the
recipes agree **in both directions**: a recipe with no header entry is a breakage
the file proves but does not claim, and a header entry with no recipe is a claim
the file does not deliver. The union requirement is now an assertion rather than
a review instruction.

That check was written before it passed and caught two real defects in itself,
both recorded in the code: a `return` in a top-level heredoc'd script (a
`SyntaxError`, so it failed on every tree including a correct one), and a range
expansion that put `7-10` into a set as `int` while single entries arrived as
`str` — so every two-digit breakage was reported as both missing and orphaned. It
also correctly refused to accept breakage 5's double-quoted label, which was
fixed in the pattern rather than by rewriting a working recipe to suit a new
check. Verified green on the real header and red on both defects it claims.

## What kit-03 built (reconstructed)

The observability stack, on by default in dev. The work is all still here and
none of it was redone:

- **The collector** (`templates/compose/otel-collector.yml`) — OTLP and
  container-stderr receivers, the redaction allowlist **derived from core's
  schemas** and compared both ways, the `spanmetrics` connector, fan-out to
  Tempo/Loki/Mimir. Every endpoint a `${env:...}`; the gate fails on a literal.
- **The LGTM stack** — vendor configuration for Tempo, Loki and Mimir plus
  Grafana provisioning as files: three datasources, the dashboard provider, two
  dashboards, three alert rules. AGPL backends ship unmodified and pinned, in an
  `observability` profile, on a **15000-15999** port block asserted as a range.
- **Two Grafana dashboards** and `cafaye-fleet-errors.json`, with a check that
  every panel names the backend that can answer it — the defect that check exists
  for was every LogQL and TraceQL query being sent to Mimir's Prometheus API.
- **The six language snippets**, now honouring `<SERVICE>_OTEL_ENDPOINT` by
  default, implementing the free no-op with `OTEL_SDK_DISABLED`, recording
  `error.type` and never `error.message`, and emitting exception **log records**
  rather than the deprecated span event.
- **`tests/canary_test.sh`** — a canary secret in ten leak shapes against a real
  collector, asserted to reach no exporter, *and* that the allowed data survived.
- **`tests/no_telemetry_in_readiness.sh`** — a service starts, serves and reports
  healthy with the collector killed, and a collector whose three backends all
  refuse connections stays healthy and does not enter a retry loop.

### Bugs the work found in itself

Worth recording because each was invisible to a static check and each is now
covered:

- `tenant_id` was silently stripped from every trace and log resource — the
  redaction processor deletes every attribute it does not exempt, and the traces
  and logs processors did not exempt the private stash carrier. Per-tenant metric
  totals worked; per-tenant trace and log identity did not, with no error
  anywhere.
- The collector's `_total` rename never fired: a regex inside a YAML
  *single-quoted* scalar, where a backslash is not an escape. Every dashboard
  panel rendered "No data".
- The local stack could not start. The collector resolves values from its own
  process environment, and Docker Compose does not inject the `.env` values it
  substitutes into containers — every one resolved empty. The stack parsed,
  passed every check kit had, and did not work.
- `bin/dev` died on `KIT_DEV_PROFILES=` (the documented escape hatch) with an
  unbound-variable error, because macOS ships bash 3.2 where `"${a[@]}"` on an
  empty array is an error. Spectacular precisely because the default path works.

## Verification

`bash tests/validate.sh`, one command on a clean clone, bootstrapping its own
dependencies. Exit 0, **zero skips** (with `KIT_CORE` set so the allowlist
derivation runs against the real core schemas rather than skipping). 19 of 19
breakages go red; the unbroken tree is green. `shellcheck -S warning` clean on
every shell in the tree.

## Ground rules

Held throughout: `bin/prime` is the gate and it is one command on a clean clone;
no sleeps, no raised retries, no loosened assertions; the breakage count moved
from 18 and 12 to 19 because **a check was added**, never because one was made
easier; core read-only and never modified; nothing copied from `moon/refs/`;
nothing pushed, no remote created, no visibility changed.
