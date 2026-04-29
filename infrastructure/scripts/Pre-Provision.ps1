<#
.SYNOPSIS
    Pre-provision hook — warns if the target resource group already contains resources.

.DESCRIPTION
    Called automatically by 'azd provision' or 'azd up'. Because azd uses
    resourceGroup-scoped deployment, 'azd down' will DELETE THE ENTIRE RESOURCE
    GROUP. This script warns the user if the target RG already exists and contains
    resources, giving them a chance to abort before provisioning into a shared RG.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Ensure Ctrl+C terminates the script immediately
[Console]::TreatControlCAsInput = $false

Write-Host "`n=== Pre-provision: resource group check ===" -ForegroundColor Cyan

$rgName = $env:AZURE_RESOURCE_GROUP
$subId  = $env:AZURE_SUBSCRIPTION_ID

if (-not $rgName -or -not $subId) {
    Write-Host "  Resource group or subscription not yet set — skipping check." -ForegroundColor DarkGray
    exit 0
}

# Check if the RG exists
$rgExists = az group exists --name $rgName --subscription $subId 2>$null
if ($rgExists -ne 'true') {
    Write-Host "  Resource group '$rgName' does not exist yet — it will be created." -ForegroundColor DarkGray
    exit 0
}

# Count resources NOT tagged by azd (i.e. not part of this deployment)
$nonAzdCount = az resource list --resource-group $rgName --subscription $subId `
    --query "length([?tags.\"azd-env-name\" == null])" -o tsv 2>$null

if ([int]$nonAzdCount -gt 0) {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "  ║  WARNING: Resource group '$rgName' has $nonAzdCount resource(s) NOT    " -ForegroundColor Yellow
    Write-Host "  ║  managed by azd.                                                ║" -ForegroundColor Yellow
    Write-Host "  ║                                                                  ║" -ForegroundColor Yellow
    Write-Host "  ║  'azd down' will DELETE THE ENTIRE RESOURCE GROUP, including     ║" -ForegroundColor Yellow
    Write-Host "  ║  resources that were NOT created by azd.                         ║" -ForegroundColor Yellow
    Write-Host "  ║                                                                  ║" -ForegroundColor Yellow
    Write-Host "  ║  Consider using a dedicated resource group for this deployment.  ║" -ForegroundColor Yellow
    Write-Host "  ╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""

    try {
        $response = Read-Host "  Continue deploying into '$rgName'? (y/N)"
    } catch {
        Write-Host "`n  Aborted." -ForegroundColor Yellow
        exit 1
    }
    if ($response -notin @('y', 'Y', 'yes', 'Yes')) {
        Write-Host "  Aborted." -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-Host "  Resource group '$rgName' — no non-azd resources found." -ForegroundColor DarkGray
}

Write-Host ""
$targetSubs = $null
$targetSubsExists = $false
try {
    $targetSubs = azd env get-value AZURE_TARGET_SUBSCRIPTION_IDS 2>&1
    if ($LASTEXITCODE -eq 0) { $targetSubsExists = $true }
} catch { }

if (-not $targetSubsExists) {
    Write-Host "`n  Target subscription IDs scope the RBAC scripts — the Function App's" -ForegroundColor DarkGray
    Write-Host "  managed identity will be granted Reader / Monitoring Reader / Cognitive" -ForegroundColor DarkGray
    Write-Host "  Services Usages Reader on each one. At runtime the functions scan every" -ForegroundColor DarkGray
    Write-Host "  subscription the MI can see, so list every subscription you want monitored." -ForegroundColor DarkGray
    Write-Host "  Leave empty to grant access only to the deployment subscription.`n" -ForegroundColor DarkGray
    try {
        $value = Read-Host 'Comma-separated subscription IDs to monitor (empty to skip)'
    } catch {
        Write-Host "`n  Aborted." -ForegroundColor Yellow
        exit 1
    }
    if ($value) {
        azd env set AZURE_TARGET_SUBSCRIPTION_IDS $value
        Write-Host "  Set AZURE_TARGET_SUBSCRIPTION_IDS=$value" -ForegroundColor Green
    } else {
        Write-Host "  Skipped — RBAC will be granted on the deployment subscription only." -ForegroundColor DarkGray
    }
} else {
    Write-Host "  AZURE_TARGET_SUBSCRIPTION_IDS = $targetSubs" -ForegroundColor DarkGray
}

# ── Log Analytics workspace (optional — empty means "create a new one") ──────
Write-Host ""
$workspaceId = $null
$workspaceIdExists = $false
try {
    $workspaceId = azd env get-value AZURE_LOG_ANALYTICS_WORKSPACE_ID 2>&1
    if ($LASTEXITCODE -eq 0 -and $workspaceId) { $workspaceIdExists = $true }
} catch { }

if (-not $workspaceIdExists) {
    Write-Host "  Log Analytics workspace — paste the ARM resource ID of an existing" -ForegroundColor DarkGray
    Write-Host "  workspace, or leave empty to create a new one in the deployment RG." -ForegroundColor DarkGray
    try {
        $value = Read-Host 'Existing Log Analytics workspace resource ID (empty to create new)'
    } catch {
        Write-Host "`n  Aborted." -ForegroundColor Yellow
        exit 1
    }
    if ($value) {
        azd env set AZURE_LOG_ANALYTICS_WORKSPACE_ID $value
        Write-Host "  Set AZURE_LOG_ANALYTICS_WORKSPACE_ID" -ForegroundColor Green
    } else {
        Write-Host "  A new workspace will be created (name defaults to <prefix>-law)." -ForegroundColor DarkGray
    }
} else {
    Write-Host "  AZURE_LOG_ANALYTICS_WORKSPACE_ID is set." -ForegroundColor DarkGray
}

# ── Optional alerts (Action Group + Function-failure rule) ───────────────────
Write-Host ""
$deployAlerts = $null
$deployAlertsExists = $false
try {
    $deployAlerts = azd env get-value AZURE_DEPLOY_ALERTS 2>&1
    if ($LASTEXITCODE -eq 0 -and $deployAlerts) { $deployAlertsExists = $true }
} catch { }

if (-not $deployAlertsExists) {
    try {
        $response = Read-Host '  Deploy Action Group + Function-failure alert rule? (y/N)'
    } catch {
        Write-Host "`n  Aborted." -ForegroundColor Yellow
        exit 1
    }
    if ($response -in @('y', 'Y', 'yes', 'Yes')) {
        azd env set AZURE_DEPLOY_ALERTS true

        $alertEmail = $null
        try { $alertEmail = azd env get-value AZURE_ALERT_EMAIL 2>$null } catch { }
        if (-not $alertEmail) {
            try {
                $alertEmail = Read-Host '  Email recipient for alerts'
            } catch {
                Write-Host "`n  Aborted." -ForegroundColor Yellow
                exit 1
            }
            if (-not $alertEmail) {
                Write-Host "  Alerts enabled but no email supplied — Bicep deployment will fail." -ForegroundColor Yellow
            } else {
                azd env set AZURE_ALERT_EMAIL $alertEmail
                Write-Host "  Set AZURE_ALERT_EMAIL=$alertEmail" -ForegroundColor Green
            }
        }
    } else {
        azd env set AZURE_DEPLOY_ALERTS false
        Write-Host "  Alerts skipped." -ForegroundColor DarkGray
    }
} else {
    Write-Host "  AZURE_DEPLOY_ALERTS = $deployAlerts" -ForegroundColor DarkGray
}

