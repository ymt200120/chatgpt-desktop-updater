#requires -Version 5.1
<##
    Whitebox WinForms integration checks for the confirmation prompt.

    The test enters the production Invoke-UbConfirmationPrompt function and
    uses a Windows Forms Timer to find its own production form.  It invokes
    .NET control events directly (PerformClick, Form.Close, and OnKeyDown)
    instead of using desktop input, SendKeys, or screenshots.  The focused
    Enter check uses ActiveControl and the public PreProcessMessage pipeline
    on its own production form instance; it never changes desktop focus.
    The UI install-runspace boundary is replaced by a fake operation, while
    AppX/deployment functions are fail-closed guards.  The fake operation has
    the same PowerShell/Runspace/Async surface used by the production poll timer.

    Every case uses DemoMode and an isolated 99.999.0.0 candidate.  The fake
    boundary fails closed if production consent reaches an AppX/deployment
    function.  The DrawToBitmap PNG written by this test is a control fixture
    rendering, not a desktop or focus-acceptance screenshot.
##>
[CmdletBinding()]
param(
    [switch]$KeepTemp,
    [string]$EvidenceDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:TestTotal = 0
$script:TestFailed = 0
$script:FixtureWritten = $false
$script:ForbiddenProductionCalls = 0
$script:FocusedPreProcessChecked = $false
$script:FocusedPreProcessHandled = $false
$script:FocusedPreProcessInstallCalls = 0
$script:UiRun = $null
$script:CaseEvidence = New-Object System.Collections.ArrayList

function Write-UiSkip {
    param([Parameter(Mandatory = $true)][string]$Reason)
    Write-Host ('[UI-EVENTS] SKIP: ' + $Reason) -ForegroundColor Yellow
}

function Fail-Ui {
    param([Parameter(Mandatory = $true)][string]$Message)
    $script:TestFailed++
    Write-Host ('    FAIL: ' + $Message) -ForegroundColor Red
}

function Assert-Ui {
    param([bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { Fail-Ui -Message $Message }
}

function Get-UiPromptForm {
    foreach ($item in [System.Windows.Forms.Application]::OpenForms) {
        if ($null -ne $item -and -not $item.IsDisposed -and $item.GetType().Name -eq 'UbPromptForm') {
            return $item
        }
    }
    return $null
}

function Invoke-UiKeyDown {
    param(
        [Parameter(Mandatory = $true)]$Form,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Keys]$Key
    )
    $flags = [Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::NonPublic
    $type = $Form.GetType()
    $method = $null
    while ($null -ne $type -and $null -eq $method) {
        $method = $type.GetMethod('OnKeyDown', $flags)
        $type = $type.BaseType
    }
    if ($null -eq $method) { throw 'Could not locate Form.OnKeyDown for the Escape event test.' }
    $args = [System.Windows.Forms.KeyEventArgs]::new($Key)
    $null = $method.Invoke($Form, @($args))
    return $args
}

function Invoke-UiEscape {
    param([Parameter(Mandatory = $true)]$Form)
    return Invoke-UiKeyDown -Form $Form -Key ([System.Windows.Forms.Keys]::Escape)
}

function Invoke-UiProcessCmdKey {
    param([Parameter(Mandatory = $true)]$Form)
    $invokeArgs = @(
        [System.Windows.Forms.Message]::Create([IntPtr]::Zero, 0, [IntPtr]::Zero, [IntPtr]::Zero),
        [System.Windows.Forms.Keys]::Enter
    )
    return [bool]$script:ProcessCmdKeyGuardMethod.Invoke($Form, $invokeArgs)
}

function Invoke-UiFocusedEnterPreProcess {
    <#
        Exercise the same public Control.PreProcessMessage entry point that a
        focused child button receives for WM_KEYDOWN/Return.  The probe is a
        separate production UbPromptForm, so a regression that turns Return
        into a button click cannot mutate one of the consent scenarios.  The
        click handler is only a test counter and is the install-call guard for
        this focused-control path.
    #>
    $probe = $null
    try {
        $script:FocusedPreProcessInstallCalls = 0
        $probe = New-Object -TypeName UbPromptForm -ArgumentList 'TEST/MOCK current','99.999.0.0'
        $probe.InstallButton.Add_Click({ $script:FocusedPreProcessInstallCalls++ })

        # Select only within this test-owned form.  No desktop focus or input
        # API is involved, and ActiveControl identifies the child to probe.
        $probe.ActiveControl = $probe.InstallButton
        $null = $probe.InstallButton.Select()
        $focusedControl = $probe.ActiveControl
        Assert-Ui ($null -ne $focusedControl -and $focusedControl -eq $probe.InstallButton) 'focused Enter probe selected the production InstallButton inside its own form'

        $message = [System.Windows.Forms.Message]::Create(
            [IntPtr]::Zero,
            0x0100,
            [IntPtr]([int][System.Windows.Forms.Keys]::Enter),
            [IntPtr]::Zero
        )
        $handled = [bool]$focusedControl.PreProcessMessage([ref]$message)
        $script:FocusedPreProcessChecked = $true
        $script:FocusedPreProcessHandled = $handled
        Assert-Ui $handled 'focused InstallButton public PreProcessMessage consumed WM_KEYDOWN/Return'
        Assert-Ui ($script:FocusedPreProcessInstallCalls -eq 0) 'focused Enter preprocessing did not invoke the install click boundary'
    } catch {
        Fail-Ui ('focused Enter PreProcessMessage probe threw: ' + $_.Exception.Message)
    } finally {
        if ($null -ne $probe) {
            try { $probe.Dispose() } catch { }
        }
    }
}

function New-UiFakeOperation {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [switch]$Pending
    )

    $fakePowerShell = [pscustomobject]@{
        Result = $Result
        Disposed = $false
    }
    $fakePowerShell | Add-Member -MemberType ScriptMethod -Name EndInvoke -Value {
        param($Async)
        return $this.Result
    }
    $fakePowerShell | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
        $this.Disposed = $true
    }

    $fakeRunspace = [pscustomobject]@{ Disposed = $false }
    $fakeRunspace | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
        $this.Disposed = $true
    }

    return [pscustomobject]@{
        PowerShell = $fakePowerShell
        Runspace = $fakeRunspace
        Async = [pscustomobject]@{ IsCompleted = (-not $Pending) }
    }
}

function Get-UiScenarioState {
    param([Parameter(Mandatory = $true)][string]$Root)
    $state = Read-UbState -Root $Root
    $candidate = Get-UbProperty $state 'Candidate'
    $snooze = [string](Get-UbProperty $state 'SnoozeUntil')
    $retry = [string](Get-UbProperty $state 'NextRetryAt')
    $snoozed = $false
    $retryScheduled = $false
    $parsed = [datetime]::MinValue
    if (-not [string]::IsNullOrWhiteSpace($snooze) -and [datetime]::TryParse($snooze, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        $snoozed = $parsed.ToUniversalTime() -gt [datetime]::UtcNow.AddMinutes(1)
    }
    $parsed = [datetime]::MinValue
    if (-not [string]::IsNullOrWhiteSpace($retry) -and [datetime]::TryParse($retry, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        $retryScheduled = $parsed.ToUniversalTime() -gt [datetime]::UtcNow.AddMinutes(1)
    }
    return [pscustomobject]@{
        Candidate = $candidate
        HasCandidate = ($null -ne $candidate)
        Snoozed = $snoozed
        RetryScheduled = $retryScheduled
        LastFailure = [string](Get-UbProperty $state 'LastFailure')
    }
}

function Save-UiFixture {
    param([Parameter(Mandatory = $true)]$Form)
    if ($script:FixtureWritten) { return }
    $directory = if ([string]::IsNullOrWhiteSpace($script:EvidenceDirectory)) {
        Join-Path $script:ProjectRoot 'tests\evidence\segmented-background'
    } else { [IO.Path]::GetFullPath($script:EvidenceDirectory) }
    $null = New-Item -ItemType Directory -Path $directory -Force
    $path = Join-Path $directory 'ui-form-fixture.png'
    $bitmap = New-Object System.Drawing.Bitmap ([int]$Form.Width),([int]$Form.Height)
    $graphicsRectangle = New-Object System.Drawing.Rectangle 0,0,([int]$Form.Width),([int]$Form.Height)
    try {
        $Form.DrawToBitmap($bitmap, $graphicsRectangle)
        $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $bitmap.Dispose()
    }
    $script:FixtureWritten = $true
    $script:FixturePath = $path
    Write-Host ('    fixture: ' + $path)
}

function Invoke-UiMockStartRunspace {
    param(
        [Parameter(Mandatory = $true)][string]$Core,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Version,
        [switch]$Mock,
        [string]$MockResult = 'Success'
    )
    if ($null -eq $script:UiRun) { throw 'UI event test run state is missing.' }
    $script:UiRun.StartCalls = [int]$script:UiRun.StartCalls + 1
    $script:UiRun.LastMock = [bool]$Mock
    $script:UiRun.LastKey = $Key
    $script:UiRun.LastVersion = $Version
    if (-not $Mock) { throw 'UI event test requires the DemoMode mock boundary.' }
    if ($script:UiRun.ThrowOnStart) { throw 'TEST/MOCK startup runspace failure.' }
    $result = Get-UbDemoInstallResult -Result $MockResult
    $operation = New-UiFakeOperation -Result $result -Pending:($script:UiRun.Action -eq 'ProgressClose')
    $script:UiRun.Operation = $operation
    return $operation
}

# AppX and deployment guards.  A call here means DemoMode leaked through the
# mocked runspace boundary, so the test records it and fails closed.
function Invoke-UiGuardInstalledPackage {
    $script:ForbiddenProductionCalls++
    throw 'TEST/MOCK guard: AppX package query reached the UI event test.'
}
function Invoke-UiGuardConfirmedInstall {
    $script:ForbiddenProductionCalls++
    throw 'TEST/MOCK guard: production install reached the UI event test.'
}
function Invoke-UiGuardInstallPackage {
    param([string]$Path, [switch]$DeferRegistration)
    $script:ForbiddenProductionCalls++
    throw 'TEST/MOCK guard: Add-AppxPackage boundary reached the UI event test.'
}
function Invoke-UiGuardAddAppxPackage {
    $script:ForbiddenProductionCalls++
    throw 'TEST/MOCK guard: Add-AppxPackage reached the UI event test.'
}

function Invoke-UiProductionMockRunspaceChecks {
    param([Parameter(Mandatory = $true)][scriptblock]$ProductionStart)
    $checks = @(
        @{ Name = 'Success'; Expected = 'Installed' },
        @{ Name = 'Deferred'; Expected = 'Deferred' },
        @{ Name = 'D02'; Expected = 'Failed' },
        @{ Name = 'Changed'; Expected = 'CandidateChanged' }
    )
    foreach ($check in $checks) {
        $root = Join-Path $script:IsolatedRoot ('production-runspace-' + $check.Name + '-' + [guid]::NewGuid().ToString('N'))
        $demo = New-UbDemoState -DemoRoot $root
        $operation = $null
        try {
            # This is the production Start-UbInstallRunspace function captured
            # before the UI-only fake is installed.  DemoMode makes its inline
            # branch return a deterministic result without dot-sourcing the
            # core, validating AppX state, or calling deployment.
            $operation = & $ProductionStart -Core (Join-Path $script:ProjectRoot 'update-chatgpt.ps1') -Key $demo.Candidate.Key -Version $demo.Candidate.Version -Mock -MockResult $check.Name
            Assert-Ui ($null -ne $operation -and $null -ne $operation.Async) ('production runspace mock ' + $check.Name + ' returned an operation')
            $deadline = [datetime]::UtcNow.AddSeconds(5)
            while ($null -ne $operation -and -not $operation.Async.IsCompleted -and [datetime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 25
            }
            Assert-Ui ($null -ne $operation -and $operation.Async.IsCompleted) ('production runspace mock ' + $check.Name + ' completed within 5 seconds')
            if ($null -ne $operation -and $operation.Async.IsCompleted) {
                $output = $operation.PowerShell.EndInvoke($operation.Async)
                $result = @($output) | Select-Object -Last 1
                Assert-Ui ([string](Get-UbProperty $result 'Status') -eq $check.Expected) ('production runspace mock ' + $check.Name + ' returned ' + $check.Expected)
            }
        } catch {
            Fail-Ui ('production runspace mock ' + $check.Name + ' threw: ' + $_.Exception.Message)
        } finally {
            if ($null -ne $operation) {
                try { $operation.PowerShell.Dispose() } catch { }
                try { $operation.Runspace.Dispose() } catch { }
            }
        }
    }
}

function Invoke-UiScenario {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('Later','X','Esc','Enter','Timeout','Install','RepeatedInstall','ProgressClose','StartupFailure')][string]$Action,
        [ValidateSet('Success','Deferred','D02','Changed')][string]$MockResult = 'Success',
        [int]$PromptTimeoutSeconds = 600,
        [switch]$ThrowOnStart
    )

    $script:TestTotal++
    Write-Host ('  - ' + $Name)
    $scenarioRoot = Join-Path $script:IsolatedRoot ($Name + '-' + [guid]::NewGuid().ToString('N'))
    $demo = New-UbDemoState -DemoRoot $scenarioRoot
    Assert-Ui ([string]$demo.Candidate.Version -eq '99.999.0.0') ($Name + ': isolated DemoMode candidate is 99.999.0.0')

    $script:UiRun = [ordered]@{
        Name = $Name
        Action = $Action
        MockResult = $MockResult
        ThrowOnStart = [bool]$ThrowOnStart
        StartCalls = 0
        LastMock = $false
        LastKey = $null
        LastVersion = $null
        Seen = $false
        Form = $null
        FirstFormText = $null
        Operation = $null
        Driver = $null
        DriverError = $null
        Unhandled = $null
        StatusLabelText = $null
        StatusLabelHeight = 0
        StatusLabelPreferredHeight = 0
        StatusLabelMeasuredHeight = 0
        StatusLabelBottom = 0
        InstallButtonTop = 0
        LaterButtonTop = 0
        ClientHeight = 0
        ActionSent = $false
        CloseSent = $false
        CloseProgressAttempted = $false
        AsyncReleased = $false
        EnterArgs = $null
        ProcessCmdKeyChecked = $false
        StartedAt = [datetime]::UtcNow
        Deadline = [datetime]::UtcNow.AddSeconds([math]::Max(12, $PromptTimeoutSeconds + 6))
    }

    $driver = New-Object System.Windows.Forms.Timer
    $driver.Interval = 50
    $script:UiRun.Driver = $driver
    $driver.Add_Tick({
        $run = $script:UiRun
        if ($null -eq $run) { return }
        try {
            $form = Get-UiPromptForm
            if ($null -eq $form) {
                if ($run.Seen) { $run.Driver.Stop() }
                return
            }
            $run.Form = $form
            if ($script:UbInstallComplete -and [string]::IsNullOrWhiteSpace([string]$run.StatusLabelText)) {
                $run.StatusLabelText = [string]$form.StatusLabel.Text
                $run.StatusLabelHeight = [int]$form.StatusLabel.Height
                $run.StatusLabelPreferredHeight = [int]$form.StatusLabel.PreferredHeight
                $measureSize = [System.Drawing.Size]::new([int]$form.StatusLabel.MaximumSize.Width, 1000)
                $measureFlags = [System.Windows.Forms.TextFormatFlags]::WordBreak
                $run.StatusLabelMeasuredHeight = [int]([System.Windows.Forms.TextRenderer]::MeasureText($form.StatusLabel.Text, $form.StatusLabel.Font, $measureSize, $measureFlags)).Height
                $run.StatusLabelBottom = [int]$form.StatusLabel.Bottom
                $run.InstallButtonTop = [int]$form.InstallButton.Top
                $run.LaterButtonTop = [int]$form.LaterButton.Top
                $run.ClientHeight = [int]$form.ClientSize.Height
            }
            if (-not $run.Seen) {
                $run.Seen = $true
                $run.FirstFormText = [string]$form.Text
                Assert-Ui $run.FirstFormText.Contains('[TEST/MOCK]') ($run.Name + ': production form shows TEST/MOCK marker')
                $versionTextFound = $false
                foreach ($control in $form.Controls) {
                    if ([string]$control.Text -like '*99.999.0.0*') { $versionTextFound = $true; break }
                }
                Assert-Ui $versionTextFound ($run.Name + ': production form renders candidate version 99.999.0.0')
                Save-UiFixture -Form $form
                Assert-Ui (Invoke-UiProcessCmdKey -Form $form) ($run.Name + ': ProcessCmdKey consumes Enter before button activation')
                $run.ProcessCmdKeyChecked = $true

                switch ($run.Action) {
                    'Later' { $null = $form.LaterButton.PerformClick(); $run.ActionSent = $true }
                    'X' { $form.Close(); $run.ActionSent = $true }
                    'Esc' { Invoke-UiEscape -Form $form; $run.ActionSent = $true }
                    'Enter' { $run.EnterArgs = Invoke-UiKeyDown -Form $form -Key ([System.Windows.Forms.Keys]::Enter); $run.ActionSent = $true }
                    'Timeout' { $run.ActionSent = $true }
                    'Install' {
                        $null = $form.InstallButton.PerformClick()
                        $run.ActionSent = $true
                    }
                    'RepeatedInstall' {
                        $null = $form.InstallButton.PerformClick()
                        $null = $form.InstallButton.PerformClick()
                        $run.ActionSent = $true
                    }
                    'ProgressClose' {
                        $null = $form.InstallButton.PerformClick()
                        $run.ActionSent = $true
                    }
                    'StartupFailure' {
                        $null = $form.InstallButton.PerformClick()
                        $run.ActionSent = $true
                    }
                }
            }

            if ($run.Action -eq 'StartupFailure' -and $run.ActionSent -and -not $run.CloseSent) {
                if ($script:UbInstallComplete -or ((-not $script:UbInstallActive) -and (([datetime]::UtcNow - $run.StartedAt).TotalSeconds -gt 0.5))) {
                    $null = $form.LaterButton.PerformClick()
                    $run.CloseSent = $true
                }
            } elseif ($run.Action -eq 'Enter' -and $run.ActionSent -and -not $run.CloseSent -and (([datetime]::UtcNow - $run.StartedAt).TotalSeconds -gt 0.5)) {
                Assert-Ui $run.EnterArgs.Handled ($run.Name + ': Enter event was marked handled')
                Assert-Ui $run.EnterArgs.SuppressKeyPress ($run.Name + ': Enter event suppressed default activation')
                Assert-Ui (-not $script:UbInstallActive) ($run.Name + ': Enter did not start installation')
                $null = $form.LaterButton.PerformClick()
                $run.CloseSent = $true
            } elseif ($run.Action -eq 'ProgressClose' -and $run.ActionSent -and $run.StartCalls -gt 0) {
                $elapsed = ([datetime]::UtcNow - $run.StartedAt).TotalSeconds
                if (-not $run.CloseProgressAttempted -and $elapsed -gt 0.3) {
                    $form.Close()
                    $run.CloseProgressAttempted = $true
                    Assert-Ui (-not $form.Visible) ($run.Name + ': close during install hides the form')
                    Assert-Ui (-not $form.IsDisposed) ($run.Name + ': close during install keeps the form alive')
                    Assert-Ui $script:UbInstallActive ($run.Name + ': close during install leaves the operation active')
                }
                if ($run.CloseProgressAttempted -and -not $run.AsyncReleased -and $elapsed -gt 0.9) {
                    $run.Operation.Async.IsCompleted = $true
                    $run.AsyncReleased = $true
                }
                if ($script:UbInstallComplete -and -not $run.CloseSent) {
                    Assert-Ui ($form.Visible) ($run.Name + ': completed operation re-shows the hidden form')
                    $null = $form.LaterButton.PerformClick()
                    $run.CloseSent = $true
                }
            } elseif (($run.Action -eq 'Install' -or $run.Action -eq 'RepeatedInstall') -and $script:UbInstallComplete -and -not $run.CloseSent) {
                $null = $form.LaterButton.PerformClick()
                $run.CloseSent = $true
            }

            if ([datetime]::UtcNow -gt $run.Deadline) {
                $run.DriverError = 'Production form did not complete the expected event flow before the test deadline.'
                $run.Driver.Stop()
                [System.Windows.Forms.Application]::ExitThread()
            }
        } catch {
            $run.Unhandled = $_.Exception.ToString()
            $run.DriverError = 'Timer event raised: ' + $_.Exception.Message
            try { $run.Driver.Stop() } catch { }
            # This only terminates the test-owned Application.Run loop after
            # capturing an unexpected production callback exception.
            try { [System.Windows.Forms.Application]::ExitThread() } catch { }
        }
    })
    $driver.Start()

    $result = $null
    $outerException = $null
    try {
        $result = Invoke-UbConfirmationPrompt -StateRoot $demo.Root -Key $demo.Candidate.Key -Version $demo.Candidate.Version -PromptCorePath (Join-Path $script:ProjectRoot 'update-chatgpt.ps1') -DemoMode -MockResult $MockResult -PromptTimeoutSeconds $PromptTimeoutSeconds
    } catch {
        $outerException = $_.Exception.ToString()
    } finally {
        try { $driver.Stop() } catch { }
        try { $driver.Dispose() } catch { }
        $script:UiRun.Driver = $null
    }

    if ($null -ne $outerException) { Fail-Ui ($Name + ': Invoke-UbConfirmationPrompt threw: ' + $outerException) }
    Assert-Ui $script:UiRun.Seen ($Name + ': entered the production WinForms message loop')
    Assert-Ui ([string]::IsNullOrWhiteSpace([string]$script:UiRun.Unhandled)) ($Name + ': no unhandled production callback exception')
    Assert-Ui ([string]::IsNullOrWhiteSpace([string]$script:UiRun.DriverError)) ($Name + ': driver completed without timeout/error')
    $requiresInstall = $Action -in @('Install','RepeatedInstall','ProgressClose','StartupFailure')
    if ($requiresInstall) {
        Assert-Ui ([bool]$script:UiRun.LastMock) ($Name + ': install boundary received Mock=true')
        Assert-Ui ([string]$script:UiRun.LastKey -eq [string]$demo.Candidate.Key) ($Name + ': install boundary received the candidate key')
        Assert-Ui ([string]$script:UiRun.LastVersion -eq [string]$demo.Candidate.Version) ($Name + ': install boundary received the candidate version')
    }

    $stateAfter = Get-UiScenarioState -Root $demo.Root
    $status = if ($null -eq $result) { $null } else { [string](Get-UbProperty $result 'Status') }
    $record = [ordered]@{
        Name = $Name
        Action = $Action
        MockResult = $MockResult
        ResultStatus = $status
        ResultMessage = if ($null -eq $result) { $null } else { [string](Get-UbProperty $result 'Message') }
        StatusLabelText = [string]$script:UiRun.StatusLabelText
        StatusLabelHeight = [int]$script:UiRun.StatusLabelHeight
        StatusLabelPreferredHeight = [int]$script:UiRun.StatusLabelPreferredHeight
        StatusLabelMeasuredHeight = [int]$script:UiRun.StatusLabelMeasuredHeight
        StatusLabelBottom = [int]$script:UiRun.StatusLabelBottom
        InstallButtonTop = [int]$script:UiRun.InstallButtonTop
        LaterButtonTop = [int]$script:UiRun.LaterButtonTop
        ClientHeight = [int]$script:UiRun.ClientHeight
        StartCalls = [int]$script:UiRun.StartCalls
        MockBoundary = [bool]$script:UiRun.LastMock
        EnteredProductionForm = [bool]$script:UiRun.Seen
        UnhandledCallback = [string]$script:UiRun.Unhandled
        DriverError = [string]$script:UiRun.DriverError
        HasCandidateAfter = [bool]$stateAfter.HasCandidate
        SnoozedAfter = [bool]$stateAfter.Snoozed
        RetryScheduledAfter = [bool]$stateAfter.RetryScheduled
        LastFailure = [string]$stateAfter.LastFailure
        Root = $demo.Root
    }
    $null = $script:CaseEvidence.Add([pscustomobject]$record)
    return [pscustomobject]@{ Result = $result; State = $stateAfter; Evidence = [pscustomobject]$record }
}

function Assert-UiScenario {
    param(
        [Parameter(Mandatory = $true)]$Case,
        [Parameter(Mandatory = $true)][string[]]$Statuses,
        [Parameter(Mandatory = $true)][bool]$HasCandidate,
        [Parameter(Mandatory = $true)][bool]$Snoozed,
        [bool]$RetryScheduled = $false,
        [int]$StartCalls = -1
    )
    $actualStatus = [string]$Case.Evidence.ResultStatus
    Assert-Ui ($Statuses -contains $actualStatus) ($Case.Evidence.Name + ': result status is one of ' + ($Statuses -join ', ') + ' (got ' + $actualStatus + ')')
    Assert-Ui ([bool]$Case.State.HasCandidate -eq $HasCandidate) ($Case.Evidence.Name + ': candidate retention state')
    Assert-Ui ([bool]$Case.State.Snoozed -eq $Snoozed) ($Case.Evidence.Name + ': snooze state')
    if ($RetryScheduled) { Assert-Ui ([bool]$Case.State.RetryScheduled) ($Case.Evidence.Name + ': retry schedule recorded') }
    if ($StartCalls -ge 0) { Assert-Ui ([int]$Case.Evidence.StartCalls -eq $StartCalls) ($Case.Evidence.Name + ': repeated-click runspace call count') }
}

# Preflight before loading the production UI avoids creating a misleading
# result on a non-Windows or non-STA host.  No environment override is used:
# Test-UbCanShowPrompt must pass using the real input desktop probe.
if ($env:OS -ne 'Windows_NT') {
    Write-UiSkip 'Windows Forms and the production desktop probe require Windows.'
    exit 0
}
if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
    Write-UiSkip 'Run this script from powershell.exe -STA or pwsh -STA.'
    exit 0
}

$script:OriginalLocalAppData = $env:LOCALAPPDATA
$script:IsolatedRoot = Join-Path $env:TEMP ('ChatGPTUpdater UI events ' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $script:IsolatedRoot -Force
$env:LOCALAPPDATA = $script:IsolatedRoot

$summaryPath = $null
try {
    $loadError = $null
    try {
        . (Join-Path $script:ProjectRoot 'confirm-install.ps1') -UbCliCorePath (Join-Path $script:ProjectRoot 'update-chatgpt.ps1')
        Ensure-UbPromptTypes
    } catch {
        $loadError = $_
    }
    if ($null -ne $loadError) {
        if ($PSVersionTable.PSEdition -eq 'Core' -and [string]$loadError.Exception.Message -match 'System\.Windows\.Forms\.(Message|Primitives)') {
            Write-UiSkip ('PowerShell 7 cannot load the production WinForms references in this host: ' + $loadError.Exception.Message)
            exit 0
        }
        throw $loadError
    }

    $script:ProductionStartRunspace = (Get-Command Start-UbInstallRunspace -CommandType Function).ScriptBlock
    Invoke-UiProductionMockRunspaceChecks -ProductionStart $script:ProductionStartRunspace

    # confirm-install.ps1 is dot-sourced inside this try scope.  Replace the
    # functions in that same scope after loading so the production callback
    # resolves the explicit fake runspace boundary rather than the real MTA
    # RunspaceFactory implementation.
    Set-Item -Path Function:\Start-UbInstallRunspace -Value ((Get-Command Invoke-UiMockStartRunspace -CommandType Function).ScriptBlock)
    Set-Item -Path Function:\Get-UtInstalledPackage -Value ((Get-Command Invoke-UiGuardInstalledPackage -CommandType Function).ScriptBlock)
    Set-Item -Path Function:\Invoke-UtConfirmedInstall -Value ((Get-Command Invoke-UiGuardConfirmedInstall -CommandType Function).ScriptBlock)
    Set-Item -Path Function:\Install-UtPackage -Value ((Get-Command Invoke-UiGuardInstallPackage -CommandType Function).ScriptBlock)
    Set-Item -Path Function:\Add-AppxPackage -Value ((Get-Command Invoke-UiGuardAddAppxPackage -CommandType Function).ScriptBlock)
    if (-not (Test-UbCanShowPrompt)) {
        Write-UiSkip 'The production Test-UbCanShowPrompt desktop probe reported no visible input desktop.'
        exit 0
    }

    $commandKeyFlags = [Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::NonPublic
    $script:ProcessCmdKeyGuardMethod = [UbPromptForm].GetMethod('ProcessCmdKey', $commandKeyFlags)
    Assert-Ui ($null -ne $script:ProcessCmdKeyGuardMethod -and $script:ProcessCmdKeyGuardMethod.DeclaringType.Name -eq 'UbPromptForm') 'production form declares the ProcessCmdKey Enter guard'
    $script:ProcessDialogKeyGuardMethod = [UbPromptForm].GetMethod('ProcessDialogKey', $commandKeyFlags)
    Assert-Ui ($null -ne $script:ProcessDialogKeyGuardMethod -and $script:ProcessDialogKeyGuardMethod.DeclaringType.Name -eq 'UbPromptForm') 'production form declares the ProcessDialogKey Enter guard'
    Invoke-UiFocusedEnterPreProcess

    $later = Invoke-UiScenario -Name 'Later' -Action Later
    Assert-UiScenario -Case $later -Statuses @('Snoozed') -HasCandidate $true -Snoozed $true

    $x = Invoke-UiScenario -Name 'X' -Action X
    Assert-UiScenario -Case $x -Statuses @('Snoozed') -HasCandidate $true -Snoozed $true

    $esc = Invoke-UiScenario -Name 'Esc' -Action Esc
    Assert-UiScenario -Case $esc -Statuses @('Snoozed') -HasCandidate $true -Snoozed $true

    $timeout = Invoke-UiScenario -Name 'Timeout' -Action Timeout -PromptTimeoutSeconds 1
    Assert-UiScenario -Case $timeout -Statuses @('Snoozed') -HasCandidate $true -Snoozed $true

    $enter = Invoke-UiScenario -Name 'EnterSuppressed' -Action Enter
    Assert-UiScenario -Case $enter -Statuses @('Snoozed') -HasCandidate $true -Snoozed $true

    $success = Invoke-UiScenario -Name 'InstallSuccess' -Action Install -MockResult Success
    Assert-UiScenario -Case $success -Statuses @('Installed','AlreadyCurrent') -HasCandidate $false -Snoozed $false -StartCalls 1

    $deferred = Invoke-UiScenario -Name 'InstallDeferred' -Action Install -MockResult Deferred
    Assert-UiScenario -Case $deferred -Statuses @('Deferred') -HasCandidate $true -Snoozed $true -StartCalls 1
    $deferredHint = [string]$deferred.Evidence.StatusLabelText
    $deferredText = ConvertFrom-UbUnicodeText '\u66f4\u65b0\u5df2\u6682\u5b58'
    $nextLaunchText = ConvertFrom-UbUnicodeText '\u4e0b\u6b21\u542f\u52a8'
    Assert-Ui ($deferredHint -like ('*' + $deferredText + '*') -and $deferredHint -like ('*' + $nextLaunchText + '*')) 'Deferred UI hint explains that registration completes on the next launch'
    Assert-Ui ([int]$deferred.Evidence.StatusLabelHeight -ge [int]$deferred.Evidence.StatusLabelMeasuredHeight) 'Deferred UI status label contains its full measured text'

    $d02 = Invoke-UiScenario -Name 'InstallD02' -Action Install -MockResult D02
    Assert-UiScenario -Case $d02 -Statuses @('Failed') -HasCandidate $true -Snoozed $true -StartCalls 1
    $d02Hint = [string]$d02.Evidence.StatusLabelText
    $resourceText = ConvertFrom-UbUnicodeText '\u5b89\u88c5\u5305\u8d44\u6e90'
    $serviceText = ConvertFrom-UbUnicodeText '\u540e\u53f0\u670d\u52a1'
    $noWindowText = ConvertFrom-UbUnicodeText '\u65e0 ChatGPT \u7a97\u53e3'
    $incompleteText = ConvertFrom-UbUnicodeText '\u66f4\u65b0\u672a\u5b8c\u6210'
    $cachedText = ConvertFrom-UbUnicodeText '\u7f13\u5b58\u5305'
    $oldHintText = ConvertFrom-UbUnicodeText '\u6b63\u5e38\u9000\u51fa ChatGPT'
    $restartText = ConvertFrom-UbUnicodeText '\u91cd\u542f Windows \u540e\u91cd\u8bd5'
    Assert-Ui (
        $d02Hint -like '*0x80073D02*' -and
        $d02Hint -like ('*' + $resourceText + '*') -and
        $d02Hint -like ('*' + $serviceText + '*') -and
        $d02Hint -like ('*' + $noWindowText + '*') -and
        $d02Hint -like ('*' + $incompleteText + '*') -and
        $d02Hint -like ('*' + $cachedText + '*') -and
        $d02Hint -like ('*' + $restartText + '*') -and
        $d02Hint -like '*background.log*' -and
        $d02Hint -notlike ('*' + $oldHintText + '*')
    ) 'D02 UI hint explains package/background-service use, incomplete update, retained cache and restart guidance'
    Assert-Ui ([int]$d02.Evidence.StatusLabelHeight -ge [int]$d02.Evidence.StatusLabelMeasuredHeight) 'D02 UI status label contains its full uncapped measured text'
    Assert-Ui ([int]$d02.Evidence.StatusLabelBottom -lt [int]$d02.Evidence.InstallButtonTop) 'D02 UI status label does not overlap the install button'
    Assert-Ui ([int]$d02.Evidence.LaterButtonTop -ge [int]$d02.Evidence.InstallButtonTop -and [int]$d02.Evidence.LaterButtonTop -lt [int]$d02.Evidence.ClientHeight) 'D02 UI buttons remain inside the form client area'

    $changed = Invoke-UiScenario -Name 'InstallChanged' -Action Install -MockResult Changed
    Assert-UiScenario -Case $changed -Statuses @('CandidateChanged') -HasCandidate $false -Snoozed $false -StartCalls 1

    $repeated = Invoke-UiScenario -Name 'RepeatedInstallClick' -Action RepeatedInstall -MockResult Success
    Assert-UiScenario -Case $repeated -Statuses @('Installed','AlreadyCurrent') -HasCandidate $false -Snoozed $false -StartCalls 1

    $progressClose = Invoke-UiScenario -Name 'ProgressCloseLifecycle' -Action ProgressClose -MockResult Success
    Assert-UiScenario -Case $progressClose -Statuses @('Installed','AlreadyCurrent') -HasCandidate $false -Snoozed $false -StartCalls 1

    $startup = Invoke-UiScenario -Name 'StartupRunspaceFailure' -Action StartupFailure -ThrowOnStart
    Assert-UiScenario -Case $startup -Statuses @('Snoozed','Ready') -HasCandidate $true -Snoozed $true -RetryScheduled $true -StartCalls 1

    Assert-Ui ($script:ForbiddenProductionCalls -eq 0) ('no production AppX/deployment call escaped DemoMode (calls=' + $script:ForbiddenProductionCalls + ')')

    $evidenceDirectory = if ([string]::IsNullOrWhiteSpace($script:EvidenceDirectory)) {
        Join-Path $script:ProjectRoot 'tests\evidence\segmented-background'
    } else { [IO.Path]::GetFullPath($script:EvidenceDirectory) }
    $null = New-Item -ItemType Directory -Path $evidenceDirectory -Force
    $summaryPath = Join-Path $evidenceDirectory 'ui-events-summary.json'
    [pscustomobject]@{
        GeneratedUtc = [datetime]::UtcNow.ToString('o')
        Test = 'Test-UIEvents.ps1'
        TestTotal = $script:TestTotal
        TestFailed = $script:TestFailed
        DemoMode = $true
        DemoCandidateVersion = '99.999.0.0'
        ProductionInstallCalls = $script:ForbiddenProductionCalls
        FocusedPreProcess = [pscustomobject]@{
            Checked = $script:FocusedPreProcessChecked
            Handled = $script:FocusedPreProcessHandled
            InstallCalls = $script:FocusedPreProcessInstallCalls
        }
        DesktopInputAutomation = $false
        VisualAcceptance = 'Not performed; PNG is a DrawToBitmap control fixture rendering, not a desktop/focus screenshot.'
        FixturePath = $script:FixturePath
        Cases = @($script:CaseEvidence)
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    Write-Host ('[UI-EVENTS] evidence: ' + $summaryPath)
} finally {
    if ($null -ne $script:UiRun -and $null -ne $script:UiRun.Driver) {
        try { $script:UiRun.Driver.Stop() } catch { }
        try { $script:UiRun.Driver.Dispose() } catch { }
    }
    $env:LOCALAPPDATA = $script:OriginalLocalAppData
    if (-not $KeepTemp -and (Test-Path -LiteralPath $script:IsolatedRoot)) {
        Remove-Item -LiteralPath $script:IsolatedRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ('[UI-EVENTS] total=' + $script:TestTotal + ' failed=' + $script:TestFailed)
if ($script:TestFailed -gt 0) { exit 1 }
exit 0
