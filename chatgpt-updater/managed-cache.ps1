#requires -Version 5.1
<#!
    Managed complete-package cache and confirmed-install boundary.

    This file is dot-sourced by update-chatgpt.ps1.  It deliberately contains
    no independent entry point: all package validation and deployment remain in
    the production functions defined by that script.
#>

function Assert-UtManagedPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root,
        [switch]$AllowMissingLeaf
    )
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    if ($pathFull -ine $rootFull -and -not $pathFull.StartsWith($rootFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-Ut $script:UtExitSecurity "The managed path '$Path' escapes the controlled root."
    }

    $current = $pathFull
    while ($true) {
        if (Test-Path -LiteralPath $current) {
            try {
                $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
                if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    Stop-Ut $script:UtExitSecurity "The managed path '$current' is a reparse point; refusing to use it."
                }
            } catch {
                if ($_.Exception.Data.Contains('UtExitCode')) { throw }
                Stop-Ut $script:UtExitSecurity "The managed path '$current' could not be inspected: $($_.Exception.Message)"
            }
        } elseif (-not $AllowMissingLeaf) {
            Stop-Ut $script:UtExitSecurity "The managed path '$current' does not exist."
        }
        $parent = [System.IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrEmpty($parent) -or $parent -ieq $current) { break }
        $current = $parent
        if ($current.Length -le 3 -and $current.EndsWith(':\')) {
            if (Test-Path -LiteralPath $current) {
                try {
                    $volume = Get-Item -LiteralPath $current -Force -ErrorAction Stop
                    if (($volume.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                        Stop-Ut $script:UtExitSecurity "The managed path ancestor '$current' is a reparse point."
                    }
                } catch {
                    if ($_.Exception.Data.Contains('UtExitCode')) { throw }
                    Stop-Ut $script:UtExitSecurity "The managed path ancestor '$current' could not be inspected."
                }
            }
            break
        }
    }
}

function Get-UtCacheRootDirectory {
    $toolRoot = Get-UtRootDirectory
    $root = Join-Path $toolRoot 'cache'
    Assert-UtManagedPath -Path $root -Root $toolRoot -AllowMissingLeaf
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop
    }
    Assert-UtManagedPath -Path $root -Root $toolRoot
    return $root
}

function Get-UtCachePackagesDirectory {
    $root = Get-UtCacheRootDirectory
    $path = Join-Path $root 'packages'
    Assert-UtManagedPath -Path $path -Root $root -AllowMissingLeaf
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop
    }
    Assert-UtManagedPath -Path $path -Root $root
    return $path
}

function Get-UtCacheStatesDirectory {
    $root = Get-UtCacheRootDirectory
    $path = Join-Path $root 'states'
    Assert-UtManagedPath -Path $path -Root $root -AllowMissingLeaf
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop
    }
    Assert-UtManagedPath -Path $path -Root $root
    return $path
}

function Test-UtCacheKey {
    param([Parameter(Mandatory = $true)][string]$Key)
    return ($Key -cmatch '^(x64|arm64)-[0-9]{1,5}(?:\.[0-9]{1,5}){3}-[0-9a-f]{64}-[0-9a-f]{64}$')
}

function Get-UtCachePathForKey {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Package', 'State')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Key
    )
    if (-not (Test-UtCacheKey -Key $Key)) {
        Stop-Ut $script:UtExitSecurity "The cache key '$Key' is invalid."
    }
    if ($Kind -eq 'Package') {
        $root = Get-UtCachePackagesDirectory
        $path = Join-Path $root ($Key + '.msix')
    } else {
        $root = Get-UtCacheStatesDirectory
        $path = Join-Path $root ($Key + '.json')
    }
    Assert-UtManagedPath -Path $path -Root $root -AllowMissingLeaf
    return $path
}

function Get-UtUtf8Sha256 {
    param([Parameter(Mandatory = $true)][string]$Text)
    $sha = $null
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        if ($null -ne $sha) { $sha.Dispose() }
    }
}

function Get-UtSnapshotCanonicalText {
    param([Parameter(Mandatory = $true)]$Metadata)
    $etagKind = [string](Get-UtNodeValue $Metadata 'ETagKind')
    if ([string]::IsNullOrEmpty($etagKind)) {
        $etagKind = if ([bool](Get-UtNodeValue $Metadata 'StrongETag')) { 'Strong' } elseif ([string]::IsNullOrEmpty([string](Get-UtNodeValue $Metadata 'ETag'))) { 'Missing' } else { 'Weak' }
    }
    $etag = [string](Get-UtNodeValue $Metadata 'ETag')
    if ($etagKind -eq 'Missing') { $etag = '<missing>' }
    $fields = @(
        [string](Get-UtNodeValue $Metadata 'Architecture'),
        [string](Get-UtNodeValue $Metadata 'Version'),
        [string]([long](Get-UtNodeValue $Metadata 'ContentLength')),
        $etagKind,
        $etag,
        [string](Get-UtNodeValue $Metadata 'Url'),
        [string](Get-UtNodeValue $Metadata 'FinalUri')
    )
    return (($fields | ForEach-Object { '{0}:{1}' -f ([string]$_).Length, [string]$_ }) -join '|')
}

function Get-UtSnapshotDigest {
    param([Parameter(Mandatory = $true)]$Metadata)
    return Get-UtUtf8Sha256 -Text (Get-UtSnapshotCanonicalText -Metadata $Metadata)
}

function Test-UtSnapshotMatch {
    param(
        [Parameter(Mandatory = $true)]$A,
        [Parameter(Mandatory = $true)]$B
    )
    try {
        $aVersion = ConvertTo-UtVersion -Value ([string](Get-UtNodeValue $A 'Version')) -Code $script:UtExitMetadata -Label 'cache snapshot version'
        $bVersion = ConvertTo-UtVersion -Value ([string](Get-UtNodeValue $B 'Version')) -Code $script:UtExitMetadata -Label 'cache snapshot version'
        if ((Compare-UtVersion -A $aVersion -B $bVersion) -ne 0) { return $false }
        if ([string](Get-UtNodeValue $A 'Architecture') -cne [string](Get-UtNodeValue $B 'Architecture')) { return $false }
        if ([long](Get-UtNodeValue $A 'ContentLength') -ne [long](Get-UtNodeValue $B 'ContentLength')) { return $false }
        if ([string](Get-UtNodeValue $A 'ETag') -cne [string](Get-UtNodeValue $B 'ETag')) { return $false }
        if ([string](Get-UtNodeValue $A 'ETagKind') -cne [string](Get-UtNodeValue $B 'ETagKind')) { return $false }
        if ([string](Get-UtNodeValue $A 'Url') -cne [string](Get-UtNodeValue $B 'Url')) { return $false }
        if ([string](Get-UtNodeValue $A 'FinalUri') -cne [string](Get-UtNodeValue $B 'FinalUri')) { return $false }
        return $true
    } catch { return $false }
}

function New-UtCacheKey {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$Architecture,
        [Parameter(Mandatory = $true)][string]$SHA256
    )
    if ($SHA256 -notmatch '^[0-9a-fA-F]{64}$') { Stop-Ut $script:UtExitSecurity 'The candidate SHA256 is not a 64-character hexadecimal digest.' }
    $version = ConvertTo-UtVersion -Value ([string](Get-UtNodeValue $Metadata 'Version')) -Code $script:UtExitMetadata -Label 'cache version'
    $snapshotDigest = Get-UtSnapshotDigest -Metadata $Metadata
    return ('{0}-{1}-{2}-{3}' -f $Architecture.ToLowerInvariant(), $version.ToString(), $snapshotDigest, $SHA256.ToLowerInvariant())
}

function ConvertTo-UtCacheState {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$Architecture,
        [Parameter(Mandatory = $true)][string]$SHA256
    )
    $etagKind = [string](Get-UtNodeValue $Metadata 'ETagKind')
    if ([string]::IsNullOrEmpty($etagKind)) { $etagKind = if ([bool](Get-UtNodeValue $Metadata 'StrongETag')) { 'Strong' } elseif ([string]::IsNullOrEmpty([string](Get-UtNodeValue $Metadata 'ETag'))) { 'Missing' } else { 'Weak' } }
    return [ordered]@{
        SchemaVersion = [int]$script:UtCacheSchemaVersion
        State         = 'Ready'
        Key           = $Key
        Architecture  = $Architecture
        Version       = [string](Get-UtNodeValue $Metadata 'Version')
        ContentLength = [string][long](Get-UtNodeValue $Metadata 'ContentLength')
        ETag          = if ($null -eq (Get-UtNodeValue $Metadata 'ETag')) { $null } else { [string](Get-UtNodeValue $Metadata 'ETag') }
        ETagKind      = $etagKind
        Url           = [string](Get-UtNodeValue $Metadata 'Url')
        FinalUri      = [string](Get-UtNodeValue $Metadata 'FinalUri')
        SHA256        = $SHA256.ToUpperInvariant()
        PackageFile   = ($Key + '.msix')
        VerifiedAt    = [DateTime]::UtcNow.ToString('o')
    }
}

function ConvertFrom-UtCacheState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$ExpectedKey
    )
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $root = Get-UtCacheRootDirectory
        Assert-UtManagedPath -Path $Path -Root (Get-UtCacheStatesDirectory)
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.Length -gt $script:UtCacheMaxStateBytes -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $null }
        $state = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($Path))
        if ([int](Get-UtNodeValue $state 'SchemaVersion') -ne [int]$script:UtCacheSchemaVersion) { return $null }
        if ([string](Get-UtNodeValue $state 'State') -cne 'Ready') { return $null }
        $key = [string](Get-UtNodeValue $state 'Key')
        if (-not (Test-UtCacheKey -Key $key) -or (-not [string]::IsNullOrEmpty($ExpectedKey) -and $key -cne $ExpectedKey)) { return $null }
        if ([string](Get-UtNodeValue $state 'PackageFile') -cne ($key + '.msix')) { return $null }
        $architecture = [string](Get-UtNodeValue $state 'Architecture')
        if ($architecture -notin @('x64', 'arm64')) { return $null }
        $version = ConvertTo-UtVersion -Value ([string](Get-UtNodeValue $state 'Version')) -Code $script:UtExitMetadata -Label 'cache version'
        $lengthText = [string](Get-UtNodeValue $state 'ContentLength')
        if ($lengthText -notmatch '^[0-9]+$') { return $null }
        $length = [long]$lengthText
        if ($length -le 0) { return $null }
        $etagKind = [string](Get-UtNodeValue $state 'ETagKind')
        if ($etagKind -notin @('Strong', 'Weak', 'Missing')) { return $null }
        $etagValue = Get-UtNodeValue $state 'ETag'
        if ($etagKind -eq 'Missing') {
            if ($null -ne $etagValue -and -not [string]::IsNullOrEmpty([string]$etagValue)) { return $null }
            $etag = $null
        } else {
            if ($null -eq $etagValue -or [string]::IsNullOrEmpty([string]$etagValue)) { return $null }
            $etag = [string]$etagValue
        }
        $url = [string](Get-UtNodeValue $state 'Url')
        $finalUri = [string](Get-UtNodeValue $state 'FinalUri')
        if ([string]::IsNullOrEmpty($url) -or [string]::IsNullOrEmpty($finalUri)) { return $null }
        $sha = [string](Get-UtNodeValue $state 'SHA256')
        if ($sha -notmatch '^[0-9a-fA-F]{64}$') { return $null }
        $verifiedAt = $null
        try {
            $verifiedAt = [DateTime]::Parse([string](Get-UtNodeValue $state 'VerifiedAt'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        } catch { return $null }
        $metadata = [pscustomobject]@{
            Version       = $version
            ContentLength = $length
            ETag          = $etag
            ETagKind      = $etagKind
            StrongETag    = ($etagKind -eq 'Strong')
            Url           = $url
            FinalUri      = $finalUri
            Architecture  = $architecture
        }
        if ((New-UtCacheKey -Metadata $metadata -Architecture $architecture -SHA256 $sha) -cne $key) { return $null }
        return [pscustomobject]@{ Key = $key; Metadata = $metadata; SHA256 = $sha.ToUpperInvariant(); VerifiedAt = $verifiedAt }
    } catch {
        return $null
    }
}

function Move-UtAtomicFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Root
    )
    Assert-UtManagedPath -Path $Source -Root $Root
    Assert-UtManagedPath -Path $Destination -Root $Root -AllowMissingLeaf
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $backup = $Destination + '.bak'
        Assert-UtManagedPath -Path $backup -Root $Root -AllowMissingLeaf
        try {
            if (Test-Path -LiteralPath $backup -PathType Leaf) { Remove-Item -LiteralPath $backup -Force -ErrorAction Stop }
            [System.IO.File]::Replace($Source, $Destination, $backup, $true)
        } catch { Stop-Ut $script:UtExitDownload "Atomic replacement of '$Destination' failed: $($_.Exception.Message)" }
        finally { if (Test-Path -LiteralPath $backup -PathType Leaf) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue } }
    } else {
        try { [System.IO.File]::Move($Source, $Destination) }
        catch { Stop-Ut $script:UtExitDownload "Atomic publication of '$Destination' failed: $($_.Exception.Message)" }
    }
}

function Write-UtCacheState {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$Architecture,
        [Parameter(Mandatory = $true)][string]$SHA256
    )
    $states = Get-UtCacheStatesDirectory
    $target = Get-UtCachePathForKey -Kind State -Key $Key
    $temp = Join-Path $states ('.' + $Key + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    Assert-UtManagedPath -Path $temp -Root $states -AllowMissingLeaf
    $json = (ConvertTo-Json -InputObject (ConvertTo-UtCacheState -Key $Key -Metadata $Metadata -Architecture $Architecture -SHA256 $SHA256) -Depth 5)
    try {
        [System.IO.File]::WriteAllText($temp, $json, (New-Object System.Text.UTF8Encoding($false)))
        Move-UtAtomicFile -Source $temp -Destination $target -Root $states
    } finally {
        if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Get-UtCacheRecord {
    param([Parameter(Mandatory = $true)][string]$Key)
    $statePath = Get-UtCachePathForKey -Kind State -Key $Key
    return ConvertFrom-UtCacheState -Path $statePath -ExpectedKey $Key
}

function Get-UtReusableCacheCandidate {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$Architecture,
        [Parameter(Mandatory = $true)][version]$WindowsVersion
    )
    $states = Get-UtCacheStatesDirectory
    $records = @(Get-ChildItem -LiteralPath $states -Filter '*.json' -File -Force -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
    foreach ($stateFile in $records) {
        $record = ConvertFrom-UtCacheState -Path $stateFile.FullName
        if ($null -eq $record) { continue }
        if ($record.Metadata.Architecture -cne $Architecture -or -not (Test-UtSnapshotMatch -A $record.Metadata -B $Metadata)) { continue }
        $package = Get-UtCachePathForKey -Kind Package -Key $record.Key
        if (-not (Test-Path -LiteralPath $package -PathType Leaf)) { continue }
        try {
            $validated = Get-UtValidatedCandidate -Path $package -Metadata $Metadata -Architecture $Architecture -WindowsVersion $WindowsVersion
            if ($validated.SHA256 -cne $record.SHA256) { continue }
            if ((New-UtCacheKey -Metadata $Metadata -Architecture $Architecture -SHA256 $validated.SHA256) -cne $record.Key) { continue }
            return [pscustomobject]@{ Path = $package; Key = $record.Key; Metadata = $Metadata; SHA256 = $validated.SHA256 }
        } catch { continue }
    }

    # A package rename can succeed immediately before the Ready state rename.
    # Recover only a directly managed file whose strict key prefix matches this
    # exact snapshot.  The filename is merely a search hint: the full validator
    # and freshly computed SHA256 remain mandatory before publishing state.
    $packages = Get-UtCachePackagesDirectory
    $prefix = '{0}-{1}-{2}-' -f $Architecture.ToLowerInvariant(), $Metadata.Version.ToString(), (Get-UtSnapshotDigest -Metadata $Metadata)
    foreach ($packageFile in @(Get-ChildItem -LiteralPath $packages -Filter '*.msix' -File -Force -ErrorAction SilentlyContinue)) {
        $key = [System.IO.Path]::GetFileNameWithoutExtension($packageFile.Name)
        if (-not (Test-UtCacheKey -Key $key) -or -not $key.StartsWith($prefix, [System.StringComparison]::Ordinal)) { continue }
        try {
            $validated = Get-UtValidatedCandidate -Path $packageFile.FullName -Metadata $Metadata -Architecture $Architecture -WindowsVersion $WindowsVersion
            $derivedKey = New-UtCacheKey -Metadata $Metadata -Architecture $Architecture -SHA256 $validated.SHA256
            if ($derivedKey -cne $key) { continue }
            Write-UtCacheState -Key $key -Metadata $Metadata -Architecture $Architecture -SHA256 $validated.SHA256
            return [pscustomobject]@{ Path = $packageFile.FullName; Key = $key; Metadata = $Metadata; SHA256 = $validated.SHA256 }
        } catch { continue }
    }
    return $null
}

function Publish-UtPreparedCandidate {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$Architecture,
        [Parameter(Mandatory = $true)][string]$SHA256
    )
    $key = New-UtCacheKey -Metadata $Metadata -Architecture $Architecture -SHA256 $SHA256
    $packages = Get-UtCachePackagesDirectory
    $packagePath = Get-UtCachePathForKey -Kind Package -Key $key
    Move-UtAtomicFile -Source ([System.IO.Path]::GetFullPath($Path)) -Destination $packagePath -Root (Get-UtRootDirectory)
    try {
        Write-UtCacheState -Key $key -Metadata $Metadata -Architecture $Architecture -SHA256 $SHA256
    } catch {
        # The complete package is intentionally retained.  A later prepare run
        # can recover this orphan by rerunning the full validator.
        throw
    }
    return [pscustomobject]@{ Path = $packagePath; Key = $key; Metadata = $Metadata; SHA256 = $SHA256 }
}

function Remove-UtCacheOverflow {
    param([string]$KeepKey)
    try {
        $packages = Get-UtCachePackagesDirectory
        $states = Get-UtCacheStatesDirectory
        $limit = [Math]::Max(1, [int]$script:UtMaxManagedPackages)
        if (-not [string]::IsNullOrEmpty($KeepKey) -and -not (Test-UtCacheKey -Key $KeepKey)) { $KeepKey = $null }

        # The cache index is advisory.  Build the bounded set from direct,
        # regular files whose names are strict cache keys, then use the Ready
        # timestamp when it is valid and the package/index last-write time for
        # orphan or corrupt records.  Unknown names and reparse points are
        # never candidates for deletion.
        $itemsByKey = @{}
        foreach ($packageFile in @(Get-ChildItem -LiteralPath $packages -Filter '*.msix' -File -Force -ErrorAction SilentlyContinue)) {
            if (($packageFile.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $key = [System.IO.Path]::GetFileNameWithoutExtension($packageFile.Name)
            if (-not (Test-UtCacheKey -Key $key)) { continue }
            $statePath = Get-UtCachePathForKey -Kind State -Key $key
            $record = ConvertFrom-UtCacheState -Path $statePath -ExpectedKey $key
            $stamp = $packageFile.LastWriteTimeUtc
            if ($null -ne $record) { $stamp = $record.VerifiedAt.ToUniversalTime() }
            $itemsByKey[$key] = [pscustomobject]@{ Key = $key; PackagePath = $packageFile.FullName; StatePath = $statePath; Stamp = $stamp }
        }

        # State-only indexes are retained for the normal missing-package
        # recovery path.  They never consume one of the three package slots;
        # when a package is pruned, its own strict-key index is pruned with it.
        $items = @($itemsByKey.Values | Sort-Object Stamp -Descending)
        $keep = @($items | Select-Object -First $limit)
        if (-not [string]::IsNullOrEmpty($KeepKey) -and @($keep | Where-Object { $_.Key -ceq $KeepKey }).Count -eq 0) {
            # The active package survives even when its timestamp is old.  A
            # bounded set replaces its oldest non-current entry rather than
            # appending a fourth package.
            $current = @($items | Where-Object { $_.Key -ceq $KeepKey } | Select-Object -First 1)
            if ($current.Count -gt 0) {
                $replace = @($keep | Where-Object { $_.Key -cne $KeepKey } | Sort-Object Stamp | Select-Object -First 1)
                if ($replace.Count -gt 0) { $keep = @($keep | Where-Object { $_.Key -cne $replace[0].Key }) }
                if (@($keep | Where-Object { $_.Key -ceq $KeepKey }).Count -eq 0) { $keep = @($keep + $current[0]) }
            }
        }
        $keepKeys = @{}
        foreach ($item in $keep) { $keepKeys[$item.Key] = $true }
        foreach ($item in $items) {
            if ($keepKeys.ContainsKey($item.Key)) { continue }
            foreach ($path in @($item.PackagePath, $item.StatePath)) {
                if ([string]::IsNullOrEmpty($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
                try {
                    $file = Get-Item -LiteralPath $path -Force -ErrorAction Stop
                    if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
                } catch { }
            }
        }
    } catch { }
}

function Remove-UtCacheRecord {
    param([Parameter(Mandatory = $true)][string]$Key)
    try {
        $statePath = Get-UtCachePathForKey -Kind State -Key $Key
        $packagePath = Get-UtCachePathForKey -Kind Package -Key $Key
        Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $packagePath -Force -ErrorAction SilentlyContinue
    } catch { }
}

function Get-UtPreparedCandidate {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$Architecture,
        [Parameter(Mandatory = $true)][version]$WindowsVersion,
        [int]$Connections = 8,
        [switch]$Background
    )
    $reused = Get-UtReusableCacheCandidate -Metadata $Metadata -Architecture $Architecture -WindowsVersion $WindowsVersion
    if ($null -ne $reused) {
        Remove-UtCacheOverflow -KeepKey $reused.Key
        return $reused
    }

    $runDirectory = $null
    try {
        $runDirectory = New-UtRunDirectory
        $receiver = Get-Command Receive-UtParallelCandidate -CommandType Function -ErrorAction SilentlyContinue
        if ($null -ne $receiver) {
            $candidate = Receive-UtParallelCandidate -Metadata $Metadata -RunDirectory $runDirectory -Architecture $Architecture -Connections $Connections -Background:$Background
        } else {
            if ($Connections -ne 1) {
                Stop-Ut $script:UtExitEnvironment 'The segmented downloader module is unavailable; use -Connections 1 for the serial backend.'
            }
            $candidate = Receive-UtCandidate -Metadata $Metadata -RunDirectory $runDirectory -Architecture $Architecture -Background:$Background
        }
        $validated = Get-UtValidatedCandidate -Path ([string]$candidate) -Metadata $Metadata -Architecture $Architecture -WindowsVersion $WindowsVersion
        $published = Publish-UtPreparedCandidate -Path $validated.Path -Metadata $Metadata -Architecture $Architecture -SHA256 $validated.SHA256
        Remove-UtCacheOverflow -KeepKey $published.Key
        return $published
    } finally {
        if ($null -ne $runDirectory) { Remove-UtRunDirectoryIfEmpty -RunDirectory $runDirectory }
    }
}

function New-UtInstallResult {
    param([int]$Code, [string]$Status, [string]$Message)
    return [pscustomobject]@{ Code = $Code; Status = $Status; Message = $Message }
}

function Invoke-UtConfirmedInstall {
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedKey,
        [Parameter(Mandatory = $true)][version]$ExpectedVersion
    )
    $lock = $null
    $candidate = $null
    try {
        if (-not (Test-UtCacheKey -Key $ExpectedKey)) {
            return New-UtInstallResult -Code $script:UtExitSecurity -Status 'Failed' -Message 'The prepared candidate key is invalid.'
        }
        try { $lock = Enter-UtLock } catch {
            return New-UtInstallResult -Code $script:UtExitLock -Status 'Failed' -Message ("Another updater instance holds the lock: {0}" -f $_.Exception.Message)
        }
        $installed = $null
        try { $installed = Get-UtInstalledPackage } catch {
            return New-UtInstallResult -Code $script:UtExitInstalled -Status 'Failed' -Message $_.Exception.Message
        }
        $architecture = Get-UtNativeArchitecture
        $windowsVersion = Get-UtWindowsVersion
        $url = "{0}/ChatGPT-{1}.msix" -f $script:UtBaseUrl, $architecture
        $head = $null
        try { $head = Invoke-UtHeadRequest -Uri $url } catch {
            return New-UtInstallResult -Code (Get-UtErrorCode -ErrorRecord $_ -Default $script:UtExitNetwork) -Status 'Failed' -Message $_.Exception.Message
        }
        $metadata = $null
        try { $metadata = Get-UtRemoteMetadata -HeadResult $head -Architecture $architecture -RequestedUri $url } catch {
            return New-UtInstallResult -Code (Get-UtErrorCode -ErrorRecord $_ -Default $script:UtExitMetadata) -Status 'Failed' -Message $_.Exception.Message
        }
        if ($null -ne $installed -and (Compare-UtVersion -A $installed.Version -B $ExpectedVersion) -ge 0) {
            return New-UtInstallResult -Code $script:UtExitOk -Status 'AlreadyCurrent' -Message ("Installed version {0} is already current or newer." -f $installed.Version)
        }
        if ((Compare-UtVersion -A $metadata.Version -B $ExpectedVersion) -ne 0) {
            return New-UtInstallResult -Code $script:UtExitDownload -Status 'CandidateChanged' -Message ("The CDN candidate changed from {0} to {1}; confirmation was not reused." -f $ExpectedVersion, $metadata.Version)
        }
        $record = Get-UtCacheRecord -Key $ExpectedKey
        if ($null -eq $record -or $record.Metadata.Architecture -cne $architecture -or -not (Test-UtSnapshotMatch -A $record.Metadata -B $metadata)) {
            return New-UtInstallResult -Code $script:UtExitDownload -Status 'CandidateChanged' -Message 'The prepared candidate no longer matches the current CDN snapshot.'
        }
        $packagePath = Get-UtCachePathForKey -Kind Package -Key $ExpectedKey
        if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
            return New-UtInstallResult -Code $script:UtExitDownload -Status 'Failed' -Message 'The prepared package is missing from the managed cache.'
        }
        try {
            $candidate = Open-UtValidatedCandidate -Path $packagePath -Metadata $metadata -Architecture $architecture -WindowsVersion $windowsVersion -KeepLease
            if ($candidate.SHA256 -cne $record.SHA256 -or (New-UtCacheKey -Metadata $metadata -Architecture $architecture -SHA256 $candidate.SHA256) -cne $ExpectedKey) {
                return New-UtInstallResult -Code $script:UtExitSecurity -Status 'Failed' -Message 'The prepared package failed its cache identity or hash check.'
            }
            $before = $null
            try { $before = Get-UtInstalledPackage } catch {
                return New-UtInstallResult -Code $script:UtExitDeployment -Status 'Failed' -Message ("Re-querying the installed package before deployment failed: {0}" -f $_.Exception.Message)
            }
            if ($null -ne $before -and (Compare-UtVersion -A $before.Version -B $candidate.Identity.Version) -ge 0) {
                return New-UtInstallResult -Code $script:UtExitOk -Status 'AlreadyCurrent' -Message ("Installed version {0} is already current or newer." -f $before.Version)
            }
            try { Install-UtPackage -Path $candidate.Path -DeferRegistration } catch {
                Write-UtDeploymentFailure -ErrorRecord $_
                return New-UtInstallResult -Code $script:UtExitDeployment -Status 'Failed' -Message ("Add-AppxPackage failed: {0}" -f $_.Exception.Message)
            }
            $after = $null
            $verifyError = $null
            try { $after = Get-UtInstalledPackage } catch { $verifyError = $_.Exception.Message }
            if ($null -ne $verifyError) {
                return New-UtInstallResult -Code $script:UtExitVerify -Status 'Failed' -Message "Installation is NOT confirmed: the post-install package query failed: $verifyError"
            }
            if ($null -ne $after -and (Compare-UtVersion -A $after.Version -B $candidate.Identity.Version) -ge 0) {
                if ($null -ne $candidate.Lease) {
                    $candidate.Lease.Dispose()
                    $candidate.Lease = $null
                }
                Remove-UtCacheRecord -Key $ExpectedKey
                return New-UtInstallResult -Code $script:UtExitOk -Status 'Installed' -Message ("Update successful: {0} (Status {1})." -f $after.Version, $after.Status)
            }
            # Add-AppxPackage succeeded but the old package is still registered.
            # That is the expected result when Windows honored the deferred
            # registration request because an app or packaged service was in use.
            # Keep the verified cache entry until a later worker run observes the
            # new registered version; never report this as an installed update.
            if ($null -ne $after -and $null -ne $before -and (Compare-UtVersion -A $after.Version -B $before.Version) -eq 0) {
                return New-UtInstallResult -Code $script:UtExitDeferred -Status 'Deferred' -Message ("Update staged with deferred registration: the registered version is still {0}. Windows should complete registration on the next ChatGPT launch. If it does not, restart Windows and run the updater again. The verified package remains in the cache." -f $after.Version)
            }
            return New-UtInstallResult -Code $script:UtExitVerify -Status 'Failed' -Message 'Installation is NOT confirmed: the registered package is missing or lower than the candidate.'
        } catch {
            return New-UtInstallResult -Code (Get-UtErrorCode -ErrorRecord $_ -Default $script:UtExitSecurity) -Status 'Failed' -Message $_.Exception.Message
        }
    } finally {
        if ($null -ne $candidate -and $null -ne $candidate.Lease) { $candidate.Lease.Dispose() }
        if ($null -ne $lock) { $lock.Dispose() }
    }
}
