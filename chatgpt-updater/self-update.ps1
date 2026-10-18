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
$script:SuUpdateLockStream = $null
$script:SuTransactionSchema = 2

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

function Get-SuPathBoundary {
    param([string]$Path)
    return ([IO.Path]::GetFullPath((Get-UbLocalAppData))).TrimEnd('\')
}

function Assert-SuNoReparseAncestors {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Boundary
    )
    $full = ([IO.Path]::GetFullPath($Path)).TrimEnd('\')
    $boundaryFull = ([IO.Path]::GetFullPath($Boundary)).TrimEnd('\')
    if ($full -ne $boundaryFull -and -not $full.StartsWith(($boundaryFull + '\'), [StringComparison]::OrdinalIgnoreCase)) {
        Stop-Su 7 ('Self-update path is outside its managed boundary: ' + $Path)
    }
    $probe = $full
    while (-not (Test-Path -LiteralPath $probe)) {
        $parent = [IO.Directory]::GetParent($probe)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $probe) { break }
        $probe = $parent
    }
    while (-not [string]::IsNullOrWhiteSpace($probe)) {
        $item = Get-Item -LiteralPath $probe -Force -ErrorAction Stop
        if ($probe -ine $boundaryFull -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            Stop-Su 7 ('Refusing a reparse-point ancestor in the self-update path: ' + $probe)
        }
        if ($probe -ieq $boundaryFull) { break }
        $parent = if ($item.PSIsContainer) { $item.Parent } else { $item.Directory }
        if ($null -eq $parent) { break }
        $probe = $parent.FullName
    }
}

function Assert-SuOwnedPath {
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$AllowMissingLeaf)
    $full = ([IO.Path]::GetFullPath($Path)).TrimEnd('\')
    $boundary = Get-SuPathBoundary
    Assert-SuNoReparseAncestors -Path $full -Boundary $boundary
    if (-not $AllowMissingLeaf -and (Test-Path -LiteralPath $full)) {
        $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-Su 7 ('Refusing a reparse-point self-update path: ' + $full) }
    }
    return $full
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
    if ($Path.StartsWith((Get-SuPathBoundary + '\'), [StringComparison]::OrdinalIgnoreCase)) { Assert-SuNoReparseAncestors -Path $Path -Boundary (Get-SuPathBoundary) }
    return $item
}

function Assert-SuDirectory {
    param([string]$Path)
    $full = ([IO.Path]::GetFullPath($Path)).TrimEnd('\')
    if ($full.StartsWith((Get-SuPathBoundary + '\'), [StringComparison]::OrdinalIgnoreCase)) { Assert-SuNoReparseAncestors -Path $full -Boundary (Get-SuPathBoundary) }
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
        '--disable', '--silent', '--show-error', '--fail', '--location', '--globoff',
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

function Test-SuTaskNotFoundError {
    param($ErrorRecord)
    if ($null -eq $ErrorRecord) { return $false }
    $message = [string]$ErrorRecord.Exception.Message
    $hresult = 0
    try { $hresult = [int]$ErrorRecord.Exception.HResult } catch { }
    $fqid = [string]$ErrorRecord.FullyQualifiedErrorId
    $category = [string]$ErrorRecord.CategoryInfo.Category
    return (($fqid -match '(?i)^CmdletizationQuery_NotFound_TaskName,Get-ScheduledTask' -and $category -eq 'ObjectNotFound') -or
        $hresult -eq -2147024894 -or
        $message -match '(?i)0x80070002' -or
        $message -match '(?i)the system cannot find the file specified' -or
        $message -match '(?i)no MSFT_ScheduledTask object found')
}

function Get-SuTask {
    try { return (Get-ScheduledTask -TaskName $script:UbTaskName -ErrorAction Stop) }
    catch {
        if (Test-SuTaskNotFoundError $_) { return $null }
        throw ('Unable to query the updater background task: ' + $_.Exception.Message)
    }
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
    $disableAttempted = $false
    try {
        if ($wasEnabled) {
            $disableAttempted = $true
            Disable-ScheduledTask -TaskName $script:UbTaskName -ErrorAction Stop | Out-Null
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while ($true) {
            $current = Get-SuTask
            if ($null -eq $current -or [string]$current.State -ne 'Running') { break }
            if ([DateTime]::UtcNow -ge $deadline) { Stop-Su 8 'The background task is still running; close it and retry the self-update.' }
            Start-Sleep -Milliseconds 500
        }
        $promptLock = Join-Path (Get-UbRoot) 'background-prompt.lock'
        if (Test-Path -LiteralPath $promptLock -PathType Leaf) {
            $stream = $null
            try { $stream = [IO.File]::Open($promptLock, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
            catch { Stop-Su 8 'A confirmation window is active; close it and retry the self-update.' }
            finally { if ($null -ne $stream) { $stream.Dispose() } }
        }
        return [pscustomobject]@{ Existed = $true; WasEnabled = $wasEnabled }
    } catch {
        $failure = $_.Exception.Message
        if (-not $wasEnabled -or -not $disableAttempted) { throw }
        $recoveryErrors = New-Object Collections.ArrayList
        try {
            if (-not (Set-SuTaskEnabled -Enabled $true)) { throw 'The background task disappeared before it could be re-enabled.' }
            $after = Get-SuTask
            if ($null -eq $after -or [string]$after.State -eq 'Disabled') { throw 'The background task did not return to the enabled state.' }
        } catch { [void]$recoveryErrors.Add('task re-enable: ' + $_.Exception.Message) }
        if ($recoveryErrors.Count -gt 0) {
            try {
                Write-SuJson -Path $script:SuResultPath -Value ([ordered]@{
                    Status = 'RecoveryRequired'
                    Error = $failure
                    RecoveryErrors = @($recoveryErrors)
                    TaskWasEnabled = $true
                    Action = 'Re-enable the updater background task, then retry self-update recovery.'
                })
            } catch { }
            Stop-Su 1 ('Self-update could not quiesce the background task and recovery is required: ' + (($recoveryErrors -join '; ')))
        }
        throw
    }
}

function Write-SuJson {
    param([string]$Path, $Value)
    $directory = Split-Path -Parent $Path
    $null = Assert-SuDirectory -Path $directory
    if (Test-Path -LiteralPath $Path -PathType Leaf) { $null = Assert-SuRegularFile -Path $Path }
    $text = $Value | ConvertTo-Json -Depth 8 -Compress
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $text, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try { [IO.File]::Replace($temporary, $Path, [NullString]::Value, $true) }
            catch { Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop }
        } else { Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop }
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Get-SuPendingPath {
    return (Assert-SuOwnedPath -Path (Join-Path (Get-SuStableRoot) $script:SuPendingName) -AllowMissingLeaf)
}

function Get-SuPendingObject {
    $path = Get-SuPendingPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $item = Assert-SuRegularFile -Path $path
    if ($item.Length -gt 262144) { Stop-Su 7 'The self-update pending marker is too large.' }
    try { return ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop) }
    catch { Stop-Su 7 ('The self-update pending marker is invalid: ' + $_.Exception.Message) }
}

function Test-SuTransactionMatches {
    param($Pending, $Plan, [string]$PlanPath)
    if ($null -eq $Pending -or $null -eq $Plan) { return $false }
    $pendingSchema = [int](Get-UbProperty $Pending 'Schema')
    $planSchema = [int](Get-UbProperty $Plan 'Schema')
    $pendingId = [string](Get-UbProperty $Pending 'TransactionId')
    $planId = [string](Get-UbProperty $Plan 'TransactionId')
    $schema2 = ($pendingSchema -ge 2 -or $planSchema -ge 2 -or -not [string]::IsNullOrWhiteSpace($pendingId) -or -not [string]::IsNullOrWhiteSpace($planId))
    if ($schema2) {
        if ([string]::IsNullOrWhiteSpace($pendingId) -or [string]::IsNullOrWhiteSpace($planId) -or $pendingId -ne $planId) { return $false }
    }
    $fields = @('Version','StagingRoot','BackupRoot','ResultPath')
    if ($schema2) { $fields += @('PendingPath','OrdinaryLockPath','PlanPath') }
    foreach ($field in $fields) {
        $left = [string](Get-UbProperty $Pending $field)
        $right = [string](Get-UbProperty $Plan $field)
        if ([string]::IsNullOrWhiteSpace($left) -or [string]::IsNullOrWhiteSpace($right)) { return $false }
        if ($field -match 'Path$' -or $field -in @('StagingRoot','BackupRoot','ResultPath','PendingPath','OrdinaryLockPath')) {
            try { if (([IO.Path]::GetFullPath($left)).TrimEnd('\') -ine ([IO.Path]::GetFullPath($right)).TrimEnd('\')) { return $false } }
            catch { return $false }
        } elseif ($left -ine $right) { return $false }
    }
    if (-not $schema2) {
        $pendingPlan = [string](Get-UbProperty $Pending 'PlanPath')
        if (-not [string]::IsNullOrWhiteSpace($pendingPlan)) {
            if ([string]::IsNullOrWhiteSpace($PlanPath)) { return $false }
            try { if (([IO.Path]::GetFullPath($pendingPlan)).TrimEnd('\') -ine ([IO.Path]::GetFullPath($PlanPath)).TrimEnd('\')) { return $false } }
            catch { return $false }
        }
    }
    return $true
}

function Write-SuPlanStatus {
    param([string]$PlanPath, [string]$Status, [string[]]$Completed = @(), [string]$ErrorMessage = $null)
    if ([string]::IsNullOrWhiteSpace($PlanPath) -or -not (Test-Path -LiteralPath $PlanPath -PathType Leaf)) { return }
    $plan = $null
    try { $plan = [IO.File]::ReadAllText($PlanPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop } catch { return }
    $plan | Add-Member -NotePropertyName Status -NotePropertyValue $Status -Force
    $plan | Add-Member -NotePropertyName UpdatedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    $plan | Add-Member -NotePropertyName CompletedFiles -NotePropertyValue @($Completed) -Force
    if ($null -ne $ErrorMessage) { $plan | Add-Member -NotePropertyName Error -NotePropertyValue $ErrorMessage -Force }
    try { Write-SuJson -Path $PlanPath -Value $plan }
    catch {
        Write-SuLog ('Failed to persist plan status: ' + $_.Exception.Message)
        throw
    }
}

function Set-SuPendingStatus {
    param($Pending, [string]$Status, [string]$Reason = $null)
    if ($null -eq $Pending) { return $null }
    $copy = $Pending | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $copy | Add-Member -NotePropertyName Status -NotePropertyValue $Status -Force
    $copy | Add-Member -NotePropertyName UpdatedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    if ($null -ne $Reason) { $copy | Add-Member -NotePropertyName Reason -NotePropertyValue $Reason -Force }
    Write-SuJson -Path (Get-SuPendingPath) -Value $copy
    return $copy
}

function Remove-SuPendingExact {
    param($Pending, [switch]$AllowMissing)
    $path = Get-SuPendingPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        if ($AllowMissing) { return }
        Stop-Su 1 'The self-update pending marker is missing during recovery.'
    }
    if ($null -ne $Pending) {
        $current = Get-SuPendingObject
        if ($null -eq $current -or -not (Test-SuTransactionMatches -Pending $current -Plan $Pending -PlanPath ([string](Get-UbProperty $Pending 'PlanPath')))) {
            Stop-Su 7 'The self-update pending marker belongs to another transaction.'
        }
    }
    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $path) { Stop-Su 1 'The self-update pending marker could not be removed.' }
}

function Enter-SuCoordinationLocks {
    try { $script:SuUpdateLockStream = Enter-UtLock }
    catch { Stop-Su 8 ('Another foreground updater holds the ordinary update lock, or it could not be acquired: ' + $_.Exception.Message) }
    try {
        $lockPath = Assert-SuOwnedPath -Path (Join-Path $script:SuStateRoot 'self-update.lock') -AllowMissingLeaf
        $script:SuApplyLockStream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch {
        if ($null -ne $script:SuUpdateLockStream) { $script:SuUpdateLockStream.Dispose(); $script:SuUpdateLockStream = $null }
        Stop-Su 8 ('Another self-update or rollback is already running, or its lock path is unusable: ' + $_.Exception.Message)
    }
}

function Start-SuActivation {
    param($Manifest, [string]$Staging, $TaskState)
    $runId = [guid]::NewGuid().ToString('N')
    $stable = $null
    $backup = $null
    $planPath = $null
    $pendingPath = $null
    $pending = $null
    $planWritten = $false
    $pendingWritten = $false
    try {
        $stable = Get-SuStableRoot
        $null = Assert-SuDirectory -Path $stable
        $backup = Join-Path $script:SuStateRoot ('backups\' + $runId)
        $planDirectory = Join-Path $script:SuStateRoot 'plans'
        $helperDirectory = Join-Path $script:SuStateRoot 'helpers'
        $null = Assert-SuDirectory -Path $backup
        $null = Assert-SuDirectory -Path $planDirectory
        $null = Assert-SuDirectory -Path $helperDirectory
        $planPath = Join-Path $planDirectory ($runId + '.json')
        $pendingPath = Join-Path $stable $script:SuPendingName
        $lockPath = Join-Path $script:SuStateRoot 'self-update.lock'
        $ordinaryLockPath = Join-Path (Get-UbRoot) 'update.lock'
        $files = @($Manifest.Files | ForEach-Object { [ordered]@{ Name = $_.Name; SHA256 = $_.SHA256 } })
        $plan = [ordered]@{
            Schema = $script:SuTransactionSchema
            TransactionId = $runId
            Status = 'Pending'
            Version = $Manifest.Version.ToString()
            StableRoot = $stable
            StagingRoot = $Staging
            BackupRoot = $backup
            PendingPath = $pendingPath
            ResultPath = $script:SuResultPath
            LogPath = $script:SuLogPath
            LockPath = $lockPath
            OrdinaryLockPath = $ordinaryLockPath
            PlanPath = $planPath
            ParentPid = $PID
            TaskName = $script:UbTaskName
            TaskMarker = $script:UbTaskMarker
            TaskExisted = [bool]$TaskState.Existed
            TaskWasEnabled = [bool]$TaskState.WasEnabled
            TestMode = [bool]$TestMode
            Files = $files
        }
        Write-SuJson -Path $planPath -Value $plan
        $planWritten = $true
        $pending = [ordered]@{
            Schema = $script:SuTransactionSchema
            TransactionId = $runId
            Status = 'Pending'
            Version = $Manifest.Version.ToString()
            StartedUtc = [DateTime]::UtcNow.ToString('o')
            ParentPid = $PID
            BackupRoot = $backup
            StagingRoot = $Staging
            ResultPath = $script:SuResultPath
            PlanPath = $planPath
            PendingPath = $pendingPath
            OrdinaryLockPath = $ordinaryLockPath
            TaskExisted = [bool]$TaskState.Existed
            TaskWasEnabled = [bool]$TaskState.WasEnabled
        }
        Write-SuJson -Path $pendingPath -Value $pending
        $pendingWritten = $true
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
        $process = Start-Process -FilePath $powerShell -ArgumentList $arguments -WindowStyle Hidden -PassThru -ErrorAction Stop
        Write-SuLog ('Self-update activation scheduled for version ' + $Manifest.Version.ToString() + '; helper PID ' + $process.Id + '.')
        Write-SuLine ('Self-update {0} staged. The helper will replace the updater files after this process exits.' -f $Manifest.Version.ToString())
        Write-SuLine ('Backup: {0}' -f $backup)
        Write-SuLine 'Run update-updater.cmd -Status after a few seconds to check the result.'
        return 0
    } catch {
        $failure = $_.Exception.Message
        $manifestVersionText = $null
        if ($null -ne $Manifest) { $manifestVersionText = $Manifest.Version.ToString() }
        $cleanupErrors = New-Object Collections.ArrayList
        $taskRestored = $true
        if ($null -ne $TaskState -and [bool]$TaskState.WasEnabled) {
            try {
                if (-not (Set-SuTaskEnabled -Enabled $true)) { throw 'The background task disappeared before it could be re-enabled.' }
                $after = Get-SuTask
                if ($null -eq $after -or [string]$after.State -eq 'Disabled') { throw 'The background task did not return to the enabled state.' }
            } catch {
                $taskRestored = $false
                [void]$cleanupErrors.Add('task: ' + $_.Exception.Message)
            }
        }
        if ($pendingWritten) {
            if ($taskRestored) {
                try { Remove-SuPendingExact -Pending ([pscustomobject]$pending) } catch { [void]$cleanupErrors.Add('pending: ' + $_.Exception.Message) }
            } else {
                try { $null = Set-SuPendingStatus -Pending ([pscustomobject]$pending) -Status 'RecoveryRequired' -Reason $failure } catch { [void]$cleanupErrors.Add('pending status: ' + $_.Exception.Message) }
            }
        }
        if ($planWritten -and -not $taskRestored) {
            try { Write-SuPlanStatus -PlanPath $planPath -Status 'RecoveryRequired' -ErrorMessage $failure } catch { [void]$cleanupErrors.Add('plan: ' + $_.Exception.Message) }
        } elseif ($planWritten) {
            try { Write-SuPlanStatus -PlanPath $planPath -Status 'Cancelled' -ErrorMessage $failure } catch { [void]$cleanupErrors.Add('plan: ' + $_.Exception.Message) }
        }
        if ($cleanupErrors.Count -gt 0) {
            try {
                Write-SuJson -Path $script:SuResultPath -Value ([ordered]@{
                    Status = 'RecoveryRequired'
                    TransactionId = $runId
                    Version = $manifestVersionText
                    Error = $failure
                    RecoveryErrors = @($cleanupErrors)
                })
            } catch { }
            Stop-Su 1 ('Self-update activation setup failed and recovery is required: ' + (($cleanupErrors -join '; ')))
        }
        try {
            Write-SuJson -Path $script:SuResultPath -Value ([ordered]@{
                Status = 'Failed'
                TransactionId = $runId
                Version = $manifestVersionText
                Error = $failure
            })
        } catch { }
        $code = Get-SuExitCode -ErrorRecord $_ -Default 3
        Stop-Su $code ('Failed to prepare the self-update activation helper: ' + $failure)
    }
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

function Get-SuBackupRecord {
    param([string]$BackupRoot = $null, [string]$ExpectedTransactionId = $null)
    if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
        $root = Join-Path $script:SuStateRoot 'backups'
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { Stop-Su 3 'No self-update backups are available.' }
        $items = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop | Sort-Object LastWriteTime -Descending)
        foreach ($item in $items) {
            if (Test-Path -LiteralPath (Join-Path $item.FullName 'backup.json') -PathType Leaf) { $BackupRoot = $item.FullName; break }
        }
        if ([string]::IsNullOrWhiteSpace($BackupRoot)) { Stop-Su 3 'No self-update recovery record is available.' }
    }
    $backupFull = Assert-SuOwnedPath -Path $BackupRoot
    $manifestPath = Assert-SuOwnedPath -Path (Join-Path $backupFull 'backup.json')
    $manifest = $null
    try { $manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop } catch { Stop-Su 7 'The selected self-update recovery record is invalid.' }
    $schema = [int](Get-UbProperty $manifest 'Schema')
    if ($schema -eq 1) {
        if (-not [bool](Get-UbProperty $manifest 'Complete')) { Stop-Su 3 'The interrupted legacy self-update has no durable recovery-ready backup; preserve the pending state and retry after inspection.' }
        Stop-Su 7 'The legacy self-update backup lacks integrity metadata and cannot be restored safely.'
    }
    if ($schema -ne $script:SuTransactionSchema) { Stop-Su 7 'Unsupported self-update recovery schema.' }
    if (-not [bool](Get-UbProperty $manifest 'RecoveryReady')) { Stop-Su 3 'The current self-update backup is incomplete; recovery is not ready.' }
    $manifestId = [string](Get-UbProperty $manifest 'TransactionId')
    if (-not [string]::IsNullOrWhiteSpace($ExpectedTransactionId) -and $manifestId -ne $ExpectedTransactionId) { Stop-Su 7 'The self-update recovery record belongs to another transaction.' }
    $readyPath = Get-SuChildPath -Root $backupFull -Name 'recovery-ready.json'
    $null = Assert-SuRegularFile -Path $readyPath
    try { $ready = [IO.File]::ReadAllText($readyPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop }
    catch { Stop-Su 7 'The self-update recovery-ready marker is invalid.' }
    if (-not [bool](Get-UbProperty $ready 'Ready') -or [string](Get-UbProperty $ready 'TransactionId') -ne $manifestId -or [string](Get-UbProperty $ready 'BackupManifestSHA256') -ne (Get-SuSha256 -Path $manifestPath)) { Stop-Su 7 'The self-update recovery-ready marker does not match the backup.' }
    $stable = [IO.Path]::GetFullPath((Get-SuStableRoot)).TrimEnd('\')
    $manifestStable = [string](Get-UbProperty $manifest 'StableRoot')
    if ([string]::IsNullOrWhiteSpace($manifestStable) -or ([IO.Path]::GetFullPath($manifestStable)).TrimEnd('\') -ine $stable) { Stop-Su 7 'The self-update recovery record targets another stable directory.' }
    $versionText = [string](Get-UbProperty $manifest 'Version')
    try { $oldVersion = [version]$versionText } catch { Stop-Su 7 'The self-update recovery VERSION is invalid.' }
    $files = @(Get-UbProperty $manifest 'Files')
    if ($files.Count -lt 1) { Stop-Su 7 'The self-update recovery record contains no files.' }
    $seen = @{}
    foreach ($entry in $files) {
        $name = [string](Get-UbProperty $entry 'Name')
        if (-not (Test-SuSafeFileName -Name $name) -or $seen.ContainsKey($name.ToLowerInvariant())) { Stop-Su 7 'The self-update recovery record contains an unsafe or duplicate file.' }
        $seen[$name.ToLowerInvariant()] = $true
        $existedProperty = $entry.PSObject.Properties['Existed']
        if ($null -eq $existedProperty) { Stop-Su 7 ('The recovery record is missing existence state for ' + $name) }
        $existed = [bool]$existedProperty.Value
        $originalHash = [string](Get-UbProperty $entry 'OriginalSHA256')
        $activatedHash = [string](Get-UbProperty $entry 'ActivatedSHA256')
        if ($activatedHash -notmatch '^[0-9A-Fa-f]{64}$' -or ($existed -and $originalHash -notmatch '^[0-9A-Fa-f]{64}$')) { Stop-Su 7 ('The recovery record lacks integrity hashes for ' + $name) }
        $backupFile = Get-SuChildPath -Root $backupFull -Name $name
        if ($existed) {
            $null = Assert-SuRegularFile -Path $backupFile
            if ((Get-SuSha256 -Path $backupFile) -ne $originalHash.ToUpperInvariant()) { Stop-Su 7 ('The recovery backup is corrupt: ' + $name) }
        } elseif (Test-Path -LiteralPath $backupFile) {
            Stop-Su 7 ('The recovery record unexpectedly contains a backup for a missing target: ' + $name)
        }
    }
    if (-not $seen.ContainsKey('version')) { Stop-Su 7 'The self-update recovery record has no VERSION backup.' }
    $versionBackup = Get-SuChildPath -Root $backupFull -Name 'VERSION'
    try { $recordedVersion = [version]([IO.File]::ReadAllText($versionBackup, [Text.Encoding]::UTF8).Trim()) }
    catch { Stop-Su 7 'The recovery VERSION backup is missing or invalid.' }
    if ($recordedVersion -ne $oldVersion) { Stop-Su 7 'The recovery VERSION backup does not match its record.' }
    return [pscustomobject]@{ Root = $backupFull; Manifest = $manifest; Version = $oldVersion }
}

function Get-SuPendingPlan {
    param($Pending)
    $planPath = [string](Get-UbProperty $Pending 'PlanPath')
    if (-not [string]::IsNullOrWhiteSpace($planPath) -and (Test-Path -LiteralPath $planPath -PathType Leaf)) {
        $planFull = Assert-SuOwnedPath -Path $planPath
        $null = Assert-SuRegularFile -Path $planFull
        try { $plan = [IO.File]::ReadAllText($planFull, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop }
        catch { Stop-Su 7 'The self-update transaction plan is invalid.' }
        if (-not (Test-SuTransactionMatches -Pending $Pending -Plan $plan -PlanPath $planFull)) { Stop-Su 7 'The self-update transaction plan does not match the pending marker.' }
        return [pscustomobject]@{ Path = $planFull; Plan = $plan }
    }
    if ([int](Get-UbProperty $Pending 'Schema') -ge 2) { Stop-Su 7 'The current transaction plan is missing; preserve pending state for recovery.' }
    $plansRoot = Join-Path $script:SuStateRoot 'plans'
    if (Test-Path -LiteralPath $plansRoot -PathType Container) {
        foreach ($item in @(Get-ChildItem -LiteralPath $plansRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            try { $candidate = [IO.File]::ReadAllText($item.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if (Test-SuTransactionMatches -Pending $Pending -Plan $candidate -PlanPath $item.FullName) { return [pscustomobject]@{ Path = $item.FullName; Plan = $candidate } }
        }
    }
    return $null
}

function Set-SuTaskFinalState {
    param([bool]$Enabled, [bool]$Existed)
    if ($TestMode) { return }
    $task = Get-SuTask
    if ($null -eq $task) {
        if ($Existed -or $Enabled) { Stop-Su 1 'The updater background task disappeared during self-update recovery.' }
        return
    }
    if (-not (Test-SuTaskOwned $task)) { Stop-Su 7 'The background task is not owned by this updater.' }
    $null = Set-SuTaskEnabled -Enabled $Enabled
    $after = Get-SuTask
    if ($null -eq $after) { Stop-Su 1 'The updater background task disappeared after recovery.' }
    $isEnabled = ([string]$after.State -ne 'Disabled')
    if ($isEnabled -ne $Enabled) { Stop-Su 1 ('The updater background task did not reach the requested state: enabled=' + $Enabled) }
}

function Restore-SuFileAtomic {
    param([string]$Source, [string]$Target, [string]$SHA256)
    $temporary = $Target + '.restore-' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        Copy-Item -LiteralPath $Source -Destination $temporary -ErrorAction Stop
        if ((Get-SuSha256 -Path $temporary) -ne $SHA256.ToUpperInvariant()) { Stop-Su 7 'The prepared rollback file does not match its backup.' }
        if (Test-Path -LiteralPath $Target -PathType Leaf) { [IO.File]::Replace($temporary, $Target, [NullString]::Value, $true) }
        elseif (Test-Path -LiteralPath $Target) { Stop-Su 7 'The rollback target is not a regular file.' }
        else { [IO.File]::Move($temporary, $Target) }
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-SuRollback {
    $stable = Get-SuStableRoot
    $null = Assert-SuDirectory -Path $stable
    $pending = Get-SuPendingObject
    $pendingPlan = if ($null -ne $pending) { Get-SuPendingPlan -Pending $pending } else { $null }
    $desiredEnabled = $false
    $desiredExisted = $false
    $backupRecord = $null
    if ($null -ne $pending) {
        $pendingStatusBefore = [string](Get-UbProperty $pending 'Status')
        $planStatusBefore = if ($null -eq $pendingPlan) { $pendingStatusBefore } else { [string](Get-UbProperty $pendingPlan.Plan 'Status') }
        $desiredEnabled = [bool](Get-UbProperty $pending 'TaskWasEnabled')
        $desiredExisted = [bool](Get-UbProperty $pending 'TaskExisted')
        if ($null -ne $pendingPlan) {
            $desiredEnabled = [bool](Get-UbProperty $pendingPlan.Plan 'TaskWasEnabled')
            $desiredExisted = [bool](Get-UbProperty $pendingPlan.Plan 'TaskExisted')
        }
        $null = Set-SuPendingStatus -Pending $pending -Status 'CancelRequested' -Reason 'Rollback requested.'
        if ($null -ne $pendingPlan) { Write-SuPlanStatus -PlanPath $pendingPlan.Path -Status 'CancelRequested' }
        $backupPath = [string](Get-UbProperty $pending 'BackupRoot')
        if ([string]::IsNullOrWhiteSpace($backupPath) -and $null -ne $pendingPlan) { $backupPath = [string](Get-UbProperty $pendingPlan.Plan 'BackupRoot') }
        if (-not [string]::IsNullOrWhiteSpace($backupPath) -and (Test-Path -LiteralPath $backupPath -PathType Container)) {
            $backupFull = Assert-SuOwnedPath -Path $backupPath -AllowMissingLeaf
            $manifestPath = Join-Path $backupFull 'backup.json'
            if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
                $manifest = $null
                try { $manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop } catch { throw 'The pending self-update backup manifest is invalid; recovery is required.' }
                $manifestSchema = [int](Get-UbProperty $manifest 'Schema')
                $ready = ($manifestSchema -eq $script:SuTransactionSchema -and [bool](Get-UbProperty $manifest 'RecoveryReady'))
                $activationStarted = [bool](Get-UbProperty $manifest 'ActivationStarted')
                if ($manifestSchema -ne $script:SuTransactionSchema -or $ready -or $activationStarted -or $planStatusBefore -match '^(?i:RecoveryReady|Activating|RecoveryRequired)$') {
                    $expectedId = [string](Get-UbProperty $pending 'TransactionId')
                    if ([string]::IsNullOrWhiteSpace($expectedId) -and $null -ne $pendingPlan) { $expectedId = [string](Get-UbProperty $pendingPlan.Plan 'TransactionId') }
                    $backupRecord = Get-SuBackupRecord -BackupRoot $backupFull -ExpectedTransactionId $expectedId
                }
            }
        }
        if ($null -eq $backupRecord -and ($pendingStatusBefore -match '^(?i:RecoveryReady|Activating|RecoveryRequired|Rollback)$' -or $planStatusBefore -match '^(?i:RecoveryReady|Activating|RecoveryRequired|Rollback)$')) {
            $reason = 'The interrupted transaction recovery record is missing or not ready; pending state was retained.'
            $null = Set-SuPendingStatus -Pending $pending -Status 'RecoveryRequired' -Reason $reason
            if ($null -ne $pendingPlan) { Write-SuPlanStatus -PlanPath $pendingPlan.Path -Status 'RecoveryRequired' -ErrorMessage $reason }
            Stop-Su 3 $reason
        }
    } else {
        $backupRecord = Get-SuBackupRecord
        $desiredEnabled = [bool](Get-UbProperty $backupRecord.Manifest 'TaskWasEnabled')
        $desiredExisted = [bool](Get-UbProperty $backupRecord.Manifest 'TaskExisted')
        # A rollback without an activation marker still changes the stable
        # directory.  Publish a durable rollback marker before the first
        # restore so a foreground updater cannot pass through a partial
        # restoration if a copy or task postcondition fails.
        $rollbackName = 'rollback-' + [guid]::NewGuid().ToString('N')
        $rollbackPending = [ordered]@{
            Schema = $script:SuTransactionSchema
            TransactionId = [string](Get-UbProperty $backupRecord.Manifest 'TransactionId')
            Status = 'Rollback'
            Version = [string](Get-UbProperty $backupRecord.Manifest 'TargetVersion')
            StartedUtc = [DateTime]::UtcNow.ToString('o')
            BackupRoot = $backupRecord.Root
            StagingRoot = (Join-Path $script:SuStateRoot ('staging\' + $rollbackName))
            ResultPath = $script:SuResultPath
            PendingPath = (Get-SuPendingPath)
            OrdinaryLockPath = (Join-Path (Get-UbRoot) 'update.lock')
            PlanPath = (Join-Path $script:SuStateRoot ('plans\' + $rollbackName + '.json'))
            TaskExisted = $desiredExisted
            TaskWasEnabled = $desiredEnabled
        }
        $rollbackPlan = [ordered]@{}
        foreach ($key in $rollbackPending.Keys) { $rollbackPlan[$key] = $rollbackPending[$key] }
        $rollbackPlan.StableRoot = $stable
        $rollbackPlan.LockPath = Join-Path $script:SuStateRoot 'self-update.lock'
        $rollbackPlan.LogPath = $script:SuLogPath
        $rollbackPlan.ParentPid = 0
        $rollbackPlan.TaskName = $script:UbTaskName
        $rollbackPlan.TaskMarker = $script:UbTaskMarker
        $rollbackPlan.TestMode = [bool]$TestMode
        $rollbackPlan.Files = @($backupRecord.Manifest.Files | ForEach-Object { [ordered]@{ Name = $_.Name; SHA256 = $_.ActivatedSHA256 } })
        Write-SuJson -Path $rollbackPending.PlanPath -Value $rollbackPlan
        $helperDirectory = Join-Path $script:SuStateRoot 'helpers'
        $null = Assert-SuDirectory -Path $helperDirectory
        $helperSource = Join-Path $PSScriptRoot 'self-update-helper.ps1'
        $null = Assert-SuRegularFile -Path $helperSource
        $helperCopy = Join-Path $helperDirectory ('helper-' + $rollbackName + '.ps1')
        Copy-Item -LiteralPath $helperSource -Destination $helperCopy -ErrorAction Stop
        if ((Get-SuSha256 -Path $helperCopy) -ne (Get-SuSha256 -Path $helperSource)) { Stop-Su 7 'The independent rollback helper copy did not match.' }
        Write-SuJson -Path (Get-SuPendingPath) -Value $rollbackPending
        $pending = [IO.File]::ReadAllText((Get-SuPendingPath), [Text.Encoding]::UTF8) | ConvertFrom-Json
        $pendingPlan = [pscustomobject]@{Path = $rollbackPending.PlanPath; Plan = [pscustomobject]$rollbackPlan}
    }

    $cleanupErrors = New-Object Collections.ArrayList
    try {
        # Rollback changes every stable file it restores.  Quiesce the task
        # while the ordinary/self-update locks are held, then restore the
        # durable task state recorded for this transaction below.
        $null = Suspend-SuBackgroundTask
        if ($null -ne $backupRecord) {
            foreach ($entry in @($backupRecord.Manifest.Files)) {
                $name = [string](Get-UbProperty $entry 'Name')
                $target = Get-SuChildPath -Root $stable -Name $name
                $existed = [bool](Get-UbProperty $entry 'Existed')
                if ($existed) {
                    $backupFile = Get-SuChildPath -Root $backupRecord.Root -Name $name
                    $null = Assert-SuRegularFile -Path $backupFile
                    if (Test-Path -LiteralPath $target -PathType Leaf) {
                        $null = Assert-SuRegularFile -Path $target
                        $currentHash = Get-SuSha256 -Path $target
                        $originalHash = ([string](Get-UbProperty $entry 'OriginalSHA256')).ToUpperInvariant()
                        $activatedHash = ([string](Get-UbProperty $entry 'ActivatedSHA256')).ToUpperInvariant()
                        if ($currentHash -ne $activatedHash -and $currentHash -ne $originalHash) { Stop-Su 7 ('Refusing to overwrite an unexpected target during rollback: ' + $name) }
                    } elseif (Test-Path -LiteralPath $target) {
                        Stop-Su 7 ('Refusing to replace a non-regular target during rollback: ' + $name)
                    }
                    Restore-SuFileAtomic -Source $backupFile -Target $target -SHA256 ([string](Get-UbProperty $entry 'OriginalSHA256'))
                } elseif (Test-Path -LiteralPath $target) {
                    $null = Assert-SuRegularFile -Path $target
                    $currentHash = Get-SuSha256 -Path $target
                    if ($currentHash -ne ([string](Get-UbProperty $entry 'ActivatedSHA256')).ToUpperInvariant()) { Stop-Su 7 ('Refusing to delete an unexpected target during rollback: ' + $name) }
                    Remove-Item -LiteralPath $target -Force -ErrorAction Stop
                }
            }
        }
        Set-SuTaskFinalState -Enabled:$desiredEnabled -Existed:$desiredExisted
        if ($null -ne $pending) { Remove-SuPendingExact -Pending $pending }
        if ($null -ne $pendingPlan) {
            $completedStatus = if ($null -eq $backupRecord) { 'Cancelled' } else { 'RolledBack' }
            Write-SuPlanStatus -PlanPath $pendingPlan.Path -Status $completedStatus
            $staging = [string](Get-UbProperty $pendingPlan.Plan 'StagingRoot')
            if (-not [string]::IsNullOrWhiteSpace($staging) -and (Test-Path -LiteralPath $staging -PathType Container)) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Stop }
        }
        $status = if ($null -eq $backupRecord) { 'Cancelled' } else { 'RolledBack' }
        $resultVersion = if ($null -eq $backupRecord) { [string](Get-SuCurrentVersion) } else { $backupRecord.Version.ToString() }
        $resultBackupRoot = $null
        if ($null -ne $backupRecord) { $resultBackupRoot = $backupRecord.Root }
        $resultId = if ($null -eq $backupRecord) { [string](Get-UbProperty $pending 'TransactionId') } else { [string](Get-UbProperty $backupRecord.Manifest 'TransactionId') }
        Write-SuJson -Path $script:SuResultPath -Value ([ordered]@{ Status = $status; TransactionId = $resultId; Version = $resultVersion; CompletedUtc = [DateTime]::UtcNow.ToString('o'); BackupRoot = $resultBackupRoot })
        $rollbackMessage = if ($null -eq $backupRecord) { 'Cancelled the pending self-update before activation.' } else { 'Rolled back from backup: ' + $backupRecord.Root }
        Write-SuLine $rollbackMessage
        return 0
    } catch {
        $message = $_.Exception.Message
        if ($null -ne $pending) {
            try { $null = Set-SuPendingStatus -Pending $pending -Status 'RecoveryRequired' -Reason $message } catch { [void]$cleanupErrors.Add('pending status: ' + $_.Exception.Message) }
        }
        if ($null -ne $pendingPlan) { try { Write-SuPlanStatus -PlanPath $pendingPlan.Path -Status 'RecoveryRequired' -ErrorMessage $message } catch { [void]$cleanupErrors.Add('plan status: ' + $_.Exception.Message) } }
        $recoveryBackupRoot = $null
        if ($null -ne $backupRecord) { $recoveryBackupRoot = $backupRecord.Root }
        try { Write-SuJson -Path $script:SuResultPath -Value ([ordered]@{ Status = 'RecoveryRequired'; Error = $message; BackupRoot = $recoveryBackupRoot; RecoveryErrors = @($cleanupErrors) }) } catch { }
        Stop-Su 1 ('Rollback requires recovery: ' + $message)
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
    if ($Apply -or $Rollback) { Enter-SuCoordinationLocks }
    if ($Status) { exit (Show-SuStatus) }
    if ($Rollback) { Assert-SuStableInvocation; exit (Invoke-SuRollback) }
    Assert-SuStableInvocation
    $pendingPath = Get-SuPendingPath
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
        $taskState = $null
        $taskState = Suspend-SuBackgroundTask
        Write-SuLine 'This will replace the updater scripts in the stable directory. The background task is paused during activation.'
        try {
            $result = Start-SuActivation -Manifest $manifest -Staging $staging -TaskState $taskState
        } catch {
            $activationError = $_.Exception.Message
            $recoveryErrors = New-Object Collections.ArrayList
            if ($null -ne $taskState -and $taskState.WasEnabled) {
                $pendingStillPresent = $false
                try { $pendingStillPresent = Test-Path -LiteralPath (Get-SuPendingPath) -PathType Leaf } catch { $pendingStillPresent = $true }
                if ($pendingStillPresent) {
                    try {
                        if (-not (Set-SuTaskEnabled -Enabled $true)) { throw 'The background task disappeared before it could be re-enabled.' }
                        $after = Get-SuTask
                        if ($null -eq $after -or [string]$after.State -eq 'Disabled') { throw 'The background task did not return to the enabled state.' }
                    } catch { [void]$recoveryErrors.Add('task: ' + $_.Exception.Message) }
                }
            }
            if ($recoveryErrors.Count -gt 0) {
                try { Write-SuJson -Path $script:SuResultPath -Value ([ordered]@{ Status = 'RecoveryRequired'; Error = $activationError; RecoveryErrors = @($recoveryErrors) }) } catch { }
                Stop-Su 1 ('Self-update activation failed and recovery is required: ' + (($recoveryErrors -join '; ')))
            }
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
    if ($null -ne $script:SuUpdateLockStream) { $script:SuUpdateLockStream.Dispose() }
}
