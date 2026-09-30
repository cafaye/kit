#!/usr/bin/env python3
"""Structural checks on the core fan-out artifacts.

Run by `tests/validate.sh` as `core_fanout_check`. Kept out of `validate.sh`
because it is a real parser over four file types and inlining it would bury it.

WHAT IT CHECKS, AND WHY EACH ONE IS A DEFECT SOMEONE WILL SHIP

1. every `core/vendir/vendir.yml.*` parses, and declares exactly one content
   entry with a `git:` source;
2. `includePaths` is a SIBLING of `git:`, never a child of it;
3. the `git:` URL is `https://` or `ssh://`;
4. the source is `git:`, never `http:`;
5. every `includePaths` pattern ends in a glob or names a file that exists
   upstream — a bare directory name matches no file;
6. `ref` is a tag-shaped string or the literal `master`, and a `ref` of `master`
   is reported as a NOTE, not a failure;
7. `newRootPath` is present, because a document that changes directory needs it;
8. every option named in `core/renovate/*.json5` is a real Renovate option.

Item 2 is the one this file exists for. `includePaths` nested under `git:` is
dropped silently by vendir's YAML unmarshalling and the sync then vendors the
ENTIRE upstream repository while exiting 0. That was run, not guessed: see
`core/vendir/README.md`.
"""

from __future__ import annotations

import json
import os
import re
import sys

import yaml

# Renovate options this design uses. Anything else in a renovate.json5 is a typo
# that Renovate would reject — or worse, one that looks accepted and is ignored.
RENOVATE_OPTIONS = {
    "$schema", "extends", "enabled", "enabledManagers", "ignorePaths",
    "packageRules", "constraints", "installTools", "automerge", "labels",
    "description", "matchManagers", "matchDatasources", "matchUpdateTypes",
    "versioning", "osvOffline", "ignoreUnstable", "schedule", "timezone",
    "rangeStrategy", "lockFileMaintenance", "dependencyDashboard",
}

# Options whose VALUES are free-form maps rather than option names. Walking into
# `constraints` and demanding its keys be options reports `constraints.vendir` as
# a typo, which is the checker being wrong about the shape of the thing it is
# checking. Each of these is a map keyed by something that is not a Renovate
# option: a tool name, a host, a registry URL.
FREE_FORM_VALUE_OPTIONS = {
    "constraints", "hostRules", "registryAliases", "customDatasources",
    "customManagers", "postUpgradeTasks", "allowedPostUpgradeCommands",
    "customEnvVariables", "secrets", "artifactAuth",
}

# Options verified NOT to exist at Renovate f998d68. Naming them here means a
# future commit that reaches for one gets a gate error instead of a silent
# no-op, and the comment is the receipt.
RENOVATE_OPTIONS_THAT_DO_NOT_EXIST = {
    "needsCodeChanges": "no such option at f998d68: zero matches for 'codechange' in lib/",
}

# A tag-shaped ref: v1.2.3, 1.2.3, v0.4.0-rc.1
TAG_RE = re.compile(r"^v?\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.\-]+)?$")
URL_RE = re.compile(r"^(?:ssh|https?)://.+")

problems: list[str] = []
notes: list[str] = []


def fail(msg: str) -> None:
    problems.append(msg)


def check_vendir(path: str, rel: str) -> None:
    try:
        with open(path, encoding="utf-8") as fh:
            doc = yaml.safe_load(fh)
    except Exception as exc:  # noqa: BLE001 - a parse error is the finding
        fail(f"{rel}: does not parse: {exc}")
        return

    if not isinstance(doc, dict):
        fail(f"{rel}: is not a mapping")
        return

    if doc.get("apiVersion") != "vendir.k14s.io/v1alpha1":
        fail(f"{rel}: apiVersion is {doc.get('apiVersion')!r}, "
             f"expected 'vendir.k14s.io/v1alpha1'")

    directories = doc.get("directories")
    if not isinstance(directories, list) or not directories:
        fail(f"{rel}: has no directories")
        return

    for index, directory in enumerate(directories):
        where = f"{rel}: directories[{index}]"
        if not isinstance(directory, dict):
            fail(f"{where}: not a mapping")
            continue
        if "path" not in directory:
            fail(f"{where}: no `path` — the destination directory is required")

        contents = directory.get("contents")
        if not isinstance(contents, list) or not contents:
            fail(f"{where}: has no contents")
            continue

        for cindex, content in enumerate(contents):
            cwhere = f"{where}.contents[{cindex}]"
            if not isinstance(content, dict):
                fail(f"{cwhere}: not a mapping")
                continue

            git = content.get("git")
            if git is None:
                if "http" in content:
                    fail(f"{cwhere}: uses an `http:` source. Renovate extracts it "
                         f"with skipReason 'unsupported-datasource', so it is never "
                         f"updated. Use `git:`.")
                else:
                    fail(f"{cwhere}: has no `git:`, `http:`, `helmChart:` or "
                         f"`githubRelease:` source")
                continue

            if not isinstance(git, dict):
                fail(f"{cwhere}: `git:` is not a mapping")
                continue

            # (2) THE CHECK THIS FILE EXISTS FOR.
            if "includePaths" in git:
                fail(f"{cwhere}: `includePaths` is nested under `git:`. vendir drops "
                     f"keys its schema does not declare, so the filter is silently "
                     f"empty and the sync vendors the WHOLE upstream repository while "
                     f"exiting 0. It is a sibling of `git:`, not a child.")

            url = git.get("url")
            if not isinstance(url, str) or not URL_RE.match(url):
                fail(f"{cwhere}: git url {url!r} is not ssh:// or https://. Renovate's "
                     f"extractor requires that shape, so a git@github.com:… URL syncs "
                     f"locally and is never seen by the bot meant to bump it.")

            ref = git.get("ref")
            if ref is None:
                fail(f"{cwhere}: no `ref`")
            elif not isinstance(ref, str):
                fail(f"{cwhere}: `ref` is not a string")
            elif ref == "master":
                notes.append(
                    f"{cwhere}: ref is `master`. Correct until cafaye/core publishes "
                    f"its first tag; it has none, so a tag ref would fail. See "
                    f"core/release/README.md."
                )
            elif not TAG_RE.match(ref):
                fail(f"{cwhere}: ref {ref!r} is neither a semver tag nor `master`. A "
                     f"branch produces a pull request nobody reads.")

            # (5) a bare directory name matches no file.
            include = content.get("includePaths")
            if include is None:
                fail(f"{cwhere}: no `includePaths`. Without it vendir copies the "
                     f"entire upstream repository.")
            elif isinstance(include, list):
                for pattern in include:
                    if not isinstance(pattern, str):
                        fail(f"{cwhere}: includePaths entry {pattern!r} is not a string")
                    elif not pattern.endswith("/**") and "." not in os.path.basename(pattern):
                        fail(f"{cwhere}: includePaths entry {pattern!r} names a "
                             f"directory. vendir matches each FILE against the joined "
                             f"pattern, so a bare directory matches nothing and the "
                             f"sync fails. Use '{pattern}/**' or the file name.")
            else:
                fail(f"{cwhere}: `includePaths` is not a list")

            # (7)
            if "newRootPath" not in content and isinstance(include, list):
                notes.append(
                    f"{cwhere}: no `newRootPath`. Correct only when this repository "
                    f"keeps the document at the same path core publishes it at; "
                    f"otherwise the copy lands one directory too deep."
                )


def strip_json5(text: str) -> str:
    """Make a .json5 document parseable by the stdlib json module.

    Renovate reads JSON5, and a comment in this file is the only place some of
    these decisions are recorded. Rather than add a JSON5 parser as a dependency
    — kit is a repository with no dependencies, and that is a rule, not an
    accident — the JSON5-isms are removed here: comments, trailing commas, bare
    identifier keys, and single-quoted strings.

    Deliberately small and deliberately literal. This is a LINTER, and a linter
    that silently mis-parses is worse than no linter, so anything it cannot
    handle is left alone for `json.loads` to reject — which makes the check fail
    loudly rather than validate the wrong thing.
    """
    out: list[str] = []
    i = 0
    length = len(text)
    while i < length:
        ch = text[i]
        # Line comment.
        if ch == "/" and i + 1 < length and text[i + 1] == "/":
            while i < length and text[i] != "\n":
                i += 1
            continue
        # Block comment.
        if ch == "/" and i + 1 < length and text[i + 1] == "*":
            close = text.find("*/", i + 2)
            if close == -1:
                raise ValueError("unterminated /* */ comment")
            i = close + 2
            continue
        # Single-quoted string: re-emit as a double-quoted one. JSON5 allows the
        # single quotes; JSON does not, and a value wrapped in them is the single
        # most common way a .json5 file fails to parse for a reader who has
        # assumed it was JSON.
        if ch == "'":
            out.append('"')
            i += 1
            while i < length and text[i] != "'":
                if text[i] == "\\":
                    i += 1
                elif text[i] == '"':
                    out.append('\\"')
                    i += 1
                    continue
                out.append(text[i])
                i += 1
            if i >= length:
                raise ValueError("unterminated single-quoted string")
            i += 1
            out.append('"')
            continue
        out.append(ch)
        i += 1

    joined = "".join(out)
    # Bare identifier keys, which JSON5 allows and JSON does not. Anchored to the
    # start of a line so it cannot reach inside a string value: a key mid-line is
    # left alone, and if that ever matters the parse below fails loudly rather
    # than this quietly rewriting a string.
    joined = re.sub(r"^(\s*)([A-Za-z_$][A-Za-z0-9_$]*)\s*:", r'\1"\2":', joined,
                    flags=re.MULTILINE)
    # Trailing commas before a closing brace/bracket.
    return re.sub(r",(\s*[}\]])", r"\1", joined)


def check_renovate(path: str, rel: str) -> None:
    try:
        with open(path, encoding="utf-8") as fh:
            raw = fh.read()
        doc = json.loads(strip_json5(raw))
    except Exception as exc:  # noqa: BLE001
        fail(f"{rel}: does not parse: {exc}")
        return

    def walk(node, where: str) -> None:
        if isinstance(node, dict):
            for key, value in node.items():
                if key in RENOVATE_OPTIONS_THAT_DO_NOT_EXIST:
                    fail(f"{rel}:{where}.{key} — "
                         f"{RENOVATE_OPTIONS_THAT_DO_NOT_EXIST[key]}")
                elif key not in RENOVATE_OPTIONS:
                    fail(f"{rel}:{where}.{key} is not a Renovate option. A typo here "
                         f"is a policy that reads as applied and is not.")
                if key not in FREE_FORM_VALUE_OPTIONS:
                    walk(value, f"{where}.{key}")
        elif isinstance(node, list):
            for index, value in enumerate(node):
                walk(value, f"{where}[{index}]")

    walk(doc, "$")

    # `installTools` is an object keyed by tool name. The array form iterates
    # Object.keys() as ["0"], fails Renovate's isToolName check, and is a
    # configuration error — verified against validation.ts, which iterates
    # `Object.keys(val)` and rejects anything that is not a tool name.
    if isinstance(doc.get("installTools"), list):
        fail(f"{rel}: installTools is an array. It is typed "
             f"Partial<Record<ToolName, …>> and validated by tool name, so the array "
             f"form is a configuration error. Use {{ vendir: {{}} }}.")
    # The tool constraint belongs in the SHARED config, and only there. A
    # per-repository stub that re-declared it would be a second copy of the
    # policy, which is the drift `inheritConfig` exists to prevent — so a stub is
    # checked for NOT having one. That is the same allowlist-hygiene shape as the
    # `breaking: false` rule in tests/rules.json: an escape hatch nobody is
    # watching is an escape hatch that gets used.
    extends = doc.get("extends") or []
    inherits_shared = any("renovate-config" in str(item) for item in extends)
    vendir_constraint = (doc.get("constraints") or {}).get("vendir")

    if inherits_shared:
        if "constraints" in doc:
            fail(f"{rel}: declares `constraints` but extends the shared config. The "
                 f"tool constraint is inherited; a second copy is a second policy.")
    elif not isinstance(vendir_constraint, str) or not TAG_RE.match(vendir_constraint):
        fail(f"{rel}: constraints.vendir is {vendir_constraint!r}. The vendir manager "
             f"installs its tool from `constraints` via resolveToolConstraint, so an "
             f"absent or unpinned value means an unpinned binary.")


def main() -> int:
    root = sys.argv[1]

    vendir_dir = os.path.join(root, "core", "vendir")
    if not os.path.isdir(vendir_dir):
        fail("core/vendir/ is missing — the fan-out templates are the deliverable")
    else:
        names = sorted(n for n in os.listdir(vendir_dir) if n.startswith("vendir.yml"))
        if not names:
            fail("core/vendir/ has no vendir.yml* template")
        for name in names:
            check_vendir(os.path.join(vendir_dir, name), f"core/vendir/{name}")

    renovate_dir = os.path.join(root, "core", "renovate")
    if not os.path.isdir(renovate_dir):
        fail("core/renovate/ is missing — the shared policy is a deliverable")
    else:
        for name in sorted(os.listdir(renovate_dir)):
            if name.endswith(".json5"):
                check_renovate(os.path.join(renovate_dir, name),
                               f"core/renovate/{name}")

    for note in notes:
        print(f"note: {note}")

    if problems:
        for problem in problems:
            print(problem)
        sys.exit(1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
