#requires -Version 5.1
<##
    Detached activation helper for the updater's own files.

    This process is launched by self-update.ps1 from a temporary copy.  It waits
    for the parent updater process to exit, then replaces the staged production
    files, keeping a backup for recovery.  It never downloads code or installs
    an AppX package.  The plan file is written and hash-checked by the parent.
##>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PlanPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SuHelperLogPath = $null

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

function ConvertTo-SuHelperUtcText {
    return ([DateTime]::UtcNow.ToString('o'))
}

function Write-SuHelperJson {
    param([string]$Path, $Value)
    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { $null = New-Item -ItemType Directory -Path $directory -Force }
    }
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

function Assert-SuHelperSafeName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 96) { throw 'Self-update plan contains an invalid file name.' }
    if ($Name -notmatch '^[A-Za-z0-9._-]+$' -or $Name -match '\.\.' -or $Name -match '^[.]' -or $Name -match '[.]$') { throw 'Self-update plan contains an unsafe file name.' }
    return $Name
}

function Get-SuHelperChildPath {
    param([string]$Root, [string]$Name)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $child = [IO.Path]::GetFullPath((Join-Path $rootFull $Name))
    if (-not $child.StartsWith(($rootFull + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Self-update path escapes its root.' }
    return $child
}

function Assert-SuHelperRegularFile {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw "Refusing a non-regular or reparse-point self-update path: $Path" }
    return $item
}

function Assert-SuHelperDirectory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Self-update directory is missing: $Path" }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Self-update directory is a reparse point: $Path" }
    return $item
}

function Get-SuHelperSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
}

function Test-SuHelperTaskOwned {
    param($Task)
    if ($null -eq $Task) { return $false }
    if ([string]$Task.Description -ne [string]$script:SuPlan.TaskMarker) { return $false }
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
        $currentSid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
        return ($taskSid -eq $currentSid)
    } catch { return $false }
}

function Get-SuHelperTask {
    try { return (Get-ScheduledTask -TaskName ([string]$script:SuPlan.TaskName) -ErrorAction Stop) }
    catch { return $null }
}

function Set-SuHelperTaskEnabled {
    param([bool]$Enabled)
    $task = Get-SuHelperTask
    if ($null -eq $task) { return $false }
    if (-not (Test-SuHelperTaskOwned $task)) { throw 'The scheduled task is not owned by this updater.' }
    if ($Enabled) { Enable-ScheduledTask -TaskName ([string]$script:SuPlan.TaskName) -ErrorAction Stop | Out-Null }
    else { Disable-ScheduledTask -TaskName ([string]$script:SuPlan.TaskName) -ErrorAction Stop | Out-Null }
    return $true
}

function Remove-SuHelperPending {
    try {
        if (Test-Path -LiteralPath ([string]$script:SuPlan.PendingPath) -PathType Leaf) {
            Remove-Item -LiteralPath ([string]$script:SuPlan.PendingPath) -Force -ErrorAction Stop
        }
    } catch { Write-SuHelperLog ('Failed to remove pending marker: ' + $_.Exception.Message) }
}

function Restore-SuHelperBackup {
    param([string[]]$Completed)
    $failed = New-Object Collections.ArrayList
    $items = @($Completed)
    if ($items.Count -gt 0) { [array]::Reverse($items) }
    foreach ($name in $items) {
        try {
            $target = Get-SuHelperChildPath -Root ([string]$script:SuPlan.StableRoot) -Name $name
            $backup = Get-SuHelperChildPath -Root ([string]$script:SuPlan.BackupRoot) -Name $name
            if (Test-Path -LiteralPath $backup -PathType Leaf) {
                Copy-Item -LiteralPath $backup -Destination $target -Force -ErrorAction Stop
            } elseif (Test-Path -LiteralPath $target -PathType Leaf) {
                Remove-Item -LiteralPath $target -Force -ErrorAction Stop
            }
        } catch { [void]$failed.Add($name) }
    }
    return @($failed)
}

$script:SuPlan = $null
$lockStream = $null
$result = $null
$completed = New-Object Collections.ArrayList
try {
    $planPathFull = [IO.Path]::GetFullPath($PlanPath)
    if (-not (Test-Path -LiteralPath $planPathFull -PathType Leaf)) { throw 'Self-update plan file is missing.' }
    $planItem = Assert-SuHelperRegularFile -Path $planPathFull
    if ($planItem.Length -gt 262144) { throw 'Self-update plan file is too large.' }
    $script:SuPlan = [IO.File]::ReadAllText($planPathFull, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    $script:SuHelperLogPath = [string](Get-SuHelperProperty $script:SuPlan 'LogPath')
    if ([int](Get-SuHelperProperty $script:SuPlan 'Schema') -ne 1) { throw 'Unsupported self-update plan schema.' }
    $planVersion = [version][string](Get-SuHelperProperty $script:SuPlan 'Version')
    $stableRoot = [IO.Path]::GetFullPath([string](Get-SuHelperProperty $script:SuPlan 'StableRoot')).TrimEnd('\')
    $stagingRoot = [IO.Path]::GetFullPath([string](Get-SuHelperProperty $script:SuPlan 'StagingRoot')).TrimEnd('\')
    $backupRoot = [IO.Path]::GetFullPath([string](Get-SuHelperProperty $script:SuPlan 'BackupRoot')).TrimEnd('\')
    $pendingPath = [IO.Path]::GetFullPath([string](Get-SuHelperProperty $script:SuPlan 'PendingPath'))
    $resultPath = [IO.Path]::GetFullPath([string](Get-SuHelperProperty $script:SuPlan 'ResultPath'))
    $lockPath = [IO.Path]::GetFullPath([string](Get-SuHelperProperty $script:SuPlan 'LockPath'))
    $testMode = [bool](Get-SuHelperProperty $script:SuPlan 'TestMode')
    $expectedStable = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs\ChatGPTUpdater')).TrimEnd('\')
    if (-not $testMode -and $stableRoot -ine $expectedStable) { throw 'Self-update plan targets an unexpected stable root.' }
    $null = Assert-SuHelperDirectory -Path $stableRoot
    $null = Assert-SuHelperDirectory -Path $stagingRoot
    if (-not (Test-Path -LiteralPath $backupRoot -PathType Container)) { $null = New-Item -ItemType Directory -Path $backupRoot -Force }
    $null = Assert-SuHelperDirectory -Path $backupRoot
    $files = @(Get-SuHelperProperty $script:SuPlan 'Files')
    if ($files.Count -lt 1) { throw 'Self-update plan has no files.' }
    $seen = @{}
    foreach ($entry in $files) {
        $name = Assert-SuHelperSafeName ([string](Get-SuHelperProperty $entry 'Name'))
        $hash = [string](Get-SuHelperProperty $entry 'SHA256')
        if ($hash -notmatch '^[0-9A-Fa-f]{64}$') { throw "Invalid staged hash for '$name'." }
        if ($seen.ContainsKey($name.ToLowerInvariant())) { throw "Duplicate staged file '$name'." }
        $seen[$name.ToLowerInvariant()] = $true
        $staged = Get-SuHelperChildPath -Root $stagingRoot -Name $name
        $null = Assert-SuHelperRegularFile -Path $staged
        if ((Get-SuHelperSha256 -Path $staged) -ne $hash.ToUpperInvariant()) { throw "Staged file hash changed for '$name'." }
        if ($name -eq 'VERSION') {
            $stagedVersion = [version](([IO.File]::ReadAllText($staged, [Text.Encoding]::UTF8)).Trim())
            if ($stagedVersion -ne $planVersion) { throw 'Staged VERSION does not match the plan version.' }
        }
        if ($name -like '*.ps1') {
            $tokens = $null
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($staged, [ref]$tokens, [ref]$errors)
            if (@($errors).Count -gt 0) { throw "Staged script '$name' has a parse error." }
        }
    }
    if (-not $seen.ContainsKey('version')) { throw 'Self-update plan is missing VERSION.' }
    $parentPid = [int](Get-SuHelperProperty $script:SuPlan 'ParentPid')
    if ($parentPid -gt 0) {
        Write-SuHelperLog ("Waiting for parent process {0} to exit." -f $parentPid)
        $deadline = [DateTime]::UtcNow.AddSeconds(120)
        while ($null -ne (Get-Process -Id $parentPid -ErrorAction SilentlyContinue)) {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Parent updater process did not exit; activation was not started.' }
            Start-Sleep -Milliseconds 200
        }
    }
    if (Test-Path -LiteralPath $lockPath -PathType Leaf) { Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue }
    $lockDirectory = Split-Path -Parent $lockPath
    if (-not (Test-Path -LiteralPath $lockDirectory -PathType Container)) { $null = New-Item -ItemType Directory -Path $lockDirectory -Force }
    $lockStream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $backupManifest = [ordered]@{
        Schema = 1
        Version = $planVersion.ToString()
        CreatedUtc = ConvertTo-SuHelperUtcText
        Complete = $false
        TaskWasEnabled = [bool](Get-SuHelperProperty $script:SuPlan 'TaskWasEnabled')
        Files = @()
    }
    foreach ($entry in $files) {
        $name = [string](Get-SuHelperProperty $entry 'Name')
        $target = Get-SuHelperChildPath -Root $stableRoot -Name $name
        $existed = Test-Path -LiteralPath $target -PathType Leaf
        if ($existed) { $null = Assert-SuHelperRegularFile -Path $target }
        $backupManifest.Files += [ordered]@{ Name = $name; Existed = $existed }
    }
    Write-SuHelperJson -Path (Join-Path $backupRoot 'backup.json') -Value $backupManifest
    Write-SuHelperLog ('Activating updater version {0}.' -f $planVersion)
    foreach ($entry in $files) {
        $name = [string](Get-SuHelperProperty $entry 'Name')
        $staged = Get-SuHelperChildPath -Root $stagingRoot -Name $name
        $target = Get-SuHelperChildPath -Root $stableRoot -Name $name
        $backup = Get-SuHelperChildPath -Root $backupRoot -Name $name
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            $null = Assert-SuHelperRegularFile -Path $target
            [IO.File]::Replace($staged, $target, $backup, $true)
        } else {
            [IO.File]::Move($staged, $target)
        }
        [void]$completed.Add($name)
        Write-SuHelperLog ("Activated '{0}'." -f $name)
    }
    $backupManifest.Complete = $true
    Write-SuHelperJson -Path (Join-Path $backupRoot 'backup.json') -Value $backupManifest
    if ([bool](Get-SuHelperProperty $script:SuPlan 'TaskWasEnabled')) {
        try { $null = Set-SuHelperTaskEnabled -Enabled $true; Write-SuHelperLog 'Background task re-enabled.' }
        catch { Write-SuHelperLog ('Background task re-enable failed: ' + $_.Exception.Message) }
    }
    Remove-SuHelperPending
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
    $result = [ordered]@{
        Status = 'Activated'
        Version = $planVersion.ToString()
        CompletedUtc = ConvertTo-SuHelperUtcText
        BackupRoot = $backupRoot
    }
    Write-SuHelperJson -Path $resultPath -Value $result
    Write-SuHelperLog ('Activation completed for version {0}.' -f $planVersion)
    exit 0
} catch {
    $message = $_.Exception.Message
    Write-SuHelperLog ('Activation failed: ' + $message)
    $restoreFailed = @()
    if ($completed.Count -gt 0) {
        try { $restoreFailed = @(Restore-SuHelperBackup -Completed @($completed)) }
        catch { $restoreFailed = @('rollback-exception') }
    }
    if ($restoreFailed.Count -eq 0) {
        Remove-SuHelperPending
        try { if ($null -ne $script:SuPlan -and [bool](Get-SuHelperProperty $script:SuPlan 'TaskWasEnabled')) { $null = Set-SuHelperTaskEnabled -Enabled $true } } catch { }
        $status = 'Failed'
    } else {
        $status = 'RecoveryRequired'
    }
    $resultPath = $null
    try { if ($null -ne $script:SuPlan) { $resultPath = [IO.Path]::GetFullPath([string](Get-SuHelperProperty $script:SuPlan 'ResultPath')) } } catch { }
    if (-not [string]::IsNullOrWhiteSpace($resultPath)) {
        try {
            Write-SuHelperJson -Path $resultPath -Value ([ordered]@{
                Status = $status
                Version = if ($null -eq $script:SuPlan) { $null } else { [string](Get-SuHelperProperty $script:SuPlan 'Version') }
                CompletedUtc = ConvertTo-SuHelperUtcText
                Error = $message
                RestoreFailed = @($restoreFailed)
            })
        } catch { }
    }
    exit 1
} finally {
    if ($null -ne $lockStream) { $lockStream.Dispose() }
}
