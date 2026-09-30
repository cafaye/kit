# REPORT-kit-06-reclaim — the reclamation ledger

> **Read this first.** This packet did not build the tool. It verified the three
> claims the tool would be built on, and two of them turned out to be wrong, and
> the third has a hole in it that changes the design. It then hit a scope
> conflict it could not resolve inside its own instructions. Sections 2–4 are
> the evidence and are worth reading even if you skip the rest; section 5 is the
> decision I need.

## 1. What landed

| file | what |
|---|---|
| `REPORT-kit-06-reclaim.md` | this file |

No other file changed. The gate is green and `self_test` is 18/18 red-for-the-
right-reason, unchanged from the baseline I measured before touching anything
(`bash tests/validate.sh` → `GATE_EXIT=0`).

**Nothing was implemented, on purpose, and the reason is section 5.** Briefly:
the deliverables are a Go/bash CLI with a Docker dependency, and `kit` is a
config-and-docs repository that forbids exactly that in three separate places
in its own `AGENTS.md`. Writing it anyway would have produced a large diff in
the wrong repository, on a branch whose merge touches the same files as kit-04
and kit-05.

## 2. The leak is real, and reproduced

The packet's central claim is that `docker system prune --volumes` prunes
anonymous volumes only, and that a single leaked *stopped* container pins a
named volume forever. **Reproduced, hermetically, 11/11 assertions.**

The reproduction is surgical on purpose. Every resource is named `kit06*` and
carries `kit06.reclaim=demo`, and every prune is filtered on that label, so
"only mine" is enforced by the daemon rather than promised by the script. The
packet forbids a blanket `docker system prune -a` and requires leaving
`searxng-*` and the kamal buildkit volume alone; a filter is the only way to
demonstrate the mechanism without a `system prune` that would have reaped the
exited `buildx_buildkit_kamal-local-docker-container0` container.

```
== 1. a NAMED volume survives the anonymous-only prune ==
  PASS  named volume exists                                        yes
  PASS  named volume after prune (anon-only)                       survived

== 2. an ANONYMOUS volume does NOT survive the same prune ==
  PASS  anonymous volume created                                   yes
  PASS  anonymous volume after prune                               GONE

== 3. a leaked STOPPED container pins the named volume ==
  PASS  leaked container state                                     created
  PASS  named volume after prune --all, container alive            survived
  PASS  reason: volume still referenced                            1

== 4. containers before volumes: remove the container, then it reclaims ==
  PASS  named volume after container removal                       GONE

== 5. the size the leak actually costs ==
  local volumes now: Local Volumes: 4.958GB (50.33MB (1%) reclaimable)
  after anonymous-only prune: Local Volumes: 4.958GB (50.33MB (1%) reclaimable)
  after container-first + --all: Local Volumes: 4.908GB (0B (0%) reclaimable)

== 6. the volumes this script did NOT touch are still there ==
  PASS  searxng_core-data                                          survived
  PASS  searxng_valkey-data                                        survived
  PASS  buildx_buildkit_kamal-local-docker-container0_state        survived

11 passed, 0 failed
```

Section 5 is the money line. A 48 MiB volume is invisible (`50.33MB (1%)`), and
the anonymous-only prune reclaimed **zero** of it. Only removing the container
first and *then* asking for `--all` gave the 50.33MB back. That is the entire
mechanism in two lines of output, and it is why R5 says containers before
volumes, always.

The mechanism, exactly:

```
docker run --rm -v "$NAMED":/d --label kit06.reclaim=demo alpine:3 \
  sh -c 'dd if=/dev/zero of=/d/blob bs=1M count=48; sync'
docker create --name kit06reclaim-leaked --label kit06.reclaim=demo \
  -v "$NAMED":/var/lib/postgresql/data alpine:3 sleep 300   # created, not run
docker volume prune --all --force --filter label=kit06.reclaim=demo
#   -> the named volume is STILL THERE. One stopped container pins it.
docker rm -f kit06reclaim-leaked
docker volume prune --all --force --filter label=kit06.reclaim=demo
#   -> gone. 50.33MB back.
```

### The cited evidence volume no longer exists

`identity-worker-identity-06_postgres-data` is **not on this machine**. The three
volumes present at the start of this packet were `searxng_core-data`,
`searxng_valkey-data`, and `buildx_buildkit_kamal-local-docker-container0_state`
— the last two of which the packet explicitly says to leave alone. So I could
not re-demonstrate against the original artifact; I reproduced the mechanism
with a hermetic volume instead, which is the stronger proof anyway because the
state is controlled rather than inherited. I did not invent a claim about the
original volume.

## 3. R2 is *half* true, and the false half is the dangerous one

MD13: *"the Docker daemon as the port arbiter. Measured on this machine:
publishing a second container onto a claimed port gives `Bind for
127.0.0.1:32768 failed: port is already allocated` — an atomic, authoritative
claim-or-fail. The kernel is the single source of truth."*

**Container against container: confirmed, exactly, including the error string.**

```
first  container: started
second container: REFUSED
docker: Error response from daemon: failed to set up container networking:
  driver failed programming external connectivity on endpoint kit06b
  (548319d5...): Bind for 127.0.0.1:15002 failed: port is already allocated
```

**Container against a plain host process: NOT confirmed, and it fails silently.**

```
1. host process listening on 127.0.0.1:15004
   connect(127.0.0.1,15004) from a second socket: accepted

2. docker run -d -p 127.0.0.1:15004:80 -> STARTED (no error)

3. the host listener is still open and still bound
4. connections reach the HOST process: True
5. a fresh connect() succeeds: True
```

A host process is listening on 15004. `docker run -p 127.0.0.1:15004:80` exits
**0**, the container is **Up**, `docker ps` shows the mapping, and every
connection goes to the host process instead of the container. Nothing errors.
The container is running and unreachable.

This is the exact failure cafaye exists to prevent, and it is worse than the one
R2 was written about: R2's tiebreak produces a loud `port is already allocated`,
which a developer can act on. This produces a green-looking stack. A worker
whose test suite needs Postgres on 15000 gets a connection to *some* Postgres —
or to nothing at all — and the error lands in the code under test, at 3am, in a
wave of eight parallel workers. That is the invisible red run MD13 is trying to
prevent, arriving by a different door.

**Consequence for the design:** reserving under `flock` and letting Docker break
the tie is necessary and not sufficient. The tool must also *hold* the
reservation, because the only arbiter that sees both worlds is the kernel, and
the kernel only arbitrates for whoever is actually binding. Practically: a
reserved port stays bound (or a lockfile the containers' entrypoint honours)
for the life of the session, and the retry-on-"already allocated" path is a
backstop, not the mechanism.

This also promotes two rules from hygiene to load-bearing, which is the useful
part: R2.4 (*never `SO_REUSEPORT`*) and R2.5 (*probe both `127.0.0.1` and
`::1`*) are now the only things standing between cafaye and the silent
collision, because the daemon will not do it.

### R2.4 `SO_REUSEPORT`: the conclusion holds, the stated mechanism does not

MD13: *"On macOS it lets a second socket bind the same port and the kernel
load-balances between them."*

The bind part is confirmed. The **load-balancing is not** — it is total capture
by the last binder:

```
== R2.3 no SO_REUSEPORT: the second bind must fail ==
  PASS  second plain bind on the same port                       EADDRINUSE

== R2.4 SO_REUSEPORT: the second bind SUCCEEDS (the trap) ==
  PASS  second SO_REUSEPORT bind on the same port                SUCCEEDED

two SO_REUSEPORT sockets bound to 127.0.0.1:15410
  40 connections: first=0 second=40
  total accounted for: 40/40
  -> NO balancing. All 40 went to the socket bound second (bound last).
```

My first measurement of this queued all 40 connections and then drained one
socket, so the split I read could have been a drain-order artefact. The number
above connects **one** connection and drains **both** sockets after each, so no
connection can survive to be read out of order — it is per-connection assignment.
40/40 to the last-bound socket, twice.

The ruling's *conclusion* — never set `SO_REUSEPORT` in a prober — is correct and
the trap is in fact **worse** than described. Load-balancing would at least mean
your socket gets some of the traffic. Total capture means a successful bind
identifies which socket owns the port *not at all*, and the failure looks like
an unreachable service rather than a busy port. Ruling text should change; the
prohibition should not.

### R2.5 dual-stack probe: confirmed, both directions

```
== R2.5 dual-stack: an IPv4-only prober misses an ::1 listener ==
  PASS  IPv4-only probe against an ::1-only listener              ECONNREFUSED
  PASS  IPv6-only probe against a 127.0.0.1 listener              ECONNREFUSED
```

An IPv4-only prober calls a port free while something is genuinely listening on
it. Given section 3's finding, this is not academic.

### A live instance of the problem, from a sibling worker

While testing I found another worker's container publishing a port **inside the
block MD13 reserves for cafaye**:

```
identity-pg-identity10   0.0.0.0:15001->5432/tcp, [::]:15001->5432/tcp
```

15001 is in 15000–15999. Parallel workers are hand-rolling ports into the very
range the port registry exists to arbitrate, which is the sprawl MD13 describes
(21101/55432/16001) starting again one packet later. Left alone — not mine.

## 4. R1 (Ryuk): every claim checked against the source

Cloned `testcontainers/moby-ryuk` and read it rather than trusting the summary.

| MD13 claim | verdict | evidence |
|---|---|---|
| MIT | ✅ | `"license": {"spdx_id": "MIT"}` |
| 246 stars | ✅ | `"stargazers_count": 246` |
| actively pushed | ✅ | `pushed_at 2026-09-18` (12 days ago), `archived: false` |
| `ACK\n` per line | ✅ | `ackResponse = []byte("ACK\n")`; `require.Equal(t, "ACK\n", …)` |
| the connection is the lease | ✅ | `pruneWait` counts `connected`/`disconnected`; prune fires on `clients == 0` |
| `label=org.testcontainers.*` | ✅ | `consts.go: labelBase = "org.testcontainers"` |
| `RYUK_RETRY_OFFSET=-1s`, the settle window | ✅ | README table: *"offset added to the start time of the prune pass … Any resource created after this calculated time will trigger a retry to ensure in use resources are not removed"* |
| `RYUK_RECONNECTION_TIMEOUT=10s` | ✅ | README table, default `10s` |
| R5: `RemoveVolumes: true, Force: true` | ✅ | `reaper.go:30 containerRemoveOptions = container.RemoveOptions{RemoveVolumes: true, Force: true}` |
| prunes images too | ⚠️ **needs rewording** | see below |

**The image warning is right in conclusion, wrong in mechanism.** MD13 says Ryuk
"prunes **images** as well as containers — never enable it with image filters."
The actual code is narrower and therefore safer than the ruling implies: images
are collected by `affectedImages(since, args)` with the *same* label filters
(`image.ListOptions{Filters: args}`) and removed with `image.RemoveOptions{PruneChildren: true}`.
A session-scoped label does not drag in unrelated images.

That is a *reason* to send only a session label and never a broad one — but the
ruling as written implies Ryuk will delete your images if you merely use it,
which is not what the code does, and a rule justified by a false mechanism gets
ignored the first time it is seen to be false. Worth correcting in MD13.

One protocol detail the packet gets subtly wrong, harmless but worth recording:
MD13 says "write `label=…` lines, read `ACK\n` per line". The real wire format
is one line per filter, and when a client sends several filters it joins them
with `&` on a single line (`strings.Join(labelFilters, "&") + "\n"`). One ACK
per line either way.

## 5. The scope conflict — the decision I need

**The packet asks for a runtime tool in a repository whose charter forbids
runtime code, and the repository that would actually own it is one I am
instructed not to touch.**

`kit/AGENTS.md` says, in three separate places:

> - **Contains:** configuration and documentation only. No runtime code, no
>   library, no build step, no dependencies.
> - **Not:** a CLI, a package, or a service. Nothing here is imported by anything.
> - **Config only.** No runtime code, no dependencies, no generated output. If
>   kit grows a dependency it has stopped being conventions.

Every deliverable in this packet is runtime code with a Docker dependency: a
`flock` ledger, a port registry, a Ryuk lease client, a reclaim sweep, a
`doctor`, and an `env up` that must be the *parent* of a test process. None of
it is config. `kit` does not depend on Docker at all today, and adopting Ryuk
would be the dependency the rule names.

Meanwhile `caf` — which PLAN.md describes as *"CLI in Go: init, new, dev,
deploy, gen, contract, mcp, install"* — already matches the deliverables almost
one for one:

| packet deliverable | `caf` today |
|---|---|
| `cafaye env up` (the local stack) | `caf dev [project]`, **marked "works"** |
| one subcommand per file | `internal/cli/<name>.go`, *"one file per subcommand"* |
| the port registry (R2) | `internal/dev/plan.go` already refuses on `ErrPortConflict` |
| `cafaye doctor` (R9 tri-state) | `doctor` already a working subcommand |
| the ledger + worktree coupling | nowhere yet — this is the genuinely new build |
| `cafaye gate` (R10 seam) | `internal/ci/` is *"no code; the test that keeps ci.yml honest"* |

And `caf`'s own `AGENTS.md` draws the boundary explicitly: *"the shared CI and
lint configuration comes from `cafaye/kit` — neither lives here."* The two repos
have already written down which side of the line each one is on, and this
packet's deliverables are on `caf`'s side of it.

So: the tool belongs in `caf`, and I was told to work only in `kit-worker-kit-06`
and not to touch other repos. Those cannot both be satisfied, and guessing wrong
costs a large revert plus a merge collision with kit-04/kit-05 in the same
files. I stopped and asked rather than picking.

**My recommendation:** re-dispatch the implementation to `caf` —
`internal/cli/{doctor,reclaim,gate,env}.go`, `internal/dev/` for the planner and
port registry, and a new `internal/ledger/` for the `flock` ledger and the `gen`
fencing token. The `gen` token and the ledger are the only genuinely new
subsystems; the command surface slots into a registry that already exists.

**What I would keep in `kit`, if the manager agrees it is worth a small
kit packet:** the naming convention that makes reclamation *possible at all* —
labelled volumes and a per-generation stack name in
`templates/compose/docker-compose.yml`, which already has
`name: ${KIT_STACK_NAME:-cafaye}` as the natural place for it. Today every
adopting repo's volumes are unlabelled, which is why nothing can tell a
worker's volume from a developer's. That is genuinely kit's to fix, it is
config, and it is the thing that would have prevented this leak rather than
cleaning it up afterwards.

## 6. Recorded as owed, not implemented

- **MD12, the tier policy.** Out of scope by the packet's own instruction, and
  correctly so. `cafaye gate` must take no arguments to pass, and a weak gate is
  worse than no gate, so I implemented no gate at all rather than a
  pass-able one. The seam `gate` needs is the receipt from `env up`; that seam
  is part of the re-dispatch above.
- **The `gen` fencing token (R4) and the tri-state `doctor` meta-test (R10).**
  Both are pure design and both belong with the implementation. Neither is
  meaningful in a repo that has no tool.

## 7. What I could not verify

- **"A closed connection reaps and an open one does not."** This is the packet's
  one named test for the lease and I did not run it. It needs a real Ryuk with
  `/var/run/docker.sock` mounted, and a socket-mounted reaper on a machine where
  `identity-pg-identity10` and a `kit-canary-*` pair are live is precisely the
  catastrophic outcome this packet exists to prevent: one malformed or empty
  filter degrades to "match everything" and reaps a sibling worker's
  database. I judged that not mine to risk unasked. The protocol is verified
  from source (section 4); the reaping behaviour is not. To verify it safely,
  run Ryuk against a Docker context with only labelled throwaway resources, or
  on a machine with no other workers.
- **`docker system prune --volumes` itself.** I demonstrated the
  anonymous-versus-named distinction through `docker volume prune`, which is the
  inner mechanism, with a label filter for safety. A bare `docker system
  prune --volumes` on this machine would additionally reap the *exited* kamal
  buildkit container — the packet says leave kamal buildkit alone, so I did not
  run it. The direction of the claim is confirmed; the exact command is not.
- **OrbStack-specific behaviour in section 3.** The silent host-process
  collision is measured on this machine, which runs OrbStack. The mechanism is
  almost certainly OrbStack's userspace port forwarding rather than a kernel
  bind, so on Docker Desktop or a native Linux daemon the daemon may well
  arbitrate correctly and R2's "the kernel is the single source of truth" may
  hold in full. **I have not tested that, and cafaye is a shipped tool that
  will run on all three.** Treat section 3 as "verified on OrbStack", not as
  "verified everywhere".
- **The 7.4 GiB figure and `identity-worker-identity-06_postgres-data`.** Not
  present on this machine; not re-measured, not re-claimed.
- **Ryuk on this machine.** Never started. Everything in section 4 is read from
  the source at `main`, not observed running.
