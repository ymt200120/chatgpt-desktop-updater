#requires -Version 5.1
<#
    Offline tests for the updater's own self-update path.

    They build a local release (ZIP + manifest) from the current production
    files, then exercise manifest validation, staging, the detached activation
    helper, rollback, and the pending-marker guard.  No GitHub request, real
    scheduled task, AppX deployment, or live updater replacement is performed.
#>
[CmdletBinding()]
param([switch]$KeepTemp)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:OriginalLocalAppData = $env:LOCALAPPDATA
$script:NonAscii = [string]([char]0x6D4B) + [string]([char]0x8BD5)
$script:IsolatedRoot = Join-Path $env:TEMP ('ChatGPTUpdater-self-update ' + $script:NonAscii + ' [brackets] ' + [guid]::NewGuid().ToString('N'))
$script:LocalAppData = Join-Path $script:IsolatedRoot 'local data'
$script:StableRoot = Join-Path $script:LocalAppData 'Programs\ChatGPTUpdater'
$script:ReleaseRoot = Join-Path $script:IsolatedRoot 'release'
$script:StateRoot = Join-Path $script:LocalAppData 'ChatGPTUpdater\updater'
$null = New-Item -ItemType Directory -Path $script:StableRoot -Force
$null = New-Item -ItemType Directory -Path $script:ReleaseRoot -Force
$env:LOCALAPPDATA = $script:LocalAppData

. (Join-Path $script:ProjectRoot 'update-chatgpt.ps1')

$script:TestTotal = 0
$script:TestFailed = 0
function Assert-True { param([bool]$Value, [string]$Message) if (-not $Value) { throw $Message } }
function Assert-Equal { param($Expected, $Actual, [string]$Message) if ([string]$Expected -cne [string]$Actual) { throw "$Message (expected '$Expected', got '$Actual')" } }
function Invoke-Case {
    param([string]$Name, [scriptblock]$Body)
    $script:TestTotal++
    try { & $Body; Write-Host ('PASS ' + $Name) -ForegroundColor Green }
    catch { $script:TestFailed++; Write-Host ('FAIL ' + $Name + ': ' + $_.Exception.Message) -ForegroundColor Red }
}

function Get-TestRuntime {
    $name = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { 'pwsh.exe' }
    $candidate = Join-Path $PSHOME $name
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    return (Get-Command $name -CommandType Application -ErrorAction Stop).Source
}

$script:Runtime = Get-TestRuntime
$script:ProductionFiles = @($script:UtUpdaterFiles)

foreach ($name in $script:ProductionFiles) {
    $source = Join-Path $script:ProjectRoot $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Production file is missing: $name" }
    Copy-Item -LiteralPath $source -Destination (Join-Path $script:StableRoot $name) -Force -ErrorAction Stop
}
$script:StableVersion = ([string](Get-Content -LiteralPath (Join-Path $script:StableRoot 'VERSION') -Raw)).Trim()
$stableVersionValue = [version]$script:StableVersion
$script:NextVersion = '{0}.{1}.{2}.{3}' -f $stableVersionValue.Major, $stableVersionValue.Minor, $stableVersionValue.Build, ($stableVersionValue.Revision + 1)

function New-TestRelease {
    param([string]$Version = $script:NextVersion)
    $filesRoot = Join-Path $script:ReleaseRoot ('files-' + $Version)
    if (Test-Path -LiteralPath $filesRoot -PathType Container) { Remove-Item -LiteralPath $filesRoot -Recurse -Force -ErrorAction SilentlyContinue }
    $null = New-Item -ItemType Directory -Path $filesRoot -Force
    foreach ($name in $script:ProductionFiles) {
        Copy-Item -LiteralPath (Join-Path $script:StableRoot $name) -Destination (Join-Path $filesRoot $name) -Force -ErrorAction Stop
    }
    [IO.File]::WriteAllText((Join-Path $filesRoot 'VERSION'), $Version + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::AppendAllText((Join-Path $filesRoot 'update-chatgpt.ps1'), ('# self-update test release ' + $Version + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
    $archiveName = 'chatgpt-desktop-updater-v{0}.zip' -f $Version
    $archivePath = Join-Path $script:ReleaseRoot $archiveName
    if (Test-Path -LiteralPath $archivePath -PathType Leaf) { Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue }
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    [IO.Compression.ZipFile]::CreateFromDirectory($filesRoot, $archivePath, [IO.Compression.CompressionLevel]::Optimal, $false)
    $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToUpperInvariant()
    $files = New-Object Collections.ArrayList
    foreach ($name in $script:ProductionFiles) {
        [void]$files.Add([ordered]@{
            Name = $name
            SHA256 = (Get-FileHash -LiteralPath (Join-Path $filesRoot $name) -Algorithm SHA256).Hash.ToUpperInvariant()
        })
    }
    $manifest = [ordered]@{
        Schema = 1
        Product = 'chatgpt-desktop-updater'
        Version = $Version
        MinimumVersion = '0.1.0.0'
        Archive = [ordered]@{
            Url = 'https://github.com/ymt200120/chatgpt-desktop-updater-public/releases/download/v' + $Version + '/' + $archiveName
            SHA256 = $archiveHash
        }
        Files = @($files)
    }
    $manifestPath = Join-Path $script:ReleaseRoot ('updater-release-' + $Version + '.json')
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    return [pscustomobject]@{
        Version = $Version
        FilesRoot = $filesRoot
        ArchivePath = $archivePath
        ArchiveHash = $archiveHash
        ManifestPath = $manifestPath
        Manifest = $manifest
    }
}

function Invoke-TestChild {
    param([string]$FilePath, [string[]]$Arguments)
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $FilePath @Arguments 2>&1)
        $code = [int]$LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    return [pscustomobject]@{ Code = $code; Text = (($output | ForEach-Object { [string]$_ }) -join "`n") }
}

function Invoke-SelfUpdate {
    param([string[]]$Arguments)
    $scriptPath = Join-Path $script:StableRoot 'self-update.ps1'
    return Invoke-TestChild -FilePath $script:Runtime -Arguments (@('-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath) + $Arguments)
}

function Get-StableVersion {
    return ([string](Get-Content -LiteralPath (Join-Path $script:StableRoot 'VERSION') -Raw)).Trim()
}

function Get-LatestStaging {
    $root = Join-Path $script:StateRoot 'staging'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return $null }
    return Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Get-Hash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

$script:Release = $null
$script:Staging = $null

Invoke-Case 'current and staged versions are separate and manifest validation rejects unsafe names' {
    $script:Release = New-TestRelease
    Assert-Equal $script:StableVersion (Get-StableVersion) 'stable starts at the repository version'
    $check = Invoke-SelfUpdate @('-CheckOnly', '-TestMode', '-StableRoot', $script:StableRoot, '-ManifestPath', $script:Release.ManifestPath, '-ArchivePath', $script:Release.ArchivePath)
    Assert-Equal 0 $check.Code 'check-only exit code'
    Assert-True ($check.Text -like ('*' + $script:NextVersion + '*')) 'check-only reports the available version'
    Assert-Equal $script:StableVersion (Get-StableVersion) 'check-only does not replace files'

    $unsafe = $script:Release.Manifest | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $unsafe.Files[0].Name = '../evil.ps1'
    $unsafePath = Join-Path $script:ReleaseRoot 'unsafe.json'
    [IO.File]::WriteAllText($unsafePath, ($unsafe | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    $rejected = Invoke-SelfUpdate @('-CheckOnly', '-TestMode', '-StableRoot', $script:StableRoot, '-ManifestPath', $unsafePath, '-ArchivePath', $script:Release.ArchivePath)
    Assert-Equal 5 $rejected.Code 'unsafe manifest file name is a manifest error'
    Assert-True ($rejected.Text -like '*unsafe file name*') 'unsafe manifest file name is explained'
}

Invoke-Case 'archive hash mismatch is rejected before staging' {
    $badArchive = Join-Path $script:ReleaseRoot 'tampered.zip'
    [IO.File]::WriteAllBytes($badArchive, [IO.File]::ReadAllBytes($script:Release.ArchivePath) + [byte[]](1, 2, 3))
    $result = Invoke-SelfUpdate @('-Apply', '-NoActivate', '-TestMode', '-StableRoot', $script:StableRoot, '-ManifestPath', $script:Release.ManifestPath, '-ArchivePath', $badArchive)
    Assert-Equal 6 $result.Code 'archive hash mismatch is an archive error'
    Assert-Equal $script:StableVersion (Get-StableVersion) 'archive mismatch leaves stable files unchanged'
    Assert-True ($null -eq (Get-LatestStaging)) 'archive mismatch creates no accepted staging directory'
}

Invoke-Case 'apply stages verified files without touching the stable files' {
    $result = Invoke-SelfUpdate @('-Apply', '-NoActivate', '-TestMode', '-StableRoot', $script:StableRoot, '-ManifestPath', $script:Release.ManifestPath, '-ArchivePath', $script:Release.ArchivePath)
    Assert-Equal 0 $result.Code 'staging exit code'
    Assert-True ($result.Text -like '*staging retained*') 'staging path is reported'
    Assert-Equal $script:StableVersion (Get-StableVersion) 'staging does not replace stable files'
    $script:Staging = Get-LatestStaging
    Assert-True ($null -ne $script:Staging) 'staging directory exists'
    Assert-Equal $script:NextVersion (([string](Get-Content -LiteralPath (Join-Path $script:Staging.FullName 'VERSION') -Raw)).Trim()) 'staged version is new'
    foreach ($entry in @($script:Release.Manifest.Files)) {
        Assert-Equal $entry.SHA256 (Get-Hash (Join-Path $script:Staging.FullName $entry.Name)) ('staged hash for ' + $entry.Name)
    }
}

Invoke-Case 'detached helper activates only the staged files and keeps a backup' {
    $backupRoot = Join-Path $script:StateRoot ('backups\helper-' + [guid]::NewGuid().ToString('N'))
    $planPath = Join-Path $script:StateRoot 'helper-plan.json'
    $resultPath = Join-Path $script:StateRoot 'helper-result.json'
    $logPath = Join-Path $script:StateRoot 'helper.log'
    $lockPath = Join-Path $script:StateRoot 'helper.lock'
    $pendingPath = Join-Path $script:StableRoot 'self-update.pending.json'
    $null = New-Item -ItemType Directory -Path $backupRoot -Force
    [IO.File]::WriteAllText($pendingPath, '{"Schema":1}', (New-Object Text.UTF8Encoding($false)))
    $plan = [ordered]@{
        Schema = 1
        Version = $script:Release.Version
        StableRoot = $script:StableRoot
        StagingRoot = $script:Staging.FullName
        BackupRoot = $backupRoot
        PendingPath = $pendingPath
        ResultPath = $resultPath
        LogPath = $logPath
        LockPath = $lockPath
        ParentPid = 0
        TaskName = 'ChatGPTUpdater-Background'
        TaskMarker = 'ChatGPTUpdater-owned-v1'
        TaskWasEnabled = $false
        TestMode = $true
        Files = @($script:Release.Manifest.Files | ForEach-Object { [ordered]@{ Name = $_.Name; SHA256 = $_.SHA256 } })
    }
    [IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    $helper = Join-Path $script:Staging.FullName 'self-update-helper.ps1'
    $helperRun = Invoke-TestChild -FilePath $script:Runtime -Arguments @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$helper,'-PlanPath',$planPath)
    Assert-Equal 0 $helperRun.Code 'helper exit code'
    Assert-Equal $script:NextVersion (Get-StableVersion) 'helper activates the new VERSION'
    Assert-True ((Get-Content -LiteralPath (Join-Path $script:StableRoot 'update-chatgpt.ps1') -Raw) -like ('*self-update test release ' + $script:NextVersion + '*')) 'helper activates changed content'
    Assert-True (Test-Path -LiteralPath (Join-Path $backupRoot 'update-chatgpt.ps1') -PathType Leaf) 'helper keeps a backup'
    Assert-True (-not (Test-Path -LiteralPath $pendingPath -PathType Leaf)) 'helper removes the pending marker'
    Remove-Item -LiteralPath $script:Staging.FullName -Recurse -Force -ErrorAction SilentlyContinue
    $helperResult = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    Assert-Equal 'Activated' $helperResult.Status 'helper result status'
    Assert-True ($helperRun.Text -notlike '*ERROR*') 'helper does not report an error'
}

Invoke-Case 'rollback restores the previous files and version' {
    $result = Invoke-SelfUpdate @('-Rollback', '-TestMode', '-StableRoot', $script:StableRoot)
    Assert-Equal 0 $result.Code 'rollback exit code'
    Assert-Equal $script:StableVersion (Get-StableVersion) 'rollback restores the old VERSION'
    Assert-True ((Get-Content -LiteralPath (Join-Path $script:StableRoot 'update-chatgpt.ps1') -Raw) -notlike ('*self-update test release ' + $script:NextVersion + '*')) 'rollback restores the old content'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:StableRoot 'self-update.pending.json') -PathType Leaf)) 'rollback clears a stale pending marker'
}

Invoke-Case 'pending marker blocks a direct updater run before network access' {
    $pendingPath = Join-Path $script:StableRoot 'self-update.pending.json'
    [IO.File]::WriteAllText($pendingPath, '{"Schema":1}', (New-Object Text.UTF8Encoding($false)))
    try {
        $pendingRun = Invoke-TestChild -FilePath $script:Runtime -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $script:StableRoot 'update-chatgpt.ps1'),'-CheckOnly')
        Assert-Equal 12 $pendingRun.Code 'pending marker returns the lock-conflict code'
        Assert-True ($pendingRun.Text -like '*self-update activation is pending*') 'pending marker is explained'
    } finally {
        Remove-Item -LiteralPath $pendingPath -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Case 'helper refuses a staged hash mismatch and leaves the old version intact' {
    $staging = Get-LatestStaging
    if ($null -eq $staging) {
        $apply = Invoke-SelfUpdate @('-Apply', '-NoActivate', '-TestMode', '-StableRoot', $script:StableRoot, '-ManifestPath', $script:Release.ManifestPath, '-ArchivePath', $script:Release.ArchivePath)
        Assert-Equal 0 $apply.Code 'fixture staging created'
        $staging = Get-LatestStaging
    }
    [IO.File]::AppendAllText((Join-Path $staging.FullName 'update-chatgpt.ps1'), ('# tampered after staging' + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
    $backupRoot = Join-Path $script:StateRoot ('backups\bad-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $backupRoot -Force
    $pendingPath = Join-Path $script:StableRoot 'self-update.pending.json'
    [IO.File]::WriteAllText($pendingPath, '{"Schema":1}', (New-Object Text.UTF8Encoding($false)))
    $planPath = Join-Path $script:StateRoot 'bad-plan.json'
    $resultPath = Join-Path $script:StateRoot 'bad-result.json'
    $plan = [ordered]@{
        Schema = 1
        Version = $script:Release.Version
        StableRoot = $script:StableRoot
        StagingRoot = $staging.FullName
        BackupRoot = $backupRoot
        PendingPath = $pendingPath
        ResultPath = $resultPath
        LogPath = (Join-Path $script:StateRoot 'bad.log')
        LockPath = (Join-Path $script:StateRoot 'bad.lock')
        ParentPid = 0
        TaskName = 'ChatGPTUpdater-Background'
        TaskMarker = 'ChatGPTUpdater-owned-v1'
        TaskWasEnabled = $false
        TestMode = $true
        Files = @($script:Release.Manifest.Files | ForEach-Object { [ordered]@{ Name = $_.Name; SHA256 = $_.SHA256 } })
    }
    [IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    $before = Get-Hash (Join-Path $script:StableRoot 'update-chatgpt.ps1')
    $badRun = Invoke-TestChild -FilePath $script:Runtime -Arguments @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $staging.FullName 'self-update-helper.ps1'),'-PlanPath',$planPath)
    Assert-Equal 1 $badRun.Code 'tampered helper exit code'
    Assert-Equal $before (Get-Hash (Join-Path $script:StableRoot 'update-chatgpt.ps1')) 'tampered helper leaves the old file unchanged'
    Assert-True (-not (Test-Path -LiteralPath $pendingPath -PathType Leaf)) 'failed helper removes a recoverable pending marker'
    $badResult = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    Assert-Equal 'Failed' $badResult.Status 'failed helper result status'
}

$env:LOCALAPPDATA = $script:OriginalLocalAppData
Write-Host ''
if ($script:TestFailed -eq 0) {
    Write-Host ('All {0} self-update test cases passed.' -f $script:TestTotal) -ForegroundColor Green
    if (-not $KeepTemp) { Remove-Item -LiteralPath $script:IsolatedRoot -Recurse -Force -ErrorAction SilentlyContinue }
    exit 0
}
Write-Host ('{0} of {1} self-update test cases had failures.' -f $script:TestFailed, $script:TestTotal) -ForegroundColor Red
Write-Host ('Isolated evidence kept at: {0}' -f $script:IsolatedRoot)
exit 1
