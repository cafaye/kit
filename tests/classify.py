#!/usr/bin/env python3
"""Classify a change to a vendored schema set, failing closed.

    classify.py <old-dir> <new-dir> [--tier T] [--json] [--quiet]

WHAT IT IS FOR

  `tests/self_test.sh` proves eighteen synthetic breakages of *kit's own* tree go
  red. It cannot prove that a future change to core's
  `event-envelope.schema.json` is one of those eighteen shapes. A change outside
  the modelled set would pass, get auto-merged, and break every consumer at
  once. This script is the defence: it compares the schema set a repository
  vendored before against the one it vendored after, and classifies every
  difference against a named rule in `tests/rules.json`.

THE PROPERTY THAT MATTERS

  It fails CLOSED. A difference it does not recognise is not reported as "no
  recognised breakage" and it is not skipped — it is reported as UNRECOGNISED,
  which is assigned the strictest tier, which fails at every tier a caller can
  declare. Silence and "nothing broke" are not the same answer, and only one of
  them is safe to hand to an auto-merge.

  Concretely: `classify.py` models a fixed set of JSON Schema keywords. A
  keyword it does not model — `unevaluatedProperties`, `dependentSchemas`, a
  dialect keyword nobody has seen — produces the `unmodelled-keyword`
  observation, which is FILE. Adding a keyword to core therefore cannot be
  auto-merged green by omission. That is the whole point.

THE FOUR TIERS, AND WHY FOUR

  FILE > PACKAGE > WIRE_JSON > WIRE, borrowed from buf's four categories
  because the distinction is the useful one: *pick the category that matches
  what your consumers actually depend on*. A Go struct with a `json:"..."` tag
  is a FILE consumer. A JSON payload validator is WIRE_JSON. kit defaults to
  FILE because every one of core's three real consumers unmarshals the document
  (muse asserts byte-identity and parses it, pantry resolves it to validate
  manifests, caf `go:embed`s it into a struct) — and because a default of FILE
  is the one that cannot be wrong in the unsafe direction.

  A consumer passes `--tier` naming the strictest tier its code depends on. The
  change is a failure when the change's tier is at least as strict as that. The
  tiers are cumulative — breaking FILE implies breaking WIRE_JSON — so one tier
  per change, the strictest it breaks, is sufficient to decide every case.

EXIT STATUS

  0  every change is at a tier looser than --tier
  1  at least one change is at or above --tier's strictness
  2  bad invocation, unreadable input, or an unparseable document
"""

from __future__ import annotations

import argparse
import json
import os
import sys

# The tier order, strictest first. Index is the strictness rank: a change with a
# LOWER index is stricter. `min()` over the observations of one change therefore
# yields the strictest thing that change breaks, which is the whole reduction.
TIERS = ("FILE", "PACKAGE", "WIRE_JSON", "WIRE")

# Keywords whose value is a single scalar. Any change is the same observation,
# because a rule that tried to tell a widening from a narrowing would be a rule
# that is wrong on the day someone writes a constraint it cannot compare.
NUMERIC_CONSTRAINTS = frozenset(
    {"minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf"}
)
LENGTH_CONSTRAINTS = frozenset(
    {
        "minLength",
        "maxLength",
        "minItems",
        "maxItems",
        "minProperties",
        "maxProperties",
    }
)
COMPOSITION = frozenset({"allOf", "anyOf", "oneOf", "not", "if", "then", "else"})

# The keywords whose value is an array of strings compared as a SET, not a list.
# `required` and `enum` share one code path, and a rule may therefore be written
# once for both by naming `{family}`. A family that is added here without a rule
# in rules.json falls through to UNRECOGNISED, which is the direction that is safe.
LIST_FAMILIES = ("required", "enum")

# Documentation-only keywords. Their rules are read out of rules.json rather than
# hardcoded, so that the tier of a documentation change is auditable in the same
# place as every other tier.
DOC_DEFAULT = "documentation:changed"

# Structural keywords that are containers rather than leaves. They are modelled
# explicitly because the operations inside them mean different things at
# different tiers (a key added to `properties` is additive; a key added to
# `required` is not).
CONTAINER_KEYWORDS = frozenset(
    {
        "$schema",
        "$id",
        "$defs",
        "$ref",
        "properties",
        "patternProperties",
        "required",
        "enum",
        "const",
        "type",
        "items",
        "prefixItems",
        "pattern",
        "format",
        "additionalProperties",
        "default",
        "uniqueItems",
    }
) | NUMERIC_CONSTRAINTS | LENGTH_CONSTRAINTS | COMPOSITION


class Observation:
    """One classified difference, with the pointer that located it."""

    __slots__ = ("pointer", "op", "rule", "tier", "detail")

    def __init__(self, pointer: str, op: str, rule: str, tier: str, detail: str = ""):
        self.pointer = pointer
        self.op = op
        self.rule = rule
        self.tier = tier
        self.detail = detail

    def as_dict(self) -> dict:
        return {
            "pointer": self.pointer,
            "op": self.op,
            "rule": self.rule,
            "tier": self.tier,
            "detail": self.detail,
        }

    def __str__(self) -> str:
        where = f"{self.pointer} {self.op}" if self.pointer else self.op
        return f"{self.tier:<10} {self.rule:<32} {where}" + (
            f"  ({self.detail})" if self.detail else ""
        )


class Catalogue:
    """The rule catalogue, indexed by the operation it claims."""

    def __init__(self, path: str):
        with open(path, encoding="utf-8") as fh:
            raw = json.load(fh)
        self.path = path
        self.rules = raw["rules"]
        self.descriptions = frozenset(raw.get("descriptions", []))
        self.advisory_ops = frozenset(
            op.format(family=family)
            for op in raw.get("advisoryOps", [])
            for family in (LIST_FAMILIES if "{family}" in op else ("",))
        )
        # Read from the catalogue rather than written here, so the fail-closed
        # tier is stated in exactly one place. It was `"FILE"` here AND a rule in
        # rules.json at the same time, and a self-test breakage that inverted
        # only the Python half left the whole suite green — which is what a
        # property asserted in two places looks like from the outside.
        self.unrecognised_tier = raw.get("unrecognisedTier")
        if self.unrecognised_tier not in TIERS:
            raise SystemExit(
                f"classify.py: rules.json unrecognisedTier is "
                f"{self.unrecognised_tier!r}, which is not one of {list(TIERS)}"
            )
        # Whether an unrecognised change fails at all, as opposed to at which
        # tier. These are two different switches and both are real: no tier can
        # be permissive enough for an unrecognised change to slip through, so
        # the only way to fail OPEN is this flag. That is why the self-test's
        # sharpest breakage flips this one rather than the tier above.
        self.unrecognised_is_breaking = raw.get("unrecognisedIsBreaking")
        if not isinstance(self.unrecognised_is_breaking, bool):
            raise SystemExit(
                "classify.py: rules.json unrecognisedIsBreaking must be a boolean. "
                "Omitting it is not the same as false; the whole property rests "
                "on it being stated."
            )
        self.by_op: dict[str, list[dict]] = {}
        for rule in self.rules:
            op = rule["op"]
            if "{family}" in op:
                # One rule for a code path shared by several keywords. Expanded
                # here so the catalogue stays readable and the classifier stays
                # ignorant of which keywords happen to share the path.
                for family in LIST_FAMILIES:
                    self.by_op.setdefault(op.format(family=family), []).append(rule)
            else:
                self.by_op.setdefault(op, []).append(rule)
        # An op with two rules would make "the" tier of a change ambiguous.
        # Refuse at load time rather than picking one arbitrarily later.
        clashes = [op for op, rs in self.by_op.items() if len(rs) > 1]
        if clashes:
            raise SystemExit(
                f"classify.py: rules.json maps {clashes} to more than one rule; "
                f"a change would have no single tier"
            )
        for rule in self.rules:
            if rule["tier"] not in TIERS:
                raise SystemExit(
                    f"classify.py: rule {rule['id']} has unknown tier {rule['tier']!r}"
                )
            # Allowlist hygiene, in the direction that matters: the ONLY way to
            # declare a change non-breaking is to name an operation that the
            # catalogue has already agreed is documentation. Anything else is a
            # refusal, not a warning.
            # Compare against the rule's EXPANDED ops, because advisory_ops holds
            # concrete names: a `{family}` rule is registered under each family it
            # covers, and checking the raw template against the expanded set would
            # reject the very rule the allowlist exists to permit.
            expanded = (
                [op.format(family=family) for family in LIST_FAMILIES]
                if "{family}" in rule["op"]
                else [rule["op"]]
            )
            if (not rule.get("breaking", True)
                    and not any(op in self.advisory_ops for op in expanded)):
                raise SystemExit(
                    f"classify.py: rule {rule['id']} declares "
                    f"breaking: false for op {rule['op']!r}, which is not in "
                    f"advisoryOps. Only a documentation change may be absorbed "
                    f"silently; making that decision auditable is the point."
                )

    def lookup(self, op: str) -> dict | None:
        found = self.by_op.get(op)
        return found[0] if found else None

    def is_breaking(self, op: str) -> bool:
        """Whether an operation may fail the gate.

        A rule opts out by declaring `"breaking": false`, and only an operation
        in `advisoryOps` may do so. That second condition is the whole defence:
        it means marking `enum:item-removed` as non-breaking is not a judgement
        call a future commit can make quietly, it is a catalogue that fails to
        load. The alternative — trusting the flag — turns the one escape hatch
        into the first place a fail-open classifier reappears.

        Borrowed from ESLint's `reportUnusedDisableDirectives`: an escape hatch
        with no hygiene rule is a ratchet that only turns one way.
        """
        if op == "unrecognised":
            return self.unrecognised_is_breaking
        rule = self.lookup(op)
        if rule is None:
            return True  # unknown => breaking. The direction that is safe.
        return rule.get("breaking", True)


def observation(cat: Catalogue, pointer: str, op: str, detail: str = "") -> Observation:
    """Classify one operation, failing closed when nothing claims it."""
    rule = cat.lookup(op)
    if rule is None:
        return Observation(pointer, op, "unrecognised",
                           cat.unrecognised_tier, detail)
    return Observation(pointer, op, rule["id"], rule["tier"], detail)


def walk_schemas(root: str) -> list[str]:
    """Every .json under root, as sorted repo-relative paths.

    Sorted so that the output of two runs over the same pair of trees is
    byte-identical: a classifier whose output ordering depends on the filesystem
    is a classifier whose diffs are noise.
    """
    found = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in sorted(filenames):
            if name.endswith(".json"):
                full = os.path.join(dirpath, name)
                found.append(os.path.relpath(full, root))
    return sorted(found)


def load(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"classify.py: cannot read {path}: {exc}")


def compare_value(pointer: str, key: str, old: object, new: object,
                  cat: Catalogue) -> list[Observation]:
    """Compare one keyword's value.

    Every branch either recurses into a modelled structure or returns a single
    observation. There is no branch that falls through and returns nothing,
    because a silent return is the fail-open bug this script exists to not have.
    """
    out: list[Observation] = []
    here = f"{pointer}/{key}" if pointer else key

    if key in cat.descriptions:
        if old != new:
            out.append(observation(cat, pointer, DOC_DEFAULT))
        return out

    if key == "$schema" or key == "$id":
        if old != new:
            out.append(observation(cat, pointer, "dialect-changed", f"{old!r} -> {new!r}"))
        return out

    if key == "properties" or key == "patternProperties":
        out += compare_map(here, old, new, cat)
        return out

    if key == "required":
        out += compare_string_list(here, old, new, "required", cat)
        return out

    if key == "enum":
        out += compare_string_list(here, old, new, "enum", cat)
        return out

    if key == "type":
        if old != new:
            out.append(observation(cat, pointer, "type:changed", f"{old!r} -> {new!r}"))
        return out

    if key == "pattern":
        if old != new:
            out.append(observation(cat, pointer, "pattern:changed"))
        return out

    if key == "format":
        if old != new:
            out.append(observation(cat, pointer, "format:changed", f"{old!r} -> {new!r}"))
        return out

    if key == "const":
        if old != new:
            out.append(observation(cat, pointer, "const:changed", f"{old!r} -> {new!r}"))
        return out

    if key == "additionalProperties":
        if old != new:
            out.append(observation(cat, here, "additionalProperties:changed"))
        return out

    if key == "default":
        if old != new:
            out.append(observation(cat, pointer, DOC_DEFAULT, f"{key} default moved"))
        return out

    if key in NUMERIC_CONSTRAINTS:
        if old != new:
            out.append(observation(cat, pointer, "numeric-constraint:changed",
                                   f"{key}: {old!r} -> {new!r}"))
        return out

    if key in LENGTH_CONSTRAINTS:
        if old != new:
            out.append(observation(cat, pointer, "length-constraint:changed",
                                   f"{key}: {old!r} -> {new!r}"))
        return out

    if key in COMPOSITION:
        if old != new:
            out.append(observation(cat, here, "composition:changed"))
        return out

    if key in ("$defs",):
        out += compare_map(here, old, new, cat)
        return out

    if key in ("items", "prefixItems"):
        out += compare_sequence(here, old, new, cat)
        return out

    if key == "$ref":
        if old != new:
            out.append(observation(cat, pointer, "dialect-changed", f"$ref moved"))
        return out

    # Anything left is a keyword this script does not model. That is the whole
    # fail-closed property, and it is reached by falling off the end on purpose.
    if old != new:
        out.append(observation(cat, here, "unrecognised", f"keyword {key!r}"))
    return out


def compare_map(pointer: str, old: object, new: object,
                cat: Catalogue) -> list[Observation]:
    """Compare a keyword whose value is an object of sub-schemas."""
    if not isinstance(old, dict) or not isinstance(new, dict):
        return compare_value(pointer, "", old, new, cat) if old != new else []
    out: list[Observation] = []
    for key in sorted(set(old) | set(new)):
        child = f"{pointer}/{key}"
        if key not in new:
            out.append(observation(cat, child, "properties:key-removed"))
        elif key not in old:
            out.append(observation(cat, child, "properties:key-added"))
        else:
            out += compare_schema(child, old[key], new[key], cat)
    return out


def compare_string_list(pointer: str, old: object, new: object, family: str,
                        cat: Catalogue) -> list[Observation]:
    """Compare `required` and `enum`, where added and removed mean opposite things."""
    if not isinstance(old, list) or not isinstance(new, list):
        return compare_value(pointer, family, old, new, cat) if old != new else []
    out: list[Observation] = []
    old_set, new_set = set(old), set(new)
    for item in sorted(old_set - new_set):
        out.append(observation(cat, pointer, f"{family}:item-removed", f"{item!r}"))
    for item in sorted(new_set - old_set):
        out.append(observation(cat, pointer, f"{family}:item-added", f"{item!r}"))
    if not out and old != new:
        # Same members, different order or duplicates. Semantically a no-op for a
        # validator, but it is not a rule anyone wrote down, so it fails closed
        # rather than being quietly waved through.
        out.append(observation(cat, pointer, f"{family}:reordered"))
    return out


def compare_sequence(pointer: str, old: object, new: object,
                     cat: Catalogue) -> list[Observation]:
    """Compare a keyword whose value is an array of sub-schemas."""
    if not isinstance(old, list) or not isinstance(new, list):
        return compare_value(pointer, "", old, new, cat) if old != new else []
    out: list[Observation] = []
    for index in range(max(len(old), len(new))):
        child = f"{pointer}/{index}"
        if index >= len(new):
            out.append(observation(cat, child, "composition:changed", "element removed"))
        elif index >= len(old):
            out.append(observation(cat, child, "composition:changed", "element added"))
        else:
            out += compare_schema(child, old[index], new[index], cat)
    return out


def compare_schema(pointer: str, old: dict, new: dict,
                   cat: Catalogue) -> list[Observation]:
    """Compare two sub-schemas key by key.

    Keys only in `old` and keys only in `new` are both real differences, and both
    are reported. A keyword present in one and absent in the other is the case
    that a naive `for key in old` loop drops, and dropping it is how a removal
    becomes an auto-merge.
    """
    out: list[Observation] = []
    for key in sorted(set(old) | set(new)):
        if key not in new:
            out.append(observation(cat, f"{pointer}/{key}", "unrecognised",
                                   f"keyword {key!r} removed"))
        elif key not in old:
            out.append(observation(cat, f"{pointer}/{key}", "unrecognised",
                                   f"keyword {key!r} added"))
        else:
            out += compare_value(pointer, key, old[key], new[key], cat)
    return out


def classify_file_change(rel: str, old: dict, new: dict,
                         cat: Catalogue) -> list[Observation]:
    prefix = f"/{rel}"
    out: list[Observation] = []
    for key in ("$schema", "$id"):
        if old.get(key) != new.get(key):
            out.append(observation(cat, prefix, "dialect-changed",
                                   f"{key}: {old.get(key)!r} -> {new.get(key)!r}"))
    out += compare_schema(prefix, old, new, cat)
    return out


def classify(old_dir: str, new_dir: str, cat: Catalogue) -> list[Observation]:
    """Every difference between two vendored schema sets, in a stable order."""
    out: list[Observation] = []
    old_files = set(walk_schemas(old_dir))
    new_files = set(walk_schemas(new_dir))

    for rel in sorted(new_files - old_files):
        out.append(observation(cat, f"/{rel}", "file-added"))
    for rel in sorted(old_files - new_files):
        out.append(observation(cat, f"/{rel}", "file-removed"))

    for rel in sorted(old_files & new_files):
        out += classify_file_change(rel, load(os.path.join(old_dir, rel)),
                                    load(os.path.join(new_dir, rel)), cat)
    return out


def worst(observations: list[Observation], cat: Catalogue) -> str | None:
    """The strictest tier any BREAKING observation breaks, or None.

    Advisory observations are excluded here rather than filtered at the call
    site, so that there is exactly one place that decides what "breaking" means
    and it reads the catalogue to find out. An advisory change is still
    reported, in full, by `classify()` — it is reported as not breaking, which
    is a different statement from not reported.
    """
    breaking = [o for o in observations if cat.is_breaking(o.op)]
    if not breaking:
        return None
    return min((o.tier for o in breaking), key=TIERS.index)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="classify.py",
        description="Classify a vendored schema change, failing closed on anything "
                    "tests/rules.json does not name.",
    )
    parser.add_argument("old_dir", help="the schema set as vendored before")
    parser.add_argument("new_dir", help="the schema set as vendored after")
    parser.add_argument(
        "--tier",
        choices=TIERS,
        default="FILE",
        help="the strictest tier this consumer's code depends on. Defaults to "
             "FILE, the strictest, because a default that can only fail safe is "
             "the only default worth having.",
    )
    parser.add_argument("--rules", default=None,
                        help="path to rules.json (default: alongside this script)")
    parser.add_argument("--json", action="store_true",
                        help="emit the observations as JSON")
    parser.add_argument("--quiet", action="store_true",
                        help="print only the verdict")
    args = parser.parse_args(argv)

    rules_path = args.rules or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                            "rules.json")
    cat = Catalogue(rules_path)

    for directory in (args.old_dir, args.new_dir):
        if not os.path.isdir(directory):
            raise SystemExit(f"classify.py: not a directory: {directory}")

    observations = classify(args.old_dir, args.new_dir, cat)
    tier = worst(observations, cat)
    breaking = tier is not None and TIERS.index(tier) <= TIERS.index(args.tier)
    advisory = [o for o in observations if not cat.is_breaking(o.op)]

    if args.json:
        json.dump(
            {
                "tier": args.tier,
                "worst": tier,
                "breaking": breaking,
                "advisory": [o.as_dict() for o in advisory],
                "observations": [o.as_dict() for o in observations],
            },
            sys.stdout,
            indent=2,
            sort_keys=True,
        )
        sys.stdout.write("\n")
        return 1 if breaking else 0

    if not args.quiet:
        if not observations:
            print("classify.py: no difference between the two schema sets")
        for obs in observations:
            suffix = "  (advisory)" if not cat.is_breaking(obs.op) else ""
            print(f"  {obs}{suffix}")
        if observations:
            verdict = tier if tier is not None else "nothing breaking"
            print(f"\n  strictest tier broken: {verdict}")

    if breaking:
        print(
            f"FAIL classify: the change breaks {args.tier} "
            f"(strictest: {tier}). This consumer depends on {args.tier}, so it is "
            f"not auto-mergeable. See core/README.md, 'F3'."
        )
        return 1

    if tier == "FILE" and observations:
        # Unreachable while the default is FILE, but reachable the moment a
        # consumer declares a looser tier, and then it is the case that matters:
        # a change the classifier could not explain, in a consumer that would
        # otherwise absorb it silently.
        print(
            f"note classify: the strictest change is FILE while this consumer "
            f"declares {args.tier}. A FILE change in a {args.tier} consumer is "
            f"expected only if the binding is generated; check before merging."
        )
    print(f"PASS classify: the change does not break {args.tier} (strictest: {tier})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
