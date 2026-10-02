# HANDOFF — kit-dev-profile-01

Worktree `cafaye/wt-m39-kit-dev-profile-01`, branch `worker/kit-dev-profile-01`.
Read `moon/logs/briefs/_WORKING_RULES.txt` first: non-interactive, commit to
this branch only, push is not yours.

The one-line state: **the static gate is green, the docs tell the truth, and the
cheap stack comes up in 6 seconds.** One measured defect remains and it is the
successor's first move.

---

## Done and verified

**Gate.** `bash tests/validate.sh --static-only` → `EXIT=0`,
`PASS: every check passed`, `note: 5 check(s) skipped`. The eight checks the
previous session's removal broke are fixed in `8af7764`, and three of them are
STRONGER than they were rather than merely retargeted:

- the metrics pipeline must export to `debug` **and to nothing else**;
- Grafana must provision **no** metrics datasource;
- nothing under `templates/compose/` may be **unreferenced** — the check that
  would have caught the leftover `mimir.yaml` on its own.

The escape-hatch check (`templates/bin/dev.sh  (KIT_DEV_PROFILES= escape hatch
actually runs)`) is PASS and its fixture is now stronger: its stub kit tree
carries no metrics-store directory, so it actually proves the check and the
default agree rather than passing for the reason the old default passed.

**The thing the packet is for, measured.** A throwaway service repository with
`bin/dev`, `kit.ref` = `8af7764`, and `KIT_STACK_DIR` pointed at this checkout:

| | command | result |
|---|---|---|
| cheap default | `KIT_DEV_PROFILES= timeout 120 bash bin/dev up` | **exit 0 in 6s** — postgres, nats, redis, otel-collector healthy |
| teardown | `timeout 300 bash bin/dev down` | **exit 0**, 0 containers left, 6 volumes kept |
| explicit | `KIT_DEV_PROFILES=observability timeout 240 bash bin/dev up` | **exit 0 in 21s**, all 8 containers healthy |

21s against 6s, and that is the *conservative* comparison: the second run had
the postgres image built and every volume warm, which flatters the slow path.
On the cold numbers the branch cites (tempo 65s, loki 16s, grafana up to 180s of
readiness budget, plus the 130s the metrics store used to add) the gap is an
order of magnitude, not a factor of three.

`print_urls` is correct on both paths: the cheap run prints **no** tempo/loki/
grafana URL and names the profile that gets them, which is the "a printed URL
that does not resolve is worse than none" rule holding.

`otelcol validate` against the live mounted config: **exit 0**. The metrics
pipeline with `exporters: [debug]` and no store builds.

### Fixed here, and it was a real leak

`bin/dev down` on the **cheap** path exited 0, printed "stopping the stack", and
left tempo, loki and grafana running and healthy — because the backends are
behind a compose profile and `docker compose down` without that profile does not
touch them. Fixed in `1a2b…` (see the report for the sha): `down` and `nuke` now
read the project's own profile list from `compose config --profiles` and pass
every one, so the teardown covers the whole project whichever variable this
shell happens to have. Re-measured: after the full stack is up, `bin/dev down`
with `KIT_DEV_PROFILES` unset leaves **0 containers and 6 volumes**.

That is the mirror of the `print_urls` defect the previous session found, and
only running the thing found it — which is the argument for the successor doing
the same to the item below.

---

## Half-done, and why — **this is the successor's first move**

### On the cheap path the collector still dials `tempo:4317` and `loki:3100`, forever.

Measured, not reasoned. `docker compose logs otel-collector` on the 6-second
cheap stack:

```
warn grpc@v1.68.0/clientconn.go:1384  [Channel #1 SubChannel #2]grpc:
  addrConn.createTransport failed to connect to {Addr: "tempo:4317",
  ServerName: "tempo:4317"}. Err: connection error: desc = "transport: Error
  while dialing: dial tcp: lookup tempo on 127.0.0.11:53: no such host"
```

repeating at 0.1s, 1s, 2s, 4s, 8s, 20s, 29s, 89s … for the life of the
process. There is no `tempo` container on the cheap path.

**Why this is the same defect the branch already fixed, stated in three places
already in the tree.** `docker-compose.yml` says of the metrics store:
"no collector exporter still dialling a host with nothing behind it… An exporter
pointed at a host with nothing behind it is a connection refused per flush,
forever, in a log nobody reads." `otel-collector.yml` says the same about the
metrics exporter. `templates/otel-collector.yml`'s fan-out to Tempo and Loki now
has exactly that shape on the default path, and the compose header's own sentence
— "the collector is still NOT behind the profile: on the cheap path telemetry
still arrives… and is then dropped because there is no store to hand it to" —
describes the *intent* while the dial loop contradicts it.

**Why I did not fix it.** Every available fix is an architecture change, not a
one-line correction, and I had roughly twenty minutes:

- `profiles:` cannot help — the collector is deliberately NOT in the
  `observability` profile, because it is the default value of
  `<SERVICE>_OTEL_ENDPOINT` and putting it behind a profile would leave a
  service with nothing configured holding a dead endpoint. `backing_check` and
  `dev_escape_hatch_check` both assert that.
- The collector config is a static bind-mounted file; it cannot read compose
  profiles. Making the endpoints conditional needs one of: a per-profile
  collector config (two files, and the gate's "every vendor config is mounted"
  list grows), or a `${env:}` endpoint that resolves to a discard address on the
  cheap path and to the store on the full one, set from `.env` — which turns
  `KIT_DEV_PROFILES` into a second reader of a fact `stack_setting` already owns
  and cannot express "unset" for.
- Shipping an untested guess at any of those is worse than shipping the
  measurement.

**What I would do, in order.** Write the decision down first (a `DECISIONS.md`
entry or a compose-header note) and pick one:

1. **Accept it and say so.** The cheapest honest answer: the dial is the visible
   cost of keeping the collector outside the profile, it backs off
   exponentially, `retry_on_failure` and `sending_queue` are already off, and
   `up --wait` is unaffected. Record it in `docker-compose.yml` next to the
   sentence it contradicts, and add a check that asserts the WARN is present on
   the cheap path and ABSENT on the full one — a check that can fail is better
   than a comment nobody re-reads.
2. **Ship a second collector config for the cheap path**, mounted by
   `bin/dev` rather than by compose, so the cheap run has `exporters: [debug]`
   on all three signals and dials nothing. Costs a file in
   `VENDOR_MOUNTS` and a `stack_is_usable` entry.
3. **Filter the destination**, which the collector already supports and which
   this config does not use: a `filter` processor dropping all signals when the
   stores are absent. Cheapest in files, and it keeps one config — but it is a
   real behaviour change and wants its own commit and its own gate entry.

Whichever is chosen, `tests/stack_live_test.sh`'s new collector-log assertions
are the natural place to prove it.

---

## Deliberately not done

- **The full gate was not run.** `self_test` is *n* whole gates in sequence and
  `AGENTS.md` records it hitting a 90-minute bound on a busy box; the docker
  tiers are ~107s. The hour did not contain either, and a `BOUND` self_test is a
  gate to run **by hand**, not to report. What was run: `--static-only`, plus
  `bin/dev up`/`down` by hand. The docker-tier proofs named in `AGENTS.md`'s
  observability phase — `stack_live_test.sh`,
  `no_telemetry_in_readiness.sh`, `isolation_test.sh`, `tenancy_test.sh` — were
  **not executed**, and `tests/stack_live_test.sh` in particular was rewritten
  without being run. That is the largest untested surface this branch carries.
- **`tests/self_test.sh` was not run** (see above), and no recipe was edited.
  Its labels were checked by grep first: no recipe asserts any of the three
  labels this branch renames (`four AGPL backends`, `3 datasources`, and none
  else), so no breakage was silently un-proofed.
- **The adoption-ceiling prose in `README.md` still says "twelve files" in the
  compose directory and "0 of 12".** That was already wrong before this packet
  (the bundle holds 14 members, now 13) and the whole paragraph is a
  measurement of the fleet taken at a point in time. It was not touched here
  because re-measuring it is a different packet and a wrong number in a
  different paragraph would be a worse outcome than a stale one in a dated one.
- **No push, no merge to master, no tag.** This branch is the deliverable.