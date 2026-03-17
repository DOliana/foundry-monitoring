<#
.SYNOPSIS
    Deploys the AI Foundry monitoring infrastructure and assigns RBAC roles
    for the Function App's managed identity.

.DESCRIPTION
    This script:
      1. Creates the resource group (if it doesn't exist)
      2. Deploys main.bicep with the provided parameters
      3. Reads the deployment outputs (principal ID, DCR resource IDs)
      4. Calls Assign-MonitoringRbac.ps1 to grant the managed identity
         the required roles across target subscriptions

.PARAMETER ResourceGroupName
    Name of the resource group to create/use. Default: rg-ai-monitoring

.PARAMETER Location
    Azure region. Default: swedencentral

.PARAMETER LogAnalyticsWorkspaceId
    Mandatory. Full resource ID of the existing Log Analytics workspace.

.PARAMETER AlertEmail
    Mandatory. Email address for alert notifications.

.PARAMETER TargetSubscriptionIds
    Mandatory. Array of subscription IDs the monitoring functions will scan.

.PARAMETER Prefix
    Optional. Naming prefix. Default: heaip

.PARAMETER Environment
    Optional. Environment tag. Default: DEV

.PARAMETER MaxParallelSubs
    Optional. Concurrency limit. Default: 5

.PARAMETER SkipRbac
    Optional. Skip the RBAC assignment step (useful for re-deploys where RBAC is already set).

.PARAMETER WhatIf
    Preview changes without applying them.

.EXAMPLE
    .\Deploy-MonitoringInfra.ps1 `
        -LogAnalyticsWorkspaceId "/subscriptions/aaaa/resourceGroups/rg-shared/providers/Microsoft.OperationalInsights/workspaces/my-workspace" `
        -AlertEmail "platformteam@contoso.com" `
        -TargetSubscriptionIds @("sub-1111-aaaa", "sub-2222-bbbb", "sub-3333-cccc")
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ResourceGroupName = 'rg-ai-monitoring',

    [string]$Location = 'swedencentral',

    [Parameter(Mandatory)]
    [string]$LogAnalyticsWorkspaceId,

    [Parameter(Mandatory)]
    [string]$AlertEmail,

    [Parameter(Mandatory)]
    [string[]]$TargetSubscriptionIds,

    [string]$Prefix = 'heaip',

    [ValidateSet('DEV', 'TEST', 'PROD')]
    [string]$Environment = 'DEV',

    [int]$MaxParallelSubs = 5,

    [switch]$SkipRbac
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot

# ── Step 1: Create resource group ─────────────────────────────────────────────

Write-Host "`n=== Step 1/3: Resource group ===" -ForegroundColor Cyan

$rgExists = az group exists --name $ResourceGroupName -o tsv
if ($rgExists -eq 'true') {
    Write-Host "  Resource group '$ResourceGroupName' already exists."
} else {
    if ($PSCmdlet.ShouldProcess($ResourceGroupName, 'Create resource group')) {
        Write-Host "  Creating resource group '$ResourceGroupName' in '$Location'..."
        az group create --name $ResourceGroupName --location $Location --output none
    }
}

# ── Step 2: Deploy Bicep template ─────────────────────────────────────────────

Write-Host "`n=== Step 2/3: Bicep deployment ===" -ForegroundColor Cyan

$bicepFile = Join-Path $scriptDir '..' 'main.bicep'
$deploymentName = "monitoring-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

$deployArgs = @(
    'deployment', 'group', 'create'
    '--resource-group', $ResourceGroupName
    '--template-file', $bicepFile
    '--name', $deploymentName
    '--parameters'
    "location=$Location"
    "prefix=$Prefix"
    "environment=$Environment"
    "logAnalyticsWorkspaceId=$LogAnalyticsWorkspaceId"
    "alertEmail=$AlertEmail"
    "maxParallelSubs=$MaxParallelSubs"
    '--output', 'json'
)

if ($PSCmdlet.ShouldProcess($bicepFile, 'Deploy Bicep template')) {
    Write-Host "  Deploying main.bicep (deployment: $deploymentName)..."
    $deployOutput = az @deployArgs | ConvertFrom-Json

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Bicep deployment failed. Check the Azure portal for details."
        return
    }

    Write-Host "  Deployment succeeded." -ForegroundColor Green
} else {
    Write-Host "  [WhatIf] Would deploy main.bicep to resource group '$ResourceGroupName'"
    return
}

# ── Step 3: Assign RBAC ──────────────────────────────────────────────────────

if ($SkipRbac) {
    Write-Host "`n=== Step 3/3: RBAC assignment (SKIPPED) ===" -ForegroundColor Yellow
    Write-Host "  Use -SkipRbac:`$false or run Assign-MonitoringRbac.ps1 manually."
} else {
    Write-Host "`n=== Step 3/3: RBAC assignment ===" -ForegroundColor Cyan

    $principalId = $deployOutput.properties.outputs.functionAppPrincipalId.value
    $dcrQuota    = $deployOutput.properties.outputs.dcrQuotaSnapshotId.value
    $dcrDeploy   = $deployOutput.properties.outputs.dcrDeploymentConfigId.value
    $dcrToken    = $deployOutput.properties.outputs.dcrTokenUsageId.value

    Write-Host "  Function App principal ID: $principalId"
    Write-Host "  Target subscriptions: $($TargetSubscriptionIds -join ', ')"

    $rbacScript = Join-Path $scriptDir 'Assign-MonitoringRbac.ps1'

    $rbacArgs = @{
        PrincipalId                    = $principalId
        TargetSubscriptionIds          = $TargetSubscriptionIds
        LogAnalyticsWorkspaceResourceId = $LogAnalyticsWorkspaceId
        DcrResourceIds                 = @($dcrQuota, $dcrDeploy, $dcrToken)
    }

    & $rbacScript @rbacArgs
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host "`n=== Deployment complete ===" -ForegroundColor Green
Write-Host "  Resource group:    $ResourceGroupName"
Write-Host "  Function App:      $($deployOutput.properties.outputs.functionAppName.value)"
Write-Host "  Principal ID:      $($deployOutput.properties.outputs.functionAppPrincipalId.value)"
Write-Host ""
Write-Host "  Next step: deploy the Function App code (Python functions)."
