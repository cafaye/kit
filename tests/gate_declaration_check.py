#!/usr/bin/env python3
"""The adopting repositories carry no workaround for a core defect that is fixed.

    gate_declaration_check.py <fleet-root>

WHAT THIS EXISTS FOR

`core` publishes a gate declaration format (`schemas/gate.schema.json`), a
checker (`harness/gate_check.py`) and a proof that the checker can fail. Two
defects in that checker forced repositories that adopted the format into local
workarounds:

  D12    `RUN_KEY` only matched a `run: |` block, so `run: ./bin/prime` on one
         line was invisible to `gate.ci-disagrees`. The step that runs the gate
         stopped counting as a step that runs the gate. Fixed in core `63fd319`.
  D13    a proof was matched against raw bytes, which carry whatever ANSI colour
         the gate's own tools emit, so a pattern written by reading a terminal
         failed on a machine whose tools colourise. Fixed in core `c63af27`;
         core now strips ANSI in exactly one place, before matching.

The trap is that such a workaround is not neutral. It is a second, local,
unpolicied copy of a decision that now lives in `core`, and it is the kind that
rots. A `gate.yml` carrying a hand-rolled escape-tolerant regex is now *weaker*
than one without it, because the escape runs absorb characters a stricter
pattern would have rejected. A rule that only lives in a report is a rule
violated within a month, so it lives here.

THE FIRST VERSION OF THIS FILE WAS A KEYWORD SCAN, AND IT CRIED WOLF

Worth recording, because the shape of the mistake is the transferable part. It
matched phrases like `cannot see`, `only matches`, `workaround` and `D12` in any
comment, and against the real fleet it reported **4 repositories and 24
findings**, almost all of them false:

  * `core/gate.yml` was reported for the sentence "That is MD12's
    collect-then-run machinery" — `D12` is a substring of `MD12`, and the
    sentence is about an unrelated owed feature.
  * `cafaye-ts/gate.yml` twice, for "the checker cannot see the file" — a true
    sentence about `check_command` and a bare name, with nothing to do with
    either defect.
  * `darkroom/gate.yml`, for "when a recipe stops matching", which is about its
    own self-test.
  * `caf`'s declaration, twice, for comments arguing that a workaround is now
    UNNECESSARY — the exact opposite of the finding.

That is `gate.ci-disagrees`'s own defect class: a check that fires on correct
work teaches the reader to ignore it, and it taught on the first repository
scanned. Both fixes below came from reading every comment the scan flagged, and
both are narrowing rather than loosening.

THE THREE RULES, AND WHY EACH IS STRUCTURAL

**1. D13 — a `proof[].match` carrying an escape token.** Unambiguous. Core
strips the escapes before matching, so an escape-tolerant pattern and a strict
one agree on a colour-bearing log: the workaround is invisible in *behaviour*
and visible in *spelling*, and spelling is what this reads. No keywords, no
prose, no judgement.

**2. D12 — a `run:` block scalar whose whole body is the declared argv and
nothing else.** This is the workaround's actual shape, and it is measurable
rather than guessed. `courier` writes its gate as a block scalar for three real
reasons — `pipefail`, a `tee`, an exit-code assertion — and every one of those
puts more than the command in the body, so it does not match. A block scalar
containing nothing but `./bin/prime` has no other reason to exist.

**3. D12 — a comment that names a checker-internal term AND makes a claim
about a `run:` spelling.** Two conditions, and both are required, which is what
the keyword version got wrong by having neither. `RUN_KEY`, `gate.ci-disagrees`
or `gate.ci-unproven` is the internal vocabulary; "one-line", "block scalar",
`run:` or "spelling" is the claim. A comment that mentions the finding and
documents what the check does is the common case in this fleet and is a true
sentence; a comment that names the finding *and* claims a spelling is invisible
to it is the workaround. The narrow escape list is a claim that the check
WORKS, and none of its phrasings can be produced by the sentence shape a
justification takes.

WHAT IS DELIBERATELY NOT HERE

`core` already checks that a workflow invokes the gate it declares
(`gate.ci-disagrees`), and does it properly: it parses `run:` spellings, follows
the multi-invocation policy, and accepts a declared mise task or a task-runner
deferral. Re-expressing any of that here would be the same defect in a second
place — which is what rules 2 and 3 exist to prevent.

**The limit, stated rather than hidden:** a D12 workaround with no comment
justifying it is only caught by rule 2, and a D12 workaround written as a
one-liner with a comment that avoids the internal vocabulary is not caught at
all. Nothing distinguishes the latter from a workflow that never had the
problem, and a check that guessed would be crying wolf again. Rules 2 and 3
together cover both shapes the two workarounds in this fleet actually took.

TWO THINGS THAT ARE ABOUT `core`'s DIALECT, NOT ABOUT THE DECLARATION

1. **PyYAML is stricter than `core`'s reader** on a plain scalar carrying `: ` —
   `unmet: bin/prime: ruby not found` is a legal core declaration and a PyYAML
   error. Three of the fourteen declaring repositories are in that state. So a
   document PyYAML refuses falls back to a narrow line reader for the two keys
   this check needs, and says so per repository. It is never a FAILURE:
   converting a difference between two readers into a red would be reporting
   somebody else's defect as this check's finding.
2. **`core_fanout_check.py` is stdlib-plus-PyYAML and this file is the same
   shape.** That is kit's one carve-out for a program that has to parse
   documents; a third program needs a manager's decision, and this one reuses
   the existing carve-out rather than opening a new one.

EXIT STATUS

    0  no merged adopting repository carries a workaround
    1  at least one does
    2  the check could not happen — no fleet root, or it could not be read

2 is never 0. A sweep that could not read a single declaration has not found the
fleet, and reporting that as a clean sweep is the defect this file exists to
prevent.
"""

from __future__ import annotations

import os
import re
import sys

import yaml

#: Where an adopting repository's declaration lives. One name, because two is a
#: second thing to remember and the second is what drifts.
DECLARATION = "gate.yml"

#: The tokens a hand-rolled escape-tolerant proof pattern is built from.
#:
#: `\x1b`, `\033` and `\e[` are the three ways an author writes ESC in a Python
#: regex; `001b` is the JSON/unicode spelling. Case-insensitive, so `x1B` and
#: `x1b` are one token rather than two.
ESCAPE_TOKEN = re.compile(r"x1b|033|\\e\[|001b", re.IGNORECASE)

#: `core`'s own internal vocabulary. A comment quoting this is talking about the
#: checker; a comment that does NOT is documentation a reader benefits from, and
#: requiring this is what stops the check reporting eight true sentences.
INTERNAL_TERMS = ("run_key", "gate.ci-disagrees", "gate.ci-unproven")

#: The claim about how a `run:` key is written. Paired with a term above.
SPELLING_CLAIMS = ("one-line", "one line", "block scalar", "run:", "spelling")

#: The narrow escape list: phrasings that are a claim the check WORKS. None of
#: them can be produced by "…is invisible to it", which is the shape a
#: justification takes, and a check whose escape hatch is a wide substring is a
#: check that can be satisfied by accident.
BENIGN = re.compile(
    r"stays honest"
    r"|rather than a quiet divergence"
    r"|the finding that means"
    r"|names? (?:the )?finding"
    r"|is the finding"
    r"|would be (?:a lie|a false red)"
    r"|no longer (?:necessary|needed)",
    re.IGNORECASE,
)

#: `match:`, `invokes:` and `workflow:` for the fallback reader. Anchored,
#: permissive about quoting, because a YAML scalar may be single-quoted,
#: double-quoted or bare.
#:
#: `workflow:` is here because a reader that found `invokes` but not `workflow`
#: would report "no workflow was read" for exactly the three repositories whose
#: declarations PyYAML refuses — which are `cafaye-rb` and `cafaye-ts`, and
#: `cafaye-rb` is the repository D12 was found in. A fallback that skips the
#: repository the check exists to watch is worse than no fallback, and the way it
#: fails is silently: the row reads `ok` either way.
MATCH_LINE = re.compile(r"^\s*-?\s*match:\s*(?P<value>.+?)\s*$")
INVOKES_LINE = re.compile(r"^\s*invokes:\s*\[(?P<value>[^\]]*)\]\s*$")
WORKFLOW_LINE = re.compile(r"^\s*workflow:\s*(?P<value>.+?)\s*$")


class Repository:
    """One adopting repository, and what this check could say about it."""

    def __init__(self, name: str, root: str) -> None:
        self.name = name
        self.root = root
        self.problems: list[str] = []
        # Rules that could not be evaluated. Reported, never folded into a pass.
        self.notes: list[str] = []
        self.proof_count = 0
        self.workflow: str | None = None
        self.invokes: list[str] = []


def comment_lines(text: str) -> list[tuple[int, str]]:
    """Every comment in a YAML file, with its line number.

    Two shapes, and both are read: a whole-line comment and a trailing comment
    on a line that carries a value. The D12 workaround wrote the first; a
    rewrite could write the second, and a check reading only the first would be
    satisfied by moving the justification onto one line.
    """
    out: list[tuple[int, str]] = []
    for number, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("#"):
            out.append((number, stripped))
            continue
        if "#" in line:
            value, _, tail = line.partition("#")
            if value.strip() and tail.strip():
                out.append((number, tail.strip()))
    return out


def parse_declaration(path: str) -> tuple[dict | None, str]:
    """`(declaration, how-it-was-read)`, or `(None, why)`.

    PyYAML first, because it is the right answer. On failure, the narrow line
    reader — and the failure is NOT a finding, because the document may be
    perfectly legal under `core`'s own reader and that difference is core's to
    own.
    """
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError as exc:
        return None, f"could not be read: {exc}"

    try:
        loaded = yaml.safe_load(text)
    except yaml.YAMLError:
        return _line_reader(text), "the line reader, because PyYAML refused the document"

    if not isinstance(loaded, dict):
        return None, "is not a mapping"
    return loaded, "PyYAML"


def _line_reader(text: str) -> dict:
    """`{"proof": [...], "ci": {...}}` from lines.

    Deliberately tiny and deliberately total: it answers the two questions this
    check asks and nothing else, and a key it cannot see is absent rather than
    guessed. Everything it returns is a string the author wrote in the file.
    """
    proofs: list[dict] = []
    ci: dict = {}
    for line in text.splitlines():
        matched = MATCH_LINE.match(line)
        if matched:
            proofs.append({"match": _unquote(matched.group("value"))})
            continue
        matched = INVOKES_LINE.match(line)
        if matched:
            ci["invokes"] = [
                _unquote(item.strip())
                for item in matched.group("value").split(",")
                if item.strip()
            ]
            continue
        matched = WORKFLOW_LINE.match(line)
        if matched:
            ci["workflow"] = _unquote(matched.group("value"))
    return {"proof": proofs, "ci": ci}


def _unquote(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        return value[1:-1]
    return value


def escape_tolerant(proofs: object) -> list[str]:
    """Which `gate.proof[].match` values carry escape tolerance, and why.

    The pattern is shown, truncated to 90 characters. A proof pattern is data
    its author wrote in a committed file, not a secret; the truncation is about
    the summary line staying readable.
    """
    found: list[str] = []
    if not isinstance(proofs, list):
        return found
    for index, item in enumerate(proofs):
        if not isinstance(item, dict):
            continue
        pattern = item.get("match")
        if not isinstance(pattern, str):
            continue
        hit = ESCAPE_TOKEN.search(pattern)
        if not hit:
            continue
        label = item.get("id", f"proof/{index}")
        shown = pattern if len(pattern) <= 90 else pattern[:87] + "..."
        found.append(
            f"D13: gate.proof[{index}] ({label}) is escape-tolerant — {shown!r} "
            f"matches {hit.group(0)!r}. core strips ANSI in exactly one place "
            f"before matching (c63af27), so this is a second, local copy of a "
            f"decision core already makes. The escape runs also absorb characters "
            f"a stricter pattern would reject, so the declaration is WEAKER than "
            f"the same declaration written without them"
        )
    return found


def block_scalar_carrying_only_the_gate(workflow_text: str, invokes: list[str]) -> list[str]:
    """`run:` block scalars whose entire body is the declared argv. Line numbers.

    Rule 2, and the only measurement in this file. A block scalar that contains
    nothing but the gate command has no reason to be a block scalar other than
    the shape D12 forced on it; the legitimate uses all put something else in
    the body (`pipefail`, a `tee`, an exit-code assertion, a multi-line script),
    which is why `courier` is not reported.

    The comparison is exact after normalising surrounding whitespace, and that
    strictness is the point: a body with anything else in it is not this shape.
    """
    if not invokes:
        return []
    wanted = " ".join(invokes).strip()
    # `./bin/prime` and `bin/prime` are the same file and both are in this
    # fleet; the leading `./` is stripped, which is the same leniency core's
    # `_appears` applies and for the same reason.
    variants = {wanted}
    if wanted.startswith("./"):
        variants.add(wanted[2:])
    else:
        variants.add(f"./{wanted}")

    hits: list[str] = []
    lines = workflow_text.splitlines()
    for index, raw in enumerate(lines):
        matched = re.match(r"^(?P<indent>\s*)(?:-\s+)?run:\s*[|>][+-]?\d*\s*$", raw)
        if not matched:
            continue
        key_indent = len(matched.group("indent"))
        body: list[str] = []
        cursor = index + 1
        while cursor < len(lines):
            line = lines[cursor]
            if not line.strip():
                cursor += 1
                continue
            if len(line) - len(line.lstrip()) <= key_indent:
                break
            body.append(line.strip())
            cursor += 1
        if not body:
            continue
        joined = " ".join(body).strip()
        if joined in variants:
            hits.append(str(index + 1))
    return hits


def inspect(name: str, root: str) -> Repository:
    repo = Repository(name, root)
    path = os.path.join(root, DECLARATION)
    declaration, reader = parse_declaration(path)
    if reader != "PyYAML":
        repo.notes.append(
            f"{DECLARATION} was read with {reader}. That is a difference between "
            f"two YAML readers, not a defect here, and it is counted as neither a "
            f"pass nor a failure — see the module docstring"
        )
    if declaration is None:
        repo.notes.append(f"{DECLARATION} {reader}; nothing could be checked")
        return repo

    # The declaration's own comments: rule 3, and rule 1's reasoning lives here
    # too even when the pattern itself is clean.
    text = _read_text(path)
    if text is not None:
        for number, comment in comment_lines(text):
            _judge(repo, f"{DECLARATION}:{number}", comment)

    gate = declaration.get("gate")
    proofs = gate.get("proof") if isinstance(gate, dict) else None
    if proofs is None:
        # The fallback reader puts `proof` at the top level, so both shapes are
        # read. Whichever answered, the count is the author's own.
        proofs = declaration.get("proof")
    if isinstance(proofs, list):
        repo.proof_count = len(proofs)
    repo.problems.extend(escape_tolerant(proofs))

    ci = declaration.get("ci")
    workflow = ci.get("workflow") if isinstance(ci, dict) else None
    invokes = ci.get("invokes") if isinstance(ci, dict) else None
    if isinstance(invokes, list):
        repo.invokes = [item for item in invokes if isinstance(item, str)]

    if not (isinstance(workflow, str) and workflow):
        # core's checker reports this as `gate.ci-undeclared`, a warning that
        # does not move its exit code. Mirrored: a note, because this check does
        # not claim to have read a workflow that is not named.
        repo.notes.append(
            "gate.yml names no ci.workflow, so no workflow was read. core's "
            "checker calls this gate.ci-undeclared"
        )
        return repo

    repo.workflow = workflow
    workflow_text = _read_text(os.path.join(root, workflow))
    if workflow_text is None:
        repo.notes.append(f"{workflow} could not be read; it was not checked")
        return repo

    for number, comment in comment_lines(workflow_text):
        _judge(repo, f"{workflow}:{number}", comment)

    # Rule 2 needs `invokes`; without it the shape is unmeasurable and that is
    # said rather than assumed either way.
    if not repo.invokes:
        repo.notes.append(
            "gate.yml declares no ci.invokes, so the block-scalar shape is not "
            "measurable here. core's checker treats that as gate.ci-undeclared"
        )
    else:
        for line in block_scalar_carrying_only_the_gate(workflow_text, repo.invokes):
            repo.problems.append(
                f"D12: {workflow}:{line} writes the gate as a `run:` block scalar "
                f"whose entire body is {' '.join(repo.invokes)!r} and nothing else. "
                f"That spelling has no reason to exist: core's RUN_KEY reads every "
                f"`run:` form as of 63fd319, and a block scalar that contains only "
                f"the command is the shape a workaround for the old limitation "
                f"takes. A step that also sets `pipefail`, tees a log, or asserts "
                f"an exit code is not this shape and is not reported"
            )
    return repo


def _read_text(path: str) -> str | None:
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError:
        return None


def _judge(repo: Repository, where: str, comment: str) -> None:
    """Rule 3: an internal term AND a claim about a `run:` spelling."""
    lowered = comment.lower()
    internal = next((t for t in INTERNAL_TERMS if t in lowered), None)
    if internal is None:
        return
    claim = next((c for c in SPELLING_CLAIMS if c in lowered), None)
    if claim is None:
        return
    if BENIGN.search(comment):
        return
    repo.problems.append(
        f"D12: {where} justifies a workflow spelling by citing {internal!r} and "
        f"claiming a {claim!r} form it cannot see: {comment[:110]!r}. D12 is core "
        f"63fd319 and core now reads every `run:` spelling, so that is a false "
        f"sentence about core. A comment citing a limitation which no longer "
        f"exists is worse than no comment, because the next reader cannot tell "
        f"it is obsolete from the text — which is why the workaround and the "
        f"sentence have to be removed together"
    )


def discover(root: str) -> list[Repository]:
    """Every adopting repository under `root`, sorted.

    Worktrees are NOT excluded, and the reason is not an oversight.
    `tests/staleness.py` excludes them on purpose: its unit is a repository's
    history and a worktree shares its parent's, so counting one reports one
    consumer as two. This check's unit is the FILES ON DISK, and a worktree is
    where a workaround would actually be written today.

    A worktree repeats its parent's findings, which is a duplicated report line
    rather than a wrong one — the harmless direction. But a worktree is also
    another packet's unmerged work, and kit's gate going red because of a branch
    this packet does not own is a gate that blocks a merge over something
    uncommitted. So the two are reported separately: a worktree's findings are a
    `note:` and never move the exit code, and its row says which it is.
    """
    found: list[Repository] = []
    try:
        entries = sorted(os.listdir(root))
    except OSError as exc:
        raise SystemExit(f"gate_declaration_check: cannot read {root}: {exc}")
    for entry in entries:
        if entry.startswith("."):
            continue
        path = os.path.join(root, entry)
        if not os.path.isdir(path) or not os.path.isfile(os.path.join(path, DECLARATION)):
            continue
        found.append(inspect(entry, path))
    return found


def is_worktree(root: str, name: str) -> bool:
    """A worktree's `.git` is a file saying `gitdir:`; a clone's is a directory."""
    marker = os.path.join(root, name, ".git")
    if not os.path.isfile(marker):
        return False
    try:
        with open(marker, encoding="utf-8") as handle:
            return handle.read(6).strip() == "gitdir"
    except OSError:
        return False


def render(repos: list[Repository], root: str) -> None:
    print(f"swept {len(repos)} adopting repository(ies) under {root}")
    for repo in repos:
        worktree = is_worktree(root, repo.name)
        if repo.problems and not worktree:
            state = "FAIL"
        elif repo.problems:
            state = "note"
        elif repo.notes:
            state = "SKIP"
        else:
            state = "ok"
        kind = " (worktree)" if worktree else ""
        print(
            f"  {state:4} {repo.name:36}{kind:12} {repo.proof_count} proof(s), "
            f"invokes: {' '.join(repo.invokes) or '-'}, workflow: {repo.workflow or '-'}"
        )
        for problem in repo.problems:
            prefix = "note (worktree, does not move the exit code): " if worktree else ""
            print(f"       - {prefix}{problem}")
        for note in repo.notes:
            print(f"       - unproven: {note}")


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(
            "gate_declaration_check: usage: gate_declaration_check.py <fleet-root>",
            file=sys.stderr,
        )
        return 2
    root = argv[0]
    if not os.path.isdir(root):
        print(
            f"gate_declaration_check: {root} is not a directory. This is exit 2 and "
            f"never 0: a sweep that could not read a single declaration has not "
            f"found the fleet, and reporting that as a clean sweep is the defect "
            f"this check exists to prevent.",
            file=sys.stderr,
        )
        return 2

    repos = discover(root)
    render(repos, root)

    failures = [r for r in repos if r.problems and not is_worktree(root, r.name)]
    worktree_notes = sum(1 for r in repos if r.problems and is_worktree(root, r.name))
    unproven = sum(1 for r in repos if r.notes)
    if worktree_notes:
        print(
            f"note: {worktree_notes} worktree(s) carry a workaround. Reported, not "
            f"counted: a worktree is another packet's unmerged branch, and kit's "
            f"gate must not be red because of work this packet does not own."
        )
    if failures:
        print(
            f"FAIL: {len(failures)} of {len(repos)} adopting repositories carry a "
            f"workaround for a fixed core defect. core 63fd319 (D12) and c63af27 "
            f"(D13) make both of those decisions in one place; a local copy is a "
            f"second, unversioned version of a decision that now lives in core."
        )
        return 1
    if not repos:
        print(
            "note: no adopting repository found. Exit 0 because the check ran and "
            "found nothing, not because it could not run — but it is worth "
            "knowing that it looked at nothing."
        )
        return 0
    if unproven:
        print(
            f"note: {unproven} of {len(repos)} could not be fully checked and each "
            f"names itself above. An unevaluated rule is not a rule that passed."
        )
        return 0
    print(
        f"OK: none of the {len(repos)} adopting repositories carries a D12 or D13 "
        f"workaround, and every one was fully checked."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
