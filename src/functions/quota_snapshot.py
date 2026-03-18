"""Collect subscription-level quota snapshots from the ARM usages API."""

import asyncio
import logging
import os
from datetime import datetime, timedelta, timezone

from azure.monitor.query import LogsQueryClient, LogsQueryStatus

from shared.arm import get_quota_usages, list_instances, list_subscriptions
from shared.clients import get_credential, get_ingestion_client
from shared.watermark import mark_failed, mark_success, read_watermark

logger = logging.getLogger(__name__)

_DCR_RULE_ID = os.environ.get("DCR_QUOTA_SNAPSHOT_IMMUTABLE_ID", "")
_STREAM_NAME = "Custom-QuotaSnapshot_CL"
_WATERMARK_STREAM = "quota_snapshot"
_MAX_PARALLEL = int(os.environ.get("MAX_PARALLEL_SUBS", "5"))
_WORKSPACE_ID = os.environ.get("LOG_ANALYTICS_WORKSPACE_ID", "")

_COMPARE_FIELDS = [
    "deployedTPM_d",
    "maxTPM_d",
]


def _get_last_snapshot(sub_id: str) -> dict[tuple[str, str], dict]:
    """Query Log Analytics for the latest quota snapshot per region/model.

    Returns an empty dict if LOG_ANALYTICS_WORKSPACE_ID is not set, which
    disables change detection and causes all rows to be written.
    """
    if not _WORKSPACE_ID:
        logger.debug("Change detection disabled — no LOG_ANALYTICS_WORKSPACE_ID")
        return {}

    client = LogsQueryClient(credential=get_credential())
    logger.debug("Querying last quota snapshot for sub %s", sub_id)
    query = (
        "QuotaSnapshot_CL"
        " | where subscriptionId_s == @sub_id"
        " | summarize arg_max(TimeGenerated, *) by region_s, model_s"
    )
    result = client.query_workspace(
        _WORKSPACE_ID,
        query,
        timespan=timedelta(days=7),
        additional_workspaces=None,
        query_parameters={"sub_id": sub_id},
    )

    snapshot: dict[tuple[str, str], dict] = {}
    if result.status == LogsQueryStatus.SUCCESS and result.tables:
        columns = [c.name for c in result.tables[0].columns]
        for row in result.tables[0].rows:
            row_dict = dict(zip(columns, row))
            key = (
                row_dict.get("region_s", ""),
                row_dict.get("model_s", ""),
            )
            snapshot[key] = row_dict
    logger.debug("Sub %s: loaded %d previous quota snapshot rows", sub_id, len(snapshot))
    return snapshot


def _collect(sub: dict, now: datetime) -> list[dict]:
    """Collect quota data for a single subscription across all instance regions."""
    sub_id = sub["subscriptionId"]
    sub_name = sub["displayName"]

    instances = list_instances(sub_id)
    logger.debug("Sub %s: found %d instances", sub_id, len(instances))
    locations = {inst["location"] for inst in instances}
    logger.debug("Sub %s: unique locations: %s", sub_id, locations)

    last_snapshot = _get_last_snapshot(sub_id)
    logger.debug("Sub %s: loaded %d previous snapshot entries", sub_id, len(last_snapshot))

    rows = []
    for location in locations:
        usages = get_quota_usages(sub_id, location)
        logger.debug("Sub %s, %s: got %d usage records", sub_id, location, len(usages))
        for u in usages:
            current = u.get("currentValue", 0)
            limit_val = u.get("limit", 0)

            row = {
                "TimeGenerated": now.isoformat(),
                "timestamp_t": now.isoformat(),
                "subscriptionId_s": sub_id.lower(),
                "subscriptionName_s": sub_name,
                "region_s": location,
                "model_s": u.get("name", {}).get("value", ""),
                "deployedTPM_d": float(current),
                "maxTPM_d": float(limit_val),
                "utilizationPct_d": (
                    round(current / limit_val * 100, 2) if limit_val > 0 else 0.0
                ),
            }

            # Change detection: skip if identical to the last snapshot
            key = (location, row["model_s"])
            prev = last_snapshot.get(key)
            if prev is not None and all(
                row.get(f) == prev.get(f) for f in _COMPARE_FIELDS
            ):
                logger.debug("Skipping unchanged quota %s/%s", location, row["model_s"])
                continue

            rows.append(row)
    return rows


async def run() -> None:
    now = datetime.now(timezone.utc)
    semaphore = asyncio.Semaphore(_MAX_PARALLEL)
    subscriptions = list_subscriptions()
    ingestion = get_ingestion_client()

    logger.debug("Resolved %d subscriptions for quota snapshot", len(subscriptions))
    logger.info("Starting quota snapshot for %d subscriptions", len(subscriptions))
    if not _WORKSPACE_ID:
        logger.warning(
            "LOG_ANALYTICS_WORKSPACE_ID not set — change detection disabled, "
            "all quota rows will be written each run"
        )

    async def process_one(sub: dict) -> str:
        async with semaphore:
            sub_id = sub["subscriptionId"]
            watermark = read_watermark(_WATERMARK_STREAM, sub_id)
            logger.debug("Sub %s: watermark=%s, cutoff=%s", sub_id, watermark, now - timedelta(minutes=5))

            if watermark and watermark >= now - timedelta(minutes=5):
                logger.info("Sub %s: already up to date", sub_id)
                return "skipped"

            try:
                logger.debug("Sub %s: collecting quota data", sub_id)
                rows = await asyncio.to_thread(_collect, sub, now)
                if rows:
                    await asyncio.to_thread(
                        ingestion.upload, _DCR_RULE_ID, _STREAM_NAME, rows
                    )
                    logger.info("Sub %s: ingested %d quota rows", sub_id, len(rows))
                    mark_success(_WATERMARK_STREAM, sub_id, now)
                    return "ingested"
                else:
                    logger.info("Sub %s: no quota data found", sub_id)
                    mark_success(_WATERMARK_STREAM, sub_id, now)
                    return "skipped"
            except Exception:
                mark_failed(_WATERMARK_STREAM, sub_id)
                raise

    results = await asyncio.gather(
        *[process_one(s) for s in subscriptions],
        return_exceptions=True,
    )

    ingested = skipped = failed = 0
    for sub, r in zip(subscriptions, results):
        if isinstance(r, Exception):
            logger.error("Sub %s failed: %s", sub["subscriptionId"], r)
            failed += 1
        elif r == "ingested":
            ingested += 1
        else:
            skipped += 1

    logger.info(
        "Quota snapshot complete: %d ingested, %d skipped, %d failed (of %d)",
        ingested, skipped, failed, len(subscriptions),
    )
