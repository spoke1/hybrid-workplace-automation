# Hybrid Workplace Automation 🌍

Practical scripts and tools to automate and secure the hybrid workplace.
Focus: bridging on-prem Active Directory, Intune, and Microsoft Entra ID.

## Highlights
- 🧱 Hybrid AD Health Check → Detect stale accounts and sync drift
- 💻 Autopilot Pre-Staging → Prepare devices for remote provisioning
- 🔒 Compliance Export → Intune device compliance + BitLocker status
- ☁️ Conditional Access Insights → Identify risky sign-ins & device gaps

## 🔄 Roadmap – October 2025

- [x] Compliance Export Module (Intune)
- [x] Hybrid AD Health Check
- [ ] Autopilot Pre-Staging (coming soon)
- [ ] Conditional Access Insights

## Documentation
- [Compliance Export – usage](docs/ComplianceExport.md)
- [HybridADHealth Check](docs/HybridADHealth.md)

## Goal
Empower IT architects and security engineers to manage hybrid environments efficiently, securely, and at scale.

## 🧠 How to connect to Microsoft Graph & Active Directory

Before running any Hybrid Workplace scripts, make sure you can connect to both:
- **Microsoft Entra ID (Graph)**
- **On-prem Active Directory**

### 1️⃣ Install required modules
```powershell
# Microsoft Graph PowerShell SDK
Install-Module Microsoft.Graph -Scope CurrentUser

# (Optional) Active Directory RSAT tools
# Windows Server:
Install-WindowsFeature RSAT-AD-PowerShell
# Windows 10/11:
Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0

# Authenticate with your Entra ID tenant
Connect-MgGraph -Scopes "Directory.Read.All"

# Optional: switch to beta profile (for Intune / device properties)
Select-MgProfile -Name beta

# Test the connection
Get-MgUser -Top 5 | Select DisplayName, UserPrincipalName

# Import AD module and verify connectivity
Import-Module ActiveDirectory
Get-ADUser -Top 1 | Select SamAccountName, Enabled

