#requires -Version 5.1
<##
    Explicit, hash-verified self-update for this updater.

    Trust boundary:
      - The manifest URL is pinned to the public GitHub repository over HTTPS.
      - The manifest carries the SHA-256 of the release archive and every
        production file; all values are checked before staging.
      - This version does not use a separate signing key.  Its trust root is
        the pinned GitHub repository account and the user's explicit -Apply.
        Compromise of that account or of this machine is outside the boundary.

    Consent boundary:
      - -CheckOnly, -Status and -Rollback are explicit local operations.
      - -Apply is the only command that stages and activates new updater code.
        The background worker never calls it.  No update is installed silently.
##>
[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [switch]$Apply,
    [switch]$Status,
    [switch]$Rollback,
    [switch]$TestMode,
    [string]$ManifestPath,
    [string]$ArchivePath,
    [string]$StableRoot,
    [switch]$NoActivate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'background-common.ps1') -CorePath (Join-Path $PSScriptRoot 'update-chatgpt.ps1')

$script:SuProduct = $script:UtUpdaterProduct
$script:SuManifestUrl = $script:UtUpdaterManifestUrl
$script:SuReleasePrefix = $script:UtUpdaterReleasePrefix
$script:SuMaxManifestBytes = [int64]$script:UtSelfUpdateMaxManifestBytes
$script:SuMaxArchiveBytes = [int64]$script:UtSelfUpdateMaxArchiveBytes
$script:SuMaxExpandedBytes = [int64](16 * 1024 * 1024)
$script:SuStateRoot = Join-Path (Get-UbRoot) 'updater'
$script:SuLogPath = Join-Path $script:SuStateRoot 'self-update.log'
$script:SuResultPath = Join-Path $script:SuStateRoot 'self-update-result.json'
$script:SuPendingName = 'self-update.pending.json'
$script:SuApplyLockStream = $null

function Stop-Su {
    param([int]$Code, [string]$Message)
    $exception = New-Object Exception -ArgumentList @($Message)
    $exception.Data['SuExitCode'] = $Code
    throw $exception
}

function Get-SuExitCode {
    param($ErrorRecord, [int]$Default = 1)
    if ($null -ne $ErrorRecord -and $null -ne $ErrorRecord.Exception -and $null -ne $ErrorRecord.Exception.Data -and $ErrorRecord.Exception.Data.Contains('SuExitCode')) {
        return [int]$ErrorRecord.Exception.Data['SuExitCode']
    }
    return $Default
}

function Write-SuLine {
    param([string]$Message)
    Write-Host $Message
}

function Write-SuError {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}

function Write-SuLog {
    param([string]$Message)
    try {
        $null = Assert-UbDirectory -Path $script:SuStateRoot
        $line = ('{0} {1}' -f ([DateTime]::UtcNow.ToString('o')), $Message)
        [IO.File]::AppendAllText($script:SuLogPath, $line + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

function Get-SuCurrentVersion {
    $path = Join-Path $PSScriptRoot $script:UtUpdaterVersionFile
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Stop-Su 3 ('The updater VERSION file is missing: ' + $path) }
    $text = ([string](Get-Content -LiteralPath $path -Raw -ErrorAction Stop)).Trim()
    try { return [version]$text } catch { Stop-Su 3 ('The updater VERSION file is invalid: ' + $text) }
}

function Get-SuStableRoot {
    if ($TestMode -and -not [string]::IsNullOrWhiteSpace($StableRoot)) {
        return ([IO.Path]::GetFullPath($StableRoot)).TrimEnd('\')
    }
    return ([IO.Path]::GetFullPath((Get-UbStableRoot))).TrimEnd('\')
}

function Assert-SuStableInvocation {
    if ($TestMode) { return }
    $scriptRoot = ([IO.Path]::GetFullPath($PSScriptRoot)).TrimEnd('\')
    $stable = Get-SuStableRoot
    if ($scriptRoot -ine $stable) {
        Stop-Su 3 ('Self-update must run from the deployed stable directory. Expected: ' + $stable + ' ; actual: ' + $scriptRoot)
    }
}

function Test-SuSafeFileName {
    param([string]$Name)
    return ([string]::IsNullOrWhiteSpace($Name) -eq $false -and
        $Name.Length -le 96 -and
        $Name -match '^[A-Za-z0-9._-]+$' -and
        $Name -notmatch '\.\.' -and
        $Name -notmatch '^[.]' -and
        $Name -notmatch '[.]$')
}

function Get-SuChildPath {
    param([string]$Root, [string]$Name)
    if (-not (Test-SuSafeFileName -Name $Name)) { Stop-Su 7 ('Unsafe self-update file name: ' + $Name) }
    $rootFull = ([IO.Path]::GetFullPath($Root)).TrimEnd('\')
    $child = [IO.Path]::GetFullPath((Join-Path $rootFull $Name))
    if (-not $child.StartsWith(($rootFull + '\'), [StringComparison]::OrdinalIgnoreCase)) { Stop-Su 7 'Self-update path escaped its root.' }
    return $child
}

function Assert-SuRegularFile {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { Stop-Su 7 ('Refusing a non-regular or reparse-point path: ' + $Path) }
    return $item
}

function Assert-SuDirectory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { $null = New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-Su 7 ('Refusing a reparse-point directory: ' + $Path) }
    return $item
}

function Get-SuSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
}

function Save-SuDownload {
    param([string]$Url, [string]$OutputPath, [int64]$MaxBytes, [int]$TimeoutSeconds = 120)
    $curl = Get-UtCurlPath
    if ([string]::IsNullOrWhiteSpace($curl)) { Stop-Su 3 'curl.exe is unavailable.' }
    if (Test-Path -LiteralPath $OutputPath -PathType Leaf) { Remove-Item -LiteralPath $OutputPath -Force -ErrorAction Stop }
    $arguments = @(
        '--disable', '--silent', '--show-error', '--fail', '--location',
        '--proto', '=https', '--proto-redir', '=https',
        '--max-time', [string]$TimeoutSeconds,
        '--max-filesize', [string]$MaxBytes,
        '--output', $OutputPath,
        $Url
    )
    $output = & $curl @arguments 2>&1
    $exitCode = [int]$LASTEXITCODE
    if ($exitCode -ne 0) {
        Stop-Su 4 ("Download failed (curl exit {0}): {1}" -f $exitCode, (($output | Out-String).Trim()))
    }
    if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) { Stop-Su 4 'The download produced no file.' }
    $item = Assert-SuRegularFile -Path $OutputPath
    if ($item.Length -lt 1 -or $item.Length -gt $MaxBytes) { Stop-Su 4 ('Downloaded size is outside the allowed range: ' + $item.Length) }
}

function Get-SuLocalText {
    param([string]$Path, [int64]$MaxBytes)
    $item = Assert-SuRegularFile -Path $Path
    if ($item.Length -lt 1 -or $item.Length -gt $MaxBytes) { Stop-Su 5 'Local manifest size is outside the allowed range.' }
    return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
}

function Get-SuManifestObject {
    param([string]$Path, [version]$CurrentVersion)
    $raw = Get-SuLocalText -Path $Path -MaxBytes $script:SuMaxManifestBytes
    $manifest = $null
    try { $manifest = $raw | ConvertFrom-Json -ErrorAction Stop } catch { Stop-Su 5 ('Self-update manifest JSON is invalid: ' + $_.Exception.Message) }
    if ([int](Get-UbProperty $manifest 'Schema') -ne 1) { Stop-Su 5 'Unsupported self-update manifest schema.' }
    if ([string](Get-UbProperty $manifest 'Product') -ne $script:SuProduct) { Stop-Su 5 'Self-update manifest product does not match.' }
    $versionText = [string](Get-UbProperty $manifest 'Version')
    $version = $null
    try { $version = [version]$versionText } catch { Stop-Su 5 ('Self-update manifest version is invalid: ' + $versionText) }
    if ($version -le $CurrentVersion) { return [pscustomobject]@{ UpToDate = $true; Version = $version } }
    $minimumText = [string](Get-UbProperty $manifest 'MinimumVersion')
    if (-not [string]::IsNullOrWhiteSpace($minimumText)) {
        $minimum = $null
        try { $minimum = [version]$minimumText } catch { Stop-Su 5 'Self-update MinimumVersion is invalid.' }
        if ($CurrentVersion -lt $minimum) { Stop-Su 5 ('This updater is too old for an in-place update; minimum version is ' + $minimum.ToString() + '.') }
    }
    $archive = Get-UbProperty $manifest 'Archive'
    if ($null -eq $archive) { Stop-Su 5 'Self-update manifest has no archive.' }
    $archiveUrl = [string](Get-UbProperty $archive 'Url')
    $archiveHash = [string](Get-UbProperty $archive 'SHA256')
    if ($archiveHash -notmatch '^[0-9A-Fa-f]{64}$') { Stop-Su 5 'Self-update archive SHA256 is invalid.' }
    $uri = $null
    if (-not [Uri]::TryCreate($archiveUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.Host -ine 'github.com' -or -not [string]::IsNullOrEmpty($uri.UserInfo) -or -not [string]::IsNullOrEmpty($uri.Query) -or -not [string]::IsNullOrEmpty($uri.Fragment) -or -not $uri.AbsoluteUri.StartsWith($script:SuReleasePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        Stop-Su 5 'Self-update archive URL is outside the pinned GitHub release path.'
    }
    $manifestFiles = @(Get-UbProperty $manifest 'Files')
    if ($manifestFiles.Count -lt 1 -or $manifestFiles.Count -gt 64) { Stop-Su 5 'Self-update manifest has an invalid file list.' }
    $files = New-Object Collections.ArrayList
    $seen = @{}
    foreach ($entry in $manifestFiles) {
        $name = [string](Get-UbProperty $entry 'Name')
        $hash = [string](Get-UbProperty $entry 'SHA256')
        if (-not (Test-SuSafeFileName -Name $name)) { Stop-Su 5 ('Self-update manifest contains an unsafe file name: ' + $name) }
        if ($hash -notmatch '^[0-9A-Fa-f]{64}$') { Stop-Su 5 ('Self-update manifest has an invalid SHA256 for ' + $name) }
        $key = $name.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { Stop-Su 5 ('Self-update manifest contains a duplicate file: ' + $name) }
        $seen[$key] = $true
        [void]$files.Add([pscustomobject]@{ Name = $name; SHA256 = $hash.ToUpperInvariant() })
    }
    foreach ($required in @($script:UtUpdaterFiles)) {
        if (-not $seen.ContainsKey(([string]$required).ToLowerInvariant())) { Stop-Su 5 ('Self-update manifest is missing required file: ' + $required) }
    }
    return [pscustomobject]@{
        UpToDate = $false
        Version = $version
        ArchiveUrl = $archiveUrl
        ArchiveSha256 = $archiveHash.ToUpperInvariant()
        Files = @($files)
        ManifestPath = $Path
    }
}

function Get-SuManifest {
    param([version]$CurrentVersion)
    $temporary = $null
    try {
        if (-not [string]::IsNullOrWhiteSpace($ManifestPath)) {
            if (-not $TestMode) { Stop-Su 2 '-ManifestPath is only available with -TestMode.' }
            $source = [IO.Path]::GetFullPath($ManifestPath)
        } else {
            $temporary = Join-Path $env:TEMP ('ChatGPTUpdater-manifest-' + [guid]::NewGuid().ToString('N') + '.json')
            Save-SuDownload -Url $script:SuManifestUrl -OutputPath $temporary -MaxBytes $script:SuMaxManifestBytes -TimeoutSeconds 60
            $source = $temporary
        }
        return (Get-SuManifestObject -Path $source -CurrentVersion $CurrentVersion)
    } finally {
        if ($null -ne $temporary -and (Test-Path -LiteralPath $temporary -PathType Leaf)) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Save-SuArchive {
    param($Manifest)
    $temporary = Join-Path $env:TEMP ('ChatGPTUpdater-update-' + [guid]::NewGuid().ToString('N') + '.zip')
    try {
        if (-not [string]::IsNullOrWhiteSpace($ArchivePath)) {
            if (-not $TestMode) { Stop-Su 2 '-ArchivePath is only available with -TestMode.' }
            $source = [IO.Path]::GetFullPath($ArchivePath)
            $null = Assert-SuRegularFile -Path $source
            if ((Get-Item -LiteralPath $source).Length -gt $script:SuMaxArchiveBytes) { Stop-Su 6 'Local self-update archive is too large.' }
            Copy-Item -LiteralPath $source -Destination $temporary -Force -ErrorAction Stop
        } else {
            Save-SuDownload -Url $Manifest.ArchiveUrl -OutputPath $temporary -MaxBytes $script:SuMaxArchiveBytes -TimeoutSeconds 300
        }
        if ((Get-SuSha256 -Path $temporary) -ne $Manifest.ArchiveSha256) { Stop-Su 6 'Self-update archive SHA256 does not match the manifest.' }
        return $temporary
    } catch {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Expand-SuArchive {
    param([string]$Archive, $Manifest)
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $staging = Join-Path $script:SuStateRoot ('staging\' + [guid]::NewGuid().ToString('N'))
    $null = Assert-SuDirectory -Path $staging
    $zip = $null
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
        $entries = @($zip.Entries)
        if ($entries.Count -ne @($Manifest.Files).Count) { Stop-Su 6 'Self-update archive entry count does not match the manifest.' }
        $manifestByName = @{}
        foreach ($file in @($Manifest.Files)) { $manifestByName[$file.Name.ToLowerInvariant()] = $file }
        $seen = @{}
        [int64]$total = 0
        foreach ($entry in $entries) {
            $name = [string]$entry.FullName
            if (-not (Test-SuSafeFileName -Name $name)) { Stop-Su 6 ('Self-update archive contains an unsafe entry: ' + $name) }
            $key = $name.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { Stop-Su 6 ('Self-update archive contains a duplicate entry: ' + $name) }
            $seen[$key] = $true
            if (-not $manifestByName.ContainsKey($key)) { Stop-Su 6 ('Self-update archive contains an undeclared entry: ' + $name) }
            [int64]$total += [int64]$entry.Length
            if ($total -gt $script:SuMaxExpandedBytes) { Stop-Su 6 'Self-update archive expands beyond the allowed size.' }
            $destination = Get-SuChildPath -Root $staging -Name $name
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destination, $false)
        }
        foreach ($file in @($Manifest.Files)) {
            if (-not $seen.ContainsKey($file.Name.ToLowerInvariant())) { Stop-Su 6 ('Self-update archive is missing: ' + $file.Name) }
            $path = Get-SuChildPath -Root $staging -Name $file.Name
            $null = Assert-SuRegularFile -Path $path
            if ((Get-SuSha256 -Path $path) -ne $file.SHA256) { Stop-Su 6 ('Self-update file hash does not match: ' + $file.Name) }
            if ($file.Name -like '*.ps1') {
                $tokens = $null
                $errors = $null
                $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
                if (@($errors).Count -gt 0) { Stop-Su 7 ('Self-update script has a parse error: ' + $file.Name) }
            }
        }
        $versionPath = Get-SuChildPath -Root $staging -Name $script:UtUpdaterVersionFile
        $stagedVersion = $null
        try { $stagedVersion = [version]((Get-Content -LiteralPath $versionPath -Raw -ErrorAction Stop).Trim()) } catch { Stop-Su 6 'Staged VERSION is invalid.' }
        if ($stagedVersion -ne $Manifest.Version) { Stop-Su 6 'Staged VERSION does not match the manifest version.' }
        return $staging
    } catch {
        if (Test-Path -LiteralPath $staging -PathType Container) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    } finally {
        if ($null -ne $zip) { $zip.Dispose() }
    }
}

function Get-SuTask {
    try { return (Get-ScheduledTask -TaskName $script:UbTaskName -ErrorAction Stop) }
    catch { return $null }
}

function Test-SuTaskOwned {
    param($Task)
    if ($null -eq $Task) { return $false }
    if ([string]$Task.Description -ne $script:UbTaskMarker) { return $false }
    $principal = $Task.Principal
    if ($null -eq $principal) { return $false }
    $userId = [string]$principal.UserId
    if ([string]::IsNullOrWhiteSpace($userId)) { return $false }
    try {
        if ($userId -match '^S-') { $taskSid = (New-Object Security.Principal.SecurityIdentifier -ArgumentList @($userId)).Value }
        else {
            $account = New-Object Security.Principal.NTAccount -ArgumentList @($userId)
            $taskSid = $account.Translate([Security.Principal.SecurityIdentifier]).Value
        }
        return ($taskSid -eq ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value)
    } catch { return $false }
}

function Set-SuTaskEnabled {
    param([bool]$Enabled)
    $task = Get-SuTask
    if ($null -eq $task) { return $false }
    if (-not (Test-SuTaskOwned $task)) { Stop-Su 7 'The background task is not owned by this updater.' }
    if ($Enabled) { Enable-ScheduledTask -TaskName $script:UbTaskName -ErrorAction Stop | Out-Null }
    else { Disable-ScheduledTask -TaskName $script:UbTaskName -ErrorAction Stop | Out-Null }
    return $true
}

function Suspend-SuBackgroundTask {
    if ($TestMode) { return [pscustomobject]@{ Existed = $false; WasEnabled = $false } }
    $task = Get-SuTask
    if ($null -eq $task) { return [pscustomobject]@{ Existed = $false; WasEnabled = $false } }
    if (-not (Test-SuTaskOwned $task)) { Stop-Su 7 'The background task exists but is not owned by this updater; no self-update was attempted.' }
    $wasEnabled = ([string]$task.State -ne 'Disabled')
    if ($wasEnabled) {
        Disable-ScheduledTask -TaskName $script:UbTaskName -ErrorAction Stop | Out-Null
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ($true) {
        $current = Get-SuTask
        if ($null -eq $current -or [string]$current.State -ne 'Running') { break }
        if ([DateTime]::UtcNow -ge $deadline) {
            if ($wasEnabled) { try { Enable-ScheduledTask -TaskName $script:UbTaskName -ErrorAction SilentlyContinue | Out-Null } catch { } }
            Stop-Su 8 'The background task is still running; close it and retry the self-update.'
        }
        Start-Sleep -Milliseconds 500
    }
    $promptLock = Join-Path (Get-UbRoot) 'background-prompt.lock'
    if (Test-Path -LiteralPath $promptLock -PathType Leaf) {
        $stream = $null
        try { $stream = [IO.File]::Open($promptLock, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch {
            if ($wasEnabled) { try { Enable-ScheduledTask -TaskName $script:UbTaskName -ErrorAction SilentlyContinue | Out-Null } catch { } }
            Stop-Su 8 'A confirmation window is active; close it and retry the self-update.'
        }
        finally { if ($null -ne $stream) { $stream.Dispose() } }
    }
    return [pscustomobject]@{ Existed = $true; WasEnabled = $wasEnabled }
}

function Write-SuJson {
    param([string]$Path, $Value)
    $directory = Split-Path -Parent $Path
    $null = Assert-SuDirectory -Path $directory
    $text = $Value | ConvertTo-Json -Depth 8 -Compress
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $text, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try { [IO.File]::Replace($temporary, $Path, $null, $true) }
            catch { Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop }
        } else { Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop }
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Start-SuActivation {
    param($Manifest, [string]$Staging, $TaskState)
    $stable = Get-SuStableRoot
    $null = Assert-SuDirectory -Path $stable
    $runId = [guid]::NewGuid().ToString('N')
    $backup = Join-Path $script:SuStateRoot ('backups\' + $runId)
    $planDirectory = Join-Path $script:SuStateRoot 'plans'
    $helperDirectory = Join-Path $script:SuStateRoot 'helpers'
    $null = Assert-SuDirectory -Path $backup
    $null = Assert-SuDirectory -Path $planDirectory
    $null = Assert-SuDirectory -Path $helperDirectory
    $planPath = Join-Path $planDirectory ($runId + '.json')
    $pendingPath = Join-Path $stable $script:SuPendingName
    $lockPath = Join-Path $script:SuStateRoot 'self-update.lock'
    $files = @($Manifest.Files | ForEach-Object { [ordered]@{ Name = $_.Name; SHA256 = $_.SHA256 } })
    $plan = [ordered]@{
        Schema = 1
        Version = $Manifest.Version.ToString()
        StableRoot = $stable
        StagingRoot = $Staging
        BackupRoot = $backup
        PendingPath = $pendingPath
        ResultPath = $script:SuResultPath
        LogPath = $script:SuLogPath
        LockPath = $lockPath
        ParentPid = $PID
        TaskName = $script:UbTaskName
        TaskMarker = $script:UbTaskMarker
        TaskWasEnabled = [bool]$TaskState.WasEnabled
        TestMode = [bool]$TestMode
        Files = $files
    }
    Write-SuJson -Path $planPath -Value $plan
    $pending = [ordered]@{
        Schema = 1
        Version = $Manifest.Version.ToString()
        StartedUtc = [DateTime]::UtcNow.ToString('o')
        ParentPid = $PID
        BackupRoot = $backup
        StagingRoot = $Staging
        ResultPath = $script:SuResultPath
    }
    Write-SuJson -Path $pendingPath -Value $pending
    $helperSource = Get-SuChildPath -Root $Staging -Name 'self-update-helper.ps1'
    $helperCopy = Join-Path $helperDirectory ('helper-' + $runId + '.ps1')
    Copy-Item -LiteralPath $helperSource -Destination $helperCopy -Force -ErrorAction Stop
    if ((Get-SuSha256 -Path $helperCopy) -ne (Get-SuSha256 -Path $helperSource)) { Stop-Su 7 'The staged self-update helper copy did not match.' }
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powerShell -PathType Leaf)) { $powerShell = 'powershell.exe' }
    $arguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', (ConvertTo-UbProcessArgument -Value $helperCopy),
        '-PlanPath', (ConvertTo-UbProcessArgument -Value $planPath)
    ) -join ' '
    try {
        $process = Start-Process -FilePath $powerShell -ArgumentList $arguments -WindowStyle Hidden -PassThru -ErrorAction Stop
    } catch {
        if ($TaskState.WasEnabled) { try { $null = Set-SuTaskEnabled -Enabled $true } catch { } }
        Remove-Item -LiteralPath $pendingPath -Force -ErrorAction SilentlyContinue
        Stop-Su 3 ('Failed to launch the self-update activation helper: ' + $_.Exception.Message)
    }
    Write-SuLog ('Self-update activation scheduled for version ' + $Manifest.Version.ToString() + '; helper PID ' + $process.Id + '.')
    Write-SuLine ('Self-update {0} staged. The helper will replace the updater files after this process exits.' -f $Manifest.Version.ToString())
    Write-SuLine ('Backup: {0}' -f $backup)
    Write-SuLine 'Run update-updater.cmd -Status after a few seconds to check the result.'
    return 0
}

function Show-SuStatus {
    $version = Get-SuCurrentVersion
    $stable = Get-SuStableRoot
    Write-SuLine ('Updater version: {0}' -f $version.ToString())
    Write-SuLine ('Stable root:     {0}' -f $stable)
    $pendingPath = Join-Path $stable $script:SuPendingName
    if (Test-Path -LiteralPath $pendingPath -PathType Leaf) {
        Write-SuLine ('Pending marker:  {0}' -f $pendingPath)
        try { Write-SuLine ('Pending:         ' + ([IO.File]::ReadAllText($pendingPath, [Text.Encoding]::UTF8))) } catch { }
    } else { Write-SuLine 'Pending marker:  none' }
    if (Test-Path -LiteralPath $script:SuResultPath -PathType Leaf) {
        try { Write-SuLine ('Last result:     ' + ([IO.File]::ReadAllText($script:SuResultPath, [Text.Encoding]::UTF8))) } catch { }
    }
    $backups = @(Get-ChildItem -LiteralPath (Join-Path $script:SuStateRoot 'backups') -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 5)
    if ($backups.Count -gt 0) {
        Write-SuLine 'Recent backups:'
        foreach ($item in $backups) { Write-SuLine ('  ' + $item.FullName) }
    }
    return 0
}

function Get-SuLatestBackup {
    $root = Join-Path $script:SuStateRoot 'backups'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { Stop-Su 3 'No self-update backups are available.' }
    $candidates = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop | Where-Object {
        $manifestPath = Join-Path $_.FullName 'backup.json'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $false }
        try { $manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop } catch { return $false }
        return ([bool](Get-UbProperty $manifest 'Complete'))
    } | Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -eq 0) { Stop-Su 3 'No completed self-update backup is available.' }
    return $candidates[0]
}

function Invoke-SuRollback {
    $currentVersion = Get-SuCurrentVersion
    $backupItem = Get-SuLatestBackup
    $backupRoot = $backupItem.FullName
    $backupManifestPath = Join-Path $backupRoot 'backup.json'
    $backupManifest = $null
    try { $backupManifest = Get-Content -LiteralPath $backupManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { Stop-Su 7 'The selected backup manifest is invalid.' }
    if ([int](Get-UbProperty $backupManifest 'Schema') -ne 1) { Stop-Su 7 'Unsupported backup manifest schema.' }
    $stable = Get-SuStableRoot
    $null = Assert-SuDirectory -Path $stable
    $taskState = Suspend-SuBackgroundTask
    try {
        foreach ($entry in @(Get-UbProperty $backupManifest 'Files')) {
            $name = [string](Get-UbProperty $entry 'Name')
            $target = Get-SuChildPath -Root $stable -Name $name
            $existed = [bool](Get-UbProperty $entry 'Existed')
            if ($existed) {
                $backupFile = Get-SuChildPath -Root $backupRoot -Name $name
                $null = Assert-SuRegularFile -Path $backupFile
                Copy-Item -LiteralPath $backupFile -Destination $target -Force -ErrorAction Stop
            } elseif (Test-Path -LiteralPath $target -PathType Leaf) {
                Remove-Item -LiteralPath $target -Force -ErrorAction Stop
            }
        }
        $pendingPath = Join-Path $stable $script:SuPendingName
        Remove-Item -LiteralPath $pendingPath -Force -ErrorAction SilentlyContinue
        if ($taskState.WasEnabled) { try { $null = Set-SuTaskEnabled -Enabled $true } catch { } }
        Write-SuJson -Path $script:SuResultPath -Value ([ordered]@{
            Status = 'RolledBack'
            Version = $currentVersion.ToString()
            CompletedUtc = [DateTime]::UtcNow.ToString('o')
            BackupRoot = $backupRoot
        })
        Write-SuLine ('Rolled back from backup: {0}' -f $backupRoot)
        return 0
    } catch {
        if ($taskState.WasEnabled) { try { $null = Set-SuTaskEnabled -Enabled $true } catch { } }
        Stop-Su 1 ('Rollback failed: ' + $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------
# Entry point.
# ---------------------------------------------------------------------------
try {
    $actions = @(@($CheckOnly.IsPresent, $Apply.IsPresent, $Status.IsPresent, $Rollback.IsPresent) | Where-Object { $_ })
    if ($actions.Count -gt 1) { Stop-Su 2 'Use exactly one of -CheckOnly, -Apply, -Status or -Rollback.' }
    if (-not $TestMode) {
        if (-not [string]::IsNullOrWhiteSpace($ManifestPath) -or -not [string]::IsNullOrWhiteSpace($ArchivePath) -or -not [string]::IsNullOrWhiteSpace($StableRoot) -or $NoActivate) {
            Stop-Su 2 'ManifestPath, ArchivePath, StableRoot and NoActivate are test-only options.'
        }
    }
    $null = Assert-SuDirectory -Path $script:SuStateRoot
    if ($Apply -or $Rollback) {
        $lockPath = Join-Path $script:SuStateRoot 'self-update.lock'
        try {
            $script:SuApplyLockStream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        } catch { Stop-Su 8 'Another self-update or rollback is already running.' }
    }
    if ($Status) { exit (Show-SuStatus) }
    if ($Rollback) { Assert-SuStableInvocation; exit (Invoke-SuRollback) }
    Assert-SuStableInvocation
    $pendingPath = Join-Path (Get-SuStableRoot) $script:SuPendingName
    if ($Apply -and (Test-Path -LiteralPath $pendingPath -PathType Leaf)) {
        Stop-Su 8 'A self-update is already pending or incomplete. Run update-updater.cmd -Status and -Rollback if needed.'
    }
    $current = Get-SuCurrentVersion
    Write-SuLine ('Updater version: {0}' -f $current.ToString())
    $manifest = Get-SuManifest -CurrentVersion $current
    if ([bool]$manifest.UpToDate) {
        Write-SuLine ('Updater is current: {0}' -f $manifest.Version.ToString())
        exit 0
    }
    Write-SuLine ('Updater update available: {0} -> {1}' -f $current.ToString(), $manifest.Version.ToString())
    if ($CheckOnly -or (-not $Apply)) {
        Write-SuLine 'Check-only: no updater files were staged or replaced.'
        exit 0
    }
    $archive = $null
    $staging = $null
    try {
        $archive = Save-SuArchive -Manifest $manifest
        $staging = Expand-SuArchive -Archive $archive -Manifest $manifest
        Write-SuLine ('Verified {0} files for updater version {1}.' -f @($manifest.Files).Count, $manifest.Version.ToString())
        if ($NoActivate) {
            Write-SuLine ('Test mode: staging retained at {0}' -f $staging)
            exit 0
        }
        $taskState = Suspend-SuBackgroundTask
        Write-SuLine 'This will replace the updater scripts in the stable directory. The background task is paused during activation.'
        try {
            $result = Start-SuActivation -Manifest $manifest -Staging $staging -TaskState $taskState
        } catch {
            if ($taskState.WasEnabled) { try { $null = Set-SuTaskEnabled -Enabled $true } catch { } }
            Remove-Item -LiteralPath (Join-Path (Get-SuStableRoot) $script:SuPendingName) -Force -ErrorAction SilentlyContinue
            throw
        }
        if ($null -ne $archive -and (Test-Path -LiteralPath $archive -PathType Leaf)) { Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue }
        exit ([int]$result)
    } catch {
        if ($null -ne $archive -and (Test-Path -LiteralPath $archive -PathType Leaf)) { Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue }
        throw
    }
} catch {
    $message = $_.Exception.Message
    $code = Get-SuExitCode -ErrorRecord $_ -Default 1
    Write-SuLog ('Self-update failed: ' + $message)
    Write-SuError ('ERROR: ' + $message)
    exit $code
} finally {
    if ($null -ne $script:SuApplyLockStream) { $script:SuApplyLockStream.Dispose() }
}
