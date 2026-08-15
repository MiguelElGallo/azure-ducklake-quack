targetScope = 'resourceGroup'

param name string
param location string = resourceGroup().location
param tags object = {}
@minLength(6)
param suffix string

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

param gatewayPrincipalId string
param readerPrincipalId string
param writerPrincipalId string
param bootstrapPrincipalId string
var moduleTags = union(tags, { 'azdq-module': name })

var postgresAdminUser = 'azdq_admin'
var postgresDatabaseName = 'ducklake_catalog'
var containerName = 'ducklake'
var storageBlobReaderRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')
var storageBlobContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
var keyVaultSecretsUserRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')

resource storage 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  #disable-next-line BCP334
  name: take(replace('stazdq${suffix}', '-', ''), 24)
  location: location
  tags: moduleTags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    isHnsEnabled: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' = {
  parent: storage
  name: 'default'
  properties: {
    deleteRetentionPolicy: { enabled: true, days: 7 }
    containerDeleteRetentionPolicy: { enabled: true, days: 7 }
  }
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' = {
  parent: blobService
  name: containerName
  properties: {
    publicAccess: 'None'
  }
}

resource postgres 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: 'psql-azdq-${suffix}'
  location: location
  tags: moduleTags
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  properties: {
    administratorLogin: postgresAdminUser
    administratorLoginPassword: postgresAdminPassword
    version: '17'
    authConfig: {
      activeDirectoryAuth: 'Disabled'
      passwordAuth: 'Enabled'
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
    network: {
      publicNetworkAccess: 'Enabled'
    }
    storage: {
      storageSizeGB: 32
      autoGrow: 'Enabled'
      tier: 'P4'
    }
  }
}

resource database 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: postgres
  name: postgresDatabaseName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

// Development-preview tradeoff: ACA Consumption has non-stable egress IPs. TLS,
// least-privilege PostgreSQL logins, and Key Vault secrets remain mandatory.
resource allowAzureServices 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2024-08-01' = {
  parent: postgres
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-azdq-${suffix}'
  location: location
  tags: moduleTags
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enablePurgeProtection: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    publicNetworkAccess: 'Enabled'
  }
}

resource adminPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'postgres-admin-password'
  properties: { value: postgresAdminPassword }
}
resource readerPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'postgres-reader-password'
  properties: { value: postgresReaderPassword }
}
resource writerPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'postgres-writer-password'
  properties: { value: postgresWriterPassword }
}
resource readerTokenSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'quack-reader-token'
  properties: { value: readerQuackToken }
}
resource writerTokenSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'quack-writer-token'
  properties: { value: writerQuackToken }
}
resource easyAuthSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'easyauth-client-secret'
  properties: { value: easyAuthClientSecret }
}

resource storageReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(container.id, readerPrincipalId, 'blob-reader')
  scope: container
  properties: { principalId: readerPrincipalId, principalType: 'ServicePrincipal', roleDefinitionId: storageBlobReaderRoleId }
}
resource storageWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(container.id, writerPrincipalId, 'blob-writer')
  scope: container
  properties: { principalId: writerPrincipalId, principalType: 'ServicePrincipal', roleDefinitionId: storageBlobContributorRoleId }
}
resource storageBootstrap 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(container.id, bootstrapPrincipalId, 'blob-bootstrap')
  scope: container
  properties: { principalId: bootstrapPrincipalId, principalType: 'ServicePrincipal', roleDefinitionId: storageBlobContributorRoleId }
}

var gatewaySecretNames = [readerTokenSecret.name, writerTokenSecret.name, easyAuthSecret.name]
var readerSecretNames = [readerPasswordSecret.name, readerTokenSecret.name]
var writerSecretNames = [writerPasswordSecret.name, writerTokenSecret.name]
var bootstrapSecretNames = [adminPasswordSecret.name, readerPasswordSecret.name, writerPasswordSecret.name]

resource gatewaySecrets 'Microsoft.KeyVault/vaults/secrets@2023-07-01' existing = [for secretName in gatewaySecretNames: {
  parent: vault
  name: secretName
}]
resource readerSecrets 'Microsoft.KeyVault/vaults/secrets@2023-07-01' existing = [for secretName in readerSecretNames: {
  parent: vault
  name: secretName
}]
resource writerSecrets 'Microsoft.KeyVault/vaults/secrets@2023-07-01' existing = [for secretName in writerSecretNames: {
  parent: vault
  name: secretName
}]
resource bootstrapSecrets 'Microsoft.KeyVault/vaults/secrets@2023-07-01' existing = [for secretName in bootstrapSecretNames: {
  parent: vault
  name: secretName
}]

resource gatewaySecretAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (secretName, index) in gatewaySecretNames: {
  name: guid(gatewaySecrets[index].id, gatewayPrincipalId, 'secret-read')
  scope: gatewaySecrets[index]
  properties: { principalId: gatewayPrincipalId, principalType: 'ServicePrincipal', roleDefinitionId: keyVaultSecretsUserRoleId }
}]
resource readerSecretAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (secretName, index) in readerSecretNames: {
  name: guid(readerSecrets[index].id, readerPrincipalId, 'secret-read')
  scope: readerSecrets[index]
  properties: { principalId: readerPrincipalId, principalType: 'ServicePrincipal', roleDefinitionId: keyVaultSecretsUserRoleId }
}]
resource writerSecretAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (secretName, index) in writerSecretNames: {
  name: guid(writerSecrets[index].id, writerPrincipalId, 'secret-read')
  scope: writerSecrets[index]
  properties: { principalId: writerPrincipalId, principalType: 'ServicePrincipal', roleDefinitionId: keyVaultSecretsUserRoleId }
}]
resource bootstrapSecretAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (secretName, index) in bootstrapSecretNames: {
  name: guid(bootstrapSecrets[index].id, bootstrapPrincipalId, 'secret-read')
  scope: bootstrapSecrets[index]
  properties: { principalId: bootstrapPrincipalId, principalType: 'ServicePrincipal', roleDefinitionId: keyVaultSecretsUserRoleId }
}]

output storageAccountName string = storage.name
output dataPath string = 'az://${storage.name}.blob.${environment().suffixes.storage}/${container.name}/data/'
output postgresServerFqdn string = postgres.properties.fullyQualifiedDomainName
output postgresDatabaseName string = database.name
output keyVaultName string = vault.name
output keyVaultUri string = vault.properties.vaultUri
output secretUris object = {
  postgresAdminPassword: adminPasswordSecret.properties.secretUri
  postgresReaderPassword: readerPasswordSecret.properties.secretUri
  postgresWriterPassword: writerPasswordSecret.properties.secretUri
  readerQuackToken: readerTokenSecret.properties.secretUri
  writerQuackToken: writerTokenSecret.properties.secretUri
  easyAuthClientSecret: easyAuthSecret.properties.secretUri
}
