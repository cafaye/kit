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
trap 'rm -rf "$WORK"' EXIT

FLEET="$WORK/fleet"
mkdir -p "$FLEET"

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
    && printf '%s\n' "$OUT" | grep -qE '^current-repo .* current$' \
    && printf '%s\n' "$OUT" | grep -qE '^behind-repo .* behind$' \
    && printf '%s\n' "$OUT" | grep -qE '^handbumped-repo .* behind$' \
    && printf '%s\n' "$OUT" | grep -qE '^undeclared-repo .* undeclared$'; then
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
if printf '%s\n' "$OUT" | grep -qE '^behind-repo .* +2 +behind$'; then
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
if printf '%s\n' "$OUT" | grep -qE '^handbumped-repo .* CORE_REF'; then
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
if printf '%s\n' "$OUT" | grep -q 'PINS DISAGREE'; then
  printf 'PASS staleness_test: two disagreeing pins are reported\n'
  passes=$((passes + 1))
else
  printf 'FAIL staleness_test: disagreeing pins were not reported\n'
  printf '%s\n' "$OUT" | sed 's/^/       /'
  failures=$((failures + 1))
fi

# 5. a lockfile's tag is read, so the table can say which release is vendored.
if printf '%s\n' "$OUT" | grep -qE '^current-repo .* v0\.3\.0'; then
  printf 'PASS staleness_test: the lockfile tag is reported\n'
  passes=$((passes + 1))
else
  printf 'FAIL staleness_test: the lockfile tag was not reported\n'
  failures=$((failures + 1))
fi

# 6. THE RED PROOF, half one: --fail-on-behind exits 1 on a stale copy.
run --fail-on-behind
if [ "$EC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q 'FAIL staleness:'; then
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
if [ "$EC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q 'could not be read'; then
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
if printf '%s\n' "$OUT" | grep -qE '^core +[^ ]+ +(none|vendir\.lock\.yml|CORE_REF) +'; then
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
  if printf '%s\n' "$OUT" | grep -q '^behind-worktree '; then
    printf 'FAIL staleness_test: a git worktree was counted as a second consumer\n'
    failures=$((failures + 1))
  else
    printf 'PASS staleness_test: a git worktree is not counted as a second consumer\n'
    passes=$((passes + 1))
  fi
  run --include-worktrees
  if printf '%s\n' "$OUT" | grep -q '^behind-worktree '; then
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

printf '\n'
if [ "$failures" -ne 0 ]; then
  echo "FAIL: staleness_test — $failures case(s) failed, $passes passed."
  exit 1
fi
echo "PASS: staleness_test — $passes case(s), including the red proof."
