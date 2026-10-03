#!/bin/sh
#
# kit template — the service entrypoint. Copy to docker/entrypoint.sh in the
# service repo, or leave it in `docker/` and COPY it from there.
#
#   cp <kit>/docker/entrypoint.sh docker/entrypoint.sh
#
# THE CONTRACT, IN ORDER. Nothing runs before the thing it depends on.
#
#   1. Resolve the migration command, or prove there is none to run.
#   2. Prove DATABASE_URL is set.
#   3. Run the migration. Take an advisory lock first, if one was asked for.
#   4. `exec "$@"` — the real service, as PID 1.
#
# WHY THIS EXISTS. Every one of kit's seven image templates shipped a bare
# `ENTRYPOINT ["/app/service"]`. The schema a service booted against was
# therefore whatever the last deploy — or the last developer — left behind, and
# a second replica booting beside the first met the classic cold-start failure:
# the service is up, the schema is not. Both references that get this right do
# it in exactly this shape, migration first and serve last, chained so a failure
# refuses the start:
#
#   - refs/signoz/.devenv/docker/signoz-otel-collector/compose.yaml:7-12 —
#     the container's command IS `migrate sync check && otelcol --config=…`.
#   - refs/bugsink/Dockerfile:54 — `manage check && manage migrate && … &&
#     gunicorn`.
#
# So THE DEPLOY STORY CHANGED, and this is the feature rather than a
# regression: **a failed migration now means a failed container.** A rolling
# deploy of N replicas applies the schema N times at boot (see CONCURRENCY) and
# a service whose migration fails now crash-loops instead of serving 500s
# against a schema it does not understand. That is the whole point: it deletes
# the "service is healthy, database is wrong" class. It also means the image
# cannot be started for any purpose that does not want the schema touched
# (`docker run … --help`, a one-off shell) without `KIT_MIGRATE=off`.
#
# WHY ONE SCRIPT AND NOT SEVEN. The migrate step is per-language; the shape
# around it is not. Seven hand-written wrappers is seven chances to reorder
# check and migrate, or to `exec` before migrating, and the difference between
# two of them is invisible until one of them boots against a stale schema. So
# the shape lives here once and each Dockerfile names this file.
#
# THE MIGRATE COMMAND, in resolution order:
#
#   1. `KIT_MIGRATE_CMD` — an explicit command string, run through the shell.
#      This is the escape hatch and, for Go, Rust and Elixir, the normal path.
#   2. `./bin/migrate` — the fleet's own migration entrypoint, if it is in the
#      image and executable. Every repo that has one is picked up with no
#      Dockerfile edit at all.
#   3. `./bin/rails db:prepare` — if `./bin/rails` and `./config/application.rb`
#      are both there. Rails services do not need `bin/migrate` to migrate.
#
# This is deliberately the same probe `templates/bin/dev.sh` performs, in the
# same order, minus the `mix ecto.create && mix ecto.migrate` branch: that pair
# is a *developer* sequence against a database it may have to create, and an
# image should not create a database at boot. An Elixir service sets
# `KIT_MIGRATE_CMD` to its release's migrator instead. Two lists would drift;
# one list, quoted in both places, does not.
#
# `KIT_MIGRATE` is what happens when there is no command to run:
#
#   auto     (default) log one line and serve. Correct for a service with no
#            database — a gateway, a webhook sink — which is a real member of
#            this fleet and must not be made unbootable by a migration step it
#            does not have.
#   required no command is a hard failure, before the service starts. Use it
#            for a service that owns a schema: the boot fails loudly on a
#            misconfigured image instead of silently serving an old one.
#   off      skip, and say so. For `docker run … --help`, and for a service that
#            migrates out of band (a job, an accessory) and wants its distroless
#            `static` base back.
#
# CONCURRENCY — WHAT THIS ACTUALLY GUARANTEES, AND WHAT IT DOES NOT.
#
# Every replica runs the migration at boot. **This script does not serialize
# them by default**, and it does not pretend to. Safety is delegated to the
# migrate command, and the delegation is stated rather than assumed:
#
#   - `bin/migrate` (the fleet's bash+psql path, e.g. identity): **no lock at
#     all.** No version table, no advisory lock, no transaction around the set —
#     a `for` loop of `psql` calls. Its own header names idempotent replay as
#     the safety property, because goose's `goose_db_version` table is what makes
#     re-running a file harmless on the developer's machine; in an image with no
#     goose, N replicas apply all N files concurrently and rely on the Up
#     sections being written re-runnable (`CREATE TABLE IF NOT EXISTS`, a
#     guarded `DO` block). That is a property of the migration files, not a
#     lock, and it is why the template's answer below exists.
#   - `db:prepare` (Rails), `goose up`, `mix ecto.migrate`, `alembic upgrade
#     head`: each keeps a version table, so concurrent runs converge on one
#     schema instead of duplicating work. Whether they *serialize* is a
#     property of each tool and is **not** verified by this file — do not assume
#     it from here. Read the tool's own docs for the version you deploy.
#
# `KIT_MIGRATE_ADVISORY_LOCK=<int>` is the answer for the case above: it holds a
# PostgreSQL session-level advisory lock around the migrate command, so exactly
# one replica migrates and the rest wait and then find the work done. Two
# properties make it worth having, and one makes it opt-in:
#
#   - A **session**-level lock is the correct primitive, not a transaction-level
#     one. A migration is not one transaction (each file is, and there are many),
#     and `pg_advisory_xact_lock` is released at the end of the transaction that
#     took it. The session form is released when the session ends, which is what
#     makes it safe if the migrating replica is killed mid-migration. Evidence:
#     refs/supabase-postgres/apps/docs/content/guides/database/connection-
#     management.mdx:122 — "Postgres releases the transaction's ordinary locks as
#     part of the abort — the exception is session-level advisory locks
#     (`pg_advisory_lock`, not `pg_advisory_xact_lock`), which are held until
#     explicitly unlocked or the session ends."
#   - The lock is HELD ACROSS the migrate command by a dedicated `psql` session
#     driven over a FIFO, and the migrate command's exit status is the shell's
#     own. It is deliberately NOT `psql -c "\! <cmd>"`: that was measured on
#     PostgreSQL 17 and psql does **not** propagate the `\!` command's exit
#     status, so a failed migration exits 0 and this script would then serve
#     against exactly the schema it just failed to apply. A lock wrapper that
#     swallows the failure is worse than no lock at all.
#   - It is OPT-IN because it needs `psql`, which `distroless/static` does not
#     have and `distroless/base` does not have either. A service that asks for
#     the lock in an image with no `psql` **fails to start**, loudly, rather than
#     quietly migrating unserialized.
#
# Choose a key nothing else uses: the fleet convention is the service name
# hashed into the 63-bit signed space Postgres allows. `identity` -> 1372041396
# is an example; a collision only over-serializes, which is safe, and reusing
# one service's key for another's schema would serialize unrelated work, which
# is merely slow. So a per-service constant is enough and a hash is nicer.
#
# WHY `exec`, AND WHAT IT COSTS. The last line is `exec "$@"`, so after the
# migration the service *replaces* the shell and is PID 1. The templates' notes
# say "a shell wrapper would swallow" SIGTERM, and that is still true of a
# wrapper that does not exec. The cost of this one is that PID 1 is a shell for
# the duration of the migration only: no orphaned children to reap before the
# exec, and after the exec there is no shell left to swallow anything.
# WHY `set -eu` AND NOT `set -euo pipefail`. kit's style rule says `pipefail` in
# every shell script, and this one is the exception it has to be. This file runs
# as `/bin/sh` inside a `python:*-slim`, an `oven/bun:*-slim`, a `debian:*-slim`
# and a `distroless`-alike — dash on Debian, ash on Alpine-derived bases — and
# `set -o pipefail` is a bash/ksh addition that those shells reject, so the
# script would die on line one in every image it exists to serve. The cost is
# real and small: there is no pipeline on any load-bearing path. The one place
# output is examined, the lock acknowledgement, is `grep -q` reading a FILE and
# not a pipe — which is the distinction kit's own rule draws, since the broken
# shape there is `printf … | grep -q` and the working shape is a search over
# something already on disk.
set -eu

log() { printf 'kit-entrypoint: %s\n' "$*" >&2; }
die() {
  printf 'kit-entrypoint: %s\n' "$*" >&2
  exit 1
}

# No arguments at all is a misconfiguration, not a request to do nothing:
# `ENTRYPOINT ["…/entrypoint.sh"]` with the service command left off means the
# container would exec `""`, and a container that starts and immediately exits 0
# looks healthy to a `--wait` and a restart policy.
[ "$#" -gt 0 ] || die "no command given — ENTRYPOINT must end with the service command, e.g. [\"/app/kit-entrypoint\", \"/app/service\"]"

mode="${KIT_MIGRATE:-auto}"
case "$mode" in
  auto | required | off) ;;
  *) die "KIT_MIGRATE='$mode' is not one of auto, required, off" ;;
esac

# --- 1. resolve ---------------------------------------------------------------

resolve_migrate() {
  if [ -n "${KIT_MIGRATE_CMD:-}" ]; then
    printf '%s' "$KIT_MIGRATE_CMD"
    return 0
  fi
  if [ -x ./bin/migrate ]; then
    printf '%s' "./bin/migrate"
    return 0
  fi
  if [ -x ./bin/rails ] && [ -f ./config/application.rb ]; then
    printf '%s' "./bin/rails db:prepare"
    return 0
  fi
  return 1
}

# --- 2. hold the advisory lock (opt-in) ---------------------------------------
#
# Prints nothing and returns 0. Sets KIT_ENTRYPOINT_LOCK_FIFO when it ran, so
# the caller can close the session afterwards. If it cannot hold the lock it
# dies: a lock that was asked for and not taken is a guarantee that was not
# given, and the honest response is to refuse to serve.
lock_acquire() {
  key="$1"
  command -v psql >/dev/null 2>&1 || die \
    "KIT_MIGRATE_ADVISORY_LOCK=$key was requested but there is no psql in this image, so the lock cannot be taken. Either install psql, or unset the variable and accept that every replica migrates concurrently."

  # `XXXXXX` at the END of both templates, and that is not cosmetic: BSD mktemp
  # (macOS) and busybox mktemp both replace only a trailing run of X's, so
  # `…lock.XXXXXX.log` fails outright on a developer machine. Measured, on this
  # one: `mktemp: mkstemp failed on …: File exists`.
  tmpdir="${TMPDIR:-/tmp}"
  fifo="$(mktemp -u "$tmpdir/kit-entrypoint-lock.XXXXXX")"
  mkfifo "$fifo" || die "could not create the lock FIFO at $fifo"
  locklog="$(mktemp "$tmpdir/kit-entrypoint-lock-log.XXXXXX")"

  # ON_ERROR_STOP=1 so a failed `pg_advisory_lock` is a non-zero exit and the
  # wait below times out rather than proceeding unlocked.
  psql "$DATABASE_URL" -q -A -t -v ON_ERROR_STOP=1 \
    -f "$fifo" >"$locklog" 2>&1 &
  lock_pid=$!
  # The backgrounded psql blocks on open() of the FIFO until a writer appears;
  # exec 3> is that writer, and it is deliberately before any `printf`, or the
  # two deadlock against each other.
  exec 3>"$fifo"
  {
    printf "SELECT pg_advisory_lock(%s);\n" "$key"
    printf "SELECT 'kit-entrypoint:lock-held';\n"
  } >&3

  # Wait for the acknowledgement rather than sleeping: a fixed sleep is a race
  # that passes on a fast machine and hands two replicas the same key on a slow
  # one, which is the failure this whole block exists to prevent. 30 × 0.2s.
  held=0
  i=0
  while [ "$i" -lt 150 ]; do
    if grep -q 'kit-entrypoint:lock-held' "$locklog" 2>/dev/null; then
      held=1
      break
    fi
    kill -0 "$lock_pid" 2>/dev/null || break
    sleep 0.2
  done

  if [ "$held" -ne 1 ]; then
    exec 3>&- 2>/dev/null || true
    printf 'kit-entrypoint: could not take advisory lock %s:\n' "$key" >&2
    sed 's/^/kit-entrypoint:   /' "$locklog" >&2 2>/dev/null || true
    die "refusing to start: the migration lock this image is configured for was not granted."
  fi
  KIT_ENTRYPOINT_LOCK_FIFO="$fifo"
  log "holding postgres advisory lock $key (session-scoped; released when this replica exits or dies)"
}

lock_release() {
  [ -n "${KIT_ENTRYPOINT_LOCK_FIFO:-}" ] || return 0
  # Closing the session is the release. `pg_advisory_unlock` is not sent
  # deliberately: if the migrate command killed this replica, there is no shell
  # left to run it, and the session's own death is the backstop Postgres
  # provides (see the session-level note above).
  exec 3>&- 2>/dev/null || true
  wait "${KIT_ENTRYPOINT_LOCK_PID:-0}" 2>/dev/null || true
  rm -f "$KIT_ENTRYPOINT_LOCK_FIFO"
}

# --- 3. migrate ---------------------------------------------------------------

migrate() {
  if ! command=$(resolve_migrate); then
    case "$mode" in
      off) log "KIT_MIGRATE=off — not migrating; the schema is whatever is already there."; return 0 ;;
      required) die \
        "KIT_MIGRATE=required and no migration command was found (looked for KIT_MIGRATE_CMD, ./bin/migrate, ./bin/rails db:prepare). Set one of them, or set KIT_MIGRATE=auto if this service genuinely owns no schema." ;;
      *) log "no migration command found (looked for KIT_MIGRATE_CMD, ./bin/migrate, ./bin/rails) — serving. Set KIT_MIGRATE=required for a service that owns a schema."; return 0 ;;
    esac
  fi

  [ -n "${DATABASE_URL:-}" ] || die \
    "DATABASE_URL is not set, so there is nothing to migrate against. The service would boot against whatever the pool defaults to, which is the failure this script exists to remove."

  if [ -n "${KIT_MIGRATE_ADVISORY_LOCK:-}" ]; then
    lock_acquire "$KIT_MIGRATE_ADVISORY_LOCK"
    KIT_ENTRYPOINT_LOCK_PID="$lock_pid"
  else
    log "no KIT_MIGRATE_ADVISORY_LOCK set — every replica runs this migration at boot. Safety is the migrate command's own idempotency. Set KIT_MIGRATE_ADVISORY_LOCK if that is not enough."
  fi

  log "migrating: $command"
  # `set -e` makes a non-zero status abort here, which is the feature: the
  # service never starts. No `|| true` anywhere on this path.
  if [ -n "${KIT_ENTRYPOINT_LOCK_FIFO:-}" ]; then
    # Inside the lock, the command's own exit status is what decides. psql is
    # NOT in this pipeline: it holds the lock on fd 3 and has nothing to say
    # about whether the migration worked.
    if ! sh -c "$command"; then
      lock_release
      die "migration failed: $command — the container will not start. This is deliberate; see the header of this file."
    fi
  else
    sh -c "$command" || die \
      "migration failed: $command — the container will not start. This is deliberate; see the header of this file."
  fi
  lock_release
  log "migrations applied"
}

if [ "$mode" = "off" ]; then
  log "KIT_MIGRATE=off — starting $1 without touching the schema."
else
  migrate
fi

# --- 3b. name the artifact ---------------------------------------------------
#
# ONE line, before the service takes over, and it is the difference between an
# image that carries provenance and one that merely has it.
#
# The image labels are in the image CONFIG, which a running process cannot reach
# — there is no docker socket and no CLI in here — so without this the thing
# running could not say what it was built from, and "stamp the artifact so the
# thing running can name what it was built from" would have been half true. The
# file sink exists for exactly this line, and this line is why it is not
# decorative.
#
# It is one `sed`, not a parse, and a stamp that cannot be read does NOT stop a
# service booting: an unreadable stamp is a fact about the image, while a refusal
# to start is a fact about the deploy, and an image must be able to boot far
# enough to be diagnosed. `docker/provenance.sh --verify` is where an unreadable
# stamp IS a failure — that is a consumer ASSERTING about an artifact, which is a
# different act from an artifact booting.
if [ -r /app/kit-provenance.json ]; then
  kit_provenance="$(sed -n 's/.*"revision": "\([^"]*\)".*/\1/p' /app/kit-provenance.json 2>/dev/null || true)"
  log "built from ${kit_provenance:-an unstamped revision} — full stamp in /app/kit-provenance.json"
fi

# --- 4. serve -----------------------------------------------------------------
exec "$@"
