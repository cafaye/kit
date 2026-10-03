# REPORT — kit-stability-01

**Repo:** `cafaye/kit` · **Branch:** `worker/kit-stability-01` · **Base:** `0b0ec67`
**Commits:** `8e27051`, `6da6a08`, `edb5801`

**The packet in one line:** make the version string the single source of truth for
how safe a release is to consume, derive the breaking-change tiers from it rather
than asserting them, gate on it so the promise is checkable, and work out what the
two references mean by `reserved` tombstones.

---

## The rule I derived, and why

`VERSION` is one line, one number, and the **only** place kit's version is
written. Three tiers are **derived** from two version strings by one function
(`stability_tier` in `tests/validate.sh`), asserted against a published table of
ten pairs, so a change to the rule that is not a change to the table is a red gate.

| the bump | the tier | what a consumer may do |
| --- | --- | --- |
| MAJOR | `breaking` | read `MIGRATIONS.md` for that version |
| MINOR | `additive` | take it; nothing a consumer holds went away |
| PATCH | `invisible` | take it without reading anything |

**Why three tiers and not four.** The rule of thumb from the reference is that
the number you do not have to read is the size of the promise, so the tiers have
to be the three sizes of change there are. A fourth would be a claim about
something kit cannot observe — the difference between "invisible" and "safe" is a
difference about the *consumer's* code.

**Why not the existing boolean.** cafaye's one `breaking: true|false` answers
"did anything break?" with one bit, so it cannot say *which surface* broke, so a
consumer still opens the diff. That is the argument P1-7 makes for
`SOURCE`/`JSON`/`WIRE` over a boolean, and it applies here unchanged: **a single
bit cannot express a tier because a tier is more than a bit.** The tier is derived
from the number the consumer already holds, which is the property that makes it
checkable at all.

**Where the source of truth lives, and why not `cafaye.yml`.** The packet asked.
`caf` owns the manifest, so this was worth checking rather than assuming:
`identity/cafaye.yml` says in its own comments that it *deliberately* carries no
`version` key and that a second version number in the file is a footgun. Nine
services carry no version, and the ones that do (`guard`, `muse`, `cafaye-rb`)
mean it as *"the dependency's own contract version"* — a different question from
"how safe is kit to take". So the two numbers stay in different files, and
`VERSION` is the one that carries the promise.

**Why `1.0.0` and not `0.x`.** In semver `0.x` *means* "unstable, anything may
change" — the exact sentence this removes. A version a consumer must re-read the
meaning of is not a source of truth. This is not a decision about what kit's
version *should* be; it is the only base case from which "a MAJOR means something"
is true.

**Why the derivation refuses some strings instead of guessing.** `1.0.0-rc1`
(a prerelease suffix makes the tier change meaning when the suffix is dropped, so
the string stops carrying its own promise), `v1.4.0` (`v` is the *tag* spelling —
`kit.ref` accepts `v<semver>` — so a `v` here means somebody pasted a tag where
the version goes), `01.4.0` (one string, two numbers), a two-component string, and
a backwards move. All fail closed. A string the function cannot place must not be
given a tier, because a tier that is a guess is the fail-open direction.

## The gate, which is the part that earns it

`stability_gate_check` is a check, not a paragraph. What each tier **owes** is a
file the check reads:

- **`### Breaking` is legal only under a version whose MAJOR actually moved**, and
  never under `## Unreleased`, where no version covers it. **This rule needs no
  predecessor**, so it holds for the whole history rather than only for the bump
  being released — which is what turns the promise from documented into checkable.
- **A MAJOR owes a `MIGRATIONS.md` section.** A consumer who adopted kit by copy
  cannot apply a sentence; the migration is the only artefact that can tell them
  what to change.
- **`VERSION` has a changelog section**, sections descend, and the top one is the
  version — otherwise the version is written down in two places and can disagree.
- **The changelog and `VERSION` must agree**, which is the same rule the licence
  check uses (agreement, not presence).

## The `reserved` finding: the two references are NOT the same thing

This is the part of the packet that turned out to be a finding rather than a
merge, and it is written up as MD27.

- **buf's `reserved: 3, 7;` is a WIRE tombstone.** The field *number* is what
  travels in the bytes, so a retired number may never be reused — otherwise an old
  message and a new one decode the same bytes into two meanings. Its purpose is to
  make DELETION non-breaking.
- **Kubernetes' `+k8s:deprecated=width,protobuf=3` is a LIFECYCLE marker on a
  field that is still there.** k8s does not delete an API; it deprecates, names
  the replacement and the version, and leaves the type in place.

**kit has no encoding, so buf's justification does not transfer** — there is no
byte whose meaning a reused name would corrupt. What transfers is the weaker half
both references enforce, which is the half that actually matters here (services
adopt by copy, so a copy outlives the decision): **a retired name stays retired.**

**The deprecation half does not port either**, for two reasons: a comment in a
copied YAML file is a comment in the copy — the adopter's file never learns it —
and kit has no registry a deprecation could live in, since an artefact is fetched
by ref or copied by hand. `templates/parity-allowlist` already carries that half.

`RESERVED` is therefore in the `skip-allowlist` dialect (same four rules, same
words, one entry per line) with **the fourth hygiene rule INVERTED**: in a skip
allowlist an entry matching nothing is a ratchet that only turns one way; for a
tombstone the dead entry and the live name are one defect with two names, so
`reserved_check` fails when a reserved path **exists**. Two entries, both from
kit-20's withdrawn backup distribution.

## What now fails that did not

Five breakages (96-100), each naming one check and mutating one thing, each run
by hand against a throwaway copy *before* being committed:

| # | what it breaks | caught by |
| --- | --- | --- |
| 96 | a MAJOR bump ships without the `MIGRATIONS.md` the tier owes | `stability gate` |
| 97 | a MINOR bump declares a `### Breaking` change | `stability gate` |
| 98 | a `### Breaking` heading sits under `## Unreleased` | `stability gate` |
| 99 | `VERSION` is `1.0.0-rc1`, a string the derivation refuses | `stability gate` |
| 100 | a reserved name is back in the tree | `reserved tombstones` |

Plus the tier table itself: ten version pairs asserted, so a loosened derivation
is a red gate rather than a prose drift.

**A defect the breakages found in my own check, measured rather than argued.** The
first version read its predecessor from `git show HEAD:VERSION`. That resolves to
**nothing** in a throwaway copy, so breakages 96 and 97 derived `initial` and
stayed **green**. A gate whose verdict depends on a `.git` sitting beside it
verifies nothing on the machines that consume kit the way services do — an
unpacked tarball, a release rehearsal, a vendored copy. The predecessor now comes
from the changelog section below the current one, which is a version a consumer can
*see*, and therefore the same fact the promise is about. It is recorded in MD26 and
in `AGENTS.md` rather than quietly corrected.

## Verification

- `bash tests/validate.sh --static-only` — **PASS: every check passed** (234 PASS,
  0 FAIL) at every commit.
- `tests/self_test.sh` shards `1/8`, `2/8`, `3/8`, `4/8`, `8/8`, run **sequentially**
  (the docker-sharing rule). Each reported `EXIT=0`, and each of 96, 97, 98, 99,
  100 was reported `PASS … caught by` its named check.

## What I did NOT finish

- **The fleet-wide rollout.** This is the mechanism, demonstrated on kit itself,
  as scoped. Thirteen of fifteen repositories have no version at all.
- **The three-tier `SOURCE`/`JSON`/`WIRE` split (P1-7's other half).** P1-7 has two
  claims; I took the classification one (three tiers instead of one boolean) and
  did not take the per-surface one. That is a change to how a *service's* breaking
  surface is classified, which needs the contract schemas to exist first.
- **No `MIGRATIONS.md` yet**, because kit has made no MAJOR bump. The gate will
  demand one on the first one.
- **The version bump is not automated.** Nothing checks that `VERSION` matches a
  git tag at release time. That belongs in `core/release/release.yml`.