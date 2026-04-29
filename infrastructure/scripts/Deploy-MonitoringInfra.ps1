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
    Optional. Full resource ID of an existing Log Analytics workspace. If omitted, a new
    workspace named '<prefix>-law' is created in the deployment resource group.

.PARAMETER DeployAlerts
    Optional switch. When set, deploys the Action Group and Function-failure alert rule.
    Requires -AlertEmail.

.PARAMETER AlertEmail
    Optional. Email address for alert notifications. Required when -DeployAlerts is supplied.

.PARAMETER TargetSubscriptionIds
    Mandatory. Array of subscription IDs the monitoring functions will scan.

.PARAMETER Prefix
    Mandatory. Naming prefix (lowercase, 2-8 chars).

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
        -Prefix "aimon" `
        -LogAnalyticsWorkspaceId "/subscriptions/aaaa/resourceGroups/rg-shared/providers/Microsoft.OperationalInsights/workspaces/my-workspace" `
        -DeployAlerts -AlertEmail "platformteam@contoso.com" `
        -TargetSubscriptionIds @("sub-1111-aaaa", "sub-2222-bbbb", "sub-3333-cccc")

.EXAMPLE
    # Create a new workspace in the deployment RG; no alerts
    .\Deploy-MonitoringInfra.ps1 -Prefix "aimon" -TargetSubscriptionIds @("sub-1111")
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ResourceGroupName = 'rg-ai-monitoring',

    [string]$Location = 'swedencentral',

    [string]$LogAnalyticsWorkspaceId = '',

    [string]$WorkspaceName = '',

    [ValidateRange(7, 730)]
    [int]$WorkspaceRetentionDays = 30,

    [ValidateSet('PerGB2018', 'CapacityReservation', 'Standalone', 'PerNode', 'Standard', 'Premium')]
    [string]$WorkspaceSku = 'PerGB2018',

    [switch]$DeployAlerts,

    [string]$AlertEmail = '',

    [Parameter(Mandatory)]
    [string[]]$TargetSubscriptionIds,

    [Parameter(Mandatory)]
    [ValidateLength(2, 8)]
    [string]$Prefix,

    [ValidateSet('DEV', 'TEST', 'PROD')]
    [string]$Environment = 'DEV',

    [int]$MaxParallelSubs = 5,

    [switch]$SkipRbac
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($DeployAlerts -and -not $AlertEmail) {
    throw '-AlertEmail is required when -DeployAlerts is set.'
}

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
    "maxParallelSubs=$MaxParallelSubs"
    "deployAlerts=$([string]([bool]$DeployAlerts).ToString().ToLower())"
    '--output', 'json'
)

if ($LogAnalyticsWorkspaceId) { $deployArgs += "logAnalyticsWorkspaceId=$LogAnalyticsWorkspaceId" }
if ($WorkspaceName)           { $deployArgs += "workspaceName=$WorkspaceName" }
$deployArgs += "workspaceRetentionDays=$WorkspaceRetentionDays"
$deployArgs += "workspaceSku=$WorkspaceSku"
if ($AlertEmail)              { $deployArgs += "alertEmail=$AlertEmail" }

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

    $principalId   = $deployOutput.properties.outputs.aZURE_FUNCTION_APP_PRINCIPAL_ID.value
    $effectiveWsId = $deployOutput.properties.outputs.aZURE_LOG_ANALYTICS_WORKSPACE_ID.value
    $dcrQuota      = $deployOutput.properties.outputs.aZURE_DCR_QUOTA_SNAPSHOT_ID.value
    $dcrDeploy     = $deployOutput.properties.outputs.aZURE_DCR_DEPLOYMENT_CONFIG_ID.value
    $dcrToken      = $deployOutput.properties.outputs.aZURE_DCR_TOKEN_USAGE_ID.value
    $dcrModel      = $deployOutput.properties.outputs.aZURE_DCR_MODEL_CATALOG_ID.value

    Write-Host "  Function App principal ID: $principalId"
    Write-Host "  Target subscriptions: $($TargetSubscriptionIds -join ', ')"

    $rbacScript = Join-Path $scriptDir 'Assign-MonitoringRbac.ps1'

    $rbacArgs = @{
        PrincipalId                     = $principalId
        TargetSubscriptionIds           = $TargetSubscriptionIds
        LogAnalyticsWorkspaceResourceId = $effectiveWsId
        DcrResourceIds                  = @($dcrQuota, $dcrDeploy, $dcrToken, $dcrModel)
    }

    & $rbacScript @rbacArgs
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host "`n=== Deployment complete ===" -ForegroundColor Green
Write-Host "  Resource group:    $ResourceGroupName"
Write-Host "  Function App:      $($deployOutput.properties.outputs.aZURE_FUNCTION_APP_NAME.value)"
Write-Host "  Principal ID:      $($deployOutput.properties.outputs.aZURE_FUNCTION_APP_PRINCIPAL_ID.value)"
Write-Host ""
Write-Host "  Next steps:"
Write-Host "    - Deploy code: azd deploy (or func azure functionapp publish)"
Write-Host "    - Local dev:   Run Assign-DevRbac.ps1 then func host start"
