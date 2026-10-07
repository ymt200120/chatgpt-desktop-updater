#requires -Version 5.1
<#
    Offline tests for update-chatgpt.ps1.

    These tests exercise the real production flow and the real validation
    functions (version comparison, ZIP/XML manifest parsing, identity checks,
    compatibility and dependency logic). Only these OS/network boundaries are
    mocked: architecture/Windows version facts, AppX package queries, HEAD,
    curl download, Authenticode, Add-AppxPackage, app launch and the lock.

    Fixture MSIX files are unsigned ZIP archives: Authenticode is mocked and is
    reported as such. No network request, uninstall, policy change or real
    installation is performed by these tests.
#>
[CmdletBinding()]
param(
    [switch]$KeepTemp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProjectRoot = Split-Path -Parent $PSScriptRoot

# Isolated working root: spaces, non-ASCII and square brackets on purpose.
# The non-ASCII characters are built from code points so this file stays pure
# ASCII and is unaffected by Windows PowerShell 5.1 ANSI/BOM file decoding.
$script:NonAscii = [string]([char]0x6D4B) + [string]([char]0x8BD5)
$script:IsolatedRoot = Join-Path $env:TEMP ('ut test ' + $script:NonAscii + ' [brackets] ' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $script:IsolatedRoot -Force
$script:FixtureDir = Join-Path $script:IsolatedRoot 'fixtures'
$null = New-Item -ItemType Directory -Path $script:FixtureDir -Force
$script:OriginalLocalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = $script:IsolatedRoot

# Load production functions only (dot-sourcing must not start the updater).
. (Join-Path $script:ProjectRoot 'update-chatgpt.ps1')

# Capture the production lock function before the test mocks shadow it, so one
# case can exercise the real exclusive lock in the isolated directory.
$script:ProductionEnterLock = (Get-Command Enter-UtLock -CommandType Function).ScriptBlock
$script:ProductionConfirmationBridge = (Get-Command Start-UtConfirmationPrompt -CommandType Function).ScriptBlock

# ---------------------------------------------------------------------------
# Tiny assertion harness (no Pester, no automatic installs).
# ---------------------------------------------------------------------------
$script:TestTotal = 0
$script:TestFailed = 0

function Fail-Assertion {
    param([string]$Message)
    $script:TestFailed++
    Write-Host ("    FAIL: {0}" -f $Message) -ForegroundColor Red
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { Fail-Assertion $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { Fail-Assertion ("{0} -- expected [{1}], got [{2}]" -f $Message, $Expected, $Actual) }
}

function Assert-Null {
    param($Value, [string]$Message)
    if ($null -ne $Value) { Fail-Assertion ("{0} -- expected null, got [{1}]" -f $Message, $Value) }
}

function Assert-UtFailure {
    param([int]$Code, [scriptblock]$Body, [string]$Message)
    $threw = $false
    try { $null = & $Body } catch {
        $threw = $true
        $actual = Get-UtErrorCode -ErrorRecord $_ -Default -1
        Assert-Equal $Code $actual $Message
    }
    if (-not $threw) { Fail-Assertion ("{0} -- expected failure code {1} but nothing was thrown" -f $Message, $Code) }
}

function Assert-SentinelSnapshot {
    param($Snapshot, [string]$Message)
    foreach ($file in $Snapshot.Keys) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            Fail-Assertion ("{0} -- sentinel file was removed: {1}" -f $Message, $file)
            continue
        }
        $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        if ($hash -ne $Snapshot[$file]) { Fail-Assertion ("{0} -- sentinel file changed: {1}" -f $Message, $file) }
    }
}

function Invoke-Case {
    param([string]$Name, [scriptblock]$Body)
    $script:TestTotal++
    Write-Host ("  - {0}" -f $Name)
    Reset-MockState
    try { & $Body } catch {
        $script:TestFailed++
        Write-Host ("    FAIL: unhandled exception: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Write-Host ("          at {0}" -f $_.InvocationInfo.PositionMessage.Trim()) -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------------------
# Mock state.
# ---------------------------------------------------------------------------
$script:UninstalledSentinel = '<uninstalled>'

function Reset-MockState {
    $cacheRoot = Join-Path $script:IsolatedRoot 'ChatGPTUpdater\cache'
    if (Test-Path -LiteralPath $cacheRoot) { Remove-Item -LiteralPath $cacheRoot -Recurse -Force -ErrorAction SilentlyContinue }
    $script:Calls = @{ Head = 0; Download = 0; Deploy = 0; Prompt = 0; UiLaunch = 0; StartApp = 0; AppxQuery = 0; Signature = 0; Lock = 0; Remove = 0; Provision = 0 }
    $script:MockArchitecture = 'x64'
    $script:MockWindowsVersion = [version]'10.0.26100.0'
    $script:MockRawPackages = @{}
    $script:MockRawQueue = @{}
    $script:MockRawThrow = @{}
    $script:MockHead = $null
    $script:MockHeadThrow = $null
    $script:MockSignatureStatus = 'Valid'
    $script:MockSignatureThrow = $null
    $script:MockDeployThrow = $null
    $script:MockLockThrow = $null
    $script:MockFixturePath = $null
    $script:MockDownloadHttpCode = 200
    $script:MockDownloadExitCode = 0
    $script:MockDownloadSkipFile = $false
    $script:MockDownloadBytes = -1
    $script:MockDownloadFinalUrl = 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix'
    $script:MockDownloadOmitFinalUrl = $false
    $script:MockDownloadHeaders = $null
    $script:MockDownloadHeaderStatusCode = $null
    $script:DeployedPaths = @()
    $script:LastIfMatch = $null
    $script:LastDownloadUrl = $null
    $script:LastDownloadOutput = $null
    $script:LastUiLaunch = $null
    $script:MockPromptChoice = 'Install'
}

# ---------------------------------------------------------------------------
# Mock boundaries.
# ---------------------------------------------------------------------------
function Get-UtNativeArchitecture { return $script:MockArchitecture }
function Get-UtWindowsVersion { return $script:MockWindowsVersion }

function Get-UtRawAppxPackage {
    param([Parameter(Mandatory = $true)][string]$Name)
    $script:Calls.AppxQuery++
    if ($script:MockRawThrow.ContainsKey($Name)) { throw $script:MockRawThrow[$Name] }
    if ($script:MockRawQueue.ContainsKey($Name)) {
        $queue = $script:MockRawQueue[$Name]
        if ($queue.Count -gt 0) {
            $item = $queue[0]
            $queue.RemoveAt(0)
            if ($null -eq $item -or $item -eq $script:UninstalledSentinel) { return @() }
            if ($item -is [hashtable] -and $item.ContainsKey('Throw')) { throw $item['Throw'] }
            return @($item)
        }
    }
    if ($script:MockRawPackages.ContainsKey($Name)) {
        $value = $script:MockRawPackages[$Name]
        if ($null -eq $value) { return @() }
        return @($value)
    }
    return @()
}

function Invoke-UtHeadRequest {
    param([Parameter(Mandatory = $true)][string]$Uri)
    $script:Calls.Head++
    if ($null -ne $script:MockHeadThrow) { throw $script:MockHeadThrow }
    return $script:MockHead
}

function Invoke-UtCurlDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        $IfMatch
    )
    $script:Calls.Download++
    $script:LastIfMatch = $IfMatch
    $script:LastDownloadUrl = $Url
    $script:LastDownloadOutput = $OutputPath
    $text = ("HTTPCODE={0}" -f $script:MockDownloadHttpCode)
    if (-not $script:MockDownloadOmitFinalUrl) { $text += "`nFINALURL=" + $script:MockDownloadFinalUrl }
    $responseHeaders = $script:MockDownloadHeaders
    if ($null -eq $responseHeaders -and $null -ne $script:MockHead) { $responseHeaders = $script:MockHead.Headers }
    $responseHeaderStatusCode = $script:MockDownloadHeaderStatusCode
    if ($null -eq $responseHeaderStatusCode) { $responseHeaderStatusCode = $script:MockDownloadHttpCode }
    if ($script:MockDownloadHttpCode -eq 412) {
        return [pscustomobject]@{ ExitCode = 22; Text = $text; Headers = $responseHeaders; HeaderStatusCode = $responseHeaderStatusCode }
    }
    if ($script:MockDownloadExitCode -ne 0) {
        return [pscustomobject]@{ ExitCode = $script:MockDownloadExitCode; Text = $text; Headers = $responseHeaders; HeaderStatusCode = $responseHeaderStatusCode }
    }
    if ($script:MockDownloadSkipFile) {
        return [pscustomobject]@{ ExitCode = 0; Text = $text; Headers = $responseHeaders; HeaderStatusCode = $responseHeaderStatusCode }
    }
    if ($script:MockDownloadBytes -ge 0) {
        [System.IO.File]::WriteAllBytes($OutputPath, [byte[]](New-Object byte[] $script:MockDownloadBytes))
    } elseif (-not [string]::IsNullOrEmpty($script:MockFixturePath) -and (Test-Path -LiteralPath $script:MockFixturePath)) {
        Copy-Item -LiteralPath $script:MockFixturePath -Destination $OutputPath -Force
    } else {
        [System.IO.File]::WriteAllBytes($OutputPath, [byte[]](1, 2, 3, 4))
    }
    return [pscustomobject]@{ ExitCode = 0; Text = $text; Headers = $responseHeaders; HeaderStatusCode = $responseHeaderStatusCode }
}

function Get-UtAuthenticodeSignature {
    param([Parameter(Mandatory = $true)][string]$Path)
    $script:Calls.Signature++
    if ($null -ne $script:MockSignatureThrow) { throw $script:MockSignatureThrow }
    return [pscustomobject]@{ Status = $script:MockSignatureStatus; SignerCertificate = $null }
}

function Install-UtPackage {
    param([Parameter(Mandatory = $true)][string]$Path)
    $script:Calls.Deploy++
    $script:DeployedPaths += $Path
    if ($null -ne $script:MockDeployThrow) { throw $script:MockDeployThrow }
}

function Start-UtConfirmationPrompt {
    param([Parameter(Mandatory = $true)]$Prepared, [switch]$OpenApp)
    $script:Calls.Prompt++
    if ($script:MockPromptChoice -ne 'Install') {
        return [pscustomobject]@{ Code = 0; Status = 'Snoozed'; Message = 'No installation was authorized.' }
    }
    return Invoke-UtConfirmedInstall -ExpectedKey ([string]$Prepared.Key) -ExpectedVersion ([version]$Prepared.Metadata.Version)
}

function Start-UbPromptDetached {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$ExpectedKey,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion,
        [string]$CorePath,
        [switch]$OpenApp
    )
    $script:Calls.UiLaunch++
    $script:LastUiLaunch = [pscustomobject]@{ ScriptPath = $ScriptPath; Root = $Root; ExpectedKey = $ExpectedKey; ExpectedVersion = $ExpectedVersion; CorePath = $CorePath; OpenApp = [bool]$OpenApp }
    return [pscustomobject]@{ Id = 321 }
}

function Start-UtApp {
    $script:Calls.StartApp++
}

function Enter-UtLock {
    $script:Calls.Lock++
    if ($null -ne $script:MockLockThrow) { throw $script:MockLockThrow }
    return (New-Object System.IO.MemoryStream)
}

# Forbidden operations: if production ever calls these, the test must notice.
function Remove-AppxPackage { $script:Calls.Remove++ }
function Add-AppxProvisionedPackage { $script:Calls.Provision++ }
function Remove-AppxProvisionedPackage { $script:Calls.Provision++ }

# ---------------------------------------------------------------------------
# Fixture and mock helpers.
# ---------------------------------------------------------------------------
function Add-UtZipEntry {
    param($Zip, [string]$Name, [string]$Text)
    $entry = $Zip.CreateEntry($Name)
    $stream = $entry.Open()
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $writer = New-Object System.IO.StreamWriter($stream, $encoding)
    try { $writer.Write($Text) } finally { $writer.Dispose() }
}

function New-RawZip {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object[]]$Entries)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { }
    try { Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop } catch { }
    if ($null -eq ('System.IO.Compression.ZipArchiveMode' -as [type])) { throw 'System.IO.Compression.ZipArchiveMode is unavailable in this host.' }
    $zip = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($entry in $Entries) { Add-UtZipEntry -Zip $zip -Name ([string]$entry.Name) -Text ([string]$entry.Text) }
    } finally { $zip.Dispose() }
}

function New-FixtureMsix {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ManifestXml)
    New-RawZip -Path $Path -Entries @(@{ Name = 'AppxManifest.xml'; Text = $ManifestXml })
}

function New-ManifestXml {
    param(
        [string]$Name = 'OpenAI.Codex',
        [string]$Publisher = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B',
        [string]$Version = '26.930.7945.0',
        [string]$Architecture = 'x64',
        [string]$Namespace = 'http://schemas.microsoft.com/appx/manifest/foundation/windows10',
        [string]$DeviceFamilyXml = '<TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.17763.0" MaxVersionTested="10.0.26100.0" />',
        [string]$DependenciesExtra = '',
        [switch]$NoDependencies,
        [switch]$DuplicateIdentity
    )
    return @"
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="$Namespace">
  <Identity Name="$Name" Publisher="$Publisher" Version="$Version" ProcessorArchitecture="$Architecture" />
$(if ($DuplicateIdentity) { "  <Identity Name=`"$Name`" Publisher=`"$Publisher`" Version=`"$Version`" ProcessorArchitecture=`"$Architecture`" />" })
  <Properties>
    <DisplayName>ChatGPT</DisplayName>
    <PublisherDisplayName>OpenAI</PublisherDisplayName>
    <Logo>Assets\StoreLogo.png</Logo>
  </Properties>
$(if ($NoDependencies) { '  <Dependencies />' } else { "  <Dependencies>`n    $DeviceFamilyXml`n    $DependenciesExtra`n  </Dependencies>" })
</Package>
"@
}

function New-ValidFixtureFile {
    param(
        [string]$Version = '26.930.7945.0',
        [string]$Architecture = 'x64',
        [string]$DeviceFamilyXml = '<TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.17763.0" MaxVersionTested="10.0.26100.0" />',
        [string]$DependenciesExtra = '',
        [string]$Name = 'OpenAI.Codex',
        [string]$Publisher = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'
    )
    $path = Join-Path $script:FixtureDir ([guid]::NewGuid().ToString('N') + '.msix')
    $xml = New-ManifestXml -Name $Name -Publisher $Publisher -Version $Version -Architecture $Architecture -DeviceFamilyXml $DeviceFamilyXml -DependenciesExtra $DependenciesExtra
    New-FixtureMsix -Path $path -ManifestXml $xml
    return $path
}

function New-ManifestDocument {
    param([string]$Xml)
    $path = Join-Path $script:FixtureDir ([guid]::NewGuid().ToString('N') + '.msix')
    New-FixtureMsix -Path $path -ManifestXml $Xml
    return (Read-UtManifestXml -Path $path)
}

function New-MockPackage {
    param(
        [string]$Name = 'OpenAI.Codex',
        [string]$Family = 'OpenAI.Codex_2p2nqsd0c76g0',
        [string]$Version = '26.707.3748.0',
        [string]$Status = 'Ok',
        [string]$Architecture = 'X64',
        [string]$Publisher = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B',
        [bool]$IsFramework = $true
    )
    return [pscustomobject]@{
        Name = $Name
        PackageFamilyName = $Family
        Version = $Version
        Status = $Status
        Architecture = $Architecture
        Publisher = $Publisher
        IsFramework = $IsFramework
        PackageFullName = ("{0}_{1}_{2}__{3}" -f $Name, $Version, $Architecture, $Family)
    }
}

function New-MockHead {
    param(
        [string]$Version = '26.930.7945.0',
        [long]$Length = 12345,
        [string]$ETag = '"0xSTRONGETAG"',
        [int]$StatusCode = 200,
        [string]$FinalUri = 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix',
        [string]$Architecture = 'x64',
        [string]$Identity = 'OpenAI.Codex',
        [switch]$OmitVersion,
        [switch]$OmitLength,
        [switch]$OmitETag
    )
    $headers = @{}
    if (-not $OmitVersion) { $headers['x-ms-meta-package_version'] = @($Version) }
    if (-not $OmitLength) { $headers['content-length'] = @([string]$Length) }
    if (-not $OmitETag -and -not [string]::IsNullOrEmpty($ETag)) { $headers['etag'] = @($ETag) }
    if (-not [string]::IsNullOrEmpty($Architecture)) { $headers['x-ms-meta-architecture'] = @($Architecture) }
    if (-not [string]::IsNullOrEmpty($Identity)) { $headers['x-ms-meta-package_identity'] = @($Identity) }
    return [pscustomobject]@{ StatusCode = $StatusCode; FinalUri = $FinalUri; Headers = $headers }
}

function Set-InstalledSequence {
    param([Parameter(Mandatory = $true)][object[]]$Items)
    $queue = New-Object System.Collections.ArrayList
    foreach ($item in $Items) { [void]$queue.Add($item) }
    $script:MockRawQueue['OpenAI.Codex'] = $queue
}

function Set-ValidUpdateHead {
    param([string]$FixturePath, [string]$Version = '26.930.7945.0', [string]$Architecture = 'x64')
    $length = (Get-Item -LiteralPath $FixturePath).Length
    $script:MockHead = New-MockHead -Version $Version -Length $length -Architecture $Architecture
    $script:MockFixturePath = $FixturePath
}

function Invoke-Production {
    param([switch]$CheckOnly, [switch]$DownloadOnly, [switch]$OpenApp, [int]$Connections = 1)
    $bound = @{}
    if ($CheckOnly) { $bound['CheckOnly'] = $true }
    if ($DownloadOnly) { $bound['DownloadOnly'] = $true }
    if ($OpenApp) { $bound['OpenApp'] = $true }
    $bound['Connections'] = $Connections
    if ($env:UT_TEST_SHOW) { return [int](Invoke-UtUpdater @bound) }
    return [int](Invoke-UtUpdater @bound 6>$null)
}

function Invoke-ProductionOutput {
    # Captures the production information stream (Write-Host) via the common
    # -InformationVariable parameter while still discarding the console copy.
    param([switch]$CheckOnly, [switch]$DownloadOnly, [switch]$OpenApp, [int]$Connections = 1)
    $bound = @{}
    if ($CheckOnly) { $bound['CheckOnly'] = $true }
    if ($DownloadOnly) { $bound['DownloadOnly'] = $true }
    if ($OpenApp) { $bound['OpenApp'] = $true }
    $bound['Connections'] = $Connections
    $information = $null
    $code = Invoke-UtUpdater @bound -InformationVariable information 6>$null
    return [pscustomobject]@{ Code = [int]$code; Text = (@($information) | Out-String) }
}

function New-ValidUpdateScenario {
    param([string]$Version = '26.930.7945.0', [string]$InstalledVersion = '26.707.3748.0')
    $fixture = New-ValidFixtureFile -Version $Version
    Set-ValidUpdateHead -FixturePath $fixture -Version $Version
    Set-InstalledSequence -Items @((New-MockPackage -Version $InstalledVersion), (New-MockPackage -Version $InstalledVersion), (New-MockPackage -Version $InstalledVersion), (New-MockPackage -Version $Version))
    return $fixture
}

function New-SentinelSnapshot {
    param([string]$Root)
    $snapshot = @{}
    foreach ($relative in @('Packages\OpenAI.Codex_2p2nqsd0c76g0', 'OpenAI', '.codex')) {
        $dir = Join-Path $Root $relative
        $null = New-Item -ItemType Directory -Path $dir -Force
        $file = Join-Path $dir 'keep.txt'
        Set-Content -LiteralPath $file -Value ('SENTINEL ' + $relative) -Encoding UTF8
        $snapshot[$file] = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    }
    return $snapshot
}

# ---------------------------------------------------------------------------
# Global test setup.
# ---------------------------------------------------------------------------
Reset-MockState
$script:Sentinel = New-SentinelSnapshot -Root $script:IsolatedRoot

Write-Host 'ChatGPT updater offline tests'
Write-Host ("Isolated LOCALAPPDATA: {0}" -f $script:IsolatedRoot)
Write-Host ''

Invoke-Case 'dot-sourcing core leaves the confirmation UI unloaded' {
    Assert-Null (Get-Command Get-UbProperty -CommandType Function -ErrorAction SilentlyContinue) 'background UI helpers are not loaded by core dot-sourcing'
    Assert-Null (Get-Command Invoke-UbConfirmationPrompt -CommandType Function -ErrorAction SilentlyContinue) 'confirmation prompt is not loaded by core dot-sourcing'
}

# ===========================================================================
# 1-3: version decisions
# ===========================================================================
Invoke-Case 'installed == latest: no download, no deploy' {
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.930.7945.0'))
    $script:MockHead = New-MockHead -Version '26.930.7945.0' -Length 12345
    $code = Invoke-Production
    Assert-Equal 0 $code 'exit code 0'
    Assert-Equal 1 $script:Calls.Head 'one HEAD'
    Assert-Equal 0 $script:Calls.Download 'no download'
    Assert-Equal 0 $script:Calls.Deploy 'no deploy'
}

Invoke-Case 'installed < latest: download, verify, mock deploy' {
    $fixture = New-ValidFixtureFile -Version '26.930.7945.0'
    Set-ValidUpdateHead -FixturePath $fixture -Version '26.930.7945.0'
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.930.7945.0'))
    $code = Invoke-Production
    Assert-Equal 0 $code 'exit code 0'
    Assert-Equal 1 $script:Calls.Download 'one download'
    Assert-Equal 2 $script:Calls.Signature 'preparation and confirmation signature checks (mocked API)'
    Assert-Equal 1 $script:Calls.Deploy 'one deploy'
    Assert-Equal 0 $script:Calls.StartApp 'app not launched'
    Assert-Equal $script:MockHead.Headers['etag'][0] $script:LastIfMatch 'strong ETag sent as If-Match'
    Assert-True (-not (Test-Path -LiteralPath (Split-Path -Parent $script:LastDownloadOutput))) 'successful normal update removed its run directory'
    Assert-SentinelSnapshot $script:Sentinel 'user data untouched'
}

Invoke-Case 'installed > latest: no download, no downgrade' {
    Set-InstalledSequence -Items @((New-MockPackage -Version '99.0.0.0'))
    $script:MockHead = New-MockHead -Version '26.930.7945.0' -Length 12345
    $code = Invoke-Production
    Assert-Equal 0 $code 'exit code 0'
    Assert-Equal 0 $script:Calls.Download 'no download'
    Assert-Equal 0 $script:Calls.Deploy 'no deploy'
}

# ===========================================================================
# 4: not installed / query errors
# ===========================================================================
Invoke-Case 'not installed: enters candidate flow and mock deploys' {
    $fixture = New-ValidFixtureFile -Version '26.930.7945.0'
    Set-ValidUpdateHead -FixturePath $fixture -Version '26.930.7945.0'
    Set-InstalledSequence -Items @($script:UninstalledSentinel, $script:UninstalledSentinel, $script:UninstalledSentinel, (New-MockPackage -Version '26.930.7945.0'))
    $code = Invoke-Production
    Assert-Equal 0 $code 'exit code 0'
    Assert-Equal 1 $script:Calls.Download 'one download'
    Assert-Equal 1 $script:Calls.Deploy 'one deploy'
}

Invoke-Case 'query error is not treated as not-installed' {
    $script:MockRawThrow['OpenAI.Codex'] = 'simulated query failure'
    $code = Invoke-Production
    Assert-Equal 13 $code 'installed-state failure code'
    Assert-Equal 0 $script:Calls.Head 'no HEAD after query failure'
    Assert-Equal 0 $script:Calls.Download 'no download'
    Assert-Equal 0 $script:Calls.Deploy 'no deploy'
}

# ===========================================================================
# 5: invalid installed state
# ===========================================================================
Invoke-Case 'same Name, different PackageFamily: reject' {
    $script:MockRawPackages['OpenAI.Codex'] = @((New-MockPackage -Family 'OpenAI.Codex_OTHERFAMILY'))
    $code = Invoke-Production
    Assert-Equal 13 $code 'installed-state failure code'
    Assert-Equal 0 $script:Calls.Head 'no HEAD'
}

Invoke-Case 'multiple installed packages: reject' {
    $script:MockRawPackages['OpenAI.Codex'] = @((New-MockPackage -Version '26.1.0.0'), (New-MockPackage -Version '26.2.0.0'))
    $code = Invoke-Production
    Assert-Equal 13 $code 'installed-state failure code'
    Assert-Equal 0 $script:Calls.Deploy 'no deploy'
}

Invoke-Case 'installed Status not Ok: reject' {
    $script:MockRawPackages['OpenAI.Codex'] = @((New-MockPackage -Status 'Modified'))
    $code = Invoke-Production
    Assert-Equal 13 $code 'installed-state failure code'
    Assert-Equal 0 $script:Calls.Head 'no HEAD'
}

# ===========================================================================
# 6: signature
# ===========================================================================
Invoke-Case 'invalid signature: reject, no deploy' {
    $fixture = New-ValidFixtureFile -Version '26.930.7945.0'
    Set-ValidUpdateHead -FixturePath $fixture -Version '26.930.7945.0'
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'))
    $script:MockSignatureStatus = 'HashMismatch'
    $code = Invoke-Production
    Assert-Equal 7 $code 'security failure code'
    Assert-Equal 1 $script:Calls.Download 'download happened'
    Assert-Equal 0 $script:Calls.Deploy 'no deploy'
    Assert-SentinelSnapshot $script:Sentinel 'user data untouched'
}

Invoke-Case 'signature API exception: reject, no deploy' {
    $fixture = New-ValidFixtureFile -Version '26.930.7945.0'
    Set-ValidUpdateHead -FixturePath $fixture -Version '26.930.7945.0'
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'))
    $script:MockSignatureThrow = 'simulated Authenticode failure'
    $code = Invoke-Production
    Assert-Equal 7 $code 'security failure code'
    Assert-Equal 0 $script:Calls.Deploy 'no deploy'
}

# ===========================================================================
# 7: wrong identity fields
# ===========================================================================
Invoke-Case 'wrong manifest Name: reject, no deploy' {
    $fixture = New-ValidFixtureFile -Version '26.930.7945.0' -Name 'Evil.App'
    Set-ValidUpdateHead -FixturePath $fixture -Version '26.930.7945.0'
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.930.7945.0'))
    $code = Invoke-Production
    Assert-Equal 7 $code 'security failure code'
    Assert-Equal 0 $script:Calls.Deploy 'no deploy'
}

Invoke-Case 'wrong manifest Publisher: reject, no deploy' {
    $fixture = New-ValidFixtureFile -Version '26.930.7945.0' -Publisher 'CN=ATTACKER'
    Set-ValidUpdateHead -FixturePath $fixture -Version '26.930.7945.0'
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'))
    $code = Invoke-Production
    Assert-Equal 7 $code 'security failure code'
    Assert-Equal 0 $script:Calls.Deploy 'no deploy'
}

Invoke-Case 'wrong manifest Architecture: reject, no deploy' {
    $fixture = New-ValidFixtureFile -Version '26.930.7945.0' -Architecture 'arm64'
    Set-ValidUpdateHead -FixturePath $fixture -Version '26.930.7945.0'
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'))
    $code = Invoke-Production
    Assert-Equal 7 $code 'security failure code'
    Assert-Equal 0 $script:Calls.Deploy 'no deploy'
}

# ===========================================================================
# 8: manifest robustness (production parser)
# ===========================================================================
Invoke-Case 'manifest: missing / duplicate / case-ambiguous rejected' {
    $missing = Join-Path $script:FixtureDir 'missing.msix'
    New-RawZip -Path $missing -Entries @(@{ Name = 'Other.txt'; Text = 'no manifest' })
    Assert-UtFailure 7 { Read-UtManifestXml -Path $missing } 'missing manifest rejected'

    $duplicate = Join-Path $script:FixtureDir 'duplicate.msix'
    $xml = New-ManifestXml
    New-RawZip -Path $duplicate -Entries @(@{ Name = 'AppxManifest.xml'; Text = $xml }, @{ Name = 'AppxManifest.xml'; Text = $xml })
    Assert-UtFailure 7 { Read-UtManifestXml -Path $duplicate } 'duplicate manifest rejected'

    $lower = Join-Path $script:FixtureDir 'lower.msix'
    New-RawZip -Path $lower -Entries @(@{ Name = 'appxmanifest.xml'; Text = $xml })
    Assert-UtFailure 7 { Read-UtManifestXml -Path $lower } 'non-canonical manifest name rejected'

    $both = Join-Path $script:FixtureDir 'both.msix'
    New-RawZip -Path $both -Entries @(@{ Name = 'AppxManifest.xml'; Text = $xml }, @{ Name = 'APPXMANIFEST.XML'; Text = $xml })
    Assert-UtFailure 7 { Read-UtManifestXml -Path $both } 'case-ambiguous manifest rejected'
}

Invoke-Case 'manifest: oversize / DTD / malformed rejected' {
    $oversize = Join-Path $script:FixtureDir 'oversize.msix'
    $big = '<!--' + ('x' * 1100000) + '-->'
    New-FixtureMsix -Path $oversize -ManifestXml $big
    Assert-UtFailure 7 { Read-UtManifestXml -Path $oversize } 'oversize manifest rejected'

    $dtd = Join-Path $script:FixtureDir 'dtd.msix'
    $dtdXml = "<?xml version=`"1.0`"?><!DOCTYPE Package [ <!ENTITY xxe `"xxe`"> ]><Package xmlns=`"http://schemas.microsoft.com/appx/manifest/foundation/windows10`"><Identity Name=`"OpenAI.Codex`" Publisher=`"CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B`" Version=`"26.930.7945.0`" ProcessorArchitecture=`"x64`" /></Package>"
    New-FixtureMsix -Path $dtd -ManifestXml $dtdXml
    Assert-UtFailure 7 { Read-UtManifestXml -Path $dtd } 'DTD rejected'

    $malformed = Join-Path $script:FixtureDir 'malformed.msix'
    New-FixtureMsix -Path $malformed -ManifestXml '<Package><Identity Name="x"'
    Assert-UtFailure 7 { Read-UtManifestXml -Path $malformed } 'malformed XML rejected'
}

Invoke-Case 'manifest: wrong namespace / duplicate Identity / invalid version rejected' {
    $wrongNs = New-ManifestXml -Namespace 'urn:not:appx'
    Assert-UtFailure 7 { Read-UtManifestIdentity -Document (New-ManifestDocument -Xml $wrongNs) } 'wrong namespace rejected'

    $dup = New-ManifestXml -DuplicateIdentity
    Assert-UtFailure 7 { Read-UtManifestIdentity -Document (New-ManifestDocument -Xml $dup) } 'duplicate Identity rejected'

    $badVersion = New-ManifestXml -Version '1.2.3'
    Assert-UtFailure 7 { Read-UtManifestIdentity -Document (New-ManifestDocument -Xml $badVersion) } 'invalid version rejected'
}

Invoke-Case 'manifest rejection in full flow does not deploy' {
    $fixture = Join-Path $script:FixtureDir ([guid]::NewGuid().ToString('N') + '.msix')
    New-FixtureMsix -Path $fixture -ManifestXml (New-ManifestXml -Namespace 'urn:not:appx')
    Set-ValidUpdateHead -FixturePath $fixture -Version '26.930.7945.0'
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'))
    $code = Invoke-Production
    Assert-Equal 7 $code 'security failure code'
    Assert-Equal 0 $script:Calls.Deploy 'no deploy'
}

# ===========================================================================
# 9-11: Windows compatibility
# ===========================================================================
Invoke-Case 'Windows below Desktop MinVersion: reject; invalid version rejected separately' {
    $doc = New-ManifestDocument -Xml (New-ManifestXml -DeviceFamilyXml '<TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.30000.0" />')
    Assert-UtFailure 8 { Assert-UtCompatibility -Document $doc -WindowsVersion ([version]'10.0.26100.0') } 'Windows below MinVersion rejected'

    $invalid = New-ManifestDocument -Xml (New-ManifestXml -DeviceFamilyXml '<TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.99999.0" />')
    Assert-UtFailure 8 { Assert-UtCompatibility -Document $invalid -WindowsVersion ([version]'10.0.26100.0') } 'version above the MSIX range rejected'
}

Invoke-Case 'Universal satisfied but Desktop not: reject (no bypass)' {
    $deviceXml = '<TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.30000.0" /><TargetDeviceFamily Name="Windows.Universal" MinVersion="10.0.10240.0" />'
    $doc = New-ManifestDocument -Xml (New-ManifestXml -DeviceFamilyXml $deviceXml)
    Assert-UtFailure 8 { Assert-UtCompatibility -Document $doc -WindowsVersion ([version]'10.0.26100.0') } 'lower Universal must not bypass Desktop'
}

Invoke-Case 'Mobile-only family rejected; Windows above MaxVersionTested accepted' {
    $mobile = New-ManifestDocument -Xml (New-ManifestXml -DeviceFamilyXml '<TargetDeviceFamily Name="Windows.Mobile" MinVersion="10.0.10240.0" />')
    Assert-UtFailure 8 { Assert-UtCompatibility -Document $mobile -WindowsVersion ([version]'10.0.26100.0') } 'Mobile-only rejected'

    $aboveTested = New-ManifestDocument -Xml (New-ManifestXml -DeviceFamilyXml '<TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.17763.0" MaxVersionTested="10.0.19041.0" />')
    $ok = $true
    try { $null = Assert-UtCompatibility -Document $aboveTested -WindowsVersion ([version]'10.0.26100.0') } catch { $ok = $false }
    Assert-True $ok 'Windows above MaxVersionTested must not be rejected'
}

# ===========================================================================
# 12-13: dependencies
# ===========================================================================
$script:DepName = 'Microsoft.WindowsAppRuntime.1.5'
$script:DepPublisher = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
$script:DepXml = ('<PackageDependency Name="{0}" Publisher="{1}" MinVersion="5001.0.0.0" />' -f $script:DepName, $script:DepPublisher)
$script:Uap6Ns = 'http://schemas.microsoft.com/appx/manifest/uap/windows10/6'

function New-DependencyPackage {
    param(
        [string]$Name = $script:DepName,
        [string]$Version = '6001.2.3.0',
        [string]$Architecture = 'Neutral',
        [string]$Status = 'Ok',
        [string]$Publisher = $script:DepPublisher,
        [bool]$IsFramework = $true
    )
    return [pscustomobject]@{ Name = $Name; Publisher = $Publisher; Version = $Version; Architecture = $Architecture; Status = $Status; IsFramework = $IsFramework }
}

Invoke-Case 'dependency missing: reject, no deploy' {
    $fixture = New-ValidFixtureFile -Version '26.930.7945.0' -DependenciesExtra $script:DepXml
    Set-ValidUpdateHead -FixturePath $fixture -Version '26.930.7945.0'
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'))
    $code = Invoke-Production
    Assert-Equal 9 $code 'dependency failure code'
    Assert-Equal 0 $script:Calls.Deploy 'no deploy'
}

Invoke-Case 'dependency publisher/version/arch/status/name/framework failures rejected' {
    $doc = New-ManifestDocument -Xml (New-ManifestXml -DependenciesExtra $script:DepXml)

    $script:MockRawPackages[$script:DepName] = @(New-DependencyPackage -Publisher 'CN=WRONG')
    Assert-UtFailure 9 { Assert-UtDependencies -Document $doc -Architecture 'x64' } 'wrong publisher rejected'

    $script:MockRawPackages[$script:DepName] = @(New-DependencyPackage -Version '4000.0.0.0')
    Assert-UtFailure 9 { Assert-UtDependencies -Document $doc -Architecture 'x64' } 'low version rejected'

    $script:MockRawPackages[$script:DepName] = @(New-DependencyPackage -Architecture 'Arm64')
    Assert-UtFailure 9 { Assert-UtDependencies -Document $doc -Architecture 'x64' } 'wrong architecture rejected'

    $script:MockRawPackages[$script:DepName] = @(New-DependencyPackage -Status 'Modified')
    Assert-UtFailure 9 { Assert-UtDependencies -Document $doc -Architecture 'x64' } 'bad dependency status rejected'

    $script:MockRawPackages[$script:DepName] = @(New-DependencyPackage -Name 'Other.Package')
    Assert-UtFailure 9 { Assert-UtDependencies -Document $doc -Architecture 'x64' } 'wrong package Name rejected'

    $script:MockRawPackages[$script:DepName] = @(New-DependencyPackage -IsFramework $false)
    Assert-UtFailure 9 { Assert-UtDependencies -Document $doc -Architecture 'x64' } 'non-framework package rejected'
}

Invoke-Case 'uap6 Optional semantics: true/1 skip, false/0 required, no-namespace cannot bypass' {
    $optionalTrue = ('<PackageDependency xmlns:uap6="{0}" uap6:Optional="true" Name="{1}" Publisher="{2}" MinVersion="5001.0.0.0" />' -f $script:Uap6Ns, $script:DepName, $script:DepPublisher)
    $optionalOne = ('<PackageDependency xmlns:uap6="{0}" uap6:Optional="1" Name="{1}" Publisher="{2}" MinVersion="5001.0.0.0" />' -f $script:Uap6Ns, $script:DepName, $script:DepPublisher)
    $optionalFalse = ('<PackageDependency xmlns:uap6="{0}" uap6:Optional="false" Name="{1}" Publisher="{2}" MinVersion="5001.0.0.0" />' -f $script:Uap6Ns, $script:DepName, $script:DepPublisher)
    $optionalZero = ('<PackageDependency xmlns:uap6="{0}" uap6:Optional="0" Name="{1}" Publisher="{2}" MinVersion="5001.0.0.0" />' -f $script:Uap6Ns, $script:DepName, $script:DepPublisher)
    $noNamespace = ('<PackageDependency Optional="true" Name="{0}" Publisher="{1}" MinVersion="5001.0.0.0" />' -f $script:DepName, $script:DepPublisher)

    foreach ($xml in @($optionalTrue, $optionalOne)) {
        $doc = New-ManifestDocument -Xml (New-ManifestXml -DependenciesExtra $xml)
        $ok = $true
        try { Assert-UtDependencies -Document $doc -Architecture 'x64' } catch { $ok = $false }
        Assert-True $ok ('uap6 Optional should make the missing dependency acceptable: ' + $xml)
    }

    foreach ($xml in @($optionalFalse, $optionalZero)) {
        $doc = New-ManifestDocument -Xml (New-ManifestXml -DependenciesExtra $xml)
        Assert-UtFailure 9 { Assert-UtDependencies -Document $doc -Architecture 'x64' } ('uap6 Optional false/0 must stay required: ' + $xml)
    }

    $doc = New-ManifestDocument -Xml (New-ManifestXml -DependenciesExtra $noNamespace)
    Assert-UtFailure 9 { Assert-UtDependencies -Document $doc -Architecture 'x64' } 'non-namespaced Optional must not bypass a required dependency'
}

Invoke-Case 'foreign-namespace and duplicate dependency declarations rejected' {
    $foreign = ('<x:PackageDependency xmlns:x="urn:foreign" Name="{0}" Publisher="{1}" MinVersion="5001.0.0.0" />' -f $script:DepName, $script:DepPublisher)
    $doc = New-ManifestDocument -Xml (New-ManifestXml -DependenciesExtra $foreign)
    Assert-UtFailure 9 { Assert-UtDependencies -Document $doc -Architecture 'x64' } 'foreign namespace dependency rejected'

    $duplicate = ($script:DepXml + $script:DepXml)
    $doc2 = New-ManifestDocument -Xml (New-ManifestXml -DependenciesExtra $duplicate)
    Assert-UtFailure 9 { Assert-UtDependencies -Document $doc2 -Architecture 'x64' } 'duplicate dependency declaration rejected'
}

Invoke-Case 'valid Neutral framework accepted; full flow deploys' {
    $fixture = New-ValidFixtureFile -Version '26.930.7945.0' -DependenciesExtra $script:DepXml
    Set-ValidUpdateHead -FixturePath $fixture -Version '26.930.7945.0'
    $script:MockRawPackages[$script:DepName] = @(New-DependencyPackage -Version '6001.2.3.0' -Architecture 'Neutral' -IsFramework $true)
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.930.7945.0'))
    $code = Invoke-Production
    Assert-Equal 0 $code 'exit code 0'
    Assert-Equal 1 $script:Calls.Deploy 'deploy happened'
}

Invoke-Case 'unsupported dependency element rejected' {
    $doc = New-ManifestDocument -Xml (New-ManifestXml -DependenciesExtra '<MainPackageDependency Name="Foo" Publisher="CN=Foo" />')
    Assert-UtFailure 9 { Assert-UtDependencies -Document $doc -Architecture 'x64' } 'unknown dependency element rejected'
}

# ===========================================================================
# 14: download failures
# ===========================================================================
Invoke-Case 'download failures never deploy and never touch user data' {
    $null = New-ValidUpdateScenario
    $script:MockDownloadExitCode = 22
    $script:MockDownloadHttpCode = 404
    Assert-Equal 6 (Invoke-Production) 'curl failure -> download code'
    Assert-Equal 0 $script:Calls.Deploy 'no deploy after curl failure'

    Reset-MockState
    $null = New-ValidUpdateScenario
    $script:MockDownloadBytes = 0
    Assert-Equal 6 (Invoke-Production) 'empty file -> download code'
    Assert-Equal 0 $script:Calls.Deploy 'no deploy after empty file'

    Reset-MockState
    $null = New-ValidUpdateScenario
    $script:MockDownloadBytes = 10
    Assert-Equal 6 (Invoke-Production) 'length mismatch -> download code'
    Assert-Equal 0 $script:Calls.Deploy 'no deploy after length mismatch'

    Reset-MockState
    $null = New-ValidUpdateScenario
    $script:MockDownloadSkipFile = $true
    Assert-Equal 6 (Invoke-Production) 'missing output -> download code'
    Assert-Equal 0 $script:Calls.Deploy 'no deploy after missing output'

    Reset-MockState
    $null = New-ValidUpdateScenario
    $script:MockDownloadHttpCode = 204
    Assert-Equal 6 (Invoke-Production) 'HTTP 204 with curl exit 0 must fail'
    Assert-Equal 0 $script:Calls.Deploy 'no deploy after HTTP 204'

    Reset-MockState
    $null = New-ValidUpdateScenario
    $script:MockDownloadHttpCode = 302
    Assert-Equal 6 (Invoke-Production) 'HTTP 302 redirect with curl exit 0 must fail'
    Assert-Equal 0 $script:Calls.Deploy 'no deploy after HTTP 302'

    Reset-MockState
    $null = New-ValidUpdateScenario
    $script:MockDownloadOmitFinalUrl = $true
    Assert-Equal 6 (Invoke-Production) 'missing FINALURL must fail'
    Assert-Equal 0 $script:Calls.Deploy 'no deploy after missing FINALURL'

    Reset-MockState
    $null = New-ValidUpdateScenario
    $script:MockDownloadFinalUrl = 'https://evil.example/ChatGPT-x64.msix'
    Assert-Equal 6 (Invoke-Production) 'unconfirmed final host must fail'
    Assert-Equal 0 $script:Calls.Deploy 'no deploy after unconfirmed final host'

    Assert-Equal 0 $script:Calls.Remove 'no uninstall'
    Assert-SentinelSnapshot $script:Sentinel 'user data untouched after download failures'
}

# ===========================================================================
# 15: HEAD metadata failures
# ===========================================================================
Invoke-Case 'HEAD metadata failures: no download, no deploy' {
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'))
    $script:MockHead = New-MockHead -OmitVersion
    Assert-Equal 5 (Invoke-Production) 'missing version header'
    Assert-Equal 0 $script:Calls.Download 'no download (missing version)'

    Reset-MockState
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'))
    $script:MockHead = New-MockHead -Version 'not-a-version'
    Assert-Equal 5 (Invoke-Production) 'invalid version header'
    Assert-Equal 0 $script:Calls.Download 'no download (invalid version)'

    Reset-MockState
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'))
    $script:MockHead = New-MockHead -OmitLength
    Assert-Equal 5 (Invoke-Production) 'missing content-length'
    Assert-Equal 0 $script:Calls.Download 'no download (missing length)'

    Reset-MockState
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'))
    $script:MockHead = New-MockHead -Length 0
    Assert-Equal 5 (Invoke-Production) 'non-positive content-length'
    Assert-Equal 0 $script:Calls.Download 'no download (zero length)'

    Reset-MockState
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'))
    $emptyEtag = New-MockHead
    $emptyEtag.Headers['etag'] = @('')
    $script:MockHead = $emptyEtag
    Assert-Equal 5 (Invoke-Production) 'present but empty ETag header is invalid'
    Assert-Equal 0 $script:Calls.Download 'no download (empty ETag)'

    Reset-MockState
    $missingEtag = New-MockHead -OmitETag
    $missingMetadata = Get-UtRemoteMetadata -HeadResult $missingEtag -Architecture 'x64' -RequestedUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix'
    Assert-Equal 'Missing' $missingMetadata.ETagKind 'missing ETag is classified explicitly'

    Reset-MockState
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'))
    $script:MockHead = New-MockHead -StatusCode 500
    Assert-Equal 5 (Invoke-Production) 'HTTP error status'
    Assert-Equal 0 $script:Calls.Download 'no download (HTTP 500)'

    Reset-MockState
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'))
    $script:MockHead = New-MockHead -FinalUri 'https://evil.example/ChatGPT-x64.msix'
    Assert-Equal 5 (Invoke-Production) 'unconfirmed final host'
    Assert-Equal 0 $script:Calls.Download 'no download (unconfirmed host)'

    Reset-MockState
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'))
    $script:MockHead = New-MockHead -FinalUri ''
    Assert-Equal 5 (Invoke-Production) 'missing final URL'
    Assert-Equal 0 $script:Calls.Download 'no download (missing final URL)'

    Reset-MockState
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'))
    $script:MockHeadThrow = (New-UtFailure -Code 4 -Message 'simulated curl failure')
    Assert-Equal 4 (Invoke-Production) 'HEAD transport failure'
    Assert-Equal 0 $script:Calls.Download 'no download (HEAD transport failure)'

    Assert-Equal 0 $script:Calls.Remove 'no uninstall'
}

# ===========================================================================
# 16: HEAD vs candidate consistency
# ===========================================================================
Invoke-Case 'HEAD version differs from manifest version: reject' {
    $fixture = New-ValidFixtureFile -Version '26.800.0.0'
    Set-ValidUpdateHead -FixturePath $fixture -Version '26.930.7945.0'
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'))
    $code = Invoke-Production
    Assert-Equal 6 $code 'CDN/manifest mismatch code'
    Assert-Equal 0 $script:Calls.Deploy 'no deploy'
}

Invoke-Case 'If-Match 412: stop and do not deploy' {
    $fixture = New-ValidFixtureFile -Version '26.930.7945.0'
    Set-ValidUpdateHead -FixturePath $fixture -Version '26.930.7945.0'
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'))
    $script:MockDownloadHttpCode = 412
    $code = Invoke-Production
    Assert-Equal 6 $code 'precondition failure code'
    Assert-Equal 1 $script:Calls.Download 'download attempted'
    Assert-Equal 0 $script:Calls.Deploy 'no deploy'
}

Invoke-Case 'weak ETag is not sent as If-Match' {
    $fixture = New-ValidFixtureFile -Version '26.930.7945.0'
    $length = (Get-Item -LiteralPath $fixture).Length
    $script:MockHead = New-MockHead -Version '26.930.7945.0' -Length $length -ETag 'W/"weak-etag"'
    $script:MockFixturePath = $fixture
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.930.7945.0'))
    $code = Invoke-Production
    Assert-Equal 0 $code 'exit code 0'
    Assert-Null $script:LastIfMatch 'weak ETag must not be used as If-Match'

    Reset-MockState
    $fixture = New-ValidFixtureFile -Version '26.930.7945.0'
    $length = (Get-Item -LiteralPath $fixture).Length
    $script:MockHead = New-MockHead -Version '26.930.7945.0' -Length $length -OmitETag
    $script:MockFixturePath = $fixture
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.930.7945.0'))
    $code = Invoke-Production
    Assert-Equal 0 $code 'missing ETag uses the safe serial backend'
    Assert-Null $script:LastIfMatch 'missing ETag must not be used as If-Match'
}

Invoke-Case 'serial response headers must match the HEAD snapshot' {
    $newFixture = New-ValidFixtureFile -Version '26.930.7945.0'
    Set-ValidUpdateHead -FixturePath $newFixture -Version '26.930.7945.0'
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'))

    $missing = @{}
    foreach ($name in $script:MockHead.Headers.Keys) { $missing[$name] = @($script:MockHead.Headers[$name]) }
    [void]$missing.Remove('etag')
    $script:MockDownloadHeaders = $missing
    Assert-Equal 6 (Invoke-Production) 'missing response ETag is rejected'
    Assert-Equal 0 $script:Calls.Deploy 'missing response ETag does not deploy'

    Reset-MockState
    Set-ValidUpdateHead -FixturePath $newFixture -Version '26.930.7945.0'
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'))
    $changed = @{}
    foreach ($name in $script:MockHead.Headers.Keys) { $changed[$name] = @($script:MockHead.Headers[$name]) }
    $changed['etag'] = @('"changed-etag"')
    $script:MockDownloadHeaders = $changed
    Assert-Equal 6 (Invoke-Production) 'changed response ETag is rejected'

    Reset-MockState
    Set-ValidUpdateHead -FixturePath $newFixture -Version '26.930.7945.0'
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'))
    $duplicate = @{}
    foreach ($name in $script:MockHead.Headers.Keys) { $duplicate[$name] = @($script:MockHead.Headers[$name]) }
    $duplicate['etag'] = @($script:MockHead.Headers['etag'][0], '"duplicate-etag"')
    $script:MockDownloadHeaders = $duplicate
    Assert-Equal 6 (Invoke-Production) 'duplicate response ETag is rejected'

    Reset-MockState
    Set-ValidUpdateHead -FixturePath $newFixture -Version '26.930.7945.0'
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'))
    $encoded = @{}
    foreach ($name in $script:MockHead.Headers.Keys) { $encoded[$name] = @($script:MockHead.Headers[$name]) }
    $encoded['content-encoding'] = @('gzip')
    $script:MockDownloadHeaders = $encoded
    Assert-Equal 6 (Invoke-Production) 'nonidentity response encoding is rejected'
}

# ===========================================================================
# 16b: network boundary helpers (production code, no real network)
# ===========================================================================
Invoke-Case 'curl argument lists never follow redirects and are hardened' {
    $headArgs = New-UtHeadCurlArguments -Uri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -HeaderFile 'C:\tmp\h.txt'
    Assert-Equal '--disable' $headArgs[0] 'HEAD --disable must be first'
    Assert-True ($headArgs -notcontains '--location') 'HEAD must not use --location'
    Assert-True ($headArgs -contains '--proto') 'HEAD must restrict protocols'
    Assert-True ($headArgs -contains '=https') 'HEAD must restrict to https'
    Assert-True ($headArgs -contains '--proto-redir') 'HEAD must restrict redirect protocols'
    Assert-True ($headArgs -contains '--head') 'HEAD must use --head'

    $downloadArgs = New-UtDownloadCurlArguments -Url 'https://persistent.oaistatic.com/x.msix' -OutputPath 'C:\tmp\out.partial' -IfMatch $null -ConfigPath $null
    Assert-Equal '--disable' $downloadArgs[0] 'download --disable must be first'
    Assert-True ($downloadArgs -notcontains '--location') 'download must not use --location'
    Assert-True ($downloadArgs -contains '--fail') 'download must use --fail'
    Assert-True ($downloadArgs -contains '--proto') 'download must restrict protocols'
    Assert-True ($downloadArgs -contains '--proto-redir') 'download must restrict redirect protocols'

    $backgroundArgs = New-UtDownloadCurlArguments -Url 'https://persistent.oaistatic.com/x.msix' -OutputPath 'C:\tmp\out.partial' -IfMatch $null -ConfigPath 'C:\tmp\request.cfg' -HeaderFile 'C:\tmp\response.headers' -Background
    Assert-True ($backgroundArgs -contains '--silent') 'background download must be quiet'
    Assert-True ($backgroundArgs -notcontains '--progress-bar') 'background download must not emit a progress bar'
    Assert-True ($backgroundArgs -contains '--dump-header') 'download must expose bounded response headers'

    $withMatch = New-UtDownloadCurlArguments -Url 'https://persistent.oaistatic.com/x.msix' -OutputPath 'C:\tmp\out.partial' -IfMatch '"0xETAG"' -ConfigPath 'C:\tmp\ifmatch.cfg'
    Assert-True ($withMatch -contains '--config') 'If-Match must be passed via --config, not a native quoted argv'
    Assert-True ($withMatch -notcontains '--header') 'If-Match must not be a native --header argv'
}

Invoke-Case 'If-Match config line carries the quoted entity tag' {
    $line = New-UtIfMatchConfigLine -ETag '"0x8DF23761D7C5A8B"'
    Assert-Equal 'header = "If-Match: \"0x8DF23761D7C5A8B\""' $line 'exact curl config line'
}

Invoke-Case 'ConvertFrom-UtWriteOut rejects missing or invalid FINALURL' {
    Assert-UtFailure 4 { ConvertFrom-UtWriteOut -Text 'HTTPCODE=200' -RequestedUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -Code 4 } 'missing FINALURL rejected'
    Assert-UtFailure 4 { ConvertFrom-UtWriteOut -Text 'FINALURL=https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -RequestedUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -Code 4 } 'missing HTTPCODE rejected'
    Assert-UtFailure 4 { ConvertFrom-UtWriteOut -Text "HTTPCODE=200`nFINALURL=https://evil.example/codex-app-prod/ChatGPT-x64.msix" -RequestedUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -Code 4 } 'unconfirmed host rejected'
    Assert-UtFailure 4 { ConvertFrom-UtWriteOut -Text "HTTPCODE=200`nFINALURL=not a url" -RequestedUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -Code 4 } 'unparseable URL rejected'
    $valid = ConvertFrom-UtWriteOut -Text "HTTPCODE=200`nFINALURL=https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix" -RequestedUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -Code 4
    Assert-Equal 200 $valid.HttpCode 'valid HTTP code parsed'
    Assert-Equal 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' $valid.FinalUrl 'valid final URL parsed'
}

Invoke-Case 'raw header parser handles proxy CONNECT, duplicates and invalid fields' {
    $headerFile = Join-Path $script:FixtureDir 'headers.txt'
    $sample = @(
        'HTTP/1.1 200 Connection established',
        'Proxy-agent: local',
        '',
        'HTTP/1.1 301 Moved Permanently',
        'Content-Length: 111',
        '',
        'HTTP/1.1 200 OK',
        'Content-Length: 456',
        'x-ms-meta-package_version: 26.930.7945.0',
        'ETag: "abc"'
    ) -join "`n"
    Set-Content -LiteralPath $headerFile -Value $sample -Encoding ASCII
    $parsed = ConvertFrom-UtFinalHeaderBlock -Path $headerFile
    Assert-Equal 200 $parsed.StatusCode 'final block status is used'
    Assert-Equal '456' (Get-UtSingleHeader -Headers $parsed.Headers -Name 'content-length' -Required) 'only the final block is used'
    Assert-UtFailure 5 { Get-UtSingleHeader -Headers @{ 'content-length' = @('1', '2') } -Name 'content-length' -Required } 'duplicate required header rejected'
    Assert-UtFailure 5 { Get-UtSingleHeader -Headers @{} -Name 'x-ms-meta-package_version' -Required } 'missing required header rejected'
    Assert-UtFailure 5 { Get-UtSingleHeader -Headers @{ 'etag' = @('a', 'b') } -Name 'etag' } 'duplicate optional header rejected'
    Assert-Null (Get-UtSingleHeader -Headers @{ 'etag' = @('') } -Name 'etag') 'empty optional header is null'

    $oversizedHeaderFile = Join-Path $script:FixtureDir 'oversized-valid-response.headers'
    $oversizedText = "HTTP/1.1 200 OK`r`nContent-Length: 1`r`nETag: `"abc`"`r`nX-Padding: " + ('a' * ($script:UtMaxResponseHeaderBytes + 1)) + "`r`n"
    [IO.File]::WriteAllText($oversizedHeaderFile, $oversizedText, [Text.Encoding]::ASCII)
    Assert-UtFailure 5 { ConvertFrom-UtFinalHeaderBlock -Path $oversizedHeaderFile } 'oversized HEAD headers fail before parsing with metadata code'
    Assert-UtFailure 6 { ConvertFrom-UtDownloadHeaderBlock -Path $oversizedHeaderFile } 'oversized download headers fail with download code'
}

# ===========================================================================
# 17: installed version changes during download
# ===========================================================================
Invoke-Case 'installed becomes equal or higher during download: no deploy' {
    $null = New-ValidUpdateScenario
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.930.7945.0'))
    Assert-Equal 0 (Invoke-Production) 'equal during download -> exit 0'
    Assert-Equal 1 $script:Calls.Download 'download happened'
    Assert-Equal 0 $script:Calls.Deploy 'no deploy because it is already current'

    Reset-MockState
    $null = New-ValidUpdateScenario
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.999.0.0'))
    Assert-Equal 0 (Invoke-Production) 'higher during download -> exit 0'
    Assert-Equal 1 $script:Calls.Download 'download happened'
    Assert-Equal 0 $script:Calls.Deploy 'no deploy because a newer version appeared'
}

# ===========================================================================
# 18: pre-deploy re-query failures
# ===========================================================================
Invoke-Case 'pre-deploy query failure or family change: reject, no deploy' {
    $fixture = New-ValidFixtureFile -Version '26.930.7945.0'
    Set-ValidUpdateHead -FixturePath $fixture -Version '26.930.7945.0'
    # The confirmation boundary performs a fresh query, then a pre-deploy
    # query.  Put the throw on that third observation so this remains a
    # pre-deploy failure after the UI boundary was introduced.
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.707.3748.0'), @{ Throw = 'simulated pre-deploy query failure' })
    $code = Invoke-Production
    Assert-Equal 10 $code 'pre-deploy query failure code'
    Assert-Equal 0 $script:Calls.Deploy 'no deploy'

    Reset-MockState
    $fixture = New-ValidFixtureFile -Version '26.930.7945.0'
    Set-ValidUpdateHead -FixturePath $fixture -Version '26.930.7945.0'
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Family 'OpenAI.Codex_CHANGED'))
    $code = Invoke-Production
    Assert-Equal 10 $code 'family change code'
    Assert-Equal 0 $script:Calls.Deploy 'no deploy'
}

# ===========================================================================
# 19: deployment errors
# ===========================================================================
Invoke-Case 'Add-AppxPackage D02/D28 failure: non-zero, no kill, no uninstall' {
    foreach ($hresult in @('0x80073D02', '0x80073D28')) {
        Reset-MockState
        $fixture = New-ValidFixtureFile -Version '26.930.7945.0'
        Set-ValidUpdateHead -FixturePath $fixture -Version '26.930.7945.0'
        Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.707.3748.0'))
        $script:MockDeployThrow = ("Add-AppxPackage failed: {0} (0x{1:x8}) ActivityId 11111111-2222-3333-4444-555555555555" -f $hresult, (Get-Random))
        $code = Invoke-Production
        Assert-Equal 10 $code ("deployment failure code for {0}" -f $hresult)
        Assert-Equal 1 $script:Calls.Deploy 'deploy attempted once'
        Assert-Equal 0 $script:Calls.Remove 'no uninstall'
        Assert-Equal 0 $script:Calls.Provision 'no provisioning'
        $keptPackages = @(Get-ChildItem -LiteralPath (Get-UtCachePackagesDirectory) -Filter '*.msix' -File -Force)
        Assert-Equal 1 $keptPackages.Count 'deploy failure keeps the verified cache package for retry'
    }
    Assert-SentinelSnapshot $script:Sentinel 'user data untouched after deploy failure'
}

# ===========================================================================
# 20: post-install verification
# ===========================================================================
Invoke-Case 'post-install missing / low / wrong family / bad status: NOT confirmed' {
    $null = New-ValidUpdateScenario
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.707.3748.0'), $script:UninstalledSentinel)
    $result = Invoke-ProductionOutput
    Assert-Equal 11 $result.Code 'after missing -> not confirmed'
    Assert-Equal 1 $script:Calls.Deploy 'deploy attempted (missing)'
    Assert-True ($result.Text -like '*Installation is NOT confirmed*') 'missing must print NOT confirmed'
    Assert-True ($result.Text -notlike '*Update successful*') 'missing must not print success'

    Reset-MockState
    $null = New-ValidUpdateScenario
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.800.0.0'))
    $result = Invoke-ProductionOutput
    Assert-Equal 11 $result.Code 'after lower version -> not confirmed'
    Assert-True ($result.Text -like '*Installation is NOT confirmed*') 'lower version must print NOT confirmed'
    Assert-True ($result.Text -notlike '*Update successful*') 'lower version must not print success'

    Reset-MockState
    $null = New-ValidUpdateScenario
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Family 'OpenAI.Codex_OTHER'))
    $result = Invoke-ProductionOutput
    Assert-Equal 11 $result.Code 'after wrong family -> not confirmed'
    Assert-True ($result.Text -like '*Installation is NOT confirmed*') 'wrong family must print NOT confirmed'
    Assert-True ($result.Text -notlike '*Update successful*') 'wrong family must not print success'

    Reset-MockState
    $null = New-ValidUpdateScenario
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Status 'Modified'))
    $result = Invoke-ProductionOutput
    Assert-Equal 11 $result.Code 'after bad status -> not confirmed'
    Assert-True ($result.Text -like '*Installation is NOT confirmed*') 'bad status must print NOT confirmed'
    Assert-True ($result.Text -notlike '*Update successful*') 'bad status must not print success'

    Assert-Equal 0 $script:Calls.Remove 'no uninstall on failed verification'
}

# ===========================================================================
# 21: CheckOnly
# ===========================================================================
Invoke-Case 'CheckOnly with and without update: no download, no deploy' {
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'))
    $script:MockHead = New-MockHead -Version '26.930.7945.0' -Length 12345
    Assert-Equal 0 (Invoke-Production -CheckOnly) 'check-only with update exits 0'
    Assert-Equal 0 $script:Calls.Download 'no download'
    Assert-Equal 0 $script:Calls.Deploy 'no deploy'

    Reset-MockState
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.930.7945.0'))
    $script:MockHead = New-MockHead -Version '26.930.7945.0' -Length 12345
    Assert-Equal 0 (Invoke-Production -CheckOnly) 'check-only up to date exits 0'
    Assert-Equal 0 $script:Calls.Download 'no download'
    Assert-Equal 0 $script:Calls.Deploy 'no deploy'
}

# ===========================================================================
# 22: DownloadOnly
# ===========================================================================
Invoke-Case 'DownloadOnly: verifies and keeps the file, deploy count is zero' {
    $fixture = New-ValidFixtureFile -Version '26.930.7945.0'
    Set-ValidUpdateHead -FixturePath $fixture -Version '26.930.7945.0'
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'))
    $code = Invoke-Production -DownloadOnly
    Assert-Equal 0 $code 'exit code 0'
    Assert-Equal 1 $script:Calls.Download 'one download'
    Assert-Equal 0 $script:Calls.Deploy 'no deploy'
    $keptPackages = @(Get-ChildItem -LiteralPath (Get-UtCachePackagesDirectory) -Filter '*.msix' -File -Force)
    Assert-Equal 1 $keptPackages.Count 'verified candidate was kept in managed cache'

    Reset-MockState
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.930.7945.0'))
    $script:MockHead = New-MockHead -Version '26.930.7945.0' -Length 12345
    Assert-Equal 0 (Invoke-Production -DownloadOnly) 'download-only up to date exits 0'
    Assert-Equal 0 $script:Calls.Download 'no download when up to date'
}

# ===========================================================================
# 23: confirmation boundary
# ===========================================================================
Invoke-Case 'bare CLI preparation does not install without an explicit prompt choice' {
    $fixture = New-ValidFixtureFile -Version '26.930.7945.0'
    Set-ValidUpdateHead -FixturePath $fixture -Version '26.930.7945.0'
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.707.3748.0'))
    $script:MockPromptChoice = 'Snooze'
    $code = Invoke-Production
    Assert-Equal 0 $code 'snoozed confirmation exits cleanly'
    Assert-Equal 1 $script:Calls.Prompt 'one confirmation prompt was shown'
    Assert-Equal 1 $script:Calls.Download 'candidate was prepared before prompting'
    Assert-Equal 0 $script:Calls.Deploy 'no click means no deployment'
    Assert-Equal 1 @(Get-ChildItem -LiteralPath (Get-UtCachePackagesDirectory) -Filter '*.msix' -File -Force).Count 'prepared package remains cached'
}

Invoke-Case 'standalone CLI lazily loads the confirmation UI and dispatches its launch boundary' {
    $fixture = New-ValidFixtureFile -Version '26.930.7945.0'
    Set-ValidUpdateHead -FixturePath $fixture -Version '26.930.7945.0'
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'))
    $mockPromptScript = (Get-Command Start-UtConfirmationPrompt -CommandType Function).ScriptBlock
    Set-Item -Path Function:\Start-UtConfirmationPrompt -Value $script:ProductionConfirmationBridge
    try {
        $code = Invoke-Production
        Assert-Equal 0 $code 'prompt launch returns success while awaiting the user'
        Assert-Equal 1 $script:Calls.Download 'candidate was prepared before UI dispatch'
        Assert-Equal 1 $script:Calls.UiLaunch 'standalone bridge invoked the PS5 UI launch boundary'
        Assert-Equal 0 $script:Calls.Deploy 'UI launch alone never installs'
        Assert-True ($script:LastUiLaunch.ScriptPath -like '*confirm-install.ps1') 'UI launch targeted confirm-install.ps1'
        Assert-Equal ([IO.Path]::GetFullPath((Join-Path $script:ProjectRoot 'update-chatgpt.ps1'))) $script:LastUiLaunch.CorePath 'UI launch received the absolute core path'
        Assert-Equal $false $script:LastUiLaunch.OpenApp 'default UI launch does not request app launch'

        # Dot-sourcing the UI script defines its in-process prompt function in
        # the current scope.  Reinstall the standalone bridge before the
        # second invocation so the OpenApp propagation is tested through the
        # same detached boundary.
        Set-Item -Path Function:\Start-UtConfirmationPrompt -Value $script:ProductionConfirmationBridge
        Reset-MockState
        $fixture = New-ValidFixtureFile -Version '26.930.7945.0'
        Set-ValidUpdateHead -FixturePath $fixture -Version '26.930.7945.0'
        Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'))
        $openCode = Invoke-Production -OpenApp
        Assert-Equal 0 $openCode 'OpenApp prompt launch returns success while awaiting the user'
        Assert-Equal 1 $script:Calls.UiLaunch 'OpenApp launches one prompt boundary'
        Assert-Equal $true $script:LastUiLaunch.OpenApp 'requested OpenApp flag reaches the UI boundary'
        Assert-Equal 0 $script:Calls.StartApp 'OpenApp is not launched before verified installation'
    } finally {
        Set-Item -Path Function:\Start-UtConfirmationPrompt -Value $mockPromptScript
    }
    Assert-True (Test-Path -LiteralPath (Get-UtCachePackagesDirectory) -PathType Container) 'managed cache remains available while prompt is open'
}

# ===========================================================================
# 24: argument conflicts
# ===========================================================================
Invoke-Case 'argument conflicts: rejected before any network or file work' {
    Assert-Equal 2 (Invoke-Production -CheckOnly -DownloadOnly) 'CheckOnly+DownloadOnly rejected'
    Assert-Equal 2 (Invoke-Production -CheckOnly -OpenApp) 'CheckOnly+OpenApp rejected'
    Assert-Equal 2 (Invoke-Production -DownloadOnly -OpenApp) 'DownloadOnly+OpenApp rejected'
    Assert-Equal 0 $script:Calls.Head 'no HEAD'
    Assert-Equal 0 $script:Calls.Download 'no download'
    Assert-Equal 0 $script:Calls.Deploy 'no deploy'
}

# ===========================================================================
# 24: concurrency lock
# ===========================================================================
Invoke-Case 'lock conflict: no download, no deploy' {
    $fixture = New-ValidFixtureFile -Version '26.930.7945.0'
    Set-ValidUpdateHead -FixturePath $fixture -Version '26.930.7945.0'
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'))
    $script:MockLockThrow = 'simulated lock conflict'
    $code = Invoke-Production
    Assert-Equal 12 $code 'lock conflict code'
    Assert-Equal 0 $script:Calls.Download 'no download'
    Assert-Equal 0 $script:Calls.Deploy 'no deploy'
}

Invoke-Case 'production lock is exclusive in the isolated directory' {
    $first = $null
    $second = $null
    try {
        $first = & $script:ProductionEnterLock
        $blocked = $false
        try { $second = & $script:ProductionEnterLock } catch { $blocked = $true }
        Assert-True $blocked 'a second production Enter-UtLock must fail while the first is held'
        Assert-Null $second 'no second lock stream is returned'
    } finally {
        if ($null -ne $second) { $second.Dispose() }
        if ($null -ne $first) { $first.Dispose() }
    }
    $third = & $script:ProductionEnterLock
    Assert-True ($null -ne $third) 'the lock can be acquired again after release'
    $third.Dispose()
}

Invoke-Case 'run directory cleanup only touches this run known files' {
    $runDir = New-UtRunDirectory
    $candidate = Join-Path $runDir 'ChatGPT-x64.msix'
    [System.IO.File]::WriteAllBytes($candidate, [byte[]](1, 2, 3))
    $unknown = Join-Path $runDir 'keep-me.txt'
    Set-Content -LiteralPath $unknown -Value 'keep'
    Remove-UtRunArtifacts -RunDirectory $runDir -Architecture 'x64'
    Assert-True (-not (Test-Path -LiteralPath $candidate)) 'candidate removed'
    Assert-True (Test-Path -LiteralPath $unknown) 'unknown file inside the run directory is kept'
    Assert-True (Test-Path -LiteralPath $runDir) 'non-empty run directory is not removed'
    Remove-Item -LiteralPath $runDir -Recurse -Force -ErrorAction SilentlyContinue

    $emptyRun = New-UtRunDirectory
    Remove-UtRunDirectoryIfEmpty -RunDirectory $emptyRun
    Assert-True (-not (Test-Path -LiteralPath $emptyRun)) 'empty run directory is removed'
}

# ===========================================================================
# 25: file lease and special-character paths
# ===========================================================================
Invoke-Case 'read lease blocks concurrent write/replace' {
    $fixture = New-ValidFixtureFile -Version '26.930.7945.0'
    $lease = Open-UtReadLease -Path $fixture
    try {
        $blocked = $false
        try { $writer = [System.IO.File]::Open($fixture, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None); $writer.Dispose() }
        catch [System.IO.IOException] { $blocked = $true }
        Assert-True $blocked 'writer must be blocked while the read lease is held'
        $blockedDelete = $false
        try { [System.IO.File]::Delete($fixture) } catch [System.IO.IOException] { $blockedDelete = $true }
        Assert-True $blockedDelete 'delete must be blocked while the read lease is held'
    } finally { $lease.Dispose() }
}

Invoke-Case 'paths with spaces/Chinese/brackets work end to end' {
    $fixture = New-ValidFixtureFile -Version '26.930.7945.0'
    Set-ValidUpdateHead -FixturePath $fixture -Version '26.930.7945.0'
    Set-InstalledSequence -Items @((New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.707.3748.0'), (New-MockPackage -Version '26.930.7945.0'))
    $code = Invoke-Production
    Assert-Equal 0 $code 'exit code 0'
    Assert-True ($script:LastDownloadOutput -like '*ut test*') 'work directory uses the isolated special-character path'
    Assert-True ($script:LastDownloadOutput -like '*[[]brackets[]]*') 'square brackets preserved in the path'
}

# ===========================================================================
# 26: CMD wrapper (isolated fixture copy, never starts the real updater)
# ===========================================================================
Invoke-Case 'CMD wrapper quotes paths, forwards args and returns exit code' {
    $wrapperDir = Join-Path $env:TEMP ('ut cmd test [' + [string]([char]0x5F15) + '] ' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $wrapperDir -Force
    Copy-Item -LiteralPath (Join-Path $script:ProjectRoot 'update-chatgpt.cmd') -Destination (Join-Path $wrapperDir 'update-chatgpt.cmd') -Force
    $fake = @'
param([switch]$CheckOnly, [switch]$DownloadOnly, [switch]$OpenApp)
Set-Content -LiteralPath (Join-Path $PSScriptRoot 'args.txt') -Value ("CheckOnly={0};DownloadOnly={1};OpenApp={2}" -f $CheckOnly, $DownloadOnly, $OpenApp)
exit 7
'@
    Set-Content -LiteralPath (Join-Path $wrapperDir 'update-chatgpt.ps1') -Value $fake -Encoding UTF8

    $wrapper = Join-Path $wrapperDir 'update-chatgpt.cmd'
    $null = & $wrapper -CheckOnly 2>&1
    $wrapperExit = $LASTEXITCODE
    Assert-Equal 7 $wrapperExit 'wrapper must return the real exit code'
    $recorded = Get-Content -LiteralPath (Join-Path $wrapperDir 'args.txt') -Raw
    Assert-True ($recorded -like '*CheckOnly=True*') 'wrapper must forward -CheckOnly'
    Assert-True ($recorded -like '*DownloadOnly=False*') 'wrapper must not invent arguments'
    Remove-Item -LiteralPath $wrapperDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ===========================================================================
# 27: dot-sourcing has no side effects
# ===========================================================================
Invoke-Case 'dot-sourcing performs no network/download/deploy and does not exit the host' {
    $scriptPath = Join-Path $script:ProjectRoot 'update-chatgpt.ps1'
    $command = ". '$scriptPath'; Write-Output 'DOTSOURCE-OK'"
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $command 2>&1 | Out-String
    Assert-Equal 0 $LASTEXITCODE 'dot-source child exit code'
    Assert-True ($output -like '*DOTSOURCE-OK*') 'dot-source marker missing'
    Assert-True ($output -notlike '*ChatGPT Desktop updater*') 'dot-sourcing started the updater'
}

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------
$env:LOCALAPPDATA = $script:OriginalLocalAppData
Assert-SentinelSnapshot $script:Sentinel 'user data untouched for the whole run'

Write-Host ''
if ($script:TestFailed -eq 0) {
    Write-Host ("All {0} test cases passed." -f $script:TestTotal) -ForegroundColor Green
    if (-not $KeepTemp) { Remove-Item -LiteralPath $script:IsolatedRoot -Recurse -Force -ErrorAction SilentlyContinue }
    exit 0
} else {
    Write-Host ("{0} of {1} test cases had failures." -f $script:TestFailed, $script:TestTotal) -ForegroundColor Red
    Write-Host ("Isolated evidence kept at: {0}" -f $script:IsolatedRoot)
    exit 1
}
