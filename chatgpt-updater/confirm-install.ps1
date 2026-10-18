#requires -Version 5.1
<##
    Explicit installation confirmation process.

    The only production install call in this file is the user-button callback,
    which invokes the core's Invoke-UtConfirmedInstall API.  The scheduled
    worker never reaches that API.  A prompt holds only the prompt lock while
    it is visible; the core reacquires update.lock for its short validation /
    deployment transaction.
##>
[CmdletBinding()]
param(
    [Alias('Root')][string]$UbCliRoot,
    [Alias('CorePath')][string]$UbCliCorePath,
    [Alias('ExpectedKey')][string]$UbCliExpectedKey,
    [Alias('ExpectedVersion')][string]$UbCliExpectedVersion,
    [Alias('TestMode')][switch]$UbCliTestMode,
    [Alias('TestChoice')][ValidateSet('Install','Later','Timeout','Cancel','X','Esc')][string]$UbCliTestChoice,
    [Alias('Demo')][switch]$UbCliDemo,
    [Alias('DemoResult')][ValidateSet('Success','Deferred','D02','Changed')][string]$UbCliDemoResult = 'Success',
    [Alias('DemoChoice')][ValidateSet('Install','Later','Timeout','Cancel','X','Esc')][string]$UbCliDemoChoice,
    [Alias('TimeoutSeconds')][int]$UbCliTimeoutSeconds = 600,
    [Alias('StartupMarker')][string]$UbCliStartupMarker,
    [Alias('OpenApp')][switch]$UbCliOpenApp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($UbCliCorePath)) { $UbCliCorePath = Join-Path $PSScriptRoot 'update-chatgpt.ps1' }
. (Join-Path $PSScriptRoot 'background-common.ps1') -CorePath $UbCliCorePath

$script:UbConfirmCorePath = $UbCliCorePath
$script:UbInstallActive = $false
$script:UbInstallComplete = $false
$script:UbDecision = $null
$script:UbPromptResult = $null
$script:UbDemoResultObject = $null

function Ensure-UbPromptTypes {
    if ($null -ne ('UbPromptForm' -as [type])) { return }
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $formAssembly = [System.Windows.Forms.Form].Assembly.Location
    $drawingAssembly = [System.Drawing.Font].Assembly.Location
    $references = @($formAssembly,$drawingAssembly)
    $formsPrimitiveReference = @(
        (Join-Path $PSHOME 'ref\System.Windows.Forms.Primitives.dll'),
        (Join-Path $PSHOME 'System.Windows.Forms.Primitives.dll')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if ($null -ne $formsPrimitiveReference) { $references += [string]$formsPrimitiveReference }
    $primitiveReference = Join-Path $PSHOME 'ref\System.ComponentModel.Primitives.dll'
    if (Test-Path -LiteralPath $primitiveReference -PathType Leaf) { $references += $primitiveReference }
    $drawingPrimitiveReference = Join-Path $PSHOME 'ref\System.Drawing.Primitives.dll'
    if (Test-Path -LiteralPath $drawingPrimitiveReference -PathType Leaf) { $references += $drawingPrimitiveReference }
    Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Windows.Forms;

public sealed class UbPromptForm : Form {
    public readonly Button InstallButton;
    public readonly Button LaterButton;
    public readonly Label StatusLabel;

    public UbPromptForm(string currentVersion, string newVersion) {
        Text = "ChatGPT \u65b0\u7248\u672c\u5df2\u51c6\u5907\u597d";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        StartPosition = FormStartPosition.CenterScreen;
        ShowInTaskbar = true;
        TopMost = false;
        MaximizeBox = false;
        MinimizeBox = false;
        KeyPreview = true;
        AutoSize = false;
        ClientSize = new Size(470, 320);

        var title = new Label();
        title.Text = "ChatGPT \u65b0\u7248\u672c\u5df2\u51c6\u5907\u597d";
        title.Font = new Font(Font.FontFamily, 12, FontStyle.Bold);
        title.AutoSize = true;
        title.Location = new Point(20, 18);

        var versions = new Label();
        versions.Text = "\u5f53\u524d\u7248\u672c\uff1a" + currentVersion + Environment.NewLine + "\u65b0\u7248\u672c\uff1a" + newVersion;
        versions.AutoSize = true;
        versions.Location = new Point(20, 55);

        var explanation = new Label();
        explanation.Text = "\u5b89\u88c5\u5305\u5df2\u4e0b\u8f7d\uff0c\u51c6\u5907\u9636\u6bb5\u5b89\u5168\u9a8c\u8bc1\u901a\u8fc7\u3002" + Environment.NewLine +
            "\u5b89\u88c5\u524d\u4f1a\u518d\u6b21\u9a8c\u8bc1\u3002\u82e5 ChatGPT \u6216\u540e\u53f0\u670d\u52a1\u6b63\u5728\u8fd0\u884c\uff0c\u66f4\u65b0\u4f1a\u6682\u5b58\u5e76\u5728\u4e0b\u6b21\u542f\u52a8\u65f6\u5b8c\u6210\uff0c\u4e0d\u4f1a\u5f3a\u5236\u5173\u95ed\u5e94\u7528\u6216\u505c\u6b62\u670d\u52a1\u3002";
        explanation.AutoSize = true;
        explanation.MaximumSize = new Size(430, 80);
        explanation.Location = new Point(20, 100);

        StatusLabel = new Label();
        StatusLabel.Text = "\u7b49\u5f85\u9009\u62e9\uff08\u65e0\u4eba\u56de\u5e94\u5c06\u5728\u7ea6 10 \u5206\u949f\u540e\u7a0d\u540e\uff09";
        StatusLabel.AutoSize = true;
        StatusLabel.MaximumSize = new Size(430, 55);
        StatusLabel.Location = new Point(20, 190);

        InstallButton = new Button();
        InstallButton.Text = "\u7acb\u5373\u5b89\u88c5";
        InstallButton.Size = new Size(115, 32);
        InstallButton.Location = new Point(215, 260);
        InstallButton.TabStop = false;

        LaterButton = new Button();
        LaterButton.Text = "\u7a0d\u540e";
        LaterButton.Size = new Size(95, 32);
        LaterButton.Location = new Point(340, 260);
        LaterButton.TabStop = true;

        Controls.Add(title);
        Controls.Add(versions);
        Controls.Add(explanation);
        Controls.Add(StatusLabel);
        Controls.Add(InstallButton);
        Controls.Add(LaterButton);
        // Do not set AcceptButton or CancelButton.  Enter must never grant
        // installation consent; Escape and the window X are handled by the
        // PowerShell event handlers as a snooze.
    }

    protected override bool ShowWithoutActivation { get { return true; } }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData) {
        if ((keyData & Keys.KeyCode) == Keys.Enter) return true;
        return base.ProcessCmdKey(ref msg, keyData);
    }

    protected override bool ProcessDialogKey(Keys keyData) {
        if ((keyData & Keys.KeyCode) == Keys.Enter) return true;
        return base.ProcessDialogKey(keyData);
    }
}

public static class UbForegroundProbe {
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
}
'@ -Language CSharp -ReferencedAssemblies $references -ErrorAction Stop
}

function Get-UbPromptCandidate {
    param([Parameter(Mandatory = $true)][string]$StateRoot, [Parameter(Mandatory = $true)][string]$Key, [Parameter(Mandatory = $true)][string]$Version)
    $lock = $null
    try {
        $lock = Enter-UbStateLock -Root $StateRoot
        $state = Read-UbState -Root $StateRoot
        $candidate = Get-UbProperty $state 'Candidate'
        if ($null -eq $candidate) { return $null }
        $candidate = Assert-UbCandidate $candidate
        if ([string]$candidate.Key -cne (ConvertTo-UbKey $Key)) { return $null }
        if ([string]$candidate.Version -cne (ConvertTo-UbVersionText $Version)) { return $null }
        return $candidate
    } finally { if ($null -ne $lock) { $lock.Dispose() } }
}

function ConvertFrom-UbUnicodeText {
    param([Parameter(Mandatory = $true)][string]$Text)
    return [Text.RegularExpressions.Regex]::Unescape($Text)
}

function New-UbDemoState {
    param([string]$DemoRoot)
    $root = if ([string]::IsNullOrWhiteSpace($DemoRoot)) { Join-Path $env:TEMP ('ChatGPTUpdater-Demo-' + [guid]::NewGuid().ToString('N')) } else { $DemoRoot }
    $null = Assert-UbDirectory -Path $root
    $metadata = [pscustomobject]@{
        Architecture = 'x64'
        Version = '99.999.0.0'
        ContentLength = [int64]1234
        ETag = '"demo-etag"'
        Url = 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix'
    }
    $snapshot = ConvertTo-UbMetadataSnapshot -Metadata $metadata -Architecture 'x64' -SHA256 ('0' * 64)
    $candidate = New-UbCandidate -Key 'demo-x64-99-999-0-0' -Version '99.999.0.0' -Snapshot $snapshot
    $null = Set-UbCandidate -Root $root -Candidate $candidate -Now ([DateTime]::UtcNow)
    return [pscustomobject]@{ Root = $root; Candidate = $candidate }
}

function Get-UbDemoInstallResult {
    param([ValidateSet('Success','Deferred','D02','Changed')][string]$Result = 'Success')
    switch ($Result) {
        'Success' { return [pscustomobject]@{ Code = 0; Status = 'Installed'; Message = 'TEST/MOCK: installation verified successfully.' } }
        'Deferred' { return [pscustomobject]@{ Code = 14; Status = 'Deferred'; Message = 'TEST/MOCK: update staged with deferred registration; the registered version is unchanged.' } }
        'D02' { return [pscustomobject]@{ Code = 10; Status = 'Failed'; Message = 'TEST/MOCK: 0x80073D02; package resources are in use. A background service may still hold them even when no ChatGPT window is open. Update incomplete; cached package retained. See background.log for details.' } }
        'Changed' { return [pscustomobject]@{ Code = 0; Status = 'CandidateChanged'; Message = 'TEST/MOCK: HEAD snapshot changed; the candidate was not installed.' } }
    }
}

function Invoke-UbInstallBoundary {
    param([Parameter(Mandatory = $true)][string]$Key, [Parameter(Mandatory = $true)][string]$Version, [switch]$Mock, [ValidateSet('Success','Deferred','D02','Changed')][string]$MockResult = 'Success')
    if ($Mock) { return Get-UbDemoInstallResult -Result $MockResult }
    # This is the sole production consent boundary.  The worker has no call
    # path to this function; it only launches this process after the button.
    return Invoke-UtConfirmedInstall -ExpectedKey $Key -ExpectedVersion $Version
}

function Start-UbInstallRunspace {
    param(
        [Parameter(Mandatory = $true)][string]$Core,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Version,
        [switch]$Mock,
        [ValidateSet('Success','Deferred','D02','Changed')][string]$MockResult = 'Success'
    )
    $pool = $null
    $ps = $null
    try {
        $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $pool.ApartmentState = [System.Threading.ApartmentState]::MTA
        $pool.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $pool.Open()
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $pool
        $code = @'
param($corePath, $candidateKey, $candidateVersion, $isMock, $mockResult)
if ($isMock) {
    switch ($mockResult) {
        'Deferred' { [pscustomobject]@{ Code = 14; Status = 'Deferred'; Message = 'TEST/MOCK: update staged with deferred registration; the registered version is unchanged.' }; return }
        'D02' { [pscustomobject]@{ Code = 10; Status = 'Failed'; Message = 'TEST/MOCK: 0x80073D02; package resources are in use. A background service may still hold them even when no ChatGPT window is open. Update incomplete; cached package retained. See background.log for details.' }; return }
        'Changed' { [pscustomobject]@{ Code = 0; Status = 'CandidateChanged'; Message = 'TEST/MOCK: HEAD snapshot changed; the candidate was not installed.' }; return }
        default { [pscustomobject]@{ Code = 0; Status = 'Installed'; Message = 'TEST/MOCK: installation verified successfully.' }; return }
    }
}
. $corePath
Invoke-UtConfirmedInstall -ExpectedKey $candidateKey -ExpectedVersion $candidateVersion
'@
        $null = $ps.AddScript($code).AddArgument($Core).AddArgument($Key).AddArgument($Version).AddArgument([bool]$Mock).AddArgument($MockResult)
        $async = $ps.BeginInvoke()
        return [pscustomobject]@{ PowerShell = $ps; Runspace = $pool; Async = $async }
    } catch {
        if ($null -ne $ps) { $ps.Dispose() }
        if ($null -ne $pool) { $pool.Dispose() }
        throw
    }
}

function Complete-UbInstallResult {
    param([Parameter(Mandatory = $true)]$Result, [Parameter(Mandatory = $true)][string]$StateRoot)
    $resultObject = @($Result) | Select-Object -Last 1
    if ($null -eq $resultObject) {
        $message = 'Installation returned no result.'
        $null = Set-UbSnooze -Root $StateRoot
        Write-UbLog -Root $StateRoot -Message ('Confirmed installation failed; Ready candidate retained: ' + $message)
        return [pscustomobject]@{ Code = 1; Status = 'Failed'; Message = $message }
    }
    $status = [string](Get-UbProperty $resultObject 'Status')
    $message = [string](Get-UbProperty $resultObject 'Message')
    if ($status -eq 'Installed' -or $status -eq 'AlreadyCurrent') {
        $null = Clear-UbCandidate -Root $StateRoot -Message $status
        Write-UbLog -Root $StateRoot -Message ("Confirmed installation completed: {0}." -f $status)
    } elseif ($status -eq 'Deferred') {
        $null = Set-UbDeferred -Root $StateRoot
        Write-UbLog -Root $StateRoot -Message ('Confirmed installation deferred; Ready candidate retained until the next launch: ' + $message)
    } elseif ($status -eq 'CandidateChanged') {
        $null = Clear-UbCandidate -Root $StateRoot -Message 'Candidate changed; a later worker run must prepare and ask again.' -ImmediateRetry
        Write-UbLog -Root $StateRoot -Message 'Candidate changed during confirmation; no installation was performed.'
    } else {
        $null = Set-UbSnooze -Root $StateRoot
        Write-UbLog -Root $StateRoot -Message ('Confirmed installation failed; Ready candidate retained: ' + $message)
    }
    return [pscustomobject]@{ Code = [int](Get-UbProperty $resultObject 'Code'); Status = $status; Message = $message }
}

function Invoke-UbTestPrompt {
    param([Parameter(Mandatory = $true)][string]$StateRoot, [Parameter(Mandatory = $true)]$Candidate, [ValidateSet('Install','Later','Timeout','Cancel','X','Esc')][string]$Choice, [switch]$MockInstall, [ValidateSet('Success','Deferred','D02','Changed')][string]$MockResult = 'Success', [datetime]$PromptNow = [datetime]::MinValue)
    if ([string]::IsNullOrWhiteSpace($Choice)) { $Choice = 'Later' }
    if ($Choice -eq 'Install') {
        $result = Invoke-UbInstallBoundary -Key $Candidate.Key -Version $Candidate.Version -Mock:$MockInstall -MockResult $MockResult
        return Complete-UbInstallResult -Result $result -StateRoot $StateRoot
    }
    $null = Set-UbSnooze -Root $StateRoot -Now $PromptNow
    Write-UbLog -Root $StateRoot -Message ("Prompt decision {0}; no installation was authorized." -f $Choice)
    return [pscustomobject]@{ Code = 0; Status = 'Snoozed'; Message = 'No installation was authorized.'; Choice = $Choice }
}

function Invoke-UbConfirmationPrompt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Version,
        [string]$PromptCorePath,
        [switch]$TestMode,
        [ValidateSet('Install','Later','Timeout','Cancel','X','Esc')][string]$Choice,
        [switch]$DemoMode,
        [ValidateSet('Success','Deferred','D02','Changed')][string]$MockResult = 'Success',
        [int]$PromptTimeoutSeconds = 600,
        [switch]$OpenApp,
        [datetime]$PromptNow = [datetime]::MinValue,
        [string]$StartupMarker
    )
    $promptLock = $null
    try {
        if ([string]::IsNullOrWhiteSpace($PromptCorePath)) { $PromptCorePath = $script:UbConfirmCorePath }
        $script:UbPromptResult = $null
        $script:UbDecision = $null
        $script:UbInstallActive = $false
        $script:UbInstallComplete = $false
        $promptLock = Enter-UbPromptLock -Root $StateRoot
        $candidate = Get-UbPromptCandidate -StateRoot $StateRoot -Key $Key -Version $Version
        if ($null -eq $candidate) { return [pscustomobject]@{ Code = 0; Status = 'CandidateChanged'; Message = 'The requested candidate is no longer current.' } }
        if ($TestMode) { return Invoke-UbTestPrompt -StateRoot $StateRoot -Candidate $candidate -Choice $Choice -MockInstall:$true -MockResult $MockResult -PromptNow $PromptNow }
        if (-not (Test-UbCanShowPrompt)) { return [pscustomobject]@{ Code = 0; Status = 'Ready'; Message = 'The interactive desktop is unavailable; candidate retained.' } }
        Ensure-UbPromptTypes

        $beforeHwnd = [UbForegroundProbe]::GetForegroundWindow()
        $currentVersion = '(not installed)'
        if ($DemoMode) { $currentVersion = 'TEST/MOCK demo' }
        else {
            try {
                $installed = Get-UtInstalledPackage
                if ($null -ne $installed) { $currentVersion = [string]$installed.Version }
            } catch { $currentVersion = '(query failed; install will re-validate)' }
        }
        $form = New-Object -TypeName UbPromptForm -ArgumentList ([string]$currentVersion),([string]$candidate.Version)
        if ($DemoMode) { $form.Text = $form.Text + ' [TEST/MOCK]' }
        $form.Tag = [string]$beforeHwnd.ToInt64()
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 1000
        $started = [DateTime]::UtcNow
        $ui = @{ Operation = $null; ShownHwnd = [IntPtr]::Zero }
        $poll = New-Object System.Windows.Forms.Timer
        $poll.Interval = 200
        $script:UbInstallActive = $false
        $script:UbInstallComplete = $false
        $script:UbDecision = $null

        $laterHandler = {
            if ($script:UbInstallActive) { return }
            if ($script:UbInstallComplete) { $script:UbDecision = 'Close' }
            else { $script:UbDecision = 'Later'; $null = Set-UbSnooze -Root $StateRoot; Write-UbLog -Root $StateRoot -Message 'User selected Later.' }
            $form.Close()
        }
        $form.LaterButton.Add_Click($laterHandler)
        $form.InstallButton.Add_Click({
            if ($script:UbInstallActive -or $script:UbInstallComplete) { return }
            $script:UbInstallActive = $true
            $form.InstallButton.Enabled = $false
            $form.LaterButton.Enabled = $false
            $form.StatusLabel.Text = ConvertFrom-UbUnicodeText '\u6b63\u5728\u91cd\u65b0\u9a8c\u8bc1\u5e76\u5b89\u88c5\uff0c\u8bf7\u7a0d\u5019\u3002'
            $timer.Stop()
            try {
                $ui.Operation = Start-UbInstallRunspace -Core $PromptCorePath -Key $candidate.Key -Version $candidate.Version -Mock:$DemoMode -MockResult $MockResult
                $poll.Start()
            } catch {
                $message = $_.Exception.Message
                $script:UbInstallActive = $false
                $form.InstallButton.Enabled = $true
                $form.LaterButton.Enabled = $true
                $timer.Start()
                try { $null = Set-UbFailure -Root $StateRoot -Now ([DateTime]::UtcNow) -Message ('Install worker startup failed: ' + $message) } catch { }
                Write-UbLog -Root $StateRoot -Message ('Install worker startup failed; Ready candidate retained for a later retry: ' + $message)
                $form.StatusLabel.Text = ConvertFrom-UbUnicodeText '\u5b89\u88c5\u542f\u52a8\u5931\u8d25\uff1b\u5df2\u4fdd\u7559\u66f4\u65b0\u5e76\u7a0d\u540e\u91cd\u8bd5\u3002'
            }
        })
        $form.Add_KeyDown({ param($sender,$event)
            if ($event.KeyCode -eq [Windows.Forms.Keys]::Escape) { $event.Handled = $true; $event.SuppressKeyPress = $true; & $laterHandler }
            elseif ($event.KeyCode -eq [Windows.Forms.Keys]::Enter) { $event.Handled = $true; $event.SuppressKeyPress = $true }
        })
        $form.Add_FormClosing({ param($sender,$event)
            if ($script:UbInstallActive) { $event.Cancel = $true; $sender.Hide(); Write-UbLog -Root $StateRoot -Message 'Install progress window hidden; deployment continues.'; return }
            if ($script:UbInstallComplete) { if ($null -eq $script:UbDecision) { $script:UbDecision = 'Close' }; return }
            if ($script:UbDecision -eq $null) { $script:UbDecision = 'Later'; $null = Set-UbSnooze -Root $StateRoot; Write-UbLog -Root $StateRoot -Message 'Prompt closed (X); no installation was authorized.' }
        })
        $timer.Add_Tick({
            if ((([DateTime]::UtcNow - $started).TotalSeconds) -ge $PromptTimeoutSeconds) {
                $timer.Stop(); if (-not $script:UbInstallActive) { $script:UbDecision = 'Timeout'; $null = Set-UbSnooze -Root $StateRoot; Write-UbLog -Root $StateRoot -Message 'Prompt timed out; no installation was authorized.'; $form.Close() }
            }
        })
        $poll.Add_Tick({
            $operation = $ui.Operation
            if ($null -eq $operation -or -not $operation.Async.IsCompleted) { return }
            $poll.Stop()
            try {
                $output = $operation.PowerShell.EndInvoke($operation.Async)
                $result = Complete-UbInstallResult -Result $output -StateRoot $StateRoot
            } catch {
                $message = $_.Exception.Message
                $result = [pscustomobject]@{ Code = 1; Status = 'Failed'; Message = $message }
                $null = Complete-UbInstallResult -Result $result -StateRoot $StateRoot
                Write-UbLog -Root $StateRoot -Message ('Install runspace failed; Ready candidate retained with a safe reminder: ' + $message)
            }
            $operation.PowerShell.Dispose(); $operation.Runspace.Dispose()
            $script:UbInstallActive = $false; $script:UbInstallComplete = $true; $script:UbPromptResult = $result
            if ([string]$result.Status -eq 'Installed' -or [string]$result.Status -eq 'AlreadyCurrent') { $form.StatusLabel.Text = ConvertFrom-UbUnicodeText '\u5b89\u88c5\u5df2\u6210\u529f\u5e76\u7ecf\u6838\u9a8c\u3002' }
            elseif ([string]$result.Status -eq 'Deferred') { $form.StatusLabel.Text = ConvertFrom-UbUnicodeText '\u66f4\u65b0\u5df2\u6682\u5b58\uff1b\u4e0b\u6b21\u542f\u52a8 ChatGPT \u65f6\u7531 Windows \u5b8c\u6210\u6ce8\u518c\u3002\u82e5\u4ecd\u672a\u66f4\u65b0\uff0c\u8bf7\u91cd\u542f Windows \u540e\u518d\u6b21\u8fd0\u884c\u66f4\u65b0\u5668\u3002' }
            elseif ([string]$result.Message -like '*0x80073D02*') { $form.StatusLabel.Text = ConvertFrom-UbUnicodeText '0x80073D02\uff1a\u5b89\u88c5\u5305\u8d44\u6e90\u88ab\u5360\u7528\uff1b\u65e0 ChatGPT \u7a97\u53e3\u65f6\uff0c\u540e\u53f0\u670d\u52a1\u4ecd\u53ef\u5360\u7528\u3002\u66f4\u65b0\u672a\u5b8c\u6210\uff0c\u7f13\u5b58\u5305\u5df2\u4fdd\u7559\uff1b\u8bf7\u91cd\u542f Windows \u540e\u91cd\u8bd5\uff0c\u8be6\u89c1 background.log\u3002' }
            else { $form.StatusLabel.Text = [string]$result.Message }
            if ($OpenApp -and -not $DemoMode -and [string]$result.Status -eq 'Installed') {
                try { Start-UtApp; Write-UbLog -Root $StateRoot -Message 'OpenApp launched after confirmed Installed result.' }
                catch { Write-UbLog -Root $StateRoot -Message ('OpenApp launch failed after confirmed Installed result: ' + $_.Exception.Message) }
            }
            $form.LaterButton.Text = ConvertFrom-UbUnicodeText '\u5173\u95ed'; $form.LaterButton.Enabled = $true
            if (-not $form.Visible) { $form.Show() }
        })
        $form.ActiveControl = $form.LaterButton
        $form.Add_Shown({
            $ui.ShownHwnd = [UbForegroundProbe]::GetForegroundWindow()
            if (-not [string]::IsNullOrWhiteSpace($StartupMarker)) { Write-UbPromptStartupMarker -Root $StateRoot -Path $StartupMarker }
            Write-UbLog -Root $StateRoot -Message ("Prompt shown focus evidence: before=0x{0:X}, shown=0x{1:X}; ShowWithoutActivation was requested." -f $beforeHwnd.ToInt64(), $ui.ShownHwnd.ToInt64())
        })
        $timer.Start()
        try {
            [Windows.Forms.Application]::Run($form)
            $afterHwnd = [UbForegroundProbe]::GetForegroundWindow()
            Write-UbLog -Root $StateRoot -Message ("Prompt closed focus evidence: before=0x{0:X}, shown=0x{1:X}, after=0x{2:X}; ShowWithoutActivation was requested." -f $beforeHwnd.ToInt64(), $ui.ShownHwnd.ToInt64(), $afterHwnd.ToInt64())
            if ($null -ne $script:UbPromptResult) { return $script:UbPromptResult }
            if ($script:UbDecision -eq 'Later' -or $script:UbDecision -eq 'Timeout' -or $script:UbDecision -eq 'Close') { return [pscustomobject]@{ Code = 0; Status = 'Snoozed'; Message = 'No installation was authorized.'; Choice = $script:UbDecision } }
            return [pscustomobject]@{ Code = 0; Status = 'Ready'; Message = 'Prompt ended; candidate retained.' }
        } finally {
            $timer.Stop(); $poll.Stop()
            $timer.Dispose(); $poll.Dispose(); $form.Dispose()
        }
    } finally { if ($null -ne $promptLock) { $promptLock.Dispose() } }
}

function Start-UtConfirmationPrompt {
    <#
        Core integration for a normal, manually started updater.  The core has
        already released its preparation lock and lease before calling this
        function.  Persisting the strict candidate index here lets a Later
        choice survive a restart while the actual deployment still goes only
        through the button callback above.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Prepared,
        [switch]$OpenApp
    )
    $metadata = Get-UbProperty $Prepared 'Metadata'
    if ($null -eq $metadata) { throw 'Prepared candidate metadata is missing.' }
    $architecture = [string](Get-UbProperty $metadata 'Architecture')
    if ([string]::IsNullOrWhiteSpace($architecture)) { throw 'Prepared candidate architecture is missing.' }
    $root = Get-UbRoot
    $candidate = ConvertTo-UbCandidateFromPrepared -Prepared $Prepared -Metadata $metadata -Architecture $architecture
    $null = Set-UbCandidate -Root $root -Candidate $candidate -Now ([DateTime]::UtcNow)
    $promptPath = Join-Path $PSScriptRoot 'confirm-install.ps1'
    # Keep WinForms in a dedicated Windows PowerShell STA process.  The core
    # caller may be PowerShell 7/MTA; it must only publish the candidate and
    # release its update lock before this detached prompt starts.
    try {
        $process = Start-UbPromptDetached -ScriptPath $promptPath -Root $root -ExpectedKey $candidate.Key -ExpectedVersion $candidate.Version -CorePath $script:UbConfirmCorePath -OpenApp:$OpenApp
        return [pscustomobject]@{ Code = 0; Status = 'Prompted'; Message = 'Confirmation prompt launched.'; ProcessId = $process.Id }
    } catch {
        $message = 'Confirmation prompt startup failed; Ready candidate retained.'
        Write-UbLog -Root $root -Message ($message + ' ' + $_.Exception.Message)
        $null = Set-UbFailure -Root $root -Now ([DateTime]::UtcNow) -Message ('Prompt startup failed: ' + $_.Exception.Message)
        return [pscustomobject]@{ Code = 1; Status = 'Ready'; Message = $message }
    }
}

if ($UbCliDemo) {
    $demoState = New-UbDemoState
    $UbCliRoot = $demoState.Root
    $UbCliExpectedKey = $demoState.Candidate.Key
    $UbCliExpectedVersion = $demoState.Candidate.Version
    $script:UbDemoRoot = $UbCliRoot
    Write-UbLog -Root $UbCliRoot -Message ("TEST/MOCK demo started; isolated state root: {0}; result={1}." -f $UbCliRoot, $UbCliDemoResult)
    if (-not [string]::IsNullOrWhiteSpace($UbCliDemoChoice)) { $UbCliTestChoice = $UbCliDemoChoice }
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = $null
    try {
        if ([string]::IsNullOrWhiteSpace($UbCliRoot) -or [string]::IsNullOrWhiteSpace($UbCliExpectedKey) -or [string]::IsNullOrWhiteSpace($UbCliExpectedVersion)) { throw 'Root, ExpectedKey and ExpectedVersion are required.' }
        if ($UbCliTestMode -and -not $UbCliDemo) {
            $result = Invoke-UbConfirmationPrompt -StateRoot $UbCliRoot -Key $UbCliExpectedKey -Version $UbCliExpectedVersion -PromptCorePath $UbCliCorePath -TestMode -Choice $UbCliTestChoice -MockResult $UbCliDemoResult -OpenApp:$UbCliOpenApp -StartupMarker $UbCliStartupMarker
        } else {
            $result = Invoke-UbConfirmationPrompt -StateRoot $UbCliRoot -Key $UbCliExpectedKey -Version $UbCliExpectedVersion -PromptCorePath $UbCliCorePath -DemoMode:$UbCliDemo -MockResult $UbCliDemoResult -PromptTimeoutSeconds $UbCliTimeoutSeconds -OpenApp:$UbCliOpenApp -StartupMarker $UbCliStartupMarker
        }
    } catch {
        $message = $_.Exception.Message
        if (-not [string]::IsNullOrWhiteSpace($UbCliRoot)) {
            try {
                Write-UbLog -Root $UbCliRoot -Message ('Confirmation process failed; Ready candidate retained: ' + $message)
                $null = Set-UbFailure -Root $UbCliRoot -Now ([DateTime]::UtcNow) -Message ('Confirmation process failed: ' + $message)
            } catch { }
        }
        $result = [pscustomobject]@{ Code = 1; Status = 'Ready'; Message = 'Confirmation process failed; Ready candidate retained.' }
    }
    if ($null -ne $result) { $result | ConvertTo-Json -Depth 8 -Compress }
    exit ([int](Get-UbProperty $result 'Code'))
}
