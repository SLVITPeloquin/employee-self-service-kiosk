<#
.SYNOPSIS
    Self-contained regression test for Employee Kiosk Assigned Access XML transformations.

.DESCRIPTION
    Verifies that Update-KioskXml in Setup.ps1 preserves account mappings, GUIDs, breakout
    sequences, and unrelated profiles, correctly applies Edge public-browsing arguments with
    a 2-minute idle timeout, and rejects malformed configurations.
#>

$ErrorActionPreference = "Stop"

function Assert-Condition {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        throw "ASSERTION FAILED: $Message"
    }
}

# Resolve and dot-source Setup.ps1
$setupPath = Join-Path -Path $PSScriptRoot -ChildPath "Setup.ps1"
if (-not (Test-Path -Path $setupPath -PathType Leaf)) {
    throw "Setup.ps1 not found at $setupPath"
}
. $setupPath

# ---------------------------------------------------------------------------
# Test 1: Preservation Invariants on Valid Multi-Profile Configuration
# ---------------------------------------------------------------------------
Write-Host "Running Test 1: Preserving invariants and applying Edge kiosk parameters..."

$kioskGuid = "{EDB3036B-780D-487D-A375-69369D8A8F78}"
$unrelatedGuid = "{98765432-ABCD-EF01-2345-6789ABCDEF01}"
$kioskUser = "MYPC\KioskUser"
$otherUser = "MYPC\OtherUser"

$fixtureXmlString = @"
<?xml version="1.0" encoding="utf-8"?>
<AssignedAccessConfiguration xmlns="http://schemas.microsoft.com/AssignedAccess/2017/config">
  <Profiles>
    <Profile Id="$kioskGuid">
      <KioskModeApp AppUserModelId="Microsoft.BingWeather_8wekyb3d8bbwe!App" />
      <BreakoutSequence Key="Ctrl+A" />
    </Profile>
    <Profile Id="$unrelatedGuid">
      <AllAppList>
        <AllowedApps>
          <App DesktopAppPath="%windir%\notepad.exe" />
        </AllowedApps>
      </AllAppList>
    </Profile>
  </Profiles>
  <Configs>
    <Config>
      <Account>$kioskUser</Account>
      <DefaultProfile Id="$kioskGuid" />
    </Config>
    <Config>
      <Account>$otherUser</Account>
      <DefaultProfile Id="$unrelatedGuid" />
    </Config>
  </Configs>
</AssignedAccessConfiguration>
"@

$fixtureDoc = [xml]$fixtureXmlString
$edgePath = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
$selectorUrl = "file:///C:/ProgramData/EmployeeKiosk/index.html"

$updatedDoc = Update-KioskXml -Configuration $fixtureDoc -EdgePath $edgePath -SelectorUrl $selectorUrl

# Namespace checks
$nsMgr = New-Object System.Xml.XmlNamespaceManager($updatedDoc.NameTable)
$nsMgr.AddNamespace("aa", "http://schemas.microsoft.com/AssignedAccess/2017/config")
$v4Ns = "http://schemas.microsoft.com/AssignedAccess/2021/config"
$nsMgr.AddNamespace("v4", $v4Ns)

Assert-Condition ($updatedDoc.DocumentElement.HasAttribute("xmlns:v4")) "Document element must declare xmlns:v4."
Assert-Condition ($updatedDoc.DocumentElement.GetAttribute("xmlns:v4") -eq $v4Ns) "xmlns:v4 must match AssignedAccess 2021 schema."

# Check kiosk profile preservation
$kioskProfiles = @($updatedDoc.SelectNodes("//aa:Profile[aa:KioskModeApp]", $nsMgr))
Assert-Condition ($kioskProfiles.Count -eq 1) "Expected exactly 1 kiosk profile after update."
$kioskProfile = $kioskProfiles[0]

Assert-Condition ($kioskProfile.GetAttribute("Id") -eq $kioskGuid) "Kiosk Profile Id GUID must remain unchanged."

# Check breakout sequence preservation
$breakout = $kioskProfile.SelectSingleNode("aa:BreakoutSequence", $nsMgr)
Assert-Condition ($null -ne $breakout) "BreakoutSequence element must be preserved."
Assert-Condition ($breakout.GetAttribute("Key") -eq "Ctrl+A") "BreakoutSequence Key attribute must remain unchanged."

# Check KioskModeApp attributes
$kioskApp = $kioskProfile.SelectSingleNode("aa:KioskModeApp", $nsMgr)
Assert-Condition (-not $kioskApp.HasAttribute("AppUserModelId")) "Obsolete AppUserModelId must be removed."
Assert-Condition ($kioskApp.GetAttribute("ClassicAppPath", $v4Ns) -eq $edgePath) "v4:ClassicAppPath must match resolved Edge executable path."

$actualArgs = $kioskApp.GetAttribute("ClassicAppArguments", $v4Ns)
Assert-Condition ($actualArgs -like "*--edge-kiosk-type=public-browsing*") "ClassicAppArguments must specify --edge-kiosk-type=public-browsing."
Assert-Condition ($actualArgs -like "*--kiosk-idle-timeout-minutes=2*") "ClassicAppArguments must specify --kiosk-idle-timeout-minutes=2."
Assert-Condition ($actualArgs -like "*--kiosk `"$selectorUrl`"*") "ClassicAppArguments must point to specified selector URL."
Assert-Condition ($actualArgs -like "*--no-first-run*") "ClassicAppArguments must include --no-first-run."

# Check Config mapping preservation
$kioskConfig = $updatedDoc.SelectSingleNode("//aa:Config[aa:DefaultProfile[@Id=""$kioskGuid""]]", $nsMgr)
Assert-Condition ($null -ne $kioskConfig) "Kiosk Config element must exist."
Assert-Condition ($kioskConfig.SelectSingleNode("aa:Account", $nsMgr).InnerText -eq $kioskUser) "Kiosk Config Account must remain unchanged."

# Check unrelated profile preservation
$unrelatedProfile = $updatedDoc.SelectSingleNode("//aa:Profile[@Id=""$unrelatedGuid""]", $nsMgr)
Assert-Condition ($null -ne $unrelatedProfile) "Unrelated profile must remain present."
$notepadApp = $unrelatedProfile.SelectSingleNode("aa:AllAppList/aa:AllowedApps/aa:App", $nsMgr)
Assert-Condition ($null -ne $notepadApp -and $notepadApp.GetAttribute("DesktopAppPath") -eq "%windir%\notepad.exe") "Unrelated profile AllowedApps content must be unchanged."

$unrelatedConfig = $updatedDoc.SelectSingleNode("//aa:Config[aa:DefaultProfile[@Id=""$unrelatedGuid""]]", $nsMgr)
Assert-Condition ($null -ne $unrelatedConfig) "Unrelated user Config must remain present."
Assert-Condition ($unrelatedConfig.SelectSingleNode("aa:Account", $nsMgr).InnerText -eq $otherUser) "Unrelated Config Account must remain unchanged."

Write-Host "Test 1 PASSED: All preservation invariants and attributes verified." -ForegroundColor Green

# ---------------------------------------------------------------------------
# Test 2: Rejection of Missing Account Mapping
# ---------------------------------------------------------------------------
Write-Host "Running Test 2: Rejecting configuration with missing account mapping..."

$missingMappingXml = [xml]@"
<?xml version="1.0" encoding="utf-8"?>
<AssignedAccessConfiguration xmlns="http://schemas.microsoft.com/AssignedAccess/2017/config">
  <Profiles>
    <Profile Id="{ORPHANED-GUID}">
      <KioskModeApp AppUserModelId="App1" />
    </Profile>
  </Profiles>
  <Configs>
    <Config>
      <Account>MYPC\SomeUser</Account>
      <DefaultProfile Id="{DIFFERENT-GUID}" />
    </Config>
  </Configs>
</AssignedAccessConfiguration>
"@

$test2Passed = $false
try {
    $null = Update-KioskXml -Configuration $missingMappingXml -EdgePath $edgePath -SelectorUrl $selectorUrl
} catch {
    if ($_.Exception.Message -like "*Account mapping missing*") {
        $test2Passed = $true
    } else {
        throw "Unexpected error message: $($_.Exception.Message)"
    }
}
Assert-Condition $test2Passed "Update-KioskXml must throw an error when kiosk profile has no account mapping."
Write-Host "Test 2 PASSED: Missing account mapping properly rejected." -ForegroundColor Green

# ---------------------------------------------------------------------------
# Test 3: Rejection of Configurations Without Exactly One Kiosk Profile
# ---------------------------------------------------------------------------
Write-Host "Running Test 3: Rejecting configurations with zero or multiple kiosk profiles..."

$zeroKioskXml = [xml]@"
<?xml version="1.0" encoding="utf-8"?>
<AssignedAccessConfiguration xmlns="http://schemas.microsoft.com/AssignedAccess/2017/config">
  <Profiles>
    <Profile Id="{P1}"><AllAppList /></Profile>
  </Profiles>
  <Configs />
</AssignedAccessConfiguration>
"@

$zeroPassed = $false
try {
    $null = Update-KioskXml -Configuration $zeroKioskXml -EdgePath $edgePath -SelectorUrl $selectorUrl
} catch {
    if ($_.Exception.Message -like "*Expected exactly 1 kiosk profile*") {
        $zeroPassed = $true
    }
}
Assert-Condition $zeroPassed "Update-KioskXml must throw when 0 kiosk profiles exist."

$multiKioskXml = [xml]@"
<?xml version="1.0" encoding="utf-8"?>
<AssignedAccessConfiguration xmlns="http://schemas.microsoft.com/AssignedAccess/2017/config">
  <Profiles>
    <Profile Id="{P1}"><KioskModeApp AppUserModelId="App1" /></Profile>
    <Profile Id="{P2}"><KioskModeApp AppUserModelId="App2" /></Profile>
  </Profiles>
  <Configs />
</AssignedAccessConfiguration>
"@

$multiPassed = $false
try {
    $null = Update-KioskXml -Configuration $multiKioskXml -EdgePath $edgePath -SelectorUrl $selectorUrl
} catch {
    if ($_.Exception.Message -like "*Expected exactly 1 kiosk profile*") {
        $multiPassed = $true
    }
}
Assert-Condition $multiPassed "Update-KioskXml must throw when multiple kiosk profiles exist."
Write-Host "Test 3 PASSED: Zero and multiple kiosk profiles properly rejected." -ForegroundColor Green

Write-Host "`nAll configuration regression checks passed successfully." -ForegroundColor Green
