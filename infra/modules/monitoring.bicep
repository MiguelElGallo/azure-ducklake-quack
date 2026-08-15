targetScope = 'resourceGroup'

param name string
param location string = resourceGroup().location
param tags object = {}
param suffix string
var moduleTags = union(tags, { 'azdq-module': name })

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-azdq-${suffix}'
  location: location
  tags: moduleTags
  properties: {
    retentionInDays: 30
    sku: {
      name: 'PerGB2018'
    }
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

output workspaceId string = workspace.id
output customerId string = workspace.properties.customerId
@secure()
output sharedKey string = workspace.listKeys().primarySharedKey
