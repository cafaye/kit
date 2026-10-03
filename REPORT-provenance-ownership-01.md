# REPORT — provenance-ownership-01

**Branch** `worker/provenance-ownership-01` · **base** `b72a3c2` · three commits.

The packet asked for two distinct defects to be fixed and both of them were
real. This report is the measurement; the reasoning that could not be measured
is in `HANDOFF-provenance-ownership-01.md`.

---

## The bar, and the one command that clears it

```console
$ sh docker/provenance.sh --verify cafaye/guard:e2e ; echo "EXIT=$?"
provenance: cafaye/guard:e2e
  source:           https://github.com/oven-sh/bun
  revision:         700fc117a2fd01ac0201deaa6fa69c5557acb04f
  built_at:         2026-04-10T03:06:38.682Z
  source_dirty:     <absent>
  template_version: <absent>
kit-provenance: FAIL cafaye/guard:e2e carries labels, and they are not a cafaye provenance stamp.
kit-provenance:   source           = "https://github.com/oven-sh/bun" — it must be owner/repo, or "unknown" (lowercase, exactly one "/", no scheme, no host, no port)
kit-provenance:   built_at         = "2026-04-10T03:06:38.682Z" — it must be RFC3339 UTC to the second (YYYY-MM-DDTHH:MM:SSZ), or "unknown"
kit-provenance:   org.opencontainers.image.* are STANDARD OCI labels that every base image sets,
kit-provenance:   and an image built FROM a stamped one INHERITS them. This stamp names "https://github.com/oven-sh/bun",
kit-provenance:   which is not us. A verifier a third party's labels can satisfy is not a verifier.
EXIT=6
```

Before this branch: `EXIT=0`, and the five label lines were identical. The
labels did not change. **What changed is that the verifier now has an opinion
about them**, and the opinion names Bun.

---

## Defect (a): no shape validation on the verify path

`emit_verify` read the five labels with `sed`, printed them, and then reached:

```sh
[ -n "$expect_rev" ] || return 0
```

so with no `--expect-revision` it returned 0 for whatever the labels said.
`shape_source` and its three siblings — each with a documented grammar and an
`expect_*` line for the failure message — were reachable only from `validate`,
the **authoring** path. The value printed violated the script's own `source`
grammar in five separate ways.

`--verify` now runs the same `shape_*` functions over the extracted values.
There is no second grammar in the file, deliberately: a redaction rule that
exists only at stamp time is a rule about the moment of writing, and a pulled
image never passes through that moment.

## Defect (b): "are there labels?" rather than "are these labels ours?"

This is the security half, and the general fix is a default-on ownership check
plus an opt-in repository assertion.

**Ownership by namespace, always asked, needs no flag.** `org.opencontainers.
image.*` is the standard half of the format; `com.cafaye.kit.*` is kit's own,
and a base image cannot supply it by accident. Absence of the kit namespace is
evidence of non-authorship — the negative claim a label format can actually
support, and the one that catches inheritance.

The limit is stated in the source rather than glossed: **presence is evidence of
nothing in particular.** Anyone who wants to forge a label can. The defect here
is *inheritance*, and inheritance cannot supply a private namespace.

**`--expect-source owner/repo`, mirroring `--expect-revision`.** Given, it is an
assertion; a mismatch is exit 5. This is the only thing that catches a
**well-formed** foreign source — `oven-sh/bun` is two clean lowercase segments
with exactly one slash and passes every grammar in the file.

---

## The overrule, and why

The packet recommended that an absent `--expect-source` **fail** loudly rather
than pass silently. **I overrule that, and warn instead**, because of exit-code
cost rather than taste:

`HANDOFF-kit-provenance-01`'s FIRST MOVE tells services to write
`provenance.sh --verify IMG || true` in `parlor/bin/e2e-stack` and
`site/bin/e2e-stack`. A mandatory new failure there prints a FAIL and
continues — on images that are fine — and **teaches a reader that the line is
noise**. A check that cries wolf on a green tree is not obeyed on a red one.

The concern behind the recommendation is not lost, only made impossible to
ignore:

- the **namespace half fails the run with no flag at all**, so the silent
  default that *is* the defect is closed;
- the warning is not a log line. It names the source, says in words that
  repository ownership **was not established**, and names the flag that
  establishes it:
  ```console
  $ sh docker/provenance.sh --verify kit-owns-proof:ours ; echo "EXIT=$?"
  ...
  kit-provenance: WARN no --expect-source was given, so OWNERSHIP OF THE REPOSITORY WAS NOT ESTABLISHED.
  kit-provenance:      the source reads "cafaye/guard", and every grammar in this file accepts it. Only
  kit-provenance:      --expect-source owner/repo turns "it is shaped like ours" into "it IS ours".
  EXIT=0
  ```
- `verify_says` in part D takes the **exit code as a parameter** precisely so
  this warning is assertable. A helper that hardcoded "non-zero" would have made
  the most important warning in the packet unassertable, which is how a warning
  becomes decorative.

## What an absent field means — decided, not inherited

| field | absent on `--verify` | why |
| --- | --- | --- |
| `source`, `revision` | **FAILURE**, exit 6 | identity; the two a caller can `--expect` |
| `built_at`, `source_dirty`, `template_version` | **NOTE**, exit unchanged | metadata, not identity |

Absent and `unknown` mean the same thing to a reader — *nobody told me* — and
the script already calls `unknown` "the honest 'I do not know what this is'"
and already fails it in an assertion. Accepting one while failing the other has
no defensible basis. The other three are notes because refusing an image for
predating `template_version` is refusing it for being **old**, which is what
exit 4 already says, and says better.

`source_dirty: <absent>` was printed and ignored for the whole life of the
packet. It is now said out loud on every run.

---

## The red proofs, measured

`measurement-provenance-ownership-01.out` is the transcript — five fixtures
built with `docker build`, every case run, every real exit code printed.

| | case | exit |
| --- | --- | --- |
| 1 | foreign but **well-formed** source + `--expect-source cafaye/guard` | **5** |
| 2 | source is a URL (over the one-slash budget) | **6** |
| 2 | source is `cafaye/guard/labels` (three segments) | **6** |
| 3 | correct stamp, matching `--expect-source` and `--expect-revision` | **0** |
| 3b | the same image, **no** `--expect-source` | **0** + `WARN` |
| 4 | unstamped fixture **and** real `cafaye/identity:e2e` | **4** |
| — | **the witness**, `cafaye/guard:e2e`, no flags | **6** |

Fixtures set their labels **directly** in a Dockerfile rather than through a kit
Dockerfile, because the authoring path already refuses a malformed value — a
fixture built through kit's own path could not produce the case.

### Exit 4 is preserved and is not collapsed into 6

`identity:e2e` (no labels) → 4. `guard:e2e` (someone else's labels) → 6. The
distinction is what a consumer needs: *this image is old* is a different
operational response from *this image's provenance is not ours*. The CHANGELOG
says so in those words.

---

## Two findings the packet did not anticipate

Both came from running the thing rather than reasoning about it.

**1. A grammar this file believed was wrong about a real published image.**
`built_at` also fails on `guard:e2e`, and not for the reason the packet gave.
Bun's OCI `created` is `2026-04-10T03:06:38.682Z` — **milliseconds** — and the
grammar is RFC3339-to-the-second, which is a deliberate choice. So the shape
check found something the packet did not predict, and it is a better
advertisement for the check than the case it was written for: a grammar kit had
held for the packet's whole life was refuted by a real image, and nothing could
have told it.

**2. Two more real images were green and were not named.** `cafaye/e2e-parlor:local`
and `cafaye/e2e-site:local` carry labels and **none** of the five:

```json
{"com.docker.compose.project":"parlor-e2e","com.docker.compose.service":"parlor","com.docker.compose.version":"5.1.2"}
```

So they are **not** exit 4 — they do carry labels — and under the old script they
exited **0** while printing five `<absent>` lines. **That is the most misleading
output the old script could produce:** it reads exactly like an unstamped image
and reports success. Both are now exit 6, naming the absent `source` and
`revision` as the refusal. Both are in the transcript, not just in this report.

---

## Why the existing suite could not see this

Every `--verify` case in part C of `tests/provenance_test.sh` builds an image
**from kit's own Dockerfile**. A foreign base image's labels are precisely the
labels kit's Dockerfile did not write, so no fixture part C could build would
have caught it. The suite was green on a script that printed a third party's
URL as our provenance.

**Part D stubs the label sink.** A `docker` on PATH answers `image inspect`
with canned JSON, so shape, ownership, the absent-field policy and the
exit-code separation are all executable with **no daemon and no build** — the
same rule parts A and B are under, applied to the half that had no coverage.
It is also the control part C needed: same script, same expectations, two
different sets of labels. 44 assertions, 0 failures, 0 skips.

### Three of my own assertions were wrong first

All three were the harness asking the wrong question and reporting a confident
answer — the same class as this repo's documented 64K-pipe defect:

- `verify_says` hardcoded "must be non-zero", which made the exit-0 ownership
  **warning unassertable**;
- `ec=$?` immediately after `out="$(...)"` reads the **assignment's** status,
  not the command's, so every exit code was 0;
- one needle was the wrong string.

The first two are now prevented by construction: the exit code is a parameter,
and `stub_verify` returns its code in a global rather than through `$(...)`.

---

## Coverage that can prove it is load-bearing

**Breakage 103**, above the shard summary (breakage 101 sat below it and no
shard ever claimed it, hiding an exit code). It deletes the
ownership-by-namespace block and nothing else: the script still parses, still
prints all five fields, and all eleven part A refusals still pass. A script with
one decision removed, not a script that broke.

The `HANDOFF-kit-provenance-01` SECOND MOVE asked for the `shape_source`
mutation; that claim is now carried by part A, so 103 takes the half that had
**no** proof at all — and could not, because until this packet `--verify` had
no ownership check to mutate.

One mutation, one cause. Deleting the shape loop would also red part A, so the
recipe would report red for a cause it did not introduce. Deleting the
`--expect-source` branch would leave D1/D2 **green**, because those cases carry
no `--expect-source`. Both are the trap this repo's header warns about: a
control satisfiable by two checks proves the gate can go red and says nothing
about either.

`tests/validate.sh`'s check label now names what the check covers. A label a
self-test asserts is a contract, and the old one said `--verify` "goes red on a
wrong commit" — true, and now the narrowest of four things it does.

---

## Not this packet

- **`parlor` and `site` are untouched.** Each carries a copy of this script and
  is mid-packet with the consumer wiring.
- **`identity` and `guard` still do not stamp themselves.** `identity:e2e` has
  `null` labels and `guard:e2e` has Bun's. Named precisely in the handoff; that
  is the next packet.
- **The `caf.lock` relation is still unwritten**, as the predecessor handoff's
  open question 3 recorded.