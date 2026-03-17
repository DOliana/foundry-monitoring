// Monitoring infrastructure for Azure AI Foundry / Azure OpenAI
//
// Deploys: DCE, DCRs (3 custom tables), Function App (Flex Consumption),
//          Storage Account (watermark table), App Insights, alert rules.
//
// Prerequisites:
//   - An existing Log Analytics workspace
//   - azd CLI installed (https://aka.ms/azd)
//
// Deploy with azd (recommended):
//   azd env set AZURE_LOG_ANALYTICS_WORKSPACE_ID "/subscriptions/.../workspaces/{name}"
//   azd env set AZURE_ALERT_EMAIL "team@contoso.com"
//   azd env set AZURE_TARGET_SUBSCRIPTION_IDS "sub1,sub2"
//   azd up
//
// Deploy manually (alternative):
//   ./scripts/Deploy-MonitoringInfra.ps1 -LogAnalyticsWorkspaceId "..." -AlertEmail "..." -TargetSubscriptionIds @("...")
//
// Parameters:
//   MANDATORY (no defaults — must be provided):
//     logAnalyticsWorkspaceId  — full resource ID of the existing Log Analytics workspace
//     alertEmail               — email for alert notifications
//
//   OPTIONAL (have defaults — override as needed):
//     location                 — Azure region for Function App & Storage (default: swedencentral)
//                                DCE, DCRs, and App Insights are auto-placed in the workspace's region
//     prefix                   — naming prefix (default: heaip)
//     environment              — environment tag (default: DEV)
//     maxParallelSubs          — concurrency limit for subscription processing (default: 5)

targetScope = 'resourceGroup'

// ── Optional parameters (have defaults) ──────────────────────────────────────

@description('Optional. Azure region for Function App and Storage Account. DCE, DCRs, and App Insights are automatically placed in the Log Analytics workspace region. Default: swedencentral')
param location string = 'swedencentral'

@description('Naming prefix (lowercase, 2-8 chars).')
@minLength(2)
@maxLength(8)
param prefix string

@description('Optional. Environment tag. Default: DEV')
@allowed(['DEV', 'TEST', 'PROD'])
param environment string = 'DEV'

@description('Optional. Max parallel subscriptions to process concurrently. Default: 5')
param maxParallelSubs int = 5

// ── Mandatory parameters (no defaults) ───────────────────────────────────────

@description('Mandatory. Full resource ID of the existing Log Analytics workspace. Example: /subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.OperationalInsights/workspaces/{name}')
param logAnalyticsWorkspaceId string

@description('Mandatory. Email address for alert notifications.')
param alertEmail string

var tags = {
  Environment: environment
  Project: 'AI-Foundry-Monitoring'
}

// Extract workspace location from the existing resource
var workspaceSubscriptionId = split(logAnalyticsWorkspaceId, '/')[2]
var workspaceResourceGroup = split(logAnalyticsWorkspaceId, '/')[4]
var workspaceName = split(logAnalyticsWorkspaceId, '/')[8]

resource existingWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
  scope: resourceGroup(workspaceSubscriptionId, workspaceResourceGroup)
}

// Custom tables must exist in the workspace before DCRs can reference them
module customTables 'modules/custom-tables.bicep' = {
  scope: resourceGroup(workspaceSubscriptionId, workspaceResourceGroup)
  params: {
    workspaceName: workspaceName
  }
}

module dataCollection 'modules/data-collection.bicep' = {
  dependsOn: [customTables]
  params: {
    location: existingWorkspace.location
    prefix: prefix
    tags: tags
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
  }
}

module functionApp 'modules/function-app.bicep' = {
  params: {
    location: location
    workspaceLocation: existingWorkspace.location
    prefix: prefix
    tags: tags
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    dceEndpoint: dataCollection.outputs.dceEndpoint
    dcrQuotaSnapshotImmutableId: dataCollection.outputs.dcrQuotaSnapshotImmutableId
    dcrDeploymentConfigImmutableId: dataCollection.outputs.dcrDeploymentConfigImmutableId
    dcrTokenUsageImmutableId: dataCollection.outputs.dcrTokenUsageImmutableId
    maxParallelSubs: maxParallelSubs
  }
}

module alerts 'modules/alerts.bicep' = {
  params: {
    prefix: prefix
    tags: tags
    appInsightsId: functionApp.outputs.appInsightsId
    alertEmail: alertEmail
  }
}

// Outputs for azd environment variables and RBAC scripts
output AZURE_FUNCTION_APP_PRINCIPAL_ID string = functionApp.outputs.functionAppPrincipalId
output AZURE_FUNCTION_APP_NAME string = functionApp.outputs.functionAppName
output AZURE_DCR_QUOTA_SNAPSHOT_ID string = dataCollection.outputs.dcrQuotaSnapshotId
output AZURE_DCR_DEPLOYMENT_CONFIG_ID string = dataCollection.outputs.dcrDeploymentConfigId
output AZURE_DCR_TOKEN_USAGE_ID string = dataCollection.outputs.dcrTokenUsageId
output AZURE_DCE_ENDPOINT string = dataCollection.outputs.dceEndpoint
output AZURE_DCR_QUOTA_SNAPSHOT_IMMUTABLE_ID string = dataCollection.outputs.dcrQuotaSnapshotImmutableId
output AZURE_DCR_DEPLOYMENT_CONFIG_IMMUTABLE_ID string = dataCollection.outputs.dcrDeploymentConfigImmutableId
output AZURE_DCR_TOKEN_USAGE_IMMUTABLE_ID string = dataCollection.outputs.dcrTokenUsageImmutableId
output AZURE_STORAGE_ACCOUNT_NAME string = functionApp.outputs.storageAccountName
output AZURE_STORAGE_TABLE_ENDPOINT string = functionApp.outputs.storageTableEndpoint
output AZURE_APP_INSIGHTS_CONNECTION_STRING string = functionApp.outputs.appInsightsConnectionString
output AZURE_LOG_ANALYTICS_WORKSPACE_ID string = logAnalyticsWorkspaceId
