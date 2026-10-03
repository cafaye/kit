# The BEFORE evidence: two concurrent runs, one project name

This directory holds the observation that `tests/isolation_test.sh` and
`tests/tenancy_test.sh` hardcoded `docker compose --project-name`, and therefore
that two concurrent runs of either tier are not two stacks but one stack with two
owners. The fix is described in `DECISIONS.md` (MD32); the guard is
`tests/validate.sh`'s `docker_tier_project_name`. This file records what was
watched happen, because the claim is worth nothing read out of the source.

`collide.sh` is the harness. Run it against either tier:

    bash reports/compose-collision/collide.sh tenancy_test.sh /tmp/out

It launches run A, waits for A to print the line it prints when its cluster is up
and it is about to start asserting, and only then launches run B. The sync is the
point, and it was arrived at by measurement rather than taste.

## Why a fixed sleep does not work on these tiers

A first attempt staggered the two launches by a fixed 12 seconds. On
`isolation_test.sh` that produced a hard collision. On `tenancy_test.sh` both
runs reported **PASS**.

Both passing is the worse outcome, so it is worth being precise about what it
means. A timestamped single run of `tenancy_test.sh` on this box spends about 60
seconds building the image and about **4 seconds** in its whole assertion phase:

    +0s  == assertion 0: the topology the templates require is present
    +1s  == assertion 0b: an adopter's fixture schema is present …
    +1s  == assertion 1: every assertion in isolation.sql passes
    +1s  == assertion 4: the proof returns EXACTLY the assertions assertions.txt names
    +1s  == assertion 2: the CONTROL — same proof, FORCE ROW LEVEL SECURITY removed
    +2s  == assertion 5: the sweep still names an unprotected table …
    +2s  == assertion 3: the (select ...) wrapping, measured
    +2s  == assertion 6: advisor.sql, against this cluster
    +2s  == assertion 7: every rule, on a fixture built to trip it
    +2s  == assertion 8: the credential audit reports the same tables to every role
    +4s  PASS

A stagger that lands outside that 4-second window never puts the two runs in each
other's way at all, so it proves nothing — it is not a gentler test of the
collision, it is no test of it. `collide.sh` syncs on
`== the cluster, provisioned by` instead, which is the last thing the tier prints
before it starts asserting.

## What was observed

### tenancy, marker-synced — `before-tenancy-marker-{A,B}.log`

    == A reached the marker after 8s; launching B now
    == A exit=2   B exit=1

**B**, launched second, could not bring up a cluster of its own:

    FAIL: the shared cluster did not come up. Last lines:
            Container kit-tenancy-postgres-1 Recreate
            Container kit-tenancy-postgres-1 Error response from daemon: removal of
            container f55b2fbe… is already in progress
    FAIL: cluster bring-up

**A**, which had already begun asserting, died partway through assertion 5 with
**no `FAIL:` line of its own**. It reached

    == assertion 5: the sweep still names an unprotected table in the substrate's OWN schema

and stopped, exiting **2**. That exit code is psql's, propagating out of the
`docker exec` under `set -e`, because A's `cleanup` had already removed the
project volume out from under A's own assertion.

This is the whole defect in one exchange. A is not told that anything went wrong
with the test harness; the last thing it did was ask a question about row-level
security, and the answer it got came back as an infrastructure error. Read from
CI, or from the `FAIL:` summary `validate.sh` prints, that is a
database-boundary violation — which is precisely the claim this tier exists to
prove, and precisely the claim a reader must not be able to trust.

The 12-second stagger run, before the harness existed, is not kept here because
it demonstrated the same collision at a moment it could not control; the
marker-synced run is the one that says *when* it happened.

### isolation, marker-synced — `before-isolation-marker-{A,B}.log`

    == A reached the marker after 7s; launching B now
    == A exit=0   B exit=1

B, launched second, **replaced A's running container**:

    Container kit-isolation-postgres-1 Recreate
    Container kit-isolation-postgres-1 Recreated
    Container kit-isolation-postgres-1 Starting
    Container kit-isolation-postgres-1 Started
    Container kit-isolation-postgres-1 Waiting
    Error response from daemon: No such container: 84e80c22…
    FAIL: cluster bring-up

A happens to have finished its assertions before it noticed, so A reports PASS
and B reports a bring-up failure. That is luck, not design: A and B were racing
for the same container, and the race was decided by which one happened to be
further along. Swap the timing and A is the one that dies mid-assertion, which
is what happened in the tenancy run above and in the 12-second isolation stagger
before the harness existed:

    Container kit-isolation-postgres-1 Recreate
    Error response from daemon: removal of container 1c09bf0c… is already in progress
    FAIL: cluster bring-up

Note that "A passes, B fails to bring up" is already a broken test suite even
with nothing else wrong: a developer running the gate twice, or CI running two
jobs on one daemon, gets a red that names `docker` rather than naming the
collision.

## AFTER: the same harness, the same two tiers

Same script, same marker, same machine:

    tenancy     A exit=0   B exit=0
    isolation   A exit=0   B exit=0

`after-{isolation,tenancy}-{A,B}.log` are those runs.

**Both green is not the proof, on its own.** Two runs can both be green against
ONE stack, which is the false pass worth fearing most here and which the BEFORE
12-second stagger demonstrated in reverse: both tenancy runs reported PASS while
sharing a cluster. So the clusters were counted while both were live:

    kit-isolation-98792-postgres-1   0.0.0.0:15892->5432/tcp
    kit-isolation-98380-postgres-1   0.0.0.0:15880->5432/tcp

Two project namespaces, two host ports, two containers running at once — which is
only possible if each run derived its own names. And `docker ps -a` after both
exited shows nothing at all, so the teardown is still reaching only its own.

## The guard, and the three ways it was wrong first

`tests/validate.sh`'s `docker_tier_project_name` fails when a docker tier
hardcodes a name in a shared namespace — project, container, volume or published
host port. `mutations.sh` is its proof: it breaks one property at a time, requires
the gate to go red **and name the site**, then restores and re-asserts green. It
refuses to start on a dirty tree, which is how it caught itself mid-write.

It is here rather than in prose because the guard was **wrong four times** and the
mutation suite plus one run of the gate are the only reason any of them was found:

| what the guard did | what it missed |
|---|---|
| anchored the scan at `^[ \t]*docker` | every bring-up site is `if ! docker compose …` — blind to the exact line the packet protects |
| detected bring-up per LINE | `… \` + `up -d` is ONE command; tenancy dropped out of scope entirely |
| read use sites only | `CONTROL_C="kit-isolation-control"` makes every use read a derived `$CONTROL_C` |
| called an inline `$$` a literal | fired on `deploy_test.sh`'s decoy volume, which *is* unique to the run |
| sat inside `if [ "$RUN_SELF_TEST" -eq 1 ]` | `--static-only` sets that to 0, so **the static phase was green on a tree with a hardcoded name in it** — and 84 of the 93 self-test recipes run the gate that way |

The last row is the one the mutation suite could **not** catch, and it is worth
naming why: `mutations.sh` invokes the gate with `--only`, and `--only` selects a
check by label without skipping its phase. A guard can therefore be fully bitten
by every mutation and still not run in the phase that matters. It was found by
running the plain static gate and looking for the check in the output rather than
by reading where the check had been put.

Four times in one packet, reading the code and running it disagreed. That is the
argument for the mutation script existing at all.

A guard reading correctly is not evidence that it *is* correct, and neither is one
that has never been seen to fail. Seven mutations, seven reds:

    BITTEN  project name hardcoded at the bring-up site      isolation_test.sh:254
    BITTEN  project name hardcoded at the TEARDOWN site       tenancy_test.sh:169
    BITTEN  control container name hardcoded                  isolation_test.sh:78
    BITTEN  control volume name introduced as a literal       tenancy_test.sh:109
    BITTEN  host port pinned to a literal                     isolation_test.sh:249
    BITTEN  a NEW tier, added with no edit to validate.sh     compose_collision_probe.sh:5
    BITTEN  emptiness is a finding, not a silent pass
    GREEN   the fixed tree, restored

The sixth row is the derivation claim, measured: a brand-new tier file was caught
without this directory being edited at all. And deriving the scope that way is
what turned up the tier that was never on anybody's list —
`tests/rls_perf_test.sh`, whose `C="kit-rlsperf-pg"` is a fixed container name.

## What this is not

Not part of the gate, and it should not become one. This brings up two clusters
at once on purpose, which is the thing the fix exists to stop doing. It is
evidence, kept beside the logs it produced, so that the claim in `DECISIONS.md`
can be checked rather than believed.