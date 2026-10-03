# HANDOFF — provenance-ownership-01

**Branch** `worker/provenance-ownership-01` · **base** `b72a3c2` · four commits.

| | what it is |
| --- | --- |
| `e57e589` | the fix. shape checks on the verify path, ownership by namespace, `--expect-source`, the absent-field policy, and the four exit verdicts |
| `2540726` | `measurement-provenance-ownership-01.out` — the red proofs as a transcript, plus part D of `tests/provenance_test.sh` |
| `b4e3e10` | the `CHANGELOG.md` entry, breakage 103, and the `validate.sh` check label |
| `b601aea` | `REPORT-provenance-ownership-01.md` |

---

## FIRST MOVE — the verifier is fixed; **the debt it exposed is not**

`sh docker/provenance.sh --verify cafaye/guard:e2e` no longer exits 0. It exits
**6** and names `oven-sh/bun` in two fields. That is the whole bar, and one
command clears it.

**But four images in this repository are now refused, and all four refusals are
correct.** This is the part a successor must not mistake for a regression:

| image | exit | what is actually true |
| --- | --- | --- |
| `cafaye/guard:e2e` | **6** | built `FROM oven/bun`; carries Bun's publisher labels and none of kit's |
| `cafaye/identity:e2e` | **4** | `null` labels; predates the stamp |
| `cafaye/e2e-parlor:local` | **6** | carries only `com.docker.compose.*`; **none** of the five fields |
| `cafaye/e2e-site:local` | **6** | carries only `com.docker.compose.*`; **none** of the five fields |

**The next packet is: make `identity` and `guard` stamp themselves.** That is
the precise debt, and it is now *visible* rather than latent, which is the whole
point of this one. Specifically:

- **`identity` needs a real stamp.** It has `null` labels. It is the one image
  still on exit 4, and once it carries the stamp it moves to 0 and the exit-4
  path has no image left in this repository exercising it except the fixture in
  `provenance_test.sh` part C. **That is a coverage hole opening**, and the fix
  is to keep the part C `plain` fixture — do not delete it when the real images
  stop needing it.
- **`guard` needs the same, and it is the interesting one** because it is the
  only image in the repository whose labels are *another project's*, which makes
  it the only live witness the defect has. A successor proving the verifier can
  fail should not throw that away; keep a fixture in `tests/provenance_test.sh`
  part D (`inherit`, the byte-for-byte label set of the real `guard:e2e`) as the
  standing witness, which is what it now is.
- **Both e2e-tier images are a third case worth naming:** `parlor` and `site`
  carry compose labels and no provenance at all, and they were exiting 0. Fixing
  them means their Dockerfiles need the five `LABEL`s, not just a stamp script.

---

## SECOND MOVE — copy the fixed script into `parlor` and `site`

**Deliberately not done here.** Each carries its own copy and both are
mid-packet with the consumer wiring. kit cannot commit to those repositories,
and an uncommittedable edit is worse than none.

When that copy happens, three things travel with it:

1. **`--expect-source` on the asserting form.** The predecessor handoff's FIRST
   MOVE wrote the printing form as
   `provenance.sh --verify "$image" || true`. That still exits 0 on a correctly
   stamped image and is unaffected. The **asserting** form should gain
   `--expect-source "<owner/repo>"`, because a well-formed foreign source passes
   shape and passes the namespace check if it was built from another cafaye
   image — the repository assertion is the only thing left that sees it.
2. **Expect a red first run.** All four images above are refused today. The
   predecessor handoff flagged exit 4 as the surprise; it is now **6** for three
   of them, which is the same class of surprise with a different number.
3. **Do not expect the e2e tier to go green** until the Dockerfiles stamp. A
   consumer wired to an unstamped image is a red build, and that is correct.

---

## What a successor should know before touching this script

- **The shape grammars are shared by construction.** `emit_verify` calls the
  same `shape_*` functions `validate` calls. Do not add a second grammar for the
  consumer side. A redaction rule that exists only at stamp time is a rule about
  the moment of writing, and a pulled image never passes through that moment.
- **The kit-namespace ownership check is the load-bearing half, not
  `--expect-source`.** `--expect-source` requires a caller to pass a flag;
  the namespace check fires with no flag at all, which is what closed the silent
  default the packet named. If you remove one, remove the flag — **not** the
  namespace check.
- **The ownership claim is the NEGATIVE one, and that is deliberate.** Absence
  of `com.cafaye.kit.*` is evidence of non-authorship. Presence is evidence of
  nothing in particular, because anyone can forge a label. The threat this
  defends against is *inheritance*, and inheritance cannot supply a private
  namespace. Do not upgrade the comment into a stronger claim.
- **Exit 4 and exit 6 must stay distinct.** Something upstream depends on telling
  "built before the stamp" from "carries somebody else's". Collapsing them into
  one code is not a simplification.
- **The `inheritshape` fixture is the only one that proves the ownership check.**
  Do not "simplify" it back into the real `guard:e2e` label set, which is a URL
  and therefore gets caught by shape first — that change silently un-proves
  breakage 103 while every assertion still passes. Measured, in
  `measurement-breakage-103.out`: the URL fixture leaves the suite GREEN on the
  ownership mutation. This is the trap `AGENTS.md` calls out, and this packet
  paid it rather than just citing it.
- **`verify_says` in part D takes the exit code as a parameter** because one
  assertion (D4) checks a warning at exit 0. Do not "simplify" that back to a
  hardcoded non-zero; it makes the ownership warning unassertable, which is how
  a warning becomes decorative.

---

## The three decisions recorded rather than argued

The packet said to decide, record the reason, and keep going. These three were
decided against a stated recommendation or a default, so they are here in full.

**1. Absent `--expect-source` warns rather than fails.** The packet recommended
a loud failure. Overruled on exit-code cost: the predecessor handoff's own FIRST
MOVE tells services to write `--verify IMG || true`, so a mandatory failure
there prints a FAIL on a good image and teaches a reader the line is noise. The
namespace half still fails with no flag, so the silent default is closed; the
warning names the source and says in words that repository ownership was not
established.

**2. An absent field is a failure for `source` and `revision`, a note for the
other three.** Absent and `unknown` mean the same thing to a reader, and the
script already fails `unknown` in an assertion — so accepting one while failing
the other has no defensible basis. `built_at`, `source_dirty` and
`template_version` carry metadata rather than identity, and refusing an image
for predating `template_version` is refusing it for being old, which is what
exit 4 already says.

**3. The namespace check requires AT LEAST ONE kit key, not both.** The question
is "did kit's build write this?", and one value in the private namespace answers
it. Requiring both would be a second copy of `tests/provenance_test.sh` part B's
five-key agreement check, and a check that is a copy of another check goes red
twice for one cause.

---

## Commands to re-run this yourself

```sh
sh docker/provenance.sh --verify cafaye/guard:e2e ; echo "EXIT=$?"   # 6, names oven-sh/bun
sh docker/provenance.sh --verify cafaye/identity:e2e ; echo "EXIT=$?"  # 4
bash tests/provenance_test.sh                                          # 44/44, part D needs no docker
KIT_SELF_TEST_SHARD=1/1 bash tests/self_test.sh                        # includes breakage 103
bash tests/validate.sh --static-only --only='tests/provenance_test.sh'  # PASS
```

Part D runs identically with no docker daemon, which is the point of it: the
security claim's coverage does not depend on the machine.

---

## TWO REDS A SUCCESSOR INHERITS, and only one of them is mine to fix

**`self_test` breakage 98 is RED and it is NOT this packet's.** Its anchor is
`## Unreleased\n\n### Added`, and that string has not existed since an earlier
packet replaced `### Added` with `### Changed` — verified **absent at the base
commit `b72a3c2`**, so this branch did not cause it. It reports as its own
distinct verdict (`the recipe no longer applies to its copy`) rather than as a
caught defect, which is the correct behaviour for a stale recipe, and it is
enforced by the suite rather than by anyone reading.

**Giving it a live anchor is a separate change** and was deliberately not done
here: editing a recipe for the version gate while landing a MAJOR bump would put
two unrelated claims in one commit, and the anchor's correct text depends on
which heading the next packet wants under `## Unreleased`. A successor should
pick an anchor that exists and is stable — `## Unreleased\n\n### Changed` is the
obvious candidate, since that is what the section is actually called now.

So a `self_test` run on this branch reports **1 red** until that happens, and
this report does not claim otherwise. Everything else holds.

---

## The version bump is a decision a manager may want to revisit

This packet bumped **VERSION 1.0.0 → 2.0.0** and created `MIGRATIONS.md`,
because a `### Breaking` heading under `## Unreleased` is a hard gate failure
and the gate's message says the fix is a MAJOR release. The change *is*
breaking by this repo's own definition: a consumer who copied the script into a
service repository gets a red result on an image that used to verify clean, and
kit is adopted **by copy**, so an old copy is an old verifier.

If the manager would rather version at merge time, the revert is mechanical and
the content is already written to be moved: put the section back under
`## Unreleased` and retitle the heading something other than `### Breaking`.
**Do not do both** — the gate refuses `### Breaking` there, and a `CHANGELOG.md`
that declares a breaking change under no version is a red build by design.

---

## Open questions (resolve, do not ask)

1. **`template_version` can still be stamped inaccurately** — carried forward
   from `HANDOFF-kit-provenance-01` and untouched here. The grammar refuses a
   malformed version, not a wrong one. `caf.lock` pins template bytes; making
   this field agree with it is still the real follow-up.
2. **`source` still carries no host**, so an image from a self-hosted git remote
   is indistinguishable from GitHub's. A true gap the moment the fleet is not one
   GitHub org, and the `--expect-source` assertion does not close it either.
3. **`DECISIONS.md` still has no entry** for how the stamp relates to
   `caf.lock`, three packets on. The report argues they do not contradict each
   other (stamp = which commit, lockfile = which dependency bytes) and that
   argument belongs in the file.
4. **The `built_at` millisecond finding is unresolved.** The grammar requires
   RFC3339-to-the-second and a real published base image emits milliseconds, so
   `--verify` on *any* image built from a stock base that stamps `created` will
   fail shape on a field kit does not even write — the third OCI key, inherited
   for the same reason `source` is. **The real fix is probably for
   `com.cafaye.kit.*` to become the only sink the verifier trusts**, with
   `org.opencontainers.image.*` read for display only. That is a format
   decision, not a patch, and it is why this is listed here rather than fixed.