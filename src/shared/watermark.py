"""Watermark table operations for tracking ingestion progress."""

import logging
from datetime import datetime, timezone

from azure.core.exceptions import ResourceNotFoundError

from shared.clients import get_watermark_client

logger = logging.getLogger(__name__)


def read_watermark(stream: str, subscription_id: str) -> datetime | None:
    """Read the last successful ingestion timestamp for a stream/subscription pair."""
    try:
        entity = get_watermark_client().get_entity(
            partition_key=stream, row_key=subscription_id
        )
        ts = entity.get("last_success_utc", "")
        if not ts:
            logger.debug("Watermark %s/%s: no timestamp stored", stream, subscription_id)
            return None
        result = datetime.fromisoformat(ts)
        logger.debug("Watermark %s/%s: %s", stream, subscription_id, result.isoformat())
        return result
    except ResourceNotFoundError:
        logger.debug("Watermark %s/%s: not found", stream, subscription_id)
        return None


def mark_success(stream: str, subscription_id: str, window_end: datetime) -> None:
    """Update watermark after successful ingestion."""
    logger.debug("Marking watermark success %s/%s at %s", stream, subscription_id, window_end.isoformat())
    get_watermark_client().upsert_entity(
        {
            "PartitionKey": stream,
            "RowKey": subscription_id,
            "SubscriptionId": subscription_id,
            "last_success_utc": window_end.isoformat(),
            "last_attempt_utc": datetime.now(timezone.utc).isoformat(),
            "status": "success",
        }
    )


def mark_failed(stream: str, subscription_id: str) -> None:
    """Record a failed attempt without advancing the watermark."""
    logger.debug("Marking watermark failed %s/%s", stream, subscription_id)
    client = get_watermark_client()
    now = datetime.now(timezone.utc).isoformat()
    try:
        entity = client.get_entity(partition_key=stream, row_key=subscription_id)
        entity["last_attempt_utc"] = now
        entity["status"] = "failed"
        client.upsert_entity(entity)
    except ResourceNotFoundError:
        client.upsert_entity(
            {
                "PartitionKey": stream,
                "RowKey": subscription_id,
                "SubscriptionId": subscription_id,
                "last_success_utc": "",
                "last_attempt_utc": now,
                "status": "failed",
            }
        )
