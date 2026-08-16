targetScope = 'resourceGroup'

param name string
param location string = resourceGroup().location
param tags object = {}
param containerAppsEnvironmentId string
param registryServer string
param dbtSpikeImage string
param writerIdentityId string
param writerIdentityClientId string
param storageAccountName string
param dataPath string
param postgresServerFqdn string
param postgresDatabaseName string
param postgresWriterPasswordSecretUri string

var moduleTags = union(tags, { 'azdq-module': name })
var parquetSourcePath = '${dataPath}sources/dbt-spike/orders.parquet'

resource dbtSpike 'Microsoft.App/jobs@2025-01-01' = {
  name: 'caj-azdq-dbt-spike'
  location: location
  tags: moduleTags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${writerIdentityId}': {} }
  }
  properties: {
    environmentId: containerAppsEnvironmentId
    workloadProfileName: 'Consumption'
    configuration: {
      triggerType: 'Manual'
      replicaTimeout: 900
      replicaRetryLimit: 0
      manualTriggerConfig: { parallelism: 1, replicaCompletionCount: 1 }
      registries: [
        { server: registryServer, identity: writerIdentityId }
      ]
      secrets: [
        {
          name: 'writer-password'
          keyVaultUrl: postgresWriterPasswordSecretUri
          identity: writerIdentityId
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'dbt-spike'
          image: dbtSpikeImage
          env: [
            { name: 'DBT_TARGET', value: 'writer' }
            { name: 'DUCKLAKE_METADATA_PATH', value: 'postgres:' }
            { name: 'DUCKLAKE_METADATA_SCHEMA', value: 'public' }
            { name: 'DUCKLAKE_DATA_PATH', value: dataPath }
            { name: 'DBT_PARQUET_SOURCE_PATH', value: parquetSourcePath }
            { name: 'AZURE_STORAGE_ACCOUNT', value: storageAccountName }
            { name: 'AZURE_CLIENT_ID', value: writerIdentityClientId }
            { name: 'PGHOST', value: postgresServerFqdn }
            { name: 'PGPORT', value: '5432' }
            { name: 'PGDATABASE', value: postgresDatabaseName }
            { name: 'PGUSER', value: 'azdq_writer' }
            { name: 'PGPASSWORD', secretRef: 'writer-password' }
            { name: 'PGSSLMODE', value: 'require' }
            { name: 'SSL_CERT_FILE', value: '/etc/ssl/certs/ca-certificates.crt' }
            { name: 'CURL_CA_INFO', value: '/etc/ssl/certs/ca-certificates.crt' }
          ]
          resources: { cpu: json('0.5'), memory: '1Gi' }
        }
      ]
    }
  }
}

output jobName string = dbtSpike.name
