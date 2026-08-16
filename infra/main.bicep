targetScope = 'subscription'

@minLength(2)
@maxLength(20)
param environmentName string

param location string = 'swedencentral'
param deployBootstrap bool = false
param deployApps bool = false
param deployDbtSpike bool = false

@secure()
param postgresAdminPassword string
@secure()
param postgresReaderPassword string
@secure()
param postgresWriterPassword string
@secure()
param readerQuackToken string
@secure()
param writerQuackToken string
@secure()
param easyAuthClientSecret string

param entraApiClientId string
param entraNativeClientId string
param entraReaderGroupId string
param entraWriterGroupId string
param gatewayImage string = ''
param runtimeImage string = ''
param dbtSpikeImage string = ''

var suffix = take(uniqueString(subscription().id, environmentName, location), 6)
var tags = {
  'azd-env-name': environmentName
  project: 'azure-ducklake-quack'
  environment: 'dev'
}

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: 'rg-azure-ducklake-quack-${environmentName}'
  location: location
  tags: tags
}

module identities './modules/identities.bicep' = {
  name: 'identities'
  scope: resourceGroup
  params: {
    name: environmentName
    location: location
    tags: tags
    suffix: suffix
  }
}

module monitoring './modules/monitoring.bicep' = {
  name: 'monitoring'
  scope: resourceGroup
  params: {
    name: environmentName
    location: location
    tags: tags
    suffix: suffix
  }
}

module platform './modules/platform.bicep' = {
  name: 'platform'
  scope: resourceGroup
  params: {
    name: environmentName
    location: location
    tags: tags
    suffix: suffix
    logAnalyticsCustomerId: monitoring.outputs.customerId
    logAnalyticsSharedKey: monitoring.outputs.sharedKey
    pullPrincipalIds: [
      identities.outputs.gatewayPrincipalId
      identities.outputs.readerPrincipalId
      identities.outputs.writerPrincipalId
      identities.outputs.bootstrapPrincipalId
    ]
  }
}

module data './modules/data.bicep' = {
  name: 'data'
  scope: resourceGroup
  params: {
    name: environmentName
    location: location
    tags: tags
    suffix: suffix
    postgresAdminPassword: postgresAdminPassword
    postgresReaderPassword: postgresReaderPassword
    postgresWriterPassword: postgresWriterPassword
    readerQuackToken: readerQuackToken
    writerQuackToken: writerQuackToken
    easyAuthClientSecret: easyAuthClientSecret
    gatewayPrincipalId: identities.outputs.gatewayPrincipalId
    readerPrincipalId: identities.outputs.readerPrincipalId
    writerPrincipalId: identities.outputs.writerPrincipalId
    bootstrapPrincipalId: identities.outputs.bootstrapPrincipalId
  }
}

module apps './modules/apps.bicep' = if (deployApps) {
  name: 'apps'
  scope: resourceGroup
  params: {
    name: environmentName
    location: location
    tags: tags
    containerAppsEnvironmentId: platform.outputs.containerAppsEnvironmentId
    containerAppsEnvironmentDefaultDomain: platform.outputs.containerAppsEnvironmentDefaultDomain
    registryServer: platform.outputs.registryServer
    gatewayImage: gatewayImage
    runtimeImage: runtimeImage
    gatewayIdentityId: identities.outputs.gatewayIdentityId
    readerIdentityId: identities.outputs.readerIdentityId
    writerIdentityId: identities.outputs.writerIdentityId
    readerIdentityClientId: identities.outputs.readerClientId
    writerIdentityClientId: identities.outputs.writerClientId
    storageAccountName: data.outputs.storageAccountName
    dataPath: data.outputs.dataPath
    postgresServerFqdn: data.outputs.postgresServerFqdn
    postgresDatabaseName: data.outputs.postgresDatabaseName
    secretUris: data.outputs.secretUris
    entraApiClientId: entraApiClientId
    entraNativeClientId: entraNativeClientId
    entraReaderGroupId: entraReaderGroupId
    entraWriterGroupId: entraWriterGroupId
  }
}

module bootstrap './modules/bootstrap.bicep' = if (deployBootstrap) {
  name: 'bootstrap'
  scope: resourceGroup
  params: {
    name: environmentName
    location: location
    tags: tags
    containerAppsEnvironmentId: platform.outputs.containerAppsEnvironmentId
    registryServer: platform.outputs.registryServer
    runtimeImage: runtimeImage
    bootstrapIdentityId: identities.outputs.bootstrapIdentityId
    bootstrapIdentityClientId: identities.outputs.bootstrapClientId
    storageAccountName: data.outputs.storageAccountName
    dataPath: data.outputs.dataPath
    postgresServerFqdn: data.outputs.postgresServerFqdn
    postgresDatabaseName: data.outputs.postgresDatabaseName
    secretUris: data.outputs.secretUris
  }
}

module dbtSpike './modules/dbt-spike.bicep' = if (deployDbtSpike) {
  name: 'dbt-spike'
  scope: resourceGroup
  params: {
    name: environmentName
    location: location
    tags: tags
    containerAppsEnvironmentId: platform.outputs.containerAppsEnvironmentId
    registryServer: platform.outputs.registryServer
    dbtSpikeImage: dbtSpikeImage
    writerIdentityId: identities.outputs.writerIdentityId
    writerIdentityClientId: identities.outputs.writerClientId
    storageAccountName: data.outputs.storageAccountName
    dataPath: data.outputs.dataPath
    postgresServerFqdn: data.outputs.postgresServerFqdn
    postgresDatabaseName: data.outputs.postgresDatabaseName
    postgresWriterPasswordSecretUri: data.outputs.secretUris.postgresWriterPassword
  }
}

output AZURE_RESOURCE_GROUP string = resourceGroup.name
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = platform.outputs.registryServer
output AZURE_CONTAINER_REGISTRY_NAME string = platform.outputs.registryName
output AZURE_CONTAINER_APPS_ENVIRONMENT_NAME string = platform.outputs.containerAppsEnvironmentName
output AZURE_KEY_VAULT_NAME string = data.outputs.keyVaultName
output AZURE_LOG_ANALYTICS_WORKSPACE_ID string = monitoring.outputs.workspaceId
output AZURE_STORAGE_ACCOUNT string = data.outputs.storageAccountName
output POSTGRES_SERVER_FQDN string = data.outputs.postgresServerFqdn
output BOOTSTRAP_JOB_NAME string = deployBootstrap ? bootstrap!.outputs.jobName : ''
output DBT_SPIKE_JOB_NAME string = deployDbtSpike ? dbtSpike!.outputs.jobName : ''
output GATEWAY_URL string = deployApps ? apps!.outputs.gatewayUrl : ''
output QUACK_URI string = deployApps ? apps!.outputs.quackUri : ''
