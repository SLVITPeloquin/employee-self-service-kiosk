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
    if (-not [string]::IsNullOrWhiteSpace($env:KIOSK_USER)) {
        $KioskUser = $env:KIOSK_USER
    } else {
        $prompt = Read-Host "Enter the local kiosk username [Press Enter for default: KioskUser]"
        if ([string]::IsNullOrWhiteSpace($prompt)) {
            $KioskUser = 'KioskUser'
        } else {
            $KioskUser = $prompt.Trim()
        }
    }
}
if ([string]::IsNullOrWhiteSpace($KioskUser)) {
    $KioskUser = 'KioskUser'
}

# Staging directory
$tempDir = Join-Path -Path $env:TEMP -ChildPath ("kiosk-install-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$null = New-Item -Path $tempDir -ItemType Directory -Force

$baseUrl = "https://raw.githubusercontent.com/SLVITPeloquin/employee-self-service-kiosk/main"
$files = @("index.html", "Setup.ps1", "Check-Configuration.ps1")

try {
    Write-Host "Downloading latest kiosk files from GitHub..." -ForegroundColor Cyan
    $cacheBuster = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    foreach ($file in $files) {
        $fileUrl = "$baseUrl/$file`?v=$cacheBuster"
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
