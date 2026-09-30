# The tier declaration for Python. Copy conftest.py to your test root and
# tier_db_test.py beside your database tests.
#
# WHY THE MARKER AND NOT A CONVENTION
#
# `@pytest.mark.tier_db` is read by pytest's own collector:
#
#     pytest --collect-only -q                # INVENTORY, every test
#     pytest --collect-only -q -m tier_db     # the tier's tests
#     pytest -m tier_db -p no:randomly        # RUN the tier
#
# `conftest.py` is not optional. pytest 8 errors on an unregistered marker
# (`PytestUnknownMarkWarning`, fatal under `--strict-markers`), and it should:
# a marker nobody registered is a typo that would otherwise be a tier that
# silently contains nothing. Registration is the declaration's other half.

# The tier itself. The value that appears in the `tier` field of a normalised
# result line, and the suffix of the gate variable: REQUIRED_DB=1.
TIER = "db"


def pytest_configure(config):
    """Register the tier markers.

    `config.addinivalue_line` is the documented registration path; editing
    `markers` in pyproject.toml instead is equivalent and this file is what a
    repo copies, so both work and neither is required to be the other.
    """
    config.addinivalue_line(
        "markers",
        f"tier_{TIER}: needs a real {TIER}; runs when REQUIRED_{TIER.upper()}=1",
    )
