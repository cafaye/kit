# REPORT — kit-08, finishing the `worker/kit-04` merge

`worker/kit-08-merge` was left mid-merge by a worker that died holding it. This
records what the merge turned out to be, what was actually wrong with it, and the
measured state of the gate.

## 1. The state I inherited was not quite as described, and it moved under me

On arrival the brief's measurement was exact: nothing committed, five paths
unmerged, conflict markers already stripped but never staged.

What the brief did not know: **the worktree was still being written to while I
audited it.** `tests/self_test.sh` grew 971 → 1023 lines, then changed again three
more times over the following four minutes — each time in the direction of fixing
the very defects the brief asked me to find (the header's `18 + 17 + 11 + 12 = 58`
arithmetic, and the out-of-order `19`–`22` block). A concurrent session was
holding this same worktree and finished the job while I was verifying it,
committing the merge as `90328e1` about six minutes into my run.

I inherited none of its conclusions. Everything below is my own measurement, and
where I disagreed with what I found I say so — including the one case where I
disagreed with myself and was wrong (§6).

## 2. The renumbering: the scheme, and why

**The scheme:** master's numbering is canonical and does not move.

- `1`–`22` plus `2b` are master's — unchanged.
- `13`–`18` are the six language mutants. `kit-04` carried its own copies at
  `24`–`29`; those were **dropped, not renumbered**, because they are master's
  `13`–`18` byte for byte — verified by diffing the recipe *bodies*, not by
  reading the labels. A second copy would prove the same six rules twice under two
  names.
- `24`–`34` are `kit-04`'s eleven secrets breakages, moved by a uniform `+11`:
  its `13` became `24`, its `23` became `34`.

**Why a textual union was not available.** A naive union carries 34 recipes with
four labels used twice (`19`, `20`, `21`, `22`). `self_test_claims` compares the
documented set against the carried set **as sets**, so duplicates collapse
silently and the check reports an agreement that does not exist — the precise
class of defect this repository exists to catch.

### What happened to label 23

**Nothing was dropped; nothing was overwritten.** This is answerable from history
rather than by inspecting the file:

- `git show worker/kit-04:tests/self_test.sh` contains **exactly eleven** secrets
  breakages, `13`–`23`, and no twelfth.
- The merged file contains **exactly eleven** recipes, `24`–`34`, whose recipe
  bodies diff **identical** against `kit-04`'s `13`–`23` after digit normalisation.

So the `+11` mapping is total and lossless. `kit-04`'s `23` — the zizmor
`unpinned-uses` baseline — **is** breakage `34` here, and it is the last recipe in
the file. The gap at `23` is a seam, not a hole.

I deliberately did **not** close it by sliding the block to `23`–`33`. That would
renumber eleven recipes plus every prose reference to them across three documents
to remove a cosmetic gap, and a numbering exists so a number can be cited in a
review, a bisect or an incident. Eleven stable references are worth more than
eleven consecutive integers. The gap is documented instead, at the one place a
future renumber script will read it as a bug, and in `README`.

### The second defect: the recipes ran out of order

Resolved. The file had been running `1`–`18`, then `24`–`34`, then `19`–`22`.
`19`–`22` now sit between `18` and `24`. Verified from the file itself:

```
1 2 2b 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 24 25 26 27 28 29 30 31 32 33 34
```

## 3. The real defect: the renumber killed two proofs

This is the finding, and it was not in the brief.

Naming `24`–`34`'s throwaway copies after what they break — the right instinct,
and the thing that stopped them colliding with master's `nineteen`…`twentytwo` —
gave breakage 33's copy the name `canary_literal`. That was **already the name of
the canary value**, assembled six lines below it:

```bash
canary_literal="$(fresh_copy canary-committed-as-literal)"   # a DIRECTORY
...
canary_literal="$canary_prefix${canary_body:0:32}"            # the VALUE
edit "$canary_literal/templates/secrets/go/canary.go" ...     # neither
```

So `edit` was handed `cafaye_canary_…/templates/secrets/go/canary.go` and died
with a `FileNotFoundError`. Breakage 33 never ran, and because the script stops at
the first crash, neither did 34. **Two of the thirty-four proofs had silently
stopped being tested** — *"the canary is committed as a literal"* and *"the zizmor
config baselines unpinned-uses"* — and the run died before printing its summary.

Restored to `kit-04`'s naming, where the directory was `twentytwo` and the value
`canary_literal`. In `kit-04` these could not collide, because the directory
variables were `twelve`, `thirteen`, … `twentytwo` and none of them was a word.

Worth stating plainly: this is the exact failure the renumber was introduced to
prevent, produced by the renumber itself. And nothing about reading the file shows
it — both lines are correct in isolation, `bash -n` is happy, and the
header/recipe agreement is perfect while both are wrong. It is fatal only when the
recipe runs, on the one phase whose output nobody reads on a green run.

**The check.** `self_test_claims` already parses this file to compare the header
against the recipes, so it now also asserts that no `fresh_copy` directory variable
is ever reassigned. Verified in both directions — it fails on the pre-fix file,
naming line 981 and its origin at line 963, and is clean after:

```
$ guard.py <pre-fix self_test.sh>
PROBLEMS:
  - line 981: `canary_literal` holds a throwaway copy (assigned at line 963) and
    is reassigned here, so that recipe edits a path that no longer exists
$ guard.py <fixed self_test.sh>
CLEAN
```

## 4. Completeness: did either side lose anything?

Compared **label sets**, not counts, across all three sides.

- **`tests/validate.sh`** — every label on master's side survives. Exactly two
  differ, both deliberately:
  - `collector_check` — one function, two labels; master's fuller revision won.
    Master's version *subsumes* the part of `kit-04`'s that is not superseded:
    `receivers` and `batch` are asserted per signal rather than for `traces` alone.
    The rest is deliberately gone — `kit-04`'s "the traces pipeline ships to no
    non-local exporter" describes the pre-fan-out stack, whose only exporter was
    `debug` (`git show worker/kit-04:…/otel-collector.yml` → `['debug']`), and it
    would go **red** against the tempo/loki/mimir fan-out master now ships.
    Keeping it would have been a check that fails on a correct tree, which is worse
    than no check.
  - the `self_test` invocation site, which is the documented union.
- **`README.md`** — `kit-04`'s adoption step survives as **7d** (the canary), with
  master's tier step at **7c**. Both present.
- **`CHANGELOG.md`** — `kit-04`'s entry survives, its breakage numbers annotated as
  renumbered rather than silently rewritten.
- `templates/compose/*` is still in the parse loop; nothing from master's side was
  lost from any of the five paths.

## 5. The one red check in the shared worktree, and why it is not mine

In the worktree, `bash tests/validate.sh` is red on exactly one check:

```
FAIL gitleaks  (8.30.1, full history, --redact)   →  leaks found: 1
```

**It is not caused by this merge, and it is not fixable from this merge.** The scan
runs `git log --all`, and every worker in this fleet is a *worktree of one shared
repository* — so `--all` reaches sibling branches that have never been on master.
The single finding is `worker/kit-16-deploy`'s commit `924b725`, a JWT-shaped
canary in `tests/deploy_test.sh` (the signature is the base64 of a string reading
`KIT16CANARY…`, so it is a fixture, not a credential).

Proof that the merge is clean, by running the same scan twice with only the scope
changed:

| scope | commits scanned | result |
|---|---|---|
| `-p -U0 --full-history HEAD` (the merge's own history) | 38 | **0 leaks, exit 0** |
| `-p -U0 --full-history --all` (what the gate runs) | 44 | 1 leak, exit 1 |

I did not "fix" this. Narrowing the scan would weaken it — for an adopting
service, `--all` is what catches a secret that lives only on a branch — and
editing `worker/kit-16-deploy` is not this packet's branch. **This needs an owner:**
`kit-16` should make the canary not JWT-shaped, or allowlist it with a proper
`description`. Left unfixed and unreported it would fail the moment that branch
lands.

Because of this, all verification below was run in an **isolated single-branch
clone**, where `--all` cannot reach a sibling worktree and the check behaves as it
would in CI.

## 6. A correction I made and then withdrew

The merge's `CHANGELOG.md` claimed `45 / 34 / 59` check sites with twenty shared.
Measuring the tree I got `59 / 34 / 59` with 34 shared, and "corrected" the entry.

**That correction was wrong.** The `59` was master's number only because I measured
`HEAD` *after* the concurrent session had already made the merge commit — so I was
comparing the merge against itself and calling it master. Re-measured against the
true tips: master `41f8bcb` = **45**, `kit-04` `c5b7381` = **34**, merged `90328e1`
= **59**, and `45 + 34 − 59 = 20` shared. The original entry was right; I restored
it and kept only the genuinely new `collector_check` analysis.

This is precisely the failure the changelog's own prose-count bullet warns about — a
number copied by hand instead of measured — and I committed it for about ten
minutes. Recorded here rather than quietly reverted, because the mistake is the
useful part.

## 7. One flake, and what it exposes in the harness

The first `validate.sh` run reported, once:

```
FAIL self_test: breakage 8 … the gate went red, but NOT via
  `.github/workflows/ci.reusable.yml  (callable: exists, on: workflow_call, docs agree)`
```

with an **empty** dump of which checks actually fired. An identical re-run of the
same tree passes breakage 8, and a faithful manual reproduction of its mutation
fails the expected check correctly. So it is environmental — this box had 70k
pageouts and ten other agents running, after an OOM earlier in the day.

The mechanism is worth recording because the harness cannot see it.
`expect_red_check` treats "non-zero exit" as "the gate ran and reported something
else". But `validate.sh:2650` — if `yamllint` cannot be bootstrapped — does
`exit 1` **without emitting a single `FAIL` line**. A gate that died and a gate
that ran and disagreed are indistinguishable to the assertion, so a dead gate is
reported as an accusation that a correct check has stopped being load-bearing.

This is the same *symptom* as the `SIGPIPE`/`pipefail` bug already recorded in the
changelog, with a different cause. I did **not** change the harness: the fix is to
distinguish "the gate never reached its summary" from "the gate ran and named a
different check", which changes proof semantics and cannot be validated against a
flake that reproduces about once in twenty runs. It is reported instead. Fixing it
means having `expect_red_check` assert that `$out` contains the gate's own
`FAIL: N check(s) failed.` summary line before it is willing to call the proof
wrong.

## 8. Measured counts

Counted from the tree, not taken from prose.

| Quantity | Value | How measured |
|---|---|---|
| self-test breakages | **34** | `grep -cE '^expect_red(_check\|_lang\|_script)? '` — the expression `validate.sh` reuses for its own label |
| assert a **named** check fired | **19** | `expect_red_check` invocations |
| assert a **named proof script** went red | **2** | `expect_red_script` invocations |
| per-language semantic mutants | **6** | `expect_red_lang` invocations |
| only assert the gate can fail | **7** | `expect_red` invocations |
| header/recipe agreement | **AGREE** | both sides are the same 34-label set |
| throwaway copies per gate run | **30** | `fresh_copy` invocations — 34 breakages over 29 copies, the six language mutants sharing one, plus the control's own |
| `validate.sh` check sites | **45** master / 34 `kit-04` / **59** merged | `^\s*(check\|check_verbose) ` |
| secret scan, merge's own history | **0 leaks, exit 0** | `--full-history HEAD` |

## 9. Gate result

**No single full green run exists, and pretending otherwise would be the easiest
lie available here.** This section is filled from what was actually measured, and
it is deliberately incomplete in one respect, which is stated rather than papered
over.

Measured on the merged tree (`90328e1`) in an isolated single-branch clone, where
`--all` cannot reach a sibling worktree:

```
FAIL: 1 check(s) failed.
note: 3 check(s) skipped
  33 PASS / 0 FAIL / 0 SKIP   (1 control + 32 breakages)
```

The single failure is `tests/self_test.sh`, and it is the defect in §3: it ran
through breakage 32 and died at 33 with the `FileNotFoundError`. `33 PASS / 0 FAIL
/ 0 SKIP` is the count of everything that *ran* — 34 and 34 is what a green run
must print, and that number was not reached on this commit.

Verified separately, on `c8271716`, by exercising the two proofs the defect had
killed rather than re-running the whole suite:

| proof | mutation | check that fired |
|---|---|---|
| 33 | canary written as a literal in `canary.go` | `the canary  (never committed as a literal, anywhere)` |
| 34 | `unpinned-uses` baselined in `.github/zizmor.yml` | `.github/zizmor.yml  (unpinned-uses recorded, never baselined)` |

Both fire the check the recipe names, so both proofs are live again. The guard
added in the same commit was checked in both directions: it **fails** on the
pre-fix file, naming line 981 and its origin at line 963, and is **clean** on the
current one.

The two proofs the earlier `SIGPIPE`/`pipefail` defect used to fail — breakages 11
(hadolint) and 25 (the working-tree credential) — both report `PASS` in the run
above. That is the fix working: under the old matcher they were the two breakages
whose gate output exceeded the 64KB pipe buffer, and they were reported as *"the
gate went red, but NOT via `<the check that fired>`"*. Confirmed in isolation too —
old matcher: `hit` at 8KB/32KB, `MISS` at 64KB/128KB/512KB; new matcher: `hit` at
every size, with a negative control still correctly missing.

**Not verified: a complete `bash tests/validate.sh` exit 0 on `c8271716`.** The box
is carrying load average 54–76 with several sibling workers running their own
gates, and it ran out of memory earlier in this packet — §7's flake came from
exactly that. A further 50-minute run would have added load to the critical path
three workers are blocked on, to produce a result that a loaded box is liable to
distort anyway. **Whoever picks this branch up should run the full gate once
before it is pushed**, and should expect §5's `--all` finding to be the only red.

## 10. What I changed

Two commits, on top of the merge `90328e1`:

**`c827171` — the breakage-33 defect and its check**
- `tests/self_test.sh`: breakage 33's directory `canary_literal` → `canary_as_literal`,
  restoring `kit-04`'s separation of directory from value. Comment added explaining
  the constraint, because the names looked interchangeable.
- `tests/validate.sh`: `self_test_claims` now also rejects any `fresh_copy`
  directory variable that is reassigned.
- `README.md`: the copy count was "twenty-nine"; the tree makes thirty. Already
  wrong on both sides of this merge.
- `CHANGELOG.md`: how master's `collector_check` subsumes `kit-04`'s `receivers` and
  `batch` assertions, and why the local-only exporter check is deliberately gone
  rather than lost; the breakage-33 defect and the new check.

**This report.**

No check was weakened, no threshold lowered, and nothing under `harness/` or
`core/` was touched. No `kit-12`/`13`/`14`/`15`/`16` branch was merged. Nothing was
pushed.