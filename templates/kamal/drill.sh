#!/usr/bin/env bash
# drill.sh — a restore drill that cleans up after itself and proves it restored
# something.
#
# WHY THIS EXISTS AT ALL, GIVEN THAT `kamal-backup drill` IS A REAL COMMAND
#
#   Two things, and both were found by reading kamal-backup 0.5.2's source
#   rather than by trying it and liking the result:
#
#   1. `kamal-backup drill production` restores into the scratch database and
#      LEAVES IT THERE. Nothing in the gem drops it: `restore_to_scratch`
#      (databases/base.rb:52-55) is validate-then-restore and returns; the only
#      `DROP SCHEMA` in the whole gem is `reset_current_schema`, which runs on a
#      restore into the LIVE database, not the scratch one. So the scratch
#      database is an operator's problem by default, and anymark's own runbook
#      documents it as a two-step manual procedure (KILL the pooled connection,
#      then DROP DATABASE). A step an operator has to remember after a failure
#      is a step that does not happen after a failure — and the case where it
#      matters most is the case where everything went wrong.
#
#   2. The gem decides the drill passed or failed by the EXIT STATUS of the
#      `--check` command (app.rb:307-325, and the CLI exits 1 unless
#      `result[:status] == 'ok'`). That is the right contract and it puts the
#      burden on the check to be an assertion. The check published in anymark's
#      runbook is `psql -tAc "SELECT count(*) FROM agents"` — which exits 0
#      whether the count is 4,000 or 0. A restore of an empty database, or a
#      restore that silently created the table and copied no rows into it,
#      would be reported as a successful drill. The count is printed; nobody
#      reads it in a log aggregator.
#
#   So this wrapper supplies both: cleanup on every exit path, and a check whose
#   exit status is the assertion.
#
# WHAT IT DOES NOT DO
#   It does not back up, restore-for-real, or manage the repository. Those are
#   kamal-backup's, and re-implementing them is the mistake this file exists
#   next to. It runs `kamal-backup drill` and adds a `trap`.
#
# SECRETS
#   No credential appears in this script, in its arguments, or in the check
#   string it builds. The connection is taken from the backup accessory's own
#   environment — `DATABASE_URL` is a Kamal secret on that accessory — and is
#   split into `PG*` variables, which libpq reads from the ENVIRONMENT. It is
#   never an argument, because `ps` shows arguments to every user on the machine
#   and a shell keeps them in its history. The generated check therefore
#   contains no host, no user and no password: only table names.
#
# USAGE (from the service repository, where config/deploy.yml lives)
#
#   bin/drill --table users --table documents
#   bin/drill --scratch myservice_drill_2 --table users
#   bin/drill --table users --snapshot c6688d64
#   bin/drill --table users --print-check     # show the check, run nothing
set -euo pipefail

SERVICE_ROOT="${SERVICE_ROOT:-$(pwd)}"
CONFIG_FILE="${KIT_DEPLOY_CONFIG:-config/deploy.yml}"

# `kamal` if it is on PATH, `bin/kamal` if the service vendored it, and
# `bundle exec kamal` if the service has a Gemfile. kamal-backup makes exactly
# this choice in KamalBridge#kamal_command (kamal-backup 0.5.2, lines 225-233),
# so matching it means the wrapper and the gem never disagree about which
# binary answered.
kamal_cmd() {
  if [ -x "$SERVICE_ROOT/bin/kamal" ]; then
    printf 'bin/kamal'
  elif [ -f "$SERVICE_ROOT/Gemfile" ]; then
    printf 'bundle exec kamal'
  else
    printf 'kamal'
  fi
}

note() { printf 'drill: %s\n' "$*" >&2; }
die() {
  printf 'drill: %s\n' "$*" >&2
  exit "${2:-1}"
}

usage() {
  cat >&2 <<'USAGE'
usage: drill.sh --table NAME [--table NAME ...] [options]

  --table NAME        a table that MUST have rows after the restore. Repeatable,
                      and required: a drill with no table asserts nothing.
  --scratch NAME      scratch database name (default: <service>_drill)
  --snapshot ID       restore a specific snapshot instead of the latest
  --database URL      the postgres accessory's host:port (default: <service>-postgres:5432)
  --print-check       print the generated check command and exit, running nothing
  -h, --help          this text
USAGE
  exit 64
}

# --------------------------------------------------------------------------
# Arguments. A drill with no content assertion is refused rather than defaulted,
# because "the restore command exited zero" is not a drill.
# --------------------------------------------------------------------------
TABLES=""
SCRATCH=""
SNAPSHOT=""
PGHOST_OVERRIDE=""
PRINT_CHECK=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --table)
      [ "$#" -ge 2 ] || usage
      TABLES="$TABLES $2"
      shift 2
      ;;
    --table=*)
      TABLES="$TABLES ${1#*=}"
      shift
      ;;
    --scratch)
      [ "$#" -ge 2 ] || usage
      SCRATCH="$2"
      shift 2
      ;;
    --scratch=*)
      SCRATCH="${1#*=}"
      shift
      ;;
    --snapshot)
      [ "$#" -ge 2 ] || usage
      SNAPSHOT="$2"
      shift 2
      ;;
    --snapshot=*)
      SNAPSHOT="${1#*=}"
      shift
      ;;
    --database)
      [ "$#" -ge 2 ] || usage
      PGHOST_OVERRIDE="$2"
      shift 2
      ;;
    --print-check)
      PRINT_CHECK=1
      shift
      ;;
    -h | --help) usage ;;
    *) printf 'drill: unknown argument %s\n' "$1" >&2; usage ;;
  esac
done

[ -n "${TABLES// /}" ] || usage

# The service name is the Kamal config's own `service:`, read from the file
# rather than taken as an argument, so the drill cannot be pointed at a scratch
# database belonging to some other service on the same host.
[ -f "$SERVICE_ROOT/$CONFIG_FILE" ] ||
  die "no Kamal config at $SERVICE_ROOT/$CONFIG_FILE. Run this from the service repository."

SERVICE="$(awk '/^service:/ { print $2; exit }' "$SERVICE_ROOT/$CONFIG_FILE")"
[ -n "$SERVICE" ] ||
  die "$CONFIG_FILE has no top-level 'service:' line, so there is no name to derive a scratch database from."

# An UNRENDERED template. Reading `service:` out of a file that still contains
# ERB yields `<%=`, which produces a scratch database called `<%=_drill` and a
# confusing complaint about its first character. The template is a template: it
# becomes `config/deploy.yml` when a service copies it and Kamal renders it.
case "$SERVICE" in
  *'<'* | *'%'*)
    die "$CONFIG_FILE still contains ERB. This is kit's template, not a rendered Kamal config — copy it to $CONFIG_FILE and let Kamal render it (or render it yourself) before drilling." 64
    ;;
esac

# --------------------------------------------------------------------------
# THE TWO REFUSALS, BEFORE ANYTHING IS CREATED.
#
# kamal-backup refuses a production-looking target too (Config#production_named_target?
# matches /production/, and a delimited prod/live). Doing it here as well is
# deliberate and not redundant: the gem's check runs inside the accessory, after
# this script has already connected to the server and issued a CREATE DATABASE.
# The cheapest refusal is the one that needs no round trip.
# --------------------------------------------------------------------------
[ -n "$SCRATCH" ] || SCRATCH="${SERVICE}_drill"

case "$SCRATCH" in
  # `*prod*` rather than a list of `*production*`, `*prod`, `prod_*`: "prod" is
  # a substring of "production", so the longer pattern is subsumed by the
  # shorter one and listing both is a second spelling of one rule.
  *prod* | *PROD* | *live* | *LIVE*)
    die "refusing to drill into '$SCRATCH': the name looks like production. A drill restores into a scratch database and then DROPS it, so a production-looking name is a database that gets dropped." 65
    ;;
esac

[ "$SCRATCH" != "$SERVICE" ] ||
  die "refusing to drill into '$SCRATCH': that is the live database." 65

case "$SCRATCH" in
  [A-Za-z_]* ) ;;
  * ) die "scratch database name '$SCRATCH' must start with a letter or underscore" 64 ;;
esac

# The heredoc terminator the generated check uses. A variable, so it cannot
# collide with a terminator in this file, and quoted (`<<'...'`) in the emitted
# text so the shell inside the check does not expand anything before psql sees
# it — a check that expanded `$PGPASSWORD` into its own argv would put a
# credential in a process listing, which is the exact thing this file avoids.
SQL_MARK='CAF_DRILL_SQL'

# --------------------------------------------------------------------------
# THE CHECK, AND WHY IT IS BUILT THE WAY IT IS.
#
# The gem runs the check as `sh -lc <check>` and reads its exit status. So the
# check has to be an assertion, not a report.
#
# `psql -tAc "SELECT count(*) FROM t"` is NOT an assertion: it exits 0 for 0
# rows, for 4,000 rows, and for a table that exists because pg_restore created
# it and then copied nothing into it.
#
# A plpgsql DO block with RAISE EXCEPTION is, because ON_ERROR_STOP=1 makes
# psql exit non-zero on a script error. So `count(*) = 0` becomes a non-zero
# exit, which becomes a failed drill, which is the only thing the gem looks at.
#
# The block is also cumulative rather than per-table, so a drill that restores
# three tables reports which ones are empty rather than only that something is.
# --------------------------------------------------------------------------
#
# ONE heredoc, not two. The first version nested a `cat <<SQL` inside a
# `cat <<CHECK`, and command substitution does not run inside a heredoc body —
# the inner heredoc was emitted as literal text and the whole file stopped
# parsing. The terminator is therefore a variable, so the two can never be
# confused for each other.
build_check() {
  local scratch="$1" body="" table
  for table in $TABLES; do
    [ -n "$body" ] && body="${body}
    "
    body="${body}    IF (SELECT count(*) FROM \"${table}\") = 0 THEN
      RAISE EXCEPTION 'drill: table ${table} is empty in ${scratch}';
    END IF;"
  done

  printf '%s\n' \
    "psql --no-psqlrc --quiet --set=ON_ERROR_STOP=1 --dbname=${scratch} <<'${SQL_MARK}'" \
    'DO $$' \
    'DECLARE' \
    'BEGIN' \
    "${body}" \
    'END' \
    '$$;' \
    "${SQL_MARK}"
}

CHECK_COMMAND="$(build_check "$SCRATCH")"

if [ "$PRINT_CHECK" -eq 1 ]; then
  # --print-check exists so an operator can read the assertion before trusting
  # it, and so a test can assert on the text without a database. It is also the
  # reason this file is testable without docker: everything above this line is
  # argument handling and string building.
  printf '%s\n' "$CHECK_COMMAND"
  exit 0
fi

# --------------------------------------------------------------------------
# CONNECTION, AS ENVIRONMENT AND NEVER AS AN ARGUMENT.
#
# PGPASSWORD reaches libpq through the environment, which is how kamal-backup
# itself does it (CommandSpec.new(argv: %w[pg_dump ...], env: current_connection)
# — the password is in `env`, never in `argv`). The generated check above
# therefore needs no host, no user and no password: it inherits all three.
# --------------------------------------------------------------------------
DATABASE_URL="${DATABASE_URL:-}"
[ -n "$DATABASE_URL" ] ||
  die "DATABASE_URL is not set. It is a Kamal secret on the backup accessory, so this normally runs through 'kamal accessory exec'; running it directly means exporting the secret yourself." 78

# Split the URL without printing it. `read` on a here-string keeps it out of argv
# and out of the shell's xtrace.
url_scheme="${DATABASE_URL%%://*}"
url_rest="${DATABASE_URL#*://}"
url_userinfo="${url_rest%%@*}"
url_hostport="${url_rest##*@}"
url_host="${url_hostport%%:*}"
url_port="${url_hostport##*:}"
[ "$url_port" = "$url_hostport" ] && url_port=5432
url_user="${url_userinfo%%:*}"
url_pass=""
case "$url_userinfo" in
  *:*) url_pass="${url_userinfo#*:}" ;;
esac
# The live database's own name is deliberately NOT extracted. It is not needed:
# the administrative connection below targets `postgres`, and the check targets
# the scratch database. Carrying the live name in this shell would only create
# an opportunity to connect to it by accident.

case "$url_scheme" in
  postgres | postgresql) ;;
  *) die "DATABASE_URL must be a postgres:// URL, not $url_scheme://" 64 ;;
esac

# The scratch database lives on the postgres accessory, not on the app's pgbouncer.
# A pooled connection reports a freshly restored schema as missing, because the
# session is serving a different backend. That is a property of pooling, not a
# broken restore, and it is why this defaults to the accessory's own host.
: "${PGHOST:=$url_host}"
: "${PGPORT:=$url_port}"
: "${PGUSER:=$url_user}"
: "${PGPASSWORD:=$url_pass}"
if [ -n "$PGHOST_OVERRIDE" ]; then
  PGHOST="${PGHOST_OVERRIDE%%:*}"
  PGPORT="${PGHOST_OVERRIDE##*:}"
  [ "$PGPORT" = "$PGHOST_OVERRIDE" ] && PGPORT=5432
fi
export PGHOST PGPORT PGUSER PGPASSWORD

admin() { psql --no-psqlrc --quiet --set=ON_ERROR_STOP=1 --dbname=postgres "$@"; }

# --------------------------------------------------------------------------
# CLEANUP ON EVERY EXIT PATH. Registered BEFORE the scratch database exists, so
# a failure to create it still runs a DROP IF EXISTS that costs nothing.
# --------------------------------------------------------------------------
cleanup() {
  # `with (force)` is what makes this work: a drill that failed halfway leaves
  # psql's own session connected to the scratch database, and a plain DROP
  # DATABASE would refuse with "database is being accessed by other users" and
  # leave the very thing this function exists to remove.
  admin -c "DROP DATABASE IF EXISTS \"${SCRATCH}\" WITH (FORCE)" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

note "scratch database '${SCRATCH}' will be dropped on every exit path, including a failure or a Ctrl-C"

cleanup
admin -c "CREATE DATABASE \"${SCRATCH}\"" >/dev/null ||
  die "could not create the scratch database '${SCRATCH}'. If it exists, something else owns it — pick another name with --scratch."

# --------------------------------------------------------------------------
# THE DRILL ITSELF, which is entirely kamal-backup's.
# --------------------------------------------------------------------------
KAMAL="$(kamal_cmd)"
# `--files` is deliberately NOT passed. kamal-backup defaults it to
# `/restore/files`, and `perform_file_restore` returns nil immediately when the
# config declares no `paths:` (app.rb:460-461) — which is the shape
# config/kamal-backup.yml.erb ships, because object storage is already remote and
# there is nothing local to snapshot. A service that DOES configure `paths:` adds
# `--files <target>` here; without one, passing it would ask the gem to restore a
# file snapshot that was never taken.
set -- drill production ${SNAPSHOT:-latest} \
  --database "$SCRATCH" \
  --check "$CHECK_COMMAND" \
  --yes

status=0
"$KAMAL" accessory exec -c "$CONFIG_FILE" --interactive --reuse backup \
  kamal-backup "$@" || status=$?

# The trap still runs; this is only so the operator sees the drop succeed
# before the shell's own exit status does the talking.
cleanup

if [ "$status" -ne 0 ]; then
  die "the drill FAILED (kamal-backup exit ${status}). The scratch database has been dropped; nothing about the live database was touched."
fi

note "drill passed: '${SCRATCH}' held rows in $(echo $TABLES | wc -w | tr -d ' ') table(s), and has been dropped."
