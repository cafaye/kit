// Package safe is the reference credential-bearing package: what a service's own
// credential types look like once this harness has been pointed at them and has
// stopped complaining.
//
// WHY IT IS A SEPARATE PACKAGE
//
//	The harness needs a subject to sweep and a counter-example to prove the sweep
//	bites. Both are here, and both are reachable only from inside this module —
//	Go's `internal/` rule means a service that copies the template cannot import
//	this by accident, and `leaky` in particular is not something anyone should be
//	able to reach by accident.
//
// WHAT "SAFE" MEANS HERE, PRECISELY, AND WHY IT IS PRECISELY THAT
//
//	This package's shape is not a matter of taste. It is the answer to a question
//	that was measured rather than argued, because vector 1 caught the first two
//	plausible answers and print_shape_test.go pins the whole table:
//
//	    value field,  unexported     LEAKS under %v %+v %#v %s %q %d
//	    pointer field, unexported    safe under %v, and LEAKS under %s and %q
//	    value field,  EXPORTED       LEAKS under every verb
//	    pointer field, EXPORTED      safe under every verb          <-- this one
//
//	Three things in that table are counter-intuitive and all three are worth
//	knowing before writing a credential type:
//
//	1. AN UNEXPORTED FIELD IS NOT PROTECTION. `fmt` reaches unexported fields
//	   through reflection and prints their values. The field being lowercase buys
//	   nothing against `%v`, and `%v` is in every log line in every service.
//	   `-race` will not stop it and `go vet` will not mention it.
//
//	2. A `String()` METHOD ON THE FIELD'S TYPE IS IGNORED WHEN THE FIELD IS
//	   UNEXPORTED. `fmt` cannot call a method on a value obtained from an
//	   unexported field, so it falls back to reflection and prints the struct. A
//	   redacting `String()` is real protection in an EXPORTED field and worth
//	   nothing in an unexported one.
//
//	3. THE POINTER SHAPE IS NOT A FREE LUNCH. An unexported pointer field prints
//	   an address under `%v`, which looks like the answer, and then `%s` and `%q`
//	   walk the pointer and print the value anyway. A shape that is safe under the
//	   verb everyone uses and unsafe under two others is worse than one that is
//	   obviously broken, because it passes review.
//
//	So `Session.Token` below is EXPORTED. That reads like a mistake — an exported
//	credential field is the thing every security review looks for — and it is the
//	correct shape only because the field is a POINTER to a type that redacts in
//	both String and GoString.
//
//	The better option, where it is available, is not to hold the credential at
//	all: pass the *Token to the code that authenticates with it, and keep only
//	the subject and the scopes in a struct that gets logged. Session
//	demonstrates the shape for the cases where the credential genuinely has to
//	travel with the type, and the harness needs a holder for vector 5 to have
//	something to check.
//
// NO DEPENDENCIES. Stdlib only, so the whole harness runs with GOPROXY=off.
package safe

// Token is a credential.
//
// It redacts in String and in GoString, and that is a decision with two sides.
// The good side: `fmt.Sprintf("%v", token)` prints `Token(redacted)` under every
// verb, and so does every `log.Info("t", token)` in the codebase. The bad side: a
// String method is a promise about every future call site, and GoString is what
// keeps `%#v` — the verb a developer reaches for precisely when a value is not
// what they expected — from printing the fields instead.
//
// Pointer receivers on both, deliberately: a pointer-receiver method is not in
// the method set of the value type, so `Token` is not a fmt.Stringer and the
// redaction cannot be relied on by accident from a place that copied the struct.
// Every way of getting at a Token hands out a pointer.
type Token struct {
	value string
}

// NewToken builds a Token. A service passes a real secret here and reads the
// value back through Value, in as few places as possible.
func NewToken(v string) *Token { return &Token{value: v} }

// String redacts.
func (t *Token) String() string { return "Token(redacted)" }

// GoString redacts too, because `%#v` bypasses String() and prints every field.
// A redaction that relies on String() alone is one debug line away from not
// being one.
func (t *Token) GoString() string { return "safe.Token(redacted)" }

// Value returns the underlying credential. Every call site is a place a reviewer
// has to look, which is the point.
func (t *Token) Value() string { return t.value }

// Session is a credential-bearing type: it holds a Token and therefore must not
// be printable. Vector 5's rule is about this type, not about Token.
//
// The first three fields are the ones a consumer legitimately needs, and none of
// them is a secret. Note what is NOT in the serialised form: there is no `token`
// key, empty or otherwise. An always-present key teaches every consumer to look
// for one and to handle the case where it is filled in later, and that refactor
// is a separate commit no test in this harness would catch. The ABSENCE of the
// key is the property; see vector 4 in canary_test.go, and the `json:"-"` below
// is what vector 2 asserts.
type Session struct {
	Subject   string   `json:"subject"`
	Scopes    []string `json:"scopes"`
	ExpiresAt int64    `json:"expires_at"`

	// Token is the credential, and it is EXPORTED. Read the package comment
	// before changing that: it is exported because an unexported field is not
	// protectable in Go, and an exported VALUE field leaks under every verb. It
	// is a pointer to a redacting type, and that is the only shape that is safe
	// under all of them.
	//
	// `json:"-"` is not decoration. Without it this type marshals a `token` key
	// holding the credential, which is vector 2's finding, and an always-present
	// key is vector 4's.
	Token *Token `json:"-"`
}

// NewSession builds a Session.
func NewSession(subject string, scopes []string, tok *Token) Session {
	return Session{Subject: subject, Scopes: scopes, ExpiresAt: 0, Token: tok}
}

// Claims is the shape kit points a service at FIRST, and it is this one.
//
// It holds no credential. There is no field, no tag, no method and no shape to
// get wrong, which is why it is better than Session rather than merely
// equivalent: the table in the package comment is a list of ways to be unsafe,
// and this type is not on it.
//
// The credential travels separately, as a `*Token` argument to whatever
// authenticates with it. That is a real ergonomic cost — a caller that needs the
// value three functions down is now threading it three frames — and it is the
// right trade for anything that ends up in a log line, which in Go is
// everything.
//
// A service should reach for Session only when the credential genuinely has to
// travel with the type, and a `func() string` field before that if it can; see
// print_shape_test.go for the measurement that ranks those three shapes.
type Claims struct {
	Subject   string   `json:"subject"`
	Scopes    []string `json:"scopes"`
	ExpiresAt int64    `json:"expires_at"`
}

// NewClaims builds Claims. There is deliberately no token parameter: the absence
// is the API, and adding one later is the refactor this type exists to make
// unnecessary.
func NewClaims(subject string, scopes []string, expiresAt int64) Claims {
	return Claims{Subject: subject, Scopes: scopes, ExpiresAt: expiresAt}
}
