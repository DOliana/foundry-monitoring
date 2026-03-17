@description('Naming prefix')
param prefix string

@description('Tags to apply to all resources')
param tags object

@description('Resource ID of Application Insights instance')
param appInsightsId string

@description('Email address for alert notifications')
param alertEmail string

resource actionGroup 'Microsoft.Insights/actionGroups@2023-09-01-preview' = {
  name: '${prefix}-ag-mon'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'AIMonAlert'
    enabled: true
    emailReceivers: [
      {
        name: 'MonitoringTeam'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

// Alert: Function execution failures (3+ failed invocations in 15 minutes)
// Uses a scheduled query rule against Application Insights traces
resource functionFailureAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: '${prefix}-alert-func-failures'
  location: resourceGroup().location
  tags: tags
  properties: {
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    scopes: [
      appInsightsId
    ]
    criteria: {
      allOf: [
        {
          query: 'requests | where success == false | summarize FailedCount = count() by bin(timestamp, 5m)'
          timeAggregation: 'Total'
          metricMeasureColumn: 'FailedCount'
          operator: 'GreaterThanOrEqual'
          threshold: 3
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

output actionGroupId string = actionGroup.id
