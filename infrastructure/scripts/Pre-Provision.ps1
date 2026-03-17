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
    Write-Host "`n  Target subscription IDs are used by the RBAC scripts to assign" -ForegroundColor DarkGray
    Write-Host "  monitoring permissions across subscriptions. Leave empty to skip" -ForegroundColor DarkGray
    Write-Host "  (defaults to the deployment subscription).`n" -ForegroundColor DarkGray
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
        Write-Host "  Skipped — RBAC scripts will use the deployment subscription only." -ForegroundColor DarkGray
    }
} else {
    Write-Host "  AZURE_TARGET_SUBSCRIPTION_IDS = $targetSubs" -ForegroundColor DarkGray
}

