#Requires -Version 7.0
<#
.SYNOPSIS
    Nordvik's tenant, set up once: the two apps that hold what reaches outside an environment, and the
    SharePoint list the Function writes a copy of every report to.

.DESCRIPTION
    Run once, before the first `mov up nordvik-v41-prod`, by someone who is Global Administrator in both
    tenants. Safe to run again: everything already in place is left as it is.

    In the Azure tenant (az, already signed in):
      - app-nordvik-m365, open to other organisations, for the Function to reach Microsoft 365;
      - app-nordvik-kostnad, holding Cost Management Reader on the subscription and Billing profile
        reader on the billing profile, for the finance site to read cost.

    In the Microsoft 365 tenant (a browser sign-in, Microsoft Graph PowerShell):
      - app-nordvik-m365 consented with Lists.SelectedOperations.Selected only;
      - the list Felanmalningar on the root site, its columns from felanmalningar.json, indexed;
      - write granted to app-nordvik-m365 on that one list, and nothing else.

    With -Remove it undoes all of that, so the tenant layer can be rebuilt from nothing. Run it after
    `mov down` of every environment: they use the apps.

    Then it writes the two app ids, the site id and the list id into the profile, so nothing is pasted by
    hand. No secret is made anywhere: each app is used by an environment's managed identity through a
    federated credential, which trust.ps1 adds after `mov up` and removes before `mov down`.
#>
[CmdletBinding()]
param(
    # The Global Administrator of the Microsoft 365 tenant, handed to the sign-in so it opens with the account
    # filled in.
    [string]$M365Admin = 'DanielAssarelius@mov25areslius.onmicrosoft.com',
    # Undo all of it: the list, the consent, the roles, both apps, and the values written into the profile.
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

# What the workspace pins, and Microsoft's fixed ids.
$AzureTenant   = '65b3c448-4eb8-49ce-b0fb-f373ad166449'
$Subscription  = '409a5c62-0fe5-4c23-b559-7e0e63ff8603'
$M365Tenant    = 'mov25areslius.onmicrosoft.com'
$GraphAppId    = '00000003-0000-0000-c000-000000000000'
$ListRole      = 'Lists.SelectedOperations.Selected'
$BillingReader = '40000000-aaaa-bbbb-cccc-100000000002'
$ListName      = 'Felanmalningar'
$ProfilePath   = Join-Path $PSScriptRoot '..\..\mov-workspace-nordvik\profiles\nordvik-v41-prod.json'
$ListPath      = Join-Path $PSScriptRoot 'felanmalningar.json'

function Say([string]$Text) { Write-Host "     $Text" }
function Ok([string]$Text) { Write-Host '     OK   ' -ForegroundColor Green -NoNewline; Write-Host $Text }
function Warn([string]$Text) { Write-Host '     WARN ' -ForegroundColor Yellow -NoNewline; Write-Host $Text }
function Step([string]$Text) { Write-Host "`n$Text" -ForegroundColor Cyan }

function Invoke-Az {
    # az with its exit code checked: a failed call stops the script instead of passing on an empty answer.
    $output = & az @args
    if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed" }
    $output
}

function Set-App([string]$Name, [string]$Audience) {
    $appId = Invoke-Az ad app list --display-name $Name --query '[0].appId' -o tsv
    if ($appId) {
        Say "$Name exists ($appId)"
    } else {
        $appId = Invoke-Az ad app create --display-name $Name --sign-in-audience $Audience --query appId -o tsv
        Ok "$Name registered, $Audience, no secret"
    }
    $objectId = Invoke-Az ad sp list --filter "appId eq '$appId'" --query '[0].id' -o tsv
    if (-not $objectId) {
        $objectId = Invoke-Az ad sp create --id $appId --query id -o tsv
        Ok "$Name has its service principal"
    }
    [pscustomobject]@{ Name = $Name; AppId = $appId; ObjectId = $objectId }
}

function Set-ProfileValue([string]$Text, [string]$Setting, [string]$Value) {
    $pattern = '("name": "' + [regex]::Escape($Setting) + '",\s*"value": ")[^"]*(")'
    if ($Text -notmatch $pattern) { throw "$Setting is not in $ProfilePath" }
    [regex]::Replace($Text, $pattern, '${1}' + $Value + '${2}')
}

function Connect-M365 {
    if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) {
        Say 'installing Microsoft.Graph.Authentication for this user, once'
        Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force
    }
    Import-Module Microsoft.Graph.Authentication
    Step "Microsoft 365 tenant, ${M365Tenant}: signing in as $M365Admin"
    Say 'the sign-in window opens with that account filled in; it may open behind this terminal'
    Connect-MgGraph -TenantId $M365Tenant -LoginHint $M365Admin -NoWelcome `
        -Scopes 'Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All', 'Sites.FullControl.All', 'Sites.Manage.All'
    Ok "signed in as $((Get-MgContext).Account)"
}

function G([string]$Method, [string]$Uri, $Body) {
    if ($null -ne $Body) {
        Invoke-MgGraphRequest -Method $Method -Uri $Uri -Body ($Body | ConvertTo-Json -Depth 20) -ContentType 'application/json'
    } else {
        Invoke-MgGraphRequest -Method $Method -Uri $Uri
    }
}

function Wait-Ready([string]$What, [scriptblock]$Call) {
    # A new app takes a while to reach other tenants and SharePoint: until it has, Entra answers
    # NoBackingApplicationObject. The call is tried again every 10 seconds, for up to 3 minutes.
    foreach ($attempt in 1..18) {
        try { return & $Call }
        catch {
            if ($attempt -eq 18) { throw }
            if ($attempt -eq 1) { Say "$What waits for the new app to reach this tenant" }
            Start-Sleep -Seconds 10
        }
    }
}

if ($Remove) {
    Invoke-Az account set --subscription $Subscription | Out-Null
    $tenant = Invoke-Az account show --query tenantId -o tsv
    if ($tenant -ne $AzureTenant) { throw "az is signed in to tenant $tenant, and Nordvik's Azure is ${AzureTenant}: run mov use --login" }
    $m365Id = Invoke-Az ad app list --display-name 'app-nordvik-m365' --query '[0].appId' -o tsv
    $costId = Invoke-Az ad app list --display-name 'app-nordvik-kostnad' --query '[0].appId' -o tsv

    Connect-M365
    $site = G GET 'v1.0/sites/root'
    $list = (G GET "v1.0/sites/$($site.id)/lists?`$filter=displayName eq '$ListName'").value | Select-Object -First 1
    if ($list) {
        try {
            G DELETE "v1.0/sites/$($site.id)/lists/$($list.id)" | Out-Null
            Ok "the list $ListName removed, its grant with it"
        } catch {
            Warn "the list $ListName was not removed ($($_.Exception.Message)): delete it on $($site.webUrl)"
        }
    } else { Say "no list $ListName" }
    if ($m365Id) {
        $principal = (G GET "v1.0/servicePrincipals?`$filter=appId eq '$m365Id'").value | Select-Object -First 1
        if ($principal) { G DELETE "v1.0/servicePrincipals/$($principal.id)" | Out-Null; Ok 'app-nordvik-m365 and its consent removed here' }
    }
    Disconnect-MgGraph | Out-Null

    Step 'Azure tenant'
    if ($costId) {
        $costObject = Invoke-Az ad sp list --filter "appId eq '$costId'" --query '[0].id' -o tsv
        try {
            $profileId = Invoke-Az rest --method get `
                --url "https://management.azure.com/subscriptions/$Subscription/providers/Microsoft.Billing/billingProperty/default?api-version=2024-04-01" `
                --query properties.billingProfileId -o tsv
            $held = (Invoke-Az rest --method get --url "https://management.azure.com$profileId/billingRoleAssignments?api-version=2024-04-01" -o json |
                ConvertFrom-Json).value | Where-Object { $_.properties.principalId -eq $costObject }
            foreach ($assignment in $held) {
                Invoke-Az rest --method delete --url "https://management.azure.com$($assignment.id)?api-version=2024-04-01" | Out-Null
                Ok 'app-nordvik-kostnad: Billing profile reader removed'
            }
        } catch { Warn "Billing profile reader not removed ($($_.Exception.Message))" }
        Invoke-Az role assignment delete --assignee $costObject --role 'Cost Management Reader' --scope "/subscriptions/$Subscription" | Out-Null
        Ok 'app-nordvik-kostnad: Cost Management Reader removed'
        Invoke-Az ad app delete --id $costId | Out-Null
        Ok 'app-nordvik-kostnad removed'
    }
    if ($m365Id) { Invoke-Az ad app delete --id $m365Id | Out-Null; Ok 'app-nordvik-m365 removed' }

    Step 'Profile'
    $text = Get-Content $ProfilePath -Raw
    $text = Set-ProfileValue $text 'NORDVIK_M365_APP_ID' ''
    $text = Set-ProfileValue $text 'NORDVIK_COST_APP_ID' ''
    $text = Set-ProfileValue $text 'NORDVIK_LIST_SITE' 'root'
    $text = Set-ProfileValue $text 'NORDVIK_LIST' $ListName
    $text = Set-ProfileValue $text 'NORDVIK_ONCALL_EMAIL' ''
    Set-Content -Path $ProfilePath -Value $text -NoNewline -Encoding utf8NoBOM
    Ok "the values setup wrote are reset in $(Split-Path $ProfilePath -Leaf)"
    Write-Host "`nRemoved. The tenant is as it was before setup.ps1." -ForegroundColor Cyan
    return
}

# --- the Azure tenant ------------------------------------------------------------------------------

Step 'Azure tenant'
Invoke-Az account set --subscription $Subscription | Out-Null
$tenant = Invoke-Az account show --query tenantId -o tsv
if ($tenant -ne $AzureTenant) { throw "az is signed in to tenant $tenant, and Nordvik's Azure is ${AzureTenant}: run mov use --login" }
Ok "az on subscription $Subscription"

# Both tenants are signed in to before anything is made: a sign-in that is cancelled or never completes
# leaves nothing half built.
Connect-M365

Step 'Azure tenant: apps and roles'
$m365 = Set-App 'app-nordvik-m365' 'AzureADMultipleOrgs'
$cost = Set-App 'app-nordvik-kostnad' 'AzureADMyOrg'

$scope = "/subscriptions/$Subscription"
$held = Invoke-Az role assignment list --assignee $cost.ObjectId --role 'Cost Management Reader' --scope $scope --query '[0].id' -o tsv
if ($held) {
    Say 'app-nordvik-kostnad holds Cost Management Reader on the subscription'
} else {
    Invoke-Az role assignment create --assignee-object-id $cost.ObjectId --assignee-principal-type ServicePrincipal `
        --role 'Cost Management Reader' --scope $scope --description 'Nordvik finance site: reads cost, budgets and alerts.' | Out-Null
    Ok 'app-nordvik-kostnad: Cost Management Reader on the subscription'
}

# The billing role is not an Azure role: it is assigned on the billing profile, through the billing API.
try {
    $profileId = Invoke-Az rest --method get `
        --url "https://management.azure.com/subscriptions/$Subscription/providers/Microsoft.Billing/billingProperty/default?api-version=2024-04-01" `
        --query properties.billingProfileId -o tsv
    $existing = Invoke-Az rest --method get `
        --url "https://management.azure.com$profileId/billingRoleAssignments?api-version=2024-04-01" -o json | ConvertFrom-Json
    if ($existing.value | Where-Object { $_.properties.principalId -eq $cost.ObjectId }) {
        Say 'app-nordvik-kostnad holds Billing profile reader'
    } else {
        $body = New-TemporaryFile
        @{ principalId = $cost.ObjectId; principalTenantId = $AzureTenant
           roleDefinitionId = "$profileId/billingRoleDefinitions/$BillingReader" } | ConvertTo-Json | Set-Content $body
        Invoke-Az rest --method post --url "https://management.azure.com$profileId/createBillingRoleAssignment?api-version=2024-04-01" `
            --body "@$body" | Out-Null
        Remove-Item $body
        Ok 'app-nordvik-kostnad: Billing profile reader on the billing profile'
    }
} catch {
    Warn "Billing profile reader was not granted ($($_.Exception.Message)): the finance site starts at the subscription"
}

# --- the Microsoft 365 tenant ----------------------------------------------------------------------

Step "Microsoft 365 tenant, ${M365Tenant}: the list and its grant"
$principal = (G GET "v1.0/servicePrincipals?`$filter=appId eq '$($m365.AppId)'").value | Select-Object -First 1
if ($principal) {
    Say 'app-nordvik-m365 is provisioned here'
} else {
    $principal = Wait-Ready 'provisioning' { G POST 'v1.0/servicePrincipals' @{ appId = $m365.AppId } }
    Ok 'app-nordvik-m365 provisioned here'
}

$graph = (G GET "v1.0/servicePrincipals?`$filter=appId eq '$GraphAppId'").value | Select-Object -First 1
$role = $graph.appRoles | Where-Object { $_.value -eq $ListRole }
$granted = (G GET "v1.0/servicePrincipals/$($principal.id)/appRoleAssignments").value | Where-Object { $_.appRoleId -eq $role.id }
if ($granted) {
    Say "app-nordvik-m365 holds $ListRole"
} else {
    Wait-Ready 'the consent' { G POST "v1.0/servicePrincipals/$($principal.id)/appRoleAssignments" @{
        principalId = $principal.id; resourceId = $graph.id; appRoleId = $role.id } } | Out-Null
    Ok "app-nordvik-m365 consented: $ListRole, and nothing else"
}

$site = G GET 'v1.0/sites/root'
$list = (G GET "v1.0/sites/$($site.id)/lists?`$filter=displayName eq '$ListName'").value | Select-Object -First 1
if ($list) {
    Say "the list $ListName exists on $($site.webUrl)"
} else {
    $definition = Get-Content $ListPath -Raw | ConvertFrom-Json -AsHashtable
    $list = G POST "v1.0/sites/$($site.id)/lists" $definition
    Ok "the list $ListName made on $($site.webUrl)"
}

$permissions = (G GET "v1.0/sites/$($site.id)/lists/$($list.id)/permissions").value
if ($permissions | Where-Object { $_.grantedToV2.application.id -eq $m365.AppId -or $_.grantedToIdentitiesV2.application.id -eq $m365.AppId }) {
    Say "app-nordvik-m365 may write $ListName"
} else {
    Wait-Ready 'the list grant' { G POST "v1.0/sites/$($site.id)/lists/$($list.id)/permissions" @{
        roles = @('write'); grantedToV2 = @{ application = @{ id = $m365.AppId; displayName = 'app-nordvik-m365' } } } } | Out-Null
    Ok "app-nordvik-m365 may write $ListName, and nothing else on the site"
}
# The on-call address is the administrator's own mailbox in the demo: an inbox in Nordvik's
# Microsoft 365 that urgent mail reaches at once.
$onCall = (Get-MgContext).Account
Disconnect-MgGraph | Out-Null

# --- the profile -----------------------------------------------------------------------------------

Step 'Profile'
$text = Get-Content $ProfilePath -Raw
$text = Set-ProfileValue $text 'NORDVIK_M365_APP_ID' $m365.AppId
$text = Set-ProfileValue $text 'NORDVIK_COST_APP_ID' $cost.AppId
$text = Set-ProfileValue $text 'NORDVIK_LIST_SITE' $site.id
$text = Set-ProfileValue $text 'NORDVIK_LIST' $list.id
$text = Set-ProfileValue $text 'NORDVIK_ONCALL_EMAIL' $onCall
Set-Content -Path $ProfilePath -Value $text -NoNewline -Encoding utf8NoBOM
Ok "app ids, site, list and on-call address written into $(Split-Path $ProfilePath -Leaf)"

Write-Host "`nDone. Next: mov up nordvik-v41-prod, then pwsh D:\MOV25\GitHub\azure\v41\setup\trust.ps1" -ForegroundColor Cyan
