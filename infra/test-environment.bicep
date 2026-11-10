targetScope = 'resourceGroup'

param location string = resourceGroup().location
param suffix string = '261110-844b'

@description('Use only with an explicitly approved test-RG policy exemption. Anonymous and shared-key access remain disabled.')
param enableTestStoragePublicAccess bool = false

@secure()
param notificationEmail string

var tags = {
  workload: 'bing-domain-guard-demo'
  environment: 'test'
}
var deploymentContainer = 'function-packages'
var storageName = 'stbdg${uniqueString(resourceGroup().id)}'

// Based on Azure-Samples/functions-quickstart-dotnet-azd v1.0.0.
module identity 'br/public:avm/res/managed-identity/user-assigned-identity:0.4.1' = {
  name: 'function-identity'
  params: {
    name: 'id-bing-guard-${suffix}'
    location: location
    tags: tags
  }
}

module storage 'br/public:avm/res/storage/storage-account:0.8.3' = {
  name: 'function-storage'
  params: {
    name: storageName
    location: location
    tags: tags
    skuName: 'Standard_LRS'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: enableTestStoragePublicAccess ? 'Enabled' : 'Disabled'
    networkAcls: {
      defaultAction: enableTestStoragePublicAccess ? 'Allow' : 'Deny'
      bypass: 'None'
    }
    blobServices: {
      containers: [
        { name: deploymentContainer }
      ]
    }
    roleAssignments: [
      {
        principalId: identity.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'Storage Blob Data Owner'
      }
    ]
  }
}

module network 'br/public:avm/res/network/virtual-network:0.6.1' = {
  name: 'function-network'
  params: {
    name: 'vnet-bing-guard-${suffix}'
    location: location
    tags: tags
    addressPrefixes: ['10.87.0.0/16']
    subnets: [
      {
        name: 'private-endpoints'
        addressPrefix: '10.87.1.0/24'
        privateEndpointNetworkPolicies: 'Disabled'
      }
      {
        name: 'functions'
        addressPrefix: '10.87.2.0/24'
        delegation: 'Microsoft.App/environments'
        privateEndpointNetworkPolicies: 'Disabled'
      }
    ]
  }
}

module blobDns 'br/public:avm/res/network/private-dns-zone:0.7.1' = {
  name: 'blob-private-dns'
  params: {
    name: 'privatelink.blob.${environment().suffixes.storage}'
    location: 'global'
    tags: tags
    virtualNetworkLinks: [
      {
        name: 'function-network-link'
        virtualNetworkResourceId: network.outputs.resourceId
        registrationEnabled: false
      }
    ]
  }
}

module blobEndpoint 'br/public:avm/res/network/private-endpoint:0.11.0' = {
  name: 'blob-private-endpoint'
  params: {
    name: 'pe-bing-guard-blob'
    location: location
    tags: tags
    subnetResourceId: '${network.outputs.resourceId}/subnets/private-endpoints'
    privateLinkServiceConnections: [
      {
        name: 'storage-blob'
        properties: {
          privateLinkServiceId: storage.outputs.resourceId
          groupIds: ['blob']
        }
      }
    ]
    privateDnsZoneGroup: {
      name: 'blob-zone-group'
      privateDnsZoneGroupConfigs: [
        {
          name: 'storage-blob'
          privateDnsZoneResourceId: blobDns.outputs.resourceId
        }
      ]
    }
  }
}

module plan 'br/public:avm/res/web/serverfarm:0.1.1' = {
  name: 'function-plan'
  params: {
    name: 'plan-bing-guard-${suffix}'
    location: location
    tags: tags
    reserved: true
    sku: {
      name: 'FC1'
      tier: 'FlexConsumption'
    }
  }
}

module workspace 'br/public:avm/res/operational-insights/workspace:0.11.1' = {
  name: 'log-workspace'
  params: {
    name: 'law-bing-guard-${suffix}'
    location: location
    tags: tags
    dataRetention: 30
  }
}

module insights 'br/public:avm/res/insights/component:0.6.0' = {
  name: 'application-insights'
  params: {
    name: 'appi-bing-guard-${suffix}'
    location: location
    tags: tags
    workspaceResourceId: workspace.outputs.resourceId
    disableLocalAuth: true
  }
}

resource insightResource 'Microsoft.Insights/components@2020-02-02' existing = {
  name: 'appi-bing-guard-${suffix}'
}

resource identityPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, 'function-monitoring')
  scope: insightResource
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
    principalId: identity.outputs.principalId
    principalType: 'ServicePrincipal'
  }
  dependsOn: [insights]
}

module function 'br/public:avm/res/web/site:0.15.1' = {
  name: 'function-app'
  params: {
    name: 'func-bing-guard-${suffix}'
    location: location
    tags: tags
    kind: 'functionapp,linux'
    serverFarmResourceId: plan.outputs.resourceId
    virtualNetworkSubnetId: '${network.outputs.resourceId}/subnets/functions'
    managedIdentities: {
      userAssignedResourceIds: [identity.outputs.resourceId]
    }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: 'https://${storage.outputs.name}.blob.${environment().suffixes.storage}/${deploymentContainer}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: identity.outputs.resourceId
          }
        }
      }
      runtime: {
        name: 'dotnet-isolated'
        version: '10.0'
      }
      scaleAndConcurrency: {
        instanceMemoryMB: 512
        maximumInstanceCount: 5
      }
    }
    siteConfig: {
      alwaysOn: false
    }
    appSettingsKeyValuePairs: {
      AzureWebJobsStorage__blobServiceUri: 'https://${storage.outputs.name}.blob.${environment().suffixes.storage}/'
      AzureWebJobsStorage__credential: 'managedidentity'
      AzureWebJobsStorage__clientId: identity.outputs.clientId
      APPLICATIONINSIGHTS_CONNECTION_STRING: insights.outputs.connectionString
      APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'ClientId=${identity.outputs.clientId};Authorization=AAD'
      MOCK_ALLOWED_DOMAIN: 'panasonic.jp'
      MOCK_EXCEPTION_DOMAIN: 'exceptions.example'
    }
  }
  dependsOn: [identityPublisher, blobEndpoint]
}

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: 'apim-bing-guard-${suffix}'
  location: location
  tags: tags
  sku: {
    name: 'Consumption'
    capacity: 0
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherName: 'Bing guard test'
    publisherEmail: notificationEmail
  }
}

resource apimPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, 'apim-monitoring')
  scope: insightResource
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
  }
  dependsOn: [insights]
}

output functionName string = function.outputs.name
output apimName string = apim.name
output insightsName string = insights.outputs.name
output workspaceName string = workspace.outputs.name
output storageAccountName string = storage.outputs.name
output gatewayUrl string = apim.properties.gatewayUrl
