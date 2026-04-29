// Monitoring infrastructure for Azure AI Foundry / Azure OpenAI
//
// Deploys: DCE, DCRs (4 custom tables), Function App (Flex Consumption),
//          Storage Account (watermark table), App Insights, optional alert rules,
//          and optionally a new Log Analytics workspace.
//
// Prerequisites:
//   - azd CLI installed (https://aka.ms/azd) — recommended path
//   - An existing Log Analytics workspace (optional — leave logAnalyticsWorkspaceId empty
//     to create a new one in the deployment resource group)
//
// Deploy with azd (recommended):
//   azd env set AZURE_TARGET_SUBSCRIPTION_IDS "sub1,sub2"        # optional
//   azd env set AZURE_LOG_ANALYTICS_WORKSPACE_ID "/subs/.../workspaces/{name}"  # optional
//   azd env set AZURE_DEPLOY_ALERTS true                         # optional
//   azd env set AZURE_ALERT_EMAIL "team@contoso.com"             # required only if alerts enabled
//   azd up
//
// Deploy manually (alternative):
//   ./scripts/Deploy-MonitoringInfra.ps1 -Prefix "aimon" -TargetSubscriptionIds @("...")
//
// Parameters:
//   MANDATORY:
//     prefix                   — naming prefix (lowercase, 2-8 chars)
//
//   OPTIONAL:
//     location                 — Azure region for Function App & Storage (default: swedencentral)
//                                DCE, DCRs, App Insights are placed in the workspace's region.
//     environment              — environment tag (default: DEV)
//     maxParallelSubs          — concurrency limit for subscription processing (default: 5)
//     logAnalyticsWorkspaceId  — full ARM ID of an existing workspace. Leave empty to create one.
//     workspaceName            — name for the new workspace (default: <prefix>-law). Ignored if
//                                logAnalyticsWorkspaceId is supplied.
//     workspaceRetentionDays   — retention for the new workspace (default: 30). Ignored if
//                                logAnalyticsWorkspaceId is supplied.
//     workspaceSku             — pricing SKU for the new workspace (default: PerGB2018).
//     deployAlerts             — deploy Action Group + scheduled-query rule (default: false)
//     alertEmail               — email recipient (required when deployAlerts is true)

targetScope = 'resourceGroup'

// ── Naming / environment ─────────────────────────────────────────────────────

@description('Naming prefix (lowercase, 2-8 chars).')
@minLength(2)
@maxLength(8)
param prefix string

@description('Optional. Azure region for Function App and Storage Account. DCE, DCRs, and App Insights are automatically placed in the Log Analytics workspace region. Default: swedencentral')
param location string = 'swedencentral'

@description('Optional. Environment tag. Default: DEV')
@allowed(['DEV', 'TEST', 'PROD'])
param environment string = 'DEV'

@description('Optional. Max parallel subscriptions to process concurrently. Default: 5')
param maxParallelSubs int = 5

// ── Log Analytics workspace (use existing OR create new) ─────────────────────

@description('Optional. Full resource ID of an existing Log Analytics workspace. Leave empty to create a new workspace in this resource group. Example: /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.OperationalInsights/workspaces/{name}')
param logAnalyticsWorkspaceId string = ''

@description('Optional. Name for the new Log Analytics workspace. Ignored when logAnalyticsWorkspaceId is supplied. Default: <prefix>-law')
param workspaceName string = '${prefix}-law'

@description('Optional. Retention (days) for the new Log Analytics workspace. Ignored when logAnalyticsWorkspaceId is supplied. Default: 30')
@minValue(7)
@maxValue(730)
param workspaceRetentionDays int = 30

@description('Optional. Pricing SKU for the new Log Analytics workspace. Ignored when logAnalyticsWorkspaceId is supplied. Default: PerGB2018')
@allowed(['PerGB2018', 'CapacityReservation', 'Standalone', 'PerNode', 'Standard', 'Premium'])
param workspaceSku string = 'PerGB2018'

// ── Optional alerts ──────────────────────────────────────────────────────────

@description('Optional. Deploy the Action Group and Function-failure alert rule. Default: false')
param deployAlerts bool = false

@description('Optional. Email address for alert notifications. Required only when deployAlerts is true.')
param alertEmail string = ''

// ── Computed ─────────────────────────────────────────────────────────────────

var tags = {
  Environment: environment
  Project: 'AI-Foundry-Monitoring'
}

var createWorkspace = empty(logAnalyticsWorkspaceId)

// Parse the existing workspace ID (only meaningful when createWorkspace is false)
var existingWorkspaceSub = createWorkspace ? subscription().subscriptionId : split(logAnalyticsWorkspaceId, '/')[2]
var existingWorkspaceRg = createWorkspace ? resourceGroup().name : split(logAnalyticsWorkspaceId, '/')[4]
var existingWorkspaceName = createWorkspace ? workspaceName : split(logAnalyticsWorkspaceId, '/')[8]

// ── Workspace (one of two paths) ─────────────────────────────────────────────

module newWorkspace 'modules/log-analytics.bicep' = if (createWorkspace) {
  name: 'newWorkspace'
  params: {
    name: workspaceName
    location: location
    tags: tags
    retentionInDays: workspaceRetentionDays
    sku: workspaceSku
  }
}

resource existingWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = if (!createWorkspace) {
  name: existingWorkspaceName
  scope: resourceGroup(existingWorkspaceSub, existingWorkspaceRg)
}

// Effective workspace facts used by downstream modules
var effectiveWorkspaceId = createWorkspace ? newWorkspace!.outputs.id : logAnalyticsWorkspaceId
var effectiveWorkspaceName = createWorkspace ? workspaceName : existingWorkspaceName
var effectiveWorkspaceSub = existingWorkspaceSub
var effectiveWorkspaceRg = existingWorkspaceRg
var effectiveWorkspaceLocation = createWorkspace ? location : existingWorkspace!.location

// ── Custom tables (in the workspace's resource group) ────────────────────────

module customTables 'modules/custom-tables.bicep' = {
  scope: resourceGroup(effectiveWorkspaceSub, effectiveWorkspaceRg)
  name: 'customTables'
  params: {
    workspaceName: effectiveWorkspaceName
  }
  dependsOn: createWorkspace ? [newWorkspace] : []
}

module dataCollection 'modules/data-collection.bicep' = {
  name: 'dataCollection'
  dependsOn: [customTables]
  params: {
    location: effectiveWorkspaceLocation
    prefix: prefix
    tags: tags
    logAnalyticsWorkspaceId: effectiveWorkspaceId
  }
}

module functionApp 'modules/function-app.bicep' = {
  name: 'functionApp'
  params: {
    location: location
    workspaceLocation: effectiveWorkspaceLocation
    prefix: prefix
    tags: tags
    logAnalyticsWorkspaceId: effectiveWorkspaceId
    dceEndpoint: dataCollection.outputs.dceEndpoint
    dcrQuotaSnapshotImmutableId: dataCollection.outputs.dcrQuotaSnapshotImmutableId
    dcrDeploymentConfigImmutableId: dataCollection.outputs.dcrDeploymentConfigImmutableId
    dcrTokenUsageImmutableId: dataCollection.outputs.dcrTokenUsageImmutableId
    dcrModelCatalogImmutableId: dataCollection.outputs.dcrModelCatalogImmutableId
    maxParallelSubs: maxParallelSubs
  }
}

// Optional: alerts.
// Note: when deployAlerts is true, alertEmail must be a non-empty address —
// the Action Group resource will fail validation otherwise.
module alerts 'modules/alerts.bicep' = if (deployAlerts) {
  name: 'alerts'
  params: {
    prefix: prefix
    tags: tags
    appInsightsId: functionApp.outputs.appInsightsId
    alertEmail: alertEmail
  }
}

// ── Outputs (consumed by azd env vars and RBAC scripts) ──────────────────────

output AZURE_FUNCTION_APP_PRINCIPAL_ID string = functionApp.outputs.functionAppPrincipalId
output AZURE_FUNCTION_APP_NAME string = functionApp.outputs.functionAppName
output AZURE_DCR_QUOTA_SNAPSHOT_ID string = dataCollection.outputs.dcrQuotaSnapshotId
output AZURE_DCR_DEPLOYMENT_CONFIG_ID string = dataCollection.outputs.dcrDeploymentConfigId
output AZURE_DCR_TOKEN_USAGE_ID string = dataCollection.outputs.dcrTokenUsageId
output AZURE_DCR_MODEL_CATALOG_ID string = dataCollection.outputs.dcrModelCatalogId
output AZURE_DCE_ENDPOINT string = dataCollection.outputs.dceEndpoint
output AZURE_DCR_QUOTA_SNAPSHOT_IMMUTABLE_ID string = dataCollection.outputs.dcrQuotaSnapshotImmutableId
output AZURE_DCR_DEPLOYMENT_CONFIG_IMMUTABLE_ID string = dataCollection.outputs.dcrDeploymentConfigImmutableId
output AZURE_DCR_TOKEN_USAGE_IMMUTABLE_ID string = dataCollection.outputs.dcrTokenUsageImmutableId
output AZURE_DCR_MODEL_CATALOG_IMMUTABLE_ID string = dataCollection.outputs.dcrModelCatalogImmutableId
output AZURE_STORAGE_ACCOUNT_NAME string = functionApp.outputs.storageAccountName
output AZURE_STORAGE_TABLE_ENDPOINT string = functionApp.outputs.storageTableEndpoint
output AZURE_APP_INSIGHTS_CONNECTION_STRING string = functionApp.outputs.appInsightsConnectionString
output AZURE_LOG_ANALYTICS_WORKSPACE_ID string = effectiveWorkspaceId
output AZURE_LOG_ANALYTICS_WORKSPACE_NAME string = effectiveWorkspaceName
output AZURE_LOG_ANALYTICS_CREATED bool = createWorkspace
