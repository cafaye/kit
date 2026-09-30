//go:build tier_db

// The build-tag form of the tier declaration. Copy this beside tier.go.
//
// # WHY A BUILD TAG IS THE SHARPEST FORM GO HAS
//
// The tag is read by the toolchain, not by a parser kit wrote. `go test -list`
// with the tag enumerates exactly the tests in the tier; without the tag the
// file is not part of the package at all, so the inventory cannot drift from
// the set of tests that exist. There is no second list to keep in step, which is
// the property every other language in this table has to work to reproduce.
//
// THE TWO COMMANDS, AND WHAT EACH ONE PROVES
//
//	go test -tags tier_db -list '.*' ./...    # INVENTORY: what should exist
//	go test -tags tier_db -count=1 ./...     # RUN:       what actually ran
//
// The set difference between the two is the check. Counting is not: 41 tests
// ran is compatible with 41 of the wrong 41, and with a package filtered out of
// the run entirely. See templates/tier/README.md, "What this cannot catch".
//
// -count=1 is not optional on the run. Go keys its test cache on the
// environment variables the test reads, so a gated and an ungated run already
// have different cache keys — genuinely good news — but mandating -count=1
// removes the question rather than reasoning about it, and it costs nothing.
package dbtest

import (
	"database/sql"
	"os"
	"testing"
)

// TestTierDBPoolRoundTrips is a database test. Its id is the function name, and
// that is the whole convention: the normalised format's <test-id> is whatever
// the runner's collector already calls this test, so there is no mapping table
// to maintain and no id that can mean two different tests in two languages.
func TestTierDBPoolRoundTrips(t *testing.T) {
	// REQUIRED_DB=1 turns a missing DSN from a skip into a failure. A skip here
	// is a green run that never opened a connection, and a green run is the
	// failure this tier exists to prevent.
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		if os.Getenv("REQUIRED_DB") == "1" {
			t.Fatal("REQUIRED_DB=1 and TEST_DATABASE_URL is unset: the db tier cannot run. " +
				"Start the database, or unset REQUIRED_DB to skip this tier on purpose.")
		}
		t.Skip("TEST_DATABASE_URL unset: db tier not requested on this run")
	}

	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer func() { _ = db.Close() }()

	if err := db.Ping(); err != nil {
		t.Fatalf("ping: %v", err)
	}
	// The machinery can prove this test ran. Only an assertion inside it proves
	// it reached Postgres, and a template that does not assert that is a
	// template that teaches the wrong lesson.
	var one int
	if err := db.QueryRow("SELECT 1").Scan(&one); err != nil {
		t.Fatalf("SELECT 1: %v", err)
	}
	if one != 1 {
		t.Fatalf("SELECT 1 = %d, want 1", one)
	}
}
