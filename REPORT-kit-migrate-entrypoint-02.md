# REPORT — kit-migrate-entrypoint-02

The relay's packet: attribute and fix the two reds the manager's verification run
produced, prove green, report. Branch `worker/kit-migrate-entrypoint-01`, worktree
`moon/cafaye/wt-m39-kit-migrate-entrypoint-01`. Nothing pushed, nothing merged.

**Both reds attributed. One was a real defect in the tree (and it was not the one
the packet pointed at); the other cannot be caused by this branch, and the branch
now carries a green static gate, a green account-boundary proof and a green shard
of the self-test.** The one thing I could not finish inside the hour is the
unsharded 96-breakage `self_test`, and §5 hands the exact command forward.

---

## 1. Red one — `tests/self_test.sh: line 1956: e: command not found`

### It is not a defect in recipe 23b

Recipe 23b is green on this tip, measured twice on two independent runs:

```
PASS self_test: breakage 23b: an interpreter below the floor is a named skip, not a
     silent pass — reported as `templates/otel/ruby  (ruby 2.6.10 is below the
     template's 2.7 floor)`
```

(in a `KIT_SELF_TEST_SHARD=0/23` run of `tests/self_test.sh`, which evaluates
breakages 23, 23b, 46, 69 and 92 — `PASS: self_test — shard 0/23 ran 6 of 96
breakages and every one it ran held`, `EXIT=0`; and in the full unsharded
`bash tests/self_test.sh` running on this worktree since 00:15:47, which has
passed 23 and 23b with zero `FAIL` lines).

`bash -n tests/self_test.sh` is clean, and I read every construct on the path:
`fresh_copy` prints its destination with `printf '%s' "$dst"` (one line, no
trailing junk), the stub heredoc at 1912–1924 is written before the recipe, and
`expect_skip_check` reaches the gate through
`out=$(cd "$dir" && KIT_PYTHON="$PY" bash tests/validate.sh "$@" 2>&1) || ec=$?`.
There is no `eval` anywhere in the file and no recipe mutates the root tree —
every `edit` in the suite targets a throwaway copy or `$FLEET`.

### What the packet's own premise gets right, and what it misses

The packet is right that `bash -n` being clean does not make this a non-defect: a
word can only reach command position at runtime if it was not there when the file
was parsed. It is wrong that the subject is recipe 23b. Bash reads a script
**incrementally, by byte offset**, and resumes at the offset it last buffered. If
the file's bytes move underneath a running interpreter, the next command it parses
starts wherever the stale offset now lands — mid-word, mid-line — and the tail of
a word is executed as a command. That is the only thing I know of that puts a
one-letter word like `e` into command position at a line whose source is a quoted
argument list, and it is the same accident kit's own `AGENTS.md` records for
`tests/validate.sh` (`proofs: command not found`, `EXIT=127`, "the file shifted
under a running script and bash resumed mid-line").

**The file moved under it, twice, minutes apart.** The tree this run read was 20
lines longer than the committed tip: the manager's recovery commit `0ce22e6`
inserted 9 lines into `tests/self_test.sh` (at ~1731) and the predecessor's
uncommitted work, which I committed as `802f87b`, inserted 11 more (at ~1740).
Both insertions are above line 1956, so both shift every byte after them. A run
that had already buffered past 1740 and was still alive across either commit reads
the wrong bytes from that offset onward. `e` is what the tail of a word looks like
when the offset lands one character into it.

I could not build a faithful reproduction of the offset shift inside my hour — my
first probe was too small for bash to re-read (it buffers whole files under ~30KB,
so the edit landed after the last read and the probe exited 0). The claim above is
therefore an attribution from the shape of the error plus the two measured file
deltas, not from a reproduction. **I am flagging that honestly rather than
dressing it up: what is proved is "not recipe 23b, not the helper, not the child
copy"; what is argued is the mechanism.**

### The real defect the red was sitting next to

Attributing the abort correctly is what exposed it. Line 1956 is not where the
suite died — the suite died *before* it, at breakage 12, and kept going because
`expect_red_check` reports rather than exits.

`edit` replaces the **first** occurrence. Breakage 12's mutation string was
retargeted to `USER 65532:65532` in `0ce22e6` (correctly: the Go runtime stage
moved off distroless, and `USER nonroot:nonroot` names an account `debian:*-slim`
does not have). But the Go template's STRICTNESS NOTES **quoted that directive
verbatim** while explaining why it is numeric, and the comment sits above the
instruction. So the mutation removed the quote, left the instruction, and the gate
stayed green:

```
FAIL self_test: breakage 12: a Dockerfile final stage runs as root — the gate
     stayed GREEN
```

A proof of nothing wearing a proof's label, in the one breakage whose job is to
prove a Dockerfile's final stage cannot run as root. `docker/Dockerfile.rust`
carried the same sentence and the same defect. Fixed in `802f87b` by rewording
both notes to describe the directive (`a numeric uid/gid directive
(65532:65532)`) instead of quoting it, so the string occurs exactly once in each
file — in the instruction — plus a comment in `self_test.sh` recording why.

**No check was weakened and no recipe was skipped.** The fix makes the mutation
land where it names.

## 2. Red two — `FAIL tests/tenancy_test.sh`

**Attributed to the machine, and provably not to this branch.**

Standalone, on this tip, twice:

```
PASS: kit's account boundary is enforced by Postgres, and the enforcement is
      proven able to fail.
      24 assertions, every one passing, named identically in assertions.txt.
      FORCE ROW LEVEL SECURITY removed: 6 red, all of them owner/ or sweep/.
      identity function calls over five rows: 1 wrapped, 5 bare.
EXIT=0
```

The code-level argument, which does not depend on the machine being quiet:

```
$ git diff --name-only master...HEAD | grep -E 'tenancy|database|compose'
NONE
$ git diff master...HEAD -- tests/validate.sh | grep -iE 'tenancy|isolation|observab|docker compose|15531'
(no output)
```

The branch's thirteen changed files are `README.md`, the seven
`docker/Dockerfile.*`, `docker/entrypoint.sh`, `tests/validate.sh` and
`tests/self_test.sh`. `tests/tenancy_test.sh` reads `templates/compose/**` and
`templates/database/tenancy/**` and builds only
`templates/compose/postgres/Dockerfile` — **it reads nothing this branch
touches**, and the branch's `validate.sh` diff touches nothing in the
tenancy/isolation path either. A red in that proof is about the box.

What the box can do to it, from reading `tests/tenancy_test.sh`:

- **`tests/tenancy_test.sh:105` names the container `kit-tenancy-postgres-1` and
  line 161 pins the compose project to `kit-tenancy`** — fixed, global names, no
  per-run suffix. I measured what that means: **two concurrent runs of the proof
  share one cluster** (the second's `compose up` finds the project's container
  already up and healthy, and its assertions run against the first one's
  provisioning). Both passed, so it is benign in the common case — but the proof
  is not isolated from a concurrent run, and a neighbour's cluster under that
  project name would be adopted rather than reported.
- **Line 123's provisioning wait is 90 seconds** against a cluster that runs
  initdb plus a `CREATE EXTENSION` per database. On a box carrying four other
  Postgres clusters (this machine had `kt-entrypoint-pg`, `wt-m39-identity-pg`,
  `kit-adv` and `identity-postgres-1` live during this hour), that budget is the
  most likely way a neighbour turns this proof red, and the failure prints as
  `FAIL: the cluster came up but initdb/10-cluster.sh never created a database
  named <svc>`.

I tried to reproduce the port half and **could not**, and I am reporting that
rather than omitting it: with `nc -l 127.0.0.1 15531` held and the compose project
torn down, `tests/tenancy_test.sh` still passed (`EXIT=0`). Docker Desktop's port
proxy binds the published port in a way macOS permits alongside a
loopback-only listener, so on this platform holding 15531 does not produce the
`FAIL: the shared cluster did not come up` a Linux host would give. The port is
therefore not a usable attribution on this machine, and I am not claiming it.

**Not fixed, deliberately.** Both fragilities above are real, but changing the
project name, the container name or the provisioning budget is a change to the
proof harness that this red does not justify — no measurement in this hour says
which of them the manager's run hit. Per `AGENTS.md` ("never weaken a check"), the
90-second budget in particular is the kind of number that gets widened to reach
green. Handed forward in §5 as a decision, not a patch.

## 3. What I changed

One commit on top of the manager's recovery commit, `802f87b`:

| file | change |
| --- | --- |
| `docker/Dockerfile.go` | the strictness note no longer quotes `USER 65532:65532` verbatim |
| `docker/Dockerfile.rust` | the same note, the same defect, reworded the same way |
| `tests/self_test.sh` | 11 lines recording *why* the string must occur exactly once in the file |

Nothing else. No check changed, no threshold moved, no recipe skipped, no
`templates/` file touched, no other worker's file touched.

## 4. The green, as measured

```
# tests/tenancy_test.sh, standalone, this tip
PASS: kit's account boundary is enforced by Postgres, and the enforcement is
      proven able to fail.                                            EXIT=0

# tests/validate.sh --static-only, this tip
PASS: every check passed.                                             (see §5)

# KIT_SELF_TEST_SHARD=0/23 bash tests/self_test.sh, this tip
PASS self_test: unbroken tree — the gate is green on an unbroken tree
PASS self_test: breakage 12: a Dockerfile final stage runs as root — caught by
     `docker/Dockerfile.*  (non-root final stage, no :latest, no ADD)`
PASS self_test: breakage 23 / 23b / 46 / 69 / 92
PASS: self_test — shard 0/23 ran 6 of 96 breakages and every one it ran held.
       This is a SHARD. It has NOT evaluated the other 90 breakage(s).  EXIT=0

# bash tests/self_test.sh, unsharded, running on this worktree since 00:15:47
breakage 23 PASS, breakage 23b PASS, … breakage 29 PASS, 0 FAIL lines
```

Breakage 12 passing in both self-test runs is the substantive change: before
`802f87b` that recipe could not fail.

## 5. What I did not do, and what is left

**I did not finish the unsharded 96-breakage `self_test`.** It is *n* whole gates
in sequence; on this box the run in flight took 16 minutes to reach breakage 23,
which puts the end past 01:15 — outside this hour. The packet's rule is explicit
("do not start a verification you cannot finish inside your hour — hand it forward
instead"), so it is handed forward rather than half-claimed:

```sh
cd /Users/kaka/Code/any/moon/cafaye/wt-m39-kit-migrate-entrypoint-01
gtimeout 5400 bash tests/self_test.sh          # ~66 min on a busy box
# read the EXIT= line and the summary's "ran N of 96", not the FAIL count alone
# a run that reaches breakage 90-92 also exercises tests/tenancy_test.sh in a copy,
# on host port 15531, under the fixed compose project name `kit-tenancy`
```

A live unsharded run of exactly this command **is in flight on this worktree**
(started 00:15:47, output
`/private/var/folders/3b/kt90wy3d66lftws_dwtxxglm0000gn/T/opencode/selftest2.txt`),
green through breakage 29 when this report was written. **Do not edit
`tests/self_test.sh` while it runs** — that is the whole of §1, and it is how the
predecessor's `proofs: command not found` happened too.

Also deliberately not done, and why:

- **No fix for the byte-offset class itself.** The durable mitigations are (a) run
  the suite from a private snapshot of itself, or (b) a check that the script
  changed mid-run. (a) is clever, which `AGENTS.md` forbids; (b) is a new piece of
  harness machinery invented on a mechanism I could not reproduce. A successor
  with the reproduction in hand should write it; I should not guess at it.
- **No change to `tests/tenancy_test.sh`'s names, port or 90s budget** (§2).
- **No adoption.** No service repo takes the entrypoint; that was out of scope in
  `-01` and is still out of scope.
- **No `tests/artifacts.json` entry for `docker/entrypoint.sh`** — the nine
  `absent` findings and the `parity-allowlist` entries it needs are still a packet
  of their own, as `HANDOFF-kit-migrate-entrypoint.md` says.
- **No `CHANGELOG.md` entry for this packet.** The branch already carries one for
  the feature (Unreleased → "the service entrypoint migrates before it serves"),
  and this commit changes no behaviour — it rewords two comments in Dockerfile
  templates and adds a comment to a test. An entry saying "a comment no longer
  quotes an instruction" would be noise in a file whose entries are for people
  consuming kit.