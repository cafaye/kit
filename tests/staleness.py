#!/usr/bin/env python3
"""Report how far each vendored copy of `core` has fallen behind.

    staleness.py --repos-dir ../ --manifest core/fleet.yml
    staleness.py --repos-dir ../ --repo muse --repo caf
    staleness.py --repos-dir ../ --github-org cafaye

WHAT IT IS FOR

  Every consuming repository records which commit of `core` it vendored. That
  record is a claim, and a claim nobody checks is a rumour — the same argument
  `cafaye-ts/specs/index.json` already makes in its own `about` field. This
  script reads those records, resolves where `core`'s default branch is *now*,
  and prints the distance between the two.

  It exists because the fleet's staleness is otherwise visible only as a red
  build in whichever repository happened to be built, which is the reporting
  half of a problem that needs the fixing half. vendir + Renovate is the fixing
  half (see `core/README.md`); this is how you see the backlog before a PR
  exists to fix it.

THE HARD PART, STATED HONESTLY

  Not the comparison — a sha and a sha is a subtraction. The hard part is
  *discovery*: knowing which repositories consume core, and where each one
  records its pin. Three sources, in the order they are tried:

    1. `--repos-dir`  — every immediate subdirectory that looks like a checkout.
       Works offline, works with a partial clone, and is what you use in a test.
    2. `--repo`       — named repositories, resolved under `--repos-dir`.
    3. `--github-org` — enumerate an organisation through the GitHub API.

  A repository that records its pin in a form this script does not recognise is
  reported as `unknown`, never as `current`. That distinction is the whole
  difference between this being a staleness report and this being a report that
  says everything is fine.

THE PIN, AND WHY THE OLD ONE STILL MATTERS

  A repository can record its core pin two ways, and during the migration it is
  usually both at once:

    * `vendir.lock.yml` — a resolved `sha` under a git content entry. This is
      what vendir writes and what Renovate updates.
    * a `CORE_REF` in `.github/workflows/*.yml` — a full sha in an env block.
      This is the hand-bumped form, and it is still what three repositories use
      today. A migration that only learned to read lockfiles would report all
      three as `unknown` on the day it landed, which is the worst possible moment
      to stop being able to see them.

EXIT STATUS

  0  the table was produced
  1  a repository named on the command line could not be read
  2  bad invocation

  Deliberately NOT non-zero for "something is stale". A scheduled report that
  exits 1 every week is a scheduled report that gets muted, and the whole reason
  this is an artifact rather than a blocking check is that a stale copy is
  legal — it is a copy that has not been bumped yet. What must be loud is
  *unreadable*, because an unreadable pin is a pin nobody is maintaining.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

SHA_RE = re.compile(r"^[0-9a-f]{40}$")

# The states a repository can be in. Ordered worst-last so a sort by this key
# puts the repositories that need attention first.
UNKNOWN = "unknown"
CURRENT = "current"
BEHIND = "behind"
UNDECLARED = "undeclared"

# Where a pin can hide, in preference order. Lockfile first: it is the form the
# migration moves toward, and a repository that has both is mid-migration and
# its two pins should agree (see `pins_disagree`).
LOCKFILE = "vendir.lock.yml"
WORKFLOW_GLOB = ".github/workflows"


def run_git(args: list[str], cwd: str) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            ["git", *args], cwd=cwd, capture_output=True, text=True, check=False
        )
    except OSError as exc:
        return 127, "", str(exc)
    return proc.returncode, proc.stdout, proc.stderr


def is_checkout(path: str) -> bool:
    return os.path.isdir(os.path.join(path, ".git")) or os.path.isfile(
        os.path.join(path, ".git")
    )


def is_worktree(path: str) -> bool:
    """True when `path` is a git WORKTREE rather than its own repository.

    A worktree's `.git` is a file containing `gitdir: <main>/.git/worktrees/<name>`
    and it shares the main repository's history and remotes. Treating one as a
    separate consumer counts the same pin twice, which inflates the denominator
    and — worse — makes a repository look like it holds two independent copies of
    core at two different ages, which is a story nobody should have to disprove.

    The cost of getting this wrong is invisible, which is why it is a named
    function rather than an `if` in the caller.
    """
    marker = os.path.join(path, ".git")
    if not os.path.isfile(marker):
        return False
    try:
        with open(marker, encoding="utf-8") as fh:
            return fh.read(6).strip() == "gitdir"
    except OSError:
        return False


def read_lockfile_sha(repo_dir: str) -> tuple[str | None, str | None]:
    """The `sha` of the first git content entry in a vendir lockfile.

    Returns (sha, ref) where ref is the tag or branch the lockfile names, or
    (None, None) when there is no lockfile or it has no git content.
    """
    path = os.path.join(repo_dir, LOCKFILE)
    if not os.path.isfile(path):
        return None, None
    with open(path, encoding="utf-8") as fh:
        body = fh.read()
    sha = re.search(r"^\s*sha:\s*([0-9a-f]{40})\s*$", body, re.MULTILINE)
    if not sha:
        return None, None
    tags = re.search(r"^\s*-\s*(v?\d+\.\d+\.\d+[^\s]*)\s*$", body, re.MULTILINE)
    return sha.group(1), (tags.group(1) if tags else None)


def read_core_ref(repo_dir: str) -> str | None:
    """A `CORE_REF: <sha>` in any workflow file.

    The hand-bumped form. Read as text rather than as YAML on purpose: it is a
    grep for one literal in a known shape, and a YAML round-trip here would add a
    parser dependency to a script whose entire virtue is that it cannot fail to
    start.
    """
    root = os.path.join(repo_dir, WORKFLOW_GLOB)
    if not os.path.isdir(root):
        return None
    for dirpath, _dirs, files in os.walk(root):
        for name in sorted(files):
            if not (name.endswith(".yml") or name.endswith(".yaml")):
                continue
            try:
                with open(os.path.join(dirpath, name), encoding="utf-8") as fh:
                    body = fh.read()
            except OSError:
                continue
            found = re.search(r"^\s*CORE_REF:\s*([0-9a-f]{40})\s*$", body, re.MULTILINE)
            if found:
                return found.group(1)
    return None


def pins_disagree(lock_sha: str | None, core_ref: str | None) -> bool:
    """A repository mid-migration whose two pins do not match.

    This is a real and reportable state, not a rounding error: the lockfile says
    the vendored bytes came from one commit and the workflow says the CI gate
    checks another, so the bytes under test and the bytes on disk are not the
    same bytes and the parity test is proving something narrower than it claims.
    """
    return bool(lock_sha and core_ref and lock_sha != core_ref)


def resolve_core_head(core_dir: str) -> str | None:
    """The sha the core checkout has locally, preferring the remote-tracking ref.

    `master` before `HEAD` on purpose: a repository that has been sitting on a
    branch for a week is reporting the wrong thing, and the thing being reported
    should be what the fleet would pull.
    """
    for ref in ("refs/remotes/origin/master", "refs/remotes/origin/main", "master", "HEAD"):
        code, out, _ = run_git(["rev-parse", ref], core_dir)
        sha = out.strip()
        if code == 0 and SHA_RE.match(sha):
            return sha
    return None


def commits_between(core_dir: str, older: str, newer: str) -> int | None:
    """How many commits `older` is behind `newer`, or None if unknown.

    `git rev-list --count older..newer`. An unknown count is None rather than 0,
    because "0" would claim the copies are identical, which is a different claim
    from "I could not tell".
    """
    code, out, _ = run_git(["rev-list", "--count", f"{older}..{newer}"], core_dir)
    if code != 0:
        return None
    try:
        return int(out.strip())
    except ValueError:
        return None


def classify_state(pin: str | None, behind: int | None) -> str:
    if pin is None:
        return UNDECLARED
    if behind is None:
        return UNKNOWN
    return CURRENT if behind == 0 else BEHIND


def discover_local(repos_dir: str, include_worktrees: bool = False) -> list[str]:
    """Immediate subdirectories of repos_dir that are their own git repository.

    `core` itself is excluded: it is the reference this report measures against,
    not a consumer of it, and a row saying "core is undeclared" would be a true
    sentence about a meaningless question.
    """
    found = []
    try:
        entries = sorted(os.listdir(repos_dir))
    except OSError as exc:
        raise SystemExit(f"staleness.py: cannot read {repos_dir}: {exc}")
    for entry in entries:
        if entry == "core":
            continue
        path = os.path.join(repos_dir, entry)
        if not os.path.isdir(path) or not is_checkout(path):
            continue
        if not include_worktrees and is_worktree(path):
            continue
        found.append(entry)
    return found


def discover_github_org(org: str, token: str | None) -> list[str]:
    """Every repository in a GitHub organisation.

    The token is read from the environment and never echoed, never logged, and
    never placed in a URL — a token in a URL is a token in a proxy log, and a
    token in this script's output is a token in a CI log. An unauthenticated
    request works for a public organisation and is what the cafaye fleet uses;
    the token exists for a private one.
    """
    url = f"https://api.github.com/orgs/{org}/repos?per_page=100&type=all"
    request = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as exc:
        raise SystemExit(f"staleness.py: GitHub API returned {exc.code} for org {org}")
    except urllib.error.URLError as exc:
        raise SystemExit(f"staleness.py: cannot reach the GitHub API: {exc.reason}")
    return sorted(repo["name"] for repo in payload)


def collect_row(name: str, repo_dir: str, core_dir: str, head: str) -> dict:
    lock_sha, ref = read_lockfile_sha(repo_dir)
    core_ref = read_core_ref(repo_dir)
    pin = lock_sha or core_ref
    behind = None
    if pin and head:
        if pin == head:
            # Pinned at exactly what core publishes right now: that is `current`,
            # and it is a DIFFERENT claim from "I could not measure". Reporting it
            # as `unknown` was a real bug this suite caught — and it is the
            # expensive direction to get wrong, because `unknown` is the state a
            # reader learns to ignore.
            behind = 0
        else:
            behind = commits_between(core_dir, pin, head)
    row = {
        "repo": name,
        "pin": pin,
        "pin_source": (
            LOCKFILE if lock_sha else ("CORE_REF" if core_ref else "none")
        ),
        "ref": ref,
        "state": classify_state(pin, behind),
        "behind": behind if behind is not None else 0,
        "behind_known": behind is not None,
        "disagrees": pins_disagree(lock_sha, core_ref),
    }
    return row


def render_table(rows: list[dict], head: str) -> str:
    order = {BEHIND: 0, UNKNOWN: 1, UNDECLARED: 2, CURRENT: 3}
    rows = sorted(rows, key=lambda r: (order.get(r["state"], 9), r["repo"]))
    name_w = max([len("repository")] + [len(r["repo"]) for r in rows])
    src_w = max([len("source")] + [len(r["pin_source"]) for r in rows])

    out = [f"core master: {head}", ""]
    header = (
        f"{'repository'.ljust(name_w)}  {'pin'.ljust(12)}  {'source'.ljust(src_w)}  "
        f"{'ref'.ljust(8)}  {'behind'.rjust(7)}  state"
    )
    out.append(header)
    out.append("-" * len(header))
    for row in rows:
        behind = str(row["behind"]) if row["behind_known"] else "?"
        pin = (row["pin"] or "-")[:12]
        flag = ""
        if row["disagrees"]:
            # A mid-migration disagreement is worth its own column's worth of
            # attention: both pins exist, and they name different commits.
            flag = "  PINS DISAGREE"
        out.append(
            f"{row['repo'].ljust(name_w)}  {pin.ljust(12)}  "
            f"{row['pin_source'].ljust(src_w)}  {(row['ref'] or '-')[:8].ljust(8)}  "
            f"{behind.rjust(7)}  {row['state']}{flag}"
        )
    behind_count = sum(1 for r in rows if r["state"] == BEHIND)
    unknown_count = sum(1 for r in rows if r["state"] in (UNKNOWN, UNDECLARED))
    out.append("")
    out.append(
        f"{len(rows)} repo(s): {behind_count} behind, {unknown_count} not measured, "
        f"{len(rows) - behind_count - unknown_count} current"
    )
    return "\n".join(out)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="staleness.py",
        description="Report how far each vendored copy of core has fallen behind.",
    )
    parser.add_argument("--repos-dir", required=True,
                        help="directory holding one checkout per cafaye repository")
    parser.add_argument("--core", default=None,
                        help="path to the core checkout (default: <repos-dir>/core)")
    parser.add_argument("--repo", action="append", default=[], metavar="NAME",
                        help="restrict to these repositories (repeatable)")
    parser.add_argument("--github-org", default=None, metavar="ORG",
                        help="discover repositories from this GitHub organisation "
                             "instead of listing --repos-dir")
    parser.add_argument("--fail-on-behind", action="store_true",
                        help="exit 1 when any repository is behind. Off by default, "
                             "because a stale copy is LEGAL — it is a copy that has "
                             "not been bumped yet — and a scheduled report that is red "
                             "every week is a report that gets muted. Turn this on in "
                             "a pull request, where a stale copy is the defect.")
    parser.add_argument("--include-worktrees", action="store_true",
                        help="count git worktrees as repositories. Off by default: "
                             "a worktree shares its parent repository's history, so "
                             "counting one reports one consumer as two.")
    parser.add_argument("--json", action="store_true", help="emit JSON")
    args = parser.parse_args(argv)

    core_dir = args.core or os.path.join(args.repos_dir, "core")
    if not os.path.isdir(core_dir):
        raise SystemExit(f"staleness.py: no core checkout at {core_dir}")
    head = resolve_core_head(core_dir)
    if head is None:
        raise SystemExit(
            f"staleness.py: cannot resolve core's published commit in {core_dir}. "
            f"A report that cannot say what `now` means would print a table of "
            f"agreements it did not check."
        )

    if args.repo:
        names = list(args.repo)
    elif args.github_org:
        token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
        names = discover_github_org(args.github_org, token)
    else:
        names = discover_local(args.repos_dir, args.include_worktrees)

    rows = []
    missing = []
    for name in names:
        repo_dir = os.path.join(args.repos_dir, name)
        if not os.path.isdir(repo_dir):
            missing.append(name)
            continue
        rows.append(collect_row(name, repo_dir, core_dir, head))

    if args.json:
        json.dump({"core_head": head, "rows": rows, "missing": missing},
                  sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    else:
        print(render_table(rows, head))
        if missing:
            print(f"\nnot found under {args.repos_dir}: {', '.join(sorted(missing))}")

    if missing:
        print(
            f"FAIL: {len(missing)} repository(ies) named on the command line could not "
            f"be read. A pin nobody can read is a pin nobody is maintaining.",
            file=sys.stderr,
        )
        return 1

    if args.fail_on_behind:
        behind_rows = [r for r in rows if r["state"] == BEHIND]
        if behind_rows:
            for row in behind_rows:
                print(
                    f"FAIL staleness: {row['repo']} is {row['behind']} commit(s) behind "
                    f"core master (pin {(row['pin'] or '')[:12]}, via {row['pin_source']}). "
                    f"Re-vendor, or record in the PR why this repository is pinned here."
                )
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
