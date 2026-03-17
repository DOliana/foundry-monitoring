<#
.SYNOPSIS
    Assigns the required RBAC roles for the AI Foundry monitoring Function App's
    managed identity across one or more Azure subscriptions and the Log Analytics / DCR resources.

.DESCRIPTION
    The monitoring functions need:
      - Monitoring Reader               on each target subscription (read Azure Monitor metrics)
      - Cognitive Services Usages Reader on each target subscription (read quota data)
      - Reader                          on each target subscription (enumerate accounts/deployments)
      - Log Analytics Data Reader       on the Log Analytics workspace (change detection queries)
      - Monitoring Metrics Publisher     on each DCR (write via Logs Ingestion API)

    Run this script after deploying the infrastructure (main.bicep) to grant the
    Function App's managed identity the necessary permissions.

.PARAMETER PrincipalId
    The Object ID of the Function App's system-assigned managed identity.
    Retrieve from: az functionapp identity show -n <name> -g <rg> --query principalId -o tsv

.PARAMETER TargetSubscriptionIds
    Array of subscription IDs the monitoring functions will scan.

.PARAMETER LogAnalyticsWorkspaceResourceId
    Full resource ID of the existing Log Analytics workspace.

.PARAMETER DcrResourceIds
    Array of full resource IDs of the Data Collection Rules (one per custom table).

.PARAMETER WhatIf
    Preview changes without applying them.

.EXAMPLE
    .\Assign-MonitoringRbac.ps1 `
        -PrincipalId "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" `
        -TargetSubscriptionIds @("sub-1111", "sub-2222") `
        -LogAnalyticsWorkspaceResourceId "/subscriptions/.../Microsoft.OperationalInsights/workspaces/my-ws" `
        -DcrResourceIds @("/subscriptions/.../Microsoft.Insights/dataCollectionRules/dcr-quota", "/subscriptions/.../Microsoft.Insights/dataCollectionRules/dcr-deploy", "/subscriptions/.../Microsoft.Insights/dataCollectionRules/dcr-token")
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$PrincipalId = $env:AZURE_FUNCTION_APP_PRINCIPAL_ID,

    [string[]]$TargetSubscriptionIds = @(
        if ($env:AZURE_TARGET_SUBSCRIPTION_IDS) {
            $env:AZURE_TARGET_SUBSCRIPTION_IDS -split ',' | Where-Object { $_ }
        } elseif ($env:AZURE_SUBSCRIPTION_ID) {
            $env:AZURE_SUBSCRIPTION_ID
        }
    ),

    [string]$LogAnalyticsWorkspaceResourceId = $env:AZURE_LOG_ANALYTICS_WORKSPACE_ID,

    [string[]]$DcrResourceIds = @(
        $env:AZURE_DCR_QUOTA_SNAPSHOT_ID,
        $env:AZURE_DCR_DEPLOYMENT_CONFIG_ID,
        $env:AZURE_DCR_TOKEN_USAGE_ID
    ).Where({ $_ })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Validate required parameters
if (-not $PrincipalId)                    { throw 'PrincipalId is required. Pass it as a parameter or set AZURE_FUNCTION_APP_PRINCIPAL_ID.' }
if (-not $TargetSubscriptionIds.Count)    { throw 'TargetSubscriptionIds is required. Pass it as a parameter, set AZURE_TARGET_SUBSCRIPTION_IDS, or ensure AZURE_SUBSCRIPTION_ID is set.' }
if (-not $LogAnalyticsWorkspaceResourceId){ throw 'LogAnalyticsWorkspaceResourceId is required. Pass it as a parameter or set AZURE_LOG_ANALYTICS_WORKSPACE_ID.' }
if (-not $DcrResourceIds.Count)           { throw 'DcrResourceIds is required. Pass them as a parameter or set AZURE_DCR_QUOTA_SNAPSHOT_ID, AZURE_DCR_DEPLOYMENT_CONFIG_ID, AZURE_DCR_TOKEN_USAGE_ID.' }

# Built-in role definition IDs
$roles = @{
    MonitoringReader              = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
    CognitiveServicesUsagesReader = 'bba48692-92b0-4667-a9ad-c31c7b334ac2'
    Reader                        = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
    LogAnalyticsDataReader        = '73c42c96-874c-492b-b04d-ab87d138a893'
    MonitoringMetricsPublisher    = '3913510d-42f4-4e42-8a64-420c390055eb'
}

function Grant-RoleIfMissing {
    param(
        [string]$Scope,
        [string]$RoleId,
        [string]$RoleName,
        [string]$Principal
    )

    $existing = az role assignment list `
        --assignee $Principal `
        --role $RoleId `
        --scope $Scope `
        --query "[].id" -o tsv 2>$null

    if ($existing) {
        Write-Host "  [SKIP] $RoleName already assigned at scope: $Scope"
        return
    }

    if ($PSCmdlet.ShouldProcess("$RoleName on $Scope", "Assign role")) {
        Write-Host "  [ASSIGN] $RoleName at scope: $Scope"
        az role assignment create `
            --assignee-object-id $Principal `
            --assignee-principal-type ServicePrincipal `
            --role $RoleId `
            --scope $Scope `
            --output none
    }
}

# 1. Per-subscription roles
foreach ($subId in $TargetSubscriptionIds) {
    $scope = "/subscriptions/$subId"
    Write-Host "`nSubscription: $subId"

    Grant-RoleIfMissing -Scope $scope -RoleId $roles.MonitoringReader              -RoleName 'Monitoring Reader'              -Principal $PrincipalId
    Grant-RoleIfMissing -Scope $scope -RoleId $roles.CognitiveServicesUsagesReader -RoleName 'Cognitive Services Usages Reader' -Principal $PrincipalId
    Grant-RoleIfMissing -Scope $scope -RoleId $roles.Reader                        -RoleName 'Reader'                          -Principal $PrincipalId
}

# 2. Log Analytics workspace
Write-Host "`nLog Analytics workspace"
Grant-RoleIfMissing -Scope $LogAnalyticsWorkspaceResourceId -RoleId $roles.LogAnalyticsDataReader -RoleName 'Log Analytics Data Reader' -Principal $PrincipalId

# 3. DCR — Monitoring Metrics Publisher (allows writing via Logs Ingestion API)
foreach ($dcrId in $DcrResourceIds) {
    Write-Host "`nDCR: $(Split-Path $dcrId -Leaf)"
    Grant-RoleIfMissing -Scope $dcrId -RoleId $roles.MonitoringMetricsPublisher -RoleName 'Monitoring Metrics Publisher' -Principal $PrincipalId
}

Write-Host "`nDone." -ForegroundColor Green
