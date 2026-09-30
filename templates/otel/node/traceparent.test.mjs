// kit template — W3C Trace Context propagation for a Hono/TypeScript service.
//
// Copy traceparent.mjs and this file into your service, then run
// `node --test test/traceparent.test.mjs` (or whatever your test runner is
// wired to). The suite is the contract: it proves the template still continues a
// trace instead of quietly restarting it.
//
// REFERENCE: W3C Trace Context, W3C Recommendation 23 November 2021
// https://www.w3.org/TR/trace-context/ — every rule asserted below cites the
// section that requires it.
//
// WHAT IT PROMISES
//   - A valid inbound traceparent is continued: same trace-id, sampled flag
//     preserved, parent-id replaced with this hop's span id (§3.4).
//   - A missing or malformed traceparent starts a new trace and never throws. A
//     request is not a 500 because its trace header was garbage.
//   - tracestate travels with the trace, capped at 512 characters and truncated
//     on whole-entry boundaries (§3.3.1.5).
//
// No dependencies: node:test, node:assert and node:crypto are all stdlib. The
// @opentelemetry/* packages are referenced by version in hono.ts.snippet, not
// imported here — kit has no dependencies and this suite must run without one.

import assert from "node:assert/strict";
import test from "node:test";

import { newSpanId, newTraceId, parseTraceparent, serverHop } from "./traceparent.mjs";

const KNOWN_HEADER = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";
const KNOWN_TRACE = "4bf92f3577b34da6a3ce929d0e0e4736";
const KNOWN_PARENT = "00f067aa0ba902b7";
// Fixed so every assertion below is an equality, not a shape check.
const FIXED_SPAN = "1111111111111111";

const BAD_HEADERS = {
  empty: "",
  "not a header": "garbage",
  "truncated at 54": `00-${KNOWN_TRACE}-${KNOWN_PARENT}`,
  "version 00 plus junk": `${KNOWN_HEADER}-extra`,
  "all-zero trace-id": `00-${"0".repeat(32)}-${KNOWN_PARENT}-01`,
  "all-zero parent-id": `00-${KNOWN_TRACE}-${"0".repeat(16)}-01`,
  "uppercase hex": `00-4BF92F3577B34DA6A3CE929D0E0E4736-${KNOWN_PARENT}-01`,
  "forbidden version ff": `ff-${KNOWN_TRACE}-${KNOWN_PARENT}-01`,
  "one-char version": `0-${KNOWN_TRACE}-${KNOWN_PARENT}-01`,
  "wrong delimiters": `00_${KNOWN_TRACE}_${KNOWN_PARENT}_01`,
  "non-hex flags": `00-${KNOWN_TRACE}-${KNOWN_PARENT}-0g`,
};

test("known traceparent is continued", () => {
  // The headline promise: a known traceparent comes out the other side with its
  // trace identity intact and a fresh span id (§3.4).
  const hop = serverHop({ traceparent: KNOWN_HEADER }, FIXED_SPAN);

  assert.equal(hop.traceId, KNOWN_TRACE);
  assert.ok(hop.continued, "a valid inbound traceparent must be continued, not restarted");
  assert.equal(hop.spanId, FIXED_SPAN);
  assert.notEqual(hop.spanId, KNOWN_PARENT, "span id must not be the inbound parent-id");
  assert.ok(hop.sampled, "sampled flag (§3.2.2.5.1) must survive the hop");

  const out = hop.outboundHeaders;
  const parsed = parseTraceparent(out.traceparent);
  assert.ok(parsed, `outbound traceparent ${out.traceparent} did not parse`);
  assert.equal(parsed.traceId, KNOWN_TRACE);
  assert.equal(parsed.parentId, FIXED_SPAN, "outbound parent-id is this hop's span id");
  assert.ok(parsed.sampled, "outbound trace-flags lost the sampled bit");
  assert.equal(parsed.version, 0, "we emit the version we implement");
});

test("unsampled flag is preserved", () => {
  // §3.2.2.5.1: sampled is a recommendation, not a rule.
  const hop = serverHop({ traceparent: `00-${KNOWN_TRACE}-${KNOWN_PARENT}-00` }, FIXED_SPAN);

  assert.equal(hop.sampled, false, "sampled flag must not be invented on an unsampled trace");
  assert.equal(hop.traceId, KNOWN_TRACE);
  assert.ok(hop.outboundHeaders.traceparent.endsWith("-00"));
});

test("second hop keeps the same trace-id", () => {
  // Three services, one trace: hop N+1 keeps the trace-id hop N produced.
  const first = serverHop({ traceparent: KNOWN_HEADER }, "2222222222222222");
  const second = serverHop(first.outboundHeaders, "3333333333333333");

  assert.equal(second.traceId, KNOWN_TRACE, "trace broken across hops");
  assert.ok(second.continued, "a traceparent this service just emitted must parse on the way back in");
});

test("malformed traceparent starts a new trace", () => {
  // Every one of these is garbage a proxy, a client library, or an attacker will
  // eventually send: start a new trace, silently, without throwing.
  for (const [name, value] of Object.entries(BAD_HEADERS)) {
    const hop = serverHop({ traceparent: value }, FIXED_SPAN);

    assert.equal(hop.continued, false, `${name}: ${value} was accepted as a valid traceparent`);
    assert.notEqual(hop.traceId, KNOWN_TRACE, `${name}: an invalid traceparent contributed its trace-id`);
    assert.equal(hop.traceId.length, 32);
    assert.notEqual(hop.traceId, "0".repeat(32), `${name}: trace-id must not be all zeroes (§3.2.2.3)`);
    assert.ok(parseTraceparent(hop.outboundHeaders.traceparent), `${name}: the restarted trace must be valid`);
  }
});

test("missing traceparent starts a new trace", () => {
  // §4.2
  const hop = serverHop({}, FIXED_SPAN);

  assert.equal(hop.continued, false);
  assert.equal(hop.traceId.length, 32);
  assert.notEqual(hop.traceId, "0".repeat(32));
  assert.equal(hop.sampled, false, "a trace this service started defaults to not-sampled (§3.2.2.5.1)");
});

test("tracestate is forwarded", () => {
  // §3.3: tracestate is opaque to us and MUST travel with the trace.
  const hop = serverHop({ traceparent: KNOWN_HEADER, tracestate: "congo=t61rcWkgMzE" }, FIXED_SPAN);
  assert.equal(hop.outboundHeaders.tracestate, "congo=t61rcWkgMzE");
});

test("tracestate is truncated at whole entries", () => {
  // §3.3.1.5: propagate at least 512 characters, truncating whole entries.
  const entries = Array.from({ length: 60 }, (_, i) => `v${String(i).padStart(2, "0")}=${"x".repeat(30)}`);
  const long = entries.join(",");

  const out = serverHop({ traceparent: KNOWN_HEADER, tracestate: long }, FIXED_SPAN).outboundHeaders.tracestate;

  assert.ok(out.length <= 512, `tracestate is ${out.length} characters; §3.3.1.5 caps at 512`);
  assert.notEqual(out, "", "truncating dropped the whole header");
  for (const entry of out.split(",")) {
    assert.ok(long.includes(entry), `entry ${entry} was truncated mid-entry, which §3.3.1.5 forbids`);
  }
  assert.ok(out.startsWith(entries[0]), "§3.3.1.5 drops entries from the end");
});

test("oversized tracestate entries are removed first", () => {
  // §3.3.1.5: "Entries larger than 128 characters long SHOULD be removed first."
  const out = serverHop(
    { traceparent: KNOWN_HEADER, tracestate: `huge=${"y".repeat(200)},small=1` },
    FIXED_SPAN,
  ).outboundHeaders.tracestate;

  assert.ok(!out.includes("huge="), "an entry over 128 characters is removed first");
  assert.equal(out, "small=1");
});

test("tracestate without a valid traceparent is discarded", () => {
  // §3.3 and §4.2: forwarding it would attach vendor state to an unrelated trace.
  for (const value of ["", "not-a-traceparent"]) {
    const hop = serverHop({ traceparent: value, tracestate: "congo=t61rcWkgMzE" }, FIXED_SPAN);
    assert.ok(
      !("tracestate" in hop.outboundHeaders),
      `tracestate must be discarded when traceparent is ${JSON.stringify(value)}`,
    );
  }
});

test("header names are case-insensitive and sent lowercase", () => {
  // §3.2.1: accept the header name in any case, send it lowercase.
  for (const name of ["traceparent", "TraceParent", "TRACEPARENT", "Traceparent"]) {
    const hop = serverHop({ [name]: KNOWN_HEADER }, FIXED_SPAN);
    assert.equal(hop.traceId, KNOWN_TRACE, `header ${name} was not recognised`);
  }

  const out = serverHop({ TraceParent: KNOWN_HEADER }, FIXED_SPAN).outboundHeaders;
  for (const name of Object.keys(out)) {
    assert.equal(name, name.toLowerCase(), `§3.2.1: send ${name} lowercase`);
  }
});

test("higher version is downgraded and unknown fields are not forwarded", () => {
  // §3.2.4: parse positionally, then re-emit at version 00 without the unknown
  // fields.
  const future = `cc-${KNOWN_TRACE}-${KNOWN_PARENT}-01-what-the-future-wants`;

  const parsed = parseTraceparent(future);
  assert.ok(parsed, "a well-formed higher version must be parsed per §3.2.4");
  assert.equal(parsed.version, 0xcc);
  assert.equal(parsed.traceId, KNOWN_TRACE);
  assert.equal(parsed.parentId, KNOWN_PARENT);

  const out = serverHop({ traceparent: future }, FIXED_SPAN).outboundHeaders.traceparent;
  assert.ok(out.startsWith("00-"), `outbound ${out} must be downgraded to version 00`);
  assert.ok(!out.includes("what-the-future-wants"), "§3.2.4: MUST NOT forward unknown fields");
});

test("trace-flags are a bit field", () => {
  // §3.2.2.5: mask on read, rebuild on write; §3.2.2.5.2: reserved bits zero.
  const hop = serverHop({ traceparent: `00-${KNOWN_TRACE}-${KNOWN_PARENT}-03` }, FIXED_SPAN);

  assert.ok(hop.sampled, "bit 0 set means sampled; reading flags as a number is the classic bug");
  assert.ok(
    hop.outboundHeaders.traceparent.endsWith("-01"),
    "reserved bits must be zeroed on the way out (§3.2.2.5.2)",
  );
});

test("new identifiers are random and never all zero", () => {
  // §8: 16 and 8 random bytes, never all zeroes, never repeated.
  const seen = new Set();
  for (let i = 0; i < 256; i += 1) {
    const traceId = newTraceId();
    assert.equal(traceId.length, 32);
    assert.notEqual(traceId, "0".repeat(32));
    assert.ok(!seen.has(traceId), `newTraceId repeated ${traceId} within 256 draws (§8.2)`);
    seen.add(traceId);

    assert.equal(newSpanId().length, 16);
  }
});
