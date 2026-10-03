# REPORT — kit-fingerprint-01: the fingerprint manifest, and the skip it buys

Date: 2026-10-03. Branch: `worker/kit-fingerprint-01`. Base: `7ab60ee`.
Commits: `e34df0f` (mechanism + proof), `d0d575a` (wiring + numbers),
`b6ce258` (breakage 101), plus `.gitignore`.

For someone who has not seen the packet: kit's gate is measured, filtered and
sharded, and there was no cache, so every run redid the work. This is the
cache. It is one fingerprint manifest, one record store, one skip decision, one
gate wired to it, and the proof — run, not asserted — that the skip cannot hand
back a green for work it did not do.

---

## 1. The before and after numbers

All on this box, same tree, paired. This box runs several kit gates at once, so
absolute seconds are worse than `PROFILE-gate.md`'s 42.70s for a child gate; only
the ratios are claimed.

### The whole static gate, before any cache existed

| | measured |
|---|---:|
| `bash tests/validate.sh --static-only`, warm venv, commit `e34df0f` | **76.69 s** |

That is the before-number, and it is deliberately the same tree the after-numbers
come from. A second identical before-run was started and abandoned at 106s when
the packet's clock ran out; it was not wrong, it was just not needed, since the
claim being made is about the *difference* between a run with records and a run
without.

### The wired gate, `--only=fetch`, four runs

| run | state | wall clock | tier skipped |
|---|---|---:|---:|
| 1 | cold, no record — full work, then writes a record | **17.29 s** | 0 |
| 2 | **identical second run** | **8.31 s** | **1** |
| 3 | **one byte added to `templates/bin/dev.sh`** — a declared input | **15.13 s** | 0 |
| 4 | the byte removed again | 15.15 s | 0 |
| 5 | unchanged since run 3 | 9.22 s | 1 |

Read that as three claims, all measured:

- **A second identical run does materially less work: 17.29 s → 8.31 s, 52%.**
  The skip line the run prints names the gate and the clause:
  `(skipped: the fingerprint is unchanged and the declared outputs are still on
  disk — tests/fetch_test.sh)`.
- **A run after a real edit does the full work again: 15.13 s, 0 skips.** One
  byte, in one declared input, is enough.
- **Runs 4 and 5 are the single-record design showing its conservative face.**
  The record is keyed by *check* and holds *one* fingerprint, so reverting an
  edit is a new fingerprint against a record that does not describe it — a
  miss. Run 5 hits, so run 4 was the design and not a wedge. The alternative, a
  record per fingerprint, is a directory that grows without bound and expires
  nothing.

### Why `fetch_test` and not `self_test`

`PROFILE-gate.md` puts `self_test` at ~85% of the filtered set and this packet
does **not** make that number better, and it would be dishonest to imply
otherwise. `self_test`'s cost is 94 throwaway *copies* of the whole static
phase; each check inside a copy is individually cheap, so a per-check cache
saves little until the 94 copies share a cache directory, which requires 94 ×
~113 correct input declarations that nobody has written. That is §5, the
rollout, and it is a list of declarations rather than a flag.

`fetch_test` was wired because it is a real tier the profile measured at 6.83s,
because it is the tier whose subject is a *fetched tree* — a work product rather
than a verdict — and because it is reachable through `--only`, so the before and
after are 30-second experiments rather than 15-minute ones. It is the smallest
honest demonstration, not the largest available one.

---

## 2. The fingerprint's schema

One JSON document, built by `tests/fingerprint.py manifest`, hashed over its own
canonical serialization (`sort_keys`, no insignificant whitespace, UTF-8).

| field | what it is | why it is there |
|---|---|---|
| `version` | `1`, bumped by hand | the fingerprint format. Bumping it invalidates every record at once, which is what a wholesale invalidation *is* |
| `tool` | kit's `VERSION` file at write time | a record from another kit build is refused rather than honoured (§3.4) |
| `check` | the stable id — `tests/fetch_test.sh`, the same string `--only` matches | P0-1: one id, written once, read by three callers |
| `command` | the exact argv | an edited command line cannot hit |
| `inputs` | `[{path, sha256}]`, sorted, content-addressed | P0-3: the *declared* manifest, hashed by bytes |
| `outputs` | the declared output globs | P0-4's second clause has something to be about |
| `env` | `NAME=VALUE` literals plus `--env-from` names resolved at run time | a check whose behaviour depends on a variable nobody declared would hit a record earned under a different value |

The **record** adds `schema`, `exit`, `output_paths`, `output_paths_hash`,
`stdout` (the replayed evidence) and `written_at`.

Three decisions that are not obvious:

- **Content, never mtime.** A cache key built from mtimes is a guess about the
  future; a fingerprint is a list somebody wrote down, auditable in the same
  commit as the check it guards.
- **The outputs clause compares the *set of paths* the globs match, not their
  contents** — moon's `hash_output_globs`, for the same reason: the question is
  "is the same work still here", and re-hashing every output would make the
  check cost as much as the work it skips.
- **No timestamp inside the hashed material.** `caf lock`'s rule: two locks over
  one tree must produce the same bytes, or a diff between two manifests becomes
  a diff between two runs. `written_at` is in the record, outside every
  comparison. Proof 6a checks this by building two manifests a second apart.

### Where the record lives, and why it is overridable

`$KIT_CACHE_DIR` if set, else `.kit/cache/gate` under the tree (now gitignored).
The override exists for `self_test`: a cache scoped to a throwaway copy is
deleted with the copy and can never be hit by the copy after it. One shared
cache directory is what lets copy 57 skip the checks copy 23 already ran — P0-1
arriving as a side effect of P0-4 rather than as a second mechanism. That is the
rollout's whole trick and it is not switched on.

### Is this a second sha256 with a different salt?

**No, and here is the precise answer to "can the hashing be shared".**

`caf lock` (`cafaye/caf/internal/lock/`) already decided this in this fleet and
wrote down why (`doc.go`, "The hash is of the bytes, and the lock is not about
git"): SHA-256 over raw file bytes, no git blob ids, no index hashes — because
a pin that can only be verified inside a checkout cannot be verified in the
tarball a release ships or in a Docker build context — and no timestamp, so two
locks over one tree are byte-identical.

**The code cannot be shared.** `caf lock` is Go, in a sibling checkout that a
kit clone does not contain, and a gate that shells out to a sibling checkout is
not hermetic — it would also fail `lint drift` resolution for every adopter who
clones kit alone. So each language keeps its own twenty lines over the stdlib
primitive (`hashlib.sha256` here, `crypto/sha256` there): **same algorithm, same
discipline, one implementation per language.**

**The salt is a field, not a prefix.** `version`, `tool` and `schema` are inside
the bytes being hashed, so a fingerprint computed by a future kit cannot collide
with one computed by this one even over identical inputs. Nothing is prepended.

### P0-2 came for free

`manifest` hashes every declared input **in one interpreter**. The obvious bash
spelling is `for f in $inputs; do shasum "$f"; done` — one process per input
file, which is exactly the process-spawn cost P0-2 names. The loop here is a
loop over bytes.

---

## 3. The four ways it is proven unable to lie

`tests/fingerprint_test.sh` is **22 counterexamples, not 22 confirmations** — in
every case a cache that says HIT against a tree whose honest answer is "run it".
Registered as a check in `validate.sh`, so it runs with the gate.

**Four exit codes, and none of them is "crash":** `0` hit, `1` miss, `2`
corrupt, `3` foreign. Every non-zero means *run the check*. Corrupt is its own
code so it is not indistinguishable from a cold cache in the logs.

| # | proof | asserted |
|---|---|---|
| 1 | **outputs deleted, fingerprint unchanged** | exit **1**. P0-4's second clause: "same hash **AND** outputs still on disk". The outputs were deleted, so this is not a hit — and proof 1c then restores them and asserts exit 0, so 1a was about the outputs and not about a wedge |
| 2 | **one byte of one declared input** | exit **1**. One character, same file length, `1.0` → `2.0`. Also 1b: a *different set* of outputs is a miss too, and 2c: `diff` names the file, and 2d: reordering the declaration is not a change |
| 3 | **a corrupt or truncated record** | exit **2**, four ways: truncated mid-object, binary garbage, well-formed JSON with a wrong-typed field, and — the one a `json.load` cannot see — **a valid record whose `fingerprint` field lies** about the manifest beside it |
| 4 | **a record from another kit version** | exit **3**. `tool` set to another version: refused. `schema` set to 99 under this kit's version: refused by name. Both are records that would otherwise be a green |
| 5 | a recorded FAILURE | exit **1**. moon's first conjunct; a cache of failures would make the next run red for a reason nobody can reproduce |
| 6 | determinism, and a declaration with a hole | two manifests a second apart agree; a manifest naming an absent input is **refused, named, never hashed** |
| **7** | **THE GREEN CONTROL** | see below |

### 7 — the control: the skip is provable able to be WRONG

Everything above proves the mechanism enforces what it was told. Proof 7a proves
the thing that actually matters: **a declaration that omits the file the check
reads still returns HIT after that file changes.** The tree is mutated, the
fingerprint does not move, and the cache hands back the old PASS — a lie,
produced by a correct implementation of the contract.

No amount of hashing repairs an omission. A fingerprint can only be as complete
as its declaration, and **this is the rollout's real risk**: a gate wired to a
check whose declaration misses one input is not "probably fine", it is a green
light wired to a switch that was never connected, and it surfaces as a broken
build somewhere else entirely. Proof 7b says so in the suite, so a successor
reading only the test file learns it.

### And in self_test's own idiom: breakage 101

`tests/self_test.sh` has 100 breakages and every one proves *a check can fail*.
None proved *a cache can be caught failing*, which is the property this packet
is buying. Breakage 101 deletes the outputs conjunct outright:

```
edit kit-101/tests/fingerprint.py \
  '    if now_paths != record["output_paths"]:' '    if False:'
expect_red_check 'breakage 101: the outputs conjunct is deleted from the skip,
  so a cache with no work on disk still answers HIT' "$base101" 'fingerprint_test'
```

**Run, and it is red.** `tests/fingerprint_test.sh` goes **22/22 → 20/22**:

```
FAIL 1a. SAME fingerprint, outputs DELETED -> RE-RUN (the second clause) (wanted exit 1, got 0)
FAIL 1b. SAME fingerprint, a DIFFERENT set of outputs -> RE-RUN (wanted exit 1, got 0)
PASS 1c. outputs restored -> HIT again, so 1a was the outputs and not a wedge
```

`got 0` is the silent green P0-4 exists to prevent. Everything else in the cache
survives that mutation — cold is still a miss, a changed input is still a miss, a
corrupt record is still refused, a foreign version is still refused — so the
clause is invisible to every other proof, which is exactly why it needed its own.

---

## 4. Two failures this tree produced on itself

Both cost minutes and both are the mechanism earning its keep.

**A declaration naming a file that does not exist.** The first wiring named
`templates/bin/dev` (it is `templates/bin/dev.sh`). The manifest **refused to
build, named the absent file, and the tier ran uncached with the reason printed
into the gate's own output**:

```
note: the fingerprint declaration for tests/fetch_test.sh did not build, so this
tier ran uncached. The declaration is:
  fingerprint: declared input does not exist: templates/bin/dev (a manifest may
  not name a file that is absent — that is how a cache starts lying)
```

A silent miss would have been invisible; a raised declaration is a loud one, and
the skip was off for the whole run rather than quietly wrong for one tier.

**The record's own name.** A check id is a *path* (`tests/fetch_test.sh`), so it
cannot be a filename. The slashes are now folded in both the manifest name and
the record name, so the two cannot disagree about the fold.

---

## 5. What was NOT finished

### The rollout, as a list of declarations

The mechanism is built for `self_test` and does nothing for it yet. The list:

1. **Point `KIT_CACHE_DIR` at one shared directory** from `self_test.sh`. One
   line; without it 94 copies each keep a cache that dies with them.
2. **Write the declarations.** ~113 checks per child gate × 94 copies. This is
   the entire remaining cost, and it is why the rollout is a list rather than a
   flag: an incorrect declaration is a false green (proof 7a).
3. **Start with the checks `PROFILE-gate.md` names inside a child gate** —
   which it explicitly does not know, because it only profiled the outer gate's
   own rows. **Whoever continues should run
   `KIT_PROFILE=… bash tests/validate.sh --only=<one child check>` and read the
   child gate's own `check` rows before choosing.** Do not guess.
4. **Promote a check to the strict outputs clause as soon as it has an artefact.**
   `fetch_test` is wired with **no declared outputs** — it builds its fixtures in
   a `mktemp` tree — so its hit rests on the fingerprint and the recorded exit,
   not on the second conjunct. That is *sound* (it is a pure predicate over its
   declared inputs) but it is the weaker of the two cases, and the difference
   should be visible in the declaration rather than remembered. The promotion
   rule: any check that writes a real artefact declares it as a glob and gets
   P0-4's second clause for free.

### Blocked, and not by this packet

**`KIT_SELF_TEST_SHARD` cannot start on this tree at all**, so breakage 101 has
not been run *through the shard runner*. Breakage 98's recipe edits
`CHANGELOG.md`'s `## Unreleased\n\n_(nothing yet`, and that text no longer
exists, so `edit` exits — and `edit` runs **eagerly, outside the shard guard**,
so one stale recipe in one shard stops every shard. That is a pre-existing
harness defect and fixing it is a change to `self_test`'s editing discipline,
which this packet already touches; it was written up rather than fixed. The
verification in §3 was done by applying the identical mutation to a copy of
`tests/fingerprint.py` and running `tests/fingerprint_test.sh` against it.

The successor's first two moves: fix `edit` to be lazy (inside the shard guard,
or at minimum a loud skip rather than `exit`), then re-run
`KIT_SELF_TEST_SHARD=101/101`.

### Also not done

- **Not a runtime speed gate.** Nothing here can turn a check green on its own.
  `KIT_FINGERPRINT=0` disables the skip and the gate behaves exactly as before.
- **No eviction.** One record per check; the cache cannot grow without bound
  because it is one file per check, and it is never stale by construction (the
  fingerprint is the staleness test).
- **No in-flight dedup** (dagger's concurrency key, packet C). Two concurrent
  gates still both run a cold tier and both write the same record; the record is
  written atomically via `os.replace`, so the loser is harmless, but the work is
  duplicated.
- **`moon hash --diff` equivalent is hand-rolled** (`fingerprint.py diff`, proof
  2c) rather than reusing a tool, for the same reason the hashing is not reused.

### Open questions

1. Should a check with **no declared outputs** be cacheable at all? The packet's
   wording ("outputs still on disk") presupposes outputs exist, and moon allows
   the vacuous case. kit allows it today, with the record showing `outputs: []`.
   The stricter rule — no declaration, no caching — would be more defensible and
   would have refused the `fetch_test` wiring; it was not adopted because it
   would have made the packet's one wired gate impossible to demonstrate.
2. **Is the record's stdout the right "output" for a pure predicate?** It is
   what makes a hit informative rather than silent (proof 0c), but it is an
   output the check did not declare, and the record could grow without bound if a
   chatty check were ever wired. A size cap on `stdout` is probably wanted.
3. `self_test`'s 94 copies are **fresh copies of a mutated tree**; a shared cache
   across them is sound only because every mutation changes some file's *content*
   and therefore some check's fingerprint — provided the mutation is on a file
   some declaration names. **Proof 7a is exactly the failure of that
   assumption**, and it is the single biggest risk in the rollout.