#requires -Version 5.1
<##
    Strict range downloader for the ChatGPT MSIX source.

    This file is intentionally function-only.  update-chatgpt.ps1 dot-sources
    it after defining the shared metadata, curl and error helpers.  The network
    boundary is Start-UtParallelRangeProcess: offline tests may replace that
    one function (or its response) while the range, response and merge checks
    below remain production code.

    The implementation uses System.Diagnostics.Process instead of the PowerShell
    native command operator.  Windows PowerShell 5.1 does not expose an
    ArgumentList property, so arguments are quoted using the Windows C runtime
    command-line rules before ProcessStartInfo receives them.
##>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:UtParallelCurlCapabilityCache = @{}

# ---------------------------------------------------------------------------
# Small shared helpers.  They deliberately tolerate this file being dot-sourced
# in a standalone test as well as after update-chatgpt.ps1.
# ---------------------------------------------------------------------------
function Get-UtParallelScriptValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Default
    )
    $variable = Get-Variable -Name $Name -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $variable) { return $variable.Value }
    return $Default
}

function Stop-UtParallel {
    param(
        [Parameter(Mandatory = $true)][int]$Code,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $stop = Get-Command Stop-Ut -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $stop) {
        Stop-Ut -Code $Code -Message $Message
    }
    $exception = New-Object System.Exception($Message)
    $exception.Data['UtExitCode'] = $Code
    throw $exception
}

function Get-UtParallelProperty {
    param(
        $Object,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-UtParallelProperty {
    param(
        $Object,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Object) { return $false }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-UtParallelMetadataCode { return [int](Get-UtParallelScriptValue -Name 'UtExitMetadata' -Default 5) }
function Get-UtParallelDownloadCode { return [int](Get-UtParallelScriptValue -Name 'UtExitDownload' -Default 6) }
function Get-UtParallelEnvironmentCode { return [int](Get-UtParallelScriptValue -Name 'UtExitEnvironment' -Default 3) }

function ConvertTo-UtParallelInvariantInt64 {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Label,
        [int]$Code = 6
    )
    $text = [string]$Value
    if ($text -notmatch '^[0-9]+$') {
        Stop-UtParallel -Code $Code -Message ("{0} '{1}' is not a non-negative Int64." -f $Label, $text)
    }
    $parsed = [long]0
    if (-not [long]::TryParse($text, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        Stop-UtParallel -Code $Code -Message ("{0} '{1}' is outside the Int64 range." -f $Label, $text)
    }
    return $parsed
}

# ---------------------------------------------------------------------------
# Strict ETag classification.
# ---------------------------------------------------------------------------
function Get-UtETagKind {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][AllowNull()][AllowEmptyString()]$ETag
    )

    if ($null -eq $ETag) { return 'Missing' }
    if ($ETag -isnot [string]) { $ETag = [string]$ETag }
    if ($ETag.Length -eq 0) {
        Stop-UtParallel -Code (Get-UtParallelMetadataCode) -Message 'The ETag header is present but empty.'
    }

    $weak = $false
    $value = $ETag
    if ($value.StartsWith('W/', [System.StringComparison]::Ordinal)) {
        $weak = $true
        $value = $value.Substring(2)
    }
    if ($value.Length -lt 2 -or $value[0] -ne [char]0x22 -or $value[$value.Length - 1] -ne [char]0x22) {
        Stop-UtParallel -Code (Get-UtParallelMetadataCode) -Message ("The ETag '{0}' is not a valid quoted entity-tag." -f $ETag)
    }

    # Keep the accepted grammar at visible ASCII.  The curl config is written
    # as ASCII on PowerShell 5.1; accepting obs-text here would silently change
    # the validator sent on the wire.
    for ($index = 1; $index -lt ($value.Length - 1); $index++) {
        $number = [int][char]$value[$index]
        if ($number -lt 0x21 -or $number -eq 0x22 -or $number -gt 0x7E) {
            Stop-UtParallel -Code (Get-UtParallelMetadataCode) -Message ("The ETag '{0}' contains a control, quote or unsupported character." -f $ETag)
        }
    }
    if ($weak) { return 'Weak' }
    return 'Strong'
}

# ---------------------------------------------------------------------------
# Official source and metadata checks.
# ---------------------------------------------------------------------------
function Get-UtParallelOfficialBaseUrl {
    return [string](Get-UtParallelScriptValue -Name 'UtBaseUrl' -Default 'https://persistent.oaistatic.com/codex-app-prod')
}

function Get-UtParallelAllowedHost {
    return [string](Get-UtParallelScriptValue -Name 'UtAllowedHost' -Default 'persistent.oaistatic.com')
}

function ConvertTo-UtParallelUri {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $uri = $null
    try { $uri = [System.Uri]$Value } catch { $uri = $null }
    if ($null -eq $uri -or -not $uri.IsAbsoluteUri) {
        Stop-UtParallel -Code (Get-UtParallelMetadataCode) -Message ("{0} '{1}' is not an absolute URI." -f $Label, $Value)
    }
    return $uri
}

function Assert-UtParallelOfficialSource {
    param(
        [Parameter(Mandatory = $true)][string]$RequestedUri,
        [Parameter(Mandatory = $true)][string]$FinalUri,
        [Parameter(Mandatory = $true)][string]$Architecture,
        [int]$Code = 6
    )
    $requested = ConvertTo-UtParallelUri -Value $RequestedUri -Label 'Requested source URL'
    $final = ConvertTo-UtParallelUri -Value $FinalUri -Label 'Final source URL'
    $allowedHost = Get-UtParallelAllowedHost
    foreach ($uri in @($requested, $final)) {
        if ($uri.Scheme -cne 'https' -or $uri.Host -cne $allowedHost) {
            Stop-UtParallel -Code $Code -Message ("The source URL '{0}' is outside the pinned HTTPS source." -f $uri.AbsoluteUri)
        }
        if ($uri.Port -ne -1 -and $uri.Port -ne 443) {
            Stop-UtParallel -Code $Code -Message ("The source URL '{0}' uses an unexpected port." -f $uri.AbsoluteUri)
        }
        if (-not [string]::IsNullOrEmpty($uri.UserInfo) -or -not [string]::IsNullOrEmpty($uri.Query) -or -not [string]::IsNullOrEmpty($uri.Fragment)) {
            Stop-UtParallel -Code $Code -Message ("The source URL '{0}' contains credentials, a query or a fragment." -f $uri.AbsoluteUri)
        }
    }
    $expectedName = 'ChatGPT-{0}.msix' -f $Architecture.ToLowerInvariant()
    $expectedPath = '/codex-app-prod/{0}' -f $expectedName
    if ($requested.AbsolutePath -cne $expectedPath -or $final.AbsolutePath -cne $expectedPath) {
        Stop-UtParallel -Code $Code -Message 'The source URL path is not the pinned architecture-specific MSIX path.'
    }
    if ($requested.AbsoluteUri -cne $final.AbsoluteUri) {
        Stop-UtParallel -Code $Code -Message ("The final URL '{0}' differs from the requested source; redirects are not permitted." -f $final.AbsoluteUri)
    }
    return $final.AbsoluteUri
}

function Assert-UtParallelMetadata {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$Architecture
    )
    if ($null -eq $Metadata) { Stop-UtParallel -Code (Get-UtParallelMetadataCode) -Message 'Download metadata is missing.' }
    if ($Architecture -cne 'x64' -and $Architecture -cne 'arm64') {
        Stop-UtParallel -Code (Get-UtParallelMetadataCode) -Message ("Unsupported download architecture '{0}'." -f $Architecture)
    }
    $metadataArchitecture = [string](Get-UtParallelProperty -Object $Metadata -Name 'Architecture')
    if ([string]::IsNullOrWhiteSpace($metadataArchitecture) -or $metadataArchitecture -ine $Architecture) {
        Stop-UtParallel -Code (Get-UtParallelMetadataCode) -Message ("Metadata architecture '{0}' does not match '{1}'." -f $metadataArchitecture, $Architecture)
    }
    $lengthValue = Get-UtParallelProperty -Object $Metadata -Name 'ContentLength'
    if ($null -eq $lengthValue) { Stop-UtParallel -Code (Get-UtParallelMetadataCode) -Message 'Download metadata has no ContentLength.' }
    $length = ConvertTo-UtParallelInvariantInt64 -Value $lengthValue -Label 'ContentLength' -Code (Get-UtParallelMetadataCode)
    if ($length -le 0) { Stop-UtParallel -Code (Get-UtParallelMetadataCode) -Message 'ContentLength must be positive.' }
    $version = Get-UtParallelProperty -Object $Metadata -Name 'Version'
    if ($null -eq $version -or [string]::IsNullOrWhiteSpace([string]$version)) {
        Stop-UtParallel -Code (Get-UtParallelMetadataCode) -Message 'Download metadata has no Version.'
    }
    $versionText = [string]$version
    if ($versionText -notmatch '^[0-9]{1,5}(\.[0-9]{1,5}){3}$') {
        Stop-UtParallel -Code (Get-UtParallelMetadataCode) -Message ("Metadata version '{0}' is not a four-part version." -f $versionText)
    }
    foreach ($versionPart in $versionText.Split('.')) {
        $versionNumber = 0
        if (-not [int]::TryParse($versionPart, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$versionNumber) -or $versionNumber -gt 65535) {
            Stop-UtParallel -Code (Get-UtParallelMetadataCode) -Message ("Metadata version '{0}' contains an out-of-range component." -f $versionText)
        }
    }
    $url = [string](Get-UtParallelProperty -Object $Metadata -Name 'Url')
    $finalUri = [string](Get-UtParallelProperty -Object $Metadata -Name 'FinalUri')
    if ([string]::IsNullOrWhiteSpace($url) -or [string]::IsNullOrWhiteSpace($finalUri)) {
        Stop-UtParallel -Code (Get-UtParallelMetadataCode) -Message 'Download metadata must contain both Url and FinalUri.'
    }
    $null = Assert-UtParallelOfficialSource -RequestedUri $url -FinalUri $finalUri -Architecture $Architecture -Code (Get-UtParallelMetadataCode)
    $etag = Get-UtParallelProperty -Object $Metadata -Name 'ETag'
    $etagValue = $null
    if ($null -ne $etag) { $etagValue = [string]$etag }
    $etagKind = Get-UtETagKind -ETag $etagValue
    return [pscustomobject]@{
        Version       = $version
        ContentLength = [long]$length
        ETag          = if ($null -eq $etag) { $null } else { [string]$etag }
        ETagKind      = $etagKind
        StrongETag    = ($etagKind -ceq 'Strong')
        Url           = $url
        FinalUri      = $finalUri
        Architecture  = $Architecture
    }
}

# ---------------------------------------------------------------------------
# Int64 range planning.  A tiny object cannot be divided into more non-empty
# ranges than it has bytes, so the effective connection count is capped at the
# total length while preserving exact coverage.
# ---------------------------------------------------------------------------
function Assert-UtParallelConnections {
    param([int]$Connections)
    if (@(1, 4, 8, 16) -notcontains $Connections) {
        Stop-UtParallel -Code (Get-UtParallelMetadataCode) -Message 'Connections must be one of 1, 4, 8 or 16.'
    }
}

function New-UtRangePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][long]$TotalLength,
        [Parameter(Mandatory = $true)][int]$Connections
    )
    Assert-UtParallelConnections -Connections $Connections
    if ($TotalLength -le 0) { Stop-UtParallel -Code (Get-UtParallelMetadataCode) -Message 'TotalLength must be positive.' }
    $count = [long]$Connections
    if ($TotalLength -lt $count) { $count = $TotalLength }
    $remainder = [long]0
    $baseLength = [long][System.Math]::DivRem($TotalLength, $count, [ref]$remainder)
    $start = [long]0
    $result = New-Object System.Collections.ArrayList
    for ($index = [long]0; $index -lt $count; $index++) {
        $partLength = $baseLength
        if ($index -lt $remainder) { $partLength++ }
        $end = $start + $partLength - 1L
        [void]$result.Add([pscustomobject]@{
            Index        = [int]$index
            Start        = [long]$start
            End          = [long]$end
            Length       = [long]$partLength
            Range        = ('bytes={0}-{1}' -f $start, $end)
        })
        $start = $end + 1L
    }
    if ($start -ne $TotalLength) { Stop-UtParallel -Code (Get-UtParallelMetadataCode) -Message 'Internal range planning did not cover the complete object.' }
    return $result.ToArray()
}

function Get-UtParallelRangeValues {
    param(
        [Parameter(Mandatory = $true)]$Range,
        [Parameter(Mandatory = $true)][long]$TotalLength
    )
    $startValue = Get-UtParallelProperty -Object $Range -Name 'Start'
    $endValue = Get-UtParallelProperty -Object $Range -Name 'End'
    if ($null -eq $startValue -or $null -eq $endValue) {
        Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message 'A range request is missing Start or End.'
    }
    $start = ConvertTo-UtParallelInvariantInt64 -Value $startValue -Label 'Range start' -Code (Get-UtParallelDownloadCode)
    $end = ConvertTo-UtParallelInvariantInt64 -Value $endValue -Label 'Range end' -Code (Get-UtParallelDownloadCode)
    if ($start -lt 0 -or $end -lt $start -or $end -ge $TotalLength) {
        Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("Range bytes={0}-{1} is outside the object length {2}." -f $start, $end, $TotalLength)
    }
    return [pscustomobject]@{ Start = $start; End = $end; Length = [long]($end - $start + 1L); Range = ('bytes={0}-{1}' -f $start, $end) }
}

# ---------------------------------------------------------------------------
# curl config and Windows process quoting.
# ---------------------------------------------------------------------------
function ConvertTo-UtWindowsProcessArgument {
    [CmdletBinding()]
    param([Parameter(Mandatory = $false)][AllowNull()][AllowEmptyString()][string]$Value)
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append([char]0x22)
    $slashes = 0
    for ($index = 0; $index -lt $Value.Length; $index++) {
        $character = $Value[$index]
        if ($character -eq [char]0x5C) {
            $slashes++
            continue
        }
        if ($character -eq [char]0x22) {
            for ($copy = 0; $copy -lt (($slashes * 2) + 1); $copy++) { [void]$builder.Append([char]0x5C) }
            [void]$builder.Append([char]0x22)
            $slashes = 0
            continue
        }
        for ($copy = 0; $copy -lt $slashes; $copy++) { [void]$builder.Append([char]0x5C) }
        $slashes = 0
        [void]$builder.Append($character)
    }
    for ($copy = 0; $copy -lt ($slashes * 2); $copy++) { [void]$builder.Append([char]0x5C) }
    [void]$builder.Append([char]0x22)
    return $builder.ToString()
}

function ConvertTo-UtParallelCurlConfigLine {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value.IndexOf([char]0x0D) -ge 0 -or $Value.IndexOf([char]0x0A) -ge 0) {
        Stop-UtParallel -Code (Get-UtParallelMetadataCode) -Message 'A curl config header contains a newline.'
    }
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    return 'header = "' + $escaped + '"'
}

function New-UtParallelCurlConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ETag
    )
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add((ConvertTo-UtParallelCurlConfigLine -Value 'Accept-Encoding: identity'))
    [void]$lines.Add((ConvertTo-UtParallelCurlConfigLine -Value ('If-Match: {0}' -f $ETag)))
    try {
        [System.IO.File]::WriteAllLines($Path, [string[]]$lines.ToArray(), [System.Text.Encoding]::ASCII)
    } catch {
        Stop-UtParallel -Code (Get-UtParallelEnvironmentCode) -Message ("Unable to write the curl config file '{0}': {1}" -f $Path, $_.Exception.Message)
    }
    return $Path
}

function New-UtRangeRequestArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$HeaderPath,
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][long]$Start,
        [Parameter(Mandatory = $true)][long]$End,
        [switch]$Probe
    )
    if ($Start -lt 0 -or $End -lt $Start) {
        Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message 'Cannot construct a curl request for an invalid range.'
    }
    $maxTime = [int](Get-UtParallelScriptValue -Name 'UtDownloadMaxTime' -Default 3600)
    if ($Probe) { $maxTime = [int](Get-UtParallelScriptValue -Name 'UtParallelProbeMaxTime' -Default 10) }
    return [string[]]@(
        '--disable', '--silent', '--show-error', '--fail',
        '--proto', '=https', '--proto-redir', '=https',
        '--connect-timeout', [string](Get-UtParallelScriptValue -Name 'UtHeadConnectTimeout' -Default 20),
        '--max-time', [string]$maxTime,
        '--max-filesize', [string]($End - $Start + 1L),
        '--range', ('{0}-{1}' -f $Start, $End),
        '--config', $ConfigPath,
        '--dump-header', $HeaderPath,
        '--output', $OutputPath,
        '--write-out', "HTTPCODE=%{http_code}`nFINALURL=%{url_effective}",
        '--url', $Url
    )
}

# ---------------------------------------------------------------------------
# Native curl process boundary.  This is the only production function intended
# to be replaced by offline tests.
# ---------------------------------------------------------------------------
function Get-UtParallelCurlPath {
    $existing = Get-Command Get-UtCurlPath -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $existing) { return [string](Get-UtCurlPath) }
    $systemRoot = [Environment]::GetEnvironmentVariable('SystemRoot')
    $curlCandidates = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($systemRoot)) {
        [void]$curlCandidates.Add((Join-Path $systemRoot 'System32\curl.exe'))
        [void]$curlCandidates.Add((Join-Path $systemRoot 'Sysnative\curl.exe'))
    }
    foreach ($candidate in @($curlCandidates)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    $command = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) { return [string]$command.Source }
    Stop-UtParallel -Code (Get-UtParallelEnvironmentCode) -Message 'Trusted curl.exe was not found.'
}

function New-UtParallelProcessArguments {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $quoted = New-Object System.Collections.ArrayList
    foreach ($argument in $Arguments) { [void]$quoted.Add((ConvertTo-UtWindowsProcessArgument -Value $argument)) }
    return ($quoted -join ' ')
}

function Start-UtParallelRangeProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Request)
    $curl = Get-UtParallelCurlPath
    Assert-UtParallelCurlCapabilities -CurlPath $curl
    $arguments = New-UtRangeRequestArguments -Url $Request.Url -OutputPath $Request.OutputPath -HeaderPath $Request.HeaderPath -ConfigPath $Request.ConfigPath -Start $Request.Start -End $Request.End -Probe:$Request.Probe
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $curl
    $startInfo.Arguments = New-UtParallelProcessArguments -Arguments $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { Stop-UtParallel -Code (Get-UtParallelEnvironmentCode) -Message 'curl process did not start.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        return [pscustomobject]@{ Process = $process; StdoutTask = $stdoutTask; StderrTask = $stderrTask }
    } catch {
        if ($null -ne $process) { try { $process.Dispose() } catch { } }
        if ($null -ne $_.Exception.Data -and $_.Exception.Data.Contains('UtExitCode')) { throw }
        Stop-UtParallel -Code (Get-UtParallelEnvironmentCode) -Message ("Unable to start curl: {0}" -f $_.Exception.Message)
    }
}

function Assert-UtParallelCurlCapabilities {
    param([Parameter(Mandatory = $true)][string]$CurlPath)
    $key = [System.IO.Path]::GetFullPath($CurlPath)
    if ($script:UtParallelCurlCapabilityCache.ContainsKey($key)) {
        if (-not $script:UtParallelCurlCapabilityCache[$key]) {
            Stop-UtParallel -Code (Get-UtParallelEnvironmentCode) -Message 'Trusted curl.exe is too old for the required --max-filesize range cap; use -Connections 1 for the serial backend.'
        }
        return
    }
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $CurlPath
    $info.Arguments = '--version'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { Stop-UtParallel -Code (Get-UtParallelEnvironmentCode) -Message 'Unable to query curl capabilities.' }
        $text = $process.StandardOutput.ReadToEnd()
        [void]$process.WaitForExit()
    } catch {
        if ($null -ne $process) { try { $process.Dispose() } catch { } }
        if ($null -ne $_.Exception.Data -and $_.Exception.Data.Contains('UtExitCode')) { throw }
        Stop-UtParallel -Code (Get-UtParallelEnvironmentCode) -Message ("Unable to query curl capabilities: {0}" -f $_.Exception.Message)
    } finally {
        if ($null -ne $process) { try { $process.Dispose() } catch { } }
    }
    $match = [regex]::Match([string]$text, '(?m)^curl\s+([0-9]+)\.([0-9]+)\.([0-9]+)')
    $supported = $false
    if ($match.Success) {
        try {
            $version = New-Object System.Version([int]$match.Groups[1].Value, [int]$match.Groups[2].Value, [int]$match.Groups[3].Value)
            $supported = ($version -ge (New-Object System.Version(8, 4, 0)))
        } catch { $supported = $false }
    }
    $script:UtParallelCurlCapabilityCache[$key] = $supported
    if (-not $supported) {
        Stop-UtParallel -Code (Get-UtParallelEnvironmentCode) -Message 'Trusted curl.exe is too old for the required --max-filesize range cap; use -Connections 1 for the serial backend.'
    }
}

function Stop-UtParallelProcess {
    param($Worker)
    if ($null -eq $Worker) { return }
    $process = Get-UtParallelProperty -Object $Worker -Name 'Process'
    if ($null -eq $process) { return }
    try {
        if (-not $process.HasExited) { $process.Kill() }
    } catch { }
    try { [void]$process.WaitForExit(5000) } catch { }
}

function Stop-UtParallelOwnedProcesses {
    param([object[]]$Handles)
    foreach ($handle in @($Handles)) {
        $worker = Get-UtParallelProperty -Object $handle -Name 'Worker'
        Stop-UtParallelProcess -Worker $worker
    }
}

function Test-UtParallelTransportExitCode {
    param([int]$ExitCode)
    return @(
        5, 6, 7, 18, 28, 52, 55, 56
    ) -contains $ExitCode
}

function Test-UtParallelRetryableResponse {
    param(
        [Parameter(Mandatory = $true)]$Response,
        [Parameter(Mandatory = $true)]$Handle
    )
    $worker = Get-UtParallelProperty -Object $Handle -Name 'Worker'
    if ((Get-UtParallelProperty -Object $worker -Name 'ProbeCapExceeded') -eq $true -or (Get-UtParallelProperty -Object $worker -Name 'SegmentCapExceeded') -eq $true -or (Get-UtParallelProperty -Object $worker -Name 'HeaderCapExceeded') -eq $true) { return $false }
    if ((Get-UtParallelProperty -Object $Response -Name 'HeaderParseFailed') -eq $true) { return $false }
    $exitValue = Get-UtParallelProperty -Object $Response -Name 'ExitCode'
    $httpValue = Get-UtParallelProperty -Object $Response -Name 'HttpCode'
    if ($null -eq $exitValue -or $null -eq $httpValue) { return $false }
    $exitCode = [int]$exitValue
    $httpCode = [int]$httpValue
    $isHttpServerFailure = ($httpCode -ge 500 -and $httpCode -le 599)
    if ($exitCode -eq 22) {
        if (-not $isHttpServerFailure) { return $false }
    } elseif (-not (Test-UtParallelTransportExitCode -ExitCode $exitCode)) {
        return $false
    }
    if ($httpCode -ne 0 -and $httpCode -ne 206 -and -not $isHttpServerFailure) { return $false }

    $headerStatus = Get-UtParallelProperty -Object $Response -Name 'HeaderStatusCode'
    if ($null -ne $headerStatus -and [int]$headerStatus -ne $httpCode) { return $false }

    $metadata = $Handle.Request.Metadata
    $finalUri = [string](Get-UtParallelProperty -Object $Response -Name 'FinalUri')
    if (-not [string]::IsNullOrWhiteSpace($finalUri)) {
        try {
            $null = Assert-UtParallelOfficialSource -RequestedUri $metadata.Url -FinalUri $finalUri -Architecture $Handle.Request.Architecture -Code (Get-UtParallelDownloadCode)
        } catch { return $false }
    }

    $headers = Get-UtParallelProperty -Object $Response -Name 'Headers'
    if ($httpCode -eq 206 -and $null -eq $headers) { return $false }
    if ($null -eq $headers) { return $true }
    if ($headers -isnot [System.Collections.IDictionary]) { return $false }
    if ($httpCode -eq 206 -and (-not $headers.ContainsKey('etag') -or -not $headers.ContainsKey('content-range'))) { return $false }
    if ($headers.ContainsKey('etag')) {
        try {
            $etag = Get-UtParallelHeaderValue -Headers $headers -Name 'etag' -Required
            if ((Get-UtETagKind -ETag $etag) -cne 'Strong' -or $etag -cne [string]$metadata.ETag) { return $false }
        } catch { return $false }
    }
    if ($headers.ContainsKey('content-encoding')) {
        try { Assert-UtParallelIdentityEncoding -Headers $headers } catch { return $false }
    }
    if ($httpCode -eq 206 -and $headers.ContainsKey('content-range')) {
        try {
            $contentRange = ConvertFrom-UtParallelContentRange -Value (Get-UtParallelHeaderValue -Headers $headers -Name 'content-range' -Required)
            if ($contentRange.Start -ne [long]$Handle.Request.Start -or $contentRange.End -ne [long]$Handle.Request.End -or $contentRange.Total -ne [long]$metadata.ContentLength) { return $false }
            if ($headers.ContainsKey('content-length')) {
                $reportedLength = ConvertTo-UtParallelInvariantInt64 -Value (Get-UtParallelHeaderValue -Headers $headers -Name 'content-length' -Required) -Label 'Content-Length' -Code (Get-UtParallelDownloadCode)
                if ($reportedLength -ne $contentRange.Length) { return $false }
            }
        } catch { return $false }
    }
    return $true
}

function Test-UtParallelRetryableFailure {
    param(
        [Parameter(Mandatory = $true)]$Handle,
        [Parameter(Mandatory = $false)]$ErrorRecord
    )
    $worker = Get-UtParallelProperty -Object $Handle -Name 'Worker'
    if ((Get-UtParallelProperty -Object $worker -Name 'ProbeCapExceeded') -eq $true -or (Get-UtParallelProperty -Object $worker -Name 'SegmentCapExceeded') -eq $true -or (Get-UtParallelProperty -Object $worker -Name 'HeaderCapExceeded') -eq $true) { return $false }
    $response = Get-UtParallelProperty -Object $Handle -Name 'Response'
    if ($null -ne $response) { return (Test-UtParallelRetryableResponse -Response $response -Handle $Handle) }
    if ($null -ne $worker -and (Test-UtParallelProperty -Object $worker -Name 'Response')) {
        $workerResponse = Get-UtParallelProperty -Object $worker -Name 'Response'
        if ($null -eq $workerResponse) { return $false }
        return (Test-UtParallelRetryableResponse -Response $workerResponse -Handle $Handle)
    }
    $process = Get-UtParallelProperty -Object $worker -Name 'Process'
    if ($null -eq $process) { return $false }
    try {
        if (-not $process.HasExited) { return $false }
        return (Test-UtParallelTransportExitCode -ExitCode ([int]$process.ExitCode))
    } catch { return $false }
}

function Test-UtParallelHandleReady {
    param([Parameter(Mandatory = $true)]$Handle)
    $worker = Get-UtParallelProperty -Object $Handle -Name 'Worker'
    if ($null -eq $worker) { return $true }
    if (Test-UtParallelProperty -Object $worker -Name 'Response') { return $true }
    $process = Get-UtParallelProperty -Object $worker -Name 'Process'
    if ($null -eq $process) { return $true }
    try { return [bool]$process.HasExited } catch { return $true }
}

function Test-UtParallelProbeLimit {
    param([Parameter(Mandatory = $true)]$Handle)
    $request = Get-UtParallelProperty -Object $Handle -Name 'Request'
    if ($null -eq $request -or -not [bool]$request.Probe) { return }
    $path = [string]$request.OutputPath
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $limit = [long](Get-UtParallelScriptValue -Name 'UtParallelProbeMaxBytes' -Default 1)
    try { $length = [long](Get-Item -LiteralPath $path -Force).Length } catch { return }
    if ($length -le $limit) { return }
    $worker = Get-UtParallelProperty -Object $Handle -Name 'Worker'
    $process = Get-UtParallelProperty -Object $worker -Name 'Process'
    if ($null -ne $process) {
        try {
            if (-not $process.HasExited) { $process.Kill() }
        } catch { }
        try { [void]$process.WaitForExit(5000) } catch { }
    }
    if (-not (Test-UtParallelProperty -Object $worker -Name 'ProbeCapExceeded')) {
        $worker | Add-Member -NotePropertyName ProbeCapExceeded -NotePropertyValue $true -Force
    } else {
        $worker.ProbeCapExceeded = $true
    }
}

function Test-UtParallelSegmentLimit {
    param([Parameter(Mandatory = $true)]$Handle)
    $request = Get-UtParallelProperty -Object $Handle -Name 'Request'
    if ($null -eq $request -or [bool]$request.Probe) { return }
    $path = [string]$request.OutputPath
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    try { $length = [long](Get-Item -LiteralPath $path -Force).Length } catch { return }
    if ($length -le [long]$request.Length) { return }
    $worker = Get-UtParallelProperty -Object $Handle -Name 'Worker'
    $process = Get-UtParallelProperty -Object $worker -Name 'Process'
    if ($null -ne $process) {
        try {
            if (-not $process.HasExited) { $process.Kill() }
        } catch { }
        try { [void]$process.WaitForExit(5000) } catch { }
    }
    if (-not (Test-UtParallelProperty -Object $worker -Name 'SegmentCapExceeded')) {
        $worker | Add-Member -NotePropertyName SegmentCapExceeded -NotePropertyValue $true -Force
    } else {
        $worker.SegmentCapExceeded = $true
    }
}

function Get-UtParallelHeaderLimit {
    $raw = Get-UtParallelScriptValue -Name 'UtMaxResponseHeaderBytes' -Default 262144
    $limit = [long]0
    $parsed = $false
    if ($null -ne $raw) {
        try {
            $parsed = [long]::TryParse(
                [string]$raw,
                [Globalization.NumberStyles]::Integer,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$limit)
        } catch { $parsed = $false }
    }
    if (-not $parsed -or $limit -le 0) { return [long]262144 }
    return $limit
}

function Test-UtParallelHeaderLimit {
    param([Parameter(Mandatory = $true)]$Handle)
    $request = Get-UtParallelProperty -Object $Handle -Name 'Request'
    if ($null -eq $request) { return }
    $path = [string](Get-UtParallelProperty -Object $request -Name 'HeaderPath')
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $tooLarge = $false
    try {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or [long]$item.Length -gt (Get-UtParallelHeaderLimit)) {
            $tooLarge = $true
        }
    } catch { return }
    if (-not $tooLarge) { return }
    $worker = Get-UtParallelProperty -Object $Handle -Name 'Worker'
    # This is deliberately scoped to this handle.  The receiver may have other
    # curl workers in flight and must leave those workers alone until the
    # terminal header violation is classified.
    Stop-UtParallelProcess -Worker $worker
    if (-not (Test-UtParallelProperty -Object $worker -Name 'HeaderCapExceeded')) {
        $worker | Add-Member -NotePropertyName HeaderCapExceeded -NotePropertyValue $true -Force
    } else {
        $worker.HeaderCapExceeded = $true
    }
}

# ---------------------------------------------------------------------------
# Response parsing and validation.
# ---------------------------------------------------------------------------
function Get-UtParallelHeaderValue {
    param(
        [Parameter(Mandatory = $true)]$Headers,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$Required
    )
    $key = $Name.ToLowerInvariant()
    if (-not $Headers.ContainsKey($key)) {
        if ($Required) { Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("Required response header '{0}' is missing." -f $Name) }
        return $null
    }
    $values = @($Headers[$key])
    if ($values.Count -ne 1) {
        Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("Response header '{0}' is duplicated or ambiguous." -f $Name)
    }
    $value = [string]$values[0]
    if ([string]::IsNullOrWhiteSpace($value)) {
        if ($Required) { Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("Required response header '{0}' is empty." -f $Name) }
        return $null
    }
    return $value
}

function Read-UtParallelHeaderFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][AllowNull()][AllowEmptyString()][string]$Root
    )
    try { $fullPath = [System.IO.Path]::GetFullPath($Path) } catch {
        Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("The response header path '{0}' is invalid." -f $Path)
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("curl did not produce a response header file '{0}'." -f $Path)
    }

    # Header files are attacker-controlled input.  Reuse the managed-path guard
    # when the production script has loaded it; the fallback walks every existing
    # ancestor so standalone use still rejects reparse-point paths.
    $pathGuard = Get-Command Assert-UtManagedPath -CommandType Function -ErrorAction SilentlyContinue
    $rootFull = $Root
    if ([string]::IsNullOrWhiteSpace($rootFull)) { $rootFull = Split-Path -Parent $fullPath }
    if ($null -ne $pathGuard) {
        Assert-UtManagedPath -Path $fullPath -Root $rootFull
    } else {
        $current = $fullPath
        while ($true) {
            try {
                $ancestor = Get-Item -LiteralPath $current -Force -ErrorAction Stop
                if (($ancestor.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("The response header path ancestor '{0}' is a reparse point." -f $current)
                }
            } catch {
                if ($_.Exception.Data.Contains('UtExitCode')) { throw }
                Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("The response header path ancestor '{0}' could not be inspected: {1}" -f $current, $_.Exception.Message)
            }
            $parent = [System.IO.Path]::GetDirectoryName($current)
            if ([string]::IsNullOrEmpty($parent) -or $parent -ieq $current) { break }
            $current = $parent
        }
    }

    try {
        $headerItem = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
        if (($headerItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("The response header path '{0}' is a reparse point." -f $Path)
        }
        if ([long]$headerItem.Length -gt (Get-UtParallelHeaderLimit)) {
            Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("The response header file '{0}' exceeds the configured size limit." -f $Path)
        }
    } catch {
        if ($_.Exception.Data.Contains('UtExitCode')) { throw }
        Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("The response header file could not be inspected: {0}" -f $_.Exception.Message)
    }
    try {
        $text = [System.IO.File]::ReadAllText($fullPath)
        # Recheck after the read to close the common grow-between-stat-and-read
        # race.  The pending-process watchdog below handles a file that keeps
        # growing while curl is still alive.
        $afterRead = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
        if ([long]$afterRead.Length -gt (Get-UtParallelHeaderLimit)) {
            Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("The response header file '{0}' exceeds the configured size limit." -f $Path)
        }
    } catch {
        if ($_.Exception.Data.Contains('UtExitCode')) { throw }
        Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("The response header file could not be read: {0}" -f $_.Exception.Message)
    }
    $lines = $text -split "`r?`n"
    $blocks = New-Object System.Collections.ArrayList
    $currentStatus = $null
    $currentHeaders = @{}
    foreach ($line in $lines) {
        if ($line.Length -eq 0) {
            if ($null -ne $currentStatus) {
                [void]$blocks.Add([pscustomobject]@{ StatusCode = [int]$currentStatus; Headers = $currentHeaders })
                $currentStatus = $null
                $currentHeaders = @{}
            }
            continue
        }
        if ($line -match '^HTTP/[0-9](?:\.[0-9])?\s+([0-9]{3})(?:\s.*)?$') {
            if ($null -ne $currentStatus) {
                [void]$blocks.Add([pscustomobject]@{ StatusCode = [int]$currentStatus; Headers = $currentHeaders })
            }
            $currentStatus = [int]$Matches[1]
            $currentHeaders = @{}
            continue
        }
        if ($null -eq $currentStatus) {
            Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("Malformed response header line before the HTTP status: '{0}'." -f $line)
        }
        $separator = $line.IndexOf(':')
        if ($separator -lt 1) {
            Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("Malformed response header line: '{0}'." -f $line)
        }
        $name = $line.Substring(0, $separator).Trim().ToLowerInvariant()
        $value = $line.Substring($separator + 1).Trim()
        if ($name -notmatch '^[!#-\x7E]+$') {
            Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("Malformed response header name '{0}'." -f $name)
        }
        for ($characterIndex = 0; $characterIndex -lt $value.Length; $characterIndex++) {
            $number = [int][char]$value[$characterIndex]
            if ($number -lt 0x20 -or $number -eq 0x7F) {
                Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("Response header '{0}' contains a control character." -f $name)
            }
        }
        if (-not $currentHeaders.ContainsKey($name)) { $currentHeaders[$name] = New-Object System.Collections.ArrayList }
        [void]$currentHeaders[$name].Add($value)
    }
    if ($null -ne $currentStatus) {
        [void]$blocks.Add([pscustomobject]@{ StatusCode = [int]$currentStatus; Headers = $currentHeaders })
    }
    if ($blocks.Count -eq 0) { Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message 'The response contained no HTTP header block.' }
    return $blocks[$blocks.Count - 1]
}

function ConvertFrom-UtParallelWriteOut {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$RequestedUri
    )
    $codeMatches = [regex]::Matches($Text, '(?m)^HTTPCODE=([0-9]{3})\s*$')
    $urlMatches = [regex]::Matches($Text, '(?m)^FINALURL=([^\r\n]*)')
    if ($codeMatches.Count -ne 1 -or $urlMatches.Count -ne 1) {
        Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("curl did not produce one status and one final URL for '{0}'." -f $RequestedUri)
    }
    $final = $urlMatches[0].Groups[1].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($final)) { Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message 'curl reported an empty final URL.' }
    return [pscustomobject]@{ HttpCode = [int]$codeMatches[0].Groups[1].Value; FinalUri = $final }
}

function ConvertTo-UtParallelResponseObject {
    param(
        [Parameter(Mandatory = $true)]$Handle,
        [Parameter(Mandatory = $true)]$Worker
    )
    $mockResponse = Get-UtParallelProperty -Object $Worker -Name 'Response'
    if ($null -ne $mockResponse) {
        $mockExit = 0
        if (Test-UtParallelProperty -Object $mockResponse -Name 'ExitCode') { $mockExit = [int]$mockResponse.ExitCode }
        $mockHttp = $null
        if (Test-UtParallelProperty -Object $mockResponse -Name 'HttpCode') { $mockHttp = [int]$mockResponse.HttpCode }
        elseif (Test-UtParallelProperty -Object $mockResponse -Name 'StatusCode') { $mockHttp = [int]$mockResponse.StatusCode }
        if ($null -eq $mockHttp) { Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message 'A mocked range response has no HTTP status.' }
        $mockFinal = $null
        if (Test-UtParallelProperty -Object $mockResponse -Name 'FinalUri') { $mockFinal = [string]$mockResponse.FinalUri }
        elseif (Test-UtParallelProperty -Object $mockResponse -Name 'FinalURL') { $mockFinal = [string]$mockResponse.FinalURL }
        $mockOutput = [string]$Handle.Request.OutputPath
        if (Test-UtParallelProperty -Object $mockResponse -Name 'OutputPath') { $mockOutput = [string]$mockResponse.OutputPath }
        $mockProcessId = $null
        if (Test-UtParallelProperty -Object $mockResponse -Name 'ProcessId') { $mockProcessId = $mockResponse.ProcessId }
        $mockHeaderStatus = $null
        if (Test-UtParallelProperty -Object $mockResponse -Name 'HeaderStatusCode') { $mockHeaderStatus = [int]$mockResponse.HeaderStatusCode }
        return [pscustomobject]@{
            ExitCode  = $mockExit
            HttpCode  = $mockHttp
            FinalUri  = $mockFinal
            Headers   = $mockResponse.Headers
            OutputPath = $mockOutput
            ProcessId = $mockProcessId
            HeaderStatusCode = $mockHeaderStatus
        }
    }
    $process = Get-UtParallelProperty -Object $Worker -Name 'Process'
    if ($null -eq $process) { Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message 'The range worker returned no process or response.' }
    $stdoutTask = Get-UtParallelProperty -Object $Worker -Name 'StdoutTask'
    $stderrTask = Get-UtParallelProperty -Object $Worker -Name 'StderrTask'
    $stdout = if ($null -ne $stdoutTask) { [string]$stdoutTask.Result } else { [string]$process.StandardOutput.ReadToEnd() }
    $stderr = if ($null -ne $stderrTask) { [string]$stderrTask.Result } else { [string]$process.StandardError.ReadToEnd() }
    $effectiveExit = [int]$process.ExitCode
    $writeOut = $null
    try {
        $writeOut = ConvertFrom-UtParallelWriteOut -Text $stdout -RequestedUri $Handle.Request.Url
    } catch {
        # curl normally emits --write-out for a transport failure.  Preserve a
        # transport-only response when it emitted nothing; malformed non-empty
        # output remains a terminal protocol failure.
        if (-not (Test-UtParallelTransportExitCode -ExitCode $effectiveExit) -or -not [string]::IsNullOrWhiteSpace($stdout)) { throw }
        $nonEmptyHeader = $false
        if (Test-Path -LiteralPath $Handle.Request.HeaderPath -PathType Leaf) {
            try {
                $emptyHeaderItem = Get-Item -LiteralPath $Handle.Request.HeaderPath -Force -ErrorAction Stop
                $nonEmptyHeader = (($emptyHeaderItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or [long]$emptyHeaderItem.Length -gt 0)
            } catch { $nonEmptyHeader = $true }
        }
        if ($nonEmptyHeader) {
            return [pscustomobject]@{
                ExitCode = $effectiveExit
                HttpCode = 0
                FinalUri = $null
                Headers = @{}
                OutputPath = $Handle.Request.OutputPath
                ProcessId = $process.Id
                Stderr = $stderr
                HeaderStatusCode = -1
                HeaderParseFailed = $true
            }
        }
        return [pscustomobject]@{
            ExitCode = $effectiveExit
            HttpCode = 0
            FinalUri = $null
            Headers = @{}
            OutputPath = $Handle.Request.OutputPath
            ProcessId = $process.Id
            Stderr = $stderr
            HeaderStatusCode = $null
        }
    }
    $header = $null
    $headerParseFailed = $false
    $headerExists = Test-Path -LiteralPath $Handle.Request.HeaderPath -PathType Leaf
    if ($headerExists) {
        try {
            $headerItem = Get-Item -LiteralPath $Handle.Request.HeaderPath -Force -ErrorAction Stop
            if (($headerItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                $headerParseFailed = $true
            } elseif ([long]$headerItem.Length -eq 0 -and [int]$writeOut.HttpCode -eq 0 -and (Test-UtParallelTransportExitCode -ExitCode $effectiveExit)) {
                # Windows curl creates an empty dump-header file when the
                # connection fails before receiving HTTP response headers.
                # Treat that exact pre-HTTP state as an absent snapshot.
                $header = $null
            } elseif ([long]$headerItem.Length -eq 0) {
                $headerParseFailed = $true
            } else {
                $header = Read-UtParallelHeaderFile -Path $Handle.Request.HeaderPath -Root $Handle.Request.SegmentRoot
            }
        } catch {
            $headerParseFailed = $true
        }
    } elseif ([int]$writeOut.HttpCode -eq 0 -and (Test-UtParallelTransportExitCode -ExitCode $effectiveExit)) {
        $header = $null
    } else {
        $headerParseFailed = $true
    }
    if ($headerParseFailed) {
        return [pscustomobject]@{
            ExitCode = $effectiveExit
            HttpCode = [int]$writeOut.HttpCode
            FinalUri = [string]$writeOut.FinalUri
            Headers = @{}
            OutputPath = $Handle.Request.OutputPath
            ProcessId = $process.Id
            Stderr = $stderr
            HeaderStatusCode = -1
            HeaderParseFailed = $true
        }
    }
    if ($null -eq $header) {
        return [pscustomobject]@{
            ExitCode = $effectiveExit
            HttpCode = [int]$writeOut.HttpCode
            FinalUri = [string]$writeOut.FinalUri
            Headers = @{}
            OutputPath = $Handle.Request.OutputPath
            ProcessId = $process.Id
            Stderr = $stderr
            HeaderStatusCode = $null
        }
    }
    if ((Get-UtParallelProperty -Object $worker -Name 'ProbeCapExceeded') -eq $true) { $effectiveExit = 63 }
    return [pscustomobject]@{
        ExitCode   = $effectiveExit
        HttpCode   = [int]$writeOut.HttpCode
        FinalUri   = [string]$writeOut.FinalUri
        Headers    = $header.Headers
        OutputPath = $Handle.Request.OutputPath
        ProcessId  = $process.Id
        Stderr     = $stderr
        HeaderStatusCode = [int]$header.StatusCode
    }
}

function ConvertFrom-UtParallelContentRange {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value -notmatch '^bytes ([0-9]+)-([0-9]+)/([0-9]+)$') {
        Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("Content-Range '{0}' is malformed." -f $Value)
    }
    $start = ConvertTo-UtParallelInvariantInt64 -Value $Matches[1] -Label 'Content-Range start' -Code (Get-UtParallelDownloadCode)
    $end = ConvertTo-UtParallelInvariantInt64 -Value $Matches[2] -Label 'Content-Range end' -Code (Get-UtParallelDownloadCode)
    $total = ConvertTo-UtParallelInvariantInt64 -Value $Matches[3] -Label 'Content-Range total' -Code (Get-UtParallelDownloadCode)
    if ($end -lt $start) { Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message 'Content-Range end precedes start.' }
    return [pscustomobject]@{ Start = $start; End = $end; Total = $total; Length = [long]($end - $start + 1L) }
}

function Assert-UtParallelResponseSource {
    param(
        [Parameter(Mandatory = $true)]$Response,
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$Architecture
    )
    $finalUri = [string]$Response.FinalUri
    if ([string]::IsNullOrWhiteSpace($finalUri)) { Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message 'The response did not report a final URL.' }
    $null = Assert-UtParallelOfficialSource -RequestedUri $Metadata.Url -FinalUri $finalUri -Architecture $Architecture -Code (Get-UtParallelDownloadCode)
}

function Assert-UtParallelETag {
    param(
        [Parameter(Mandatory = $true)]$Headers,
        [Parameter(Mandatory = $true)]$Metadata
    )
    $responseEtag = Get-UtParallelHeaderValue -Headers $Headers -Name 'etag' -Required
    $kind = Get-UtETagKind -ETag $responseEtag
    if ($kind -cne 'Strong' -or $responseEtag -cne [string]$Metadata.ETag) {
        Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message 'The response ETag is missing, weak, malformed or different from the HEAD snapshot.'
    }
}

function Assert-UtParallelIdentityEncoding {
    param([Parameter(Mandatory = $true)]$Headers)
    if ($Headers.ContainsKey('content-encoding')) {
        $encoding = Get-UtParallelHeaderValue -Headers $Headers -Name 'content-encoding' -Required
        if ($encoding -cne 'identity') {
            Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("The response Content-Encoding '{0}' is not identity." -f $encoding)
        }
    }
}

function Assert-UtParallelSegmentResponse {
    param(
        [Parameter(Mandatory = $true)]$Response,
        [Parameter(Mandatory = $true)]$Handle,
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$Architecture
    )
    Assert-UtParallelResponseSource -Response $Response -Metadata $Metadata -Architecture $Architecture
    if ([int]$Response.ExitCode -ne 0) {
        Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("The range request bytes={0}-{1} failed (curl exit {2}, HTTP {3})." -f $Handle.Request.Start, $Handle.Request.End, $Response.ExitCode, $Response.HttpCode)
    }
    if ([int]$Response.HttpCode -ne 206) {
        Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("The range request bytes={0}-{1} returned HTTP {2}; HTTP 206 is required." -f $Handle.Request.Start, $Handle.Request.End, $Response.HttpCode)
    }
    $contentRange = ConvertFrom-UtParallelContentRange -Value (Get-UtParallelHeaderValue -Headers $Response.Headers -Name 'content-range' -Required)
    if ($contentRange.Start -ne [long]$Handle.Request.Start -or $contentRange.End -ne [long]$Handle.Request.End -or $contentRange.Total -ne [long]$Metadata.ContentLength) {
        Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message 'The response Content-Range does not exactly match the requested range and HEAD length.'
    }
    Assert-UtParallelETag -Headers $Response.Headers -Metadata $Metadata
    Assert-UtParallelIdentityEncoding -Headers $Response.Headers
    if ($Response.Headers.ContainsKey('content-length')) {
        $reportedLength = ConvertTo-UtParallelInvariantInt64 -Value (Get-UtParallelHeaderValue -Headers $Response.Headers -Name 'content-length' -Required) -Label 'Content-Length' -Code (Get-UtParallelDownloadCode)
        if ($reportedLength -ne $contentRange.Length) {
            Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message 'The response Content-Length does not match Content-Range.'
        }
    }
    $path = [string]$Response.OutputPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message 'The range response did not produce a body file.'
    }
    $bodyItem = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if (($bodyItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message 'The range body file is a reparse point.'
    }
    $actualLength = [long]$bodyItem.Length
    if ($actualLength -ne $contentRange.Length) {
        Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("The range body length {0} does not match the requested {1} bytes." -f $actualLength, $contentRange.Length)
    }
    return $Response
}

function Assert-UtParallelProbeResponse {
    param(
        [Parameter(Mandatory = $true)]$Response,
        [Parameter(Mandatory = $true)]$Handle,
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$Architecture
    )
    Assert-UtParallelResponseSource -Response $Response -Metadata $Metadata -Architecture $Architecture
    if ([int]$Response.HttpCode -eq 200) {
        if ([int]$Response.ExitCode -ne 0 -and [int]$Response.ExitCode -ne 63) {
            Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("The 200 range probe stopped with curl exit {0}; only a completed request or the explicit size-cap exit 63 is accepted." -f $Response.ExitCode)
        }
        $contentLength = ConvertTo-UtParallelInvariantInt64 -Value (Get-UtParallelHeaderValue -Headers $Response.Headers -Name 'content-length' -Required) -Label 'Probe Content-Length' -Code (Get-UtParallelDownloadCode)
        if ($contentLength -ne [long]$Metadata.ContentLength) {
            Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message 'A 200 range probe did not report the complete HEAD Content-Length.'
        }
        if ($Response.Headers.ContainsKey('content-range')) {
            Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message 'A 200 range probe unexpectedly returned Content-Range.'
        }
        Assert-UtParallelETag -Headers $Response.Headers -Metadata $Metadata
        Assert-UtParallelIdentityEncoding -Headers $Response.Headers
        return 'FullResponse'
    }
    if ([int]$Response.ExitCode -ne 0) {
        Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("The bounded range probe failed (curl exit {0}, HTTP {1})." -f $Response.ExitCode, $Response.HttpCode)
    }
    if ([int]$Response.HttpCode -ne 206) {
        Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("The bounded range probe returned HTTP {0}; HTTP 206 or a validated 200 fallback is required." -f $Response.HttpCode)
    }
    $null = Assert-UtParallelSegmentResponse -Response $Response -Handle $Handle -Metadata $Metadata -Architecture $Architecture
    return 'RangeResponse'
}

# ---------------------------------------------------------------------------
# Public one-range helpers.  These make small live transport checks possible
# without invoking the full 900 MiB candidate flow.
# ---------------------------------------------------------------------------
function Start-UtRangeDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$RunDirectory,
        [Parameter(Mandatory = $true)][string]$Architecture,
        [Parameter(Mandatory = $false)]$Range,
        [Parameter(Mandatory = $false)][long]$Start = -1,
        [Parameter(Mandatory = $false)][long]$End = -1,
        [int]$Index = -1,
        [switch]$Probe,
        [string]$SegmentDirectory
    )
    $normalized = Assert-UtParallelMetadata -Metadata $Metadata -Architecture $Architecture
    if ($normalized.ETagKind -cne 'Strong') {
        Stop-UtParallel -Code (Get-UtParallelMetadataCode) -Message 'A range request requires a legal strong ETag validator.'
    }
    if ($null -ne $Range) {
        $rangeValues = Get-UtParallelRangeValues -Range $Range -TotalLength $normalized.ContentLength
        $start = $rangeValues.Start
        $end = $rangeValues.End
    } else {
        if ($Start -lt 0 -or $End -lt $Start) { Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message 'Start-UtRangeDownload requires a valid Start and End.' }
        $rangeValues = Get-UtParallelRangeValues -Range ([pscustomobject]@{ Start = $Start; End = $End }) -TotalLength $normalized.ContentLength
        $start = $rangeValues.Start
        $end = $rangeValues.End
    }
    if ($Probe -and ($start -ne 0 -or $end -ne 0)) { Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message 'The bounded probe must request bytes=0-0.' }
    if ([string]::IsNullOrWhiteSpace($RunDirectory)) { Stop-UtParallel -Code (Get-UtParallelEnvironmentCode) -Message 'RunDirectory is empty.' }
    try { $runFull = [System.IO.Path]::GetFullPath($RunDirectory) } catch { Stop-UtParallel -Code (Get-UtParallelEnvironmentCode) -Message ("RunDirectory '{0}' is invalid." -f $RunDirectory) }
    if (-not (Test-Path -LiteralPath $runFull -PathType Container)) {
        try { [void][System.IO.Directory]::CreateDirectory($runFull) } catch { Stop-UtParallel -Code (Get-UtParallelEnvironmentCode) -Message ("RunDirectory '{0}' could not be created: {1}" -f $runFull, $_.Exception.Message) }
    }
    if ([string]::IsNullOrWhiteSpace($SegmentDirectory)) {
        $segmentRoot = Join-Path $runFull ('segments-' + [guid]::NewGuid().ToString('N'))
    } else {
        $segmentRoot = [System.IO.Path]::GetFullPath($SegmentDirectory)
    }
    $managedPathGuard = Get-Command Assert-UtManagedPath -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $managedPathGuard) { Assert-UtManagedPath -Path $segmentRoot -Root $runFull -AllowMissingLeaf }
    [void][System.IO.Directory]::CreateDirectory($segmentRoot)
    if ($null -ne $managedPathGuard) { Assert-UtManagedPath -Path $segmentRoot -Root $runFull }
    if ($Probe) {
        $name = 'probe'
    } elseif ($Index -ge 0) {
        $name = 'segment-{0:D4}' -f $Index
    } else {
        $name = 'range-{0}-{1}' -f $start, $end
    }
    $outputPath = Join-Path $segmentRoot ($name + '.partial')
    $headerPath = Join-Path $segmentRoot ($name + '.headers')
    $configPath = Join-Path $segmentRoot ($name + '.curlrc')
    $null = New-UtParallelCurlConfig -Path $configPath -ETag ([string]$normalized.ETag)
    $request = [pscustomobject]@{
        Metadata       = $normalized
        Url            = $normalized.Url
        FinalUri       = $normalized.FinalUri
        Architecture   = $Architecture
        Start          = [long]$start
        End            = [long]$end
        Length         = [long]($end - $start + 1L)
        Index          = [int]$Index
        Probe          = [bool]$Probe
        RunDirectory   = $runFull
        SegmentRoot    = $segmentRoot
        OutputPath     = $outputPath
        HeaderPath     = $headerPath
        ConfigPath     = $configPath
    }
    try {
        $worker = Start-UtParallelRangeProcess -Request $request
        return [pscustomobject]@{ Request = $request; Worker = $worker; Response = $null; Attempt = 0 }
    } catch {
        Remove-UtParallelHandleArtifacts -Handle ([pscustomobject]@{ Request = $request })
        throw
    }
}

function Complete-UtRangeDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Handle
    )
    if ($null -eq $Handle -or -not (Test-UtParallelProperty -Object $Handle -Name 'Request')) {
        Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message 'Range handle is missing its request.'
    }
    $request = $Handle.Request
    $worker = Get-UtParallelProperty -Object $Handle -Name 'Worker'
    if ($null -eq $worker) { Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message 'Range handle is missing its worker.' }
    $process = Get-UtParallelProperty -Object $worker -Name 'Process'
    $response = $null
    try {
        if ($null -ne $process) {
            while (-not $process.HasExited) {
                Test-UtParallelHeaderLimit -Handle $Handle
                Test-UtParallelProbeLimit -Handle $Handle
                Test-UtParallelSegmentLimit -Handle $Handle
                if ($process.HasExited) { break }
                Start-Sleep -Milliseconds 50
            }
            [void]$process.WaitForExit()
        }
        # A mocked boundary has no process loop, and a native process can write
        # the final oversized header just as it exits.  Check both cases before
        # accepting or classifying the response.
        Test-UtParallelHeaderLimit -Handle $Handle
        $response = ConvertTo-UtParallelResponseObject -Handle $Handle -Worker $worker
        # Retain the raw response even when a later semantic validator fails;
        # the receiver uses it to distinguish an eligible transport retry from
        # a terminal identity/range/source failure.
        $Handle.Response = $response
        if ((Get-UtParallelProperty -Object $worker -Name 'HeaderCapExceeded') -eq $true) {
            Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message 'The response header exceeded the configured size limit.'
        }
        if ($null -ne (Get-UtParallelProperty -Object $response -Name 'HeaderStatusCode') -and [int]$response.HeaderStatusCode -ne [int]$response.HttpCode) {
            Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message 'The response header status and write-out status disagree.'
        }
        if ($request.Probe) {
            $probeKind = Assert-UtParallelProbeResponse -Response $response -Handle $Handle -Metadata $request.Metadata -Architecture $request.Architecture
            $response | Add-Member -NotePropertyName ProbeKind -NotePropertyValue $probeKind -Force
        } else {
            $null = Assert-UtParallelSegmentResponse -Response $response -Handle $Handle -Metadata $request.Metadata -Architecture $request.Architecture
        }
        return $response
    } finally {
        if ($null -ne $process) { try { $process.Dispose() } catch { } }
    }
}

function Invoke-UtParallelNetworkRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Request)
    $handle = Start-UtRangeDownload -Metadata $Request.Metadata -RunDirectory $Request.RunDirectory -Architecture $Request.Architecture -Start $Request.Start -End $Request.End -Index $Request.Index -Probe:$Request.Probe -SegmentDirectory $Request.SegmentRoot
    return (Complete-UtRangeDownload -Handle $handle)
}

function Remove-UtParallelHandleArtifacts {
    param([Parameter(Mandatory = $true)]$Handle)
    $request = Get-UtParallelProperty -Object $Handle -Name 'Request'
    if ($null -eq $request) { return }
    foreach ($path in @($request.OutputPath, $request.HeaderPath, $request.ConfigPath)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$path)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
}

function Start-UtParallelRetry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Handle)
    $request = Get-UtParallelProperty -Object $Handle -Name 'Request'
    if ($null -eq $request) { Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message 'Cannot retry a range without its request.' }
    Remove-UtParallelHandleArtifacts -Handle $Handle
    $retry = Start-UtRangeDownload -Metadata $request.Metadata -RunDirectory $request.RunDirectory -Architecture $request.Architecture -Start $request.Start -End $request.End -Index $request.Index -SegmentDirectory $request.SegmentRoot
    $attempt = Get-UtParallelProperty -Object $Handle -Name 'Attempt'
    if ($null -eq $attempt) { $attempt = 0 }
    $retry.Attempt = [int]$attempt + 1
    return $retry
}

function Merge-UtRangeFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Ranges,
        [Parameter(Mandatory = $true)]$Responses,
        [Parameter(Mandatory = $true)][string]$PartialPath,
        [Parameter(Mandatory = $true)][long]$TotalLength
    )
    if ($TotalLength -le 0) { Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message 'Merge TotalLength must be positive.' }
    if ($null -eq $Ranges -or $Ranges.Count -eq 0) { Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message 'Merge requires at least one range.' }
    $ordered = @($Ranges | Sort-Object { [long](Get-UtParallelProperty -Object $_ -Name 'Start') })
    $expectedStart = [long]0
    $buffer = New-Object byte[] 1048576
    $output = $null
    try {
        $parent = Split-Path -Parent ([System.IO.Path]::GetFullPath($PartialPath))
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($parent) }
        $managedPathGuard = Get-Command Assert-UtManagedPath -CommandType Function -ErrorAction SilentlyContinue
        if ($null -ne $managedPathGuard) { Assert-UtManagedPath -Path $PartialPath -Root $parent -AllowMissingLeaf }
        $output = [System.IO.File]::Open($PartialPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        for ($position = 0; $position -lt $ordered.Count; $position++) {
            $range = $ordered[$position]
            $rangeValues = Get-UtParallelRangeValues -Range $range -TotalLength $TotalLength
            if ($rangeValues.Start -ne $expectedStart) {
                Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message 'Merge ranges are not continuous, ordered and non-overlapping.'
            }
            $indexValue = Get-UtParallelProperty -Object $range -Name 'Index'
            $index = if ($null -eq $indexValue) { $position } else { [int]$indexValue }
            $response = $null
            if ($Responses -is [System.Collections.IDictionary]) {
                if (-not $Responses.Contains($index)) { Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("Merge response for range index {0} is missing." -f $index) }
                $response = $Responses[$index]
            } else {
                $response = @($Responses)[$position]
            }
            $sourcePath = if ($response -is [string]) { [string]$response } else { [string](Get-UtParallelProperty -Object $response -Name 'OutputPath') }
            if ([string]::IsNullOrWhiteSpace($sourcePath) -or -not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("Merge body for range index {0} is missing." -f $index)
            }
            $sourceFull = [System.IO.Path]::GetFullPath($sourcePath)
            if (-not $sourceFull.StartsWith(([System.IO.Path]::GetFullPath($parent).TrimEnd('\') + '\'), [System.StringComparison]::OrdinalIgnoreCase)) {
                Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("Merge body for range index {0} escapes the run directory." -f $index)
            }
            if ($null -ne $managedPathGuard) { Assert-UtManagedPath -Path $sourceFull -Root $parent }
            $item = Get-Item -LiteralPath $sourceFull -Force -ErrorAction Stop
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or [long]$item.Length -ne $rangeValues.Length) {
                Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("Merge body for range index {0} has the wrong length or is a reparse point." -f $index)
            }
            $input = $null
            try {
                $input = [System.IO.File]::OpenRead($sourceFull)
                while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) { $output.Write($buffer, 0, $read) }
            } finally {
                if ($null -ne $input) { $input.Dispose() }
            }
            $expectedStart = $rangeValues.End + 1L
        }
        if ($expectedStart -ne $TotalLength) { Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message 'Merge ranges did not cover the complete object.' }
    } catch {
        if ($null -ne $output) { $output.Dispose(); $output = $null }
        Remove-Item -LiteralPath $PartialPath -Force -ErrorAction SilentlyContinue
        throw
    } finally {
        if ($null -ne $output) { $output.Dispose() }
    }
    $length = [long](Get-Item -LiteralPath $PartialPath -Force -ErrorAction Stop).Length
    if ($length -ne $TotalLength) {
        Remove-Item -LiteralPath $PartialPath -Force -ErrorAction SilentlyContinue
        Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message ("Merged body length {0} does not match {1}." -f $length, $TotalLength)
    }
    return [System.IO.Path]::GetFullPath($PartialPath)
}

function Remove-UtParallelSegmentRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    try {
        $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
        $leaf = [System.IO.Path]::GetFileName($full)
        if ($leaf -notmatch '^segments-[0-9a-fA-F]{32}$') { return }
        $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return }
        $entries = @(Get-ChildItem -LiteralPath $full -Force -ErrorAction Stop)
        if ($entries.Count -eq 0) { Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue }
    } catch { }
}

# ---------------------------------------------------------------------------
# Full candidate receiver.
# ---------------------------------------------------------------------------
function Update-UtParallelProgress {
    param(
        [object[]]$Handles,
        [long]$TotalLength,
        [datetime]$StartedAt,
        [int]$Connections,
        [switch]$Background
    )
    if ($Background) { return }
    $bytes = [long]0
    foreach ($handle in @($Handles)) {
        $request = Get-UtParallelProperty -Object $handle -Name 'Request'
        $path = [string](Get-UtParallelProperty -Object $request -Name 'OutputPath')
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            try { $bytes += [long](Get-Item -LiteralPath $path -Force).Length } catch { }
        }
    }
    $elapsed = ([datetime]::UtcNow - $StartedAt).TotalSeconds
    if ($elapsed -lt 0.1) { $elapsed = 0.1 }
    $speed = [double]$bytes / $elapsed
    $percent = [int][math]::Min(100, [math]::Max(0, [math]::Floor(([double]$bytes * 100.0) / [double]$TotalLength)))
    $status = '{0} / {1} bytes, {2:N1} MiB/s, {3} connections' -f $bytes, $TotalLength, ($speed / 1MB), $Connections
    Write-Progress -Id 7321 -Activity 'Downloading ChatGPT MSIX' -Status $status -PercentComplete $percent
}

function Receive-UtParallelCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$RunDirectory,
        [Parameter(Mandatory = $true)][string]$Architecture,
        [int]$Connections = 8,
        [switch]$Background
    )

    Assert-UtParallelConnections -Connections $Connections
    $normalized = Assert-UtParallelMetadata -Metadata $Metadata -Architecture $Architecture
    if ([string]::IsNullOrWhiteSpace($RunDirectory)) { Stop-UtParallel -Code (Get-UtParallelEnvironmentCode) -Message 'RunDirectory is empty.' }

    # The serial backend is the only safe path when no strong validator binds
    # each range to the HEAD object.  It is also deliberately used for an
    # explicit one-connection request.
    if ($Connections -eq 1 -or $normalized.ETagKind -ne 'Strong') {
        $receiver = Get-Command Receive-UtCandidate -CommandType Function -ErrorAction SilentlyContinue
        if ($null -eq $receiver) { Stop-UtParallel -Code (Get-UtParallelDownloadCode) -Message 'The serial download backend is unavailable.' }
        if ($receiver.Parameters.ContainsKey('Background')) {
            return (Receive-UtCandidate -Metadata $normalized -RunDirectory $RunDirectory -Architecture $Architecture -Background:$Background)
        }
        return (Receive-UtCandidate -Metadata $normalized -RunDirectory $RunDirectory -Architecture $Architecture)
    }

    $segmentRoot = Join-Path ([System.IO.Path]::GetFullPath($RunDirectory)) ('segments-' + [guid]::NewGuid().ToString('N'))
    $handles = New-Object System.Collections.ArrayList
    $startedAt = [datetime]::UtcNow
    try {
        # First make a tiny bounded request.  A validated 200 means this object
        # does not support ranges; the complete serial backend may then safely
        # download the object from the same strong ETag snapshot.  Every other
        # unexpected result fails closed and never falls back.
        $probe = Start-UtRangeDownload -Metadata $normalized -RunDirectory $RunDirectory -Architecture $Architecture -Start 0 -End 0 -Index 0 -Probe -SegmentDirectory $segmentRoot
        [void]$handles.Add($probe)
        $probeResponse = Complete-UtRangeDownload -Handle $probe
        if ([string]$probeResponse.ProbeKind -eq 'FullResponse') {
            $null = Remove-UtParallelHandleArtifacts -Handle $probe
            Remove-UtParallelSegmentRoot -Path $segmentRoot
            return (Receive-UtCandidate -Metadata $normalized -RunDirectory $RunDirectory -Architecture $Architecture)
        }
        Remove-UtParallelHandleArtifacts -Handle $probe
        [void]$handles.Remove($probe)

        $plan = @(New-UtRangePlan -TotalLength ([long]$normalized.ContentLength) -Connections $Connections)
        $pending = New-Object System.Collections.ArrayList
        foreach ($range in $plan) {
            try {
                $handle = Start-UtRangeDownload -Metadata $normalized -RunDirectory $RunDirectory -Architecture $Architecture -Range $range -Index $range.Index -SegmentDirectory $segmentRoot
                [void]$handles.Add($handle)
                [void]$pending.Add($handle)
            } catch {
                Stop-UtParallelOwnedProcesses -Handles @($handles)
                throw
            }
        }

        $completed = @{}
        while ($pending.Count -gt 0) {
            foreach ($pendingHandle in @($pending.ToArray())) {
                Test-UtParallelHeaderLimit -Handle $pendingHandle
                Test-UtParallelProbeLimit -Handle $pendingHandle
                Test-UtParallelSegmentLimit -Handle $pendingHandle
            }
            Update-UtParallelProgress -Handles @($handles) -TotalLength ([long]$normalized.ContentLength) -StartedAt $startedAt -Connections $plan.Count -Background:$Background
            $madeProgress = $false
            foreach ($handle in @($pending.ToArray())) {
                if (-not (Test-UtParallelHandleReady -Handle $handle)) { continue }
                try {
                    $completed[[int]$handle.Request.Index] = Complete-UtRangeDownload -Handle $handle
                } catch {
                    $attempt = Get-UtParallelProperty -Object $handle -Name 'Attempt'
                    if ($null -eq $attempt) { $attempt = 0 }
                    if (-not [bool]$handle.Request.Probe -and [int]$attempt -lt 1 -and (Test-UtParallelRetryableFailure -Handle $handle -ErrorRecord $_)) {
                        try {
                            $retryHandle = Start-UtParallelRetry -Handle $handle
                        } catch {
                            Stop-UtParallelOwnedProcesses -Handles @($handles)
                            throw
                        }
                        [void]$pending.Remove($handle)
                        [void]$handles.Remove($handle)
                        [void]$handles.Add($retryHandle)
                        [void]$pending.Add($retryHandle)
                        $madeProgress = $true
                        continue
                    }
                    Stop-UtParallelOwnedProcesses -Handles @($handles)
                    throw
                }
                [void]$pending.Remove($handle)
                $madeProgress = $true
            }
            if (-not $madeProgress -and $pending.Count -gt 0) { Start-Sleep -Milliseconds 75 }
        }
        Update-UtParallelProgress -Handles @($handles) -TotalLength ([long]$normalized.ContentLength) -StartedAt $startedAt -Connections $plan.Count -Background:$Background
        if (-not $Background) { Write-Progress -Id 7321 -Activity 'Downloading ChatGPT MSIX' -Completed }

        $partialPath = Join-Path ([System.IO.Path]::GetFullPath($RunDirectory)) ('ChatGPT-{0}.msix.partial' -f $Architecture)
        $finalPath = Join-Path ([System.IO.Path]::GetFullPath($RunDirectory)) ('ChatGPT-{0}.msix' -f $Architecture)
        Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $finalPath -Force -ErrorAction SilentlyContinue
        $merged = Merge-UtRangeFiles -Ranges $plan -Responses $completed -PartialPath $partialPath -TotalLength ([long]$normalized.ContentLength)
        Move-Item -LiteralPath $partialPath -Destination $finalPath -Force -ErrorAction Stop
        foreach ($handle in @($handles)) { Remove-UtParallelHandleArtifacts -Handle $handle }
        Remove-UtParallelSegmentRoot -Path $segmentRoot
        return $finalPath
    } catch {
        Stop-UtParallelOwnedProcesses -Handles @($handles)
        if (-not $Background) { Write-Progress -Id 7321 -Activity 'Downloading ChatGPT MSIX' -Completed -ErrorAction SilentlyContinue }
        foreach ($handle in @($handles)) { Remove-UtParallelHandleArtifacts -Handle $handle }
        Remove-UtParallelSegmentRoot -Path $segmentRoot
        $partial = Join-Path ([System.IO.Path]::GetFullPath($RunDirectory)) ('ChatGPT-{0}.msix.partial' -f $Architecture)
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        throw
    }
}
