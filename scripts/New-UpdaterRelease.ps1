#requires -Version 5.1
<##
    Development-only release packager for updater self-update.

    It builds a flat production ZIP plus updater-release.json.  The current
    self-update implementation trusts the pinned GitHub release account over
    HTTPS and verifies these SHA-256 values; it does not add a separate signing
    key.  Upload the ZIP and manifest to the matching GitHub release.
##>
[CmdletBinding()]
param(
    [string]$Version,
    [string]$OutputDirectory,
    [string]$BaseUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$updaterRoot = Join-Path $projectRoot 'chatgpt-updater'
. (Join-Path $updaterRoot 'update-chatgpt.ps1')

if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = ([string](Get-Content -LiteralPath (Join-Path $updaterRoot 'VERSION') -Raw)).Trim()
}
try { $versionValue = [version]$Version } catch { throw "Invalid updater version: $Version" }
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $projectRoot ('dist\updater-v' + $versionValue.ToString()) }
if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = 'https://github.com/' + $script:UtUpdaterRepository + '/releases/download/v' + $versionValue.ToString() }
$BaseUrl = $BaseUrl.TrimEnd('/')
if ($BaseUrl -notmatch '^https://github\.com/ymt200120/chatgpt-desktop-updater-public/releases/download/v[0-9.]+$') { throw 'BaseUrl must be the pinned public GitHub release download URL.' }

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$null = New-Item -ItemType Directory -Path $outputFull -Force
$temporary = Join-Path $env:TEMP ('ChatGPTUpdater-release-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temporary -Force
try {
    $files = @($script:UtUpdaterFiles)
    foreach ($name in $files) {
        $source = Join-Path $updaterRoot $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Production file is missing: $name" }
        Copy-Item -LiteralPath $source -Destination (Join-Path $temporary $name) -Force -ErrorAction Stop
    }
    $versionText = ([string](Get-Content -LiteralPath (Join-Path $temporary 'VERSION') -Raw)).Trim()
    if ([version]$versionText -ne $versionValue) { throw 'VERSION does not match the requested release version.' }

    $archiveName = 'chatgpt-desktop-updater-v{0}.zip' -f $versionValue.ToString()
    $archivePath = Join-Path $outputFull $archiveName
    if (Test-Path -LiteralPath $archivePath -PathType Leaf) { Remove-Item -LiteralPath $archivePath -Force -ErrorAction Stop }
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    [IO.Compression.ZipFile]::CreateFromDirectory($temporary, $archivePath, [IO.Compression.CompressionLevel]::Optimal, $false)
    $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToUpperInvariant()

    $manifestFiles = New-Object Collections.ArrayList
    foreach ($name in $files) {
        $hash = (Get-FileHash -LiteralPath (Join-Path $temporary $name) -Algorithm SHA256).Hash.ToUpperInvariant()
        [void]$manifestFiles.Add([ordered]@{ Name = $name; SHA256 = $hash })
    }
    $manifest = [ordered]@{
        Schema = 1
        Product = $script:UtUpdaterProduct
        Version = $versionValue.ToString()
        MinimumVersion = '0.1.0.0'
        Archive = [ordered]@{
            Url = $BaseUrl + '/' + $archiveName
            SHA256 = $archiveHash
        }
        Files = @($manifestFiles)
    }
    $manifestPath = Join-Path $outputFull 'updater-release.json'
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    $sums = @(
        ('{0}  {1}' -f $archiveHash, $archiveName),
        ('{0}  updater-release.json' -f (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToUpperInvariant())
    ) -join [Environment]::NewLine
    [IO.File]::WriteAllText((Join-Path $outputFull 'SHA256SUMS'), $sums + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    Write-Host ('Release directory: {0}' -f $outputFull)
    Write-Host ('Archive:           {0}' -f $archivePath)
    Write-Host ('Manifest:          {0}' -f $manifestPath)
    Write-Host ('Archive SHA256:    {0}' -f $archiveHash)
    exit 0
} finally {
    if (Test-Path -LiteralPath $temporary -PathType Container) { Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue }
}
