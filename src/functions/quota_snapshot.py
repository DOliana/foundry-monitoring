"""Collect subscription-level quota snapshots from the ARM usages API."""

import asyncio
import logging
import os
from datetime import datetime, timedelta, timezone

from azure.monitor.query import LogsQueryClient, LogsQueryStatus

from requests.exceptions import HTTPError

from shared.arm import get_quota_usages, list_instances, list_subscriptions
from shared.clients import get_credential, get_ingestion_client
from shared.watermark import (
    list_watermarked_subscriptions,
    mark_failed,
    mark_success,
    read_watermark,
)

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
    """Collect quota data for a single subscription across all instance regions.

    Also detects quota entries that were present in the last snapshot but are no
    longer returned by ARM and emits soft-delete marker rows for them.
    """
    sub_id = sub["subscriptionId"]
    sub_name = sub["displayName"]

    instances = list_instances(sub_id)
    logger.debug("Sub %s: found %d instances", sub_id, len(instances))
    locations = {inst["location"] for inst in instances}
    logger.debug("Sub %s: unique locations: %s", sub_id, locations)

    last_snapshot = _get_last_snapshot(sub_id)
    logger.debug("Sub %s: loaded %d previous snapshot entries", sub_id, len(last_snapshot))

    rows = []
    current_keys: set[tuple[str, str]] = set()

    for location in locations:
        try:
            usages = get_quota_usages(sub_id, location)
        except HTTPError as exc:
            if exc.response is not None and exc.response.status_code in (404, 409):
                logger.warning(
                    "Sub %s, %s: HTTP %d fetching quota (region may be unavailable), skipping",
                    sub_id, location, exc.response.status_code,
                )
                continue
            raise
        logger.debug("Sub %s, %s: got %d usage records", sub_id, location, len(usages))
        for u in usages:
            current = u.get("currentValue", 0)
            limit_val = u.get("limit", 0)

            model = u.get("name", {}).get("value", "")
            key = (location, model)
            current_keys.add(key)

            row = {
                "TimeGenerated": now.isoformat(),
                "timestamp_t": now.isoformat(),
                "subscriptionId_s": sub_id.lower(),
                "subscriptionName_s": sub_name,
                "region_s": location,
                "model_s": model,
                "deployedTPM_d": float(current),
                "maxTPM_d": float(limit_val),
                "utilizationPct_d": (
                    round(current / limit_val * 100, 2) if limit_val > 0 else 0.0
                ),
                "isDeleted_b": False,
            }

            # Change detection: skip if identical to the last snapshot
            prev = last_snapshot.get(key)
            if prev is not None and all(
                row.get(f) == prev.get(f) for f in _COMPARE_FIELDS
            ):
                logger.debug("Skipping unchanged quota %s/%s", location, model)
                continue

            rows.append(row)

    # Detect deleted quota entries: present in snapshot but missing from ARM,
    # and not already marked as deleted in the previous snapshot.
    if last_snapshot:
        for key, prev in last_snapshot.items():
            if key in current_keys:
                continue
            if prev.get("isDeleted_b") is True:
                logger.debug("Already marked deleted: %s/%s", *key)
                continue
            logger.info("Detected deleted quota entry: %s/%s", *key)
            rows.append({
                "TimeGenerated": now.isoformat(),
                "timestamp_t": now.isoformat(),
                "subscriptionId_s": prev.get("subscriptionId_s", ""),
                "subscriptionName_s": prev.get("subscriptionName_s", ""),
                "region_s": prev.get("region_s", ""),
                "model_s": prev.get("model_s", ""),
                "deployedTPM_d": 0.0,
                "maxTPM_d": 0.0,
                "utilizationPct_d": 0.0,
                "isDeleted_b": True,
            })

    return rows


def _collect_deleted_sub_rows(sub_id: str, now: datetime) -> list[dict]:
    """Emit soft-delete markers for all quota entries of a disappeared subscription."""
    last_snapshot = _get_last_snapshot(sub_id)
    rows = []
    for key, prev in last_snapshot.items():
        if prev.get("isDeleted_b") is True:
            continue
        logger.info("Detected deleted quota entry (sub gone): %s/%s in sub %s", *key, sub_id)
        rows.append({
            "TimeGenerated": now.isoformat(),
            "timestamp_t": now.isoformat(),
            "subscriptionId_s": prev.get("subscriptionId_s", ""),
            "subscriptionName_s": prev.get("subscriptionName_s", ""),
            "region_s": prev.get("region_s", ""),
            "model_s": prev.get("model_s", ""),
            "deployedTPM_d": 0.0,
            "maxTPM_d": 0.0,
            "utilizationPct_d": 0.0,
            "isDeleted_b": True,
        })
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

    # Detect disappeared subscriptions: have a watermark but are no longer in ARM.
    if _WORKSPACE_ID:
        active_sub_ids = {s["subscriptionId"] for s in subscriptions}
        watermarked = list_watermarked_subscriptions(_WATERMARK_STREAM)
        gone_subs = [sid for sid in watermarked if sid not in active_sub_ids]
        for sub_id in gone_subs:
            try:
                rows = await asyncio.to_thread(_collect_deleted_sub_rows, sub_id, now)
                if rows:
                    await asyncio.to_thread(
                        ingestion.upload, _DCR_RULE_ID, _STREAM_NAME, rows
                    )
                    logger.info(
                        "Sub %s (gone): emitted %d deletion markers for quota", sub_id, len(rows)
                    )
            except Exception:
                logger.error("Sub %s (gone): failed to emit quota deletion markers", sub_id, exc_info=True)
