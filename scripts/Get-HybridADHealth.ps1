<#
.SYNOPSIS
  Hybrid AD Health Check: findet verwaiste / inaktive Konten in On-Prem AD
  und vergleicht sie mit Entra ID (Azure AD) für Sync-Drift.

.DESCRIPTION
  - On-Prem AD:
      * Nutzer & Computer mit letztem Logon > X Tage (oder nie)
      * Disabled-Status, Erstellung, Änderung, OU, OS (für Computer)
  - Entra ID:
      * Vergleich via onPremisesImmutableId (Base64(objectGUID))
      * AD-Objekte, die NICHT in Entra existieren (NotSyncedToAAD)
      * AAD-Objekte, deren Quelle OnPrem ist, aber im AD NICHT mehr existieren (OrphanedInAAD)

.OUTPUTS
  CSVs + Markdown Summary im OutDir.

.REQUIREMENTS
  - Windows, Domänen-joined Admin-Host
  - RSAT ActiveDirectory Modul (Get-ADUser/Get-ADComputer)
  - Microsoft Graph PowerShell SDK
  - Graph Scopes: Directory.Read.All

.NOTES
  Author : Ramón Lotz
  Version: 1.0
#>
Write-Host "Starting script execution at $(Get-Date -Format 'u')" -ForegroundColor Cyan

[CmdletBinding()]
param(
  [string]$OutDir = ".\output\hybrid-ad-health",
  [int]$StaleDaysUsers = 90,
  [int]$StaleDaysComputers = 60,
  [switch]$OpenFolder
)

function Assert-Module {
  param([string]$Name)
  if (-not (Get-Module -ListAvailable -Name $Name)) {
    Write-Host "Installing module: $Name ..."
    Install-Module $Name -Scope CurrentUser -Force -ErrorAction Stop
  }
  Import-Module $Name -ErrorAction Stop
}

function Convert-ObjectGuidToImmutableId {
  param([Guid]$Guid)
  # onPremisesImmutableId ist Base64(objectGUID bytes, little-endian)
  $bytes = $Guid.ToByteArray()
  return [System.Convert]::ToBase64String($bytes)
}

# --- Prep
$null = New-Item -ItemType Directory -Force -Path $OutDir
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$usersCsv     = Join-Path $OutDir "AD_Users_Stale_$ts.csv"
$computersCsv = Join-Path $OutDir "AD_Computers_Stale_$ts.csv"
$notSyncedCsv = Join-Path $OutDir "Drift_AD_NotSyncedToAAD_$ts.csv"
$orphanedCsv  = Join-Path $OutDir "Drift_AAD_Orphaned_$ts.csv"
$mdPath       = Join-Path $OutDir "HybridADHealth_Summary_$ts.md"

# --- Modules
Assert-Module -Name ActiveDirectory
if (-not (Get-Module Microsoft.Graph -ListAvailable)) {
  Install-Module Microsoft.Graph -Scope CurrentUser -Force
}
Import-Module Microsoft.Graph

# --- Connect Graph
$scopes = @("Directory.Read.All")
Write-Host "▶ Connecting to Microsoft Graph..."
Connect-MgGraph -Scopes $scopes | Out-Null
Select-MgProfile -Name beta

# --- Helper: lastLogonTimestamp -> DateTime
function Get-LastLogonDate {
  param($llt)
  if ($null -eq $llt -or $llt -eq 0) { return $null }
  try { return [DateTime]::FromFileTime($llt) } catch { return $null }
}

$cutUsers = (Get-Date).AddDays(-$StaleDaysUsers)
$cutComps = (Get-Date).AddDays(-$StaleDaysComputers)

Write-Host "▶ Querying Active Directory (users & computers)..."

# --- AD Users
$adUsers = Get-ADUser -Filter * -Properties DisplayName,mail,Enabled,objectGUID,whenCreated,whenChanged,pwdLastSet,lastLogonTimestamp,DistinguishedName |
  Select-Object SamAccountName,DisplayName,mail,Enabled,objectGUID,whenCreated,whenChanged,pwdLastSet,lastLogonTimestamp,DistinguishedName

$adUserRows = foreach ($u in $adUsers) {
  $lastLogon = Get-LastLogonDate $u.lastLogonTimestamp
  $pwdSet    = if ($u.pwdLastSet) { [DateTime]::FromFileTime($u.pwdLastSet) } else { $null }
  $ou        = ($u.DistinguishedName -split ',(?=OU=)')[0] # schneller OU-Griff

  [pscustomobject]@{
    Type            = 'User'
    SamAccountName  = $u.SamAccountName
    DisplayName     = $u.DisplayName
    Mail            = $u.mail
    Enabled         = $u.Enabled
    WhenCreated     = $u.whenCreated
    WhenChanged     = $u.whenChanged
    LastLogon       = $lastLogon
    PwdLastSet      = $pwdSet
    OU              = $ou
    ObjectGUID      = $u.objectGUID
    ImmutableIdB64  = Convert-ObjectGuidToImmutableId $u.objectGUID
    IsStale         = ($null -eq $lastLogon -or $lastLogon -lt $cutUsers)
  }
}

# --- AD Computers
$adComps = Get-ADComputer -Filter * -Properties DNSHostName,Enabled,objectGUID,whenCreated,whenChanged,lastLogonTimestamp,OperatingSystem,DistinguishedName |
  Select-Object Name,DNSHostName,Enabled,objectGUID,whenCreated,whenChanged,lastLogonTimestamp,OperatingSystem,DistinguishedName

$adCompRows = foreach ($c in $adComps) {
  $lastLogon = Get-LastLogonDate $c.lastLogonTimestamp
  $ou        = ($c.DistinguishedName -split ',(?=OU=)')[0]

  [pscustomobject]@{
    Type            = 'Computer'
    Name            = $c.Name
    DNSHostName     = $c.DNSHostName
    OS              = $c.OperatingSystem
    Enabled         = $c.Enabled
    WhenCreated     = $c.whenCreated
    WhenChanged     = $c.whenChanged
    LastLogon       = $lastLogon
    OU              = $ou
    ObjectGUID      = $c.objectGUID
    ImmutableIdB64  = Convert-ObjectGuidToImmutableId $c.objectGUID
    IsStale         = ($null -eq $lastLogon -or $lastLogon -lt $cutComps)
  }
}

# --- Export stale sets
$adUserRows | Where-Object IsStale | Export-Csv -Path $usersCsv -NoTypeInformation -Encoding UTF8
$adCompRows | Where-Object IsStale | Export-Csv -Path $computersCsv -NoTypeInformation -Encoding UTF8
Write-Host "✅ Exported stale users -> $usersCsv"
Write-Host "✅ Exported stale computers -> $computersCsv"

# --- Build lookup sets for drift compare
$adUserIds  = [System.Collections.Generic.HashSet[string]]::new()
$adCompIds  = [System.Collections.Generic.HashSet[string]]::new()
$adUserRows.ImmutableIdB64  | ForEach-Object { if ($_){ $null = $adUserIds.Add($_) } }
$adCompRows.ImmutableIdB64  | ForEach-Object { if ($_){ $null = $adCompIds.Add($_) } }

# --- AAD Users (only those with on-prem source/immutable)
Write-Host "▶ Querying Entra ID (users/devices) ..."
$aadUsers = Get-MgUser -All -ConsistencyLevel eventual -CountVariable cc `
  -Property id,displayName,userPrincipalName,onPremisesImmutableId,onPremisesSyncEnabled,accountEnabled

# Some tenants represent hybrid devices as "devices" rather than users; include both:
$aadDevices = Get-MgDevice -All -Property id,displayName,deviceId,onPremisesSyncEnabled,onPremisesSecurityIdentifier,accountEnabled

# --- Drift: AD Not Synced to AAD (present in AD, missing in AAD)
$aadUserIdSet = [System.Collections.Generic.HashSet[string]]::new()
$aadUsers | ForEach-Object {
  if ($_.onPremisesImmutableId) { $null = $aadUserIdSet.Add($_.onPremisesImmutableId) }
}
$notSyncedUsers = $adUserRows | Where-Object { $_.ImmutableIdB64 -and -not $aadUserIdSet.Contains($_.ImmutableIdB64) }

# Computer drift via devices is trickier (no guaranteed immutable match). Best effort:
# Often devices carry onPremisesSecurityIdentifier rather than immutableId; we report only users robustly.
# Optional: you could compare by DNSHostName vs device displayName (not reliable). Here we keep it clean.

$notSyncedUsers | Export-Csv -Path $notSyncedCsv -NoTypeInformation -Encoding UTF8
Write-Host "✅ Exported AD->AAD not-synced users -> $notSyncedCsv"

# --- Drift: Orphaned in AAD (AAD indicates onPrem sync but AD object is gone)
$orphanedUsers = $aadUsers | Where-Object {
  $_.onPremisesSyncEnabled -eq $true -and $_.onPremisesImmutableId -and -not $adUserIds.Contains($_.onPremisesImmutableId)
} | Select-Object displayName,userPrincipalName,onPremisesImmutableId,accountEnabled

$orphanedUsers | Export-Csv -Path $orphanedCsv -NoTypeInformation -Encoding UTF8
Write-Host "✅ Exported AAD orphaned users -> $orphanedCsv"

# --- Summary
$totalUsers      = $adUserRows.Count
$totalComps      = $adCompRows.Count
$staleUsers      = ($adUserRows | Where-Object IsStale).Count
$staleComps      = ($adCompRows | Where-Object IsStale).Count
$disabledUsers   = ($adUserRows | Where-Object { -not $_.Enabled }).Count
$disabledComps   = ($adCompRows | Where-Object { -not $_.Enabled }).Count
$notSyncedCount  = ($notSyncedUsers).Count
$orphanedCount   = ($orphanedUsers).Count

$md = @()
$md += "# Hybrid AD Health – Summary"
$md += ""
$md += "> Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
$md += ""
$md += "## AD Inventory"
$md += "- Users: **$totalUsers** (stale: $staleUsers, disabled: $disabledUsers)"
$md += "- Computers: **$totalComps** (stale: $staleComps, disabled: $disabledComps)"
$md += ""
$md += "## Sync Drift"
$md += "- AD users **not synced to AAD**: **$notSyncedCount**"
$md += "- AAD users **orphaned (onPrem sync enabled, missing in AD)**: **$orphanedCount**"
$md | Out-File -FilePath $mdPath -Encoding UTF8

Write-Host ""
Write-Host "   Done."
Write-Host "   Stale users      : $usersCsv"
Write-Host "   Stale computers  : $computersCsv"
Write-Host "   Not synced (users): $notSyncedCsv"
Write-Host "   Orphaned in AAD  : $orphanedCsv"
Write-Host "   Summary MD       : $mdPath"
Write-Host "   Script completed successfully 🎯" -ForegroundColor Green


if ($OpenFolder) { Invoke-Item $OutDir }
