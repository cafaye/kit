# REPORT — kit-04-secrets

**Packet:** kit-04-secrets · **Repo:** `kit` · **Branch:** `worker/kit-04`
**Gate:** `bash tests/validate.sh` → **exit 0** · **Before/after breakages: 18 → 29**

---

## 0. The gate command in the packet, and the one that was run

The packet's GATE says `mise x -- ./bin/prime`. **kit has no `bin/prime` and no
`bin/`** — it is a config-only repository with no service manifest, which is
exactly the `language: none` case that exists *because* kit is such a repository.
That command is the gate for a **service** repo; kit's own gate is the one its
`AGENTS.md` specifies and the one its CI runs:

```sh
bash tests/validate.sh
```

**Exit code 0.** Reported in `bash` with `${PIPESTATUS[0]}` as instructed, never
through a `zsh` pipe.

```
GATE_EXIT=0        bash tests/validate.sh
SELFTEST_EXIT=0    bash tests/self_test.sh
```

Baseline before any edit, same command, same machine: `GATE_EXIT=0` with **18**
breakages, 19 `PASS self_test` lines (18 breakages + the unbroken-tree control).

---

## 1. What each check is, and its red proof

Every row below was watched fail before the thing it checks existed. "Red proof"
is the `self_test` breakage number, or a demonstration with the failure text
quoted, where the packet's R6 authorised exactly one new self-test breakage for
the scanner and the remaining proofs live inside the canary suite.

### 1.1 The secret scanner

| Check (as the gate prints it) | What it asserts | Red proof |
|---|---|---|
| `.gitleaks.toml  (allowlist only, every entry reasoned)` | `extend.useDefault = true`; no `[[rules]]`; every `[[allowlists]]` entry has a `description` of ≥ 40 chars **and** names something to allowlist | see §4 |
| `no .gitleaksignore  (the allowlist is the committed config)` | no inline allowlist file anywhere in the tree | see §4 |
| `tests/gitleaks_gate.sh  (finds a real secret, never prints it, reads history)` | **executed** over a throwaway git repo holding a detectable credential: exits non-zero, names the rule, does not print the value, and still finds it after the file is deleted | **13, 14, 15, 16** |
| `gitleaks  (8.30.1, full history, --redact)` | the real scan of this repository's real history | 13, 14 |
| `.github/workflows/*  (no dangerous trigger, on parsed keys)` | no `pull_request_target` / `workflow_run` / `issue_comment`, read off parsed trigger **keys** | **17** |
| `.github/zizmor.yml  (unpinned-uses recorded, never baselined)` | `unpinned-uses` is not disabled or ignored; no blanket `ignore: "*"` | **23** |
| `.github/zizmor.yml  (every ignore entry carries a reason)` | every ignore item has a reason in an adjacent comment | see §4 |
| `ci.reusable.yml  (secrets job: not advisory, full history, not opt-in)` | the job exists; no `continue-on-error` at job or step; `fetch-depth: 0`; calls the shared script; no `if: always()`; no `inputs.*` gate; and **no `secrets` input exists** | **18** |

**Two of these are behavioural, and that is deliberate.** The first version
asserted `--redact` with a `grep` over the scan script. `self_test` breakage 15
removed the flag, and the check stayed green — because the script's own comment
reads `#   - --redact, always, not optionally.`, and a `grep -- --redact` is
satisfied by the sentence explaining that the flag is mandatory. The check now
runs the scan and reads its output.

### 1.2 The canary harness — five vectors, five red proofs

Each vector runs **twice** in one test: against `internal/safe` (must be clean)
and against `internal/leaky` (must be **red**). The second half is what makes the
first half mean anything.

| Vector | Detector | Red proof | Where the leak was found |
|---|---|---|---|
| 0 — canary safety | `TestCanaryIsSafe` | reads the template's own sources for the assembled literal | `canary_test.go:99` |
| 1 — canary in output | `SweepOutput`, `SweepSinks` | `internal/leaky.Session` printed with `%+v` | `canary_test.go:212` — **found the reference type's own first design** |
| 2 — unknown field | `SweepSerialised` | `leaky.Session` marshals the token under an undeclared key | `canary_test.go:257` |
| 3 — stringified error | `SweepErrorChain` | `leaky.AuthFailure`, leaking at **depth 1 of a 3-error chain** | `canary_test.go:294` |
| 4 — absent field | `SweepSerialised` | `leaky.MintedSession` marshals an **empty** `token` key | `canary_test.go:341` — **found a real hole in the detector** |
| 5 — Go type coverage | `TypeCoverage` | `leaky.PrintableSession.String()` | `typecover_test.go:88` |

Plus four self_test breakages that break the **safe** reference type in the four
ways that turn it into the leaky one — **19, 20, 21, 22**.

The full red-proof output, from `go test -v`:

```
canary_test.go:212:  RED PROOF vector 1 (canary): no log record, no stdout, no stderr:
                    fired on the stdout sweep and the log-sink sweep
canary_test.go:257:  RED PROOF vector 2 (unknown-field): no unrecognised key carries
                    the value: fired, and named the undeclared key "Token.Value"
canary_test.go:294:  RED PROOF vector 3 (stringified-error): no format verb, at any
                    depth of the chain: fired at depth 1 of a 3-error chain
                    (14 of the format verbs leaked)
canary_test.go:341:  RED PROOF vector 4 (absent-field): no credential-named key
                    marshalled at all: fired on the empty `token` key ([token])
                    while the safe type emitted none
typecover_test.go:88: RED PROOF vector 5 (type-coverage): fired on
                    "internal/leaky/creds.go:68:1: PrintableSession declares String()
                    while holding a credential type"; a secret type with its own
                    String() was correctly not flagged
```

### 1.3 The gate check for the canary itself

| Check | What it asserts | Red proof |
|---|---|---|
| `templates/secrets  (contract names all five vectors, states its limits)` | the contract exists, names all five vectors, states the prefix and the assemble-at-run-time property, and says what it does **not** cover | §4 |
| `the canary  (never committed as a literal, anywhere)` | walks the whole tree for the assembled 46-byte value | **22** |
| `the canary  (unmistakably fake: prefixed, low-entropy, self-describing)` | prefix, length, and body == the repeated word | §4 |

---

## 2. The exact remediation text a failing check prints

Verbatim, so a reader who hits one of these knows what to do.

### `gitleaks` finds something

```
FAIL gitleaks  (8.30.1, full history, --redact)
       5:41PM INF 33 commits scanned.
       5:41PM WRN leaks found: 4
```

**Remediation text is not in the failure line, deliberately.** gitleaks'
`--redact` means the finding names the file, the line and the rule but not the
value, so the message is the rule and the location:

```
Finding:     REDACTED
Secret:      REDACTED
RuleID:      gitlab-pat
File:        config/deploy.toml
Line:        12
```

**What to do, in order:**
1. **Treat it as compromised. Rotate it.** A scanner finding a secret is not a
   plan for it, and nothing below substitutes for rotation.
2. If it is still in the working tree: remove it in this commit. The scanner
   reads history too, so the next run will still be red — which is correct.
3. If it is a false positive, add **one** entry to `.gitleaks.toml`:

```toml
[[allowlists]]
description = "the deploy script writes the staging PAT here; it is issued per-run and expires in 1h, so it is not a standing credential"
paths = ['''^scripts/deploy\.sh$''']
```

A `description` under 40 characters fails:

```
.gitleaks.toml: allowlist entry #1 has a description of 15 characters, which is not a
reason. State what is allowed AND why, in at least 40 characters. `false positive` is
not a reason: it is the absence of one, and a presence check accepts it silently
```

And an entry with a reason and nothing to allowlist:

```
.gitleaks.toml: allowlist entry #1 has a description but no paths, regexes, commits or
stopwords — it allows nothing and says why, which is the shape of a comment that will
be mistaken for a rule
```

### `pull_request_target` appears

```
.github/workflows/ci.reusable.yml declares `on: pull_request_target`. It runs with the
base repository's secrets and a writable token in the context of a FORK's code. Any
job under it is a credential-theft primitive waiting for a reason, and the secret
scanner is the job that most invites 'let me just pull the base branch in so the scan
sees the real history'
```

**Remediation:** use `pull_request`. If the job genuinely needs write access to
comment on a PR, it does not belong in this workflow — GitHub's own advice is
that `pull_request_target` cannot be made safe for fork-controlled code, including
via argument injection, `LD_PRELOAD`, and local file inclusion.

### The `secrets` job is made advisory

```
the `secrets` job sets continue-on-error: true. That is what makes a secret scanner a
report: the build goes green having found nothing, and a green badge is a claim
```

**Remediation:** delete it. There is no partial setting. If the scan is too slow
for a repository's PR cadence, that is a real cost — open an issue and say so —
but the answer is not `continue-on-error`.

### The scan loses full history

```
the `secrets` job checks out with fetch-depth [None]. The runner default is a SHALLOW
clone — one commit. A shallow scan is a diff scan with extra steps, and a diff scan
cannot see a secret that was committed and deleted, which is the finding that matters
most: it is on every fork and in the packfile of anyone who cloned. fetch-depth must be 0
```

**Remediation:** `fetch-depth: 0` on the checkout step. It costs a full clone; on
a repository of this size, seconds.

### The canary reaches output

```
vector 1 did not fire on a log sink: a struct with an exported Token field printed by
the standard library's own formatter reached no sink, so the sweep is looking in the
wrong place
```

and, when a real leak is found:

```
cafaye_canary_…(46 bytes) reached stdout/stderr while formatting a safe.Session.
captured 196 bytes
```

**Remediation:** the message names the shape, not the value. The usual cause is
`%v` or `%+v` on a struct that holds a credential. Fix the type, not the logger:
see `internal/safe/creds.go` for the measured table of which field shapes `fmt`
can and cannot print, and `Claims` for the shape that has no field to get wrong.

### An allowlist entry has no reason

```
.github/zizmor.yml:12: ignore entry '- ci.yml:48:11' has no reason. A baseline with no
stated reason is how a scanner becomes a report one commit at a time: the next reader
cannot tell an accepted false positive from a deferred one
```

**Remediation:** a comment on the line above, naming what is allowed and why.

---

## 3. R4 — zizmor, and the trade this packet did **not** make

**Measured** against this tree with zizmor 1.30.1, not quoted from the brief:

| Audit | Count | What was done |
|---|---|---|
| `unpinned-uses` | 35 | **RECORDED.** Counted and printed on every run. Not fixed, not baselined. |
| `artipacked` | 9 | **FIXED.** `persist-credentials: false` on all nine checkouts. |
| `self-repository` | 1 | **BASELINED WITH A REASON**, in `.github/zizmor.yml`. |

`tests/zizmor_gate.sh` splits them: `unpinned-uses` is counted and printed with
its reason, every other audit is fatal. `tests/validate.sh` **fails** if
`unpinned-uses` is ever added to the ignore list, and `self_test` breakage 23
plants that suppression and proves it goes red.

The three options are costed in `DECISIONS.md` under **MD10a**, including the
third one nobody had costed (pin to a SHA, let Renovate open the bump PRs, which
is the machinery MD11 already ruled for schemas). **Option 3 is recommended. It
is the manager's call, not kit's** — kit cannot own a thirteen-repository
migration.

### The `self-repository` baseline, and why it is a boundary and not a disagreement

zizmor wants `uses: $/...` rather than `./...` for a same-repo reference. GitHub
shipped that in July 2026 and it is a genuine improvement. It was **not** adopted
here, and the reason is in `.github/zizmor.yml`:

> kit's entire documented contract is the `./` form. `AGENTS.md`, `README.md`,
> the `callable path` check in `tests/validate.sh` and **four** of the self_test
> breakages all assert on that exact string. Changing the spelling means
> rewriting all of them plus the sentence in `ci.yml` that explains why kit
> calls itself — and that is a change to the one job that proves kit's standard
> resolves, which must not be made and asserted green from a laptop.

One line, one file, one finding, written down with the cost. See §6.

---

## 4. Proofs that are demonstrations, not self_test breakages

Named here because R6 authorised **one** new self-test breakage for the scanner,
and because a proof nobody can locate is a proof nobody ran. All were produced by
breaking the thing and capturing the output.

**`.gitleaks.toml` — an entry with no reason.** A `description = "false positive"`:

```
.gitleaks.toml: allowlist entry #1 has a description of 15 characters, which is not a
reason. State what is allowed AND why, in at least 40 characters. `false positive` is
not a reason: it is the absence of one, and a presence check accepts it silently
```

**`.gitleaks.toml` — a redefined rule.** Adding `[[rules]]`:

```
.gitleaks.toml defines its own [[rules]]. kit extends gitleaks' defaults
(extend.useDefault) so a new provider detection reaches thirteen repos the day
gitleaks ships it. A vendored rule set is a rule set that stops receiving providers,
which is a secret scanner that has stopped working
```

**`.gitleaks.toml` — an entry with no scope.** A `description` and nothing else:

```
.gitleaks.toml: allowlist entry #1 has a description but no paths, regexes, commits or
stopwords — it allows nothing and says why, which is the shape of a comment that will
be mistaken for a rule
```

**`.gitleaks.toml` — missing entirely:**

```
.gitleaks.toml does not exist. gitleaks then runs on its DEFAULT rules with no cafaye
allowlist, which is a scan that looks configured and is not — and the allowlist is the
only part of it anyone wrote
```

**A `.gitleaksignore` appears:**

```
a .gitleaksignore exists at ['.gitleaksignore']. That is the inline allowlist: it lives
beside the scanner rather than in the committed config, so it is invisible in review,
unversioned, and gone the next time someone runs the scanner by hand. Entries go in
the committed config, one per finding, each with a reason
```

**The canary is committed as a literal** — the property holds twice: inside the Go
suite (`TestCanaryIsSafe`) and over the whole tree. Breakage 22 is the tree-wide
one.

**The canary stops being unmistakably fake** (a high-entropy body, so an entropy
scorer could rate it as random):

```
the canary body is not the repeated word the contract specifies, so it is no longer
unmistakably fake. A high-entropy canary is indistinguishable from a real credential
to any detector that scores entropy, which is most of them
```

This check was originally an entropy *threshold* (`distinct bytes > 8`) and **it
failed on kit's own canary**, which has 9. That is the whole argument against
thresholds, and the property is now structural.

---

## 5. What the canary harness found

Three findings, all in kit's own reference type or in the harness, all measured,
all now pinned by a test.

### 5.1 An unexported field is not protection, and `String()` is ignored on one

The reference type was first written with an unexported `token Token` field,
believing lowercase bought protection. **Vector 1 failed on it.** The measured
table (`print_shape_test.go`, all cells asserted):

| shape | `%v` | `%+v` | `%#v` | `%s` | `%q` | `%d` | `%x` | `%X` | `%t` | `%e` | `%U` |
|---|---|---|---|---|---|---|---|---|---|---|---|
| value field, unexported | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| value field, exported | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| pointer field, unexported | · | · | · | **✗** | **✗** | · | · | · | ✗ | ✗ | ✗ |
| pointer field, exported | · | · | · | · | · | · | · | · | ✗ | ✗ | ✗ |
| `func() string` field | · | · | · | · | · | · | · | · | · | · | · |

Three things nobody would have guessed:

1. **`fmt` prints unexported field values.** The field being lowercase buys
   nothing against `%v`, and `%v` is in every log line in every service. `-race`
   will not stop it, `go vet` will not mention it.
2. **A redacting `String()` is *ignored* when the field is unexported.** `fmt`
   cannot call a method on a value obtained from an unexported field, so it falls
   back to reflection and prints the struct. The redaction is right there in the
   code and does nothing.
3. **`%x` is a leak.** It prints `6361666179655f…` — not readable by a human,
   one `xxd -r -p` from a live secret. A table that called `%x` safe would be
   wrong in the way that matters, which is why the predicate asks about both hex
   cases.

The only field shape safe under **every** verb is `func() string` — and
`encoding/json` **refuses** to marshal it, so a type shaped that way cannot be
serialised with the credential in it at all.

**And the actual answer, above all of them: don't hold the credential.**
`internal/safe.Claims` has no credential field at all, and it is the shape kit
points a service at first.

### 5.2 A residual risk, asserted rather than forgotten

`internal/safe.Session` is **not** safe under `%t`, `%e`, `%f`, `%g`, `%U`, `%d`.
`fmt` has no `Stringer` path for a numeric verb and falls back to
`%!t(*safe.Token=&{…})` — the value inside the error text.

`TestTheReferenceTypeLeaksUnderBadVerbs` **asserts the leak exists**, and fails
when it stops existing, with a message saying to update the comment. The
alternative — testing only the verbs that pass — leaves the gap in a comment, and
a comment is not something a toolchain change can fail. It is accepted because
every one of those verbs is also a bug at the call site.

### 5.3 A real hole in vector 4, found by breakage 21

`walkJSON` visited only **scalars**. Dropping the `json:"-"` from a field whose
type marshals to `{}` left every sweep reporting clean — the key existed and held
nothing, and a walk over scalars cannot see a key whose value is the absence of
one. That is *precisely* vector 4's finding. Fixed to report empty objects and
arrays; breakage 21 now goes red.

---

## 6. What is **NOT** covered

Stated plainly, because a scanner's gaps are part of its contract.

### Language coverage

| Language | Canary adapter | Why |
|---|---|---|
| **Go** | **complete**, five vectors, each with a red proof | the packet's minimum, and the one that produced §5 |
| Ruby | **none** | see below |
| Python | **none** | see below |
| Node / Bun | **none** | see below |
| Elixir | **none** | see below |
| Rust | **none** | see below |

**Five of six services have no runtime-leak coverage.** The contract is written
(`templates/secrets/README.md`) and the failure is **not** "the tool was not
found": gosec's `credentials.Match` has no `*ast.CallExpr` case, Bandit matches
`ast.Constant` only, Brakeman's secret check is optional and off, and of 268
Semgrep taint rules **zero** intersect CWE-532. There is nothing to adopt, in any
language.

Why Go shipped alone, honestly:

- It is the packet's stated minimum and the language this wave's hardest services
  are written in.
- The contract's **vector 5 is Go-specific by construction** — `fmt.Stringer`,
  `error`, `go/ast`. A Python or Ruby adapter cannot implement it as written, and
  a paraphrase would be a different check wearing the same name.
- The measurements in §5.1 are Go's `fmt` behaviour. Carrying them to another
  language would be carrying a claim nobody measured, which is the one thing this
  packet is against.
- The template structure allowed it: `templates/otel/<lang>/` is already
  per-language with its own suite, so `templates/secrets/<lang>/` slots in. It is
  a **slot that is empty five times**, and the gate asserts the Go one exists
  rather than pretending the other five do.

**This is the largest gap in the packet** and it should be the next one.

### Vector 5's own limits

- It is a **type check, not a call-graph check**, and that is the point: gosec's
  missing `*ast.CallExpr` case is why this had to be built at all.
- It **will not** find a `String()` on a type whose secret is a plain `string`
  field — the common case today. It matches a *named secret type*.
- It **will not** find `Render()`, `Describe()`, `LogValue()`, or any method that
  is not `String` or `Error`.
- It sees **nothing** in a dependency, behind a build tag, in generated code, or in
  a package it was not pointed at. The package list is an argument, so passing the
  wrong one asserts over nothing — which is why an empty directory is a hard
  error, not a clean result.

### Vector 1's own limit

`SweepOutput` replaces the `os.Stdout`/`os.Stderr` **variables**, not the file
descriptors. A logger holding its own dup of fd 1 bypasses it. A service with one
should point vector 1 at a `Sink` as well.

### Scanner limits

- gitleaks scans **kit's history**, not GitHub's. A secret first pushed straight to
  a remote that kit never saw is GitHub's `secret_scanning` to find — which
  **is enabled on all sixteen public repos** (MD10) and is not a substitute for
  this.
- A **false negative is possible and unmeasured.** gitleaks is regex- and
  entropy-based; a credential that matches no known provider format and scores
  below the entropy floor is not found. No false-negative rate was measured here
  and none is claimed.
- The **canary is only as good as the sinks you name.** A harness covering three
  of nine log destinations asserts over a third of the surface. It is bounded by
  the arguments, and the gate cannot know them.
- **The runners have network.** R1 says run offline "where the runner permits it",
  and GitHub-hosted runners do not permit it. What is offline is the *scan*:
  gitleaks is a static binary that reads a repository and matches regexes, and
  makes no network call in either mode. That property is precisely what
  disqualified trufflehog, and it is the reason to prefer one over the other
  even though both would have worked.

### Decisions this packet did not take

- **`unpinned-uses` is still an open decision** (MD10a). Nothing was pinned and
  nothing was suppressed.
- **`self-repository` (`$/` syntax) is deferred.** One finding, one line, one
  file. The reason is a packet boundary, not a judgement: changing kit's
  documented `uses:` string means rewriting `AGENTS.md`, `README.md`, the
  `callable path` check and four self_test breakages, and it changes the one job
  that proves kit's standard resolves. **It should be done, by whoever owns the
  callable path, on a commit that can verify it in GitHub's own runner.**
- **The `secrets` job is on by default**, which will turn a repo's first build
  red if it has a secret in history. That is the ruling, and it is the cost. README
  says what to do, and the first thing is to rotate.

---

## 7. The full check list

**Before: 18 breakages. After: 29.** The count is derived from the breakages that
actually ran, and `self_test` prints it.

```
PASS self_test: unbroken tree — the gate is green on an unbroken tree
PASS self_test: breakage  1: templates/otel/go/traceparent.go deleted
PASS self_test: breakage  2: collector traces pipeline exports over the network
PASS self_test: breakage  3: python codec stops preserving trace-flags
PASS self_test: breakage  4: docker-compose.yml hardcodes a published port
PASS self_test: breakage  5: the telemetry CI job is no longer opt-in
PASS self_test: breakage  6: the `none` job is no longer gated on its own input
PASS self_test: breakage  7: README documents a `uses:` path that is not the reusable workflow
PASS self_test: breakage  8: the workflow no longer declares `on: workflow_call`
PASS self_test: breakage  9: a second copy of the reusable workflow, out of reach
PASS self_test: breakage 10: kit CI calls a remote ref instead of its own local copy
PASS self_test: breakage 11: a Dockerfile pins nothing (hadolint DL3013)
PASS self_test: breakage 12: a Dockerfile final stage runs as root
PASS self_test: breakage 13: a credential in history, since removed
PASS self_test: breakage 14: a credential in the working tree
PASS self_test: breakage 15: the scan stops redacting
PASS self_test: breakage 16: the scan narrows to the last commit
PASS self_test: breakage 17: a dangerous trigger appears in the workflow
PASS self_test: breakage 18: the secret scanner is made non-blocking
PASS self_test: breakage 19: the reference type hides its credential in an unexported field
PASS self_test: breakage 20: the credential type stops redacting when printed
PASS self_test: breakage 21: the reference type marshals its credential
PASS self_test: breakage 22: the canary is committed as a literal
PASS self_test: breakage 23: the zizmor config baselines unpinned-uses
PASS self_test: breakage 24: go stops masking trace-flags (§3.2.2.5)
PASS self_test: breakage 25: ruby accepts uppercase hex (§3.2.2)
PASS self_test: breakage 26: elixir accepts trailing junk on version 00 (§3.2.2.2)
PASS self_test: breakage 27: node never truncates tracestate (§3.3.1.5)
PASS self_test: breakage 28: rust accepts an all-zero trace-id (§3.2.2.3)
PASS self_test: breakage 29: python stops masking trace-flags (§3.2.2.5)

PASS: self_test — all 29 breakages went red, and the unbroken tree is green.
```

**15 of the 29 assert a *named* check**, not merely "the gate went red" — a red
that forty checks could have produced is a weak proof when the check under test
is one of them.

### Three defects this packet introduced and then caught

Recorded because each is the failure mode the packet is about, appearing inside
the packet:

1. **`self_test` breakages 13–14 made `tests/validate.sh` report four leaks in
   the file that was planting them.** The GitLab PAT was written out as a
   literal. It is now assembled from two halves.
2. **Breakage 22 did the same with the canary**, and the tree-wide canary check
   caught the breakage's own replacement string. It is now assembled at the moment
   the defect is introduced, in a copy that is deleted.
3. **Breakage 21 found a real hole in the detector** (§5.3), not a false proof —
   which is the outcome a breakage is supposed to produce, and the reason the
   breakages were aimed at the safe type as well as the leaky one.

---

## 8. Files

| File | What |
|---|---|
| `.gitleaks.toml` | the allowlist, and nothing else |
| `.github/zizmor.yml` | one reasoned baseline; `unpinned-uses` deliberately absent |
| `tests/gitleaks_gate.sh` | the one secret scan — CI and the gate |
| `tests/zizmor_gate.sh` | the one zizmor split — `unpinned-uses` recorded, rest fatal |
| `tests/bootstrap.sh` | gitleaks (verified release binary) and a tarball-capable installer |
| `tests/requirements.txt` | `zizmor==1.30.1`, pinned, and why |
| `tests/validate.sh` | ten new checks; scanner resolved before the checks that run it |
| `tests/self_test.sh` | eleven new breakages; count now derived |
| `.github/workflows/ci.reusable.yml` | `secrets` + `zizmor` jobs; `persist-credentials: false` × 9 |
| `templates/secrets/README.md` | **the contract**, language-neutral, all five vectors, and its limits |
| `templates/secrets/go/` | the Go adapter: `canary.go`, `sweep.go`, `typecover.go`, the suites, `internal/safe`, `internal/leaky` |
| `.gitignore` | `tests/.bin/` |
| `README.md`, `AGENTS.md`, `CHANGELOG.md` | updated to match the tree |
| `../DECISIONS.md` (moon) | **MD10a** — the `unpinned-uses` trade, three options costed |

**No token, cookie, or JWT appears in this repository, this report, or any
failure message the gate can print.** The two planted probes are a documented
GitLab format sample and kit's own fake canary, both assembled rather than
written; every harness message truncates or reduces to a position rather than
quoting the value.
