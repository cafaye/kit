#!/usr/bin/env bash
#
# tests/staleness_test.sh — the staleness reporter, on a fleet built in a temp dir.
#
#   bash tests/staleness_test.sh
#
# WHY A SYNTHETIC FLEET
#
#   The real fleet is a developer's working directory: it changes under whoever
#   runs it, and every one of its repositories is a moving target. A test that
#   asserted against it would be green on Tuesday and red on Wednesday for a
#   reason that has nothing to do with the reporter. So this builds its own core
#   with real commits and real tags, and its own consumers with real
#   `vendir.lock.yml` and real `CORE_REF:` lines, and asserts the reporter tells
#   them apart.
#
# THE CLAIMS BEING TESTED
#
#   1. It says `current`, `behind`, `unknown` and `undeclared` and never
#      confuses them. A reporter that cannot say "I do not know" is a reporter
#      that will eventually say "fine".
#   2. It reads BOTH pin forms, because three of the fleet's repositories still
#      use the hand-bumped `CORE_REF` and a reporter that only understood
#      lockfiles would lose sight of them on the day the migration landed.
#   3. It notices when a mid-migration repository's two pins disagree.
#   4. It does not count a git worktree as a second consumer.
#   5. `--fail-on-behind` is red on a stale copy and green on a current one. The
#      red half is the proof; the green half is what stops it being red on
#      everything, which is the other way a staleness gate rots.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STALE="$ROOT/tests/staleness.py"

if [ ! -r "$ROOT/tests/bootstrap.sh" ]; then
  echo "staleness_test.sh: tests/bootstrap.sh is missing — cannot resolve a python" >&2
  exit 1
fi
# shellcheck source=tests/bootstrap.sh
. "$ROOT/tests/bootstrap.sh"
kit_bootstrap_python "$ROOT"
export KIT_PYTHON="$PY"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kit-staleness.XXXXXX")"
# `KIT_KEEP_WORK=1` leaves the fixtures on disk, which is the difference between
# debugging a state table and guessing at one. The default still cleans up.
if [ "${KIT_KEEP_WORK:-0}" = "1" ]; then
  trap 'printf "note: fixtures kept at %s\n" "$WORK" >&2' EXIT
else
  trap 'rm -rf "$WORK"' EXIT
fi

FLEET="$WORK/fleet"
mkdir -p "$FLEET"

# WHY EVERY ASSERTION BELOW IS A HERE-STRING AND NOT A PIPE.
#
# `printf '%s\n' "$OUT" | grep -qE '...'` is a race, and this file ran it 28
# times under `set -o pipefail`. `grep -q` exits at the FIRST match and closes
# the pipe, so `printf` takes SIGPIPE and dies 141 — but only if it had not
# already finished writing. The reporter's table is large (9 fixture services,
# ~60 rows), so "had not finished" is the common case, and `pipefail` then turns
# a SUCCESSFUL match into a non-zero pipeline. The `if` reads that as "the
# assertion failed" and the case goes red for a reason that has nothing to do
# with the reporter.
#
# It bit for real: the self_test control went red at load average 160 with
# `printf: write error: Broken pipe` on the line before the failing case, and the
# case named the reporter. `tests/canary_test.sh` already documents this exact
# race and fixes it the same way — "reading a file has no pipe and no SIGPIPE,
# so there is nothing left to race against". A here-string is the same answer for
# a value already in a variable: no pipe, no SIGPIPE, nothing to race against.
#
# The same rewrite was applied to `self_test.sh` (whose `expect_red_check` pipes
# an entire gate run — the largest producer here), `classify_test.sh`,
# `validate.sh` and `canary_test.sh`: 36 sites in total.

failures=0
passes=0

# --- a real core with real history -----------------------------------------
git -C "$FLEET" init -q core
CORE="$FLEET/core"
printf '{}\n' >"$CORE/f.json"
git -C "$CORE" add -A
git -C "$CORE" -c user.email=t@e -c user.name=t commit -qm one
OLD_SHA=$(git -C "$CORE" rev-parse HEAD)
printf '{"x":1}\n' >"$CORE/f.json"
git -C "$CORE" add -A
git -C "$CORE" -c user.email=t@e -c user.name=t commit -qm two
printf '{"x":2}\n' >"$CORE/f.json"
git -C "$CORE" add -A
git -C "$CORE" -c user.email=t@e -c user.name=t commit -qm three
HEAD_SHA=$(git -C "$CORE" rev-parse HEAD)

# --- consumers --------------------------------------------------------------
#
# Every consumer is a git checkout, because that is the precondition the reporter
# uses to decide what a repository is. The first version of this fixture created
# the directories and forgot to `git init` them, so discovery correctly reported
# one repository out of five and four cases failed — which is the reporter being
# right and the fixture being wrong, and worth recording because "the reporter
# found nothing" and "the fixture was incomplete" look identical from outside.
for repo in current-repo behind-repo handbumped-repo disagreeing-repo undeclared-repo; do
  mkdir -p "$FLEET/$repo"
  git -C "$FLEET/$repo" init -q
  # One commit each, so a worktree can be created below: `git worktree add`
  # needs a resolvable HEAD, and a repository with no commits has none.
  printf '%s\n' "$repo" >"$FLEET/$repo/README.md"
  git -C "$FLEET/$repo" add -A
  git -C "$FLEET/$repo" -c user.email=t@e -c user.name=t commit -qm "init $repo"
done

# current: a lockfile pinned at core's own HEAD.
mkdir -p "$FLEET/current-repo/.github/workflows"
cat >"$FLEET/current-repo/vendir.lock.yml" <<YML
apiVersion: vendir.k14s.io/v1alpha1
directories:
- contents:
  - git:
      commitTitle: three
      sha: $HEAD_SHA
      tags:
      - v0.3.0
    path: .
  path: out
kind: LockConfig
YML

# behind: a lockfile pinned two commits back.
mkdir -p "$FLEET/behind-repo"
cat >"$FLEET/behind-repo/vendir.lock.yml" <<YML
apiVersion: vendir.k14s.io/v1alpha1
directories:
- contents:
  - git:
      sha: $OLD_SHA
    path: .
  path: out
kind: LockConfig
YML

# handbumped: the CORE_REF form, at the old sha. This is what three of the
# fleet's repositories actually look like today.
mkdir -p "$FLEET/handbumped-repo/.github/workflows"
cat >"$FLEET/handbumped-repo/.github/workflows/ci.yml" <<YML
name: ci
on: [push]
env:
  CORE_REF: $OLD_SHA
jobs: {}
YML

# disagreeing: a mid-migration repository whose two pins name different commits.
mkdir -p "$FLEET/disagreeing-repo/.github/workflows"
cat >"$FLEET/disagreeing-repo/vendir.lock.yml" <<YML
apiVersion: vendir.k14s.io/v1alpha1
directories:
- contents:
  - git:
      sha: $HEAD_SHA
    path: .
  path: out
kind: LockConfig
YML
cat >"$FLEET/disagreeing-repo/.github/workflows/ci.yml" <<YML
name: ci
on: [push]
env:
  CORE_REF: $OLD_SHA
jobs: {}
YML

# undeclared: a repository that vendors core's bytes and records nothing.
mkdir -p "$FLEET/undeclared-repo/schemas"
printf '{}\n' >"$FLEET/undeclared-repo/schemas/x.json"

# a worktree of behind-repo, which must NOT appear as its own consumer. A
# worktree's `.git` is a FILE holding a `gitdir:` pointer, which is the whole
# difference the reporter has to notice.
git -C "$FLEET/behind-repo" worktree add -q --detach "$FLEET/behind-worktree" HEAD \
  || echo "note: worktree unavailable; case 9b falls back to the is_worktree() unit assertion"

# --- assertions -------------------------------------------------------------

printf -- '-- staleness_test: the fleet staleness reporter tells the states apart\n'

# run <args...> — capture output and status without a pipe. A piped status is the
# status of the last stage, and this script asserts on a command that is meant to
# fail more often than not.
run() {
  OUT=""
  EC=0
  OUT=$("$PY" "$STALE" --repos-dir "$FLEET" "$@" 2>&1) || EC=$?
}

# 1. the control: the table names all five repositories and gets the states right.
run
if [ "$EC" -eq 0 ] \
    && grep -qE '^current-repo .* current$' <<<"$OUT" \
    && grep -qE '^behind-repo .* behind$' <<<"$OUT" \
    && grep -qE '^handbumped-repo .* behind$' <<<"$OUT" \
    && grep -qE '^undeclared-repo .* undeclared$' <<<"$OUT"; then
  printf 'PASS staleness_test: current / behind / undeclared are told apart\n'
  passes=$((passes + 1))
else
  printf 'FAIL staleness_test: the state table is wrong (exit %s)\n' "$EC"
  printf '%s\n' "$OUT" | sed 's/^/       /'
  failures=$((failures + 1))
fi

# 2. the behind count is measured, not guessed. Two commits separate OLD_SHA and
#    HEAD_SHA, and a reporter that reported any number at all would be no better
#    than one that reported "behind".
if grep -qE '^behind-repo .* +2 +behind$' <<<"$OUT"; then
  printf 'PASS staleness_test: the distance is measured (2 commits)\n'
  passes=$((passes + 1))
else
  printf 'FAIL staleness_test: the distance is not 2\n'
  printf '%s\n' "$OUT" | sed 's/^/       /'
  failures=$((failures + 1))
fi

# 3. the hand-bumped form is read. This is the form three real repositories use,
#    and a reporter that only understood lockfiles would report them as
#    `undeclared` — which is the failure mode that matters, because `undeclared`
#    reads as "nothing to do".
if grep -qE '^handbumped-repo .* CORE_REF' <<<"$OUT"; then
  printf 'PASS staleness_test: a hand-bumped CORE_REF is read as a pin\n'
  passes=$((passes + 1))
else
  printf 'FAIL staleness_test: the CORE_REF form was not read\n'
  printf '%s\n' "$OUT" | sed 's/^/       /'
  failures=$((failures + 1))
fi

# 4. the two pins of a mid-migration repository are compared, not just the first
#    one found. A repository whose lockfile and workflow name different commits
#    has bytes under test that are not the bytes on disk.
if grep -q 'PINS DISAGREE' <<<"$OUT"; then
  printf 'PASS staleness_test: two disagreeing pins are reported\n'
  passes=$((passes + 1))
else
  printf 'FAIL staleness_test: disagreeing pins were not reported\n'
  printf '%s\n' "$OUT" | sed 's/^/       /'
  failures=$((failures + 1))
fi

# 5. a lockfile's tag is read, so the table can say which release is vendored.
if grep -qE '^current-repo .* v0\.3\.0' <<<"$OUT"; then
  printf 'PASS staleness_test: the lockfile tag is reported\n'
  passes=$((passes + 1))
else
  printf 'FAIL staleness_test: the lockfile tag was not reported\n'
  failures=$((failures + 1))
fi

# 6. THE RED PROOF, half one: --fail-on-behind exits 1 on a stale copy.
run --fail-on-behind
if [ "$EC" -eq 1 ] && grep -q 'FAIL staleness:' <<<"$OUT"; then
  printf 'PASS staleness_test: --fail-on-behind is RED on a stale copy\n'
  passes=$((passes + 1))
else
  printf 'FAIL staleness_test: --fail-on-behind stayed green on a stale copy (exit %s)\n' "$EC"
  printf '%s\n' "$OUT" | sed 's/^/       /'
  failures=$((failures + 1))
fi

# 7. THE RED PROOF, half two: the same flag is green when every named repository
#    is current. Without this the flag could be a constant `exit 1` and case 6
#    would still pass, which is the failure mode of a gate nobody ever sees pass.
run --repo current-repo --fail-on-behind
if [ "$EC" -eq 0 ]; then
  printf 'PASS staleness_test: --fail-on-behind is GREEN when every pin is current\n'
  passes=$((passes + 1))
else
  printf 'FAIL staleness_test: --fail-on-behind was red on a current pin (exit %s)\n' "$EC"
  printf '%s\n' "$OUT" | sed 's/^/       /'
  failures=$((failures + 1))
fi

# 8. a repository named on the command line that does not exist is an error, not
#    an empty row. Silence here would make a typo look like a clean fleet.
run --repo does-not-exist
if [ "$EC" -eq 1 ] && grep -q 'could not be read' <<<"$OUT"; then
  printf 'PASS staleness_test: a named repository that cannot be read is an error\n'
  passes=$((passes + 1))
else
  printf 'FAIL staleness_test: a missing repository was reported as a clean row\n'
  failures=$((failures + 1))
fi

# 9. `core` is the reference, not a consumer, so it gets no row. A row reading
#    "core: undeclared" would be a true sentence about a meaningless question.
#    The pattern is anchored on a state word so it cannot match the `core master:`
#    header line, which the first version of this assertion did — and which made
#    the check fail for a header rather than for a row.
run
if grep -qE '^core +[^ ]+ +(none|vendir\.lock\.yml|CORE_REF) +' <<<"$OUT"; then
  printf 'FAIL staleness_test: core is reported as its own consumer\n'
  printf '%s\n' "$OUT" | sed 's/^/       /'
  failures=$((failures + 1))
else
  printf 'PASS staleness_test: core is the reference and gets no row\n'
  passes=$((passes + 1))
fi

# 9b. A git worktree is the same consumer as its parent and must not be counted
#     twice. Where the worktree could not be created, `is_worktree` is asserted
#     directly so the case is never silently skipped.
if [ -e "$FLEET/behind-worktree/.git" ] && [ ! -d "$FLEET/behind-worktree/.git" ]; then
  run
  if grep -q '^behind-worktree ' <<<"$OUT"; then
    printf 'FAIL staleness_test: a git worktree was counted as a second consumer\n'
    failures=$((failures + 1))
  else
    printf 'PASS staleness_test: a git worktree is not counted as a second consumer\n'
    passes=$((passes + 1))
  fi
  run --include-worktrees
  if grep -q '^behind-worktree ' <<<"$OUT"; then
    printf 'PASS staleness_test: --include-worktrees opts back in\n'
    passes=$((passes + 1))
  else
    printf 'FAIL staleness_test: --include-worktrees did not include the worktree\n'
    failures=$((failures + 1))
  fi
elif "$PY" - "$FLEET/handbumped-repo" <<'PY'
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(".")), ""))
import importlib.util
spec = importlib.util.spec_from_file_location("stale", os.path.join("tests", "staleness.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
# A real repository's .git is a directory; a worktree's is a file.
assert mod.is_worktree(os.path.join(sys.argv[1], ".git")) is False
PY
then
  printf 'PASS staleness_test: a real checkout is not mistaken for a worktree\n'
  passes=$((passes + 1))
else
  printf 'FAIL staleness_test: is_worktree() misreads a real checkout\n'
  failures=$((failures + 1))
fi

# 10. JSON output is machine-readable and agrees with the table, because the
#     scheduled artifact is the JSON and the table is for a human reading it.
run --json
if [ "$EC" -eq 0 ] && "$PY" - "$OUT" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
states = {row["repo"]: row["state"] for row in payload["rows"]}
assert payload["core_head"], "no core head"
assert states["behind-repo"] == "behind", states
assert states["current-repo"] == "current", states
assert states["undeclared-repo"] == "undeclared", states
PY
then
  printf 'PASS staleness_test: --json agrees with the table\n'
  passes=$((passes + 1))
else
  printf 'FAIL staleness_test: --json disagrees with the table\n'
  failures=$((failures + 1))
fi

# ===========================================================================
# the templates half: the copy-is-gone case
# ===========================================================================
#
# `--scope core` measures a PIN. `--scope templates` measures a FILE, and the
# three states it has to tell apart are not a subset of the core four:
#
#   current   byte-identical to what kit ships, at the declared path
#   diverged  present, not identical
#   absent    kit ships one and the service has NOTHING there. This is the
#             state the reporter had no word for, and it is the common one:
#             0/9 of the fleet has otel-collector.yml. A reporter that called
#             it "nothing to check" would be right about the comparison and
#             wrong about the fleet.
#
# The fixture below copies kit's REAL artefacts, byte for byte, so a `current`
# cell here means the same thing it will mean against the real fleet. Nothing
# synthetic: a fixture artefact that kit later renames would make this suite
# green for a table that is wrong, so the fixture names the artefacts
# explicitly and a rename turns the control red.

TABLE="$ROOT/tests/artifacts.json"
ALLOWLIST="$ROOT/templates/parity-allowlist"

if [ ! -r "$TABLE" ]; then
  echo "FAIL staleness_test: tests/artifacts.json is missing — there is no declaration of what kit ships" >&2
  failures=$((failures + 1))
fi

# A fleet for the templates half. Four services, each exercising a different
# part of the vocabulary, plus a fifth whose pins are all dead.
TPL="$WORK/templates-fleet"
mkdir -p "$TPL"

# kit under the name the reporter excludes from the core scope. It is here so
# the SAME `--repos-dir` serves both scopes, which is how the real fleet is
# laid out, and so a change that made the two scopes interfere would be caught.
git -C "$TPL" init -q kit
cp -R "$ROOT/templates" "$TPL/kit/templates"
cp -R "$ROOT/lint" "$TPL/kit/lint"
cp -R "$ROOT/docker" "$TPL/kit/docker"
mkdir -p "$TPL/kit/.github/workflows"
cp "$ROOT/.github/workflows/ci.reusable.yml" "$TPL/kit/.github/workflows/ci.reusable.yml"
git -C "$TPL/kit" add -A
git -C "$TPL/kit" -c user.email=t@e -c user.name=t commit -qm kit

# mksvc <name> <language|-> — a service checkout. `git init` because that is the
# precondition discovery uses to decide what a repository is, and a fixture that
# forgets it looks exactly like "the reporter found nothing".
mksvc() {
  mkdir -p "$TPL/$1"
  git -C "$TPL/$1" init -q
  printf '%s\n' "$1" >"$TPL/$1/README.md"
  git -C "$TPL/$1" add -A
  git -C "$TPL/$1" -c user.email=t@e -c user.name=t commit -qm "init $1"
  if [ "$2" != "-" ]; then
    mkdir -p "$TPL/$1/.github/workflows"
    cat >"$TPL/$1/.github/workflows/ci.yml" <<YML
---
name: ci
on: [push, pull_request]
jobs:
  ci:
    uses: cafaye/kit/.github/workflows/ci.reusable.yml@master
    with:
      language: $2
YML
  fi
}

# adopt <service> <source-relative-to-kit> <dest-relative-to-service> — a copy
# a service really made. Byte-for-byte, so `current` is a true word.
adopt() {
  mkdir -p "$TPL/$1/$(dirname "$3")"
  cp "$TPL/kit/$2" "$TPL/$1/$3"
}

# 11. CURRENT. Everything kit ships for a `go` service, copied verbatim — and
#     copied to the paths `artifacts.json` declares, because the reporter
#     resolves a cell by the DECLARED path and by no other. A fixture that
#     copied the stack to `compose/` would prove the reporter reads a table it
#     does not ship rather than the one it does.
mksvc current-svc go
adopt current-svc templates/mise.toml mise.toml
adopt current-svc templates/AGENTS.md AGENTS.md
adopt current-svc templates/bin-prime/go.sh bin/prime
adopt current-svc templates/bin/dev.sh bin/dev
adopt current-svc docker/Dockerfile.go docker/Dockerfile
adopt current-svc lint/yamllint.yml .yamllint.yml
adopt current-svc lint/golangci.yml .golangci.yml
adopt current-svc lint/hadolint.yaml .hadolint.yaml
cp -R "$TPL/kit/templates/compose/." "$TPL/current-svc/"

# 12. DIVERGED. A copy that was made and then edited — a service pinning its
#     own version, which is what kit's own README tells it to do.
mksvc diverged-svc ruby
adopt diverged-svc templates/AGENTS.md AGENTS.md
sed 's/^# kit template.*/# service-local edit, one line/' \
  "$TPL/kit/templates/mise.toml" >"$TPL/diverged-svc/mise.toml"
adopt diverged-svc templates/bin-prime/ruby.sh bin/prime
adopt diverged-svc lint/rubocop.yml .rubocop.yml

# 13. ABSENT. A service that adopted the caller and nothing else. This is the
#     state the reporter had no word for, and the shape most of the real fleet
#     is in.
mksvc absent-svc node

# 13b. THE HARD CASE, and the one a member-by-member report would get wrong. A
#      service holding NINE of the stack's twelve files: `docker-compose.yml` is
#      its own, and `otel-collector.yml` is absent. That stack does not start,
#      and eleven separately-pinned cells would call it nine successes and two
#      absences. `compose` is one artefact precisely so it is `diverged` here.
mksvc halfstack-svc python
adopt halfstack-svc templates/compose/docker-compose.yml docker-compose.yml
sed 's/^# the LGTM stack.*/# this service runs postgres and nats only/' \
  "$TPL/kit/templates/compose/docker-compose.yml" >"$TPL/halfstack-svc/docker-compose.yml"
adopt halfstack-svc templates/compose/loki/loki-config.yaml loki/loki-config.yaml
adopt halfstack-svc templates/compose/mimir/mimir.yaml mimir/mimir.yaml
adopt halfstack-svc templates/compose/tempo/tempo.yaml tempo/tempo.yaml

# 14. UNDECLARED LANGUAGE. Calls nothing, so the language-dependent artefacts
#     cannot be resolved. This must be `unknown` and must require a pin, not
#     fall back to a default language and quietly compare the wrong file.
#
#     It holds the language-INDEPENDENT artefacts byte-identically, on purpose:
#     `unknown` has to stay scoped to what it cannot answer, or one missing
#     declaration makes the whole service unmeasured and the word stops meaning
#     anything. An undeclared service still has a `mise.toml`.
mksvc undeclared-svc -

# 14b. THE DECLARED-IN-A-STRING CASE, and it is not hypothetical: the real
#      `docs` repository carries an `echo "    uses: cafaye/kit/...
#      @master"` inside a `run:` block whose entire purpose is to print the
#      documented string to a reader, and a `grep` pattern naming the same
#      prefix. A reporter that searches for the substring rather than anchoring
#      on `uses:` at the start of a line calls that a CALL, and reports a
#      service as pinned at a ref it never pinned — from a line that is a
#      quoted echo argument.
mksvc docs-svc go
mkdir -p "$TPL/docs-svc/.github/workflows"
cat >"$TPL/docs-svc/.github/workflows/ci.yml" <<'YML'
---
name: ci
on: [push]
jobs:
  docs:
    runs-on: ubuntu-latest
    steps:
      - run: |
          set -euo pipefail
          echo "    uses: cafaye/kit/.github/workflows/ci.reusable.yml@master" >&2
          if grep -Eq '^[[:space:]]*uses:[[:space:]]*cafaye/kit/' "$workflow"; then
            echo "documented string only" >&2
          fi
YML
# No real call. So this service has no caller, and ci.reusable.yml is `absent`.
# A substring reporter reads the echo and grades it `current`.
adopt undeclared-svc templates/mise.toml mise.toml
adopt undeclared-svc templates/AGENTS.md AGENTS.md

# 15. SIMILAR BUT NOT IDENTICAL. One byte different from kit's, and a symlink
#     to a real copy. Both are the "looks like kit's" cases requirement 3 names:
#     a reporter that graded by resemblance, or by a hash match found anywhere
#     in the tree rather than at the declared path, would call both `current`.
mksvc similar-svc python
adopt similar-svc templates/mise.toml mise.toml
printf 'x' >>"$TPL/similar-svc/mise.toml"
mkdir -p "$TPL/similar-svc/link-target"
cp "$TPL/kit/templates/AGENTS.md" "$TPL/similar-svc/link-target/AGENTS.md"
ln -sf link-target/AGENTS.md "$TPL/similar-svc/AGENTS.md"

# 16. FULLY PINNED. A second `go` service that adopted everything and then made
#     exactly one deliberate, recorded divergence. It exists for ONE reason: a
#     `--fail-on-unpinned` that can never be green is a constant `exit 1`, and
#     case 22 would pass against one. The green half is what stops the flag
#     being red on everything, which is the other way a staleness gate rots.
mksvc pinned-svc go
adopt pinned-svc templates/mise.toml mise.toml
adopt pinned-svc templates/AGENTS.md AGENTS.md
adopt pinned-svc templates/bin-prime/go.sh bin/prime
adopt pinned-svc templates/bin/dev.sh bin/dev
adopt pinned-svc docker/Dockerfile.go docker/Dockerfile
adopt pinned-svc lint/yamllint.yml .yamllint.yml
adopt pinned-svc lint/golangci.yml .golangci.yml
adopt pinned-svc lint/hadolint.yaml .hadolint.yaml
cp -R "$TPL/kit/templates/compose/." "$TPL/pinned-svc/"
# The anchor is the placeholder the template actually carries, not a comment:
# `<service-name>` is the slot the adopter is REQUIRED to fill, so changing it
# is the smallest edit that makes a copy legitimately its own. A sed that matched
# nothing would silently leave a byte-identical file and this fixture would stop
# testing what it claims to — the same trap `edit` exists to catch in self_test.
sed 's/^# AGENTS.md — <service-name>.*$/# AGENTS.md — pinned-svc, the one that diverges/' \
  "$TPL/kit/templates/AGENTS.md" >"$TPL/pinned-svc/AGENTS.md"
if cmp -s "$TPL/pinned-svc/AGENTS.md" "$TPL/kit/templates/AGENTS.md"; then
  echo "FAIL staleness_test: the pinned-svc mutation did not change a byte" >&2
  failures=$((failures + 1))
fi

# A fixture allowlist. The real one is copied and extended, so the fixture is
# held to the same four hygiene rules kit's own gate enforces.
#
# The real file's entries name REAL fleet repositories, which are not in this
# fixture fleet — so copying it wholesale would make every one of them a dead
# pin and the ledger would be entirely dead entries. Its HEADER is what the copy
# exercises, so the header is kept and the entries are not.
cp "$ALLOWLIST" "$TPL/real-allowlist" 2>/dev/null || : >"$TPL/real-allowlist"
grep -vE '^(diverged|absent) ' "$TPL/real-allowlist" >"$TPL/parity-allowlist"
#
# The fixture ledger pins a strict SUBSET of the fleet's findings, on purpose.
# A fixture that pinned everything would make `--fail-on-unpinned` green and
# there would be nothing left for the red proofs to be red about.
cat >>"$TPL/parity-allowlist" <<'ENTRY'
diverged diverged-svc mise.toml reason="a service raises the placeholder pins to the versions it deploys" owner=platform since=2026-09-30 until=2026-12-31
diverged diverged-svc AGENTS.md reason="this service's AGENTS.md names its neighbours, so it is its own file" owner=diverged-svc since=2026-09-30 until=2026-12-31
diverged diverged-svc compose reason="the stack was replaced with this service's own dependency set" owner=diverged-svc since=2026-09-30 until=2026-12-31
diverged diverged-svc ci.reusable.yml reason="this caller pins kit at its own branch while it waits to move to master" owner=diverged-svc since=2026-09-30 until=2026-12-31
absent absent-svc bin/dev reason="this service drives compose directly; bin/dev is not adopted and never was" owner=absent-svc since=2026-09-30 until=2026-12-31
absent absent-svc compose reason="this service runs postgres and nats only; the observability profile was never adopted" owner=absent-svc since=2026-09-30 until=2026-12-31
ENTRY

# A ledger that covers `pinned-svc` completely: it adopted everything, so the
# only cell that is not `current` is the one divergence it records.
cat >"$TPL/pinned-only" <<'ENTRY'
diverged pinned-svc AGENTS.md reason="this service's AGENTS.md names its neighbours, so it is its own file" owner=pinned-svc since=2026-09-30 until=2026-12-31
ENTRY

# The default `--table` is the real `tests/artifacts.json`, deliberately: a
# fixture that passed its own copy would prove the reporter reads whatever
# table it is handed, which is the weaker claim. The table's OWN correctness —
# that every source it names is a file kit ships — is case 28.
tpl_run() {
  OUT=""
  EC=0
  OUT=$("$PY" "$STALE" --repos-dir "$TPL" --scope templates \
    --allowlist "$TPL/parity-allowlist" "$@" 2>&1) || EC=$?
}

# --- THE FIXTURE MUST MEASURE WHAT THE CASES THINK IT MEASURES ---------------
#
# Observed, not hypothesised. On a machine at load average 160 this suite
# failed `an absent artefact is a counted finding, not silence` while passing
# the other 25, and the self_test control went red with it. The reporter had
# measured 8 repositories / 96 cells where the fixture has 9 / 108 — one
# service, twelve cells, silently not counted. The case failed on a row that
# was not in the table, and its failure text named the reporter, which is the
# one thing it must never do: the reporter was reading a smaller fleet, not
# misreading a full one.
#
# The reporter counts a repository by its `.git` (`isRepo` in staleness.py), so
# the obvious suspect is a service directory that exists without one. I could
# not confirm that, because the run's log was lost before I could read it, and
# this script runs `set -euo pipefail`, which means a failed `git init` would
# have aborted the suite rather than skipped a repository silently. So the
# diagnosis is open and the fix deliberately does not depend on it: assert the
# DISCREPANCY itself. If the number of fixture repositories is not the number
# the reporter counted, this harness is measuring something other than what its
# cases assert on, and that is a harness failure to be named as one — which is
# the fail-closed rule the reporter inherits, applied to the reporter's own
# test instead of assumed below it.
_fixture_expected="current-svc diverged-svc absent-svc halfstack-svc undeclared-svc docs-svc similar-svc pinned-svc"
# Visibility is read from `--json`, not the printed table, and the distinction is
# load-bearing: the table OMITS `current` cells on purpose, so a service that
# adopted everything has no row in it at all. Asserting on the table would call
# a fully-adopted fixture broken. The JSON carries every cell, so it answers
# "was this service measured" without depending on what the report chooses to
# print.
# "COULD NOT BE MEASURED" IS A VERDICT, AND IT HAS A SPELLING.
#
# This harness runs the reporter ITSELF, in a command substitution, and parses
# what came back with `json.loads` — so a reporter that failed, printed a
# traceback, or wrote nothing left `json.loads("")` to raise
# JSONDecodeError, and a raise inside `$( … )` under `set -euo pipefail` takes
# the whole suite down with it. The suite died with a traceback where a reader
# needed a sentence, which is the opposite of what every other case here does
# and the reason REPORT-kit-20's §7 flagged it.
#
# So the child never raises. It answers in exactly one shape: either the list of
# services the fixture lost, or the literal word `UNMEASURABLE:` followed by why
# — and the shell turns the second into a named FAIL with prose, beside the
# FAIL it already raises for a fixture that lost a service. It is a FAIL and not
# a SKIP for the reason its sibling is a FAIL: this is not a claim about the
# ENVIRONMENT (nothing here is missing a toolchain), it is a harness that
# measured something other than what its cases assert on, and a harness in that
# state has proved nothing. A SKIP would be the worse answer precisely because it
# is the one a reader has learned to ignore.
#
# The three things that are checked, and why each is a separate exit:
#   returncode — a reporter that failed has no output to parse, and reading past
#     a failure is how a traceback gets mistaken for a result.
#   JSON       — `JSONDecodeError` subclasses `ValueError`, so one `except`
#     catches a truncated document and a non-JSON one alike.
#   `cells`    — a well-formed document with no `cells` key, or with one that is
#     not a list, is the fail-closed case this repository argues for everywhere
#     else: the cheap answer would be to treat it as "measured nothing", and
#     that would report a broken reporter as a clean fleet.
_fixture_gone=$(
  "$PY" - "$TPL" "$STALE" "$_fixture_expected" <<'PY'
import json, os, subprocess, sys

tpl, stale = sys.argv[1], sys.argv[2]
expected = sys.argv[3].split()
out = subprocess.run(
    [sys.executable, stale, "--repos-dir", tpl, "--scope", "templates",
     "--allowlist", os.path.join(tpl, "parity-allowlist"), "--json"],
    capture_output=True, text=True)
if out.returncode != 0:
    first = (out.stderr or out.stdout or "").strip().splitlines()
    print(f"UNMEASURABLE: the reporter exited {out.returncode}"
          + (f": {first[0]}" if first else " with no output at all"))
    sys.exit(0)
try:
    payload = json.loads(out.stdout)
except ValueError as exc:
    first = out.stdout.strip().splitlines()
    print(f"UNMEASURABLE: the reporter's stdout was not JSON ({exc})"
          + (f"; it began {first[0][:80]!r}" if first else "; it was empty"))
    sys.exit(0)
cells = payload.get("cells") if isinstance(payload, dict) else None
if not isinstance(cells, list):
    print("UNMEASURABLE: the reporter's JSON carries no `cells` list, so no cell "
          "could be counted. Treated as unmeasured rather than as a clean fleet.")
    sys.exit(0)
measured = {c["repo"] for c in cells}
print(" ".join(s for s in expected if s not in measured))
PY
)
case "$_fixture_gone" in
  UNMEASURABLE:*)
    printf 'FAIL staleness_test: the fixture could not be MEASURED, so this is NOT a reporter result\n'
    printf '       %s\n' "${_fixture_gone#UNMEASURABLE: }"
    printf '       The harness above parses the reporter with json.loads and did not\n'
    printf '       guard it, so a reporter that failed, traced back, or printed\n'
    printf '       nothing left json.loads("") to raise inside a command substitution\n'
    printf '       under set -euo pipefail -- which killed the suite with a traceback\n'
    printf '       where a reader needed a sentence. Every other case in this file\n'
    printf '       names its own failure; this one now does too.\n'
    printf '       fixture: %s\n' "$TPL"
    tpl_run
    printf '%s\n' "$OUT" | sed 's/^/       /'
    exit 1
    ;;
esac
if [ -n "$_fixture_gone" ]; then
  printf 'FAIL staleness_test: the FIXTURE lost a service the cases assert on, so this is NOT a reporter result\n'
  printf '       the reporter measured no cell for:%s\n' "$_fixture_gone"
  printf '       A case reading a row the reporter never emitted fails for a reason\n'
  printf '       that has nothing to do with the reporter. Observed once at load\n'
  printf '       average 160: 8 repos / 96 cells where the fixture has 9 / 108.\n'
  printf '       fixture: %s\n' "$TPL"
  tpl_run
  printf '%s\n' "$OUT" | sed 's/^/       /'
  exit 1
fi

printf -- '\n-- staleness_test: the templates half tells current / diverged / absent apart\n'

# 17. THE CONTROL. The three states appear, spelled, and never collapse into one
#     another. A reporter that says `current` for a file that is not there is a
#     reporter that makes a fleet look clean by looking away.
#
#     `current` rows are omitted from the TABLE on purpose — sixty findings are
#     what a reader should be looking at, not a hundred and eight cells — so
#     this asserts `current` on the JSON, which has every cell. Asserting it on
#     the table is how a test ends up demanding a design it does not want.
tpl_run
EC=0
OUT_JSON=$("$PY" "$STALE" --repos-dir "$TPL" --scope templates \
  --allowlist "$TPL/parity-allowlist" --json 2>&1) || EC=$?
if [ "$EC" -eq 0 ] \
    && grep -qE '^diverged-svc +mise\.toml +diverged ' <<<"$OUT" \
    && grep -qE '^absent-svc +bin/dev +absent ' <<<"$OUT" \
    && "$PY" - "$OUT_JSON" <<'PY'
import json, sys

cells = {(r["repo"], r["artefact"]): r["state"] for r in json.loads(sys.argv[1])["cells"]}
# A service that adopted everything has a `current` cell AND has none of its
# rows in the table. Both are true at once and neither is a contradiction.
assert cells[("current-svc", "mise.toml")] == "current", cells
assert cells[("current-svc", "compose")] == "current", cells
assert cells[("diverged-svc", "mise.toml")] == "diverged", cells
assert cells[("absent-svc", "bin/dev")] == "absent", cells
PY
then
  printf 'PASS staleness_test: current / diverged / absent are told apart\n'
  passes=$((passes + 1))
else
  printf 'FAIL staleness_test: the templates state table is wrong (exit %s)\n' "$EC"
  printf '%s\n' "$OUT" | sed 's/^/       /'
  failures=$((failures + 1))
fi

# 18. AN ABSENCE IS A ROW, not a gap. `absent` is a word in the table and a
#     number in the summary; the reporter used to have no way to say it, and
#     the failure it enables is silence about the commonest state there is.
#
#     The half-adopted stack is here for the harder half of the same claim: a
#     service holding four of the twelve files, one of them its own. That is
#     `diverged`, and the note has to say which shape it is — because a
#     member-by-member report would call it four successes.
#
#     And it has to say what it MEASURED. An earlier version of the note ended
#     "a stack missing members does not start", which is a claim the reporter
#     cannot support: it compares bytes, and a service whose compose file mounts
#     none of kit's stack files is a REPLACEMENT, not a broken copy. The real
#     fleet is exactly that case — `docker compose config` is green on five of its
#     six compose files — so the sentence was wrong about the fleet this reporter
#     is pointed at, which is the only kind of wrong worth fixing.
if grep -qE '[0-9]+ absent' <<<"$OUT" \
    && grep -qE '^absent-svc +compose +absent ' <<<"$OUT" \
    && grep -qE '^halfstack-svc +compose +diverged .*partially adopted' <<<"$OUT"; then
  printf 'PASS staleness_test: an absent artefact is a counted finding, not silence\n'
  passes=$((passes + 1))
else
  printf 'FAIL staleness_test: the summary does not count absences'
  printf '%s\n' "$OUT" | sed 's/^/       /'
  failures=$((failures + 1))
fi

# 18. A DIVERGED COPY IS REPORTED WITH THE PIN THAT EXPLAINS IT, and a copy with
#     no pin says so in those words. "report the diff, with the pin that
#     explains it" — the reason, the owner and the expiry, not a bare state.
if grep -qE '^diverged-svc +mise\.toml +diverged +[^ ]* .*a service raises the placeholder pins' <<<"$OUT" \
    && grep -qE 'unpinned' <<<"$OUT"; then
  printf 'PASS staleness_test: a divergence carries its pin, and a missing pin is named\n'
  passes=$((passes + 1))
else
  printf 'FAIL staleness_test: a divergence is not reported with the pin that explains it\n'
  printf '%s\n' "$OUT" | sed 's/^/       /'
  failures=$((failures + 1))
fi

# 19. NEVER INFER FROM CONTENT, half one: a file that differs from kit's by ONE
#     BYTE is `diverged` and needs a pin. A reporter that graded resemblance —
#     99.9% is close enough — has made "looks like kit's" into "is kit's", and
#     that is the one inference this must never make.
if grep -qE '^similar-svc +mise\.toml +diverged ' <<<"$OUT"; then
  printf 'PASS staleness_test: a one-byte difference is diverged, never current\n'
  passes=$((passes + 1))
else
  printf 'FAIL staleness_test: a near-identical copy was graded current'
  printf '%s\n' "$OUT" | sed 's/^/       /'
  failures=$((failures + 1))
fi

# 20. NEVER INFER FROM CONTENT, half two: a SYMLINK at the declared path, whose
#     target is byte-identical, is `unknown` and not `current`. The bytes are
#     right today and the arrangement is a bet that the target never moves; a
#     reporter that hashed whatever it found would call this a copy and it is
#     not one. It is also the shape a service adopts by accident.
if grep -qE '^similar-svc +AGENTS\.md +unknown ' <<<"$OUT"; then
  printf 'PASS staleness_test: a symlink to an identical file is not a copy\n'
  passes=$((passes + 1))
else
  printf 'FAIL staleness_test: a symlink was graded as a byte-identical copy'
  printf '%s\n' "$OUT" | sed 's/^/       /'
  failures=$((failures + 1))
fi

# 21. AN UNDECLARED LANGUAGE IS `unknown`, never a pass. The alternative is to
#     guess a language, compare the wrong file, and report the guess — which is
#     the fail-open direction the classifier is forbidden from taking, and this
#     reporter inherits the rule.
#
#     `current` rows are omitted from the table, so the second half of this
#     assertion is on the JSON: an undeclared service still has a `mise.toml`
#     and `AGENTS.md`, and both are byte-identical here. `unknown` has to stay
#     scoped to what it genuinely cannot answer, or one missing declaration
#     makes the whole service unmeasured and the word stops meaning anything.
EC=0
OUT_JSON=$("$PY" "$STALE" --repos-dir "$TPL" --scope templates \
  --allowlist "$TPL/parity-allowlist" --json 2>&1) || EC=$?
if [ "$EC" -eq 0 ] \
    && grep -qE '^undeclared-svc +bin/prime +unknown ' <<<"$OUT" \
    && "$PY" - "$OUT_JSON" <<'PY'
import json, sys

cells = {(r["repo"], r["artefact"]): r["state"] for r in json.loads(sys.argv[1])["cells"]}
assert cells[("undeclared-svc", "bin/prime")] == "unknown", cells
assert cells[("undeclared-svc", "docker/Dockerfile")] == "unknown", cells
assert cells[("undeclared-svc", "AGENTS.md")] == "current", cells
assert cells[("undeclared-svc", "mise.toml")] == "current", cells
# A language-keyed artefact for a language the service is not is `n/a`, NOT
# `unknown`. `pinned-svc` is a `go` service: it has no rubocop config because it
# is not a Ruby service, and calling that unmeasurable would put three
# permanent, unfixable findings on every service in the fleet.
assert cells[("pinned-svc", "lint/rubocop.yml")] == "n/a", cells
assert cells[("pinned-svc", "lint/eslint.config.mjs")] == "n/a", cells
assert cells[("current-svc", "lint/golangci.yml")] == "current", cells
PY
then
  printf 'PASS staleness_test: undeclared is unknown, and not-applicable is n/a\n'
  passes=$((passes + 1))
else
  printf 'FAIL staleness_test: undeclared language resolved by guessing, or n/a conflated with unknown\n'
  printf '%s\n' "$OUT" | sed 's/^/       /'
  failures=$((failures + 1))
fi

# 22. THE RED PROOF, half one: --fail-on-unpinned is RED on an unpinned cell.
#     `absent-svc/AGENTS.md` is the cell this is really about — kit ships it and
#     the service holds nothing, which is the state nothing in the tree catches.
#     So the assertion names that cell rather than the flag, because "the flag
#     is red" is a weak claim when forty unpinned cells could each have made it
#     so, and the one that matters is the one this proves.
tpl_run --fail-on-unpinned
if [ "$EC" -eq 1 ] \
    && grep -q 'FAIL parity: the fleet' <<<"$OUT" \
    && grep -qE 'FAIL parity: absent-svc/AGENTS\.md is an unpinned absence' <<<"$OUT"; then
  printf 'PASS staleness_test: --fail-on-unpinned is RED, naming the unpinned absence\n'
  passes=$((passes + 1))
else
  printf 'FAIL staleness_test: an unpinned absence passed (exit %s)\n' "$EC"
  printf '%s\n' "$OUT" | sed 's/^/       /'
  failures=$((failures + 1))
fi

# 23. THE RED PROOF, half two: the same flag is GREEN when every non-current cell
#     of the named repository is pinned. Without this the flag could be a
#     constant `exit 1` and case 22 would still pass — which is the failure mode
#     of a gate nobody ever sees pass, and the same reason the core half has
#     two halves.
#
#     `pinned-svc` adopted every artefact kit ships for a `go` service and then
#     diverged on exactly one, with a reason. There is nothing left to find.
EC=0
OUT=$("$PY" "$STALE" --repos-dir "$TPL" --scope templates \
  --allowlist "$TPL/pinned-only" --repo pinned-svc --fail-on-unpinned 2>&1) || EC=$?
if [ "$EC" -eq 0 ]; then
  printf 'PASS staleness_test: --fail-on-unpinned is GREEN on a fully pinned service\n'
  passes=$((passes + 1))
else
  printf 'FAIL staleness_test: --fail-on-unpinned is red on a fully pinned service (exit %s)\n' "$EC"
  printf '%s\n' "$OUT" | sed 's/^/       /'
  failures=$((failures + 1))
fi

# 24. THE ESLINT DIRECTION: a pin that matches NOTHING is a failure. Modelled on
#     `reportUnusedDisableDirectives`, which reports a disable comment that no
#     longer suppresses anything. Here the entry is well-formed in every other
#     respect — reason, owner, since, until, not a duplicate — and it names a
#     cell that is byte-identical to kit, so it excuses nothing. That is the
#     only way to catch it: a shape-only check passes, and a ledger that cannot
#     notice its own dead entries is a ledger that within two quarters contains
#     the whole fleet.
#
# The three shapes, which are three DIFFERENT failures and a reporter that
# merged any two of them would be reporting the wrong thing:
#
#   a cell that is current        the entry excuses nothing
#   a cell that does not exist   the entry is for an artefact kit does not ship
#   a repository that is absent  the entry names a repository that is not there
#
# The fourth shape, and the one that is EASY to get wrong, is a verb that
# disagrees with what was measured — an entry saying `absent` for a file that
# is present and different. It is not a dead entry and not a correct one; it is
# a record of a decision that does not describe the fleet, which is worse than
# either because it looks maintained. The reporter checks the verb against the
# measurement, so this cannot pass by being well-formed.
#
# And the fourth shape, which is NOT a failure and which the first version of
# this reporter got wrong: a pin for a repository this run did not measure. A
# `--repo X` run is a SCOPED run, and the fleet-wide ledger is full of entries
# for repositories it never looked at — the first version reported all eighty
# of them as dead entries, which is a reporter crying wolf on the one input
# that cannot possibly be wrong. `pinned-svc` is the service a scoped run does
# not measure and its pin must survive the run silently.
cat >"$TPL/dead-pins" <<ENTRY
diverged current-svc AGENTS.md reason="this copy is byte-identical to kit, so this entry is dead weight" owner=kit since=2026-09-30 until=2026-12-31
diverged current-svc lint/hadolint.yaml reason="kit ships no such artefact id, so this entry can never match" owner=kit since=2026-09-30 until=2026-12-31
diverged not-a-real-service mise.toml reason="and so is one naming a repository that does not exist" owner=kit since=2026-09-30 until=2026-12-31
diverged pinned-svc AGENTS.md reason="a real entry for a service this scoped run does not measure, which is not a failure" owner=kit since=2026-09-30 until=2026-12-31
ENTRY
tpl_run --repo current-svc --allowlist "$TPL/dead-pins" --fail-on-unpinned
dead_count=$(printf '%s\n' "$OUT" | grep -c 'matches NOTHING')
if [ "$EC" -eq 1 ] \
    && [ "$dead_count" -eq 3 ] \
    && ! grep -q 'pinned-svc/AGENTS.md matches NOTHING' <<<"$OUT"; then
  printf 'PASS staleness_test: three dead pins fail; a pin for an unmeasured repo does not\n'
  passes=$((passes + 1))
else
  printf 'FAIL staleness_test: %s dead pin(s) reported (want 3), and pinned-svc must NOT be one (exit %s)\n' \
    "$dead_count" "$EC"
  printf '%s\n' "$OUT" | sed 's/^/       /'
  failures=$((failures + 1))
fi

# 25. A `uses:` STRING IS NOT A CALL. `docs-svc` is the real `docs` repository's
#     shape: an `echo` of the documented string inside a `run:` block, plus a
#     `grep` for it. A reporter that searched for the substring would report this
#     service as calling kit at `@master` and grade the cell `current` — a
#     `current` backed by a quoted echo argument, which is the same failure the
#     packet names: something that looks like kit's, called kit's.
EC=0
OUT_JSON=$("$PY" "$STALE" --repos-dir "$TPL" --scope templates \
  --allowlist "$TPL/parity-allowlist" --json 2>&1) || EC=$?
if [ "$EC" -eq 0 ] && "$PY" - "$OUT_JSON" <<'PY'
import json, sys

payload = json.loads(sys.argv[1])
cells = {(r["repo"], r["artefact"]): r for r in payload["cells"]}
docs = cells[("docs-svc", "ci.reusable.yml")]
assert docs["state"] == "absent", docs
assert "no caller" in docs["note"], docs
PY
then
  printf 'PASS staleness_test: a uses: string inside a run: block is not a call\n'
  passes=$((passes + 1))
else
  printf 'FAIL staleness_test: a quoted uses: string was read as a real call'
  failures=$((failures + 1))
fi

# 26. A DECLARED ALTERNATIVE PATH IS NOT AN ABSENCE. Six of the nine real
#     services keep their Dockerfile at the repository root rather than at
#     `docker/Dockerfile` where kit's README says, and a reporter that calls
#     that `absent` is crying wolf over a documented, working placement — which
#     is how a report gets muted. Resolution is by existence among a DECLARED
#     list, and the file is graded on its bytes.
mksvc rootplaced-svc go
adopt rootplaced-svc docker/Dockerfile.go Dockerfile
EC=0
OUT_JSON=$("$PY" "$STALE" --repos-dir "$TPL" --scope templates \
  --allowlist "$TPL/parity-allowlist" --json 2>&1) || EC=$?
if [ "$EC" -eq 0 ] && "$PY" - "$OUT_JSON" <<'PY'
import json, sys

cells = {(r["repo"], r["artefact"]): r for r in json.loads(sys.argv[1])["cells"]}
cell = cells[("rootplaced-svc", "docker/Dockerfile")]
assert cell["state"] == "current", cell
assert cell["found_at"] == "Dockerfile", cell
# And the documented path is still honoured when it is the one in use.
assert cells[("current-svc", "docker/Dockerfile")]["found_at"] == "docker/Dockerfile"
PY
then
  printf 'PASS staleness_test: a declared alternative path is graded, not called absent\n'
  passes=$((passes + 1))
else
  printf 'FAIL staleness_test: a Dockerfile at the repo root was called absent'
  failures=$((failures + 1))
fi

# 27. THE TWO SCOPES DO NOT INTERFERE. The core half measures a pin and the
#     templates half measures a file, and the word `absent` belongs only to the
#     second. A reporter whose new scope rewrote its old one would invalidate
#     the measured core numbers kit's README publishes, which is the cheapest
#     way to lose the credibility this reporter exists to have.
run
if [ "$EC" -eq 0 ] && ! grep -qE 'absent|diverged' <<<"$OUT"; then
  printf 'PASS staleness_test: the core scope is unchanged by the templates scope\n'
  passes=$((passes + 1))
else
  printf 'FAIL staleness_test: the core scope leaked artefact vocabulary'
  printf '%s\n' "$OUT" | sed 's/^/       /'
  failures=$((failures + 1))
fi

# 26. --json agrees with the templates table, cell for cell, and carries the pin.
#     The scheduled artefact is the JSON; a table that disagrees with it is two
#     reporters, and the one nobody reads is the one that is wrong.
tpl_run --json
if [ "$EC" -eq 0 ] && "$PY" - "$OUT" <<'PY'
import json, sys

payload = json.loads(sys.argv[1])
cells = {(r["repo"], r["artefact"]): r for r in payload["cells"]}
assert payload["kit_head"], "no kit head"
assert cells[("current-svc", "mise.toml")]["state"] == "current", cells[("current-svc", "mise.toml")]
assert cells[("diverged-svc", "mise.toml")]["state"] == "diverged"
assert cells[("diverged-svc", "mise.toml")]["pin"], "a diverged cell must carry its pin"
assert cells[("diverged-svc", "mise.toml")]["pin"]["reason"], "a pin with no reason is not a pin"
assert cells[("absent-svc", "AGENTS.md")]["state"] == "absent"
assert cells[("absent-svc", "AGENTS.md")]["pin"] is None, "an unpinned absence must not invent a pin"
assert cells[("similar-svc", "mise.toml")]["state"] == "diverged"
assert cells[("similar-svc", "AGENTS.md")]["state"] == "unknown"
assert cells[("undeclared-svc", "bin/prime")]["state"] == "unknown"
PY
then
  printf 'PASS staleness_test: --json agrees with the templates table\n'
  passes=$((passes + 1))
else
  printf 'FAIL staleness_test: --json disagrees with the templates table\n'
  printf '%s\n' "$OUT" | sed 's/^/       /'
  failures=$((failures + 1))
fi

# 27. A MALFORMED TABLE IS A FINDING, NEVER AN EMPTY REPORT. An artefact table
#     naming a file kit does not ship would make every service in the fleet
#     report `absent` forever, which reads as a migration backlog and is
#     actually a typo. Fails closed, like the classifier.
cp "$TABLE" "$TPL/broken-table.json"
"$PY" - "$TPL/broken-table.json" <<'PY'
import json, sys

path = sys.argv[1]
table = json.load(open(path, encoding="utf-8"))
for artefact in table["artefacts"]:
    if artefact["id"] == "bin/dev":
        artefact["source"] = "templates/bin/dev-deleted.sh"
json.dump(table, open(path, "w", encoding="utf-8"), indent=2)
PY
EC=0
OUT=$("$PY" "$STALE" --repos-dir "$TPL" --scope templates --table "$TPL/broken-table.json" 2>&1) || EC=$?
if [ "$EC" -ne 0 ] && grep -qi 'does not ship' <<<"$OUT"; then
  printf 'PASS staleness_test: a table naming a file kit does not ship is refused\n'
  passes=$((passes + 1))
else
  printf 'FAIL staleness_test: a broken artefact table was accepted silently (exit %s)\n' "$EC"
  printf '%s\n' "$OUT" | sed 's/^/       /'
  failures=$((failures + 1))
fi

printf '\n'
if [ "$failures" -ne 0 ]; then
  echo "FAIL: staleness_test — $failures case(s) failed, $passes passed."
  exit 1
fi
echo "PASS: staleness_test — $passes case(s), including the red proof."
