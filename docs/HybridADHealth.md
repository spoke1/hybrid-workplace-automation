# Hybrid AD Health Check

Detects stale or disabled accounts in on-prem Active Directory and checks **sync drift** against Microsoft Entra ID.

## What it does
- **AD Users & Computers**
  - stale if `lastLogonTimestamp` is older than threshold (or never logged on)
  - includes `Enabled`, `OU`, `WhenCreated`, `WhenChanged`, `OS` (for computers)
- **Drift**
  - **Not synced to AAD**: present in AD but missing in Entra (by `onPremisesImmutableId`)
  - **Orphaned in AAD**: Entra object claims on-prem sync but no matching AD object

## Requirements
- Windows host joined to the domain
- RSAT ActiveDirectory module
- Microsoft Graph PowerShell SDK
- Graph scopes: `Directory.Read.All`

Install modules (once):
```powershell
Install-WindowsFeature RSAT-AD-PowerShell -IncludeAllSubFeature # on server
# or enable RSAT AD tools on Windows 10/11 via Features
Install-Module Microsoft.Graph -Scope CurrentUser
