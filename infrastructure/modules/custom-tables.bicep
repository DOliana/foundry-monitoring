@description('Name of the existing Log Analytics workspace')
param workspaceName string

// Reference the existing workspace
resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

resource tableQuotaSnapshot 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: 'QuotaSnapshot_CL'
  properties: {
    schema: {
      name: 'QuotaSnapshot_CL'
      columns: [
        { name: 'TimeGenerated', type: 'dateTime' }
        { name: 'timestamp_t', type: 'dateTime' }
        { name: 'subscriptionId_s', type: 'string' }
        { name: 'subscriptionName_s', type: 'string' }
        { name: 'region_s', type: 'string' }
        { name: 'model_s', type: 'string' }
        { name: 'deployedTPM_d', type: 'real' }
        { name: 'maxTPM_d', type: 'real' }
        { name: 'utilizationPct_d', type: 'real' }
      ]
    }
    retentionInDays: 90
    totalRetentionInDays: 90
  }
}

resource tableDeploymentConfig 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: 'DeploymentConfig_CL'
  properties: {
    schema: {
      name: 'DeploymentConfig_CL'
      columns: [
        { name: 'TimeGenerated', type: 'dateTime' }
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
    retentionInDays: 90
    totalRetentionInDays: 90
  }
}

resource tableTokenUsage 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: 'TokenUsage_CL'
  properties: {
    schema: {
      name: 'TokenUsage_CL'
      columns: [
        { name: 'TimeGenerated', type: 'dateTime' }
        { name: 'timestamp_t', type: 'dateTime' }
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
    retentionInDays: 90
    totalRetentionInDays: 90
  }
}

resource tableModelCatalog 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: 'ModelCatalog_CL'
  properties: {
    schema: {
      name: 'ModelCatalog_CL'
      columns: [
        { name: 'TimeGenerated', type: 'dateTime' }
        { name: 'subscriptionId_s', type: 'string' }
        { name: 'subscriptionName_s', type: 'string' }
        { name: 'region_s', type: 'string' }
        { name: 'modelFormat_s', type: 'string' }
        { name: 'modelName_s', type: 'string' }
        { name: 'modelVersion_s', type: 'string' }
        { name: 'lifecycleStatus_s', type: 'string' }
        { name: 'isDefaultVersion_b', type: 'boolean' }
        { name: 'maxCapacity_d', type: 'real' }
        { name: 'fineTune_b', type: 'boolean' }
        { name: 'inference_b', type: 'boolean' }
        { name: 'chatCompletion_b', type: 'boolean' }
        { name: 'completion_b', type: 'boolean' }
        { name: 'embeddings_b', type: 'boolean' }
        { name: 'imageGeneration_b', type: 'boolean' }
        { name: 'deprecationInference_s', type: 'string' }
        { name: 'deprecationFineTune_s', type: 'string' }
        { name: 'skuNames_s', type: 'string' }
      ]
    }
    retentionInDays: 90
    totalRetentionInDays: 90
  }
}
