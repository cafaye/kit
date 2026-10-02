# HANDOFF — kit-sweep-scope-01

**State: the packet's one thing is DONE and verified in both directions. Nothing
is half-done. The only outstanding item is the full `self_test` phase, which was
still executing its 94 breakages when the hour ended — recorded verbatim in §4
rather than reported as a pass.**

Branch `worker/kit-sweep-scope-01`. Three commits on top of `f5d4238`:
`0e1d4c1`, `0c4aa38`, `af01845`. Nothing pushed, nothing merged, nothing tagged.

Report: `moon/logs/REPORT-kit-sweep-scope-01.md`.

## 1. Done and verified

- **`cafaye.unprotected_tables/0` is scoped to the schemas the substrate was
  applied in**, plus `cafaye` and the session's temporary schema. It was scanning
  every table in the database, which made the assertion set assume it owned the
  database.
- **The scope is derived from `pg_policy`**, not recorded in a registry table, so
  an adopter gets the fix by re-copying two files and **needs no migration**. This
  is the load-bearing design decision — see report §2.
- **Two new assertions in `tests/tenancy_test.sh`, `0b` and `5`**, which measure
  the scope in both directions. `0b` alone would be satisfiable by a sweep
  narrowed to `pg_temp`; `5` is what makes the pair a control.
- `sweep/the-only-finding-is-the-control` now has an explicit `order by` in its
  `string_agg`, so a text-expected value is not at the planner's discretion.
- Prose in `substrate.sql`, `isolation.sql`, the tenancy `README.md` and
  `CHANGELOG.md` now describes the scope that exists.

**No assertion NAME changed.** `assertions.txt` and the six drivers are
byte-identical.

**No enforcement changed.** Verified mechanically — the only changed non-comment
lines in `substrate.sql` are the two inside the sweep function:

```
$ git diff f5d4238 -U0 -- templates/database/tenancy/substrate.sql \
    | grep -E "^[-+]" | grep -v "^[-+][-+]" | grep -vE "^[-+]\s*--" | grep -vE "^[-+]\s*$"
+  with scoped(nspname) as (
+    select 'cafaye'::name
+    union
+    select n.nspname
+      from pg_namespace n
+     where n.nspname = 'pg_temp' or left(n.nspname, 8) = 'pg_temp_'
+    union
+    select n.nspname
+      from pg_namespace n
+      join pg_class c on c.relnamespace = n.oid
+      join pg_policy p on p.polrelid = c.oid
+     where c.relkind = 'r'
+       and p.polname ~ '_cafaye_(select|insert|update|delete)$'
+  )
-    and n.nspname not in ('pg_catalog', 'information_schema', 'pg_toast', 'cafaye')
+    and n.nspname in (select s.nspname from scoped s)
```

## 2. The one thing to check before merging

**I edited `templates/database/tenancy/substrate.sql`, which the packet's
constraint named only as "do not touch substrate.sql's *enforcement*".** The root
cause is a function in `substrate.sql` (`unprotected_tables()`); the packet's own
constraint line also names `isolation.sql` as the file to stay in, and those two
cannot both be right. I read the constraint as excluding enforcement — the
function bodies of `protect_table`, `begin_account`, the policy DDL, `FORCE` — and
as not naming `isolation.sql` exclusively by accident. The argument is report §3.
**If that reading is wrong, this is a one-file-too-wide diff and the successor
should decide it before merging**, because the alternative (filtering at the three
call sites in `isolation.sql`) leaves a function kit documents as answering "is
this service isolated?" still wrong for anyone who calls it directly.

## 3. Half-done, and why

Nothing in the packet's scope. Two things are *not* done and are deliberately so:

- **No `self_test.sh` breakage for the new scope.** `tests/self_test.sh` belongs
  to `worker/kit-gate-speed-01`, which has diffs in it. The two-sided control
  lives in `tests/tenancy_test.sh` instead, where it runs against a real cluster
  on every gate — a stronger place than a throwaway copy with no database. The
  successor should add the recipe once that branch merges (report §7).
- **Identity is untouched.** It is another session's repository and branch. It
  needs two file copies and no migration (report §7).

## 4. The currently-running command and its real output

**Not failing — still running.** The full gate's `self_test` phase is *n* whole
gates in sequence and this machine runs several kit gates at once; kit's own
`AGENTS.md` records that it hits its 90-minute bound on a busy box and that a
`BOUND` verdict is not evidence about the breakages it never reached.

From the correctly-placed worktree (`moon/cafaye/wt-m39-kit-sweep-01`, the same
commit, detached — the nested worktree the manager created cannot see a fleet):

```
$ bash tests/validate.sh
...
PASS lint drift  (a service config is compared to kit, not merely forbidden)
...
PASS lint_test — 14 assertions; every linter ran with kit's config and rejected a bad file.

-- self_test: this gate is able to fail
PASS tests/self_test.sh  (every documented breakage has a recipe, and vice versa)
```

`grep -c '^FAIL' /tmp/kt-gate2.log` = **0** at the point the hour ended. The run
had reached the `self_test` phase with no failure of any kind.

**The tenancy proof itself is finished and green**, and is the gate that covers
this change:

```
$ bash tests/tenancy_test.sh
...
== assertion 0b: an adopter's fixture schema is present, and out of the sweep's scope
   2 unprotected account-scoped tables in kit_neighbour_fixture, and the sweep names neither.
== assertion 1: every assertion in templates/database/tenancy/isolation.sql passes
   24 assertions, all pass
== assertion 4: the proof returns EXACTLY the assertions assertions.txt names
   24 assertions, named identically in both files
== assertion 2: the CONTROL — same proof, FORCE ROW LEVEL SECURITY removed
   without FORCE: 6 assertion(s) red, every one of them an owner/ or sweep/ assertion
== assertion 5: the sweep still names an unprotected table in a schema the substrate OWNS
   named it: sweep/every-account-scoped-table-is-protected and
   sweep/the-only-finding-is-the-control both went red.
== assertion 3: the (select ...) wrapping, measured
     (select …) wrapped:  1
     bare call:           5

PASS: kit's account boundary is enforced by Postgres, and the enforcement is proven able to fail.
EXIT=0
```

## 5. A finding about the worktree, and a warning about it

**The worktree this packet was given was at
`cafaye/kit/cafaye/wt-m39-kit-sweep-scope-01` — nested INSIDE the kit repository,
not beside it — and it was removed from under this session partway through.**
Both are worth recording.

**Nested inside `kit` makes two gate checks unable to see anything.** `lint drift`
FAILED there with *"no cafaye service checkout was found beside this one"*. From
a worktree beside `kit`, the same commit at the same `HEAD`, **PASSES**:

```
$ grep -n "lint drift" /tmp/kt-gate2.log
2360:PASS lint drift  (a service config is compared to kit, not merely forbidden)
```

The check globs `$ROOT/..`, `$ROOT/../..`, `$ROOT/../../cafaye` and skips
worktrees by design (`is_worktree()`), so from inside kit every candidate it
finds is a worktree of kit itself. `fleet_check.py` and
`gate_declaration_check.py` have the same shape. Anyone reading `logs/` will find a
red `lint drift` attributed to this packet: **it is placement, and re-running the
gate beside `kit` clears it.**

**The directory was emptied mid-session.** The worktree lost its `.git` pointer
file and its contents while `validate.sh` was running inside it, so git fell
through to the parent `kit` repository and reported an unrelated in-progress
merge (`CHANGELOG.md` unmerged, plus other packets' files) as this packet's
working tree. **The three commits were never at risk** — they were on
`worker/kit-sweep-scope-01`, and `git log worker/kit-sweep-scope-01` was intact
throughout. The branch has been re-attached to a worktree beside `kit` at
`moon/cafaye/wt-m39-kit-sweep-01`, which is where the successor should work.

The lesson for whoever schedules these: **a worktree must not be created inside
the repository it is a worktree of.** `cafaye/kit/cafaye/…` is that mistake, and
it is invisible until a check that reads a neighbouring repository returns
nothing and says so.

## 6. The successor's first move

1. **Re-run `bash tests/validate.sh` from `moon/cafaye/wt-m39-kit-sweep-01`**
   (the branch is checked out there) and confirm `self_test` reaches its end
   verdict. Nothing in the diff predicts a failure there; the tenancy proof, the
   tenancy contract check and `lint drift` are all green at this commit.
2. **Decide §2** — whether `substrate.sql`'s sweep function is in scope. It is the
   only judgement call in the packet.
3. **Identity:** re-copy `templates/database/tenancy/isolation.sql` and
   `assertions.txt` from this branch. **No migration** — the scope is derived from
   policies `protect_table` already wrote, so identity's existing `00016`
   suffices. `TestTenancyAccountIsolation` goes green on the whole-suite run;
   `TestTheCoverageExclusionIsOnlyGeneratedCode` stays red and is not this packet.
4. **Once `self_test.sh` is free**, add the breakage: revert
   `unprotected_tables()` to the whole-database scan and require assertion `0b`
   to go red. The mutation belongs in `tests/tenancy_test.sh`; the recipe belongs
   in `tests/self_test.sh`.
