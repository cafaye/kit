# REPORT — kit-05-fanout

Stop hand-bumping `CORE_REF`: vendir + Renovate across the fleet, with a
breaking-change gate that fails closed and a staleness reporter.

Branch `worker/kit-05`. Gate: `bash tests/validate.sh` → **exit 0**, 109 checks
passed, 0 failed, 0 skipped.

---

## Before and after

| | before | after |
| --- | --- | --- |
| self-test breakages | 18 | **21** |
| breakages that went red | 18 | **21** |
| total gate checks | 94 | **109** |
| skips | 0 | 0 |

Three breakages added, and the middle one is the point of the packet:

| # | breakage | caught by |
| --- | --- | --- |
| 19 | `includePaths` nested under `git:` | `core fan-out` structural check |
| **20** | **the classifier made to FAIL OPEN** | `classify_test.sh` |
| 21 | the staleness reporter calls an undeclared pin `current` | `staleness_test.sh` |

Breakage 20 is the sharpest proof in the file. It does not break a check — it
inverts the fail-closed property and asserts the suite notices, so the property is
a counterexample rather than a claim in a comment. It also found a real defect:
the first version of it inverted a hardcoded `"FILE"` inside `classify.py`, and
**the suite stayed green**, because the same tier was *also* a rule in
`rules.json`. A property stated in two places is asserted in zero. Both facts now
live in `rules.json` alone and the counterexample is one token
(`unrecognisedIsBreaking: true`).

### A note on the gate command

The packet's GATE section says `mise x -- ./bin/prime`. There is no `bin/prime`
in `kit` — `templates/bin-prime/<lang>.sh` is what kit *ships*, and kit's gate is
`bash tests/validate.sh` per its own `AGENTS.md`. That line appears to be
carried over from a service-repo packet. I gated on the real one, and used
`${PIPESTATUS[0]}` (and variable capture) everywhere a status mattered.

---

## Deliverables

| deliverable | where | state |
| --- | --- | --- |
| `vendir.yml` for three consumers, three languages | `core/vendir/vendir.yml.{muse,pantry,caf}` | `muse`/`pantry` **proven byte-identical** by running vendir; `caf` proven *not* to migrate without a rename |
| template for the rest | `core/vendir/vendir.yml.template` | four marked changes |
| `renovate-config` content + setup steps | `core/renovate/` | two files + `SETUP.md` |
| what `core` needs to be taggable | `core/release/release.yml` | ships here, belongs in `core/.github/workflows/` |
| breaking-classification gate, failing closed, red proof | `tests/classify.py`, `tests/rules.json`, `tests/classify_test.sh` | 19 cases, incl. the fail-closed proof |
| staleness reporter, red proof | `tests/staleness.py`, `tests/staleness_test.sh` | 12 cases, incl. the red proof |
| self-test breakage for the fail-closed property | breakage 20 | red, and it found a real duplication |
| this report | — | including the required heading |

---

## What the measurement found — and it is not what I was briefed

I ran the staleness reporter against the real working tree before designing
anything:

```
core master: 39acaed6f1e25a895b0410e0689fe68d523b1b63

repository  pin           source    behind  state
muse        15e541cd9988  CORE_REF      19  behind
billing     -             none          ?  undeclared
guard       -             none          ?  undeclared
pantry      -             none          ?  undeclared
caf         -             none          ?  undeclared
```

Three things changed the plan:

1. **One repository declares a core pin, and it is nineteen commits behind.**
   The packet describes "twelve copies of that act". The code has one, in `muse`.
2. **`caf` and `pantry` hold vendored bytes with no recorded origin at all.** The
   packet's own literature puts 4.3% of vendored copies in that state; two of our
   own repositories are in it, today. The reporter says `undeclared`, which is a
   different statement from `current` and the only honest one.
3. **`billing` and `guard` fetch core at test time on purpose.** `guard`'s
   workflow says: *"The schema is fetched rather than vendored so this tracks what
   core publishes today instead of freezing a copy that silently goes stale."*
   Adopting vendir there means *introducing* a frozen copy — a policy change, not
   a migration. I did not write a `vendir.yml` for either, and `SETUP.md` says
   why.

Also measured: **three of the fleet's five parity guards skip** when the core
checkout they compare against is absent (`muse` `pytest.skip` without
`MUSE_CORE_SCHEMAS`; `pantry` returns early). That is independent of vendir and
more urgent than vendir.

---

## Verified against source or an actual run

Renovate claims, read from a sparse clone of `renovatebot/renovate` at
**`f998d68fd7e9846b243b3c2e2f0bbcb50b9de422`** (2026-09-30), not from docs:

| claim | verdict | evidence |
| --- | --- | --- |
| the vendir manager runs `vendir sync` and commits re-copied bytes in the same PR | **true** | `lib/modules/manager/vendir/artifacts.ts`: `await gitExec('vendir sync', …)` then `collectFileChanges(getRepoStatus())` |
| `http:` sources are `skipReason: 'unsupported-datasource'` | **true** | `extract.ts`, `extractHttpReleaseSource` |
| `git:` sources use the `git-refs` datasource with `ref:` as the pin | **true** | `extract.ts`, `extractGitSource` |
| `installTools: ['vendir']` is the right lever | **FALSE** | see below |
| `installTools` is permitted in inherited config | **true, and the mechanism is not the one assumed** | see below |

### The packet's flagged detail, resolved

> *Verify `installTools: ['vendir']` is permitted in inherited config before
> relying on it … if it is not inheritable the tool constraint moves to each
> repo's config, which is a real cost.*

The feared cost **does not arise**, and not for the reason the question assumed.

1. **`installTools` is the wrong lever, and the array form is invalid.** It is
   typed `Partial<Record<ToolName, …>>` and validated by iterating
   `Object.keys(val)` against `isToolName` (`lib/config/validation.ts:949`); the
   array `['vendir']` iterates the key `"0"` and is a configuration error. It is
   also scoped to `postUpgradeTasks` (`parents: ['postUpgradeTasks']`) and the
   vendir manager never reads it.
2. **The lever is `constraints`.** `artifacts.ts` calls
   `resolveToolConstraint(config, 'vendir')`, which reads
   `config.constraints?.vendir`; `lib/util/exec/index.ts` turns `toolConstraints`
   into `generateInstallCommands`, installing vendir from containerbase
   (`carvel-dev/vendir`, verified a valid `ToolName`). `constraints` is not
   `globalOnly`, so it is inheritable with no exemption needed.
3. **The flag to check is `globalOnly`, not `inheritConfigSupport`.** In
   `validation.ts:312-333` the inherited-config exemption is nested *inside* the
   global-option check, so `inheritConfigSupport` only ever exempts an option that
   is **also** `globalOnly`. `constraints` is not, so it never needs it.

### Two more corrections

- **`needsCodeChanges` does not exist** at `f998d68` — zero case-insensitive
  matches for "codechange" anywhere in `lib/`, and no such name in the option
  schema. F3's mitigation is therefore `labels: ['needs-code-change']` plus
  `automerge: false`, which is the better control anyway: a label is advice, a
  missing automerge is a mechanism.
- **`includePaths` and `newRootPath` are not modelled by Renovate's schema** —
  `schema.ts` has `GitRef = { ref, url, depth? }`. That is harmless, and worth
  knowing *why*: `doAutoReplace` is index-based text splicing on the raw file
  (`lib/workers/repository/update/branch/auto-replace.ts`, using
  `matchAt`/`replaceAt`), never a YAML re-serialisation. The zod parse is used
  only to *verify*. So the fields survive — and comments, and key order. The
  sharp edge is different: `replaceString` defaults to `currentValue` with
  `autoReplaceGlobalMatch` off, so **only the first occurrence of the tag is
  replaced** and a second pin to the same tag ends in
  `throw new Error(WORKER_FILE_UPDATE_FAILED)`.

vendir claims, all verified by **running vendir 0.46.2** (checksum-verified
against Carvel's published `checksums.txt`) against the real `cafaye/core`:

| claim | verdict |
| --- | --- |
| a semver tag resolves to that tag's tree, and the lockfile records the sha | **true** — run against a purpose-built repo with two tags whose contents differ |
| `includePaths` is a sibling of `git:` | **true** — and nesting it under `git:` is **silently ignored**: the sync vendors the *whole* upstream repo and **exits 0**. Run. |
| `includePaths: [schemas]` matches nothing | **true** — patterns are joined then matched with `doublestar.PathMatch`, which is exact. Loud failure. |
| `vendir.lock.yml` must be a sibling of `vendir.yml` | **true** — missing/empty means `return null`: the pin moves, the bytes do not. |
| `ref: v0.3.0` works against `cafaye/core` | **FALSE** — it has no tags. Run: `error: pathspec 'v0.3.0' did not match any file(s) known to git`. |
| vendir can rename a file | **FALSE** — no rename field in `pkg/vendir/config/directory.go`. This is why `caf` cannot migrate as-is. |

oasdiff, by **running the binary** (v1.32.1, checksum-verified):

- **"755 distinct detected changes" is exactly right.** `oasdiff checks changelog`
  prints 755 level-tagged checks: 399 `info`, 339 `err`, 17 `warning`. Its docs
  say only "hundreds".
- The 17 `warning` checks are precisely the "cannot be confirmed programmatically"
  set — the natural material for a fail-closed policy.
- Go, Apache-2.0, static per-platform binaries, and `oasdiff/oasdiff-action` is
  live (last push 2026-09-15). All confirmed.

The negative finding is **stronger than three web searches**: grepping
`lib/modules` and `lib/workers` at `f998d68` for
`staleness|freshness|outdated-copy|vendored.*drift` returns **zero** matches
across 118 managers. Renovate's output unit is a pull request per repository;
there is no cross-repo artifact to hang a fleet report on.

---

## What I could not verify

Required heading. Everything here is a claim I am **not** making.

1. **No Renovate run happened.** Every Renovate statement above is read out of
   source at `f998d68`. I did not observe a single pull request moving a pin and
   re-copying bytes. `core/renovate/SETUP.md` step 5 exists to make that the
   first thing the next person does, and step 4 lists what to look for in
   `renovate --dry-run` before onboarding a second repository.
2. **Inherited config was never resolved at runtime.** The answer to the
   packet's flagged question rests on reading `validation.ts` and
   `lib/config/index.ts`, not on watching Renovate apply the config. The
   reasoning is sound and the mechanism is explicit, but "checked in source" and
   "observed running" are different claims and only the first is true.
3. **Web search was unavailable in this environment.** The packet cites "three
   searches" establishing that no off-the-shelf vendored-copy staleness tool
   exists. I could not run them. I substituted a stronger, source-level negative
   over Renovate's own registries, and I have **not** independently confirmed the
   wider claim about the rest of the ecosystem.
4. **The citation figures in the packet are unverified.** The 155-day median
   staleness, 4.3% / 2.0% provenance rates, and the gdal/LibTIFF 3-day →
   61-day / 20,768-repository case are repeated from the packet and from
   `moon/DECISIONS.md` MD11. I did not go to those sources. They are the packet's
   evidence, not mine.
5. **`core` will publish tags: unproven.** The *tag mechanism* is proven —
   against a purpose-built repository, where `ref: v0.3.0` copied the v0.3.0
   bytes and the lockfile recorded the sha. The *failure* path is proven against
   the real `cafaye/core`. What is unproven is that `core/release/release.yml`
   runs correctly, and that Renovate proposes tag bumps once tags exist. All
   three templates therefore say `ref: master`, and the gate reports that as a
   `note:` rather than a failure — a note, because failing it would be failing
   the correct state.
6. **The classifier has never seen a real core diff.** It is tested against 19
   fixtures including the fail-closed case, and against a real `vendir sync` of
   core's `schemas/`. The first real spec change is still its first real input.
7. **`caf`'s migration is unproven end to end.** The bytes are identical
   (sha256 `9f90b370…`, measured on both sides) and vendir provably cannot
   rename, so the rename is required. I did not perform it — it is nine
   references in `caf`, which I must not touch. Whether `caf` should migrate at
   all is `caf`'s decision, and its own `contract_test.go` drift guard is the
   thing that makes the decision safe.
8. **`--github-org` discovery was never exercised.** It is implemented and it
   reads a token from the environment without echoing it, but I used the
   filesystem path exclusively and **used no token at all** — including not
   logging one, not putting one in a URL, and not reading one from this
   environment.
9. **Three of the five parity guards still skip.** I found this; I did not fix
   it. The fix belongs to `muse` and `pantry`.
10. **The tier comparison is subtle and I changed the documentation to match the
    code, not the reverse.** With cumulative tiers, a `--tier FILE` consumer is
    the *most* protected and a `--tier WIRE` consumer fails on every breaking
    change. That reads backwards until you check it, it is asserted by four test
    cases, and `rules.json` now states the index arithmetic explicitly. But it is
    my reading of buf's semantics, not buf's documentation, and someone who reads
    buf will disagree with at least the phrasing.
11. **`oasdiff` was never run on a real OpenAPI pair.** I ran its catalogue
    command, which is what the 755 figure comes from. I did not run `oasdiff
    breaking` on two documents, so the severity-level mapping is inferred from the
    output format rather than observed.
12. **A latent upstream inconsistency I did not report upstream.** The vendir
    manager declares `supportedDatasources = [helm, docker]` while its extractor
    emits `git-refs` and `github-releases` dependencies. I verified the field is
    **never read** — zero property-access consumers in `lib/` — so it does not
    filter, and the `git-refs` path is covered by Renovate's own
    `extract.spec.ts`. It is still an inconsistency, and I did not open an issue.
13. **`git subtree` was not re-litigated, only recorded.** The packet's rejection
    is right and I have stated it once in `core/README.md`; I did not go looking
    for a counter-argument.

---

## Judgement calls worth challenging

- **`core/` contains two programs, in a repository whose rule is "config only".**
  I judged a standard nothing enforces is not a standard, and bounded the
  exception explicitly in `AGENTS.md`: stdlib only, nothing imports them, no
  committed output, and a stated default answer of "no" for a third. If you would
  rather they lived in `core` itself, that is a reasonable disagreement and the
  move is mechanical.
- **The gate treats a `ref: master` in a template as a note, not a failure.**
  Failing it would mean the gate is red in the correct state, which teaches
  people to ignore it.
- **`documentation-changed` and the set-reorder rule are the only two escapes
  from fail-closed, and both are argued in `rules.json`.** A third would have to
  argue for itself in the same file. A gate that is red on a cosmetic diff is a
  gate that gets switched off.
- **I did not write `vendir.yml` for `billing` and `guard`.** Adding one would
  replace a decision their authors made and documented with a default.
