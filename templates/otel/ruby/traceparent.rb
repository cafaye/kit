# frozen_string_literal: true

# kit template — W3C Trace Context propagation for a Rails service.
#
# Copy traceparent.rb and test_traceparent.rb into your service. For inbound
# requests, rack_middleware.rb.snippet wires this into a Rails controller
# around_action; keep the test suite either way.
#
# The upstream OTel SDK does this for you — see rack_middleware.rb.snippet for
# the versioned wiring. Use this file when you need the header handling on its
# own: a webhook signer, a Sidekiq job that talks to another service, or a test
# that asserts propagation without standing up an SDK.
#
# REFERENCE: W3C Trace Context, W3C Recommendation 23 November 2021
# https://www.w3.org/TR/trace-context/
#
# IMPLEMENTED SECTIONS (every one is asserted in test_traceparent.rb)
#   3.2.1     header name: accept any case, send lowercase
#   3.2.2.1   version is 2 hex chars; ff is forbidden
#   3.2.2.2   version-format for version 00
#   3.2.2.3   invalid trace-id -> ignore the traceparent (all zeroes forbidden)
#   3.2.2.4   invalid parent-id -> ignore the traceparent (all zeroes forbidden)
#   3.2.2.5   trace-flags is a bit field; mask on read
#   3.2.2.5.1 the sampled flag is the only flag in version 00
#   3.2.2.5.2 reserved flags MUST be set to zero on the wire
#   3.2.4     higher version: parse positionally, re-emit at 00, drop unknowns
#   3.3       a failed traceparent MUST NOT be rescued by a tracestate
#   3.3.1.5   tracestate: propagate >=512 chars, truncate whole entries only
#   4.2/4.3   no traceparent -> new trace; invalid -> restart, never an error
#
# NO DEPENDENCIES. Stdlib only, so this file drops into any Rails service and
# the test suite runs without `bundle install`.

require "securerandom"

module KitOtel
  # Bit 0 of trace-flags (3.2.2.5.1). It is a bit in a field, not the field's
  # value: reading `flags == 1` instead of `flags & 1 == 1` is the single most
  # common trace-context bug, and it is why this is a named constant.
  SAMPLED = 0x01

  # A traceparent is exactly 55 characters: 2 version, 32 trace-id, 16
  # parent-id, 2 trace-flags, and 3 dashes (3.2.2.2).
  MIN_HEADER_LEN = 55

  # 3.3.1.5: "Vendors SHOULD propagate at least 512 characters of a combined
  # header." Bigger than this and we truncate whole entries.
  TRACESTATE_LIMIT = 512

  # 3.3.1.5: "Entries larger than 128 characters long SHOULD be removed first."
  TRACESTATE_ENTRY_LIMIT = 128

  ZERO_TRACE_ID = "0" * 32
  ZERO_SPAN_ID = "0" * 16

  # A parsed `traceparent` header.
  #
  # +version+ is the raw version byte. Zero for version "00", the only version
  # we emit; a higher version is parsed (3.2.4) and then downgraded.
  # +extra+ is everything after the flags field on a higher-version header.
  # Retained for logging only: 3.2.4 says vendors MUST NOT forward unknown
  # fields, and #outbound_headers does not.
  TraceParent = Struct.new(:version, :trace_id, :parent_id, :flags, :extra) do
    # The caller's recording decision (3.2.2.5.1). We carry this rather than
    # making our own: a service that re-decides sampling per hop produces traces
    # with holes in them, which are worse than no traces.
    #
    # Named `sampled` with a `sampled?` alias so the predicate reads the same
    # here as in the other five templates — a cross-language suite that has to
    # remember which language suffixes its booleans is a suite nobody maintains.
    def sampled
      (flags & SAMPLED) == SAMPLED
    end
    alias sampled? sampled
  end

  # One service's continuation of a trace: what we tell our caller about the
  # request we handled, and what we put on the wire to the next hop.
  #
  # +continued+ is not a debug field: a span exporter needs to know whether this
  # is a root span in order to label it correctly.
  ServerHop = Struct.new(:trace_id, :span_id, :flags, :tracestate, :continued) do
    def sampled
      (flags & SAMPLED) == SAMPLED
    end
    alias sampled? sampled

    # The shape is fixed by 3.4: parent-id becomes this hop's span id, and the
    # version is downgraded to the one we implement. Those two mutations plus
    # the sampled flag are the entire allowed set.
    def outbound_headers
      out = { "traceparent" => KitOtel.format_traceparent(trace_id, span_id, flags) }
      out["tracestate"] = tracestate unless tracestate.to_s.empty?
      out
    end
  end

  class << self
    # Parse a `traceparent` header value.
    #
    # Returns nil for anything invalid, and that is the whole contract:
    # 3.2.2.3 and 3.2.2.4 say a vendor MUST ignore the header when trace-id or
    # parent-id is invalid, and 3.2.4 says to restart the trace when the version
    # cannot be parsed. There is no error to handle and no value to partially
    # trust.
    def parse_traceparent(value)
      return nil if value.nil?

      raw = value.to_s
      # A short header cannot hold the four fields, whatever the version.
      return nil if raw.length < MIN_HEADER_LEN

      # 3.2.4: "When the version prefix cannot be parsed (it's not 2 hex
      # characters followed by a dash), the implementation should restart the
      # trace." Checked before anything else, so a malformed version is never
      # mistaken for a valid one.
      return nil unless raw[2] == "-" && lowercase_hex?(raw[0, 2])

      version = raw[0, 2].to_i(16)
      # 3.2.2.1: "Version ff is invalid."
      return nil if version == 0xFF

      trace_id = raw[3, 32]
      parent_id = raw[36, 16]
      flags_field = raw[53, 2]

      # The three fixed positions, all three mandatory (3.2.4).
      return nil unless raw[35] == "-" && raw[52] == "-"
      return nil unless lowercase_hex?(trace_id) && lowercase_hex?(parent_id) && lowercase_hex?(flags_field)

      if version.zero?
        # 3.2.2.2 defines version 00 as exactly these four fields. Trailing data
        # means the sender is not speaking version 00, and accepting it would be
        # inventing a format the spec does not define.
        return nil unless raw.length == MIN_HEADER_LEN
      elsif raw.length > MIN_HEADER_LEN
        # 3.2.4: on a higher version the two flag characters are followed by
        # either the end of the header or a dash introducing an unknown field.
        return nil unless raw[MIN_HEADER_LEN] == "-"
      end

      # 3.2.2.3 and 3.2.2.4: all zeroes is an invalid value for both, and the
      # required response is to ignore the header.
      return nil if trace_id == ZERO_TRACE_ID || parent_id == ZERO_SPAN_ID

      TraceParent.new(version, trace_id, parent_id, flags_field.to_i(16), raw[(MIN_HEADER_LEN + 1)..].to_s)
    end

    # Continue the trace described by the inbound headers.
    #
    # This is the one function a service's middleware calls. It cannot fail: a
    # malformed or absent traceparent yields a new trace, because a request is
    # not an error because its trace header was garbage (4.2, 3.2.2.3).
    #
    # +span_id+ is a parameter rather than generated here so the caller owns the
    # span lifecycle — in a service it comes from the tracer, in a test it is a
    # constant, which is why the suite can assert equality instead of a shape.
    def server_hop(headers, span_id)
      tp = parse_traceparent(header(headers, "traceparent"))

      if tp.nil?
        # 3.3: "If the vendor failed to parse traceparent, it MUST NOT attempt to
        # parse tracestate." 4.2 makes it explicit for the no-traceparent case:
        # a tracestate alone "is invalid and MUST be discarded". Forwarding it
        # would attach a vendor's state to an unrelated trace.
        return ServerHop.new(new_trace_id, span_id, 0, nil, false)
      end

      ServerHop.new(
        tp.trace_id,
        span_id,
        # 3.2.2.5: a bit field, so mask on read rather than carry the bytes
        # through. 3.2.2.5.2 requires the reserved bits to be zero outbound.
        tp.flags & SAMPLED,
        forward_tracestate(header(headers, "tracestate")),
        true,
      )
    end

    # Build a traceparent at version 00.
    #
    # Always version 00, always lowercase hex, always exactly 55 characters
    # (3.2.2.2). It takes no version parameter on purpose: a service speaks one
    # version, and a caller that could pass any version would eventually pass a
    # wrong one.
    def format_traceparent(trace_id, parent_id, flags)
      format("00-%s-%s-%02x", trace_id, parent_id, flags & 0xFF)
    end

    # Apply the 3.3.1.5 limits to an inbound tracestate.
    #
    # The order matters and is the order the spec states: oversized entries go
    # first (they are the expensive ones and the least likely to be a
    # well-known vendor key), then entries are dropped from the end. Dropping
    # from the front would discard the most recent vendor's entry, which is the
    # one that just wrote it and the one that knows where the trace currently is.
    def forward_tracestate(value)
      return nil if value.nil? || value.empty?

      entries = value.split(",", -1).filter_map do |raw|
        entry = raw.strip
        # 3.3.1.1: "Empty and whitespace-only list members are allowed."
        next if entry.empty?

        entry.length > TRACESTATE_ENTRY_LIMIT ? nil : entry
      end

      # Pop from the end until the combined value fits (3.3.1.5).
      entries.pop while entries.length.positive? && entries.join(",").length > TRACESTATE_LIMIT

      entries.empty? ? nil : entries.join(",")
    end

    # Look a header up case-insensitively.
    #
    # 3.2.1: "Vendors MUST expect the header name in any case (upper, lower,
    # mixed)". Rack gives us Title-Case, but a test, a proxy, or a middleware
    # that copies raw keys will not, and being strict here breaks traces in
    # production for no reason.
    def header(headers, name)
      return nil unless headers.respond_to?(:each_pair)

      pair = headers.find { |key, _| key.to_s.casecmp?(name) }
      pair&.last
    end

    # A fresh 16-byte trace identifier as 32 hex characters.
    #
    # 8: 16 bytes from a cryptographically secure source, never all zeroes.
    def new_trace_id
      random_hex(16)
    end

    # A fresh 8-byte span identifier as 16 hex characters.
    #
    # 8. On all-zero failure it returns a fixed non-zero constant rather than
    # raising: an exhausted entropy source is not a reason to take the service
    # down, and 3.2.2.4 only requires that the value is not all zeroes. The
    # collision risk is theoretical; the availability risk is not.
    def new_span_id
      id = random_hex(8)
      id == ZERO_SPAN_ID ? "0000000000000001" : id
    end

    private

    # Whether +str+ is entirely lowercase hex. 3.2.2 defines the alphabet as
    # HEXDIGLC, lowercase only. Uppercase is rejected rather than folded:
    # accepting it means two services disagree about whether a header is valid,
    # and one of them starts a new trace.
    def lowercase_hex?(str)
      !str.empty? && str.match?(/\A[0-9a-f]+\z/)
    end

    # +n+ bytes from SecureRandom as lowercase hex.
    #
    # SecureRandom rather than Random: trace ids end up in logs and in traces
    # that leave the process, and a predictable trace id is an invitation to
    # correlate two users' requests by guessing.
    def random_hex(n)
      SecureRandom.hex(n)
    end
  end
end
