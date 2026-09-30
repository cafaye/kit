// kit template — the module that lets `go test` run the traceparent template in
// place. It is here for kit's own gate, not for a service to copy: a service
// already has a go.mod, and two go.mod files in one tree is a build that fails in
// a way nobody enjoys.
//
// WHY IT EXISTS AT ALL
//   `go test` needs a module. This one declares a Go version and no `require`
//   block, which is what keeps the template stdlib-only: kit can execute the
//   suite with GOPROXY=off and no network at all. A `require` line appearing here
//   fails the gate (see tests/validate.sh), because at that point kit has a
//   dependency and has stopped being conventions.
module kitotel

go 1.24
