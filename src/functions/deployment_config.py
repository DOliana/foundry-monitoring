"""Collect deployment configurations with change detection."""

import asyncio
import logging
import os
from datetime import datetime, timedelta, timezone

from azure.monitor.query import LogsQueryClient, LogsQueryStatus

from requests.exceptions import HTTPError

from shared.arm import list_deployments, list_instances, list_subscriptions
from shared.clients import get_credential, get_ingestion_client
from shared.watermark import (
    list_watermarked_subscriptions,
    mark_failed,
    mark_success,
    read_watermark,
)

logger = logging.getLogger(__name__)

_DCR_RULE_ID = os.environ.get("DCR_DEPLOYMENT_CONFIG_IMMUTABLE_ID", "")
_STREAM_NAME = "Custom-DeploymentConfig_CL"
_WATERMARK_STREAM = "deployment_config"
_MAX_PARALLEL = int(os.environ.get("MAX_PARALLEL_SUBS", "5"))
_WORKSPACE_ID = os.environ.get("LOG_ANALYTICS_WORKSPACE_ID", "")

_COMPARE_FIELDS = [
    "modelName_s",
    "modelVersion_s",
    "skuName_s",
    "skuCapacity_d",
    "tpmLimit_d",
    "rpmLimit_d",
]


def _get_last_snapshot(sub_id: str) -> dict[tuple[str, str], dict]:
    """Query Log Analytics for the latest deployment config per instance/deployment.

    Returns an empty dict if LOG_ANALYTICS_WORKSPACE_ID is not set, which
    disables change detection and causes all deployments to be written.
    """
    if not _WORKSPACE_ID:
        logger.debug("Change detection disabled — no LOG_ANALYTICS_WORKSPACE_ID")
        return {}

    client = LogsQueryClient(credential=get_credential())
    logger.debug("Querying last deployment snapshot for sub %s", sub_id)
    query = (
        "DeploymentConfig_CL"
        " | where subscriptionId_s == @sub_id"
        " | summarize arg_max(TimeGenerated, *) by resourceId_s, deploymentName_s"
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
                row_dict.get("resourceId_s", ""),
                row_dict.get("deploymentName_s", ""),
            )
            snapshot[key] = row_dict
    logger.debug("Sub %s: loaded %d previous snapshot rows", sub_id, len(snapshot))
    return snapshot


def _collect(sub: dict, now: datetime) -> list[dict]:
    """Collect deployment configs for a subscription, filtering to changes only.

    Also detects deployments that were present in the last snapshot but are no
    longer returned by ARM (deleted deployments or deleted instances) and emits
    soft-delete marker rows for them.
    """
    sub_id = sub["subscriptionId"]
    sub_name = sub["displayName"]

    instances = list_instances(sub_id)
    last_snapshot = _get_last_snapshot(sub_id)
    logger.debug("Sub %s: found %d instances, %d snapshot entries", sub_id, len(instances), len(last_snapshot))

    rows = []
    current_keys: set[tuple[str, str]] = set()

    for inst in instances:
        resource_id = inst["resourceId"]
        try:
            deployments = list_deployments(resource_id)
        except HTTPError as exc:
            if exc.response is not None and exc.response.status_code in (404, 409):
                logger.warning(
                    "Instance %s: HTTP %d listing deployments (resource may be deleting), skipping",
                    inst["name"],
                    exc.response.status_code,
                )
                continue
            raise
        logger.debug("Instance %s: %d deployments", inst["name"], len(deployments))

        for d in deployments:
            props = d.get("properties", {})
            model = props.get("model", {})
            sku = d.get("sku", {})
            rate_limits = props.get("rateLimits", [])
            tpm = next(
                (r["count"] for r in rate_limits if r.get("key") == "token"), 0
            )
            rpm = next(
                (r["count"] for r in rate_limits if r.get("key") == "request"), 0
            )

            key = (resource_id.lower(), d["name"])
            current_keys.add(key)

            row = {
                "TimeGenerated": now.isoformat(),
                "subscriptionId_s": sub_id.lower(),
                "subscriptionName_s": sub_name,
                "resourceId_s": resource_id.lower(),
                "resourceName_s": inst["name"],
                "location_s": inst["location"],
                "kind_s": inst["kind"],
                "deploymentName_s": d["name"],
                "modelName_s": model.get("name", ""),
                "modelVersion_s": model.get("version", ""),
                "skuName_s": sku.get("name", ""),
                "skuCapacity_d": float(sku.get("capacity", 0)),
                "tpmLimit_d": float(tpm),
                "rpmLimit_d": float(rpm),
                "isDeleted_b": False,
            }

            # Change detection: skip if identical to the last snapshot
            prev = last_snapshot.get(key)
            if prev is not None and all(
                row.get(f) == prev.get(f) for f in _COMPARE_FIELDS
            ):
                logger.debug("Skipping unchanged deployment %s/%s", resource_id, d["name"])
                continue

            rows.append(row)

    # Detect deleted deployments: present in snapshot but missing from ARM,
    # and not already marked as deleted in the previous snapshot.
    if last_snapshot:
        for key, prev in last_snapshot.items():
            if key in current_keys:
                continue
            if prev.get("isDeleted_b") is True:
                logger.debug("Already marked deleted: %s/%s", *key)
                continue
            logger.info("Detected deleted deployment: %s/%s", *key)
            rows.append({
                "TimeGenerated": now.isoformat(),
                "subscriptionId_s": prev.get("subscriptionId_s", ""),
                "subscriptionName_s": prev.get("subscriptionName_s", ""),
                "resourceId_s": prev.get("resourceId_s", ""),
                "resourceName_s": prev.get("resourceName_s", ""),
                "location_s": prev.get("location_s", ""),
                "kind_s": prev.get("kind_s", ""),
                "deploymentName_s": prev.get("deploymentName_s", ""),
                "modelName_s": prev.get("modelName_s", ""),
                "modelVersion_s": prev.get("modelVersion_s", ""),
                "skuName_s": prev.get("skuName_s", ""),
                "skuCapacity_d": 0.0,
                "tpmLimit_d": 0.0,
                "rpmLimit_d": 0.0,
                "isDeleted_b": True,
            })

    return rows


def _collect_deleted_sub_rows(sub_id: str, now: datetime) -> list[dict]:
    """Emit soft-delete markers for all deployments of a disappeared subscription."""
    last_snapshot = _get_last_snapshot(sub_id)
    rows = []
    for key, prev in last_snapshot.items():
        if prev.get("isDeleted_b") is True:
            continue
        logger.info("Detected deleted deployment (sub gone): %s/%s in sub %s", *key, sub_id)
        rows.append({
            "TimeGenerated": now.isoformat(),
            "subscriptionId_s": prev.get("subscriptionId_s", ""),
            "subscriptionName_s": prev.get("subscriptionName_s", ""),
            "resourceId_s": prev.get("resourceId_s", ""),
            "resourceName_s": prev.get("resourceName_s", ""),
            "location_s": prev.get("location_s", ""),
            "kind_s": prev.get("kind_s", ""),
            "deploymentName_s": prev.get("deploymentName_s", ""),
            "modelName_s": prev.get("modelName_s", ""),
            "modelVersion_s": prev.get("modelVersion_s", ""),
            "skuName_s": prev.get("skuName_s", ""),
            "skuCapacity_d": 0.0,
            "tpmLimit_d": 0.0,
            "rpmLimit_d": 0.0,
            "isDeleted_b": True,
        })
    return rows


async def run() -> None:
    now = datetime.now(timezone.utc)
    semaphore = asyncio.Semaphore(_MAX_PARALLEL)
    subscriptions = list_subscriptions()
    ingestion = get_ingestion_client()

    logger.debug("Resolved %d subscriptions for deployment config", len(subscriptions))
    logger.info(
        "Starting deployment config for %d subscriptions", len(subscriptions)
    )
    if not _WORKSPACE_ID:
        logger.warning(
            "LOG_ANALYTICS_WORKSPACE_ID not set — change detection disabled, "
            "all deployments will be written each run"
        )

    async def process_one(sub: dict) -> str:
        async with semaphore:
            sub_id = sub["subscriptionId"]
            watermark = read_watermark(_WATERMARK_STREAM, sub_id)
            logger.debug("Sub %s: watermark=%s, cutoff=%s", sub_id, watermark, now - timedelta(minutes=30))

            if watermark and watermark >= now - timedelta(minutes=30):
                logger.info("Sub %s: already up to date", sub_id)
                return "skipped"

            try:
                logger.debug("Sub %s: collecting deployment configs", sub_id)
                rows = await asyncio.to_thread(_collect, sub, now)
                if rows:
                    await asyncio.to_thread(
                        ingestion.upload, _DCR_RULE_ID, _STREAM_NAME, rows
                    )
                    logger.info(
                        "Sub %s: ingested %d deployment rows", sub_id, len(rows)
                    )
                    mark_success(_WATERMARK_STREAM, sub_id, now)
                    return "ingested"
                else:
                    logger.info("Sub %s: no deployment changes detected", sub_id)
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
        "Deployment config complete: %d ingested, %d skipped, %d failed (of %d)",
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
                        "Sub %s (gone): emitted %d deletion markers for deployments", sub_id, len(rows)
                    )
            except Exception:
                logger.error("Sub %s (gone): failed to emit deployment deletion markers", sub_id, exc_info=True)
