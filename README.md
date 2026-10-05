# Employee Self-Service Kiosk

Dedicated multi-selector kiosk solution for shared employee benefit and HR portals on Windows PCs.

Built on native **Windows Assigned Access (Single-App Kiosk)** and **Microsoft Edge Public-Browsing Mode**. No custom browser wrapper or resident background services required.

---

## Included Portals

The selector displays the portals in the following order:

1. **Team Sahara** — `https://www.teamsaharalv.com/`
2. **The Source (PlanSource)** — `https://thesource.plansource.com/meruelogroup`
3. **UKG (Kronos)** — `https://lasvegasresort.prd.mykronos.com/`

---

## Security & Session Architecture

- **Automatic Inactivity Reset:** Microsoft Edge runs with `--kiosk-idle-timeout-minutes=2` in InPrivate mode. After 2 minutes without user input, Edge closes all tabs, purges session cookies and cache, and Windows Assigned Access automatically relaunches Edge at the clean selector screen.
- **Manual End Session:** Users can click Edge's native **End session** button at any time to immediately close all tabs and return to the selector.
- **View-Only Lockdown:** Mandatory machine policies (`HKLM\SOFTWARE\Policies\Microsoft\Edge`) enforce:
  - `KioskAddressBarEditingEnabled = 0` (address bar locked)
  - `DownloadRestrictions = 3` (blocks all file downloads)
  - `PrintingEnabled = 0` (blocks printing and Print to PDF)
  - `AllowFileSelectionDialogs = 0` (blocks Open/Save/Upload file dialogs)
- **Account & Sign-in Preservation:** Setup preserves existing local standard kiosk accounts, auto-logon credentials, and breakout keys without collecting passwords or recreating accounts.

---

## Files in this Repository

| File | Description |
|---|---|
| `install.ps1` | One-line bootstrap script that downloads the bundle and runs pre-flight checks and installation. |
| `index.html` | Self-contained static selector page (inline CSS, system fonts, high-contrast accessible buttons, visible session instructions). Staged to `C:\ProgramData\EmployeeKiosk\index.html`. |
| `Setup.ps1` | PowerShell 5.1 administrator script supporting `Inspect`, `Install`, and `Restore` workflows via `MDM_AssignedAccess` WMI Bridge. |
| `Check-Configuration.ps1` | Self-contained regression test verifying XML preservation invariants, argument injection, and error handling. |

---

## One-Line PowerShell Installation (Recommended)

Open an elevated PowerShell prompt (**Run as Administrator**) on the kiosk PC and run:
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force; irm https://raw.githubusercontent.com/SLVITPeloquin/employee-self-service-kiosk/main/install.ps1 | iex
```
The script will automatically run pre-flight checks, download the required files to a temporary staging folder, prompt for or auto-detect your existing local kiosk account, configure Windows Assigned Access, apply Edge lockdown policies, and clean up the temporary files.

### Non-Interactive / Scripted Usage

Pass the local kiosk username directly:
```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/SLVITPeloquin/employee-self-service-kiosk/main/install.ps1))) -KioskUser 'KioskUser'
```

Run a read-only pre-flight inspection without modifying anything:
```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/SLVITPeloquin/employee-self-service-kiosk/main/install.ps1))) -Mode Inspect
```

Revert to the original pre-installation setup:
```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/SLVITPeloquin/employee-self-service-kiosk/main/install.ps1))) -Mode Restore
```

---

## Prerequisites

1. **Operating System:** Windows 10/11 Pro, Enterprise, Education, or IoT Enterprise with User Account Control (UAC) enabled (`EnableLUA = 1`).
2. **Kiosk Account:** An existing local standard user account (e.g. `KioskUser`). The account must **not** be a member of the local Administrators group.
3. **Microsoft Edge:** Edge Stable Channel installed in standard Program Files paths.
4. **Permissions:** An elevated administrator PowerShell prompt to execute `Setup.ps1`.

---

## Installation Instructions

### Step 1: Pre-flight Inspection

Extract or clone this repository onto the kiosk PC, open an elevated PowerShell prompt as Administrator, and run:

```powershell
powershell.exe -NoProfile -File .\Setup.ps1 -Mode Inspect
```

This inspects the environment and reports:
- Windows edition, build number, and UAC state.
- Installed Microsoft Edge path and version.
- Current Edge registry policies in HKLM.
- Existing Windows Assigned Access configuration (modern XML or legacy JSON) and mapped accounts.

### Step 2: Run Configuration Regression Tests

Before modifying any machine state, verify the XML engine in memory:

```powershell
powershell.exe -NoProfile -File .\Check-Configuration.ps1
```

All tests should pass, confirming that account mappings, GUIDs, and unrelated profiles are preserved.

### Step 3: Install the Kiosk Bundle

Run the installation by specifying your existing local standard kiosk user:

```powershell
powershell.exe -NoProfile -File .\Setup.ps1 -Mode Install -KioskUser '<your-kiosk-account-name>'
```

Example:
```powershell
powershell.exe -NoProfile -File .\Setup.ps1 -Mode Install -KioskUser 'KioskUser'
```

#### What the installer does:
1. Validates the account exists, is standard (non-admin), and UAC is active.
2. Copies `index.html` to `C:\ProgramData\EmployeeKiosk\index.html`.
3. Creates a pre-install backup at `C:\ProgramData\EmployeeKiosk\Backup\backup.json` (preserves prior state).
4. Updates the single-app Assigned Access configuration in `MDM_AssignedAccess` to launch Edge with `--kiosk "file:///C:/ProgramData/EmployeeKiosk/index.html" --edge-kiosk-type=public-browsing --kiosk-idle-timeout-minutes=2 --no-first-run`.
5. Applies the four view-only registry policies in `HKLM\SOFTWARE\Policies\Microsoft\Edge`.
6. Performs readback verification to confirm the settings were accepted.

> **Optional Parameter:** If you host `index.html` on an internal HTTPS web server instead of a local file, pass `-SelectorUrl "https://intranet.example.com/kiosk/"`.

---

## Pilot Verification Checklist

After installation, sign out or restart the machine into the kiosk account to verify:

1. **Selector Screen:** Edge launches directly to the *Employee Resources* selector page displaying Team Sahara, The Source, and UKG in order.
2. **Tab Navigation:** Clicking a portal opens it in a new tab while keeping the selector tab available.
3. **Inactivity Timeout:** Leave an authenticated session idle for 2 minutes. Verify Edge automatically closes all tabs and relaunches clean at the selector.
4. **End Session Button:** Click the top-bar "End session" button in Edge. Verify all tabs close immediately and return to the selector.
5. **Session Discard:** Reopen the portal after a reset and confirm the previous employee is logged out (no cached session or form autofill).
6. **View-Only Restrictions:**
   - Attempt `Ctrl+P` or right-click print: printing must be disabled.
   - Attempt `Ctrl+S` or downloading documents: downloads and file dialogs must be blocked.
   - Attempt editing the address bar: URL input is read-only.

---

## Rollback / Restoration

To revert the PC back to its pre-installation kiosk configuration and restore original Edge policies:

```powershell
powershell.exe -NoProfile -File .\Setup.ps1 -Mode Restore
```

This reads `C:\ProgramData\EmployeeKiosk\Backup\backup.json`, restores original WMI Assigned Access configuration, and restores original Edge registry policies.
