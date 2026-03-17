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

Write-Host "`n=== Post-provision: Step 1/3 — Function App RBAC ===" -ForegroundColor Cyan
& "$scriptDir/Assign-MonitoringRbac.ps1"

Write-Host "`n=== Post-provision: Step 2/3 — Developer RBAC ===" -ForegroundColor Cyan
$response = Read-Host "  Assign RBAC roles to your local identity for local development? (y/N)"
if ($response -in @('y', 'Y', 'yes', 'Yes')) {
    & "$scriptDir/Assign-DevRbac.ps1"
} else {
    Write-Host "  Skipped." -ForegroundColor DarkGray
}

Write-Host "`n=== Post-provision: Step 3/3 — Generate local.settings.json ===" -ForegroundColor Cyan
& "$scriptDir/Create-LocalSettings.ps1"

Write-Host "`n=== Post-provision complete ===" -ForegroundColor Green
