targetScope = 'resourceGroup'

param name string
param location string = resourceGroup().location
param tags object = {}
param suffix string
var moduleTags = union(tags, { 'azdq-module': name })

resource gateway 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-azdq-gateway-${suffix}'
  location: location
  tags: moduleTags
}

resource reader 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-azdq-reader-${suffix}'
  location: location
  tags: moduleTags
}

resource writer 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-azdq-writer-${suffix}'
  location: location
  tags: moduleTags
}

resource bootstrap 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-azdq-bootstrap-${suffix}'
  location: location
  tags: moduleTags
}

output gatewayIdentityId string = gateway.id
output gatewayPrincipalId string = gateway.properties.principalId
output readerIdentityId string = reader.id
output readerPrincipalId string = reader.properties.principalId
output readerClientId string = reader.properties.clientId
output writerIdentityId string = writer.id
output writerPrincipalId string = writer.properties.principalId
output writerClientId string = writer.properties.clientId
output bootstrapIdentityId string = bootstrap.id
output bootstrapPrincipalId string = bootstrap.properties.principalId
output bootstrapClientId string = bootstrap.properties.clientId
