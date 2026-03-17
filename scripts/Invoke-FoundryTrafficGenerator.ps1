<#
.SYNOPSIS
    Generates test traffic against model deployments on Azure AI Foundry instances.

.DESCRIPTION
    This script discovers Azure AI Foundry (CognitiveServices/AIServices) resources,
    lists their model deployments, and sends test requests to each deployment to
    generate traffic. Uses the v1 API (no api-version needed). Authentication uses
    Microsoft Entra ID (AAD) via az account get-access-token — no API keys required.

    Supported model types:
    - Chat completions (GPT, DeepSeek, Phi, Mistral, Llama, Cohere, o-series, etc.)
    - Embeddings (text-embedding models)

    Models that don't match these types (e.g., DALL-E, Whisper, TTS) are reported
    but skipped.

.PARAMETER SubscriptionId
    Optional. Target a specific subscription. If omitted, the script prompts.

.PARAMETER AllSubscriptions
    Switch. Scan all accessible subscriptions.

.PARAMETER Prompt
    Custom prompt text. Default: "What is the capital of France? Answer in one sentence."

.PARAMETER Iterations
    Number of times to repeat the full pass over all deployments. Default: 1.

.PARAMETER Sequential
    Switch. Send requests sequentially instead of in parallel.
    By default, requests are sent in parallel using ForEach-Object -Parallel (PowerShell 7+).

.PARAMETER Delay
    Number of seconds to wait between each iteration. Default: 0 (no delay).

.PARAMETER ThrottleLimit
    Maximum number of concurrent parallel requests. Default: 10. Only used in parallel mode.

.PARAMETER FirstOnly
    Debug mode — uses only the first subscription and first Foundry instance
    that has model deployments. Useful for quick testing.

.PARAMETER WhatIf
    Preview mode — lists deployments without sending requests.

.EXAMPLE
    .\Invoke-FoundryTrafficGenerator.ps1

.EXAMPLE
    .\Invoke-FoundryTrafficGenerator.ps1 -AllSubscriptions

.EXAMPLE
    .\Invoke-FoundryTrafficGenerator.ps1 -Prompt "Explain quantum computing briefly." -WhatIf

.NOTES
    Requires: Azure CLI (az) authenticated with sufficient permissions.
    The signed-in user must have the "Cognitive Services OpenAI User" or
    "Cognitive Services OpenAI Contributor" role on the target resources.

    References:
    - https://learn.microsoft.com/en-us/azure/foundry/openai/api-version-lifecycle
    - https://learn.microsoft.com/en-us/azure/foundry/openai/reference
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [switch]$AllSubscriptions,

    [Parameter()]
    [string]$Prompt = "What is the capital of France? Answer in one sentence.",

    [Parameter()]
    [int]$Iterations = 1,

    [Parameter()]
    [int]$Delay = 0,

    [Parameter()]
    [switch]$Sequential,

    [Parameter()]
    [int]$ThrottleLimit = 10,

    [Parameter()]
    [switch]$FirstOnly
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
    param([string]$TargetSubscriptionId, [bool]$ScanAll, [bool]$FirstOnly)

    if ($TargetSubscriptionId) {
        Write-Debug "Resolving specific subscription: $TargetSubscriptionId"
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

    Write-Host "`nAvailable subscriptions:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $allSubs.Count; $i++) {
        Write-Host "  [$($i + 1)] $($allSubs[$i].name) ($($allSubs[$i].id))"
    }
    Write-Host "  [A] All subscriptions"

    if ($FirstOnly) {
        Write-Host "`nFirstOnly: using first subscription '$($allSubs[0].name)'" -ForegroundColor Yellow
        $idx = 0
    }
    else {        
        do {
            $choice = Read-Host "`nSelect subscription (number or Enter for all)"
            if ($choice -eq '' -or $choice -eq 'A' -or $choice -eq 'a') {
                return $allSubs
            }
            $idx = [int]$choice - 1
        } while ($idx -lt 0 -or $idx -ge $allSubs.Count)
    }
    
    return @($allSubs[$idx])
}

function Get-AadToken {
    Write-Debug "Requesting AAD token for resource: https://cognitiveservices.azure.com"
    $tokenJson = az account get-access-token --resource "https://cognitiveservices.azure.com" --query "{accessToken:accessToken, expiresOn:expiresOn}" -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to acquire AAD token for Cognitive Services."
        exit 1
    }
    $parsed = $tokenJson | ConvertFrom-Json
    $token = $parsed.accessToken
    $expiresOn = [DateTimeOffset]::Parse($parsed.expiresOn).UtcDateTime
    Write-Debug "Token acquired (length: $($token.Length) chars, expires: $expiresOn UTC)"
    return [PSCustomObject]@{
        AccessToken = $token
        ExpiresOn   = $expiresOn
    }
}

function Get-ValidToken {
    param(
        [PSCustomObject]$TokenInfo,
        [int]$RenewalMarginSeconds = 300
    )
    $now = [DateTime]::UtcNow
    $remaining = ($TokenInfo.ExpiresOn - $now).TotalSeconds
    if ($remaining -le $RenewalMarginSeconds) {
        Write-Host "  Token expires in $([math]::Round($remaining))s — renewing..." -ForegroundColor Yellow
        $TokenInfo = Get-AadToken
        Write-Success "Token renewed (expires: $($TokenInfo.ExpiresOn) UTC)"
    }
    return $TokenInfo
}

function Find-FoundryAIServicesAccounts {
    param([array]$Subscriptions)

    Write-Step "Discovering Azure AI Foundry (AIServices) accounts..."

    $accounts = @()

    foreach ($sub in $Subscriptions) {
        Write-Host "  Scanning subscription: $($sub.name)..." -ForegroundColor Gray

        # Use 'az resource list' instead of 'az cognitiveservices account list'
        # to avoid a deserialization bug in certain Azure CLI versions on Linux.
        $resources = az resource list `
            --subscription $sub.id `
            --resource-type "Microsoft.CognitiveServices/accounts" `
            --query "[?kind=='AIServices'].{name:name, resourceGroup:resourceGroup, id:id}" `
            -o json 2>$null

        $parsed = $null
        if ($resources) {
            try { $parsed = $resources | ConvertFrom-Json } catch { $parsed = $null }
        }

        if ($parsed -and @($parsed).Count -gt 0) {
            foreach ($acct in $parsed) {
                # Retrieve the endpoint via account show (reliable across CLI versions)
                $endpoint = $null
                $endpointJson = az cognitiveservices account show `
                    --name $acct.name `
                    --resource-group $acct.resourceGroup `
                    --subscription $sub.id `
                    --query "properties.endpoint" -o tsv 2>$null
                if ($LASTEXITCODE -eq 0 -and $endpointJson) {
                    $endpoint = $endpointJson.Trim()
                }

                Write-Debug "Found AIServices account: $($acct.name) | Endpoint: $endpoint | RG: $($acct.resourceGroup)"
                $accounts += [PSCustomObject]@{
                    Name           = $acct.name
                    ResourceGroup  = $acct.resourceGroup
                    Endpoint       = $endpoint
                    Id             = $acct.id
                    SubscriptionId = $sub.id
                    Subscription   = $sub.name
                }
            }
        }
        else {
            Write-Debug "No AIServices accounts found in subscription $($sub.name) (exitCode=$LASTEXITCODE)"
        }
    }

    return $accounts
}

function Get-ModelDeployments {
    param(
        [string]$AccountName,
        [string]$ResourceGroup,
        [string]$SubscriptionId
    )

    Write-Debug "Listing deployments for account: $AccountName (RG: $ResourceGroup, Sub: $SubscriptionId)"
    $deployments = az cognitiveservices account deployment list `
        --name $AccountName `
        --resource-group $ResourceGroup `
        --subscription $SubscriptionId `
        --query "[].{name:name, model:properties.model.name, format:properties.model.format, version:properties.model.version, status:properties.provisioningState}" `
        -o json 2>$null

    $result = $null
    if ($deployments) {
        try { $result = @($deployments | ConvertFrom-Json) } catch { $result = $null }
    }

    if (-not $result -or $result.Count -eq 0) {
        Write-Debug "No deployments found for $AccountName"
        return @()
    }
    Write-Debug "Found $($result.Count) deployment(s) for $AccountName"
    foreach ($d in $result) {
        Write-Debug "  Deployment: $($d.name) | Model: $($d.model) | Format: $($d.format) | Version: $($d.version) | Status: $($d.status)"
    }
    return $result
}

function Get-DeploymentType {
    param([string]$ModelName)

    # Embedding models
    if ($ModelName -match "embedding|ada") {
        return "embeddings"
    }

    # Image generation models
    if ($ModelName -match "dall-e|gpt-image") {
        return "unsupported"
    }

    # Realtime / streaming-only models
    if ($ModelName -match "realtime") {
        return "unsupported"
    }

    # Document AI models
    if ($ModelName -match "document-ai") {
        return "unsupported"
    }

    # Speech/audio models
    if ($ModelName -match "whisper|tts") {
        return "unsupported"
    }

    # Responses API-only models (no chat completions support)
    if ($ModelName -match "codex|gpt-5-pro") {
        return "unsupported"
    }

    # Default: treat as chat completion (covers GPT, o-series, DeepSeek, Phi, Mistral, Llama, Cohere, Grok, etc.)
    return "chat"
}

function Invoke-ChatCompletion {
    param(
        [string]$Endpoint,
        [string]$DeploymentName,
        [string]$Token,
        [string]$PromptText
    )

    $uri = "$($Endpoint.TrimEnd('/'))/openai/v1/chat/completions"
    Write-Debug "Chat completion URI: $uri"

    $body = @{
        model    = $DeploymentName
        messages = @(
            @{ role = "user"; content = $PromptText }
        )
    } | ConvertTo-Json -Depth 5
    Write-Debug "Request body: $body"

    $response = Invoke-RestMethod -Uri $uri -Method Post `
        -Headers @{ Authorization = "Bearer $Token"; "Content-Type" = "application/json" } `
        -Body $body -ErrorAction Stop

    Write-Debug "Response: $($response | ConvertTo-Json -Depth 5 -Compress)"
    return $response
}

function Invoke-EmbeddingRequest {
    param(
        [string]$Endpoint,
        [string]$DeploymentName,
        [string]$Token,
        [string]$InputText
    )

    $uri = "$($Endpoint.TrimEnd('/'))/openai/v1/embeddings"
    Write-Debug "Embedding URI: $uri"

    $body = @{
        model = $DeploymentName
        input = @($InputText)
    } | ConvertTo-Json -Depth 5
    Write-Debug "Request body: $body"

    $response = Invoke-RestMethod -Uri $uri -Method Post `
        -Headers @{ Authorization = "Bearer $Token"; "Content-Type" = "application/json" } `
        -Body $body -ErrorAction Stop

    Write-Debug "Response: $($response | ConvertTo-Json -Depth 5 -Compress)"
    return $response
}

function Invoke-DeploymentRequest {
    param(
        [string]$Endpoint,
        [string]$DeploymentName,
        [string]$ModelName,
        [string]$Token,
        [string]$PromptText,
        [bool]$Preview
    )

    $type = Get-DeploymentType -ModelName $ModelName
    Write-Debug "Deployment '$DeploymentName' model '$ModelName' resolved to type: $type"

    if ($type -eq "unsupported") {
        Write-Skip "$DeploymentName ($ModelName) — unsupported model type, skipping"
        return "skipped"
    }

    if ($Preview) {
        Write-Host "  [PREVIEW] Would send $type request to $DeploymentName ($ModelName)" -ForegroundColor Magenta
        return "preview"
    }

    try {
        switch ($type) {
            "chat" {
                $response = Invoke-ChatCompletion -Endpoint $Endpoint -DeploymentName $DeploymentName `
                    -Token $Token -PromptText $PromptText
                $tokens = $response.usage.total_tokens
                Write-Success "$DeploymentName ($ModelName) — chat completion OK, $tokens tokens used"
            }
            "embeddings" {
                $response = Invoke-EmbeddingRequest -Endpoint $Endpoint -DeploymentName $DeploymentName `
                    -Token $Token -InputText $PromptText
                $tokens = $response.usage.total_tokens
                Write-Success "$DeploymentName ($ModelName) — embedding OK, $tokens tokens used"
            }
        }
        return "success"
    }
    catch {
        $errMsg = $_.Exception.Message
        # Try to extract meaningful error from response
        $errDetails = $_.ErrorDetails
        if ($null -ne $errDetails -and $null -ne $errDetails.Message) {
            try {
                $errDetail = $errDetails.Message | ConvertFrom-Json
                $errMsg = $errDetail.error.message
            }
            catch {
                $errMsg = $errDetails.Message
            }
        }
        if ($errMsg -match 'general failure|A connection attempt failed|No such host is known|actively refused') {
            Write-Fail "$DeploymentName ($ModelName) — endpoint unreachable (private network?): $errMsg"
            return "blocked"
        }
        Write-Fail "$DeploymentName ($ModelName) — $errMsg"
        return "failed"
    }
}

#endregion

#region Main

Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host " Azure AI Foundry — Traffic Generator (Entra ID auth)" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan

# Verify authentication
Write-Step "Verifying Azure CLI authentication..."
$currentAccount = Test-AzCliAuthenticated
Write-Success "Authenticated as: $($currentAccount.user.name)"

# Resolve subscriptions
$subscriptions = Get-Subscriptions -TargetSubscriptionId $SubscriptionId -ScanAll $AllSubscriptions.IsPresent -FirstOnly $FirstOnly.IsPresent
Write-Host "`nTarget subscriptions: $($subscriptions.Count)" -ForegroundColor Cyan

# Acquire AAD token
Write-Step "Acquiring Entra ID token for Cognitive Services..."
$tokenInfo = Get-AadToken
$aadToken = $tokenInfo.AccessToken
Write-Success "Token acquired (expires: $($tokenInfo.ExpiresOn) UTC)"

# Discover Foundry AI Services accounts
$accounts = @(Find-FoundryAIServicesAccounts -Subscriptions $subscriptions)

if ($accounts.Count -eq 0) {
    Write-Host "`nNo Azure AI Foundry (AIServices) accounts found." -ForegroundColor Yellow
    exit 0
}

Write-Host "`nFound $($accounts.Count) AIServices account(s):" -ForegroundColor Cyan
$accounts | Format-Table Name, ResourceGroup, Subscription -AutoSize

# Discover deployments per account
Write-Step "Discovering model deployments..."

$allDeployments = @()
foreach ($acct in $accounts) {
    $deployments = @(Get-ModelDeployments -AccountName $acct.Name -ResourceGroup $acct.ResourceGroup -SubscriptionId $acct.SubscriptionId)

    if ($deployments.Count -eq 0) {
        Write-Host "  $($acct.Name) — no deployments found" -ForegroundColor Gray
        continue
    }

    foreach ($dep in $deployments) {
        $allDeployments += [PSCustomObject]@{
            Account      = $acct.Name
            Endpoint     = $acct.Endpoint
            Deployment   = $dep.name
            Model        = $dep.model
            Format       = $dep.format
            Version      = $dep.version
            Status       = $dep.status
            Subscription = $acct.Subscription
        }
    }

    if ($FirstOnly) {
        Write-Host "  FirstOnly: using account '$($acct.Name)' with $($deployments.Count) deployment(s)" -ForegroundColor Yellow
        break
    }
}

if ($allDeployments.Count -eq 0) {
    Write-Host "`nNo model deployments found across all accounts." -ForegroundColor Yellow
    exit 0
}

Write-Host "`nFound $($allDeployments.Count) deployment(s):" -ForegroundColor Cyan
$allDeployments | Format-Table Account, Deployment, Model, Version, Status -AutoSize

# Filter to only succeeded deployments
$activeDeployments = @($allDeployments | Where-Object { $_.Status -eq "Succeeded" })
$skippedNotReady = $allDeployments.Count - $activeDeployments.Count

if ($skippedNotReady -gt 0) {
    Write-Host "  $skippedNotReady deployment(s) skipped (not in Succeeded state)" -ForegroundColor Yellow
}

if ($activeDeployments.Count -eq 0) {
    Write-Host "`nNo active deployments to test." -ForegroundColor Yellow
    exit 0
}

# Confirm
if (-not $WhatIfPreference) {
    $totalRequests = $activeDeployments.Count * $Iterations
    $confirm = Read-Host "`nSend $totalRequests request(s) across $($activeDeployments.Count) deployment(s) ($Iterations iteration(s))? (Y/N)"
    if ($confirm -notin @('Y', 'y', 'yes', 'Yes')) {
        Write-Host "Aborted." -ForegroundColor Yellow
        exit 0
    }
}

# Build task list: expand deployments × requests × iterations into individual work items
$taskList = @()
foreach ($dep in $activeDeployments) {
    for ($iter = 1; $iter -le $Iterations; $iter++) {
        $taskList += [PSCustomObject]@{
            Account        = $dep.Account
            Endpoint       = $dep.Endpoint
            Deployment     = $dep.Deployment
            Model          = $dep.Model
            Iteration      = $iter
        }
    }
}

# Send requests
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
Write-Step "Generating traffic$(if (-not $Sequential) { " (parallel, throttle=$ThrottleLimit)" } else { " (sequential)" })..."

$blockedEndpoints = [System.Collections.Concurrent.ConcurrentDictionary[string, bool]]::new()
$stats = @{ success = 0; failed = 0; skipped = 0; preview = 0; blocked = 0 }

if (-not $Sequential) {
    # Parallel execution using ForEach-Object -Parallel (PowerShell 7+)
    for ($iter = 1; $iter -le $Iterations; $iter++) {
        if ($Delay -gt 0 -and $iter -gt 1) {
            Write-Host "  Waiting $Delay second(s) before next iteration..." -ForegroundColor DarkGray
            Start-Sleep -Seconds $Delay
        }
        if ($Iterations -gt 1) {
            Write-Host "`n===== Iteration $iter of $Iterations =====" -ForegroundColor Cyan
        }
        # Renew token if needed before each parallel iteration
        $tokenInfo = Get-ValidToken -TokenInfo $tokenInfo
        $aadToken = $tokenInfo.AccessToken

        $iterTasks = $taskList | Where-Object { $_.Iteration -eq $iter }
        $results = $iterTasks | ForEach-Object -Parallel {
        $task = $_
        $token = $using:aadToken
        $prompt = $using:Prompt
        $preview = $using:WhatIfPreference

        # Classify model type inline (functions not available in parallel runspaces)
        $modelName = $task.Model
        if ($modelName -match 'embedding|ada') {
            $type = 'embeddings'
        } elseif ($modelName -match 'dall-e|gpt-image|realtime|document-ai|whisper|tts|codex|gpt-5-pro') {
            $type = 'unsupported'
        } else {
            $type = 'chat'
        }

        $result = [PSCustomObject]@{
            Account    = $task.Account
            Deployment = $task.Deployment
            Model      = $modelName
            Iteration  = $task.Iteration
            Status     = ''
            Message    = ''
        }

        if ($type -eq 'unsupported') {
            $result.Status = 'skipped'
            $result.Message = 'unsupported model type'
            return $result
        }

        $blocked = $using:blockedEndpoints
        if ($blocked.ContainsKey($task.Endpoint)) {
            $result.Status = 'blocked'
            $result.Message = 'endpoint unreachable (private network) — skipped'
            return $result
        }

        if ($preview) {
            $result.Status = 'preview'
            $result.Message = "would send $type request"
            return $result
        }

        try {
            $endpoint = "$($task.Endpoint.TrimEnd('/'))/openai/v1"
            $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }

            if ($type -eq 'chat') {
                $body = @{
                    model    = $task.Deployment
                    messages = @(@{ role = 'user'; content = $prompt })
                } | ConvertTo-Json -Depth 5
                $response = Invoke-RestMethod -Uri "$endpoint/chat/completions" -Method Post -Headers $headers -Body $body -ErrorAction Stop
                $tokens = $response.usage.total_tokens
                $result.Status = 'success'
                $result.Message = "chat completion OK, $tokens tokens used"
            } else {
                $body = @{
                    model = $task.Deployment
                    input = @($prompt)
                } | ConvertTo-Json -Depth 5
                $response = Invoke-RestMethod -Uri "$endpoint/embeddings" -Method Post -Headers $headers -Body $body -ErrorAction Stop
                $tokens = $response.usage.total_tokens
                $result.Status = 'success'
                $result.Message = "embedding OK, $tokens tokens used"
            }
        }
        catch {
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
            if ($errMsg -match 'general failure|A connection attempt failed|No such host is known|actively refused') {
                $blocked = $using:blockedEndpoints
                $blocked.TryAdd($task.Endpoint, $true) | Out-Null
                $result.Status = 'blocked'
                $result.Message = "endpoint unreachable (private network?): $errMsg"
            } else {
                $result.Status = 'failed'
                $result.Message = $errMsg
            }
        }

        return $result
    } -ThrottleLimit $ThrottleLimit

    # Print results and tally stats
    $currentLabel = ''
    foreach ($r in $results) {
        $label = "$($r.Account) / $($r.Deployment) ($($r.Model))"
        if ($label -ne $currentLabel) {
            Write-Host "`n  --- $label ---" -ForegroundColor White
            $currentLabel = $label
        }
        switch ($r.Status) {
            'success' { Write-Success "$($r.Deployment) ($($r.Model)) — $($r.Message)" }
            'failed'  { Write-Fail "$($r.Deployment) ($($r.Model)) — $($r.Message)" }
            'skipped' { Write-Skip "$($r.Deployment) ($($r.Model)) — $($r.Message)" }
            'blocked' { Write-Fail "$($r.Deployment) ($($r.Model)) — $($r.Message)" }
            'preview' { Write-Host "  [PREVIEW] $($r.Deployment) ($($r.Model)) — $($r.Message)" -ForegroundColor Magenta }
        }
        $stats[$r.Status]++
        }
    }
} else {
    # Sequential execution
    for ($iter = 1; $iter -le $Iterations; $iter++) {
        if ($Delay -gt 0 -and $iter -gt 1) {
            Write-Host "  Waiting $Delay second(s) before next iteration..." -ForegroundColor DarkGray
            Start-Sleep -Seconds $Delay
        }
        if ($Iterations -gt 1) {
            Write-Host "`n===== Iteration $iter of $Iterations =====" -ForegroundColor Cyan
        }

        foreach ($dep in $activeDeployments) {
            if ($blockedEndpoints.ContainsKey($dep.Endpoint)) {
                Write-Skip "$($dep.Deployment) ($($dep.Model)) — endpoint $($dep.Endpoint) unreachable (private network), skipping"
                $stats['blocked']++
                continue
            }

            Write-Host "`n  --- $($dep.Account) / $($dep.Deployment) ($($dep.Model)) ---" -ForegroundColor White

            # Renew token if needed before each sequential request
            $tokenInfo = Get-ValidToken -TokenInfo $tokenInfo
            $aadToken = $tokenInfo.AccessToken

            $result = Invoke-DeploymentRequest `
                -Endpoint $dep.Endpoint `
                -DeploymentName $dep.Deployment `
                -ModelName $dep.Model `
                -Token $aadToken `
                -PromptText $Prompt `
                -Preview $WhatIfPreference

            if ($result -eq 'blocked') {
                $blockedEndpoints.TryAdd($dep.Endpoint, $true) | Out-Null
                Write-Skip "Marking endpoint $($dep.Endpoint) as unreachable — will skip remaining deployments"
            }

            $stats[$result]++
        }
    }
}

# Summary
$stopwatch.Stop()
Write-Host "`n=====================================================" -ForegroundColor Cyan
Write-Host " Summary" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "  Deployments found:  $($allDeployments.Count)"
Write-Host "  Requests sent:      $($stats.success + $stats.failed)" -ForegroundColor White
Write-Host "  Successful:         $($stats.success)" -ForegroundColor Green
Write-Host "  Failed:             $($stats.failed)" -ForegroundColor $(if ($stats.failed -gt 0) { "Red" } else { "Gray" })
Write-Host "  Skipped:            $($stats.skipped)" -ForegroundColor Yellow
Write-Host "  Blocked (private):  $($stats.blocked)" -ForegroundColor $(if ($stats.blocked -gt 0) { "Red" } else { "Gray" })
if ($WhatIfPreference) {
    Write-Host "  Preview only:       $($stats.preview)" -ForegroundColor Magenta
}
Write-Host "  Elapsed time:       $($stopwatch.Elapsed.ToString('hh\:mm\:ss\.fff'))" -ForegroundColor White

#endregion
