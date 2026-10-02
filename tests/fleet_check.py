#!/usr/bin/env python3
"""kit's gate on the FLEET: do the services actually use the stack, or copy it?

    tests/fleet_check.py --kit <kit root> [--repos-dir <dir>] [--service NAME]

WHAT IT IS FOR
    `kit/templates/compose/` ships a complete observability platform, and at the
    time this was written **no service used it**. Every one of them shipped a
    bespoke 44-86 line `docker-compose.yml` containing a Postgres and little
    else, each one about 450 lines away from kit's, and exactly one of them
    adopted `bin/dev`. A platform that is built, gated, and running nowhere.

    So the gate is about the ADOPTION, not about kit's own files. There are four
    failure modes, each of which is a way for a service to end up running
    something other than the pinned stack while still looking like it adopted
    kit:

      1. STALE COPY. The service carries its own copy of the shared
         infrastructure — a `postgres` container of its own, a collector
         config of its own. It drifts, and nothing notices, because the file
         parses and the container starts.
      2. WEAKENED BOUNDARY, and a misread override. The service overrides the collector's config
         mount, its command or its image. That file carries the redaction
         allowlist, DERIVED from core's schemas, and a service that owns it is
         shipping a telemetry boundary nobody derived — so prompt content
         leaves the process inside a boundary that is supposed to stop exactly
         that. The SAME mode, for the same reason, now also covers overriding
         the shared cluster's `POSTGRES_USER` / `POSTGRES_DB` /
         `POSTGRES_PASSWORD`: that is the one override which used to be kit's
         own documented advice, and it either makes the overriding service's
         role a cluster SUPERUSER or stops initdb dead. See
         `_SHARED_CLUSTER_ENV`.
      3. A COLLECTOR CONFIG NOBODY STARTS. An `otel-collector.yml` in the
         repository that no compose file mounts. A developer edits it believing
         they changed the boundary, and the running collector reads the pinned
         ref's copy instead. The edit is not wrong; it is inert, which is worse.
      4. AN UNPINNED REF. `KIT_STACK_REF` set to a branch, or to nothing.
         `bin/dev` refuses a branch at run time, so this gate and the runtime
         agree; the gate exists so the mistake is found on a laptop rather than
         by whoever runs `bin/dev` first.

WHY IT IS A SEPARATE FILE AND NOT FOUR SECTIONS OF validate.sh
    It is a real parser over many repositories and many failure modes, and
    `core_fanout_check.py` set the precedent for exactly that. More practically:
    it has to be runnable against a FIXTURE fleet, so `self_test.sh` can prove
    each of the four checks is still load-bearing by breaking one repository and
    watching the named check go red. Inlining it would make every self-test
    breakage depend on the real fleet being present and dirty, which is a test
    that passes when the fleet is absent.

WHO IS IN SCOPE, AND WHY IT IS NOT "EVERY REPOSITORY"
    A repository is checked when it DECLARES LOCAL INFRASTRUCTURE: a compose
    file at its root, or a collector config at its root. That is the population
    this packet is about - a repository that has already decided it needs a
    database, and is therefore already carrying its own copy of one.

    Everything else is out of scope and is COUNTED, not silently dropped: `core`
    is a spec repository, `docs` is prose, and neither will ever run a stack.
    Demanding a `kit.ref` of them is a gate failing a repository for not adopting
    something it never adopted, and a check that reports a dozen irrelevant
    findings is a check whose real ones get read second.

    `parlor/e2e/docker-compose.yml` is out of scope too, and that is not an
    oversight: it is a test harness's compose file for one end-to-end run, not a
    developer's local stack, and it is not at the repository root. Scope is by
    ROOT, deliberately — a compose file two directories down is somebody's
    temporary environment, not the loop a developer runs all day.

WHY IT SKIPS AND DOES NOT PASS WHEN THERE IS NO FLEET
    A clone of kit on CI has no siblings. "No fleet was found" is not "the fleet
    is clean", and a gate that reports the second when it means the first is the
    `unknown` vs `current` confusion `tests/staleness.py` exists to avoid. It
    exits 0 with `--no-fleet` and the caller SKIPs loudly.

THE ADOPTION CEILING, and why it is not a weakening
    A finding inside a repository that has NOT adopted is a WARNING that names
    the adoption path. A finding inside a repository that HAS a `kit.ref` is a
    FAIL, every time, with no discretion.

    The judgement is about WHO OWNS THE DEBT, not about how bad it is. Every
    finding is equally true of an unadopted repository; what differs is whether
    that repository has already accepted the standard and is therefore already
    accountable to it. A repository that has adopted and still runs its own
    `postgres:17-alpine` has made a promise it is breaking, and that is a FAIL.
    A repository that has adopted nothing and runs the same image has not made a
    promise yet, and the useful thing the gate can do is name what it would have
    to do — which is what the adoption path printed with each warning is.

    MEASURED TODAY, and stated because it is the honest state of both halves:
    no repository in this fleet has a `kit.ref`, so the WARN side is exercised by
    all six and the FAIL side by none of them. That leaves the FAIL side a claim
    about the future, which is not good enough on its own — so
    `tests/self_test.sh` breakages 59 and 60 run the SAME mutation twice, once
    unadopted (must stay green and name the finding) and once adopted (must go
    red), and the FAIL side is proved against a fixture today rather than trusted
    to hold until somebody adopts.

    The strictness MOVES rather than disappearing. Nothing about the four checks
    changes: the same predicate, the same message, the same severity the moment
    a `kit.ref` exists. What the ceiling buys is that the gate is red for
    something a repository can act on *today* — commit one line and re-run —
    instead of being red for thirteen findings nobody has agreed to fix, which is
    the state a permanently-red gate decays into within one release.

    The ceiling is stated in this file's output, in `tests/validate.sh`, and in
    REPORT-kit-13.md, because a ceiling that only exists in the exit code is a
    ceiling nobody knows is there:

        A WARNING IS A DEBT WITH A NAME. The adoption wave turns them into
        failures one repository at a time.

EXIT STATUS
    0  no finding inside an ADOPTING repository, and no fleet to check. Warnings
       about unadopted repositories do not change this.
    1  at least one adopting repository is carrying a copy, weakening the
       boundary, pinning something that moves, or failing to parse
    2  bad invocation, or a service named on the command line is unreadable
"""

from __future__ import annotations

import argparse
import os
import re
import sys

import yaml

SHA_RE = re.compile(r"^[0-9a-f]{40}$")
# Semver, with the optional pre-release/build suffixes semver itself admits. Kept
# in step with `validate_ref` in templates/bin/dev.sh by hand, and the check
# below says so where the two could disagree.
SEMVER_RE = re.compile(r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$")

# The compose file names a service repository may carry. A service's own file is
# the OVERRIDE passed second to the fetched stack, and these are the three names
# compose would accept for one. `docker-compose.override.yml` is listed because
# it is the idiomatic name and a service that adopts the convention by the other
# name should not escape the gate by spelling.
SERVICE_COMPOSE_FILES = (
    "docker-compose.yml",
    "docker-compose.yaml",
    "compose.yml",
    "compose.yaml",
    "docker-compose.override.yml",
)

# The collector config file kit hands out. Named here because three checks
# and `bin/dev`'s own validator all have to agree on it, and a shared name is
# how they agree.
COLLECTOR_CONFIG = "otel-collector.yml"

# The four AGPL backends. Their `image:` may not be overridden at all, and a
# `build:` is a fork rather than configuration. Named rather than DERIVED from
# kit's compose file, unlike the service images above, because the reason here is
# a LICENCE and not drift: grafana/tempo/loki/mimir are shipped unmodified as the
# condition of AGPL-3.0, and that condition does not stop applying because kit's
# compose file was reorganised. A renamed service would still be the same
# obligation.
AGPL_BACKENDS = ("tempo", "loki", "mimir", "grafana")

# The environment variables a service may NOT set on the shared cluster, and the
# three-line reason each one is refused.
#
# THIS WAS KIT'S OWN ADVICE UNTIL THIS FILE SAID OTHERWISE. `check_stale_copy`
# and the adoption-path block in main() both told a service that had its own
# postgres to "point it at its own database by overriding the postgres service's
# environment (POSTGRES_DB / POSTGRES_USER)". That sentence is the defect: it is
# wrong in a way that does not merely fail, and it shipped. `identity` carries
# precisely the override it recommended, inherited from following it.
#
# WHY IT IS DANGEROUS, MEASURED against `postgres:17` on this cluster's own
# `initdb/10-cluster.sh`, and each result is the whole argument:
#
#   POSTGRES_USER   The official image creates that role, and it creates it as a
#                   SUPERUSER — measured, `rolsuper = t` for a role a service
#                   named for itself, against `f` for every role the init script
#                   made. So the override hands one service a cluster superuser,
#                   and the whole point of `10-cluster.sh:108`'s
#                   `LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION`
#                   is undone by the override that kit used to recommend. Measured
#                   from inside that cluster, one service provisioned the supported
#                   way and one the overridden way ON THE SAME CLUSTER
#                   (`KIT_POSTGRES_DATABASES=courier`, `POSTGRES_USER=identity`):
#                   the overriding role reads the other service's table
#                   (`select count(*) from invoices` → `2`), while the properly
#                   isolated role is refused at the door —
#                   `FATAL: permission denied for database "identity"`,
#                   `DETAIL: User does not have CONNECT privilege.` — which is
#                   the control, and is the property being destroyed. The
#                   refusal happens before a single table is named, so this is
#                   MD21d's `REVOKE CONNECT` and not a missing GRANT.
#   POSTGRES_DB     The image creates that database too, before any init script
#                   runs, so `CREATE DATABASE` in `10-cluster.sh:118` finds it
#                   already there.
#   Either of those  `ON_ERROR_STOP=1` (10-cluster.sh:78) makes the failure
#                   fatal, the failure happens DURING initdb, and the cluster
#                   refuses to start. Measured both ways, exit status 3 and:
#                       [cluster] provisioning identity
#                       ERROR:  role "identity" already exists
#                   and, for `POSTGRES_DB` alone with kit's own role left alone:
#                       ERROR:  database "identity" already exists
#                   That is a laptop that will not boot the stack, discovered by
#                   a developer, from advice this repository published.
#   POSTGRES_PASSWORD
#                   The only one that does NOT break initdb, and it is here
#                   anyway: it is the credential of every role on the cluster
#                   (`10-cluster.sh:107` hands each one `$POSTGRES_PASSWORD`),
#                   so one service choosing it decides the password for all the
#                   others. Measured: with one service's `POSTGRES_PASSWORD`
#                   overridden on a fresh volume, the init script completes and
#                   another service's role — `courier`, which this repository
#                   never mentioned — authenticates with the first service's
#                   password. No isolation boundary is broken, and the reason it
#                   is still refused is stated plainly in the finding rather than
#                   dressed up as the other two.
#
# WHY ALL THREE ARE REFUSED RATHER THAN JUST THE TWO THAT BREAK. The check is
# about a service reaching into a CLUSTER-WIDE decision from inside one service's
# file. `KIT_POSTGRES_USER`, `KIT_POSTGRES_DB` and `KIT_POSTGRES_PASSWORD` are
# the variables for those decisions, they are declared in kit's own compose
# file, and they reach it through `.env` — which is where all three belong and
# where all three are already documented.
#
# NOT `KIT_POSTGRES_DATABASES`, which is deliberately absent from this tuple and
# is the whole point: naming a database there is how a service gets one, and it
# goes through kit's own compose file rather than through an override. Its
# presence in the service's own `environment:` block is harmless and is not
# this finding.
#
# LITERAL KEYS IN A `environment:` BLOCK ONLY, and not `env_file:`. `.env` is
# git-ignored, so a gate that read it would be reading a file that exists on one
# laptop and on no CI runner — and every legitimate way of setting any of these
# is the `KIT_*` variable, which does not appear as a `POSTGRES_*` key in a
# service's compose file at all.
_SHARED_CLUSTER_ENV = {
    "POSTGRES_USER": (
        "the official image creates that role as a SUPERUSER, so this override "
        "makes your service a cluster superuser: it can read every other "
        "service's database, which is the boundary "
        "templates/compose/postgres/initdb/10-cluster.sh exists to draw"
    ),
    "POSTGRES_DB": (
        "the image creates that database before any init script runs, so "
        "CREATE DATABASE finds it already there"
    ),
    "POSTGRES_PASSWORD": (
        "it is the credential of EVERY role on the cluster, so one service "
        "choosing it decides the password for all the others"
    ),
}
# ...and the single sentence explaining why each of the above stops the CLUSTER
# rather than one service. Only true of the two CREATE statements; kept beside
# the table so a future entry cannot inherit it by accident.
_SHARED_CLUSTER_ENV_KILLS_INITDB = ("POSTGRES_USER", "POSTGRES_DB")


def is_checkout(path: str) -> bool:
    return os.path.isdir(os.path.join(path, ".git")) or os.path.isfile(
        os.path.join(path, ".git")
    )


def is_worktree(path: str) -> bool:
    """True for a git WORKTREE rather than its own repository.

    A worktree shares its parent's history and remote, so counting one as a
    separate consumer reports the same service twice and makes a repository look
    like it holds two copies at two ages. Same reasoning, and the same function
    shape, as `tests/staleness.py` — which is the point: two checks that both
    enumerate the fleet must enumerate it the same way, or they disagree about
    how many repositories there are.
    """
    marker = os.path.join(path, ".git")
    if not os.path.isfile(marker):
        return False
    try:
        with open(marker, encoding="utf-8") as fh:
            return fh.read(6).strip() == "gitdir"
    except OSError:
        return False


def declares_local_infrastructure(repo: str) -> str | bool:
    """Does this repository declare local infrastructure at its root?

    Returns the name of what declared it (a compose file, or a collector config),
    or False. The name is carried so the report can say WHY a repository was
    checked rather than only that it was — a scope rule whose reasons are not
    printed is a scope rule a reader has to reverse-engineer from the output.
    """
    if find_compose_file(repo):
        return find_compose_file(repo)
    if os.path.isfile(os.path.join(repo, COLLECTOR_CONFIG)):
        return COLLECTOR_CONFIG
    return False


def find_compose_file(repo: str) -> str | None:
    for name in SERVICE_COMPOSE_FILES:
        candidate = os.path.join(repo, name)
        if os.path.isfile(candidate):
            return candidate
    return None


def read_kit_ref(repo: str) -> tuple[str, str]:
    """(value, source) for the pin in a service's `kit.ref`.

    ONE committed file, one line. Not `.env`, because `.env` is git-ignored and
    a pin kept there exists on one machine and on no CI runner. Not
    `.env.example`, because that is a template and a template's value is a
    placeholder nobody chose.

    Read as TEXT and never sourced: these are other repositories' files, and
    executing one to read a variable is not something a gate should do. Comments
    and blank lines are skipped, so the file can carry the reason it moved - a
    one-line file that cannot hold a reason cannot hold the thing that makes a
    pin deliberate.
    """
    path = os.path.join(repo, "kit.ref")
    if not os.path.isfile(path):
        return "", "absent"
    try:
        with open(path, encoding="utf-8") as fh:
            raw = fh.read().splitlines()
    except OSError:
        return "", "unreadable"
    values = [ln.strip() for ln in raw if ln.strip() and not ln.strip().startswith("#")]
    if not values:
        return "", "empty"
    return values[0], ("many" if len(values) > 1 else "kit.ref")


class _ComposeLoader(yaml.SafeLoader):
    """`SafeLoader` that tolerates compose's own `!` tags.

    `!reset`, `!override` and `!reset null` are compose extensions that mean
    something inside a compose file and nothing to PyYAML. A service that uses
    `!override` on its one override key is doing exactly what this packet tells
    it to do, and a gate that cannot parse it reports the correct repository as
    broken - which is how a check gets ignored rather than fixed.
    """


_ComposeLoader.add_multi_constructor("!", lambda loader, suffix, node: node.value)


def _expand(image: str) -> str:
    """`${KIT_X:-default}` -> `default`, for kit's own compose file.

    kit writes its images as `kit-postgres:${KIT_POSTGRES_TAG:-17}`, and a
    service writes a literal. Comparing the two as text finds nothing, which is
    what the name-based version of this check did: six repositories running their
    own database, zero findings, because the strings had `${...}` in them.

    The default, not the environment: a fleet gate must not change its answer
    because of a shell variable. `bin/dev` is the thing that expands these, and
    the check is asking what the file MEANS.
    """
    out = re.sub(r"\$\{[A-Za-z_][A-Za-z0-9_]*:-([^}]*)\}", r"\1", image)
    out = re.sub(r"\$\{[A-Za-z_][A-Za-z0-9_]*\}", "", out)
    return out


# The upstream images kit's stack is BUILT from, per kit service, and the reason
# this table exists at all.
#
# kit-21 made the cluster a BUILT image rather than a pulled one, because pgvector
# has to be composed onto the official base (MD21b). That moved postgres from
#
#     image: postgres:${KIT_POSTGRES_TAG:-…}      # what kit used to publish
#     image: kit-postgres:${KIT_POSTGRES_TAG:-…}  # what kit publishes now
#
# and `check_stale_copy` matches a service's image against kit's by BARE REPOSITORY
# NAME. The rename changed `postgres` -> `kit-postgres`, and the bare name a service
# writes when it duplicates the platform is still `postgres` — so the two stopped
# matching and FAILURE MODE 1 stopped firing. Measured, after the rename:
#
#     $ fleet_check.py --repos-dir <a fleet whose alpha runs postgres:17>
#     PASS fleet: no service carries a copy of kit's stack, …
#
# while the fixture held exactly the copy the check exists to report. Five
# repositories in the real fleet carry their own postgres, and the check that was
# written to name them had been silently reporting a clean fleet.
#
# The reason it went unnoticed is the shape AGENTS.md keeps warning about: the
# check still RAN, still printed PASS, and its own self-test breakages 59 and 60
# still went the right colour — because break_stale_copy's fixture writes a
# `ports:` entry on the copy, and `check_override_surface` reports that by SERVICE
# NAME, which the rename did not touch. So breakage 60 went red for the port and
# nobody ever found out the image half had stopped working. A green control is
# evidence about the whole gate, and this one was evidence about a different check.
#
# So the predicate below is the thing the check always meant: a service duplicates
# the platform when it runs the UPSTREAM image kit's stack is built from. Keyed by
# kit's service name, because that is what compose merges on, and read out of kit's
# own compose file rather than a list here — except that the upstream name is no
# longer visible in it, because kit names the artefact it built, not the base it
# built FROM. Hence this one small table, which is a fact about the upstream
# registry rather than about kit's own layout, and which fails loudly if kit ever
# builds a different set.
_UPSTREAM_BUILT_FROM = {"postgres": "postgres"}


def _kit_duplicate_names(kit_name: str, kit_image: str) -> set:
    """The image repository names that count as duplicating kit's `kit_name`.

    Both the name kit publishes AND, when kit builds it, the upstream base that
    name is an artefact of. A service cannot know to write `kit-postgres` — that
    is a local build tag that exists on one developer's machine — so matching only
    on it would report a fleet that is entirely non-compliant as clean.
    """
    names = set()
    if kit_image:
        bare = kit_image.split("@")[0].rsplit("/", 1)[-1]
        names.add(bare.rsplit(":", 1)[0])
    upstream = _UPSTREAM_BUILT_FROM.get(kit_name)
    if upstream:
        names.add(upstream)
    return names


def load_yaml(path: str):
    import yaml

    with open(path, encoding="utf-8") as fh:
        return yaml.load(fh, Loader=_ComposeLoader)


def check_stale_copy(repo: str, name: str, compose: dict, problems: list) -> None:
    """FAILURE MODE 1 - a service carrying its own copy of the shared stack.

    The predicate is an IMAGE, not a service name, and that is the whole
    subtlety. Six of the services name their database `db` rather than
    `postgres`, so a check that looked for the NAME would find nothing in five
    repositories out of six and report the fleet clean while every copy of the
    platform stood right there. What is actually duplicated is the container, and
    the container names itself in its `image:` line.

    The set of images is read out of KIT'S OWN compose file rather than written
    down here. A hand-kept list is a list that has to be edited every time kit
    adds a service, and a check that must be edited is a check that gets
    skipped - which is how the state this packet exists to remove survived a
    full round of CI.

    Matched on the whole image reference first and on the bare REPOSITORY name
    second, so `ghcr.io/cafaye/postgres:18-alpine` matches kit's
    `postgres:${KIT_POSTGRES_TAG...}` even when the tag differs - which is the
    case a service actually hits, because choosing its own postgres major is the
    one override the packet says is legitimate and it is made by changing the
    tag on an image the service should not be running at all.

    The comparison is over `_kit_duplicate_names`, not over kit's published
    `image:` string alone: kit BUILDS its cluster image (MD21b), so what it
    publishes is `kit-postgres:17` while what a duplicating service runs is
    `postgres:17-alpine`. Matching on the published name only, which is what this
    did until kit-21 renamed it, found nothing and reported a clean fleet - see
    `_UPSTREAM_BUILT_FROM` for the measurement.

    THE REMEDIATION THIS CHECK PRINTS WAS ITSELF THE DEFECT, and this paragraph
    exists so the next reader does not put it back. For years the finding ended
    "Point it at its own database by overriding the `postgres` service's
    environment (POSTGRES_DB / POSTGRES_USER)". That is not a fix; it is a
    second, quieter copy of the same mistake, and `identity` carries the override
    it recommends. The remedy is `_own_thing`, and for the cluster it is
    `KIT_POSTGRES_DATABASES` in `.env`.

    A check's remediation is load-bearing the same way its predicate is, and for
    a stronger reason: a reader who follows the advice is now broken in a way
    the gate never reports, because they have deleted the thing the gate looks
    for. That is why the advice was corrected and `check_override_surface` grew
    a check for the override at the same time — either alone leaves a gap the
    other one fills.
    """
    services = compose.get("services") or {}
    for svc_name, svc in services.items():
        if not isinstance(svc, dict):
            continue
        image = str(svc.get("image") or "")
        if not image:
            continue
        bare = image.split("@")[0].rsplit("/", 1)[-1]
        repo_name = bare.rsplit(":", 1)[0]
        for kit_name, kit_image in _kit_images.items():
            if not kit_image:
                continue
            dupes = _kit_duplicate_names(kit_name, kit_image)
            if not dupes:
                continue
            if image.split("@")[0] == kit_image.split("@")[0] or repo_name in dupes:
                problems.append(
                    f"{name}/{svc_name}: runs {image!r}, which is the image kit's "
                    f"stack already ships for {kit_name!r}. A service does not get "
                    f"its own copy of the shared infrastructure: it joins kit's, and "
                    f"its own file becomes an OVERRIDE beside the fetched stack. "
                    f"{_own_thing(kit_name, name)}"
                )


def _own_thing(kit_name: str, name: str) -> str:
    """The last sentence of the stale-copy finding: what the service does instead.

    BRANCHES, because the sentence is only true for the cluster and this loop
    runs over every service kit ships. The version this replaced was one
    sentence that said the same thing for all of them — "override the
    `redis` service's environment (POSTGRES_DB / POSTGRES_USER)" — which is
    both nonsense for every service except the cluster and, for the one where
    it was not nonsense, the defect that shipped.

    The cluster sentence names `KIT_POSTGRES_DATABASES` because that variable
    is the entire mechanism: the init script turns each name in it into a
    NOSUPERUSER role and a database that role owns, and then applies the
    `REVOKE CONNECT ... FROM PUBLIC` boundary to it. The `down -v` is in the
    sentence rather than left implicit because
    `docker-entrypoint-initdb.d` runs once per VOLUME, so a developer who adds
    their name and runs `bin/dev up` gets a cluster that looks fine and a
    database that was never created.
    """
    if kit_name == _kit_cluster_service:
        return (
            f"Delete this service and add {name!r} to KIT_POSTGRES_DATABASES in "
            f"your .env (comma-separated, alongside the names already there). "
            f"The init script then gives {name!r} its own NOSUPERUSER role and a "
            f"database that role owns, and applies the boundary that keeps the "
            f"other services' databases closed to it. Once, because initdb runs "
            f"once per VOLUME: `bin/dev down -v && bin/dev up`."
        )
    return (
        f"Delete it and let {kit_name!r} come from the fetched stack — a second "
        f"copy is two versions to keep in step and a second thing to be wrong."
    )


def check_override_surface(repo: str, name: str, compose: dict, problems: list) -> None:
    """FAILURE MODE 2 — a service weakening the redaction boundary.

    Three keys on `otel-collector`, and each is a way to take the boundary
    somewhere it was not derived from:

      volumes   re-point the mount at the service's own otel-collector.yml
      command   start the collector with a different config file
      image     run a collector nobody gated

    Plus the four AGPL backends, where the reason is a licence rather than a
    leak: `build:` is a fork, and an `image:` that is not the stock one is the
    same fork by another route.

    A fourth thing is checked here rather than in its own mode because it is the
    same claim: an `otel-collector.yml` IN THE SERVICE REPOSITORY is a copy of a
    derived file, and a copy of a derived file is a boundary nobody keeps in
    step with core's schemas. The gate compares it against the pinned kit's.

    ...and a fifth, which is the same shape one layer down: overriding the shared
    cluster's `POSTGRES_USER` / `POSTGRES_DB` / `POSTGRES_PASSWORD`. That one
    belongs to this mode and not to a new one because it is literally the same
    claim — a service has taken a boundary that belongs to the whole fleet — and
    because it used to be kit's own remediation advice, which is the reason it
    needed a check rather than better prose. `_SHARED_CLUSTER_ENV` carries the
    measurements.

    THE FALSE-POSITIVE CASE, because this is the half of the design that decides
    whether the check survives. Could a legitimate override file set one of
    these? Worked through rather than assumed:

      `services.postgres` with no `image:` and no `build:` is an OVERRIDE of
      kit's container — that is the only shape this fires on, and it is checked
      explicitly, so a service shipping its own postgres under kit's name is
      left to `check_stale_copy` alone. One defect, one finding, which is the
      same reason `check_dead_collector_config` exists.

      A service setting `POSTGRES_*` on ITS OWN service is the ordinary case —
      `alpha:` in every self-test fixture carries `POSTGRES_DB: alpha` for its
      application's connection string — and this check keys on the CLUSTER
      service name, so it stays silent. Every existing fixture is therefore
      already the green control for this check, which is why there is no new one.

      A service wanting its own database names itself in
      `KIT_POSTGRES_DATABASES`, which reaches the cluster through kit's own
      compose file and is never a `POSTGRES_*` key in the service's file.

      A service wanting a different admin role, a different admin database or a
      different password sets `KIT_POSTGRES_USER` / `KIT_POSTGRES_DB` /
      `KIT_POSTGRES_PASSWORD` in `.env`. All three are already declared in kit's
      compose file, and on a shared cluster they are a decision for the cluster
      rather than for one service.

    So there is no case found where a correct override file sets one of the
    three. If one appears, this is the wrong place to relax it — the claim
    itself would have changed, and the measurements in `_SHARED_CLUSTER_ENV`
    are what say so.
    """
    services = compose.get("services") or {}
    collector = services.get("otel-collector")
    if isinstance(collector, dict):
        for key in ("volumes", "command", "entrypoint", "image", "build"):
            if key in collector:
                problems.append(
                    f"{name}/otel-collector: overrides {key!r}. That service is where the "
                    f"redaction allowlist lives, and the allowlist is DERIVED from core's "
                    f"schemas by kit's gate — not transcribed, and not owned by a service. "
                    f"A service that points the collector's config, command or image "
                    f"elsewhere is shipping a telemetry boundary nobody derived, and prompt "
                    f"content leaves the process inside it. To use your own backend, set "
                    f"<SERVICE>_OTEL_ENDPOINT, which is the only contract."
                )

    # The shared cluster's identity, decided by one service. Keyed on kit's own
    # service name and only when the entry is an OVERRIDE — no `image:`, no
    # `build:` — so this cannot double-report the stale copy a service ships
    # under kit's own service name. That guard is the whole false-positive
    # surface, and it is written as an explicit condition rather than left to
    # "check_stale_copy will already have said so", because a check that relies
    # on another check having run first is a check that stops working the day
    # somebody narrows the other one.
    cluster = services.get(_kit_cluster_service)
    if isinstance(cluster, dict) and not (cluster.get("image") or cluster.get("build")):
        env = cluster.get("environment") or {}
        if isinstance(env, dict):
            for key in _SHARED_CLUSTER_ENV:
                if key not in env:
                    continue
                kills = (
                    f"It also stops the CLUSTER starting, not just your service: "
                    f"the image has already created that role/database, "
                    f"CREATE ROLE / CREATE DATABASE then fails, `ON_ERROR_STOP=1` "
                    f"makes it fatal, and it fails during initdb."
                    if key in _SHARED_CLUSTER_ENV_KILLS_INITDB
                    else
                    f"It does not stop the cluster starting; what it does is make "
                    f"one service's file decide a credential every other service "
                    f"on the cluster authenticates with."
                )
                problems.append(
                    f"{name}/{_kit_cluster_service}: overrides {key!r} on the "
                    f"SHARED cluster — {_SHARED_CLUSTER_ENV[key]}. {kills} "
                    f"Get a database of your own the way the init script expects: "
                    f"delete this service and add {name!r} to "
                    f"KIT_POSTGRES_DATABASES in your .env, which creates a "
                    f"NOSUPERUSER role and a database it owns and applies the "
                    f"boundary. To move the cluster's own identity or credential, "
                    f"use the KIT_POSTGRES_* variables in .env, which is where "
                    f"all of them are already declared."
                )

    # A `ports:` on a service kit ALREADY SHIPS. Compose MERGES a second file
    # per key, and `ports` is a list, so a second file's entries APPEND rather
    # than replace. A service that writes
    #
    #     services:
    #       postgres:
    #         ports: ["15433:5432"]
    #
    # gets postgres listening on 15500 AND on 15433 — which is not the override
    # it reads like, and it collides with whatever else wanted 15433. Measured
    # against `docker compose config` rather than assumed; the unsurprising
    # merge semantics are exactly the ones that bite.
    #
    # The documented way to move a published port is the VARIABLE, in `.env`:
    # `KIT_POSTGRES_PORT=15433`. That is a different mechanism, it replaces
    # rather than appends, and it is the only one the port-block rule in
    # kit's own compose file can see.
    for kit_name in _kit_images:
        cfg = services.get(kit_name)
        if isinstance(cfg, dict) and cfg.get("ports"):
            published = ", ".join(str(p) for p in cfg["ports"])
            problems.append(
                f"{name}/{kit_name}: publishes ports ({published}) in a file that is "
                f"MERGED with the fetched stack, not substituted for it. Compose "
                f"appends a second file's `ports:` list rather than replacing it, so "
                f"this repository ends up with postgres on kit's port AND on this one. "
                f"Move the port with its variable in .env instead "
                f"(KIT_POSTGRES_PORT, KIT_REDIS_PORT, …) — a variable replaces, a list "
                f"appends."
            )

    for backend in AGPL_BACKENDS:
        svc = services.get(backend)
        if not isinstance(svc, dict):
            continue
        if "build" in svc:
            problems.append(
                f"{name}/{backend}: has a `build:` stanza. The four Grafana-licensed "
                f"backends are shipped UNMODIFIED as a condition of AGPL-3.0, and "
                f"rebuilding one is a fork."
            )
        image = svc.get("image")
        upstream = _kit_images.get(backend)
        if image and upstream and not str(image).startswith(str(upstream).split(":")[0] + ":"):
            problems.append(
                f"{name}/{backend}: image {image!r} is not the stock {upstream!r} the "
                f"licence condition names."
            )



def check_dead_collector_config(repo: str, name: str, compose_files: list, problems: list) -> None:
    """FAILURE MODE 3 - collector configuration in the repository, and what it does.

    One owner for the FILE, and this is it. Mode 2 also reported the file's mere
    EXISTENCE, which meant a repository with one stray `otel-collector.yml`
    produced two findings for one defect, and a self-test breakage could not say
    which check it had proved. A file has one home and one verdict.

    Two verdicts, because there are two things it can be, and they need opposite
    fixes:

      INERT  nothing bind-mounts it. `docker compose up` reads the pinned ref's
             copy, so every edit to this file changes nothing at all while
             looking exactly like it would. Deleting it is the only fix; reverting
             a change to it achieves nothing, because it was never read.

      OWNED  one of this repository's own services mounts it. Then the
             repository is running its own collector with its own redaction
             allowlist, derived from nothing. That is the same boundary claim
             mode 2 makes about `volumes:` on kit's collector, reached by
             declaring a service of your own rather than by overriding kit's.

    Compose resolves a relative bind source against the DIRECTORY HOLDING THE
    FILE, not the process's cwd, so every source is resolved that way. A check
    that resolved it against cwd would call every service's mount wrong and
    report a healthy repository as inert.
    """
    own = os.path.join(repo, COLLECTOR_CONFIG)
    if not os.path.isfile(own):
        return
    real = os.path.realpath(own)
    mounting = ""
    for compose in compose_files:
        services = (compose or {}).get("services") or {}
        for svc_name, svc in services.items():
            if not isinstance(svc, dict):
                continue
            for entry in svc.get("volumes") or []:
                source = entry.get("source") if isinstance(entry, dict) else (
                    str(entry).split(":")[0] if isinstance(entry, str) else ""
                )
                if not source:
                    continue
                if source.startswith("/"):
                    resolved = os.path.realpath(source)
                else:
                    resolved = os.path.realpath(
                        os.path.join(os.path.dirname(compose["__path__"]), source)
                    )
                if resolved == real:
                    mounting = svc_name
    if not mounting:
        problems.append(
            f"{name}/{COLLECTOR_CONFIG}: exists, and NOTHING MOUNTS IT. No compose "
            f"service in this repository bind-mounts it into a container, so the "
            f"collector that actually runs is reading the pinned kit ref's copy. "
            f"Editing this file changes nothing - not the redaction allowlist, not an "
            f"endpoint, nothing - while looking exactly like it would. Delete it; a "
            f"boundary that needs to change changes in core and in a new kit release, "
            f"not in a local file nobody reads."
        )
    else:
        problems.append(
            f"{name}/{COLLECTOR_CONFIG}: mounted by this repository's own "
            f"{mounting!r} service. So this repository runs its own collector with "
            f"its own redaction allowlist, and that allowlist is derived from "
            f"nothing - kit DERIVES it from core's schemas, and a service-owned copy "
            f"is one nobody keeps in step. Delete the file and the service: "
            f"`bin/dev` mounts the pinned ref's, and `<SERVICE>_OTEL_ENDPOINT` is the "
            f"only way to send telemetry somewhere else."
        )


def check_pin(repo: str, name: str, problems: list) -> None:
    """FAILURE MODE 4 - no ref, or a ref that moves.

    A 40-character commit sha, or a semver tag. Not a branch, not empty, not an
    abbreviated sha. Same rule and same reason as `validate_ref` in
    `templates/bin/dev.sh`, which refuses the same set at run time; the two are
    written out twice on purpose, because one is a gate review runs and the
    other is a gate a developer's `bin/dev` runs, and a rule that exists in only
    one of them is a rule that one of them does not have.

    This regex is STRICTER than `validate_ref` on exactly one point, and that
    direction is the safe one: `validate_ref` accepts `v01.2.3` because it counts
    digits, and semver forbids a leading zero. A repository the gate refuses and
    `bin/dev` accepts is reported; the reverse would be a hole.

    ABSENCE IS A FINDING, and this is the one judgement in the file a reader
    should check against the packet rather than take on trust. An earlier version
    treated "no .env" as "not a defect", on the grounds that `bin/dev` creates
    `.env` on first run. That was true while the pin lived in `.env` and it is
    false now: the pin is `kit.ref`, it is committed, and a repository without
    one has not said which kit it runs at all. Softening it to keep the fleet's
    first column green would be exactly the move this packet exists to refuse.
    """
    value, source = read_kit_ref(repo)
    if source == "absent":
        problems.append(
            f"{name}/kit.ref: ABSENT. `bin/dev` is the only callable path to the "
            f"stack - a compose file cannot be `uses:`-ed - so a repository with no "
            f"kit.ref has not said which bytes of kit it runs. Write one line: "
            f"`git -C ../kit rev-parse HEAD > kit.ref`."
        )
        return
    if source == "unreadable":
        problems.append(f"{name}/kit.ref: present but unreadable")
        return
    if source == "empty":
        problems.append(
            f"{name}/kit.ref: EMPTY. An empty pin is not a pin. Write a "
            f"40-character commit sha or a v<semver> tag."
        )
        return
    if source == "many":
        problems.append(
            f"{name}/kit.ref: {value!r} and more. The file holds exactly one value - "
            f"the ref - and everything else in it is a comment."
        )
        return
    if SHA_RE.match(value) or SEMVER_RE.match(value):
        return
    if re.match(r"^[0-9a-f]{7,39}$", value):
        problems.append(
            f"{name}/kit.ref: {value!r} is an ABBREVIATED sha. `git fetch` resolves "
            f"one happily and it is ambiguous across remotes, so two machines can "
            f"disagree about what it meant. Use all forty characters."
        )
        return
    problems.append(
        f"{name}/kit.ref: {value!r} is not a PIN - it is neither a 40-character "
        f"commit sha nor a v<semver> tag. A branch name is a MOVING reference: "
        f"`bin/dev` would fetch whatever it points at today, so the redaction "
        f"allowlist and the port block this repository's dev loop runs would change "
        f"between two runs of the same command. `bin/dev pin <ref>` moves it "
        f"deliberately and prints the stack diff first."
    )


# Filled in by main() from kit's own compose file. Module-level so the check
# functions can read it without threading it through every signature, and
# deliberately so: a `kit_images` argument would be one more thing a caller
# could pass wrong, and this value has exactly one correct definition.
_kit_images: dict = {}

# ...and the name of the ONE service in that file which is the cluster, filled in
# the same way and for the same reason.
#
# DERIVED, not written down as `"postgres"`, and the derivation is the service
# that declares `KIT_POSTGRES_DATABASES`. That is the variable the init script
# reads and the only way a service gets a database, so the service carrying it
# IS the cluster by definition rather than by a name somebody chose. It matters
# because `_own_thing` and the cluster-environment check both have to know which
# service is the cluster, and a literal would be a second place to edit if kit
# ever renamed it — the exact drift `_UPSTREAM_BUILT_FROM`'s comment records
# happening to the image name.
_kit_cluster_service: str = ""


def discover(repos_dir: str) -> list:
    """Every immediate subdirectory that is its own repository.

    `kit` is excluded, and so is anything that is a worktree. The first is
    obvious; the second is the same reason `staleness.py` has the same exclusion,
    and the two lists have to agree or the fleet has a different size depending
    on which script asked.
    """
    found = []
    try:
        entries = sorted(os.listdir(repos_dir))
    except OSError as exc:
        raise SystemExit(f"fleet_check.py: cannot read {repos_dir}: {exc}")
    for entry in entries:
        if entry == "kit" or entry.startswith("kit-worker"):
            continue
        path = os.path.join(repos_dir, entry)
        if not os.path.isdir(path) or not is_checkout(path):
            continue
        if is_worktree(path):
            continue
        found.append(entry)
    return found


def main(argv: list) -> int:
    parser = argparse.ArgumentParser(
        prog="fleet_check.py",
        description="Gate the fleet on adopting kit's stack rather than copying it.",
    )
    parser.add_argument("--kit", required=True, help="the kit checkout to check against")
    parser.add_argument("--repos-dir", default=None,
                        help="directory holding one checkout per cafaye repository")
    parser.add_argument("--service", action="append", default=[], metavar="NAME",
                        help="restrict to these repositories (repeatable)")
    parser.add_argument("--no-fleet", action="store_true",
                        help="accept that there is no fleet (exit 0 with a note)")
    args = parser.parse_args(argv)

    kit = os.path.abspath(args.kit)
    kit_compose_path = os.path.join(kit, "templates", "compose", "docker-compose.yml")
    if not os.path.isfile(kit_compose_path):
        raise SystemExit(f"fleet_check.py: no kit stack at {kit_compose_path}")
    # Image STRINGS, keyed by kit's service name. The first version stored the
    # whole `services:` mapping here and `check_stale_copy` called `.split()` on
    # each value, so the check raised AttributeError on the FIRST repository and
    # printed a traceback instead of a finding. Nothing had ever run it.
    #
    # An `image:` is `${KIT_POSTGRES_TAG:-17}` in kit's own file, so the
    # stored string is the substitution with the default expanded — which is what
    # makes the comparison against a service's `postgres:18-alpine` work at all.
    # For the cluster that string is `kit-postgres:17`, and the UPSTREAM half of
    # the comparison comes from `_UPSTREAM_BUILT_FROM` rather than from here.
    for name, svc in (load_yaml(kit_compose_path).get("services") or {}).items():
        if isinstance(svc, dict):
            _kit_images[name] = _expand(svc.get("image") or "")
    if not _kit_images:
        raise SystemExit(
            f"fleet_check.py: no services with an `image:` in {kit_compose_path}. "
            f"That is a broken kit, and a check that silently compares against "
            f"nothing is how six copies of the platform stood unnoticed."
        )

    # Which service is the CLUSTER, and it is REFUSED loudly rather than
    # defaulted, for the reason the `_kit_images` refusal above gives: a check
    # that compares against nothing reports a clean fleet. This one is worse in
    # a specific direction — with no cluster service, the override check below
    # matches nothing, so the fleet would be reported clean precisely on the
    # repositories carrying the override kit used to recommend.
    global _kit_cluster_service
    for svc_name, svc in (load_yaml(kit_compose_path).get("services") or {}).items():
        if not isinstance(svc, dict):
            continue
        if "KIT_POSTGRES_DATABASES" in (svc.get("environment") or {}):
            _kit_cluster_service = svc_name
    if not _kit_cluster_service:
        raise SystemExit(
            f"fleet_check.py: no service in {kit_compose_path} declares "
            f"KIT_POSTGRES_DATABASES. That is a broken kit: without it there is "
            f"no shared cluster, and every advice message below loses the "
            f"variable that is the whole mechanism."
        )

    repos_dir = args.repos_dir or os.path.join(kit, "..")
    if args.service:
        names = list(args.service)
    else:
        names = discover(repos_dir)

    if not names:
        if args.no_fleet:
            # A MACHINE-READABLE marker, and the reason it is one. `validate.sh`
            # has to decide between PASS, FAIL and SKIP from this exit code, and
            # "no fleet was found" is a third answer that is neither of the
            # first two. Deciding it here — in the one place that knows what a
            # repository is — rather than in the caller means there is no second
            # discovery predicate to keep in step. The first version had one in
            # each, and they disagreed: the caller asked "are there any files
            # here?", which is true of a self-test's throwaway directory.
            print(f"FLEET-ABSENT: no cafaye repository under {repos_dir}")
            return 0
        raise SystemExit(
            f"fleet_check.py: no cafaye repositories under {repos_dir}. "
            f"Pass --repos-dir, or --no-fleet to accept it."
        )

    problems: list = []
    warnings: list = []
    # The repositories each warning is about, so the ceiling's own output can say
    # "across 6 repository(ies)" about the debt and not about the whole fleet.
    warned_repos: set = set()
    checked = 0
    adopted = 0
    failing: set = set()
    out_of_scope = 0
    for name in names:
        repo = os.path.join(repos_dir, name)
        if not os.path.isdir(repo):
            problems.append(f"{name}: named on the command line and not found under {repos_dir}")
            continue
        # Scope. `--service` is an explicit request and is NOT narrowed: a caller
        # that names a repository has already made the scoping decision, and a
        # flag that quietly ignored its own argument would be a worse tool than
        # one without the flag.
        declared = declares_local_infrastructure(repo)
        if not declared and not args.service:
            out_of_scope += 1
            continue
        # A repository IN SCOPE with no compose file still gets the pin and the
        # dead-config checks, because both are about files rather than about
        # compose. `parlor`-shaped repositories never get here: an `e2e/`
        # compose file is not a root compose file, and neither is a spec
        # repository that ships no infrastructure at all.
        compose_path = find_compose_file(repo)
        compose_docs = []
        # Every finding for this repository lands here first, and the CEILING
        # decides where they go at the end. Collecting first and routing once is
        # what keeps the ceiling honest: a check that appended straight to
        # `problems` would be choosing its own severity, and a check that
        # short-circuited on an unreadable file would be exempt from the ceiling
        # in precisely the case where the file is most wrong.
        found: list = []
        if compose_path:
            try:
                doc = load_yaml(compose_path)
            except Exception as exc:
                found.append(
                    f"{name}/{os.path.basename(compose_path)}: not valid YAML: {exc}"
                )
                doc = None
            if doc is not None:
                # `__path__` is where a relative bind-mount source is resolved
                # from. Compose resolves it against the directory holding the
                # file, not the process's cwd, and a check that resolved it
                # against cwd would call every service's mount wrong.
                doc["__path__"] = compose_path
                compose_docs.append(doc)
        check_pin(repo, name, found)
        check_dead_collector_config(repo, name, compose_docs, found)
        for doc in compose_docs:
            check_stale_copy(repo, name, doc, found)
            check_override_surface(repo, name, doc, found)

        # THE CEILING, and the one place it is applied. Read once, from the same
        # `read_kit_ref` every other check's wording already assumes, so there
        # is no second definition of "adopted" to keep in step — the failure mode
        # this file already documents once (`reportUnusedDisableDirectives`-shaped
        # drift) does not get a second chance here.
        #
        # `source == "absent"` is the ONLY value that means "has not adopted".
        # An unreadable, empty or multi-valued `kit.ref` is a repository that has
        # adopted and written the pin wrong, and `check_pin` already says which
        # of those it is. Reading adoption from "the file is there" instead would
        # have been simpler and wrong: it would have made a broken pin a warning
        # in exactly the case where somebody tried to fix the last warning.
        if read_kit_ref(repo)[1] == "absent":
            if found:
                warnings.extend(found)
                warned_repos.add(name)
        else:
            adopted += 1
            if found:
                # Counted per DEFECTIVE repository, not per adopting repository.
                # `FAIL fleet: 1 problem(s) across 2 adopting repository(ies)` is a
                # sentence about two repositories when one of them is clean, and a
                # summary line that overstates the blast radius is the first thing
                # a reader stops trusting — which costs the gate the credibility it
                # needs to hold the line when adoption does arrive.
                failing.add(name)
            problems.extend(found)
        checked += 1

    print(
        f"{checked} repository(ies) declare local infrastructure and were checked"
        + (f"; {out_of_scope} have none and are out of scope" if out_of_scope else ""),
        file=sys.stderr if problems else sys.stdout,
    )
    # The ceiling is printed even when there is nothing to report, and it is
    # printed BY THIS PROGRAM rather than by the caller: a caller that decides
    # whether to print the rule is a caller that can be pointed at a fixture
    # fleet where it does not, and the rule stops being a property of the check.
    # When there are no warnings the line still appears, because the reader who
    # sees "PASS fleet" needs to know what PASS was measured against.
    #
    # It goes ABOVE the findings, not below them. A rule stated after the thing
    # it governs reads as an epilogue, and an epilogue is what a reader skips
    # when they are scanning for what went wrong.
    print(
        "CEILING fleet: a finding inside a repository that has a kit.ref is a FAIL; "
        "inside one that has not adopted, it is a named WARN and the run stays green. "
        "The four checks are "
        "identical either way — the strictness MOVES to where adoption exists, it "
        "does not disappear. A warning is a debt with a name, and the adoption wave "
        "turns them into failures one repository at a time.",
        file=sys.stderr if (problems or warnings) else sys.stdout,
    )
    if warnings:
        for w in warnings:
            print(f"  WARN {w}", file=sys.stderr)
        print(
            f"WARN fleet: {len(warnings)} finding(s) across {len(warned_repos)} "
            f"repository(ies) that have not adopted kit's stack "
            f"({', '.join(sorted(warned_repos))}).",
            file=sys.stderr,
        )
        # The path ONCE, not once per repository. Six identical four-line blocks
        # is a wall, and a wall is read as boilerplate — which is how the one
        # line in it that a service owner has to type gets skipped. The
        # repositories are already named on the WARN line above, so nothing is
        # lost by printing it once for all of them.
        print("  the adoption path, for every repository named above:", file=sys.stderr)
        print(
            "    1. git -C ../kit rev-parse HEAD > kit.ref      # ONE committed line, and "
            "the only thing that decides which bytes of kit your machine runs",
            file=sys.stderr,
        )
        # STEP 2 IS THE ONE THAT WAS WRONG, and the paragraph that replaced it
        # said to override `POSTGRES_DB` / `POSTGRES_USER` on kit's postgres.
        #
        # This is the second copy of the defect `check_stale_copy` carried, and
        # it is worth being precise about which of the two is more dangerous,
        # because the answer is not the obvious one. The stale-copy finding is
        # read by somebody who is already fixing a stale copy; this line is read
        # by every unadopted repository in the fleet, every time one of them has
        # anything to fix — so it is the line that actually gets followed, and
        # `identity` followed it. It was printed by the very check that was
        # telling people to stop copying the stack, which is why it survived: the
        # recommendation and the detection came from the same program, and a
        # reader checking that line had no reason to suspect it.
        #
        # `KIT_POSTGRES_DATABASES` replaces it, and `POSTGRES_USER` is now named
        # as the thing NOT to do rather than as the thing to do. The measurements
        # behind both halves are in `_SHARED_CLUSTER_ENV`.
        print(
            "    2. your docker-compose.yml becomes an OVERRIDE beside the fetched "
            "stack, not a copy of it: delete your own postgres service and add your "
            "name to KIT_POSTGRES_DATABASES in .env, which is what gives you a "
            "NOSUPERUSER role and a database it owns. Do NOT override "
            "POSTGRES_USER / POSTGRES_DB / POSTGRES_PASSWORD on kit's postgres: the "
            "image creates POSTGRES_USER as a SUPERUSER, and the other two make "
            "CREATE ROLE / CREATE DATABASE fail during initdb and stop the whole "
            "cluster starting. The collector config is never yours to own.",
            file=sys.stderr,
        )
        print(
            "    3. move a published port with its VARIABLE (KIT_POSTGRES_PORT=…), "
            "because a second compose file's `ports:` list is APPENDED rather than "
            "substituted, so a `ports:` block buys you both ports",
            file=sys.stderr,
        )
    if problems:
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        print(
            f"FAIL fleet: {len(problems)} problem(s) across {len(failing)} of the "
            f"{adopted} adopting repository(ies) checked "
            f"({', '.join(sorted(failing))}). Every one of these is a repository "
            f"that HAS a kit.ref, so each is a defect against a standard it has "
            f"already adopted.",
            file=sys.stderr,
        )
        return 1
    if warnings:
        # The adopting count is stated even at zero, and `no repository has
        # adopted yet` rather than `0 repository(ies) are clean`. The second
        # phrasing reads as a boast, and this gate's whole subject is the
        # distance between the fleet and the standard — a summary that flatters
        # the current state is exactly the thing a reader stops trusting.
        clean = (
            f"{adopted} adopting repository(ies) are clean"
            if adopted
            else "no repository has adopted yet, so nothing is judged strictly"
        )
        print(
            f"PASS fleet: {clean} — no copy of the stack, no weakened boundary, no "
            f"dead collector config, every ref a pin. {len(warned_repos)} unadopted "
            f"repository(ies) carry {len(warnings)} named warning(s) above; that is "
            f"adoption debt, not a pass, and committing kit.ref is what converts it "
            f"into the failure it already is."
        )
        return 0
    print(
        f"PASS fleet: no service carries a copy of kit's stack, none weakens the "
        f"redaction boundary, no collector config is dead, and every kit.ref is a pin."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
