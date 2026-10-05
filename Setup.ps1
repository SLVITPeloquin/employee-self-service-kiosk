<#
.SYNOPSIS
    Employee Kiosk setup bundle for Windows Assigned Access with Microsoft Edge.

.DESCRIPTION
    Manages a single-app Microsoft Edge public-browsing kiosk for employee benefit portals.
    Configures a 2-minute inactivity reset and applies view-only restrictions (no printing,
    no downloads, no file dialogs, locked address bar).

.PARAMETER Mode
    Execution mode: Inspect (default, read-only), Install (applies configuration), Restore (reverts from backup).

.PARAMETER KioskUser
    Name of the existing local standard user account used for kiosk mode. Required for Install.

.PARAMETER SelectorUrl
    URL launched by Edge kiosk mode. Defaults to local file:///C:/ProgramData/EmployeeKiosk/index.html.
#>
[CmdletBinding()]
param(
    [ValidateSet('Inspect', 'Install', 'Restore')]
    [string]$Mode = 'Inspect',

    [string]$KioskUser,

    [string]$SelectorUrl = 'file:///C:/ProgramData/EmployeeKiosk/index.html'
)

# ---------------------------------------------------------------------------
# Pure XML Transformation (callable independently for verification)
# ---------------------------------------------------------------------------
function Update-KioskXml {
    param(
        [Parameter(Mandatory = $true)]
        [xml]$Configuration,
        [Parameter(Mandatory = $true)]
        [string]$EdgePath,
        [Parameter(Mandatory = $true)]
        [string]$SelectorUrl
    )

    if ($null -eq $Configuration -or $null -eq $Configuration.DocumentElement) {
        throw "Invalid configuration XML document."
    }

    $v4Ns = "http://schemas.microsoft.com/AssignedAccess/2021/config"
    if (-not $Configuration.DocumentElement.HasAttribute("xmlns:v4")) {
        $nsAttr = $Configuration.CreateAttribute("xmlns", "v4", "http://www.w3.org/2000/xmlns/")
        $nsAttr.Value = $v4Ns
        $null = $Configuration.DocumentElement.Attributes.Append($nsAttr)
    }

    $baseNs = $Configuration.DocumentElement.NamespaceURI
    if ([string]::IsNullOrWhiteSpace($baseNs)) {
        $baseNs = "http://schemas.microsoft.com/AssignedAccess/2017/config"
    }

    $nsMgr = New-Object System.Xml.XmlNamespaceManager($Configuration.NameTable)
    $nsMgr.AddNamespace("aa", $baseNs)

    $kioskProfiles = @($Configuration.SelectNodes("//aa:Profile[aa:KioskModeApp]", $nsMgr))
    if ($kioskProfiles.Count -ne 1) {
        throw "Expected exactly 1 kiosk profile with KioskModeApp, found $($kioskProfiles.Count)."
    }

    $targetProfile = $kioskProfiles[0]
    $profileId = $targetProfile.GetAttribute("Id")
    if ([string]::IsNullOrWhiteSpace($profileId)) {
        throw "Kiosk profile is missing a valid Id attribute."
    }

    $configs = @($Configuration.SelectNodes("//aa:Config[aa:DefaultProfile[@Id=""$profileId""]]", $nsMgr))
    if ($configs.Count -eq 0) {
        throw "Account mapping missing for kiosk profile Id: $profileId."
    }

    $kioskApp = $targetProfile.SelectSingleNode("aa:KioskModeApp", $nsMgr)
    if ($null -eq $kioskApp) {
        throw "KioskModeApp element missing from kiosk profile."
    }

    # Remove obsolete UWP attribute if present
    if ($kioskApp.HasAttribute("AppUserModelId")) {
        $kioskApp.RemoveAttribute("AppUserModelId")
    }

    $arguments = "--kiosk `"$SelectorUrl`" --edge-kiosk-type=public-browsing --kiosk-idle-timeout-minutes=2 --no-first-run"

    $attrPath = $Configuration.CreateAttribute("v4", "ClassicAppPath", $v4Ns)
    $attrPath.Value = $EdgePath
    $null = $kioskApp.Attributes.SetNamedItem($attrPath)

    $attrArgs = $Configuration.CreateAttribute("v4", "ClassicAppArguments", $v4Ns)
    $attrArgs.Value = $arguments
    $null = $kioskApp.Attributes.SetNamedItem($attrArgs)

    return $Configuration
}

# ---------------------------------------------------------------------------
# Utility and System Helpers
# ---------------------------------------------------------------------------
function Test-IsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}
function Test-IsUacDisabled {
    try {
        $regKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System", $false)
        if ($null -ne $regKey) {
            $val = $regKey.GetValue("EnableLUA", 1) # Default in Windows is 1 (Enabled)
            $regKey.Close()
            return ($val -eq 0)
        }
    } catch {}
    return $false
}


function Get-EdgeExecutablePath {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        "C:\Program Files\Microsoft\Edge\Application\msedge.exe"
    )
    foreach ($path in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -Path $path -PathType Leaf)) {
            return $path
        }
    }
    return $null
}

function Get-EdgeVersion {
    param([string]$Path)
    if (-not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -Path $Path -PathType Leaf)) {
        try {
            return (Get-Item -Path $Path).VersionInfo.ProductVersion
        } catch {
            return "Unknown"
        }
    }
    return $null
}

function Test-IsLocalUserStandard {
    param([string]$Username)
    $bareUsername = $Username.Split('\')[-1]
    # Check if local user exists
    try {
        $localUser = Get-LocalUser -Name $bareUsername -ErrorAction SilentlyContinue
        if ($null -ne $localUser) { $userFound = $true }
    } catch {
        $userFound = $false
    }

    if (-not $userFound) {
        try {
            $adsiUser = [ADSI]"WinNT://$env:COMPUTERNAME/$bareUsername,user"
            if ($adsiUser.psbase.Name) { $userFound = $true }
        } catch {
            $userFound = $false
        }
    }

    # Check if member of local Administrators group
    $isAdmin = $false
    try {
        $adminGroup = [ADSI]"WinNT://$env:COMPUTERNAME/Administrators,group"
        $members = @($adminGroup.psbase.Invoke("Members"))
        foreach ($member in $members) {
            $mName = $member.GetType().InvokeMember("Name", 'GetProperty', $null, $member, $null)
            if ($mName -ieq $bareUsername) {
                $isAdmin = $true
                break
            }
        }
    } catch {
        $netAdmins = net localgroup administrators 2>$null
        if ($netAdmins -match "(?m)^\s*$([regex]::Escape($bareUsername))\s*$") {
            $isAdmin = $true
        }
    }

    return @{ Exists = $true; IsAdmin = $isAdmin }
}

# ---------------------------------------------------------------------------
# Scheduled Task SYSTEM Executor for WMI Access
# ---------------------------------------------------------------------------
function Invoke-SystemWmiTask {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptContent,
        [int]$TimeoutSeconds = 30
    )

    $taskDir = "C:\ProgramData\EmployeeKiosk\SystemTasks"
    if (-not (Test-Path -Path $taskDir)) {
        $null = New-Item -Path $taskDir -ItemType Directory -Force
    }

    $taskId = [guid]::NewGuid().ToString("N").Substring(0, 8)
    $taskName = "EmployeeKiosk_WMI_$taskId"
    $scriptFile = Join-Path -Path $taskDir -ChildPath "task_$taskId.ps1"
    $resultFile = Join-Path -Path $taskDir -ChildPath "result_$taskId.json"
    $logFile = Join-Path -Path $taskDir -ChildPath "log_$taskId.txt"

    # Wrap script to write output to result file
    $wrappedScript = @"
try {
    `$result = & {
$ScriptContent
    }
    `$output = @{
        Success = `$true
        Data    = `$result
        Error   = `$null
    }
} catch {
    `$output = @{
        Success = `$false
        Data    = `$null
        Error   = `$_.Exception.Message
    }
}
`$output | ConvertTo-Json -Depth 5 | Set-Content -Path '$resultFile' -Encoding UTF8 -Force
"@

    Set-Content -Path $scriptFile -Value $wrappedScript -Encoding UTF8 -Force

    $psExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path $psExe)) { $psExe = "powershell.exe" }

    $taskRegistered = $false
    try {
        $started = $false

        # Method 1: PowerShell ScheduledTasks module with battery support & error checking
        if (Get-Command -Name Register-ScheduledTask -ErrorAction SilentlyContinue) {
            try {
                $action = New-ScheduledTaskAction -Execute $psExe -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptFile`" *>`"$logFile`"" -WorkingDirectory $taskDir
                $principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
                $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
                $null = Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop
                $taskRegistered = $true
                Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
                $started = $true
            } catch {
                Write-Verbose "Register-ScheduledTask failed: $($_.Exception.Message). Falling back to schtasks.exe..."
            }
        }

        # Method 2: Fallback to schtasks.exe
        if (-not $started) {
            $schCmd = "schtasks.exe /Create /TN `"$taskName`" /TR `"\`"$psExe\`" -NoProfile -ExecutionPolicy Bypass -File \`"$scriptFile\`"`" /SC ONCE /ST 00:00 /RU `"NT AUTHORITY\SYSTEM`" /RL HIGHEST /F"
            $createOut = cmd.exe /c $schCmd 2>&1
            if ($LASTEXITCODE -ne 0) {
                $schCmd2 = "schtasks.exe /Create /TN `"$taskName`" /TR `"\`"$psExe\`" -NoProfile -ExecutionPolicy Bypass -File \`"$scriptFile\`"`" /SC ONCE /ST 00:00 /RU SYSTEM /RL HIGHEST /F"
                $createOut = cmd.exe /c $schCmd2 2>&1
            }
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to create SYSTEM scheduled task: $createOut"
            }
            $taskRegistered = $true
            $runOut = cmd.exe /c "schtasks.exe /Run /TN `"$taskName`"" 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to run SYSTEM scheduled task: $runOut"
            }
        }

        # Wait for result file (max 30 seconds, polling every 250ms)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            if (Test-Path -Path $resultFile -PathType Leaf) {
                Start-Sleep -Milliseconds 250
                break
            }
            Start-Sleep -Milliseconds 250
        }

        if (-not (Test-Path -Path $resultFile -PathType Leaf)) {
            $logContent = if (Test-Path $logFile) { Get-Content $logFile -Raw } else { "No log file produced." }
            throw "System task timed out after $TimeoutSeconds seconds without producing result. Task log: $logContent"
        }

        $rawJson = Get-Content -Path $resultFile -Raw -Encoding UTF8
        $res = $rawJson | ConvertFrom-Json
        if (-not $res.Success) {
            throw "System task execution failed: $($res.Error)"
        }
        return $res.Data
    } finally {
        if ($taskRegistered) {
            if (Get-Command -Name Unregister-ScheduledTask -ErrorAction SilentlyContinue) {
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            } else {
                cmd.exe /c "schtasks.exe /Delete /TN `"$taskName`" /F" 2>$null
            }
        }
        Remove-Item -Path $scriptFile, $resultFile, $logFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-AssignedAccessState {
    $script = @'
$obj = Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_AssignedAccess' -ErrorAction SilentlyContinue
if ($null -eq $obj) {
    return @{ Available = $false; Configuration = $null; KioskModeApp = $null }
}
$config = if ([string]::IsNullOrWhiteSpace($obj.Configuration)) { $null } else { [System.Net.WebUtility]::HtmlDecode($obj.Configuration) }
return @{
    Available     = $true
    Configuration = $config
    KioskModeApp  = $obj.KioskModeApp
}
'@
    return Invoke-SystemWmiTask -ScriptContent $script
}

function Set-AssignedAccessConfigurationXml {
    param([string]$XmlContent)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($XmlContent)
    $b64 = [System.Convert]::ToBase64String($bytes)
    $script = @"
`$bytes = [System.Convert]::FromBase64String('$b64')
`$xmlStr = [System.Text.Encoding]::UTF8.GetString(`$bytes)
`$encoded = [System.Net.WebUtility]::HtmlEncode(`$xmlStr)
`$obj = Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_AssignedAccess' -ErrorAction Stop
`$obj.Configuration = `$encoded
Set-CimInstance -CimInstance `$obj -ErrorAction Stop
return `$true
"@
    return Invoke-SystemWmiTask -ScriptContent $script
}

function Clear-AssignedAccessConfiguration {
    $script = @'
$obj = Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_AssignedAccess' -ErrorAction Stop
$obj.Configuration = $null
Set-CimInstance -CimInstance $obj -ErrorAction Stop
return $true
'@
    return Invoke-SystemWmiTask -ScriptContent $script
}

# ---------------------------------------------------------------------------
# Edge Registry Policy Management
# ---------------------------------------------------------------------------
$Script:TargetPolicies = @{
    'KioskAddressBarEditingEnabled' = [uint32]0
    'DownloadRestrictions'          = [uint32]3
    'PrintingEnabled'               = [uint32]0
    'AllowFileSelectionDialogs'     = [uint32]0
}

function Get-EdgePolicySnapshot {
    $keyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
    $snapshot = @{}

    foreach ($policyName in $Script:TargetPolicies.Keys) {
        $info = @{ Exists = $false; Value = $null; Type = $null }
        if (Test-Path -Path $keyPath) {
            $regKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SOFTWARE\Policies\Microsoft\Edge", $false)
            if ($null -ne $regKey) {
                try {
                    $val = $regKey.GetValue($policyName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    if ($null -ne $val) {
                        $info.Exists = $true
                        $info.Value = $val
                        $info.Type = $regKey.GetValueKind($policyName).ToString()
                    }
                } finally {
                    $regKey.Close()
                }
            }
        }
        $snapshot[$policyName] = $info
    }
    return $snapshot
}

function Apply-EdgePolicies {
    $keyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
    if (-not (Test-Path -Path $keyPath)) {
        $null = New-Item -Path $keyPath -Force
    }

    foreach ($policyName in $Script:TargetPolicies.Keys) {
        $targetVal = $Script:TargetPolicies[$policyName]
        Set-ItemProperty -Path $keyPath -Name $policyName -Value $targetVal -Type DWord -Force
    }
}

function Restore-EdgePolicies {
    param([hashtable]$OriginalSnapshot)

    $keyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
    if (-not (Test-Path -Path $keyPath)) { return }

    foreach ($policyName in $OriginalSnapshot.Keys) {
        $orig = $OriginalSnapshot[$policyName]
        if ($orig.Exists) {
            # Restore original value and type
            $kind = [Microsoft.Win32.RegistryValueKind]::DWord
            if ($orig.Type -eq 'String') { $kind = [Microsoft.Win32.RegistryValueKind]::String }
            elseif ($orig.Type -eq 'QWord') { $kind = [Microsoft.Win32.RegistryValueKind]::QWord }
            elseif ($orig.Type -eq 'Binary') { $kind = [Microsoft.Win32.RegistryValueKind]::Binary }

            Set-ItemProperty -Path $keyPath -Name $policyName -Value $orig.Value -Type $orig.Type -Force
        } else {
            # Remove value if it was originally absent
            Remove-ItemProperty -Path $keyPath -Name $policyName -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# Workflows: Inspect, Install, Restore
# ---------------------------------------------------------------------------
function Invoke-Inspect {
    Write-Host "`n=== Employee Kiosk Inspection Report ===" -ForegroundColor Cyan

    $isAdmin = Test-IsAdministrator
    Write-Host "Execution Context: " -NoNewline
    if ($isAdmin) {
        Write-Host "Elevated Administrator" -ForegroundColor Green
    } else {
        Write-Host "Standard User (Assigned Access WMI query requires elevation)" -ForegroundColor Yellow
    }

    # OS Information
    $osInfo = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue
    $productName = if ($osInfo) { $osInfo.ProductName } else { "Unknown" }
    $buildNumber = if ($osInfo) { $osInfo.CurrentBuild } else { "Unknown" }
    $displayVer = if ($osInfo -and $osInfo.DisplayVersion) { $osInfo.DisplayVersion } else { "N/A" }
    Write-Host "Operating System:   $productName ($displayVer, Build $buildNumber)"

    # UAC Check
    $uacDisabled = Test-IsUacDisabled
    Write-Host "UAC (EnableLUA):    " -NoNewline
    if (-not $uacDisabled) {
        Write-Host "Enabled" -ForegroundColor Green
    } else {
        Write-Host "Disabled (Assigned Access requires UAC)" -ForegroundColor Red
    }

    # Microsoft Edge
    $edgePath = Get-EdgeExecutablePath
    if ($edgePath) {
        $edgeVer = Get-EdgeVersion -Path $edgePath
        Write-Host "Microsoft Edge:     $edgePath (Version $edgeVer)" -ForegroundColor Green
    } else {
        Write-Host "Microsoft Edge:     NOT FOUND in standard installation paths" -ForegroundColor Red
    }

    # Edge Policies
    Write-Host "`n--- Microsoft Edge Policies (HKLM) ---" -ForegroundColor Cyan
    $policies = Get-EdgePolicySnapshot
    foreach ($p in $policies.Keys) {
        $pInfo = $policies[$p]
        $status = if ($pInfo.Exists) { "Present (Value: $($pInfo.Value), Type: $($pInfo.Type))" } else { "Not configured" }
        Write-Host "  $p : $status"
    }

    # Assigned Access Inspection
    Write-Host "`n--- Windows Assigned Access ---" -ForegroundColor Cyan
    if (-not $isAdmin) {
        Write-Host "  Run Setup.ps1 with elevated administrator privileges to query MDM_AssignedAccess WMI." -ForegroundColor Yellow
        return
    }

    try {
        $aaState = Get-AssignedAccessState
        if (-not $aaState.Available) {
            Write-Host "  MDM_AssignedAccess class not available on this system." -ForegroundColor Red
            return
        }

        if (-not [string]::IsNullOrWhiteSpace($aaState.Configuration)) {
            Write-Host "  Modern Configuration XML detected:" -ForegroundColor Green
            try {
                $doc = [xml]$aaState.Configuration
                $nsMgr = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
                $baseNs = $doc.DocumentElement.NamespaceURI
                if ([string]::IsNullOrWhiteSpace($baseNs)) { $baseNs = "http://schemas.microsoft.com/AssignedAccess/2017/config" }
                $nsMgr.AddNamespace("aa", $baseNs)

                $profiles = @($doc.SelectNodes("//aa:Profile", $nsMgr))
                Write-Host "    Total Profiles: $($profiles.Count)"
                foreach ($prof in $profiles) {
                    $pId = $prof.GetAttribute("Id")
                    $kioskApp = $prof.SelectSingleNode("aa:KioskModeApp", $nsMgr)
                    if ($kioskApp) {
                        Write-Host "    - Kiosk Profile Id: $pId"
                        if ($kioskApp.HasAttribute("AppUserModelId")) {
                            Write-Host "      AppUserModelId: $($kioskApp.GetAttribute('AppUserModelId'))"
                        }
                        # Check classic app
                        foreach ($att in $kioskApp.Attributes) {
                            if ($att.LocalName -eq 'ClassicAppPath') { Write-Host "      ClassicAppPath: $($att.Value)" }
                            if ($att.LocalName -eq 'ClassicAppArguments') { Write-Host "      ClassicAppArguments: $($att.Value)" }
                        }
                    } else {
                        Write-Host "    - Other Profile Id: $pId"
                    }
                }

                $configs = @($doc.SelectNodes("//aa:Config", $nsMgr))
                Write-Host "    Configs / Accounts:"
                foreach ($cfg in $configs) {
                    $acctNode = $cfg.SelectSingleNode("aa:Account", $nsMgr)
                    $autoLogon = $cfg.SelectSingleNode("aa:AutoLogonAccount", $nsMgr)
                    $defProf = $cfg.SelectSingleNode("aa:DefaultProfile", $nsMgr)
                    $acctName = if ($acctNode) { $acctNode.InnerText } elseif ($autoLogon) { "[AutoLogonAccount]" } else { "Unknown" }
                    $pRef = if ($defProf) { $defProf.GetAttribute("Id") } else { "None" }
                    Write-Host "    - Account: $acctName -> Profile: $pRef"
                }
            } catch {
                Write-Host "    Failed to parse XML: $($_.Exception.Message)" -ForegroundColor Red
            }
        } elseif (-not [string]::IsNullOrWhiteSpace($aaState.KioskModeApp)) {
            Write-Host "  Legacy KioskModeApp JSON detected:" -ForegroundColor Yellow
            Write-Host "    $($aaState.KioskModeApp)"
        } else {
            Write-Host "  No active Assigned Access configuration found in WMI." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  Error reading Assigned Access state: $($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host "`nInspection complete.`n"
}

function Invoke-Install {
    param([string]$KioskUser, [string]$SelectorUrl)

    Write-Host "`n=== Employee Kiosk Installation ===" -ForegroundColor Cyan

    if (-not (Test-IsAdministrator)) {
        throw "Install mode requires an elevated administrator PowerShell session."
    }

    if ([string]::IsNullOrWhiteSpace($KioskUser)) {
        throw "The -KioskUser parameter is required for Install mode."
    }

    # Validate SelectorUrl
    if ($SelectorUrl -ne 'file:///C:/ProgramData/EmployeeKiosk/index.html') {
        $uri = $null
        if (-not [System.Uri]::TryCreate($SelectorUrl, [System.UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or -not [string]::IsNullOrEmpty($uri.UserInfo)) {
            throw "SelectorUrl must be the default file URL or an absolute HTTPS URL without embedded credentials: $SelectorUrl"
        }
    }

    # Validate target user
    $bareUsername = $KioskUser.Split('\')[-1]
    Write-Host "Checking kiosk user account '$bareUsername'..."
    $userCheck = Test-IsLocalUserStandard -Username $bareUsername
    if (-not $userCheck.Exists) {
        Write-Host "Local user account '$bareUsername' does not exist. Creating local standard kiosk user..." -ForegroundColor Cyan
        $created = $false
        try {
            if (Get-Command -Name New-LocalUser -ErrorAction SilentlyContinue) {
                $null = New-LocalUser -Name $bareUsername -NoPassword -Description "Employee Kiosk Account" -ErrorAction Stop
                $created = $true
            }
        } catch {}

        if (-not $created) {
            $addResult = cmd.exe /c "net user `"$bareUsername`" /add /comment:`"Employee Kiosk Account`"" 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to create local user account '$bareUsername': $addResult"
            }
        }
        $userCheck = Test-IsLocalUserStandard -Username $bareUsername
        if (-not $userCheck.Exists) {
            throw "Could not verify local user '$bareUsername' after creation."
        }
        Write-Host "Local standard user account '$bareUsername' created successfully." -ForegroundColor Green
    }
    if ($userCheck.IsAdmin) {
        throw "Kiosk user account '$bareUsername' is an administrator. Assigned Access requires a standard user account."
    }
    Write-Host "Kiosk user account is valid standard local account." -ForegroundColor Green
    if (Test-IsUacDisabled) {
        Write-Host "UAC is explicitly disabled (EnableLUA = 0). Windows Assigned Access strictly requires UAC." -ForegroundColor Yellow
        Write-Host "Enabling UAC (EnableLUA = 1) in registry..." -ForegroundColor Cyan
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "EnableLUA" -Value 1 -Type DWord -Force
        throw "UAC has been enabled in the registry, but Windows requires a computer restart before Assigned Access can be activated. Please restart this PC and re-run the installer command."
    }

    # Validate Microsoft Edge
    $edgePath = Get-EdgeExecutablePath
    if (-not $edgePath) {
        throw "Microsoft Edge was not found in standard installation paths."
    }
    Write-Host "Resolved Microsoft Edge path: $edgePath" -ForegroundColor Green

    # Prepare directories
    $kioskDir = "C:\ProgramData\EmployeeKiosk"
    $backupDir = "C:\ProgramData\EmployeeKiosk\Backup"
    if (-not (Test-Path -Path $kioskDir)) { $null = New-Item -Path $kioskDir -ItemType Directory -Force }
    if (-not (Test-Path -Path $backupDir)) { $null = New-Item -Path $backupDir -ItemType Directory -Force }

    # Copy index.html
    $sourceHtml = Join-Path -Path $PSScriptRoot -ChildPath "index.html"
    $targetHtml = Join-Path -Path $kioskDir -ChildPath "index.html"
    if (Test-Path -Path $sourceHtml -PathType Leaf) {
        Copy-Item -Path $sourceHtml -Destination $targetHtml -Force
        Write-Host "Staged selector page to $targetHtml" -ForegroundColor Green
    } else {
        if (-not (Test-Path -Path $targetHtml -PathType Leaf)) {
            throw "Source selector file index.html not found in $PSScriptRoot and destination $targetHtml does not exist."
        }
    }

    # Query current Assigned Access state
    Write-Host "Reading current Assigned Access configuration..."
    $aaState = Get-AssignedAccessState
    if (-not $aaState.Available) {
        throw "MDM_AssignedAccess WMI class is not available on this system."
    }

    # Take backup if not already present (preserve initial pre-install state)
    $backupFile = Join-Path -Path $backupDir -ChildPath "backup.json"
    if (-not (Test-Path -Path $backupFile -PathType Leaf)) {
        Write-Host "Creating pre-install backup at $backupFile..."
        $policySnapshot = Get-EdgePolicySnapshot
        $backupData = @{
            Timestamp     = (Get-Date).ToString("o")
            KioskUser     = $KioskUser
            Configuration = $aaState.Configuration
            KioskModeApp  = $aaState.KioskModeApp
            Policies      = $policySnapshot
        }
        $backupData | ConvertTo-Json -Depth 5 | Set-Content -Path $backupFile -Encoding UTF8 -Force
        Write-Host "Backup saved successfully." -ForegroundColor Green
    } else {
        Write-Host "Preserving existing pre-install backup at $backupFile." -ForegroundColor Yellow
    }

    # Determine transformation
    $newXmlDoc = $null
    if (-not [string]::IsNullOrWhiteSpace($aaState.Configuration)) {
        Write-Host "Updating existing Assigned Access modern configuration XML..."
        $currentXml = [xml]$aaState.Configuration
        $newXmlDoc = Update-KioskXml -Configuration $currentXml -EdgePath $edgePath -SelectorUrl $SelectorUrl
    } elseif (-not [string]::IsNullOrWhiteSpace($aaState.KioskModeApp)) {
        Write-Host "Migrating legacy KioskModeApp JSON to modern XML..."
        $legacyObj = $aaState.KioskModeApp | ConvertFrom-Json
        $legacyUser = if ($legacyObj.User) { $legacyObj.User } elseif ($legacyObj.Account) { $legacyObj.Account } else { $null }
        if ($null -ne $legacyUser) {
            $unqualifiedUser = $legacyUser.Split('\')[-1]
            if ($unqualifiedUser -ine $KioskUser) {
                throw "Configured legacy kiosk user '$legacyUser' does not match requested -KioskUser '$KioskUser'."
            }
        }

        $formattedAccount = if ($KioskUser.Contains('\')) { $KioskUser } else { ".\$KioskUser" }
        $guid = "{" + [guid]::NewGuid().ToString().ToUpper() + "}"
        $arguments = "--kiosk `"$SelectorUrl`" --edge-kiosk-type=public-browsing --kiosk-idle-timeout-minutes=2 --no-first-run"
        $newXmlDoc = [xml]@"
<?xml version="1.0" encoding="utf-8"?>
<AssignedAccessConfiguration xmlns="http://schemas.microsoft.com/AssignedAccess/2017/config" xmlns:v4="http://schemas.microsoft.com/AssignedAccess/2021/config">
  <Profiles>
    <Profile Id="$guid">
      <KioskModeApp v4:ClassicAppPath="$edgePath" v4:ClassicAppArguments="$arguments" />
    </Profile>
  </Profiles>
  <Configs>
    <Config>
      <Account>$formattedAccount</Account>
      <DefaultProfile Id="$guid" />
    </Config>
  </Configs>
</AssignedAccessConfiguration>
"@
    } else {
        Write-Host "No existing Assigned Access configuration found; creating fresh single-app kiosk configuration for '$KioskUser'..." -ForegroundColor Cyan
        $formattedAccount = if ($KioskUser.Contains('\')) { $KioskUser } else { ".\$KioskUser" }
        $guid = "{" + [guid]::NewGuid().ToString().ToUpper() + "}"
        $arguments = "--kiosk `"$SelectorUrl`" --edge-kiosk-type=public-browsing --kiosk-idle-timeout-minutes=2 --no-first-run"
        $newXmlDoc = [xml]@"
<?xml version="1.0" encoding="utf-8"?>
<AssignedAccessConfiguration xmlns="http://schemas.microsoft.com/AssignedAccess/2017/config" xmlns:v4="http://schemas.microsoft.com/AssignedAccess/2021/config">
  <Profiles>
    <Profile Id="$guid">
      <KioskModeApp v4:ClassicAppPath="$edgePath" v4:ClassicAppArguments="$arguments" />
    </Profile>
  </Profiles>
  <Configs>
    <Config>
      <Account>$formattedAccount</Account>
      <DefaultProfile Id="$guid" />
    </Config>
  </Configs>
</AssignedAccessConfiguration>
"@
    }

    # Apply configuration and policies with rollback protection
    $appliedXml = $newXmlDoc.OuterXml
    try {
        Write-Host "Writing updated Assigned Access configuration to WMI..."
        $null = Set-AssignedAccessConfigurationXml -XmlContent $appliedXml

        Write-Host "Applying Microsoft Edge view-only policies (HKLM)..."
        Apply-EdgePolicies

        # Verification readback
        Write-Host "Verifying configuration readback..."
        $verifyState = Get-AssignedAccessState
        if ([string]::IsNullOrWhiteSpace($verifyState.Configuration) -or -not $verifyState.Configuration.Contains("kiosk-idle-timeout-minutes=2")) {
            throw "Assigned Access readback verification failed: Configuration does not contain expected kiosk arguments."
        }

        Write-Host "Configuration applied and verified successfully!" -ForegroundColor Green
        Write-Host "`nNext Step: Sign out or restart the machine into user '$KioskUser' to validate the kiosk session." -ForegroundColor Cyan
    } catch {
        Write-Warning "Installation encountered an error: $($_.Exception.Message). Initiating rollback..."
        try {
            if (Test-Path -Path $backupFile -PathType Leaf) {
                $rawBak = Get-Content -Path $backupFile -Raw -Encoding UTF8 | ConvertFrom-Json
                if (-not [string]::IsNullOrWhiteSpace($rawBak.Configuration)) {
                    $null = Set-AssignedAccessConfigurationXml -XmlContent $rawBak.Configuration
                } else {
                    $null = Clear-AssignedAccessConfiguration
                }
                if ($rawBak.Policies) {
                    Restore-EdgePolicies -OriginalSnapshot $rawBak.Policies
                }
                Write-Host "Rollback completed." -ForegroundColor Yellow
            }
        } catch {
            Write-Error "Rollback also encountered an error: $($_.Exception.Message)"
        }
        throw
    }
}

function Invoke-Restore {
    Write-Host "`n=== Employee Kiosk Restore ===" -ForegroundColor Cyan

    if (-not (Test-IsAdministrator)) {
        throw "Restore mode requires an elevated administrator PowerShell session."
    }

    $backupFile = "C:\ProgramData\EmployeeKiosk\Backup\backup.json"
    if (-not (Test-Path -Path $backupFile -PathType Leaf)) {
        throw "Backup file not found at $backupFile. Cannot restore."
    }

    Write-Host "Loading backup from $backupFile..."
    $backupData = Get-Content -Path $backupFile -Raw -Encoding UTF8 | ConvertFrom-Json

    # Restore Assigned Access
    if (-not [string]::IsNullOrWhiteSpace($backupData.Configuration)) {
        Write-Host "Restoring original modern Assigned Access XML..."
        $null = Set-AssignedAccessConfigurationXml -XmlContent $backupData.Configuration
    } else {
        Write-Host "Clearing modern Assigned Access configuration..."
        $null = Clear-AssignedAccessConfiguration
    }

    # Restore Edge Policies
    if ($backupData.Policies) {
        Write-Host "Restoring original Edge registry policies..."
        $hashSnap = @{}
        foreach ($prop in $backupData.Policies.PSObject.Properties) {
            $hashSnap[$prop.Name] = @{
                Exists = [bool]$prop.Value.Exists
                Value  = $prop.Value.Value
                Type   = $prop.Value.Type
            }
        }
        Restore-EdgePolicies -OriginalSnapshot $hashSnap
    }

    Write-Host "Restoration completed successfully." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Entry Point Execution Guard
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {
    switch ($Mode) {
        'Inspect' { Invoke-Inspect }
        'Install' { Invoke-Install -KioskUser $KioskUser -SelectorUrl $SelectorUrl }
        'Restore' { Invoke-Restore }
    }
}
