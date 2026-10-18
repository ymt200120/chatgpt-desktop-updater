#requires -Version 5.1
<##
    Shared, side-effect-free helpers for the current-user background updater.

    This file only defines functions.  It deliberately does not register a
    task, start a process, call the network, or install an AppX package when it
    is dot-sourced.  The worker and confirmation process own those actions.

    The state file is an index and retry journal.  A candidate contains only
    a safe cache key, a four-part version, and a whitelisted metadata snapshot;
    it never stores a path or a command supplied by a file.
##>
[CmdletBinding()]
param(
    [string]$CorePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:UbStateSchema = 1
$script:UbStateFileName = 'background-state.json'
$script:UbStateLockName = 'background-state.lock'
$script:UbPromptLockName = 'background-prompt.lock'
$script:UbLogLockName = 'background-log.lock'
$script:UbLogName = 'background.log'
$script:UbMaxStateBytes = 262144
$script:UbMaxLogBytes = 262144
$script:UbCheckInterval = [TimeSpan]::FromDays(7)
$script:UbRetryInterval = [TimeSpan]::FromHours(6)
$script:UbSnoozeInterval = [TimeSpan]::FromHours(24)
$script:UbPromptTimeout = [TimeSpan]::FromMinutes(10)
$script:UbTaskName = 'ChatGPTUpdater-Background'
$script:UbTaskMarker = 'ChatGPTUpdater-owned-v1'

if ([string]::IsNullOrWhiteSpace($CorePath)) { $CorePath = Join-Path $PSScriptRoot 'update-chatgpt.ps1' }
$coreLoadVariable = Get-Variable -Name UbCoreLoadInProgress -Scope Script -ErrorAction SilentlyContinue
$coreAlreadyLoaded = Get-Command Invoke-UtConfirmedInstall -CommandType Function -ErrorAction SilentlyContinue
if ((Test-Path -LiteralPath $CorePath -PathType Leaf) -and $null -eq $coreAlreadyLoaded -and ($null -eq $coreLoadVariable -or -not [bool]$coreLoadVariable.Value)) {
    Set-Variable -Name UbCoreLoadInProgress -Scope Script -Value $true
    try { . ([IO.Path]::GetFullPath($CorePath)) }
    finally { Set-Variable -Name UbCoreLoadInProgress -Scope Script -Value $false }
}

function Get-UbProperty {
    param($Object, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-UbLocalAppData {
    $value = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    if ([string]::IsNullOrWhiteSpace($value)) { throw 'LOCALAPPDATA is not set.' }
    return [IO.Path]::GetFullPath($value)
}

function Get-UbRoot {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Join-Path (Get-UbLocalAppData) 'ChatGPTUpdater' }
    $full = [IO.Path]::GetFullPath($Root)
    if ([string]::IsNullOrWhiteSpace($full) -or $full -eq [IO.Path]::GetPathRoot($full)) { throw 'Unsafe background state root.' }
    return $full.TrimEnd('\')
}

function Get-UbStableRoot {
    return (Join-Path (Get-UbLocalAppData) 'Programs\ChatGPTUpdater')
}

function Assert-UbDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($full) -or $full -eq [IO.Path]::GetPathRoot($full).TrimEnd('\')) { throw "Refusing an unsafe directory: $Path" }

    # Walk to an existing ancestor before creating anything.  This prevents a
    # missing child below a junction/symlink from being created through the
    # reparse point before the safety check runs.
    $probe = $full
    while (-not (Test-Path -LiteralPath $probe)) {
        $parentPath = [IO.Directory]::GetParent($probe)
        if ([string]::IsNullOrWhiteSpace($parentPath) -or $parentPath -eq $probe) { throw "Cannot resolve directory ancestry: $full" }
        $probe = $parentPath
    }
    $existing = Get-Item -LiteralPath $probe -Force -ErrorAction Stop
    if (-not $existing.PSIsContainer) { throw "Refusing to create below a non-directory ancestor: $($existing.FullName)" }
    $ancestor = $existing
    while ($null -ne $ancestor) {
        if (($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing a reparse-point ancestor: $($ancestor.FullName)" }
        $ancestor = $ancestor.Parent
    }
    if (Test-Path -LiteralPath $full) {
        $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Refusing to use a non-directory or reparse-point directory: $full"
        }
    } else {
        $null = [IO.Directory]::CreateDirectory($full)
    }
    $ancestor = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    while ($null -ne $ancestor) {
        if (($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing a reparse-point ancestor: $($ancestor.FullName)" }
        $ancestor = $ancestor.Parent
    }
    return $full
}

function Get-UbStatePath {
    param([string]$Root)
    return (Join-Path (Get-UbRoot -Root $Root) $script:UbStateFileName)
}

function Get-UbLogPath {
    param([string]$Root)
    return (Join-Path (Get-UbRoot -Root $Root) $script:UbLogName)
}

function Enter-UbFileLock {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][ValidateSet('State','Prompt','Log')][string]$Kind
    )
    $directory = Assert-UbDirectory -Path (Get-UbRoot -Root $Root)
    $name = switch ($Kind) {
        'State' { $script:UbStateLockName }
        'Prompt' { $script:UbPromptLockName }
        'Log' { $script:UbLogLockName }
    }
    $path = Join-Path $directory $name
    if (Test-Path -LiteralPath $path) {
        $lockItem = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($lockItem.PSIsContainer -or (($lockItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw "Refusing a non-regular or reparse-point lock: $path" }
    }
    return [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
}

function Enter-UbStateLock {
    param([string]$Root)
    return Enter-UbFileLock -Root (Get-UbRoot -Root $Root) -Kind State
}

function Enter-UbPromptLock {
    param([string]$Root)
    return Enter-UbFileLock -Root (Get-UbRoot -Root $Root) -Kind Prompt
}

function New-UbEmptyState {
    return [pscustomobject]@{
        Schema = $script:UbStateSchema
        LastSuccessfulCheck = $null
        LastCheckAttempt = $null
        LastPrepareSuccess = $null
        Candidate = $null
        # A deferred registration is durable phase state, independent from the
        # human-readable LastMessage.  The key binds it to one candidate so a
        # later candidate cannot inherit a previous deferred completion probe.
        DeferredCandidateKey = $null
        SnoozeUntil = $null
        LastFailure = $null
        NextRetryAt = $null
        LastMessage = $null
    }
}

function ConvertTo-UbUtcDate {
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    try {
        if ($Value -is [DateTimeOffset]) { return $Value.ToUniversalTime().ToString('o') }
        if ($Value -is [DateTime]) {
            $date = [DateTime]$Value
            if ($date.Kind -eq [DateTimeKind]::Unspecified) { $date = [DateTime]::SpecifyKind($date, [DateTimeKind]::Utc) }
            return $date.ToUniversalTime().ToString('o')
        }
        $parsed = [DateTime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        if ($parsed.Kind -eq [DateTimeKind]::Unspecified) { $parsed = [DateTime]::SpecifyKind($parsed, [DateTimeKind]::Utc) }
        return $parsed.ToUniversalTime().ToString('o')
    }
    catch { throw "Invalid UTC timestamp in background state: $Value" }
}

function ConvertTo-UbVersionText {
    param([Parameter(Mandatory = $true)]$Value)
    $text = ([string]$Value).Trim()
    if ($text -notmatch '^[0-9]{1,5}(\.[0-9]{1,5}){3}$') { throw "Invalid candidate version '$Value'." }
    foreach ($part in $text.Split('.')) {
        $number = 0
        if (-not [int]::TryParse($part, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or $number -lt 0 -or $number -gt 65535) { throw "Invalid candidate version '$Value'." }
    }
    return $text
}

function ConvertTo-UbKey {
    param([Parameter(Mandatory = $true)][string]$Value)
    $text = $Value.Trim()
    if ($text.Length -lt 1 -or $text.Length -gt 180 -or $text -notmatch '^[A-Za-z0-9._-]+$' -or $text -match '\.\.|^[.]|[.]$') { throw 'Candidate key contains unsafe characters.' }
    return $text
}

function ConvertTo-UbSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [string]$Architecture,
        [string]$SHA256,
        [switch]$RequireSHA256
    )
    $version = Get-UbProperty $Metadata 'Version'
    if ($null -eq $version) { throw 'Metadata snapshot has no version.' }
    $length = Get-UbProperty $Metadata 'ContentLength'
    if ($null -eq $length) { $length = Get-UbProperty $Metadata 'Length' }
    $lengthValue = 0L
    if ($null -eq $length -or -not [Int64]::TryParse([string]$length, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$lengthValue) -or $lengthValue -lt 1) { throw 'Metadata snapshot has an invalid content length.' }
    $architectureValue = if ([string]::IsNullOrWhiteSpace($Architecture)) { [string](Get-UbProperty $Metadata 'Architecture') } else { [string]$Architecture }
    if ($architectureValue -notin @('x64','arm64')) { throw 'Metadata snapshot has an unsupported architecture.' }
    $etag = Get-UbProperty $Metadata 'ETag'
    $url = Get-UbProperty $Metadata 'Url'
    if ($null -eq $url) { $url = Get-UbProperty $Metadata 'URL' }
    if ($null -ne $url) {
        $uri = $null
        if (-not [Uri]::TryCreate([string]$url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.Host -ne 'persistent.oaistatic.com' -or -not $uri.IsDefaultPort -or -not [string]::IsNullOrEmpty($uri.UserInfo) -or -not [string]::IsNullOrEmpty($uri.Query) -or -not [string]::IsNullOrEmpty($uri.Fragment) -or $uri.AbsolutePath -cne ('/codex-app-prod/ChatGPT-{0}.msix' -f $architectureValue)) { throw 'Metadata snapshot URL is outside the official HTTPS source.' }
        $url = $uri.AbsoluteUri
    }
    $finalUri = Get-UbProperty $Metadata 'FinalUri'
    if ($null -eq $finalUri) { $finalUri = $url }
    if ($null -ne $finalUri) {
        $finalParsed = $null
        if (-not [Uri]::TryCreate([string]$finalUri, [UriKind]::Absolute, [ref]$finalParsed) -or $finalParsed.Scheme -ne 'https' -or $finalParsed.Host -ne 'persistent.oaistatic.com' -or -not $finalParsed.IsDefaultPort -or -not [string]::IsNullOrEmpty($finalParsed.UserInfo) -or -not [string]::IsNullOrEmpty($finalParsed.Query) -or -not [string]::IsNullOrEmpty($finalParsed.Fragment) -or $finalParsed.AbsolutePath -cne ('/codex-app-prod/ChatGPT-{0}.msix' -f $architectureValue)) { throw 'Metadata final URL is outside the official HTTPS source.' }
        $finalUri = $finalParsed.AbsoluteUri
    }
    $etagKind = [string](Get-UbProperty $Metadata 'ETagKind')
    if ([string]::IsNullOrWhiteSpace($etagKind)) {
        if ($null -eq $etag -or [string]::IsNullOrWhiteSpace([string]$etag)) { $etagKind = 'Missing' }
        elseif ([string]$etag -match '^W/') { $etagKind = 'Weak' }
        else { $etagKind = 'Strong' }
    }
    if ($etagKind -notin @('Strong','Weak','Missing')) { throw 'Metadata snapshot has an invalid ETag kind.' }
    $shaValue = if ([string]::IsNullOrEmpty($SHA256)) { $null } else { $SHA256.ToUpperInvariant() }
    $result = [ordered]@{
        Architecture = $architectureValue
        Version = ConvertTo-UbVersionText $version
        ContentLength = $lengthValue
        ETag = if ($null -eq $etag -or [string]::IsNullOrWhiteSpace([string]$etag)) { $null } else { [string]$etag }
        ETagKind = $etagKind
        StrongETag = ($etagKind -eq 'Strong')
        Url = if ($null -eq $url) { $null } else { [string]$url }
        FinalUri = if ($null -eq $finalUri) { $null } else { [string]$finalUri }
        SHA256 = $shaValue
    }
    if ($null -eq $result.Url -or $null -eq $result.FinalUri) { throw 'Metadata snapshot must retain the official URL and final URI.' }
    if ($RequireSHA256 -and $null -eq $result.SHA256) { throw 'Metadata snapshot requires a computed SHA256 audit value.' }
    if ($null -ne $result.SHA256 -and $result.SHA256 -notmatch '^[0-9A-F]{64}$') { throw 'Metadata snapshot has an invalid SHA256 audit value.' }
    return [pscustomobject]$result
}

function New-UbCandidate {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)]$Snapshot
    )
    return [pscustomobject]@{
        Key = ConvertTo-UbKey $Key
        Version = ConvertTo-UbVersionText $Version
        Snapshot = $Snapshot
    }
}

function Assert-UbCandidate {
    param([Parameter(Mandatory = $true)]$Candidate)
    if ($null -eq $Candidate) { throw 'Candidate is missing.' }
    $names = @($Candidate.PSObject.Properties.Name | Sort-Object)
    if ((@($names) -join '|') -ne 'Key|Snapshot|Version') { throw 'Candidate state contains unsupported fields.' }
    $snapshot = ConvertTo-UbSnapshot -Metadata $Candidate.Snapshot -Architecture (Get-UbProperty $Candidate.Snapshot 'Architecture') -SHA256 (Get-UbProperty $Candidate.Snapshot 'SHA256') -RequireSHA256
    $null = ConvertTo-UbKey ([string]$Candidate.Key)
    $version = ConvertTo-UbVersionText $Candidate.Version
    if ($version -ne (ConvertTo-UbVersionText (Get-UbProperty $snapshot 'Version'))) { throw 'Candidate version and snapshot version differ.' }
    return (New-UbCandidate -Key ([string]$Candidate.Key) -Version $version -Snapshot $snapshot)
}

function Read-UbState {
    param([string]$Root)
    $path = Get-UbStatePath -Root $Root
    if (-not (Test-Path -LiteralPath $path)) { return (New-UbEmptyState) }
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -gt $script:UbMaxStateBytes) { throw 'Background state is not a bounded regular file.' }
    $raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'Background state is empty.' }
    try { $state = $raw | ConvertFrom-Json -ErrorAction Stop } catch { throw "Background state JSON is invalid: $($_.Exception.Message)" }
    if ([int](Get-UbProperty $state 'Schema') -ne $script:UbStateSchema) { throw 'Unsupported background state schema.' }
    $result = New-UbEmptyState
    foreach ($field in @('LastSuccessfulCheck','LastCheckAttempt','LastPrepareSuccess','SnoozeUntil','NextRetryAt')) {
        $value = Get-UbProperty $state $field
        $result.$field = ConvertTo-UbUtcDate $value
    }
    $result.LastFailure = [string](Get-UbProperty $state 'LastFailure')
    if ([string]::IsNullOrWhiteSpace($result.LastFailure)) { $result.LastFailure = $null }
    $result.LastMessage = [string](Get-UbProperty $state 'LastMessage')
    if ([string]::IsNullOrWhiteSpace($result.LastMessage)) { $result.LastMessage = $null }
    $candidate = Get-UbProperty $state 'Candidate'
    if ($null -ne $candidate) { $result.Candidate = Assert-UbCandidate $candidate }

    # Schema 1 states written before DeferredCandidateKey existed have only
    # LastMessage='Deferred'.  Migrate that marker only when the field is
    # absent, and bind it to the candidate that was already persisted.  A
    # present null marker is treated as an intentional clear, which prevents
    # a newer state from inventing deferred state from stale display text.
    $hasDeferredMarker = $null -ne $state.PSObject.Properties['DeferredCandidateKey']
    $rawDeferredKey = Get-UbProperty $state 'DeferredCandidateKey'
    if ($null -ne $rawDeferredKey -and -not [string]::IsNullOrWhiteSpace([string]$rawDeferredKey)) {
        try { $result.DeferredCandidateKey = ConvertTo-UbKey ([string]$rawDeferredKey) }
        catch { throw 'Background state contains an invalid deferred candidate key.' }
    }
    if ($null -eq $result.Candidate) {
        $result.DeferredCandidateKey = $null
    } elseif ($null -ne $result.DeferredCandidateKey) {
        # A marker for another candidate is stale and cannot authorize a
        # completion check for the currently stored candidate.
        if ([string]$result.DeferredCandidateKey -cne [string]$result.Candidate.Key) { $result.DeferredCandidateKey = $null }
    } elseif (-not $hasDeferredMarker -and $result.LastMessage -ceq 'Deferred') {
        $result.DeferredCandidateKey = [string]$result.Candidate.Key
    }
    return $result
}

function Write-UbAtomicText {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
    $directory = Split-Path -Parent $Path
    $null = Assert-UbDirectory -Path $directory
    if (Test-Path -LiteralPath $Path) {
        $target = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($target.PSIsContainer -or (($target.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw "Refusing to overwrite a non-regular or reparse-point file: $Path" }
    }
    $temp = Join-Path $directory ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temp, $Text, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try { [IO.File]::Replace($temp, $Path, $null, $true) }
            catch { Move-Item -LiteralPath $temp -Destination $Path -Force -ErrorAction Stop }
        } else { Move-Item -LiteralPath $temp -Destination $Path -Force -ErrorAction Stop }
    } finally {
        if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Write-UbState {
    param([Parameter(Mandatory = $true)]$State, [string]$Root)
    $normalized = New-UbEmptyState
    foreach ($field in @('LastSuccessfulCheck','LastCheckAttempt','LastPrepareSuccess','SnoozeUntil','NextRetryAt')) { $normalized.$field = ConvertTo-UbUtcDate (Get-UbProperty $State $field) }
    $normalized.LastFailure = if ([string]::IsNullOrWhiteSpace([string](Get-UbProperty $State 'LastFailure'))) { $null } else { [string](Get-UbProperty $State 'LastFailure') }
    $normalized.LastMessage = if ([string]::IsNullOrWhiteSpace([string](Get-UbProperty $State 'LastMessage'))) { $null } else { [string](Get-UbProperty $State 'LastMessage') }
    $candidate = Get-UbProperty $State 'Candidate'
    if ($null -ne $candidate) { $normalized.Candidate = Assert-UbCandidate $candidate }
    $hasDeferredMarker = $null -ne $State.PSObject.Properties['DeferredCandidateKey']
    $deferredKey = Get-UbProperty $State 'DeferredCandidateKey'
    if ($null -ne $deferredKey -and -not [string]::IsNullOrWhiteSpace([string]$deferredKey)) {
        $normalized.DeferredCandidateKey = ConvertTo-UbKey ([string]$deferredKey)
        if ($null -eq $normalized.Candidate -or [string]$normalized.DeferredCandidateKey -cne [string]$normalized.Candidate.Key) {
            $normalized.DeferredCandidateKey = $null
        }
    } elseif (-not $hasDeferredMarker -and $null -ne $normalized.Candidate -and $normalized.LastMessage -ceq 'Deferred') {
        # Keep direct writes of a legacy state compatible with Read-UbState's
        # migration rule while still respecting an explicit null marker.
        $normalized.DeferredCandidateKey = [string]$normalized.Candidate.Key
    }
    $json = $normalized | ConvertTo-Json -Depth 8 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt $script:UbMaxStateBytes) { throw 'Background state exceeds its size limit.' }
    Write-UbAtomicText -Path (Get-UbStatePath -Root $Root) -Text $json
    return $normalized
}

function Set-UbStateFields {
    param([Parameter(Mandatory = $true)][hashtable]$Changes, [string]$Root)
    $lock = $null
    try {
        $lock = Enter-UbStateLock -Root $Root
        $state = Read-UbState -Root $Root
        foreach ($key in $Changes.Keys) { if ($state.PSObject.Properties[$key]) { $state.$key = $Changes[$key] } }
        return (Write-UbState -State $state -Root $Root)
    } finally { if ($null -ne $lock) { $lock.Dispose() } }
}

function Write-UbLog {
    param([Parameter(Mandatory = $true)][string]$Message, [string]$Root)
    $lock = $null
    try {
        $lock = Enter-UbFileLock -Root (Get-UbRoot -Root $Root) -Kind Log
        $path = Get-UbLogPath -Root $Root
        $line = ('{0:o} {1}' -f [DateTime]::UtcNow, $Message) + [Environment]::NewLine
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path -Force
            if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Background log is not a regular file.' }
            if ($item.Length -gt $script:UbMaxLogBytes) {
                $old = Join-Path (Split-Path -Parent $path) 'background.log.1'
                if (Test-Path -LiteralPath $old) {
                    $oldItem = Get-Item -LiteralPath $old -Force -ErrorAction Stop
                    if ($oldItem.PSIsContainer -or (($oldItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Background log rotation target is unsafe.' }
                }
                Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
                Move-Item -LiteralPath $path -Destination $old -Force -ErrorAction Stop
            }
        }
        [IO.File]::AppendAllText($path, $line, (New-Object Text.UTF8Encoding($false)))
        $newItem = Get-Item -LiteralPath $path -Force
        if ($newItem.Length -gt $script:UbMaxLogBytes) {
            $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
            $keep = $text.Substring([Math]::Max(0, $text.Length - [int]($script:UbMaxLogBytes * 0.75)))
            [IO.File]::WriteAllText($path, $keep, (New-Object Text.UTF8Encoding($false)))
        }
    } catch { }
    finally { if ($null -ne $lock) { $lock.Dispose() } }
}

function Write-UbPromptStartupMarker {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Path)
    $rootFull = [IO.Path]::GetFullPath((Get-UbRoot -Root $Root)).TrimEnd('\')
    $markerFull = [IO.Path]::GetFullPath($Path)
    $prefix = $rootFull + '\'
    if (-not $markerFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Prompt startup marker escaped the background state root.' }
    $null = Write-UbAtomicText -Path $markerFull -Text (([pscustomobject]@{ Pid = [Diagnostics.Process]::GetCurrentProcess().Id; StartedUtc = [DateTime]::UtcNow.ToString('o') }) | ConvertTo-Json -Compress)
}

function ConvertTo-UbMetadataSnapshot {
    param([Parameter(Mandatory = $true)]$Metadata, [string]$Architecture, [string]$SHA256, [switch]$RequireSHA256)
    return ConvertTo-UbSnapshot -Metadata $Metadata -Architecture $Architecture -SHA256 $SHA256 -RequireSHA256:$RequireSHA256
}

function Get-UbCandidateKey {
    param([Parameter(Mandatory = $true)]$Prepared, [Parameter(Mandatory = $true)]$Metadata, [Parameter(Mandatory = $true)][string]$Architecture)
    $key = Get-UbProperty $Prepared 'Key'
    if ($null -eq $key) { $key = Get-UbProperty $Metadata 'Key' }
    if ($null -eq $key) {
        $version = ConvertTo-UbVersionText (Get-UbProperty $Metadata 'Version')
        $length = [string](Get-UbProperty $Metadata 'ContentLength')
        $etag = [string](Get-UbProperty $Metadata 'ETag')
        $safeEtag = if ([string]::IsNullOrWhiteSpace($etag)) { 'noetag' } else { ([Convert]::ToBase64String(([Text.Encoding]::UTF8.GetBytes($etag))) -replace '[^A-Za-z0-9]', '') }
        $key = '{0}-{1}-{2}-{3}' -f $Architecture, $version, $length, $safeEtag
    }
    return ConvertTo-UbKey ([string]$key)
}

function ConvertTo-UbCandidateFromPrepared {
    param([Parameter(Mandatory = $true)]$Prepared, [Parameter(Mandatory = $true)]$Metadata, [Parameter(Mandatory = $true)][string]$Architecture)
    $sha = Get-UbProperty $Prepared 'SHA256'
    $snapshot = ConvertTo-UbMetadataSnapshot -Metadata $Metadata -Architecture $Architecture -SHA256 ([string]$sha) -RequireSHA256
    $version = ConvertTo-UbVersionText (Get-UbProperty $Metadata 'Version')
    $key = Get-UbCandidateKey -Prepared $Prepared -Metadata $Metadata -Architecture $Architecture
    return New-UbCandidate -Key $key -Version $version -Snapshot $snapshot
}

function Test-UbSnapshotMatch {
    param([Parameter(Mandatory = $true)]$A, [Parameter(Mandatory = $true)]$B)
    try {
        if (Get-Command Test-UtSnapshotMatch -ErrorAction SilentlyContinue) { return [bool](Test-UtSnapshotMatch -A $A -B $B) }
    } catch { return $false }
    try {
        $left = ConvertTo-UbSnapshot -Metadata $A -Architecture (Get-UbProperty $A 'Architecture') -SHA256 (Get-UbProperty $A 'SHA256')
        $right = ConvertTo-UbSnapshot -Metadata $B -Architecture (Get-UbProperty $B 'Architecture') -SHA256 (Get-UbProperty $B 'SHA256')
        return ([string]$left.Architecture -ceq [string]$right.Architecture -and
            [string]$left.Version -ceq [string]$right.Version -and
            [Int64]$left.ContentLength -eq [Int64]$right.ContentLength -and
            [string]$left.ETag -ceq [string]$right.ETag -and
            [string]$left.ETagKind -ceq [string]$right.ETagKind -and
            [string]$left.Url -ceq [string]$right.Url -and
            [string]$left.FinalUri -ceq [string]$right.FinalUri)
    } catch { return $false }
}

function Get-UbNowUtc {
    param([datetime]$Now = [datetime]::MinValue)
    if ($Now -eq [datetime]::MinValue) { return [DateTime]::UtcNow }
    return $Now.ToUniversalTime()
}

function Test-UbDueForCheck {
    param($State, [datetime]$Now = [datetime]::MinValue)
    $utc = Get-UbNowUtc $Now
    $last = Get-UbProperty $State 'LastSuccessfulCheck'
    $retry = Get-UbProperty $State 'NextRetryAt'
    if ($null -ne $retry -and -not [string]::IsNullOrWhiteSpace([string]$retry)) {
        try { return (([DateTime]::Parse([string]$retry)).ToUniversalTime() -le $utc) } catch { return $true }
    }
    if ($null -eq $last -or [string]::IsNullOrWhiteSpace([string]$last)) { return $true }
    try { return (([DateTime]::Parse([string]$last)).ToUniversalTime() + $script:UbCheckInterval -le $utc) } catch { return $true }
}

function Test-UbReminderDue {
    param($State, [datetime]$Now = [datetime]::MinValue)
    $candidate = Get-UbProperty $State 'Candidate'
    if ($null -eq $candidate) { return $false }
    $utc = Get-UbNowUtc $Now
    $retry = Get-UbProperty $State 'NextRetryAt'
    if ($null -ne $retry -and -not [string]::IsNullOrWhiteSpace([string]$retry)) {
        try { if (([DateTime]::Parse([string]$retry)).ToUniversalTime() -gt $utc) { return $false } } catch { return $false }
    }
    $until = Get-UbProperty $State 'SnoozeUntil'
    if ($null -eq $until -or [string]::IsNullOrWhiteSpace([string]$until)) { return $true }
    try { return ([DateTime]::Parse([string]$until)).ToUniversalTime() -le $utc } catch { return $true }
}

function Set-UbCandidate {
    param([Parameter(Mandatory = $true)]$Candidate, [string]$Root, [datetime]$Now = [datetime]::MinValue)
    $utcText = (Get-UbNowUtc $Now).ToString('o')
    $lock = $null
    try {
        $lock = Enter-UbStateLock -Root $Root
        $state = Read-UbState -Root $Root
        $previousCandidate = Get-UbProperty $state 'Candidate'
        $state.Candidate = Assert-UbCandidate $Candidate
        $state.LastPrepareSuccess = $utcText
        $state.SnoozeUntil = $null
        $state.LastFailure = $null
        $state.NextRetryAt = $null
        $state.LastMessage = 'Ready'
        $sameCandidate = $false
        if ($null -ne $previousCandidate -and
            [string]$previousCandidate.Key -ceq [string]$state.Candidate.Key -and
            [string]$previousCandidate.Version -ceq [string]$state.Candidate.Version) {
            $sameCandidate = Test-UbSnapshotMatch -A $previousCandidate.Snapshot -B $state.Candidate.Snapshot
        }
        if (-not $sameCandidate) {
            $state.DeferredCandidateKey = $null
        }
        return Write-UbState -State $state -Root $Root
    } finally { if ($null -ne $lock) { $lock.Dispose() } }
}

function Set-UbHeadSuccess {
    param([string]$Root, [datetime]$Now = [datetime]::MinValue)
    $utcText = (Get-UbNowUtc $Now).ToString('o')
    return Set-UbStateFields -Root $Root -Changes @{ LastSuccessfulCheck = $utcText; LastCheckAttempt = $utcText; LastFailure = $null; NextRetryAt = $null; LastMessage = 'HEAD check succeeded' }
}

function Set-UbFailure {
    param([Parameter(Mandatory = $true)][string]$Message, [string]$Root, [datetime]$Now = [datetime]::MinValue, [switch]$HeadSucceeded)
    $utc = Get-UbNowUtc $Now
    $changes = @{ LastCheckAttempt = $utc.ToString('o'); LastFailure = $Message; NextRetryAt = $utc.Add($script:UbRetryInterval).ToString('o'); LastMessage = $Message }
    if ($HeadSucceeded) { $changes.LastSuccessfulCheck = $utc.ToString('o') }
    return Set-UbStateFields -Root $Root -Changes $changes
}

function Set-UbSnooze {
    param([string]$Root, [datetime]$Now = [datetime]::MinValue, [TimeSpan]$Duration = $script:UbSnoozeInterval)
    $until = (Get-UbNowUtc $Now).Add($Duration).ToString('o')
    return Set-UbStateFields -Root $Root -Changes @{ SnoozeUntil = $until; LastMessage = 'Snoozed' }
}

function Set-UbDeferred {
    # A deferred registration is not a completed install.  Keep the candidate
    # and give the worker a bounded reminder interval so it can observe the
    # next launch without prompting again immediately.
    param([string]$Root, [datetime]$Now = [datetime]::MinValue, [TimeSpan]$Duration = $script:UbSnoozeInterval)
    $until = (Get-UbNowUtc $Now).Add($Duration).ToString('o')
    $lock = $null
    try {
        $lock = Enter-UbStateLock -Root $Root
        $state = Read-UbState -Root $Root
        $candidate = Get-UbProperty $state 'Candidate'
        if ($null -eq $candidate) { throw 'Cannot mark a deferred registration without a candidate.' }
        $state.DeferredCandidateKey = [string]$candidate.Key
        $state.SnoozeUntil = $until
        $state.LastMessage = 'Deferred'
        return Write-UbState -State $state -Root $Root
    } finally { if ($null -ne $lock) { $lock.Dispose() } }
}

function Clear-UbCandidate {
    param([string]$Root, [string]$Message = 'Candidate cleared', [switch]$ImmediateRetry)
    $changes = @{ Candidate = $null; DeferredCandidateKey = $null; SnoozeUntil = $null; LastMessage = $Message }
    if ($ImmediateRetry) { $changes.LastSuccessfulCheck = $null; $changes.NextRetryAt = $null }
    return Set-UbStateFields -Root $Root -Changes $changes
}

function Test-UbCanShowPrompt {
    # The environment override is used only by isolated tests.  Production
    # uses the input desktop to avoid showing a prompt on a locked session.
    if ($env:CHATGPT_UPDATER_TEST_SESSION_LOCKED -eq '1') { return $false }
    if ($env:CHATGPT_UPDATER_TEST_SESSION_VISIBLE -eq '0') { return $false }
    try {
        if ($null -eq ('UbDesktopProbe' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class UbDesktopProbe {
  const int UOI_NAME = 2;
  [DllImport("user32.dll", SetLastError=true)] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
  [DllImport("user32.dll", SetLastError=true)] static extern bool CloseDesktop(IntPtr desktop);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern bool GetUserObjectInformation(IntPtr hObj, int nIndex, [Out] System.Text.StringBuilder pvInfo, int nLength, out uint lpnLengthNeeded);
  public static bool IsDefaultName(string name) {
    return string.Equals((name ?? string.Empty).TrimEnd('\0'), "Default", StringComparison.OrdinalIgnoreCase);
  }
  public static bool IsVisible() {
    IntPtr desktop = IntPtr.Zero;
    try {
      desktop = OpenInputDesktop(0, false, 0x0100|0x0001);
      if (desktop == IntPtr.Zero) return false;
      var name = new System.Text.StringBuilder(256);
      uint needed = 0;
      if (!GetUserObjectInformation(desktop, UOI_NAME, name, name.Capacity * 2, out needed)) return false;
      return IsDefaultName(name.ToString());
    }
    catch { return false; }
    finally { if (desktop != IntPtr.Zero) CloseDesktop(desktop); }
  }
}
'@ -ErrorAction Stop
        }
        return [UbDesktopProbe]::IsVisible()
    } catch { return $false }
}

function ConvertTo-UbProcessArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $quoted = $Value -replace '(\\*)"', '$1$1\"'
    $quoted = $quoted -replace '(\\+)$', '$1$1'
    return '"' + $quoted + '"'
}

function Start-UbPromptDetached {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$ExpectedKey,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion,
        [string]$CorePath,
        [string]$StartupMarker,
        [switch]$OpenApp,
        [switch]$TestMode,
        [string]$TestChoice,
        [int]$TimeoutSeconds = 0
    )
    try {
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { throw "Confirmation script is missing: $ScriptPath" }
    $rootFull = Assert-UbDirectory -Path (Get-UbRoot -Root $Root)
    if ([string]::IsNullOrWhiteSpace($StartupMarker)) { $StartupMarker = Join-Path $rootFull ('.background-prompt.started.' + [guid]::NewGuid().ToString('N') + '.json') }
    else {
        $markerFull = [IO.Path]::GetFullPath($StartupMarker)
        if (-not $markerFull.StartsWith($rootFull.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Prompt startup marker escaped the background state root.' }
        $StartupMarker = $markerFull
    }
    if (Test-Path -LiteralPath $StartupMarker) {
        $markerItem = Get-Item -LiteralPath $StartupMarker -Force -ErrorAction Stop
        if (($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Prompt startup marker is a reparse point.' }
        Remove-Item -LiteralPath $StartupMarker -Force -ErrorAction Stop
    }
    $systemRoot = [Environment]::GetEnvironmentVariable('SystemRoot')
    if ([string]::IsNullOrWhiteSpace($systemRoot)) { throw 'SystemRoot is not set; refusing an untrusted PowerShell executable.' }
    $powershell = Join-Path $systemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershell -PathType Leaf)) { throw 'Trusted Windows PowerShell 5.1 executable is unavailable.' }
    $args = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-STA','-WindowStyle','Hidden','-File',$ScriptPath,'-Root',$Root,'-ExpectedKey',$ExpectedKey,'-ExpectedVersion',$ExpectedVersion)
    if (-not [string]::IsNullOrWhiteSpace($CorePath)) { $args += @('-CorePath',$CorePath) }
    $args += @('-StartupMarker',$StartupMarker)
    if ($OpenApp) { $args += '-OpenApp' }
    if ($TestMode) { $args += '-TestMode' }
    if (-not [string]::IsNullOrWhiteSpace($TestChoice)) { $args += @('-TestChoice', $TestChoice) }
    if ($TimeoutSeconds -gt 0) { $args += @('-TimeoutSeconds',[string]$TimeoutSeconds) }
    $argumentText = (($args | ForEach-Object { ConvertTo-UbProcessArgument -Value ([string]$_) }) -join ' ')
    $process = Start-Process -FilePath $powershell -ArgumentList $argumentText -WindowStyle Hidden -PassThru -ErrorAction Stop
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not (Test-Path -LiteralPath $StartupMarker -PathType Leaf) -and -not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
    if (-not (Test-Path -LiteralPath $StartupMarker -PathType Leaf)) {
        $exitCode = if ($process.HasExited) { [string]$process.ExitCode } else { 'startup timeout' }
        throw "Confirmation process did not complete its startup handshake ($exitCode)."
    }
    Remove-Item -LiteralPath $StartupMarker -Force -ErrorAction SilentlyContinue
    return $process
    } catch {
        try {
            Write-UbLog -Root $Root -Message ('Confirmation process startup failed; Ready candidate retained: ' + $_.Exception.Message)
            $null = Set-UbFailure -Root $Root -Now ([DateTime]::UtcNow) -Message ('Confirmation process startup failed: ' + $_.Exception.Message)
        } catch { }
        throw
    }
}
