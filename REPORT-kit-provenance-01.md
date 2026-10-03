# REPORT — kit-provenance-01

**For someone who has not seen the packet.** Today the fleet moved every
end-to-end tier onto images *pulled* from a registry instead of rebuilt from a
sibling checkout. That was correct, and it left a hole: a tag is a mutable name,
so an image pulled as `:e2e` cannot say which commit is inside it. A consumer
that pulls cannot tell whether the bytes contain the fix merged five minutes ago
or the one before it. This packet stamps the artifact so it can answer *what am
I*, and makes the stamp checkable rather than decorative.

**Outcome: the mechanism shipped and the gate is green. Two things were not
finished — the per-service consumer wiring and a `self_test` breakage.** Both are
named below with the exact next move.

---

## 1. What the stamp says

Five fields, three of them standard OCI keys so a tool that knows nothing about
cafaye reads them:

| field | label | grammar |
| --- | --- | --- |
| source | `org.opencontainers.image.source` | `owner/repo`, lowercase, **exactly one `/`** |
| revision | `org.opencontainers.image.revision` | 40 lowercase hex, or `unknown` |
| built_at | `org.opencontainers.image.created` | RFC3339 UTC to the second, or `unknown` |
| source_dirty | `com.cafaye.kit.source.dirty` | `clean` / `dirty` / `unknown` — a flag |
| template_version | `com.cafaye.kit.template.version` | `vN.N.N`, or `unknown` |

Measured on a real image built from the real `docker/Dockerfile.go`:

```
$ docker image inspect stampprobe:go --format '{{json .Config.Labels}}'
{"com.cafaye.kit.source.dirty":"clean",
 "com.cafaye.kit.template.version":"v0.1.0",
 "org.opencontainers.image.created":"2026-10-03T09:20:00Z",
 "org.opencontainers.image.revision":"0123456789abcdef0123456789abcdef01234567",
 "org.opencontainers.image.source":"cafaye/identity"}
```

It lands in **two** sinks, because one of them alone does not answer the
question:

- **OCI labels** — readable by whoever pulls, with `docker image inspect`, the
  tool every consumer in this fleet already runs.
- **`/app/kit-provenance.json`** — readable by *the running process*, which
  cannot reach the image config (no docker socket, no CLI). This is not
  decoration: `docker/entrypoint.sh` prints the revision at boot, and it is the
  only reason that line can exist. `tests/provenance_test.sh` asserts the two
  sinks agree field for field, so the file cannot become a second, hand-editable
  lie.

## 2. Why labels, against the three alternatives

The packet said to find out whether the obvious answer is the right one.

- **The buildx provenance attestation is already on** (`provenance: mode=max` in
  `image.reusable.yml`) and is the **wrong answer for a consumer**. Reading one
  is `docker buildx imagetools inspect` / `docker attestation verify`, both of
  which fetch a *referrer* from the registry over the network — and the e2e tier
  pulls from a plain-HTTP registry on `localhost:16010`. Decisive: the e2e
  artifacts are pushed by `bin/e2e-stack publish-siblings` with a bare `docker
  build`, which never runs that workflow, so an attestation is **absent exactly
  where this packet needs it**. Kept on; it answers a different question.
- **An OCI annotation on the manifest list** — same reachability problem, and
  worse: annotations sit on the *index*, not the per-platform config, so
  `docker image inspect` never shows them at all.
- **A manifest beside the image** — rejected outright. It joins two
  independently mutable things, so "the registry and the source disagree"
  becomes a state you cannot detect. The whole point is that the stamp must be
  **able to disagree visibly**.
- **Labels** — the only sink both readable by the consumer and impossible to
  forget, because they live in the Dockerfile that *every* build path goes
  through. A stamp that depends on remembering to pass a flag is absent exactly
  when someone is in a hurry.

Cost, stated: labels are metadata, so a `--no-cache` rebuild changes them. So
does any other stamp.

## 3. What it deliberately refuses to say — and the one shape it cannot

Redaction is a **closed grammar, not a denylist**. A value may be stamped *iff*
it matches the exact shape of the field it is going into. There is no escape
hatch and no way to add a field without writing its shape, which is what makes
this structural rather than a list the next contributor has to remember to
extend. Eleven shapes are asserted refused, each **by name**, against a green
control so a stamper that refused everything would not pass:

an email · an absolute local path · a relative path · an internal hostname with
a port · a full URL · a credential · a branch where a commit is claimed · a short
sha · uppercase hex · a dirty **file list** · a non-RFC3339 timestamp

`source` admits **exactly one `/`**. That single character budget is what makes
`owner/repo` expressible and every path, URL and hostname inexpressible; the host
is not merely omitted from the format but structurally absent from it.

**The shape no grammar can refuse, stated rather than papered over:** a branch
name in `source`. `owner/branch` is shape-identical to `owner/repo`, so no regex
separates them, and a comment claiming otherwise would have read as coverage and
been nothing. It *is* refused in every other field. It is also not a leak — the
registry already publishes that exact string as a tag (`type=ref,event=branch`)
to exactly the population that can read the stamp. So the rule is not "no secret
is stamped" but the sharper one: **nothing is stamped that the registry reader
did not already have.** The suite asserts this asymmetry holds; if it ever
became false, the failure message says to rewrite the header rather than widen
the grammar.

Also deliberately absent, each of which was tempting: the dirty **file list** (a
developer's working directory), the branch, the builder's hostname (a laptop on
the e2e path), and a software version (kit's own header already argues a release
tag is a decision, not an output).

## 4. What now fails that did not

`docker/provenance.sh --verify IMAGE [--expect-revision SHA]` — the consumer
side, and the reason a stamp is not a label on a picture:

| exit | meaning |
| --- | --- |
| 0 | the pulled image is the expected commit |
| **5** | it is a **different commit** — the tag is a mutable name |
| **4** | it carries **no labels at all** — built before the stamp existed |
| 5 | it is stamped `unknown` and an expectation was given |

Two codes for two failures because one code cannot tell a consumer which
happened. And the asymmetry is the design: **an unstamped build is fine to
*create* and not fine to *assert about*** — `unknown` is accepted at build time
(so a developer's local `docker build` is not refused) and refused by `--verify`.

Proved red, not asserted: all four rows were run against real images.

## 5. How it went red during this work, and what that cost

Three defects the *measurements* caught and a comment would not have:

1. **`LABEL ${VAR}` does not work.** Buildkit does not word-split an expansion
   in a `LABEL`, so it fails `LABEL must have two arguments`. The obvious
   one-ARG-one-LABEL spelling — which is what a reader would write from the docs
   — does not build. That is why there are five ARGs.
2. **My own `--expect-revision` flag was parsed positionally**, so it compared
   the revision against the literal string `--expect-revision` and reported a
   mismatch on an image that was correct. A check whose flag parsing is wrong
   fails in the direction that *looks like* the bug it was written to catch.
3. **Two extraction bugs in the agreement check** reported all seven Dockerfiles
   broken when they were fine: a pattern anchored at line start misses the first
   key of a multi-line `LABEL` (it sits after the keyword), and BSD `sed` has no
   `\|` alternation so it matched nothing at all. **Identical failures across
   seven inputs is the signature of the check being wrong, not the tree.**

Two shellcheck warnings in the new suite (unused variables) were fixed, not
silenced.

## 6. What I did not finish

- **The per-service consumer wiring.** `parlor/bin/e2e-stack` and
  `site/bin/e2e-stack` print what they pulled, and the packet wants the stamp
  visible there. kit cannot commit to those repositories, and editing a sibling
  checkout I cannot commit to is worse than not doing it. The change is two
  lines and is written out in `HANDOFF-kit-provenance-01.md`.
- **A `self_test` breakage (would be 80).** kit's convention is that every new
  check gets a recipe that breaks a throwaway copy and asserts the gate goes red.
  `provenance_test.sh` carries its own red proofs (exit 5, exit 4), which
  satisfies the packet's "prove it goes red on a wrong commit" literally — but
  the *repo's* convention wants a recipe too, and I was over budget rather than
  finished. The exact recipe is in the handoff. **Do not add it without running
  it:** an unexecuted recipe is a proof of nothing, and this file's own header
  says so.

## 7. Open questions

- **Should `template_version` be a workflow input or derived?** It is an input
  (`kit-version`, empty → `unknown`) because kit is deliberately not an org-wide
  lockfile. But that means a service can stamp a version that does not match the
  templates it actually copied, and nothing catches it — the grammar refuses a
  malformed version, not an *inaccurate* one. `caf.lock` already pins template
  bytes; making this field agree with it is the natural follow-up and is a real
  check, not a nicety.
- **Should `source` carry the host?** It deliberately cannot. The cost is that
  an image built from a self-hosted git remote is stamped `owner/repo` with no
  way to tell *which* host — true today, since the fleet is one GitHub org, and
  a real gap the moment it is not.
- **Pins vs stamps.** `caf lock` already sha256-pins specs, schemas, clients and
  rule bundles. The stamp does not duplicate that and does not contradict it: it
  answers *which commit*, the lockfile answers *which bytes of a dependency*.
  Worth a sentence in `DECISIONS.md` that has not been written.