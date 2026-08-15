targetScope = 'resourceGroup'

param name string
param location string = resourceGroup().location
param tags object = {}
param containerAppsEnvironmentId string
param registryServer string
param runtimeImage string
param bootstrapIdentityId string
param bootstrapIdentityClientId string
param storageAccountName string
param dataPath string
param postgresServerFqdn string
param postgresDatabaseName string
param secretUris object

var moduleTags = union(tags, { 'azdq-module': name })

resource bootstrap 'Microsoft.App/jobs@2025-01-01' = {
  name: 'caj-azdq-bootstrap'
  location: location
  tags: moduleTags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${bootstrapIdentityId}': {} }
  }
  properties: {
    environmentId: containerAppsEnvironmentId
    workloadProfileName: 'Consumption'
    configuration: {
      triggerType: 'Manual'
      replicaTimeout: 900
      replicaRetryLimit: 1
      manualTriggerConfig: { parallelism: 1, replicaCompletionCount: 1 }
      registries: [
        { server: registryServer, identity: bootstrapIdentityId }
      ]
      secrets: [
        { name: 'admin-password', keyVaultUrl: secretUris.postgresAdminPassword, identity: bootstrapIdentityId }
        { name: 'reader-password', keyVaultUrl: secretUris.postgresReaderPassword, identity: bootstrapIdentityId }
        { name: 'writer-password', keyVaultUrl: secretUris.postgresWriterPassword, identity: bootstrapIdentityId }
      ]
    }
    template: {
      containers: [
        {
          name: 'bootstrap'
          image: runtimeImage
          command: ['/usr/local/bin/azdq-bootstrap']
          env: [
            { name: 'POSTGRES_HOST', value: postgresServerFqdn }
            { name: 'POSTGRES_DATABASE', value: postgresDatabaseName }
            { name: 'POSTGRES_ADMIN_USER', value: 'azdq_admin' }
            { name: 'POSTGRES_ADMIN_PASSWORD', secretRef: 'admin-password' }
            { name: 'POSTGRES_SSLMODE', value: 'require' }
            { name: 'DUCKLAKE_METADATA_SCHEMA', value: 'public' }
            { name: 'DUCKLAKE_DATA_PATH', value: dataPath }
            { name: 'AZURE_STORAGE_ACCOUNT', value: storageAccountName }
            { name: 'AZURE_CLIENT_ID', value: bootstrapIdentityClientId }
            { name: 'POSTGRES_READER_USER', value: 'azdq_reader' }
            { name: 'POSTGRES_READER_PASSWORD', secretRef: 'reader-password' }
            { name: 'POSTGRES_WRITER_USER', value: 'azdq_writer' }
            { name: 'POSTGRES_WRITER_PASSWORD', secretRef: 'writer-password' }
            // Keep bootstrap storage access on the same explicit trust bundle as the runtimes.
            { name: 'SSL_CERT_FILE', value: '/etc/ssl/certs/ca-certificates.crt' }
            { name: 'CURL_CA_BUNDLE', value: '/etc/ssl/certs/ca-certificates.crt' }
          ]
          resources: { cpu: json('0.5'), memory: '1Gi' }
        }
      ]
    }
  }
}

output jobName string = bootstrap.name
