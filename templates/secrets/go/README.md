# kit — the Go canary adapter

> The contract is in [`../README.md`](../README.md). This file is the adoption
> notes for Go specifically: what to copy, what to point at your own code, and
> what the adapter cannot see.

## What to copy

Copy the whole directory into your service, and keep every file.

```
internal/canary/          # canary.go, sweep.go, typecover.go  (+ go.mod's absence)
```

| File | Copy it? | Why |
|---|---|---|
| `canary.go` | yes | the canary value and vector 1's detectors |
| `sweep.go` | yes | vectors 2, 3, 4 |
| `typecover.go` | yes | vector 5 |
| `canary_test.go`, `typecover_test.go`, `print_shape_test.go` | yes | the red proofs. They are the part that proves the rest. |
| `internal/safe/` | **yes, and read it first** | the reference shape |
| `internal/leaky/` | **no** | deliberately defective; it is the counter-example |
| `go.mod` | **no** | you already have one. Two go.mod files in one tree is a build that fails in a way nobody enjoys. |

## Wiring it to your own code

Three things, in this order. Each one is a place the harness can be pointed at
nothing, which reads exactly like a pass.

**1. The credential type.** The single most useful thing in this directory is
`internal/safe`, and the single most important thing in it is that
`Claims` — which holds no credential — is the shape kit points you at **first**.
`Session` exists because the harness needs a *holder* for vector 5 to have
something to check, and because your credential may genuinely have to travel
with a type.

`internal/safe/creds.go` carries a measured table of which field shapes `fmt`
can and cannot print. Read it before writing your own. The short version:

| shape | verdict |
|---|---|
| unexported value field | **leaks under every verb** — `fmt` prints unexported fields |
| unexported pointer field | safe under `%v`, **leaks under `%s` and `%q`** |
| exported value field | **leaks under every verb** |
| exported pointer to a redacting type | safe under every dispatched verb; leaks under the numeric ones |
| `func() string` field | safe under every verb, and unmarshalable |

`print_shape_test.go` pins all of it. It is the file to keep if you keep one.

**2. The sinks.** Vector 1 needs your loggers by name, because nothing can
enumerate them:

```go
sinks := []kitsecrets.ReadSink{stdoutSink, fileSink, otelSpanSink}
leaked := kitsecrets.SweepSinks(sinks, func(s kitsecrets.ReadSink) {
    // your code, writing to s
})
```

Point it at **every** place a credential could land: stdout, your file logger,
your error reporter, and your span exporter if you record attributes. A harness
covering three sinks out of nine is a harness asserting over a third of the
surface.

**3. The public keys.** `SweepSerialised` needs to know which keys are meant to
be public:

```go
sweep, err := kitsecrets.SweepSerialised(session, []string{"subject", "scopes"}, credentialKeys)
```

Only your service knows this. A harness that guessed would be asserting against
the wrong contract, and a wrong contract that passes is worse than no contract.

**4. Your credential type names.** Vector 5 matches on type *names*:

```go
kitsecrets.SecretTypeNames = append(kitsecrets.SecretTypeNames, "Bearer", "SigningKey")
```

Add yours. A type named here is **not** flagged; a type *holding* one is.

**5. Point vector 5 at your packages.**

```go
findings, err := kitsecrets.TypeCoverage([]string{"internal/auth", "internal/session"})
```

Do not point it at a directory with no `.go` files: it refuses, loudly, because
a coverage check over nothing reads identically to a clean one.

## Running it

```sh
go test ./internal/canary/... -v
```

Stdlib only. No `require` block, no network, `GOPROXY=off` works.

## What this adapter cannot see

Stated here as well as in `../README.md`, because this is the file you will
actually read.

- **Vector 5 is a type check, not a call-graph check.** It finds
  `String()`/`Error()` on a type holding a *named* secret type. It does **not**
  find a `String()` on a type whose secret is a plain `string` field — which is
  the common case today — nor `Render()`, `Describe()` or `LogValue()`, nor
  anything in a dependency or behind a build tag. Wrap the credential in its own
  type; that is what makes every other vector work as well.
- **`SweepOutput` swaps `os.Stdout`/`os.Stderr`, not the fds.** A logger holding
  its own dup of fd 1 bypasses it. Use `SweepSinks` for those.
- **`SweepErrorChain` finds formatting leaks, not provenance.** It cannot tell
  your error from someone else's in the chain; it can only say that some error in
  the chain printed the canary.
- **A green run means nothing was found**, not that nothing leaks. It is bounded
  by the sinks and packages you named.
