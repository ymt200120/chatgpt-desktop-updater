#requires -Version 5.1
<##
    Install, inspect, enable, disable, and remove the current-user task.

    Registration is deliberately explicit.  The worker action prepares a
    candidate and can launch a confirmation window, but it never contains an
    Add-AppxPackage command or a consent flag.
##>
[CmdletBinding(DefaultParameterSetName = 'Status')]
param(
    [Parameter(ParameterSetName = 'Install')][switch]$Install,
    [Parameter(ParameterSetName = 'Enable')][switch]$Enable,
    [Parameter(ParameterSetName = 'Disable')][switch]$Disable,
    [Parameter(ParameterSetName = 'Remove')][switch]$Remove,
    [Parameter(ParameterSetName = 'Status')][switch]$Status,
    [string]$SourceRoot,
    [string]$DestinationRoot,
    [ValidateSet(1,4,8,16)][int]$Connections = 8,
    [switch]$TestMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($SourceRoot)) { $SourceRoot = $PSScriptRoot }
. (Join-Path $SourceRoot 'background-common.ps1') -CorePath (Join-Path $SourceRoot 'update-chatgpt.ps1')
$script:UgAllowCustomDestination = [bool]$TestMode

$script:UgProductionFiles = @(
    'update-chatgpt.ps1',
    'update-chatgpt.cmd',
    'background-common.ps1',
    'segmented-download.ps1',
    'managed-cache.ps1',
    'background-worker.ps1',
    'background-worker.cmd',
    'confirm-install.ps1',
    'manage-background.ps1',
    'manage-background.cmd'
)

function Get-UgCurrentSid {
    return ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
}

function Resolve-UgPrincipalSid {
    param([AllowEmptyString()][string]$UserId)
    $text = ([string]$UserId).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    # ScheduledTasks exposes a raw SID on some systems and an account name on
    # others.  Canonicalize both forms before comparing; an unresolvable value
    # is never treated as owned.
    if ($text -match '(?i)^S-') {
        try { return (New-Object System.Security.Principal.SecurityIdentifier -ArgumentList @($text)).Value }
        catch { return $null }
    }
    try {
        $account = New-Object System.Security.Principal.NTAccount -ArgumentList @($text)
        $sid = $account.Translate([System.Security.Principal.SecurityIdentifier])
        if ($null -eq $sid) { return $null }
        return ([System.Security.Principal.SecurityIdentifier]$sid).Value
    }
    catch { return $null }
}

function Get-UgTaskName { return $script:UbTaskName }

function Get-UgTask {
    param([string]$TaskName = $script:UbTaskName)
    try { return Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop }
    catch {
        $message = [string]$_.Exception.Message
        $hresult = 0
        try { $hresult = [int]$_.Exception.HResult } catch { }
        $fqid = [string]$_.FullyQualifiedErrorId
        $category = [string]$_.CategoryInfo.Category
        if (($fqid -match '(?i)^CmdletizationQuery_NotFound_TaskName,Get-ScheduledTask' -and $category -eq 'ObjectNotFound') -or
            $hresult -eq -2147024894 -or
            $message -match '(?i)0x80070002' -or
            $message -match '(?i)the system cannot find the file specified' -or
            $message -match '(?i)no MSFT_ScheduledTask object found') { return $null }
        throw
    }
}

function Get-UgPowerShellPath {
    $systemRoot = [Environment]::GetEnvironmentVariable('SystemRoot')
    if ([string]::IsNullOrWhiteSpace($systemRoot)) { throw 'SystemRoot is not set; refusing an untrusted PowerShell executable.' }
    $path = Join-Path $systemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Windows PowerShell 5.1 is unavailable.' }
    return [IO.Path]::GetFullPath($path)
}

function Get-UgStablePath {
    param([string]$Destination)
    $canonical = [IO.Path]::GetFullPath((Get-UbStableRoot))
    if ([string]::IsNullOrWhiteSpace($Destination)) { return $canonical }
    $full = [IO.Path]::GetFullPath($Destination)
    if (-not $script:UgAllowCustomDestination -and $full -ine $canonical) { throw "Deployment destination must be the current user's stable root: $canonical" }
    return $full
}

function Assert-UgRegularSource {
    param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$SourceBase)
    $baseFull = [IO.Path]::GetFullPath($SourceBase).TrimEnd('\')
    $baseItem = Get-Item -LiteralPath $baseFull -Force -ErrorAction Stop
    if (-not $baseItem.PSIsContainer -or (($baseItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw "Source root is not a stable directory: $SourceBase" }
    $baseAncestor = $baseItem
    while ($null -ne $baseAncestor) {
        if (($baseAncestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Source root contains a reparse-point ancestor: $SourceBase" }
        $baseAncestor = $baseAncestor.Parent
    }
    $base = $baseFull + '\'
    $full = [IO.Path]::GetFullPath($Source)
    if (-not $full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw "Source escapes the selected source root: $Source" }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw "Source is missing, not a regular file, or is a reparse point: $Source" }
    $parent = $item.Directory
    while ($null -ne $parent -and [IO.Path]::GetFullPath($parent.FullName).Length -ge $baseFull.Length) {
        if (($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Source path contains a reparse-point ancestor: $Source" }
        if ([IO.Path]::GetFullPath($parent.FullName).TrimEnd('\') -ieq $baseFull) { break }
        $parent = $parent.Parent
    }
    return $full
}

function Assert-UgStableFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Root)
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw "Refusing to overwrite a non-regular or reparse-point deployment path: $Path" }
    }
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    if (-not ([IO.Path]::GetFullPath($Path)).StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw 'Deployment path escaped the stable root.' }
}

function Copy-UgProductionFiles {
    param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Destination)
    $destinationRoot = Assert-UbDirectory -Path $Destination
    foreach ($name in $script:UgProductionFiles) {
        $sourcePath = Assert-UgRegularSource -Source (Join-Path $Source $name) -SourceBase $Source
        $targetPath = Join-Path $destinationRoot $name
        Assert-UgStableFile -Path $targetPath -Root $destinationRoot
        $temporary = Join-Path $destinationRoot ('.' + $name + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            Copy-Item -LiteralPath $sourcePath -Destination $temporary -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
                try { [IO.File]::Replace($temporary, $targetPath, $null, $true) }
                catch { Move-Item -LiteralPath $temporary -Destination $targetPath -Force -ErrorAction Stop }
            } else { Move-Item -LiteralPath $temporary -Destination $targetPath -Force -ErrorAction Stop }
        } finally {
            if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        }
    }
    return $destinationRoot
}

function New-UgTaskAction {
    param([Parameter(Mandatory = $true)][string]$StableRoot, [ValidateSet(1,4,8,16)][int]$Connections = 8)
    $worker = [IO.Path]::GetFullPath((Join-Path $StableRoot 'background-worker.ps1'))
    $quoted = '"' + ($worker -replace '"','\"') + '"'
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File {0} -Mode Run -Connections {1}' -f $quoted, $Connections
    return New-ScheduledTaskAction -Execute (Get-UgPowerShellPath) -Argument $arguments -WorkingDirectory $StableRoot
}

function Get-UgExpectedTaskArguments {
    param([Parameter(Mandatory = $true)][string]$StableRoot, [ValidateSet(1,4,8,16)][int]$Connections = 8)
    $worker = [IO.Path]::GetFullPath((Join-Path $StableRoot 'background-worker.ps1'))
    return '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Mode Run -Connections {1}' -f $worker, $Connections
}

function Test-UgTaskOwnership {
    param([Parameter(Mandatory = $true)]$Task, [Parameter(Mandatory = $true)][string]$StableRoot, [Parameter(Mandatory = $true)][string]$Sid, [ValidateSet(1,4,8,16)][int]$Connections = 8)
    if ($null -eq $Task) { return $false }
    if ([string]$Task.Description -ne $script:UbTaskMarker) { return $false }
    $principal = Get-UbProperty $Task 'Principal'
    if ($null -eq $principal) { return $false }
    $expectedSid = Resolve-UgPrincipalSid -UserId $Sid
    $principalSid = Resolve-UgPrincipalSid -UserId ([string](Get-UbProperty $principal 'UserId'))
    if ($null -eq $expectedSid -or $null -eq $principalSid -or $principalSid -cne $expectedSid -or [string](Get-UbProperty $principal 'LogonType') -cne 'Interactive' -or [string](Get-UbProperty $principal 'RunLevel') -ne 'Limited') { return $false }
    $actions = @($Task.Actions)
    if ($actions.Count -ne 1) { return $false }
    $action = $actions[0]
    $expectedWorker = [IO.Path]::GetFullPath((Join-Path $StableRoot 'background-worker.ps1'))
    $expectedPowerShell = [IO.Path]::GetFullPath((Get-UgPowerShellPath))
    try { if ([IO.Path]::GetFullPath([string]$action.Execute) -ine $expectedPowerShell) { return $false } } catch { return $false }
    $args = ([string]$action.Arguments).Trim()
    $supported = @(
        (Get-UgExpectedTaskArguments -StableRoot $StableRoot -Connections 1),
        (Get-UgExpectedTaskArguments -StableRoot $StableRoot -Connections 4),
        (Get-UgExpectedTaskArguments -StableRoot $StableRoot -Connections 8),
        (Get-UgExpectedTaskArguments -StableRoot $StableRoot -Connections 16)
    )
    if ($supported -notcontains $args) { return $false }
    if ([string]$action.WorkingDirectory -cne [IO.Path]::GetFullPath($StableRoot)) { return $false }
    return $true
}

function Assert-UgOwnedTask {
    param([Parameter(Mandatory = $true)]$Task, [Parameter(Mandatory = $true)][string]$StableRoot, [Parameter(Mandatory = $true)][string]$Sid)
    if (-not (Test-UgTaskOwnership -Task $Task -StableRoot $StableRoot -Sid $Sid)) { throw "Scheduled task '$($script:UbTaskName)' exists but is not owned by this updater; no overwrite/removal was attempted." }
}

function New-UgTaskDefinition {
    param([Parameter(Mandatory = $true)][string]$StableRoot, [Parameter(Mandatory = $true)][string]$Sid, [ValidateSet(1,4,8,16)][int]$Connections = 8)
    $daily = New-ScheduledTaskTrigger -Daily -At '12:00'
    $logon = New-ScheduledTaskTrigger -AtLogOn -User $Sid
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal = New-ScheduledTaskPrincipal -UserId $Sid -LogonType Interactive -RunLevel Limited
    $action = New-UgTaskAction -StableRoot $StableRoot -Connections $Connections
    return [pscustomobject]@{ Action = $action; Trigger = @($daily,$logon); Settings = $settings; Principal = $principal }
}

function Install-UgBackgroundTask {
    param([string]$Source = $SourceRoot, [string]$Destination = $DestinationRoot, [ValidateSet(1,4,8,16)][int]$TaskConnections = 8)
    $stableTarget = Get-UgStablePath -Destination $Destination
    $sid = Get-UgCurrentSid
    $existing = Get-UgTask
    if ($null -ne $existing) { Assert-UgOwnedTask -Task $existing -StableRoot $stableTarget -Sid $sid }
    $stable = Copy-UgProductionFiles -Source $Source -Destination $stableTarget
    $definition = New-UgTaskDefinition -StableRoot $stable -Sid $sid -Connections $TaskConnections
    $description = $script:UbTaskMarker
    Register-ScheduledTask -TaskName $script:UbTaskName -Action $definition.Action -Trigger $definition.Trigger -Settings $definition.Settings -Principal $definition.Principal -Description $description -Force -ErrorAction Stop | Out-Null
    $registered = Get-UgTask
    if ($null -eq $registered) { throw "Scheduled task '$($script:UbTaskName)' disappeared after registration; no start was attempted." }
    Assert-UgOwnedTask -Task $registered -StableRoot $stable -Sid $sid
    Enable-ScheduledTask -TaskName $script:UbTaskName -ErrorAction Stop | Out-Null
    # Start one bounded preparation immediately so an explicit install does
    # not wait until the next noon/logon trigger.  The worker still has no
    # installation path; any deployment requires its separate UI button.
    Start-ScheduledTask -TaskName $script:UbTaskName -ErrorAction Stop | Out-Null
    return Get-UgBackgroundStatus -StableRoot $stable
}

function Get-UgBackgroundStatus {
    param([string]$StableRoot = $DestinationRoot)
    $stable = Get-UgStablePath -Destination $StableRoot
    $sid = Get-UgCurrentSid
    $task = Get-UgTask
    $owned = $false
    $info = $null
    if ($null -ne $task) {
        $owned = Test-UgTaskOwnership -Task $task -StableRoot $stable -Sid $sid
        if ($owned) { try { $info = Get-ScheduledTaskInfo -TaskName $script:UbTaskName -ErrorAction Stop } catch { $info = $null } }
    }
    return [pscustomobject]@{
        TaskName = $script:UbTaskName
        StableRoot = $stable
        CurrentUserSid = $sid
        Exists = ($null -ne $task)
        Owned = $owned
        State = if ($null -eq $task) { 'Absent' } elseif (-not $owned) { 'Foreign' } else { [string]$task.State }
        LastRunTime = if ($null -eq $info) { $null } else { $info.LastRunTime }
        NextRunTime = if ($null -eq $info) { $null } else { $info.NextRunTime }
        LastTaskResult = if ($null -eq $info) { $null } else { $info.LastTaskResult }
        FilesPresent = (@($script:UgProductionFiles | ForEach-Object { Test-Path -LiteralPath (Join-Path $stable $_) -PathType Leaf } | Where-Object { $_ })).Count
    }
}

function Set-UgTaskEnabled {
    param([Parameter(Mandatory = $true)][bool]$Enabled, [string]$StableRoot = $DestinationRoot)
    $task = Get-UgTask
    if ($null -eq $task) { throw "Scheduled task '$($script:UbTaskName)' does not exist." }
    Assert-UgOwnedTask -Task $task -StableRoot (Get-UgStablePath -Destination $StableRoot) -Sid (Get-UgCurrentSid)
    if ($Enabled) {
        Enable-ScheduledTask -TaskName $script:UbTaskName -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $script:UbTaskName -ErrorAction Stop | Out-Null
    }
    else { Disable-ScheduledTask -TaskName $script:UbTaskName -ErrorAction Stop | Out-Null }
    return Get-UgBackgroundStatus -StableRoot $StableRoot
}

function Remove-UgBackgroundTask {
    param([string]$StableRoot = $DestinationRoot)
    $task = Get-UgTask
    if ($null -eq $task) { return [pscustomobject]@{ Status = 'Absent'; TaskName = $script:UbTaskName } }
    Assert-UgOwnedTask -Task $task -StableRoot (Get-UgStablePath -Destination $StableRoot) -Sid (Get-UgCurrentSid)
    Unregister-ScheduledTask -TaskName $script:UbTaskName -Confirm:$false -ErrorAction Stop
    return [pscustomobject]@{ Status = 'Removed'; TaskName = $script:UbTaskName }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($TestMode) {
        $stable = Get-UgStablePath -Destination $DestinationRoot
        $plan = [pscustomobject]@{ Mode = if ($Install) { 'Install' } elseif ($Enable) { 'Enable' } elseif ($Disable) { 'Disable' } elseif ($Remove) { 'Remove' } else { 'Status' }; TaskName = $script:UbTaskName; StableRoot = $stable; Connections = $Connections; RegisterTask = $false; Description = $script:UbTaskMarker }
        $plan | ConvertTo-Json -Depth 6 -Compress
        exit 0
    }
    try {
        if ($Install) { $result = Install-UgBackgroundTask -Source $SourceRoot -Destination $DestinationRoot -TaskConnections $Connections }
        elseif ($Enable) { $result = Set-UgTaskEnabled -Enabled $true -StableRoot $DestinationRoot }
        elseif ($Disable) { $result = Set-UgTaskEnabled -Enabled $false -StableRoot $DestinationRoot }
        elseif ($Remove) { $result = Remove-UgBackgroundTask -StableRoot $DestinationRoot }
        else { $result = Get-UgBackgroundStatus -StableRoot $DestinationRoot }
        if ($null -ne $result) { $result | ConvertTo-Json -Depth 8 }
        exit 0
    } catch {
        Write-Error $_.Exception.Message -ErrorAction Continue
        exit 12
    }
}
