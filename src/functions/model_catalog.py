"""Collect available models from the Cognitive Services model catalog per region."""

import asyncio
import logging
import os
from datetime import datetime, timedelta, timezone

from requests.exceptions import HTTPError

from shared.arm import list_models, list_instances, list_subscriptions
from shared.clients import get_ingestion_client
from shared.watermark import mark_failed, mark_success, read_watermark

logger = logging.getLogger(__name__)

_DCR_RULE_ID = os.environ.get("DCR_MODEL_CATALOG_IMMUTABLE_ID", "")
_STREAM_NAME = "Custom-ModelCatalog_CL"
_WATERMARK_STREAM = "model_catalog"
_MAX_PARALLEL = int(os.environ.get("MAX_PARALLEL_SUBS", "5"))


def _collect(sub: dict, now: datetime) -> list[dict]:
    """Collect available models for each region where the subscription has instances."""
    sub_id = sub["subscriptionId"]
    sub_name = sub["displayName"]

    instances = list_instances(sub_id)
    locations = {inst["location"] for inst in instances}
    logger.debug("Sub %s: querying model catalog for %d locations", sub_id, len(locations))

    rows = []
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

            rows.append({
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
            })

    return rows


async def run() -> None:
    now = datetime.now(timezone.utc)
    semaphore = asyncio.Semaphore(_MAX_PARALLEL)
    subscriptions = list_subscriptions()
    ingestion = get_ingestion_client()

    logger.debug("Resolved %d subscriptions for model catalog", len(subscriptions))
    logger.info("Starting model catalog for %d subscriptions", len(subscriptions))

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
