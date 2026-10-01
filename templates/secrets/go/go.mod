// kit template — the module that lets `go test` run the canary harness in
// place. Same purpose and same reasoning as templates/otel/go/go.mod: `go test`
// needs a module, a service already has one, and two go.mod files in one tree is
// a build that fails in a way nobody enjoys.
//
// Declares a Go version and no `require` block, which is what keeps the harness
// stdlib-only. The type-coverage analyzer deliberately uses `go/parser` and
// `go/ast` rather than `go/packages`: the latter needs a module context and a
// resolver, and the whole advantage of this check is that it runs with
// GOPROXY=off and no network. A `require` line appearing here fails the gate
// (see tests/validate.sh), because at that point kit has a dependency and has
// stopped being conventions.
module kitsecrets

go 1.24
