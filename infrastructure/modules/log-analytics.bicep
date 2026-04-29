@description('Workspace name')
param name string

@description('Azure region')
param location string

@description('Tags to apply to the workspace')
param tags object = {}

@description('Daily ingestion retention (in days)')
@minValue(7)
@maxValue(730)
param retentionInDays int = 30

@description('Workspace pricing SKU')
@allowed(['PerGB2018', 'CapacityReservation', 'Free', 'Standalone', 'PerNode', 'Standard', 'Premium'])
param sku string = 'PerGB2018'

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: {
      name: sku
    }
    retentionInDays: retentionInDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

output id string = workspace.id
output name string = workspace.name
output customerId string = workspace.properties.customerId
output location string = workspace.location
