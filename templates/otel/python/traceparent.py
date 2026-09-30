"""kit template — W3C Trace Context propagation for a FastAPI service.

Copy ``traceparent.py`` and ``test_traceparent.py`` into your service. For
inbound requests, ``fastapi.py.snippet`` wires this into a middleware; keep the
test suite either way.

The upstream OTel SDK does this for you — see ``fastapi.py.snippet`` for the
versioned wiring. Use this file when you need the header handling on its own: a
Celery task that calls another service, a webhook signer, or a test that asserts
propagation without standing up an SDK.

REFERENCE: W3C Trace Context, W3C Recommendation 23 November 2021
https://www.w3.org/TR/trace-context/

IMPLEMENTED SECTIONS (every one is asserted in ``test_traceparent.py``)
    §3.2.1      header name: accept any case, send lowercase
    §3.2.2.1    version is 2 hex chars; ff is forbidden
    §3.2.2.2    version-format for version 00
    §3.2.2.3    invalid trace-id -> ignore the traceparent (all zeroes forbidden)
    §3.2.2.4    invalid parent-id -> ignore the traceparent (all zeroes forbidden)
    §3.2.2.5    trace-flags is a bit field; mask on read
    §3.2.2.5.1  the sampled flag is the only flag in version 00
    §3.2.2.5.2  reserved flags MUST be set to zero on the wire
    §3.2.4      higher version: parse positionally, re-emit at 00, drop unknowns
    §3.3        a failed traceparent MUST NOT be rescued by a tracestate
    §3.3.1.5    tracestate: propagate >=512 chars, truncate whole entries only
    §4.2/§4.3   no traceparent -> new trace; invalid -> restart, never an error

NO DEPENDENCIES. Stdlib only, so this file drops into any FastAPI service and the
suite runs without ``pip install``.
"""

from __future__ import annotations

import secrets
from dataclasses import dataclass
from typing import Mapping

__all__ = [
    "ServerHop",
    "TraceParent",
    "format_traceparent",
    "forward_tracestate",
    "header",
    "new_span_id",
    "new_trace_id",
    "parse_traceparent",
    "server_hop",
]

# Bit 0 of trace-flags (§3.2.2.5.1). It is a bit in a field, not the field's
# value: reading ``flags == 1`` instead of ``flags & 1 == 1`` is the single most
# common trace-context bug, and it is why this is a named constant.
SAMPLED = 0x01

# A traceparent is exactly 55 characters: 2 version, 32 trace-id, 16 parent-id,
# 2 trace-flags, and 3 dashes (§3.2.2.2).
MIN_HEADER_LEN = 55

# §3.3.1.5: "Vendors SHOULD propagate at least 512 characters of a combined
# header." Bigger than this and we truncate whole entries.
TRACESTATE_LIMIT = 512

# §3.3.1.5: "Entries larger than 128 characters long SHOULD be removed first."
TRACESTATE_ENTRY_LIMIT = 128

ZERO_TRACE_ID = "0" * 32
ZERO_SPAN_ID = "0" * 16

_LOWER_HEX = frozenset("0123456789abcdef")


@dataclass(frozen=True)
class TraceParent:
    """A parsed ``traceparent`` header.

    ``version`` is the raw version byte: zero for version ``00``, the only
    version we emit; a higher version is parsed (§3.2.4) and then downgraded.
    ``extra`` is everything after the flags field on a higher-version header,
    retained for logging only — §3.2.4 says vendors MUST NOT forward unknown
    fields, and :meth:`ServerHop.outbound_headers` does not.
    """

    version: int
    trace_id: str
    parent_id: str
    flags: int
    extra: str = ""

    @property
    def sampled(self) -> bool:
        """The caller's recording decision (§3.2.2.5.1).

        We carry this rather than making our own: a service that re-decides
        sampling per hop produces traces with holes in them, which are worse than
        no traces.
        """
        return self.flags & SAMPLED == SAMPLED


@dataclass(frozen=True)
class ServerHop:
    """One service's continuation of a trace.

    ``continued`` is not a debug field: a span exporter needs to know whether this
    is a root span in order to label it correctly.
    """

    trace_id: str
    span_id: str
    flags: int
    tracestate: str = ""
    continued: bool = False

    @property
    def sampled(self) -> bool:
        return self.flags & SAMPLED == SAMPLED

    @property
    def outbound_headers(self) -> dict[str, str]:
        """This hop as headers for the next service.

        The shape is fixed by §3.4: parent-id becomes this hop's span id, and the
        version is downgraded to the one we implement. Those two mutations plus
        the sampled flag are the entire allowed set — §3.4 says vendors MUST NOT
        make any other mutation.
        """
        out = {"traceparent": format_traceparent(self.trace_id, self.span_id, self.flags)}
        if self.tracestate:
            out["tracestate"] = self.tracestate
        return out


def parse_traceparent(value: str | None) -> TraceParent | None:
    """Parse a ``traceparent`` header value.

    Returns ``None`` for anything invalid, and that is the whole contract:
    §3.2.2.3 and §3.2.2.4 say a vendor MUST ignore the header when trace-id or
    parent-id is invalid, and §3.2.4 says to restart the trace when the version
    cannot be parsed. There is no error to handle and no value to partially
    trust.
    """
    if not value:
        return None

    raw = value if isinstance(value, str) else str(value)
    # A short header cannot hold the four fields, whatever the version (§3.2.4).
    if len(raw) < MIN_HEADER_LEN:
        return None

    # §3.2.4: "When the version prefix cannot be parsed (it's not 2 hex characters
    # followed by a dash), the implementation should restart the trace." Checked
    # before anything else, so a malformed version is never mistaken for a valid
    # one.
    if raw[2] != "-" or not _is_lower_hex(raw[0:2]):
        return None

    version = int(raw[0:2], 16)
    # §3.2.2.1: "Version ff is invalid."
    if version == 0xFF:
        return None

    trace_id = raw[3:35]
    parent_id = raw[36:52]
    flags_field = raw[53:55]

    # The three fixed positions, all three mandatory (§3.2.4).
    if raw[35] != "-" or raw[52] != "-":
        return None
    if not (_is_lower_hex(trace_id) and _is_lower_hex(parent_id) and _is_lower_hex(flags_field)):
        return None

    if version == 0:
        # §3.2.2.2 defines version 00 as exactly these four fields. Trailing data
        # means the sender is not speaking version 00, and accepting it would be
        # inventing a format the spec does not define.
        if len(raw) != MIN_HEADER_LEN:
            return None
    elif len(raw) > MIN_HEADER_LEN:
        # §3.2.4: on a higher version the two flag characters are followed by
        # either the end of the header or a dash introducing an unknown field.
        if raw[MIN_HEADER_LEN] != "-":
            return None

    # §3.2.2.3 and §3.2.2.4: all zeroes is an invalid value for both, and the
    # required response is to ignore the header.
    if trace_id == ZERO_TRACE_ID or parent_id == ZERO_SPAN_ID:
        return None

    return TraceParent(version, trace_id, parent_id, int(flags_field, 16), raw[MIN_HEADER_LEN + 1 :])


def server_hop(headers: Mapping[str, str], span_id: str) -> ServerHop:
    """Continue the trace described by the inbound headers.

    This is the one function a service's middleware calls. It cannot fail: a
    malformed or absent traceparent yields a new trace, because a request is not
    an error because its trace header was garbage (§4.2, §3.2.2.3).

    ``span_id`` is a parameter rather than generated here so the caller owns the
    span lifecycle — in a service it comes from the tracer, in a test it is a
    constant, which is why the suite can assert equality instead of a shape.
    """
    parsed = parse_traceparent(header(headers, "traceparent"))

    if parsed is None:
        # §3.3: "If the vendor failed to parse traceparent, it MUST NOT attempt to
        # parse tracestate." §4.2 makes it explicit for the no-traceparent case: a
        # tracestate alone "is invalid and MUST be discarded". Forwarding it
        # would attach a vendor's state to an unrelated trace.
        return ServerHop(trace_id=new_trace_id(), span_id=span_id, flags=0)

    return ServerHop(
        trace_id=parsed.trace_id,
        span_id=span_id,
        # §3.2.2.5: a bit field, so mask on read rather than carry the bytes
        # through. §3.2.2.5.2 requires the reserved bits to be zero outbound.
        flags=parsed.flags & SAMPLED,
        tracestate=forward_tracestate(header(headers, "tracestate")) or "",
        continued=True,
    )


def format_traceparent(trace_id: str, parent_id: str, flags: int) -> str:
    """Build a ``traceparent`` at version 00.

    Always version 00, always lowercase hex, always exactly 55 characters
    (§3.2.2.2). It takes no version parameter on purpose: a service speaks one
    version, and a caller that could pass any version would eventually pass a
    wrong one.
    """
    return f"00-{trace_id}-{parent_id}-{flags & 0xFF:02x}"


def forward_tracestate(value: str | None) -> str | None:
    """Apply the §3.3.1.5 limits to an inbound ``tracestate``.

    The order matters and is the order the spec states: oversized entries go
    first (they are the expensive ones and the least likely to be a well-known
    vendor key), then entries are dropped from the end. Dropping from the front
    would discard the most recent vendor's entry, which is the one that just
    wrote it and the one that knows where the trace currently is.
    """
    if not value:
        return None

    entries: list[str] = []
    for raw in value.split(","):
        entry = raw.strip()
        # §3.3.1.1: "Empty and whitespace-only list members are allowed."
        if not entry or len(entry) > TRACESTATE_ENTRY_LIMIT:
            continue
        entries.append(entry)

    # Pop from the end until the combined value fits (§3.3.1.5).
    while entries and len(",".join(entries)) > TRACESTATE_LIMIT:
        entries.pop()

    return ",".join(entries) or None


def header(headers: Mapping[str, str], name: str) -> str | None:
    """Look a header up case-insensitively.

    §3.2.1: "Vendors MUST expect the header name in any case (upper, lower,
    mixed)". Starlette lowercases, but a test, a proxy, or a middleware that
    copies raw keys will not, and being strict here breaks traces in production
    for no reason.
    """
    value = headers.get(name)
    if value is not None:
        return value
    lowered = name.lower()
    for key, candidate in headers.items():
        if key.lower() == lowered:
            return candidate
    return None


def new_trace_id() -> str:
    """A fresh 16-byte trace identifier as 32 hex characters.

    §8: 16 bytes from a cryptographically secure source, never all zeroes.
    """
    return secrets.token_hex(16)


def new_span_id() -> str:
    """A fresh 8-byte span identifier as 16 hex characters.

    §8. On all-zero failure it returns a fixed non-zero constant rather than
    raising: an exhausted entropy source is not a reason to take the service
    down, and §3.2.2.4 only requires that the value is not all zeroes. The
    collision risk is theoretical; the availability risk is not.
    """
    span_id = secrets.token_hex(8)
    return "0000000000000001" if span_id == ZERO_SPAN_ID else span_id


def _is_lower_hex(value: str) -> bool:
    """Whether ``value`` is entirely lowercase hex.

    §3.2.2 defines the alphabet as HEXDIGLC, lowercase only. Uppercase is
    rejected rather than folded: accepting it means two services disagree about
    whether a header is valid, and one of them starts a new trace.
    """
    return bool(value) and _LOWER_HEX.issuperset(value)
