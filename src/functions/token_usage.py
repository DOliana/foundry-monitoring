"""Collect token usage metrics from Azure Monitor with a 30-minute delay."""

import asyncio
import logging
import os
from datetime import datetime, timedelta, timezone

from azure.monitor.querymetrics import MetricAggregationType, MetricsClient

from shared.arm import list_deployments, list_instances, list_subscriptions
from shared.clients import get_credential, get_ingestion_client
from shared.watermark import mark_failed, mark_success, read_watermark

logger = logging.getLogger(__name__)

_DCR_RULE_ID = os.environ.get("DCR_TOKEN_USAGE_IMMUTABLE_ID", "")
_STREAM_NAME = "Custom-TokenUsage_CL"
_WATERMARK_STREAM = "token_usage"
_MAX_PARALLEL = int(os.environ.get("MAX_PARALLEL_SUBS", "5"))
_COLLECTION_DELAY = timedelta(minutes=30)
_DEFAULT_LOOKBACK = timedelta(hours=24)
_GRANULARITY = timedelta(minutes=5)


def _query_metrics(
    resource_id: str,
    location: str,
    start: datetime,
    end: datetime,
) -> dict[tuple[str, datetime], dict]:
    """Query ProcessedPromptTokens and GeneratedTokens for a single resource."""
    endpoint = f"https://{location}.metrics.monitor.azure.com"
    client = MetricsClient(endpoint=endpoint, credential=get_credential())

    results = client.query_resources(
        resource_ids=[resource_id],
        metric_namespace="Microsoft.CognitiveServices/accounts",
        metric_names=["ProcessedPromptTokens", "GeneratedTokens"],
        timespan=(start, end),
        granularity=_GRANULARITY,
        aggregations=[MetricAggregationType.TOTAL],
        filter="ModelDeploymentName eq '*'",
    )

    metric_data: dict[tuple[str, datetime], dict] = {}
    for result in results:
        for metric in result.metrics:
            logger.debug("Processing metric %s with %d timeseries", metric.name, len(metric.timeseries))
            for ts_element in metric.timeseries:
                deployment = (
                    ts_element.metadata_values.get("modeldeploymentname", "")
                    if ts_element.metadata_values
                    else ""
                )
                for dp in ts_element.data:
                    if dp.total is None:
                        continue
                    key = (deployment, dp.timestamp)
                    if key not in metric_data:
                        metric_data[key] = {
                            "deployment": deployment,
                            "timestamp": dp.timestamp,
                            "promptTokens": 0.0,
                            "completionTokens": 0.0,
                        }
                    if metric.name == "ProcessedPromptTokens":
                        metric_data[key]["promptTokens"] = dp.total
                    elif metric.name == "GeneratedTokens":
                        metric_data[key]["completionTokens"] = dp.total

    return metric_data


def _collect(sub: dict, window_start: datetime, window_end: datetime) -> list[dict]:
    """Collect token usage for all instances in a subscription."""
    sub_id = sub["subscriptionId"]
    sub_name = sub["displayName"]

    instances = list_instances(sub_id)
    rows = []
    logger.debug("Sub %s: found %d instances for token usage", sub_id, len(instances))

    for inst in instances:
        resource_id = inst["resourceId"]
        location = inst["location"]
        instance_name = inst["name"]

        # Build deployment → model name map
        deployments = list_deployments(resource_id)
        model_map = {}
        for d in deployments:
            props = d.get("properties", {})
            model = props.get("model", {})
            model_map[d["name"]] = model.get("name", "")

        if not deployments:
            logger.debug("Instance %s: no deployments, skipping", instance_name)
            continue

        logger.debug("Instance %s: querying metrics for %d deployments (window %s – %s)",
                      instance_name, len(deployments), window_start.isoformat(), window_end.isoformat())
        metric_data = _query_metrics(resource_id, location, window_start, window_end)
        logger.debug("Instance %s: got %d metric data points", instance_name, len(metric_data))

        for (deployment, ts), values in metric_data.items():
            total = values["promptTokens"] + values["completionTokens"]
            rows.append(
                {
                    "TimeGenerated": ts.isoformat(),
                    "timestamp_t": ts.isoformat(),
                    "subscriptionId_s": sub_id.lower(),
                    "subscriptionName_s": sub_name,
                    "resourceId_s": resource_id.lower(),
                    "resourceName_s": instance_name,
                    "location_s": location,
                    "deploymentName_s": deployment,
                    "modelName_s": model_map.get(deployment, ""),
                    "promptTokens_d": values["promptTokens"],
                    "completionTokens_d": values["completionTokens"],
                    "totalTokens_d": total,
                }
            )

    return rows


async def run() -> None:
    now = datetime.now(timezone.utc)
    window_end = now - _COLLECTION_DELAY
    semaphore = asyncio.Semaphore(_MAX_PARALLEL)
    subscriptions = list_subscriptions()
    ingestion = get_ingestion_client()

    logger.debug("Resolved %d subscriptions for token usage", len(subscriptions))
    logger.info(
        "Starting token usage for %d subscriptions (window end: %s)",
        len(subscriptions),
        window_end.isoformat(),
    )

    async def process_one(sub: dict) -> str:
        async with semaphore:
            sub_id = sub["subscriptionId"]
            watermark = read_watermark(_WATERMARK_STREAM, sub_id)
            logger.debug("Sub %s: watermark=%s, window_end=%s", sub_id, watermark, window_end)

            if watermark and watermark >= window_end:
                logger.info("Sub %s: already up to date", sub_id)
                return "skipped"

            window_start = (
                watermark if watermark else (window_end - _DEFAULT_LOOKBACK)
            )
            logger.debug("Sub %s: collection window %s – %s", sub_id, window_start.isoformat(), window_end.isoformat())

            try:
                logger.debug("Sub %s: collecting token usage", sub_id)
                rows = await asyncio.to_thread(
                    _collect, sub, window_start, window_end
                )
                if rows:
                    await asyncio.to_thread(
                        ingestion.upload, _DCR_RULE_ID, _STREAM_NAME, rows
                    )
                    logger.info(
                        "Sub %s: ingested %d token usage rows", sub_id, len(rows)
                    )
                    mark_success(_WATERMARK_STREAM, sub_id, window_end)
                    return "ingested"
                else:
                    logger.info("Sub %s: no token usage data found", sub_id)
                    mark_success(_WATERMARK_STREAM, sub_id, window_end)
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
        "Token usage complete: %d ingested, %d skipped, %d failed (of %d)",
        ingested, skipped, failed, len(subscriptions),
    )
