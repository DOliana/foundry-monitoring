@description('Azure region')
param location string

@description('Resource ID of the existing Log Analytics workspace')
param logAnalyticsWorkspaceId string

@description('Naming prefix')
param prefix string

@description('Tags to apply to all resources')
param tags object

// Data Collection Endpoint — HTTPS ingress for custom table writes
resource dce 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: '${prefix}-dce'
  location: location
  tags: tags
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// Custom tables are defined inline in the DCR via the schema.
// One DCR per custom table for independent management.

resource dcrQuotaSnapshot 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: '${prefix}-dcr-quota-snapshot'
  location: location
  tags: tags
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      'Custom-QuotaSnapshot_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'timestamp_t', type: 'datetime' }
          { name: 'subscriptionId_s', type: 'string' }
          { name: 'subscriptionName_s', type: 'string' }
          { name: 'region_s', type: 'string' }
          { name: 'model_s', type: 'string' }
          { name: 'deployedTPM_d', type: 'real' }
          { name: 'maxTPM_d', type: 'real' }
          { name: 'utilizationPct_d', type: 'real' }
        ]
      }
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: logAnalyticsWorkspaceId
          name: 'logAnalytics'
        }
      ]
    }
    dataFlows: [
      {
        streams: ['Custom-QuotaSnapshot_CL']
        destinations: ['logAnalytics']
        transformKql: 'source'
        outputStream: 'Custom-QuotaSnapshot_CL'
      }
    ]
  }
}

resource dcrDeploymentConfig 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: '${prefix}-dcr-deployment-config'
  location: location
  tags: tags
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      'Custom-DeploymentConfig_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'subscriptionId_s', type: 'string' }
          { name: 'subscriptionName_s', type: 'string' }
          { name: 'resourceId_s', type: 'string' }
          { name: 'resourceName_s', type: 'string' }
          { name: 'location_s', type: 'string' }
          { name: 'kind_s', type: 'string' }
          { name: 'deploymentName_s', type: 'string' }
          { name: 'modelName_s', type: 'string' }
          { name: 'modelVersion_s', type: 'string' }
          { name: 'skuName_s', type: 'string' }
          { name: 'skuCapacity_d', type: 'real' }
          { name: 'tpmLimit_d', type: 'real' }
          { name: 'rpmLimit_d', type: 'real' }
        ]
      }
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: logAnalyticsWorkspaceId
          name: 'logAnalytics'
        }
      ]
    }
    dataFlows: [
      {
        streams: ['Custom-DeploymentConfig_CL']
        destinations: ['logAnalytics']
        transformKql: 'source'
        outputStream: 'Custom-DeploymentConfig_CL'
      }
    ]
  }
}

resource dcrTokenUsage 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: '${prefix}-dcr-token-usage'
  location: location
  tags: tags
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      'Custom-TokenUsage_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'timestamp_t', type: 'datetime' }
          { name: 'subscriptionId_s', type: 'string' }
          { name: 'subscriptionName_s', type: 'string' }
          { name: 'resourceId_s', type: 'string' }
          { name: 'resourceName_s', type: 'string' }
          { name: 'location_s', type: 'string' }
          { name: 'deploymentName_s', type: 'string' }
          { name: 'modelName_s', type: 'string' }
          { name: 'promptTokens_d', type: 'real' }
          { name: 'completionTokens_d', type: 'real' }
          { name: 'totalTokens_d', type: 'real' }
          { name: 'granularity_s', type: 'string' }
        ]
      }
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: logAnalyticsWorkspaceId
          name: 'logAnalytics'
        }
      ]
    }
    dataFlows: [
      {
        streams: ['Custom-TokenUsage_CL']
        destinations: ['logAnalytics']
        transformKql: 'source'
        outputStream: 'Custom-TokenUsage_CL'
      }
    ]
  }
}

output dceId string = dce.id
output dceEndpoint string = dce.properties.logsIngestion.endpoint
output dcrQuotaSnapshotId string = dcrQuotaSnapshot.id
output dcrQuotaSnapshotImmutableId string = dcrQuotaSnapshot.properties.immutableId
output dcrDeploymentConfigId string = dcrDeploymentConfig.id
output dcrDeploymentConfigImmutableId string = dcrDeploymentConfig.properties.immutableId
output dcrTokenUsageId string = dcrTokenUsage.id
output dcrTokenUsageImmutableId string = dcrTokenUsage.properties.immutableId
