targetScope = 'resourceGroup'

@description('Existing APIM instance in the deployment resource group.')
param apimServiceName string

@description('Existing, published Function App in the same resource group.')
param functionAppName string

@description('Initial rollout mode; switch to enforce only after reviewing monitor results.')
@allowed([
  'off'
  'monitor'
  'enforce'
])
param guardMode string = 'monitor'

@description('Hostname substring match. Empty disables keywords for a strict domain-only configuration.')
param allowedKeywords string = 'panasonic,technics'

@description('DEMO exception domain only. Replace with approved values before production; empty is allowed.')
param allowedDomains string = 'exceptions.example'

param sorryTitle string = 'Search is temporarily unavailable'
param sorrySnippet string = 'We apologize for the inconvenience. Please try again later.'

@description('DEMO value. Set an approved public notice URL before production.')
param sorryUrl string = 'https://www.panasonic.com/'

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimServiceName
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' existing = {
  name: functionAppName
}

resource functionKey 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'bing-function-key'
  properties: {
    displayName: 'bing-function-key'
    secret: true
    value: listKeys('${functionApp.id}/host/default', '2024-04-01').functionKeys.default
  }
}

var settings = [
  { name: 'bing-guard-mode', value: guardMode }
  { name: 'bing-guard-allowed-keywords', value: empty(allowedKeywords) ? ' ' : allowedKeywords }
  { name: 'bing-guard-allowed-domains', value: empty(allowedDomains) ? ' ' : allowedDomains }
  { name: 'bing-guard-sorry-title', value: sorryTitle }
  { name: 'bing-guard-sorry-snippet', value: sorrySnippet }
  { name: 'bing-guard-sorry-url', value: sorryUrl }
]

resource guardSettings 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = [for setting in settings: {
  parent: apim
  name: setting.name
  properties: {
    displayName: setting.name
    secret: false
    value: setting.value
  }
}]

resource inboundFragment 'Microsoft.ApiManagement/service/policyFragments@2024-05-01' = {
  parent: apim
  name: 'bing-guard-inbound'
  properties: {
    description: 'Capture guard mode and remove request compression negotiation.'
    format: 'rawxml'
    value: loadTextContent('../apim/fragments/bing-guard-inbound.xml')
  }
  dependsOn: [guardSettings]
}

resource outboundFragment 'Microsoft.ApiManagement/service/policyFragments@2024-05-01' = {
  parent: apim
  name: 'bing-guard-outbound'
  properties: {
    description: 'PDF guard: monitor/enforce, one-result fallback, trace and metric.'
    format: 'rawxml'
    value: loadTextContent('../apim/fragments/bing-guard-outbound.xml')
  }
  dependsOn: [guardSettings]
}

resource backend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'bing-mock-function'
  properties: {
    title: 'Mock Bing Function'
    protocol: 'http'
    url: 'https://${functionApp.properties.defaultHostName}/api'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
}

resource api 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'bing-domain-guard'
  properties: {
    displayName: 'Bing test with PDF domain guard'
    apiRevision: '1'
    path: 'bing-test'
    protocols: [
      'https'
    ]
    serviceUrl: backend.properties.url
    subscriptionRequired: true
  }
}

resource search 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'search'
  properties: {
    displayName: 'Search'
    method: 'GET'
    urlTemplate: '/search'
    responses: [
      {
        statusCode: 200
        description: 'Original response, monitor detection, or one-result outage message.'
      }
      {
        statusCode: 500
        description: 'Original backend error or gateway configuration error.'
      }
    ]
  }
}

resource policy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../apim/policy.xml')
  }
  dependsOn: [
    functionKey
    inboundFragment
    outboundFragment
    search
  ]
}

resource mockApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'bing-mock'
  properties: {
    displayName: 'Bing mock without guard (test only)'
    apiRevision: '1'
    path: 'bing-mock'
    protocols: ['https']
    serviceUrl: backend.properties.url
    subscriptionRequired: true
  }
}

resource mockSearch 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: mockApi
  name: 'search'
  properties: {
    displayName: 'Search'
    method: 'GET'
    urlTemplate: '/search'
  }
}

resource mockPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: mockApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../apim/mock-policy.xml')
  }
  dependsOn: [
    functionKey
    mockSearch
  ]
}

output searchUrl string = '${apim.properties.gatewayUrl}/bing-test/search'
output mockUrl string = '${apim.properties.gatewayUrl}/bing-mock/search'
