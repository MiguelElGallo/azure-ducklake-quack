targetScope = 'resourceGroup'

param name string
param location string = resourceGroup().location
param tags object = {}
param suffix string
param logAnalyticsCustomerId string
@secure()
param logAnalyticsSharedKey string
param pullPrincipalIds array
var moduleTags = union(tags, { 'azdq-module': name })

var acrPullRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: replace('acrazdq${suffix}', '-', '')
  location: location
  tags: moduleTags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
    policies: {
      quarantinePolicy: { status: 'disabled' }
      retentionPolicy: { days: 7, status: 'disabled' }
      trustPolicy: { type: 'Notary', status: 'disabled' }
    }
  }
}

resource environment 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: 'cae-azdq-${suffix}'
  location: location
  tags: moduleTags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsCustomerId
        sharedKey: logAnalyticsSharedKey
      }
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

resource pullAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in pullPrincipalIds: {
  name: guid(registry.id, principalId, 'acrpull')
  scope: registry
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: acrPullRoleId
  }
}]

output registryName string = registry.name
output registryServer string = registry.properties.loginServer
output containerAppsEnvironmentId string = environment.id
output containerAppsEnvironmentName string = environment.name
output containerAppsEnvironmentDefaultDomain string = environment.properties.defaultDomain
