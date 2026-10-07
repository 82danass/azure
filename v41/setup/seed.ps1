#Requires -Version 7.0
<#
.SYNOPSIS
    Loads example properties and their managers into an environment's table, after `mov up`.

.DESCRIPTION
    The properties in exempel.json are written to the table fastigheter, each manager's with the
    manager's Entra object id, and the managers to the same table with the address their notices go
    to. A fresh environment has no properties, and the tenant form offers nothing to report against
    until a manager has added one: this gives a demo something to show at once.

    The storage account has no public endpoint, so this runs inside the environment: a short-lived
    Container Apps job with the portal's image and the portal's identity writes through the portal's
    own code, the same way the portal does. The job is removed afterwards, also when it fails, so
    `mov down` finds only what mov made. Running it again changes nothing but the same rows.

        pwsh v41/setup/seed.ps1
        pwsh v41/setup/seed.ps1 nordvik-v41-test
#>
[CmdletBinding()]
param(
    [ValidateSet('nordvik-v41-prod', 'nordvik-v41-test')]
    [string]$Environment = 'nordvik-v41-prod',
    # Where a seeded manager's notices go: the test users have no mailbox of their own.
    [string]$NotifyEmail = 'DanielAssarelius@mov25areslius.onmicrosoft.com'
)

$ErrorActionPreference = 'Stop'

$Subscription = '409a5c62-0fe5-4c23-b559-7e0e63ff8603'
$Groups = @{ 'nordvik-v41-prod' = 'rg-nordvik'; 'nordvik-v41-test' = 'rg-nordvik-v41-test' }
$Group = $Groups[$Environment]
$Portal = 'ca-nordvik-portal'
$Job = 'job-nordvik-seed'

function Ok([string]$Text) { Write-Host '     OK   ' -ForegroundColor Green -NoNewline; Write-Host $Text }
function Invoke-Az {
    $output = & az @args
    if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed" }
    $output
}

Invoke-Az account set --subscription $Subscription | Out-Null

# Everything the job needs, read off the portal as it runs: its environment, identity, image and
# the settings that point its code at the storage account.
$app = Invoke-Az containerapp show -g $Group -n $Portal -o json | ConvertFrom-Json
$container = $app.properties.template.containers[0]
$settings = @{}
foreach ($entry in $container.env) { if ($null -ne $entry.value) { $settings[$entry.name] = $entry.value } }
$identity = @($app.identity.userAssignedIdentities.PSObject.Properties.Name)[0]

# The managers by the purpose directory.json gives them, as Entra knows them.
$seed = Get-Content (Join-Path $PSScriptRoot 'exempel.json') -Raw | ConvertFrom-Json
# Looked up by sign-in name: az is a .cmd on Windows, and cmd reads the parentheses of a Graph
# filter as its own syntax.
$domain = (Get-Content (Join-Path $PSScriptRoot '..\..\mov-workspace-nordvik\mov.workspace.json') -Raw | ConvertFrom-Json).azure.tenantDomain
$managers = @{}
foreach ($purpose in ($seed.properties.manager | Where-Object { $_ } | Sort-Object -Unique)) {
    $found = & az ad user show --id "usr-nordvik-$purpose@$domain" --query '{id:id,name:displayName}' -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $found) { throw "no Entra user for manager ${purpose}: run mov up $Environment first" }
    $managers[$purpose] = $found | ConvertFrom-Json
}
$payload = @{
    managers   = @($managers.Values | ForEach-Object { @{ oid = $_.id; name = $_.name; notify_email = $NotifyEmail } })
    properties = @($seed.properties | ForEach-Object {
        $manager = if ($_.manager) { $managers[$_.manager] } else { $null }
        @{ name = $_.name; address = $_.address; oid = ($manager ? $manager.id : ''); manager_name = ($manager ? $manager.name : '') }
    })
} | ConvertTo-Json -Depth 5 -Compress

$code = @'
import json, os
import nordvik
seed = json.loads(os.environ["NORDVIK_SEED"])
for manager in seed["managers"]:
    nordvik.save_manager(manager["oid"], manager["name"], manager["notify_email"])
for building in seed["properties"]:
    nordvik.save_property({"PartitionKey": "fastighet", "RowKey": nordvik.property_slug(building["name"]),
                           "name": building["name"], "address": building["address"],
                           "manager_oid": building["oid"], "manager_name": building["manager_name"]})
print("seeded", len(seed["properties"]), "properties and", len(seed["managers"]), "managers", flush=True)
'@
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($code))

$definition = @{
    location   = $app.location
    identity   = @{ type = 'UserAssigned'; userAssignedIdentities = @{ $identity = @{} } }
    properties = @{
        environmentId       = $app.properties.managedEnvironmentId
        workloadProfileName = 'Consumption'
        configuration       = @{ triggerType = 'Manual'; replicaTimeout = 300; replicaRetryLimit = 0
                                 manualTriggerConfig = @{ parallelism = 1; replicaCompletionCount = 1 } }
        template            = @{ containers = @(@{
            name      = 'seed'
            image     = $container.image
            command   = @('python', '-c', "import base64;exec(base64.b64decode('$encoded'))")
            resources = @{ cpu = 0.25; memory = '0.5Gi' }
            env       = @(
                @{ name = 'AZURE_CLIENT_ID'; value = $settings['AZURE_CLIENT_ID'] },
                @{ name = 'NORDVIK_STORAGE_ACCOUNT'; value = $settings['NORDVIK_STORAGE_ACCOUNT'] },
                @{ name = 'NORDVIK_SEED'; value = $payload }
            )
        }) }
    }
}
$file = New-TemporaryFile
$definition | ConvertTo-Json -Depth 10 | Set-Content $file
try {
    Invoke-Az containerapp job create -g $Group -n $Job --environment $app.properties.managedEnvironmentId --yaml $file -o none 2>$null
    $execution = Invoke-Az containerapp job start -g $Group -n $Job --query name -o tsv
    do {
        Start-Sleep -Seconds 10
        $status = Invoke-Az containerapp job execution show -g $Group -n $Job --job-execution-name $execution --query properties.status -o tsv
    } while ($status -in 'Running', 'Processing')
    if ($status -ne 'Succeeded') { throw "the seed job ended $status" }
    Ok "$($seed.properties.Count) properties in fastigheter, $($managers.Count) managers with notices to $NotifyEmail"
} finally {
    Remove-Item $file -ErrorAction SilentlyContinue
    & az containerapp job delete -g $Group -n $Job --yes -o none 2>$null
}
