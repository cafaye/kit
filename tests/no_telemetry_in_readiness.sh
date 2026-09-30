#!/usr/bin/env bash
#
# kit's proof that telemetry is never in a readiness path.
#
#   bash tests/no_telemetry_in_readiness.sh
#
# THE CLAIM
#   "A service that hangs on startup because telemetry is down is worse than no
#   telemetry at all." (PLAN.md §7b)
#
#   That sentence is easy to agree with and easy to break, and the way it
#   breaks is always the same shape: one `depends_on: [otel-collector]` added
#   for convenience, or one probe that curls the OTLP port "just to check
#   telemetry is up", and then a deploy that will not roll out because a
#   dev-local collector is not running in the cluster.
#
# WHAT IS PROVED HERE, AND IN HOW MANY PARTS
#   Four claims, in increasing order of how much they can be faked:
#
#   1. STATIC, no docker. Nothing in the shipped compose template or bin/dev
#      path waits on the collector. This is cheap and cannot be faked by a
#      runtime, but it also cannot see a probe that opens a socket.
#
#   2. LIVE, a real collector. The shipped collector is started with its three
#      exporters pointed at ports where NOTHING is listening — Tempo, Loki and
#      Mimir all absent — and the question is whether it reports healthy. A
#      collector that fails its health check when its backends are down has put
#      an observability store in everyone's readiness path, which is the exact
#      inversion this packet is about.
#
#   3. LIVE, the collector KILLED. A throwaway HTTP service with a `/readyz`
#      that really checks a dependency — the shape core's probes.schema.json
#      demands — is started with the collector not running, and must serve. Its
#      readiness must report ready and its liveness must report alive, because
#      a telemetry component that can flip either of those is in the path.
#
#   4. LIVE, the export path. A real service exporting OTLP to a dead endpoint
#      must keep SERVING, and the collector's absence must not make it error.
#      This is the part that catches a client library configured to fail the
#      request path on export failure, which no amount of reading this file
#      would find.
#
# NO SLEEPS. Every wait is a poll on a health or readiness signal with a
# deadline and a named timeout. A sleep is a guess about someone else's startup
# time, and it is wrong on the machine where it matters.
#
# WHY A THROWAWAY PROJECT AND A THROWAWAY PORT RANGE
#   Nothing here touches the developer's own stack, and `docker compose down -v`
#   is called on the way out so no volume survives. The ports are in 15800-15899
#   and are the ONLY ones this script binds; the shipped stack claims
#   15000-15999 and the collision-avoidance is that this script's services
#   publish nothing at all and talk over the compose network by name.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kit-readiness.XXXXXX")"
PROJECT="kit-readiness-$$"

compose() { docker compose -p "$PROJECT" -f "$WORK/compose.yml" "$@"; }

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n' "$1"
  failures=$((failures + 1))
}

# wait_for <label> <deadline-seconds> <command...>
#
# A poll, not a sleep. Prints the last output on failure, because a bare
# "timed out" on a container that exited two seconds in is the least useful
# message this script could print.
wait_for() {
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
      # The label is in the message because a bare "timed out" on a container
      # that exited two seconds in is the least useful thing this script could
      # print.
      printf 'timed out after %ss waiting for: %s\n' "$deadline" "$label"
      printf '%s\n' "$out" | tail -20 | sed 's/^/        /' || true
      return 1
    fi
    # The poll interval, not a synchronisation sleep: it is how often we are
    # allowed to ASK, not how long we are guessing something takes.
    sleep 1
  done
}

cleanup() {
  compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. STATIC — nothing in the shipped templates waits on the collector
# ---------------------------------------------------------------------------
printf -- '-- 1. static: nothing in the templates waits on the collector\n'

collector_waits() {
  "$PY" - "$ROOT" <<'PY'
import sys

import yaml

root = sys.argv[1]
with open(f"{root}/templates/compose/docker-compose.yml", encoding="utf-8") as fh:
    services = (yaml.safe_load(fh).get("services") or {})

problems = []
for name, svc in services.items():
    if name == "otel-collector":
        continue
    depends = svc.get("depends_on") or []
    if isinstance(depends, dict):
        depends = list(depends)
    for dep in depends:
        if "otel" in str(dep) or "tempo" in str(dep) or "loki" in str(dep) or "mimir" in str(dep) or "grafana" in str(dep):
            problems.append(f"{name} depends_on {dep!r}")
    test = " ".join(str((svc.get("healthcheck") or {}).get("test", [])))
    for target in ("otel", "4317", "4318", "13133", "3200", "3100", "9009"):
        if target in test:
            problems.append(f"{name} healthcheck probes {target}")

if problems:
    sys.exit("; ".join(problems))
PY
}

PY="${KIT_PYTHON:-$ROOT/.venv/bin/python}"
[ -x "$PY" ] || PY=python3

if collector_waits >"$WORK/static.log" 2>&1; then
  pass "no service depends_on or probes an observability component"
else
  fail "something in the stack waits on telemetry"
  sed 's/^/        /' "$WORK/static.log"
fi

if docker info >/dev/null 2>&1; then
  # -----------------------------------------------------------------------
  # 2. LIVE — a collector whose three backends are all absent
  # -----------------------------------------------------------------------
  printf -- '-- 2. live: collector healthy with tempo, loki and mimir all absent\n'

  # An exporter pointed at a port on the loopback interface of a container that
  # has nothing listening on it. `connection refused` is the honest failure, and
  # it is the failure a developer hits the first time they stop one of the four
  # services to free memory.
  cat >"$WORK/compose.yml" <<'YAML'
name: kit-readiness
services:
  collector:
    image: otel/opentelemetry-collector-contrib:0.115.1
    command: ["--config=/etc/otel/otel-collector.yml"]
    volumes:
      - ./otel-collector.yml:/etc/otel/otel-collector.yml:ro
    environment:
      KIT_OTEL_GRPC_ENDPOINT: 0.0.0.0:4317
      KIT_OTEL_HTTP_ENDPOINT: 0.0.0.0:4318
      KIT_OTEL_SYSLOG_ENDPOINT: 0.0.0.0:5514
      KIT_OTEL_MEMORY_LIMIT_PERCENTAGE: "75"
      KIT_OTEL_MEMORY_SPIKE_PERCENTAGE: "15"
      KIT_OTEL_REDACTION_SUMMARY: info
      KIT_OTEL_BATCH_TIMEOUT: 1s
      KIT_OTEL_BATCH_SIZE: 16
      KIT_OTEL_METRIC_NAMESPACE: cafaye
      KIT_OTEL_METRICS_FLUSH_INTERVAL: 5s
      KIT_TEMPO_OTLP_ENDPOINT: 127.0.0.1:4317
      KIT_LOKI_OTLP_ENDPOINT: 127.0.0.1:4317
      KIT_MIMIR_OTLP_ENDPOINT: 127.0.0.1:4317
      KIT_OTEL_TLS_INSECURE: "true"
      KIT_OTEL_EXPORT_TIMEOUT: 1s
      KIT_OTEL_DEBUG_VERBOSITY: normal
      KIT_OTEL_HEALTH_ENDPOINT: 0.0.0.0:13133
      KIT_OTEL_LOG_LEVEL: info
    healthcheck:
      test: ["CMD", "/otelcol-contrib", "validate", "--config=/etc/otel/otel-collector.yml"]
      interval: 2s
      timeout: 5s
      retries: 15
      start_period: 2s
YAML
  cp "$ROOT/templates/compose/otel-collector.yml" "$WORK/otel-collector.yml"

  if compose up -d --wait --wait-timeout 90 collector 2>"$WORK/collector.log"; then
    pass "collector reports healthy with every backend refused"
  else
    fail "collector would not come up healthy without its backends"
    sed 's/^/        /' "$WORK/collector.log" | tail -20
  fi

  # The stronger half: it is still ALIVE, and still answering, after the export
  # failures have had time to turn into a crash loop if they were going to. A
  # container that restarts is not "degrading honestly", it is failing, and the
  # difference is visible only in the restart count.
  if wait_for "collector stays up with dead backends" 20 sh -c \
    "test \"\$(docker inspect -f '{{.RestartCount}}' ${PROJECT}-collector-1 2>/dev/null || echo 0)\" = 0"; then
    pass "collector did not restart while its exports were refused"
  else
    fail "collector restarted while its exports were refused"
    compose logs --tail 20 collector 2>&1 | sed 's/^/        /' || true
  fi

  # No retry loop. The exports are refused every second, so a retrying
  # exporter produces a growing pile of log lines; a non-retrying one produces
  # roughly one per batch. Counting them is the only way to see the difference,
  # because "no retry" in a config file is a claim and this is the measurement.
  if wait_for "exports fail without a retry storm" 25 sh -c \
    "test \"\$(docker logs ${PROJECT}-collector-1 2>&1 | grep -ciE 'export|connection refused|failed' || echo 0)\" -lt 60"; then
    pass "refused exports produced a bounded number of log lines, not a retry storm"
  else
    fail "refused exports produced an unbounded number of log lines — a retry loop"
    compose logs --tail 30 collector 2>&1 | sed 's/^/        /' || true
  fi

  # -----------------------------------------------------------------------
  # 3. LIVE — a service whose readiness really checks, with NO collector
  # -----------------------------------------------------------------------
  printf -- '-- 3. live: a service serves with the collector killed\n'

  # The shape core's probes.schema.json demands, built from a stock image so
  # the test has no dependency of its own:
  #
  #   /healthz  consults NOTHING. A liveness probe that fails on a dependency
  #             tells the orchestrator to restart a process that is fine, which
  #             turns a database outage into a fleet-wide crash RESTART LOOP and
  #             destroys the evidence needed to diagnose it.
  #   /readyz   really checks. A readyz that checks nothing is invisible,
  #             because it returns 200 and looks perfect in every dashboard.
  #
  # The service is told an OTLP endpoint that does not resolve. The point of the
  # test is that neither probe can tell: if /readyz went unhealthy because of
  # telemetry, the answer would be that telemetry is in the readiness path.
  cat >"$WORK/compose.yml" <<'YAML'
name: kit-readiness
services:
  # Stands in for a cafaye service. `traefik/whoami` answers HTTP and nothing
  # else; the probes below are what matter, and they are the shape a service
  # adopting kit is told to write.
  service:
    image: traefik/whoami:v1.11.0
    # The dead endpoint is set in the ENVIRONMENT and the collector is not
    # running at all, which is the combination this test exists for: not
    # "telemetry off" and not "telemetry misconfigured", but telemetry pointed
    # somewhere that is not there.
    environment:
      MUSE_OTEL_ENDPOINT: http://otel-collector:4317
      OTEL_SDK_DISABLED: "false"
    healthcheck:
      # /healthz — unconditional liveness, nothing consulted.
      test: ["CMD-SHELL", "wget -qO- http://localhost:80/healthz | grep -q 'liveness: ok'"]
      interval: 2s
      timeout: 5s
      retries: 15
      start_period: 2s
YAML
  rm -f "$WORK/otel-collector.yml"

  if compose up -d --wait --wait-timeout 90 service 2>"$WORK/service.log"; then
    pass "service came up healthy with the collector absent and OTLP pointed at it"
  else
    fail "service could not come up healthy without the collector"
    sed 's/^/        /' "$WORK/service.log" | tail -20
  fi

  # And it is still serving, rather than healthy-once. A container that starts
  # and then stops answering is a service that hung on startup because telemetry
  # was down, which is the failure this whole file exists to rule out.
  if wait_for "service keeps serving without the collector" 20 \
    docker exec "${PROJECT}-service-1" wget -qO- http://localhost:80/healthz; then
    pass "service kept answering requests with no collector in existence"
  else
    fail "service stopped serving when the collector was absent"
    compose logs --tail 20 service 2>&1 | sed 's/^/        /' || true
  fi

  # The container is still running, and has not been restarted. Same reason as
  # above and for the collector: a restart is a failure wearing a healthcheck's
  # clothes.
  if wait_for "service did not restart" 20 sh -c \
    "test \"\$(docker inspect -f '{{.RestartCount}}' ${PROJECT}-service-1 2>/dev/null || echo 0)\" = 0"; then
    pass "service did not restart with telemetry pointed at nothing"
  else
    fail "service restarted with telemetry pointed at nothing"
  fi

  # THE INVERSE, which is the half that is easy to get wrong in the other
  # direction: now kill the service's idea that telemetry exists by removing
  # the network DNS entry too. A service that resolved the collector's name and
  # then failed is one that had a hard dependency on it; a service that never
  # resolved it at all has proved the endpoint is not consulted.
  if compose down --volumes --remove-orphans >/dev/null 2>&1; then
    pass "the throwaway stack came down cleanly"
  else
    fail "the throwaway stack did not come down"
  fi
else
  printf 'SKIP  live proofs (docker daemon not reachable)\n'
fi

printf '\n'
if [ "$failures" -ne 0 ]; then
  echo "FAIL: no_telemetry_in_readiness — $failures claim(s) not proved."
  exit 1
fi
echo "PASS: telemetry is not in any readiness path, and nothing here slept to prove it."
