@description('Name of the optional Stream Analytics job. Deploy alongside the existing input and output resources.')
@minLength(3)
@maxLength(50)
param jobName string

param location string = resourceGroup().location

@minLength(6)
param inputNamespaceName string

@minLength(1)
param inputEventHubName string

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

@description('Existing output destination. Never use the input event hub as the output.')
@discriminator('type')
param destination storageDestination | eventHubDestination

@description('Stream Analytics SQL using input alias rawLogs and output alias export. Default preserves the payload.')
@minLength(1)
param query string = 'SELECT * INTO [export] FROM [rawLogs]'

resource inputNamespace 'Microsoft.EventHub/namespaces@2024-01-01' existing = {
  name: inputNamespaceName
}

resource inputHub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' existing = {
  parent: inputNamespace
  name: inputEventHubName
}

resource consumerGroup 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2024-01-01' = {
  parent: inputHub
  name: jobName
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = if (destination.type == 'storage') {
  name: destination.name
}

resource outputNamespace 'Microsoft.EventHub/namespaces@2024-01-01' existing = if (destination.type == 'eventHub') {
  name: destination.name
}

resource outputHub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' existing = if (destination.type == 'eventHub') {
  parent: outputNamespace
  name: destination.entityName
}

resource job 'Microsoft.StreamAnalytics/streamingjobs@2020-03-01' = {
  name: jobName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    jobType: 'Cloud'
    sku: {
      name: 'StandardV2'
    }
    compatibilityLevel: '1.2'
    eventsOutOfOrderPolicy: 'Adjust'
    outputErrorPolicy: 'Stop'
    inputs: [
      {
        name: 'rawLogs'
        properties: {
          type: 'Stream'
          datasource: {
            type: 'Microsoft.ServiceBus/EventHub'
            properties: {
              serviceBusNamespace: inputNamespaceName
              eventHubName: inputEventHubName
              consumerGroupName: consumerGroup.name
              authenticationMode: 'Msi'
            }
          }
          serialization: {
            type: 'Json'
            properties: {
              encoding: 'UTF8'
            }
          }
        }
      }
    ]
    outputs: [
      {
        name: 'export'
        properties: {
          datasource: destination.type == 'storage' ? {
            type: 'Microsoft.Storage/Blob'
            properties: {
              storageAccounts: [
                {
                  accountName: destination.name
                }
              ]
              container: destination.entityName
              pathPattern: 'logs/{date}/{time}'
              dateFormat: 'yyyy/MM/dd'
              timeFormat: 'HH'
              authenticationMode: 'Msi'
            }
          } : {
            type: 'Microsoft.ServiceBus/EventHub'
            properties: {
              serviceBusNamespace: destination.name
              eventHubName: destination.entityName
              authenticationMode: 'Msi'
            }
          }
          serialization: {
            type: 'Json'
            properties: {
              encoding: 'UTF8'
              format: 'LineSeparated'
            }
          }
        }
      }
    ]
    transformation: {
      name: 'filterAndTransform'
      properties: {
        streamingUnits: 3
        query: query
      }
    }
  }
}

resource reader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(inputHub.id, job.id, 'Azure Event Hubs Data Receiver')
  scope: inputHub
  properties: {
    principalId: job.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'a638d3c7-ab3a-418d-83e6-5f17a39d4fde')
  }
}

resource storageWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (destination.type == 'storage') {
  name: guid(storage.id, job.id, 'Storage Blob Data Contributor')
  scope: storage
  properties: {
    principalId: job.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  }
}

resource sender 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (destination.type == 'eventHub') {
  name: guid(outputHub.id, job.id, 'Azure Event Hubs Data Sender')
  scope: outputHub
  properties: {
    principalId: job.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2b629674-e913-4c01-ae53-ef4638d8f975')
  }
}

output jobId string = job.id
