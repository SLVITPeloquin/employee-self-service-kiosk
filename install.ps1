<#
.SYNOPSIS
    One-line bootstrap installer for Employee Self-Service Kiosk.

.DESCRIPTION
    Downloads the latest release files directly from GitHub and executes Setup.ps1.
    Usage:
        irm https://raw.githubusercontent.com/SLVITPeloquin/employee-self-service-kiosk/main/install.ps1 | iex
        or
        & ([scriptblock]::Create((irm https://raw.githubusercontent.com/SLVITPeloquin/employee-self-service-kiosk/main/install.ps1))) -KioskUser 'KioskUser'
#>
[CmdletBinding()]
param(
    [ValidateSet('Inspect', 'Install', 'Restore')]
    [string]$Mode = 'Install',

    [string]$KioskUser,

    [string]$SelectorUrl = 'file:///C:/ProgramData/EmployeeKiosk/index.html'
)

$ErrorActionPreference = 'Stop'
try {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue
} catch {}


Write-Host "`n=== Employee Self-Service Kiosk Online Installer ===" -ForegroundColor Cyan

# Check for elevation if running Install or Restore
function Test-IsAdminElevated {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

if ($Mode -in @('Install', 'Restore') -and -not (Test-IsAdminElevated)) {
    Write-Error "This installer requires an elevated administrator PowerShell session. Please re-run PowerShell as Administrator."
    return
}

# Determine KioskUser if installing
if ($Mode -eq 'Install' -and [string]::IsNullOrWhiteSpace($KioskUser)) {
    # Check environment variable
    if (-not [string]::IsNullOrWhiteSpace($env:KIOSK_USER)) {
        $KioskUser = $env:KIOSK_USER
    } else {
        # Try auto-detecting from existing Assigned Access cmdlet if available
        $detectedUser = $null
        try {
            if (Get-Command -Name Get-AssignedAccess -ErrorAction SilentlyContinue) {
                $aa = Get-AssignedAccess -ErrorAction SilentlyContinue
                if ($aa -and $aa.UserName) {
                    $detectedUser = $aa.UserName.Split('\')[-1]
                }
            }
        } catch {}

        if (-not [string]::IsNullOrWhiteSpace($detectedUser)) {
            $prompt = Read-Host "Detected existing kiosk account '$detectedUser'. Use this account? (Y/n or enter custom account)"
            if ([string]::IsNullOrWhiteSpace($prompt) -or $prompt -ieq 'y' -or $prompt -ieq 'yes') {
                $KioskUser = $detectedUser
            } else {
                $KioskUser = $prompt.Trim()
            }
        } else {
            # Check for common local standard accounts or prompt
            $KioskUser = Read-Host "Enter the local kiosk username to configure (e.g. KioskUser)"
        }
    }
}
# Ensure KioskUser exists, or offer to create it
if ($Mode -eq 'Install' -and -not [string]::IsNullOrWhiteSpace($KioskUser)) {
    $userExists = $false
    try {
        $localU = Get-LocalUser -Name $KioskUser -ErrorAction SilentlyContinue
        if ($null -ne $localU) { $userExists = $true }
    } catch {}

    if (-not $userExists) {
        $netCheck = cmd.exe /c "net user `"$KioskUser`"" 2>&1
        if ($LASTEXITCODE -eq 0) { $userExists = $true }
    }

    if (-not $userExists) {
        $createPrompt = Read-Host "Local user account '$KioskUser' was not found. Create it now as a local standard kiosk account with no password? (Y/n)"
        if ([string]::IsNullOrWhiteSpace($createPrompt) -or $createPrompt -ieq 'y' -or $createPrompt -ieq 'yes') {
            Write-Host "Creating local standard user '$KioskUser'..." -ForegroundColor Cyan
            $null = cmd.exe /c "net user `"$KioskUser`" `"`" /add /comment:`"Employee Kiosk User`""
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to create local user account '$KioskUser'."
            }
            Write-Host "Local account '$KioskUser' created successfully." -ForegroundColor Green
        } else {
            Write-Error "Cannot proceed without a valid local standard user account."
            return
        }
    }
}


if ($Mode -eq 'Install' -and [string]::IsNullOrWhiteSpace($KioskUser)) {
    Write-Error "A local kiosk user account must be specified to complete installation."
    return
}

# Staging directory
$tempDir = Join-Path -Path $env:TEMP -ChildPath ("kiosk-install-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$null = New-Item -Path $tempDir -ItemType Directory -Force

$baseUrl = "https://raw.githubusercontent.com/SLVITPeloquin/employee-self-service-kiosk/main"
$files = @("index.html", "Setup.ps1", "Check-Configuration.ps1")

try {
    Write-Host "Downloading latest kiosk files from GitHub..." -ForegroundColor Cyan
    foreach ($file in $files) {
        $fileUrl = "$baseUrl/$file"
        $destPath = Join-Path -Path $tempDir -ChildPath $file
        Invoke-WebRequest -Uri $fileUrl -OutFile $destPath -UseBasicParsing
        Write-Host "  Downloaded $file" -ForegroundColor Green
    }

    $setupScript = Join-Path -Path $tempDir -ChildPath "Setup.ps1"
    $checkScript = Join-Path -Path $tempDir -ChildPath "Check-Configuration.ps1"

    if ($Mode -eq 'Install') {
        Write-Host "`nRunning pre-installation configuration check..." -ForegroundColor Cyan
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$checkScript"
        if ($LASTEXITCODE -ne 0) {
            throw "Pre-installation configuration checks failed."
        }
        Write-Host "Pre-installation checks passed.`n" -ForegroundColor Green

        Write-Host "Executing Setup.ps1 -Mode Install -KioskUser '$KioskUser'..." -ForegroundColor Cyan
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$setupScript" -Mode Install -KioskUser $KioskUser -SelectorUrl $SelectorUrl
    } elseif ($Mode -eq 'Inspect') {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$setupScript" -Mode Inspect
    } elseif ($Mode -eq 'Restore') {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$setupScript" -Mode Restore
    }
} finally {
    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
