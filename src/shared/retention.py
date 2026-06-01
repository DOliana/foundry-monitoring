"""Log Analytics retention settings shared across all functions."""

import os
from datetime import timedelta

# Environment override for the Log Analytics interactive retention window.
# Must match the workspace retention setting used for queried tables.
RETENTION_DAYS = int(os.environ.get("RETENTION_DAYS", "30"))

# Used as the timespan for _get_last_snapshot queries so they cover the full
# queryable window instead of a hardcoded 7d/14d.
RETENTION_PERIOD = timedelta(days=RETENTION_DAYS)

# Unchanged rows older than this are re-written with a fresh TimeGenerated so
# they don't silently age out of retention and disappear from dashboards.
REFRESH_THRESHOLD = timedelta(days=RETENTION_DAYS - 1)


def fields_match(row: dict, prev: dict, fields: list[str]) -> bool:
    """Return True if every compare field is equal between a freshly-built row
    and the previous Log Analytics snapshot, normalizing for LA quirks.

    Change detection compares a row we just built against the last snapshot read
    back from Log Analytics. A naive ``==`` comparison reports a false "change"
    on every run because LA does not round-trip values identically:

      * Empty string (``_s``) columns come back as ``None`` instead of ``""``.
      * Numeric (``_d``) columns can come back as ``int`` while the row holds a
        ``float`` (e.g. ``0`` vs ``0.0``), or vice versa.
      * Boolean (``_b``) columns can come back as ``None`` when never set.

    Normalizing both sides by column-type suffix before comparing makes the
    comparison stable, so unchanged deployments/models/quota are correctly
    skipped instead of being re-ingested every run.
    """
    for f in fields:
        current = row.get(f)
        snapshot = prev.get(f)
        if f.endswith("_d"):
            # Numeric: coerce both to float so int/float drift doesn't matter.
            current = float(current) if current is not None else 0.0
            snapshot = float(snapshot) if snapshot is not None else 0.0
        elif f.endswith("_b"):
            # Boolean: treat a missing/None snapshot value as False.
            current = bool(current) if current is not None else False
            snapshot = bool(snapshot) if snapshot is not None else False
        else:
            # String (_s) and anything else: treat LA's None as "".
            current = "" if current is None else current
            snapshot = "" if snapshot is None else snapshot
        if current != snapshot:
            return False
    return True
