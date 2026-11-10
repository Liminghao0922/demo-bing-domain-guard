targetScope = 'subscription'

param location string = 'japaneast'
param resourceGroupName string = 'rg-bing-guard-demo-20261110'
param suffix string = '261110-844b'

@description('Explicitly approved testing-only exemption: tag this new RG SecurityControl=Ignore and enable identity-protected Storage public access.')
param enableTestStoragePublicAccess bool = false

@secure()
param notificationEmail string

resource group 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: union({
    workload: 'bing-domain-guard-demo'
    environment: 'test'
  }, enableTestStoragePublicAccess ? { SecurityControl: 'Ignore' } : {})
}

module environment 'test-environment.bicep' = {
  scope: group
  name: 'bing-guard-environment'
  params: {
    location: location
    suffix: suffix
    notificationEmail: notificationEmail
    enableTestStoragePublicAccess: enableTestStoragePublicAccess
  }
}

output functionName string = environment.outputs.functionName
output apimName string = environment.outputs.apimName
output insightsName string = environment.outputs.insightsName
output gatewayUrl string = environment.outputs.gatewayUrl
