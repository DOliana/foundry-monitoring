<#
.SYNOPSIS
    Configures diagnostic settings for all Azure AI Foundry instances to send metrics
    to a central Log Analytics workspace.

.DESCRIPTION
    DEMO ASSET — NOT REQUIRED BY THE DEPLOYED SOLUTION.

    The deployed Functions in /src write to custom *_CL tables via the Logs Ingestion
    API. They do not consume the AzureMetrics or AzureDiagnostics tables produced by
    this script. Run this only when you want to explore the push-based path used by
    /demo/notebooks/monitor-foundry-example.ipynb.

    This script discovers all Azure AI Foundry-related resources across the current
    subscription (or all accessible subscriptions) and creates diagnostic settings
    to forward all platform metrics to a selected Log Analytics workspace.

    Foundry resource types discovered:
    - Microsoft.CognitiveServices/accounts (kind: AIServices)
    - Microsoft.MachineLearningServices/workspaces (kind: Hub, Project)

.PARAMETER SubscriptionId
    Optional. Target a specific subscription. If omitted, the script lets you choose
    from available subscriptions or scan all of them.

.PARAMETER WorkspaceResourceId
    Optional. Full ARM resource ID of the Log Analytics workspace. If omitted, the
    script lists available workspaces and prompts for selection.

.PARAMETER DiagnosticSettingName
    Name for the diagnostic setting. Defaults to "foundry-metrics-to-law".

.PARAMETER AllSubscriptions
    Switch. When set, scans all accessible subscriptions instead of prompting.

.PARAMETER Remove
    Switch. When set, removes the diagnostic settings previously created by this
    script (matched by DiagnosticSettingName) from all discovered Foundry resources.

.PARAMETER WhatIf
    Switch. Preview mode — shows what would be created/removed without making changes.

.EXAMPLE
    .\Set-FoundryDiagnosticSettings.ps1

.EXAMPLE
    .\Set-FoundryDiagnosticSettings.ps1 -AllSubscriptions

.EXAMPLE
    .\Set-FoundryDiagnosticSettings.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000" `
        -WorkspaceResourceId "/subscriptions/.../providers/Microsoft.OperationalInsights/workspaces/my-law"

.EXAMPLE
    # Remove all diagnostic settings created by this script
    .\Set-FoundryDiagnosticSettings.ps1 -Remove

.EXAMPLE
    # Remove with preview (no actual deletions)
    .\Set-FoundryDiagnosticSettings.ps1 -Remove -WhatIf

.NOTES
    Requires: Azure CLI (az) authenticated with sufficient permissions.
    Permissions needed:
    - Reader on subscriptions to discover resources
    - Microsoft.Insights/diagnosticSettings/write on target resources
    - Microsoft.OperationalInsights/workspaces/read on the Log Analytics workspace

    References:
    - https://learn.microsoft.com/en-us/cli/azure/monitor/diagnostic-settings
    - https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/diagnostic-settings
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$WorkspaceResourceId,

    [Parameter()]
    [string]$DiagnosticSettingName = "foundry-metrics-to-law",

    [Parameter()]
    [switch]$AllSubscriptions,

    [Parameter()]
    [switch]$Remove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region Helper Functions

function Write-Step {
    param([string]$Message)
    Write-Host "`n>>> $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-Skip {
    param([string]$Message)
    Write-Host "  [SKIP] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [FAIL] $Message" -ForegroundColor Red
}

function Test-AzCliAuthenticated {
    $account = az account show 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Azure CLI is not authenticated. Run 'az login' first."
        exit 1
    }
    return ($account | ConvertFrom-Json)
}

function Get-Subscriptions {
    param([string]$TargetSubscriptionId, [bool]$ScanAll)

    if ($TargetSubscriptionId) {
        $sub = az account show --subscription $TargetSubscriptionId --query "{id:id, name:name}" -o json 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Subscription '$TargetSubscriptionId' not found or not accessible."
            exit 1
        }
        return @(($sub | ConvertFrom-Json))
    }

    $allSubs = az account list --query "[?state=='Enabled'].{id:id, name:name}" -o json 2>&1 | ConvertFrom-Json

    if ($ScanAll) {
        return $allSubs
    }

    # Prompt user to select
    Write-Host "`nAvailable subscriptions:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $allSubs.Count; $i++) {
        Write-Host "  [$($i + 1)] $($allSubs[$i].name) ($($allSubs[$i].id))"
    }
    Write-Host "  [A] All subscriptions"

    do {
        $choice = Read-Host "`nSelect subscription (number or 'A' for all)"
        if ($choice -eq 'A' -or $choice -eq 'a') {
            return $allSubs
        }
        $idx = [int]$choice - 1
    } while ($idx -lt 0 -or $idx -ge $allSubs.Count)

    return @($allSubs[$idx])
}

function Select-LogAnalyticsWorkspace {
    param([string]$PreselectedId, [array]$Subscriptions)

    if ($PreselectedId) {
        # Validate it exists
        $wsName = az resource show --ids $PreselectedId --query "name" -o tsv 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Log Analytics workspace '$PreselectedId' not found."
            exit 1
        }
        Write-Host "Using Log Analytics workspace: $wsName" -ForegroundColor Green
        return $PreselectedId
    }

    Write-Step "Discovering Log Analytics workspaces..."

    $allWorkspaces = @()
    foreach ($sub in $Subscriptions) {
        $workspaces = az resource list `
            --subscription $sub.id `
            --resource-type "Microsoft.OperationalInsights/workspaces" `
            --query "[].{id:id, name:name, resourceGroup:resourceGroup, location:location}" `
            -o json 2>&1

        if ($LASTEXITCODE -eq 0 -and $workspaces -ne "[]") {
            $parsed = $workspaces | ConvertFrom-Json
            foreach ($ws in $parsed) {
                $allWorkspaces += [PSCustomObject]@{
                    Id            = $ws.id
                    Name          = $ws.name
                    ResourceGroup = $ws.resourceGroup
                    Location      = $ws.location
                    Subscription  = $sub.name
                }
            }
        }
    }

    if ($allWorkspaces.Count -eq 0) {
        Write-Error "No Log Analytics workspaces found in the selected subscriptions."
        exit 1
    }

    Write-Host "`nAvailable Log Analytics workspaces:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $allWorkspaces.Count; $i++) {
        $ws = $allWorkspaces[$i]
        Write-Host "  [$($i + 1)] $($ws.Name) | RG: $($ws.ResourceGroup) | Location: $($ws.Location) | Sub: $($ws.Subscription)"
    }

    do {
        $choice = Read-Host "`nSelect Log Analytics workspace (number)"
        $idx = [int]$choice - 1
    } while ($idx -lt 0 -or $idx -ge $allWorkspaces.Count)

    $selected = $allWorkspaces[$idx]
    Write-Host "Selected: $($selected.Name)" -ForegroundColor Green
    return $selected.Id
}

function Find-FoundryResources {
    param([array]$Subscriptions)

    Write-Step "Discovering Azure AI Foundry resources..."

    $foundryResources = @()

    foreach ($sub in $Subscriptions) {
        Write-Host "  Scanning subscription: $($sub.name)..." -ForegroundColor Gray

        # 1. AI Services accounts (kind=AIServices) — core Foundry service
        $cogAccounts = az resource list `
            --subscription $sub.id `
            --resource-type "Microsoft.CognitiveServices/accounts" `
            --query "[].{id:id, name:name, kind:kind, resourceGroup:resourceGroup, location:location}" `
            -o json 2>&1

        if ($LASTEXITCODE -eq 0 -and $cogAccounts -ne "[]") {
            $parsed = $cogAccounts | ConvertFrom-Json
            foreach ($res in $parsed) {
                if ($res.kind -eq "AIServices") {
                    $foundryResources += [PSCustomObject]@{
                        Id            = $res.id
                        Name          = $res.name
                        Type          = "Microsoft.CognitiveServices/accounts"
                        Kind          = $res.kind
                        ResourceGroup = $res.resourceGroup
                        Location      = $res.location
                        Subscription  = $sub.name
                    }
                }
            }
        }

        # 2. ML workspaces (kind=Hub or Project) — Foundry hub/project
        $mlWorkspaces = az resource list `
            --subscription $sub.id `
            --resource-type "Microsoft.MachineLearningServices/workspaces" `
            --query "[].{id:id, name:name, kind:kind, resourceGroup:resourceGroup, location:location}" `
            -o json 2>&1

        if ($LASTEXITCODE -eq 0 -and $mlWorkspaces -ne "[]") {
            $parsed = $mlWorkspaces | ConvertFrom-Json
            foreach ($res in $parsed) {
                if ($res.kind -in @("Hub", "Project")) {
                    $foundryResources += [PSCustomObject]@{
                        Id            = $res.id
                        Name          = $res.name
                        Type          = "Microsoft.MachineLearningServices/workspaces"
                        Kind          = $res.kind
                        ResourceGroup = $res.resourceGroup
                        Location      = $res.location
                        Subscription  = $sub.name
                    }
                }
            }
        }
    }

    return $foundryResources
}

function New-DiagnosticSetting {
    param(
        [string]$ResourceId,
        [string]$ResourceName,
        [string]$SettingName,
        [string]$WorkspaceId,
        [bool]$Preview
    )

    if ($Preview) {
        Write-Host "  [PREVIEW] Would create diagnostic setting '$SettingName' on $ResourceName" -ForegroundColor Magenta
        return "preview"
    }

    $metricsConfig = '[{"category":"AllMetrics","enabled":true}]'
    $logsConfig = '[{"category":"RequestResponse","enabled":true},{"category":"AzureOpenAIRequestUsage","enabled":true},{"category":"Audit","enabled":true}]'

    $result = az monitor diagnostic-settings create `
        --name $SettingName `
        --resource $ResourceId `
        --workspace $WorkspaceId `
        --metrics $metricsConfig `
        --logs $logsConfig `
        -o json 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-Success "$ResourceName — diagnostic setting applied"
        return "created"
    }
    else {
        Write-Fail "$ResourceName — $result"
        return "failed"
    }
}

function Remove-DiagnosticSetting {
    param(
        [string]$ResourceId,
        [string]$ResourceName,
        [string]$SettingName,
        [bool]$Preview
    )

    # Check if diagnostic setting exists
    $existing = az monitor diagnostic-settings list --resource $ResourceId --query "[?name=='$SettingName'].name" -o tsv 2>&1
    if ($LASTEXITCODE -ne 0 -or $existing -ne $SettingName) {
        Write-Skip "$ResourceName — diagnostic setting '$SettingName' not found"
        return "skipped"
    }

    if ($Preview) {
        Write-Host "  [PREVIEW] Would remove diagnostic setting '$SettingName' from $ResourceName" -ForegroundColor Magenta
        return "preview"
    }

    $result = az monitor diagnostic-settings delete `
        --name $SettingName `
        --resource $ResourceId `
        2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-Success "$ResourceName — diagnostic setting removed"
        return "removed"
    }
    else {
        Write-Fail "$ResourceName — $result"
        return "failed"
    }
}

#endregion

#region Main

$mode = if ($Remove) { "Removal" } else { "Setup" }
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Azure AI Foundry — Diagnostic Settings $mode" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

# Verify authentication
Write-Step "Verifying Azure CLI authentication..."
$currentAccount = Test-AzCliAuthenticated
Write-Success "Authenticated as: $($currentAccount.user.name)"

# Resolve subscriptions
$subscriptions = Get-Subscriptions -TargetSubscriptionId $SubscriptionId -ScanAll $AllSubscriptions.IsPresent
Write-Host "`nTarget subscriptions: $($subscriptions.Count)" -ForegroundColor Cyan

# Select Log Analytics workspace (only needed for create mode)
if (-not $Remove) {
    $selectedWorkspaceId = Select-LogAnalyticsWorkspace -PreselectedId $WorkspaceResourceId -Subscriptions $subscriptions
}

# Discover Foundry resources
$resources = Find-FoundryResources -Subscriptions $subscriptions

if ($resources.Count -eq 0) {
    Write-Host "`nNo Azure AI Foundry resources found." -ForegroundColor Yellow
    exit 0
}

Write-Host "`nFound $($resources.Count) Foundry resource(s):" -ForegroundColor Cyan
$resources | Format-Table Name, Kind, Type, ResourceGroup, Location, Subscription -AutoSize

# Confirm before proceeding
$action = if ($Remove) { "Remove" } else { "Create" }
if (-not $WhatIfPreference) {
    $confirm = Read-Host "`n$action diagnostic settings for all $($resources.Count) resources? (Y/N)"
    if ($confirm -notin @('Y', 'y', 'yes', 'Yes')) {
        Write-Host "Aborted." -ForegroundColor Yellow
        exit 0
    }
}

if ($Remove) {
    # Remove diagnostic settings
    Write-Step "Removing diagnostic settings..."

    $stats = @{ removed = 0; skipped = 0; failed = 0; preview = 0 }

    foreach ($res in $resources) {
        $result = Remove-DiagnosticSetting `
            -ResourceId $res.Id `
            -ResourceName "$($res.Name) ($($res.Kind))" `
            -SettingName $DiagnosticSettingName `
            -Preview $WhatIfPreference

        $stats[$result]++
    }

    # Summary
    Write-Host "`n=============================================" -ForegroundColor Cyan
    Write-Host " Summary (Removal)" -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host "  Total resources:  $($resources.Count)"
    Write-Host "  Removed:          $($stats.removed)" -ForegroundColor Green
    Write-Host "  Not found:        $($stats.skipped)" -ForegroundColor Yellow
    Write-Host "  Failed:           $($stats.failed)" -ForegroundColor $(if ($stats.failed -gt 0) { "Red" } else { "Gray" })
    if ($WhatIfPreference) {
        Write-Host "  Preview only:     $($stats.preview)" -ForegroundColor Magenta
    }
}
else {
    # Create diagnostic settings
    Write-Step "Configuring diagnostic settings..."

    $stats = @{ created = 0; failed = 0; preview = 0 }

    foreach ($res in $resources) {
        $result = New-DiagnosticSetting `
            -ResourceId $res.Id `
            -ResourceName "$($res.Name) ($($res.Kind))" `
            -SettingName $DiagnosticSettingName `
            -WorkspaceId $selectedWorkspaceId `
            -Preview $WhatIfPreference

        $stats[$result]++
    }

    # Summary
    Write-Host "`n=============================================" -ForegroundColor Cyan
    Write-Host " Summary (Create)" -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host "  Total resources:  $($resources.Count)"
    Write-Host "  Applied:          $($stats.created)" -ForegroundColor Green
    Write-Host "  Failed:           $($stats.failed)" -ForegroundColor $(if ($stats.failed -gt 0) { "Red" } else { "Gray" })
    if ($WhatIfPreference) {
        Write-Host "  Preview only:     $($stats.preview)" -ForegroundColor Magenta
    }
}

#endregion
