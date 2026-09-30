# OTel dependency pins

Versions referenced by the `*.snippet` files. kit does **not** vendor any of
these and does not depend on any of them — the snippets are documentation you
copy, and the `traceparent.*` files beside them are stdlib-only so the
conformance suite runs with no network and no lockfile.

## Why a pins file at all

A version in a comment rots. A version in a file with a check on it does not.
This file exists so that:

1. Every snippet's `go get` / `bun add` / `bundle add` / `mix deps.get` /
   `pip install` / `cargo add` line states a **concrete** version, so a reader
   copying it gets something that resolves rather than a floating major that
   moved three minors ago.
2. `tests/validate.sh` asserts those lines still parse and still name all six
   languages, so deleting a snippet's install block fails the gate instead of
   quietly shipping a template that cannot be installed.

## The versions

| Language | Packages | Version |
|----------|----------|---------|
| go | `go.opentelemetry.io/otel`, `.../sdk` | 1.34.0 |
| go | `.../exporters/otlp/otlptrace/otlptracegrpc` | 1.34.0 |
| go | `go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp` | 0.59.0 |
| ruby | `opentelemetry-sdk`, `opentelemetry-exporter-otlp` | 1.5.0 |
| ruby | `opentelemetry-instrumentation-rails` | 0.34.0 |
| elixir | `:opentelemetry`, `:opentelemetry_exporter` | 1.5.0 |
| elixir | `:opentelemetry_phoenix`, `:opentelemetry_bandit` | 0.3.0 / 0.6.0 |
| rust | `opentelemetry`, `opentelemetry_sdk`, `opentelemetry-otlp` | 0.27.0 |
| rust | `opentelemetry-semantic-conventions` | 0.27.0 |
| python | `opentelemetry-api`, `opentelemetry-sdk` | 1.30.0 |
| python | `opentelemetry-instrumentation-fastapi` | 0.51b0 |
| python | `opentelemetry-exporter-otlp-proto-grpc` | 1.30.0 |
| node / bun | `@opentelemetry/api`, `@opentelemetry/sdk-trace-base` | 2.0.0 |
| node / bun | `@opentelemetry/exporter-trace-otlp-proto` | 0.57.0 |
| node / bun | `@opentelemetry/core`, `@opentelemetry/sdk-trace-node` | 2.0.0 / 0.57.0 |

## These are placeholders, on purpose

Same rule as `templates/mise.toml`: **a service pins to the version it
deploys.** When you copy a snippet into your repo, raise these to the current
release in the language's own ecosystem and record the choice in your
`CHANGELOG.md`. A version that is right for every cafaye service is a version
that is right for none of them a year from now.

What is *not* a placeholder is the rule each version encodes:

- **`@opentelemetry/api` before `@opentelemetry/sdk-*`.** The api package is the
  version floor; an sdk newer than its api is a build that compiles and then
  fails to record spans at runtime.
- **`instrumentation-*` tracks the sdk minor.** A `0.51b0` instrumentation
  against a `1.53` sdk is a silently-uninstrumented app, not a build error.
- **Batch processors, never simple ones, in any production path.** One export
  per span makes the collector the bottleneck and drops spans on a slow
  network.

## What the gate checks

`tests/validate.sh` asserts, for every language directory:

- the `*.snippet` file exists (artifact presence),
- it contains at least one install line naming a version — a snippet with no
  `go get` / `bun add` / etc. is a snippet nobody can install, and
- it never contains a floating `@latest` or a bare `^`/`~` with no version.

A vendored OTel tree would be caught by the existing "no third-party
dependency" check on `templates/otel/go/go.mod` and `templates/otel/node/`.
