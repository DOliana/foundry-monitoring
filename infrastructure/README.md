# AI Foundry Monitoring — Infrastructure

Deploys the monitoring infrastructure for collecting quota, deployment config, and token usage data from Azure AI Foundry / Azure OpenAI instances across multiple subscriptions.

## What gets deployed

| Resource | Purpose |
|---|---|
| Data Collection Endpoint (DCE) | HTTPS ingress for custom table writes |
| 3 × Data Collection Rules (DCR) | Schema + routing for `QuotaSnapshot_CL`, `DeploymentConfig_CL`, `TokenUsage_CL` |
| Storage Account | Function App backing store + watermark table |
| Application Insights | Function App telemetry (linked to existing Log Analytics workspace) |
| Function App (Flex Consumption) | Hosts the 3 timer-triggered ingestion functions |
| Action Group + Alert Rule | Email notification on function failures |

## Prerequisites

- An **existing Log Analytics workspace** — its full resource ID is required
- [Azure Developer CLI (`azd`)](https://aka.ms/azd) installed
- Azure CLI with Bicep support (`az bicep version` ≥ 0.30)
- Permissions: Contributor on the target resource group, User Access Administrator for RBAC

## Deploy with azd (recommended)

```bash
# One-time setup — azd will prompt for required parameters
azd init
azd up
```

`azd` automatically prompts for the two mandatory Bicep parameters (`logAnalyticsWorkspaceId` and `alertEmail`) if they aren't already set. You can also pre-set them:

```bash
azd env set AZURE_LOG_ANALYTICS_WORKSPACE_ID "/subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.OperationalInsights/workspaces/{name}"
azd env set AZURE_ALERT_EMAIL "platformteam@contoso.com"

# Optional — defaults to the deployment subscription if not set
# azd env set AZURE_TARGET_SUBSCRIPTION_IDS "sub-id-1,sub-id-2,sub-id-3"
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

```powershell
./scripts/Deploy-MonitoringInfra.ps1 `
    -LogAnalyticsWorkspaceId "/subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.OperationalInsights/workspaces/{name}" `
    -AlertEmail "platformteam@contoso.com" `
    -TargetSubscriptionIds @("sub-id-1", "sub-id-2", "sub-id-3")
```

Optional parameters (with defaults):

| Parameter | Default | Description |
|---|---|---|
| `-ResourceGroupName` | `rg-ai-monitoring` | Resource group name |
| `-Location` | `swedencentral` | Azure region |
| `-Prefix` | `heaip` | Naming prefix |
| `-Environment` | `DEV` | Environment tag |
| `-MaxParallelSubs` | `5` | Concurrency limit |
| `-SkipRbac` | `$false` | Skip RBAC step (for re-deploys) |

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
│   ├── custom-tables.bicep     # 3 custom Log Analytics tables
│   ├── data-collection.bicep   # DCE + 3 DCRs
│   ├── function-app.bicep      # Storage + App Insights + Function App
│   └── alerts.bicep            # Alert rules + action group
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
|---|---|---|
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
|---|---|---|
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
|---|---|---|
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
