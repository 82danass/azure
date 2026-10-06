#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys the notifier's code to the Function app the profile made: after `mov up nordvik-v41-prod`.

.DESCRIPTION
    Zips function_app.py, host.json and requirements.txt and hands them to the Flex Consumption app,
    which builds the Python packages on Linux itself. az signs in as you; no publish profile and no secret
    is used. The app's code lives in its own storage account, which only the app's identity can write.

        pwsh v41/notify/deploy.ps1
        pwsh v41/notify/deploy.ps1 nordvik-v41-test
#>
[CmdletBinding()]
param(
    [ValidateSet('nordvik-v41-prod', 'nordvik-v41-test')]
    [string]$Environment = 'nordvik-v41-prod'
)

$ErrorActionPreference = 'Stop'

$Subscription = '409a5c62-0fe5-4c23-b559-7e0e63ff8603'
$Groups = @{ 'nordvik-v41-prod' = 'rg-nordvik'; 'nordvik-v41-test' = 'rg-nordvik-v41-test' }
$App = "func-$Environment-notify"

$zip = Join-Path ([IO.Path]::GetTempPath()) "$App.zip"
Remove-Item $zip -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $PSScriptRoot 'function_app.py'), (Join-Path $PSScriptRoot 'host.json'),
    (Join-Path $PSScriptRoot 'requirements.txt') -DestinationPath $zip

az account set --subscription $Subscription
if ($LASTEXITCODE -ne 0) { throw 'az could not select the subscription' }
az functionapp deployment source config-zip --resource-group $Groups[$Environment] --name $App --src $zip --build-remote true
if ($LASTEXITCODE -ne 0) { throw "the deployment to $App failed" }
Remove-Item $zip
Write-Host "     OK   $App runs the notifier from $PSScriptRoot" -ForegroundColor Green
