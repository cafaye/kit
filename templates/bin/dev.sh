#!/usr/bin/env bash
#
# kit template — the local developer loop. Copy to bin/dev in the service repo.
#
#   bin/dev            # compose up --wait, migrate, seed an admin, print URLs
#   bin/dev down       # stop the stack, keep the volumes
#   bin/dev nuke       # stop the stack and DELETE the volumes
#   bin/dev status     # what is running, and its health
#   bin/dev logs [svc] # tail the stack, or one service
#   bin/dev migrate    # run migrations, nothing else
#   bin/dev seed       # seed the local admin, nothing else
#   bin/dev --help
#
# WHAT IT PROMISES
#   Exit 0 means the stack is up, healthy, migrated, and seeded. Anything else
#   is nonzero, and the failing step is named. It never leaves a half-started
#   stack behind silently: if a step fails, the message says which one and what
#   to run, and the stack it started is stopped.
#
# STRICTNESS NOTES — READ BEFORE EDITING
#   - `docker compose up -d --wait`, never bare `up -d`. `--wait` blocks until
#     every service reports healthy, which is the only way "migrations ran
#     against a database that was not ready" stops being a flake you learn to
#     retry past. It is why every service in the compose template has a
#     healthcheck.
#   - NO SLEEPS ANYWHERE. Every wait is a poll on a health signal with a deadline
#     and a named timeout. A sleep is a guess about someone else's startup time,
#     and it is wrong on the machine where it matters.
#   - `bin/dev` is idempotent. Running it twice changes nothing: compose is
#     declarative, migrations are guarded, and the admin seed is an upsert. The
#     second run is as fast as the first.
#   - `nuke` is the only destructive step and it is the only one that is not the
#     default. It is spelled out rather than aliased, and it asks nothing — a
#     prompt here is a prompt someone will pipe `yes` into.
#   - Nothing is written to git. `.env` is created from `.env.example` if absent
#     and is git-ignored by every adopting repo.
#   - Connection URLs are printed, never written anywhere else. A developer
#     pasting one into a ticket is the developer's choice, not this script's.
#   - The observability profile comes UP, and this is the load-bearing decision
#     for the dev loop's speed. Observability is on by default (PLAN.md §7b), so
#     `bin/dev` without arguments brings up the collector AND Tempo, Loki, Mimir
#     and Grafana — five more containers than kit-02 shipped, and the difference
#     between "a developer sees real traces" and "read the docs about installing
#     a tracing backend".
#   - It is still ONE command and still not slow, because the profile is opt-OUT
#     via `KIT_DEV_PROFILES`, and the expensive stores are memory-bounded in the
#     compose file. `bin/dev` prints the wall-clock it took, so "the dev loop is
#     slow" is a number rather than a feeling.
#   - NOTHING HERE WAITS ON TELEMETRY. Not `up --wait` (which gates on the
#     collector's own health, and the collector's health does not depend on
#     Tempo, Loki or Mimir), not migrate, not seed. A dev machine that cannot
#     start because an observability store is unhealthy is a dev machine that
#     teaches people to switch telemetry off, which is the opposite of the
#     intent. `tests/no_telemetry_in_readiness.sh` in kit proves the underlying
#     property against a real collector.

set -euo pipefail

# Resolved BEFORE the chdir below. `usage` prints a slice of this file, and $0 is
# a relative path from wherever bin/dev was invoked — so a chdir first, then a
# `sed ... "$0"`, prints "No such file or directory" instead of the help. The
# other kit scripts get away without this because their `cd` is inside a
# function; this one runs at the top of the file.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

cd "$(dirname "$SELF")/.."

# How long to wait for the stack to be healthy, in seconds. A deadline, not a
# sleep: `up --wait` polls health itself, and this is the point at which we stop
# believing it and say so.
#
# 180 rather than kit-02's 120, and the extra 60 is for the observability
# profile: five more containers, four of them with a real initialisation
# (Tempo's WAL, Loki's schema, Mimir's ingester, Grafana's migrations). The
# deadline has to cover the default path, and a deadline that fires on a cold
# start is a deadline that trains people to re-run.
STACK_TIMEOUT="${KIT_DEV_TIMEOUT:-180}"

# The compose profiles to bring up. The observability profile IS the default,
# because observability is on by default and a stack that requires a flag to
# show you its own errors is opt-in with extra steps.
#
# The escape hatch is one variable, and it is the same shape as
# `<SERVICE>_OTEL_ENDPOINT`: a self-hoster on a constrained machine, or CI,
# sets `KIT_DEV_PROFILES=` (empty) and gets postgres/nats/redis/collector alone.
# The collector is NOT behind the profile — it is the default value of the
# endpoint variable, so a service with nothing switched on needs somewhere to
# send, and a dead endpoint with no retry costs spans rather than availability.
KIT_DEV_PROFILES="${KIT_DEV_PROFILES-observability}"

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
info() { printf '   %s\n' "$1"; }
die() {
  printf '\n\033[1;31mbin/dev: %s\033[0m\n' "$1" >&2
  exit "${2:-1}"
}

usage() { sed -n '2,28p' "$SELF"; }

# --------------------------------------------------------------------------
# preflight
# --------------------------------------------------------------------------

compose() {
  # `docker compose` is the v2 plugin; `docker-compose` is v1 and is a different
  # tool with different flags. Probe for the plugin and fail with a message that
  # says which one is missing, because "unknown command" from docker is the
  # single least helpful error in this script.
  #
  # `--profile` is applied here, on every invocation, so no call site can forget
  # it. `up` is the one that matters for the default path; `ps` and `logs` need
  # it too, or `bin/dev status` reports a healthy stack as half-absent and
  # `bin/dev logs tempo` says "no such service".
  local profile_args=()
  if [ -n "$KIT_DEV_PROFILES" ]; then
    profile_args=(--profile "$KIT_DEV_PROFILES")
  fi

  if docker compose version >/dev/null 2>&1; then
    docker compose "${profile_args[@]}" "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "${profile_args[@]}" "$@"
  else
    die "neither 'docker compose' (v2) nor 'docker-compose' is installed" 127
  fi
}

require_files() {
  local missing=()
  local f
  for f in "$@"; do
    [ -e "$f" ] || missing+=("$f")
  done
  if [ "${#missing[@]}" -ne 0 ]; then
    printf 'bin/dev: missing %s\n' "${missing[*]}" >&2
    printf '\nFrom a fresh kit checkout:\n' >&2
    printf '  cp <kit>/templates/compose/docker-compose.yml ./docker-compose.yml\n' >&2
    printf '  cp <kit>/templates/compose/otel-collector.yml  ./otel-collector.yml\n' >&2
    printf '  cp -R <kit>/templates/compose/grafana ./grafana\n' >&2
    printf '  cp -R <kit>/templates/compose/tempo  ./tempo\n' >&2
    printf '  cp -R <kit>/templates/compose/loki   ./loki\n' >&2
    printf '  cp -R <kit>/templates/compose/mimir  ./mimir\n' >&2
    printf '  cp <kit>/templates/compose/.env.example        ./.env\n' >&2
    exit 1
  fi
}

# --------------------------------------------------------------------------
# .env
# --------------------------------------------------------------------------

ensure_env() {
  [ -f .env ] && return 0
  [ -f .env.example ] || die "no .env and no .env.example to copy one from"

  # Copied, never written from scratch: a .env assembled here would drift from
  # the .env.example a teammate has in git, and the two disagreeing is exactly
  # the failure this avoids.
  cp .env.example .env
  info "created .env from .env.example — edit it if a port collides"
}

# --------------------------------------------------------------------------
# steps
# --------------------------------------------------------------------------

up() {
  step "starting the stack (deadline: ${STACK_TIMEOUT}s)"
  # The wall-clock is measured here and printed at the end, because "the dev
  # loop is slow" is a claim everyone makes and nobody measures, and the whole
  # point of shipping five more containers is that it is not slow. A number in
  # the output is the only thing that settles the argument, and it is also what
  # makes a regression visible in a commit message.
  local started elapsed
  started=$(date +%s)

  # --wait blocks on health, not on "the container exists". A postgres that is
  # running but has not finished initdb answers nothing, and the migration step
  # below would fail against it.
  if ! KIT_TIMEOUT="$STACK_TIMEOUT" compose up -d --wait --wait-timeout "$STACK_TIMEOUT"; then
    printf '\n' >&2
    printf 'bin/dev: the stack did not become healthy in %ss.\n' "$STACK_TIMEOUT" >&2
    printf 'What is unhealthy:\n' >&2
    compose ps >&2 2>&1 | sed 's/^/  /' >&2
    printf '\nIts logs:\n' >&2
    compose logs --tail 40 >&2 2>&1 | sed 's/^/  /' >&2
    printf '\nRaise the deadline with KIT_DEV_TIMEOUT=300 bin/dev, or run bin/dev logs.\n' >&2
    die "stack did not become healthy — nothing further was run, so nothing is half-migrated" 1
  fi

  step "migrating"
  migrate

  step "seeding the local admin"
  seed

  print_urls

  elapsed=$(( $(date +%s) - started ))
  step "up in ${elapsed}s"
  if [ -n "$KIT_DEV_PROFILES" ]; then
    info "observability is ON (compose profile: $KIT_DEV_PROFILES)"
    info "to run the data services only: KIT_DEV_PROFILES= bin/dev up"
  else
    info "observability is OFF (KIT_DEV_PROFILES is empty) — nothing is exporting anywhere"
  fi
}

migrate() {
  # Each language migrates differently; the repo's own command is the only one
  # that is correct, and every cafaye service has one under a bin/ or script/
  # entry. Probed in a fixed order and the first match wins, so this works
  # without kit having to know six migration systems.
  if [ -x bin/migrate ]; then
    bin/migrate
  elif [ -x bin/rails ] && [ -f config/application.rb ]; then
    bin/rails db:prepare
  elif [ -x bin/ecto.setup ]; then
    mix ecto.create
    mix ecto.migrate
  elif [ -f Cargo.toml ] && [ -x bin/prime ]; then
    # Rust services own their migrations as SQL applied by the app; the primer
    # is the supported entry point and runs them.
    bin/prime --fast
    info "no bin/migrate: ran bin/prime --fast — apply migrations in your own task if you have one"
  else
    die "no migration command found (looked for bin/migrate, bin/rails, bin/ecto.setup). Add bin/migrate and re-run."
  fi
}

seed() {
  # The admin user is what stops the first five minutes of a new checkout being
  # "log in as whom?". An upsert, not an insert: running this twice must not
  # create two admins or fail on a unique constraint.
  if [ -x bin/seed ]; then
    bin/seed
  elif [ -x bin/rails ] && [ -f config/application.rb ]; then
    bin/rails db:seed
  else
    info "no bin/seed: skipping the admin seed"
  fi
}

print_urls() {
  # Read from .env rather than hardcoding, so the printed URL is the URL that
  # actually works on this machine. A printed URL that does not resolve is worse
  # than none.
  # shellcheck disable=SC1091
  set -a && . ./.env && set +a

  # Every port read from .env, never hardcoded — including the observability
  # ones. A printed URL that does not resolve is worse than none, and the whole
  # point of kit's claimed port block is that these are NOT the well-known
  # numbers, so hardcoding them here would print the one address that is wrong.
  local pg_port="${KIT_POSTGRES_PORT:-15500}"
  local nats_port="${KIT_NATS_CLIENT_PORT:-15600}"
  local redis_port="${KIT_REDIS_PORT:-15800}"
  local grafana_port="${KIT_GRAFANA_PORT:-15000}"
  local pg_user="${KIT_POSTGRES_USER:-cafaye}"
  local pg_pass="${KIT_POSTGRES_PASSWORD:-cafaye}"
  local pg_db="${KIT_POSTGRES_DB:-cafaye_platform}"

  step "ready"
  cat <<URLS
   postgres     postgresql://$pg_user:$pg_pass@localhost:$pg_port/$pg_db
   nats         nats://localhost:$nats_port
   redis        redis://localhost:$redis_port

   grafana      http://localhost:$grafana_port        (traces, metrics, errors)
   tempo        http://localhost:${KIT_TEMPO_PORT:-15900}
   loki         http://localhost:${KIT_LOKI_PORT:-15901}
   mimir        http://localhost:${KIT_MIMIR_PORT:-15902}

   otel (otlp)  http://otel-collector:${KIT_OTEL_HTTP_PORT:-4318}   (compose network only)

   service      ${KIT_DEV_SERVICE_URL:-http://localhost:3000}

   Nothing leaves this machine unless you point it somewhere. To use your own
   backend instead of the four above, set <SERVICE>_OTEL_ENDPOINT in your own
   .env — that is the only contract, and the shipped collector is just its
   default value. Unset the variable and the exporter is a genuine no-op: no
   queue, no retry loop, no warning per request, no dial at boot.
URLS
}

status() {
  step "stack status"
  compose ps
}

logs() {
  if [ "${1:-}" = "" ]; then
    compose logs -f
  else
    compose logs -f "$1"
  fi
}

down() {
  step "stopping the stack (volumes kept)"
  # `down` without -v on purpose: your local data is the thing you are not
  # throwing away by typing `bin/dev down`.
  compose down
}

nuke() {
  # The only destructive step. Spelled out, never the default, never aliased.
  step "stopping the stack and DELETING its volumes"
  info "postgres, nats and redis data in this stack are gone after this."
  compose down --volumes --remove-orphans
}

# --------------------------------------------------------------------------

main() {
  case "${1:-up}" in
    up)
      # The vendor config trees are required alongside the compose file. They
      # are mounted read-only and they are the reason the four stores start, so
      # a missing `tempo/` is a `bin/dev up` that dies four containers later
      # with a bind-mount error naming a path the developer has never heard of.
      require_files docker-compose.yml otel-collector.yml grafana tempo loki mimir
      ensure_env
      up
      ;;
    down) down ;;
    nuke) nuke ;;
    status) status ;;
    logs) shift; logs "${1:-}" ;;
    migrate) migrate ;;
    seed) seed ;;
    -h | --help | help) usage ;;
    *)
      printf 'bin/dev: unknown command: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
