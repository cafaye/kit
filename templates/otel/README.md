"""kit template — W3C traceparent, per language.

WHAT THIS IS
  Two implementations, same contract, one per language:

    1. The stdlib codec (`traceparent.*`). Zero dependencies, runs offline,
       ~13 assertions against the W3C Trace Context spec. This is what the
       conformance suite in `tests/validate.sh` executes. Use it when you need
       the header handling on its own — a queue consumer, a webhook signer, a
       Celery task, a PubSub subscriber, a test asserting propagation without
       standing up an SDK.

    2. The SDK wiring (`*.snippet`). The upstream OpenTelemetry SDK already
       implements all of this and additionally gives you spans, metrics, and a
       trace UI. Use this for anything serving HTTP. Versions are referenced in
       `pins.md`; kit vendors nothing and depends on nothing.

  Both are in every language directory. The choice is which one you want, not
  whether propagation is available.

THE CONTRACT (identical in all six languages)
  - A valid inbound `traceparent` is CONTINUED: same trace-id, sampled flag
    preserved, parent-id replaced with this hop's span id (§3.4).
  - A missing or malformed `traceparent` starts a NEW trace and never throws,
    never returns 4xx, never panics. A request is not an error because its
    trace header was garbage (§3.2.2.3, §4.2).
  - `tracestate` travels with the trace, capped at 512 chars, truncated on
    whole-entry boundaries only (§3.3.1.5).
  - A `traceparent` that fails to parse is NOT rescued by a `tracestate`
    alongside it (§3.3) — a tracestate alone is invalid and discarded (§4.2).
  - Header NAMES are matched case-insensitively and always SENT lowercase
    (§3.2.1).

WHY SIX IMPLEMENTATIONS OF ONE ALGORITHM
  Because a service cannot import another language's codec, and because a
  shared HTTP shim is a network hop in the request path. Six copies of the
  same 13 rules is cheaper than a service that cannot propagate traces. The
  cost is drift, and drift is what the conformance suite is for: all six are
  asserted against the same spec sections, so a rule that one language drops
  and the others keep is a red build rather than a broken trace in production.

REFERENCE
  W3C Trace Context, W3C Recommendation 23 November 2021
  https://www.w3.org/TR/trace-context/

LAYOUT
  <lang>/traceparent.*        the codec, stdlib only
  <lang>/test_traceparent.*   its suite — COPY THIS WITH THE CODEC, ALWAYS
  <lang>/*.snippet            SDK wiring, versioned against pins.md
  <lang>/README.md            when to use which, and the wiring
  pins.md                     the OTel versions the snippets reference

LAYOUT OF THE SUITES
  Five languages carry a separate test file. Rust does not: `rustc --test`
  builds one crate from one source, so its `mod tests` is inline. The gate
  asserts the suite exists either way.

RUNNING ONE
  bash tests/validate.sh --language=go
  bash tests/validate.sh --static-only     # no toolchains needed

OPTING IN TO CI
  Copy `templates/otel/<lang>/` into your service and call kit's reusable
  workflow with `telemetry: 'true'`. It is opt-in so that adopting kit never
  turns a green repo red; once on, the suite runs on every push and a broken
  codec is a red build, not a paragraph in a README.
"""
