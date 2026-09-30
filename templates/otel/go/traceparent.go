// kit template — W3C Trace Context propagation for a Go service.
//
// Copy into your service (package kitotel, or rename to internal/telemetry),
// then wire ServerHopFrom in your HTTP middleware and OutboundHeaders on your
// outbound client. traceparent_test.go is the suite; keep it.
//
// The upstream OTel SDK does this for you — see otelhttp.go.snippet for the
// versioned wiring. Use this file when you need the header handling on its own:
// a NATS consumer, a webhook signer, or a test that asserts propagation without
// standing up an SDK.
//
// REFERENCE: W3C Trace Context, W3C Recommendation 23 November 2021
// https://www.w3.org/TR/trace-context/
//
// IMPLEMENTED SECTIONS (every one is asserted in traceparent_test.go)
//
//	§3.2.1      header name: accept any case, send lowercase
//	§3.2.2.1    version is 2 hex chars; ff is forbidden
//	§3.2.2.2    version-format for version 00
//	§3.2.2.3    invalid trace-id -> ignore the traceparent (all zeroes forbidden)
//	§3.2.2.4    invalid parent-id -> ignore the traceparent (all zeroes forbidden)
//	§3.2.2.5    trace-flags is a bit field; mask on read
//	§3.2.2.5.1  the sampled flag is the only flag in version 00
//	§3.2.2.5.2  reserved flags MUST be set to zero on the wire
//	§3.2.4      higher version: parse positionally, re-emit at 00, drop unknowns
//	§3.3        a failed traceparent MUST NOT be rescued by a tracestate
//	§3.3.1.5    tracestate: propagate >=512 chars, truncate whole entries only
//	§4.2/§4.3   no traceparent -> new trace; invalid -> restart, never error
//
// NO DEPENDENCIES. Stdlib only, so this file drops into any Go service and the
// test suite runs with GOPROXY=off. If you find yourself importing the OTel SDK
// to make this work, read otelhttp.go.snippet instead — that is the supported
// path and it is one line.
package kitotel

import (
	"crypto/rand"
	"encoding/hex"
	"strconv"
	"strings"
)

const (
	// sampledFlag is bit 0 of trace-flags (§3.2.2.5.1). It is a bit in a field,
	// not the field's value: reading `flags == 1` instead of `flags&1 == 1` is
	// the single most common trace-context bug, and it is why this is a constant
	// with a name rather than a literal.
	sampledFlag = 0x01

	// A traceparent is exactly 55 characters: 2 version, 32 trace-id, 16
	// parent-id, 2 trace-flags, and 3 dashes (§3.2.2.2).
	minHeaderLen = 55

	// §3.3.1.5: "Vendors SHOULD propagate at least 512 characters of a combined
	// header." Bigger than this and we truncate whole entries.
	tracestateLimit = 512

	// §3.3.1.5: "Entries larger than 128 characters long SHOULD be removed
	// first."
	tracestateEntryLimit = 128

	zeroTraceID = "00000000000000000000000000000000"
	zeroSpanID  = "0000000000000000"
)

// TraceParent is a parsed `traceparent` header.
//
// Exported so a caller can inspect what it received without re-parsing, which
// is how a debug endpoint shows the inbound trace-id.
type TraceParent struct {
	// Version is the raw version byte. Zero for version "00", which is the only
	// version we emit. A higher version is parsed (§3.2.4) and then downgraded.
	Version int
	// TraceID is 32 lowercase hex characters: the whole trace (§3.2.2.3).
	TraceID string
	// ParentID is 16 lowercase hex characters: the caller's span (§3.2.2.4).
	ParentID string
	// Flags is the full 8-bit field, preserved from the inbound header. Read
	// Sampled(), not Flags, so the masking stays in one place.
	Flags int
	// Extra is everything after the flags field on a higher-version header
	// (§3.2.4). Retained for logging only: §3.2.4 says vendors MUST NOT forward
	// unknown fields, and OutboundHeaders does not.
	Extra string
}

// Sampled reports the caller's recording decision (§3.2.2.5.1). We carry this
// rather than making our own: a service that re-decides sampling per hop
// produces traces with holes in them, which are worse than no traces.
func (tp TraceParent) Sampled() bool { return tp.Flags&sampledFlag == sampledFlag }

// ServerHop is one service's continuation of a trace: what we tell our caller
// about the request we handled, and what we put on the wire to the next hop.
type ServerHop struct {
	// TraceID continues the inbound trace, or is fresh when there was none.
	TraceID string
	// SpanID is this hop's span. It becomes the parent-id the next hop sees.
	SpanID string
	// Flags is the outbound trace-flags: the sampled bit, and nothing else
	// (§3.2.2.5.2 requires reserved bits to be zero on the wire).
	Flags int
	// Tracestate is the inbound tracestate, truncated per §3.3.1.5. Empty when
	// there was no valid traceparent to travel with it.
	Tracestate string
	// Continued reports whether we continued the caller's trace. It is not a
	// debug field: a span exporter needs to know this to label a root span.
	Continued bool
}

// Sampled is the recording decision this hop forwards (§3.2.2.5.1).
func (h ServerHop) Sampled() bool { return h.Flags&sampledFlag == sampledFlag }

// ParseTraceparent parses a `traceparent` header value.
//
// Returns false for anything invalid, and that is the whole contract: §3.2.2.3
// and §3.2.2.4 say a vendor MUST ignore the header when trace-id or parent-id is
// invalid, and §3.2.4 says to restart the trace when the version cannot be
// parsed. There is no error to handle and no value to partially trust — an
// invalid header means "start a new trace", not "carry on with what parsed".
func ParseTraceparent(value string) (TraceParent, bool) {
	// A short header cannot hold the four fields, whatever the version (§3.2.4).
	if len(value) < minHeaderLen {
		return TraceParent{}, false
	}
	// §3.2.4: "When the version prefix cannot be parsed (it's not 2 hex
	// characters followed by a dash), the implementation should restart the
	// trace." Checked before anything else so a malformed version is never
	// mistaken for a valid one.
	if value[2] != '-' || !isLowerHex(value[0:2]) {
		return TraceParent{}, false
	}
	version, err := strconv.ParseInt(value[0:2], 16, 16)
	if err != nil {
		return TraceParent{}, false
	}
	// §3.2.2.1: "Version ff is invalid."
	if version == 0xFF {
		return TraceParent{}, false
	}

	traceID := value[3:35]
	parentID := value[36:52]
	flagsField := value[53:55]

	// The three fixed positions, all three mandatory (§3.2.4).
	if value[35] != '-' || value[52] != '-' {
		return TraceParent{}, false
	}
	if !isLowerHex(traceID) || !isLowerHex(parentID) || !isLowerHex(flagsField) {
		return TraceParent{}, false
	}

	flags, err := strconv.ParseInt(flagsField, 16, 16)
	if err != nil {
		return TraceParent{}, false
	}

	if version == 0 {
		// §3.2.2.2 defines version 00 as exactly these four fields. Trailing
		// data means the sender is not speaking version 00, and accepting it
		// would be inventing a format the spec does not define.
		if len(value) != minHeaderLen {
			return TraceParent{}, false
		}
	} else if len(value) > minHeaderLen {
		// §3.2.4: on a higher version, the two flag characters are followed by
		// either the end of the header or a dash introducing an unknown field.
		// Anything else is unparseable.
		if value[55] != '-' {
			return TraceParent{}, false
		}
	}

	// §3.2.2.3 and §3.2.2.4: all zeroes is an invalid value for both, and the
	// required response is to ignore the header.
	if traceID == zeroTraceID || parentID == zeroSpanID {
		return TraceParent{}, false
	}

	return TraceParent{
		Version:  int(version),
		TraceID:  traceID,
		ParentID: parentID,
		Flags:    int(flags),
		Extra:    strings.TrimPrefix(value[minHeaderLen:], "-"),
	}, true
}

// ServerHopFrom continues the trace described by the inbound headers.
//
// This is the one function a service's inbound middleware calls. It cannot
// fail: a malformed or absent traceparent yields a new trace, because a request
// is not an error because its trace header was garbage (§4.2, §3.2.2.3).
//
// spanID is a parameter rather than generated here so that the caller owns the
// span lifecycle — in a real service it comes from the tracer, and in a test it
// is a constant, which is why traceparent_test.go can assert equality instead
// of a shape.
func ServerHopFrom(headers map[string]string, spanID string) ServerHop {
	tp, valid := ParseTraceparent(header(headers, "traceparent"))

	if !valid {
		// §3.3: "If the vendor failed to parse traceparent, it MUST NOT attempt
		// to parse tracestate." §4.2 makes it explicit for the no-traceparent
		// case: a tracestate alone "is invalid and MUST be discarded".
		// Forwarding it would attach a vendor's state to an unrelated trace.
		return ServerHop{TraceID: NewTraceID(), SpanID: spanID, Flags: 0}
	}

	return ServerHop{
		TraceID: tp.TraceID,
		SpanID:  spanID,
		// §3.2.2.5: a bit field, so mask on read rather than carry the bytes
		// through. §3.2.2.5.2 requires the reserved bits to be zero outbound.
		Flags:      tp.Flags & sampledFlag,
		Tracestate: forwardTracestate(header(headers, "tracestate")),
		Continued:  true,
	}
}

// OutboundHeaders renders this hop as headers for the next service.
//
// The shape is fixed by §3.4: parent-id becomes this hop's span id, and the
// version is downgraded to the one we implement. Those two mutations plus the
// sampled flag are the entire allowed set — §3.4 says vendors MUST NOT make any
// other mutation.
func (h ServerHop) OutboundHeaders() map[string]string {
	out := map[string]string{
		// §3.2.1: send lowercase. The name is part of the contract even though
		// the receiving side is required to be case-insensitive.
		"traceparent": formatTraceparent(h.TraceID, h.SpanID, h.Flags),
	}
	if h.Tracestate != "" {
		out["tracestate"] = h.Tracestate
	}
	return out
}

// formatTraceparent builds the header at version 00.
//
// Always version 00, always lowercase hex, always exactly 55 characters —
// §3.2.2.2. It does not take a version parameter on purpose: a service speaks
// one version, and a caller that could pass any version would eventually pass a
// wrong one.
func formatTraceparent(traceID, parentID string, flags int) string {
	var b strings.Builder
	b.Grow(minHeaderLen)
	b.WriteString("00-")
	b.WriteString(traceID)
	b.WriteByte('-')
	b.WriteString(parentID)
	b.WriteByte('-')
	b.WriteString(hex.EncodeToString([]byte{byte(flags & 0xFF)}))
	return b.String()
}

// forwardTracestate applies the §3.3.1.5 limits to an inbound tracestate.
//
// The order matters and is the order the spec states: oversized entries go
// first (they are the expensive ones and the least likely to be a well-known
// vendor key), then entries are dropped from the end. Dropping from the front
// would discard the most recent vendor's entry, which is the one that just wrote
// it and the one that knows where the trace currently is.
func forwardTracestate(value string) string {
	if value == "" {
		return ""
	}

	entries := make([]string, 0, 8)
	for _, raw := range strings.Split(value, ",") {
		entry := strings.TrimSpace(raw)
		// §3.3.1.1: "Empty and whitespace-only list members are allowed."
		if entry == "" {
			continue
		}
		if len(entry) > tracestateEntryLimit {
			continue
		}
		entries = append(entries, entry)
	}

	// Pop from the end until the combined value fits (§3.3.1.5).
	for len(entries) > 0 && len(strings.Join(entries, ",")) > tracestateLimit {
		entries = entries[:len(entries)-1]
	}

	return strings.Join(entries, ",")
}

// header looks a header up case-insensitively.
//
// §3.2.1: "Vendors MUST expect the header name in any case (upper, lower,
// mixed)". Go's http.Header canonicalises to Title-Case on Set, but a map built
// by hand, a test, or a middleware that copies raw keys will not, and being
// strict here breaks traces in production for no reason.
func header(headers map[string]string, name string) string {
	if value, ok := headers[name]; ok {
		return value
	}
	for key, value := range headers {
		if strings.EqualFold(key, name) {
			return value
		}
	}
	return ""
}

// isLowerHex reports whether s is entirely lowercase hex (§3.2.2 defines the
// alphabet as HEXDIGLC, lowercase only). Uppercase is rejected rather than
// folded: accepting it means two services disagree about whether a header is
// valid, and one of them starts a new trace.
func isLowerHex(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

// NewTraceID returns a fresh 16-byte trace identifier as 32 hex characters.
//
// §8: 16 bytes from a cryptographically secure source, never all zeroes.
func NewTraceID() string { return randomHex(16) }

// NewSpanID returns a fresh 8-byte span identifier as 16 hex characters.
//
// §8. On all-zero failure it returns a fixed non-zero constant rather than
// panicking: an exhausted entropy source is not a reason to take the service
// down, and §3.2.2.4 only requires that the value is not all zeroes. The
// collision risk is theoretical; the availability risk is not.
func NewSpanID() string {
	id := randomHex(8)
	if id == zeroSpanID {
		return "0000000000000001"
	}
	return id
}

// randomHex returns n bytes from crypto/rand as lowercase hex.
//
// crypto/rand rather than math/rand: trace ids end up in logs and in traces
// that leave the process, and a predictable trace id is an invitation to
// correlate two users' requests by guessing.
func randomHex(n int) string {
	b := make([]byte, n)
	// The error is deliberately ignored; see NewSpanID's note on all-zero.
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
