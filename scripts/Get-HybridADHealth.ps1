<#
.SYNOPSIS
  Hybrid AD Health Check: identifies orphaned or inactive accounts in On-Prem AD
  and compares them with Entra ID (Azure AD) for sync drift.

.DESCRIPTION
  - On-Prem AD:
      * Users & Computers with last logon > X days (or never)
      * Disabled status, creation, modification, OU, OS (for computers)
  - Entra ID:
      * Comparison via onPremisesImmutableId (Base64(objectGUID))
      * AD objects NOT present in Entra ID (NotSyncedToAAD)
      * AAD objects sourced from OnPrem but no longer existing in AD (OrphanedInAAD)

.OUTPUTS
  CSVs + Markdown Summary in OutDir.

.REQUIREMENTS
  - Windows, domain-joined admin host
  - RSAT ActiveDirectory module (Get-ADUser/Get-ADComputer)
  - Microsoft Graph PowerShell SDK
  - Graph Scopes: Directory.Read.All

.NOTES
  Author : Ramon Lotz
  Version: 1.0
#>

param (
    [int]$InactiveDays = 90,
    [string]$OutDir = ".\HybridADHealthCheck"
)

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

Import-Module ActiveDirectory

$thresholdDate = (Get-Date).AddDays(-$InactiveDays)
$adUsers = Get-ADUser -Filter * -Properties LastLogonDate, Enabled, Created, Modified, ObjectGUID | Where-Object {
    !$_.Enabled -or !$_.LastLogonDate -or $_.LastLogonDate -lt $thresholdDate
}

$adComputers = Get-ADComputer -Filter * -Properties LastLogonDate, OperatingSystem, Enabled, Created, Modified, ObjectGUID | Where-Object {
    !$_.Enabled -or !$_.LastLogonDate -or $_.LastLogonDate -lt $thresholdDate
}

function Convert-GUIDToBase64 {
    param ($guid)
    [System.Convert]::ToBase64String($guid.ToByteArray())
}

$adGUIDs = $adUsers + $adComputers | ForEach-Object {
    [PSCustomObject]@{
        Name = $_.Name
        GUID = $_.ObjectGUID
        Base64GUID = Convert-GUIDToBase64 $_.ObjectGUID
        Type = ($_ -is [Microsoft.ActiveDirectory.Management.ADUser]) ? "User" : "Computer"
    }
}

Connect-MgGraph -Scopes "Directory.Read.All"

$aadObjects = Get-MgUser -All | Where-Object { $_.OnPremisesImmutableId } | Select-Object DisplayName, OnPremisesImmutableId, Id

$notSyncedToAAD = $adGUIDs | Where-Object {
    $_.Base64GUID -notin $aadObjects.OnPremisesImmutableId
}

$orphanedInAAD = $aadObjects | Where-Object {
    $_.OnPremisesImmutableId -notin $adGUIDs.Base64GUID
}

$adUsers | Export-Csv "$OutDir\InactiveADUsers.csv" -NoTypeInformation
$adComputers | Export-Csv "$OutDir\InactiveADComputers.csv" -NoTypeInformation
$notSyncedToAAD | Export-Csv "$OutDir\NotSyncedToAAD.csv" -NoTypeInformation
$orphanedInAAD | Export-Csv "$OutDir\OrphanedInAAD.csv" -NoTypeInformation

$summary = @"
# Hybrid AD Health Check Summary

**Inactive AD Users**: $($adUsers.Count)  
**Inactive AD Computers**: $($adComputers.Count)  
**Not Synced to AAD**: $($notSyncedToAAD.Count)  
**Orphaned in AAD**: $($orphanedInAAD.Count)

CSV files saved in: `$OutDir
"@

$summary | Out-File "$OutDir\Summary.md"

Write-Host "Health Check completed. Results saved in: $OutDir"
