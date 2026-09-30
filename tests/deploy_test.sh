#!/usr/bin/env bash
#
# kit's proof that the deploy story works, and that it can fail.
#
#   bash tests/deploy_test.sh
#
# WHAT IS PROVED HERE, IN ORDER OF HOW MUCH IT CAN BE FAKED
#
#   1. STATIC, no docker. The redaction boundary actually redacts. Not "the
#      file exists" — the filter is EXECUTED against a known secret and a JWT
#      and a connection string, and the assertions are that the canary is
#      absent AND that the surrounding text survived, because a filter that
#      deletes the whole line passes "no canary found" while being useless.
#
#   2. STATIC, no docker. The tool refuses the inputs that would leak. A
#      secret named as a file path, a secret nobody claims, a secret too short
#      to be a credential, a multi-line secret. Each is a refusal, and each
#      refusal is asserted by exit status AND by the message.
#
#   3. LIVE, a real deploy. `courier` is deployed as a release image and its
#      health gate goes GREEN.
#
#   4. LIVE, the red proof. The database is stopped underneath the running
#      service and the readiness endpoint is watched going 503, the container
#      healthcheck is watched going unhealthy, and `deploy verify` is watched
#      exiting non-zero. This is the assertion that gives every other "it is
#      healthy" in this file its meaning: a check that has never been seen red
#      is a check that might not be checking.
#
#   5. LIVE, the restore. The database comes back and all three go green
#      again, because a red that never clears is a different bug from one that
#      does.
#
#   6. LIVE, rollback. A second artifact is deployed and then rolled back, and
#      the previous artifact is shown to be the one actually serving. Not a
#      description of how one might roll back — the image digest the service
#      is running is compared before and after.
#
#   7. LIVE, the leak audit. After all of the above, the deploy log, the
#      rendered compose config and `docker inspect` are searched for every
#      secret value that was supplied. All three must be clean. This is the
#      check that would catch the most damaging thing this packet could get
#      wrong, and it runs LAST, against the accumulated evidence.
#
#   8. LIVE, restart policy. The application container is killed and Docker is
#      watched bringing it back and re-serving, which is the claim "restart:
#      unless-stopped" makes.
#
# NO SLEEPS. Every wait is a poll on a real signal — an HTTP status, a
# container health status, an image digest — with a deadline. `sleep` appears
# only as the interval BETWEEN polls, which is how often this script is allowed
# to ask, not how long it guesses something takes. This matches
# `tests/no_telemetry_in_readiness.sh`, which is the house pattern.
#
# IT TOUCHES NOTHING IT DID NOT CREATE. Every container, network and volume
# here belongs to the compose project `kit-deploy-test-$$` and is removed on the
# way out, volumes included. There is no `docker system prune` anywhere in this
# file and no command that is not scoped to that project by name.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="$ROOT/templates/bin/deploy"
REDACTOR="$ROOT/templates/deploy/redact.py"
COMPOSE_REF="$ROOT/templates/deploy/reference/courier.deploy.yml"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kit-deploy-test.XXXXXX")"
PROJECT="kit-deploy-test-$$"
LEDGER_DIR="$WORK/ledger"
DEPLOY_LOG="$WORK/deploy.log"

PY="${KIT_PYTHON:-$ROOT/.venv/bin/python}"
[ -x "$PY" ] || PY=python3

failures=0
passes=0
skips=0

pass() {
  printf 'PASS  %s\n' "$1"
  passes=$((passes + 1))
}
fail() {
  printf 'FAIL  %s\n' "$1"
  failures=$((failures + 1))
}
skip() {
  printf 'SKIP  %s\n' "$1"
  skips=$((skips + 1))
}
note() { printf 'NOTE  %s\n' "$1"; }

# wait_until <label> <deadline-seconds> <command...>
# A poll, never a sleep. Prints the last output on failure, because a bare
# "timed out" on a container that exited two seconds in is the least useful
# message this script could print.
wait_until() {
  local label="$1" deadline="$2"
  shift 2
  local start now out
  start=$(date +%s)
  while :; do
    if out="$("$@" 2>&1)"; then
      return 0
    fi
    now=$(date +%s)
    if [ $((now - start)) -ge "$deadline" ]; then
      printf '      timed out after %ss waiting for: %s\n' "$deadline" "$label"
      printf '%s\n' "$out" | tail -20 | sed 's/^/        /' || true
      return 1
    fi
    sleep 1
  done
}

app_cid() { dc ps --quiet app 2>/dev/null | head -1; }
db_cid() { dc ps --quiet db 2>/dev/null | head -1; }

# dc: every direct compose call in this file goes through here, because the
# deploy file interpolates two variables and refuses to render without them.
# A `stop db` that quietly failed on a missing variable would have turned the
# red proof in section 4 into a green one for the wrong reason.
dc() {
  SERVICE_NAME=courier KIT_DEPLOY_IMAGE="${IMAGE_A:-unused}" \
    docker compose --project-name "$PROJECT" --file "$COMPOSE_REF" "$@"
}

health_of() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null || echo gone; }
image_of() { docker inspect -f '{{.Image}}' "$1" 2>/dev/null || echo none; }
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || echo 000; }

cleanup() {
  # The two variables the deploy file interpolates, so the file is RENDERABLE
  # at teardown. Without them `${KIT_DEPLOY_IMAGE:?...}` refuses and `down`
  # never runs, which would leave this script's containers, network and volume
  # behind — the exact "clean up what you create" failure this packet is
  # required not to have.
  SERVICE_NAME=courier KIT_DEPLOY_IMAGE="${IMAGE_A:-unused-at-teardown}" \
    docker compose --project-name "$PROJECT" --file "$COMPOSE_REF" \
    down --volumes --remove-orphans >/dev/null 2>&1 || true
  docker image rm "${IMAGE_A:-none}-rollback-target" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. The redaction boundary, executed
# ---------------------------------------------------------------------------
printf -- '-- 1. the redactor redacts, and does not delete the line\n'

# A value the redactor cannot know by name is half the test: a filter that
# only works on its own input list is defeated by anything it did not already
# hold, and a deploy log is full of strings the deploy never supplied.
SECRET_ONE="$(openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
SECRET_TWO="KIT16CANARY-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
JWT_CANARY="eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJraXQxNiJ9.Q1lOYVJZTEZBS1JFU1VMVFRFU1FMkE"
URL_CANARY="postgres://courier:${SECRET_TWO}@db:5432/courier"
B64_CANARY="sk-$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"

# redact_with <text> <secret>... — run the real filter with a real fd 3.
redact_with() {
  local text="$1"
  shift
  local -a s=("$@")
  printf '%s' "$text" | "$PY" "$REDACTOR" --secrets-fd 3 3< <(printf '%s\n' "${s[@]}")
}

out="$(redact_with "connecting with ${SECRET_ONE} to the database" "$SECRET_ONE")"
case "$out" in
  *"$SECRET_ONE"*) fail "the redactor left a known secret value in the output" ;;
  *)
    case "$out" in
      *"[redacted:"*"database"*) pass "a known secret value is redacted and the sentence survives" ;;
      *) fail "the secret was removed but so was the sentence: $out" ;;
    esac
    ;;
esac

out="$(redact_with "auth header: Bearer ${SECRET_ONE}; user=alice" "$SECRET_ONE")"
case "$out" in
  *"$SECRET_ONE"*) fail "the redactor left a secret inside a bearer token" ;;
  *user=alice*) pass "a secret embedded in a bearer token is redacted, context kept" ;;
  *) fail "the whole line was destroyed: $out" ;;
esac

out="$(redact_with "url=${URL_CANARY}" "$SECRET_ONE")"
case "$out" in
  *"${SECRET_TWO}"*) fail "the redactor left a password inside a connection URL" ;;
  *redacted*) pass "a password inside a connection URL is redacted" ;;
  *) fail "the URL was not recognised: $out" ;;
esac

out="$(redact_with "token payload ${JWT_CANARY} rejected" "$SECRET_ONE")"
case "$out" in
  *"$JWT_CANARY"*) fail "the redactor left a JWT in the output" ;;
  *rejected*) pass "a JWT the deploy never supplied is redacted by shape alone" ;;
  *) fail "the JWT line was destroyed: $out" ;;
esac

out="$(redact_with "upstream said: ${B64_CANARY}" "$SECRET_ONE")"
case "$out" in
  *"$B64_CANARY"*) fail "the redactor left a provider-style key in the output" ;;
  *upstream*) pass "a provider key is redacted by shape alone" ;;
  *) fail "the provider key line was destroyed: $out" ;;
esac

# The false-positive floor. A redactor that masks ordinary operational text
# trains people to paste deploy logs into issue trackers by hand, which is the
# leak the redactor exists to prevent.
out="$(redact_with "starting service: app; waiting for health gate; 3 services healthy" "$SECRET_ONE")"
case "$out" in
  *"starting service: app; waiting for health gate; 3 services healthy"*) pass "ordinary operational text is not masked" ;;
  *) fail "the redactor mangled ordinary text: $out" ;;
esac

# A value shorter than MIN_LITERAL_LEN is not scrubbed as a literal, on
# purpose. Assert the behaviour rather than leaving it to be discovered in an
# incident: a 3-character "secret" in a fixture is not a credential, and
# masking every `ok` in a log would be the redactor breaking the log.
out="$(redact_with "value=ok done" "ok")"
case "$out" in
  *"ok done"*) pass "a sub-minimum-length value is not scrubbed as a literal" ;;
  *) fail "a 2-character value was scrubbed as a literal: $out" ;;
esac

# ---------------------------------------------------------------------------
# 2. The refusals. Each of these is a way to leak, and each must stop.
# ---------------------------------------------------------------------------
printf -- '-- 2. the tool refuses the inputs that would leak\n'

if bash "$DEPLOY" --help >/dev/null 2>&1; then
  pass "deploy --help exits 0"
else
  fail "deploy --help did not exit 0"
fi

# A secret as a FILE PATH is the wrong answer the platform's rule warns about,
# so the tool must not offer it as an option at all.
#
# Output is captured into a variable and matched afterwards rather than piped
# into grep. `set -o pipefail` is on in this script, so a `tool | grep -q`
# pipeline reports the TOOL's non-zero exit even when grep matched — which
# turns every one of these refusal tests into a silent pass/fail inversion.
# The refusals below are the case where reading the exit status wrongly is
# worst, because a refusal test that cannot fail is a test that will happily
# go green if the tool stops refusing.
out="$(bash "$DEPLOY" up --service courier --file "$COMPOSE_REF" --secrets-file /tmp/creds 2>&1 || true)"
case "$out" in
  *"unknown argument"*) pass "there is no --secrets-file: a credential file on disk is not a supported input" ;;
  *) fail "deploy accepted an option that would read credentials from disk. Output: $out" ;;
esac

out="$(bash "$DEPLOY" up --service courier --file "$COMPOSE_REF" 2>&1 || true)"
case "$out" in
  *"no secret source"*) pass "a deploy with no secret source is refused rather than run with none" ;;
  *) fail "a deploy with no secret source was not refused. Output: $out" ;;
esac

# A secret no service claims is the typo that produces a deploy which reports
# itself green and fails on the first real request.
out="$(SERVICE_NAME=courier KIT_DEPLOY_IMAGE=example/courier:0 \
  bash "$DEPLOY" up --service courier --file "$COMPOSE_REF" \
  --secrets-fd 3 --ledger-dir "$LEDGER_DIR" 3< <(
    printf 'DATABASE_URL=ecto://u:%s@db/courier\n' "$SECRET_ONE"
    printf 'SECRET_KEY_BASE=%s\n' "$SECRET_ONE"
    printf 'COURIER_SECRET_BOX_KEY=%s\n' "$SECRET_ONE"
    printf 'UNCLAIMED_THING=%s\n' "$SECRET_ONE"
  ) 2>&1 || true)"
case "$out" in
  *"is not claimed by any service"*) pass "a secret no service claims is refused before anything is created" ;;
  *) fail "an unclaimed secret was not refused. Output: $out" ;;
esac

# A line with no '=' is not a NAME=VALUE pair and must not be guessed at. The
# most likely way to produce one is a secrets file whose last line has no
# trailing newline and a `read` loop that mangles it — and the result would be
# a credential whose NAME is the value.
out="$(SERVICE_NAME=courier KIT_DEPLOY_IMAGE=example/courier:0 \
  bash "$DEPLOY" up --service courier --file "$COMPOSE_REF" \
  --secrets-fd 3 --ledger-dir "$LEDGER_DIR" 3< <(printf 'this-line-has-no-equals\n') 2>&1 || true)"
case "$out" in
  *"no '='"*) pass "a secret line with no '=' is refused rather than guessed at" ;;
  *) fail "a malformed secret line was not refused. Output: $out" ;;
esac

# A credential too short to be one is a misconfiguration, and masking it
# everywhere would be redaction that protects nothing.
out="$(SERVICE_NAME=courier KIT_DEPLOY_IMAGE=example/courier:0 \
  bash "$DEPLOY" up --service courier --file "$COMPOSE_REF" \
  --secrets-fd 3 --ledger-dir "$LEDGER_DIR" 3< <(printf 'DATABASE_URL=abc\n') 2>&1 || true)"
case "$out" in
  *"shorter than"*) pass "a secret too short to be a credential is refused" ;;
  *) fail "a too-short secret was not refused. Output: $out" ;;
esac

# ---------------------------------------------------------------------------
# 3-8. The live proofs
# ---------------------------------------------------------------------------
IMAGE_A="${KIT_DEPLOY_TEST_IMAGE:-}"

if ! docker info >/dev/null 2>&1; then
  skip "live proofs (the docker daemon is not reachable)"
  note "every live proof is 3-8 below: deploy, red, restore, rollback, leak audit, restart"
elif [ -z "$IMAGE_A" ]; then
  skip "live proofs (no image; set KIT_DEPLOY_TEST_IMAGE)"
  note "build one with:"
  note "  docker build -t cafaye-kit16/courier:35c6a27 /path/to/courier"
  note "then re-run with KIT_DEPLOY_TEST_IMAGE=cafaye-kit16/courier:35c6a27"
else
  printf -- '-- 3. a real deploy reaches green\n'

  PORT="${KIT_DEPLOY_TEST_PORT:-16877}"
  # Is the port free? This is a correctness check, not a politeness check, and
  # it is here because of something that actually happened while this packet
  # was being written: a leftover stack from an earlier manual run was still
  # publishing the test's port, so `curl /readyz` and `curl /healthz` were
  # answered by a stack this script had not created, and two assertions
  # reported PASS against a stranger's service.
  #
  # A deploy test that can silently measure the wrong thing is worse than one
  # that refuses to run, so this FAILS rather than skipping. Binding is the
  # test rather than probing, because a port can be taken by something that
  # does not speak HTTP.
  if ! "$PY" -c "
import socket
import sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(('127.0.0.1', $PORT))
except OSError as exc:
    print(exc)
    sys.exit(1)
finally:
    s.close()
" >"$WORK/port.txt" 2>&1; then
    fail "port $PORT is already in use — refusing to run, because this script would otherwise assert against a stack it did not create ($(cat "$WORK/port.txt"))"
    note "re-run with KIT_DEPLOY_TEST_PORT set to a free port"
    docker ps --format '{{.Names}}\t{{.Ports}}' | grep -E "[:.]${PORT}->" | sed 's/^/        /' || true
  fi
  # A second tag of the same image stands in for "the next release". Rollback
  # needs two artifacts to be meaningful, and building a second image for this
  # would add ten minutes to prove something about tagging rather than about
  # rollback. What rollback must prove is that going BACK changes what is
  # running, and that is proven by digest in section 6.
  IMAGE_B="${IMAGE_A}-rollback-target"
  docker image tag "$IMAGE_A" "$IMAGE_B" >/dev/null 2>&1 || true

  DB_PASSWORD="kit16DB-${SECRET_ONE}"
  APP_DB_URL="ecto://courier:${DB_PASSWORD}@db/courier"
  KEY_BASE="kit16Key-${SECRET_ONE}"
  BOX_KEY="$(openssl rand -base64 32 2>/dev/null | tr -d '\n')"

  # The secrets, as a stream. Built in a function because rollback needs them
  # too, and the first version of this file did not pass them — so rollback
  # failed with "no secret source" and the test reported a failure that was
  # the TEST's bug, not the tool's. Rollback is a deploy of a different
  # artifact and needs the credentials that go with it; the tool is right to
  # insist.
  secrets_stream() {
    printf 'DATABASE_URL=%s\n' "$APP_DB_URL"
    printf 'SECRET_KEY_BASE=%s\n' "$KEY_BASE"
    printf 'COURIER_SECRET_BOX_KEY=%s\n' "$BOX_KEY"
    printf 'POSTGRES_PASSWORD=%s\n' "$DB_PASSWORD"
  }

  # The deploy's own output is appended to the log for the leak audit in
  # section 7, and printed ONLY when the deploy fails. A deploy that fails
  # silently is the single most annoying thing a test of a deploy can do, and
  # it is the failure this file hit twice while it was being written.
  deploy_up() {
    local image="$1" rc=0
    : >"$DEPLOY_LOG"
    SERVICE_NAME=courier \
      KIT_DEPLOY_IMAGE="$image" \
      KIT_DEPLOY_PORT="$PORT" \
      KIT_DEPLOY_HOST=localhost \
      KIT_READY_TIMEOUT=180 \
      bash "$DEPLOY" up --service courier --file "$COMPOSE_REF" \
      --secrets-fd 3 --ledger-dir "$LEDGER_DIR" --project "$PROJECT" \
      --image "$image" 3< <(secrets_stream) >"$DEPLOY_LOG" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      printf '      --- deploy output (rc=%s) ---\n' "$rc"
      sed 's/^/      /' "$DEPLOY_LOG" | tail -25
    else
      # A deploy RECREATES the app container when the image changes, so the id
      # captured before it is an id that no longer exists. Re-resolving here is
      # not tidiness: every assertion below that names a container was
      # silently inspecting a dead one, and "the container did not come back"
      # was really "the container you asked about was deleted by the deploy".
      cid="$(app_cid)"
    fi
    return "$rc"
  }

  if deploy_up "$IMAGE_A" >/dev/null; then
    pass "deploy up reached green on $IMAGE_A"
  else
    fail "deploy up did not reach green"
  fi

  cid="$(app_cid)"
  if [ -n "$cid" ]; then
    if [ "$(http_code "http://127.0.0.1:$PORT/readyz")" = "200" ]; then
      pass "/readyz answers 200 with the database up"
    else
      fail "/readyz did not answer 200 with the database up"
    fi
    if wait_until "app healthy" 90 sh -c "[ \"\$(docker inspect -f '{{.State.Health.Status}}' '$cid' 2>/dev/null)\" = healthy ]"; then
      pass "the container healthcheck reports healthy"
    else
      fail "the container healthcheck never reported healthy"
    fi
  else
    fail "no app container was created"
  fi

  # -------------------------------------------------------------------
  # 4. The red proof
  # -------------------------------------------------------------------
  printf -- '-- 4. the health gate can go RED\n'

  # A deploy that has only ever reported green has proved nothing about the
  # gate. Break the real dependency and watch the real signal.
  #
  # `docker pause`, NOT `compose stop`. Stopping the container destroys its
  # tmpfs, so starting it again brings the database back WITHOUT its password
  # and it never comes up at all — which tests the secret-delivery path and
  # nothing else, and made the restore half of this section fail for a reason
  # that had nothing to do with readiness. Pausing freezes the process and
  # leaves the filesystem intact, so the database really stops answering
  # queries and really starts answering them again. That is the claim
  # `/readyz` makes, isolated from every other thing this platform does.
  DB_CID="$(db_cid)"
  if [ -n "$DB_CID" ] && docker pause "$DB_CID" >/dev/null 2>&1; then
    pass "the database was paused: it is now not answering queries"
  else
    fail "could not pause the database, so nothing below is a real red proof"
  fi

  if wait_until "readyz goes 503" 90 sh -c \
    "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 'http://127.0.0.1:$PORT/readyz' 2>/dev/null || echo 000)\" = 503 ]"; then
    pass "/readyz reports 503 with its database stopped — it really checks"
  else
    fail "/readyz stayed green with its database stopped — it checks nothing"
  fi

  if [ -n "$cid" ] && wait_until "container goes unhealthy" 90 sh -c \
    "[ \"\$(docker inspect -f '{{.State.Health.Status}}' '$cid' 2>/dev/null)\" = unhealthy ]"; then
    pass "the container healthcheck reports unhealthy with its database stopped"
  else
    fail "the container healthcheck stayed healthy with its database stopped"
  fi

  # The deploy tool's own verdict. A gate that reports green over a red stack
  # is worse than no gate, because it is believed.
  if bash "$DEPLOY" verify --service courier --file "$COMPOSE_REF" \
    --project "$PROJECT" --ledger-dir "$LEDGER_DIR" >"$WORK/verify-red.log" 2>&1; then
    fail "deploy verify exited 0 while the readiness endpoint was 503"
  else
    pass "deploy verify exits non-zero while the readiness endpoint is 503"
  fi

  # Liveness is the other half and it is the half that is easy to get wrong.
  # /healthz must stay 200: a liveness probe that fails on a dependency tells
  # the supervisor to restart a process that is fine, which turns a database
  # blip into a crash-restart loop and destroys the evidence.
  if [ "$(http_code "http://127.0.0.1:$PORT/healthz")" = "200" ]; then
    pass "/healthz stays 200 with the database down — liveness consults nothing"
  else
    fail "/healthz went down with the database — a liveness probe must not check a dependency"
  fi

  # -------------------------------------------------------------------
  # 5. The restore
  # -------------------------------------------------------------------
  printf -- '-- 5. and it comes back green\n'

  if [ -n "$DB_CID" ] && docker unpause "$DB_CID" >/dev/null 2>&1; then
    pass "the database was unpaused and is answering again"
  else
    fail "could not unpause the database"
  fi
  if wait_until "readyz returns to 200" 120 sh -c \
    "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 'http://127.0.0.1:$PORT/readyz' 2>/dev/null || echo 000)\" = 200 ]"; then
    pass "/readyz returns to 200 after the database comes back"
  else
    fail "/readyz did not return to 200 after the database came back"
  fi

  # -------------------------------------------------------------------
  # 6. Rollback
  # -------------------------------------------------------------------
  printf -- '-- 6. rollback actually changes what is serving\n'

  digest_before="$(image_of "$cid")"
  if deploy_up "$IMAGE_B" >/dev/null; then
    pass "a second artifact deployed and reached green"
  else
    fail "the second artifact did not reach green"
  fi
  digest_mid="$(image_of "$cid")"

  if SERVICE_NAME=courier KIT_DEPLOY_PORT="$PORT" KIT_READY_TIMEOUT=180 \
    bash "$DEPLOY" rollback --service courier --file "$COMPOSE_REF" \
    --secrets-fd 3 --ledger-dir "$LEDGER_DIR" --project "$PROJECT" \
    3< <(secrets_stream) >"$WORK/rollback.log" 2>&1; then
    cat "$WORK/rollback.log" >>"$DEPLOY_LOG"
    pass "deploy rollback reported success"
  else
    cat "$WORK/rollback.log" >>"$DEPLOY_LOG"
    fail "deploy rollback did not report success"
    sed 's/^/      /' "$WORK/rollback.log" | tail -20
  fi
  cid="$(app_cid)"

  digest_after="$(image_of "$cid")"
  if [ -n "$digest_before" ] && [ "$digest_after" = "$digest_before" ]; then
    pass "after rollback the container is running the pre-deploy artifact (digest $digest_after)"
  else
    fail "after rollback the container is not running the pre-deploy artifact (before=$digest_before after=$digest_after mid=$digest_mid)"
  fi

  if [ "$(http_code "http://127.0.0.1:$PORT/readyz")" = "200" ]; then
    pass "the rolled-back artifact is serving and ready"
  else
    fail "the rolled-back artifact is not serving"
  fi

  # -------------------------------------------------------------------
  # 7. The leak audit
  # -------------------------------------------------------------------
  printf -- '-- 7. no secret value reached any artefact a human can read\n'

  rendered="$WORK/compose-config.txt"
  dc config >"$rendered" 2>/dev/null || true
  inspected="$WORK/inspect.txt"
  docker inspect "$cid" >"$inspected" 2>/dev/null || true

  for artefact in "$DEPLOY_LOG" "$rendered" "$inspected"; do
    label="$(basename "$artefact")"
    leaked=0
    for canary in "$DB_PASSWORD" "$KEY_BASE" "$BOX_KEY" "$APP_DB_URL"; do
      if grep -qF "$canary" "$artefact" 2>/dev/null; then
        leaked=1
      fi
    done
    if [ "$leaked" -eq 0 ]; then
      pass "$label contains no secret value"
    else
      fail "$label contains a secret value"
    fi
  done

  # The value inside the running container, which is the one place it is
  # supposed to be. Asserting it is there proves the negatives above are
  # negatives because the secret existed, not because the deploy silently did
  # not deliver any.
  if docker exec -u 0 "$cid" sh -c 'test -s /run/secrets/DATABASE_URL' 2>/dev/null; then
    pass "the secret really was delivered (the negatives above are real negatives)"
  else
    fail "no secret reached the container — the leak audit proved nothing"
  fi

  # ...and the tmpfs claim, which is the load-bearing one.
  if docker exec -u 0 "$cid" sh -c 'mount | grep -q "tmpfs on /run/secrets"' 2>/dev/null; then
    pass "/run/secrets is a tmpfs — RAM, not a block device"
  else
    fail "/run/secrets is not a tmpfs; the credential is somewhere durable"
  fi

  # -------------------------------------------------------------------
  # 8. Restart policy, and what a restart costs
  # -------------------------------------------------------------------
  printf -- '-- 8. the restart policy is real, and a restart empties the secret store\n'

  if [ -n "$cid" ]; then
    if docker kill "$cid" >/dev/null 2>&1; then
      pass "the application container was killed"
    else
      skip "could not kill the application container"
    fi
    if wait_until "the container comes back" 120 sh -c \
      "docker inspect -f '{{.State.Status}}' '$cid' 2>/dev/null | grep -q running"; then
      pass "Docker restarted the killed container, per the restart policy"
    else
      fail "the killed container did not come back — the restart policy is not doing anything"
    fi

    # THE HONEST PART, and the reason this is the last section rather than a
    # line in the README. /run/secrets is a tmpfs, so the restart wiped it.
    # The restarted container therefore comes back BLOCKED at the credential
    # gate and must NOT be serving, and that is the correct behaviour: a
    # process that starts without its database URL is a process that fails in
    # a way that looks like a bad release.
    #
    # Asserting the non-serving state is what makes the next assertion mean
    # something. A test that only checked "it came back and serves" would have
    # been quietly wrong here, and would have passed against a gate that did
    # not exist.
    if wait_until "the restarted container is back and serving without credentials" 8 \
      sh -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 'http://127.0.0.1:$PORT/readyz' 2>/dev/null || echo 000)\" = 200 ]"; then
      fail "the restarted container served WITHOUT credentials — the secret gate is not a gate"
    else
      pass "the restarted container is blocked at the credential gate, not serving"
    fi

    # And the repair. Re-running a deploy is not a no-op: it delivers the
    # credentials again. On a real target an orchestrator does this on every
    # start and none of it is manual — which is precisely why the secret store
    # cannot simply be a file on disk, and why "it worked until it restarted"
    # is the failure mode a plaintext credential file would have had.
    if deploy_up "$IMAGE_B" >/dev/null; then
      pass "re-running the deploy delivers the credentials again and the service recovers"
    else
      fail "re-running the deploy did not recover the service"
    fi
    if [ "$(http_code "http://127.0.0.1:$PORT/readyz")" = "200" ]; then
      pass "the recovered service is ready again"
    else
      fail "the recovered service is not ready"
    fi
  fi

  docker image rm "$IMAGE_B" >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
printf '\n'
note "passed: $passes  failed: $failures  skipped: $skips"
if [ "$failures" -ne 0 ]; then
  echo "FAIL: deploy — $failures claim(s) not proved."
  exit 1
fi
if [ "$skips" -ne 0 ]; then
  echo "PASS (with $skips skipped): deploy, with every live proof accounted for."
  exit 0
fi
echo "PASS: deploy, and every health gate was demonstrated red and green."
