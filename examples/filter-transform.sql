SELECT
    logs.time AS TimeGenerated,
    logs.resourceId AS ResourceId,
    logs.category AS Category,
    logs.operationName AS OperationName,
    logs.properties AS Properties
INTO [export]
FROM [rawLogs] AS logs
WHERE logs.category = 'ContainerRegistryRepositoryEvents'
