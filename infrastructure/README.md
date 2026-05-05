# AI Foundry Monitoring — Infrastructure

Deploys the monitoring infrastructure for collecting quota, deployment config, and token usage data from Azure AI Foundry / Azure OpenAI instances across multiple subscriptions.

## What gets deployed

| Resource | Purpose | Optional? |
| --- | --- | --- |
| Log Analytics workspace | Stores all monitoring data | Only when no existing workspace ID is supplied |
| Data Collection Endpoint (DCE) | HTTPS ingress for custom table writes | No |
| 4 × Data Collection Rules (DCR) | Schema + routing for `QuotaSnapshot_CL`, `DeploymentConfig_CL`, `TokenUsage_CL`, `ModelCatalog_CL` | No |
| 4 × Custom Log Analytics tables | `*_CL` schemas in the workspace | No |
| Storage Account | Function App backing store + watermark table | No |
| Application Insights | Function App telemetry (linked to the workspace) | No |
| Function App (Flex Consumption) | Hosts the 4 timer-triggered ingestion functions | No |
| Action Group + Alert Rule | Email notification on function failures | Yes — `deployAlerts` parameter (default `false`) |

## Prerequisites

### Tooling

- [Azure Developer CLI (`azd`)](https://aka.ms/azd) installed
- Azure CLI with Bicep support (`az bicep version` ≥ 0.30)
- PowerShell 7+ (provision hooks)

### Azure permissions for the **deploying user**

| Scope | Role | Why |
| --- | --- | --- |
| Deployment resource group | **Contributor** | Create the storage account, App Insights, Function App, DCE, DCRs, and (optionally) the Log Analytics workspace and alert resources. |
| Workspace's resource group (only if reusing an existing workspace in a *different* RG) | **Contributor** on that RG — or at minimum `Microsoft.OperationalInsights/workspaces/tables/write` on the workspace | Custom `*_CL` tables are created on the workspace. |
| Each target subscription, the workspace, and each DCR | **User Access Administrator** (or **Owner**) | Required by `Assign-MonitoringRbac.ps1` to grant the Function App's managed identity the roles below. **Skip this if** the RBAC step will be handed off to a separate admin (set `AZURE_ASSIGN_RBAC=false`). |

### Roles assigned to the Function App's managed identity

The post-provision RBAC script grants the MI:

| Scope | Role |
| --- | --- |
| Each target subscription | `Reader`, `Monitoring Reader`, `Cognitive Services Usages Reader` |
| Log Analytics workspace | `Log Analytics Data Reader` |
| Each DCR | `Monitoring Metrics Publisher` |
| Storage Account (deployed by Bicep) | `Storage Blob Data Owner`, `Storage Table Data Contributor`, `Storage Queue Data Contributor` — already wired into `function-app.bicep`, no admin perms needed |

Full mapping (with API actions and links): [`docs/RBAC_REQUIREMENTS.md`](../docs/RBAC_REQUIREMENTS.md).

### Optional: an existing Log Analytics workspace

If none is provided, the deployment creates a new one named `<prefix>-law` in the deployment resource group.

## Deploy with azd (recommended)

```bash
# One-time setup — azd will prompt for required parameters
azd init
azd up
```

`azd` prompts on the first run for the standard inputs — **environment name**, **Azure subscription**, **region**, and the mandatory `prefix` parameter (lowercase, 2–8 chars) — and stores them in the azd environment. The resource-group name defaults to `rg-<environment-name>` (override with `azd env set AZURE_RESOURCE_GROUP <name>` before `azd up`). The pre-provision hook then prompts interactively for:

- **Target subscriptions** (`AZURE_TARGET_SUBSCRIPTION_IDS`) — comma-separated list of subscriptions the RBAC scripts will grant the Function App's managed identity access to. At runtime the functions scan every subscription the managed identity can see, so any subscription you want monitored must be listed here. Leave empty to grant access only to the deployment subscription.
- **Existing Log Analytics workspace** (`AZURE_LOG_ANALYTICS_WORKSPACE_ID`) — leave empty to create a new workspace.
- **Deploy alerts?** (`AZURE_DEPLOY_ALERTS`) — if yes, prompts for `AZURE_ALERT_EMAIL`.

### Skipping the RBAC step

If the deploying user does not have **User Access Administrator** on the target subscriptions, workspace, and DCRs, set `AZURE_ASSIGN_RBAC=false` to skip the post-provision role assignments. The deployment will succeed, but the Function App's managed identity will not yet be able to read from target subscriptions or write to the DCRs — a separate admin must run `infrastructure/scripts/Assign-MonitoringRbac.ps1` afterwards (it reads all required IDs from azd outputs).

```bash
azd env set AZURE_ASSIGN_RBAC false   # default: true
```

You can pre-set any of these to skip the prompts:

```bash
azd env set AZURE_TARGET_SUBSCRIPTION_IDS "sub-id-1,sub-id-2"
azd env set AZURE_LOG_ANALYTICS_WORKSPACE_ID "/subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.OperationalInsights/workspaces/{name}"
azd env set AZURE_DEPLOY_ALERTS true
azd env set AZURE_ALERT_EMAIL "platformteam@contoso.com"
```

`azd up` runs `azd provision` + `azd deploy`. The post-provision hook automatically:

1. Assigns RBAC roles to the Function App's managed identity
2. Assigns RBAC roles to your local developer identity (for `func host start`)
3. Generates `src/local.settings.json` from Bicep outputs

### Local development after azd provision

```bash
cd src
func host start
```

No extra setup needed — `local.settings.json` and RBAC are configured by the post-provision hook.

## Deploy manually (alternative)

The manual path **does not assign RBAC by default** — it deploys the infrastructure only and leaves the role assignments to a separate admin (typically because the deploying user does not hold User Access Administrator on the target subscriptions, workspace, and DCRs).

```powershell
# Minimal: create a new workspace, no alerts, no RBAC
./scripts/Deploy-MonitoringInfra.ps1 -Prefix "aimon"

# With existing workspace + alerts (still no RBAC)
./scripts/Deploy-MonitoringInfra.ps1 `
    -Prefix "aimon" `
    -LogAnalyticsWorkspaceId "/subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.OperationalInsights/workspaces/{name}" `
    -DeployAlerts -AlertEmail "platformteam@contoso.com"

# Same deploy AND assign RBAC in one shot (requires User Access Administrator)
./scripts/Deploy-MonitoringInfra.ps1 `
    -Prefix "aimon" `
    -AssignRbac -TargetSubscriptionIds @("sub-id-1", "sub-id-2")
```

After a deploy without `-AssignRbac`, hand the post-deploy outputs (Function App principal ID, workspace ID, the four DCR IDs — all printed by the script) to an admin who runs `./scripts/Assign-MonitoringRbac.ps1` to grant the managed identity access. Until then the functions will run but log authorization errors.

Mandatory parameters:

| Parameter | Description |
| --- | --- |
| `-Prefix` | Naming prefix (lowercase, 2–8 chars). Used to name all resources. |

Optional parameters (with defaults):

| Parameter | Default | Description |
| --- | --- | --- |
| `-ResourceGroupName` | `rg-ai-monitoring` | Resource group name |
| `-Location` | `swedencentral` | Azure region |
| `-LogAnalyticsWorkspaceId` | *(empty)* | Existing workspace ARM ID. Empty ⇒ create new |
| `-WorkspaceName` | `<prefix>-law` | Name for the new workspace (ignored when reusing existing) |
| `-WorkspaceRetentionDays` | `30` | Retention for the new workspace (7–730) |
| `-WorkspaceSku` | `PerGB2018` | Pricing SKU for the new workspace |
| `-DeployAlerts` | `$false` | Switch — deploy Action Group + alert rule |
| `-AlertEmail` | *(empty)* | Required when `-DeployAlerts` is set |
| `-Environment` | `DEV` | Environment tag |
| `-MaxParallelSubs` | `5` | Concurrency limit |
| `-AssignRbac` | `$false` | Switch — also run `Assign-MonitoringRbac.ps1` after the Bicep deploy. Requires `-TargetSubscriptionIds` and User Access Administrator on each target sub, the workspace, and each DCR. |
| `-TargetSubscriptionIds` | *(empty)* | Subscription IDs to grant the Function App MI access to. Required only when `-AssignRbac` is set. |

Every Bicep parameter is exposed as a `Deploy-MonitoringInfra.ps1` switch — the manual path does not require any interactive prompts.

Then set up local development manually:

```powershell
# Assign developer RBAC
./scripts/Assign-DevRbac.ps1 -TargetSubscriptionIds @("sub-id-1") -LogAnalyticsWorkspaceResourceId "..." -StorageAccountName "..."

# Create local.settings.json (or copy from Azure portal)
./scripts/Create-LocalSettings.ps1
```

## File structure

```
infrastructure/
├── main.bicep                  # Orchestrator (azd prompts for mandatory params)
├── modules/
│   ├── log-analytics.bicep     # Log Analytics workspace (created only when no existing ID supplied)
│   ├── custom-tables.bicep     # 4 custom Log Analytics tables
│   ├── data-collection.bicep   # DCE + 4 DCRs
│   ├── function-app.bicep      # Storage + App Insights + Function App
│   └── alerts.bicep            # Optional Action Group + alert rule (deployAlerts=true)
├── scripts/
│   ├── Post-Provision.ps1        # azd postprovision hook (orchestrates steps below)
│   ├── Assign-MonitoringRbac.ps1  # RBAC for Function App managed identity
│   ├── Assign-DevRbac.ps1         # RBAC for local developer identity
│   ├── Create-LocalSettings.ps1   # Generates src/local.settings.json
│   └── Deploy-MonitoringInfra.ps1 # Manual deploy alternative (no azd)
└── README.md                   # This file
```

## Custom table schemas

### QuotaSnapshot_CL

| Column | Type | Description |
| --- | --- | --- |
| `timestamp_t` | datetime | Point-in-time of the snapshot |
| `subscriptionId_s` | string | Azure subscription ID |
| `subscriptionName_s` | string | Subscription display name |
| `region_s` | string | Azure region |
| `model_s` | string | Model name (e.g. gpt-4o) |
| `deployedTPM_d` | real | TPM allocated to deployments |
| `maxTPM_d` | real | Subscription quota limit |
| `utilizationPct_d` | real | deployedTPM / maxTPM × 100 |

### DeploymentConfig_CL

| Column | Type | Description |
| --- | --- | --- |
| `subscriptionId_s` | string | Azure subscription ID |
| `resourceId_s` | string | Full ARM resource ID of the Cognitive Services account |
| `resourceName_s` | string | Resource display name |
| `location_s` | string | Azure region |
| `kind_s` | string | AIServices or OpenAI |
| `deploymentName_s` | string | Model deployment name |
| `modelName_s` | string | Model name |
| `modelVersion_s` | string | Model version |
| `skuName_s` | string | SKU (Standard, GlobalStandard, etc.) |
| `skuCapacity_d` | real | SKU capacity units |
| `tpmLimit_d` | real | Tokens per minute limit |
| `rpmLimit_d` | real | Requests per minute limit |

### TokenUsage_CL

| Column | Type | Description |
| --- | --- | --- |
| `timestamp_t` | datetime | Start of the 5-minute interval |
| `subscriptionId_s` | string | Azure subscription ID |
| `resourceId_s` | string | Full ARM resource ID |
| `resourceName_s` | string | Resource display name |
| `deploymentName_s` | string | Model deployment name |
| `modelName_s` | string | Model name |
| `promptTokens_d` | real | Input tokens consumed |
| `completionTokens_d` | real | Output tokens generated |
| `totalTokens_d` | real | Total tokens |
| `granularity_s` | string | ISO 8601 aggregation interval (e.g. PT5M) |
