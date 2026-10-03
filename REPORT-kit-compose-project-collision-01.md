# REPORT-kit-compose-project-collision-01

**The question the packet asked, and the answer:** two of this repository's docker
tiers hardcoded their compose project name, so two concurrent runs were one stack
with two owners. **Four** namespaces were hardcoded, not one — and the packet named
one of them. One further tier carried the same defect and was on nobody's list.

**The fix:** every name that decides which cluster a run talks to is derived from
the run's own identity, in every tier under `tests/`. `$$` kept, and DECISIONS.md
(MD32) says why, including the two claims it does not make.

**The result, measured rather than argued.** Both tiers, same harness, same box:

| | before | after |
| --- | --- | --- |
| tenancy, two concurrent runs | `A exit=2  B exit=1` | `A exit=0  B exit=0` |
| isolation, two concurrent runs | `A exit=0  B exit=1` | `A exit=0  B exit=0` |

and with both isolation runs live at once, **two project namespaces, two host
ports, two containers** — which is only possible if each run derived its own names:

```
kit-isolation-98792-postgres-1   0.0.0.0:15892->5432/tcp
kit-isolation-98380-postgres-1   0.0.0.0:15880->5432/tcp
```

`docker ps -a` after both exited: empty. The teardown reaches only its own.

**The guard:** `tests/validate.sh`'s `docker_tier_project_name`, in its own
top-level phase, four namespaces, scope derived from the directory. Seven
mutations, seven reds (`reports/compose-collision/mutations.sh`).

---

## 1. The collision, watched

The packet asked for this before any fix, and it is right to: the argument from the
source is an argument.

`reports/compose-collision/collide.sh` launches run A, waits for A to print the
line it prints when it is about to start asserting, and only then launches run B.

**A fixed sleep does not work on these tiers, and the first attempt proved it.** A
12-second stagger made `isolation_test.sh` collide hard, and made **both
`tenancy_test.sh` runs report PASS**. Both passing is the worse outcome, and worth
being precise about: a timestamped single tenancy run spends ~60 s building and
**~4 s in its entire assertion phase**, so a stagger outside that window never puts
the runs in each other's way at all. That is not a gentler test of the collision,
it is no test of it.

With the marker sync, both tiers collided. The tenancy one is the exchange that
matters:

```
== A reached the marker after 8s; launching B now
== A exit=2   B exit=1

  B:  FAIL: the shared cluster did not come up. Last lines:
          Container kit-tenancy-postgres-1 Recreate
          Error response from daemon: removal of container f55b2fbe… is already in progress

  A:  == assertion 5: the sweep still names an unprotected table in the substrate's OWN schema
      <nothing further>                                       exit 2
```

**A produced no `FAIL:` line of its own.** Its last act was to ask a question
about row-level security; the answer came back as an infrastructure error, because
B's `cleanup` had taken the project volume out from under it. The exit code 2 is
psql's, propagating out of the `docker exec` under `set -e`.

That is the whole defect in one exchange. Through `validate.sh`'s `FAIL:` summary
— the summary breakage 23b reads — this is an account-boundary violation, which is
precisely the claim that tier exists to make trustworthy. A reader, and a CI job,
are told the security property failed.

The isolation pair collided the other way round (`A exit=0 B exit=1`, B
`Recreate`-ing A's running container). A passing there is luck, not design: the
race was decided by which run was further along, and the packet's own description
of the symptom — a teardown landing mid-assertion — is what happens when the
ordering goes the other way.

Logs: `reports/compose-collision/before-{isolation,tenancy}-marker-{A,B}.log`.

## 2. "Both green" is not the proof

Two runs can both be green against **one** stack, and the 12-second stagger above
had already demonstrated that shape in reverse. So the after-state was checked by
counting clusters while both were live (§ header), not by counting PASS lines.

Two distinct `kit-isolation-<pid>-postgres-1` containers on two distinct host
ports, simultaneously. That is the evidence. Two PASS lines would not have been.

## 3. Four namespaces, and the packet named one

The packet says "a fixed HOST PORT is the same class wearing a different hat and is
worse". It is worse, and it is **load-bearing for this fix** — which is only visible
by trying:

> With only `--project-name` derived, two concurrent runs of `isolation_test.sh`
> were **still red on `port is already allocated`**. Both bound the hardcoded
> `KIT_POSTGRES_PORT=15521`.

So deriving the project name alone would have **relocated** the collision to the
next namespace and left the packet's acceptance test — two concurrent runs both
green — unachievable. Each tier now takes a free port from the same
dependency-free probe `stack_live_test.sh` uses (`/dev/tcp`; no `nc`, no python,
because no tier may assume a tool exists), seeded from `$$` so two concurrent runs
do not begin their search in the same place.

| namespace | was | now |
| --- | --- | --- |
| project | `kit-isolation` / `kit-tenancy` ×2 sites each | `$PROJECT` |
| container | `kit-isolation-control` ×9 sites | `$PROJECT-control` |
| volume | `kit-isolation-control-vol` ×3 sites | `$PROJECT-control-vol` |
| host port | `15521` / `15531` | free port, probed |

`--project-name` appeared **twice in each file**, and the packet's warning is the
reason both were changed: one site derived and one literal would bring up
`kit-isolation-<pid>` and then query `kit-isolation`, which is *some other run's*
cluster. The guard now fails on either half alone.

## 4. The sweep: a fourth tier, and a deletion

The packet asked for other fixed names in the directory. Findings, both ways:

**A fourth tier, not in the packet.** `tests/rls_perf_test.sh:61` had
`C="kit-rlsperf-pg"` — a fixed container name, so two concurrent runs were one
container with two owners. Found by the guard, whose scope is derived from `tests/`
rather than enumerated; it was not on anyone's list. Fixed, not reported: a guard
that reports a defect nobody fixes teaches everyone to ignore the guard.

**A deletion, and it is the opposite of the rest.** `tenancy_test.sh`'s cleanup ran
`docker rm -f kit-tenancy-control` and `docker volume rm kit-tenancy-control-vol`
for objects **nothing in that file ever creates** — every control there is a SQL
mutation against its own cluster, not a second container. `docker rm` takes a bare
name and does not care who made it, so those two lines reached outside the run's
own namespace to delete another tier's objects. Derived would have been wrong; the
honest version is no line.

**Clean.** No fixed network. No fixed volume left in any tier. The three remaining
literal ports in `tests/self_test.sh` (15500, 15433) are **quoted fixture text**
that existing breakages assert *against* — a hardcoded port is their subject, not
a collision. `deploy_test.sh`'s decoy names and `rls_perf_test.sh`'s `$$`-suffixed
container are correct.

## 5. The guard

`tests/validate.sh`'s `docker_tier_project_name`, beside
`self_test_live_tier` and `self_test_no_version_literal` in kind — a derived
property, not a listed one.

- **Scope derived twice.** The tiers are every script under `tests/` that brings a
  container up; within a tier the rule applies at **declaration and use site**. So
  a sixth tier is covered the day it lands, and a tier that derives its project but
  writes its control container literally is caught by the same rule.
- **Emptiness is a finding**, as `self_test_no_version_literal` does it: no tiers
  found, no names derived, no invocation readable, and a tier that brings a stack up
  without naming a project — four ways it can cover nothing, each reported.

**It was wrong four times, and that is the substantive part of this report.**

| what it did | what it missed |
| --- | --- |
| anchored the scan at `^[ \t]*docker` | every bring-up site is `if ! docker compose …` — blind to the exact line this packet protects |
| detected bring-up per LINE | `… \` + `up -d` is ONE command; `tenancy_test.sh` dropped out of scope entirely |
| read use sites only | `CONTROL_C="kit-isolation-control"` makes every use read a derived `$CONTROL_C` |
| called an inline `$$` a literal | fired on `deploy_test.sh`'s decoy volume, which **is** unique to the run |
| sat inside `if [ "$RUN_SELF_TEST" -eq 1 ]` | `--static-only` sets that to 0: **the static phase was green on a broken tree**, and 84 of 93 self-test recipes run the gate that way |

The first three were found by `mutations.sh` saying NOT BITTEN on mutations that
had demonstrably been applied. The fifth was found by running the plain static gate
and looking for the check in the output — **`--only` selects a check by label
without skipping its phase, so the mutation suite structurally could not catch it.**
A guard can be bitten by every mutation and still not run where it matters.

Four times in one packet, reading the code and running it disagreed. That is the
argument for the mutation script existing, and it is why it is committed rather than
run once by hand.

`reports/compose-collision/mutations.sh`, 7/7:

```
BITTEN  project name hardcoded at the bring-up site      isolation_test.sh:265
BITTEN  project name hardcoded at the TEARDOWN site       tenancy_test.sh:155
BITTEN  control container name hardcoded                  isolation_test.sh:78
BITTEN  control volume name introduced as a literal       tenancy_test.sh:109
BITTEN  host port pinned to a literal                     isolation_test.sh:260
BITTEN  a NEW tier, added with no edit to validate.sh     compose_collision_probe.sh:5
BITTEN  emptiness is a finding, not a silent pass
GREEN   the fixed tree, restored
```

Row 6 is the derivation claim measured: a brand-new tier file, caught without this
directory being edited.

## 6. `$$`, decided

Kept, and DECISIONS.md (MD32) carries the argument. In short: it is the idiom four
tiers already follow; sufficiency is a property of the threat model (two runs on
one machine, and every CI job here has its own daemon); and two idioms in one
directory is a cost paid by the reader.

**The packet asked whether the other four should move too. No** — `$$` is the
weaker-but-sufficient option, and moving four working files to a stronger one is a
change with no failure behind it.

**The two claims `$$` does not make**, recorded rather than left implied: not
unique across machines sharing a docker daemon, and not stable across a re-exec
within one run. The second is why no tier re-execs; one that did would leak its
first cluster, and **the guard would not notice**, because it checks that a name is
derived and not how well.

## 7. What was not done, and the limits

- **A stronger token.** Discussed above and declined with its cost stated.
- **A per-run docker network.** Not added; nothing needed one, and compose already
  namespaces the network under the project.
- **The guard's limit**, stated rather than caveated: it reads flags **at the point
  of use**. A name reached through a helper, or built by concatenation, is
  invisible:
  `compose_up kit-isolation` → GREEN. Closing that means a shell parser or
  re-implementing bash's expansion, and this repository already removed one
  brace-counting containment assertion (`self_test_live_tier`'s) because it fired
  on correct code. The rule is worth more honest than airtight.
- **Breakage 23b was not run end to end.** The self-test is 105 whole gates in
  sequence — hours. What was verified instead: the plain static gate is green with
  the guard present in both `--static-only` and `KIT_NO_LIVE=1 --static-only`;
  both changed tiers pass standalone **and** as concurrent pairs; `rls_perf_test.sh`
  passes standalone after its one-line change; shellcheck is clean. **23b is the
  claim that motivated the packet and it remains unproven by me** — see §8.

## 8. Honest notes against this work

- **I could not make the 12-second stagger collide in `tenancy_test.sh`** in a
  repeatable way; a marker sync was needed and is what `collide.sh` uses. The
  4-second assertion window is the reason, and it is worth knowing that a casual
  reproduction attempt of this defect can produce two green runs.
- **The isolation "before" pair had A passing**, so the before-state for that tier
  is a bring-up failure rather than a mid-assertion death. The tenancy pair carries
  the mid-assertion death. Together they cover both shapes; neither alone would.
- **Five intermediate commits fix the guard, not the tiers.** They are separate
  because each was a distinct blindness with a distinct cause, and squashing them
  would hide the evidence that reading the code and running it disagreed four
  times.
- **The mutation script mutates `tests/` and restores it.** It refuses to start on
  a dirty tree and restores on any exit — after it aborted once mid-run and left a
  hardcoded `--project-name` in `tests/isolation_test.sh`, which is the defect this
  packet fixes, introduced by the script proving it is guarded.
- **No time bound was widened**, no assertion weakened, no test deleted. `fail`
  call counts went **up by one** in each of the two tiers (the port guard) and are
  otherwise identical; `seq 1 90` waits are unchanged; `VERSION` and the
  `## Unreleased` heading are untouched.

## 9. Where to look

| what | where |
| --- | --- |
| before/after logs, both tiers | `reports/compose-collision/*.log` |
| the collision harness | `reports/compose-collision/collide.sh` |
| the guard's proof (7/7) | `reports/compose-collision/mutations.sh` |
| the evidence write-up | `reports/compose-collision/README.md` |
| the `$$` trade and its two unclaims | `DECISIONS.md` MD32 |
| the guard | `tests/validate.sh` → `docker_tier_project_name` |

12 commits on `worker/kit-compose-project-collision-01`, unpushed. No tag, no
merge to `master`, no other worktree touched, no `searxng-*` container touched.