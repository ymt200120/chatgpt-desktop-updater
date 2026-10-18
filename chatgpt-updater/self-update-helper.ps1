#requires -Version 5.1
<##
    Detached activation helper for the updater's own files.

    The helper accepts both the v0.2.0.1 schema-1 plan emitted by the released
    parent and the transaction-aware schema-2 plan emitted by newer parents.
    It never downloads code, installs an AppX package, or deletes a lock path.
##>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PlanPath,
    [switch]$Recover
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SuPlan = $null
$script:SuPlanOriginalSchema = 0
$script:SuPlanPath = $null
$script:SuHelperLogPath = $null
$script:SuLockStream = $null
$script:SuOrdinaryLockStream = $null
$script:SuTransactionId = $null
$script:SuTestMode = $false
$script:SuPendingOwned = $false
$script:SuBackupManifest = $null
$script:SuRecoveryReady = $false
$script:SuActivationStarted = $false
$script:SuCompleted = New-Object Collections.ArrayList
$script:SuRecoveryMode = [bool]$Recover

function Write-SuHelperLog {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($script:SuHelperLogPath)) { return }
    try {
        $line = ('{0} {1}' -f ([DateTime]::UtcNow.ToString('o')), $Message)
        [IO.File]::AppendAllText($script:SuHelperLogPath, $line + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

function Get-SuHelperProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-SuHelperUtcText { return ([DateTime]::UtcNow.ToString('o')) }

function Write-SuHelperJson {
    param([string]$Path, $Value)
    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop
    }
    $text = $Value | ConvertTo-Json -Depth 12 -Compress
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

function Get-SuHelperBoundary {
    param([string]$Path)
    if (-not $script:SuTestMode -and -not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $local = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\')
        $stable = Join-Path $local 'Programs\ChatGPTUpdater'
        $state = Join-Path $local 'ChatGPTUpdater'
        $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
        if ($full -eq $stable -or $full.StartsWith(($stable + '\'), [StringComparison]::OrdinalIgnoreCase)) { return $local }
        if ($full -eq $state -or $full.StartsWith(($state + '\'), [StringComparison]::OrdinalIgnoreCase)) { return $local }
        return $local
    }
    return [IO.Path]::GetPathRoot(([IO.Path]::GetFullPath($Path))).TrimEnd('\')
}

function Assert-SuHelperNoReparseAncestors {
    param([string]$Path, [string]$Boundary)
    $full = ([IO.Path]::GetFullPath($Path)).TrimEnd('\')
    $boundaryFull = ([IO.Path]::GetFullPath($Boundary)).TrimEnd('\')
    if (-not $script:SuTestMode -and $full -ne $boundaryFull -and -not $full.StartsWith(($boundaryFull + '\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Self-update path is outside the managed updater directory.'
    }
    $probe = $full
    while (-not (Test-Path -LiteralPath $probe)) {
        $parent = [IO.Directory]::GetParent($probe)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $probe) { break }
        $probe = $parent
    }
    while (-not [string]::IsNullOrWhiteSpace($probe)) {
        $item = Get-Item -LiteralPath $probe -Force -ErrorAction Stop
        if ($probe -ine $boundaryFull -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw ('Refusing a reparse-point ancestor in the self-update path: ' + $probe) }
        if ($probe -ieq $boundaryFull) { break }
        $parent = if ($item.PSIsContainer) { $item.Parent } else { $item.Directory }
        if ($null -eq $parent) { break }
        $probe = $parent.FullName
    }
}

function Assert-SuHelperOwnedPath {
    param([string]$Path, [switch]$AllowMissingLeaf)
    $full = ([IO.Path]::GetFullPath($Path)).TrimEnd('\')
    Assert-SuHelperNoReparseAncestors -Path $full -Boundary (Get-SuHelperBoundary -Path $full)
    if (-not $AllowMissingLeaf -and (Test-Path -LiteralPath $full)) {
        $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw ('Refusing a reparse-point self-update path: ' + $full) }
    }
    return $full
}

function Assert-SuHelperSafeName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 96 -or $Name -notmatch '^[A-Za-z0-9._-]+$' -or $Name -match '\.\.' -or $Name -match '^[.]' -or $Name -match '[.]$') { throw 'Self-update plan contains an unsafe file name.' }
    return $Name
}

function Get-SuHelperChildPath {
    param([string]$Root, [string]$Name)
    $null = Assert-SuHelperSafeName $Name
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $child = [IO.Path]::GetFullPath((Join-Path $rootFull $Name))
    if (-not $child.StartsWith(($rootFull + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Self-update path escapes its root.' }
    return $child
}

function Assert-SuHelperRegularFile {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw ('Refusing a non-regular or reparse-point self-update path: ' + $Path) }
    $null = Assert-SuHelperNoReparseAncestors -Path $Path -Boundary (Get-SuHelperBoundary -Path $Path)
    return $item
}

function Assert-SuHelperDirectory {
    param([string]$Path)
    $full = Assert-SuHelperOwnedPath -Path $Path -AllowMissingLeaf
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { $null = New-Item -ItemType Directory -Path $full -Force -ErrorAction Stop }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw ('Self-update directory is a reparse point: ' + $full) }
    return $item
}

function Get-SuHelperSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
}

function Test-SuHelperTaskNotFoundError {
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

function Get-SuHelperTask {
    try { return (Get-ScheduledTask -TaskName ([string](Get-SuHelperProperty $script:SuPlan 'TaskName')) -ErrorAction Stop) }
    catch {
        if (Test-SuHelperTaskNotFoundError $_) { return $null }
        throw ('Unable to query the updater background task: ' + $_.Exception.Message)
    }
}

function Test-SuHelperTaskOwned {
    param($Task)
    if ($null -eq $Task) { return $false }
    if ([string]$Task.Description -ne [string](Get-SuHelperProperty $script:SuPlan 'TaskMarker')) { return $false }
    $principal = $Task.Principal
    if ($null -eq $principal -or [string]::IsNullOrWhiteSpace([string]$principal.UserId)) { return $false }
    try {
        $userId = [string]$principal.UserId
        if ($userId -match '^S-') { $taskSid = (New-Object Security.Principal.SecurityIdentifier -ArgumentList @($userId)).Value }
        else { $taskSid = (New-Object Security.Principal.NTAccount -ArgumentList @($userId)).Translate([Security.Principal.SecurityIdentifier]).Value }
        return ($taskSid -eq ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value)
    } catch { return $false }
}

function Set-SuHelperTaskEnabled {
    param([bool]$Enabled)
    $task = Get-SuHelperTask
    if ($null -eq $task) { return $false }
    if (-not (Test-SuHelperTaskOwned $task)) { throw 'The scheduled task is not owned by this updater.' }
    if ($Enabled) { Enable-ScheduledTask -TaskName ([string](Get-SuHelperProperty $script:SuPlan 'TaskName')) -ErrorAction Stop | Out-Null }
    else { Disable-ScheduledTask -TaskName ([string](Get-SuHelperProperty $script:SuPlan 'TaskName')) -ErrorAction Stop | Out-Null }
    return $true
}

function Set-SuHelperTaskFinalState {
    param([bool]$Enabled, [bool]$Existed)
    if ($script:SuTestMode) { return }
    $task = Get-SuHelperTask
    if ($null -eq $task) {
        if ($Existed -or $Enabled) { throw 'The updater background task disappeared during self-update recovery.' }
        return
    }
    if (-not (Test-SuHelperTaskOwned $task)) { throw 'The background task is not owned by this updater.' }
    if ($Enabled) {
        if (-not (Set-SuHelperTaskEnabled -Enabled $true)) { throw 'The background task could not be re-enabled.' }
    }
    $after = Get-SuHelperTask
    if ($null -eq $after) { throw 'The updater background task disappeared after self-update recovery.' }
    $isEnabled = ([string]$after.State -ne 'Disabled')
    if ($isEnabled -ne $Enabled) { throw ('The updater background task did not reach the requested state: enabled=' + $Enabled) }
}

function Test-SuHelperTaskQuiescent {
    if ($script:SuTestMode) { return }
    $task = Get-SuHelperTask
    if ($null -eq $task) {
        if ([bool](Get-SuHelperProperty $script:SuPlan 'TaskExisted') -or [bool](Get-SuHelperProperty $script:SuPlan 'TaskWasEnabled')) { throw 'The updater background task disappeared before activation.' }
    } else {
        if (-not (Test-SuHelperTaskOwned $task)) { throw 'The background task is not owned by this updater.' }
        if ([string]$task.State -eq 'Running') { throw 'The background task is still running; activation was not started.' }
    }
    $promptLock = Join-Path $env:LOCALAPPDATA 'ChatGPTUpdater\background-prompt.lock'
    if (Test-Path -LiteralPath $promptLock -PathType Leaf) {
        $stream = $null
        try { $stream = [IO.File]::Open($promptLock, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch { throw 'A confirmation window is active; activation was not started.' }
        finally { if ($null -ne $stream) { $stream.Dispose() } }
    }
}

function Suspend-SuHelperTask {
    if ($script:SuTestMode) { return [pscustomobject]@{ Existed = $false; WasEnabled = $false } }
    $task = Get-SuHelperTask
    if ($null -eq $task) {
        if ([bool](Get-SuHelperProperty $script:SuPlan 'TaskExisted') -or [bool](Get-SuHelperProperty $script:SuPlan 'TaskWasEnabled')) { throw 'The updater background task disappeared before recovery.' }
        return [pscustomobject]@{ Existed = $false; WasEnabled = $false }
    }
    if (-not (Test-SuHelperTaskOwned $task)) { throw 'The background task is not owned by this updater.' }
    $wasEnabled = ([string]$task.State -ne 'Disabled')
    $disableAttempted = $false
    try {
        if ($wasEnabled) {
            $disableAttempted = $true
            Disable-ScheduledTask -TaskName ([string](Get-SuHelperProperty $script:SuPlan 'TaskName')) -ErrorAction Stop | Out-Null
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while ($true) {
            $current = Get-SuHelperTask
            if ($null -eq $current -or [string]$current.State -ne 'Running') { break }
            if ([DateTime]::UtcNow -ge $deadline) { throw 'The background task is still running; recovery was not started.' }
            Start-Sleep -Milliseconds 500
        }
        $promptLock = Join-Path $env:LOCALAPPDATA 'ChatGPTUpdater\background-prompt.lock'
        if (Test-Path -LiteralPath $promptLock -PathType Leaf) {
            $stream = $null
            try { $stream = [IO.File]::Open($promptLock, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
            catch { throw 'A confirmation window is active; recovery was not started.' }
            finally { if ($null -ne $stream) { $stream.Dispose() } }
        }
        return [pscustomobject]@{ Existed = $true; WasEnabled = $wasEnabled }
    } catch {
        $failure = $_.Exception.Message
        if ($wasEnabled -and $disableAttempted) {
            try { Set-SuHelperTaskFinalState -Enabled:$true -Existed:$true } catch { throw ('Recovery could not restore the background task after quiescence failed: ' + $_.Exception.Message) }
        }
        throw
    }
}

function Enter-SuHelperLock {
    param([string]$Path, [int]$TimeoutSeconds = 120)
    $full = Assert-SuHelperOwnedPath -Path $Path -AllowMissingLeaf
    $directory = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { $null = New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        try { return [IO.File]::Open($full, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch {
            if ([DateTime]::UtcNow -ge $deadline) { throw ('Timed out waiting for self-update lock: ' + $full) }
            Start-Sleep -Milliseconds 200
        }
    }
}

function Get-SuHelperPendingPath { return [IO.Path]::GetFullPath([string](Get-SuHelperProperty $script:SuPlan 'PendingPath')) }

function Read-SuHelperPending {
    $path = Get-SuHelperPendingPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $item = Assert-SuHelperRegularFile -Path $path
    if ($item.Length -gt 262144) { throw 'The self-update pending marker is too large.' }
    try { return ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw ('The self-update pending marker is invalid: ' + $_.Exception.Message) }
}

function Test-SuHelperPendingMatches {
    param($Pending)
    if ($null -eq $Pending) { return $false }
    $pendingSchema = [int](Get-SuHelperProperty $Pending 'Schema')
    $pendingId = [string](Get-SuHelperProperty $Pending 'TransactionId')
    $isSchema2 = ($script:SuPlanOriginalSchema -ge 2 -or $pendingSchema -ge 2 -or -not [string]::IsNullOrWhiteSpace($pendingId))
    if ($isSchema2) {
        if ([string]::IsNullOrWhiteSpace($pendingId) -or $pendingId -ne $script:SuTransactionId) { return $false }
    } elseif (-not [string]::IsNullOrWhiteSpace($pendingId)) {
        return $false
    }
    $fields = @('Version','StagingRoot','BackupRoot','ResultPath')
    if ($isSchema2) { $fields += @('PendingPath','OrdinaryLockPath','PlanPath') }
    foreach ($field in $fields) {
        $left = [string](Get-SuHelperProperty $Pending $field)
        $right = [string](Get-SuHelperProperty $script:SuPlan $field)
        if ([string]::IsNullOrWhiteSpace($left) -or [string]::IsNullOrWhiteSpace($right)) { return $false }
        if ($field -match 'Path$' -or $field -in @('StagingRoot','BackupRoot','ResultPath','PendingPath','OrdinaryLockPath')) {
            try {
                if (([IO.Path]::GetFullPath($left)).TrimEnd('\') -ine ([IO.Path]::GetFullPath($right)).TrimEnd('\')) { return $false }
            } catch { return $false }
        } elseif ($left -ine $right) { return $false }
    }
    if (-not $isSchema2) {
        $explicitPlan = [string](Get-SuHelperProperty $Pending 'PlanPath')
        if (-not [string]::IsNullOrWhiteSpace($explicitPlan)) {
            try { if (([IO.Path]::GetFullPath($explicitPlan)).TrimEnd('\') -ine $script:SuPlanPath.TrimEnd('\')) { return $false } }
            catch { return $false }
        }
    }
    return $true
}

function Test-SuHelperPendingActivatable {
    param($Pending)
    if ($null -eq $Pending -or -not (Test-SuHelperPendingMatches $Pending)) { return $false }
    $status = [string](Get-SuHelperProperty $Pending 'Status')
    return ([string]::IsNullOrWhiteSpace($status) -or $status -eq 'Pending')
}

function Write-SuHelperPlanState {
    param([string]$Status, [string]$ErrorMessage = $null)
    $script:SuPlan | Add-Member -NotePropertyName Status -NotePropertyValue $Status -Force
    $script:SuPlan | Add-Member -NotePropertyName UpdatedUtc -NotePropertyValue (ConvertTo-SuHelperUtcText) -Force
    $script:SuPlan | Add-Member -NotePropertyName CompletedFiles -NotePropertyValue @($script:SuCompleted) -Force
    if ($null -ne $ErrorMessage) { $script:SuPlan | Add-Member -NotePropertyName Error -NotePropertyValue $ErrorMessage -Force }
    Write-SuHelperJson -Path $script:SuPlanPath -Value $script:SuPlan
}

function Test-SuHelperResultOwner {
    if ($null -eq $script:SuPlan -or [string]::IsNullOrWhiteSpace($script:SuTransactionId)) { return $false }
    try {
        $pending = Read-SuHelperPending
        if ($null -ne $pending) { return (Test-SuHelperPendingMatches $pending) }
    } catch { return $false }
    # The previous activation normally left a different transaction's result.
    # Once this process owned the exact pending marker under both locks, it
    # may publish its terminal result after clearing that marker. A late helper
    # that never owned the marker has no such right, even for the same plan ID.
    return [bool]$script:SuPendingOwned
}

function Write-SuHelperResult {
    param([string]$Status, [string]$ErrorMessage = $null, [string[]]$RecoveryErrors = @(), [string]$ResultVersion = $null)
    if (-not (Test-SuHelperResultOwner)) { throw 'The self-update result belongs to another transaction.' }
    if ([string]::IsNullOrWhiteSpace($ResultVersion)) { $ResultVersion = [string](Get-SuHelperProperty $script:SuPlan 'Version') }
    $value = [ordered]@{
        Status = $Status
        TransactionId = $script:SuTransactionId
        Version = $ResultVersion
        CompletedUtc = ConvertTo-SuHelperUtcText
        BackupRoot = [string](Get-SuHelperProperty $script:SuPlan 'BackupRoot')
        Error = $ErrorMessage
        RecoveryErrors = @($RecoveryErrors)
    }
    Write-SuHelperJson -Path ([string](Get-SuHelperProperty $script:SuPlan 'ResultPath')) -Value $value
}

function Write-SuHelperPendingStatus {
    param($Pending, [string]$Status, [string]$Reason = $null)
    $copy = $Pending | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $copy | Add-Member -NotePropertyName Schema -NotePropertyValue 2 -Force
    $copy | Add-Member -NotePropertyName TransactionId -NotePropertyValue $script:SuTransactionId -Force
    $copy | Add-Member -NotePropertyName PlanPath -NotePropertyValue $script:SuPlanPath -Force
    $copy | Add-Member -NotePropertyName PendingPath -NotePropertyValue ([string](Get-SuHelperProperty $script:SuPlan 'PendingPath')) -Force
    $copy | Add-Member -NotePropertyName OrdinaryLockPath -NotePropertyValue ([string](Get-SuHelperProperty $script:SuPlan 'OrdinaryLockPath')) -Force
    $copy | Add-Member -NotePropertyName Status -NotePropertyValue $Status -Force
    $copy | Add-Member -NotePropertyName UpdatedUtc -NotePropertyValue (ConvertTo-SuHelperUtcText) -Force
    if ($null -ne $Reason) { $copy | Add-Member -NotePropertyName Reason -NotePropertyValue $Reason -Force }
    Write-SuHelperJson -Path (Get-SuHelperPendingPath) -Value $copy
    return $copy
}

function Remove-SuHelperPendingExact {
    param([switch]$RequirePresent)
    $path = Get-SuHelperPendingPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        if ($RequirePresent) { throw 'The self-update pending marker is missing during activation.' }
        return
    }
    $pending = Read-SuHelperPending
    if ($null -eq $pending -or -not (Test-SuHelperPendingMatches $pending)) { throw 'The self-update pending marker belongs to another transaction.' }
    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $path) { throw 'The self-update pending marker could not be removed.' }
}

function Get-SuHelperLegacyTransactionId {
    param([string]$Path, [string]$Version, [string]$Staging, [string]$Backup)
    $text = $Path + '|' + $Version + '|' + $Staging + '|' + $Backup
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return 'legacy-' + (($hash.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $hash.Dispose() }
}

function Prepare-SuHelperPlan {
    $script:SuPlanPath = Assert-SuHelperOwnedPath -Path $PlanPath
    if ((Get-Item -LiteralPath $script:SuPlanPath).Length -gt 262144) { throw 'Self-update plan file is too large.' }
    try { $script:SuPlan = [IO.File]::ReadAllText($script:SuPlanPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop } catch { throw ('Self-update plan is invalid: ' + $_.Exception.Message) }
    $schema = [int](Get-SuHelperProperty $script:SuPlan 'Schema')
    if ($schema -ne 1 -and $schema -ne 2) { throw 'Unsupported self-update plan schema.' }
    $script:SuPlanOriginalSchema = $schema
    $script:SuTestMode = [bool](Get-SuHelperProperty $script:SuPlan 'TestMode')
    $script:SuHelperLogPath = [string](Get-SuHelperProperty $script:SuPlan 'LogPath')
    $version = [string](Get-SuHelperProperty $script:SuPlan 'Version')
    $stable = [IO.Path]::GetFullPath([string](Get-SuHelperProperty $script:SuPlan 'StableRoot')).TrimEnd('\')
    $staging = [IO.Path]::GetFullPath([string](Get-SuHelperProperty $script:SuPlan 'StagingRoot')).TrimEnd('\')
    $backup = [IO.Path]::GetFullPath([string](Get-SuHelperProperty $script:SuPlan 'BackupRoot')).TrimEnd('\')
    $pending = [IO.Path]::GetFullPath([string](Get-SuHelperProperty $script:SuPlan 'PendingPath'))
    $result = [IO.Path]::GetFullPath([string](Get-SuHelperProperty $script:SuPlan 'ResultPath'))
    $lock = [IO.Path]::GetFullPath([string](Get-SuHelperProperty $script:SuPlan 'LockPath'))
    if (-not $script:SuTestMode) {
        $expected = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs\ChatGPTUpdater')).TrimEnd('\')
        if ($stable -ine $expected) { throw 'Self-update plan targets an unexpected stable root.' }
    }
    $script:SuPlan | Add-Member -NotePropertyName StableRoot -NotePropertyValue $stable -Force
    $script:SuPlan | Add-Member -NotePropertyName StagingRoot -NotePropertyValue $staging -Force
    $script:SuPlan | Add-Member -NotePropertyName BackupRoot -NotePropertyValue $backup -Force
    $script:SuPlan | Add-Member -NotePropertyName PendingPath -NotePropertyValue $pending -Force
    $script:SuPlan | Add-Member -NotePropertyName ResultPath -NotePropertyValue $result -Force
    $script:SuPlan | Add-Member -NotePropertyName LockPath -NotePropertyValue $lock -Force
    $script:SuPlan | Add-Member -NotePropertyName PlanPath -NotePropertyValue $script:SuPlanPath -Force
    $ordinary = [string](Get-SuHelperProperty $script:SuPlan 'OrdinaryLockPath')
    if ([string]::IsNullOrWhiteSpace($ordinary)) { $ordinary = Join-Path $env:LOCALAPPDATA 'ChatGPTUpdater\update.lock' }
    $ordinary = [IO.Path]::GetFullPath($ordinary)
    $script:SuPlan | Add-Member -NotePropertyName OrdinaryLockPath -NotePropertyValue $ordinary -Force
    $script:SuPlan | Add-Member -NotePropertyName TaskExisted -NotePropertyValue ([bool](Get-SuHelperProperty $script:SuPlan 'TaskExisted')) -Force
    $script:SuPlan | Add-Member -NotePropertyName TaskWasEnabled -NotePropertyValue ([bool](Get-SuHelperProperty $script:SuPlan 'TaskWasEnabled')) -Force
    $existingId = [string](Get-SuHelperProperty $script:SuPlan 'TransactionId')
    if ([string]::IsNullOrWhiteSpace($existingId)) { $existingId = Get-SuHelperLegacyTransactionId -Path $script:SuPlanPath -Version $version -Staging $staging -Backup $backup }
    $script:SuTransactionId = $existingId
    $script:SuPlan | Add-Member -NotePropertyName TransactionId -NotePropertyValue $existingId -Force
    $script:SuPlan | Add-Member -NotePropertyName Schema -NotePropertyValue 2 -Force
    $null = Assert-SuHelperDirectory -Path $stable
    if (-not $script:SuRecoveryMode) { $null = Assert-SuHelperDirectory -Path $staging }
    if (-not (Test-Path -LiteralPath $backup -PathType Container)) { $null = New-Item -ItemType Directory -Path $backup -Force -ErrorAction Stop }
    $null = Assert-SuHelperDirectory -Path $backup
    $files = @(Get-SuHelperProperty $script:SuPlan 'Files')
    if ($files.Count -lt 1) { throw 'Self-update plan has no files.' }
    $seen = @{}
    foreach ($entry in $files) {
        $name = Assert-SuHelperSafeName ([string](Get-SuHelperProperty $entry 'Name'))
        $hash = [string](Get-SuHelperProperty $entry 'SHA256')
        if ($hash -notmatch '^[0-9A-Fa-f]{64}$' -or $seen.ContainsKey($name.ToLowerInvariant())) { throw ('Invalid or duplicate staged file: ' + $name) }
        $seen[$name.ToLowerInvariant()] = $true
        if (-not $script:SuRecoveryMode) {
            $staged = Get-SuHelperChildPath -Root $staging -Name $name
            $null = Assert-SuHelperRegularFile -Path $staged
            if ((Get-SuHelperSha256 -Path $staged) -ne $hash.ToUpperInvariant()) { throw ('Staged file hash changed for ' + $name) }
            if ($name -eq 'VERSION') {
                try { $stagedVersion = [version](([IO.File]::ReadAllText($staged, [Text.Encoding]::UTF8)).Trim()) } catch { throw 'Staged VERSION is invalid.' }
                if ($stagedVersion.ToString() -ne $version) { throw 'Staged VERSION does not match the plan version.' }
            }
            if ($name -like '*.ps1') {
                $tokens = $null; $errors = $null
                $null = [System.Management.Automation.Language.Parser]::ParseFile($staged, [ref]$tokens, [ref]$errors)
                if (@($errors).Count -gt 0) { throw ('Staged script has a parse error: ' + $name) }
            }
        }
    }
    if (-not $seen.ContainsKey('version')) { throw 'Self-update plan is missing VERSION.' }
    return $files
}

function Test-SuHelperPendingAndMigrate {
    $pending = Read-SuHelperPending
    if ($null -eq $pending) { return $false }
    if (-not (Test-SuHelperPendingActivatable $pending)) { return $false }
    $hasIdentity = -not [string]::IsNullOrWhiteSpace([string](Get-SuHelperProperty $pending 'TransactionId'))
    $hasPlan = -not [string]::IsNullOrWhiteSpace([string](Get-SuHelperProperty $pending 'PlanPath'))
    if (-not $hasIdentity -or -not $hasPlan) { $null = Write-SuHelperPendingStatus -Pending $pending -Status 'Pending' }
    $script:SuPendingOwned = $true
    return $true
}

function New-SuHelperBackup {
    param($Files, [version]$PlanVersion)
    $backupRoot = [string](Get-SuHelperProperty $script:SuPlan 'BackupRoot')
    $stable = [string](Get-SuHelperProperty $script:SuPlan 'StableRoot')
    $manifestPath = Get-SuHelperChildPath -Root $backupRoot -Name 'backup.json'
    $manifest = [ordered]@{
        Schema = 2
        TransactionId = $script:SuTransactionId
        Version = $null
        TargetVersion = $PlanVersion.ToString()
        StableRoot = $stable
        CreatedUtc = ConvertTo-SuHelperUtcText
        RecoveryReady = $false
        ActivationStarted = $false
        ActivationComplete = $false
        TaskExisted = [bool](Get-SuHelperProperty $script:SuPlan 'TaskExisted')
        TaskWasEnabled = [bool](Get-SuHelperProperty $script:SuPlan 'TaskWasEnabled')
        Files = @()
    }
    $versionPath = Get-SuHelperChildPath -Root $stable -Name 'VERSION'
    if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) { throw 'Stable VERSION is missing before activation.' }
    $null = Assert-SuHelperRegularFile -Path $versionPath
    try { $manifest.Version = ([version](([IO.File]::ReadAllText($versionPath, [Text.Encoding]::UTF8)).Trim())).ToString() } catch { throw 'Stable VERSION is invalid before activation.' }
    foreach ($entry in $Files) {
        $name = [string](Get-SuHelperProperty $entry 'Name')
        $target = Get-SuHelperChildPath -Root $stable -Name $name
        $activatedHash = [string](Get-SuHelperProperty $entry 'SHA256').ToUpperInvariant()
        $existed = Test-Path -LiteralPath $target -PathType Leaf
        if ($existed) {
            $null = Assert-SuHelperRegularFile -Path $target
            $backupFinal = Get-SuHelperChildPath -Root $backupRoot -Name $name
            $backupTemp = $backupFinal + '.prepare-' + [guid]::NewGuid().ToString('N') + '.tmp'
            try {
                Copy-Item -LiteralPath $target -Destination $backupTemp -Force -ErrorAction Stop
                $null = Assert-SuHelperRegularFile -Path $backupTemp
                $originalHash = Get-SuHelperSha256 -Path $target
                if ((Get-SuHelperSha256 -Path $backupTemp) -ne $originalHash) { throw ('Backup verification failed for ' + $name) }
                Move-Item -LiteralPath $backupTemp -Destination $backupFinal -Force -ErrorAction Stop
            } finally { if (Test-Path -LiteralPath $backupTemp -PathType Leaf) { Remove-Item -LiteralPath $backupTemp -Force -ErrorAction SilentlyContinue } }
            $manifest.Files += [ordered]@{ Name = $name; Existed = $true; OriginalSHA256 = $originalHash; ActivatedSHA256 = $activatedHash }
        } else {
            $manifest.Files += [ordered]@{ Name = $name; Existed = $false; OriginalSHA256 = $null; ActivatedSHA256 = $activatedHash }
        }
    }
    Write-SuHelperJson -Path $manifestPath -Value $manifest
    foreach ($entry in @($manifest.Files)) {
        if ([bool](Get-SuHelperProperty $entry 'Existed')) {
            $backupFile = Get-SuHelperChildPath -Root $backupRoot -Name ([string](Get-SuHelperProperty $entry 'Name'))
            $null = Assert-SuHelperRegularFile -Path $backupFile
            if ((Get-SuHelperSha256 -Path $backupFile) -ne ([string](Get-SuHelperProperty $entry 'OriginalSHA256')).ToUpperInvariant()) { throw ('Backup verification failed for ' + [string](Get-SuHelperProperty $entry 'Name')) }
        }
    }
    $manifest.RecoveryReady = $true
    $manifest.RecoveryReadyUtc = ConvertTo-SuHelperUtcText
    # Publish the seal before atomically committing RecoveryReady=true.  A
    # crash before that commit leaves a not-ready record and unchanged stable
    # files; after it, the immutable record and its seal already agree.
    $preparedPath = Get-SuHelperChildPath -Root $backupRoot -Name 'recovery-record.prepared.json'
    try {
        Write-SuHelperJson -Path $preparedPath -Value $manifest
        $ready = [ordered]@{ Schema = 1; TransactionId = $script:SuTransactionId; BackupManifestSHA256 = Get-SuHelperSha256 -Path $preparedPath; Ready = $true; CreatedUtc = ConvertTo-SuHelperUtcText }
        Write-SuHelperJson -Path (Get-SuHelperChildPath -Root $backupRoot -Name 'recovery-ready.json') -Value $ready
        [IO.File]::Replace($preparedPath, $manifestPath, [NullString]::Value, $true)
    } finally {
        if (Test-Path -LiteralPath $preparedPath -PathType Leaf) { Remove-Item -LiteralPath $preparedPath -Force -ErrorAction SilentlyContinue }
    }
    $script:SuBackupManifest = $manifest
    $script:SuRecoveryReady = $true
    return $manifest
}

function Set-SuHelperBackupState {
    param([bool]$ActivationStarted = $false, [bool]$ActivationComplete = $false, [string]$InProgressFile = $null)
    # Progress is deliberately separate from the sealed recovery record.
    # Rewriting the record and then its seal would introduce a two-write crash
    # window precisely when the stable directory may already be mixed.
    $progress = [ordered]@{
        Schema = 1
        TransactionId = $script:SuTransactionId
        ActivationStarted = $ActivationStarted
        ActivationComplete = $ActivationComplete
        InProgressFile = $InProgressFile
        CompletedFiles = @($script:SuCompleted)
        UpdatedUtc = ConvertTo-SuHelperUtcText
    }
    $path = Get-SuHelperChildPath -Root ([string](Get-SuHelperProperty $script:SuPlan 'BackupRoot')) -Name 'activation-progress.json'
    Write-SuHelperJson -Path $path -Value $progress
}

function Get-SuHelperRecoveryRecord {
    $backupRoot = [string](Get-SuHelperProperty $script:SuPlan 'BackupRoot')
    $manifestPath = Get-SuHelperChildPath -Root $backupRoot -Name 'backup.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'The self-update recovery manifest is missing.' }
    try { $manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop } catch { throw 'The self-update recovery manifest is invalid.' }
    if ([int](Get-SuHelperProperty $manifest 'Schema') -ne 2 -or -not [bool](Get-SuHelperProperty $manifest 'RecoveryReady')) { throw 'The self-update recovery manifest is not recovery-ready.' }
    if ([string](Get-SuHelperProperty $manifest 'TransactionId') -ne $script:SuTransactionId) { throw 'The self-update recovery manifest belongs to another transaction.' }
    $manifestStable = [string](Get-SuHelperProperty $manifest 'StableRoot')
    $planStable = [string](Get-SuHelperProperty $script:SuPlan 'StableRoot')
    if ([string]::IsNullOrWhiteSpace($manifestStable) -or ([IO.Path]::GetFullPath($manifestStable)).TrimEnd('\') -ine ([IO.Path]::GetFullPath($planStable)).TrimEnd('\')) { throw 'The self-update recovery manifest targets another stable directory.' }
    $readyPath = Get-SuHelperChildPath -Root $backupRoot -Name 'recovery-ready.json'
    if (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) { throw 'The self-update recovery-ready marker is missing.' }
    try { $ready = [IO.File]::ReadAllText($readyPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop } catch { throw 'The self-update recovery-ready marker is invalid.' }
    if (-not [bool](Get-SuHelperProperty $ready 'Ready') -or [string](Get-SuHelperProperty $ready 'TransactionId') -ne $script:SuTransactionId -or [string](Get-SuHelperProperty $ready 'BackupManifestSHA256') -ne (Get-SuHelperSha256 -Path $manifestPath)) { throw 'The self-update recovery-ready marker does not match the backup.' }
    $files = @(Get-SuHelperProperty $manifest 'Files')
    if ($files.Count -lt 1 -or $files.Count -gt 64) { throw 'The self-update recovery manifest has an invalid file count.' }
    $seen = @{}
    foreach ($entry in $files) {
        $name = [string](Get-SuHelperProperty $entry 'Name')
        $null = Assert-SuHelperSafeName $name
        if ($seen.ContainsKey($name.ToLowerInvariant())) { throw 'The self-update recovery manifest contains a duplicate file.' }
        $seen[$name.ToLowerInvariant()] = $true
        $existed = [bool](Get-SuHelperProperty $entry 'Existed')
        $originalHash = [string](Get-SuHelperProperty $entry 'OriginalSHA256')
        $activatedHash = [string](Get-SuHelperProperty $entry 'ActivatedSHA256')
        if ($originalHash -notmatch '^[0-9A-Fa-f]{64}$' -and $existed) { throw ('The recovery backup lacks an integrity hash for ' + $name) }
        if ($activatedHash -notmatch '^[0-9A-Fa-f]{64}$') { throw ('The recovery record lacks an activation hash for ' + $name) }
        $backupFile = Get-SuHelperChildPath -Root $backupRoot -Name $name
        if ($existed) {
            $null = Assert-SuHelperRegularFile -Path $backupFile
            if ((Get-SuHelperSha256 -Path $backupFile) -ne $originalHash.ToUpperInvariant()) { throw ('The recovery backup is corrupt: ' + $name) }
        } elseif (Test-Path -LiteralPath $backupFile) { throw ('The recovery record unexpectedly contains a missing target backup: ' + $name) }
    }
    if (-not $seen.ContainsKey('version')) { throw 'The self-update recovery manifest has no VERSION backup.' }
    try {
        $recordedVersion = [version]([IO.File]::ReadAllText((Get-SuHelperChildPath -Root $backupRoot -Name 'VERSION'), [Text.Encoding]::UTF8).Trim())
        $manifestVersion = [version][string](Get-SuHelperProperty $manifest 'Version')
    } catch { throw 'The recovery VERSION backup is missing or invalid.' }
    if ($recordedVersion -ne $manifestVersion) { throw 'The recovery VERSION backup does not match its record.' }
    return $manifest
}

function Assert-SuHelperRecoveryOwnership {
    $pending = Read-SuHelperPending
    if ($null -ne $pending) {
        if (-not (Test-SuHelperPendingMatches $pending)) { throw 'The self-update pending marker belongs to another transaction; recovery was not started.' }
        return
    }
    $status = [string](Get-SuHelperProperty $script:SuPlan 'Status')
    if ($status -notmatch '^(?i:RecoveryRequired|RecoveryReady|Activating|CancelRequested|Rollback)$') {
        throw 'The self-update transaction has no matching pending marker or interrupted recovery status; recovery was not started.'
    }
    $resultPath = [string](Get-SuHelperProperty $script:SuPlan 'ResultPath')
    if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
        try {
            $result = [IO.File]::ReadAllText($resultPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
            $resultId = [string](Get-SuHelperProperty $result 'TransactionId')
            if (-not [string]::IsNullOrWhiteSpace($resultId) -and $resultId -ne $script:SuTransactionId) { throw 'The self-update result belongs to another transaction; recovery was not started.' }
        } catch { throw $_ }
    }
    $null = Write-SuHelperPendingStatus -Pending $script:SuPlan -Status 'Rollback' -Reason 'Independent recovery requested.'
}

function Restore-SuHelperFileAtomic {
    param([string]$Source, [string]$Target, [string]$SHA256)
    $temporary = $Target + '.restore-' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        Copy-Item -LiteralPath $Source -Destination $temporary -ErrorAction Stop
        if ((Get-SuHelperSha256 -Path $temporary) -ne $SHA256.ToUpperInvariant()) { throw 'The prepared recovery file does not match its backup.' }
        if (Test-Path -LiteralPath $Target -PathType Leaf) { [IO.File]::Replace($temporary, $Target, [NullString]::Value, $true) }
        elseif (Test-Path -LiteralPath $Target) { throw 'The recovery target is not a regular file.' }
        else { [IO.File]::Move($temporary, $Target) }
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Set-SuHelperRecoveryGuard {
    if (-not $script:SuPendingOwned) { return }
    $pending = Read-SuHelperPending
    if ($null -ne $pending -and -not (Test-SuHelperPendingMatches $pending)) { throw 'Another transaction owns the recovery marker.' }
    if ($null -eq $pending) { $pending = $script:SuPlan }
    $null = Write-SuHelperPendingStatus -Pending $pending -Status 'RecoveryRequired'
}

function Invoke-SuHelperRecovery {
    Assert-SuHelperRecoveryOwnership
    $script:SuPendingOwned = $true
    $manifest = Get-SuHelperRecoveryRecord
    $script:SuRecoveryReady = $true
    $stable = [string](Get-SuHelperProperty $script:SuPlan 'StableRoot')
    $null = Suspend-SuHelperTask
    $restoreError = $null
    try {
        try {
            foreach ($entry in @($manifest.Files)) {
                $name = [string](Get-SuHelperProperty $entry 'Name')
                $target = Get-SuHelperChildPath -Root $stable -Name $name
                if ([bool](Get-SuHelperProperty $entry 'Existed')) {
                    $backup = Get-SuHelperChildPath -Root ([string](Get-SuHelperProperty $script:SuPlan 'BackupRoot')) -Name $name
                    if (Test-Path -LiteralPath $target -PathType Leaf) {
                        $null = Assert-SuHelperRegularFile -Path $target
                        $currentHash = Get-SuHelperSha256 -Path $target
                        $originalHash = ([string](Get-SuHelperProperty $entry 'OriginalSHA256')).ToUpperInvariant()
                        $activatedHash = ([string](Get-SuHelperProperty $entry 'ActivatedSHA256')).ToUpperInvariant()
                        if ($currentHash -ne $activatedHash -and $currentHash -ne $originalHash) { throw ('Refusing to overwrite an unexpected target during recovery: ' + $name) }
                    } elseif (Test-Path -LiteralPath $target) { throw ('Refusing to replace a non-regular target during recovery: ' + $name) }
                    Restore-SuHelperFileAtomic -Source $backup -Target $target -SHA256 ([string](Get-SuHelperProperty $entry 'OriginalSHA256'))
                } elseif (Test-Path -LiteralPath $target) {
                    $null = Assert-SuHelperRegularFile -Path $target
                    if ((Get-SuHelperSha256 -Path $target) -ne ([string](Get-SuHelperProperty $entry 'ActivatedSHA256')).ToUpperInvariant()) { throw ('Refusing to delete an unexpected target during recovery: ' + $name) }
                    Remove-Item -LiteralPath $target -Force -ErrorAction Stop
                }
            }
        } catch { $restoreError = $_.Exception }
        try {
            Set-SuHelperTaskFinalState -Enabled:([bool](Get-SuHelperProperty $manifest 'TaskWasEnabled')) -Existed:([bool](Get-SuHelperProperty $manifest 'TaskExisted'))
        } catch {
            if ($null -eq $restoreError) { $restoreError = $_.Exception }
            else { $restoreError = New-Object Exception -ArgumentList @($restoreError.Message + '; task: ' + $_.Exception.Message) }
        }
        if ($null -ne $restoreError) { throw $restoreError }
    } finally {
        # The final-state call above is intentionally inside the guarded block;
        # a failed restore keeps the pending marker for a later recovery retry.
    }
    $pendingPath = Get-SuHelperPendingPath
    if (Test-Path -LiteralPath $pendingPath -PathType Leaf) { Remove-SuHelperPendingExact }
    Write-SuHelperPlanState -Status 'RolledBack'
    $staging = [string](Get-SuHelperProperty $script:SuPlan 'StagingRoot')
    if (Test-Path -LiteralPath $staging -PathType Container) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Stop }
    Write-SuHelperResult -Status 'RolledBack' -ResultVersion ([string](Get-SuHelperProperty $manifest 'Version')) -ErrorMessage 'Independent recovery restored the recovery-ready backup.'
}

function Invoke-SuHelperActivation {
    param($Files, [version]$PlanVersion)
    Test-SuHelperTaskQuiescent
    $pending = Read-SuHelperPending
    if ($null -eq $pending -or -not (Test-SuHelperPendingActivatable $pending)) { throw 'The self-update transaction was cancelled or replaced before activation.' }
    $null = New-SuHelperBackup -Files $Files -PlanVersion $PlanVersion
    Write-SuHelperPlanState -Status 'RecoveryReady'
    $script:SuActivationStarted = $true
    Set-SuHelperBackupState -ActivationStarted:$true
    foreach ($entry in $Files) {
        $name = [string](Get-SuHelperProperty $entry 'Name')
        $script:SuPlan | Add-Member -NotePropertyName InProgressFile -NotePropertyValue $name -Force
        Write-SuHelperPlanState -Status 'Activating'
        $backupEntry = @($script:SuBackupManifest.Files | Where-Object { [string]$_['Name'] -eq $name })[0]
        if ($null -eq $backupEntry) { throw ('The recovery record is missing activation state for ' + $name) }
        Set-SuHelperBackupState -ActivationStarted:$true -InProgressFile $name
        $staged = Get-SuHelperChildPath -Root ([string](Get-SuHelperProperty $script:SuPlan 'StagingRoot')) -Name $name
        $target = Get-SuHelperChildPath -Root ([string](Get-SuHelperProperty $script:SuPlan 'StableRoot')) -Name $name
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            $null = Assert-SuHelperRegularFile -Path $target
            try { [IO.File]::Replace($staged, $target, [NullString]::Value, $true) }
            catch { Move-Item -LiteralPath $staged -Destination $target -Force -ErrorAction Stop }
        } elseif (Test-Path -LiteralPath $target) { throw ('Stable target is not a regular file: ' + $name) }
        else { Move-Item -LiteralPath $staged -Destination $target -Force -ErrorAction Stop }
        [void]$script:SuCompleted.Add($name)
        $script:SuPlan | Add-Member -NotePropertyName InProgressFile -NotePropertyValue $null -Force
        Write-SuHelperPlanState -Status 'Activating'
        Write-SuHelperLog ("Activated '{0}'." -f $name)
    }
    Set-SuHelperBackupState -ActivationStarted:$true -ActivationComplete:$true
    if ([bool](Get-SuHelperProperty $script:SuPlan 'TaskWasEnabled')) {
        if (-not (Set-SuHelperTaskEnabled -Enabled $true)) { throw 'The background task could not be re-enabled after activation.' }
        $after = Get-SuHelperTask
        if ($null -eq $after -or [string]$after.State -eq 'Disabled') { throw 'The background task did not reach the enabled state after activation.' }
    } else { Set-SuHelperTaskFinalState -Enabled:$false -Existed:([bool](Get-SuHelperProperty $script:SuPlan 'TaskExisted')) }
    Remove-SuHelperPendingExact -RequirePresent
    Write-SuHelperPlanState -Status 'Activated'
    Remove-Item -LiteralPath ([string](Get-SuHelperProperty $script:SuPlan 'StagingRoot')) -Recurse -Force -ErrorAction Stop
    Write-SuHelperResult -Status 'Activated'
}

$script:SuExitCode = 1
try {
    $files = Prepare-SuHelperPlan
    Write-SuHelperLog ('Loaded transaction ' + $script:SuTransactionId + '.')
    $parentPid = [int](Get-SuHelperProperty $script:SuPlan 'ParentPid')
    if ($parentPid -gt 0) {
        Write-SuHelperLog ("Waiting for parent process {0} to exit." -f $parentPid)
        $deadline = [DateTime]::UtcNow.AddSeconds(120)
        while ($null -ne (Get-Process -Id $parentPid -ErrorAction SilentlyContinue)) {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Parent updater process did not exit; activation was not started.' }
            Start-Sleep -Milliseconds 200
        }
    }
    $script:SuOrdinaryLockStream = Enter-SuHelperLock -Path ([string](Get-SuHelperProperty $script:SuPlan 'OrdinaryLockPath'))
    $script:SuLockStream = Enter-SuHelperLock -Path ([string](Get-SuHelperProperty $script:SuPlan 'LockPath'))
    if ($script:SuRecoveryMode) {
        Invoke-SuHelperRecovery
        $script:SuExitCode = 0
        exit 0
    }
    if (-not (Test-SuHelperPendingAndMigrate)) {
        Write-SuHelperLog 'The transaction was cancelled or replaced; activation and shared-result writes were skipped.'
        exit 0
    }
    Invoke-SuHelperActivation -Files $files -PlanVersion ([version][string](Get-SuHelperProperty $script:SuPlan 'Version'))
    Write-SuHelperLog ('Activation completed for version ' + [string](Get-SuHelperProperty $script:SuPlan 'Version') + '.')
    $script:SuExitCode = 0
} catch {
    $message = $_.Exception.Message
    Write-SuHelperLog ('Activation failed: ' + $message)
    $recoveryErrors = New-Object Collections.ArrayList
    if ($script:SuRecoveryMode) {
        try { Set-SuHelperRecoveryGuard } catch { [void]$recoveryErrors.Add('pending: ' + $_.Exception.Message) }
        try { Write-SuHelperPlanState -Status 'RecoveryRequired' -ErrorMessage $message } catch { [void]$recoveryErrors.Add('plan: ' + $_.Exception.Message) }
        if (Test-SuHelperResultOwner) {
            try { Write-SuHelperResult -Status 'RecoveryRequired' -ErrorMessage $message -RecoveryErrors @($recoveryErrors) } catch { [void]$recoveryErrors.Add('result: ' + $_.Exception.Message) }
        }
        $script:SuExitCode = 1
    } elseif ($script:SuActivationStarted -or $script:SuRecoveryReady) {
        try { Set-SuHelperRecoveryGuard } catch { [void]$recoveryErrors.Add('pending: ' + $_.Exception.Message) }
        try { Write-SuHelperPlanState -Status 'RecoveryRequired' -ErrorMessage $message } catch { [void]$recoveryErrors.Add('plan: ' + $_.Exception.Message) }
        if (Test-SuHelperResultOwner) {
            try { Write-SuHelperResult -Status 'RecoveryRequired' -ErrorMessage $message -RecoveryErrors @($recoveryErrors) } catch { [void]$recoveryErrors.Add('result: ' + $_.Exception.Message) }
        }
        $script:SuExitCode = 1
    } else {
        try {
            # Validation can fail before the normal lock handoff (for example
            # a staged hash mismatch). Cleanup still needs both locks and an
            # exact pending match before changing task or transaction state.
            if ($null -eq $script:SuOrdinaryLockStream) { $script:SuOrdinaryLockStream = Enter-SuHelperLock -Path ([string](Get-SuHelperProperty $script:SuPlan 'OrdinaryLockPath')) }
            if ($null -eq $script:SuLockStream) { $script:SuLockStream = Enter-SuHelperLock -Path ([string](Get-SuHelperProperty $script:SuPlan 'LockPath')) }
            $pending = Read-SuHelperPending
            $ownsPending = ($null -ne $pending -and (Test-SuHelperPendingMatches $pending))
            if ($ownsPending) {
                $script:SuPendingOwned = $true
                $status = [string](Get-SuHelperProperty $pending 'Status')
                try {
                    Set-SuHelperTaskFinalState -Enabled:([bool](Get-SuHelperProperty $script:SuPlan 'TaskWasEnabled')) -Existed:([bool](Get-SuHelperProperty $script:SuPlan 'TaskExisted'))
                } catch { [void]$recoveryErrors.Add('task: ' + $_.Exception.Message) }
                if ($recoveryErrors.Count -eq 0) {
                    try { Remove-SuHelperPendingExact } catch { [void]$recoveryErrors.Add('pending: ' + $_.Exception.Message) }
                }
                if ($recoveryErrors.Count -eq 0) {
                    $cancelled = ($status -match '^(?i:cancel)')
                    $terminalStatus = if ($cancelled) { 'Cancelled' } else { 'Failed' }
                    try { Write-SuHelperPlanState -Status $terminalStatus -ErrorMessage $message } catch { [void]$recoveryErrors.Add('plan: ' + $_.Exception.Message) }
                    if ($recoveryErrors.Count -eq 0 -and (Test-SuHelperResultOwner)) {
                        try { Write-SuHelperResult -Status $terminalStatus -ErrorMessage $message } catch { [void]$recoveryErrors.Add('result: ' + $_.Exception.Message) }
                    }
                    $script:SuExitCode = if ($recoveryErrors.Count -eq 0 -and $cancelled) { 0 } else { 1 }
                } else {
                    try { Write-SuHelperPendingStatus -Pending $pending -Status 'RecoveryRequired' -Reason $message } catch { [void]$recoveryErrors.Add('pending status: ' + $_.Exception.Message) }
                    try { Write-SuHelperPlanState -Status 'RecoveryRequired' -ErrorMessage $message } catch { [void]$recoveryErrors.Add('plan: ' + $_.Exception.Message) }
                    if (Test-SuHelperResultOwner) {
                        try { Write-SuHelperResult -Status 'RecoveryRequired' -ErrorMessage $message -RecoveryErrors @($recoveryErrors) } catch { [void]$recoveryErrors.Add('result: ' + $_.Exception.Message) }
                    }
                    $script:SuExitCode = 1
                }
            } else {
                # A stale helper may have loaded a plan whose pending marker was
                # replaced or removed.  It must not touch the task or shared result.
                try { Write-SuHelperPlanState -Status 'Cancelled' -ErrorMessage $message } catch { }
                $script:SuExitCode = 1
            }
        } catch {
            [void]$recoveryErrors.Add('cleanup: ' + $_.Exception.Message)
            try { Write-SuHelperPlanState -Status 'RecoveryRequired' -ErrorMessage $message } catch { }
            if (Test-SuHelperResultOwner) {
                try { Write-SuHelperResult -Status 'RecoveryRequired' -ErrorMessage $message -RecoveryErrors @($recoveryErrors) } catch { }
            }
            $script:SuExitCode = 1
        }
    }
} finally {
    if ($null -ne $script:SuLockStream) { $script:SuLockStream.Dispose() }
    if ($null -ne $script:SuOrdinaryLockStream) { $script:SuOrdinaryLockStream.Dispose() }
}
exit $script:SuExitCode
