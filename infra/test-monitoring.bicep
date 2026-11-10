targetScope = 'resourceGroup'

param apimServiceName string
param insightsName string
param location string = resourceGroup().location

@secure()
param notificationEmail string

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimServiceName
}
resource insights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: insightsName
}
resource guardedApi 'Microsoft.ApiManagement/service/apis@2024-05-01' existing = {
  parent: apim
  name: 'bing-domain-guard'
}
resource mockApi 'Microsoft.ApiManagement/service/apis@2024-05-01' existing = {
  parent: apim
  name: 'bing-mock'
}

resource logger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: apim
  name: 'bing-guard-insights'
  properties: {
    loggerType: 'applicationInsights'
    resourceId: insights.id
    isBuffered: true
    credentials: {
      connectionString: insights.properties.ConnectionString
      identityClientId: 'SystemAssigned'
    }
  }
}

resource diagnostic 'Microsoft.ApiManagement/service/apis/diagnostics@2024-05-01' = {
  parent: guardedApi
  name: 'applicationinsights'
  properties: {
    loggerId: logger.id
    verbosity: 'error'
    alwaysLog: 'allErrors'
    metrics: true
    logClientIp: false
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    frontend: {
      request: { headers: [], body: { bytes: 0 } }
      response: { headers: [], body: { bytes: 0 } }
    }
    backend: {
      request: { headers: [], body: { bytes: 0 } }
      response: { headers: [], body: { bytes: 0 } }
    }
  }
}

var productNames = ['A', 'B']
resource products 'Microsoft.ApiManagement/service/products@2024-05-01' = [for name in productNames: {
  parent: apim
  name: 'product-${toLower(name)}'
  properties: {
    displayName: 'Product ${name}'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
  }
}]
resource guardedMembership 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = [for (name, i) in productNames: {
  parent: products[i]
  name: guardedApi.name
}]
resource mockMembership 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = [for (name, i) in productNames: {
  parent: products[i]
  name: mockApi.name
}]
resource subscriptions 'Microsoft.ApiManagement/service/subscriptions@2024-05-01' = [for (name, i) in productNames: {
  parent: apim
  name: 'test-${toLower(name)}'
  properties: {
    displayName: 'Test ${name}'
    scope: products[i].id
    state: 'active'
    allowTracing: false
  }
}]

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-bing-guard-demo'
  location: 'global'
  properties: {
    groupShortName: 'BingGuard'
    enabled: true
    emailReceivers: [
      {
        name: 'test-recipient'
        emailAddress: notificationEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

resource alert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'bing-guard-triggered'
  location: location
  properties: {
    displayName: 'Bing guard triggered (test)'
    description: 'Synthetic search guard detection by instance and product.'
    enabled: true
    severity: 2
    scopes: [insights.id]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    autoMitigate: false
    muteActionsDuration: 'PT1H'
    criteria: {
      allOf: [
        {
          query: loadTextContent('../monitoring/guard-alert.kql')
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          dimensions: [
            { name: 'BingInstance', operator: 'Include', values: ['*'] }
            { name: 'ProductName', operator: 'Include', values: ['*'] }
          ]
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [actionGroup.id]
    }
  }
}

output alertId string = alert.id
