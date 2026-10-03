# HANDOFF — kit-stability-01

**Branch:** `worker/kit-stability-01` · **Base:** `0b0ec67` · **Merged:** no
**Commits:** `8e27051` (mechanism) → `6da6a08` (breakages + a defect they found)
→ `edb5801` (docs)
**Gate state at handoff:** `bash tests/validate.sh --static-only` green; self_test
shards 1/8, 2/8, 3/8, 4/8, 8/8 green and run sequentially.

## What the packet was for

A consumer could not tell whether a kit version was safe to take. kit had **no
version at all** — its own changelog said so in its first paragraph — so "is 2.4.0
safe?" was answered by a person reading a diff, in every repository, forever. The
mechanism now exists: `VERSION` is the single source of truth, the tier is derived
from it, and the tier is **gated on**.

## What I learned, worth keeping

1. **The tier comes from two version strings, so the predecessor needs a home
   that travels.** I read it from `git show HEAD:VERSION` first. It resolves to
   nothing in a throwaway copy, so two of five breakages stayed green and I only
   found it by running them by hand against a copy before committing. **The
   predecessor now comes from the changelog section below the current one.** The
   general lesson: a gate whose verdict depends on `.git` being beside it verifies
   nothing on a machine that consumed the thing the way a real consumer does.
2. **`### Breaking` is the load-bearing rule, and it needs no predecessor.** "A
   breaking heading is legal only under a version whose MAJOR actually moved, and
   never under `## Unreleased`" is checkable across the whole history. Everything
   else about the gate is per-bump bookkeeping; this one is the promise.
3. **buf's `reserved` and k8s's `+k8s:deprecated` are different mechanisms.**
   Wire tombstone vs lifecycle marker on a still-present field. kit has no
   encoding, so only the shared weaker half transfers. Full argument in MD27.
4. **In a tombstone ledger, "an entry that matches nothing" is INVERTED.** The
   failure is a *live* name the entry says is dead — the same defect from the other
   side. See `RESERVED`'s own header.
5. **`0.0.0` really is in the fleet manifests** (guard, docs, site) — the
   research's claim checks out.

## What I ruled out

- **Putting the version in `cafaye.yml`.** `identity/cafaye.yml` deliberately has
  no `version` key and calls a second one a footgun; the keys that do exist mean
  "the dependency's contract version", a different question.
- **A fourth tier.** "Invisible" vs "safe" is a difference about the consumer's
  code, which kit cannot observe.
- **A prerelease spelling.** Refused rather than tiered: the suffix makes the
  derived tier change meaning when dropped.
- **A third parser in `tests/`.** Everything is shell inside `validate.sh`, so the
  existing "two programs, stdlib only" carve-out is untouched.
- **Putting tombstones in a template.** Anything in `templates/` multiplies by copy
  into every adopter; a tombstone ledger is a record of the *source*.

## What I tried and did not land

- **`MIGRATIONS.md`.** Deliberately absent — kit has made no MAJOR bump, and an
  empty file is a promise nothing keeps. The gate demands it on the first MAJOR.

## Successor's first move

**The rollout, in this order.**

1. **Tag `v1.0.0` on `master`** and add the `VERSION`-matches-the-tag check to
   `core/release/release.yml`. That is the last piece of kit's own loop, and
   nothing else can be honest until a tag exists.
2. **Decide the fleet's answer to the `0.0.0` question.** 13 of 15 repositories
   have no version; `guard`, `docs`, `site`, `muse` carry `0.0.0` or `^0.1.0`
   meaning something else. Two options, and this is a real decision, not a
   mechanical one:
   - **(a) Every service adopts the mechanism**, each with its own `VERSION` and a
     `### Breaking`-discipline changelog. Honest, uniform, and it makes "is
     identity 2.4.0 safe?" answerable.
   - **(b) Only `core` publishes a contract version**, services keep their
     application versions, and P1-10's rule becomes the actual rule: *a stable
     service may not depend on an alpha contract.* Smaller, and it matches how
   `core` already fans out.
   **I lean (b)** — it is the rule the research states for the fleet, and (a)
   multiplies a release chore across thirteen repos to solve a question only one of
   them is asked. But it is your call and MD26 documents the mechanism either way.
3. **Wire `stability_tier` into the reusable workflow** so a service that wants
   the gate gets it without copying anything. Note the constraint: anything added
   to `lint/` or `core/` is inherited at run time, while anything in `templates/`
   is copied by every adopter. `VERSION` is deliberately at the repo root, so it is
   currently **neither** — a service adopting the mechanism has to create its own,
   which is the right default and worth stating.
4. **If you pick (a), port `reserved_check` first.** A copied artefact outlives the
   decision that retired it, so the fleet has more retired names than kit does.

## Open questions (unresolved, deliberately — no human was asked)

- **Does the MAJOR tier need `MIGRATIONS.md` to be a template?** A service
  migrating between kit versions might want kit's migrations *for* kit's own
  upgrades. Untested either way; I scoped it out.
- **Is `invisible` honest for PATCH?** It means "take it without reading anything",
  which is a strong claim about a repo whose check count changed from 99 to 104 in
  one packet. Defensible (a gate is not an interface), but a stricter reading would
  make PATCH mean "no change to any template a service copies" — which is
  *measurable* (`tests/staleness.py` already knows) and is a plausible successor.
- **What is the MAJOR bump for?** 1.0.0 was free; the next one has to be earned.
  Nothing in this packet reserves it.

## Where to look

| What | Where |
| --- | --- |
| the derivation + its table | `tests/validate.sh`, `stability_tier` / `stability_tier_table_check` |
| the gate | `tests/validate.sh`, `stability_gate_check` |
| the tombstone check | `tests/validate.sh`, `reserved_check` |
| the five breakages | `tests/self_test.sh`, 96-100 |
| the two decisions | `DECISIONS.md` MD26, MD27 |
| the consumer-facing answer | `README.md` top, and `CHANGELOG.md` 1.0.0 |