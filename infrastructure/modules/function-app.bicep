@description('Azure region for Function App and Storage Account')
param location string

@description('Azure region of the Log Analytics workspace — used for App Insights (must match workspace region)')
param workspaceLocation string

@description('Naming prefix')
param prefix string

@description('Tags to apply to all resources')
param tags object

@description('Resource ID of the existing Log Analytics workspace for App Insights')
param logAnalyticsWorkspaceId string

@description('Data Collection Endpoint URL for the Logs Ingestion API')
param dceEndpoint string

@description('Immutable ID of the Quota Snapshot DCR')
param dcrQuotaSnapshotImmutableId string

@description('Immutable ID of the Deployment Config DCR')
param dcrDeploymentConfigImmutableId string

@description('Immutable ID of the Token Usage DCR')
param dcrTokenUsageImmutableId string

@description('Max parallel subscriptions to process concurrently')
param maxParallelSubs int = 5

var suffix = uniqueString(resourceGroup().id)
var short = substring(suffix, 0, 6)
var storageAccountName = replace('${prefix}stmon${short}', '-', '')

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

// Blob container for Flex Consumption deployment packages
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'deploymentpackage'
}

// Table service for the watermark table
resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource watermarkTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = {
  parent: tableService
  name: 'watermarks'
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${prefix}-appi-mon'
  location: workspaceLocation
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspaceId
    IngestionMode: 'LogAnalytics'
  }
}

resource flexPlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: '${prefix}-plan-mon'
  location: location
  tags: tags
  kind: 'functionapp'
  sku: {
    tier: 'FlexConsumption'
    name: 'FC1'
  }
  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: '${prefix}-func-mon-${short}'
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: flexPlan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storageAccount.properties.primaryEndpoints.blob}deploymentpackage'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      runtime: {
        name: 'python'
        version: '3.13'
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 10
        instanceMemoryMB: 2048
      }
    }
    siteConfig: {
      appSettings: [
        { name: 'AzureWebJobsStorage__accountName', value: storageAccount.name }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        { name: 'DCE_ENDPOINT', value: dceEndpoint }
        { name: 'DCR_QUOTA_SNAPSHOT_IMMUTABLE_ID', value: dcrQuotaSnapshotImmutableId }
        { name: 'DCR_DEPLOYMENT_CONFIG_IMMUTABLE_ID', value: dcrDeploymentConfigImmutableId }
        { name: 'DCR_TOKEN_USAGE_IMMUTABLE_ID', value: dcrTokenUsageImmutableId }
        { name: 'WATERMARK_TABLE_NAME', value: watermarkTable.name }
        { name: 'WATERMARK_STORAGE_ENDPOINT', value: storageAccount.properties.primaryEndpoints.table }
        { name: 'MAX_PARALLEL_SUBS', value: string(maxParallelSubs) }
      ]
    }
  }
}

// ─── RBAC: Storage Blob Data Owner (for AzureWebJobsStorage & deployment) ────
resource storageBlobDataOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
  scope: storageAccount
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
  }
}

// ─── RBAC: Storage Table Data Contributor (for watermark table) ──────────────
resource storageTableDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
  scope: storageAccount
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
  }
}

// ─── RBAC: Storage Queue Data Contributor (for Azure Functions runtime) ──────
resource storageQueueDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
  scope: storageAccount
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
  }
}

output functionAppName string = functionApp.name
output functionAppPrincipalId string = functionApp.identity.principalId
output appInsightsId string = appInsights.id
output storageAccountName string = storageAccount.name
