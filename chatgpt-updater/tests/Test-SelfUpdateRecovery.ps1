#requires -Version 5.1
<##
    Offline recovery tests for the updater self-update transaction.

    The tests use only unique TEMP/LOCALAPPDATA fixtures.  Helper processes run
    against those fixtures, and task APIs are supplied by a child wrapper that
    persists a small deterministic task model.  No network, AppX, real task,
    service, UI, or process termination is used.
##>
[CmdletBinding()]
param([switch]$KeepTemp)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:OriginalLocalAppData = $env:LOCALAPPDATA
$script:IsolatedRoot = Join-Path $env:TEMP ('ChatGPTUpdater-self-update-recovery-' + [guid]::NewGuid().ToString('N'))
$script:LocalAppData = Join-Path $script:IsolatedRoot 'local data'
$script:StableRoot = Join-Path $script:LocalAppData 'Programs\ChatGPTUpdater'
$script:StateRoot = Join-Path $script:LocalAppData 'ChatGPTUpdater\updater'
$script:FixtureRoot = Join-Path $script:IsolatedRoot 'fixtures'
$script:HelperPath = Join-Path $script:ProjectRoot 'self-update-helper.ps1'
$script:SelfUpdatePath = Join-Path $script:ProjectRoot 'self-update.ps1'
$script:SleepWrapperPath = Join-Path $script:IsolatedRoot 'finite-parent.ps1'
$script:TaskWrapperPath = Join-Path $script:IsolatedRoot 'task-wrapper.ps1'
$script:ProbeWrapperPath = Join-Path $script:IsolatedRoot 'task-probe-wrapper.ps1'
$script:ProgressWrapperPath = Join-Path $script:IsolatedRoot 'backup-progress-wrapper.ps1'
$script:FailureWrapperPath = Join-Path $script:IsolatedRoot 'self-update-copy-failure-wrapper.ps1'
$script:TestTotal = 0
$script:TestFailed = 0

$null = New-Item -ItemType Directory -Path $script:FixtureRoot -Force
$null = New-Item -ItemType Directory -Path $script:StableRoot -Force
$null = New-Item -ItemType Directory -Path $script:StateRoot -Force
$env:LOCALAPPDATA = $script:LocalAppData

# Loading the core is function-only and supplies the production updater file
# list and path/version constants used by the local archive fixture.
. (Join-Path $script:ProjectRoot 'update-chatgpt.ps1')

function Assert-True {
    param([bool]$Value, [string]$Message)
    if (-not $Value) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ([string]$Expected -cne [string]$Actual) { throw "$Message (expected '$Expected', got '$Actual')" }
}

function Invoke-Case {
    param([string]$Name, [scriptblock]$Body)
    $script:TestTotal++
    try {
        & $Body
        Write-Host ('PASS ' + $Name) -ForegroundColor Green
    } catch {
        $script:TestFailed++
        Write-Host ('FAIL ' + $Name + ': ' + $_.Exception.Message) -ForegroundColor Red
    }
}

function Get-TestRuntime {
    $name = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { 'pwsh.exe' }
    $candidate = Join-Path $PSHOME $name
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return [IO.Path]::GetFullPath($candidate) }
    return [IO.Path]::GetFullPath((Get-Command $name -CommandType Application -ErrorAction Stop).Source)
}

$script:Runtime = Get-TestRuntime

function Write-TestJson {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Value)
    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) { $null = New-Item -ItemType Directory -Path $directory -Force }
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 12 -Compress), (New-Object Text.UTF8Encoding($false)))
}

function Read-TestJson {
    param([Parameter(Mandatory = $true)][string]$Path)
    return ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop)
}

function Write-TestText {
    param([Parameter(Mandatory = $true)][string]$Path, [AllowEmptyString()][string]$Text)
    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) { $null = New-Item -ItemType Directory -Path $directory -Force }
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Get-TestHash {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
}

function Get-TestBytesBase64 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path))
}

function Get-TestStableSnapshot {
    $root = [IO.Path]::GetFullPath($script:StableRoot).TrimEnd('\')
    $entries = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($root.Length).TrimStart('\').Replace('\', '/')
        '{0}={1}' -f $relative, (Get-TestHash -Path $_.FullName)
    })
    return ($entries -join '|')
}

function ConvertTo-TestArgument {
    param([AllowEmptyString()][string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $quoted = $Value -replace '(\\*)"', '$1$1\"'
    $quoted = $quoted -replace '(\\+)$', '$1$1'
    return '"' + $quoted + '"'
}

function Invoke-TestChild {
    param([Parameter(Mandatory = $true)][string]$FilePath, [string[]]$Arguments = @())
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $FilePath @Arguments 2>&1)
        $code = [int]$LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    return [pscustomobject]@{ Code = $code; Text = (($output | ForEach-Object { [string]$_ }) -join "`n") }
}

function Start-TestChild {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$OutputRoot = $script:IsolatedRoot
    )
    $id = [guid]::NewGuid().ToString('N')
    $stdout = Join-Path $OutputRoot ($id + '.stdout.txt')
    $stderr = Join-Path $OutputRoot ($id + '.stderr.txt')
    $argumentText = (($Arguments | ForEach-Object { ConvertTo-TestArgument -Value ([string]$_) }) -join ' ')
    $process = Start-Process -FilePath $FilePath -ArgumentList $argumentText -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    return [pscustomobject]@{ Process = $process; Stdout = $stdout; Stderr = $stderr }
}

function Wait-TestChild {
    param([Parameter(Mandatory = $true)]$Child, [int]$TimeoutSeconds = 30)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (-not $Child.Process.HasExited) {
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Isolated child process did not exit within the test timeout.' }
        Start-Sleep -Milliseconds 100
    }
    $Child.Process.Refresh()
    return [pscustomobject]@{
        Code = [int]$Child.Process.ExitCode
        Text = (($null, (Get-Content -LiteralPath $Child.Stdout -Raw -ErrorAction SilentlyContinue), (Get-Content -LiteralPath $Child.Stderr -Raw -ErrorAction SilentlyContinue) | Where-Object { $null -ne $_ }) -join "`n")
    }
}

function Remove-TestPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Container) { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue }
    elseif (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
}

function Reset-TestStableRoot {
    Remove-TestPath -Path $script:StableRoot
    $null = New-Item -ItemType Directory -Path $script:StableRoot -Force
}

function New-FiniteParentScript {
    Write-TestText -Path $script:SleepWrapperPath -Text @'
param([int]$Seconds = 2)
Start-Sleep -Seconds $Seconds
'@
}

$taskWrapperSource = @'
# Controlled task boundary wrapper.  It deliberately persists only a fixture
# state file and never calls the Windows Scheduled Task cmdlets.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetScript,
    [Parameter(Mandatory = $true)][string]$TaskStatePath,
    [Parameter(Mandatory = $true)][string]$TargetArgsPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Read-MockTask {
    return ([IO.File]::ReadAllText($TaskStatePath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop)
}
function Write-MockTask { param($State) [IO.File]::WriteAllText($TaskStatePath, ($State | ConvertTo-Json -Depth 8 -Compress), (New-Object Text.UTF8Encoding($false))) }
function Throw-MockTaskNotFound {
    param([System.Management.Automation.PSCmdlet]$Cmdlet)
    $exception = New-Object System.Runtime.InteropServices.COMException -ArgumentList 'The task does not exist.', -2147216625
    $record = New-Object System.Management.Automation.ErrorRecord -ArgumentList $exception, 'CmdletizationQuery_NotFound_TaskName,Get-ScheduledTask', ([System.Management.Automation.ErrorCategory]::ObjectNotFound), $null
    $Cmdlet.ThrowTerminatingError($record)
}
function Get-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskName)
    $state = Read-MockTask
    if ([string]$state.Mode -eq 'notfound' -or -not [bool]$state.Present) { Throw-MockTaskNotFound -Cmdlet $PSCmdlet }
    if ([string]$state.Mode -eq 'rpc') { throw 'The RPC server is unavailable while querying the task.' }
    return [pscustomobject]@{
        Description = [string]$state.Description
        State = [string]$state.State
        Principal = [pscustomobject]@{ UserId = [string]$state.UserId }
    }
}
function Disable-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskName)
    $state = Read-MockTask
    if ([string]$state.DisableMode -eq 'fail') { throw 'The fixture refused to disable the task.' }
    $state.State = 'Disabled'
    if (-not [string]::IsNullOrWhiteSpace([string]$state.AfterDisableMode)) {
        $state.Mode = [string]$state.AfterDisableMode
        $state.AfterDisableMode = ''
    }
    Write-MockTask $state
    return [pscustomobject]@{ State = 'Disabled' }
}
function Enable-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskName)
    $state = Read-MockTask
    if ([string]$state.EnableMode -eq 'fail') { throw 'The fixture refused to enable the task.' }
    $state.Mode = 'ok'
    $state.State = 'Ready'
    Write-MockTask $state
    return [pscustomobject]@{ State = 'Ready' }
}
function Remove-Item {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$LiteralPath,
        [switch]$Recurse,
        [switch]$Force
    )
    $state = Read-MockTask
    if ([string]$state.RemovePendingMode -eq 'fail') {
        foreach ($path in $LiteralPath) {
            if ([IO.Path]::GetFileName([string]$path) -ieq 'self-update.pending.json') {
                throw 'The fixture refused to remove the pending marker.'
            }
        }
    }
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -Recurse:$Recurse -Force:$Force -ErrorAction Stop
}
$targetArgs = @((Get-Content -LiteralPath $TargetArgsPath -Raw -ErrorAction Stop | ConvertFrom-Json) | ForEach-Object { [string]$_ })
$targetInvoke = @{ PlanPath = $targetArgs[1] }
if ($targetArgs -contains '-Recover') { $targetInvoke.Recover = $true }
& $TargetScript @targetInvoke
$targetExit = [int]$LASTEXITCODE
exit $targetExit
'@

function New-TaskWrapper {
    Write-TestText -Path $script:TaskWrapperPath -Text $taskWrapperSource
}

$probeWrapperSource = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SelfUpdatePath,
    [Parameter(Mandatory = $true)][string]$TaskStatePath,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [Parameter(Mandatory = $true)][string]$GuardRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Read-MockTask { return ([IO.File]::ReadAllText($TaskStatePath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop) }
function Write-MockTask { param($State) [IO.File]::WriteAllText($TaskStatePath, ($State | ConvertTo-Json -Depth 8 -Compress), (New-Object Text.UTF8Encoding($false))) }
function Throw-MockTaskNotFound {
    param([System.Management.Automation.PSCmdlet]$Cmdlet)
    $exception = New-Object System.Runtime.InteropServices.COMException -ArgumentList 'The task does not exist.', -2147216625
    $record = New-Object System.Management.Automation.ErrorRecord -ArgumentList $exception, 'CmdletizationQuery_NotFound_TaskName,Get-ScheduledTask', ([System.Management.Automation.ErrorCategory]::ObjectNotFound), $null
    $Cmdlet.ThrowTerminatingError($record)
}
function Get-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskName)
    $state = Read-MockTask
    if ([string]$state.Mode -eq 'notfound' -or -not [bool]$state.Present) { Throw-MockTaskNotFound -Cmdlet $PSCmdlet }
    if ([string]$state.Mode -eq 'rpc') { throw 'The RPC server is unavailable while querying the task.' }
    return [pscustomobject]@{ Description=[string]$state.Description; State=[string]$state.State; Principal=[pscustomobject]@{ UserId=[string]$state.UserId } }
}
function Disable-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskName)
    $state = Read-MockTask
    if ([string]$state.DisableMode -eq 'fail') { throw 'The fixture refused to disable the task.' }
    $state.State='Disabled'
    if (-not [string]::IsNullOrWhiteSpace([string]$state.AfterDisableMode)) { $state.Mode=[string]$state.AfterDisableMode; $state.AfterDisableMode='' }
    Write-MockTask $state
}
function Enable-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskName)
    $state = Read-MockTask
    if ([string]$state.EnableMode -eq 'fail') { throw 'The fixture refused to enable the task.' }
    $state.Mode='ok'; $state.State='Ready'; Write-MockTask $state
}
function Get-UbRoot { return (Join-Path $env:LOCALAPPDATA 'ChatGPTUpdater') }
function Get-UbLocalAppData { return $env:LOCALAPPDATA }
function Write-SuLog { param([string]$Message) }
function Stop-Su {
    param([int]$Code, [string]$Message)
    $exception = New-Object Exception -ArgumentList @($Message)
    $exception.Data['SuExitCode'] = $Code
    throw $exception
}
$script:UbTaskName='ChatGPTUpdater-Background'
$script:UbTaskMarker='ChatGPTUpdater-owned-v1'
$script:SuStateRoot=(Join-Path $env:LOCALAPPDATA 'ChatGPTUpdater\updater')
$script:SuResultPath=(Join-Path $GuardRoot 'task-query-guard.json')
$TestMode=$false
$tokens=$null; $errors=$null
$sourceAst=[System.Management.Automation.Language.Parser]::ParseFile($SelfUpdatePath,[ref]$tokens,[ref]$errors)
if (@($errors).Count -gt 0) { throw 'self-update source could not be parsed by the task probe' }
$functions=@($sourceAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
$definitionText=($functions | ForEach-Object { $_.Extent.Text }) -join "`r`n"
. ([scriptblock]::Create($definitionText))
$result=[ordered]@{}
try { $result.Status='Completed'; $result.Value=(Suspend-SuBackgroundTask | ConvertTo-Json -Depth 8 -Compress) }
catch { $result.Status='Failed'; $result.Error=$_.Exception.Message }
Write-TestJson -Path $ResultPath -Value $result
if ($result.Status -eq 'Failed') { exit 1 }
'@

function New-ProbeWrapper {
    # The wrapper uses the test script's JSON writer only when executed in this
    # process; its child copy receives a small local equivalent below.
    $source = $probeWrapperSource.Replace('Write-TestJson -Path $ResultPath -Value $result', '[IO.File]::WriteAllText($ResultPath, ($result | ConvertTo-Json -Depth 8 -Compress), (New-Object Text.UTF8Encoding($false)))')
    Write-TestText -Path $script:ProbeWrapperPath -Text $source
}

$progressWrapperSource = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SelfUpdateHelperPath,
    [Parameter(Mandatory = $true)][string]$PlanPath,
    [Parameter(Mandatory = $true)][string]$ResultPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$sourceAst = [System.Management.Automation.Language.Parser]::ParseFile($SelfUpdateHelperPath, [ref]$tokens, [ref]$errors)
if (@($errors).Count -gt 0) { throw 'self-update helper source could not be parsed by the progress probe' }
$functions = @($sourceAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
$definitionText = ($functions | ForEach-Object { $_.Extent.Text }) -join "`r`n"
. ([scriptblock]::Create($definitionText))
$script:SuPlanPath = [IO.Path]::GetFullPath($PlanPath)
$script:SuPlan = [IO.File]::ReadAllText($script:SuPlanPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
$script:SuPlan | Add-Member -NotePropertyName PlanPath -NotePropertyValue $script:SuPlanPath -Force
$script:SuTransactionId = [string]$script:SuPlan.TransactionId
$script:SuTestMode = [bool]$script:SuPlan.TestMode
$script:SuCompleted = New-Object Collections.ArrayList
$result = [ordered]@{}
try {
    Set-SuHelperBackupState -ActivationStarted:$true -InProgressFile 'payload.txt'
    $result.Status = 'Completed'
} catch {
    $result.Status = 'Failed'
    $result.Error = $_.Exception.Message
}
[IO.File]::WriteAllText($ResultPath, ($result | ConvertTo-Json -Depth 8 -Compress), (New-Object Text.UTF8Encoding($false)))
if ($result.Status -eq 'Failed') { exit 1 }
'@

function New-ProgressWrapper {
    Write-TestText -Path $script:ProgressWrapperPath -Text $progressWrapperSource
}

$failureWrapperSource = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetScript,
    [Parameter(Mandatory = $true)][string]$TargetArgsPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Copy-Item {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$LiteralPath,[Parameter(Mandatory=$true)][string]$Destination,[switch]$Force)
    if ($Destination -match '(?i)[\\/]helpers[\\/]helper-') { throw 'fixture failure while copying the helper after pending publication' }
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force -ErrorAction Stop
}
$targetArgs=@((Get-Content -LiteralPath $TargetArgsPath -Raw -ErrorAction Stop | ConvertFrom-Json) | ForEach-Object { [string]$_ })
$targetInvoke = @{}
for ($index = 0; $index -lt $targetArgs.Count; $index++) {
    switch ($targetArgs[$index]) {
        '-Apply' { $targetInvoke.Apply = $true }
        '-CheckOnly' { $targetInvoke.CheckOnly = $true }
        '-NoActivate' { $targetInvoke.NoActivate = $true }
        '-TestMode' { $targetInvoke.TestMode = $true }
        '-StableRoot' { $targetInvoke.StableRoot = $targetArgs[++$index] }
        '-ManifestPath' { $targetInvoke.ManifestPath = $targetArgs[++$index] }
        '-ArchivePath' { $targetInvoke.ArchivePath = $targetArgs[++$index] }
        default { throw ('Unexpected self-update fixture argument: ' + $targetArgs[$index]) }
    }
}
& $TargetScript @targetInvoke
$targetExit = [int]$LASTEXITCODE
exit $targetExit
'@

function New-FailureWrapper {
    Write-TestText -Path $script:FailureWrapperPath -Text $failureWrapperSource
}

function New-TaskState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('ok','notfound','rpc')][string]$Mode = 'ok',
        [string]$State = 'Ready',
        [bool]$Present = $true,
        [string]$AfterDisableMode = '',
        [string]$DisableMode = 'ok',
        [string]$EnableMode = 'ok',
        [string]$RemovePendingMode = 'ok'
    )
    $sid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
    Write-TestJson -Path $Path -Value ([ordered]@{
        Mode = $Mode
        Present = $Present
        Description = 'ChatGPTUpdater-owned-v1'
        UserId = $sid
        State = $State
        AfterDisableMode = $AfterDisableMode
        DisableMode = $DisableMode
        EnableMode = $EnableMode
        RemovePendingMode = $RemovePendingMode
    })
    return $Path
}

function New-HelperFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$TestMode,
        [int]$Schema = 2,
        [bool]$TaskExisted = $false,
        [bool]$TaskWasEnabled = $false,
        [hashtable]$OldFiles,
        [hashtable]$NewFiles,
        [int]$ExtraCount = 0,
        [bool]$CreateStaging = $true,
        [bool]$CreatePending = $true,
        [hashtable]$PlanOverrides,
        [hashtable]$PendingOverrides,
        [ValidateSet('ok','notfound','rpc')][string]$TaskMode = 'ok',
        [ValidateSet('ok','fail')][string]$TaskEnableMode = 'ok',
        [ValidateSet('ok','fail')][string]$TaskRemovePendingMode = 'ok'
    )
    Reset-TestStableRoot
    $caseRoot = Join-Path $script:StateRoot ('recovery-' + $Name + '-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $caseRoot -Force
    $staging = Join-Path $caseRoot 'staging'
    $backup = Join-Path $caseRoot 'backup'
    $planPath = Join-Path $caseRoot 'plan.json'
    $resultPath = Join-Path $caseRoot 'result.json'
    $logPath = Join-Path $caseRoot 'helper.log'
    $lockPath = Join-Path $caseRoot 'self-update.lock'
    $ordinaryLockPath = Join-Path $caseRoot 'update.lock'
    $pendingPath = Join-Path $script:StableRoot 'self-update.pending.json'
    if ($null -eq $OldFiles) { $OldFiles = [ordered]@{ VERSION = "0.2.0.1`r`n"; 'payload.txt' = 'old payload`r`n' } }
    if ($null -eq $NewFiles) { $NewFiles = [ordered]@{ VERSION = "0.2.0.2`r`n"; 'payload.txt' = 'new payload`r`n' } }
    $oldMap = [ordered]@{}
    foreach ($key in $OldFiles.Keys) { $oldMap[[string]$key] = [string]$OldFiles[$key] }
    $newMap = [ordered]@{}
    foreach ($key in $NewFiles.Keys) { $newMap[[string]$key] = [string]$NewFiles[$key] }
    for ($index = 1; $index -le $ExtraCount; $index++) {
        $name = 'middle-{0:D3}.txt' -f $index
        $oldMap[$name] = ('old-{0}' -f $index)
        $newMap[$name] = ('new-{0}' -f $index)
    }
    foreach ($name in @($oldMap.Keys)) { Write-TestText -Path (Join-Path $script:StableRoot $name) -Text $oldMap[$name] }
    if ($CreateStaging) {
        $null = New-Item -ItemType Directory -Path $staging -Force
        foreach ($name in @($newMap.Keys)) { Write-TestText -Path (Join-Path $staging $name) -Text $newMap[$name] }
    }
    $orderedNames = New-Object Collections.Generic.List[string]
    foreach ($name in @('VERSION')) { if ($newMap.Contains($name)) { [void]$orderedNames.Add($name) } }
    foreach ($name in @($newMap.Keys)) { if ($name -ne 'VERSION' -and $name -ne 'payload.txt') { [void]$orderedNames.Add([string]$name) } }
    if ($newMap.Contains('payload.txt')) { [void]$orderedNames.Add('payload.txt') }
    $files = @($orderedNames | ForEach-Object {
        $staged = Join-Path $staging $_
        [ordered]@{ Name = $_; SHA256 = if ($CreateStaging) { Get-TestHash -Path $staged } else { 'A' * 64 } }
    })
    $transactionId = [guid]::NewGuid().ToString('N')
    $version = [version]'0.2.0.2'
    $plan = [ordered]@{
        Schema = $Schema
        TransactionId = if ($Schema -eq 2) { $transactionId } else { $null }
        Status = 'Pending'
        Version = $version.ToString()
        StableRoot = $script:StableRoot
        StagingRoot = $staging
        BackupRoot = $backup
        PendingPath = $pendingPath
        ResultPath = $resultPath
        LogPath = $logPath
        LockPath = $lockPath
        OrdinaryLockPath = $ordinaryLockPath
        PlanPath = $planPath
        ParentPid = 0
        TaskName = 'ChatGPTUpdater-Background'
        TaskMarker = 'ChatGPTUpdater-owned-v1'
        TaskExisted = $TaskExisted
        TaskWasEnabled = $TaskWasEnabled
        TestMode = [bool]$TestMode
        Files = $files
    }
    if ($null -ne $PlanOverrides) { foreach ($key in $PlanOverrides.Keys) { $plan[[string]$key] = $PlanOverrides[$key] } }
    Write-TestJson -Path $planPath -Value $plan
    $pending = [ordered]@{
        Schema = $Schema
        TransactionId = if ($Schema -eq 2) { $transactionId } else { $null }
        Status = 'Pending'
        Version = $version.ToString()
        StartedUtc = [DateTime]::UtcNow.ToString('o')
        ParentPid = 0
        BackupRoot = $backup
        StagingRoot = $staging
        ResultPath = $resultPath
        PlanPath = if ($Schema -eq 2) { $planPath } else { $null }
        PendingPath = if ($Schema -eq 2) { $pendingPath } else { $null }
        OrdinaryLockPath = $ordinaryLockPath
        TaskExisted = $TaskExisted
        TaskWasEnabled = $TaskWasEnabled
    }
    if ($null -ne $PendingOverrides) { foreach ($key in $PendingOverrides.Keys) { $pending[[string]$key] = $PendingOverrides[$key] } }
    if ($CreatePending) { Write-TestJson -Path $pendingPath -Value $pending }
    $taskStatePath = Join-Path $caseRoot 'task.json'
    if (-not $TestMode) {
        $taskInitialState = if ($TaskWasEnabled) { 'Ready' } else { 'Disabled' }
        New-TaskState -Path $taskStatePath -Mode $TaskMode -State $taskInitialState -Present $TaskExisted -EnableMode $TaskEnableMode -RemovePendingMode $TaskRemovePendingMode | Out-Null
    }
    return [pscustomobject]@{
        Name = $Name; CaseRoot = $caseRoot; Staging = $staging; Backup = $backup; PlanPath = $planPath; PendingPath = $pendingPath
        ResultPath = $resultPath; LogPath = $logPath; LockPath = $lockPath; OrdinaryLockPath = $ordinaryLockPath; TaskStatePath = $taskStatePath
        Plan = $plan; Pending = $pending; OldFiles = $oldMap; NewFiles = $newMap; Names = @($orderedNames); UseTaskWrapper = (-not $TestMode)
    }
}

function Restore-TestPending {
    param([Parameter(Mandatory = $true)]$Fixture, [hashtable]$Overrides)
    $pending = $Fixture.Pending | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $pending.Status = 'Pending'
    if ($null -ne $Overrides) { foreach ($key in $Overrides.Keys) { $pending | Add-Member -NotePropertyName ([string]$key) -NotePropertyValue $Overrides[$key] -Force } }
    Write-TestJson -Path $Fixture.PendingPath -Value $pending
}

function Invoke-HelperFixture {
    param([Parameter(Mandatory = $true)]$Fixture, [switch]$Recover)
    $targetArgs = @('-PlanPath', $Fixture.PlanPath)
    if ($Recover) { $targetArgs += '-Recover' }
    $argsPath = Join-Path $Fixture.CaseRoot ('target-args-' + [guid]::NewGuid().ToString('N') + '.json')
    Write-TestJson -Path $argsPath -Value $targetArgs
    if ($Fixture.UseTaskWrapper) {
        return Invoke-TestChild -FilePath $script:Runtime -Arguments @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$script:TaskWrapperPath,'-TargetScript',$script:HelperPath,'-TaskStatePath',$Fixture.TaskStatePath,'-TargetArgsPath',$argsPath)
    }
    $helperArguments = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$script:HelperPath,'-PlanPath',$Fixture.PlanPath)
    if ($Recover) { $helperArguments += '-Recover' }
    return Invoke-TestChild -FilePath $script:Runtime -Arguments $helperArguments
}

function New-RecoveryPendingFromFixture {
    param([Parameter(Mandatory = $true)]$Fixture, [string]$TransactionId = $null, [string]$PlanPath = $null)
    $overrides = @{}
    if (-not [string]::IsNullOrWhiteSpace($TransactionId)) { $overrides.TransactionId = $TransactionId }
    if (-not [string]::IsNullOrWhiteSpace($PlanPath)) { $overrides.PlanPath = $PlanPath }
    Restore-TestPending -Fixture $Fixture -Overrides $overrides
}

function New-ReleaseFixture {
    param([string]$Name = 'apply')
    Reset-TestStableRoot
    foreach ($file in @($script:UtUpdaterFiles)) {
        $source = Join-Path $script:ProjectRoot $file
        $destination = Join-Path $script:StableRoot $file
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
    # The checkout may already contain the candidate VERSION.  Keep the
    # isolated deployed tree at the pre-update version so -Apply exercises the
    # staging/pending path independently of the repository's working version.
    Write-TestText -Path (Join-Path $script:StableRoot 'VERSION') -Text "0.2.0.1`r`n"
    $releaseRoot = Join-Path $script:FixtureRoot ('release-' + $Name + '-' + [guid]::NewGuid().ToString('N'))
    $filesRoot = Join-Path $releaseRoot 'files'
    $null = New-Item -ItemType Directory -Path $filesRoot -Force
    foreach ($file in @($script:UtUpdaterFiles)) {
        $source = Join-Path $script:ProjectRoot $file
        $destination = Join-Path $filesRoot $file
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
    Write-TestText -Path (Join-Path $filesRoot 'VERSION') -Text "0.2.0.2`r`n"
    $archive = Join-Path $releaseRoot 'release.zip'
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    [IO.Compression.ZipFile]::CreateFromDirectory($filesRoot, $archive, [IO.Compression.CompressionLevel]::Optimal, $false)
    $manifestFiles = @($script:UtUpdaterFiles | ForEach-Object { [ordered]@{ Name = $_; SHA256 = Get-TestHash -Path (Join-Path $filesRoot $_) } })
    $manifest = [ordered]@{
        Schema = 1
        Product = 'chatgpt-desktop-updater'
        Version = '0.2.0.2'
        MinimumVersion = '0.1.0.0'
        Archive = [ordered]@{ Url = 'https://github.com/ymt200120/chatgpt-desktop-updater-public/releases/download/v0.2.0.2/release.zip'; SHA256 = Get-TestHash -Path $archive }
        Files = $manifestFiles
    }
    $manifestPath = Join-Path $releaseRoot 'manifest.json'
    Write-TestJson -Path $manifestPath -Value $manifest
    return [pscustomobject]@{ ArchivePath = $archive; ManifestPath = $manifestPath; ReleaseRoot = $releaseRoot; StableVersion = '0.2.0.1' }
}

function Invoke-SelfUpdateFixture {
    param([Parameter(Mandatory = $true)]$Release, [switch]$Apply, [switch]$NoActivate, [string]$WrapperPath = $null)
    $entrySelfUpdate = Join-Path $script:StableRoot 'self-update.ps1'
    $arguments = @('-Apply')
    if (-not $Apply) { $arguments = @('-CheckOnly') }
    if ($NoActivate) { $arguments += '-NoActivate' }
    $arguments += @('-TestMode','-StableRoot',$script:StableRoot,'-ManifestPath',$Release.ManifestPath,'-ArchivePath',$Release.ArchivePath)
    if ([string]::IsNullOrWhiteSpace($WrapperPath)) {
        $selfUpdateArguments = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$entrySelfUpdate) + $arguments
        return Invoke-TestChild -FilePath $script:Runtime -Arguments $selfUpdateArguments
    }
    $argsPath = Join-Path $Release.ReleaseRoot 'self-update-args.json'
    Write-TestJson -Path $argsPath -Value $arguments
    return Invoke-TestChild -FilePath $script:Runtime -Arguments @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$WrapperPath,'-TargetScript',$entrySelfUpdate,'-TargetArgsPath',$argsPath)
}

function Invoke-SourceRollback {
    return Invoke-TestChild -FilePath $script:Runtime -Arguments @(
        '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$script:SelfUpdatePath,
        '-Rollback','-TestMode','-StableRoot',$script:StableRoot
    )
}

New-FiniteParentScript
New-TaskWrapper
New-ProbeWrapper
New-ProgressWrapper
New-FailureWrapper

Invoke-Case 'waiting helper observes durable cancellation and never activates after parent exit' {
    $fixture = New-HelperFixture -Name 'cancel-wait' -TestMode
    $parent = Start-TestChild -FilePath $script:Runtime -Arguments @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$script:SleepWrapperPath,'-Seconds','3')
    $plan = Read-TestJson -Path $fixture.PlanPath
    $plan.ParentPid = $parent.Process.Id
    Write-TestJson -Path $fixture.PlanPath -Value $plan
    $helper = Start-TestChild -FilePath $script:Runtime -Arguments @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$script:HelperPath,'-PlanPath',$fixture.PlanPath)
    Start-Sleep -Milliseconds 400
    $pending = Read-TestJson -Path $fixture.PendingPath
    $pending.Status = 'CancelRequested'
    Write-TestJson -Path $fixture.PendingPath -Value $pending
    $helperResult = Wait-TestChild -Child $helper -TimeoutSeconds 20
    $parentResult = Wait-TestChild -Child $parent -TimeoutSeconds 20
    Assert-Equal 0 $parentResult.Code 'finite parent process exits normally'
    Assert-Equal 0 $helperResult.Code 'cancelled waiting helper exits successfully'
    Assert-Equal '0.2.0.1' ([string](Get-Content -LiteralPath (Join-Path $script:StableRoot 'VERSION') -Raw)).Trim() 'cancelled helper never activates the staged VERSION'
    $planAfter = Read-TestJson -Path $fixture.PlanPath
    Assert-True ([string]$planAfter.Status -ne 'Activated') 'cancelled helper does not publish Activated'
}

Invoke-Case 'complete verified backup survives interrupted replacement and Recover restores original bytes' {
    $fixture = New-HelperFixture -Name 'interrupted-recover' -TestMode
    $stagedPayload = Join-Path $fixture.Staging 'payload.txt'
    $stagedLease = [IO.File]::Open($stagedPayload, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $helper = Invoke-HelperFixture -Fixture $fixture
        Assert-True ($helper.Code -ne 0) 'interrupted activation fails when the staged payload cannot be replaced'
    } finally {
        $stagedLease.Dispose()
    }
    Remove-TestPath -Path $fixture.Staging
    $manifestPath = Join-Path $fixture.Backup 'backup.json'
    Assert-True (Test-Path -LiteralPath $manifestPath -PathType Leaf) 'verified backup manifest survives interruption'
    Assert-True (Test-Path -LiteralPath (Join-Path $fixture.Backup 'recovery-ready.json') -PathType Leaf) 'recovery-ready marker survives interruption'
    Assert-Equal '0.2.0.2' ([string](Get-Content -LiteralPath (Join-Path $script:StableRoot 'VERSION') -Raw)).Trim() 'interrupted activation replaces VERSION before the locked payload fails'
    $recover = Invoke-HelperFixture -Fixture $fixture -Recover
    Assert-Equal 0 $recover.Code 'independent Recover succeeds from the complete backup'
    Assert-Equal '0.2.0.1' ([string](Get-Content -LiteralPath (Join-Path $script:StableRoot 'VERSION') -Raw)).Trim() 'Recover restores the original VERSION'
    Assert-Equal $fixture.OldFiles['payload.txt'] ([IO.File]::ReadAllText((Join-Path $script:StableRoot 'payload.txt'))) 'Recover restores original payload bytes'
    Assert-True (-not (Test-Path -LiteralPath $fixture.PendingPath -PathType Leaf)) 'successful Recover clears the matching pending marker'
}

Invoke-Case 'activation progress does not rewrite the sealed backup or its ready marker' {
    $fixture = New-HelperFixture -Name 'progress-seal' -TestMode
    $activated = Invoke-HelperFixture -Fixture $fixture
    Assert-Equal 0 $activated.Code 'fixture activation creates the recovery-ready record'
    $manifestPath = Join-Path $fixture.Backup 'backup.json'
    $readyPath = Join-Path $fixture.Backup 'recovery-ready.json'
    $manifestBefore = Get-TestBytesBase64 -Path $manifestPath
    $readyBefore = Get-TestBytesBase64 -Path $readyPath
    $progressResultPath = Join-Path $fixture.CaseRoot 'progress-result.json'
    $progress = Invoke-TestChild -FilePath $script:Runtime -Arguments @(
        '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$script:ProgressWrapperPath,
        '-SelfUpdateHelperPath',$script:HelperPath,'-PlanPath',$fixture.PlanPath,'-ResultPath',$progressResultPath
    )
    Assert-Equal 0 $progress.Code 'independent activation progress writer succeeds'
    Assert-True (Test-Path -LiteralPath (Join-Path $fixture.Backup 'activation-progress.json') -PathType Leaf) 'activation progress is persisted separately'
    Assert-Equal $manifestBefore (Get-TestBytesBase64 -Path $manifestPath) 'activation progress leaves backup.json bytes unchanged'
    Assert-Equal $readyBefore (Get-TestBytesBase64 -Path $readyPath) 'activation progress leaves recovery-ready bytes unchanged'
    New-RecoveryPendingFromFixture -Fixture $fixture
    $recover = Invoke-HelperFixture -Fixture $fixture -Recover
    Assert-Equal 0 $recover.Code 'Recover accepts the immutable sealed record after progress writes'
    $recoveryResult = Read-TestJson -Path $fixture.ResultPath
    Assert-Equal 'RolledBack' $recoveryResult.Status 'Recover publishes a rolled-back result'
    Assert-Equal '0.2.0.1' $recoveryResult.Version 'Recover result reports the actual old VERSION'
}

Invoke-Case 'Recover rejects a corrupt backup and retains pending state' {
    $fixture = New-HelperFixture -Name 'corrupt-backup' -TestMode
    $activated = Invoke-HelperFixture -Fixture $fixture
    Assert-Equal 0 $activated.Code 'fixture activation creates a recovery-ready backup'
    New-RecoveryPendingFromFixture -Fixture $fixture
    Write-TestText -Path (Join-Path $fixture.Backup 'payload.txt') -Text 'corrupted backup'
    $before = Get-TestHash -Path (Join-Path $script:StableRoot 'VERSION')
    $recover = Invoke-HelperFixture -Fixture $fixture -Recover
    Assert-True ($recover.Code -ne 0) 'corrupt backup is rejected'
    Assert-Equal $before (Get-TestHash -Path (Join-Path $script:StableRoot 'VERSION')) 'corrupt backup does not alter stable files'
    Assert-True (Test-Path -LiteralPath $fixture.PendingPath -PathType Leaf) 'corrupt backup retains pending state for inspection or retry'
}

Invoke-Case 'Recover rejects a missing backup and retains pending state' {
    $fixture = New-HelperFixture -Name 'missing-backup' -TestMode
    $activated = Invoke-HelperFixture -Fixture $fixture
    Assert-Equal 0 $activated.Code 'fixture activation creates a recovery-ready backup'
    New-RecoveryPendingFromFixture -Fixture $fixture
    Remove-Item -LiteralPath (Join-Path $fixture.Backup 'payload.txt') -Force
    $before = Get-TestHash -Path (Join-Path $script:StableRoot 'VERSION')
    $recover = Invoke-HelperFixture -Fixture $fixture -Recover
    Assert-True ($recover.Code -ne 0) 'missing backup is rejected'
    Assert-Equal $before (Get-TestHash -Path (Join-Path $script:StableRoot 'VERSION')) 'missing backup does not alter stable files'
    Assert-True (Test-Path -LiteralPath $fixture.PendingPath -PathType Leaf) 'missing backup retains pending state'
}

Invoke-Case 'partial recovery leaves pending and a retry restores and removes only the expected new file' {
    $fixture = New-HelperFixture -Name 'partial-retry' -TestMode -OldFiles ([ordered]@{ VERSION = "0.2.0.1`r`n" }) -NewFiles ([ordered]@{ VERSION = "0.2.0.2`r`n"; 'new.txt' = 'new file`r`n' })
    $activated = Invoke-HelperFixture -Fixture $fixture
    Assert-Equal 0 $activated.Code 'fixture activation creates an Existed=false recovery entry'
    New-RecoveryPendingFromFixture -Fixture $fixture
    Write-TestText -Path (Join-Path $script:StableRoot 'new.txt') -Text 'unexpected replacement'
    $partial = Invoke-HelperFixture -Fixture $fixture -Recover
    Assert-True ($partial.Code -ne 0) 'unexpected new-file bytes stop recovery'
    Assert-True (Test-Path -LiteralPath $fixture.PendingPath -PathType Leaf) 'partial recovery retains pending for retry'
    Assert-Equal '0.2.0.1' ([string](Get-Content -LiteralPath (Join-Path $script:StableRoot 'VERSION') -Raw)).Trim() 'partial recovery restores earlier files before the failing entry'
    Write-TestText -Path (Join-Path $script:StableRoot 'new.txt') -Text $fixture.NewFiles['new.txt']
    $retry = Invoke-HelperFixture -Fixture $fixture -Recover
    Assert-Equal 0 $retry.Code 'retry recovers after the unexpected file is corrected'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:StableRoot 'new.txt'))) 'retry deletes only the expected newly activated file'
    Assert-True (-not (Test-Path -LiteralPath $fixture.PendingPath -PathType Leaf)) 'successful retry clears pending'
}

Invoke-Case 'Recover with no pending marker refuses to write stable files' {
    $fixture = New-HelperFixture -Name 'recover-no-pending' -TestMode
    $activated = Invoke-HelperFixture -Fixture $fixture
    Assert-Equal 0 $activated.Code 'fixture activation creates a recovery-ready backup'
    $before = Get-TestStableSnapshot
    $recover = Invoke-HelperFixture -Fixture $fixture -Recover
    Assert-True ($recover.Code -ne 0) 'Recover without pending fails closed'
    Assert-Equal $before (Get-TestStableSnapshot) 'Recover without pending does not modify stable files'
}

Invoke-Case 'RecoveryRequired without pending retains a guard after partial recovery and retry clears it' {
    $fixture = New-HelperFixture -Name 'recover-no-pending-partial' -TestMode
    $activated = Invoke-HelperFixture -Fixture $fixture
    Assert-Equal 0 $activated.Code 'fixture activation creates a recovery-ready backup'
    $plan = Read-TestJson -Path $fixture.PlanPath
    $plan.Status = 'RecoveryRequired'
    Write-TestJson -Path $fixture.PlanPath -Value $plan
    Assert-True (-not (Test-Path -LiteralPath $fixture.PendingPath -PathType Leaf)) 'successful activation leaves no pending marker before recovery'
    Write-TestText -Path (Join-Path $script:StableRoot 'payload.txt') -Text 'unexpected recovery bytes'
    $partial = Invoke-HelperFixture -Fixture $fixture -Recover
    Assert-True ($partial.Code -ne 0) 'partial recovery without pending fails closed'
    Assert-Equal '0.2.0.1' ([string](Get-Content -LiteralPath (Join-Path $script:StableRoot 'VERSION') -Raw)).Trim() 'partial recovery restores VERSION before refusing the unexpected payload'
    Assert-Equal 'unexpected recovery bytes' ([IO.File]::ReadAllText((Join-Path $script:StableRoot 'payload.txt'))) 'partial recovery leaves the unexpected payload for inspection'
    $planAfterFailure = Read-TestJson -Path $fixture.PlanPath
    $resultAfterFailure = Read-TestJson -Path $fixture.ResultPath
    Assert-Equal 'RecoveryRequired' $planAfterFailure.Status 'partial recovery retains the RecoveryRequired plan guard'
    Assert-Equal 'RecoveryRequired' $resultAfterFailure.Status 'partial recovery retains the RecoveryRequired result guard'
    Assert-True (Test-Path -LiteralPath $fixture.PendingPath -PathType Leaf) 'partial recovery creates a pending guard for retry'
    $pendingAfterFailure = Read-TestJson -Path $fixture.PendingPath
    Assert-Equal $plan.TransactionId $pendingAfterFailure.TransactionId 'partial recovery guard binds to the original transaction'
    Assert-True ([string]$pendingAfterFailure.Status -in @('Pending','RecoveryRequired')) 'partial recovery guard remains recoverable'
    Write-TestText -Path (Join-Path $script:StableRoot 'payload.txt') -Text $fixture.NewFiles['payload.txt']
    $retry = Invoke-HelperFixture -Fixture $fixture -Recover
    Assert-Equal 0 $retry.Code 'retry succeeds after the unexpected payload is corrected'
    $planAfterRetry = Read-TestJson -Path $fixture.PlanPath
    $resultAfterRetry = Read-TestJson -Path $fixture.ResultPath
    Assert-Equal 'RolledBack' $planAfterRetry.Status 'successful retry clears the RecoveryRequired plan guard'
    Assert-Equal 'RolledBack' $resultAfterRetry.Status 'successful retry clears the RecoveryRequired result guard'
    Assert-Equal '0.2.0.1' $resultAfterRetry.Version 'successful retry reports the old VERSION'
    Assert-True (-not (Test-Path -LiteralPath $fixture.PendingPath -PathType Leaf)) 'successful retry clears the pending recovery guard'
}

Invoke-Case 'Recover with a different transaction pending performs zero stable writes' {
    $fixture = New-HelperFixture -Name 'recover-other-transaction' -TestMode
    $activated = Invoke-HelperFixture -Fixture $fixture
    Assert-Equal 0 $activated.Code 'fixture activation creates a recovery-ready backup'
    New-RecoveryPendingFromFixture -Fixture $fixture -TransactionId 'different-transaction'
    $before = Get-TestStableSnapshot
    $recover = Invoke-HelperFixture -Fixture $fixture -Recover
    Assert-True ($recover.Code -ne 0) 'different transaction is rejected'
    Assert-Equal $before (Get-TestStableSnapshot) 'different transaction cannot write stable files'
    Assert-True (Test-Path -LiteralPath $fixture.PendingPath -PathType Leaf) 'different transaction pending remains for its owner'
}

Invoke-Case 'stale helper with missing staging does not overwrite a shared result' {
    $fixture = New-HelperFixture -Name 'stale-result' -TestMode -CreateStaging:$false
    Write-TestJson -Path $fixture.ResultPath -Value ([ordered]@{ Status = 'SharedResult'; TransactionId = 'another-transaction'; Owner = 'another-transaction' })
    $stalePending = Read-TestJson -Path $fixture.PendingPath
    $stalePending.TransactionId = 'another-transaction'
    $stalePending.PlanPath = Join-Path $fixture.CaseRoot 'another-plan.json'
    Write-TestJson -Path $fixture.PendingPath -Value $stalePending
    $before = [IO.File]::ReadAllText($fixture.ResultPath, [Text.Encoding]::UTF8)
    $run = Invoke-HelperFixture -Fixture $fixture
    Assert-True ($run.Code -ne 0) 'stale helper fails when its staging directory is gone'
    Assert-Equal $before ([IO.File]::ReadAllText($fixture.ResultPath, [Text.Encoding]::UTF8)) 'stale helper preserves the shared result file'
    Assert-Equal '0.2.0.1' ([string](Get-Content -LiteralPath (Join-Path $script:StableRoot 'VERSION') -Raw)).Trim() 'stale helper does not touch stable files'
}

Invoke-Case 'legacy empty Schema1 pending does not match an arbitrary plan' {
    $fixture = New-HelperFixture -Name 'legacy-empty-pending' -TestMode -Schema 1
    Write-TestJson -Path $fixture.PendingPath -Value ([ordered]@{ Schema = 1 })
    $run = Invoke-HelperFixture -Fixture $fixture
    Assert-True ($run.Code -ne 0 -or ([string](Get-Content -LiteralPath (Join-Path $script:StableRoot 'VERSION') -Raw)).Trim() -ne '0.2.0.2') 'empty Schema1 pending cannot authorize activation'
    Assert-Equal '0.2.0.1' ([string](Get-Content -LiteralPath (Join-Path $script:StableRoot 'VERSION') -Raw)).Trim() 'empty Schema1 pending leaves stable files unchanged'
}

Invoke-Case 'legacy Schema1 plan with a confirmed missing task remains compatible' {
    $fixture = New-HelperFixture -Name 'legacy-missing-task' -TestMode:$false -Schema 1 -TaskExisted:$false -TaskWasEnabled:$false -TaskMode notfound
    $run = Invoke-HelperFixture -Fixture $fixture
    Assert-Equal 0 $run.Code 'legacy plan with a truly absent task activates successfully'
    Assert-Equal '0.2.0.2' ([string](Get-Content -LiteralPath (Join-Path $script:StableRoot 'VERSION') -Raw)).Trim() 'legacy plan activates the staged VERSION'
    Assert-True (-not (Test-Path -LiteralPath $fixture.PendingPath -PathType Leaf)) 'legacy activation removes the matching pending marker'
}

Invoke-Case 'task RPC query failures fail closed before activation' {
    $fixture = New-HelperFixture -Name 'task-rpc-fail-closed' -TestMode:$false -TaskExisted:$true -TaskWasEnabled:$true -TaskMode rpc
    $before = Get-TestHash -Path (Join-Path $script:StableRoot 'VERSION')
    $run = Invoke-HelperFixture -Fixture $fixture
    Assert-True ($run.Code -ne 0) 'RPC task query failure is surfaced'
    Assert-Equal $before (Get-TestHash -Path (Join-Path $script:StableRoot 'VERSION')) 'RPC task query failure prevents activation'
}

Invoke-Case 'query failure after Disable restores the original task state' {
    $taskPath = Join-Path $script:FixtureRoot ('probe-task-' + [guid]::NewGuid().ToString('N') + '.json')
    New-TaskState -Path $taskPath -Mode ok -State Ready -Present $true -AfterDisableMode rpc | Out-Null
    $resultPath = Join-Path $script:FixtureRoot ('probe-result-' + [guid]::NewGuid().ToString('N') + '.json')
    $probe = Invoke-TestChild -FilePath $script:Runtime -Arguments @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$script:ProbeWrapperPath,'-SelfUpdatePath',$script:SelfUpdatePath,'-TaskStatePath',$taskPath,'-ResultPath',$resultPath,'-GuardRoot',$script:FixtureRoot)
    $probeState = Read-TestJson -Path $resultPath
    $taskState = Read-TestJson -Path $taskPath
    Assert-Equal 'Failed' $probeState.Status 'query failure after disable is surfaced'
    if ([string]$taskState.State -eq 'Disabled') {
        $guardPath = Join-Path $script:FixtureRoot 'task-query-guard.json'
        Assert-True (Test-Path -LiteralPath $guardPath -PathType Leaf) 'query failure after disable leaves an observable recovery guard'
        $guard = Read-TestJson -Path $guardPath
        Assert-True ([string]$guard.Status -eq 'RecoveryRequired' -or [string]$guard.Action -match '(?i)re-enable|recovery') 'query failure guard requires task recovery'
    }
    Assert-True ($probe.Code -ne 0) 'task probe returns failure for the query exception'
}

Invoke-Case 'preactivation helper error restores a task disabled by the parent' {
    $fixture = New-HelperFixture -Name 'preactivation-task-restore' -TestMode:$false -TaskExisted:$true -TaskWasEnabled:$true -TaskMode ok
    $task = Read-TestJson -Path $fixture.TaskStatePath
    $task.State = 'Disabled'
    Write-TestJson -Path $fixture.TaskStatePath -Value $task
    $promptLock = Join-Path $script:LocalAppData 'ChatGPTUpdater\background-prompt.lock'
    Write-TestText -Path $promptLock -Text 'held by fixture'
    $promptLockStream = [IO.File]::Open($promptLock, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $run = Invoke-HelperFixture -Fixture $fixture
        Assert-True ($run.Code -ne 0) 'prompt-lock preactivation failure is surfaced'
        $after = Read-TestJson -Path $fixture.TaskStatePath
        Assert-True ([string]$after.State -ne 'Disabled') 'preactivation failure restores the task state'
        Assert-Equal '0.2.0.1' ([string](Get-Content -LiteralPath (Join-Path $script:StableRoot 'VERSION') -Raw)).Trim() 'preactivation failure does not activate files'
    } finally {
        if ($null -ne $promptLockStream) { $promptLockStream.Dispose() }
        Remove-TestPath -Path $promptLock
    }
}

Invoke-Case 'task re-enable failure after activation retains RecoveryRequired and never publishes Activated' {
    $fixture = New-HelperFixture -Name 'enable-failure-after-activation' -TestMode:$false -TaskExisted:$true -TaskWasEnabled:$true -TaskMode ok -TaskEnableMode fail
    $taskBefore = Read-TestJson -Path $fixture.TaskStatePath
    $taskBefore.State = 'Disabled'
    Write-TestJson -Path $fixture.TaskStatePath -Value $taskBefore
    $run = Invoke-HelperFixture -Fixture $fixture
    Assert-True ($run.Code -ne 0) 'task re-enable failure is surfaced'
    $plan = Read-TestJson -Path $fixture.PlanPath
    $result = Read-TestJson -Path $fixture.ResultPath
    $pending = Read-TestJson -Path $fixture.PendingPath
    $task = Read-TestJson -Path $fixture.TaskStatePath
    Assert-Equal 'RecoveryRequired' $plan.Status 'task re-enable failure leaves the plan recoverable'
    Assert-Equal 'RecoveryRequired' $result.Status 'task re-enable failure publishes a recovery result'
    Assert-True ([string]$result.Status -ne 'Activated') 'task re-enable failure cannot publish Activated'
    Assert-True (Test-Path -LiteralPath $fixture.PendingPath -PathType Leaf) 'task re-enable failure retains the pending guard'
    Assert-True ([string]$pending.Status -in @('Pending','RecoveryRequired')) 'task re-enable failure retains a recoverable pending status'
    Assert-Equal 'Disabled' $task.State 'failed re-enable leaves the task disabled for recovery'
}

Invoke-Case 'pending deletion failure after activation retains RecoveryRequired and never publishes Activated' {
    $fixture = New-HelperFixture -Name 'pending-delete-failure' -TestMode:$false -TaskExisted:$true -TaskWasEnabled:$false -TaskMode ok -TaskRemovePendingMode fail
    $run = Invoke-HelperFixture -Fixture $fixture
    Assert-True ($run.Code -ne 0) 'pending deletion failure is surfaced'
    $plan = Read-TestJson -Path $fixture.PlanPath
    $result = Read-TestJson -Path $fixture.ResultPath
    $pending = Read-TestJson -Path $fixture.PendingPath
    Assert-Equal 'RecoveryRequired' $plan.Status 'pending deletion failure leaves the plan recoverable'
    Assert-Equal 'RecoveryRequired' $result.Status 'pending deletion failure publishes a recovery result'
    Assert-True ([string]$result.Status -ne 'Activated') 'pending deletion failure cannot publish Activated'
    Assert-True (Test-Path -LiteralPath $fixture.PendingPath -PathType Leaf) 'pending deletion failure retains the pending guard'
    Assert-True ([string]$pending.Status -in @('Pending','RecoveryRequired')) 'pending deletion failure retains a recoverable pending status'
}

Invoke-Case 'Rollback with a missing recovery backup retains pending RecoveryRequired state' {
    $fixture = New-HelperFixture -Name 'rollback-missing-backup' -TestMode
    $activated = Invoke-HelperFixture -Fixture $fixture
    Assert-Equal 0 $activated.Code 'fixture activation creates a recovery-ready backup'
    $plan = Read-TestJson -Path $fixture.PlanPath
    $plan.Status = 'RecoveryRequired'
    Write-TestJson -Path $fixture.PlanPath -Value $plan
    New-RecoveryPendingFromFixture -Fixture $fixture
    $pending = Read-TestJson -Path $fixture.PendingPath
    $pending.Status = 'RecoveryRequired'
    Write-TestJson -Path $fixture.PendingPath -Value $pending
    Remove-TestPath -Path $fixture.Backup
    $rollback = Invoke-SourceRollback
    Assert-True ($rollback.Code -ne 0) 'Rollback refuses a missing recovery backup'
    $pendingAfter = Read-TestJson -Path $fixture.PendingPath
    $planAfter = Read-TestJson -Path $fixture.PlanPath
    Assert-Equal 'RecoveryRequired' $pendingAfter.Status 'missing recovery backup retains pending RecoveryRequired state'
    Assert-Equal 'RecoveryRequired' $planAfter.Status 'missing recovery backup retains plan RecoveryRequired state'
    Assert-True ([string]$pendingAfter.Status -ne 'Cancelled') 'missing recovery backup cannot become Cancelled'
    Assert-True ([string]$planAfter.Status -ne 'Cancelled') 'missing recovery backup cannot mark the plan Cancelled'
}

Invoke-Case 'Rollback rejects a schema2 pending marker whose explicit PlanPath is missing' {
    $fixture = New-HelperFixture -Name 'rollback-missing-explicit-plan' -TestMode
    $activated = Invoke-HelperFixture -Fixture $fixture
    Assert-Equal 0 $activated.Code 'fixture activation creates a recovery-ready backup'
    $plan = Read-TestJson -Path $fixture.PlanPath
    $plan.Status = 'RecoveryRequired'
    Write-TestJson -Path $fixture.PlanPath -Value $plan
    $missingPlanPath = Join-Path $fixture.CaseRoot 'missing-explicit-plan.json'
    New-RecoveryPendingFromFixture -Fixture $fixture -PlanPath $missingPlanPath
    $pending = Read-TestJson -Path $fixture.PendingPath
    $pending.Status = 'RecoveryRequired'
    Write-TestJson -Path $fixture.PendingPath -Value $pending
    $before = Get-TestStableSnapshot
    $rollback = Invoke-SourceRollback
    Assert-True ($rollback.Code -ne 0) 'Rollback rejects a missing explicit schema2 PlanPath'
    $pendingAfter = Read-TestJson -Path $fixture.PendingPath
    $planAfter = Read-TestJson -Path $fixture.PlanPath
    Assert-Equal $missingPlanPath $pendingAfter.PlanPath 'Rollback preserves the missing explicit PlanPath'
    Assert-Equal 'RecoveryRequired' $pendingAfter.Status 'missing explicit PlanPath retains pending RecoveryRequired state'
    Assert-Equal 'RecoveryRequired' $planAfter.Status 'Rollback does not fall back to the decoy plan'
    Assert-Equal $before (Get-TestStableSnapshot) 'missing explicit PlanPath performs no stable writes'
}

Invoke-Case 'ordinary update.lock excludes Apply before staging' {
    $release = New-ReleaseFixture -Name 'ordinary-lock'
    $lockPath = Join-Path $script:LocalAppData 'ChatGPTUpdater\update.lock'
    $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $run = Invoke-SelfUpdateFixture -Release $release -Apply -NoActivate
        Assert-Equal 8 $run.Code 'ordinary update lock blocks Apply'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:StableRoot 'self-update.pending.json') -PathType Leaf)) 'ordinary lock failure does not publish pending'
    } finally { $lock.Dispose() }
}

Invoke-Case 'pending guard runs after coordination lock and blocks a second Apply' {
    $release = New-ReleaseFixture -Name 'pending-guard'
    $pendingPath = Join-Path $script:StableRoot 'self-update.pending.json'
    Write-TestJson -Path $pendingPath -Value ([ordered]@{ Schema = 2; TransactionId = 'existing'; Status = 'Pending' })
    try {
        $run = Invoke-SelfUpdateFixture -Release $release -Apply -NoActivate
        Assert-Equal 8 $run.Code 'pending guard blocks a second Apply'
        Assert-True (Test-Path -LiteralPath $pendingPath -PathType Leaf) 'pending guard preserves the existing marker'
    } finally { Remove-TestPath -Path $pendingPath }
}

Invoke-Case 'pending publication followed by helper-copy failure leaves no ordinary pending block' {
    $release = New-ReleaseFixture -Name 'copy-helper-failure'
    $run = Invoke-SelfUpdateFixture -Release $release -Apply -WrapperPath $script:FailureWrapperPath
    Assert-True ($run.Code -ne 0) 'injected helper-copy failure is surfaced'
    Assert-Equal $release.StableVersion ([string](Get-Content -LiteralPath (Join-Path $script:StableRoot 'VERSION') -Raw)).Trim() 'helper-copy failure does not activate stable files'
    $pendingPath = Join-Path $script:StableRoot 'self-update.pending.json'
    if (Test-Path -LiteralPath $pendingPath -PathType Leaf) {
        $pending = Read-TestJson -Path $pendingPath
        Assert-True ([string]$pending.Status -ne 'Pending') 'helper-copy failure cannot leave an ordinary Pending block'
    }
}

$env:LOCALAPPDATA = $script:OriginalLocalAppData
Write-Host ''
if ($script:TestFailed -eq 0) {
    Write-Host ('All {0} self-update recovery test cases passed.' -f $script:TestTotal) -ForegroundColor Green
    if (-not $KeepTemp) { Remove-TestPath -Path $script:IsolatedRoot }
    exit 0
}
Write-Host ('{0} of {1} self-update recovery test cases had failures.' -f $script:TestFailed, $script:TestTotal) -ForegroundColor Red
Write-Host ('Isolated evidence kept at: ' + $script:IsolatedRoot)
exit 1
