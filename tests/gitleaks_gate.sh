#!/usr/bin/env bash
#
# kit's secret scan. ONE definition, used by two callers:
#
#   .github/workflows/ci.reusable.yml  the `secrets` job, in a service's CI
#   tests/validate.sh                  this repository's own gate
#
# They are the same script on purpose. A scanner whose CI invocation and whose
# local invocation have drifted is two scanners, and the one that goes red is
# whichever nobody runs.
#
#   bash tests/gitleaks_gate.sh [ROOT] [GITLEAKS]
#
# WHAT IT GUARANTEES
#   - FULL HISTORY, not the diff. A secret committed and deleted in the same PR
#     is still in the history and still on somebody's fork, and a diff scan is
#     blind to precisely the finding that matters most.
#   - --redact, always, not optionally. A CI log is a place secrets go to be
#     read. The scanner finding a secret must never be the reason the secret is
#     printed. Not configurable, and there is no flag to turn it off.
#   - the committed config, always, by an explicit path. gitleaks would also
#     auto-discover `.gitleaks.toml`; passing it means the config the scan used
#     is visible in the command line, and a missing file is an error rather
#     than a silent fall back to the default rules.
#   - no inline allowlist. gitleaks takes `-i`; this script never passes it, and
#     tests/validate.sh fails if a `.gitleaksignore` appears in the tree.
#
# OFFLINE
#   gitleaks is a static binary that reads a git repository and matches
#   regexes. It makes no network call, in either mode, ever. That is the
#   property that disqualified trufflehog for this job — it verifies live
#   credentials against the issuer's API, which for a fleet whose CI has network
#   access is the wrong behaviour for a scanner, not the right one. See
#   DECISIONS.md.
#
# WHY THE CALLER DECIDES WHAT A MISSING BINARY MEANS
#   A secret scanner that only warns is a report, so there must never be a
#   third outcome where a green run scanned nothing. That is the caller's rule
#   to enforce; this script's rule is that it cannot exit 0 without having
#   actually run gitleaks against the tree.

set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
GITLEAKS="${2:-gitleaks}"

# Anything the caller passed beyond the two positional arguments. Captured HERE,
# before the `set --` below rebuilds the argument list from scratch — which
# silently discarded them, so a caller asking for `--verbose` got a scan with
# neither verbose output nor an error. A swallowed argument is worse than a
# rejected one.
shift $(( $# > 2 ? 2 : $# ))
extra_flags=("$@")

# The config, resolved in two steps, and the second one is the one that matters.
#
#   1. $ROOT/.gitleaks.toml          the scanned tree's own config, if it has one
#   2. <this script's own>/../.gitleaks.toml   kit's, which always exists
#
# Step 2 is not a fallback for a missing file. This script runs in two places: in
# kit's own gate, where ROOT is kit, and in a SERVICE's CI, where it is called as
# `${GITHUB_ACTION_PATH}/tests/gitleaks_gate.sh "$GITHUB_WORKSPACE"` — kit's file,
# scanning somebody else's repository. In that second case the consumer's tree has
# no `.gitleaks.toml` unless it copied one, and resolving the config from ROOT
# meant the scan exited 1 with "config does not exist" and never ran at all.
#
# That failure is worth dwelling on: it exited NON-ZERO, so the job was red, so
# it looked like a working gate catching something. It caught nothing. A scanner
# that fails on its own configuration is a scanner that is not a scanner.
#
# A service that wants its own allowlist copies kit's .gitleaks.toml into its
# root and edits it; step 1 then picks it up and kit's own is not consulted.
script_dir="$(cd "$(dirname "$0")" && pwd)"
config="$ROOT/.gitleaks.toml"
if [ ! -f "$config" ]; then
  config="$script_dir/../.gitleaks.toml"
fi
if [ ! -f "$config" ]; then
  echo "gitleaks_gate: no .gitleaks.toml at $ROOT, and none beside this script." >&2
  echo "gitleaks_gate: without it the scan runs on gitleaks' defaults and the" >&2
  echo "gitleaks_gate: cafaye allowlist is silently absent. Restore the file." >&2
  exit 1
fi

# The flags, written once. Built into "$@" rather than an array because this
# gate is also run by whatever `bash` a slim container ships, and an empty-array
# expansion under `set -u` is an error in bash 3.2. The duplication a second
# literal would create is the thing worth avoiding here, not the array.
set -- --source "$ROOT" --config "$config" \
  --redact \
  --no-banner \
  --no-color \
  --exit-code 1

# A git repository gets a history scan. A throwaway copy — which is what
# tests/self_test.sh makes, twenty-odd times per gate run — is not one, and
# there `gitleaks detect` fails outright with "no git repository". So the copy
# is scanned as a directory instead, which is the closest offline equivalent:
# it still reads every byte in the tree, and it is the mode that finds the
# planted secret self_test's own breakage plants.
#
# The mode is decided by asking git, not by testing for a `.git` directory: a
# worktree's `.git` is a FILE, and that is not the distinction being made here.
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  # Spelled out rather than left to gitleaks' default, because "full history"
  # is a requirement and a default is not a requirement. `--all` is most of the
  # point: a secret that only ever existed on a branch is still a secret.
  set -- "$@" --log-opts '-p -U0 --full-history --all'
else
  set -- "$@" --no-git
fi

# A caller may add flags — the gate's own behaviour check adds `--verbose`, so
# it can name the rule that fired and prove that --redact holds in the output
# with the most to redact. A gate script that rejected extra arguments would
# force that check to reimplement the invocation, which is the drift this script
# exists to prevent.
#
# `${extra_flags[@]+...}` rather than `"${extra_flags[@]}"` because an EMPTY array
# under `set -u` is an error in bash 3.2, which is the `bash` a slim container
# ships. Two callers, one of which passes a flag and one of which does not, and
# the second must not die on the first's account.
exec "$GITLEAKS" detect "$@" ${extra_flags[@]+"${extra_flags[@]}"}
