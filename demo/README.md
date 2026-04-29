# Demo & sample assets

Everything in this folder is **illustrative**. None of it is required to deploy or run the production solution (the Azure Functions in `../src/` and the Bicep in `../infrastructure/`). Use these assets to explore the data, experiment with the push-based AzureMetrics path, or generate synthetic traffic for dashboards.

## `notebooks/`

| Notebook | Purpose |
|---|---|
| [`monitor-foundry.ipynb`](notebooks/monitor-foundry.ipynb) | Original POC that became the deployed Functions. Collects quota, deployment, and token usage interactively across subscriptions and renders Plotly charts. Useful for ad-hoc exploration. |
| [`monitor-foundry-example.ipynb`](notebooks/monitor-foundry-example.ipynb) | Queries `AzureMetrics` / `AzureDiagnostics` in a Log Analytics workspace. **Requires the diagnostic-settings script below to have been run first**, otherwise these tables stay empty. |

## `diagnostic-settings/`

[`Set-FoundryDiagnosticSettings.ps1`](diagnostic-settings/Set-FoundryDiagnosticSettings.ps1) — discovers Cognitive Services / Foundry resources and creates diagnostic settings forwarding platform metrics to a chosen Log Analytics workspace. The deployed Functions do **not** read `AzureMetrics` / `AzureDiagnostics`; this script exists only to enable the example notebook above.

```powershell
./Set-FoundryDiagnosticSettings.ps1 -WorkspaceResourceId "/subscriptions/.../workspaces/<name>"
./Set-FoundryDiagnosticSettings.ps1 -Remove   # tear down
```

## `load-tests/`

| Script | Purpose |
|---|---|
| [`Invoke-FoundryTrafficGenerator.ps1`](load-tests/Invoke-FoundryTrafficGenerator.ps1) | Sends representative chat / embedding requests so the deployed dashboards have something to display. |
| [`Invoke-FoundryLoadTest.ps1`](load-tests/Invoke-FoundryLoadTest.ps1) | Interactive load test designed to push a deployment past its rate limit (i.e. produce 429s) for testing alerts and quota tracking. |

Both scripts are **opt-in** and require credentials with permission to call the chosen deployments.
