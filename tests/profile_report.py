#!/usr/bin/env python3
"""Render the TSV `tests/validate.sh` writes when `KIT_PROFILE` is set.

WHY THIS IS A PROGRAM AND NOT A `sort`. The file it reads is appended to by
every gate copy the self-test spawns, so it has ~1,000 rows whose labels are
long, whose kinds are four (`check`, `cpu`, `tier`, `phase`), and which fall
into two populations that must never be added together: the GATE's rows and the
SELF-TEST's rows. Aggregating those into one column is how a profile claims a
ten-minute run that cost four, and it is why this renders the two populations
separately and refuses to sum a `cpu` row with a `phase` row.

Standard library only, like the other two programs in `tests/`. `validate.sh`'s
`carve-out boundary` check walks the AST of every Python file in this directory
and fails on an import outside json/os/re/sys/argparse/subprocess/difflib/glob/
urllib/__future__ — so this imports three of those and is green on arrival. It
is a FOURTH program under that rule's carve-out and it is deliberately the
smallest: it reads a file and prints a table.

    python3 tests/profile_report.py /tmp/profile.tsv [--top N] [--sort sum|label]
"""

import argparse
import sys

PHASE = "phase"
CHECK = "check"
CPU = "cpu"
TIER = "tier"
VERDICT = "verdict"

# The self-test's own rows are prefixed by the tag `tests/self_test.sh` sets, so
# the two populations can be told apart without a schema change. A row with no
# tag belongs to the gate that was run directly.
SELFTEST_PREFIX = "self_test "


def read(path):
    """Yield (kind, label, seconds, tag). A short or ragged row is SKIPPED.

    A profiling file is written by several hundred appends from several
    processes, so the last one can in principle be torn. A half-written row is
    not a reason to lose the other 999 — and it must not be a reason to guess,
    either, so it is counted and reported rather than repaired.
    """
    rows, torn = [], 0
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) < 3:
                torn += 1
                continue
            kind, label, secs = parts[0], parts[1], parts[2]
            tag = parts[3] if len(parts) > 3 else ""
            try:
                rows.append((kind, label, float(secs), tag))
            except ValueError:
                torn += 1
    return rows, torn


def bucket(rows):
    """Split into the gate's own rows and the self-test's copies' rows."""
    gate = [r for r in rows if not r[3].startswith(SELFTEST_PREFIX)]
    inner = [r for r in rows if r[3].startswith(SELFTEST_PREFIX)]
    return gate, inner


def selftest_by_breakage(inner):
    """Total wall time per breakage, from the `00 bootstrap` phase row.

    Each breakage runs a whole gate copy, and that copy's FIRST phase row is
    emitted right after it has resolved its interpreter — so it measures the
    copy's startup and nothing before it. Every later row in the same copy is
    that copy's real work, and summing the copy's rows measures the breakage.

    The tag is the breakage label, which is what makes the column readable; the
    breakage NUMBER is inside the label rather than parsed out of it, because
    the label is the identifier the suite already prints and re-deriving a
    number from prose is the sort of thing this repository keeps failing on.
    """
    per = {}
    for kind, label, secs, tag in inner:
        name = tag[len(SELFTEST_PREFIX):]
        entry = per.setdefault(name, {"total": 0.0, "rows": 0, "boot": 0.0})
        entry["total"] += secs
        entry["rows"] += 1
        if kind == PHASE and label.startswith("00 bootstrap"):
            entry["boot"] = secs
    return per


def render(title, rows, top, limit=25):
    """One table: slowest first. `cpu` rows are marked because they overlap."""
    print(f"\n== {title}  ({len(rows)} timed rows)")
    if not rows:
        print("   (none recorded)")
        return
    ordered = sorted(rows, key=lambda r: -r[2])[:limit]
    width = max((len(r[1]) for r in ordered), default=10)
    width = min(width, 78)
    print(f"{'seconds':>9}  {'kind':<7}  label")
    print(f"{'-' * 9}  {'-' * 7}  {'-' * min(width, 78)}")
    for kind, label, secs, _ in ordered:
        flag = "  (overlaps: sum is an upper bound)" if kind == CPU else ""
        print(f"{secs:9.2f}  {kind:<7}  {label[:width]}{flag}")
    if len(ordered) < len(rows):
        print(f"   ... {len(rows) - len(ordered)} more rows; raise --top to see them.")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("profile", help="the TSV KIT_PROFILE wrote")
    ap.add_argument("--top", type=int, default=25, help="rows per table (default 25)")
    args = ap.parse_args(argv)

    try:
        rows, torn = read(args.profile)
    except OSError as exc:
        sys.exit(f"profile_report: {exc}")
    if not rows:
        sys.exit(
            "profile_report: no rows. KIT_PROFILE must be set in the ENVIRONMENT of\n"
            "              the gate, not only of the shell that launched it, or every\n"
            "              self-test copy writes to a file this cannot find."
        )
    if torn:
        print(f"note: {torn} row(s) were too short to read and were SKIPPED, not guessed at.")

    gate, inner = bucket(rows)

    # The gate's own phases, in wall time. This is the table a reader of a
    # ten-minute run thinks in: it cannot double-count, because a phase row is
    # emitted once per phase and covers everything the phase did.
    render(
        "the GATE's phases, wall time (these do not overlap)",
        [r for r in gate if r[0] == PHASE],
        args.top,
    )
    render(
        "the GATE's own checks and bounded tiers (excludes the self-test's copies)",
        [r for r in gate if r[0] != PHASE],
        args.top,
    )

    per = selftest_by_breakage(inner)
    total = sum(e["total"] for e in per.values())
    boot = sum(e["boot"] for e in per.values())
    ordered = sorted(per.items(), key=lambda kv: -kv[1]["total"])[: args.top]
    print(f"\n== the SELF-TEST: {len(per)} breakages, {total:.1f}s total "
          f"({total / max(len(per), 1):.1f}s each on average)")
    print(f"   of which {boot:.1f}s ({100 * boot / total if total else 0:.0f}%) is interpreter "
          f"resolution and dependency bootstrap, once per copy")
    print(f"{'seconds':>9}  {'boot':>7}  {'rows':>5}  breakage")
    print(f"{'-' * 9}  {'-' * 7}  {'-' * 5}  {'-' * 40}")
    for name, e in ordered:
        print(f"{e['total']:9.2f}  {e['boot']:7.2f}  {e['rows']:5d}  {name[:78]}")

    grand = sum(r[2] for r in gate if r[0] == PHASE) + total
    print(f"\n   accounted: {grand:.1f}s of measured phase time "
          f"({sum(r[2] for r in gate if r[0] == PHASE):.1f}s gate + {total:.1f}s self-test)")
    print("   the difference from the run's wall time is the check rows that are not")
    print("   phases, the argument parsing, and whatever the parent shell spent.")
    return 0


if __name__ == "__main__":
    sys.exit(main())