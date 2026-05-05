<#
.SYNOPSIS
    Deploys the AI Foundry monitoring infrastructure. RBAC for the Function App's
    managed identity is opt-in (off by default) so a separate admin can run it later.

.DESCRIPTION
    This script:
      1. Creates the resource group (if it doesn't exist)
      2. Deploys main.bicep with the provided parameters
      3. (Only when -AssignRbac is supplied) reads the deployment outputs
         (principal ID, DCR resource IDs) and calls Assign-MonitoringRbac.ps1
         to grant the managed identity the required roles across target subscriptions

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
    Optional. Array of subscription IDs to grant the Function App's managed identity
    access to. Only required when -AssignRbac is supplied.

.PARAMETER Prefix
    Mandatory. Naming prefix (lowercase, 2-8 chars).

.PARAMETER Environment
    Optional. Environment tag. Default: DEV

.PARAMETER MaxParallelSubs
    Optional. Concurrency limit. Default: 5

.PARAMETER AssignRbac
    Optional switch. When set, runs Assign-MonitoringRbac.ps1 to grant the Function App's
    managed identity Reader / Monitoring Reader / Cognitive Services Usages Reader on each
    target subscription, Log Analytics Data Reader on the workspace, and Monitoring Metrics
    Publisher on each DCR. Requires -TargetSubscriptionIds and User Access Administrator
    (or Owner) on each of those scopes. If omitted, hand off Assign-MonitoringRbac.ps1 to
    a separate admin after deployment.

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

    [string[]]$TargetSubscriptionIds = @(),

    [Parameter(Mandatory)]
    [ValidateLength(2, 8)]
    [string]$Prefix,

    [ValidateSet('DEV', 'TEST', 'PROD')]
    [string]$Environment = 'DEV',

    [int]$MaxParallelSubs = 5,

    [switch]$AssignRbac
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($DeployAlerts -and -not $AlertEmail) {
    throw '-AlertEmail is required when -DeployAlerts is set.'
}

if ($AssignRbac -and -not $TargetSubscriptionIds.Count) {
    throw '-TargetSubscriptionIds is required when -AssignRbac is set.'
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
    "workspaceRetentionDays=$WorkspaceRetentionDays"
    "workspaceSku=$WorkspaceSku"
)

if ($LogAnalyticsWorkspaceId) { $deployArgs += "logAnalyticsWorkspaceId=$LogAnalyticsWorkspaceId" }
if ($WorkspaceName)           { $deployArgs += "workspaceName=$WorkspaceName" }
if ($AlertEmail)              { $deployArgs += "alertEmail=$AlertEmail" }

$deployArgs += @('--output', 'json')

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

# ── Step 3: Assign RBAC (opt-in) ─────────────────────────────────────────────

if (-not $AssignRbac) {
    Write-Host "`n=== Step 3/3: RBAC assignment (SKIPPED) ===" -ForegroundColor Yellow
    Write-Host "  RBAC is opt-in for manual deploys. The Function App's managed identity will"
    Write-Host "  not be able to read target subscriptions or write to the DCRs until an admin runs"
    Write-Host "  Assign-MonitoringRbac.ps1. Re-run this script with -AssignRbac (and"
    Write-Host "  -TargetSubscriptionIds) to do it now."
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
