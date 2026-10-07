#requires -Version 5.1
<#!
    Offline managed-cache tests.  The fixture is a real small ZIP/MSIX and the
    production validator, cache state parser, atomic publication and confirmed
    install boundary are exercised directly.  Network, Authenticode and AppX
    boundaries are mocked; no package is installed and no task is registered.
#>
[CmdletBinding()]
param([switch]$KeepTemp)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:OriginalLocalAppData = $env:LOCALAPPDATA
$script:IsolatedRoot = Join-Path $env:TEMP ('ut cache test ' + [string]([char]0x6D4B) + [string]([char]0x8BD5) + ' [brackets] ' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $script:IsolatedRoot -Force
$script:FixtureDir = Join-Path $script:IsolatedRoot 'fixtures'
$null = New-Item -ItemType Directory -Path $script:FixtureDir -Force
$env:LOCALAPPDATA = $script:IsolatedRoot
trap {
    $env:LOCALAPPDATA = $script:OriginalLocalAppData
    throw
}
. (Join-Path $script:ProjectRoot 'update-chatgpt.ps1')

$script:Total = 0
$script:Failed = 0
$script:Calls = @{ Download = 0; Deploy = 0; Signature = 0; Head = 0 }
$script:Fixture = $null
$script:Head = $null
$script:Installed = $null
$script:DeployError = $null
$script:MockSignatureStatus = 'Valid'
$script:MissingDependency = $false
$script:HeadThrow = $null

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { $script:Failed++; Write-Host ('    FAIL: ' + $Message) -ForegroundColor Red }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { $script:Failed++; Write-Host ("    FAIL: {0}; expected [{1}], got [{2}]" -f $Message, $Expected, $Actual) -ForegroundColor Red }
}

function Invoke-Case {
    param([string]$Name, [scriptblock]$Body)
    $script:Total++
    Write-Host ('  - ' + $Name)
    try { & $Body } catch { $script:Failed++; Write-Host ('    FAIL: ' + $_.Exception.Message) -ForegroundColor Red }
}

function Reset-CacheFixture {
    $cache = Join-Path $script:IsolatedRoot 'ChatGPTUpdater\cache'
    if (Test-Path -LiteralPath $cache) { Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue }
    $script:Calls = @{ Download = 0; Deploy = 0; Signature = 0; Head = 0 }
    $script:DeployError = $null
    $script:MockSignatureStatus = 'Valid'
    $script:MissingDependency = $false
    $script:HeadThrow = $null
    $script:DependencyPackage = [pscustomobject]@{
        Name = 'Microsoft.WindowsAppRuntime.1.5'
        PackageFamilyName = 'Microsoft.WindowsAppRuntime.1.5_family'
        Version = '5001.0.0.0'
        Status = 'Ok'
        Architecture = 'X64'
        Publisher = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
        IsFramework = $true
        PackageFullName = 'Microsoft.WindowsAppRuntime.1.5_5001.0.0.0_x64__family'
    }
    $script:Installed = [pscustomobject]@{ Name = 'OpenAI.Codex'; PackageFamilyName = 'OpenAI.Codex_2p2nqsd0c76g0'; Version = '26.707.3748.0'; Status = 'Ok'; Architecture = 'X64'; Publisher = $script:UtManifestPublisher; IsFramework = $true; PackageFullName = 'OpenAI.Codex_26.707.3748.0_x64__family' }
}

function Add-ZipText {
    param($Zip, [string]$Name, [string]$Text)
    $entry = $Zip.CreateEntry($Name)
    $stream = $entry.Open()
    $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
    try { $writer.Write($Text) } finally { $writer.Dispose() }
}

function New-Fixture {
    param(
        [string]$Version = '26.930.7945.0',
        [string]$Name = 'candidate.msix',
        [switch]$WithDependency
    )
    $path = Join-Path $script:FixtureDir $Name
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { }
    try { Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop } catch { }
    $dependency = ''
    if ($WithDependency) {
        $dependency = '<PackageDependency Name="Microsoft.WindowsAppRuntime.1.5" Publisher="CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US" MinVersion="5001.0.0.0" />'
    }
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10">
  <Identity Name="OpenAI.Codex" Publisher="CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B" Version="$Version" ProcessorArchitecture="x64" />
  <Properties><DisplayName>ChatGPT</DisplayName></Properties>
  <Dependencies><TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.17763.0" />$dependency</Dependencies>
</Package>
"@
    $zip = [System.IO.Compression.ZipFile]::Open($path, [System.IO.Compression.ZipArchiveMode]::Create)
    try { Add-ZipText -Zip $zip -Name 'AppxManifest.xml' -Text $xml } finally { $zip.Dispose() }
    return $path
}

function Get-TestMetadata {
    $length = (Get-Item -LiteralPath $script:Fixture).Length
    $headers = @{
        'x-ms-meta-package_version' = @('26.930.7945.0')
        'content-length' = @([string]$length)
        'etag' = @('"cache-test-etag"')
        'x-ms-meta-architecture' = @('x64')
        'x-ms-meta-package_identity' = @('OpenAI.Codex')
    }
    $head = [pscustomobject]@{ StatusCode = 200; FinalUri = 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix'; Headers = $headers }
    return Get-UtRemoteMetadata -HeadResult $head -Architecture 'x64' -RequestedUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix'
}

function Set-TestHeadForMetadata {
    param([Parameter(Mandatory = $true)]$Metadata)
    $script:Head = [pscustomobject]@{ StatusCode = 200; FinalUri = $metadata.FinalUri; Headers = @{
        'x-ms-meta-package_version' = @([string]$metadata.Version)
        'content-length' = @([string]$metadata.ContentLength)
        'etag' = @([string]$metadata.ETag)
        'x-ms-meta-architecture' = @('x64')
        'x-ms-meta-package_identity' = @('OpenAI.Codex')
    }}
}

function Get-UtNativeArchitecture { return 'x64' }
function Get-UtWindowsVersion { return [version]'10.0.26100.0' }
function Get-UtRawAppxPackage {
    param([string]$Name)
    if ($Name -ne $script:UtPackageName) {
        if ($script:MissingDependency) { return @() }
        return @($script:DependencyPackage)
    }
    if ($null -eq $script:Installed) { return @() }
    return @($script:Installed)
}
function Get-UtAuthenticodeSignature {
    param([string]$Path)
    $script:Calls.Signature++
    return [pscustomobject]@{ Status = $script:MockSignatureStatus }
}
function Invoke-UtHeadRequest {
    param([string]$Uri)
    $script:Calls.Head++
    if ($null -ne $script:HeadThrow) { throw $script:HeadThrow }
    return $script:Head
}
function Invoke-UtCurlDownload {
    param([string]$Url, [string]$OutputPath, $IfMatch)
    $script:Calls.Download++
    Copy-Item -LiteralPath $script:Fixture -Destination $OutputPath -Force
    return [pscustomobject]@{ ExitCode = 0; Text = "HTTPCODE=200`nFINALURL=https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix"; Headers = $script:Head.Headers; HeaderStatusCode = 200 }
}
function Install-UtPackage {
    param([string]$Path)
    $script:Calls.Deploy++
    if ($null -ne $script:DeployError) { throw $script:DeployError }
    $script:Installed = [pscustomobject]@{ Name = 'OpenAI.Codex'; PackageFamilyName = 'OpenAI.Codex_2p2nqsd0c76g0'; Version = '26.930.7945.0'; Status = 'Ok'; Architecture = 'X64'; Publisher = $script:UtManifestPublisher; IsFramework = $true; PackageFullName = 'OpenAI.Codex_26.930.7945.0_x64__family' }
}

function Prepare-TestCandidate {
    $metadata = Get-TestMetadata
    Set-TestHeadForMetadata -Metadata $metadata
    $lock = Enter-UtLock
    try { return Get-UtPreparedCandidate -Metadata $metadata -Architecture 'x64' -WindowsVersion ([version]'10.0.26100.0') -Connections 1 }
    finally { $lock.Dispose() }
}

Reset-CacheFixture
$script:Fixture = New-Fixture
$metadata = Get-TestMetadata
$script:Head = [pscustomobject]@{ StatusCode = 200; FinalUri = $metadata.FinalUri; Headers = @{
    'x-ms-meta-package_version' = @([string]$metadata.Version)
    'content-length' = @([string]$metadata.ContentLength)
    'etag' = @([string]$metadata.ETag)
    'x-ms-meta-architecture' = @('x64')
    'x-ms-meta-package_identity' = @('OpenAI.Codex')
}}

Invoke-Case 'first preparation publishes a complete Ready package' {
    $p = Prepare-TestCandidate
    Assert-True (Test-Path -LiteralPath $p.Path -PathType Leaf) 'published package exists'
    Assert-True (Test-Path -LiteralPath (Get-UtCachePathForKey -Kind State -Key $p.Key) -PathType Leaf) 'Ready state exists'
    Assert-Equal 1 $script:Calls.Download 'one GET for first preparation'
    Assert-True ($p.Key -match '^x64-26\.930\.7945\.0-[0-9a-f]{64}-[0-9a-f]{64}$') 'strict cache key shape'
}

$prepared = Prepare-TestCandidate
Invoke-Case 'matching Ready package is reused without another GET' {
    $before = $script:Calls.Download
    $again = Prepare-TestCandidate
    Assert-Equal $before $script:Calls.Download 'cache reuse has zero GETs'
    Assert-Equal $prepared.Key $again.Key 'cache key is stable'
}

Invoke-Case 'orphan package without state is fully validated and recovers Ready' {
    $state = Get-UtCachePathForKey -Kind State -Key $prepared.Key
    Remove-Item -LiteralPath $state -Force
    $before = $script:Calls.Download
    $again = Prepare-TestCandidate
    Assert-Equal $before $script:Calls.Download 'orphan recovery has zero GETs'
    Assert-True (Test-Path -LiteralPath $state -PathType Leaf) 'orphan recovery rewrites Ready state'
    Assert-Equal $prepared.Key $again.Key 'orphan key is preserved'
}

Invoke-Case 'corrupt state is unknown but a valid package is recovered' {
    $state = Get-UtCachePathForKey -Kind State -Key $prepared.Key
    [IO.File]::WriteAllText($state, '{', (New-Object Text.UTF8Encoding($false)))
    $before = $script:Calls.Download
    $again = Prepare-TestCandidate
    Assert-Equal $before $script:Calls.Download 'corrupt state recovery has zero GETs'
    Assert-Equal $prepared.Key $again.Key 'corrupt state does not change key'
}

Invoke-Case 'a Ready state without its package is never trusted' {
    $package = Get-UtCachePathForKey -Kind Package -Key $prepared.Key
    $state = Get-UtCachePathForKey -Kind State -Key $prepared.Key
    Remove-Item -LiteralPath $package -Force
    Assert-True (Test-Path -LiteralPath $state -PathType Leaf) 'state remains before package recovery'
    $before = $script:Calls.Download
    $again = Prepare-TestCandidate
    Assert-True ($script:Calls.Download -gt $before) 'missing package causes a fresh GET'
    Assert-True (Test-Path -LiteralPath $package -PathType Leaf) 'missing package is republished'
    Assert-Equal $prepared.Key $again.Key 'replacement uses the same validated key'
}

Invoke-Case 'cached package with a wrong manifest version is rejected' {
    $package = Get-UtCachePathForKey -Kind Package -Key $prepared.Key
    $wrong = New-Fixture -Version '26.930.7946.0' -Name 'wrong-version.msix'
    Assert-Equal (Get-Item -LiteralPath $script:Fixture).Length (Get-Item -LiteralPath $wrong).Length 'wrong-version fixture keeps the expected package length'
    Copy-Item -LiteralPath $wrong -Destination $package -Force
    $before = $script:Calls.Download
    $again = Prepare-TestCandidate
    Assert-True ($script:Calls.Download -gt $before) 'wrong manifest version is not reused'
    Assert-Equal $prepared.Key $again.Key 'wrong-version replacement uses the expected key'
}

Invoke-Case 'tampered package is rejected and replaced through the normal download path' {
    $package = Get-UtCachePathForKey -Kind Package -Key $prepared.Key
    [IO.File]::WriteAllBytes($package, [byte[]](1, 2, 3))
    $before = $script:Calls.Download
    $again = Prepare-TestCandidate
    Assert-True ($script:Calls.Download -gt $before) 'tampered package is not reused'
    Assert-Equal $prepared.Key $again.Key 'replacement keeps the same validated key'
}

Invoke-Case 'confirmed install refuses a changed candidate without deployment' {
    $fresh = Prepare-TestCandidate
    $changedHeaders = @{
        'x-ms-meta-package_version' = @([string]$metadata.Version)
        'content-length' = @([string]$metadata.ContentLength)
        'etag' = @('"changed-etag"')
        'x-ms-meta-architecture' = @('x64')
        'x-ms-meta-package_identity' = @('OpenAI.Codex')
    }
    $script:Head = [pscustomobject]@{ StatusCode = 200; FinalUri = $metadata.FinalUri; Headers = $changedHeaders }
    $before = $script:Calls.Deploy
    $result = Invoke-UtConfirmedInstall -ExpectedKey $fresh.Key -ExpectedVersion $metadata.Version
    Assert-Equal 'CandidateChanged' $result.Status 'changed candidate status'
    Assert-Equal $before $script:Calls.Deploy 'changed candidate not deployed'
    $script:Head = [pscustomobject]@{ StatusCode = 200; FinalUri = $metadata.FinalUri; Headers = @{
        'x-ms-meta-package_version' = @([string]$metadata.Version)
        'content-length' = @([string]$metadata.ContentLength)
        'etag' = @([string]$metadata.ETag)
        'x-ms-meta-architecture' = @('x64')
        'x-ms-meta-package_identity' = @('OpenAI.Codex')
    }}
}

Invoke-Case 'invalid cached signature never reaches deployment' {
    $fresh = Prepare-TestCandidate
    $script:MockSignatureStatus = 'HashMismatch'
    $before = $script:Calls.Deploy
    $result = Invoke-UtConfirmedInstall -ExpectedKey $fresh.Key -ExpectedVersion $metadata.Version
    Assert-Equal 'Failed' $result.Status 'invalid signature is a failed confirmation'
    Assert-Equal 7 $result.Code 'invalid signature returns the security code'
    Assert-Equal $before $script:Calls.Deploy 'invalid signature never deploys'
    Assert-True (Test-Path -LiteralPath (Get-UtCachePathForKey -Kind Package -Key $fresh.Key) -PathType Leaf) 'invalid signature retains the cache package'
    $script:MockSignatureStatus = 'Valid'
}

Invoke-Case 'missing dependency never reaches deployment' {
    $oldFixture = $script:Fixture
    $oldHead = $script:Head
    $script:Fixture = New-Fixture -Name 'dependency.msix' -WithDependency
    $dependencyMetadata = Get-TestMetadata
    Set-TestHeadForMetadata -Metadata $dependencyMetadata
    $lock = Enter-UtLock
    try { $fresh = Get-UtPreparedCandidate -Metadata $dependencyMetadata -Architecture 'x64' -WindowsVersion ([version]'10.0.26100.0') -Connections 1 }
    finally { $lock.Dispose() }
    $script:MissingDependency = $true
    $before = $script:Calls.Deploy
    $result = Invoke-UtConfirmedInstall -ExpectedKey $fresh.Key -ExpectedVersion $dependencyMetadata.Version
    Assert-Equal 'Failed' $result.Status 'missing dependency is a failed confirmation'
    Assert-Equal 9 $result.Code 'missing dependency returns the dependency code'
    Assert-Equal $before $script:Calls.Deploy 'missing dependency never deploys'
    Assert-True (Test-Path -LiteralPath (Get-UtCachePathForKey -Kind Package -Key $fresh.Key) -PathType Leaf) 'missing dependency retains the cache package'
    $script:MissingDependency = $false
    $script:Fixture = $oldFixture
    $script:Head = $oldHead
}

Invoke-Case 'network loss during confirmation retains the prepared package' {
    $fresh = Prepare-TestCandidate
    $script:HeadThrow = (New-UtFailure -Code 4 -Message 'simulated offline confirmation')
    $before = $script:Calls.Deploy
    $result = Invoke-UtConfirmedInstall -ExpectedKey $fresh.Key -ExpectedVersion $metadata.Version
    Assert-Equal 'Failed' $result.Status 'offline confirmation is failed'
    Assert-Equal 4 $result.Code 'offline confirmation returns the network code'
    Assert-Equal $before $script:Calls.Deploy 'offline confirmation never deploys'
    Assert-True (Test-Path -LiteralPath (Get-UtCachePathForKey -Kind Package -Key $fresh.Key) -PathType Leaf) 'offline confirmation retains the cache package'
    $script:HeadThrow = $null
}

Invoke-Case 'confirmed install revalidates, deploys once, verifies, and consumes the used cache entry' {
    $fresh = Prepare-TestCandidate
    $script:Installed = [pscustomobject]@{ Name = 'OpenAI.Codex'; PackageFamilyName = 'OpenAI.Codex_2p2nqsd0c76g0'; Version = '26.707.3748.0'; Status = 'Ok'; Architecture = 'X64'; Publisher = $script:UtManifestPublisher; IsFramework = $true; PackageFullName = 'OpenAI.Codex_26.707.3748.0_x64__family' }
    $result = Invoke-UtConfirmedInstall -ExpectedKey $fresh.Key -ExpectedVersion $metadata.Version
    Assert-Equal 'Installed' $result.Status 'confirmed install status'
    Assert-Equal 1 $script:Calls.Deploy 'one deployment'
    Assert-True (-not (Test-Path -LiteralPath (Get-UtCachePathForKey -Kind Package -Key $fresh.Key) -PathType Leaf)) 'used package removed after confirmed success'
}

Invoke-Case 'Ready cache publication stays within the bounded record count' {
    Reset-CacheFixture
    $base = Get-TestMetadata
    $published = @()
    for ($index = 0; $index -lt 4; $index++) {
        $variant = [pscustomobject]@{
            Version = $base.Version
            ContentLength = $base.ContentLength
            ETag = ('"cache-limit-{0}"' -f $index)
            ETagKind = 'Strong'
            StrongETag = $true
            Url = $base.Url
            FinalUri = $base.FinalUri
            Architecture = 'x64'
        }
        $run = New-UtRunDirectory
        $source = Join-Path $run ('variant-{0}.msix' -f $index)
        Copy-Item -LiteralPath $script:Fixture -Destination $source -Force
        try {
            $validated = Get-UtValidatedCandidate -Path $source -Metadata $variant -Architecture 'x64' -WindowsVersion ([version]'10.0.26100.0')
            $published += Publish-UtPreparedCandidate -Path $validated.Path -Metadata $variant -Architecture 'x64' -SHA256 $validated.SHA256
        } finally {
            Remove-UtRunDirectoryIfEmpty -RunDirectory $run
        }
    }
    Remove-UtCacheOverflow -KeepKey $published[3].Key
    $states = @(Get-ChildItem -LiteralPath (Get-UtCacheStatesDirectory) -Filter '*.json' -File -Force)
    $packages = @(Get-ChildItem -LiteralPath (Get-UtCachePackagesDirectory) -Filter '*.msix' -File -Force)
    Assert-True ($states.Count -le 3) 'Ready state count stays within the hard limit'
    Assert-True ($packages.Count -le 3) 'managed package count stays within the hard limit'
    Assert-True (Test-Path -LiteralPath (Get-UtCachePathForKey -Kind Package -Key $published[3].Key) -PathType Leaf) 'current publication remains available after overflow cleanup'
}

Invoke-Case 'reuse cleanup bounds strict orphan packages and preserves history files' {
    Reset-CacheFixture
    $base = Get-TestMetadata
    $packages = Get-UtCachePackagesDirectory
    $states = Get-UtCacheStatesDirectory
    $orphanKeys = @()
    for ($index = 0; $index -lt 4; $index++) {
        $etag = if ($index -eq 3) { [string]$base.ETag } else { '"orphan-{0}"' -f $index }
        $variant = [pscustomobject]@{
            Version = $base.Version
            ContentLength = $base.ContentLength
            ETag = $etag
            ETagKind = 'Strong'
            StrongETag = $true
            Url = $base.Url
            FinalUri = $base.FinalUri
            Architecture = 'x64'
        }
        $validated = Get-UtValidatedCandidate -Path $script:Fixture -Metadata $variant -Architecture 'x64' -WindowsVersion ([version]'10.0.26100.0')
        $key = New-UtCacheKey -Metadata $variant -Architecture 'x64' -SHA256 $validated.SHA256
        $orphanKeys += $key
        $destination = Get-UtCachePathForKey -Kind Package -Key $key
        Copy-Item -LiteralPath $script:Fixture -Destination $destination -Force
        $item = Get-Item -LiteralPath $destination -Force
        $item.LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-30 + ($index * 2))
    }
    # The current snapshot is the oldest orphan and has a corrupt index.  It
    # must be fully revalidated and retained when reuse cleanup runs.
    $currentKey = $orphanKeys[3]
    [IO.File]::WriteAllText((Get-UtCachePathForKey -Kind State -Key $currentKey), '{corrupt', (New-Object Text.UTF8Encoding($false)))
    $history = Join-Path $packages 'history.txt'
    Set-Content -LiteralPath $history -Value 'retain history' -Encoding ASCII
    $nestedHistory = Join-Path $packages 'history'
    $null = New-Item -ItemType Directory -Path $nestedHistory -Force
    $nestedHistoryFile = Join-Path $nestedHistory 'keep.txt'
    Set-Content -LiteralPath $nestedHistoryFile -Value 'retain nested history' -Encoding ASCII
    $unknownPackage = Join-Path $packages 'manual.msix'
    Set-Content -LiteralPath $unknownPackage -Value 'retain unknown name' -Encoding ASCII

    $lock = Enter-UtLock
    try { $reused = Get-UtPreparedCandidate -Metadata $base -Architecture 'x64' -WindowsVersion ([version]'10.0.26100.0') -Connections 1 }
    finally { $lock.Dispose() }
    Assert-Equal $currentKey $reused.Key 'current orphan key is recovered and reused'
    Assert-Equal 0 $script:Calls.Download 'orphan recovery reuse performs zero GETs'
    $managedPackages = @(Get-ChildItem -LiteralPath $packages -Filter '*.msix' -File -Force | Where-Object { Test-UtCacheKey -Key ([IO.Path]::GetFileNameWithoutExtension($_.Name)) })
    Assert-True ($managedPackages.Count -le 3) 'strict managed package count remains bounded after reuse'
    Assert-True (Test-Path -LiteralPath (Get-UtCachePathForKey -Kind Package -Key $currentKey) -PathType Leaf) 'current reused package remains available'
    Assert-True (Test-Path -LiteralPath $history -PathType Leaf) 'direct history sentinel remains untouched'
    Assert-True (Test-Path -LiteralPath $nestedHistoryFile -PathType Leaf) 'nested history remains untouched'
    Assert-True (Test-Path -LiteralPath $unknownPackage -PathType Leaf) 'unknown package name remains untouched'
}

Invoke-Case 'reparse root is rejected before any cache directory is created' {
    Reset-CacheFixture
    $managedRoot = Join-Path $script:IsolatedRoot 'ChatGPTUpdater'
    # Keep the target path free of the square brackets in the isolated root;
    # Windows PowerShell 5.1's Junction provider mishandles that target syntax.
    $outside = Join-Path $env:TEMP ('ut-cache-junction-target-' + [guid]::NewGuid().ToString('N'))
    $sentinel = Join-Path $outside 'sentinel.txt'
    if (Test-Path -LiteralPath $managedRoot) { Remove-Item -LiteralPath $managedRoot -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $outside -Force
    Set-Content -LiteralPath $sentinel -Value 'outside-cache-sentinel' -Encoding ASCII
    Assert-True (Test-Path -LiteralPath $outside -PathType Container) 'junction target exists before link creation'
    $junctionError = $null
    try {
        # Windows PowerShell 5.1 can report a provider error after creating a
        # junction when the target path contains square brackets.  Inspect the
        # resulting item before treating that late provider error as failure.
        $null = New-Item -ItemType Junction -Path $managedRoot -Value $outside -ErrorAction Stop
    } catch {
        $junctionError = $_
    }
    $junctionItem = Get-Item -LiteralPath $managedRoot -Force -ErrorAction SilentlyContinue
    if ($null -eq $junctionItem -or ($junctionItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
        if ($null -ne $junctionError) {
            throw ('The Windows test host could not create the required directory junction: {0}' -f $junctionError.Exception.Message)
        }
        throw 'The Windows test host did not create a reparse-point junction.'
    }
    try {
        $threw = $false
        try { $null = Get-UtCacheRootDirectory } catch {
            $threw = $true
            Assert-Equal 7 (Get-UtErrorCode -ErrorRecord $_ -Default -1) 'reparse root returns the security code'
        }
        Assert-True $threw 'reparse root was refused'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $outside 'cache'))) 'no cache directory was created through the junction'
        Assert-Equal 'outside-cache-sentinel' ((Get-Content -LiteralPath $sentinel -Raw).TrimEnd("`r`n")) 'outside sentinel remains unchanged'
    } finally {
        Remove-Item -LiteralPath $managedRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $outside -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Case 'unsafe cache state path is ignored and never controls installation' {
    $path = Join-Path (Get-UtCacheStatesDirectory) 'x64-26.930.7945.0-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json'
    $json = '{"SchemaVersion":1,"State":"Ready","Key":"x64-26.930.7945.0-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","PackageFile":"C:\\outside\\evil.msix"}'
    [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding($false)))
    Assert-True ($null -eq (ConvertFrom-UtCacheState -Path $path)) 'unsafe state is treated as unknown'
}

Write-Host ''
$env:LOCALAPPDATA = $script:OriginalLocalAppData
if ($script:Failed -eq 0) {
    Write-Host ("All {0} cache test cases passed." -f $script:Total) -ForegroundColor Green
    if (-not $KeepTemp) { Remove-Item -LiteralPath $script:IsolatedRoot -Recurse -Force -ErrorAction SilentlyContinue }
    exit 0
}
Write-Host ("{0} of {1} cache test cases had failures. Evidence: {2}" -f $script:Failed, $script:Total, $script:IsolatedRoot) -ForegroundColor Red
exit 1
