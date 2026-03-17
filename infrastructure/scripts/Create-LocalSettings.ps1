<#
.SYNOPSIS
    Generates src/local.settings.json from azd environment variables (Bicep outputs).

.DESCRIPTION
    After 'azd provision', Bicep outputs are stored as azd environment variables.
    This script reads them and writes a local.settings.json that lets you run the
    functions locally with 'func host start'.

    The file is in .gitignore — it is never committed.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Validate that key env vars exist
$required = @(
    'AZURE_STORAGE_ACCOUNT_NAME',
    'AZURE_DCE_ENDPOINT',
    'AZURE_DCR_QUOTA_SNAPSHOT_IMMUTABLE_ID',
    'AZURE_DCR_DEPLOYMENT_CONFIG_IMMUTABLE_ID',
    'AZURE_DCR_TOKEN_USAGE_IMMUTABLE_ID',
    'AZURE_STORAGE_TABLE_ENDPOINT'
)

foreach ($var in $required) {
    if (-not (Get-Item "env:$var" -ErrorAction SilentlyContinue)) {
        throw "Environment variable '$var' is not set. Run 'azd provision' first."
    }
}

$settings = @{
    IsEncrypted = $false
    Values = [ordered]@{
        FUNCTIONS_WORKER_RUNTIME                = 'python'
        AzureWebJobsStorage__accountName        = $env:AZURE_STORAGE_ACCOUNT_NAME
        APPLICATIONINSIGHTS_CONNECTION_STRING   = ($env:AZURE_APP_INSIGHTS_CONNECTION_STRING ?? '')
        DCE_ENDPOINT                            = $env:AZURE_DCE_ENDPOINT
        DCR_QUOTA_SNAPSHOT_IMMUTABLE_ID          = $env:AZURE_DCR_QUOTA_SNAPSHOT_IMMUTABLE_ID
        DCR_DEPLOYMENT_CONFIG_IMMUTABLE_ID       = $env:AZURE_DCR_DEPLOYMENT_CONFIG_IMMUTABLE_ID
        DCR_TOKEN_USAGE_IMMUTABLE_ID             = $env:AZURE_DCR_TOKEN_USAGE_IMMUTABLE_ID
        WATERMARK_TABLE_NAME                     = 'watermarks'
        WATERMARK_STORAGE_ENDPOINT               = $env:AZURE_STORAGE_TABLE_ENDPOINT
        MAX_PARALLEL_SUBS                        = ($env:AZURE_MAX_PARALLEL_SUBS ?? '5')
    }
}

$outPath = Join-Path $PSScriptRoot '..' '..' 'src' 'local.settings.json'
$settings | ConvertTo-Json -Depth 3 | Set-Content $outPath -Encoding utf8

Write-Host "Created $(Resolve-Path $outPath)" -ForegroundColor Green
