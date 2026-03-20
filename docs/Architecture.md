# Architecture Diagram

```mermaid
flowchart TB
    subgraph scanned["Scanned Resources (per subscription)"]
        CS["Azure AI Foundry /<br>Cognitive Services Accounts"]
        DEPLOYMENTS["Model Deployments"]
        QUOTAS["Quota / Usages API"]
        CATALOG["Model Catalog API"]
        METRICS["Azure Monitor Metrics API<br>(ProcessedPromptTokens,<br>GeneratedTokens)"]
    end

    subgraph arm["Azure Resource Manager"]
        ARM_API["ARM REST API"]
    end

    subgraph functions["Azure Functions (Flex Consumption)"]
        FN_QUOTA["fn_quota_snapshot<br>⏱ every 15 min"]
        FN_DEPLOY["fn_deployment_config<br>⏱ every 1 hour"]
        FN_TOKEN["fn_token_usage<br>⏱ every 1 hour"]
        FN_MODEL["fn_model_catalog<br>⏱ daily 06:00 UTC"]
    end

    subgraph storage["Azure Storage Account"]
        TABLE["Table Storage<br>(watermarks)"]
    end

    subgraph ingestion["Data Collection"]
        DCE["Data Collection Endpoint"]
        DCR_QS["DCR: QuotaSnapshot"]
        DCR_DC["DCR: DeploymentConfig"]
        DCR_TU["DCR: TokenUsage"]
        DCR_MC["DCR: ModelCatalog"]
    end

    subgraph loganalytics["Log Analytics Workspace"]
        T_QS["QuotaSnapshot_CL"]
        T_DC["DeploymentConfig_CL"]
        T_TU["TokenUsage_CL"]
        T_MC["ModelCatalog_CL"]
        T_AM["AzureMetrics"]
        T_AD["AzureDiagnostics"]
    end

    subgraph monitoring["Monitoring & Alerting"]
        APPI["Application Insights"]
        ALERTS["Alert Rules<br>(Scheduled Query Rules)"]
        AG["Action Group<br>(Email)"]
    end

    subgraph pushbased["Push-based (Diagnostic Settings)"]
        DIAG["Diagnostic Settings<br>on each Foundry instance"]
    end

    %% Scanned resources → ARM
    CS -->|"list instances"| ARM_API
    DEPLOYMENTS -->|"list deployments"| ARM_API
    QUOTAS -->|"/usages endpoint"| ARM_API
    CATALOG -->|"list models"| ARM_API

    %% ARM / Metrics → Functions (pull-based)
    ARM_API -->|"subscriptions,<br>instances, usages"| FN_QUOTA
    ARM_API -->|"subscriptions,<br>instances, deployments"| FN_DEPLOY
    ARM_API -->|"subscriptions,<br>instances"| FN_TOKEN
    ARM_API -->|"subscriptions,<br>instances, models"| FN_MODEL
    METRICS -->|"token metrics<br>(5-min granularity)"| FN_TOKEN

    %% Functions → Watermark table
    FN_QUOTA <-->|"read/write<br>watermark"| TABLE
    FN_DEPLOY <-->|"read/write<br>watermark"| TABLE
    FN_TOKEN <-->|"read/write<br>watermark"| TABLE
    FN_MODEL <-->|"read/write<br>watermark"| TABLE

    %% Functions → change detection via Log Analytics query
    FN_QUOTA -.->|"change detection<br>query"| loganalytics
    FN_DEPLOY -.->|"change detection<br>query"| loganalytics

    %% Functions → DCE → DCRs → Log Analytics
    FN_QUOTA -->|"upload"| DCE
    FN_DEPLOY -->|"upload"| DCE
    FN_TOKEN -->|"upload"| DCE
    FN_MODEL -->|"upload"| DCE

    DCE --> DCR_QS --> T_QS
    DCE --> DCR_DC --> T_DC
    DCE --> DCR_TU --> T_TU
    DCE --> DCR_MC --> T_MC

    %% Push-based path
    CS -->|"platform metrics<br>& request logs"| DIAG
    DIAG --> T_AM
    DIAG --> T_AD

    %% Monitoring
    functions -->|"telemetry"| APPI
    APPI --> ALERTS
    ALERTS -->|"notify"| AG

    %% Styling
    classDef azure fill:#0078D4,stroke:#005A9E,color:#fff
    classDef func fill:#FFA500,stroke:#CC8400,color:#fff
    classDef table fill:#68217A,stroke:#4B1560,color:#fff
    classDef alert fill:#E81123,stroke:#B30D1A,color:#fff
    classDef scannedStyle fill:#2D7D2D,stroke:#1B5E1B,color:#fff

    class CS,DEPLOYMENTS,QUOTAS,CATALOG,METRICS scannedStyle
    class ARM_API azure
    class FN_QUOTA,FN_DEPLOY,FN_TOKEN,FN_MODEL func
    class TABLE table
    class DCE,DCR_QS,DCR_DC,DCR_TU,DCR_MC azure
    class T_QS,T_DC,T_TU,T_TU,T_MC,T_AM,T_AD azure
    class APPI,ALERTS azure
    class AG alert
    class DIAG azure
```

## Legend

| Color | Meaning |
|-------|---------|
| 🟢 Green | Scanned resources (Azure AI Foundry / Cognitive Services) |
| 🟠 Orange | Azure Functions (timer-triggered ingestion) |
| 🔵 Blue | Azure platform services (ARM, DCE, DCRs, Log Analytics, App Insights) |
| 🟣 Purple | Azure Table Storage (watermark tracking) |
| 🔴 Red | Alert action group (email notifications) |

## Data Flows

**Pull-based ingestion** — Four timer-triggered Azure Functions scan resources via the ARM REST API and Azure Monitor Metrics API, then write to custom Log Analytics tables through the Logs Ingestion API (DCE → DCR → table):

| Function | Schedule | Source | Target Table |
|----------|----------|--------|--------------|
| `fn_quota_snapshot` | Every 15 min | ARM `/usages` endpoint | `QuotaSnapshot_CL` |
| `fn_deployment_config` | Every 1 hour | ARM `/deployments` endpoint | `DeploymentConfig_CL` |
| `fn_token_usage` | Every 1 hour (30-min delay) | Azure Monitor Metrics API | `TokenUsage_CL` |
| `fn_model_catalog` | Daily at 06:00 UTC | ARM model catalog API | `ModelCatalog_CL` |

**Push-based telemetry** — Diagnostic Settings on each Azure AI Foundry / Cognitive Services instance stream platform metrics and per-request logs directly to `AzureMetrics` and `AzureDiagnostics` tables.

**Monitoring** — Application Insights collects function telemetry. Scheduled query alert rules monitor for failures and notify via an Action Group (email).
