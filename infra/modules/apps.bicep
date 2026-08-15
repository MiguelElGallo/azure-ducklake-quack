targetScope = 'resourceGroup'

param name string
param location string = resourceGroup().location
param tags object = {}
param containerAppsEnvironmentId string
param containerAppsEnvironmentDefaultDomain string
param registryServer string
param gatewayImage string
param runtimeImage string
param gatewayIdentityId string
param readerIdentityId string
param writerIdentityId string
param readerIdentityClientId string
param writerIdentityClientId string
param storageAccountName string
param dataPath string
param postgresServerFqdn string
param postgresDatabaseName string
param secretUris object
param entraApiClientId string
param entraNativeClientId string
param entraReaderGroupId string
param entraWriterGroupId string
var moduleTags = union(tags, { 'azdq-module': name })

var gatewayName = 'ca-azdq-gateway'
var readerName = 'ca-azdq-reader'
var writerName = 'ca-azdq-writer'
var publicQuackUri = 'quack:${gatewayName}.${containerAppsEnvironmentDefaultDomain}:443'
var readerBackendUrl = 'https://${readerName}.internal.${containerAppsEnvironmentDefaultDomain}'
var writerBackendUrl = 'https://${writerName}.internal.${containerAppsEnvironmentDefaultDomain}'
var issuer = '${environment().authentication.loginEndpoint}${subscription().tenantId}/v2.0'

resource reader 'Microsoft.App/containerApps@2025-01-01' = {
  name: readerName
  location: location
  tags: union(moduleTags, { 'azd-service-name': 'reader' })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${readerIdentityId}': {} }
  }
  properties: {
    environmentId: containerAppsEnvironmentId
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: false
        targetPort: 9494
        transport: 'http'
        allowInsecure: false
      }
      registries: [
        { server: registryServer, identity: readerIdentityId }
      ]
      secrets: [
        { name: 'postgres-password', keyVaultUrl: secretUris.postgresReaderPassword, identity: readerIdentityId }
        { name: 'quack-token', keyVaultUrl: secretUris.readerQuackToken, identity: readerIdentityId }
      ]
    }
    template: {
      containers: [
        {
          name: 'reader'
          image: runtimeImage
          env: [
            { name: 'AZDQ_ROLE', value: 'reader' }
            { name: 'AZURE_CLIENT_ID', value: readerIdentityClientId }
            { name: 'AZURE_STORAGE_ACCOUNT', value: storageAccountName }
            { name: 'DUCKLAKE_DATA_PATH', value: dataPath }
            { name: 'DUCKLAKE_METADATA_SCHEMA', value: 'public' }
            { name: 'POSTGRES_HOST', value: postgresServerFqdn }
            { name: 'POSTGRES_DATABASE', value: postgresDatabaseName }
            { name: 'POSTGRES_USER', value: 'azdq_reader' }
            { name: 'POSTGRES_PASSWORD', secretRef: 'postgres-password' }
            { name: 'POSTGRES_SSLMODE', value: 'require' }
            { name: 'QUACK_TOKEN', secretRef: 'quack-token' }
            // Give libcurl/Azure SDK an explicit Debian CA bundle inside ACA.
            { name: 'SSL_CERT_FILE', value: '/etc/ssl/certs/ca-certificates.crt' }
            { name: 'CURL_CA_BUNDLE', value: '/etc/ssl/certs/ca-certificates.crt' }
            { name: 'RUST_LOG', value: 'info' }
          ]
          resources: { cpu: json('0.5'), memory: '1Gi' }
          probes: [
            { type: 'Startup', httpGet: { path: '/healthz', port: 8080 }, periodSeconds: 5, failureThreshold: 60 }
            { type: 'Liveness', httpGet: { path: '/healthz', port: 8080 }, periodSeconds: 30, failureThreshold: 3 }
            { type: 'Readiness', httpGet: { path: '/readyz', port: 8080 }, periodSeconds: 10, failureThreshold: 3 }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

resource writer 'Microsoft.App/containerApps@2025-01-01' = {
  name: writerName
  location: location
  tags: union(moduleTags, { 'azd-service-name': 'writer' })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${writerIdentityId}': {} }
  }
  properties: {
    environmentId: containerAppsEnvironmentId
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: false
        targetPort: 9494
        transport: 'http'
        allowInsecure: false
      }
      registries: [
        { server: registryServer, identity: writerIdentityId }
      ]
      secrets: [
        { name: 'postgres-password', keyVaultUrl: secretUris.postgresWriterPassword, identity: writerIdentityId }
        { name: 'quack-token', keyVaultUrl: secretUris.writerQuackToken, identity: writerIdentityId }
      ]
    }
    template: {
      containers: [
        {
          name: 'writer'
          image: runtimeImage
          env: [
            { name: 'AZDQ_ROLE', value: 'writer' }
            { name: 'AZURE_CLIENT_ID', value: writerIdentityClientId }
            { name: 'AZURE_STORAGE_ACCOUNT', value: storageAccountName }
            { name: 'DUCKLAKE_DATA_PATH', value: dataPath }
            { name: 'DUCKLAKE_METADATA_SCHEMA', value: 'public' }
            { name: 'POSTGRES_HOST', value: postgresServerFqdn }
            { name: 'POSTGRES_DATABASE', value: postgresDatabaseName }
            { name: 'POSTGRES_USER', value: 'azdq_writer' }
            { name: 'POSTGRES_PASSWORD', secretRef: 'postgres-password' }
            { name: 'POSTGRES_SSLMODE', value: 'require' }
            { name: 'QUACK_TOKEN', secretRef: 'quack-token' }
            // Give libcurl/Azure SDK an explicit Debian CA bundle inside ACA.
            { name: 'SSL_CERT_FILE', value: '/etc/ssl/certs/ca-certificates.crt' }
            { name: 'CURL_CA_BUNDLE', value: '/etc/ssl/certs/ca-certificates.crt' }
            { name: 'RUST_LOG', value: 'info' }
          ]
          resources: { cpu: json('0.5'), memory: '1Gi' }
          probes: [
            { type: 'Startup', httpGet: { path: '/healthz', port: 8080 }, periodSeconds: 5, failureThreshold: 60 }
            { type: 'Liveness', httpGet: { path: '/healthz', port: 8080 }, periodSeconds: 30, failureThreshold: 3 }
            { type: 'Readiness', httpGet: { path: '/readyz', port: 8080 }, periodSeconds: 10, failureThreshold: 3 }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 1
        rules: [
          { name: 'http', http: { metadata: { concurrentRequests: '1' } } }
        ]
      }
    }
  }
}

resource gateway 'Microsoft.App/containerApps@2025-01-01' = {
  name: gatewayName
  location: location
  tags: union(moduleTags, { 'azd-service-name': 'gateway' })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${gatewayIdentityId}': {} }
  }
  properties: {
    environmentId: containerAppsEnvironmentId
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8080
        transport: 'http'
        allowInsecure: false
      }
      registries: [
        { server: registryServer, identity: gatewayIdentityId }
      ]
      secrets: [
        { name: 'reader-token', keyVaultUrl: secretUris.readerQuackToken, identity: gatewayIdentityId }
        { name: 'writer-token', keyVaultUrl: secretUris.writerQuackToken, identity: gatewayIdentityId }
        { name: 'easyauth-client-secret', keyVaultUrl: secretUris.easyAuthClientSecret, identity: gatewayIdentityId }
      ]
    }
    template: {
      containers: [
        {
          name: 'gateway'
          image: gatewayImage
          env: [
            { name: 'PUBLIC_QUACK_URI', value: publicQuackUri }
            { name: 'READER_BACKEND_URL', value: readerBackendUrl }
            { name: 'WRITER_BACKEND_URL', value: writerBackendUrl }
            { name: 'ENTRA_READER_GROUP_ID', value: entraReaderGroupId }
            { name: 'ENTRA_WRITER_GROUP_ID', value: entraWriterGroupId }
            { name: 'READER_QUACK_TOKEN', secretRef: 'reader-token' }
            { name: 'WRITER_QUACK_TOKEN', secretRef: 'writer-token' }
            { name: 'RUST_LOG', value: 'info' }
          ]
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          probes: [
            { type: 'Liveness', httpGet: { path: '/healthz', port: 8080 }, periodSeconds: 30, failureThreshold: 3 }
            { type: 'Readiness', httpGet: { path: '/readyz', port: 8080 }, periodSeconds: 10, failureThreshold: 3 }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 1
        rules: [
          { name: 'http', http: { metadata: { concurrentRequests: '10' } } }
        ]
      }
    }
  }
}

resource auth 'Microsoft.App/containerApps/authConfigs@2025-01-01' = {
  parent: gateway
  name: 'current'
  properties: {
    platform: { enabled: true, runtimeVersion: '~1' }
    globalValidation: {
      unauthenticatedClientAction: 'Return401'
      redirectToProvider: 'azureactivedirectory'
      excludedPaths: [
        '/healthz'
        '/readyz'
      ]
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: entraApiClientId
          clientSecretSettingName: 'easyauth-client-secret'
          openIdIssuer: issuer
        }
        validation: {
          allowedAudiences: [
            'api://${entraApiClientId}'
          ]
          defaultAuthorizationPolicy: {
            allowedApplications: [
              entraNativeClientId
            ]
          }
        }
      }
    }
    login: {
      tokenStore: { enabled: false }
    }
  }
}

output gatewayUrl string = 'https://${gateway.properties.configuration.ingress.fqdn}'
output quackUri string = publicQuackUri
