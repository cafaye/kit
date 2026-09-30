# REPORT — kit-08, finishing the `worker/kit-04` merge

`worker/kit-08-merge` was left mid-merge by a worker that died holding it. This
records what the merge turned out to be, what was actually wrong with it, and the
measured state of the gate.

**Where this packet stands.** The merge is complete and the numbering defect it
introduced is fixed. The gitleaks red that the manager attributed to kit-16's JWT
canary is now allowlisted — narrowly, in a way measured in both directions (§5) —
and the canary itself was re-proved able to go red afterwards. The second red,
`templates/otel/ruby`, is **pre-existing on master and not this merge's**, and it
is attributed with the receipts in §6. Everything else the gate runs is green —
**`bash tests/validate.sh` exits 0, twice, watched to completion** (§10). Nothing
was pushed.

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
disagreed with myself and was wrong (§7).

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

## 5. The gitleaks red: attributed, then allowlisted — narrowly

In the worktree, `bash tests/validate.sh` was red on exactly one check:

```
FAIL gitleaks  (8.30.1, full history, --redact)   →  leaks found: 1
```

**It was not caused by this merge.** The scan runs `git log --all`, and every worker
in this fleet is a *worktree of one shared repository* — so `--all` reaches sibling
branches that have never been on master. The single finding is
`worker/kit-16-deploy`'s commit `924b725`, `RuleID: jwt`, `tests/deploy_test.sh`
line 155. Running the same scan twice with only the scope changed is what
established that, and it is the measurement the attribution rests on:

| scope | commits gitleaks scanned | result, at `e8227b0` |
|---|---|---|
| `-p -U0 --full-history HEAD` (the merge's own history) | 41 | **0 leaks, exit 0** |
| `-p -U0 --full-history --all` (what the gate runs) | 79 | 1 leak, exit 1 |

(`git rev-list --count HEAD` is 52, and gitleaks reports 41 and 79 — it counts what
its own diff walk emits, not refs. The ratio between the two scopes is the
measurement; the absolute numbers are not comparable to anything but each other,
and an earlier draft of this table printed 38 and 44, measured before this
packet's two doc commits existed. Copied forward numbers are how a table starts
lying.)

### What the finding actually is

`JWT_CANARY` in `tests/deploy_test.sh` is a deliberate fake, and its own comment
says why the fake has to be a JWT: *"A value the redactor cannot know by name is
half the test."* kit-16's deploy story claims the redactor scrubs a token the
deploy never supplied, and a canary built from a name the filter already knows
would prove nothing — the filter would be matching its own input list. So the
token is committed, it is JWT-shaped, and gitleaks' `jwt` rule fires on it. **The
scanner did the one thing it is for.** Measured, in full:

```
eyJhbGciOiJIUzI1NiJ9  ->  {"alg":"HS256"}
eyJzdWIiOiJraXQxNiJ9  ->  {"sub":"kit16"}
Q1lOYVJZTEZBS1JFU1VMVFRFU1FMkE  ->  CYNaRYLFAKRESULTTESQL\x90
```

The signature segment is the base64 of a misspelled "CANARY LFAKE RESULT SQL" plus
one stray byte. No key, no issuer, no subject a token could authenticate. The
finding is a shape, and the shape is the point of the fixture.

### The entry, and the three things it had to prove

`.gitleaks.toml` now carries exactly one `[[allowlists]]` entry:

```toml
[[allowlists]]
description = "the jwt rule on tests/deploy_test.sh only: …"
condition = "AND"
targetRules = ["jwt"]
paths = ['''^tests/deploy_test\.sh$''']
```

An allowlist entry is the one move in this repository that can silence a scanner,
so the entry is measured in both directions rather than argued for. A throwaway git
repository, three planted findings, the same binary and the same flags the gate
uses:

| planted | no allowlist | with the entry |
|---|---|---|
| `jwt` in `tests/deploy_test.sh` | reported | **suppressed** (this is the entry) |
| `generic-api-key` in `tests/deploy_test.sh` | reported | **still reported** |
| `jwt` in `other/thing.go` | reported | **still reported** |

The `generic-api-key` finding is not a contrived string: it is what gitleaks reports
for a `ghp_…` literal, so the cell is the ordinary accident a service is most
likely to have in a test file. And the surviving `jwt` in `other/thing.go` is the
byte-for-byte same token, in a different directory — which is the whole claim: the
entry is scoped to a **path**, not to a value.

Both surviving findings are the point. An entry that only excused the one string
would not be a judgement call, it would be a suppression. This one says "the `jwt`
rule, in that file" and the other two cells are what make the sentence true.

**A scope claim worth checking against the source rather than from memory:**
gitleaks' default condition is **OR**, not AND — `config/config.go`'s
`parseAllowlist` maps an empty `condition` to `AllowlistMatchOr`. With only `paths`
populated the two happen to agree, so the explicit `condition = "AND"` is inert
today. It is written out anyway, and the file says so, because a scoping line that
only holds while nobody edits it is not a scoping line: the day someone adds
`regexes` to this entry, OR would silently make it a union. Confirmed empirically
too — the same entry with `condition = "OR"` and the same three planted findings
behaves identically today, which is exactly why the line needs the reason to be
read as deliberate.

**And `targetRules` alone is not a looser option that was merely rejected by
 taste** — gitleaks refuses to load the config at all:
`[[allowlists]] must contain at least one check for: commits, paths, regexes, or
stopwords`. "Ignore `jwt` everywhere" is not something this file can say even by
accident.

### The canary still proves what it proved

Allowlisting a canary is only honest if the canary can still fail. So it was made
to fail: a scratch export of `worker/kit-16-deploy`, `redact.py`'s JWT pattern
weakened from `\.[A-Za-z0-9_-]{4,}` to `\.[A-Za-z0-9_-]{99,}` — one quantifier, so
the pattern can no longer match a token with an ordinary signature — and
`tests/deploy_test.sh` re-run:

```
FAIL  the redactor left a JWT in the output
NOTE  passed: 16  failed: 1  skipped: 1
FAIL: deploy — 1 claim(s) not proved.
```

**One claim red, and it is the JWT one.** The other 16 stayed green, which is what
rules out the duller explanations — a crash, a bad interpreter, a mutated pattern
that broke redaction generally. The test can detect the redactor failing to catch a
JWT, and it still does after this allowlist entry exists. Reverted, and the scratch
copy is byte-identical to the branch (`diff` clean against
`git show worker/kit-16-deploy:templates/deploy/redact.py`).

### The better fix, and why it is not this commit's

kit-16 could make the canary not JWT-shaped — assemble it at run time from a
prefix, the way `templates/secrets/` already does, which is the pattern that
exists precisely so this file never needs an entry. That is the better answer and
it is **kit-16's call**: that branch is not merged here, and editing it is not this
packet's branch. The allowlist entry is the correct thing to leave behind in the
meantime, and it is written so that it *decays*: if kit-16 stops committing the
string, the entry matches nothing, the next reviewer sees an entry that excuses
nothing, and the right response — stated in the file — is to delete it rather than
leave it standing.

The scan was **not** narrowed. `--all` is what catches a secret that only ever
existed on a branch, and it is the reason this finding reached me at all: on a
single-branch clone the canary is invisible and the gate is green. Reachable
sibling branches are the feature, not the bug.

### Gate state after

| | |
|---|---|
| `-p -U0 --full-history --all` at `e8227b0`'s config, 79 commits | 1 leak, exit 1 |
| `-p -U0 --full-history --all` with the entry, 79 commits | **0 leaks, exit 0** |
| `-p -U0 --full-history HEAD` with the entry, 41 commits | **0 leaks, exit 0** |

Same binary, same flags, same history, same 79 commits — the config is the only
variable.

## 6. The `templates/otel/ruby` red: pre-existing on master, and not touched

**Attributed, not fixed, and not mine to fix.** The manager's gate run reported
`FAIL templates/otel/ruby (ruby test suite)`, minitest showing `.E..EE.`. kit-14
attributed it (its report, §10); I re-derived it from scratch rather than
inheriting the conclusion, because the whole claim rests on three comparisons and
none of them is expensive.

### The error, in full

```
1) Error: TestTraceparent#test_tracestate_is_forwarded:
NoMethodError: undefined method `filter_map' for ["congo=t61rcWkgMzE"]:Array
  templates/otel/ruby/traceparent.rb:278:in `usable_tracestate_entries'
  templates/otel/ruby/traceparent.rb:267:in `forward_tracestate'
  templates/otel/ruby/traceparent.rb:239:in `server_hop'
2) Error: TestTraceparent#test_tracestate_is_truncated_at_whole_entries:  (same)
3) Error: TestTraceparent#test_oversized_tracestate_entries_are_removed_first: (same)

13 runs, 1370 assertions, 0 failures, 3 errors, 0 skips
```

`Array#filter_map` arrived in **Ruby 2.7**. The call is
`value.split(',', -1).filter_map do |raw|` at `traceparent.rb:278`. Three errors,
one error: the three `tracestate` tests are the only ones that reach
`usable_tracestate_entries`.

### The three comparisons

| candidate cause | measurement | verdict |
|---|---|---|
| **H2 — this merge's `validate.sh` changed the invocation** | `run_ruby` is `ruby "$ROOT/templates/otel/ruby/test_traceparent.rb"` and is **byte-identical to master's** (`diff` of the extracted block, not a reading of it) | refuted |
| **H2 — the template itself was touched** | `git diff master -- templates/otel/ruby/` is **empty** — all four files byte-identical to master | refuted |
| **H1 — pre-existing, toolchain** | `git archive master` into a clean directory at `41f8bcb`, master's own template, **master's own runner**: `13 runs, 1370 assertions, 0 failures, 3 errors` on `/usr/bin/ruby` 2.6.10, and `13 runs, 1407 assertions, 0 failures, 0 errors, 0 skips` on the pinned `ruby 4.0.1` | **confirmed** |

The clean-master reproduction is the load-bearing one: a tree that contains none of
this merge's work produces the identical failure. **The template is correct; the
interpreter was not.** `/usr/bin/ruby` on this machine is 2.6.10, and the pinned
4.0.1 lives behind a mise shim that only wins when the shim directory precedes
`/usr/bin` on `PATH` — which is why this is environment-dependent and why a
machine that ran the gate with a different `PATH` saw a red that this box's `PATH`
hides. The three errors' own arithmetic is the tell: **1370 vs 1407 assertions.**
An interpreter too old to define a method does not skip the assertions, it aborts
the three tests that reach it, so the suite reports fewer assertions than it has.
A "template bug" that makes the suite assert less is not a template bug.

### Why it is not fixed here

Three reasons, and the third is the one that matters:

1. It is pre-existing. Fixing it in a merge commit would put a ruby toolchain
   change inside a commit about a secrets allowlist, where nobody reviewing the
   allowlist is looking for it.
2. It is not reproduced by the documented invocation **on this box** — pinned ruby
   4.0.1 is first on `PATH` here, so `bash tests/validate.sh` on this branch
   reports `PASS templates/otel/ruby (ruby test suite)` and did so on the run in
   §10. A fix for a red I cannot see is a change I cannot verify.
3. kit-14 has already fixed it, properly, on `worker/kit-14-stale`: a
   `toolchain_floor_ruby` **feature probe** — `ruby -e 'exit(Array.method_defined?(:filter_map) ? 0 : 1)'`
   — that FAILs with a message naming the toolchain rather than letting three
   `NoMethodError`s blame a correct template, proven by its own breakage 30. That
   branch is not merged here, and this packet does not merge it.

The fix that is *not* the fix: editing `traceparent.rb` to avoid `filter_map`. It
would make the suite green on an old interpreter by removing the thing the suite
exists to exercise, and it would leave the gate reporting a template problem for
what is a machine problem. Recorded so that nobody reaches for it.

**Left as it was found.** No file under `templates/otel/ruby/` was touched, and no
ruby runner was edited.

## 7. A correction I made and then withdrew

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

## 8. Two intermittent failures, and what I could and could not establish

**Superseded on the outcome, kept on the analysis.** Across the earlier full runs on
this box I saw the self-test phase fail twice, each time differently. The full run in
§10 was watched to completion and finished green, 34/34, so neither shape reproduced
and neither is a property of the tree. What the two failures produced is still worth
reading, because it is two latent defects in the harness that this green run does
**not** retire — and the second one is the reason I would not have trusted a red
without reading it:

```
FAIL self_test: breakage 8 … the gate went red, but NOT via
  `.github/workflows/ci.reusable.yml  (callable: exists, on: workflow_call, docs agree)`
```
…with an **empty** dump of which checks actually fired, and once:

```
FAIL self_test: unbroken tree — the gate is RED on an unbroken tree
```

Both are "the inner gate exited non-zero". Neither reproduces in isolation. I
ran the control — the gate over an unmodified throwaway copy, which is the
assertion that matters most — **six times: green every time, zero `FAIL` lines.**
Breakage 8's mutation also reproduces correctly by hand, failing exactly the
check it names. §10's full run then went green through the whole phase. So neither
is a property of the tree.

I could not establish the cause, and I am not going to guess at one in a report.
My first hypothesis was a failed tool bootstrap inside the throwaway copies —
`validate.sh:2650` does `exit 1` when `yamllint` cannot be resolved — and I
checked it: copies inherit `KIT_PYTHON`, `kit_bootstrap_console_script` looks for
the tool *beside* that interpreter, and it is there, so no copy installs anything.
The hypothesis was wrong. What remained at the time was load: this machine had
~70k pageouts and ten other agents running, and it OOM'd earlier the same day; a
full self-test phase is ~35 gates back to back. **Load is a guess about a cause I
could not measure, and I am labelling it as one** — the later green run does not
prove it was load, only that it is not the tree.

Two structural weaknesses are real regardless of what fired, and both are worth
more than the flake. **Neither was exercised by the green run in §10**, so neither is
fixed by it:

- **`expect_green` discards the gate's output entirely** (`>/dev/null 2>&1`). So
  the control — the assertion that the gate is green on an unbroken tree — is the
  one failure in the file that reports *nothing about why*. The green run in §10 is
  exactly the case this defect hides: the control passed, and had it not, the log
  would have said only that it failed. It is the same defect the `check_verbose`
  comment describes for the passing case, on the failing one.
- **`expect_red_check` cannot tell a dead gate from a disagreeing one.**
  `validate.sh:2650` and `:123` can `exit 1` without emitting a single `FAIL`
  line, and the assertion reads non-zero plus no matching `FAIL` as "the gate ran
  and named a different check". A gate that died is reported as an accusation that
  a correct check has stopped being load-bearing. **This is the reason I would not
  have believed the second failure above on its own** — an empty `FAIL` dump is
  what a dead gate looks like, and the assertion cannot distinguish the two. Still
  latent; same *symptom* as the `SIGPIPE`/`pipefail` bug in the changelog, a
  different cause.

I did not change either. Fixing the first means re-running the control's gate with
output captured on failure; the second means asserting that `$out` contains the
gate's own `FAIL: N check(s) failed.` summary line before the assertion is willing
to call a proof wrong. Both change proof semantics, and neither can be validated
against a failure that reproduces about once in twenty runs. They belong to whoever
owns the harness, with a machine that can reproduce them.

## 9. Measured counts

Counted from the tree, not taken from prose.

| Quantity | Value | How measured |
|---|---|---|
| self-test breakages | **34** | `grep -cE '^expect_red(_check\|_lang\|_script)? '` — the expression `validate.sh` reuses for its own label |
| assert a **named** check fired | **19** | `expect_red_check` invocations |
| assert a **named proof script** went red | **2** | `expect_red_script` invocations |
| per-language semantic mutants | **6** | `expect_red_lang` invocations |
| only assert the gate can fail | **7** | `expect_red` invocations |
| header/recipe agreement | **AGREE** | both sides are the same 34-label set |
| throwaway copies per gate run | **30 calls, 29 distinct** | `fresh_copy` call sites; `base` is created twice (breakages 1 and the six language mutants share it) |
| `validate.sh` check sites | **45** master / 34 `kit-04` / **59** merged | `^\s*(check\|check_verbose) ` |
| secret scan, merge's own history | **0 leaks, exit 0** | `--full-history HEAD`, 41 commits |
| secret scan, the gate's own scope | **0 leaks, exit 0** | `--full-history --all`, 79 commits, with the §5 entry |
| allowlist entries | **1** | `[[allowlists]]` in `.gitleaks.toml` |

**A number that was nearly wrong, kept here because the near-miss is the lesson.**
A bare `grep -c 'fresh_copy' tests/self_test.sh` returns **31**. The 31st is the
function's own definition on line 188, and a 32nd hit is a *comment* on line 210
that mentions the function in prose. A count taken from a search that does not
distinguish a definition, a call and a mention is not a count of copies — it is a
count of the word. The 30 is call sites; 29 is distinct directories, because
`base` is created twice and reused by the six language mutants. The previous draft
of this table said "thirty" without saying which of the three it meant, which is
exactly the kind of sentence §7 is about.

## 10. Gate result

**`bash tests/validate.sh` — exit 0, watched to completion, twice**, run in the
worktree itself on the tree as this commit leaves it (the allowlist entry present,
so `--all` reaches every sibling branch exactly as it does in a shared clone). This
is the run §8's flakes were reported from, and the difference from those is that this
one finished — twice, with identical counts, which is the first time on this branch
that a claim like "no single full green run exists" (§8's predecessor) stopped
being true.

```
PASS: every check passed.
note: 2 check(s) skipped — reported above, never hidden.
```

| | run 1 | run 2 |
|---|---|---|
| exit | **0** | **0** |
| checks **failed** | **0** | **0** |
| checks **skipped** | **2** | **2** |
| top-level `PASS` lines | **173** | **173** |
| `PASS` lines including the suites' own inner assertions | 270 | 270 |
| self-test breakages red | **34 / 34** | **34 / 34** |

The only `FAIL` string anywhere in either log is one, and it is inside a `PASS` line
— breakage 21's *label*, *"the classifier FAILS OPEN on an unrecognised change"*,
which is the name of the mutation that recipe breaks. A reader grepping a log for
`FAIL` will hit it, and it means the opposite of what it looks like.

The two skips are the same pair on both sides of this merge, and they are named:

```
SKIP templates/tier/bun/tier.test.ts  (node --check cannot read TypeScript; needs a type-stripping parser)
SKIP templates/tier/node/tier.test.ts (node --check cannot read TypeScript; needs a type-stripping parser)
```

### The two reds, and what each one is on this run

| red | before | after | why |
|---|---|---|---|
| `gitleaks (8.30.1, full history, --redact)` | `FAIL … leaks found: 1` | **`PASS gitleaks  (8.30.1, full history, --redact)`** | the §5 entry, scoped to the `jwt` rule at one path |
| `templates/otel/ruby (ruby test suite)` | `FAIL … 3 NoMethodErrors` | **`PASS templates/otel/ruby  (ruby test suite)`** | **not this merge, and not this commit** — see below |

**The ruby line is the one to read carefully, because it is green here for a reason
that is not "fixed".** `git diff master -- templates/otel/ruby/` is empty and the
runner is master's byte for byte (§6). The suite is green because this box's `PATH`
resolves `ruby` to the pinned **4.0.1** through a mise shim that precedes `/usr/bin`,
and it fails with three `NoMethodError`s under `/usr/bin/ruby` 2.6.10 — a red I
reproduced deliberately, from a clean `git archive` of master, and then declined to
fix. So the honest reading of this row is not "resolved"; it is "**invisible on the
machine that ran it**", which is exactly why §6 fixes the attribution with a
reproduction rather than with a claim that the check passes.

### `bash tests/self_test.sh` — 34/34, inside that run, identical in both

| | |
|---|---|
| control (unbroken tree) | **PASS** — "the gate is green on an unbroken tree" |
| breakages | **34 PASS / 0 FAIL** (34 in run 1, 34 in run 2) |
| of which name the check that fired | 21 (19 `expect_red_check` + 2 `expect_red_script`) |
| skips | **0** — a skipped proof fails the run, so this is not a count I get to soften |

Breakages 33 and 34 — the two the renumber had killed — both name the check they
expect, which is the assertion that they are live:

```
PASS self_test: breakage 33: the canary is committed as a literal — caught by `the canary  (never committed as a literal, anywhere)`
PASS self_test: breakage 34: the zizmor config baselines unpinned-uses — caught by `.github/zizmor.yml  (unpinned-uses recorded, never baselined)`
```

The `SIGPIPE`/`pipefail` fixes are visible in the same list: breakages **24** (a
credential in history, since removed) and **25** (a credential in the working
tree) are the two whose gate output exceeded the old 64KB pipe buffer, and both now
report `caught by \`gitleaks  (8.30.1, full history, --redact)\`` — the check they
name, not "some check".

### What two green runs do not prove

Two identical runs retire the *flakes* (§8) and they retire the earlier report's
"no single full green run exists". They do **not** retire §8's two latent harness
defects, because a green run never exercises either one:

- **`expect_green` throws the gate's output away** (`>/dev/null 2>&1`), so the
  control's PASS is exactly the case its own failure mode hides. Two greens is
  stronger evidence than one and is still not evidence about a third failure.
- **`expect_red_check` cannot tell a dead gate from a disagreeing one.** All 34
  breakages exiting non-zero for the *right* reason says nothing about a 35th that
  exits non-zero because the gate died before its summary.

Neither is fixed here, both change proof semantics, and neither can be validated
against a failure that reproduces about once in twenty runs. They belong to whoever
owns the harness, on a machine that reproduces them.

## 11. Collateral damage I caused, and should not have

Cleaning up gate processes orphaned by a server restart, I ran a kill loop over
`ps | grep validate.sh` **without scoping it to my own worktree**. It matched and
killed the running gates of two sibling workers — `kit-12-lint` and `kit-14-stale`.
`kit-14` had already relaunched its gate by the time I noticed; I do not know
whether `kit-12` has. Neither lost committed work, but both lost a gate run, and
`kit-12` may report a spurious failure it did not cause.

Scoping a kill by process name alone in a fleet where every worker runs the same
script from its own worktree is the same class of mistake as the renumber's
collision: correct in isolation, and wrong the moment it meets a neighbour. The
fix is `lsof -a -p <pid> -d cwd` and compare against your own root, which is what
I switched to afterwards.

## 12. What I changed

Three commits, on top of the merge `90328e1`:

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

**`2add9fd`, `e8227b0` — the report**, including the §8 flake analysis and the
measured §9/§10 results.

**This commit — the allowlist entry, the ruby attribution, and the finished report**
- `.gitleaks.toml`: the one `[[allowlists]]` entry (`targetRules = ["jwt"]`,
  `paths = ['''^tests/deploy_test\.sh$''']`, `condition = "AND"`), with the reason
  inline. The header's "there are none" paragraph is corrected — it was true when
  written and is not now, and a file that says "no entries" above an entry is a
  file whose comments have stopped describing it. The `condition` note records that
  gitleaks' default is **OR** and why the line is written out anyway.
- `README.md`: step 2 of the finding-response order now says to **delete** the
  entry when copying the config, because the file is copied into thirteen
  repositories and this one names a path none of them has; plus the `targetRules` /
  `paths` / `condition` shape as the thing to copy.
- `CHANGELOG.md`: both attributed failures, with their evidence.
- `REPORT-kit-08-merge.md`: §5 rewritten (gitleaks: attribution, the entry, the
  two-directional measurement, the canary re-proof, the better fix that is kit-16's),
  §6 added (`templates/otel/ruby`: three comparisons, the clean-master
  reproduction, and why it is not fixed here), §9's counts corrected and the source
  of the `fresh_copy` ambiguity given, and this section.

**What is deliberately not changed.** `templates/otel/ruby/` — not one byte.
`tests/gitleaks_gate.sh` and the `--all` log-opts — untouched, because narrowing
the scan is the tempting fix and it is the wrong one. `worker/kit-16-deploy` — not
edited, not merged. The gitleaks `jwt` rule — not redefined, no `[[rules]]` block
added. No check was weakened, no threshold lowered, nothing slept or retried, and
no assertion relaxed. Nothing under `core/` was touched. No `kit-12`/`13`/`14`/`15`/`16`
branch was merged. **Nothing was pushed.**