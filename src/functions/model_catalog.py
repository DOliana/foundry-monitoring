"""Collect available models from the Cognitive Services model catalog per region."""

import asyncio
import logging
import os
from datetime import datetime, timedelta, timezone

from azure.monitor.query import LogsQueryClient, LogsQueryStatus

from requests.exceptions import HTTPError

from shared.arm import list_models, list_instances, list_subscriptions
from shared.clients import get_credential, get_ingestion_client
from shared.watermark import mark_failed, mark_success, read_watermark

logger = logging.getLogger(__name__)

_DCR_RULE_ID = os.environ.get("DCR_MODEL_CATALOG_IMMUTABLE_ID", "")
_STREAM_NAME = "Custom-ModelCatalog_CL"
_WATERMARK_STREAM = "model_catalog"
_MAX_PARALLEL = int(os.environ.get("MAX_PARALLEL_SUBS", "5"))
_WORKSPACE_ID = os.environ.get("LOG_ANALYTICS_WORKSPACE_ID", "")

_COMPARE_FIELDS = [
    "lifecycleStatus_s",
    "isDefaultVersion_b",
    "maxCapacity_d",
    "fineTune_b",
    "inference_b",
    "chatCompletion_b",
    "completion_b",
    "embeddings_b",
    "imageGeneration_b",
    "deprecationInference_s",
    "deprecationFineTune_s",
    "skuNames_s",
]


def _get_last_snapshot(sub_id: str) -> dict[tuple[str, str, str], dict]:
    """Query Log Analytics for the latest model catalog entry per region/model/version.

    Returns an empty dict if LOG_ANALYTICS_WORKSPACE_ID is not set, which
    disables change detection and causes all models to be written.
    """
    if not _WORKSPACE_ID:
        logger.debug("Change detection disabled — no LOG_ANALYTICS_WORKSPACE_ID")
        return {}

    client = LogsQueryClient(credential=get_credential())
    logger.debug("Querying last model catalog snapshot for sub %s", sub_id)
    query = (
        "ModelCatalog_CL"
        " | where subscriptionId_s == @sub_id"
        " | summarize arg_max(TimeGenerated, *) by region_s, modelName_s, modelVersion_s"
    )
    result = client.query_workspace(
        _WORKSPACE_ID,
        query,
        timespan=timedelta(days=14),
        additional_workspaces=None,
        query_parameters={"sub_id": sub_id},
    )

    snapshot: dict[tuple[str, str, str], dict] = {}
    if result.status == LogsQueryStatus.SUCCESS and result.tables:
        columns = [c.name for c in result.tables[0].columns]
        for row in result.tables[0].rows:
            row_dict = dict(zip(columns, row))
            key = (
                row_dict.get("region_s", ""),
                row_dict.get("modelName_s", ""),
                row_dict.get("modelVersion_s", ""),
            )
            snapshot[key] = row_dict
    logger.debug("Sub %s: loaded %d previous model catalog rows", sub_id, len(snapshot))
    return snapshot


def _collect(sub: dict, now: datetime) -> list[dict]:
    """Collect available models for each region, filtering to changes only."""
    sub_id = sub["subscriptionId"]
    sub_name = sub["displayName"]

    instances = list_instances(sub_id)
    locations = {inst["location"] for inst in instances}
    logger.debug("Sub %s: querying model catalog for %d locations", sub_id, len(locations))

    last_snapshot = _get_last_snapshot(sub_id)
    logger.debug("Sub %s: loaded %d previous snapshot entries", sub_id, len(last_snapshot))

    rows = []
    current_keys: set[tuple[str, str, str]] = set()

    for location in locations:
        try:
            models = list_models(sub_id, location)
        except HTTPError as exc:
            if exc.response is not None and exc.response.status_code in (404, 409):
                logger.warning(
                    "Sub %s, %s: HTTP %d listing models, skipping",
                    sub_id, location, exc.response.status_code,
                )
                continue
            raise
        logger.debug("Sub %s, %s: found %d catalog models", sub_id, location, len(models))

        for entry in models:
            model = entry.get("model", {})
            capabilities = model.get("capabilities", {})
            deprecation = model.get("deprecation", {})
            skus = model.get("skus", [])
            sku_names = ",".join(s.get("name", "") for s in skus) if skus else ""

            row = {
                "TimeGenerated": now.isoformat(),
                "subscriptionId_s": sub_id.lower(),
                "subscriptionName_s": sub_name,
                "region_s": location,
                "modelFormat_s": model.get("format", ""),
                "modelName_s": model.get("name", ""),
                "modelVersion_s": model.get("version", ""),
                "lifecycleStatus_s": model.get("lifecycleStatus", ""),
                "isDefaultVersion_b": model.get("isDefaultVersion", False),
                "maxCapacity_d": float(model.get("maxCapacity", 0)),
                "fineTune_b": capabilities.get("fineTune", "false").lower() == "true",
                "inference_b": capabilities.get("inference", "false").lower() == "true",
                "chatCompletion_b": capabilities.get("chatCompletion", "false").lower() == "true",
                "completion_b": capabilities.get("completion", "false").lower() == "true",
                "embeddings_b": capabilities.get("embeddings", "false").lower() == "true",
                "imageGeneration_b": capabilities.get("imageGeneration", "false").lower() == "true",
                "deprecationInference_s": deprecation.get("inference", ""),
                "deprecationFineTune_s": deprecation.get("fineTune", ""),
                "skuNames_s": sku_names,
                "isDeleted_b": False,
            }

            # Change detection: skip if identical to the last snapshot
            key = (location, row["modelName_s"], row["modelVersion_s"])
            current_keys.add(key)
            prev = last_snapshot.get(key)
            if prev is not None and all(
                row.get(f) == prev.get(f) for f in _COMPARE_FIELDS
            ):
                logger.debug("Skipping unchanged model %s/%s/%s", *key)
                continue

            rows.append(row)

    # Detect deleted models: present in snapshot but missing from ARM,
    # and not already marked as deleted in the previous snapshot.
    if last_snapshot:
        for key, prev in last_snapshot.items():
            if key in current_keys:
                continue
            if prev.get("isDeleted_b") is True:
                logger.debug("Already marked deleted: %s/%s/%s", *key)
                continue
            logger.info("Detected deleted model: %s/%s/%s", *key)
            rows.append({
                "TimeGenerated": now.isoformat(),
                "subscriptionId_s": prev.get("subscriptionId_s", ""),
                "subscriptionName_s": prev.get("subscriptionName_s", ""),
                "region_s": prev.get("region_s", ""),
                "modelFormat_s": prev.get("modelFormat_s", ""),
                "modelName_s": prev.get("modelName_s", ""),
                "modelVersion_s": prev.get("modelVersion_s", ""),
                "lifecycleStatus_s": prev.get("lifecycleStatus_s", ""),
                "isDefaultVersion_b": False,
                "maxCapacity_d": 0.0,
                "fineTune_b": False,
                "inference_b": False,
                "chatCompletion_b": False,
                "completion_b": False,
                "embeddings_b": False,
                "imageGeneration_b": False,
                "deprecationInference_s": prev.get("deprecationInference_s", ""),
                "deprecationFineTune_s": prev.get("deprecationFineTune_s", ""),
                "skuNames_s": "",
                "isDeleted_b": True,
            })

    return rows


async def run() -> None:
    now = datetime.now(timezone.utc)
    semaphore = asyncio.Semaphore(_MAX_PARALLEL)
    subscriptions = list_subscriptions()
    ingestion = get_ingestion_client()

    logger.debug("Resolved %d subscriptions for model catalog", len(subscriptions))
    logger.info("Starting model catalog for %d subscriptions", len(subscriptions))
    if not _WORKSPACE_ID:
        logger.warning(
            "LOG_ANALYTICS_WORKSPACE_ID not set — change detection disabled, "
            "all models will be written each run"
        )

    async def process_one(sub: dict) -> str:
        async with semaphore:
            sub_id = sub["subscriptionId"]
            watermark = read_watermark(_WATERMARK_STREAM, sub_id)

            # Run once per day — skip if already collected in the last 12 hours
            if watermark and watermark >= now - timedelta(hours=12):
                logger.info("Sub %s: model catalog already up to date", sub_id)
                return "skipped"

            try:
                rows = await asyncio.to_thread(_collect, sub, now)
                if rows:
                    await asyncio.to_thread(
                        ingestion.upload, _DCR_RULE_ID, _STREAM_NAME, rows
                    )
                    logger.info("Sub %s: ingested %d model catalog rows", sub_id, len(rows))
                    mark_success(_WATERMARK_STREAM, sub_id, now)
                    return "ingested"
                else:
                    logger.info("Sub %s: no model catalog data found", sub_id)
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
        "Model catalog complete: %d ingested, %d skipped, %d failed (of %d)",
        ingested, skipped, failed, len(subscriptions),
    )
