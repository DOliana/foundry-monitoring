# Azure AI Foundry Monitoring

Tools for monitoring Azure AI Foundry and Azure OpenAI resources across subscriptions and get all the information into a central log analytics workspace.

## Known Limitations

- Log Analytics diagnostic settings (AllMetrics + AzureOpenAIRequestUsage) do not include per-model token breakdowns.
- Azure Monitor exposes tokens per model in the portal, but only per resource — data must be extracted via APIs for consolidated reporting.
- Token quotas are available via REST API, Azure CLI, or the portal.

## Open topics

- Integrate cost data

## Acknowledgement

Most of this data can be gathered by using an [AI-Gateway](https://github.com/Azure-Samples/AI-Gateway). This could still be used to enhance the data (e.g. with subscription level quotas)

## Deployment

Prerequisites:
- see `/docs/RBAC_REQUIREMENTS.md` for permissions
- existing log analyitcs workspace

use `azd up` in the root folder

## Files

### Documentation (`/docs` folder)

| File | Description |
|------|-------------|
| `Ingestion.md` | Covers the ingestion layer — compute, orchestration, and write patterns. Documents data streams (push-based vs pull-based), the Azure Functions design decision, watermark-based gap-fill, and change detection. |
| `KQL queries.md` | Power BI KQL queries for DirectQuery / Import against the Log Analytics workspace. Includes deduplication logic and step-by-step Power BI connection instructions. |
| `RBAC_REQUIREMENTS.md` | Maps minimum Azure RBAC roles and permissions required to run the monitoring code. Includes least-privilege scope guidance for Log Analytics queries, Azure Monitor metrics API, and ARM API calls. Documents required roles for each operation with official Microsoft Learn links. |

### Notebooks (`/proof-of-concept` folder)

| File | Description |
|------|-------------|
| `monitor-foundry.ipynb` | Collects quota, deployment, and token usage data across all subscriptions via Azure Monitor APIs. Visualizes subscription-level quotas, deployment rate limits, and hourly token usage with Plotly charts. |
| `monitor-foundry-example.ipynb` | Queries a Log Analytics workspace for AzureMetrics data from Foundry instances. Demonstrates how to retrieve metrics and diagnostics via the Log Analytics SDK. |

### Azure Functions (`/src` folder)

Timer-triggered functions that collect data from Azure APIs and write to custom Log Analytics tables via the Data Collection Rules pipeline. Uses watermark-based tracking for gap-fill on failure and change detection to avoid duplicate writes.

| Function | Schedule | Custom Table | Description |
|----------|----------|--------------|-------------|
| `fn_quota_snapshot` | Every 15 min | `QuotaSnapshot_CL` | Collects subscription-level quota and usage data per region/model from the ARM `/usages` endpoint. |
| `fn_deployment_config` | Hourly (at :05) | `DeploymentConfig_CL` | Collects deployment configurations (model, SKU, capacity, rate limits) per Cognitive Services instance. |
| `fn_token_usage` | Hourly (at :35) | `TokenUsage_CL` | Collects per-deployment token metrics (prompt/generated tokens) from Azure Monitor Metrics API with a 30-min delay for metric finalization. |
| `fn_model_catalog` | Daily (06:00 UTC) | `ModelCatalog_CL` | Collects available models from the Cognitive Services model catalog per region, including lifecycle and capability metadata. |

### Infrastructure (`/infrastructure` folder)

Bicep modules deployed via `azd up` or the manual `Deploy-MonitoringInfra.ps1` script. See [`infrastructure/README.md`](infrastructure/README.md) for full deployment instructions.

| Module | Description |
|--------|-------------|
| `main.bicep` | Orchestrator — wires all modules together, references the existing Log Analytics workspace. |
| `custom-tables.bicep` | Creates the 4 custom Log Analytics tables. |
| `data-collection.bicep` | Data Collection Endpoint (DCE) + Data Collection Rules (DCRs) with schema and routing. |
| `function-app.bicep` | Storage Account (watermark table), Application Insights, and Flex Consumption Function App. |
| `alerts.bicep` | Action group + alert rule for function failures. |

### PowerShell Scripts (`/scripts` folder)

| File | Description |
|------|-------------|
| `Set-FoundryDiagnosticSettings.ps1` | Discovers all Foundry resources and creates diagnostic settings to stream metrics to a Log Analytics workspace. Supports `-Remove` and `-WhatIf`. |
| `Invoke-FoundryTrafficGenerator.ps1` | Sends test requests to model deployments (chat completions, embeddings) across Foundry instances. Supports parallel execution, multiple iterations, and `-WhatIf`. |
| `Invoke-FoundryLoadTest.ps1` | Interactive load-test tool — drills down into subscription → instance → deployment, then fires parallel requests. Supports chat completions and embeddings. |
