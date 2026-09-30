// kit template — vector 5 of the canary contract: Go type coverage, executed.
//
// The vector is a static check, so its red proof cannot be produced by feeding a
// leaky VALUE to a detector the way vectors 1-4 do. It is produced by running
// the analyzer over two packages: one that must come back clean and one that
// must come back with a finding. The leaky package is a source file, not a
// value, which is why vector 5 lives in its own file.
package kitsecrets

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"kitsecrets/internal/leaky"
	"kitsecrets/internal/safe"
)

func TestVector5_TypeCoverage(t *testing.T) {
	const c = "vector 5 (type-coverage): no credential-bearing type is printable or an error"

	// The clean half. `safe.Session` holds a `safe.Token` and declares no
	// String and no Error, so the analyzer must say nothing — and saying
	// nothing here is the assertion, because a check that only ever fires is a
	// check nobody can tell apart from a check that fires on everything.
	findings, err := TypeCoverage([]string{filepath.Join("internal", "safe")})
	if err != nil {
		t.Fatalf("TypeCoverage(internal/safe): %v", err)
	}
	if len(findings) > 0 {
		var lines []string
		for _, f := range findings {
			lines = append(lines, f.String())
		}
		t.Fatalf("RED PROOF: the reference credential package is itself flagged, so the rule does "+
			"not describe the shape kit tells a service to write:\n  %s", strings.Join(lines, "\n  "))
	}

	// The red half. `leaky.PrintableSession` holds a `Token` and declares
	// `String() string`, which is the finding.
	findings, err = TypeCoverage([]string{filepath.Join("internal", "leaky")})
	if err != nil {
		t.Fatalf("TypeCoverage(internal/leaky): %v", err)
	}
	if len(findings) == 0 {
		t.Fatalf("vector 5 did not fire: %s declares String() while holding a Token and the "+
			"analyzer found nothing, so it is not reading the method declarations it claims to read",
			"PrintableSession")
	}

	// The finding must be specific: the type, the method, and a position a
	// reader can jump to. "some type is printable" is a report.
	var found *CoverageFinding
	for i := range findings {
		if findings[i].Type == "PrintableSession" && findings[i].Method == "String" {
			found = &findings[i]
		}
	}
	if found == nil {
		var lines []string
		for _, f := range findings {
			lines = append(lines, f.String())
		}
		t.Fatalf("vector 5 fired, but not on PrintableSession.String():\n  %s", strings.Join(lines, "\n  "))
	}
	if !strings.Contains(found.Pos, "leaky") || !strings.Contains(found.Pos, ":") {
		t.Fatalf("vector 5's finding has no usable position (%q); a report that cannot be "+
			"jumped to is a report nobody acts on", found.Pos)
	}

	// The negative controls, which are what keep the rule from being a blunt
	// "flag every String method" and therefore from being switched off.
	//
	// A secret type is ALLOWED a String method: `leaky.Token` declares one, and
	// the finding above did not name it. That is the rule's whole shape — a
	// secret may be printable in a controlled way, a holder may not.
	if namesType(findings, "Token") {
		t.Fatalf("vector 5 flagged the secret type itself, not the holder. A Token with a " +
			"redacting String() is the shape a service SHOULD write.")
	}
	// `leaky.Session` holds a `Token` and declares no String, so it must not
	// appear even though it is a holder.
	if namesType(findings, "Session") {
		t.Fatalf("vector 5 flagged leaky.Session, which is a holder with no String and no Error")
	}

	t.Logf("RED PROOF %s: fired on %q; a secret type with its own String() was correctly not flagged",
		c, found.String())
}

func namesType(findings []CoverageFinding, typeName string) bool {
	for _, f := range findings {
		if f.Type == typeName {
			return true
		}
	}
	return false
}

// TestTypeCoverageRefusesAnEmptyDirectory is the check that the check is real.
//
// A coverage analyzer pointed at a directory that has moved, or at a build tag
// that hid every file, walks nothing and reports nothing — and "nothing" reads
// exactly like "clean". This is the failure mode every directory-walking
// checker in every language has, and the only defence is refusing to be silent
// about it.
func TestTypeCoverageRefusesAnEmptyDirectory(t *testing.T) {
	empty := t.TempDir()
	if _, err := TypeCoverage([]string{empty}); err == nil {
		t.Fatalf("TypeCoverage over a directory with no .go files returned no error and no " +
			"findings. A coverage check over nothing is not a check, and a caller that cannot " +
			"tell that apart from a clean result will ship a credential type with a String() " +
			"method believing it was checked")
	} else if !strings.Contains(err.Error(), "no .go files") {
		t.Fatalf("TypeCoverage over an empty directory failed for the wrong reason: %v", err)
	}
}

// TestTypeCoverageUnwrapsContainers is the half of the rule that a naive
// implementation gets wrong, and it is worth its own test because the failure is
// invisible rather than loud: a `[]Token` field that is not unwrapped simply
// does not count, and the analyzer stays quiet.
func TestTypeCoverageUnwrapsContainers(t *testing.T) {
	// Compile-time witness that the shapes below exist and are what this test
	// says they are. If someone changes them the test stops meaning what its
	// name says, and the unused-import error it prevents is the cheapest
	// possible signal for that.
	_ = leaky.PrintableSession{Subject: "s", Token: leaky.Token{Value: "v"}}
	_ = safe.NewSession("s", nil, safe.NewToken("v"))

	// `internal/safe` holds `Session` (a `Token` field) and `Token` (a string
	// field). Neither is wrapped in a container here, so this test asserts the
	// unwrapping behaviour against the analyzer's own decision function rather
	// than against a package that would have to exist purely to be a fixture:
	// the shapes []Token / map[string]Token / *Token must all count.
	for _, shape := range []string{"Token", "*Token", "[]Token", "map[string]Token"} {
		if !holdsSecretShape(t, shape) {
			t.Fatalf("the analyzer does not recognise %s as holding a credential, so a holder "+
				"whose secret is behind one of these shapes is invisible to vector 5", shape)
		}
	}
	if holdsSecretShape(t, "string") {
		t.Fatalf("the analyzer recognises a bare `string` field as holding a credential, which " +
			"would flag every struct in a service")
	}
}

// holdsSecretShape builds a one-field struct of the given field type, gives it a
// String() method, and asks the analyzer whether it is flagged.
//
// Built from source text and run through the real TypeCoverage rather than
// through a second implementation of the same rule: a test that re-implements
// the predicate it is testing proves that the re-implementation agrees with
// itself.
func holdsSecretShape(t *testing.T, fieldType string) bool {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "shape.go")
	src := "package p\n\n" +
		"type Holder struct {\n\tField " + fieldType + "\n}\n\n" +
		"func (h Holder) String() string { return \"\" }\n"
	if err := os.WriteFile(path, []byte(src), 0o600); err != nil {
		t.Fatalf("could not write the fixture: %v", err)
	}
	findings, err := TypeCoverage([]string{dir})
	if err != nil {
		t.Fatalf("TypeCoverage(%s): %v", fieldType, err)
	}
	return len(findings) > 0
}
