// kit template — W3C Trace Context propagation for a Rust service.
//
// Copy traceparent.rs into your service (`src/telemetry/`), then
// `cargo test --lib`. The suite below lives in the same file because that is
// where Rust puts unit tests, so the template is one file a service can paste.
//
// REFERENCE: W3C Trace Context, W3C Recommendation 23 November 2021
// https://www.w3.org/TR/trace-context/ — every rule asserted below cites the
// section that requires it.
//
// WHAT IT PROMISES
//   - A valid inbound traceparent is continued: same trace-id, sampled flag
//     preserved, parent-id replaced with this hop's span id (§3.4).
//   - A missing or malformed traceparent starts a new trace and never panics. A
//     request is not a 500 because its trace header was garbage.
//   - tracestate travels with the trace, capped at 512 characters and truncated
//     on whole-entry boundaries (§3.3.1.5).
//
// No dependencies: everything below is std. `tracing-opentelemetry` and
// `opentelemetry-otlp` are referenced by version in otel_client.rs.snippet, not
// imported here — kit has no dependencies and this module must not grow one.

use std::collections::BTreeMap;

const KNOWN_HEADER: &str = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";
const KNOWN_TRACE: &str = "4bf92f3577b34da6a3ce929d0e0e4736";
const KNOWN_PARENT: &str = "00f067aa0ba902b7";
// Fixed so every assertion below is an equality, not a shape check.
const FIXED_SPAN: &str = "1111111111111111";

fn headers(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

#[test]
fn known_traceparent_is_continued() {
    // The headline promise: a known traceparent comes out the other side with
    // its trace identity intact and a fresh span id (§3.4).
    let hop = server_hop(&headers(&[("traceparent", KNOWN_HEADER)]), FIXED_SPAN);

    assert_eq!(hop.trace_id, KNOWN_TRACE);
    assert!(hop.continued, "a valid inbound traceparent must be continued");
    assert_eq!(hop.span_id, FIXED_SPAN);
    assert_ne!(hop.span_id, KNOWN_PARENT, "span id must not be the inbound parent-id");
    assert!(hop.sampled, "sampled flag (§3.2.2.5.1) must survive the hop");

    let out = hop.outbound_headers();
    let tp = parse_traceparent(out.get("traceparent").map(String::as_str))
        .expect("outbound traceparent must parse");
    assert_eq!(tp.trace_id, KNOWN_TRACE);
    assert_eq!(tp.parent_id, FIXED_SPAN, "outbound parent-id is this hop's span id");
    assert!(tp.sampled, "outbound trace-flags lost the sampled bit");
    assert_eq!(tp.version, 0, "we emit the version we implement");
}

#[test]
fn unsampled_flag_is_preserved() {
    // §3.2.2.5.1: sampled is a recommendation, not a rule.
    let unsampled = format!("00-{KNOWN_TRACE}-{KNOWN_PARENT}-00");
    let hop = server_hop(&headers(&[("traceparent", &unsampled)]), FIXED_SPAN);

    assert!(!hop.sampled, "sampled flag must not be invented on an unsampled trace");
    assert_eq!(hop.trace_id, KNOWN_TRACE);
    let out = hop.outbound_headers();
    assert!(out["traceparent"].ends_with("-00"), "outbound must end in -00");
}

#[test]
fn second_hop_keeps_the_same_trace_id() {
    // Three services, one trace: hop N+1 keeps the trace-id hop N produced.
    let first = server_hop(&headers(&[("traceparent", KNOWN_HEADER)]), "2222222222222222");
    let second = server_hop(&first.outbound_headers(), "3333333333333333");

    assert_eq!(second.trace_id, KNOWN_TRACE, "trace broken across hops");
    assert!(second.continued, "a traceparent we just emitted must parse again");
}

#[test]
fn malformed_traceparent_starts_a_new_trace() {
    // Every one of these is garbage a proxy, a client library, or an attacker
    // will eventually send: start a new trace, silently, without panicking.
    let bad: Vec<(&str, String)> = vec![
        ("empty", String::new()),
        ("not a header", "garbage".to_string()),
        ("truncated at 54", format!("00-{KNOWN_TRACE}-{KNOWN_PARENT}")),
        ("version 00 plus junk", format!("{KNOWN_HEADER}-extra")),
        ("all-zero trace-id", format!("00-{}-{KNOWN_PARENT}-01", "0".repeat(32))),
        ("all-zero parent-id", format!("00-{KNOWN_TRACE}-{}-01", "0".repeat(16))),
        (
            "uppercase hex",
            format!("00-4BF92F3577B34DA6A3CE929D0E0E4736-{KNOWN_PARENT}-01"),
        ),
        ("forbidden version ff", format!("ff-{KNOWN_TRACE}-{KNOWN_PARENT}-01")),
        ("one-char version", format!("0-{KNOWN_TRACE}-{KNOWN_PARENT}-01")),
        ("wrong delimiters", format!("00_{KNOWN_TRACE}_{KNOWN_PARENT}_01")),
        ("non-hex flags", format!("00-{KNOWN_TRACE}-{KNOWN_PARENT}-0g")),
    ];

    for (name, value) in &bad {
        let hop = server_hop(&headers(&[("traceparent", value.as_str())]), FIXED_SPAN);

        assert!(!hop.continued, "{name}: {value} was accepted as a valid traceparent");
        assert_ne!(hop.trace_id, KNOWN_TRACE, "{name}: an invalid traceparent contributed its trace-id");
        assert_eq!(hop.trace_id.len(), 32, "{name}");
        assert_ne!(hop.trace_id, "0".repeat(32), "{name}: trace-id must not be all zeroes (§3.2.2.3)");
        let out = hop.outbound_headers();
        assert!(
            parse_traceparent(out.get("traceparent").map(String::as_str)).is_some(),
            "{name}: the restarted trace must be valid on the way out"
        );
    }
}

#[test]
fn missing_traceparent_starts_a_new_trace() {
    // §4.2
    let hop = server_hop(&headers(&[]), FIXED_SPAN);

    assert!(!hop.continued);
    assert_eq!(hop.trace_id.len(), 32);
    assert_ne!(hop.trace_id, "0".repeat(32));
    assert!(!hop.sampled, "a trace we started defaults to not-sampled (§3.2.2.5.1)");
}

#[test]
fn tracestate_is_forwarded() {
    // §3.3: tracestate is opaque to us and MUST travel with the trace.
    let hop = server_hop(
        &headers(&[
            ("traceparent", KNOWN_HEADER),
            ("tracestate", "congo=t61rcWkgMzE"),
        ]),
        FIXED_SPAN,
    );

    assert_eq!(hop.outbound_headers()["tracestate"], "congo=t61rcWkgMzE");
}

#[test]
fn tracestate_is_truncated_at_whole_entries() {
    // §3.3.1.5: propagate at least 512 characters, truncating whole entries.
    let entries: Vec<String> = (0..60)
        .map(|i| format!("v{:02}={}", i, "x".repeat(30)))
        .collect();
    let long = entries.join(",");

    let hop = server_hop(
        &headers(&[
            ("traceparent", KNOWN_HEADER),
            ("tracestate", long.as_str()),
        ]),
        FIXED_SPAN,
    );
    let out = hop.outbound_headers();
    let out = out.get("tracestate").expect("tracestate survives").clone();

    assert!(out.len() <= 512, "§3.3.1.5 caps a combined header at 512, got {}", out.len());
    assert!(!out.is_empty(), "truncating dropped the whole header");
    for entry in out.split(',') {
        assert!(long.contains(entry), "entry {entry} was truncated mid-entry");
    }
    assert!(out.starts_with(&entries[0]), "§3.3.1.5 drops entries from the end");
}

#[test]
fn oversized_tracestate_entries_are_removed_first() {
    // §3.3.1.5: "Entries larger than 128 characters long SHOULD be removed first."
    let oversized = format!("huge={}", "y".repeat(200));
    let joined = format!("{oversized},small=1");
    let hop = server_hop(
        &headers(&[
            ("traceparent", KNOWN_HEADER),
            ("tracestate", joined.as_str()),
        ]),
        FIXED_SPAN,
    );
    let out = hop.outbound_headers();
    let out = out.get("tracestate").expect("tracestate survives").clone();

    assert!(!out.contains("huge="), "an entry over 128 characters is removed first");
    assert_eq!(out, "small=1");
}

#[test]
fn tracestate_without_a_valid_traceparent_is_discarded() {
    // §3.3 and §4.2: forwarding it would attach vendor state to an unrelated
    // trace.
    for value in ["", "not-a-traceparent"] {
        let hop = server_hop(
            &headers(&[
                ("traceparent", value),
                ("tracestate", "congo=t61rcWkgMzE"),
            ]),
            FIXED_SPAN,
        );

        assert!(
            !hop.outbound_headers().contains_key("tracestate"),
            "tracestate must be discarded when traceparent is {value:?}"
        );
    }
}

#[test]
fn header_names_are_case_insensitive_and_sent_lowercase() {
    // §3.2.1: accept the header name in any case, send it lowercase.
    for name in ["traceparent", "TraceParent", "TRACEPARENT", "Traceparent"] {
        let hop = server_hop(&headers(&[(name, KNOWN_HEADER)]), FIXED_SPAN);
        assert_eq!(hop.trace_id, KNOWN_TRACE, "header {name} was not recognised");
    }

    let out = server_hop(&headers(&[("TraceParent", KNOWN_HEADER)]), FIXED_SPAN).outbound_headers();
    for name in out.keys() {
        assert_eq!(name, &name.to_lowercase(), "§3.2.1: send the header name lowercase");
    }
}

#[test]
fn higher_version_is_downgraded_and_unknown_fields_are_not_forwarded() {
    // §3.2.4: parse positionally, then re-emit at version 00 without the unknown
    // fields.
    let future = format!("cc-{KNOWN_TRACE}-{KNOWN_PARENT}-01-what-the-future-wants");

    let tp = parse_traceparent(Some(future.as_str())).expect("a well-formed higher version parses per §3.2.4");
    assert_eq!(tp.version, 0xcc);
    assert_eq!(tp.trace_id, KNOWN_TRACE);
    assert_eq!(tp.parent_id, KNOWN_PARENT);

    let hop = server_hop(&headers(&[("traceparent", future.as_str())]), FIXED_SPAN);
    let out = hop.outbound_headers();
    let out = out.get("traceparent").expect("traceparent").clone();

    assert!(out.starts_with("00-"), "outbound {out} must be downgraded to version 00");
    assert!(
        !out.contains("what-the-future-wants"),
        "§3.2.4: MUST NOT forward unknown fields"
    );
}

#[test]
fn trace_flags_are_a_bit_field() {
    // §3.2.2.5: mask on read, rebuild on write; §3.2.2.5.2: reserved bits zero.
    let both = format!("00-{KNOWN_TRACE}-{KNOWN_PARENT}-03");
    let hop = server_hop(&headers(&[("traceparent", both.as_str())]), FIXED_SPAN);

    assert!(hop.sampled, "bit 0 set means sampled; reading flags as a number is the classic bug");
    let out = hop.outbound_headers();
    assert!(
        out["traceparent"].ends_with("-01"),
        "reserved bits must be zeroed on the way out (§3.2.2.5.2)"
    );
}

#[test]
fn new_identifiers_are_random_and_never_all_zero() {
    // §8: 16 and 8 random bytes, never all zeroes, never repeated.
    let mut seen = std::collections::HashSet::new();
    for _ in 0..256 {
        let trace_id = new_trace_id();
        assert_eq!(trace_id.len(), 32);
        assert_ne!(trace_id, "0".repeat(32));
        assert!(seen.insert(trace_id.clone()), "new_trace_id repeated {trace_id} in 256 draws (§8.2)");

        assert_eq!(new_span_id().len(), 16);
    }
}
