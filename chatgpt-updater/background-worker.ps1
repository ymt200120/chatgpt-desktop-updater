#requires -Version 5.1
<##
    Scheduled worker.  A worker can query HEAD and prepare a fully validated
    package, but it has no install path.  Only confirm-install.ps1, after the
    user clicks its explicit button, may call Invoke-UtConfirmedInstall.
##>
[CmdletBinding()]
param(
    [ValidateSet('Run','Prepare','Remind')][string]$Mode = 'Run',
    [ValidateSet(1,4,8,16)][int]$Connections = 8,
    [string]$StateRoot,
    [string]$CorePath,
    [switch]$TestMode,
    [ValidateSet('Install','Later','Timeout','Cancel','X','Esc')][string]$PromptChoice,
    [switch]$NoPrompt,
    [datetime]$Now = [datetime]::MinValue
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($CorePath)) { $CorePath = Join-Path $PSScriptRoot 'update-chatgpt.ps1' }
$script:UbWorkerCorePath = [IO.Path]::GetFullPath($CorePath)
. (Join-Path $PSScriptRoot 'background-common.ps1') -CorePath $CorePath

function Get-UbWorkerMetadata {
    param([Parameter(Mandatory = $true)][string]$Architecture)
    $base = 'https://persistent.oaistatic.com/codex-app-prod'
    $uri = '{0}/ChatGPT-{1}.msix' -f $base, $Architecture
    $head = Invoke-UtHeadRequest -Uri $uri
    return (Get-UtRemoteMetadata -HeadResult $head -Architecture $Architecture -RequestedUri $uri)
}

function Get-UbWorkerInstalled {
    try { return Get-UtInstalledPackage } catch { throw "Installed package query failed: $($_.Exception.Message)" }
}

function Get-UbWorkerState {
    param([string]$Root)
    $lock = $null
    try {
        $lock = Enter-UbStateLock -Root $Root
        try { return Read-UbState -Root $Root }
        catch {
            # A torn or hand-edited state file is unknown state. Preserve it
            # as bounded diagnostic evidence, then restart with an empty
            # journal; cache files are never touched by this recovery.
            $statePath = Get-UbStatePath -Root $Root
            if (Test-Path -LiteralPath $statePath -PathType Leaf) {
                $item = Get-Item -LiteralPath $statePath -Force -ErrorAction Stop
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -gt $script:UbMaxStateBytes) { throw }
                $backup = Join-Path (Get-UbRoot -Root $Root) ('.background-state.corrupt.' + [guid]::NewGuid().ToString('N') + '.json')
                Move-Item -LiteralPath $statePath -Destination $backup -Force -ErrorAction Stop
            }
            $empty = New-UbEmptyState
            $null = Write-UbState -State $empty -Root $Root
            Write-UbLog -Root $Root -Message 'Corrupt background state was quarantined; starting with an empty state.'
            return $empty
        }
    }
    finally { if ($null -ne $lock) { $lock.Dispose() } }
}

function Invoke-UbPromptIfDue {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][switch]$TestMode,
        [string]$PromptChoice,
        [switch]$NoPrompt,
        [datetime]$PromptNow = [datetime]::MinValue
    )
    $candidate = Get-UbProperty $State 'Candidate'
    if ($null -eq $candidate -or -not (Test-UbReminderDue -State $State -Now $PromptNow)) { return [pscustomobject]@{ Status = 'NotDue'; Code = 0; Message = 'No reminder is due.' } }
    if ($NoPrompt) { return [pscustomobject]@{ Status = 'Ready'; Code = 0; Message = 'Ready candidate retained; prompting was disabled.' } }
    $promptPath = Join-Path $PSScriptRoot 'confirm-install.ps1'
    if ($TestMode) {
        # Test mode keeps the prompt boundary in-process and isolated. It
        # never starts a real UI or calls Add-AppxPackage.
        if ($PromptChoice -eq 'Install') {
            $null = Clear-UbCandidate -Root $Root -Message 'TEST/MOCK install authorized for the isolated fixture.'
            return [pscustomobject]@{ Status = 'Installed'; Code = 0; Message = 'TEST/MOCK: installation verified successfully.' }
        }
        $null = Set-UbSnooze -Root $Root -Now $PromptNow
        return [pscustomobject]@{ Status = 'Snoozed'; Code = 0; Message = 'TEST/MOCK: no installation was authorized.'; Choice = if ([string]::IsNullOrWhiteSpace($PromptChoice)) { 'Later' } else { $PromptChoice } }
    }
    if (-not (Test-UbCanShowPrompt)) {
        Write-UbLog -Root $Root -Message 'Interactive desktop is unavailable or locked; retaining Ready candidate.'
        return [pscustomobject]@{ Status = 'Ready'; Code = 0; Message = 'Interactive desktop unavailable; candidate retained.' }
    }
    try {
        $args = @{
            ScriptPath = $promptPath
            Root = $Root
            ExpectedKey = [string]$candidate.Key
            ExpectedVersion = [string]$candidate.Version
            CorePath = $script:UbWorkerCorePath
        }
        if ($TestMode) { $args.TestMode = $true }
        if (-not [string]::IsNullOrWhiteSpace($PromptChoice)) { $args.TestChoice = $PromptChoice }
        $process = Start-UbPromptDetached @args
        Write-UbLog -Root $Root -Message ("Confirmation prompt launched for key {0}." -f $candidate.Key)
        return [pscustomobject]@{ Status = 'Prompted'; Code = 0; Message = 'Confirmation prompt launched.'; ProcessId = $process.Id }
    } catch {
        Write-UbLog -Root $Root -Message ("Confirmation prompt launch failed: {0}" -f $_.Exception.Message)
        $null = Set-UbFailure -Root $Root -Now $PromptNow -Message ('Prompt launch failed: ' + $_.Exception.Message)
        return [pscustomobject]@{ Status = 'Ready'; Code = 1; Message = 'Prompt launch failed; Ready candidate retained.' }
    }
}

function Invoke-UbPrepareCandidate {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$Architecture,
        [Parameter(Mandatory = $true)][version]$WindowsVersion,
        [Parameter(Mandatory = $true)][string]$Root,
        [ValidateSet(1,4,8,16)][int]$Connections = 8,
        [datetime]$PrepareNow = [datetime]::MinValue
    )
    $updateLock = $null
    $prepared = $null
    try {
        # The core API requires this caller-held lock.  It is released before
        # state publication and before any prompt is launched.
        $updateLock = Enter-UtLock
        $prepared = Get-UtPreparedCandidate -Metadata $Metadata -Architecture $Architecture -WindowsVersion $WindowsVersion -Connections $Connections -Background
    } finally { if ($null -ne $updateLock) { $updateLock.Dispose() } }
    if ($null -eq $prepared) { throw 'The core did not return a prepared candidate.' }
    $prepared = @($prepared) | Select-Object -Last 1
    $path = [string](Get-UbProperty $prepared 'Path')
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'The prepared candidate path is missing.' }
    $preparedMetadata = Get-UbProperty $prepared 'Metadata'
    if ($null -eq $preparedMetadata) { $preparedMetadata = $Metadata }
    $candidate = ConvertTo-UbCandidateFromPrepared -Prepared $prepared -Metadata $preparedMetadata -Architecture $Architecture
    $null = Set-UbCandidate -Root $Root -Candidate $candidate -Now $PrepareNow
    Write-UbLog -Root $Root -Message ("Prepared Ready candidate {0} ({1})." -f $candidate.Key, $candidate.Version)
    return [pscustomobject]@{ Status = 'Ready'; Code = 0; Candidate = $candidate; Prepared = $prepared; Message = 'Candidate prepared and published.' }
}

function Invoke-UbBackgroundWorker {
    [CmdletBinding()]
    param(
        [ValidateSet('Run','Prepare','Remind')][string]$WorkerMode = 'Run',
        [ValidateSet(1,4,8,16)][int]$WorkerConnections = 8,
        [string]$WorkerStateRoot,
        [switch]$WorkerTestMode,
        [string]$WorkerPromptChoice,
        [switch]$WorkerNoPrompt,
        [datetime]$WorkerNow = [datetime]::MinValue
    )
    $root = Get-UbRoot -Root $WorkerStateRoot
    $nowValue = Get-UbNowUtc $WorkerNow
    try {
        $state = Get-UbWorkerState -Root $root
        $candidate = Get-UbProperty $state 'Candidate'
        if ($null -ne $candidate -and [string](Get-UbProperty $state 'LastMessage') -eq 'Deferred') {
            # The previous confirmed install succeeded but Windows deferred the
            # registration because the package was in use.  Observe the next
            # launch even when the seven-day HEAD interval is not due.
            try {
                $deferredInstalled = Get-UbWorkerInstalled
                if ($null -ne $deferredInstalled -and (Compare-UtVersion -A $deferredInstalled.Version -B ([version]$candidate.Version)) -ge 0) {
                    $null = Clear-UbCandidate -Root $root -Message 'Deferred update completed; installed package is current.'
                    Write-UbLog -Root $root -Message ("Deferred update completed; registered version {0}." -f $deferredInstalled.Version)
                    return [pscustomobject]@{ Status = 'AlreadyCurrent'; Code = 0; Message = 'Deferred update completed; installed package is current.'; Version = $deferredInstalled.Version }
                }
            } catch {
                Write-UbLog -Root $root -Message ('Deferred registration verification query failed; candidate retained: ' + $_.Exception.Message)
            }
        }
        if ($WorkerMode -eq 'Remind') {
            return Invoke-UbPromptIfDue -State $state -Root $root -TestMode:$WorkerTestMode -PromptChoice $WorkerPromptChoice -NoPrompt:$WorkerNoPrompt -PromptNow $nowValue
        }

        if ($null -ne $candidate -and $WorkerMode -eq 'Run' -and -not (Test-UbDueForCheck -State $state -Now $nowValue)) {
            return Invoke-UbPromptIfDue -State $state -Root $root -TestMode:$WorkerTestMode -PromptChoice $WorkerPromptChoice -NoPrompt:$WorkerNoPrompt -PromptNow $nowValue
        }
        if ($WorkerMode -eq 'Run' -and $null -eq $candidate -and -not (Test-UbDueForCheck -State $state -Now $nowValue)) {
            return [pscustomobject]@{ Status = 'NotDue'; Code = 0; Message = 'Seven-day HEAD interval has not elapsed.' }
        }

        $architecture = Get-UtNativeArchitecture
        $windowsVersion = Get-UtWindowsVersion
        $installed = Get-UbWorkerInstalled
        $metadata = $null
        try {
            $metadata = Get-UbWorkerMetadata -Architecture $architecture
            $null = Set-UbHeadSuccess -Root $root -Now $nowValue
        } catch {
            $null = Set-UbFailure -Root $root -Now $nowValue -Message ('HEAD check failed: ' + $_.Exception.Message)
            Write-UbLog -Root $root -Message ('HEAD check failed: ' + $_.Exception.Message)
            return [pscustomobject]@{ Status = 'Failed'; Code = 4; Message = $_.Exception.Message }
        }

        if ($null -ne $installed -and (Compare-UtVersion -A $installed.Version -B $metadata.Version) -ge 0) {
            if ($null -ne $candidate) { $null = Clear-UbCandidate -Root $root -Message 'Installed package is already current; Ready candidate cleared.' }
            return [pscustomobject]@{ Status = 'AlreadyCurrent'; Code = 0; Message = 'Installed package is current or newer.'; Version = $installed.Version }
        }

        if ($null -ne $candidate) {
            $snapshot = ConvertTo-UbMetadataSnapshot -Metadata $metadata -Architecture $architecture
            if (([string]$candidate.Version -eq [string]$metadata.Version) -and (Test-UbSnapshotMatch -A $candidate.Snapshot -B $snapshot)) {
                if ($WorkerMode -eq 'Prepare') { return [pscustomobject]@{ Status = 'Ready'; Code = 0; Message = 'Matching Ready candidate retained.'; Candidate = $candidate } }
                $state = Get-UbWorkerState -Root $root
                return Invoke-UbPromptIfDue -State $state -Root $root -TestMode:$WorkerTestMode -PromptChoice $WorkerPromptChoice -NoPrompt:$WorkerNoPrompt -PromptNow $nowValue
            }
            $null = Clear-UbCandidate -Root $root -Message 'Remote snapshot changed; previous Ready candidate discarded.'
            $candidate = $null
        }
        if ($WorkerMode -eq 'Remind') { return [pscustomobject]@{ Status = 'NotDue'; Code = 0; Message = 'No Ready candidate.' } }

        try {
            $result = Invoke-UbPrepareCandidate -Metadata $metadata -Architecture $architecture -WindowsVersion $windowsVersion -Root $root -Connections $WorkerConnections -PrepareNow $nowValue
        } catch {
            $null = Set-UbFailure -Root $root -Now $nowValue -HeadSucceeded -Message ('Prepare failed: ' + $_.Exception.Message)
            Write-UbLog -Root $root -Message ('Prepare failed; HEAD success is retained for the seven-day check only: ' + $_.Exception.Message)
            return [pscustomobject]@{ Status = 'Failed'; Code = 6; Message = $_.Exception.Message }
        }
        if ($WorkerNoPrompt) { return $result }
        $state = Get-UbWorkerState -Root $root
        return Invoke-UbPromptIfDue -State $state -Root $root -TestMode:$WorkerTestMode -PromptChoice $WorkerPromptChoice -NoPrompt:$WorkerNoPrompt -PromptNow $nowValue
    } catch {
        $message = $_.Exception.Message
        try { $null = Set-UbFailure -Root $root -Now $nowValue -Message ('Background worker failed: ' + $message) } catch { }
        Write-UbLog -Root $root -Message ('Background worker failed; retry is delayed: ' + $message)
        return [pscustomobject]@{ Status = 'Failed'; Code = 1; Message = $message }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-UbBackgroundWorker -WorkerMode $Mode -WorkerConnections $Connections -WorkerStateRoot $StateRoot -WorkerTestMode:$TestMode -WorkerPromptChoice $PromptChoice -WorkerNoPrompt:$NoPrompt -WorkerNow $Now
    if ($null -ne $result) { $result | ConvertTo-Json -Depth 8 -Compress }
    exit ([int](Get-UbProperty $result 'Code'))
}
