# HANDOFF — kit-migrate-entrypoint-01

Branch `worker/kit-migrate-entrypoint-01`, worktree
`moon/cafaye/wt-m39-kit-migrate-entrypoint-01`. Three commits, nothing pushed.

## Done and verified

- `docker/entrypoint.sh` — POSIX sh, one shared entrypoint. Contract: resolve
  the migration command → prove `DATABASE_URL` → migrate → `exec "$@"`.
  Resolution order is `KIT_MIGRATE_CMD`, `./bin/migrate`, `./bin/rails db:prepare`
  — the same probe `templates/bin/dev.sh` performs, minus the mix developer step.
- All seven `docker/Dockerfile.*` wired: `ENTRYPOINT ["/bin/sh", "/app/kit-entrypoint", <original command…>]`.
- `KIT_MIGRATE=auto|required|off`, `KIT_MIGRATE_CMD`,
  `KIT_MIGRATE_ADVISORY_LOCK=<int>` (Postgres **session**-level `pg_advisory_lock`).
- Gate: `--static-only` → `PASS: every check passed.` (exit 0), including three
  new lines (`bash -n`, `shellcheck`, `executable`) and a new
  `docker/Dockerfile.* (ENTRYPOINT migrates, then execs the service)`.
- Concurrency measured against a real `postgres:17`, not asserted. Two replicas
  with the lock do not overlap; the same two without it do; a failing migration
  releases the lock; a `SIGKILL`ed replica releases it. The concurrency table and
  the `psql "\!"`-does-not-propagate finding are in
  `moon/logs/REPORT-kit-migrate-entrypoint-01.md` §2.
- Behaviour verified in a **real built image** (`kit-probe-go`): failing
  migration → exit 1 and the service never runs; `/proc/1/cmdline` is the
  service and `MY_PID=1 uid=65532`; `SIGTERM` reaches it.

## Half-done and why

- **`go` and `rust` left distroless for `debian:*-slim`.** Measured: *neither*
  distroless variant ships a shell (`bin/` is empty in `static` and in `base`), and
  a shell entrypoint needs one. Non-root is preserved as numeric `65532:65532`.
  The long-term fix is a compiled static supervisor binary, which is a program
  rather than a template — not this hour's work.
- **`docker/entrypoint.sh` is NOT in `tests/artifacts.json`.** Declaring it makes
  the staleness reporter grade nine services and open nine `absent` findings
  needing `templates/parity-allowlist` entries with reason/owner/since/until.
  Blast radius past an hour; the honest form of that change is its own packet.
- **No service repo adopted it.** Out of scope by instruction.
- **Tool-level migration locking (goose / Ecto / Rails / alembic) is not
  verified.** The network was unavailable. The files state the version-table
  property and explicitly decline to assert serialization.

## Currently-failing command, with real output

None. The one red seen during this hour was self-inflicted and is not a tree
defect:

```
tests/validate.sh: line 9950: proofs: command not found
EXIT=127
```

That is `bash` reading `tests/validate.sh` **incrementally** while I was editing
it — the file shifted under a running script and bash resumed mid-line. It is not
reproducible on a static tree. **Do not edit `tests/validate.sh` while the gate
is running**, which is why the tree was frozen for the final run.

## Successor's first move

1. **Read the final full-gate run** —
   `moon/../cafaye/wt-m39-kit-migrate-entrypoint-01` was frozen at `8b35088` for
   a full `bash tests/validate.sh`. Its output is at
   `/private/var/folders/3b/kt90wy3d66lftws_dwtxxglm0000gn/T/opencode/gate-full2.txt`
   (a temp path — if it is gone, re-run it). **Read the `EXIT=` line, not the
   `FAIL` count.** `self_test` runs 94 whole gates and reports `BOUND` on a busy
   box; `BOUND` is not a pass. If it bounded, take the unreached recipes by hand
   per `AGENTS.md`.
2. Then, in this order: declare `docker/entrypoint.sh` in `tests/artifacts.json`
   and open the matching `templates/parity-allowlist` entries; add a
   `self_test` breakage for `docker_entrypoint` (it has three hand-run controls
   today, none in the suite); and pick the first adopter — `identity` is the
   natural one, but its image ships only the compiled binary, so it needs a static
   migrate binary built in the builder before `KIT_MIGRATE_CMD` points at
   anything.
