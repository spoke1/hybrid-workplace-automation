<#
.SYNOPSIS
    Exports an Intune (Microsoft Endpoint Manager) device compliance snapshot
    including BitLocker state, Last Check-in, OS version and UPN.

.DESCRIPTION
    Uses Microsoft Graph (beta profile for richer device properties).
    Outputs CSV + a small Markdown summary.

.REQUIREMENTS
    - Microsoft Graph PowerShell SDK
    - Scopes: DeviceManagementManagedDevices.Read.All, Directory.Read.All

.NOTES
    Author : Ramón Lotz
    Version: 1.0
#>

[CmdletBinding()]
param(
    [string]$OutDir = ".\output\compliance",
    [switch]$OpenFolder
)

# Ensure module
if (-not (Get-Module Microsoft.Graph -ListAvailable)) {
    Install-Module Microsoft.Graph -Scope CurrentUser -Force
}
Import-Module Microsoft.Graph

# Connect
$scopes = @(
    "DeviceManagementManagedDevices.Read.All",
    "Directory.Read.All"
)
Write-Host "▶ Connecting to Microsoft Graph..."
Connect-MgGraph -Scopes $scopes | Out-Null

# Beta for managedDevice extended props
Select-MgProfile -Name beta

# Output prep
$null = New-Item -ItemType Directory -Force -Path $OutDir
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$csvPath = Join-Path $OutDir "HW_Compliance_$ts.csv"
$mdPath  = Join-Path $OutDir "HW_Compliance_$ts.md"

Write-Host "▶ Querying Intune managed devices..."
# Pull all devices (pagination handled by -All)
$devices = Get-MgBetaDeviceManagementManagedDevice -All

if (-not $devices) {
    Write-Warning "No managed devices returned."
    return
}

# Normalize & select interesting fields
$rows = foreach ($d in $devices) {
    # Some tenants expose encryption as 'encryptionState' (enum) – fall back gracefully
    $enc = $null
    try { $enc = $d.encryptionState } catch {}
    if (-not $enc) { try { $enc = $d.isEncrypted ? "encrypted" : "notEncrypted" } catch {} }

    [pscustomobject]@{
        DeviceName        = $d.deviceName
        UPN               = $d.userPrincipalName
        ComplianceState   = $d.complianceState
        OS                = $d.operatingSystem
        OSVersion         = $d.osVersion
        ManagementAgent   = $d.managementAgent
        LastCheckIn       = $d.lastSyncDateTime
        AzureAdDeviceId   = $d.azureAdDeviceId
        BitLocker         = $enc
        JailBroken        = $d.jailBroken
        DeviceEnrollment  = $d.deviceEnrollmentType
        SerialNumber      = $d.serialNumber
        Manufacturer      = $d.manufacturer
        Model             = $d.model
    }
}

# Save CSV
$rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Host "✅ CSV written to $csvPath"

# Markdown summary
$total          = $rows.Count
$compliantCount = ($rows | Where-Object { $_.ComplianceState -eq 'compliant' }).Count
$nonCompliant   = $total - $compliantCount
$encrypted      = ($rows | Where-Object { $_.BitLocker -match 'encrypted' }).Count

$md = @()
$md += "# Hybrid Workplace – Compliance Snapshot"
$md += ""
$md += "> Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
$md += ""
$md += "- **Total devices:** $total"
$md += "- **Compliant:** $compliantCount"
$md += "- **Non-compliant:** $nonCompliant"
$md += "- **BitLocker encrypted (reported):** $encrypted"
$md += ""
$md | Out-File -FilePath $mdPath -Encoding UTF8
Write-Host "✅ Summary written to $mdPath"

if ($OpenFolder) { Invoke-Item $OutDir }
