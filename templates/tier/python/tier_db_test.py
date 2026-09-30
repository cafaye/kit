"""A database test, declared.

The marker is the declaration. `pytest --collect-only -q -m tier_db` reads it,
and a test that reaches Postgres through a helper two modules away still carries
it, because the author wrote it on the test rather than a sentinel appearing
somewhere in a grep's path.
"""

import os

import pytest


@pytest.mark.tier_db
def test_tier_db_pool_round_trips():
    """A database test.

    REQUIRED_DB=1 turns a missing DSN from a skip into a failure. A skip here is
    a green run that never opened a connection.
    """
    dsn = os.environ.get("TEST_DATABASE_URL")
    if not dsn:
        if os.environ.get("REQUIRED_DB") == "1":
            pytest.fail(
                "REQUIRED_DB=1 and TEST_DATABASE_URL is unset: the db tier cannot run. "
                "Start the database, or unset REQUIRED_DB to skip this tier on purpose."
            )
        pytest.skip("TEST_DATABASE_URL unset: db tier not requested on this run")

    assert dsn.startswith("postgres"), dsn

    # The part only an assertion inside the test can prove. Everything outside
    # this function can prove "the db tier ran"; nothing outside it can prove
    # "the db tier reached postgres".
    conn = _connect(dsn)
    try:
        assert conn.execute("SELECT 1").fetchone() == (1,)
    finally:
        conn.close()


def _connect(dsn):
    """Stand-in for whatever your suite connects with.

    A real service substitutes its own driver here. The template is about the
    declaration, and a template that grew a driver dependency would make kit
    something other than config-only.
    """
    raise NotImplementedError("substitute your own driver; the tier contract is above")
