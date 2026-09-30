#!/bin/sh
# kit's deploy entrypoint: the secret gate.
#
#   docker run --entrypoint /kit/entrypoint.sh ...
#
# WHY THIS EXISTS. On plain Docker there is exactly one way to get a credential
# into a container that is not a plaintext file on the host, and it is not an
# `environment:` block: anything in `environment:` is rendered verbatim by
# `docker inspect` and by `docker compose config`, which means any operator
# with read access to the daemon can read the secret and any CI job that dumps
# the rendered config has published it. The platform's rule is no plaintext at
# rest and never in a config file, and an env var in container config is a
# config file.
#
# So the secret arrives through a different door. The deploy tool streams each
# value into this container's `/run/secrets` over stdin, where `/run/secrets`
# is a tmpfs -- RAM, never a block device, gone when the container is. This
# script waits for that to happen, puts the values where the application can
# read them, and hands PID 1 to the application.
#
# THE BARRIER IS THE POINT, NOT A DETAIL. The container starts BEFORE the
# secrets arrive, and it must not run the application until they have. A
# service that boots without its database URL fails in a way that looks like a
# bad release; a service that waits for its credentials and reports honestly
# that they never arrived is diagnosable. The wait is bounded and it FAILS
# CLOSED -- see KIT_SECRET_TIMEOUT below.
#
# WHY `exec`. The application becomes PID 1, so a `docker stop` sends SIGTERM
# to the application itself rather than to a shell that might ignore it, and
# `restart: unless-stopped` means a crash is a restart of the real process
# rather than of this script.
#
# WHY POSIX sh AND NOT bash. The runtime images differ: courier's release image
# is Debian-slim with a shell, Go and Rust images in `docker/` are
# `distroless` and carry NO shell at all. A gate that needs bash cannot be
# mounted into a distroless image, so this file is written to the sh that
# alpine and debian-slim both provide. See templates/deploy/README.md for what
# a distroless service does instead -- it is a real difference, not an
# oversight.
set -eu

SECRETS_DIR="${KIT_SECRETS_DIR:-/run/secrets}"
LOADED_MARKER="$SECRETS_DIR/.loaded"
TIMEOUT="${KIT_SECRET_TIMEOUT:-30}"

# The application, as `name=command` pairs, is appended by the deploy tool when
# it generates the entrypoint. The default is the single most common shape in
# this fleet and it is deliberately overridable per service.
APP_CMD="${KIT_APP_CMD:-}"

for f in "$SECRETS_DIR"/*; do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  [ "$name" = ".loaded" ] && continue
  # A credential that arrives containing a newline is not a credential, it is a
  # file that was pointed at by mistake, and a multi-line value cannot be
  # represented in the environment the application reads. An EMPTY one is the
  # same class of defect: an unset secret that looks injected is a deploy that
  # reports success and fails at the first real request.
  #
  # `wc -l` counts newlines, so the off-by-one at the tail is deliberate: a
  # one-line value with no trailing newline reports 0 and is accepted, because
  # a deploy tool that writes a secret without a final newline has not
  # corrupted anything. Two or more newlines is the rejection case.
  lines=$(wc -l <"$f" | tr -d ' ')
  if [ "$lines" -gt 1 ]; then
    echo "entrypoint: secret '$name' spans $lines lines; a secret is one line. Refusing to start" >&2
    exit 78
  fi
  if [ ! -s "$f" ]; then
    echo "entrypoint: secret '$name' is empty. Refusing to start" >&2
    exit 78
  fi
done

# Bounded wait. A poll, not a sleep: this is how often the gate is allowed to
# ASK whether the secret has arrived, and it stops asking at the deadline. A
# fixed `sleep 5` would be a guess about the deploy tool's speed, and it would
# be wrong on the slow machine where being wrong matters.
#
# THE TIMEOUT MUST EXCEED A RESTART CYCLE, and the reason is a property of
# this design rather than of this service: /run/secrets is a tmpfs, so it is
# empty again every time the container restarts. A container restarted by
# `restart: unless-stopped` therefore comes back BLOCKED, on purpose, and waits
# here for the deploy tool to deliver the credentials again. `deploy up` does
# that on every invocation, which is why re-running a deploy is a repair and
# not a no-op. On a real target the orchestrator re-injects secrets on every
# start and none of this is manual. See templates/deploy/README.md.
waited=0
while [ ! -f "$LOADED_MARKER" ]; do
  if [ "$waited" -ge "$TIMEOUT" ]; then
    echo "entrypoint: no credentials within ${TIMEOUT}s; refusing to start." >&2
    echo "entrypoint: if this container was restarted, /run/secrets is a tmpfs and was" >&2
    echo "entrypoint: emptied by the restart — re-run \`deploy up\` to deliver them again." >&2
    exit 78
  fi
  sleep 1
  waited=$((waited + 1))
done

# Load. `set -a` + assignment from a command substitution is the only POSIX way
# to turn files in a directory into environment variables without writing an
# env file, and an env file is the thing this whole design exists to avoid.
set -a
for f in "$SECRETS_DIR"/*; do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  [ "$name" = ".loaded" ] && continue
  # A file whose name is not a valid environment variable name is skipped
  # rather than exported, because `export 1BAD=x` is a syntax error in some
  # shells and a silent no-op in others -- and either way a deploy that claims
  # to have injected a secret but did not is the worst possible outcome.
  case "$name" in
    [A-Z_][A-Z0-9_]*) ;;
    *) echo "entrypoint: skipping '$name': not a valid environment variable name" >&2; continue ;;
  esac
  value=$(cat "$f")
  export "$name=$value"
  unset value
done
set +a

# Say what arrived, never what it was. The count and the names are what an
# operator needs to diagnose a misconfigured deploy; the values are the one
# thing that must never be written down anywhere.
loaded_count=$(find "$SECRETS_DIR" -maxdepth 1 -type f ! -name '.loaded' | wc -l | tr -d ' ')
loaded_names=$(find "$SECRETS_DIR" -maxdepth 1 -type f ! -name '.loaded' -exec basename {} \; | sort | tr '\n' ',' | sed 's/,$//')
echo "entrypoint: ${loaded_count} secret(s) loaded: ${loaded_names}"

if [ -z "$APP_CMD" ]; then
  echo "entrypoint: KIT_APP_CMD is empty; nothing to run" >&2
  exit 78
fi

# KIT_APP_CMD is operator-supplied configuration, and this is a shell
# evaluation of it. That is a deliberate, bounded decision: the command comes
# from the deploy tool that generated this file, not from the application and
# not from the network. Splitting it into an argv array is not expressible in
# POSIX sh without eval anyway, and eval is the honest spelling of the same
# thing.
eval "exec $APP_CMD"
