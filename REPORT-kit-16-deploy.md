# REPORT — kit-16-deploy

## This is a LOCAL deployment. It is not production.

**Everything in this packet was deployed to a Docker daemon on the machine it
ran on. Nothing was deployed to a remote host, a VPS, a domain, or anything
else. There is no production environment, and this packet did not create one.**

There is no real domain, no TLS, no reverse proxy, no multi-host scheduler, and
no real credential. This machine has none of those and this packet could not
obtain any without spending money or being granted access nobody offered. What
was built is the **full production shape** — immutable artifact, ordered
start, real health gates, restart policy, credential injection with a proven
boundary, automatic rollback on a failed gate — running against a local daemon.
The `courier` container really starts, really runs its migrations, really serves
`/readyz`, really goes **503** when its database is taken away, and really rolls
back to a previous artifact. The only thing missing is the remote host.

The rest of this document describes what was built, what was measured, and what
was not done.

---

## What was delivered

| Deliverable | State |
|---|---|
| A reference deployment, running and verified | **Done.** `courier` at `35c6a27`, release image, health gates green. |
| The distribution shape in `kit` | **Done.** `templates/deploy/` + `templates/bin/deploy.sh`. |
| Per-language differences tabled honestly | **Done.** Seven-row table, three differences that actually bite. |
| Every health check demonstrated red and green | **Done.** `/readyz` 200 → 503 → 200, container `healthy` → `unhealthy` → `healthy`, `deploy verify` 0 → non-zero → 0. |
| Rollback demonstrated, not described | **Done.** Container image reference observed before, during and after. |
| `REPORT-kit-16-deploy.md` | This file. |
| `CHANGELOG.md` | Done. |
| `tests/deploy_test.sh` | **Done.** 66 assertions across 9 sections, 0 failed, 0 skipped. |

### Files added — all new, nothing edited

```
templates/bin/deploy.sh                              the tool
templates/deploy/README.md                         the standard, scoped, polyglot table
templates/deploy/compose.deploy.yml                the distribution shape
templates/deploy/entrypoint.sh                     the secret gate
templates/deploy/redact.py                         the log redactor
templates/deploy/reference/courier.deploy.yml      the reference deployment
tests/deploy_test.sh                               the proofs
REPORT-kit-16-deploy.md                            this
CHANGELOG.md                                       one entry appended
```

`CHANGELOG.md` is the only pre-existing file this packet touched, because the
brief lists it as a deliverable and it is not one of the five files five other
workers are live in. **No other existing file was modified.** In particular
`tests/validate.sh`, `.github/workflows/ci.reusable.yml`, `templates/bin/dev.sh`,
the staleness reporter and the lint configs are untouched — see "What I could
not do" for what that costs.

---

## Re-verified after the OOM restart — and what changed

The machine this packet runs on ran out of memory and restarted mid-run. The
work was recovered from a commit and the re-dispatch was explicit that **every
conclusion the interrupted run had drawn is void.** So nothing below is inherited
from it. Everything in this document was re-measured, and this is what changed.

**The pin moved, and one claim in the first draft of this report died with the
image it was measured on.** The fleet's postgres image is now standardised on
`postgres:17-alpine`; the other postgres images were removed from this machine's
cache. Both deploy files now pin `postgres:17-alpine`, which is also what
`templates/compose/docker-compose.yml` uses, so a deploy and a `bin/dev up` run
the same database.

The interrupted run had justified the `curl`-in-a-slim-image claim with *"a
`postgres:17` container, which is Debian-slim-based, has neither `curl` nor
`wget`"*. That container no longer exists, so the claim could not be re-measured
as written — and it turns out it would not have survived re-measurement anyway:
`postgres:17-alpine` ships busybox, so it **does** have `wget`. The claim was
also citing the wrong container; it is a claim about application runtime images,
and a database is not one. Both documents now carry the corrected evidence, in
§5(b) and in `templates/deploy/README.md`, measured on the image that actually
carries the pin.

What else was re-measured rather than trusted:

| Claim | Re-measured how | Result |
|---|---|---|
| the postgres pin works with the secret gate | ran the whole suite on `postgres:17-alpine` | see **Tests** |
| distroless has no shell | ran the image | `/bin/sh` and `/bin/ls` both absent |
| the `docker cp` secret transport works for distroless | built a distroless image with one bare busybox and **no** `/bin/sh`, ran it, drove the tool's own functions | delivered, mode `0444`, barrier landed, value read back, `/bin/sh` genuinely absent |
| slim runtimes have a shell but no HTTP client | ran `python:3.13-slim` | `/bin/sh -> dash`; no `curl`, no `wget` |
| courier's release image has `curl` | ran it | `/usr/bin/curl`, no `wget`, `/bin/sh -> dash`, uid 65534 |

Two probe images were pulled and then removed, so nothing this packet added to
the machine's image cache survives it.

**One cleanup defect the restart exposed, and it is the packet's own rule being
broken by the interruption rather than by the code.** The test's teardown runs
from an `EXIT` trap, and a machine that is killed does not run traps: the
interrupted run left `kit-deploy-test-73232-app-1`, `kit-deploy-test-73232-db-1`
(the database still **paused**, mid-red-proof) and the `…_pgdata` volume behind.
They are namespaced to the test's own project, so removing them touches nothing
that is not this packet's, and they were removed. The lesson is recorded rather
than fixed, because the fix — a durable record of what to clean up — is
`deploy down`, which this packet already ships.

---

## Why `courier`, and why not `caf`

`courier` is Elixir/Phoenix, gate green and declared in `gate.yml` (535 tests at
`35c6a27`). It already has the two things a reference deployment needs and that
no other service in the fleet has:

1. a **release build** with its own start and migrate binaries, so the artifact a
   deploy ships is a self-contained image rather than a source tree; and
2. a **readiness endpoint that really checks its database** — `GET /readyz` runs
   `SELECT 1` and answers 503 when Postgres is taken away, while `GET /healthz`
   answers 200 regardless.

The argument is not that `courier` is representative. It is that a template
written against the *best* story in the fleet is the one least likely to
mislead the other eight. A template shaped by the weakest story misfits eight of
nine.

**`caf` was considered and rejected deliberately.** `caf` is the platform's own
resource-reclamation service, so a bug in its deploy path carries the authority
to destroy shared Docker state on a machine where other people and other
projects have containers running. Proving the pattern on the service least able
to survive a bad deploy would be a strange choice even if `caf` were otherwise
strong.

---

## 1. Credentials

The rule is absolute: never plaintext at rest, never logged, never in a config
file, never in a fixture, never in an error message. A deploy is the most
likely place in the platform to break it, because deploy tooling prints its own
configuration for a living.

### What the mechanism is

Secrets arrive on an **inherited file descriptor** and nowhere else. There is no
`--secrets-file`; the tool refuses the option by name, and that refusal is a
tested assertion rather than an accident of argument parsing.

They are delivered into a **tmpfs** — RAM, per container, destroyed with the
container — through the container's own **stdin**, so the value never appears in
`docker inspect`, in `docker compose config`, on the host disk, in the image, or
on any process's argv.

The container starts and the application does **not**. `entrypoint.sh` waits for
`/run/secrets/.loaded`, which the tool creates only after every claimed secret
is in place, and **exits non-zero if it never arrives**.

Everything the tool prints goes through `redact.py`, which has two layers: the
exact values it was given, and **shape** — JWT, bearer token, AWS key, provider
key, GitHub token, connection URL with a password, PEM header, and any
`*password*`/`*secret*`/`*token*`/`*api_key*` assignment. The credential's
*name* survives (`[redacted:jwt]`), so the log still says which one was in play.

### Measured

| Claim | How it was measured | Result |
|---|---|---|
| Secret is not in `docker inspect` | `docker inspect <app>` \| `grep -c <secret>` | **0 matches** |
| Secret is not in `docker compose config` | rendered config \| `grep -F <secret>` | **absent** |
| Secret is not in the deploy log | accumulated log \| `grep -F <secret>` | **absent** |
| Secret IS in the container | `test -s /run/secrets/DATABASE_URL` | **present** |
| The store is RAM, not a block device | `mount \| grep run/secrets` | **`tmpfs ... size=1024k`** |

The two positive assertions are what make the three negatives mean something:
a deploy that delivered nothing would have passed the leak audit cleanly.

### What this does not buy — stated plainly

- A process **inside** the container can read the credentials from
  `/run/secrets` and from `/proc`. The claim is that the credential never
  reaches an artefact a human or a CI job can read.
- The files are `0444`, not owned by the service account, because the tool
  cannot resolve the service uid portably across nine language runtimes. With a
  real secret provider this becomes `0400` owned by the service account, and the
  app reads the file rather than an exported variable. **courier reads
  `System.get_env("DATABASE_URL")` and would need a one-line change for that.
  That change is courier's to make and it was not made here.**
- Every credential in this packet was generated locally and is worthless. No
  real registry token, database URL, signing key or processor key was used,
  because none was available.

---

## 2. Health checks that can go red

### Demonstrated, on the reference deployment

| Signal | Database up | Database taken away | Database restored |
|---|---|---|---|
| `GET /readyz` | **200** | **503** | **200** |
| `GET /healthz` | 200 | **200** (unchanged) | 200 |
| App container healthcheck | **healthy** | **unhealthy** | **healthy** |
| Database container healthcheck | healthy | unhealthy | **healthy** |
| `deploy verify` exit | 0 | **non-zero** | 0 |

The database was taken away with `docker pause`, not `compose stop`. Stopping
the container destroys its tmpfs, so restarting it brings the database back
*without its password* and it never comes up at all — that tests the
secret-delivery path and nothing else, and it made the restore half of this
section fail for a reason that had nothing to do with readiness. Pausing freezes
the process and leaves the filesystem intact, so the database really stops
answering queries and really starts answering them again.

`/healthz` staying 200 is the half that is easy to get wrong in the other
direction. A liveness probe that fails on a dependency tells the supervisor to
restart a process that is fine, which turns a database blip into a fleet-wide
crash-restart loop and destroys the evidence needed to diagnose it.

### The redactor, executed rather than inspected

Seven proofs, all run with a known canary: a literal value, a value embedded in
a bearer token, a password inside a connection URL, a JWT the deploy never
supplied, a provider key, ordinary operational text that must **not** be masked,
and a sub-minimum-length value that must not be scrubbed as a literal. Each
asserts the canary is absent **and** that the surrounding sentence survived — a
filter that deletes the whole line passes "no canary found" while being useless.

### The refusals, executed

`--secrets-file` does not exist; a deploy with no secret source is refused; a
secret no service claims is refused **before a container is created**; a secret
line with no `=` is refused rather than guessed at; a secret too short to be a
credential is refused.

The unclaimed-secret check exists because its failure mode is the worst kind: a
deploy that reports itself green and then fails on its first real request with a
credential that was sitting right there.

---

## 3. Rollback

Demonstrated, with the container's image **reference** observed at three points:

```
before  cafaye-kit16/courier:35c6a27
after   cafaye-kit16/courier:35c6a27-rollback-target     <- the second deploy
back    cafaye-kit16/courier:35c6a27                      <- rollback
```

and the digest asserted to be **unchanged**, which is the evidence that rollback
re-used the previous artifact rather than quietly rebuilding something.

- The previous artifact is recorded in a ledger — image tags and digests only,
  **no secrets and no configuration** — *before* the new container starts.
- `deploy rollback` runs **the same deploy code path** with a different tag,
  including the same health gate. A rollback implemented as a second code path
  is a rollback never tested by the fact that deploys work.
- `deploy up` **rolls itself back** when the deploy cannot go green.

**The automatic rollback is now executed, not asserted.** Section 6 proves
`rollback` works when a human asks for it. Section 6b proves the third bullet —
the sentence the tool's header and the `CHANGELOG` both lead with, which until
this run was resting on reading the source. A deliberately broken artifact is
deployed: a **one-layer derivative of the good image with
`/app/bin/migrate` removed**. That construction is the point. Good and bad
differ by exactly the thing under test and nothing else, so a rollback that
appeared to work could not have worked by accident; and the failure mode is the
most ordinary bad release there is — it boots, it serves, it **passes its health
gate**, and it is still wrong, so only the migration step can catch it.

Asserted, all five: `deploy up` exited non-zero; the deploy **said** it was
rolling back; it did not report `ROLLBACK ALSO FAILED`; the container is serving
the previous artifact's image **reference** again, unprompted; and the ledger
never recorded the broken artifact as a successful deploy — because a bad
release in the ledger is something the *next* incident would roll back to.

The broken image is built at run time from a Dockerfile written into the suite's
own temp directory. A deliberately broken image has no business in the
repository, and the artifact exists for about ninety seconds.

**How long it takes:** the tool prints it (`ROLLBACK: healthy on the previous
artifact after Ns`) rather than this document asserting a number that would go
stale. In this packet's runs it was single-digit seconds, because the two
artifacts are the same image under different tags — the health-gate wait
dominates, and it is the same bounded wait every deploy uses.

### Three rollback bugs this packet found in itself

All three are recorded because all three were invisible until the test asserted
the right thing, and the third was invisible until something asserted the right
thing *about the automatic path*, which nothing had done.

1. **`rollback` did not read the credentials.** It re-runs the deploy path, the
   deploy path delivers secrets, and rollback had an empty secret list — so it
   failed at the first service with *"service claims secret 'POSTGRES_PASSWORD',
   which was not supplied"*. A rollback that cannot restart the stack it is
   rolling back fails exactly when it is most needed.
2. **`ledger_last_ok` counted from the start of the file.** The ledger is
   append-ordered, so the newest entry is the *last* line; the original walked
   forwards, which made `rollback` redeploy the artifact that was **already
   running**, report success, and change nothing.
3. **`deploy up`'s automatic rollback asked the ledger the wrong question**, and
   this one is worth reading twice. Both callers used index `1`, but they want
   different things. A rollback a **human asked for** runs while a good artifact
   is current, so it must reach past the head — index `1`. A deploy that
   **failed** never appended to the ledger (`do_deploy` appends only on
   success), so the newest entry *is* the artifact that was serving a moment ago
   — index `0`.

   Both failure modes are silent, and the second is the dangerous one:

   - with a ledger of `[A ok]` and a first-ever bad release, index `1` is out of
     range, `ledger_last_ok` returns non-zero, and the rollback was **skipped
     entirely** — leaving the stack on the broken artifact. That is the exact
     outcome the feature exists to prevent, reached *by* the feature.
   - with a ledger of `[A ok, B ok, A ok]` — a rollback having just happened,
     which is the normal state after an incident — index `1` is `B`: the release
     that had already been rolled back **away from**. The deploy reported a
     successful rollback and moved the service to a version nobody had asked for.

   `do_rollback_impl` now takes the index as a parameter, `cmd_up` passes `0`,
   `cmd_rollback` passes `1`, and a failed first-ever deploy **says out loud**
   that there is nothing to roll back to rather than skipping over it.

The second is why the test asserts on the image **reference** and not the
digest: the two tags under test point at the same image and therefore share a
digest, so a digest assertion would have passed against a rollback that did
nothing at all. The third is why §6b asserts on the image reference *and* on
the ledger: a rollback to the wrong artifact reported success and served traffic
perfectly happily, so every "it exited 0" assertion in this packet would have
passed straight through it.

---

## 4. Not touching state that is not ours

Every container, network and volume is named by the compose project, which
defaults to `kit-deploy-<service>`.

**The first version of this section asserted that by reading the source** — "no
`docker system prune`, no `docker volume prune`, no unprefixed `docker rm`
anywhere in the tool or its tests". That is an inspection, not a proof, and the
defect it would miss is a one-line edit to `cmd_down` that no reviewer would
notice in a diff. **So it is now executed.** Section 9 of the suite creates a
container and a volume that belong to this script and to nothing else, names
them so they are *not* part of the compose project, and asserts that both
**survive `down` and `down --purge`**. It goes red if `cmd_down` ever grows a
prune or an unprefixed `docker rm` / `docker volume rm`, and it also asserts
the promise `--purge` makes — that a plain `down` keeps the volume and a purging
one does not — because a flag nobody checks is a flag nobody should trust with a
database.

The same section asserts that `down` **removes the ledger**, which is the
subtler half: a ledger that outlives its stack points the next `rollback` at an
artifact whose database volume no longer exists, which is a rollback that cannot
come back.

And the scoping is **executed, not asserted by inspection**. The suite creates a
container and a volume that belong to it and to nothing else, named so that they
are deliberately *not* part of the compose project, and asserts that both
**survive** `deploy down` **and** `deploy down --purge`. This goes red if
`cmd_down` ever grows a prune or an unprefixed `docker rm` / `docker volume rm`
— which is the whole point. An inspection ("there is no `docker system prune`
anywhere in this file") is not a proof: the defect it would miss is a one-line
edit to `cmd_down`, and a reader reviewing that diff sees nothing alarming.

`down` and `down --purge` are also both exercised for what they *promise*: a
plain `down` **keeps** the project's volume, `--purge` removes it, and both
remove the ledger, so a later deploy knows it is the first one.

Verified after the run:

- `kit16-*` / `kit-deploy-test-*` containers: **none remain**
- `kit16-*` / `kit-deploy-test-*` volumes: **none remain**
- `searxng-core`, `searxng-valkey`: **running, untouched**
- `buildx_buildkit_kamal-local-docker-container0_state`: **present, untouched**

---

## 5. Polyglot: a table, not a template

A template that is wrong for eight of nine services is worse than no template,
so the differences are tabled. Facts are read from the seven Dockerfiles in
`docker/`; every row marked *measured* was measured by running the image on this
machine after the restart, and rows not marked are read from a Dockerfile rather
than verified.

| | Runtime image | App user | Shell? | `curl`? | Health probe from inside | Start command | Migrations |
|---|---|---|---|---|---|---|---|
| **go** | `distroless/static-debian12:nonroot` | `nonroot:nonroot` | **no** *(measured)* | no | exec-form only | `/app/service` | none |
| **rust** | `distroless/static-debian12:nonroot` | `nonroot:nonroot` | **no** *(measured)* | no | exec-form only | `/app/service` | none |
| **ruby** | `ruby:<v>-slim` | `app` | yes | no *(see b)* | `ruby -rnet/http -e` | `bin/rails server` | `bin/rails db:migrate` |
| **python** | `python:<v>-slim` | `app` | yes | no *(measured)* | `python -c 'urllib…'` | `python -m app` | framework / Alembic |
| **node** | `node:<v>-slim` | `node` | yes | no *(see b)* | `node -e 'fetch(…)'` | `node dist/main.js` | varies |
| **bun** | `oven/bun:<v>-slim` | `bun` | yes | no *(see b)* | `bun -e 'fetch(…)'` | `bun run src/index.ts` | varies |
| **elixir** | `elixir:<v>-otp-<otp>-slim` | `app` | yes | not in kit's Dockerfile | `curl` — courier's Dockerfile installs it *(measured)* | `bin/app start` | `bin/migrate` |

What "measured" means here, precisely, because the previous version of this
document claimed a verification it could no longer reproduce. Four images were
probed after the restart, one per distinct base: `gcr.io/distroless/static-debian12:nonroot`,
`python:3.13-slim` (the pin in `docker/Dockerfile.python`), `postgres:17-alpine`,
and courier's own release image. `ruby`, `node` and `bun` share
`debian:<trixie>-slim` with `python` and are marked *see (b)* rather than as
independently measured. The two pulled probe images were removed afterwards.

### (a) `distroless` has no shell, so a shell-script secret gate cannot be mounted into it

`docker/Dockerfile.go` and `docker/Dockerfile.rust` are
`gcr.io/distroless/static` — no shell, no coreutils, no `curl`.
`entrypoint.sh` is a shell script, so it cannot run in those images at all.

The tool **asks the container rather than the operator**: it tries one
`docker exec`, and when there is no shell it switches transport to a tar streamed
over `docker cp`, which moves bytes over the Docker API instead of exec'ing
anything. The `.loaded` barrier becomes an extra tar member, so a distroless
service gets the identical guarantee.

**Re-measured end to end after the restart, because the claim is the most
load-bearing one in this packet and it covers two of the nine services.** The
measurement has a wrinkle worth recording: a stock distroless image contains no
**process** at all — `docker run` on it fails with `no command specified` — so a
running distroless container cannot be made without adding a binary to it. A real
go or rust service image is distroless *plus* a static binary, so the probe image
was `FROM gcr.io/distroless/static-debian12:nonroot` with busybox copied in as a
bare `/busybox`, deliberately **not** as `/bin/sh`. That yields a running
container with a process, a tmpfs, and no shell, which is the only combination
that exercises this path. With the tool's own functions copied verbatim:

| Step | Result |
|---|---|
| `docker exec -u 0 … sh -c 'exit 0'` | no shell |
| the tool's `container_has_shell` | correctly answered *no shell* |
| `tar_stream API_TOKEN` | one-member tar, mode `0444` |
| `docker cp - cid:/run/secrets/` | delivered into the tmpfs |
| `tar_stream .loaded` → `docker cp` | barrier member landed |
| `docker cp cid:/run/secrets/API_TOKEN -` | read the value back out |
| `docker cp cid:/bin/sh -` | **absent from the image**, not merely unwritable |
| `docker inspect … .Config.Env` | no credential, before or after |

The limit: a distroless container cannot run a migration that is not a
subcommand of its own binary, and cannot run the credential-exporting wrapper
the other seven get for free. For those two languages the honest answer is a
service-provided subcommand, and it is a per-service fact.

### (b) A `CMD-SHELL` healthcheck needs a shell; a `curl` healthcheck needs `curl`

These are two different requirements and the slim runtimes satisfy only one of
them:

- **a shell: present.** Measured on `python:3.13-slim` — `/bin/sh -> dash`.
- **`curl`: absent.** Measured on `python:3.13-slim` — neither `curl` nor
  `wget`.

The healthcheck in `compose.deploy.yml` is written with `curl` **because
courier's own Dockerfile installs it deliberately** (measured: `/usr/bin/curl`,
no `wget`, `/bin/sh -> dash`), and the other eight must each use their own
runtime's HTTP client or add the probe tool to their image. For `go` and `rust`
it must be exec-form:

```yaml
healthcheck:
  test: ["CMD", "/app/service", "healthcheck"]
```

which requires the service to implement a `healthcheck` subcommand that exits
non-zero when it is not ready. **There is no way to probe a distroless service
from inside without either a shell or a subcommand the service provides.**

**And the correction this section now carries.** The previous version of this
report justified the row above with *"verified: a `postgres:17` container, which
is Debian-slim-based, has neither `curl` nor `wget`"*. That evidence is gone:
the fleet's postgres pin is `postgres:17-alpine` and the other postgres images
were removed from this machine's cache, so the container the claim was measured
on no longer exists and could not be re-measured. It was also the wrong
container to cite — the claim is about the **application** runtime images, and a
database is not one.

Measured on `postgres:17-alpine` instead: `/bin/sh` (busybox), `pg_isready`,
`psql`, `docker-entrypoint.sh` on `PATH`, uid 0, **no `curl`, and `wget` present**
(busybox). So the old evidence would not have survived the pin even if the image
had still been here, and the corrected story is better than the one it replaces:
the database is the worked example of probing with the right tool for the image
rather than the wrong one. What a database has to answer is "do I accept
connections", and `pg_isready` is the one binary in that image that says so — an
HTTP-shaped probe would have been wrong there regardless of which HTTP client
was present.

### (c) None of kit's seven Dockerfiles declares a `HEALTHCHECK`

The health signal comes from the compose file. A service that wants the signal
to survive being run without compose must add the line itself, and for `elixir`
that means adding `curl` to the image first.

### And the one that is genuinely per-service

Migrations: `bin/rails db:migrate`, `manage.py migrate`, `bin/migrate`
(which runs `Courier.Release.migrate/0`), and **nothing at all** for a Go or
Rust service that owns no schema. It is a `kit.deploy/migrate` label rather than
a rule in the tool, because a rule would be wrong for at least four of the nine.

---

## Tests

`bash tests/deploy_test.sh`

**66 passed, 0 failed, 0 skipped** on a run with the image present, in nine
sections.

- **13 assertions run with no Docker at all** (the redactor, and the six
  refusals) — and they are the ones that matter most, because they are the ones
  a machine without a daemon still gets.
- **53 assertions are live** and need the daemon and an image. Without them the
  suite **SKIPs loudly with the build command printed**, never silently.
- **No sleeps.** Every wait is a poll on a real signal — an HTTP status, a
  container health status, an image reference — against a deadline. `sleep`
  appears only as the interval *between* polls.
- **No raised retries, no loosened assertions.** Several were made *stricter*
  during the work (see below).
- Pass and skip counts are reported **separately**, as everywhere else.

### Assertions that got stricter, and what forced it

- **The test now refuses to run on an occupied port.** A leftover stack from an
  earlier manual run was still publishing the test's port, so `curl /readyz` was
  answered by a stack the script had not created and two assertions reported
  PASS against a stranger's service. A deploy test that can silently measure
  the wrong thing is worse than one that refuses to run.
- **Rollback asserts the image reference, not the digest.** See §3.
- **The restore now waits for the whole stack to be green**, not just for one
  HTTP endpoint. `/readyz` can be 200 a second or two before Docker's own
  healthcheck has cleared its failure streak; section 6 was racing that and
  reporting it as *"the second artifact did not reach green"*, which pointed at
  the deploy rather than at the test.
- **A failed deploy now prints its own output, to stderr.** The caller
  redirects the function's stdout, so diagnostics on stdout were invisible. This
  cost three debugging cycles.

### Bugs the test found in the deliverables

Every one of these was a real defect in the tool or the templates, not in the
test. Listing them is the most useful thing this packet has to say about its own
method, because each was found by a check written to be able to fail rather
than by reading the code:

1. the claim check matched names with a **space** on both sides while emitting
   them one per line, so only the first label ever matched;
2. **`docker exec` does not inherit PID 1's environment**, so an exec'd
   migration never saw the injected credentials while the service was healthy;
3. `POSTGRES_PASSWORD` and `POSTGRES_PASSWORD_FILE` are **mutually exclusive**
   in the official postgres image, which killed the database on boot;
4. `PHX_SERVER` in the environment made `bin/migrate` start the endpoint and
   fail to bind port 4000, which the already-running server held;
5. the placeholder image variable leaked into **rollback's** deploy, which
   passes no `--image`, so compose tried to pull a repository named
   `kit-deploy-no-artifact-required-for-this-command`;
6. `ledger_last_ok` counted from the **start** of an append-ordered file, so
   rollback redeployed the artifact that was already running (see §3);
7. `do_rollback_impl` **ignored its index argument** and always reached one
   entry too far back, so a failed deploy's self-rollback restored the artifact
   that had already been rolled back away from;
8. a later `compose up` can **recreate an earlier service** as a side effect —
   observed when `postgres:17` was re-pulled and its digest no longer matched —
   leaving it alive with an empty `/run/secrets` and taking the application
   down through `depends_on: service_healthy`;
9. `note()` was **not scrubbed**, on the reasoning that progress lines are
   written by the tool and are therefore safe. That is the exact reasoning that
   makes a leak feel safe right up until a secret is interpolated into one.

### kit's own gate

`bash tests/validate.sh` → **150 PASS, 0 FAIL, 2 SKIP**, and
`PASS: every check passed.`

Both skips are **pre-existing and not mine**:
`templates/tier/{bun,node}/tier.test.ts` — stock `node --check` cannot read
TypeScript. An earlier run of this packet had **three** skips, because
`templates/bin/deploy` (no extension) got no syntax parser at all; renaming it
to `deploy.sh` took the count back to the two that were already there.

What the gate does to the new files, with no edit to `validate.sh`:

```
PASS  templates/bin/deploy.sh  (bash -n)
PASS  templates/bin/deploy.sh  (executable)
PASS  templates/bin/deploy.sh  (shellcheck -S warning)
PASS  tests/deploy_test.sh  (bash -n)
PASS  tests/deploy_test.sh  (shellcheck -S warning)
PASS  templates/deploy/compose.deploy.yml  (yamllint -c lint/yamllint.yml)
PASS  templates/deploy/reference/courier.deploy.yml  (yamllint -c lint/yamllint.yml)
```

---

## What I could not do, and why

### 1. I did not wire `tests/deploy_test.sh` into `tests/validate.sh`

**This is the one thing a reviewer should decide on, and I could not do it
without colliding with five live workers.** `validate.sh` invokes its test
scripts by **explicit name** (lines 3848 and 3849 for the observability proofs,
3873 for the staleness proof), not by glob, so a new test file is *linted* by the
gate but never *run* by it.

What the gate already does to the new files, with **no** edit to `validate.sh`:

- `templates/bin/deploy.sh` — `bash -n`, `shellcheck -S warning`, and the
  executable-bit check (all three by existing globs over `templates/bin/*`)
- `tests/deploy_test.sh` — `bash -n` and `shellcheck -S warning` (glob over
  `tests/*.sh`)
- `templates/deploy/*.yml` — `yamllint -c lint/yamllint.yml` (the gate lints
  **every** tracked YAML in the tree)

The change needed, for whoever owns `validate.sh` — one line in the
`observability` phase, beside the existing `canary_test.sh` check at line 3848:

```bash
check 'tests/deploy_test.sh  (health gates red and green, rollback, no leak)' \
  bash "$ROOT/tests/deploy_test.sh"
```

**It is one line, not two, and that is worth knowing before somebody adds the
obvious second one.** Adding `"tests/deploy_test.sh"` to the tuple at line 3319
would be wrong: that tuple is the gate's *"README.md documents this path AND
this path exists"* check, so the new entry would make the gate **fail** until
`README.md` also mentions the file — coupling this packet's wiring to an edit
in a second shared file. Either add the `check` line alone, or add both the
tuple entry **and** the README mention together.

One consequence to be aware of either way: `yamls_of_the_tree` uses
`git ls-files`, so **the new YAML files must be `git add`ed before the gate
sees them.** They are staged in this packet.

**Until the `check` line lands, the gate does not run these proofs.** That is a
real gap and it is stated here rather than papered over.

### 2. `templates/deploy/` is not referenced from `README.md` or `AGENTS.md`

Both are shared files with other workers live in them. A 1-line pointer in
`README.md`'s layout tree, and a `templates/deploy/` entry in the layout, are
outstanding. I chose to be one commit late over colliding.

### 3. **`AGENTS.md` says kit is "Config only. No runtime code" — and this packet adds three programs**

This is a genuine conflict with a written rule, and it is the most important
thing for the manager to resolve. `AGENTS.md` states:

> **Config only.** No runtime code, no dependencies, no generated output. If kit
> grows a dependency it has stopped being conventions.
> … `core/` ships a change classifier and a staleness reporter … The one carve-out
> … If a **third** program is proposed, the default answer is no.

This packet adds `templates/bin/deploy.sh` (bash), `templates/deploy/entrypoint.sh`
(POSIX sh) and `templates/deploy/redact.py` (Python) — a third, fourth and fifth
program. The brief instructed me to build them ("Use `templates/deploy/` for the
distribution shape and `bin/` for the tool"), and I did, but the rule is a real
one and I am not the authority to override it silently.

Arguments that this is a carve-out rather than a violation:

- kit already ships a program of exactly this kind: **`templates/bin/dev.sh`**,
  which the same rule's neighbours are written around.
- `redact.py` holds to the standard `core/` sets for its programs — standard
  library only, no import outside `json`/`os`/`re`/`sys`/`argparse` — and
  nothing imports it.
- A standard with nothing that *enforces* it is a standard enforced by whoever
  reads it, which is the reasoning `core/`'s carve-out already records.

**The decision needed:** amend `AGENTS.md`'s carve-out to name
`templates/bin/` and `templates/deploy/` explicitly, or reject the programs. I
have not edited `AGENTS.md` to make my own work conform.

### 4. The tool is `templates/bin/deploy.sh`, and the `.sh` is load-bearing

The brief said `bin/`. The tool is at `templates/bin/deploy.sh`, beside
`dev.sh`, and **the extension is not cosmetic.**

kit's gate dispatches its syntax parsers by **file extension** (`*.sh`,
`*.yml`, `*.mjs`, ...) with a `*)` arm that reports `no parser for this file
type`. My first version was named `templates/bin/deploy` with no extension,
following the brief's `bin/`, and the gate dutifully reported:

```
SKIP  templates/bin/deploy  (no parser for this file type)
```

`bash -n` did not run on the tool. `shellcheck` and the executable-bit check
did, because they use their own explicit path globs -- so the summary read
`note: 3 check(s) skipped` and one of the three was **mine**. `AGENTS.md` is
explicit that a new file type with no parser is a gap, and that the skip is how
you find it. This is exactly the class of defect that rule exists to catch, and
I introduced it.

Renaming to `deploy.sh` fixes it with **no edit to `validate.sh`**: the file
now matches the existing `*.sh` arm and is covered by the same dispatch that
covers `dev.sh`, while keeping kit's own naming convention. The tool's full
gate coverage is now `bash -n` + `shellcheck -S warning` + the executable-bit
check.

Flagging the deviation from the brief's literal `bin/` explicitly rather than
letting it pass as an implementation detail.


### 5. No remote target, no real credentials, no real domain

Stated at the top of this document and in §1. A paid provider would not have
helped: the blocker is a VPS and a domain, not a tool.

### 6. The other eight services are not deployed

The brief asked for **one** reference deployment, not nine. What exists for the
other eight is the shape, the tool, and the table. Copying it is mechanical
except for the three differences in §5.

---

## Notes for whoever picks this up

- The image must be built before the live proofs run:
  `docker build -t cafaye-kit16/courier:35c6a27 <courier-repo>`
  then `KIT_DEPLOY_TEST_IMAGE=cafaye-kit16/courier:35c6a27 bash tests/deploy_test.sh`.
  The build took ~13 minutes on this machine (60+ hex packages, `mix release`).
- The deploy file guards its image with `${KIT_DEPLOY_IMAGE:?...}` on purpose.
  That guard also makes the file unrenderable for `down` and `status` without
  the variable set, which is why the tool exports a placeholder and why every
  direct `docker compose` call in the test goes through the `dc` helper. A
  `stop db` that quietly failed on a missing variable would have turned the red
  proof green for the wrong reason.
- **`docker kill` does not trigger `restart: unless-stopped`** on this machine
  (Docker 29.4.0 / OrbStack) — measured with a stock `alpine sleep 300`, which
  stayed `exited` with `RestartCount 0`. A genuine crash does restart it, also
  measured. The test therefore terminates PID 1 *from inside* the container,
  which is the crash the policy exists for.
- **A tmpfs secret store does not survive a container restart.** A restarted
  container comes back **blocked at the credential gate**, by design, and
  `deploy up` re-delivers. On a real target an orchestrator re-injects secrets
  on every start and none of this is manual. This is precisely why the secret
  store cannot simply be a file on disk: "it worked until it restarted" would be
  the failure mode a plaintext credential file would have had.
- `docker exec` does **not** inherit PID 1's environment, so anything run inside
  a deployed container — a migration, a debug shell — must load `/run/secrets`
  itself. The tool's `run_with_secrets` does this; anything else that execs into
  a deployed container must too.
