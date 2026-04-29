<#
.SYNOPSIS
    Load-tests a single Azure AI Foundry model deployment with parallel requests.

.DESCRIPTION
    Interactive drill-down: subscription → Foundry instance → model deployment,
    then fires a configurable number of parallel requests against the selected
    deployment.  Authentication uses Entra ID (AAD) — no API keys required.

    Supported model types:
    - Chat completions (GPT, DeepSeek, Phi, Mistral, Llama, Cohere, o-series, etc.)
    - Embeddings (text-embedding models)

.PARAMETER SubscriptionId
    Optional.  Azure subscription ID.  If omitted, the script prompts.

.PARAMETER InstanceName
    Optional.  Name of the Azure AI Foundry (AIServices) account.
    If omitted, the script prompts.

.PARAMETER DeploymentName
    Optional.  Name of the model deployment to load-test.
    If omitted, the script prompts.

.PARAMETER Requests
    Total number of requests to send.  Default: 100.

.PARAMETER ThrottleLimit
    Maximum concurrent parallel requests.  Default: 20.

.PARAMETER Prompt
    Custom prompt text sent in every request.
    Default: "What is the capital of France? Answer in one sentence."

.PARAMETER Force
    Skip the confirmation prompt and start the load test immediately.

.PARAMETER WhatIf
    Preview mode — shows target deployment without sending requests.

.EXAMPLE
    .\Invoke-FoundryLoadTest.ps1

.EXAMPLE
    .\Invoke-FoundryLoadTest.ps1 -Requests 500 -ThrottleLimit 50

.EXAMPLE
    .\Invoke-FoundryLoadTest.ps1 -SubscriptionId "00000000-..." -InstanceName "my-ai" -DeploymentName "gpt-4o"

.EXAMPLE
    .\Invoke-FoundryLoadTest.ps1 -WhatIf

.NOTES
    Requires: PowerShell 7+ and Azure CLI (az) authenticated with sufficient permissions.
    The signed-in user must have "Cognitive Services OpenAI User" or
    "Cognitive Services OpenAI Contributor" on the target resource.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$InstanceName,

    [Parameter()]
    [Alias('Deployment')]
    [string]$DeploymentName,

    [Parameter()]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$Requests = 100,

    [Parameter()]
    [ValidateRange(1, 200)]
    [int]$ThrottleLimit = 20,

    [Parameter()]
    [string]$Prompt = "What is the capital of France? Answer in one sentence.",

    [Parameter()]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region Helper Functions

function Write-Step  { param([string]$Message) Write-Host "`n>>> $Message" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Write-Skip  { param([string]$Message) Write-Host "  [SKIP] $Message" -ForegroundColor Yellow }
function Write-Fail  { param([string]$Message) Write-Host "  [FAIL] $Message" -ForegroundColor Red }

function Test-AzCliAuthenticated {
    $account = az account show 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Azure CLI is not authenticated. Run 'az login' first."
        exit 1
    }
    return ($account | ConvertFrom-Json)
}

function Get-AadToken {
    $tokenJson = az account get-access-token --resource "https://cognitiveservices.azure.com" `
        --query "{accessToken:accessToken, expiresOn:expiresOn}" -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to acquire AAD token for Cognitive Services."
        exit 1
    }
    $parsed = $tokenJson | ConvertFrom-Json
    return [PSCustomObject]@{
        AccessToken = $parsed.accessToken
        ExpiresOn   = [DateTimeOffset]::Parse($parsed.expiresOn).UtcDateTime
    }
}

function Select-FromList {
    param(
        [string]$Title,
        [array]$Items,
        [scriptblock]$DisplayFormatter
    )

    Write-Host "`n$Title" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $display = & $DisplayFormatter $Items[$i]
        Write-Host "  [$($i + 1)] $display"
    }

    do {
        $choice = Read-Host "`nSelect (1-$($Items.Count))"
        $idx = 0
        $valid = [int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $Items.Count
        if (-not $valid) {
            Write-Host "  Invalid selection. Please enter a number between 1 and $($Items.Count)." -ForegroundColor Yellow
        }
    } while (-not $valid)

    return $Items[$idx - 1]
}

function Get-DeploymentType {
    param([string]$ModelName)
    if ($ModelName -match "embedding|ada") { return "embeddings" }
    if ($ModelName -match "dall-e|gpt-image|realtime|document-ai|whisper|tts|codex|gpt-5-pro") { return "unsupported" }
    return "chat"
}

#endregion

#region Main

Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host " Azure AI Foundry — Load Test (Entra ID auth)"        -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan

# 1. Verify authentication
Write-Step "Verifying Azure CLI authentication..."
$currentAccount = Test-AzCliAuthenticated
Write-Success "Authenticated as: $($currentAccount.user.name)"

# 2. Select subscription
if ($SubscriptionId) {
    Write-Step "Resolving subscription $SubscriptionId..."
    $subJson = az account show --subscription $SubscriptionId --query "{id:id, name:name}" -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Subscription '$SubscriptionId' not found or not accessible."
        exit 1
    }
    $selectedSub = $subJson | ConvertFrom-Json
}
else {
    Write-Step "Loading subscriptions..."
    $allSubs = az account list --query "[?state=='Enabled'].{id:id, name:name}" -o json 2>&1 | ConvertFrom-Json
    if (-not $allSubs -or @($allSubs).Count -eq 0) {
        Write-Error "No enabled subscriptions found."
        exit 1
    }
    $selectedSub = Select-FromList -Title "Select a subscription:" -Items @($allSubs) -DisplayFormatter {
        param($s) "$($s.name)  ($($s.id))"
    }
}
Write-Success "Subscription: $($selectedSub.name)"

# 3. Select / discover Foundry instance
if ($InstanceName) {
    # Direct lookup — skip broad resource scan
    Write-Step "Resolving Foundry instance '$InstanceName'..."
    $resJson = az resource list `
        --subscription $selectedSub.id `
        --resource-type "Microsoft.CognitiveServices/accounts" `
        --name $InstanceName `
        --query "[?kind=='AIServices'] | [0].{name:name, resourceGroup:resourceGroup, id:id}" `
        -o json 2>$null
    $acct = $null
    if ($resJson) { try { $acct = $resJson | ConvertFrom-Json } catch {} }
    if (-not $acct) {
        Write-Error "Foundry instance '$InstanceName' not found in subscription '$($selectedSub.name)'."
        exit 1
    }
    $endpoint = az cognitiveservices account show `
        --name $acct.name --resource-group $acct.resourceGroup --subscription $selectedSub.id `
        --query "properties.endpoint" -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $endpoint) { $endpoint = $endpoint.Trim() }
    $selectedAccount = [PSCustomObject]@{
        Name          = $acct.name
        ResourceGroup = $acct.resourceGroup
        Endpoint      = $endpoint
        Id            = $acct.id
    }
}
else {
    Write-Step "Discovering Azure AI Foundry instances in '$($selectedSub.name)'..."
    $resources = az resource list `
        --subscription $selectedSub.id `
        --resource-type "Microsoft.CognitiveServices/accounts" `
        --query "[?kind=='AIServices'].{name:name, resourceGroup:resourceGroup, id:id}" `
        -o json 2>$null

    $accounts = @()
    if ($resources) {
        try { $accounts = @($resources | ConvertFrom-Json) } catch { $accounts = @() }
    }
    if ($accounts.Count -eq 0) {
        Write-Host "`nNo Azure AI Foundry (AIServices) accounts found in this subscription." -ForegroundColor Yellow
        exit 0
    }

    # Enrich with endpoint
    $enriched = @()
    foreach ($a in $accounts) {
        $ep = az cognitiveservices account show `
            --name $a.name --resource-group $a.resourceGroup --subscription $selectedSub.id `
            --query "properties.endpoint" -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and $ep) { $ep = $ep.Trim() }
        $enriched += [PSCustomObject]@{
            Name          = $a.name
            ResourceGroup = $a.resourceGroup
            Endpoint      = $ep
            Id            = $a.id
        }
    }

    $selectedAccount = Select-FromList -Title "Select a Foundry instance:" -Items $enriched -DisplayFormatter {
        param($a) "$($a.Name)  (RG: $($a.ResourceGroup))"
    }
}
Write-Success "Instance: $($selectedAccount.Name)"

# 4. Select / discover deployment
if ($DeploymentName) {
    # Direct lookup — skip listing all deployments
    Write-Step "Resolving deployment '$DeploymentName'..."
    $depJson = az cognitiveservices account deployment show `
        --name $selectedAccount.Name `
        --resource-group $selectedAccount.ResourceGroup `
        --subscription $selectedSub.id `
        --deployment-name $DeploymentName `
        --query "{name:name, model:properties.model.name, format:properties.model.format, version:properties.model.version, status:properties.provisioningState}" `
        -o json 2>$null
    $dep = $null
    if ($depJson) { try { $dep = $depJson | ConvertFrom-Json } catch {} }
    if (-not $dep) {
        Write-Error "Deployment '$DeploymentName' not found on '$($selectedAccount.Name)'."
        exit 1
    }
    if ($dep.status -ne "Succeeded") {
        Write-Error "Deployment '$DeploymentName' is in '$($dep.status)' state (expected Succeeded)."
        exit 1
    }
    $selectedDeployment = $dep
}
else {
    Write-Step "Loading deployments for '$($selectedAccount.Name)'..."
    $deploymentsJson = az cognitiveservices account deployment list `
        --name $selectedAccount.Name `
        --resource-group $selectedAccount.ResourceGroup `
        --subscription $selectedSub.id `
        --query "[].{name:name, model:properties.model.name, format:properties.model.format, version:properties.model.version, status:properties.provisioningState}" `
        -o json 2>$null

    $deployments = @()
    if ($deploymentsJson) {
        try { $deployments = @($deploymentsJson | ConvertFrom-Json) } catch { $deployments = @() }
    }
    $deployments = @($deployments | Where-Object { $_.status -eq "Succeeded" })

    if ($deployments.Count -eq 0) {
        Write-Host "`nNo active deployments found on this Foundry instance." -ForegroundColor Yellow
        exit 0
    }

    $selectedDeployment = Select-FromList -Title "Select a model deployment:" -Items $deployments -DisplayFormatter {
        param($d) "$($d.name)  — $($d.model) v$($d.version) [$($d.format)]"
    }
}
Write-Success "Deployment: $($selectedDeployment.name) ($($selectedDeployment.model))"

# 5. Check model type
$modelType = Get-DeploymentType -ModelName $selectedDeployment.model
if ($modelType -eq "unsupported") {
    Write-Host "`nModel '$($selectedDeployment.model)' is not supported for load testing (image/audio/realtime)." -ForegroundColor Yellow
    exit 0
}

# 6. Confirm
Write-Host "`n-----------------------------------------------------" -ForegroundColor White
Write-Host "  Target:     $($selectedAccount.Name) / $($selectedDeployment.name)" -ForegroundColor White
Write-Host "  Model:      $($selectedDeployment.model) v$($selectedDeployment.version)" -ForegroundColor White
Write-Host "  Type:       $modelType" -ForegroundColor White
Write-Host "  Requests:   $Requests" -ForegroundColor White
Write-Host "  Parallel:   $ThrottleLimit concurrent" -ForegroundColor White
Write-Host "-----------------------------------------------------" -ForegroundColor White

if ($WhatIfPreference) {
    Write-Host "`n[PREVIEW] Would send $Requests $modelType requests. Exiting." -ForegroundColor Magenta
    exit 0
}

if (-not $Force) {
    $confirm = Read-Host "`nStart load test? (Y/N)"
    if ($confirm -notin @('Y', 'y', 'yes', 'Yes')) {
        Write-Host "Aborted." -ForegroundColor Yellow
        exit 0
    }
}

# 7. Acquire token
Write-Step "Acquiring Entra ID token..."
$tokenInfo = Get-AadToken
Write-Success "Token acquired (expires: $($tokenInfo.ExpiresOn) UTC)"

# 8. Fire requests in parallel
Write-Step "Sending $Requests $modelType requests (throttle=$ThrottleLimit)..."

$endpoint    = $selectedAccount.Endpoint
$depName     = $selectedDeployment.name
$aadToken    = $tokenInfo.AccessToken
$stopwatch   = [System.Diagnostics.Stopwatch]::StartNew()

$results = 1..$Requests | ForEach-Object -Parallel {
    $reqNum       = $_
    $token        = $using:aadToken
    $prompt       = $using:Prompt
    $endpointBase = $using:endpoint
    $deployment   = $using:depName
    $type         = $using:modelType

    $result = [PSCustomObject]@{
        RequestNum = $reqNum
        Status     = ''
        Tokens     = 0
        DurationMs = 0
        Error      = ''
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $baseUri = "$($endpointBase.TrimEnd('/'))/openai/v1"
        $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }

        if ($type -eq 'chat') {
            $body = @{
                model    = $deployment
                messages = @(@{ role = 'user'; content = $prompt })
            } | ConvertTo-Json -Depth 5
            $response = Invoke-RestMethod -Uri "$baseUri/chat/completions" -Method Post -Headers $headers -Body $body -ErrorAction Stop
        }
        else {
            $body = @{
                model = $deployment
                input = @($prompt)
            } | ConvertTo-Json -Depth 5
            $response = Invoke-RestMethod -Uri "$baseUri/embeddings" -Method Post -Headers $headers -Body $body -ErrorAction Stop
        }

        $sw.Stop()
        $result.Status     = 'success'
        $result.Tokens     = $response.usage.total_tokens
        $result.DurationMs = $sw.ElapsedMilliseconds
    }
    catch {
        $sw.Stop()
        $errMsg = $_.Exception.Message
        $errDetails = $_.ErrorDetails
        if ($null -ne $errDetails -and $null -ne $errDetails.Message) {
            try {
                $errDetail = $errDetails.Message | ConvertFrom-Json
                $errMsg = $errDetail.error.message
            } catch {
                $errMsg = $errDetails.Message
            }
        }
        $statusCode = ''
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        $result.Status     = if ($statusCode -eq 429) { 'throttled' } else { 'failed' }
        $result.DurationMs = $sw.ElapsedMilliseconds
        $result.Error      = $errMsg
    }

    return $result
} -ThrottleLimit $ThrottleLimit

$stopwatch.Stop()

# 9. Summarise results
$allResults   = @($results)
$succeeded    = @($allResults | Where-Object Status -eq 'success')
$throttled    = @($allResults | Where-Object Status -eq 'throttled')
$failed       = @($allResults | Where-Object Status -eq 'failed')

$totalTokens  = if ($succeeded.Count -gt 0) { ($succeeded | Measure-Object -Property Tokens -Sum).Sum } else { 0 }
$durations    = @($succeeded | ForEach-Object { $_.DurationMs } | Sort-Object)

$p50 = 0; $p95 = 0; $p99 = 0; $avgMs = 0
if ($durations.Count -gt 0) {
    $avgMs = [math]::Round(($durations | Measure-Object -Average).Average, 0)
    $p50 = $durations[[math]::Min([math]::Floor($durations.Count * 0.50), $durations.Count - 1)]
    $p95 = $durations[[math]::Min([math]::Floor($durations.Count * 0.95), $durations.Count - 1)]
    $p99 = $durations[[math]::Min([math]::Floor($durations.Count * 0.99), $durations.Count - 1)]
}

$elapsedSec = [math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
$rps = if ($elapsedSec -gt 0) { [math]::Round($succeeded.Count / $elapsedSec, 2) } else { 0 }

Write-Host "`n=====================================================" -ForegroundColor Cyan
Write-Host " Load Test Results"                                       -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "  Target:          $($selectedAccount.Name) / $depName ($($selectedDeployment.model))"
Write-Host "  Total requests:  $Requests"                            -ForegroundColor White
Write-Host "  Successful:      $($succeeded.Count)"                  -ForegroundColor Green
Write-Host "  Throttled (429): $($throttled.Count)"                  -ForegroundColor $(if ($throttled.Count -gt 0) { "Red" } else { "Gray" })
Write-Host "  Failed:          $($failed.Count)"                     -ForegroundColor $(if ($failed.Count -gt 0) { "Red" } else { "Gray" })
Write-Host "  Total tokens:    $totalTokens"                         -ForegroundColor White
Write-Host ""
Write-Host "  Wall-clock time: $($stopwatch.Elapsed.ToString('hh\:mm\:ss\.fff'))" -ForegroundColor White
Write-Host "  Throughput:      $rps successful req/s"                -ForegroundColor White
Write-Host ""
Write-Host "  Latency (successful requests):" -ForegroundColor White
Write-Host "    Avg:  ${avgMs} ms"
Write-Host "    P50:  ${p50} ms"
Write-Host "    P95:  ${p95} ms"
Write-Host "    P99:  ${p99} ms"

if ($throttled.Count -gt 0) {
    Write-Host "`n  Throttling detected — $($throttled.Count) of $Requests requests got HTTP 429." -ForegroundColor Yellow
    Write-Host "  Consider reducing -ThrottleLimit or the deployment's TPM may be too low." -ForegroundColor Yellow
}

if ($failed.Count -gt 0) {
    Write-Host "`n  Sample errors:" -ForegroundColor Red
    $failed | Select-Object -First 5 | ForEach-Object {
        Write-Host "    Request #$($_.RequestNum): $($_.Error)" -ForegroundColor Red
    }
}

# 10. Print repeat command
$repeatCmd = ".\Invoke-FoundryLoadTest.ps1" +
    " -SubscriptionId `"$($selectedSub.id)`"" +
    " -InstanceName `"$($selectedAccount.Name)`"" +
    " -DeploymentName `"$($selectedDeployment.name)`"" +
    " -Requests $Requests" +
    " -ThrottleLimit $ThrottleLimit" +
    " -Force"

Write-Host "`n-----------------------------------------------------" -ForegroundColor DarkGray
Write-Host "  Repeat this test:" -ForegroundColor DarkGray
Write-Host "  $repeatCmd" -ForegroundColor White
Write-Host "-----------------------------------------------------" -ForegroundColor DarkGray

#endregion
