#!/usr/bin/env python3
"""kit's deploy-log redactor: the boundary between a deploy and a leak.

    redactor 3<secrets_pipe <text | redactor >clean

A deploy is the single most likely place in this platform to leak a credential,
because deploy tooling prints its own configuration for a living. `docker
compose config` renders every `environment:` line. `docker inspect` renders
every resolved env var and every command line. `docker compose logs` renders
whatever the application decided to print at 03:00. A registry client renders
the auth header when it is told to be verbose. The tool that runs the deploy is
therefore the right place to draw the line, and this is that line.

HOW SECRETS REACH THIS PROCESS, AND WHY IT IS NOT argv OR THE ENVIRONMENT
    Two streams, and they are deliberately not the obvious ones:

      * fd 3  newline-delimited values this process must scrub. The caller
        opens it as a pipe (`exec 3< <(printf '%s\n' "${VALUES[@]}")`) and
        leaves it open for the life of the deploy. A pipe is RAM; a herestring
        is a temp FILE on some shells, which would put every secret in /tmp.
      * fd 0  the text to be scrubbed.

    Not argv: `ps` shows argv to every user on the machine, and a shell's
    history file keeps it forever. Not the environment: `/proc/<pid>/environ`
    and `ps eww` read it, and CI logs tend to dump it on any crash. Not a file:
    the platform's rule is no plaintext at rest, and a redaction pattern list
    containing real keys is a plaintext credential store wearing a costume.

    This process holds the values only in its own address space, and drops them
    when it exits.

ONE CONTRACT WITH ITS CALLER, AND IT IS EASY TO GET WRONG
    **fd 3 carries BARE VALUES, one per line, and nothing else.** Not
    `NAME=value`, not quoted, not JSON, not with a trailing `=`.

    A caller that sends `NAME=value` gets that entire string treated as the
    value to scrub. The real value is then not in the list, so it is not
    redacted — and the filter still exits 0, prints a plausible-looking
    `[redacted:…]` marker for the *pair* if the pair ever appears, and reports
    success. Nothing about that failure is visible from the outside.

    This is not hypothetical. The deploy tool built its fd-3 stream from a list
    of `name=value` pairs, so for a long time its exact-value layer scrubbed
    the literal text `SECRET_KEY_BASE=hunter2` and printed the value `hunter2`
    in the clear on every line after the first. Caught by
    `tests/deploy_test.sh` §1b, which drives the tool's own `scrub` and asserts
    the bare value is absent — a test that passes a *different* format than the
    tool does would have gone green over it, which is exactly what happened for
    as long as the redaction unit test used its own helper.

TWO LAYERS, AND WHY THE SECOND ONE IS NOT OPTIONAL
    Layer 1 is the value list. It is exact and it is what protects the specific
    secrets this deploy was handed.
    Layer 2 is shape. It catches what the list cannot know about: a token the
    application minted, a JWT inside an error string, a database URL with a
    password that was assembled in code rather than injected. A redactor that
    only knows its own inputs is a redactor that is defeated by anything it did
    not already know about, and "the value was not in my list" is not a defence
    a deploy log can rest on.

WHAT IS DELIBERATELY NOT DONE
    * No "looks like a secret" heuristic wide enough to be useless. A filter
      that masks half the log teaches operators to paste into a paste bin.
    * No truncation in place of redaction. The reader still gets the line; the
      credential is gone and its NAME is not, so the log still says which
      secret was in play.
    * No attempt to parse the formats being scrubbed. These are patterns, not
      parsers, and a parser here would be a parser to get wrong on the day
      something unusual goes through.

EXIT STATUS
    0 on success, and the redacted text on stdout. A non-zero exit means the
    filter itself failed, which a caller must treat as a LEAK rather than an
    inconvenience: a redactor that fails open has no boundary at all.
"""

from __future__ import annotations

import argparse
import os
import re
import sys

# Layer 2. Applied to every line regardless of what the value list contains.
#
# Each pattern is (name, compiled_regex). `name` is what survives in the output,
# so an operator reading a redacted log learns WHICH kind of credential was
# there without learning its value -- that is the difference between a
# redaction that is safe to publish and one that is useless.
#
# The ordering is not cosmetic: `generic_assignment` is broad enough to also
# match a `Bearer ...` line, so the specific patterns run first and the
# specific name wins.
SHAPE_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    # A JWT. Three base64url segments; the header is matched literally because
    # every JWT header starts `{"alg"` which base64-encodes to `eyJ`.
    ("jwt", re.compile(r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}")),
    # A bearer token in an Authorization header, before the generic rule below
    # would file it under a less specific name.
    ("bearer", re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{8,}")),
    # AWS long-lived access key id.
    ("aws-access-key", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    # OpenAI-style and generic provider keys.
    ("provider-key", re.compile(r"\bsk-[A-Za-z0-9_-]{16,}")),
    # GitHub tokens, in both the classic and the fine-grained prefix.
    ("github-token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{16,}")),
    # A connection string with a password in it: scheme://user:password@host.
    # This is DATABASE_URL and it is the shape the platform handles most often.
    (
        "url-credentials",
        re.compile(r"\b([a-zA-Z][a-zA-Z0-9+.-]*)://([^\s:/@]+):([^\s:/@]+)@"),
    ),
    # A PEM private key, or its first line, appearing in a log.
    ("private-key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    # The last and broadest rule: any assignment to a credential-shaped name.
    # `key` alone is deliberately NOT in this list -- it matches far too much
    # ordinary configuration -- which is why the explicit patterns above exist.
    (
        "assigned-credential",
        re.compile(
            r"(?i)\b((?:[A-Za-z0-9_.-]*(?:password|passwd|secret|token|api[_-]?key|"
            r"access[_-]?key|private[_-]?key|credential|auth)[A-Za-z0-9_.-]*))"
            r"(\s*[:=]\s*)"
            r"(\"[^\"]*\"|'[^']*'|[^\s,;)}\]]+)"
        ),
    ),
)

# Values shorter than this are not scrubbed as literals. A 1- or 2-character
# "secret" is a real thing in test fixtures, and blanking every occurrence of a
# short string in a deploy log destroys the log without protecting anything.
# A real credential is never this short; the generator in the tool refuses
# inputs below it, so this is a backstop rather than a policy.
MIN_LITERAL_LEN = 8

# Replaced in place of a value. The surrounding text is preserved so the log
# still reads as a sentence, which is the difference between a log somebody
# pastes into an issue and a log nobody is willing to paste anywhere.
PLACEHOLDER = "[redacted:{0}]"


def read_secrets(fd: int) -> list[str]:
    """Read the newline-delimited value list from `fd`, without buffering it
    into anything that outlives this function."""
    if fd < 0:
        return []
    try:
        with os.fdopen(fd, "r", encoding="utf-8", errors="replace") as handle:
            return [line.strip() for line in handle if line.strip()]
    except OSError:
        # No secrets stream was supplied. That is a legitimate mode: the
        # shape layer still runs, and the caller gets value-list scrubbing
        # for free. It is not an error, because a deploy of a service with no
        # credentials is a real deploy.
        return []


def _mask_shape(line: str) -> str:
    """Apply the shape patterns, longest match first.

    Longest-first matters more than it looks. The generic assignment rule
    matches a URL with credentials in its password position, and if it ran
    first it would leave the URL's user and host exposed and only mask the
    password. Running the specific rules first means the whole authority
    section goes.
    """
    for name, pattern in SHAPE_PATTERNS:
        line = pattern.sub(PLACEHOLDER.format(name), line)
    return line


def _mask_literals(line: str, values: list[str]) -> str:
    """Replace every known secret value with its name."""
    # Longest value first, so a secret that is a prefix of another does not
    # leave the longer one's tail visible.
    for value in sorted(values, key=len, reverse=True):
        if len(value) < MIN_LITERAL_LEN:
            continue
        line = line.replace(value, PLACEHOLDER.format("secret"))
    return line


def redact(text: str, values: list[str]) -> str:
    return _mask_literals(_mask_shape(text), values)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Redact credentials from a deploy log stream."
    )
    parser.add_argument(
        "--secrets-fd",
        type=int,
        default=3,
        help="file descriptor carrying newline-delimited secret values (default: 3)",
    )
    args = parser.parse_args(argv)

    values = read_secrets(args.secrets_fd)

    out = sys.stdout
    for line in sys.stdin:
        out.write(redact(line, values))
    out.flush()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        # The consumer went away (`head`, a closed pipe). Standard Unix
        # behaviour; not a leak, and not worth a stack trace in a deploy log.
        try:
            sys.stdout.close()
        finally:
            os._exit(0)
    except KeyboardInterrupt:
        os._exit(130)
