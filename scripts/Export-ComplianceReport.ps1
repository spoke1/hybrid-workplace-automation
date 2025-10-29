<#
.SYNOPSIS
    Exports an Intune (Microsoft Endpoint Manager) device compliance snapshot
    including BitLocker state, Last Check-in, OS version, and UPN.

.DESCRIPTION
    Uses Microsoft Graph (Beta profile for richer device properties).
    Produces a CSV and a small Markdown summary.

.REQUIREMENTS
    - Microsoft Graph PowerShell SDK
    - Scopes (default): DeviceManagementManagedDevices.Read.All, Directory.Read.All
    - Optional (for Encryption Report): DeviceManagementConfiguration.Read.All

.NOTES
    Author : Ramón Lotz
    Version: 1.0
#>

[CmdletBinding()]
param(
    # Target folder for output files
    [Parameter(Position=0)]
    [string]$OutputFolder = (Join-Path -Path (Get-Location) -ChildPath "out"),

    # Use the official Encryption Report (requires DeviceManagementConfiguration.Read.All)
    [switch]$UseEncryptionReport,

    # Optionally restrict to specific OS types (e.g., "Windows","macOS","iOS","Android")
    [string[]]$IncludeOs = @()
)

#region Helpers
function Ensure-Module {
    param([string]$Name)
    if (-not (Get-Module -ListAvailable -Name $Name)) {
        Write-Verbose "Installing module '$Name' ..."
        Install-Module $Name -Scope CurrentUser -Force -ErrorAction Stop
    }
}

function Connect-GraphIfNeeded {
    param([string[]]$Scopes)

    try {
        $needConnect = $true
        try { $ctx = Get-MgContext -ErrorAction Stop } catch { $ctx = $null }

        if ($ctx) {
            $missing = @()
            foreach ($s in $Scopes) {
                if ($ctx.Scopes -notcontains $s) { $missing += $s }
            }
            if ($missing.Count -eq 0) {
                $needConnect = $false
            } else {
                Disconnect-MgGraph -ErrorAction SilentlyContinue
            }
        }

        if ($needConnect) {
            Write-Host "Connecting to Microsoft Graph ..." -ForegroundColor Cyan
            Connect-MgGraph -Scopes $Scopes -ErrorAction Stop | Out-Null
        }

        # Use the Beta profile for richer properties and the encryption report endpoints
        Select-MgProfile -Name "beta"
    }
    catch {
        throw "Failed to connect to Microsoft Graph: $($_.Exception.Message)"
    }
}

function New-OutputFiles {
    param([string]$Folder)

    if (-not (Test-Path -LiteralPath $Folder)) {
        New-Item -ItemType Directory -Path $Folder | Out-Null
    }
    $stamp = Get-Date -Format "yyyy-MM-dd_HH-mm"
    [PSCustomObject]@{
        CsvPath     = Join-Path $Folder "Intune-Compliance-Snapshot_${stamp}.csv"
        MdPath      = Join-Path $Folder "Intune-Compliance-Snapshot_SUMMARY_${stamp}.md"
        TimeStamp   = $stamp
    }
}

function NullOrEmpty {
    param($Value)
    if ($null -eq $Value) { return $true }
    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace([string]$Value)) { return $true }
    return $false
}

function Get-EncryptionStates {
    <#
        Tries the non-beta cmdlet name first (available when using Select-MgProfile beta with newer SDK),
        and falls back to the beta module cmdlet if needed.
    #>
    param(
        [string[]]$Property = @("deviceName","userPrincipalName","encryptionState","advancedBitLockerStates")
    )

    $cmd = Get-Command -Name Get-MgDeviceManagementManagedDeviceEncryptionState -ErrorAction SilentlyContinue
    if ($cmd) {
        return Get-MgDeviceManagementManagedDeviceEncryptionState -All -Property ($Property -join ",") -ErrorAction Stop
    }

    # Fallback to Beta module
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Beta.DeviceManagement)) {
        Ensure-Module -Name Microsoft.Graph.Beta.DeviceManagement
    }
    Import-Module Microsoft.Graph.Beta.DeviceManagement -ErrorAction Stop

    $betaCmd = Get-Command -Name Get-MgBetaDeviceManagementManagedDeviceEncryptionState -ErrorAction SilentlyContinue
    if (-not $betaCmd) {
        throw "Neither 'Get-MgDeviceManagementManagedDeviceEncryptionState' nor 'Get-MgBetaDeviceManagementManagedDeviceEncryptionState' is available."
    }

    return Get-MgBetaDeviceManagementManagedDeviceEncryptionState -All -Property ($Property -join ",") -ErrorAction Stop
}
#endregion Helpers

#region Main
try {
    # 1) Ensure modules / import
    Ensure-Module -Name Microsoft.Graph
    Import-Module Microsoft.Graph -ErrorAction Stop
    Import-Module Microsoft.Graph.DeviceManagement -ErrorAction Stop

    # 2) Compose scopes
    $requiredScopes = @(
        "DeviceManagementManagedDevices.Read.All",
        "Directory.Read.All"
    )
    if ($UseEncryptionReport) {
        $requiredScopes += "DeviceManagementConfiguration.Read.All"  # for managedDeviceEncryptionState
    }

    # 3) Connect to Graph (Beta profile)
    Connect-GraphIfNeeded -Scopes $requiredScopes
    # 4) Retrieve managed devices (select only what we need)
    $selectProps = @(
        "id","deviceName","userPrincipalName","operatingSystem","osVersion",
        "lastSyncDateTime","complianceState","isEncrypted","managementAgent"
    )

    Write-Host "Loading Managed Devices from Intune/Graph ..." -ForegroundColor Cyan
    $allDevices = Get-MgDeviceManagementManagedDevice -All -Property ($selectProps -join ",") -ErrorAction Stop

    if ($IncludeOs -and $IncludeOs.Count -gt 0) {
        $devices = $allDevices | Where-Object { $_.OperatingSystem -in $IncludeOs }
    } else {
        $devices = $allDevices
    }

    # 5) Optional: load Encryption Report (more precise BitLocker/FileVault status)
    $encLookup = @{}
    if ($UseEncryptionReport) {
        Write-Host "Loading Encryption Report (managedDeviceEncryptionStates) ..." -ForegroundColor Cyan

        $encStates = Get-EncryptionStates -Property @(
            "deviceName","userPrincipalName","encryptionState","advancedBitLockerStates"
        )

        foreach ($r in $encStates) {
            $devName = if (NullOrEmpty $r.deviceName) { "" } else { [string]$r.deviceName }
            $upn     = if (NullOrEmpty $r.userPrincipalName) { "" } else { [string]$r.userPrincipalName }
            $k = ("{0}||{1}" -f $devName.ToLowerInvariant(), $upn.ToLowerInvariant())
            $encLookup[$k] = $r
        }
    }

    # 6) Shape rows for export
    $rows = foreach ($d in $devices) {
        $devName = if (NullOrEmpty $d.DeviceName) { "" } else { [string]$d.DeviceName }
        $upn     = if (NullOrEmpty $d.UserPrincipalName) { "" } else { [string]$d.UserPrincipalName }
        $key     = ("{0}||{1}" -f $devName.ToLowerInvariant(), $upn.ToLowerInvariant())

        $encState      = $null
        $advBitLocker  = $null
        $encryptedBool = $null

        if ($UseEncryptionReport -and $encLookup.ContainsKey($key)) {
            $encState     = $encLookup[$key].encryptionState      # 'encrypted' | 'notEncrypted'
            $advBitLocker = $encLookup[$key].advancedBitLockerStates
            if ($encState -eq "encrypted") { $encryptedBool = $true }
            elseif ($encState -eq "notEncrypted") { $encryptedBool = $false }
        } else {
            # Fallback: managedDevice.isEncrypted (Beta profile)
            if ($null -ne $d.isEncrypted) {
                $encryptedBool = [bool]$d.isEncrypted
                $encState = if ($encryptedBool) { "encrypted" } else { "notEncrypted" }
            } else {
                $encState = $null
            }
        }

        [PSCustomObject]@{
            DeviceId          = $d.Id
            DeviceName        = $devName
            UserPrincipalName = $upn
            OperatingSystem   = $d.OperatingSystem
            OsVersion         = $d.OsVersion
            LastCheckIn       = $d.LastSyncDateTime
            ComplianceState   = $d.ComplianceState
            Encrypted         = $encryptedBool
            EncryptionState   = $encState
            AdvancedBitLocker = $advBitLocker
            ManagementAgent   = $d.ManagementAgent
        }
    }

    # 7) Write files
    $out = New-OutputFiles -Folder $OutputFolder

    $rows | Sort-Object OperatingSystem, ComplianceState, DeviceName |
        Export-Csv -Path $out.CsvPath -NoTypeInformation -Encoding UTF8

    # 8) Markdown summary
    $total           = ($rows | Measure-Object).Count
    $byCompliance    = $rows | Group-Object ComplianceState | Sort-Object Count -Descending
    $winRows         = $rows | Where-Object { $_.OperatingSystem -match '^Windows' }
    $winEncrypted    = ($winRows | Where-Object { $_.Encrypted -eq $true } | Measure-Object).Count
    $winNotEncrypted = ($winRows | Where-Object { $_.Encrypted -eq $false } | Measure-Object).Count
    $staleThreshold  = (Get-Date).AddDays(-7)
    $staleDevices    = $rows | Where-Object { $_.LastCheckIn -lt $staleThreshold } | Sort-Object LastCheckIn

    $md = @()
    $md += "# Intune Device Compliance Snapshot"
    $md += ""
    $md += ("- Generated: {0}" -f $out.TimeStamp)
    $md += ("- Total devices: **{0}**" -f $total)
    $md += ""
    $md += "## Compliance status"

    foreach ($g in $byCompliance) {
        $name = if (NullOrEmpty $g.Name) { "(unknown)" } else { $g.Name }
        # Use -f to avoid interpolation issues with colon following a variable
        $md += ("- {0}: **{1}**" -f $name, $g.Count)
    }

    $md += ""
    $md += "## Encryption (Windows)"
    $md += ("- Encrypted: **{0}**" -f $winEncrypted)
    $md += ("- Not encrypted: **{0}**" -f $winNotEncrypted)
    $md += ""
    $md += "## Devices with stale check-in (> 7 days)"

    $staleCount = ($staleDevices | Measure-Object).Count
    if ($staleCount -gt 0) {
        $md += ""
        $md += "| DeviceName | UPN | Last Check-in | OS |"
        $md += "|---|---|---:|---|"
        foreach ($s in ($staleDevices | Select-Object -First 10)) {
            $ln = if ($s.LastCheckIn) { [string]::Format("{0:yyyy-MM-dd HH:mm}", $s.LastCheckIn) } else { "" }
            $md += ("| {0} | {1} | {2} | {3} |" -f $s.DeviceName, $s.UserPrincipalName, $ln, $s.OperatingSystem)
        }
        if ($staleCount -gt 10) {
            $md += ""
            $md += "_… more entries in the CSV_"
        }
    } else {
        $md += "- No devices older than 7 days."
    }

    $md -join "`r`n" | Out-File -FilePath $out.MdPath -Encoding UTF8
    Write-Host ""
    Write-Host "Snapshot created successfully:" -ForegroundColor Green
    Write-Host ("   CSV: {0}" -f $out.CsvPath)
    Write-Host ("   MD : {0}" -f $out.MdPath)
}
catch {
    Write-Error $_
    exit 1
}
#endregion Main
