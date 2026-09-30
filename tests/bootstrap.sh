#!/usr/bin/env bash
#
# kit's dependency bootstrap. SOURCED, not executed.
#
# The property this file exists to establish:
#
#     on a clean checkout with no .venv, ONE command runs the whole gate.
#
#     bash tests/validate.sh
#
# A gate that needs an undocumented manual step is not a gate. `validate.sh`
# used to prefer `$ROOT/.venv/bin/python`, fall back to `python3`, and print
#
#     no python with PyYAML: pip install -r tests/requirements.txt
#     GATE_EXIT=1
#
# `.venv` is gitignored, so *every* fresh clone and *every* CI runner hit that
# — including the CI job this repository now runs on itself. A developer who
# read the two-line instruction in AGENTS.md was fine; a CI runner and anyone
# who cloned without reading were not. That is a gate that fails on arrival
# rather than on content.
#
# So the gate installs its own dependencies on first run, into a directory it
# already owns (`.venv/`, gitignored). Nothing here is a kit dependency: kit
# still ships no library, no lockfile and no runtime code. These are the tools
# the test suite runs, exactly as `shellcheck` is — except that shellcheck is
# optional and these are not, because the suite cannot proceed without them.
#
# Resolved in this order, and the order is the contract:
#
#   1. $KIT_PYTHON — an explicit override is a promise. If it is set and cannot
#      import yaml, that is a configuration error and we say so rather than
#      silently building a second interpreter the caller did not ask for.
#   2. $ROOT/.venv/bin/python — what a previous run of this gate bootstrapped.
#   3. whatever python is on PATH that already has PyYAML — a developer with it
#      system-installed should not pay for a venv.
#   4. bootstrap: create .venv and pip install tests/requirements.txt.
#
# Steps 2 and 3 matter for speed and step 4 for correctness, in that order: a
# warm .venv means a normal gate run never touches the network.

# kit_bootstrap_python — sets $PY, or exits 1 with one paste-able command.
#
# Sets a variable rather than echoing a path because every caller wants it as a
# variable. SC2034 fires on all four assignments because nothing in THIS file
# reads it back; the readers are the two scripts that source this one.
# shellcheck disable=SC2034
kit_bootstrap_python() {
  local root="$1"

  if [ -n "${KIT_PYTHON:-}" ]; then
    if "$KIT_PYTHON" -c 'import yaml' >/dev/null 2>&1; then
      PY="$KIT_PYTHON"
      return 0
    fi
    cat >&2 <<MSG
KIT_PYTHON is set to '$KIT_PYTHON' and it cannot import PyYAML.

An explicit override is a promise, so the gate does not quietly substitute a
different interpreter. Unset KIT_PYTHON to let the gate bootstrap its own:

    unset KIT_PYTHON && bash tests/validate.sh
MSG
    return 1
  fi

  if [ -x "$root/.venv/bin/python" ] && "$root/.venv/bin/python" -c 'import yaml' >/dev/null 2>&1; then
    PY="$root/.venv/bin/python"
    return 0
  fi

  local candidate
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 &&
      "$candidate" -c 'import yaml' >/dev/null 2>&1; then
      PY="$(command -v "$candidate")"
      return 0
    fi
  done

  # Nothing usable. Build it.
  #
  # `python3 -m venv` rather than a bare `python3`: a venv is the only way to
  # get PyYAML onto a machine that does not have it, and it is the same thing
  # AGENTS.md and the README already told people to run by hand — except that
  # now it happens as part of the gate rather than as a step nobody remembers.
  local creator=''
  for candidate in python3 python; do
    command -v "$candidate" >/dev/null 2>&1 && creator="$candidate" && break
  done

  if [ -z "$creator" ]; then
    cat >&2 <<'MSG'
the gate needs python, and this machine has neither python3 nor python.

Install one and re-run the same command:

    bash tests/validate.sh
MSG
    return 1
  fi

  printf 'note: bootstrapping %s/.venv from tests/requirements.txt (first run)\n' \
    "${root#"$PWD"/}" >&2

  # A venv left behind by a failed or cancelled run is not necessarily broken,
  # but it is cheap to prove rather than assume, and `venv` over an existing
  # directory is the exact thing that produces a half-built environment.
  if [ ! -x "$root/.venv/bin/python" ]; then
    if ! "$creator" -m venv "$root/.venv" >&2; then
      cat >&2 <<MSG
could not create $root/.venv. To do it by hand:

    $creator -m venv $root/.venv && $root/.venv/bin/pip install -r $root/tests/requirements.txt

then re-run:

    bash tests/validate.sh
MSG
      return 1
    fi
  fi

  if ! "$root/.venv/bin/python" -m pip install --quiet --disable-pip-version-check \
    -r "$root/tests/requirements.txt" >&2; then
    cat >&2 <<MSG
could not install the gate's dependencies from tests/requirements.txt
(the download failed, or there is no network). To do it by hand:

    $root/.venv/bin/pip install -r $root/tests/requirements.txt

then re-run:

    bash tests/validate.sh
MSG
    return 1
  fi

  if ! "$root/.venv/bin/python" -c 'import yaml' >/dev/null 2>&1; then
    cat >&2 <<MSG
$root/.venv exists and pip reported success, but PyYAML is still not importable.
Something is wrong with the environment rather than with the gate. Check:

    $root/.venv/bin/pip list

then re-run:

    bash tests/validate.sh
MSG
    return 1
  fi

  PY="$root/.venv/bin/python"
  return 0
}

# kit_bootstrap_console_script <name> <module> — sets $CONSOLE, or exits 1.
#
# yamllint is required and has the same failure mode PyYAML had, so it gets the
# same treatment. The subtlety is WHERE it has to live.
#
# It cannot simply be `$ROOT/.venv/bin/yamllint`. $PY is not always the
# bootstrap's own interpreter: it is a system python3 that already had PyYAML
# when no venv was needed, or — inside self_test — the interpreter of the tree
# that was invoked, passed in as KIT_PYTHON so sixteen throwaway copies share
# one. In both cases `$ROOT/.venv` does not exist, and looking there yielded
#
#     FAIL yamllint (required, not installed: pip install -r ...)
#
# on a clean clone of the real tree. A required check whose path is hardcoded
# to a directory the resolver may have decided not to create is a gate that
# fails on arrival, which is the exact defect this file was written to remove.
#
# So the script is looked for next to the interpreter we actually chose, then on
# PATH, and only then installed — into that same interpreter, so the two can
# never disagree about which environment the tool lives in.
#
# $CONSOLE is a variable, not an echo, for the same reason $PY is.
# shellcheck disable=SC2034
kit_bootstrap_console_script() {
  local name="$1" module="$2" root="$3"

  local beside
  beside="$(dirname "$PY")/$name"
  if [ -x "$beside" ]; then
    CONSOLE="$beside"
    return 0
  fi
  if command -v "$name" >/dev/null 2>&1; then
    CONSOLE="$(command -v "$name")"
    return 0
  fi

  printf 'note: installing %s into %s (first run)\n' "$name" "$PY" >&2
  if ! "$PY" -m pip install --quiet --disable-pip-version-check "$module" >&2; then
    cat >&2 <<MSG
the gate needs $name, and installing it failed (no network, or no permission
to write to the environment). To do it by hand:

    $PY -m pip install -r $root/tests/requirements.txt

then re-run:

    bash tests/validate.sh
MSG
    return 1
  fi

  if [ -x "$beside" ]; then
    CONSOLE="$beside"
    return 0
  fi
  # A venv on some platforms puts scripts elsewhere; ask the interpreter rather
  # than guessing a path.
  CONSOLE="$("$PY" -c 'import sysconfig, sys; print(sysconfig.get_path("scripts"))' 2>/dev/null)/$name"
  if [ -x "$CONSOLE" ]; then
    return 0
  fi

  cat >&2 <<MSG
pip reported installing $name, but it is still not on PATH and cannot be
imported as $module. The environment is broken rather than the gate. Check:

    $PY -m pip list

then re-run:

    bash tests/validate.sh
MSG
  return 1
}
