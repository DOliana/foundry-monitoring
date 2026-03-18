"""ARM REST API helpers with nextLink pagination."""

import logging
import re

import requests

from shared.clients import get_credential

logger = logging.getLogger(__name__)

_ARM_BASE = "https://management.azure.com"
_GUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)


def _get_headers() -> dict:
    token = get_credential().get_token("https://management.azure.com/.default")
    return {"Authorization": f"Bearer {token.token}"}


def _get_paginated(url: str, params: dict | None = None) -> list:
    """GET with nextLink pagination."""
    results = []
    page = 0
    while url:
        resp = requests.get(url, headers=_get_headers(), params=params, timeout=60)
        resp.raise_for_status()
        body = resp.json()
        page_items = body.get("value", [])
        results.extend(page_items)
        page += 1
        logger.debug("Paginated GET page %d: %d items (total %d)", page, len(page_items), len(results))
        url = body.get("nextLink")
        params = None  # nextLink already includes query params
    return results


def list_subscriptions() -> list[dict]:
    """List all enabled Azure subscriptions."""
    results = []
    for s in _get_paginated(
        f"{_ARM_BASE}/subscriptions", {"api-version": "2022-12-01"}
    ):
        if s.get("state") != "Enabled":
            logger.debug("Skipping subscription %s (state=%s)", s.get("subscriptionId"), s.get("state"))
            continue
        sub_id = s["subscriptionId"]
        if not _GUID_RE.match(sub_id):
            logger.debug("Skipping subscription with invalid GUID: %s", sub_id)
            continue
        results.append({"subscriptionId": sub_id, "displayName": s["displayName"]})
    logger.debug("list_subscriptions returning %d enabled subscriptions", len(results))
    return results


def list_instances(subscription_id: str) -> list[dict]:
    """List Cognitive Services accounts in a subscription."""
    url = (
        f"{_ARM_BASE}/subscriptions/{subscription_id}"
        "/providers/Microsoft.CognitiveServices/accounts"
    )
    accounts = _get_paginated(url, {"api-version": "2024-10-01"})
    logger.debug("Sub %s: found %d Cognitive Services accounts", subscription_id, len(accounts))
    return [
        {
            "subscriptionId": subscription_id,
            "resourceGroup": acct["id"].split("/")[4],
            "name": acct["name"],
            "location": acct["location"],
            "kind": acct.get("kind", ""),
            "resourceId": acct["id"],
        }
        for acct in accounts
    ]


def list_deployments(resource_id: str) -> list[dict]:
    """List deployments for a Cognitive Services account."""
    url = f"{_ARM_BASE}{resource_id}/deployments"
    deployments = _get_paginated(url, {"api-version": "2024-10-01"})
    logger.debug("Resource %s: found %d deployments", resource_id, len(deployments))
    return deployments


def get_quota_usages(subscription_id: str, location: str) -> list[dict]:
    """Get quota/usage data for a subscription in a specific region."""
    url = (
        f"{_ARM_BASE}/subscriptions/{subscription_id}"
        f"/providers/Microsoft.CognitiveServices/locations/{location}/usages"
    )
    usages = _get_paginated(url, {"api-version": "2024-10-01"})
    logger.debug("Sub %s, %s: got %d quota usage records", subscription_id, location, len(usages))
    return usages


def list_models(subscription_id: str, location: str) -> list[dict]:
    """List all available models in a region from the Cognitive Services model catalog."""
    url = (
        f"{_ARM_BASE}/subscriptions/{subscription_id}"
        f"/providers/Microsoft.CognitiveServices/locations/{location}/models"
    )
    models = _get_paginated(url, {"api-version": "2024-10-01"})
    logger.debug("Sub %s, %s: got %d catalog models", subscription_id, location, len(models))
    return models
