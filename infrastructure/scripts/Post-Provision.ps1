<#
.SYNOPSIS
    Post-provision hook called automatically by 'azd provision'.
    Assigns RBAC for the Function App, sets up local dev environment.

.DESCRIPTION
    Runs 3 steps after Bicep deployment completes:
      1. Assign RBAC roles to the Function App's managed identity
      2. Assign RBAC roles to the local developer (for 'func host start')
      3. Generate src/local.settings.json from Bicep outputs
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot

# Allow opting out of the RBAC step — useful when the deploying user lacks
# User Access Administrator on the target subscriptions / workspace / DCRs and
# a separate admin will run Assign-MonitoringRbac.ps1 afterwards.
$assignRbac = $true
$assignRbacEnv = $null
try { $assignRbacEnv = azd env get-value AZURE_ASSIGN_RBAC 2>$null } catch { }
if ($assignRbacEnv -and $assignRbacEnv.ToLower() -in @('false', '0', 'no', 'off')) {
    $assignRbac = $false
}

if ($assignRbac) {
    Write-Host "`n=== Post-provision: Step 1/3 — Function App RBAC ===" -ForegroundColor Cyan
    & "$scriptDir/Assign-MonitoringRbac.ps1"
} else {
    Write-Host "`n=== Post-provision: Step 1/3 — Function App RBAC (SKIPPED) ===" -ForegroundColor Yellow
    Write-Host "  AZURE_ASSIGN_RBAC=$assignRbacEnv — skipping role assignments." -ForegroundColor DarkGray
    Write-Host "  An admin with 'User Access Administrator' must run later:" -ForegroundColor DarkGray
    Write-Host "    ./infrastructure/scripts/Assign-MonitoringRbac.ps1" -ForegroundColor DarkGray
    Write-Host "  See docs/RBAC_REQUIREMENTS.md for the full role list." -ForegroundColor DarkGray
}

if ($assignRbac) {
    Write-Host "`n=== Post-provision: Step 2/3 — Developer RBAC ===" -ForegroundColor Cyan
    $response = Read-Host "  Assign RBAC roles to your local identity for local development? (y/N)"
    if ($response -in @('y', 'Y', 'yes', 'Yes')) {
        & "$scriptDir/Assign-DevRbac.ps1"
    } else {
        Write-Host "  Skipped." -ForegroundColor DarkGray
    }
} else {
    Write-Host "`n=== Post-provision: Step 2/3 — Developer RBAC (SKIPPED) ===" -ForegroundColor Yellow
}

Write-Host "`n=== Post-provision: Step 3/3 — Generate local.settings.json ===" -ForegroundColor Cyan
& "$scriptDir/Create-LocalSettings.ps1"

Write-Host "`n=== Post-provision complete ===" -ForegroundColor Green
