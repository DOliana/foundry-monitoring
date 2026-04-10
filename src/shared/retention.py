"""Log Analytics retention settings shared across all functions."""

import os
from datetime import timedelta

# Must match the Log Analytics workspace interactive retention setting.
RETENTION_DAYS = int(os.environ.get("RETENTION_DAYS", "30"))

# Used as the timespan for _get_last_snapshot queries so they cover the full
# queryable window instead of a hardcoded 7d/14d.
RETENTION_PERIOD = timedelta(days=RETENTION_DAYS)

# Unchanged rows older than this are re-written with a fresh TimeGenerated so
# they don't silently age out of retention and disappear from dashboards.
REFRESH_THRESHOLD = timedelta(days=RETENTION_DAYS - 1)
