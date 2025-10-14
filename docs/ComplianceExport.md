# Compliance Export (Hybrid Workplace)

Exports an Intune managed devices snapshot with **ComplianceState**, **BitLocker**, **Last Check-in**, **OS** and **UPN**.

## Requirements
- PowerShell 7+
- Microsoft Graph PowerShell SDK
- Scopes: `DeviceManagementManagedDevices.Read.All`, `Directory.Read.All`

Install SDK (once):
```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
