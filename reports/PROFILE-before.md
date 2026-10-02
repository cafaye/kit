# PROFILE — kit's full gate, BEFORE any speed work

Produced by `KIT_PROFILE=… bash tests/validate.sh` and rendered by
`tests/profile_report.py`. Raw rows: `reports/profile-before.tsv`.

**The run was stopped at breakage 8 of 94 by this packet's hour, not by the
gate.** The gate was in the self-test phase; the numbers below are what it had
actually measured when it was stopped, and nothing here is extrapolated into a
row. `self_test` is a bounded tier, so the stop is the run's own reporting
shape, not a hidden failure.

| what | seconds | share |
| --- | --- | --- |
| the gate's own phases (38 rows, non-overlapping) | **225.9** | the whole top-level run before self_test |
| the self-test's first 4 gate copies | **206.6** | 51.6s each |
| **the five observability tiers** (canary 18.6 + collector-killed 64.1 + stack-live 44.2 + isolation 32.3 + tenancy 1.9) | **161.1** | **71% of the gate's own time** |

## The headline: it is not one slow check, it is ~23,000 fast ones

Five breakages wrote **1,235 timed rows** — 247 per copy. Extrapolated to 94
breakages that is **~23,000 timed commands in the self-test phase alone**, and
the gate's own 264 rows are a rounding error beside it. The shape is the
opposite of the usual one: nothing is slow, everything is run once per copy.

**And the eight breakages that cost the most are the eight that ask the
least.** Breakages 1, 2, 2b, 3, 4, 5, 6 use plain `expect_red … --static-only`,
which passes **no `--only` filter**, so each runs the entire static gate to
learn one fact: 48–56s each. Breakage 3 — which is `--only`-filtered and so
should be narrow — still costs 23.4s, and its own profile says why:

| inside ONE breakage-1 gate copy | seconds |
| --- | --- |
| `tests/fetch_test.sh` | 11.6 |
| `tests/multi_tenant_split_test.sh` | 11.6 |
| `tests/lint_test.sh` | 8.7 |
| `tests/staleness_test.sh` | 8.7 |
| `tests/classify_test.sh` | 1.4 |
| `tests/kamal_test.sh` | 4.6 |

Those six are **46 seconds of work none of the 8 was asking about.** They are
not in the static tier, they are not in the self-test tier, and they are not
guarded by `--static-only` — `fetch`, `tenancy`, `multi_tenant`, `classify` and
`lint` are deliberately outside the `RUN_STATIC` guard, because a gate that
skips is not green. That decision is right and this packet does not touch it.
What it costs is that `--only` cannot narrow them either, so the eight
unfiltered breakages pay all of it 8 times over.

   of which the self-test's 4 copies spent 206.6s in total, 51.6s each

== the GATE's phases, wall time (these do not overlap)  (38 timed rows)
  seconds  kind     label
---------  -------  --------------------------------------------------------------------
   161.15  phase    40 classifier + staleness + fetch + tenancy, executed
    17.11  phase    60 self_test: n whole gates, one per breakage
     9.49  phase    50 lint: the four linters, run against fixtures that must fail them
     6.80  phase    tenancy: how one shared cluster is split into per-service databases
     4.69  phase    staleness: the fleet reporter tells the states apart
     4.24  phase    static: the canary harness parses in Go
     3.29  phase    static: templates/otel — every artifact is present
     2.81  phase    telemetry: runtime credential-leak canary, executed
     2.27  phase    static: the canary harness — contract, adapter, and every artifact
     1.92  phase    fetch: the pinned kit ref resolves, and a moving one is refused
     1.91  phase    static: handed-out scripts are executable
     1.44  phase    static: every database snippet parses in its own language
     1.20  phase    static: every language declares a tier, and says how it is collected
     1.20  phase    static: secrets — the scanner is present, configured, and can fail
     1.16  phase    20 telemetry: the six traceparent suites, executed
     0.98  phase    static: the fleet adopts the stack rather than copying it
     0.80  phase    static: templates declare no third-party dependency
     0.60  phase    30 observability: the claims worth nothing unexercised
     0.58  phase    static: every Dockerfile runs non-root on a pinned base
     0.42  phase    static: compose — the observability chokepoint
     0.41  phase    static: every otel snippet parses in its own language
     0.27  phase    static: every YAML in the tree is yamllint clean
     0.25  phase    static: the core fan-out standard
     0.19  phase    static: lint runs from kit, not from a copy
     0.17  phase    static: templates/database/tenancy — every artifact is present
   ... 13 more rows; raise --top to see them.

== the GATE's own checks and bounded tiers (excludes the self-test's copies)  (226 timed rows)
  seconds  kind     label
---------  -------  ------------------------------------------------------------------------------
    64.06  tier     tests/no_telemetry_in_readiness.sh  (collector killed, service still serves)
    44.20  tier     tests/stack_live_test.sh  (the fetched stack runs; a trace and a metric land)
    32.27  tier     tests/isolation_test.sh  (service A cannot reach service B's database)
    18.58  tier     tests/canary_test.sh  (a canary secret reaches no exporter)
    17.07  check    tests/lint_test.sh  (every linter runs, and its control disagrees)
     9.46  check    tests/staleness_test.sh  (26 cases, incl. the red proof and the absent case)
     6.77  check    tests/fetch_test.sh  (a pin fetches, a branch is refused, offline is real)
     4.66  check    tests/multi_tenant_split_test.sh  (a second tenant is split, not fused; identi
     4.12  check    kamal_test — 24 case(s), every one against the real binaries.
     1.88  check    tests/classify_test.sh  (19 cases, incl. the fail-closed property)
     1.85  tier     tests/tenancy_test.sh  (no identity, another tenant and its own tenant — as th
     1.22  cpu      tests/validate.sh  (shellcheck -S warning)  (overlaps: sum is an upper bound)
     1.16  check    tests/gitleaks_gate.sh  (finds a real secret, never prints it, reads history)
     0.98  check    the canary suite  (never prints the value it planted)
     0.91  check    templates/otel/go  (go test suite)
     0.83  cpu      templates/tier/rust/tier.rs  (rustc --test)  (overlaps: sum is an upper bound)
     0.80  cpu      tests/self_test.sh  (shellcheck -S warning)  (overlaps: sum is an upper bound)
     0.80  check    gitleaks  (8.30.1, full history, --redact)
     0.79  check    templates/otel/rust  (rustc test suite)
     0.53  check    templates/secrets/go  (five vectors, each with a red proof)
     0.49  check    templates/otel/elixir  (elixir test suite)
     0.46  cpu      tests/deploy_test.sh  (shellcheck -S warning)  (overlaps: sum is an upper bound)
     0.43  check    otel/elixir/phoenix_telemetry.ex.snippet  (parses as .ex)
     0.32  check    templates/bin/dev.sh  (KIT_DEV_PROFILES= escape hatch actually runs)
     0.31  cpu      templates/bin/deploy.sh  (shellcheck -S warning)  (overlaps: sum is an upper bound)
   ... 201 more rows; raise --top to see them.

== the SELF-TEST: 5 breakages reached, 230.0s inside their gate copies so far (46.0s each)
   of which 0.2s is interpreter resolution and dependency bootstrap, once per copy; of the rest, 280.5s is the named checks themselves
   the copy's OWN wall clock is in `wall` and the phase sum in `total`; they
   differ by the argument parsing and the exit trap, and `wall` is the one to
   quote. `total` is a sum of rows that tile the copy, so it cannot double count.
     wall    phases   checks   rows  breakage
---------  --------  -------  -----  ----------------------------------------
    56.31     56.31    46.40    246  unbroken tree
    52.64     52.64    43.46    246  breakage 2: collector gains an exporter nobody read
    49.03     49.03    40.04    246  breakage 2b: the collector ships no exporter for tempo at all
    48.55     48.55    39.46    246  breakage 1: templates/otel/go/traceparent.go deleted
    23.44     23.44   111.15    243  breakage 3: python codec stops preserving trace-flags

   accounted: 455.9s of the gate's own phase time (225.9s gate + 230.0s self-test)
   the difference from the run's wall time is the check rows that are not
   phases, the argument parsing, and whatever the parent shell spent.
