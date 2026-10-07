#requires -Version 5.1
<##
    Offline tests for segmented-download.ps1.

    The range planner, response validators, stream merge and process ownership
    are production code.  Only the network process boundary is replaced by the
    fixture below; no real curl request, signature check, AppX operation or
    scheduled task is performed.
##>
[CmdletBinding()]
param([switch]$KeepTemp)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:NonAscii = [string]([char]0x6D4B) + [string]([char]0x8BD5)
$script:TestRoot = Join-Path $env:TEMP ('segmented test ' + $script:NonAscii + ' [brackets] ' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($script:TestRoot)

. (Join-Path $script:ProjectRoot 'update-chatgpt.ps1')

$script:TestTotal = 0
$script:TestFailed = 0
$script:FixtureBytes = New-Object byte[] 0
$script:MockMode = 'normal'
$script:SerialCalls = 0
$script:SerialBackgroundCalls = 0
$script:StartedRanges = New-Object System.Collections.ArrayList
$script:MockAttempts = @{}
$script:FreshRetryChecks = 0
$script:CancelProcess = $null
$script:HeaderWatchdogPid = 0

function Fail-SegmentAssertion {
    param([string]$Message)
    $script:TestFailed++
    Write-Host ('    FAIL: ' + $Message) -ForegroundColor Red
}

function Assert-SegmentTrue {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { Fail-SegmentAssertion $Message }
}

function Assert-SegmentEqual {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { Fail-SegmentAssertion ('{0} -- expected [{1}], got [{2}]' -f $Message, $Expected, $Actual) }
}

function Assert-SegmentFailure {
    param([int]$Code, [scriptblock]$Body, [string]$Message)
    $threw = $false
    try { $null = & $Body } catch {
        $threw = $true
        $actual = Get-UtErrorCode -ErrorRecord $_ -Default -1
        Assert-SegmentEqual $Code $actual $Message
    }
    if (-not $threw) { Fail-SegmentAssertion ('{0} -- expected error code {1}' -f $Message, $Code) }
}

function Wait-SegmentProcessGone {
    param([int]$Id)
    if ($Id -le 0) { return $false }
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        $running = Get-Process -Id $Id -ErrorAction SilentlyContinue
        if ($null -eq $running) { return $true }
        Start-Sleep -Milliseconds 50
    }
    return $false
}

function Invoke-SegmentCase {
    param([string]$Name, [scriptblock]$Body)
    $script:TestTotal++
    Write-Host ('  - ' + $Name)
    $script:MockMode = 'normal'
    $script:StartedRanges.Clear()
    $script:SerialCalls = 0
    $script:SerialBackgroundCalls = 0
    $script:MockAttempts = @{}
    $script:FreshRetryChecks = 0
    $script:CancelProcess = $null
    $script:HeaderWatchdogPid = 0
    try { & $Body } catch {
        $script:TestFailed++
        Write-Host ('    FAIL: unhandled exception: ' + $_.Exception.Message) -ForegroundColor Red
        Write-Host ('          ' + $_.InvocationInfo.PositionMessage.Trim()) -ForegroundColor DarkGray
    }
}

function New-SegmentMetadata {
    param(
        $ETag = '"fixture-strong"',
        [long]$Length = 97
    )
    return [pscustomobject]@{
        Version       = [version]'26.930.7945.0'
        ContentLength = $Length
        ETag          = $ETag
        StrongETag    = ($ETag -eq '"fixture-strong"')
        Url           = 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix'
        FinalUri      = 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix'
        Architecture  = 'x64'
    }
}

function New-SegmentHeaders {
    param(
        [long]$Start,
        [long]$End,
        [long]$Total,
        [int]$Status = 206,
        [string]$ETag = '"fixture-strong"',
        [switch]$WrongRange,
        [switch]$WrongLength,
        [switch]$OmitETag
    )
    $rangeStart = $Start
    $rangeEnd = $End
    if ($WrongRange) { $rangeEnd++ }
    $length = $End - $Start + 1L
    if ($WrongLength) { $length++ }
    $headers = @{
        'content-length' = @([string]$length)
        etag = if ($OmitETag) { @() } else { @($ETag) }
    }
    if ($Status -eq 206) { $headers['content-range'] = @('bytes {0}-{1}/{2}' -f $rangeStart, $rangeEnd, $Total) }
    return $headers
}

# Network process boundary fixture.  Start returns a completed response object
# for ordinary cases, or one real child process in the cancellation case.
function Start-UtParallelRangeProcess {
    param([Parameter(Mandatory = $true)]$Request)
    [void]$script:StartedRanges.Add($Request)
    $attemptKey = if ($Request.Probe) { 'probe' } else { 'segment-{0}' -f $Request.Index }
    if (-not $script:MockAttempts.ContainsKey($attemptKey)) { $script:MockAttempts[$attemptKey] = 0 }
    $script:MockAttempts[$attemptKey] = [int]$script:MockAttempts[$attemptKey] + 1
    if (($script:MockMode -eq 'cancel' -or $script:MockMode -eq 'transient-exhausted') -and -not $Request.Probe -and $Request.Index -eq 0) {
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = (Get-Command powershell.exe).Source
        $info.Arguments = '-NoProfile -Command "Start-Sleep -Seconds 30"'
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $info
        [void]$process.Start()
        $script:CancelProcess = $process
        return [pscustomobject]@{ Process = $process }
    }
    if (($script:MockMode -eq 'native-noheader' -or $script:MockMode -eq 'native-malformed') -and -not $Request.Probe -and $Request.Index -eq 1 -and $script:MockAttempts[$attemptKey] -eq 1) {
        $headerText = if ($script:MockMode -eq 'native-malformed') { 'not an HTTP header' } else { '' }
        [IO.File]::WriteAllText($Request.HeaderPath, $headerText)
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = (Get-Command powershell.exe).Source
        $command = if ($script:MockMode -eq 'native-malformed') { 'exit 28' } else { 'Write-Output ''HTTPCODE=000''; Write-Output ''FINALURL={0}''; exit 28' -f $Request.FinalUri }
        $info.Arguments = '-NoProfile -Command "' + $command + '"'
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $info
        [void]$process.Start()
        return [pscustomobject]@{ Process = $process }
    }
    if ($script:MockMode -eq 'native-header-oversize' -and -not $Request.Probe -and $Request.Index -eq 1 -and $script:MockAttempts[$attemptKey] -eq 1) {
        $headerLimit = [long](Get-UtParallelHeaderLimit)
        $padding = [System.String]::new([char]0x41, [int]$headerLimit)
        $headerText = "HTTP/1.1 206 Partial Content`r`nX-Padding: $padding`r`n`r`n"
        [IO.File]::WriteAllText($Request.HeaderPath, $headerText, [Text.Encoding]::ASCII)
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = (Get-Command powershell.exe).Source
        $command = "Write-Output 'HTTPCODE=206'; Write-Output 'FINALURL=$($Request.FinalUri)'; Start-Sleep -Seconds 30"
        $info.Arguments = '-NoProfile -Command "' + $command + '"'
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $info
        [void]$process.Start()
        $script:CancelProcess = $process
        $script:HeaderWatchdogPid = [int]$process.Id
        return [pscustomobject]@{ Process = $process }
    }

    $status = 206
    $etag = '"fixture-strong"'
    $wrongRange = $false
    $wrongLength = $false
    $omitEtag = $false
    $probeWrongRange = $false
    $oversizeBody = $false
    $exitCode = 0
    $finalUri = $Request.FinalUri
    $transientFailure = $false
    $transientHttp = 0
    if ($script:MockMode -eq 'probe-200' -and $Request.Probe) { $status = 200 }
    if ($script:MockMode -eq 'probe-200-bad-exit' -and $Request.Probe) { $status = 200; $exitCode = 28 }
    if ($script:MockMode -eq 'probe-200-bad-range' -and $Request.Probe) { $status = 200; $probeWrongRange = $true }
    if ($script:MockMode -eq 'probe-412' -and $Request.Probe) { $status = 412 }
    if ($script:MockMode -eq 'probe-oversize-body' -and $Request.Probe) { $oversizeBody = $true }
    if ($script:MockMode -eq 'cancel' -and -not $Request.Probe -and $Request.Index -eq 1) { $status = 500 }
    if ($script:MockMode -eq 'bad-range' -and -not $Request.Probe -and $Request.Index -eq 1) { $wrongRange = $true }
    if ($script:MockMode -eq 'bad-length' -and -not $Request.Probe -and $Request.Index -eq 1) { $wrongLength = $true }
    if ($script:MockMode -eq 'bad-etag' -and -not $Request.Probe -and $Request.Index -eq 1) { $etag = '"changed"' }
    if ($script:MockMode -eq 'bad-status' -and -not $Request.Probe -and $Request.Index -eq 1) { $status = 206 }
    if ($script:MockMode -eq 'segment-200' -and -not $Request.Probe -and $Request.Index -eq 1) { $status = 200 }
    if ($script:MockMode -eq 'segment-412' -and -not $Request.Probe -and $Request.Index -eq 1) { $status = 412 }
    if ($script:MockMode -eq 'segment-redirect' -and -not $Request.Probe -and $Request.Index -eq 1) { $finalUri = 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-arm64.msix' }
    if ($script:MockMode -eq 'segment-oversize-body' -and -not $Request.Probe -and $Request.Index -eq 1) { $oversizeBody = $true }
    if ($script:MockMode -eq 'transport-206-missing-headers' -and -not $Request.Probe -and $Request.Index -eq 1 -and $script:MockAttempts[$attemptKey] -eq 1) { $exitCode = 28 }
    if ($script:MockMode -eq 'transport-oversize-body' -and -not $Request.Probe -and $Request.Index -eq 1 -and $script:MockAttempts[$attemptKey] -eq 1) { $exitCode = 28; $oversizeBody = $true }
    if ($script:MockMode -eq 'transport-200' -and -not $Request.Probe -and $Request.Index -eq 1 -and $script:MockAttempts[$attemptKey] -eq 1) { $status = 200; $exitCode = 28 }
    if ($script:MockMode -eq 'transport-412' -and -not $Request.Probe -and $Request.Index -eq 1 -and $script:MockAttempts[$attemptKey] -eq 1) { $status = 412; $exitCode = 28 }
    if ($script:MockMode -eq 'transport-etag' -and -not $Request.Probe -and $Request.Index -eq 1 -and $script:MockAttempts[$attemptKey] -eq 1) { $exitCode = 28; $etag = '"changed"' }
    if ($script:MockMode -eq 'transport-range' -and -not $Request.Probe -and $Request.Index -eq 1 -and $script:MockAttempts[$attemptKey] -eq 1) { $exitCode = 28; $wrongRange = $true }
    if ($script:MockMode -eq 'transport-redirect' -and -not $Request.Probe -and $Request.Index -eq 1 -and $script:MockAttempts[$attemptKey] -eq 1) { $exitCode = 28; $finalUri = 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-arm64.msix' }
    if (-not $Request.Probe -and $Request.Index -eq 1 -and $script:MockAttempts[$attemptKey] -eq 2 -and @('transient', 'transient-206', 'transient-http5xx', 'transient-exhausted', 'native-noheader') -contains $script:MockMode -and -not (Test-Path -LiteralPath $Request.OutputPath)) { $script:FreshRetryChecks++ }
    if (-not $Request.Probe -and $Request.Index -eq 1 -and (($script:MockMode -eq 'transient' -and $script:MockAttempts[$attemptKey] -eq 1) -or ($script:MockMode -eq 'transient-http5xx' -and $script:MockAttempts[$attemptKey] -eq 1) -or $script:MockMode -eq 'transient-exhausted')) {
        $transientFailure = $true
        if ($script:MockMode -eq 'transient-http5xx') { $exitCode = 22; $transientHttp = 500 } else { $exitCode = 28; $transientHttp = 0 }
    }
    if ($script:MockMode -eq 'transient-206' -and -not $Request.Probe -and $Request.Index -eq 1 -and $script:MockAttempts[$attemptKey] -eq 1) { $exitCode = 28 }
    if ($transientFailure) {
        [System.IO.File]::WriteAllBytes($Request.OutputPath, [byte[]](0xA5))
        return [pscustomobject]@{
            Response = [pscustomobject]@{
                ExitCode = $exitCode
                HttpCode = $transientHttp
                FinalUri = $finalUri
                Headers = @{}
                OutputPath = $Request.OutputPath
                HeaderStatusCode = $transientHttp
            }
        }
    }

    $bodyLength = [int]($Request.End - $Request.Start + 1L)
    if ($status -eq 200) { $bodyLength = 1 }
    if ($oversizeBody) { $bodyLength++ }
    $body = New-Object byte[] $bodyLength
    if ($status -eq 206) {
        for ($i = 0; $i -lt $bodyLength; $i++) { $body[$i] = $script:FixtureBytes[[int]($Request.Start + $i)] }
    } else {
        $body[0] = $script:FixtureBytes[0]
    }
    [System.IO.File]::WriteAllBytes($Request.OutputPath, $body)
    $headers = New-SegmentHeaders -Start $Request.Start -End $Request.End -Total $Request.Metadata.ContentLength -Status $status -ETag $etag -WrongRange:$wrongRange -WrongLength:$wrongLength -OmitETag:$omitEtag
    if ($script:MockMode -eq 'transport-206-missing-headers' -and -not $Request.Probe -and $Request.Index -eq 1 -and $script:MockAttempts[$attemptKey] -eq 1) {
        $headers.Remove('etag')
        $headers.Remove('content-range')
    }
    if ($status -eq 200) {
        $headers['content-length'] = @([string]$Request.Metadata.ContentLength)
        $headers.Remove('content-range')
        if ($probeWrongRange) { $headers['content-range'] = @('bytes 0-0/{0}' -f $Request.Metadata.ContentLength) }
    }
    if ($script:MockMode -eq 'header-oversize' -and -not $Request.Probe -and $Request.Index -eq 1 -and $script:MockAttempts[$attemptKey] -eq 1) {
        $headerLimit = [long](Get-UtParallelHeaderLimit)
        $padding = [System.String]::new([char]0x41, [int]$headerLimit)
        $headerText = "HTTP/1.1 206 Partial Content`r`nX-Padding: $padding`r`n`r`n"
        [IO.File]::WriteAllText($Request.HeaderPath, $headerText, [Text.Encoding]::ASCII)
    }
    $headerStatus = if ($script:MockMode -eq 'bad-status') { 200 } else { $status }
    return [pscustomobject]@{
        Response = [pscustomobject]@{
            ExitCode = $exitCode
            HttpCode = $status
            FinalUri = $finalUri
            Headers = $headers
            OutputPath = $Request.OutputPath
            HeaderStatusCode = $headerStatus
        }
    }
}

# Serial fallback boundary fixture.  It remains an explicit network boundary;
# all segment and merge checks above stay real production functions.
function Receive-UtCandidate {
    param([Parameter(Mandatory = $true)]$Metadata, [Parameter(Mandatory = $true)][string]$RunDirectory, [Parameter(Mandatory = $true)][string]$Architecture, [switch]$Background)
    $script:SerialCalls++
    if ($Background) { $script:SerialBackgroundCalls++ }
    $partial = Join-Path $RunDirectory ('ChatGPT-{0}.msix.partial' -f $Architecture)
    $final = Join-Path $RunDirectory ('ChatGPT-{0}.msix' -f $Architecture)
    [System.IO.File]::WriteAllBytes($partial, $script:FixtureBytes)
    Move-Item -LiteralPath $partial -Destination $final -Force
    return $final
}

# Fixture bytes are deterministic and small.  The expected package length is
# intentionally not an Int32 boundary in the planner tests below.
$script:FixtureBytes = New-Object byte[] 97
for ($fixtureIndex = 0; $fixtureIndex -lt $script:FixtureBytes.Length; $fixtureIndex++) { $script:FixtureBytes[$fixtureIndex] = [byte](($fixtureIndex * 17) % 251) }

Invoke-SegmentCase 'strict ETag kinds reject malformed values with metadata code' {
    Assert-SegmentEqual 'Missing' (Get-UtETagKind -ETag $null) 'null ETag is Missing'
    Assert-SegmentEqual 'Missing' (Get-UtETagKind) 'omitted ETag is Missing'
    Assert-SegmentEqual 'Strong' (Get-UtETagKind -ETag '"abc"') 'quoted ETag is Strong'
    Assert-SegmentEqual 'Weak' (Get-UtETagKind -ETag 'W/"abc"') 'weak ETag is Weak'
    Assert-SegmentFailure 5 { Get-UtETagKind -ETag 'abc' } 'unquoted ETag rejected'
    Assert-SegmentFailure 5 { Get-UtETagKind -ETag 'w/"abc"' } 'lowercase weak prefix rejected'
    Assert-SegmentFailure 5 { Get-UtETagKind -ETag ([char]34 + "a`n" + [char]34) } 'control character rejected'
    foreach ($transportCode in @(5, 6, 7, 18, 28, 52, 55, 56)) { Assert-SegmentTrue (Test-UtParallelTransportExitCode -ExitCode $transportCode) ('curl transport code {0} is retry eligible' -f $transportCode) }
    Assert-SegmentTrue (-not (Test-UtParallelTransportExitCode -ExitCode 22)) 'curl 22 needs the separate HTTP 5xx rule'
    Assert-SegmentTrue (-not (Test-UtParallelTransportExitCode -ExitCode 63)) 'curl size-cap exit is never retried'
}

Invoke-SegmentCase 'Int64 plans cover every supported connection count and tiny objects' {
    foreach ($connectionCount in @(1, 4, 8, 16)) {
        $plan = @(New-UtRangePlan -TotalLength 37 -Connections $connectionCount)
        Assert-SegmentEqual $connectionCount $plan.Count ("{0} ranges" -f $connectionCount)
        $expectedStart = [long]0
        foreach ($range in $plan) {
            Assert-SegmentEqual $expectedStart $range.Start 'range starts at previous end plus one'
            Assert-SegmentEqual ([long]($range.End - $range.Start + 1L)) $range.Length 'range length is inclusive'
            $expectedStart = [long]$range.End + 1L
        }
        Assert-SegmentEqual ([long]37) $expectedStart 'plan ends at total length'
    }
    Assert-SegmentEqual 3 (@(New-UtRangePlan -TotalLength 3 -Connections 8)).Count 'tiny object caps non-empty ranges'
    $largeTotal = [long]2147483649
    $largePlan = @(New-UtRangePlan -TotalLength $largeTotal -Connections 16)
    Assert-SegmentEqual ([long]($largeTotal - 1L)) $largePlan[$largePlan.Count - 1].End 'large Int64 end is exact'
}

Invoke-SegmentCase 'PS5 curl config and process arguments preserve special paths' {
    $path = Join-Path $script:TestRoot ('space ' + $script:NonAscii + ' [x].partial')
    $config = Join-Path $script:TestRoot 'quoted.curlrc'
    New-UtParallelCurlConfig -Path $config -ETag '"a\b"' | Out-Null
    $configText = [System.IO.File]::ReadAllText($config)
    Assert-SegmentTrue ($configText -like '*If-Match: \"a\\b\"*') 'config escapes quotes and backslashes'
    $arguments = @(New-UtRangeRequestArguments -Url 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -OutputPath $path -HeaderPath ($path + '.headers') -ConfigPath $config -Start 0 -End 7)
    Assert-SegmentTrue ($arguments -contains '--range') 'range argument is explicit'
    Assert-SegmentTrue ($arguments -contains '0-7') 'range offsets are Int64 text'
    $maxFilesize = [array]::IndexOf($arguments, '--max-filesize')
    Assert-SegmentTrue ($maxFilesize -ge 0) 'every range request has a curl size cap'
    Assert-SegmentEqual '8' $arguments[$maxFilesize + 1] 'segment cap equals requested length'
    $wideArguments = @(New-UtRangeRequestArguments -Url 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -OutputPath $path -HeaderPath ($path + '.headers') -ConfigPath $config -Start 2147483648 -End 2147483655)
    Assert-SegmentTrue ($wideArguments -contains '2147483648-2147483655') 'Int64 range offsets are not narrowed to Int32'
    $wideMaxFilesize = [array]::IndexOf($wideArguments, '--max-filesize')
    Assert-SegmentEqual '8' $wideArguments[$wideMaxFilesize + 1] 'Int64 segment keeps its exact cap'
    $probeArguments = @(New-UtRangeRequestArguments -Url 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -OutputPath $path -HeaderPath ($path + '.headers') -ConfigPath $config -Start 0 -End 0 -Probe)
    $probeMaxFilesize = [array]::IndexOf($probeArguments, '--max-filesize')
    Assert-SegmentEqual '1' $probeArguments[$probeMaxFilesize + 1] 'probe cap is one byte'
    Assert-SegmentTrue ($probeArguments -notcontains '--location') 'range requests never enable redirects'
    Assert-SegmentTrue ($probeArguments -notcontains '--insecure') 'range requests never disable TLS checks'
    Assert-SegmentTrue ($probeArguments -notcontains '--retry') 'range retries are restarted by the owned process controller'
    Assert-SegmentTrue ($arguments -notcontains '--compressed') 'identity encoding does not request compression'
    $quoted = New-UtParallelProcessArguments -Arguments ([string[]]@('--output', $path))
    Assert-SegmentTrue ($quoted -like '*"*space*"*') 'native argument is quoted'
}

Invoke-SegmentCase 'parallel fixture downloads, validates and merges out of order' {
    $run = Join-Path $script:TestRoot 'normal run'
    [void][System.IO.Directory]::CreateDirectory($run)
    $metadata = New-SegmentMetadata -Length $script:FixtureBytes.Length
    $path = Receive-UtParallelCandidate -Metadata $metadata -RunDirectory $run -Architecture x64 -Connections 8 -Background
    Assert-SegmentTrue (Test-Path -LiteralPath $path -PathType Leaf) 'merged package exists'
    Assert-SegmentEqual $script:FixtureBytes.Length ([long](Get-Item -LiteralPath $path).Length) 'merged package length'
    Assert-SegmentEqual 0 $script:SerialCalls 'strong ETag uses segmented backend'
    Assert-SegmentEqual ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash) ((Get-FileHash -InputStream ([IO.MemoryStream]::new($script:FixtureBytes)) -Algorithm SHA256).Hash) 'merged bytes hash'
}

Invoke-SegmentCase 'connections one and legal weak or missing ETag use serial backend' {
    foreach ($case in @(
        @{ Name = 'one'; Metadata = New-SegmentMetadata -Length $script:FixtureBytes.Length },
        @{ Name = 'weak'; Metadata = New-SegmentMetadata -ETag 'W/"weak"' -Length $script:FixtureBytes.Length },
        @{ Name = 'missing'; Metadata = New-SegmentMetadata -ETag $null -Length $script:FixtureBytes.Length }
    )) {
        $run = Join-Path $script:TestRoot ('serial-' + $case.Name)
        [void][IO.Directory]::CreateDirectory($run)
        $connections = if ($case.Name -eq 'one') { 1 } else { 8 }
        $path = Receive-UtParallelCandidate -Metadata $case.Metadata -RunDirectory $run -Architecture x64 -Connections $connections -Background
        Assert-SegmentTrue (Test-Path -LiteralPath $path -PathType Leaf) ($case.Name + ' serial result exists')
    }
    Assert-SegmentEqual 3 $script:SerialCalls 'all serial cases call the existing receiver'
    Assert-SegmentEqual 3 $script:SerialBackgroundCalls 'serial backend receives the background switch'
    Assert-SegmentEqual 0 $script:StartedRanges.Count 'weak and missing ETag never start range workers'
}

Invoke-SegmentCase 'validated 200 probe falls back once to serial download' {
    $script:MockMode = 'probe-200'
    $run = Join-Path $script:TestRoot 'probe 200'
    [void][IO.Directory]::CreateDirectory($run)
    $metadata = New-SegmentMetadata -Length $script:FixtureBytes.Length
    $path = Receive-UtParallelCandidate -Metadata $metadata -RunDirectory $run -Architecture x64 -Connections 16 -Background
    Assert-SegmentTrue (Test-Path -LiteralPath $path -PathType Leaf) '200 probe fallback result exists'
    Assert-SegmentEqual 1 $script:SerialCalls '200 probe fallback is one serial request'
    Assert-SegmentEqual 1 $script:StartedRanges.Count 'only bounded probe ran'
}

Invoke-SegmentCase 'one transport failure retries the same range from a fresh partial' {
    $script:MockMode = 'transient'
    $run = Join-Path $script:TestRoot 'transient retry'
    [void][IO.Directory]::CreateDirectory($run)
    $metadata = New-SegmentMetadata -Length $script:FixtureBytes.Length
    $path = Receive-UtParallelCandidate -Metadata $metadata -RunDirectory $run -Architecture x64 -Connections 4 -Background
    Assert-SegmentTrue (Test-Path -LiteralPath $path -PathType Leaf) 'retry eventually produces the package'
    Assert-SegmentEqual 2 $script:MockAttempts['segment-1'] 'transport failure has one retry'
    Assert-SegmentEqual 1 $script:FreshRetryChecks 'retry starts after deleting the old partial'
    Assert-SegmentEqual 0 $script:SerialCalls 'transport retry stays on segmented backend'
}

Invoke-SegmentCase 'transport failure with a valid 206 snapshot can retry' {
    $script:MockMode = 'transient-206'
    $run = Join-Path $script:TestRoot '206 transport retry'
    [void][IO.Directory]::CreateDirectory($run)
    $metadata = New-SegmentMetadata -Length $script:FixtureBytes.Length
    $path = Receive-UtParallelCandidate -Metadata $metadata -RunDirectory $run -Architecture x64 -Connections 4 -Background
    Assert-SegmentTrue (Test-Path -LiteralPath $path -PathType Leaf) '206 transport retry eventually produces the package'
    Assert-SegmentEqual 2 $script:MockAttempts['segment-1'] '206 transport failure has one retry'
    Assert-SegmentEqual 1 $script:FreshRetryChecks '206 retry starts from a fresh partial'
}

Invoke-SegmentCase 'HTTP 5xx with curl 22 receives one bounded retry' {
    $script:MockMode = 'transient-http5xx'
    $run = Join-Path $script:TestRoot 'http 5xx retry'
    [void][IO.Directory]::CreateDirectory($run)
    $metadata = New-SegmentMetadata -Length $script:FixtureBytes.Length
    $path = Receive-UtParallelCandidate -Metadata $metadata -RunDirectory $run -Architecture x64 -Connections 4 -Background
    Assert-SegmentTrue (Test-Path -LiteralPath $path -PathType Leaf) 'HTTP 5xx retry eventually produces the package'
    Assert-SegmentEqual 2 $script:MockAttempts['segment-1'] 'HTTP 5xx has one retry'
    Assert-SegmentEqual 1 $script:FreshRetryChecks 'HTTP 5xx retry starts from a fresh partial'
}

Invoke-SegmentCase 'pre-HTTP transport with an empty dump-header retries once' {
    $script:MockMode = 'native-noheader'
    $run = Join-Path $script:TestRoot 'native noheader retry'
    [void][IO.Directory]::CreateDirectory($run)
    $metadata = New-SegmentMetadata -Length $script:FixtureBytes.Length
    $path = Receive-UtParallelCandidate -Metadata $metadata -RunDirectory $run -Architecture x64 -Connections 4 -Background
    Assert-SegmentTrue (Test-Path -LiteralPath $path -PathType Leaf) 'pre-HTTP retry eventually produces the package'
    Assert-SegmentEqual 2 $script:MockAttempts['segment-1'] 'pre-HTTP transport has one retry'
    Assert-SegmentEqual 1 $script:FreshRetryChecks 'pre-HTTP retry starts from fresh files'
}

Invoke-SegmentCase 'retry exhaustion cancels remaining owned workers' {
    $script:MockMode = 'transient-exhausted'
    $run = Join-Path $script:TestRoot 'retry exhaustion'
    [void][IO.Directory]::CreateDirectory($run)
    $metadata = New-SegmentMetadata -Length $script:FixtureBytes.Length
    Assert-SegmentFailure 6 { Receive-UtParallelCandidate -Metadata $metadata -RunDirectory $run -Architecture x64 -Connections 4 -Background } 'exhausted transport retry is terminal'
    Assert-SegmentEqual 2 $script:MockAttempts['segment-1'] 'transport failure has at most one retry'
    Assert-SegmentTrue ($null -ne $script:CancelProcess -and $script:CancelProcess.HasExited) 'terminal retry failure cancels another owned worker'
    if ($null -ne $script:CancelProcess) { $script:CancelProcess.Dispose() }
}

Invoke-SegmentCase 'semantic range failure is never retried' {
    $script:MockMode = 'bad-etag'
    $run = Join-Path $script:TestRoot 'semantic no retry'
    [void][IO.Directory]::CreateDirectory($run)
    $metadata = New-SegmentMetadata -Length $script:FixtureBytes.Length
    Assert-SegmentFailure 6 { Receive-UtParallelCandidate -Metadata $metadata -RunDirectory $run -Architecture x64 -Connections 4 -Background } 'ETag mismatch is terminal'
    Assert-SegmentEqual 1 $script:MockAttempts['segment-1'] 'semantic ETag mismatch has no retry'
    Assert-SegmentEqual 0 $script:SerialCalls 'semantic failure does not serial-fallback'
}

Invoke-SegmentCase 'missing 206 identity headers and cap failures are never retried' {
    foreach ($mode in @('transport-206-missing-headers', 'transport-oversize-body', 'transport-200', 'transport-412', 'transport-etag', 'transport-range', 'transport-redirect', 'native-malformed', 'header-oversize', 'native-header-oversize')) {
        $script:MockMode = $mode
        $script:StartedRanges.Clear()
        $script:MockAttempts = @{}
        $run = Join-Path $script:TestRoot ('transport semantic ' + $mode)
        [void][IO.Directory]::CreateDirectory($run)
        $metadata = New-SegmentMetadata -Length $script:FixtureBytes.Length
        Assert-SegmentFailure 6 { Receive-UtParallelCandidate -Metadata $metadata -RunDirectory $run -Architecture x64 -Connections 4 -Background } ($mode + ' is terminal')
        Assert-SegmentEqual 1 $script:MockAttempts['segment-1'] ($mode + ' has no retry')
        if ($mode -eq 'native-header-oversize') {
            Assert-SegmentTrue ($script:HeaderWatchdogPid -gt 0) 'oversized header fixture started an owned helper process'
            Assert-SegmentTrue (Wait-SegmentProcessGone -Id $script:HeaderWatchdogPid) 'oversized header watchdog terminated its owned helper process'
        }
    }
}

Invoke-SegmentCase 'unsafe probe outcomes fail closed without serial fallback' {
    foreach ($mode in @('probe-200-bad-exit', 'probe-200-bad-range', 'probe-412', 'probe-oversize-body')) {
        $script:MockMode = $mode
        $script:StartedRanges.Clear()
        $script:SerialCalls = 0
        $run = Join-Path $script:TestRoot ('probe-failure-' + $mode)
        [void][IO.Directory]::CreateDirectory($run)
        $metadata = New-SegmentMetadata -Length $script:FixtureBytes.Length
        Assert-SegmentFailure 6 { Receive-UtParallelCandidate -Metadata $metadata -RunDirectory $run -Architecture x64 -Connections 8 -Background } ($mode + ' rejects the probe')
        Assert-SegmentEqual 0 $script:SerialCalls ($mode + ' never serial-fallbacks')
        Assert-SegmentEqual 1 $script:StartedRanges.Count ($mode + ' stops after the probe')
    }
}

Invoke-SegmentCase 'segment response errors fail closed without serial fallback' {
    foreach ($mode in @('bad-range', 'bad-length', 'bad-etag', 'bad-status', 'segment-200', 'segment-412', 'segment-redirect', 'segment-oversize-body')) {
        $script:MockMode = $mode
        $run = Join-Path $script:TestRoot ('failure-' + $mode)
        [void][IO.Directory]::CreateDirectory($run)
        $metadata = New-SegmentMetadata -Length $script:FixtureBytes.Length
        Assert-SegmentFailure 6 { Receive-UtParallelCandidate -Metadata $metadata -RunDirectory $run -Architecture x64 -Connections 4 -Background } ($mode + ' rejects the segment')
        Assert-SegmentEqual 0 $script:SerialCalls ($mode + ' does not serial-fallback')
    }
}

Invoke-SegmentCase 'malformed response headers and duplicate identity headers fail closed' {
    $headerPath = Join-Path $script:TestRoot 'malformed response.headers'
    [IO.File]::WriteAllText($headerPath, "HTTP/1.1 206 Partial Content`r`nContent-Range bytes 0-0/97`r`n`r`n")
    Assert-SegmentFailure 6 { Read-UtParallelHeaderFile -Path $headerPath } 'malformed response header line is rejected'
    $headerLimit = [long](Get-UtParallelHeaderLimit)
    $padding = [System.String]::new([char]0x41, [int]$headerLimit)
    $oversizedPath = Join-Path $script:TestRoot 'oversized valid response.headers'
    [IO.File]::WriteAllText($oversizedPath, ("HTTP/1.1 206 Partial Content`r`nX-Padding: $padding`r`n`r`n"), [Text.Encoding]::ASCII)
    Assert-SegmentTrue ([long](Get-Item -LiteralPath $oversizedPath -Force).Length -gt $headerLimit) 'oversized header fixture exceeds the configured cap'
    Assert-SegmentFailure 6 { Read-UtParallelHeaderFile -Path $oversizedPath } 'valid oversized response header is rejected before parsing'
    $duplicateHeaders = @{ etag = @('"fixture-strong"', '"changed"') }
    Assert-SegmentFailure 6 { Get-UtParallelHeaderValue -Headers $duplicateHeaders -Name 'etag' -Required } 'duplicate ETag is rejected'
}

Invoke-SegmentCase 'merge helper accepts shuffled ranges and streams exact bytes' {
    $run = Join-Path $script:TestRoot 'merge shuffled'
    [void][IO.Directory]::CreateDirectory($run)
    $plan = @(New-UtRangePlan -TotalLength $script:FixtureBytes.Length -Connections 4)
    $responses = @{}
    foreach ($range in $plan) {
        $source = Join-Path $run ('part-' + $range.Index + '.partial')
        $bytes = New-Object byte[] ([int]$range.Length)
        [Array]::Copy($script:FixtureBytes, [int]$range.Start, $bytes, 0, [int]$range.Length)
        [IO.File]::WriteAllBytes($source, $bytes)
        $responses[[int]$range.Index] = [pscustomobject]@{ OutputPath = $source }
    }
    $partial = Join-Path $run 'merged.partial'
    $result = Merge-UtRangeFiles -Ranges (@($plan | Sort-Object Index -Descending)) -Responses $responses -PartialPath $partial -TotalLength $script:FixtureBytes.Length
    Assert-SegmentEqual ([IO.Path]::GetFullPath($partial)) ([IO.Path]::GetFullPath($result)) 'merge returns its partial output path'
    Assert-SegmentEqual ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash) ((Get-FileHash -InputStream ([IO.MemoryStream]::new($script:FixtureBytes)) -Algorithm SHA256).Hash) 'shuffled merge preserves bytes'
}

Invoke-SegmentCase 'failure cancels only an owned range process' {
    $script:MockMode = 'cancel'
    $run = Join-Path $script:TestRoot 'cancel run'
    [void][IO.Directory]::CreateDirectory($run)
    $metadata = New-SegmentMetadata -Length $script:FixtureBytes.Length
    Assert-SegmentFailure 6 { Receive-UtParallelCandidate -Metadata $metadata -RunDirectory $run -Architecture x64 -Connections 4 -Background } 'segment failure is reported'
    Assert-SegmentTrue ($null -ne $script:CancelProcess -and $script:CancelProcess.HasExited) 'owned long-running process was cancelled'
    Assert-SegmentTrue (-not (Test-Path -LiteralPath (Join-Path $run 'ChatGPT-x64.msix'))) 'failed run has no complete package'
    if ($null -ne $script:CancelProcess) { $script:CancelProcess.Dispose() }
}

Invoke-SegmentCase 'invalid metadata fails before creating a run directory' {
    $metadata = New-SegmentMetadata -ETag 'not-an-entity-tag' -Length $script:FixtureBytes.Length
    $run = Join-Path $script:TestRoot 'must not exist'
    Assert-SegmentFailure 5 { Receive-UtParallelCandidate -Metadata $metadata -RunDirectory $run -Architecture x64 -Connections 8 -Background } 'invalid ETag is metadata error'
    Assert-SegmentTrue (-not (Test-Path -LiteralPath $run)) 'invalid metadata caused no write'

    $badVersion = New-SegmentMetadata -Length $script:FixtureBytes.Length
    $badVersion.Version = '26.930'
    $versionRun = Join-Path $script:TestRoot 'bad version must not exist'
    Assert-SegmentFailure 5 { Receive-UtParallelCandidate -Metadata $badVersion -RunDirectory $versionRun -Architecture x64 -Connections 8 -Background } 'non-four-part version is metadata error'
    Assert-SegmentTrue (-not (Test-Path -LiteralPath $versionRun)) 'invalid version caused no write'
}

Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($script:TestFailed -eq 0) {
    Write-Host ('All {0} segmented-download test cases passed.' -f $script:TestTotal) -ForegroundColor Green
    exit 0
}
Write-Host ('{0} of {1} segmented-download test cases failed.' -f $script:TestFailed, $script:TestTotal) -ForegroundColor Red
exit 1
