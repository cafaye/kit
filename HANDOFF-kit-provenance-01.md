# HANDOFF — kit-provenance-01

**Branch** `worker/kit-provenance-01` · **base** `0b0ec67` · four commits ·
gate green (`bash tests/validate.sh --static-only` → `PASS: every check passed`,
zero FAIL, `tests/provenance_test.sh` 32/32).

The full argument is in `REPORT-kit-provenance-01.md`. This file is the
successor's first move.

---

## Commits, in order

| | what it is |
| --- | --- |
| `8778987` | `docker/provenance.sh` — the field list, the grammar of each field, the serialization. The redaction rule as code. |
| `9629d12` | the two sinks in all seven `docker/Dockerfile.<lang>`, and `--verify`. Includes the `LABEL ${VAR}` and flag-parsing findings. |
| `5e0206f` | `tests/provenance_test.sh` (32 assertions), wired into `validate.sh`'s static phase; the producer in `image.reusable.yml`; one line in `entrypoint.sh`. |

## The one-paragraph version

A tag is a mutable name, so a pulled `:e2e` image cannot say which commit is in
it. `docker/provenance.sh` stamps five fields into all seven Dockerfile
templates as **OCI labels plus a JSON file in the image** — labels because
`docker image inspect` reads them off a *pulled* image with the tool the fleet
already runs, the file because a running process cannot reach the image config.
Not the attestation (`image.reusable.yml` already sets one) because reading it
fetches a referrer over the network and the e2e artifacts are pushed by a bare
`docker build` that never runs that workflow. Not a side manifest, because a
join between two mutable things cannot make a disagreement visible. Redaction is
a **closed grammar, not a denylist**: a value may be stamped iff it matches its
field's exact shape, and `source` admits exactly one `/`.

---

## FIRST MOVE — the consumer wiring (two lines, in two repos)

This is the smallest unfinished thing and it is the packet's item 2. In
`parlor/bin/e2e-stack` and `site/bin/e2e-stack`, in the function that reports
what was pulled, add:

```sh
# What am I? The stamp a pulled image carries — see docker/provenance.sh.
sh "$ROOT/docker/provenance.sh" --verify "$image" || true
```

`|| true` **only** on the printing form. The asserting form is the one that
matters and it must NOT be tolerant:

```sh
sh "$ROOT/docker/provenance.sh" --verify "$image" --expect-revision "$EXPECTED_SHA"
```

kit ships the script; each repo copies it beside `entrypoint.sh`
(`cp <kit>/docker/provenance.sh docker/provenance.sh`). `parlor/bin/e2e-stack`
already has `publish-siblings` printing a `RepoDigests` line — that is the
natural place, and `docker/provenance.sh --verify` supersedes it rather than
sitting next to it.

**The trap worth naming:** `--verify` exits 4 on an image with *no* labels, so
the first run against a sibling image built before this stamp will be red. That
is correct and it is the point — but decide whether the e2e tier asserts or only
prints, and write the answer down. "Prints and always continues" is a legitimate
answer (it surfaces the drift without blocking a tier on a rebuild race); it is
a decision, not a default.

## SECOND MOVE — the `self_test` breakage (would be 80)

kit requires every new check to have a recipe that breaks a throwaway copy and
asserts `validate.sh` goes red. **Do not add it without running it** — an
unexecuted recipe is a proof of nothing, which this repo's own header says.

Follow breakage 75's shape (`sed -n '3976,3980p' tests/self_test.sh`): a
`fresh_copy` dir, mutate, `expect_red_check <label> <dir> 'tests/provenance_test.sh'
--static-only`. The mutation to use is the interesting one — **widen
`shape_source` in `docker/provenance.sh` to accept anything**
(`shape_source() { return 0; }`), which must make the redaction cases go red.
That is the mutation that proves the *security* claim is load-bearing rather than
the file merely existing. A weaker and less useful mutation is deleting a
`LABEL` line from `docker/Dockerfile.go`, which only proves the agreement check
sees a missing label.

Then add the matching entry to `self_test.sh`'s header (there is a check that
fails when the header documents a breakage no recipe carries) and update the two
counts `AGENTS.md` states.

---

## Things that will waste your time if you do not know them

- **`LABEL ${VAR}` does not work.** Buildkit does not word-split an expansion
  there; it fails `LABEL must have two arguments`. Measured. This is why the
  block has five ARGs, and it is the single most likely thing a successor will
  "simplify" back into one.
- **BSD `sed` has no `\|` alternation.** It silently matches nothing, which reads
  as "every Dockerfile is broken". The extraction in `provenance_test.sh` uses
  `grep -oE` for this reason. If seven languages fail *identically*, suspect the
  check before the tree.
- **The first key of a multi-line `LABEL` sits after the `LABEL ` keyword**, so
  any extraction anchored at line start reads four keys and reports five missing.
- **`docker build -f docker/Dockerfile` resolved against the wrong thing** on this
  box and read a 2-byte file. Use an absolute `-f` path. The test does.
- **`tests/provenance_test.sh` needs docker for part C only**, and SKIPs loudly
  without it. Parts A (the eleven refusals) and B (the three-way agreement) are
  pure text in / exit status out, deliberately: a security claim whose coverage
  depends on whether docker happens to be installed is a claim about the machine.
  The check sits **outside** the `RUN_STATIC` guard for the same reason.

## Open questions (resolve, do not ask)

1. **`template_version` can be stamped inaccurately.** The grammar refuses a
   *malformed* version, not a wrong one, and it is a workflow input because kit
   is not an org-wide lockfile. `caf.lock` already pins template bytes — making
   this field agree with it is the real follow-up.
2. **`source` carries no host**, deliberately, so an image from a self-hosted git
   remote is indistinguishable from GitHub's. True today, a real gap the moment
   the fleet is not one GitHub org.
3. **`DECISIONS.md` has no entry** for how the stamp relates to `caf.lock`. The
   report argues they do not contradict each other (stamp = which commit,
   lockfile = which dependency bytes) and that argument belongs in the file.

## Not done, deliberately

- **No edit to any `parlor/` or `site/` checkout.** kit cannot commit to those
  repositories and an uncommittedable edit is worse than none. The change is
  written out above.
- **No `templates/` copy of `provenance.sh`.** It belongs in `docker/` beside
  `entrypoint.sh`, which is where the sibling already lives and where a service
  copies it from. Adding a second copy site would create two things to keep in
  step.
- **`AGENTS.md` not updated.** It should gain a rule in the Secrets section
  ("a stamped value must be the shape of its field") once the recipe lands, so
  the rule and its proof land together.