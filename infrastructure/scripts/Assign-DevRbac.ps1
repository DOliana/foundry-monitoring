<#
.SYNOPSIS
    Assigns RBAC roles to the currently signed-in developer for local development
    against the monitoring infrastructure.

.DESCRIPTION
    Grants the same set of roles as Assign-MonitoringRbac.ps1 but to the developer's
    own identity (from 'az ad signed-in-user show') instead of the Function App's
    managed identity. Additionally assigns Storage Blob Data Owner, Storage Table
    Data Contributor, and Storage Queue Data Contributor on the storage account
    so local functions can use DefaultAzureCredential against Azure Storage.

    Reads configuration from azd environment variables when available, or accepts
    explicit parameters. Idempotent — skips roles that are already assigned.

.PARAMETER TargetSubscriptionIds
    Subscription IDs the monitoring functions scan. Falls back to
    AZURE_TARGET_SUBSCRIPTION_IDS env var, then AZURE_SUBSCRIPTION_ID (azd default).

.PARAMETER LogAnalyticsWorkspaceResourceId
    Full resource ID of the Log Analytics workspace. Falls back to AZURE_LOG_ANALYTICS_WORKSPACE_ID env var.

.PARAMETER StorageAccountName
    Name of the monitoring storage account. Falls back to AZURE_STORAGE_ACCOUNT_NAME env var.

.PARAMETER ResourceGroupName
    Resource group containing the storage account. Falls back to AZURE_RESOURCE_GROUP env var.

.EXAMPLE
    # After 'azd provision' — all env vars are automatically set:
    .\Assign-DevRbac.ps1

    # Explicit parameters:
    .\Assign-DevRbac.ps1 -TargetSubscriptionIds @("sub-1111") -LogAnalyticsWorkspaceResourceId "/subscriptions/..." -StorageAccountName "mystmon123"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
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
        $env:AZURE_DCR_TOKEN_USAGE_ID,
        $env:AZURE_DCR_MODEL_CATALOG_ID
    ).Where({ $_ }),

    [string]$StorageAccountName = $env:AZURE_STORAGE_ACCOUNT_NAME,

    [string]$ResourceGroupName = $env:AZURE_RESOURCE_GROUP
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Validate
if (-not $TargetSubscriptionIds.Count)     { throw 'TargetSubscriptionIds is required. Set AZURE_TARGET_SUBSCRIPTION_IDS, pass as parameter, or ensure AZURE_SUBSCRIPTION_ID is set.' }
if (-not $LogAnalyticsWorkspaceResourceId) { throw 'LogAnalyticsWorkspaceResourceId is required. Run azd provision first or pass as parameter.' }
if (-not $DcrResourceIds.Count)            { throw 'DcrResourceIds are required. Run azd provision first or pass as parameter.' }
if (-not $StorageAccountName)              { throw 'StorageAccountName is required. Run azd provision first or pass as parameter.' }
if (-not $ResourceGroupName)               { throw 'ResourceGroupName is required. Run azd provision first or pass as parameter.' }

# Get the signed-in user's object ID
$userObjectId = az ad signed-in-user show --query id -o tsv
if (-not $userObjectId) { throw 'Could not determine signed-in user. Run "az login" first.' }

$userName = az ad signed-in-user show --query userPrincipalName -o tsv
Write-Host "Assigning roles to: $userName ($userObjectId)" -ForegroundColor Cyan

$roles = @{
    MonitoringReader              = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
    CognitiveServicesUsagesReader = 'bba48692-92b0-4667-a9ad-c31c7b334ac2'
    Reader                        = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
    LogAnalyticsDataReader        = '73c42c96-874c-492b-b04d-ab87d138a893'
    MonitoringMetricsPublisher    = '3913510d-42f4-4e42-8a64-420c390055eb'
    StorageBlobDataOwner          = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
    StorageTableDataContributor   = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
    StorageQueueDataContributor   = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
}

function Grant-RoleIfMissing {
    param(
        [string]$Scope,
        [string]$RoleId,
        [string]$RoleName,
        [string]$Principal,
        [string]$PrincipalType = 'User',
        [string]$PrincipalDisplayName = ''
    )

    $who = if ($PrincipalDisplayName) { "$PrincipalDisplayName ($Principal)" } else { $Principal }

    $existing = az role assignment list `
        --assignee $Principal `
        --role $RoleId `
        --scope $Scope `
        --query "[].id" -o tsv 2>$null

    if ($existing) {
        Write-Host "  [SKIP]   $RoleName — already assigned to $who"
        return
    }

    if ($PSCmdlet.ShouldProcess("$RoleName on $Scope", "Assign role to $who")) {
        Write-Host "  [ASSIGN] $RoleName — to $who"
        az role assignment create `
            --assignee-object-id $Principal `
            --assignee-principal-type $PrincipalType `
            --role $RoleId `
            --scope $Scope `
            --output none
    }
}

# 1. Per-subscription roles (same as the Function App gets)
foreach ($subId in $TargetSubscriptionIds) {
    $scope = "/subscriptions/$subId"
    Write-Host "`nSubscription: $subId"

    Grant-RoleIfMissing -Scope $scope -RoleId $roles.MonitoringReader              -RoleName 'Monitoring Reader'              -Principal $userObjectId -PrincipalDisplayName $userName
    Grant-RoleIfMissing -Scope $scope -RoleId $roles.CognitiveServicesUsagesReader -RoleName 'Cognitive Services Usages Reader' -Principal $userObjectId -PrincipalDisplayName $userName
    Grant-RoleIfMissing -Scope $scope -RoleId $roles.Reader                        -RoleName 'Reader'                          -Principal $userObjectId -PrincipalDisplayName $userName
}

# 2. Log Analytics workspace
Write-Host "`nLog Analytics workspace"
Grant-RoleIfMissing -Scope $LogAnalyticsWorkspaceResourceId -RoleId $roles.LogAnalyticsDataReader -RoleName 'Log Analytics Data Reader' -Principal $userObjectId -PrincipalDisplayName $userName

# 3. DCRs — Monitoring Metrics Publisher
foreach ($dcrId in $DcrResourceIds) {
    Write-Host "`nDCR: $(Split-Path $dcrId -Leaf)"
    Grant-RoleIfMissing -Scope $dcrId -RoleId $roles.MonitoringMetricsPublisher -RoleName 'Monitoring Metrics Publisher' -Principal $userObjectId -PrincipalDisplayName $userName
}

# 4. Storage account — roles for local function execution
$storageScope = "/subscriptions/$($TargetSubscriptionIds[0])/resourceGroups/$ResourceGroupName/providers/Microsoft.Storage/storageAccounts/$StorageAccountName"
Write-Host "`nStorage account: $StorageAccountName"
Grant-RoleIfMissing -Scope $storageScope -RoleId $roles.StorageBlobDataOwner        -RoleName 'Storage Blob Data Owner'        -Principal $userObjectId -PrincipalDisplayName $userName
Grant-RoleIfMissing -Scope $storageScope -RoleId $roles.StorageTableDataContributor -RoleName 'Storage Table Data Contributor' -Principal $userObjectId -PrincipalDisplayName $userName
Grant-RoleIfMissing -Scope $storageScope -RoleId $roles.StorageQueueDataContributor -RoleName 'Storage Queue Data Contributor' -Principal $userObjectId -PrincipalDisplayName $userName

Write-Host "`nDone (principal: $userName). You can now run 'func host start' locally." -ForegroundColor Green
