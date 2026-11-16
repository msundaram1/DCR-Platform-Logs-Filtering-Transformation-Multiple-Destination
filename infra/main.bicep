@description('Name of the platform telemetry data collection rule.')
@minLength(1)
@maxLength(64)
param ruleName string

@description('Supported preview region shared by the source resources and destination.')
param location string = resourceGroup().location

@description('Supported platform-log streams, for example microsoft.containerregistry/registries:Logs-Group-All.')
@minLength(1)
param streams string[]

type storageDestination = {
  type: 'storage'
  @minLength(3)
  name: string
  @minLength(1)
  entityName: string
}

type eventHubDestination = {
  type: 'eventHub'
  @minLength(6)
  name: string
  @minLength(1)
  entityName: string
}

@description('Existing destination in this resource group: type, account/namespace name, and container/event hub entityName.')
@discriminator('type')
param destination storageDestination | eventHubDestination

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = if (destination.type == 'storage') {
  name: destination.name
}

resource eventHubNamespace 'Microsoft.EventHub/namespaces@2024-01-01' existing = if (destination.type == 'eventHub') {
  name: destination.name
}

resource eventHub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' existing = if (destination.type == 'eventHub') {
  parent: eventHubNamespace
  name: destination.entityName
}

resource rule 'Microsoft.Insights/dataCollectionRules@2024-03-11' = {
  name: ruleName
  location: location
  kind: 'PlatformTelemetry'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dataSources: {
      platformTelemetry: [
        {
          name: 'platformLogs'
          streams: streams
        }
      ]
    }
    destinations: destination.type == 'storage' ? {
      storageAccounts: [
        {
          name: 'export'
          storageAccountResourceId: storage.id
          containerName: destination.entityName
        }
      ]
    } : {
      eventHubs: [
        {
          name: 'export'
          eventHubResourceId: eventHub.id
        }
      ]
    }
    dataFlows: [
      {
        streams: streams
        destinations: [
          'export'
        ]
      }
    ]
  }
}

resource storageWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (destination.type == 'storage') {
  name: guid(storage.id, rule.id, 'Storage Blob Data Contributor')
  scope: storage
  properties: {
    principalId: rule.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  }
}

resource eventHubSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (destination.type == 'eventHub') {
  name: guid(eventHubNamespace.id, rule.id, 'Azure Event Hubs Data Sender')
  scope: eventHubNamespace
  properties: {
    principalId: rule.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2b629674-e913-4c01-ae53-ef4638d8f975')
  }
}

output ruleId string = rule.id
output principalId string = rule.identity.principalId
