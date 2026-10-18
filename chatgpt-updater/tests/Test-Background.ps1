#requires -Version 5.1
[CmdletBinding()]
param([switch]$KeepTemp)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:OriginalLocalAppData = $env:LOCALAPPDATA
$script:FixtureRoot = Join-Path $env:TEMP ('ChatGPTUpdater-background-test [' + [guid]::NewGuid().ToString('N') + ']')
$script:StateRoot = Join-Path $script:FixtureRoot 'state'
$null = New-Item -ItemType Directory -Path $script:StateRoot -Force
$env:LOCALAPPDATA = Join-Path $script:FixtureRoot 'local data [中文]'

$script:TestTotal = 0
$script:TestFailed = 0
function Assert-True { param([bool]$Value,[string]$Message) if (-not $Value) { throw $Message } }
function Assert-Equal { param($Expected,$Actual,[string]$Message) if ([string]$Expected -cne [string]$Actual) { throw "$Message (expected '$Expected', got '$Actual')" } }
function Invoke-Case {
    param([string]$Name,[scriptblock]$Body)
    $script:TestTotal++
    try { & $Body; Write-Host ("PASS {0}" -f $Name) -ForegroundColor Green }
    catch { $script:TestFailed++; Write-Host ("FAIL {0}: {1}" -f $Name,$_.Exception.Message) -ForegroundColor Red }
}

. (Join-Path $script:ProjectRoot 'background-common.ps1') -CorePath (Join-Path $script:ProjectRoot 'update-chatgpt.ps1')

function New-TestMetadata {
    param([string]$Version = '26.930.7945.0', [string]$ETag = '"stable"')
    return [pscustomobject]@{
        Architecture = 'x64'
        Version = $Version
        ContentLength = [int64]4096
        ETag = $ETag
        Url = 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix'
    }
}

function New-TestCandidate {
    param([string]$Version = '26.930.7945.0', [string]$ETag = '"stable"')
    $metadata = New-TestMetadata -Version $Version -ETag $ETag
    $snapshot = ConvertTo-UbMetadataSnapshot -Metadata $metadata -Architecture x64 -SHA256 ('A' * 64)
    return New-UbCandidate -Key ('x64-' + ($Version -replace '\.','-') + '-4096') -Version $Version -Snapshot $snapshot
}

Invoke-Case 'HEAD metadata snapshots normalize optional SHA256 audit values' {
    $metadata = New-TestMetadata
    $omitted = ConvertTo-UbMetadataSnapshot -Metadata $metadata -Architecture x64
    $explicitNull = ConvertTo-UbMetadataSnapshot -Metadata $metadata -Architecture x64 -SHA256 $null
    $empty = ConvertTo-UbMetadataSnapshot -Metadata $metadata -Architecture x64 -SHA256 ''
    foreach ($snapshot in @($omitted, $explicitNull, $empty)) {
        Assert-True ($null -eq (Get-UbProperty $snapshot 'SHA256')) 'omitted, null, and empty SHA256 values normalize to null'
    }

    $lower = ConvertTo-UbMetadataSnapshot -Metadata $metadata -Architecture x64 -SHA256 ('ab' * 32)
    Assert-Equal ('AB' * 32) $lower.SHA256 'valid SHA256 values are normalized to uppercase'

    foreach ($invalid in @(' ', 'not-a-hash', ('A' * 63), ('G' * 64))) {
        $rejected = $false
        try { $null = ConvertTo-UbMetadataSnapshot -Metadata $metadata -Architecture x64 -SHA256 $invalid } catch { $rejected = $true }
        Assert-True $rejected ("nonempty invalid SHA256 value '{0}' is rejected" -f $invalid)
    }
}

Invoke-Case 'Ready candidate parsing and publication require a computed SHA256 audit value' {
    foreach ($invalid in @($null, '', 'not-a-hash', ('A' * 63), ('G' * 64))) {
        $snapshot = ConvertTo-UbMetadataSnapshot -Metadata (New-TestMetadata) -Architecture x64 -SHA256 ('A' * 64)
        $snapshot.SHA256 = $invalid
        $candidate = New-UbCandidate -Key 'x64-26-930-7945-0-4096' -Version '26.930.7945.0' -Snapshot $snapshot
        $rejected = $false
        try { $null = Assert-UbCandidate $candidate } catch { $rejected = $true }
        Assert-True $rejected ("stored candidate SHA256 value '{0}' is rejected" -f $invalid)
    }

    $missingSnapshot = ConvertTo-UbMetadataSnapshot -Metadata (New-TestMetadata) -Architecture x64
    $missingCandidate = New-UbCandidate -Key 'x64-26-930-7945-0-4096' -Version '26.930.7945.0' -Snapshot $missingSnapshot
    $publishRejected = $false
    try { $null = Set-UbCandidate -Root (Join-Path $script:FixtureRoot 'candidate-missing-sha') -Candidate $missingCandidate } catch { $publishRejected = $true }
    Assert-True $publishRejected 'candidate publication rejects a snapshot without a computed SHA256 value'
}

Invoke-Case 'state is atomic, versioned, and stores no trusted path' {
    $root = Join-Path $script:FixtureRoot 'state atomic'
    $candidate = New-TestCandidate
    $state = Set-UbCandidate -Root $root -Candidate $candidate
    Assert-Equal 1 $state.Schema 'schema version'
    $raw = Get-Content -Raw -LiteralPath (Get-UbStatePath $root)
    Assert-True ($raw -notmatch 'Path|Command|Add-AppxPackage') 'state must not contain path or command authority'
    $roundTrip = Read-UbState -Root $root
    Assert-Equal $candidate.Key $roundTrip.Candidate.Key 'candidate key round-trip'
    Assert-True (Test-UbSnapshotMatch -A $candidate.Snapshot -B $roundTrip.Candidate.Snapshot) 'snapshot round-trip'
}

Invoke-Case 'state and prompt locks are separate and exclusive' {
    $root = Join-Path $script:FixtureRoot 'locks'
    $stateLock = Enter-UbStateLock -Root $root
    $promptLock = $null
    $secondState = $null
    try {
        $promptLock = Enter-UbPromptLock -Root $root
        Assert-True ($null -ne $promptLock) 'prompt lock must not alias state lock'
        try { $secondState = Enter-UbStateLock -Root $root; throw 'second state lock unexpectedly succeeded' } catch [IO.IOException] { }
    } finally {
        if ($null -ne $secondState) { $secondState.Dispose() }
        if ($null -ne $promptLock) { $promptLock.Dispose() }
        if ($null -ne $stateLock) { $stateLock.Dispose() }
    }
}

Invoke-Case 'detached prompt uses trusted STA PowerShell and quotes isolated paths' {
    $root = Join-Path $script:FixtureRoot 'detached root [中文]'
    $scriptPath = Join-Path $root 'prompt [中文]\confirm-install.ps1'
    $corePath = Join-Path $root 'core [中文]\update-chatgpt.ps1'
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $scriptPath))
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $corePath))
    Copy-Item -LiteralPath (Join-Path $script:ProjectRoot 'confirm-install.ps1') -Destination $scriptPath -Force
    Copy-Item -LiteralPath (Join-Path $script:ProjectRoot 'update-chatgpt.ps1') -Destination $corePath -Force
    $script:CapturedPromptArguments = $null
    function Start-Process {
        [CmdletBinding()]
        param([string]$FilePath,[string]$ArgumentList,[string]$WindowStyle,[switch]$PassThru)
        $script:CapturedPromptArguments = $ArgumentList
        $markerMatch = [regex]::Match($ArgumentList, '-StartupMarker\s+"([^"]+)"')
        if (-not $markerMatch.Success) { throw 'startup marker was not quoted' }
        [IO.File]::WriteAllText($markerMatch.Groups[1].Value, '{}')
        return [pscustomobject]@{ Id = 4242; HasExited = $false; ExitCode = 0 }
    }
    $process = Start-UbPromptDetached -ScriptPath $scriptPath -Root $root -ExpectedKey 'x64-key' -ExpectedVersion '26.930.7945.0' -CorePath $corePath -OpenApp
    Assert-Equal 4242 $process.Id 'detached process returned'
    Assert-True ($script:CapturedPromptArguments -match '(?i)-STA') 'prompt process is STA'
    Assert-True ($script:CapturedPromptArguments -match '"[^"]*prompt \[中文\]\\confirm-install\.ps1"') 'script path with spaces is quoted'
    Assert-True ($script:CapturedPromptArguments -match '"[^"]*core \[中文\]\\update-chatgpt\.ps1"') 'core path with spaces is quoted'
    Assert-True ($script:CapturedPromptArguments -match '(?i)-OpenApp') 'OpenApp is passed explicitly'
}

Invoke-Case 'snooze is at least 24 hours and reminder is due afterwards' {
    $root = Join-Path $script:FixtureRoot 'snooze'
    $candidate = New-TestCandidate
    $clock = ([datetime]'2026-10-07T00:00:00Z').ToUniversalTime()
    Set-UbCandidate -Root $root -Candidate $candidate -Now $clock | Out-Null
    Set-UbSnooze -Root $root -Now $clock | Out-Null
    $state = Read-UbState -Root $root
    Assert-True (-not (Test-UbReminderDue -State $state -Now $clock.AddHours(23).AddMinutes(59))) 'reminder before 24 hours'
    Assert-True (Test-UbReminderDue -State $state -Now $clock.AddHours(24)) 'reminder after 24 hours'
}

# Load the worker and replace only OS/network/AppX boundaries with deterministic
# test doubles.  The worker state, locking, retry and candidate publication
# paths remain the production functions above.
. (Join-Path $script:ProjectRoot 'background-worker.ps1') -CorePath (Join-Path $script:ProjectRoot 'update-chatgpt.ps1')
. (Join-Path $script:ProjectRoot 'confirm-install.ps1') -CorePath (Join-Path $script:ProjectRoot 'update-chatgpt.ps1')
$script:HeadCalls = 0
$script:PrepareCalls = 0
$script:UpdateLockCalls = 0
$script:MockPrepareFailure = $false
$script:MockInstalledVersion = '26.707.3748.0'
$script:MockArchitectureFailure = $false
function Get-UtNativeArchitecture { if ($script:MockArchitectureFailure) { throw 'mock architecture query failure' }; return 'x64' }
function Get-UtWindowsVersion { return [version]'10.0.26100.1' }
function Get-UtInstalledPackage { return [pscustomobject]@{ Version = [version]$script:MockInstalledVersion; Status = 'Ok'; PackageFamilyName = 'OpenAI.Codex_2p2nqsd0c76g0' } }
function Invoke-UtHeadRequest { $script:HeadCalls++; return [pscustomobject]@{ Mock = $true } }
function Get-UtRemoteMetadata { return (New-TestMetadata) }
function Enter-UtLock { $script:UpdateLockCalls++; return (New-Object IO.MemoryStream) }
function Get-UtPreparedCandidate {
    $script:PrepareCalls++
    if ($script:MockPrepareFailure) { throw 'mock download failure' }
    $path = Join-Path $script:FixtureRoot ('prepared-' + [guid]::NewGuid().ToString('N') + '.msix')
    [IO.File]::WriteAllBytes($path, [byte[]](1,2,3,4))
    return [pscustomobject]@{ Path = $path; Key = 'x64-26-930-7945-0-4096'; Metadata = (New-TestMetadata); SHA256 = ('A' * 64) }
}
function Test-UtSnapshotMatch { param($A,$B) return ([string]$A.Version -eq [string]$B.Version -and [string]$A.ETag -eq [string]$B.ETag) }

Invoke-Case 'seven-day check prepares once and HEAD recheck retains a matching Ready candidate' {
    $root = Join-Path $script:FixtureRoot 'worker-seven-day'
    $now = ([datetime]'2026-10-07T00:00:00Z').ToUniversalTime()
    $result = Invoke-UbBackgroundWorker -WorkerMode Run -WorkerConnections 8 -WorkerStateRoot $root -WorkerNoPrompt -WorkerNow $now
    Assert-Equal 'Ready' $result.Status 'first worker prepares'
    Assert-Equal 1 $script:HeadCalls 'one HEAD'
    Assert-Equal 1 $script:PrepareCalls 'one prepare'
    Assert-Equal 1 $script:UpdateLockCalls 'caller-held update lock'
    $headBefore = $script:HeadCalls
    $result2 = Invoke-UbBackgroundWorker -WorkerMode Run -WorkerConnections 8 -WorkerStateRoot $root -WorkerNoPrompt -WorkerNow $now.AddDays(6)
    Assert-Equal 'Ready' $result2.Status 'matching ready candidate remains quiet'
    Assert-Equal $headBefore $script:HeadCalls 'daily trigger does not issue a second HEAD before seven days'
    $recheck = Invoke-UbBackgroundWorker -WorkerMode Run -WorkerConnections 8 -WorkerStateRoot $root -WorkerNoPrompt -WorkerNow $now.AddDays(7)
    Assert-Equal 'Ready' $recheck.Status 'HEAD-only recheck retains the matching ready candidate'
    Assert-Equal ($headBefore + 1) $script:HeadCalls 'seven-day recheck issues one HEAD'
    Assert-Equal 1 $script:PrepareCalls 'matching HEAD recheck does not prepare a second candidate'
}

Invoke-Case 'HEAD success and prepare failure retain separate retry clocks' {
    $root = Join-Path $script:FixtureRoot 'worker-retry'
    $clock = ([datetime]'2026-10-07T00:00:00Z').ToUniversalTime()
    $script:MockPrepareFailure = $true
    $result = Invoke-UbBackgroundWorker -WorkerMode Run -WorkerStateRoot $root -WorkerNoPrompt -WorkerNow $clock
    Assert-Equal 'Failed' $result.Status 'prepare failure'
    $state = Read-UbState -Root $root
    Assert-Equal $clock.ToString('o') $state.LastSuccessfulCheck 'HEAD success timestamp is still recorded'
    Assert-True ([datetime]::Parse($state.NextRetryAt) -ge $clock.AddHours(6)) 'prepare retry is six hours later'
    $before = $script:HeadCalls
    $quiet = Invoke-UbBackgroundWorker -WorkerMode Run -WorkerStateRoot $root -WorkerNoPrompt -WorkerNow $clock.AddHours(1)
    Assert-Equal 'NotDue' $quiet.Status 'failure is rate limited'
    Assert-Equal $before $script:HeadCalls 'retry interval suppresses HEAD'
    $script:MockPrepareFailure = $false
    $result2 = Invoke-UbBackgroundWorker -WorkerMode Run -WorkerStateRoot $root -WorkerNoPrompt -WorkerNow $clock.AddHours(6).AddMinutes(1)
    Assert-Equal 'Ready' $result2.Status 'retry prepares after six hours'
}

Invoke-Case 'successful already-current HEAD clears a stale prepare retry clock' {
    $root = Join-Path $script:FixtureRoot 'worker-clock-reset'
    $clock = ([datetime]'2026-10-07T00:00:00Z').ToUniversalTime()
    $script:MockPrepareFailure = $true
    $failed = Invoke-UbBackgroundWorker -WorkerMode Run -WorkerStateRoot $root -WorkerNoPrompt -WorkerNow $clock
    Assert-Equal 'Failed' $failed.Status 'initial prepare failure creates a retry clock'
    $failedState = Read-UbState -Root $root
    Assert-True ($null -ne $failedState.NextRetryAt) 'retry clock exists after failed preparation'
    $script:MockPrepareFailure = $false
    $script:MockInstalledVersion = '26.930.7945.0'
    $headBefore = $script:HeadCalls
    $current = Invoke-UbBackgroundWorker -WorkerMode Run -WorkerStateRoot $root -WorkerNoPrompt -WorkerNow $clock.AddHours(6).AddMinutes(1)
    Assert-Equal 'AlreadyCurrent' $current.Status 'successful HEAD observes an already-current package'
    $currentState = Read-UbState -Root $root
    Assert-True ([string]::IsNullOrWhiteSpace([string]$currentState.NextRetryAt)) 'successful HEAD clears stale retry clock'
    Assert-Equal $clock.AddHours(6).AddMinutes(1).ToString('o') $currentState.LastSuccessfulCheck 'successful HEAD timestamp is refreshed'
    $nextDay = Invoke-UbBackgroundWorker -WorkerMode Run -WorkerStateRoot $root -WorkerNoPrompt -WorkerNow $clock.AddDays(1)
    Assert-Equal 'NotDue' $nextDay.Status 'next day remains inside seven-day HEAD interval'
    Assert-Equal ($headBefore + 1) $script:HeadCalls 'next day does not issue a second HEAD'
    $script:MockInstalledVersion = '26.707.3748.0'
}

Invoke-Case 'deferred registration is observed on the next worker run even before the HEAD interval' {
    $root = Join-Path $script:FixtureRoot 'worker-deferred'
    $clock = ([datetime]'2026-10-07T00:00:00Z').ToUniversalTime()
    $candidate = New-TestCandidate
    Set-UbCandidate -Root $root -Candidate $candidate -Now $clock | Out-Null
    Set-UbHeadSuccess -Root $root -Now $clock | Out-Null
    Set-UbDeferred -Root $root -Now $clock | Out-Null
    $script:MockInstalledVersion = '26.930.7945.0'
    $headBefore = $script:HeadCalls
    $result = Invoke-UbBackgroundWorker -WorkerMode Run -WorkerStateRoot $root -WorkerNoPrompt -WorkerNow $clock.AddHours(1)
    Assert-Equal 'AlreadyCurrent' $result.Status 'deferred registration that completed is recognized without a new HEAD'
    Assert-True ($null -eq (Read-UbState -Root $root).Candidate) 'completed deferred candidate is cleared'
    Assert-Equal $headBefore $script:HeadCalls 'deferred completion check does not issue a HEAD'
    $script:MockInstalledVersion = '26.707.3748.0'
}

Invoke-Case 'pre-HEAD worker failures receive the same six-hour retry gate' {
    $root = Join-Path $script:FixtureRoot 'worker-prehead-failure'
    $clock = ([datetime]'2026-10-07T00:00:00Z').ToUniversalTime()
    $script:MockArchitectureFailure = $true
    $failed = Invoke-UbBackgroundWorker -WorkerMode Run -WorkerStateRoot $root -WorkerNoPrompt -WorkerNow $clock
    Assert-Equal 'Failed' $failed.Status 'architecture failure is surfaced'
    $state = Read-UbState -Root $root
    Assert-True ([datetime]::Parse($state.NextRetryAt) -ge $clock.AddHours(6)) 'pre-HEAD failure gets a six-hour retry'
    $headBefore = $script:HeadCalls
    $script:MockArchitectureFailure = $false
    $quiet = Invoke-UbBackgroundWorker -WorkerMode Run -WorkerStateRoot $root -WorkerNoPrompt -WorkerNow $clock.AddHours(1)
    Assert-Equal 'NotDue' $quiet.Status 'pre-HEAD failure does not repeat on every logon'
    Assert-Equal $headBefore $script:HeadCalls 'pre-HEAD retry gate avoids HEAD'
}

Invoke-Case 'ready reminder, Later and install test mode never invoke production install' {
    $root = Join-Path $script:FixtureRoot 'worker-reminder'
    $clock = ([datetime]'2026-10-07T00:00:00Z').ToUniversalTime()
    $candidate = New-TestCandidate
    Set-UbCandidate -Root $root -Candidate $candidate -Now $clock | Out-Null
    Set-UbSnooze -Root $root -Now $clock | Out-Null
    $before = Invoke-UbBackgroundWorker -WorkerMode Remind -WorkerStateRoot $root -WorkerTestMode -WorkerPromptChoice Later -WorkerNow $clock.AddHours(23)
    Assert-Equal 'NotDue' $before.Status 'snoozed reminder'
    $after = Invoke-UbBackgroundWorker -WorkerMode Remind -WorkerStateRoot $root -WorkerTestMode -WorkerPromptChoice Later -WorkerNow $clock.AddHours(24)
    Assert-Equal 'Snoozed' $after.Status 'Later is safe'
    $install = Invoke-UbConfirmationPrompt -StateRoot $root -Key $candidate.Key -Version $candidate.Version -TestMode -Choice Install
    Assert-Equal 'Installed' $install.Status 'test mode uses an explicit mock boundary'
    Assert-True ($null -eq (Read-UbState -Root $root).Candidate) 'mock success clears only isolated candidate state'
}

Invoke-Case 'all non-install prompt decisions snooze and retain the Ready candidate' {
    foreach ($choice in @('Later','Timeout','Cancel','X','Esc')) {
        $root = Join-Path $script:FixtureRoot ('prompt-choice-' + $choice)
        $clock = ([datetime]'2026-10-07T00:00:00Z').ToUniversalTime()
        $candidate = New-TestCandidate
        Set-UbCandidate -Root $root -Candidate $candidate -Now $clock | Out-Null
        $result = Invoke-UbConfirmationPrompt -StateRoot $root -Key $candidate.Key -Version $candidate.Version -TestMode -Choice $choice -PromptNow $clock
        Assert-Equal 'Snoozed' $result.Status ("{0} must not install" -f $choice)
        $state = Read-UbState -Root $root
        Assert-True ($null -ne $state.Candidate) ("{0} retains Ready candidate" -f $choice)
        Assert-True (-not (Test-UbReminderDue -State $state -Now ($clock.AddHours(23)))) ("{0} snoozes for 24 hours" -f $choice)
    }
}

Invoke-Case 'candidate change, install failure, and duplicate prompt lock are fail-safe' {
    $root = Join-Path $script:FixtureRoot 'prompt-boundaries'
    $candidate = New-TestCandidate
    Set-UbCandidate -Root $root -Candidate $candidate | Out-Null
    $changed = Invoke-UbConfirmationPrompt -StateRoot $root -Key $candidate.Key -Version $candidate.Version -TestMode -Choice Install -MockResult Changed
    Assert-Equal 'CandidateChanged' $changed.Status 'changed candidate is never installed'
    $changedState = Read-UbState -Root $root
    Assert-True ($null -eq $changedState.Candidate) 'changed candidate is cleared'
    Assert-True (Test-UbDueForCheck -State $changedState -Now ([datetime]::UtcNow)) 'changed candidate forces a fresh prepare'

    $candidate2 = New-TestCandidate -Version '26.930.7945.1' -ETag '"next"'
    Set-UbCandidate -Root $root -Candidate $candidate2 | Out-Null
    $failed = Invoke-UbConfirmationPrompt -StateRoot $root -Key $candidate2.Key -Version $candidate2.Version -TestMode -Choice Install -MockResult D02
    Assert-Equal 'Failed' $failed.Status 'D02 failure is surfaced'
    $failedState = Read-UbState -Root $root
    Assert-True ($null -ne $failedState.Candidate) 'D02 retains Ready candidate'
    Assert-True (-not (Test-UbReminderDue -State $failedState -Now ([datetime]::UtcNow).AddHours(23))) 'D02 uses safe reminder delay'
    $failureClock = ([datetime]'2026-10-07T00:00:00Z').ToUniversalTime()
    $retryRoot = Join-Path $script:FixtureRoot 'prompt-startup-retry'
    Set-UbCandidate -Root $retryRoot -Candidate (New-TestCandidate) -Now $failureClock | Out-Null
    Set-UbFailure -Root $retryRoot -Now $failureClock -Message 'mock prompt startup failure' | Out-Null
    $retryState = Read-UbState -Root $retryRoot
    Assert-True (-not (Test-UbReminderDue -State $retryState -Now $failureClock.AddHours(1))) 'prompt startup failure suppresses reminders until retry time'
    Assert-True (Test-UbReminderDue -State $retryState -Now $failureClock.AddHours(6).AddMinutes(1)) 'prompt startup retry becomes due after six hours'

    $promptLock = Enter-UbPromptLock -Root $root
    try {
        try {
            $null = Invoke-UbConfirmationPrompt -StateRoot $root -Key $candidate2.Key -Version $candidate2.Version -TestMode -Choice Later
            throw 'second confirmation unexpectedly acquired prompt lock'
        } catch [IO.IOException] { }
    } finally { $promptLock.Dispose() }
}

Invoke-Case 'async confirmation runspace reaches every isolated mock result' {
    foreach ($mockResult in @('Success','Deferred','D02','Changed')) {
        $root = Join-Path $script:FixtureRoot ('runspace-' + $mockResult)
        $candidate = New-TestCandidate -Version ('26.930.7945.' + $(if ($mockResult -eq 'Success') { '0' } elseif ($mockResult -eq 'Deferred') { '3' } elseif ($mockResult -eq 'D02') { '1' } else { '2' })) -ETag ('"' + $mockResult + '"')
        Set-UbCandidate -Root $root -Candidate $candidate | Out-Null
        $operation = $null
        try {
            $operation = Start-UbInstallRunspace -Core (Join-Path $script:ProjectRoot 'update-chatgpt.ps1') -Key $candidate.Key -Version $candidate.Version -Mock -MockResult $mockResult
            $output = $operation.PowerShell.EndInvoke($operation.Async)
            $result = @($output) | Select-Object -Last 1
            $expectedStatus = if ($mockResult -eq 'Success') { 'Installed' } elseif ($mockResult -eq 'Deferred') { 'Deferred' } elseif ($mockResult -eq 'D02') { 'Failed' } else { 'CandidateChanged' }
            Assert-Equal $expectedStatus $result.Status ("async {0} status" -f $mockResult)
        } finally {
            if ($null -ne $operation) { $operation.PowerShell.Dispose(); $operation.Runspace.Dispose() }
        }
    }
}

Invoke-Case 'WinForms prompt type compiles with explicit non-activation properties' {
    Ensure-UbPromptTypes
    $form = New-Object -TypeName UbPromptForm -ArgumentList '1.0.0.0','2.0.0.0'
    try {
        Assert-True (-not [bool]$form.TopMost) 'prompt must not be topmost'
        Assert-True ($null -eq $form.AcceptButton) 'prompt must not have an implicit Enter accept button'
        Assert-Equal (ConvertFrom-UbUnicodeText '\u7a0d\u540e') $form.LaterButton.Text 'Later button is Chinese and explicit'
        Assert-True (-not [bool]$form.InstallButton.TabStop) 'Install button is not the initial keyboard default'
        $keyFlags = [Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::NonPublic
        $dialogKeyMethod = [UbPromptForm].GetMethod('ProcessDialogKey', $keyFlags)
        Assert-True ($null -ne $dialogKeyMethod -and $dialogKeyMethod.DeclaringType.Name -eq 'UbPromptForm') 'prompt declares a ProcessDialogKey Enter guard'
    } finally { $form.Dispose() }
}

Invoke-Case 'input desktop probe accepts only the Default desktop and fails closed' {
    $null = Test-UbCanShowPrompt
    Assert-True ([UbDesktopProbe]::IsDefaultName('Default')) 'Default desktop classifier accepts the normal input desktop'
    Assert-True ([UbDesktopProbe]::IsDefaultName('default')) 'desktop classifier is case insensitive'
    Assert-True (-not [UbDesktopProbe]::IsDefaultName('Winlogon')) 'secure desktop name is rejected'
    Assert-True (-not [UbDesktopProbe]::IsDefaultName('')) 'empty desktop name is rejected'
    $env:CHATGPT_UPDATER_TEST_SESSION_VISIBLE = '0'
    try { Assert-True (-not (Test-UbCanShowPrompt)) 'environment test override can only deny visibility' }
    finally { Remove-Item Env:CHATGPT_UPDATER_TEST_SESSION_VISIBLE -ErrorAction SilentlyContinue }
    $actualDefaultSmoke = Test-UbCanShowPrompt
    Assert-True ($actualDefaultSmoke -is [bool]) 'actual input desktop smoke test returns a boolean'
    Write-Host ('    input desktop Default smoke: ' + [bool]$actualDefaultSmoke)
}

Invoke-Case 'locked session retains Ready candidate and state corruption is quarantined' {
    $root = Join-Path $script:FixtureRoot 'worker-locked'
    $candidate = New-TestCandidate
    Set-UbCandidate -Root $root -Candidate $candidate | Out-Null
    $env:CHATGPT_UPDATER_TEST_SESSION_LOCKED = '1'
    try {
        $result = Invoke-UbBackgroundWorker -WorkerMode Remind -WorkerStateRoot $root -WorkerNow ([datetime]::UtcNow)
        Assert-Equal 'Ready' $result.Status 'locked session does not launch UI'
    } finally { Remove-Item Env:CHATGPT_UPDATER_TEST_SESSION_LOCKED -ErrorAction SilentlyContinue }
    $path = Get-UbStatePath $root
    Set-Content -LiteralPath $path -Value '{' -Encoding UTF8
    $result2 = Invoke-UbBackgroundWorker -WorkerMode Remind -WorkerStateRoot $root -WorkerNow ([datetime]::UtcNow)
    Assert-Equal 'NotDue' $result2.Status 'corrupt state recovers to empty state'
    Assert-True (@(Get-ChildItem -LiteralPath $root -Filter '.background-state.corrupt.*.json').Count -eq 1) 'corrupt state was quarantined'
}

Invoke-Case 'task ownership requires marker, SID, exact action and working directory' {
    . (Join-Path $script:ProjectRoot 'manage-background.ps1') -SourceRoot $script:ProjectRoot
    $stable = Join-Path $script:FixtureRoot 'Programs\ChatGPTUpdater'
    $sid = 'S-1-5-21-100-200-300-1001'
    $action = [pscustomobject]@{ Execute = (Get-UgPowerShellPath); Arguments = (Get-UgExpectedTaskArguments -StableRoot $stable -Connections 8); WorkingDirectory = [IO.Path]::GetFullPath($stable) }
    $principal = [pscustomobject]@{ UserId = $sid; LogonType = 'Interactive'; RunLevel = 'Limited' }
    $task = [pscustomobject]@{ Description = $script:UbTaskMarker; Principal = $principal; Actions = @($action) }
    Assert-True (Test-UgTaskOwnership -Task $task -StableRoot $stable -Sid $sid) 'owned task accepted'
    $savedResolver = (Get-Command Resolve-UgPrincipalSid -CommandType Function).ScriptBlock
    $mappedSame = $sid
    $mappedOther = 'S-1-5-21-100-200-300-2002'
    $mockResolver = ({
        param([string]$UserId)
        switch ([string]$UserId) {
            'friendly-same' { return $mappedSame }
            'friendly-other' { return $mappedOther }
            'unresolvable-user' { return $null }
            default { if ([string]$UserId -match '(?i)^S-') { return [string]$UserId }; return $null }
        }
    }).GetNewClosure()
    try {
        Set-Item -Path Function:\Resolve-UgPrincipalSid -Value $mockResolver -Force
        $task.Principal.UserId = 'friendly-same'
        Assert-True (Test-UgTaskOwnership -Task $task -StableRoot $stable -Sid $sid) 'friendly principal resolving to current SID accepted'
        $task.Principal.UserId = 'friendly-other'
        Assert-True (-not (Test-UgTaskOwnership -Task $task -StableRoot $stable -Sid $sid)) 'friendly principal resolving to another SID rejected'
        $task.Principal.UserId = 'unresolvable-user'
        Assert-True (-not (Test-UgTaskOwnership -Task $task -StableRoot $stable -Sid $sid)) 'unresolvable friendly principal rejected'
    } finally {
        Set-Item -Path Function:\Resolve-UgPrincipalSid -Value $savedResolver -Force
        $task.Principal.UserId = $sid
    }
    $task.Description = 'foreign task'
    Assert-True (-not (Test-UgTaskOwnership -Task $task -StableRoot $stable -Sid $sid)) 'foreign marker rejected'
}

Invoke-Case 'task definition is bounded, idempotent, and fail-closed for foreign/query errors' {
    . (Join-Path $script:ProjectRoot 'manage-background.ps1') -SourceRoot $script:ProjectRoot -TestMode
    $stable = Join-Path $script:FixtureRoot 'task deployment [中文]'
    $sid = Get-UgCurrentSid

    function New-ScheduledTaskTrigger {
        param([switch]$Daily,[string]$At,[switch]$AtLogOn,[string]$User)
        [pscustomobject]@{ Daily = [bool]$Daily; At = $At; AtLogOn = [bool]$AtLogOn; User = $User }
    }
    function New-ScheduledTaskSettingsSet {
        param([switch]$StartWhenAvailable,[string]$MultipleInstances,[TimeSpan]$ExecutionTimeLimit,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries)
        [pscustomobject]@{ StartWhenAvailable = [bool]$StartWhenAvailable; MultipleInstances = $MultipleInstances; ExecutionTimeLimit = $ExecutionTimeLimit; AllowStartIfOnBatteries = [bool]$AllowStartIfOnBatteries; DontStopIfGoingOnBatteries = [bool]$DontStopIfGoingOnBatteries; WakeToRun = $false }
    }
    function New-ScheduledTaskPrincipal { param([string]$UserId,[string]$LogonType,[string]$RunLevel) [pscustomobject]@{ UserId=$UserId; LogonType=$LogonType; RunLevel=$RunLevel } }
    function New-ScheduledTaskAction { param([string]$Execute,[string]$Argument,[string]$WorkingDirectory) [pscustomobject]@{ Execute=$Execute; Arguments=$Argument; WorkingDirectory=$WorkingDirectory } }
    $definition = New-UgTaskDefinition -StableRoot $stable -Sid $sid -Connections 4
    Assert-Equal 2 @($definition.Trigger).Count 'daily and logon triggers are present'
    Assert-True (@($definition.Trigger | Where-Object { $_.Daily -and $_.At -eq '12:00' }).Count -eq 1) 'daily trigger is local noon'
    Assert-True (@($definition.Trigger | Where-Object { $_.AtLogOn -and $_.User -eq $sid }).Count -eq 1) 'logon trigger is current SID'
    Assert-True ([bool]$definition.Settings.StartWhenAvailable) 'task starts when available'
    Assert-Equal 'IgnoreNew' $definition.Settings.MultipleInstances 'duplicate starts are ignored'
    Assert-Equal ([TimeSpan]::Zero) $definition.Settings.ExecutionTimeLimit 'task has no execution timeout'
    Assert-True ([bool]$definition.Settings.AllowStartIfOnBatteries) 'task may start on battery'
    Assert-True ([bool]$definition.Settings.DontStopIfGoingOnBatteries) 'task is not stopped on battery'
    Assert-True (-not [bool]$definition.Settings.WakeToRun) 'task cannot wake the machine'
    Assert-Equal $sid $definition.Principal.UserId 'principal SID is exact'
    Assert-Equal 'Interactive' $definition.Principal.LogonType 'principal is interactive'
    Assert-Equal 'Limited' $definition.Principal.RunLevel 'principal is limited'
    Assert-Equal (Get-UgExpectedTaskArguments -StableRoot $stable -Connections 4) $definition.Action.Arguments 'action arguments are exact'
    Assert-Equal ([IO.Path]::GetFullPath($stable)) ([IO.Path]::GetFullPath($definition.Action.WorkingDirectory)) 'action working directory is exact'

    $script:MockTask = $null
    $script:RegisterCount = 0
    $script:EnableCount = 0
    $script:StartCount = 0
    $script:DisableCount = 0
    $script:RemoveCount = 0
    $script:QueryFailure = $false
    $script:LocalizedNotFound = $false
    $script:PostRegisterForeign = $false
    function Get-ScheduledTask {
        [CmdletBinding()]
        param([string]$TaskName)
        if ($script:QueryFailure) { throw 'Access is denied while querying Scheduled Tasks.' }
        if ($script:LocalizedNotFound) {
            $localizedMessage = ConvertFrom-UbUnicodeText '\u627e\u4e0d\u5230\u6307\u5b9a\u7684\u4efb\u52a1\u3002'
            $localizedException = New-Object System.Exception($localizedMessage)
            $errorRecord = New-Object System.Management.Automation.ErrorRecord -ArgumentList $localizedException, 'CmdletizationQuery_NotFound_TaskName,Get-ScheduledTask', ([System.Management.Automation.ErrorCategory]::ObjectNotFound), $null
            $PSCmdlet.ThrowTerminatingError($errorRecord)
        }
        if ($null -eq $script:MockTask) { throw '0x80070002: task not found' }
        return $script:MockTask
    }
    function Register-ScheduledTask {
        param($TaskName,$Action,$Trigger,$Settings,$Principal,$Description,[switch]$Force)
        $script:RegisterCount++
        $registeredDescription = if ($script:PostRegisterForeign) { 'foreign after registration' } else { $Description }
        $script:MockTask = [pscustomobject]@{ Description=$registeredDescription; Actions=@($Action); Principal=$Principal; State='Ready' }
        return $script:MockTask
    }
    function Enable-ScheduledTask { $script:EnableCount++; return $script:MockTask }
    function Start-ScheduledTask { $script:StartCount++; return $script:MockTask }
    function Disable-ScheduledTask { $script:DisableCount++; return $script:MockTask }
    function Unregister-ScheduledTask { $script:RemoveCount++; $script:MockTask = $null }
    function Get-ScheduledTaskInfo { [pscustomobject]@{ LastRunTime=$null; NextRunTime=$null; LastTaskResult=0 } }

    $installed = Install-UgBackgroundTask -Source $script:ProjectRoot -Destination $stable -TaskConnections 4
    Assert-Equal 1 $script:RegisterCount 'first install registers once'
    Assert-Equal 1 $script:StartCount 'install starts immediate preparation'
    Assert-Equal $script:UgProductionFiles.Count $installed.FilesPresent 'all production files are deployed'
    $null = Install-UgBackgroundTask -Source $script:ProjectRoot -Destination $stable -TaskConnections 4
    Assert-Equal 2 $script:RegisterCount 'repeat install updates only the owned task'
    Assert-Equal 2 $script:StartCount 'repeat install starts immediate preparation'
    $script:MockTask = $null
    $script:PostRegisterForeign = $true
    try { $null = Install-UgBackgroundTask -Source $script:ProjectRoot -Destination $stable -TaskConnections 4; throw 'post-registration foreign task was started' } catch { Assert-True ($_.Exception.Message -match 'not owned') 'post-registration ownership is rechecked before start' }
    Assert-Equal 2 $script:StartCount 'unexpected post-registration task is not started'
    $script:PostRegisterForeign = $false
    $script:MockTask = $null
    $null = Install-UgBackgroundTask -Source $script:ProjectRoot -Destination $stable -TaskConnections 4
    Assert-Equal 4 $script:RegisterCount 'owned registration can be retried after a post-registration mismatch'
    Assert-Equal 3 $script:StartCount 'recovered registration starts immediate preparation'
    $script:MockTask.Description = 'foreign task'
    try { $null = Install-UgBackgroundTask -Source $script:ProjectRoot -Destination $stable -TaskConnections 4; throw 'foreign task was overwritten' } catch { Assert-True ($_.Exception.Message -match 'not owned') 'foreign task blocks overwrite' }
    Assert-Equal 4 $script:RegisterCount 'foreign task does not register'
    $script:LocalizedNotFound = $true
    Assert-True ($null -eq (Get-UgTask)) 'localized confirmed-absent task is recognized'
    $script:LocalizedNotFound = $false
    $script:QueryFailure = $true
    try { $null = Get-UgTask; throw 'query failure was treated as absence' } catch { Assert-True ($_.Exception.Message -match 'Access is denied') 'task query errors fail closed' }
    $script:QueryFailure = $false
    $script:MockTask = [pscustomobject]@{ Description=$script:UbTaskMarker; Actions=@([pscustomobject]@{ Execute=(Get-UgPowerShellPath); Arguments=(Get-UgExpectedTaskArguments -StableRoot $stable -Connections 4); WorkingDirectory=[IO.Path]::GetFullPath($stable) }); Principal=[pscustomobject]@{ UserId=$sid; LogonType='Interactive'; RunLevel='Limited' }; State='Ready' }
    $null = Set-UgTaskEnabled -Enabled $true -StableRoot $stable
    Assert-Equal 4 $script:StartCount 'enabling an owned task starts immediate preparation'
    $null = Set-UgTaskEnabled -Enabled $false -StableRoot $stable
    Assert-Equal 1 $script:DisableCount 'disable calls only the owned task'
    $null = Remove-UgBackgroundTask -StableRoot $stable
    Assert-Equal 1 $script:RemoveCount 'remove calls only the owned task'
}

$env:LOCALAPPDATA = $script:OriginalLocalAppData
if ($script:TestFailed -eq 0) {
    Write-Host ("All {0} background test cases passed." -f $script:TestTotal) -ForegroundColor Green
    if (-not $KeepTemp) { Remove-Item -LiteralPath $script:FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue }
    exit 0
}
Write-Host ("{0} of {1} background test cases failed. Evidence: {2}" -f $script:TestFailed,$script:TestTotal,$script:FixtureRoot) -ForegroundColor Red
exit 1
