using 'main.bicep'

// ── Mandatory — replace placeholder values before deploying ──────────────────
param logAnalyticsWorkspaceId = '<REPLACE: /subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.OperationalInsights/workspaces/{name}>'
param alertEmail = '<REPLACE: team@example.com>'

// ── Optional — uncomment and change to override defaults ─────────────────────
// param location = 'swedencentral'
// param prefix = 'heaip'
// param environment = 'DEV'
// param maxParallelSubs = 5
