# HANDOFF — kit-startup-floor-01

Branch `worker/kit-startup-floor-01`, base `1f88196`. Read
`REPORT-kit-startup-floor-01.md` and `PROFILE-startup-floor.md` first; this file
is only the next move.

## State

Green and verified. `bash tests/validate.sh --static-only` → **EXIT=0**,
`PASS: every check passed`. `KIT_SELF_TEST_SHARD=78/102 bash tests/self_test.sh`
→ **EXIT=0**, 3 of 106 recipes. The floor (a gate running zero checks) went
**6.84 s → 2.85 s**. Nothing is half-applied; no push was attempted.

## THE ONE-LINE VERSION

**`--only` gates the verdict, not the work.** One check (`tests/kamal_test.sh`,
55.6% of the floor) was invoked by a bare `bash` instead of through
`bounded_check`, so it ignored the filter and ran 24 real-binary cases on every
invocation — including the 86 self-test copies that were told to run one check.

## YOUR FIRST MOVE, and it is the same shape as this one

**Find the next check that ignores `--only`.** This packet fixed one by reading
the gate; there are almost certainly more, and the method is cheap:

```sh
# every `bounded_check`/`check` call site in the static phase — each is filterable
grep -nE '^\s*(check|check_par|report|report_par|bounded_check) ' tests/validate.sh

# the shape that is NOT filterable: a bare `bash <script>` or `"$PY" - <<EOF`
# evaluated before any check/report helper sees it
grep -nE '^\s*(if )?bash "\$ROOT|^\s*if "\$PY" -|^\s*out="\$\(' tests/validate.sh
```

The profile gives you the target list for free — sort `/tmp/f.tsv` phase rows
descending and the top entries are the ones `--only` never reaches:

```sh
unset KIT_PYTHON
KIT_PROFILE=/tmp/f.tsv bash tests/validate.sh --static-only --only=__no_such_check__
awk -F'\t' '$1=="phase"{printf "%7.3f  %s\n",$3+0,$2}' /tmp/f.tsv | sort -rn | head
```

**The three to go after, in this order** (measured, not guessed):

| section | s | what it is |
|---|---:|---|
| `static: templates declare no third-party dependency` | 0.648 | inline Python |
| `static: the canary harness — contract, adapter, artifacts` | 0.626 | inline Python |
| `static: the fleet adopts the stack rather than copying it` | 0.522 | `tests/fleet_check.py`, 6 repos |

**These are harder than `kamal_test` was, and here is why.** `kamal_test` was a
bare `bash` in front of a `report`, so one guard in front of it fixed the whole
thing. Those three build their Python (or their fleet walk) *before* reaching a
helper, so **the guard has to move above the section's preamble, not beside the
verdict** — that is a structural change to ~20 sections, not a one-line guard.
Budget for it as a packet of its own.

## THE COST YOU MUST STATE, EVERY TIME

A filtered copy stops running that check. That is `--only`'s existing contract —
`ONLY_SKIPPED` counts it, the summary prints the exclusion, a filter matching
nothing is still a hard FAIL — and on an **unfiltered** run nothing changes.
Say all of that in the report, and prove the unfiltered path with a full
`--static-only` run at **EXIT=0**. Do not use `expect_skip_check` for this: it is
for a check that skips on its own environment, not for one the caller filtered.

## TWO TRAPS, both measured here

1. **A dynamic label cannot be filtered.** `kamal_test`'s PASS label was derived
   from the script's own last output line, so `--only=kamal_test` selected
   *nothing* and the gate printed a second, spurious `FAIL: --only=… selected NO
   check`. Breakages 78/79/82 passed only because `expect_red_check` greps for
   its own needle and ignores the line after it. **If a label is printed, it
   must also be the label the filter matches** — otherwise your filter is
   decorative and the recipe is one grep away from a false green.
2. **`lint drift` FAILs in every self-test copy**, because `fresh_copy` puts
   copies in `$WORK/<name>/kit` where no cafaye checkout sits beside them. No
   recipe notices. This is pre-existing and unrelated to any change you make —
   but it means **hand-made proof copies must be placed so `$ROOT/..` holds the
   fleet**, or your green control is red for a reason you did not introduce, and
   **this worktree must not move**: it is beside the fleet for exactly this
   check.

## NOT CLAIMED

The full 106-recipe `self_test` was not run (~30 min; the hour is 60). Only shard
78/102 was, and its own summary line says so. `cp -R` is still unmeasured — it
is the harness's cost, and the open question is whether 86 copies of the tree
need to exist at all.