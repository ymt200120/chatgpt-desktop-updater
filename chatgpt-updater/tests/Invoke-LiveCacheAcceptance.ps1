#requires -Version 5.1
<#
Development acceptance only: prepare the real official package even when the
installed app is current, then prove that another preparation performs no GET.
There is deliberately no installation or production force-download parameter.
#>
[CmdletBinding()]
param(
    [ValidateSet(1,4,8,16)][int]$Connections = 8,
    [string]$EvidenceDirectory,
    [switch]$RequireExistingCache
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) { $EvidenceDirectory = Join-Path $PSScriptRoot 'evidence\segmented-background' }
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'update-chatgpt.ps1')

# An extra guard: even an accidental call across the deployment boundary fails.
function Install-UtPackage { param([string]$Path) throw 'Live cache acceptance MUST NOT deploy.' }

# Reverification after the one permitted full download must fail instead of
# silently downloading another package if the cache or HEAD snapshot changes.
if ($RequireExistingCache) {
    function Receive-UtParallelCandidate {
        param($Metadata,[string]$RunDirectory,[string]$Architecture,[int]$Connections,[switch]$Background)
        throw 'Existing-cache acceptance forbids every package transfer.'
    }
    function Invoke-UtCurlDownload {
        param([string]$Url,[string]$OutputPath,[string]$IfMatch,[switch]$Background)
        throw 'Existing-cache acceptance forbids every package transfer.'
    }
}

$architecture = Get-UtNativeArchitecture
$windowsVersion = Get-UtWindowsVersion
$installed = Get-UtInstalledPackage
$url = '{0}/ChatGPT-{1}.msix' -f $script:UtBaseUrl,$architecture
$metadata = Get-UtRemoteMetadata -HeadResult (Invoke-UtHeadRequest -Uri $url) -Architecture $architecture -RequestedUri $url
$lock = $null
$started = [DateTime]::UtcNow
try {
    $lock = Enter-UtLock
    $prepared = Get-UtPreparedCandidate -Metadata $metadata -Architecture $architecture -WindowsVersion $windowsVersion -Connections $Connections
} finally { if ($null -ne $lock) { $lock.Dispose() } }

$freshMetadata = Get-UtRemoteMetadata -HeadResult (Invoke-UtHeadRequest -Uri $url) -Architecture $architecture -RequestedUri $url
if (-not (Test-UtSnapshotMatch -A $metadata -B $freshMetadata)) { throw 'CDN snapshot changed during acceptance; retaining the verified package without claiming reuse.' }

$script:UnexpectedTransfers = 0
function Receive-UtParallelCandidate {
    param($Metadata,[string]$RunDirectory,[string]$Architecture,[int]$Connections,[switch]$Background)
    $script:UnexpectedTransfers++
    throw 'A matching complete cache must be reused without another transfer.'
}
function Invoke-UtCurlDownload {
    param([string]$Url,[string]$OutputPath,[string]$IfMatch)
    $script:UnexpectedTransfers++
    throw 'A matching complete cache must not issue a serial GET.'
}
$lock = $null
try {
    $lock = Enter-UtLock
    $reused = Get-UtPreparedCandidate -Metadata $freshMetadata -Architecture $architecture -WindowsVersion $windowsVersion -Connections $Connections -Background
} finally { if ($null -ne $lock) { $lock.Dispose() } }
if ($reused.Key -cne $prepared.Key -or $reused.Path -cne $prepared.Path -or $reused.SHA256 -cne $prepared.SHA256 -or $script:UnexpectedTransfers -ne 0) { throw 'Cache reuse acceptance failed.' }
$signature = Get-UtAuthenticodeSignature -Path $prepared.Path
if ([string]$signature.Status -ne 'Valid') { throw 'The real signature is not Valid.' }
$report = [ordered]@{
    StartedUtc = $started.ToString('o')
    CompletedUtc = [DateTime]::UtcNow.ToString('o')
    Runtime = $PSVersionTable.PSVersion.ToString()
    Installed = if ($null -eq $installed) { $null } else { [string]$installed.Version }
    InstalledStatus = if ($null -eq $installed) { $null } else { [string]$installed.Status }
    Latest = [string]$metadata.Version
    Architecture = $architecture
    Connections = $Connections
    ExistingCacheRequired = [bool]$RequireExistingCache
    ContentLength = $metadata.ContentLength
    ETag = $metadata.ETag
    Signature = [string]$signature.Status
    SHA256 = $prepared.SHA256
    CacheKey = $prepared.Key
    PackagePath = $prepared.Path
    SecondPreparationTransfers = $script:UnexpectedTransfers
    SamePathAndHash = $true
    Deployed = $false
}
[IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($EvidenceDirectory)) | Out-Null
$json = $report | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'live-cache.json'),$json,(New-Object Text.UTF8Encoding($false)))
$json
