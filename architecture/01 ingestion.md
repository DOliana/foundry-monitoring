# 01 — Ingestion Layer

## Context

The monitoring solution for Azure AI Foundry / Azure OpenAI needs to collect data from multiple Azure APIs, store it durably, and make it available for dashboards and alerts. This document covers the **ingestion layer** — the compute, orchestration, and write patterns that move data from source APIs into the data store.

### Target state

Automated, scheduled data collection with self-healing gap-fill on failure, writing to Log Analytics as the single data store.

---

## Data streams

There are two categories of data: **push-based** (already handled) and **pull-based** (needs ingestion compute).

### Push-based — no ingestion needed

| Source | Log Analytics table | How it gets there |
|---|---|---|
| Platform metrics (tokens, latency, errors, rate limits) | `AzureMetrics` | Diagnostic settings on each Foundry instance |
| Per-request logs (deployment name, model, response bytes) | `AzureDiagnostics` | Diagnostic settings on each Foundry instance |

See `Set-FoundryDiagnosticSettings.ps1` as an example on how to set this up.

### Pull-based — requires ingestion

| Stream | Source API | Custom table | Granularity | Collection frequency |
|---|---|---|---|---|
| **Quota snapshots** | ARM REST `/usages` endpoint | `QuotaSnapshot_CL` | Per subscription × region × model | Every 15 minutes |
| **Deployment config** | ARM REST `/deployments` endpoint | `DeploymentConfig_CL` | Per instance × deployment | Every 1 hour |
| **Token usage timeseries** | Azure Monitor Metrics API | `TokenUsage_CL` | Per instance × deployment × 5-min interval | Every 1 hour (delayed 30 min) |

---

## Compute: Azure Functions (Flex Consumption)

### Decision

Use **Azure Functions on the Flex Consumption plan** with a **system-assigned managed identity**.

### Alternatives considered

| Option | Verdict | Reasoning |
|---|---|---|
| **Azure Functions (Flex Consumption)** | **Selected** | 30-minute timeout, scales to zero, most established serverless compute on Azure, easy to govern and deploy via Bicep |
| **Azure Functions on App Service Plan** | Viable alternative | No timeout limits (always-on), predictable monthly cost, no cold starts. Trade-off: you pay for the plan 24/7 even when functions are idle. A B1/S1 plan is cheap (~$13–55/month) but doesn't scale to zero. Good fit if cold starts or timeout headroom are concerns, or if the org already runs App Service workloads on a shared plan. |
| **Azure Container Apps Job** | Viable fallback | No timeout ceiling, code stays close to notebook logic; but requires ACR + Container Apps Environment = more infra to manage |
| **Azure Data Factory** | Rejected | ADF excels at "copy from source A to sink B" but our ingestion requires iterative API orchestration with cross-call dependencies (instances depend on subscriptions, deployments depend on instances). ADF would become an orchestration wrapper around Functions — adding cost and complexity without removing the need for custom code |
| **Azure Automation (Python runbook)** | Rejected | Older platform, Python version constraints, limited ecosystem |

### Parallelism: in-process async with configurable degree of parallelism

Cross-subscription enumeration is the slowest part of each function. Two approaches were evaluated:

| Approach | How it works | Pros | Cons |
|---|---|---|---|
| **In-process async (selected)** | `asyncio.gather` with a `Semaphore(MAX_PARALLEL_SUBS)` inside each function | No new dependencies; collect-then-flush stays intact; single invocation, simple debugging | All parallelism shares one function instance's memory and timeout budget |
| **Durable Functions fan-out/fan-in** | Orchestrator spawns one activity per subscription, fan-in merges results | True parallel execution across instances; per-subscription retry; no shared timeout | Adds durable task framework dependency; activity results serialized through Azure Storage; more complex to reason about |

**Decision:** Start with in-process async. At enterprise scale (10–15 subscriptions), `asyncio.gather` with `MAX_PARALLEL_SUBS=5` means 2–3 serial batches — well within the 30-min Flex Consumption timeout. `MAX_PARALLEL_SUBS` is exposed as an app setting, adjustable without redeployment.

**Graduation criteria for Durable Functions:** Revisit if subscription count exceeds ~30 and individual subscription processing takes >2 min, or if per-subscription retry isolation becomes a requirement (one subscription's API failure shouldn't block the others).

```python
# Configurable via app setting MAX_PARALLEL_SUBS (default: 5)
MAX_PARALLEL_SUBS = int(os.environ.get("MAX_PARALLEL_SUBS", "5"))

async def ingest_token_usage(subscriptions):
    semaphore = asyncio.Semaphore(MAX_PARALLEL_SUBS)

    async def process_one(sub):
        async with semaphore:
            sub_id = sub["subscriptionId"]
            watermark = read_watermark("token_usage", sub_id)
            window_end = utcnow() - timedelta(minutes=30)

            if watermark >= window_end:
                return  # already up to date

            instances = await get_instances(sub)
            rows = []
            for inst in instances:
                metrics = await query_metrics(inst, watermark, window_end)
                rows.extend(metrics)

            await ingestion_client.upload(rule_id, stream_name, rows)
            update_watermark("token_usage", sub_id, window_end)

    results = await asyncio.gather(
        *[process_one(s) for s in subscriptions],
        return_exceptions=True  # one sub's failure doesn't cancel the others
    )

    # Log failures — failed subs retain their watermark and retry next run
    for sub, result in zip(subscriptions, results):
        if isinstance(result, Exception):
            logging.error(f"Failed for {sub['subscriptionId']}: {result}")
```

### Design: 3 independent timer-triggered functions with staggered per-subscription writes

```
┌─────────────────── Azure Function App ────────────────────────┐
│                  (Flex Consumption, Managed Identity)          │
│                  App setting: MAX_PARALLEL_SUBS = 5            │
│                                                               │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │ fn_quota_snapshot  (timer: every 15 min)                │  │
│  │  1. Enumerate subscriptions (single ARM call)           │  │
│  │  2. For each sub (parallel, semaphore-bound):           │  │
│  │     a. Read per-sub watermark from Table Storage        │  │
│  │     b. Collect quota data from ARM API                  │  │
│  │     c. POST to Logs Ingestion API                       │  │
│  │     d. Update per-sub watermark on 204 response         │  │
│  │  3. Log failures; failed subs retry next run            │  │
│  └─────────────────────────────────────────────────────────┘  │
│                                                               │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │ fn_deployment_config  (timer: every 1 hour)             │  │
│  │  1. Enumerate subscriptions                             │  │
│  │  2. For each sub (parallel, semaphore-bound):           │  │
│  │     a. Read per-sub watermark                           │  │
│  │     b. Collect deployment configs from ARM              │  │
│  │     c. Query Log Analytics for last stable snapshot     │  │
│  │     d. Diff: only write changed deployments             │  │
│  │     e. Update per-sub watermark                         │  │
│  │  3. Log failures; failed subs retry next run            │  │
│  └─────────────────────────────────────────────────────────┘  │
│                                                               │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │ fn_token_usage  (timer: every 1 hour, T+30min delay)    │  │
│  │  1. Enumerate subscriptions                             │  │
│  │  2. For each sub (parallel, semaphore-bound):           │  │
│  │     a. Read per-sub watermark                           │  │
│  │     b. Query Monitor Metrics API for 5-min intervals    │  │
│  │        from watermark to (now - 30 min)                 │  │
│  │     c. POST to Logs Ingestion API                       │  │
│  │     d. Update per-sub watermark                         │  │
│  │  3. Log failures; failed subs retry next run            │  │
│  └─────────────────────────────────────────────────────────┘  │
│                                                               │
│  Watermark: Azure Table Storage (per stream × subscription)   │
└───────────────────────────────────────────────────────────────┘
```

**Why 3 separate functions (not 1):**

- **Independent schedules** — quotas change faster (15-min) than deployments (1h)
- **Failure isolation** — if the quota API is down, token usage collection still runs
- **Simpler debugging** — each function has its own logs, metrics, and invocation history

### Identity model

The Function App's **system-assigned managed identity** requires RBAC across all target subscriptions:

| Role | Scope | Purpose |
|---|---|---|
| Monitoring Reader | Each Foundry instance (or subscription) | Read Azure Monitor metrics |
| Cognitive Services Usages Reader | Each subscription | Read quota data via `/usages` endpoint |
| Reader (or Cognitive Services User) | Each subscription | Enumerate Cognitive Services accounts and deployments |
| Log Analytics Data Reader | Log Analytics workspace | Query existing data for change detection (fn_deployment_config) |
| Monitoring Metrics Publisher | Data Collection Rule | Write to custom tables via Logs Ingestion API |

See `RBAC_REQUIREMENTS.md` for detailed permission mappings.

---

## Data store: Log Analytics (single store)

### Decision

Use **Log Analytics** as the single data store for both push-based and pull-based data. Pull-based data is written to **custom tables** via the **Logs Ingestion API** (Data Collection Rules / Data Collection Endpoints).

### Why single store

- Reduces operational complexity — one query language (KQL), one set of access controls, one retention policy
- Log Analytics is already deployed for the push-based diagnostic data
- All visualization tools (Workbooks, Grafana, Power BI) can connect to a single Log Analytics workspace

### Log Analytics is append-only — consistency patterns

Log Analytics does not support upsert, update, or delete. Every write appends new rows. This requires specific patterns to maintain data correctness.

#### Challenge 1: Duplicate rows after gap-fill reruns

**Scenario:** A function fails after a partial write. The watermark doesn't update. The next run re-collects and re-writes overlapping data.

**Mitigation:** Dedup at query time via **saved KQL functions**. All dashboards and alerts reference the saved function, never the raw table:

```kql
// Saved function: fn_TokenUsage
// All consumers call fn_TokenUsage() instead of the raw table
TokenUsage_CL
| summarize arg_max(TimeGenerated, *) by timestamp_t, subscriptionId_s, resourceId_s, deploymentName_s
```

This pattern is enforced by creating saved functions for each custom table:

| Saved function | Dedup key |
|---|---|
| `fn_QuotaSnapshot()` | `(timestamp, subscriptionId, region, model)` |
| `fn_DeploymentConfig()` | `(resourceId, deploymentName)` |
| `fn_TokenUsage()` | `(timestamp, subscriptionId, resourceId, deploymentName)` |

**Rule: No dashboard, alert, or workbook queries the raw `*_CL` table directly.**

#### Challenge 2: Snapshot data accumulation

**Scenario:** Deployment config snapshots are ingested every hour. Old configurations remain in the table alongside new ones.

**Mitigation:** The `fn_deployment_config` function performs **change detection** — it queries Log Analytics for the last known snapshot and only writes rows where the configuration actually changed (e.g., TPM limit resized). This minimizes writes and keeps the table clean.

#### Challenge 3: Late-arriving / incomplete metrics

**Scenario:** Azure Monitor Metrics API may return incomplete data for intervals that haven't fully closed yet.

**Mitigation:** The `fn_token_usage` function collects data with a **30-minute delay** — it only queries for intervals ending 30+ minutes ago. This ensures all 5-minute windows have finalized before ingestion. This needs to be validated with the customer as it means dashboards show data with a 30-minute lag.

#### Challenge 4: Ingestion API partial batch failure

**Scenario:** The Logs Ingestion API accepts a batch, returns a 5xx error, but some rows were committed internally.

**Mitigation:** The watermark does not update on non-204 responses, so the next run re-ingests the full window. The saved function dedup handles any resulting duplicates. The Logs Ingestion API's transactional behavior within a single call **needs investigation** (support case or empirical testing) — but the architecture is resilient regardless.

---

## Watermark table

A table in **Azure Table Storage** (same storage account used by the Function App) tracks the last successfully ingested timestamp **per data stream × per subscription**.

| PartitionKey | RowKey | last_success_utc | last_attempt_utc | status |
|---|---|---|---|---|
| `quota_snapshots` | `sub-aaaa-1111` | 2026-03-16T14:00:00Z | 2026-03-16T14:15:00Z | `success` |
| `quota_snapshots` | `sub-bbbb-2222` | 2026-03-16T14:00:00Z | 2026-03-16T14:15:00Z | `success` |
| `deployment_config` | `sub-aaaa-1111` | 2026-03-16T14:00:00Z | 2026-03-16T14:00:00Z | `success` |
| `deployment_config` | `sub-bbbb-2222` | 2026-03-16T14:00:00Z | 2026-03-16T14:00:00Z | `success` |
| `token_usage` | `sub-aaaa-1111` | 2026-03-16T13:30:00Z | 2026-03-16T14:00:00Z | `success` |
| `token_usage` | `sub-bbbb-2222` | 2026-03-16T12:30:00Z | 2026-03-16T13:00:00Z | `failed` |

**How it works:**

1. The function enumerates all subscriptions (single ARM call)
2. For each subscription, reads its stream-specific watermark
3. Collects data for that subscription from `last_success_utc` to the current window end
4. Writes that subscription's data to Log Analytics (single Ingestion API call per subscription)
5. On success (204): updates `last_success_utc` and `status = success`
6. On failure: updates `last_attempt_utc` and `status = failed`, watermark stays
7. Other subscriptions continue regardless — `return_exceptions=True` in `asyncio.gather`
8. Next scheduled run automatically covers the gap for failed subscriptions only

**Why per-subscription granularity:**

| Concern | Single watermark (before) | Per-subscription watermark (after) |
|---|---|---|
| Function crashes at sub #8 | All data lost, full retry of all subs | Subs 1–7 persisted, only 8+ retried |
| One sub's API is down | Entire function fails | Other subscriptions succeed |
| Memory usage | All subs' data in memory at once | One sub's data at a time |
| Dashboard during partial failure | No data at all | Data for successful subs visible immediately |

**Trade-off: temporary cross-subscription inconsistency.** A given time window may show data for 14 out of 15 subscriptions until the next run fills the gap. For capacity monitoring this is acceptable — partial data is better than no data.

**Manual backfill:** Reset a specific subscription's watermark to re-ingest its data, without affecting other subscriptions.

**Cost:** One row per stream × subscription. At 3 streams × 15 subscriptions = 45 rows. Negligible cost (< $0.01/month).

---

## Write pattern: staggered per-subscription writes

Each function processes subscriptions independently — collect, write, and update the watermark per subscription before moving to the next:

```python
async def process_one(sub):
    sub_id = sub["subscriptionId"]
    watermark = read_watermark(stream, sub_id)
    window_end = utcnow() - timedelta(minutes=30)

    if watermark >= window_end:
        return  # already up to date

    # 1. Collect this subscription's data
    instances = await get_instances(sub)
    rows = []
    for inst in instances:
        metrics = await query_metrics(inst, watermark, window_end)
        rows.extend(metrics)

    # 2. Write this subscription's data (single API call)
    await ingestion_client.upload(rule_id, stream_name, rows)

    # 3. Update this subscription's watermark
    update_watermark(stream, sub_id, window_end)
```

**Why staggered writes over collect-then-flush:**

- If the function crashes at subscription #8 of 15, subscriptions 1–7 are already persisted and their watermarks updated. Only 8–15 are retried on the next run.
- If one subscription's API is unavailable, the other 14 still succeed.
- Only one subscription's data is in memory at a time, reducing peak memory usage.

**Failure modes:**
- Collection fails for one sub → that sub's watermark unchanged, other subs unaffected, next run retries only that sub
- Write fails for one sub → same as above
- Watermark update fails for one sub → next run re-ingests that sub (dedup via saved KQL functions handles duplicates)
- Subscription enumeration fails → no work happens, next scheduled run retries (transient, self-healing)

---

## Retry and alerting

| Concern | Mechanism |
|---|---|
| Transient API failures | Azure Functions host retry policy: max 3 retries with exponential backoff |
| Persistent failures | Watermark stays at last success; next scheduled run backfills the gap automatically |
| Operational alerting | Azure Monitor alert on consecutive function failures (> 3 in a row) |
| Ingestion monitoring | Function App built-in metrics: invocation count, success rate, duration |


