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

- An **existing Log Analytics workspace** — its full resource ID is required as a parameter
- Azure CLI with Bicep support (`az bicep version` ≥ 0.30)
- Permissions: Contributor on the target resource group

## Deploy

```bash
# 1. Create resource group
az group create -n rg-ai-monitoring -l swedencentral

## Deploy (recommended — single script)

The deployment script handles resource group creation, Bicep deployment, and RBAC assignment in one call:

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

Use `-WhatIf` to preview all changes before applying.

## Deploy (manual — step by step)

If you prefer to run each step separately:

```bash
# 1. Create resource group
az group create -n rg-ai-monitoring -l swedencentral

# 2. Deploy infrastructure
az deployment group create \
  -g rg-ai-monitoring \
  -f main.bicep \
  --parameters main.bicepparam

# 3. Capture outputs for RBAC script
PRINCIPAL_ID=$(az deployment group show -g rg-ai-monitoring -n main --query properties.outputs.functionAppPrincipalId.value -o tsv)
DCR_QUOTA=$(az deployment group show -g rg-ai-monitoring -n main --query properties.outputs.dcrQuotaSnapshotId.value -o tsv)
DCR_DEPLOY=$(az deployment group show -g rg-ai-monitoring -n main --query properties.outputs.dcrDeploymentConfigId.value -o tsv)
DCR_TOKEN=$(az deployment group show -g rg-ai-monitoring -n main --query properties.outputs.dcrTokenUsageId.value -o tsv)

# 4. Assign RBAC
```

```powershell
./scripts/Assign-MonitoringRbac.ps1 `
    -PrincipalId $PRINCIPAL_ID `
    -TargetSubscriptionIds @("sub-id-1", "sub-id-2", "sub-id-3") `
    -LogAnalyticsWorkspaceResourceId "/subscriptions/.../workspaces/my-ws" `
    -DcrResourceIds @($DCR_QUOTA, $DCR_DEPLOY, $DCR_TOKEN)
```

## File structure

```
infrastructure/
├── main.bicep                  # Orchestrator
├── main.bicepparam             # Parameters (edit before deploying)
├── modules/
│   ├── data-collection.bicep   # DCE + 3 DCRs
│   ├── function-app.bicep      # Storage + App Insights + Function App
│   └── alerts.bicep            # Alert rules + action group
├── scripts/
│   ├── Deploy-MonitoringInfra.ps1 # One-command deploy + RBAC (recommended)
│   └── Assign-MonitoringRbac.ps1  # Cross-subscription RBAC assignments
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
