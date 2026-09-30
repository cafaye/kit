# REPORT — kit-07-tier

**Packet:** MD12, kit half. Conventions, templates and CI wiring.
**Branch:** `worker/kit-07` → `master`.
**Gate:** `bash tests/validate.sh` — exit 0.
**Self-test breakages: 19 before, 20 after.** Every breakage red, unbroken tree
green.

---

## What this packet is, and what it deliberately is not

kit ships the **convention**. `caf gate` ships the **checker**.

In scope and landed: the declared tier per language in the templates, the
normalised result format written down as a contract, the skip allowlist with its
four hygiene rules, the `REQUIRED_<TIER>` demand in the reusable workflow, the
never-cache-a-report rule, and a check that every language kit ships a job for
also declares a tier and a gate variable.

**Not** landed, deliberately: the collector adapters, the inventory-vs-run set
difference, the production of the normalised format. That is runtime code, it
belongs beside the tool caf-06 is building, and two packets writing one
subsystem at once is a merge collision nobody needs. I did not implement a
checker. The one place kit *enforces* rule 4 is over the templates kit itself
ships, because that is the only inventory kit can see, and that boundary is
written into `templates/tier/README.md` rather than blurred.

The other five services are untouched. `guard/.github/workflows/ci.yml` and
`identity/.github/workflows/ci.yml` were **read** as reference and are
recommended against below, not edited.

---

## The finding that reframed the problem, and what I did about it

JUnit XML cannot express "filtered out". The canonical reference defines
`skipped` as a *runtime* decision: a test excluded by `-k`, a build tag or
`testpaths` does not appear at all, and an absent `<testcase>` is
indistinguishable from a test that was never written.

So the declaration had to be something a runner's own collector already reads.
That constraint drove the whole table, and it is why three languages ship a
**no-op-at-runtime declaration** (an exported const, a module attribute, a class
macro) rather than nothing: the collector becomes a ~15-line adapter instead of a
parser.

---

## Two collector claims I measured, and both corrected the prior claim

I did not take these from the packet. Both were run.

### Rust: `--format json` is nightly-only

The recipe usually quoted for "libtest's JSON formatter emits a full inventory
with `ignore_message`" does not work on a stable toolchain:

```console
$ cargo test -- --list --format json
error: The "json" format is only accepted on the nightly compiler
       with -Z unstable-options          # rustc 1.95.0, stable
```

What does work on stable, and carries the same information:

```console
$ cargo test -- --list            # INVENTORY, ignored tests INCLUDED (3 tests)
$ cargo test -- --list --ignored  # the ignored subset (1 test)
$ cargo test                      # a run prints the reason:
                                  #   test tests::tier_db_needs_postgres
                                  #     ... ignored, cafaye:tier=db reason=…
```

`--list --include-ignored` is a trap: it listed all 3, identical to `--list`, so
it reads like a filter and filters nothing. `--ignored` is the flag that filters.
`templates/tier/rust/tier.rs` says so at the point somebody will reach for it.

The load-bearing property survives intact and is the reason Rust remains the
model: **`--list` includes ignored tests.** A test that did not run is still in
the inventory, because the same compiler produced both.

### Bun: the JUnit report is *better* than the general claim, and worse elsewhere

The packet said Bun's `<skipped>` behaviour was unverified. It is verified now:

```console
$ bun test -t "alpha_ran" --reporter=junit --reporter-outfile=r.xml
 1 pass
 1 filtered out
$ grep testcase r.xml
    <testcase name="alpha_ran" .../>
    <testcase name="beta_filtered_out" .../>   # present, empty body
```

So **bun's reporter emits a full inventory** — a filtered-out test is still
present — and the absent-`<testcase>` failure mode does **not** occur there. The
general claim about JUnit is right; bun is an exception to it, and it is the
first evidence I have that the exception is achievable.

What bun does not have is a **declared reason**: `test.skip(name, fn)` takes no
reason argument, so there is nowhere to write `reason=…` for an allowlist entry
to read. The filtered-vs-skipped distinction is an **empty child element**
versus `<skipped/>` — observed behaviour, not a documented contract, and an
absence of a field is not a promise. The template says not to build on it
without pinning the version.

### Ruby: the gap is real, and it is a dependency gap

```console
$ ruby -e 'require "minitest"; puts Minitest.constants.grep(/Report|Junit/i)'
[:StatisticsReporter, :ProgressReporter, :SummaryReporter, :Reportable, ...]
```

Every built-in reporter is human-readable text. `minitest-reporters` provides a
JUnit one but is a separate gem. So on plain minitest — and on Rails, whose
default runner *is* minitest — there is no machine-readable reporter at all, and
`2 runs, 1 assertions, 0 failures, 0 errors, 1 skips` has nothing in it that
addresses a test. Confirmed, and slightly worse than "no built-in reporter":
there is no path to one without a new dependency.

---

## The allowlist, and rule 4

Four rules, all enforced by `skip_allowlist_check`:

1. every entry names a **reason** — without one, "flaky" becomes the reason for
   everything;
2. every entry names an **owner** — a skip nobody owns is a skip nobody removes;
3. every entry has **`until` and `since`** — the packet asks for "an expiry or
   since date"; this requires **both**, and the extra strictness is deliberate.
   An entry that cannot expire has stopped being a decision.
4. **an entry matching nothing is a failure.**

Rule 4 is borrowed from ESLint's `reportUnusedDisableDirectives`, which reports
a disable comment that no longer suppresses anything. Without it the file is a
ratchet that only turns one way: fixed tests stay listed, listed tests stop being
checked, and within two quarters it contains every test in the repository.

**The gate reads the clock.** An entry past its `until` is a failure *on the day
it passes*. `templates/tier/skip-allowlist` is expected to go red about four
times a year, and each time the correct response is to delete the entry or move
the date with a new reason. This is stated in the file's own header so nobody
meets it as a surprise in January.

**The total is printed on pass.** `check` prints a passing check's stdout
indented under its label, so the count is visible in a *green* run — the only
place a growing list is least likely to be noticed. Individual entries look
justified; the aggregate is the problem, and an aggregate nobody is shown is an
aggregate nobody watches. Conftest reports exceptions as a separate tally for
this reason.

The check also asserts the **inventory is non-empty**. Without that, rule 4
would be checking nothing: an empty inventory rejects every entry, or — far
worse — invites someone to relax it into a no-op that always passes. A check
that proved nothing because it looked at nothing is a check that ran nothing.

---

## `REQUIRED_<TIER>`, demanded

`required-tier` is a new opt-in string input, default `''`. The caller names the
**gate variable** (`REQUIRED_DB`), and every language job exports it as `1` on
its test step.

The design is `guard`'s, and it is the right one for a reason worth restating:
`GUARD_REDIS_REQUIRED` fails at **tier-invocation time, before a report exists**,
so nothing downstream can misreport the run. A check applied after the run
depends on the run having produced something to check.

Then the `tier demand` step, which fails **naming the variable** when the run
produced no `ran` line. A gate variable that is set while a tier runs zero tests
is a green build that verified nothing.

GitHub reusable workflows cannot share a step, so this block is duplicated seven
times. That is a real drift risk, so it is not left to discipline: the check
asserts the step exists in every language job **and that all seven bodies are
byte-identical**. Change one, change all seven, or the gate goes red. Six
hand-maintained copies of a policy block is exactly what this repo exists to
prevent, and the only defence against hand-maintained copies is a check that
reads them.

`-count=1` is mandated on the Go job. Go keys its test cache on the environment a
test reads, so a gated and an ungated run already have different cache keys —
genuinely good news — but mandating the flag removes the question rather than
reasoning about it, and it costs nothing. Asserted on Go alone: no other
language kit ships has an env-keyed test cache, and mandating a flag that does
not exist is a check nobody could satisfy honestly.

---

## Never cache a test report

Documented in README with the reasoning, and **checked**:

`restore-keys` restores stale caches by **prefix match**, and GitHub documents
that the default branch's cache is available to other branches. A key built from
`hashFiles('**/lockfile')` — which does not contain the gate variable — restores
a report written by a run that *had* the database into a run that did not. **A
witness from a different run is not a witness.** `no_cached_report_check` fails
when an `actions/cache` step names a report path; `target/`, `$GOCACHE`,
`node_modules` and `vendor/bundle` are deliberately not caught.

The cross-trust-boundary half is documented, not checked: **fork PRs get
read-only cache access**, so any workflow using `actions/cache` lets a fork
restore a trusted run's cached report. That is a property of GitHub's cache
rather than of this repository, and a single-repo check cannot see it.

I did not go looking for which service has the hole. The packet says it exists in
at least one; asserting which without reading all six would be a guess, and a
guess in a report is worse than a gap.

---

## Two more defects I introduced and then caught

Both found by breaking a throwaway copy rather than by reading the diff, and
both recorded in the CHANGELOG because they are the kind of thing the next
packet will otherwise repeat.

**The tier Go files were never gofmt'ed, and nothing checked them.** The gofmt
check covered `templates/otel/go/*.go` only. `gofmt -d` on the new tree wanted
a `#` on every ALL-CAPS doc heading — Go 1.19 reformatted doc comments, and a
heading without the marker is one gofmt rewrites. A service copying that file
gets a file its own formatter wants to change on the first commit. The check now
covers both trees.

**`python3 -m py_compile` wrote `__pycache__/` into the template tree, and two
checks then died with `IsADirectoryError`.** A gate that went red on its own
artefacts, with a traceback instead of a reason. The parse is now `compile()` —
the same check with no filesystem side effect — and both checks skip non-files
and *report* a stray directory rather than crashing on it.

The second is the more interesting finding, and it is the same lesson as the
comment bug above in a different costume: a check I added in this packet was, for
one commit, a check another check in the same packet could break.

## The self-test breakage

**19 → 20.** Breakage 19 is the unused allowlist entry, and it is
`expect_red_check` against the **named** check, because "the gate went red" would
not prove the unused-entry rule is what rejected it.

The entry it appends is well-formed in every *other* respect — reason, owner,
`since`, `until`, not a duplicate. It is only unused, which is precisely the
failure rule 4 exists to catch and precisely the one a shape-only check passes.
A hygiene rule in a data file is exactly the shape of a check nobody has ever
seen fail.

---

## A bug I found in my own check, by breaking the tree

I probed each new check by deliberately breaking a throwaway copy. Probe E
**failed**: deleting `-count=1` from the Go command left the check **green**.

The cause is the one AGENTS.md names — *a check that can be satisfied by a
comment is not a check*. The go step's comment block explains why the flag is
mandated and names it twice, so a plain substring test was satisfied by the
sentence explaining that removing it would be a mistake.

`strip_shell_comments` now removes comments while preserving `#` inside quotes
(`grep -qE '^ran[[:space:]]'` and `echo "::error::#1"` both survive), and it is
applied wherever a check greps a `run:` body. Both properties are now proven:
deleting the flag goes red, and neutering the demand grep with `true` goes red.

Every other probe went red as intended: unused entry, missing reason, expired
entry, one divergent demand step, `required-tier` defaulting to `0`, a language
with no tier directory, a declaration whose token was removed, and a workflow
caching `junit.xml`.

I also had one doc-fix-vs-check-fix call to make. The tier README table initially
used display names (`| Go |`) and the check wanted option values; the fix was to
make the check **parse the table's first column and strip backticks**, because
`f"| {lang} |" in readme` cannot match a backticked cell and the table is right
in every way a reader can check.

---

## What this cannot catch

Stated in `templates/tier/README.md` and in README, not just here.

**A test that runs but never touches the real dependency.** The machinery can
prove *"41 tests ran"*. Only an assertion inside the test proves *"41 tests hit
Postgres"*. Any claim that the tier gate "verifies the DB tier" means the first
thing, never the second. Every template in `templates/tier/` carries that
sentence next to the code, because a template that omits it teaches the wrong
lesson.

**A package filtered out of the run entirely.** The test that asserts the tier ran
lives inside the tier, so it cannot observe its own package's absence. Identity's
separate grep for its `--- PASS:` line is the right instinct — and it also fails
if the package is absent from the log. Only the inventory-vs-run set difference
catches it. Both are needed; neither is sufficient.

**A repo disabling its own guard.** Playwright's no-tests guard self-disables
under `--shard`: a scale feature silently disarming a correctness feature. **No
policy rule may be enforced by a flag the checked repo controls.** `required-tier`
is a *demand* on the runner and nothing more.

---

## Recommendations for the other five services — not applied

**Adopt `guard`'s pattern.** `GUARD_REDIS_REQUIRED` is the best of the six
current designs: it fails at tier-invocation time, before a report exists. The
other five should adopt it rather than each inventing a post-hoc report check.

**Stop grepping for the tier.** `identity`'s `dbtest.Pool|Schema|EnvVar|
TEST_DATABASE_URL` derivation **fails open**: a test reaching Postgres through
`db.Pool(ctx)` directly, a helper two files away, or a fixture is not matched, so
its package never enters the required list and the run is never required to
contain it. A new DB test written the "wrong" way is invisible to the gate. The
declaration per language is the fix and it is in
`templates/tier/<lang>/`.

**Relabel the floors.** `1254/1166`-style floors are cheap and catch deletion —
keep them. But a floor is satisfied by *any* 1254 tests including the wrong 1254.
It is a decrease detector, not a tier detector, and a doc that calls it a tier
gate is worse than a repo with no floor.

**`guard` first for the bun gap.** It is the one service where the missing piece
is a declared reason, and bun is the one language whose reporter I have measured
to be better than the general JUnit claim.

---

## What I could not verify

**No prior art was found for an owned, expiring skip allowlist.** I looked, and
did not find a project that ships one with all four rules — reason, owner, expiry,
and unused-entry-fails. Searches for skip-allowlist hygiene, expiring test-skip
registers, and the ESLint
`reportUnusedDisableDirectives` pattern did not turn up a project applying the
idea to *test skips* with an owner and an expiry. If this matters, treat it as
**novel rather than well-trodden**, and lean on the ESLint unused-directive rule
as the transferable idea rather than on any project I could cite. The four rules
are individually unremarkable; the combination, with expiry enforced by a clock,
is the part I cannot point at prior art for.

**The one-file allowlist is untested at the repos that would use it.** The packet
directs one file in kit, and I built that. The cost is real: a service that cannot
read kit's copy at run time — no submodule, no network inside the test step —
cannot use it without a second copy, and a generated copy is a drifting copy with
extra steps. I documented the cost rather than papering over it, but I have not
solved it, and no service in the fleet has yet needed to.

**The `caf gate` boundary is a claim, not a proof.** kit's check applies rule 4 to
the templates kit ships. That the same rule holds over a service's real run
depends on `caf gate` implementing the collector. I have not seen that code and
did not write it.

**Node's JUnit output was not measured.** bun's and minitest's were, because both
were named in the packet as gaps to state. `node --test-reporter=junit` was not
run, and the shipped `tier.test.ts` for bun and node are the one pair the gate
reports as a loud `SKIP`: stock `node --check` cannot read TypeScript, so two of
the files a service copies are files the gate cannot parse. That is stated in the
skip line, in the README, and here — a template kit cannot check is a template
that can ship malformed and nobody would know. Elixir's machine-readable output
was not measured either; ExUnit is known to report tags to a human, and the
allowlist says the adapter is unwritten rather than pretending otherwise.

**The expiry rule is untested against a real clock.** `until` is compared to
today's date, and the three shipped entries expire 2026-12-31. The comparison was
exercised with a past date (goes red) but no entry has yet expired on its own —
that happens in about three months, and someone should watch the first one.

**`REQUIRED_<TIER>` was not executed on a GitHub runner.** It is asserted
statically: the input exists and defaults to `''`, all seven jobs export it, all
seven demand steps are identical, and each looks for a `ran` line. The end-to-end
behaviour — a real service, a real skipped tier, a red build naming the variable —
has not been observed, because that needs a service repo adopting it.

**The `tier demand` step's `grep` is a format read, not a collector.** It looks
for `^ran` in the run log. A service that emits the normalised format satisfies
it; one that emits JUnit XML does not, and will fail with a message telling it
what to do. That is the intended failure direction, but it means the step is
only as good as the format's adoption, and adoption is six repos away.

**`no_cached_report_check` walks kit's own tree.** It cannot see the other five
services' workflows, so "there is a real hole in at least one service today"
remains unlocated.
