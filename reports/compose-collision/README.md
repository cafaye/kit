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

## What this is not

Not part of the gate, and it should not become one. This brings up two clusters
at once on purpose, which is the thing the fix exists to stop doing. It is
evidence, kept beside the logs it produced, so that the claim in `DECISIONS.md`
can be checked rather than believed.