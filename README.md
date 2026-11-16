# DCR-Platform-Logs-Filtering-Transformation-Multiple-Destination

Export Azure resource/platform logs without creating or ingesting into a Log Analytics
workspace. The templates use existing destinations and keyless managed identities.

## Architecture and service limits

```text
Supported Azure resource --DCR association--> PlatformTelemetry DCR
                                               |
                         +---------------------+---------------------+
                         |                                           |
                  Storage (raw JSON)                        Event Hub (raw JSON)
                                                                     |
                                                     optional Stream Analytics
                                                       SQL filter / projection
                                                                     |
                                                   Storage OR output Event Hub
                                                                     |
                                                   compatible Marketplace consumer
```

- [`infra/main.bicep`](infra/main.bicep) creates a platform-log DCR and grants its
  identity Storage Blob Data Contributor or Azure Event Hubs Data Sender on the
  selected destination. It does not create a workspace or change diagnostic settings.
- [`infra/processor.bicep`](infra/processor.bicep) optionally filters/transforms an
  Event Hub stream with Azure Stream Analytics SQL, then exports JSON to Storage or
  another Event Hub. This is a downstream processor, **not an in-DCR transformation**.
  Event Hubs and Stream Analytics incur their own charges.
  The example job uses Standard V2 at 1/3 SU (ARM `streamingUnits: 3`); size it for
  your throughput and monitor utilization before using it in production.
- Azure's platform-log DCR feature is **preview**, available only for supported
  resource types and regions. One destination type is supported per DCR; deploy
  separate rules and associations for simultaneous raw Storage and Event Hub export.
  A source can have at most five platform telemetry DCR associations.
- **During preview, DCR transformations are supported only for Log Analytics.**
  These templates deliberately do not put `transformKql` on direct Storage/Event Hub
  flows. Use the optional processor when workspace-free filtering/transformation is
  needed. It reduces downstream output, not the volume initially sent to Event Hubs.
- Marketplace is not a generic DCR destination type. Use an Event Hubs integration
  supported by your vendor (raw or processed output), with a separate consumer group
  and vendor-approved authentication. Vendor provisioning/configuration is not included.
  Solutions that require a Log Analytics workspace cannot use this workspace-free path.
- "Raw" means the platform-log JSON payload, not a byte-for-byte copy of the
  producer's original data. SQL projection intentionally changes that payload.

## Prerequisites

1. Azure CLI 2.61+, Bicep CLI, and an authenticated subscription (`az login`).
2. Register `Microsoft.Insights`; also register `Microsoft.StreamAnalytics` if using
   the processor. Destination resource providers must already be registered.
3. Existing supported monitored resources and a destination in the **same region**
   as the DCR. Choose a region/resource combination from the current preview documentation.
4. An existing blob container, or an existing Event Hubs namespace and event hub.
   All destinations and processor input/output resources must be in the deployment
   resource group/subscription for these templates. Sources can be in other resource
   groups; associate each explicitly.
5. Permission to deploy DCRs, associate them with sources, and create role assignments
   at destination scopes (for example Contributor plus Role Based Access Control
   Administrator). The processor also needs permission to create a consumer group.
6. Configure destination network access for the Azure services you use. RBAC alone
   does not bypass firewalls/private endpoints. Do not make containers public or
   introduce access keys to work around connectivity problems.

## Deploy a raw export

Run these Bash commands from the repository. Paths are resolved to the checkout's
absolute location. Replace the example names and source ID with your resources.

```bash
REPO="$(git rev-parse --show-toplevel)"
RG="telemetry-rg"
LOCATION="eastus" # Replace with a currently supported preview region.
SOURCE_ID="/subscriptions/<subscription-id>/resourceGroups/<source-rg>/providers/Microsoft.ContainerRegistry/registries/<registry-name>"

az deployment group create \
  --name raw-storage --resource-group "$RG" \
  --template-file "$REPO/infra/main.bicep" \
  --parameters ruleName=platform-logs-storage location="$LOCATION" \
    streams='["microsoft.containerregistry/registries:Logs-Group-All"]' \
    destination='{"type":"storage","name":"existingstorage","entityName":"platform-logs"}'

DCR_ID="$(az deployment group show --resource-group "$RG" --name raw-storage \
  --query properties.outputs.ruleId.value --output tsv)"

# Allow destination RBAC to propagate before associating the source.
az monitor data-collection rule association create \
  --name platform-logs-storage --resource "$SOURCE_ID" --rule-id "$DCR_ID"
```

For Event Hubs, deploy the same template with a distinct rule/deployment name:

```bash
az deployment group create \
  --name raw-eventhub --resource-group "$RG" \
  --template-file "$REPO/infra/main.bicep" \
  --parameters ruleName=platform-logs-eventhub location="$LOCATION" \
    streams='["microsoft.containerregistry/registries:Logs-Group-All"]' \
    destination='{"type":"eventHub","name":"existing-namespace","entityName":"raw-platform-logs"}'

EVENT_DCR_ID="$(az deployment group show --resource-group "$RG" --name raw-eventhub \
  --query properties.outputs.ruleId.value --output tsv)"
```

Associate `EVENT_DCR_ID` with the source as above, using a distinct association name.
For processing, complete the next section **before** associating this rule so that
the processor is listening before new logs arrive. Repeat associations for each
source resource. Use streams matching those source resource types; do not reuse the
registry stream for unrelated resources.

Avoid duplicate export charges: after verifying the new path, disable overlapping
diagnostic-settings log routes if they are no longer needed. Do not remove routes
needed by other consumers.

## Filter and transform without a workspace

Deploy the processor against the raw Event Hub from the preceding example. The
default query is `SELECT * INTO [export] FROM [rawLogs]`. To filter/project, supply
your own Stream Analytics SQL using those input/output aliases.

[`examples/filter-transform.sql`](examples/filter-transform.sql) selects only
`ContainerRegistryRepositoryEvents` and projects timestamp, resource, category,
operation and properties. It assumes one log record per JSON event, with the
lower-camel-case fields shown in that query. **Sample your actual input first**:
schemas vary by resource/category. An envelope containing a `records` array needs
flattening before applying record-level filtering, for example:

```sql
SELECT
    record.ArrayValue.time AS TimeGenerated,
    record.ArrayValue.resourceId AS ResourceId,
    record.ArrayValue.category AS Category,
    record.ArrayValue.operationName AS OperationName,
    record.ArrayValue.properties AS Properties
INTO [export]
FROM [rawLogs] AS batch
CROSS APPLY GetArrayElements(batch.records) AS record
WHERE record.ArrayValue.category = 'ContainerRegistryRepositoryEvents'
```

This is Stream Analytics SQL, not KQL. A filter referencing absent fields can discard
all records. Test your query with representative matching, nonmatching and missing-field
events in the Stream Analytics portal before starting production collection.

```bash
az deployment group create \
  --name processed-storage --resource-group "$RG" \
  --template-file "$REPO/infra/processor.bicep" \
  --parameters jobName=platform-log-filter location="$LOCATION" \
    inputNamespaceName=existing-namespace inputEventHubName=raw-platform-logs \
    destination='{"type":"storage","name":"existingstorage","entityName":"filtered-logs"}' \
    query="$(cat "$REPO/examples/filter-transform.sql")"

# Wait for the job identity's receiver/writer role assignments to propagate.
az stream-analytics job start --resource-group "$RG" \
  --name platform-log-filter --output-start-mode JobStartTime

az monitor data-collection rule association create \
  --name platform-logs-eventhub --resource "$SOURCE_ID" --rule-id "$EVENT_DCR_ID"
```

For processed Event Hub/Marketplace output, replace `destination` with:

```json
{"type":"eventHub","name":"existing-namespace","entityName":"processed-platform-logs"}
```

**Never use the input event hub as the output**: this creates a feedback loop.
The output hub/container must already exist. The template creates a dedicated input
consumer group named after the job. The job starts only when explicitly requested.
If input already exists, choose a custom output start time within Event Hubs retention
instead of `JobStartTime` to replay it.

For simultaneous processed Storage and Event Hub delivery, deploy two jobs with
distinct names, destinations and consumer groups. They independently read the same
raw stream; account for the additional processing cost. For raw fan-out, use separate
DCRs instead. The examples do not promise exactly-once delivery across destinations;
design consumers to handle duplicates, retries and retention limits.

## Validate and operate

No test framework exists in this repository. Compile both templates locally without
Azure credentials; place generated ARM files outside the checkout:

```bash
az bicep build --file "$REPO/infra/main.bicep" --outfile /tmp/platform-logs-main.json
az bicep build --file "$REPO/infra/processor.bicep" --outfile /tmp/platform-logs-processor.json
```

Before deploying, run `az deployment group validate` and
`az deployment group what-if` with the same template/parameters as `create`. Compilation
does not validate preview availability, SQL semantics, network access or live delivery.

After deployment:

1. Check the source's associations with
   `az monitor data-collection rule association list --resource "$SOURCE_ID"`.
   Inspect the DCR and destination role assignments. No Log Analytics destination
   should appear.
2. Generate a known source event. Allow up to 30 minutes for initial DCR delivery;
   subsequent latency is approximately three minutes. Inspect raw JSON using Storage
   Explorer or an Event Hubs test consumer with its own consumer group.
3. For a processor, use the Stream Analytics portal's input sample/query test tools.
   Verify that a matching event survives and is projected correctly, a nonmatching
   event is absent, and the pass-through query preserves the input payload fields.
4. Inspect the output container (`logs/yyyy/MM/dd/HH` for processed blobs) or output
   Event Hub. Confirm the Marketplace consumer receives the same expected events.
   Monitor input/output counts, runtime errors and Event Hubs retention/backlog.
   Processor output errors stop the job rather than silently dropping bad records.
5. For missing data, check supported streams/regions, RBAC propagation, destination
   network access, source log activity, query field names, and processor job state.
   These examples do not deploy diagnostic-log workspaces.

Stop collection by deleting the specific DCR association; stop a processor with
`az stream-analytics job stop --resource-group "$RG" --name platform-log-filter`.
Deleting a deployment record does **not** delete its resources. Remove unwanted
jobs, DCRs, consumer groups and role assignments explicitly, preserving shared
destinations and data. Remove role assignments before deleting their managed identities.

## References

- [Platform logs with DCRs: supported resources/regions, schema, RBAC and limitations](https://learn.microsoft.com/en-us/azure/azure-monitor/data-collection/platform-logs-collect)
- [Platform-log DCR preview announcement: transformation destination restriction](https://techcommunity.microsoft.com/blog/azureobservabilityblog/public-preview---azure-monitor---collect-azure-resource-platform-logs-at-scale-w/4525296)
- [Stream Analytics Event Hubs managed identity](https://learn.microsoft.com/en-us/azure/stream-analytics/event-hubs-managed-identity)
- [Stream Analytics Blob output managed identity](https://learn.microsoft.com/en-us/azure/stream-analytics/blob-output-managed-identity)