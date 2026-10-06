#Requires -Version 7.0
<#
.SYNOPSIS
    Lets an environment's identities borrow the rights of the two apps setup.ps1 made, or takes that away.

.DESCRIPTION
    Each `mov up` makes the environment's managed identities anew, with new ids. The two apps that hold
    what reaches outside the environment (app-nordvik-m365 in Microsoft 365, app-nordvik-kostnad on cost
    and billing) trust them through a federated credential each, named after the environment, so test and
    prod never overwrite each other's.

        pwsh v41/setup/trust.ps1                      after mov up nordvik-v41-prod
        pwsh v41/setup/trust.ps1 -Remove              before mov down nordvik-v41-prod
        pwsh v41/setup/trust.ps1 nordvik-v41-test     the same for test

    Nothing else on the apps is touched. A credential that already trusts the identity is left as it is.
#>
[CmdletBinding()]
param(
    [ValidateSet('nordvik-v41-prod', 'nordvik-v41-test')]
    [string]$Environment = 'nordvik-v41-prod',
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

$AzureTenant  = '65b3c448-4eb8-49ce-b0fb-f373ad166449'
$Subscription = '409a5c62-0fe5-4c23-b559-7e0e63ff8603'
$Groups       = @{ 'nordvik-v41-prod' = 'rg-nordvik'; 'nordvik-v41-test' = 'rg-nordvik-v41-test' }
$Trusts       = @(
    @{ App = 'app-nordvik-m365';    Identity = 'id-nordvik-notify';  Purpose = 'notify' }
    @{ App = 'app-nordvik-kostnad'; Identity = 'id-nordvik-ekonomi'; Purpose = 'ekonomi' }
)

function Say([string]$Text) { Write-Host "     $Text" }
function Ok([string]$Text) { Write-Host '     OK   ' -ForegroundColor Green -NoNewline; Write-Host $Text }

function Invoke-Az {
    $output = & az @args
    if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed" }
    $output
}

Invoke-Az account set --subscription $Subscription | Out-Null
$group = $Groups[$Environment]

foreach ($trust in $Trusts) {
    $appId = Invoke-Az ad app list --display-name $trust.App --query '[0].appId' -o tsv
    if (-not $appId) { throw "$($trust.App) does not exist: run D:\MOV25\GitHub\azure\v41\setup\setup.ps1 first" }
    $name = "mov-$Environment-$($trust.Purpose)"
    $existing = Invoke-Az ad app federated-credential list --id $appId -o json | ConvertFrom-Json |
        Where-Object { $_.name -eq $name } | Select-Object -First 1

    if ($Remove) {
        if ($existing) {
            Invoke-Az ad app federated-credential delete --id $appId --federated-credential-id $existing.id | Out-Null
            Ok "$($trust.App) no longer trusts $($trust.Identity) of $Environment"
        } else {
            Say "$($trust.App) holds no trust for $Environment"
        }
        continue
    }

    $subject = Invoke-Az identity show --resource-group $group --name $trust.Identity --query principalId -o tsv
    if ($existing -and $existing.subject -eq $subject) {
        Say "$($trust.App) already trusts $($trust.Identity) of $Environment"
        continue
    }
    $file = New-TemporaryFile
    @{
        name        = $name
        issuer      = "https://login.microsoftonline.com/$AzureTenant/v2.0"
        subject     = $subject
        audiences   = @('api://AzureADTokenExchange')
        description = "$($trust.Identity) in $group borrows this app's rights while $Environment stands."
    } | ConvertTo-Json | Set-Content $file
    if ($existing) {
        Invoke-Az ad app federated-credential update --id $appId --federated-credential-id $existing.id --parameters "@$file" | Out-Null
        Ok "$($trust.App) trusts the new $($trust.Identity) of $Environment"
    } else {
        Invoke-Az ad app federated-credential create --id $appId --parameters "@$file" | Out-Null
        Ok "$($trust.App) trusts $($trust.Identity) of $Environment"
    }
    Remove-Item $file
}
