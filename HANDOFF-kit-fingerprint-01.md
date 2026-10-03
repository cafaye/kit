# HANDOFF — kit-fingerprint-01

Date: 2026-10-03. Branch: `worker/kit-fingerprint-01`. Base `7ab60ee`.
Four commits: `e34df0f`, `d0d575a`, `b6ce258`, plus `.gitignore`.
Report: `REPORT-kit-fingerprint-01.md`.

## What the packet was for

kit's gate was measured, filtered and sharded, and had **no cache**: every run
redid every check. This packet built the fingerprint manifest (P0-3), the
skip (P0-4), the one-record-one-run rule (P0-1), got P0-2 for free by hashing
in one process, wired it to one real gate, and **proved by running things** that
the skip cannot hand back a green for work it did not do.

## The numbers, in one line

`--only=fetch`: **17.29s cold → 8.31s on an identical second run (52%)**, and
**15.13s with 0 skips after one byte changed in one declared input**. Whole-gate
before-number on the same tree: 76.69s.

## What is here

| file | what it is |
|---|---|
| `tests/fingerprint.py` | manifest, fingerprint, lookup (4 exit codes), record, diff, list |
| `tests/fingerprint_test.sh` | 22 counterexamples, **including the green control that proves the skip can lie** |
| `tests/validate.sh` | `kit_cached_check` + `bounded_check` publishing its outcome; `fetch_test` wired; `fingerprint_test` registered as a check |
| `tests/self_test.sh` | breakage 101: the outputs conjunct deleted, and caught |
| `.gitignore` | `.kit/cache/` |

## What I learned

- **P0-4's second clause is the only hard part, and it is cheap.** "Same hash
  **AND** outputs still on disk". Comparing the *set of paths* the output globs
  match — not their contents — is moon's `hash_output_globs`, and it costs a glob
  rather than a re-hash. Proof 1a asserts exit 1 on a deleted output; proof 1c
  restores it and asserts exit 0, so 1a cannot be passing for the wrong reason.
- **A fail-closed declaration paid for itself immediately.** My first wiring
  named `templates/bin/dev`, which does not exist. The manifest refused to
  build, named the file, and the tier ran uncached with the reason in the gate's
  output. A silent miss would have been invisible; a raised one is loud and the
  skip was off for the whole run rather than quietly wrong for one tier.
- **The dangerous failure mode is an incomplete declaration, not a bad
  implementation.** Proof 7a: omit the file the check reads, mutate it, and the
  cache returns HIT. Correct implementation, green that is not true. Every claim
  about this mechanism is downstream of declaration quality, and the report says
  so where a successor will actually read it.
- **The `self_test` win is a one-line env var away and a hundred declarations
  away from happening.** 94 copies × ~113 checks. Point `KIT_CACHE_DIR` at one
  shared directory and copy 57 skips what copy 23 already ran — P0-1 arriving as
  a side effect of P0-4 rather than as a second mechanism. That is the whole
  trick, and it is not switched on because 113 declarations nobody has written is
  exactly the place a false green would come from.

## What I ruled out, and why

- **Sharing `caf lock`'s hashing.** Cannot: it is Go, in a sibling checkout a
  kit clone does not contain, and a gate that shells out to a sibling is not
  hermetic (and would break `lint drift` for anyone who cloned kit alone). What
  IS shared is the decision `doc.go` already wrote down — sha256 over raw bytes,
  no git, no timestamp in the hashed material, a hand-bumped version for
  wholesale invalidation — plus the salt-as-a-field rule (`version`/`tool`/
  `schema` live *inside* the hashed bytes, so there is no salt prefix at all).
- **Wiring `self_test` itself.** Its cost is 94 throwaway *copies* of the static
  phase and each check inside a copy is cheap, so a per-check cache saves little
  until the copies share a cache. Wiring it half-way would have produced a number
  too small to be worth the risk of an undeclared input.
- **Keying the record by fingerprint rather than by check.** It would make run 4
  (edit then revert) a hit instead of a miss. It is also a directory that grows
  without bound and expires nothing. The miss is the cheaper failure and it is
  visible.
- **In-flight dedup** (dagger's concurrency key). Two concurrent gates still both
  run a cold tier. The record write is atomic via `os.replace` so the loser is
  harmless, but the work is duplicated. Packet C.

## Blocked, and the successor should know

**`KIT_SELF_TEST_SHARD` cannot start on this tree, for any shard.** Breakage 98's
recipe edits `CHANGELOG.md`'s `## Unreleased\n\n_(nothing yet`, and that text is
gone; `edit` runs **eagerly, outside the shard guard**, so one stale recipe stops
every shard. Pre-existing, and not mine to fix here: `edit` is the harness's
earliest-loading code and making it lazy is a change to self_test's editing
discipline.

So breakage 101 was verified by applying the identical mutation to a copy of
`tests/fingerprint.py` and running `tests/fingerprint_test.sh`: **22/22 → 20/22**,
with 1a and 1b red and the diagnostic reporting `got 0` where 1 was required.

## The successor's first three moves

1. Make `edit` lazy or shard-aware so a stale recipe in one shard cannot stop the
   others, then run `KIT_SELF_TEST_SHARD=101/101` and confirm breakage 101 goes
   red in place.
2. `KIT_PROFILE=/tmp/p.tsv bash tests/validate.sh --only=<one child check>` and
   read the **child gate's own** `check` rows. `PROFILE-gate.md` says explicitly
   that it does not know where the time goes inside a child gate — do not pick
   the first ten checks to declare from the outer table.
3. Then: `KIT_CACHE_DIR` shared from `self_test.sh`, and declarations, cheapest
   first, in the order the profile names. **Promote each check to a declared
   output glob as soon as it has an artefact** — `fetch_test` is wired with none,
   which is sound but is the weaker of the two cases.

## Open questions

1. **Should a check with no declared outputs be cacheable at all?** kit says yes
   (and `fetch_test` demonstrates it). The stricter rule — no declaration, no
   caching — is more defensible and would have refused the one gate this packet
   wired.
2. **The record's `stdout` is an output the check never declared.** It is what
   makes a hit informative instead of silent (proof 0c), and it has no size cap.
3. **The shared-cache-across-94-copies assumption is exactly proof 7a's
   failure.** It is sound only because every mutation changes some file's
   *content* and therefore some declaration's fingerprint. This is the single
   biggest risk in the rollout and it has no automated guard yet.

## State of the worktree

Green. `bash tests/fingerprint_test.sh` → 22/22. `bash tests/validate.sh
--static-only --only=fetch` → PASS with the skip on the second run. The full
`--static-only` gate was measured before the wiring (76.69s, PASS) and not
re-measured after, for want of clock; nothing in the diff touches a check other
than the two named above. `.kit/cache/` is gitignored.