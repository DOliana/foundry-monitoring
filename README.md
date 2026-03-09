# Azure AI Foundry Monitoring

Tools for monitoring Azure AI Foundry and Azure OpenAI resources across subscriptions.

## Known Limitations

- Log Analytics diagnostic settings (AllMetrics + AzureOpenAIRequestUsage) do not include per-model token breakdowns.
- Azure Monitor exposes tokens per model in the portal, but only per resource — data must be extracted via APIs for consolidated reporting.
- Token quotas are available via REST API, Azure CLI, or the portal.

## Files

### Documentation

| File | Description |
| --- | --- |
| `RBAC_REQUIREMENTS.md` | Maps minimum Azure RBAC roles and permissions required to run the monitoring code. Includes least-privilege scope guidance for Log Analytics queries, Azure Monitor metrics API, and ARM API calls. Documents required roles for each operation with official Microsoft Learn links. |


### Notebooks

| File | Description |
|------|-------------|
| `Full-Monitor.ipynb` | Collects quota, deployment, and token usage data across all subscriptions via Azure Monitor APIs. Visualizes subscription-level quotas, deployment rate limits, and hourly token usage with Plotly charts. |
| `moitor-foundry-example.ipynb` | Queries a Log Analytics workspace for AzureMetrics data from Foundry instances. Demonstrates how to retrieve metrics and diagnostics via the Log Analytics SDK. |

### PowerShell Scripts

| File | Description |
|------|-------------|
| `Set-FoundryDiagnosticSettings.ps1` | Discovers all Foundry resources and creates diagnostic settings to stream metrics to a Log Analytics workspace. Supports `-Remove` and `-WhatIf`. |
| `Invoke-FoundryTrafficGenerator.ps1` | Sends test requests to model deployments (chat completions, embeddings) across Foundry instances. Supports parallel execution, multiple iterations, and `-WhatIf`. |
