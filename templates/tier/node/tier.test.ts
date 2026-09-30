// The tier declaration for Node. Copy this file beside your database tests.
//
// THE ADAPTER THIS LANGUAGE NEEDS
//
// `node --test` (and the TAP stream it writes) has no tier-declaration channel.
// `TIER` below is a no-op at runtime that a ~15-line adapter reads. Nothing
// imports it and no test depends on it; it exists to be read, and it is
// `export`ed rather than commented so the adapter can import it rather than
// parse the file.
//
// The TAP stream does report `# SKIP` for a skipped test, and node's own
// `--test-reporter=junit` was NOT measured here — unlike bun's, which was. Treat
// node as the unmeasured case until somebody runs it; the normalised format in
// templates/tier/README.md does not depend on the answer.
import assert from "node:assert/strict";
import { test } from "node:test";

/** The tier these tests belong to. The value in a normalised result line's
 * `tier` field, and the suffix of the gate variable: REQUIRED_DB=1. */
export const TIER = "db" as const;

test("tier_db_pool_round_trips", () => {
  // REQUIRED_DB=1 turns a missing DSN from a skip into a failure. A skip is a
  // green run that never opened a connection.
  const dsn = process.env.TEST_DATABASE_URL;
  if (!dsn) {
    assert.equal(
      process.env.REQUIRED_DB,
      "1",
      "REQUIRED_DB=1 and TEST_DATABASE_URL is unset: the db tier cannot run. " +
        "Start the database, or unset REQUIRED_DB to skip this tier on purpose.",
    );
    return;
  }

  assert.ok(dsn.startsWith("postgres"), dsn);
  // The part only an assertion inside the test can prove: everything outside
  // this function can prove "the db tier ran", nothing outside it can prove
  // "the db tier reached postgres".
});
