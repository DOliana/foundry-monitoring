# Power BI KQL Queries — Azure AI Foundry Monitoring

These queries are designed for use as **Power BI DirectQuery / Import** data sources against the Log Analytics workspace. Each includes deduplication logic to handle overlapping or repeated ingestion runs.

---

## connecting Power BI

Get this information ready:

- Log analytics workspace information:
  - subscriptionid
  - resourcegroup name where your log analytics instance is
  - log analytics workspace name

Connect to each table by:

1. "Get Data" on the home ribbon in Power BI
2. select "Azure Data Explorer (Kusto)"
3. use the URL built out of the information above for Cluster: https://ade.loganalytics.io/subscriptions/**<LOG ANALYTICS SUBSCRIPTIONID>**/resourcegroups/**<LOG ANALYTICS RESOURCEGROUPNAME>**/providers/microsoft.operationalinsights/workspaces/**<LOG ANALYTICS WORKSPACE NAME>**
4. use the log analytics workspace name for database name
5. Add a KQL Query that includes deduplication in the "Table" Textbox. e.g. :
   ```
   TokenUsage_CL
   | summarize arg_max(TimeGenerated, *) by resourceId_s, deploymentName_s, timestamp_t
   ```
6. Optionally use "transform data" to remove unwanted columns or adapt column types
7. Make sure the table name is correct (will be Query X by default)

## Understanding the deduplication problem

| Table | Natural key | Why duplicates occur |
|---|---|---|
| `TokenUsage_CL` | resourceId + deployment + metric timestamp | Watermark failures cause the same 5-min bucket to be re-ingested; overlapping collection windows |
| `QuotaSnapshot_CL` | subscription + region + model + snapshot time | Change detection disabled, or same snapshot written on retry |
| `DeploymentConfig_CL` | resourceId + deployment + snapshot time | Change detection disabled, or same config written on retry |
| `ModelCatalog_CL` | subscription + region + model name + version | Change detection enabled; same catalog written on retry when change detection is disabled |

**Strategy:** For time-series tables we keep the **last-ingested row** per natural key using `arg_max(TimeGenerated, *)`. This is needed to avoid duplicates in the case a value is loaded multiple times due to retries or similar. For snapshot/config tables we additionally expose a "latest state" query.

---

## Basic queries

### TokenUsage

```kql
TokenUsage_CL
| summarize arg_max(TimeGenerated, *) by resourceId_s, deploymentName_s, timestamp_t
```

### SubscriptionQuota

```kql
QuotaSnapshot_CL
| summarize arg_max(TimeGenerated, *) by subscriptionId_s, region_s, model_s
```

### DeploymentQuota

```kql
DeploymentConfig_CL
| summarize arg_max(TimeGenerated, *) by resourceId_s, deploymentName_s
```

### ModelCatalog

```kql
ModelCatalog_CL
| summarize arg_max(TimeGenerated, *) by subscriptionId_s, region_s, modelName_s, modelVersion_s
| where isDeleted_b == false
```

### helper tables for schema (suggestion)

#### Used locations

```kql
DeploymentConfig_CL
| distinct location_s
```





## 1. Token Usage (fact table — time series)

Deduplicated 5-minute token usage per deployment. Use `timestamp_t` as the time axis (the original metric timestamp) and `TimeGenerated` only for dedup.

```kql
TokenUsage_CL
| summarize arg_max(TimeGenerated, *) by resourceId_s, deploymentName_s, timestamp_t
| extend ResourceGroup = tostring(split(resourceId_s, "/")[4])
| project
    Timestamp           = timestamp_t,
    SubscriptionId      = subscriptionId_s,
    SubscriptionName    = subscriptionName_s,
    ResourceGroup,
    ResourceId          = resourceId_s,
    ResourceName        = resourceName_s,
    Location            = location_s,
    DeploymentName      = deploymentName_s,
    ModelName           = modelName_s,
    PromptTokens        = promptTokens_d,
    CompletionTokens    = completionTokens_d,
    TotalTokens         = totalTokens_d,
    Granularity         = granularity_s
```

### 1b. Token Usage — hourly rollup

Pre-aggregated hourly grain for lighter Power BI models.

```kql
TokenUsage_CL
| summarize arg_max(TimeGenerated, *) by resourceId_s, deploymentName_s, timestamp_t
| summarize
    PromptTokens     = sum(promptTokens_d),
    CompletionTokens = sum(completionTokens_d),
    TotalTokens      = sum(totalTokens_d)
    by
    SubscriptionId   = subscriptionId_s,
    SubscriptionName = subscriptionName_s,
    ResourceId       = resourceId_s,
    ResourceName     = resourceName_s,
    Location         = location_s,
    DeploymentName   = deploymentName_s,
    ModelName        = modelName_s,
    Hour             = bin(timestamp_t, 1h)
```

---

## 2. Quota Snapshot (fact table — periodic snapshot)

Deduplicated quota data. The natural key is subscription + region + model + time bucket. Because snapshots are taken every ~1 hour, we bin `timestamp_t` to 1h to collapse any retries within the same window.

> **Join note:** QuotaSnapshot is collected at the **subscription + region** level (not per resource). Join to other tables via `SubscriptionId` + `Region`/`Location`.

```kql
QuotaSnapshot_CL
| extend SnapshotBucket = bin(timestamp_t, 1h)
| summarize arg_max(TimeGenerated, *) by subscriptionId_s, region_s, model_s, SnapshotBucket
| project
    Timestamp        = SnapshotBucket,
    SubscriptionId   = subscriptionId_s,
    SubscriptionName = subscriptionName_s,
    Region           = region_s,
    Model            = model_s,
    DeployedTPM      = deployedTPM_d,
    MaxTPM           = maxTPM_d,
    UtilizationPct   = utilizationPct_d
```

### 2b. Quota — latest state per model/region

Best for a "current capacity" page in Power BI.

```kql
QuotaSnapshot_CL
| summarize arg_max(TimeGenerated, *) by subscriptionId_s, region_s, model_s
| project
    LastUpdated      = TimeGenerated,
    SubscriptionId   = subscriptionId_s,
    SubscriptionName = subscriptionName_s,
    Region           = region_s,
    Model            = model_s,
    DeployedTPM      = deployedTPM_d,
    MaxTPM           = maxTPM_d,
    UtilizationPct   = utilizationPct_d
```

### 2c. Quota — hourly snapshot (deduplicated)

Since quota is now collected hourly, this query simply deduplicates within the 1h bucket — useful as an Import-mode table in Power BI.

```kql
QuotaSnapshot_CL
| extend Hour = bin(timestamp_t, 1h)
| summarize arg_max(TimeGenerated, *) by subscriptionId_s, region_s, model_s, Hour
| project
    Hour,
    SubscriptionId    = subscriptionId_s,
    SubscriptionName  = subscriptionName_s,
    Region            = region_s,
    Model             = model_s,
    DeployedTPM       = deployedTPM_d,
    MaxTPM            = maxTPM_d,
    UtilizationPct    = utilizationPct_d
```

---

## 3. Deployment Config (dimension table — SCD Type 2 style)

### 3a. Latest deployment configuration (current state)

Use this as a **dimension table** in your Power BI model, joined to Token Usage on `ResourceId + DeploymentName`.

```kql
DeploymentConfig_CL
| summarize arg_max(TimeGenerated, *) by resourceId_s, deploymentName_s
| extend ResourceGroup = tostring(split(resourceId_s, "/")[4])
| project
    LastUpdated      = TimeGenerated,
    SubscriptionId   = subscriptionId_s,
    SubscriptionName = subscriptionName_s,
    ResourceGroup,
    ResourceId       = resourceId_s,
    ResourceName     = resourceName_s,
    Location         = location_s,
    Kind             = kind_s,
    DeploymentName   = deploymentName_s,
    ModelName        = modelName_s,
    ModelVersion     = modelVersion_s,
    SkuName          = skuName_s,
    SkuCapacity      = skuCapacity_d,
    TpmLimit         = tpmLimit_d,
    RpmLimit         = rpmLimit_d
```

### 3b. Deployment config change history (deduplicated)

Full history of configuration changes over time, deduplicated to one row per
distinct configuration snapshot per day.

```kql
DeploymentConfig_CL
| extend SnapshotDay = bin(TimeGenerated, 1d)
| summarize arg_max(TimeGenerated, *) by resourceId_s, deploymentName_s, SnapshotDay
| project
    SnapshotDay,
    LastUpdated      = TimeGenerated,
    SubscriptionId   = subscriptionId_s,
    SubscriptionName = subscriptionName_s,
    ResourceId       = resourceId_s,
    ResourceName     = resourceName_s,
    Location         = location_s,
    Kind             = kind_s,
    DeploymentName   = deploymentName_s,
    ModelName        = modelName_s,
    ModelVersion     = modelVersion_s,
    SkuName          = skuName_s,
    SkuCapacity      = skuCapacity_d,
    TpmLimit         = tpmLimit_d,
    RpmLimit         = rpmLimit_d
| order by ResourceId asc, DeploymentName asc, SnapshotDay asc
```

---

## 4. Model Catalog (dimension table — daily snapshot)

### 4a. Latest model catalog (current state)

All models available in each region. Use as a **dimension table** to see which models could be deployed, their capabilities, lifecycle status, and deprecation dates.

```kql
ModelCatalog_CL
| summarize arg_max(TimeGenerated, *) by subscriptionId_s, region_s, modelName_s, modelVersion_s
| project
    LastUpdated         = TimeGenerated,
    SubscriptionId      = subscriptionId_s,
    SubscriptionName    = subscriptionName_s,
    Region              = region_s,
    ModelFormat         = modelFormat_s,
    ModelName           = modelName_s,
    ModelVersion        = modelVersion_s,
    LifecycleStatus     = lifecycleStatus_s,
    IsDefaultVersion    = isDefaultVersion_b,
    MaxCapacity         = maxCapacity_d,
    FineTune            = fineTune_b,
    Inference           = inference_b,
    ChatCompletion      = chatCompletion_b,
    Completion          = completion_b,
    Embeddings          = embeddings_b,
    ImageGeneration     = imageGeneration_b,
    DeprecationInference = deprecationInference_s,
    DeprecationFineTune  = deprecationFineTune_s,
    SkuNames            = skuNames_s
```

### 4b. Models approaching deprecation

Filters to models with a known inference deprecation date, sorted soonest-first. Useful for proactive migration planning.

```kql
ModelCatalog_CL
| summarize arg_max(TimeGenerated, *) by subscriptionId_s, region_s, modelName_s, modelVersion_s
| where isnotempty(deprecationInference_s)
| extend DeprecationDate = todatetime(deprecationInference_s)
| where DeprecationDate >= now()
| project
    Region              = region_s,
    ModelName           = modelName_s,
    ModelVersion        = modelVersion_s,
    LifecycleStatus     = lifecycleStatus_s,
    DeprecationDate,
    DaysUntilDeprecation = datetime_diff('day', DeprecationDate, now()),
    SkuNames            = skuNames_s
| order by DeprecationDate asc
```

### 4c. Available models by capability

Quick summary of which models support a given capability per region.

```kql
ModelCatalog_CL
| summarize arg_max(TimeGenerated, *) by subscriptionId_s, region_s, modelName_s, modelVersion_s
| where inference_b == true
| summarize
    Models = make_set(strcat(modelName_s, " v", modelVersion_s))
    by Region = region_s, ChatCompletion = chatCompletion_b, Embeddings = embeddings_b, ImageGeneration = imageGeneration_b
| order by Region asc
```

---

## 5. Cross-table: Token Usage enriched with Deployment Config

Join token usage with the latest deployment config to get model version, SKU, and capacity limits alongside consumption data. Useful as a single Power BI table or for calculated utilization metrics.

```kql
let config = DeploymentConfig_CL
    | summarize arg_max(TimeGenerated, *) by resourceId_s, deploymentName_s;
let usage = TokenUsage_CL
    | summarize arg_max(TimeGenerated, *) by resourceId_s, deploymentName_s, timestamp_t;
usage
| join kind=leftouter config on resourceId_s, deploymentName_s
| extend ResourceGroup = tostring(split(resourceId_s, "/")[4])
| project
    Timestamp           = timestamp_t,
    SubscriptionId      = subscriptionId_s,
    SubscriptionName    = subscriptionName_s,
    ResourceGroup,
    ResourceId          = resourceId_s,
    ResourceName        = resourceName_s,
    Location            = location_s,
    DeploymentName      = deploymentName_s,
    ModelName           = coalesce(modelName_s1, modelName_s),
    ModelVersion        = modelVersion_s,
    SkuName             = skuName_s,
    SkuCapacity         = skuCapacity_d,
    TpmLimit            = tpmLimit_d,
    RpmLimit            = rpmLimit_d,
    PromptTokens        = promptTokens_d,
    CompletionTokens    = completionTokens_d,
    TotalTokens         = totalTokens_d
```

### 5b. Hourly utilization vs capacity

Compares actual hourly token consumption against the configured TPM limit per deployment.

```kql
let config = DeploymentConfig_CL
    | summarize arg_max(TimeGenerated, *) by resourceId_s, deploymentName_s;
let hourly = TokenUsage_CL
    | summarize arg_max(TimeGenerated, *) by resourceId_s, deploymentName_s, timestamp_t
    | summarize
        TotalTokens = sum(totalTokens_d)
        by resourceId_s, deploymentName_s, Hour = bin(timestamp_t, 1h);
hourly
| join kind=leftouter config on resourceId_s, deploymentName_s
| extend
    // TPM limit is per minute; multiply by 60 for hourly capacity
    HourlyCapacity    = tpmLimit_d * 60,
    UtilizationPct    = iff(tpmLimit_d > 0, round(TotalTokens / (tpmLimit_d * 60) * 100, 2), 0.0)
| project
    Hour,
    SubscriptionId   = subscriptionId_s,
    ResourceId       = resourceId_s,
    ResourceName     = resourceName_s,
    Location         = location_s,
    DeploymentName   = deploymentName_s,
    ModelName        = modelName_s1,
    TotalTokens,
    TpmLimit         = tpmLimit_d,
    HourlyCapacity,
    UtilizationPct
```

---

## 6. Cross-table: Deployed models vs available catalog

Compares what is currently deployed against the full model catalog to identify newer versions or models nearing deprecation.

```kql
let deployed = DeploymentConfig_CL
    | summarize arg_max(TimeGenerated, *) by resourceId_s, deploymentName_s
    | project ResourceId = resourceId_s, DeploymentName = deploymentName_s,
             ModelName = modelName_s, ModelVersion = modelVersion_s,
             Location = location_s, SubscriptionId = subscriptionId_s;
let catalog = ModelCatalog_CL
    | summarize arg_max(TimeGenerated, *) by subscriptionId_s, region_s, modelName_s, modelVersion_s
    | project SubscriptionId = subscriptionId_s, Region = region_s,
             CatalogModelName = modelName_s, CatalogModelVersion = modelVersion_s,
             LifecycleStatus = lifecycleStatus_s, IsDefaultVersion = isDefaultVersion_b,
             DeprecationInference = deprecationInference_s;
deployed
| join kind=leftouter catalog
    on $left.SubscriptionId == $right.SubscriptionId,
       $left.Location == $right.Region,
       $left.ModelName == $right.CatalogModelName
| where CatalogModelVersion != ModelVersion and IsDefaultVersion == true
| project
    ResourceId,
    DeploymentName,
    ModelName,
    DeployedVersion     = ModelVersion,
    LatestVersion       = CatalogModelVersion,
    LifecycleStatus,
    DeprecationInference,
    Location
| order by ModelName asc, DeployedVersion asc
```

---

## 7. Subscription dimension

Distinct subscription list derived from the data, useful as a Power BI slicer dimension.

```kql
TokenUsage_CL
| distinct SubscriptionId = subscriptionId_s, SubscriptionName = subscriptionName_s
| union (
    QuotaSnapshot_CL
    | distinct SubscriptionId = subscriptionId_s, SubscriptionName = subscriptionName_s
)
| distinct SubscriptionId, SubscriptionName
```

---

## 8. Operational Monitoring (platform diagnostic logs & metrics)

These queries use the **platform diagnostic data** sent via `Set-FoundryDiagnosticSettings.ps1` (AllMetrics, RequestResponse, AzureOpenAIRequestUsage, Audit). They target the standard `AzureDiagnostics` and `AzureMetrics` tables — no custom ingestion needed.

### 8a. Throttling (429) timeline

Dedicated view of throttled requests over time — the most actionable operational signal.

```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.COGNITIVESERVICES"
| where Category == "RequestResponse"
| where toint(ResultSignature) == 429
| summarize
    ThrottledRequests = count()
    by
    Resource = _ResourceId,
    Bin      = bin(TimeGenerated, 5m)
| order by Bin desc
```

### 8b. Request latency percentiles (P50 / P95 / P99)

End-to-end latency distribution per API operation (e.g. `ChatCompletions_Create`), useful for SLA tracking.

```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.COGNITIVESERVICES"
| where Category == "RequestResponse"
| extend DurationMs = todouble(DurationMs)
| where isnotempty(DurationMs)
| summarize
    P50  = percentile(DurationMs, 50),
    P95  = percentile(DurationMs, 95),
    P99  = percentile(DurationMs, 99),
    Requests = count()
    by
    Resource       = _ResourceId,
    OperationName,
    Bin            = bin(TimeGenerated, 1h)
| order by Bin desc
```

### 8c. Content filtering triggers

Requests blocked or modified by Azure AI content safety filters.

```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.COGNITIVESERVICES"
| where Category == "RequestResponse"
| where toint(ResultSignature) == 400
| where properties_s has "content_filter" or properties_s has "ContentFilter"
| summarize
    FilteredRequests = count()
    by
    Resource       = _ResourceId,
    Bin            = bin(TimeGenerated, 1h)
| order by Bin desc
```

### 8d. Platform metrics — capacity utilization over time (AzureMetrics)

Uses the native `AzureMetrics` table for metrics like `ProcessedPromptTokens`, `GeneratedTokens`, `TokenTransaction`.

```kql
AzureMetrics
| where ResourceProvider == "MICROSOFT.COGNITIVESERVICES"
| where MetricName in ("ProcessedPromptTokens", "GeneratedTokens", "TokenTransaction")
| summarize
    Total = sum(Total),
    Avg   = avg(Average),
    Max   = max(Maximum)
    by
    ResourceId = _ResourceId,
    MetricName,
    Bin = bin(TimeGenerated, 1h)
| order by Bin desc, ResourceId asc
```

---

## Power BI Model Guidance

**Recommended relationships:**

```
TokenUsage (fact)
  ├── DeploymentConfig (dim)  on ResourceId + DeploymentName   (1:many)
  ├── ModelCatalog (dim)      on SubscriptionId + Location/Region + ModelName  (1:many)
  ├── Subscription (dim)      on SubscriptionId                (1:many)
  └── Calendar (dim)          on Timestamp (date part)         (1:many)

QuotaSnapshot (fact)
  ├── Subscription (dim)      on SubscriptionId                (1:many)
  └── Calendar (dim)          on Timestamp (date part)         (1:many)

ModelCatalog (dim)
  └── Subscription (dim)      on SubscriptionId                (1:many)

Note: QuotaSnapshot → TokenUsage is a many-to-many via SubscriptionId + Region.
Use a bridge or DAX measure rather than a direct relationship.
```

**Join keys by table:**

| Table | Available keys | Joins to |
|---|---|---|
| `TokenUsage` | `ResourceId`, `DeploymentName`, `SubscriptionId`, `Location` | DeploymentConfig on `ResourceId` + `DeploymentName` |
| `DeploymentConfig` | `ResourceId`, `DeploymentName`, `SubscriptionId`, `Location`, `ResourceGroup` | TokenUsage on `ResourceId` + `DeploymentName` |
| `QuotaSnapshot` | `SubscriptionId`, `Region` | Subscription dim on `SubscriptionId`; correlate to resources via `SubscriptionId` + `Region`=`Location` |
| `ModelCatalog` | `SubscriptionId`, `Region`, `ModelName`, `ModelVersion` | Subscription dim on `SubscriptionId`; DeploymentConfig on `ModelName` + `Location`=`Region` |

> `ResourceId` follows the ARM pattern `/subscriptions/{subId}/resourceGroups/{rgName}/providers/Microsoft.CognitiveServices/accounts/{name}`. The queries decompose `ResourceGroup` from index `[4]` of the split for convenience.

**Tips:**
- Use **Import mode** with the hourly rollup queries (1b, 2c) for dashboards that don't need 5-minute granularity — this significantly reduces model size.
- Use **DirectQuery** with the detailed queries (1, 2) only if you need live data or the volume is too large for import.
- Set scheduled refresh to match your function collection interval (~60 min for token usage, ~60 min for quota snapshots).
- The `arg_max(TimeGenerated, *)` pattern ensures that if the same data point is ingested multiple times (watermark failure, retry, overlapping window), only the most recent ingestion is kept.
