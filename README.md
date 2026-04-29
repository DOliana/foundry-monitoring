# Azure AI Foundry Monitoring

Tools for monitoring Azure AI Foundry and Azure OpenAI resources across subscriptions and get all the information into a central log analytics workspace.

See the [Architecture Diagram](docs/Architecture.md) for a visual overview of all Azure services and data flows.

## Known Limitations

- Log Analytics diagnostic settings (AllMetrics + AzureOpenAIRequestUsage) do not include per-model token breakdowns.
- Azure Monitor exposes tokens per model in the portal, but only per resource — data must be extracted via APIs for consolidated reporting.
- Token quotas are available via REST API, Azure CLI, or the portal.

## Open topics

- Integrate cost data
- Data in Log Analytics has a defined retention time. To not loose data, a refresh mechanism for data that rarely changes needs to be implemented. (example: quota remains constant for 30 days -> LA deletes data after 30 days -> dashboard shows "no data" -> function runs and writes snapshot )

## Acknowledgement

Most of this data can be gathered by using an [AI-Gateway](https://github.com/Azure-Samples/AI-Gateway). This could still be used to enhance the data (e.g. with subscription level quotas)

## Deployment

### Prerequisites

#### Tooling

- [Azure Developer CLI (`azd`)](https://aka.ms/azd) — recommended path
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) with Bicep (`az bicep version` ≥ 0.30)
- PowerShell 7+ (for the provision hooks)
- Python 3.11+ and [Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local) (only for local development)

#### Azure permissions for the deploying user

| Scope | Role | Why |
| --- | --- | --- |
| Deployment resource group | **Contributor** | Create the Function App, storage, App Insights, DCE, DCRs, and (optionally) workspace + alerts. |
| Workspace's RG (only when reusing an existing workspace in a different RG) | **Contributor** — or at minimum `Microsoft.OperationalInsights/workspaces/tables/write` on the workspace | Custom `*_CL` tables are written to the workspace. |
| Each target subscription, the workspace, and each DCR | **User Access Administrator** (or **Owner**) | Required only to assign the managed identity's runtime roles. Skip with `AZURE_ASSIGN_RBAC=false` if a separate admin will run `infrastructure/scripts/Assign-MonitoringRbac.ps1` afterwards. |

The full role-to-API-action mapping (and the runtime roles granted to the Function App's managed identity) is documented in [`docs/RBAC_REQUIREMENTS.md`](docs/RBAC_REQUIREMENTS.md).

### Parameters

| Parameter (Bicep / azd env var) | Required? | Notes |
| --- | --- | --- |
| `prefix` | **Yes** | Lowercase, 2–8 chars. Used to name all resources. `azd up` prompts for it on the first run and remembers your answer. |
| Resource group / region (azd) | **Yes** | `azd up` prompts for the Azure subscription, region, and environment name on the first run. The RG defaults to `rg-<environment-name>`; override with `azd env set AZURE_RESOURCE_GROUP <name>`. |
| `AZURE_TARGET_SUBSCRIPTION_IDS` | No | Comma-separated subscriptions the RBAC scripts will grant the Function App's managed identity access to. The functions themselves scan every subscription the MI can see, so list every subscription you want monitored here. Defaults to the deployment subscription only. |
| `logAnalyticsWorkspaceId` / `AZURE_LOG_ANALYTICS_WORKSPACE_ID` | No | Existing workspace ARM ID. Leave empty to create a new workspace named `<prefix>-law` in the deployment RG. |
| `deployAlerts` / `AZURE_DEPLOY_ALERTS` | No (default `false`) | Set `true` to deploy an Action Group + Function-failure alert rule. |
| `alertEmail` / `AZURE_ALERT_EMAIL` | Required only if `deployAlerts=true` | Recipient address for alerts. |
| `AZURE_ASSIGN_RBAC` | No (default `true`) | Set `false` to skip the post-provision RBAC step. Use when the deploying user lacks User Access Administrator and a separate admin will run `Assign-MonitoringRbac.ps1` later. |
| `location`, `environment`, `maxParallelSubs`, `workspaceName`, `workspaceRetentionDays`, `workspaceSku` | No | See [`infrastructure/README.md`](infrastructure/README.md) for defaults. |

### Run it

```bash
azd init   # one-time, choose this folder
azd up     # provisions infra and deploys the Function code
```

The pre-provision hook prompts for the optional parameters above. `azd up` itself prompts for the standard azd inputs on the first run — **environment name**, **Azure subscription**, **region** (e.g. `swedencentral`), and the mandatory `prefix` parameter (lowercase, 2–8 chars) — and remembers them in the azd environment. The resource-group name defaults to `rg-<environment-name>` (you can override with `azd env set AZURE_RESOURCE_GROUP <name>` before `azd up`). The post-provision hook then:

1. Assigns the Function App's managed identity the required RBAC across target subscriptions, the workspace, and the DCRs.
2. Optionally assigns the same RBAC to your local user (for `func host start`).
3. Generates `src/local.settings.json` from the Bicep outputs.

A manual (non-azd) deployment is also supported via [`infrastructure/scripts/Deploy-MonitoringInfra.ps1`](infrastructure/scripts/Deploy-MonitoringInfra.ps1) — see [`infrastructure/README.md`](infrastructure/README.md).

### What `azd up` does

1. **Provisions the Azure resources** defined by [`infrastructure/main.bicep`](infrastructure/main.bicep): Function App (Flex Consumption), Storage Account, Application Insights, Data Collection Endpoint, four Data Collection Rules, four custom `*_CL` Log Analytics tables, optionally a new Log Analytics workspace, and optionally an Action Group + Function-failure alert rule.
2. **Configures the Function App** with all DCE / DCR / storage / App Insights settings as application settings (no manual wiring needed).
3. **Assigns runtime RBAC** to the Function App's managed identity: `Reader`, `Monitoring Reader`, `Cognitive Services Usages Reader` on each target subscription; `Log Analytics Data Reader` on the workspace; `Monitoring Metrics Publisher` on each DCR; `Storage Blob Data Owner` + `Storage Table/Queue Data Contributor` on the deployment storage account. Skip with `AZURE_ASSIGN_RBAC=false`.
4. **Packages and deploys the Python Function code** from [`src/`](src/) to the Function App.
5. **Generates `src/local.settings.json`** from the Bicep outputs so `func host start` works locally (optional dev RBAC for your user is offered interactively).

### Verify ingestion

After ~20 minutes, query the workspace (table generation takes time):

```kusto
QuotaSnapshot_CL    | take 10
DeploymentConfig_CL | take 10
TokenUsage_CL       | take 10
ModelCatalog_CL     | take 10
```

### Uninstall

```bash
azd down --purge
```

> **Warning:** `azd down` deletes the **entire** resource group (azd uses a resource-group-scoped deployment). Deploy into a dedicated RG. The pre-provision hook warns if the target RG already contains non-azd resources.
> **Note: portal-only deployment is not supported.**
> The Data Collection Rules in [`data-collection.bicep`](infrastructure/modules/data-collection.bicep) are **direct-ingestion** DCRs (the Function App pushes JSON to the Logs Ingestion API). The Azure portal — both the new and the classic DCR creation experiences — only supports **agent-based** DCRs and always requires a `File pattern`, which does not apply here. Direct-ingestion DCRs must be created via Bicep/ARM, REST, or `az monitor data-collection rule create --rule-file`. If a click-through experience is required, deploy the compiled ARM template via *Portal → Deploy a custom template* (`az bicep build --file infrastructure/main.bicep`).

## Files

### Documentation (`/docs` folder)

| File | Description |
| ------ | ------------- |
| [`Ingestion.md`](docs/Ingestion.md) | Covers the ingestion layer — compute, orchestration, and write patterns. Documents data streams (push-based vs pull-based), the Azure Functions design decision, watermark-based gap-fill, and change detection. |
| [`KQL queries.md`](docs/KQL%20queries.md) | Power BI KQL queries for DirectQuery / Import against the Log Analytics workspace. Includes deduplication logic and step-by-step Power BI connection instructions. |
| [`RBAC_REQUIREMENTS.md`](docs/RBAC_REQUIREMENTS.md) | Maps minimum Azure RBAC roles and permissions required to run the monitoring code. Includes least-privilege scope guidance for Log Analytics queries, Azure Monitor metrics API, and ARM API calls. Documents required roles for each operation with official Microsoft Learn links. |
| [`Architecture.md`](docs/Architecture.md) | Mermaid architecture diagram showing all Azure services, the four Azure Functions, data flows, scanned resources, and the monitoring/alerting pipeline. |

### Demo content (`/demo` folder)

The `demo/` folder contains illustrative material that is **not part of the deployed solution** — use it to explore the data, generate synthetic traffic, or experiment with the push-based AzureMetrics path. None of this is required to run the production functions.

#### Notebooks (`/demo/notebooks`)

| File | Description |
| ------ | ------------- |
| [`monitor-foundry.ipynb`](demo/notebooks/monitor-foundry.ipynb) | Original POC: collects quota, deployment, and token usage data across all subscriptions via Azure Monitor APIs. Visualizes subscription-level quotas, deployment rate limits, and hourly token usage with Plotly charts. Superseded by the deployed Functions in `src/`. |
| [`monitor-foundry-example.ipynb`](demo/notebooks/monitor-foundry-example.ipynb) | Queries a Log Analytics workspace for `AzureMetrics` data from Foundry instances. Demonstrates the **push-based** path via diagnostic settings (the deployed solution does not consume `AzureMetrics`). Requires `demo/diagnostic-settings/Set-FoundryDiagnosticSettings.ps1` to have been run first. |

### Azure Functions (`/src` folder)

Timer-triggered functions that collect data from Azure APIs and write to custom Log Analytics tables via the Data Collection Rules pipeline. Uses watermark-based tracking for gap-fill on failure and change detection to avoid duplicate writes.

| Function | Schedule | Custom Table | Description |
| ---------- | ---------- | -------------- | ------------- |
| [`fn_quota_snapshot`](src/functions/quota_snapshot.py) | Hourly (at :20) | `QuotaSnapshot_CL` | Collects subscription-level quota and usage data per region/model from the ARM `/usages` endpoint. |
| [`fn_deployment_config`](src/functions/deployment_config.py) | Hourly (at :05) | `DeploymentConfig_CL` | Collects deployment configurations (model, SKU, capacity, rate limits) per Cognitive Services instance. |
| [`fn_token_usage`](src/functions/token_usage.py) | Hourly (at :35) | `TokenUsage_CL` | Collects per-deployment token metrics (prompt/generated tokens) from Azure Monitor Metrics API with a 30-min delay for metric finalization. |
| [`fn_model_catalog`](src/functions/model_catalog.py) | Daily (06:00 UTC) | `ModelCatalog_CL` | Collects available models from the Cognitive Services model catalog per region, including lifecycle and capability metadata. |

### Infrastructure (`/infrastructure` folder)

Bicep modules deployed via `azd up` or the manual `Deploy-MonitoringInfra.ps1` script. See [`infrastructure/README.md`](infrastructure/README.md) for full deployment instructions.

| Module | Description |
| -------- | ------------- |
| [`main.bicep`](infrastructure/main.bicep) | Orchestrator — uses an existing Log Analytics workspace or creates a new one. |
| [`log-analytics.bicep`](infrastructure/modules/log-analytics.bicep) | New Log Analytics workspace (only when no existing workspace ID supplied). |
| [`custom-tables.bicep`](infrastructure/modules/custom-tables.bicep) | Creates the 4 custom Log Analytics tables. |
| [`data-collection.bicep`](infrastructure/modules/data-collection.bicep) | Data Collection Endpoint (DCE) + Data Collection Rules (DCRs) with schema and routing. |
| [`function-app.bicep`](infrastructure/modules/function-app.bicep) | Storage Account (watermark table), Application Insights, and Flex Consumption Function App. |
| [`alerts.bicep`](infrastructure/modules/alerts.bicep) | Optional Action Group + alert rule for function failures (`deployAlerts=true`). |

### Demo PowerShell scripts (`/demo` folder)

| File | Description |
| ------ | ------------- |
| [`Set-FoundryDiagnosticSettings.ps1`](demo/diagnostic-settings/Set-FoundryDiagnosticSettings.ps1) | Discovers all Foundry resources and creates diagnostic settings to stream metrics to a Log Analytics workspace. Used by the example notebook only — the deployed Functions do not consume `AzureMetrics` / `AzureDiagnostics`. Supports `-Remove` and `-WhatIf`. |
| [`Invoke-FoundryTrafficGenerator.ps1`](demo/load-tests/Invoke-FoundryTrafficGenerator.ps1) | Sends test requests to model deployments (chat completions, embeddings) across Foundry instances so dashboards have data. Supports parallel execution, multiple iterations, and `-WhatIf`. |
| [`Invoke-FoundryLoadTest.ps1`](demo/load-tests/Invoke-FoundryLoadTest.ps1) | Interactive load-test tool to hammer a deployed model (produce 429s) — drills down into subscription → instance → deployment, then fires parallel requests. Supports chat completions and embeddings. |
