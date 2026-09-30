// kit template — vector 5 of the canary contract: Go type coverage.
//
// WHAT THIS IS FOR
//
//	gosec's `credentials.Match` switches on four AST node types and has no
//	`*ast.CallExpr` case. That single missing case is the whole problem: gosec
//	finds a credential LITERAL, and a credential that leaks is a value that
//	reached a `log.Info` call, and the value was never a literal in the first
//	place. Bandit matches `ast.Constant` only. Brakeman's secret check is
//	optional and off by default. Of 268 Semgrep taint rules, zero intersect
//	CWE-532.
//
//	So the call graph is not available to borrow, and this file is the closest
//	thing that can be built without one: a TYPE check. It finds every type in
//	your credential-bearing packages that has a field of a credential type AND
//	declares `String() string` or `Error() string`.
//
// THE RULE, PRECISELY
//
//		secret type        a type whose NAME is in SecretTypeNames
//		credential-bearing any type with a field whose type is a secret type
//		finding            a credential-bearing type declaring String() or Error()
//
//	  A secret type is allowed a String method, and this is not an oversight: the
//	  common defensive shape is `func (t Token) String() string { return "***" }`,
//	  and that is a good thing to write. The rule is about HOLDERS. A holder is a
//	  type that can be asked to print itself and has a credential within reach, so
//	  it has no way to print one safely — every implementation of String() on it
//	  is a decision about formatting a secret, and the compiler cannot check that
//	  decision.
//
// LIMITATION, STATED PLAINLY BECAUSE IT IS THE LIMITATION THAT MATTERS
//
//	THIS IS A TYPE CHECK, NOT A CALL-GRAPH CHECK, AND THE DIFFERENCE IS A REAL
//	GAP RATHER THAN A CAVEAT.
//
//	It will find:
//
//	  - `Session.String()` and `Session.Error()` on a holder, in any file of the
//	    package, whether or not anything ever calls them. That over-approximation
//	    is deliberate: a method nobody calls today is one line away from a caller.
//
//	It will NOT find:
//
//	  - A String method on a type this file does not consider a holder, because
//	    the secret is a plain `string` field rather than a `Token`. THIS IS THE
//	    BIG ONE. `type Session struct { token string }` with a `String()` method
//	    is invisible here, and it is not a rare shape. Wrap the credential in
//	    its own type — that is the first thing the contract asks of a service,
//	    and it is what makes every other vector work as well.
//	  - A method on a holder that prints the secret without being named String
//	    or Error: `Render()`, `Describe()`, `LogValue()`. Real, and out of reach
//	    without types.
//	  - Anything at all across a package boundary it was not pointed at, or
//	    through a build tag, or in generated code, or in a dependency. The set of
//	    packages is an argument, so it is the adopter's job to pass the right
//	    one, and a harness pointed at the wrong directory asserts over nothing.
//
//	In exchange it needs no module, no `go/packages`, no type resolution and no
//	network — it is `go/parser` and `go/ast`, both stdlib, which is what lets the
//	whole harness run with GOPROXY=off.
//
// NO DEPENDENCIES. Stdlib only.
package kitsecrets

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// SecretTypeNames are the type NAMES treated as credentials.
//
// A name list rather than a type analysis, because type analysis needs a module
// and this file's whole advantage is that it does not. The list is a
// declaration of intent: a service adds its own (`Credentials`, `Bearer`,
// `SigningKey`) and the analyzer covers the types that use them.
//
// Naming a type here does NOT flag that type. It flags the types that HOLD one.
var SecretTypeNames = []string{
	"Token",
	"Secret",
	"Credential",
	"Credentials",
	"APIKey",
	"Password",
	"PrivateKey",
	"SigningKey",
	"Bearer",
	"Session",
}

// CoverageFinding is one printable credential-bearing type.
type CoverageFinding struct {
	// Package is the import path or directory it was found in.
	Package string
	// Type is the type that declares the method.
	Type string
	// Method is "String" or "Error".
	Method string
	// Pos is the file and line, so the report points at the method rather than
	// at the package.
	Pos string
}

// String renders a finding for a test failure. It deliberately does not quote
// the method's body: the body is where the credential is.
func (f CoverageFinding) String() string {
	return fmt.Sprintf("%s: %s declares %s() while holding a credential type", f.Pos, f.Type, f.Method)
}

// TypeCoverage reports every credential-bearing type in dirs that declares
// String() string or Error() string.
//
// dirs are directories, walked for .go files. Passing a file works too, because
// the walk is the same either way and a service that wants one file should not
// have to make a directory to say so.
func TypeCoverage(dirs []string) ([]CoverageFinding, error) {
	secret := make(map[string]bool, len(SecretTypeNames))
	for _, n := range SecretTypeNames {
		secret[n] = true
	}

	var findings []CoverageFinding
	for _, dir := range dirs {
		files, err := goFiles(dir)
		if err != nil {
			return nil, err
		}
		for _, path := range files {
			fset := token.NewFileSet()
			parsed, err := parser.ParseFile(fset, path, nil, 0)
			if err != nil {
				// A file that does not parse is a different check's finding (and
				// the gate already has one). Silently skipping it here would
				// make this check quietly weaker exactly when the tree is broken.
				return nil, fmt.Errorf("kitsecrets: %s does not parse: %w", path, err)
			}
			findings = append(findings, scanFile(fset, parsed, path, secret)...)
		}
	}
	sort.Slice(findings, func(i, j int) bool {
		if findings[i].Pos != findings[j].Pos {
			return findings[i].Pos < findings[j].Pos
		}
		return findings[i].Method < findings[j].Method
	})
	return findings, nil
}

// scanFile walks one parsed file. Two passes, because the answer depends on the
// whole file: a type may be declared after the method that the method belongs
// to, and a struct may be declared after the struct that holds it.
func scanFile(fset *token.FileSet, file *ast.File, path string, secret map[string]bool) []CoverageFinding {
	// Every type declaration in the file, and whether it is a holder.
	holders := map[string]bool{}
	for _, decl := range file.Decls {
		gen, ok := decl.(*ast.GenDecl)
		if !ok || gen.Tok != token.TYPE {
			continue
		}
		for _, spec := range gen.Specs {
			ts, ok := spec.(*ast.TypeSpec)
			if !ok {
				continue
			}
			if holdsSecret(ts.Type, secret) {
				holders[ts.Name.Name] = true
			}
		}
	}

	var findings []CoverageFinding
	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Recv == nil || len(fn.Recv.List) == 0 {
			continue
		}
		name := printableName(fn)
		if name != "String" && name != "Error" {
			continue
		}
		// A method on a POINTER to a holder still prints the holder.
		recv := exprName(fn.Recv.List[0].Type)
		if !holders[recv] {
			continue
		}
		findings = append(findings, CoverageFinding{
			Package: path,
			Type:    recv,
			Method:  name,
			Pos:     fset.Position(fn.Pos()).String(),
		})
	}
	return findings
}

// printableName is the method's name, and it checks the signature too: a
// `String(x int) string` is not a Stringer and cannot be reached by `%v`, so
// flagging it would be a false positive on a rule that is already blunt.
func printableName(fn *ast.FuncDecl) string {
	switch fn.Name.Name {
	case "String":
		if fn.Type.Params != nil && len(fn.Type.Params.List) != 0 {
			return ""
		}
		if fn.Type.Results == nil || len(fn.Type.Results.List) != 1 {
			return ""
		}
		return "String"
	case "Error":
		if fn.Type.Params != nil && len(fn.Type.Params.List) != 0 {
			return ""
		}
		if fn.Type.Results == nil || len(fn.Type.Results.List) != 0 {
			return ""
		}
		return "Error"
	}
	return ""
}

// holdsSecret reports whether a type declaration has a field of a secret type,
// at any depth of embedding or nesting.
//
// Pointer, slice, array and map element types are unwrapped, so `[]Token`,
// `map[string]Token` and `*Token` all count. A field typed `string` does not,
// and that gap is the one written down in the package comment.
func holdsSecret(expr ast.Expr, secret map[string]bool) bool {
	found := false
	ast.Inspect(expr, func(n ast.Node) bool {
		if found {
			return false
		}
		switch t := n.(type) {
		case *ast.Ident:
			if secret[t.Name] {
				found = true
				return false
			}
		case *ast.SelectorExpr:
			// A qualified type from another package. `auth.Token` is a secret
			// type by name and is counted; `auth.User` is not.
			if secret[t.Sel.Name] {
				found = true
				return false
			}
		}
		return true
	})
	return found
}

// exprName is the bare name of a type expression: `Session`, `*Session`,
// `[]Session` and `map[string]Session` are all `Session`.
func exprName(expr ast.Expr) string {
	switch t := expr.(type) {
	case *ast.Ident:
		return t.Name
	case *ast.StarExpr:
		return exprName(t.X)
	case *ast.ArrayType:
		return exprName(t.Elt)
	case *ast.MapType:
		return exprName(t.Value)
	case *ast.SelectorExpr:
		return t.Sel.Name
	}
	return ""
}

// goFiles is every .go file under dir, sorted. Test files are INCLUDED: a
// helper in a _test.go that formats a credential is still a place a credential
// is formatted, and a scanner that skipped tests would skip exactly the code
// that runs with the canary planted.
func goFiles(dir string) ([]string, error) {
	info, err := os.Stat(dir)
	if err != nil {
		return nil, fmt.Errorf("kitsecrets: cannot read %s: %w", dir, err)
	}
	if !info.IsDir() {
		if !strings.HasSuffix(dir, ".go") {
			return nil, fmt.Errorf("kitsecrets: %s is not a .go file", dir)
		}
		return []string{dir}, nil
	}

	var out []string
	err = filepath.Walk(dir, func(path string, fi os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if fi.IsDir() {
			switch fi.Name() {
			case ".git", "vendor", "testdata", "node_modules":
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasSuffix(path, ".go") {
			out = append(out, path)
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("kitsecrets: walking %s: %w", dir, err)
	}
	sort.Strings(out)
	if len(out) == 0 {
		// Silence here is the failure mode this check exists to prevent: a
		// directory that was moved, or a build tag that hid every file, produces
		// zero findings and reads as clean.
		return nil, fmt.Errorf("kitsecrets: no .go files under %s — a coverage check over nothing is not a check", dir)
	}
	return out, nil
}
