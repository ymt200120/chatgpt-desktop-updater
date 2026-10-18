#requires -Version 5.1
<#
    ChatGPT Desktop updater (current user, official OpenAI MSIX only).

    Design credit / attribution:
      Some structural ideas (architecture detection, a read lease held across
      verification and deployment, a pre-deployment re-query of the installed
      package, and HRESULT-specific deployment messaging) are adapted from
      pavelbe/codex-windows-store-helper, commit bea80fb446e7b7f76f59dab33e6450519127f38d,
      scripts/Install-CodexDirect.ps1, which is licensed under the MIT License
      (Copyright (c) 2026 Pavel). This file is an independent implementation and
      is not a copy of that project. Unlike the reference, this updater always
      compares the installed version with the CDN metadata before downloading.

    Trust model:
      Official HTTPS source (persistent.oaistatic.com), a Valid Windows
      Authenticode signature, pinned package identity (Name, Publisher,
      ProcessorArchitecture) and Windows AppX deployment validation. This cannot
      defend against an attacker who already controls the current user or the
      Windows trust store.

    This script only ever touches, for the current user, a new DownloadOnly
    candidate or an in-place Add-AppxPackage upgrade. It never uninstalls,
    never removes user data, never modifies system policy, and never elevates.
#>
[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [switch]$DownloadOnly,
    [switch]$OpenApp,
    [int]$Connections = 8
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Pinned expectations (verified against the installed package and candidate).
# ---------------------------------------------------------------------------
$script:UtPackageName       = 'OpenAI.Codex'
$script:UtPackageFamily     = 'OpenAI.Codex_2p2nqsd0c76g0'
$script:UtManifestPublisher = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'
$script:UtAllowedHost       = 'persistent.oaistatic.com'
$script:UtBaseUrl           = 'https://persistent.oaistatic.com/codex-app-prod'
$script:UtFoundationNs      = 'http://schemas.microsoft.com/appx/manifest/foundation/windows10'
$script:UtUap6Ns           = 'http://schemas.microsoft.com/appx/manifest/uap/windows10/6'
$script:UtAppAumid          = 'shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App'
$script:UtMaxManifestBytes  = 1048576
$script:UtHeadConnectTimeout = 20
$script:UtHeadMaxTime        = 60
$script:UtDownloadMaxTime    = 3600
$script:UtMaxResponseHeaderBytes = 262144
$script:UtCacheSchemaVersion = 1
$script:UtCacheMaxStateBytes = 65536
$script:UtMaxManagedPackages = 3

# Updater self-update identity.  The manifest and archive are pinned to the
# public repository; the archive and every staged file are SHA-256 checked.
# This release does not embed a separate signing key, so the trust root is the
# pinned GitHub repository account over HTTPS and the user's explicit -Apply.
$script:UtUpdaterProduct = 'chatgpt-desktop-updater'
$script:UtUpdaterRepository = 'ymt200120/chatgpt-desktop-updater-public'
$script:UtUpdaterManifestUrl = 'https://github.com/ymt200120/chatgpt-desktop-updater-public/releases/latest/download/updater-release.json'
$script:UtUpdaterReleasePrefix = 'https://github.com/ymt200120/chatgpt-desktop-updater-public/releases/download/'
$script:UtUpdaterVersionFile = 'VERSION'
$script:UtUpdaterFiles = @(
    'update-chatgpt.ps1',
    'update-chatgpt.cmd',
    'background-common.ps1',
    'segmented-download.ps1',
    'managed-cache.ps1',
    'background-worker.ps1',
    'background-worker.cmd',
    'confirm-install.ps1',
    'manage-background.ps1',
    'manage-background.cmd',
    'self-update.ps1',
    'self-update-helper.ps1',
    'update-updater.cmd',
    'VERSION'
)
$script:UtSelfUpdateMaxManifestBytes = 65536
$script:UtSelfUpdateMaxArchiveBytes = 8388608

# Exit codes.
$script:UtExitOk            = 0
$script:UtExitInternal      = 1
$script:UtExitUsage         = 2
$script:UtExitEnvironment   = 3
$script:UtExitNetwork       = 4
$script:UtExitMetadata      = 5
$script:UtExitDownload      = 6
$script:UtExitSecurity      = 7
$script:UtExitCompatibility = 8
$script:UtExitDependency    = 9
$script:UtExitDeployment    = 10
$script:UtExitVerify        = 11
$script:UtExitLock          = 12
$script:UtExitInstalled     = 13
$script:UtExitDeferred      = 14

# ---------------------------------------------------------------------------
# Errors / output helpers.
# ---------------------------------------------------------------------------
function New-UtFailure {
    param(
        [Parameter(Mandatory = $true)][int]$Code,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $exception = New-Object System.Exception($Message)
    $exception.Data['UtExitCode'] = $Code
    return $exception
}

function Stop-Ut {
    param(
        [Parameter(Mandatory = $true)][int]$Code,
        [Parameter(Mandatory = $true)][string]$Message
    )
    throw (New-UtFailure -Code $Code -Message $Message)
}

function Get-UtErrorCode {
    param(
        $ErrorRecord,
        [int]$Default = 1
    )
    $exception = $null
    if ($null -ne $ErrorRecord) { $exception = $ErrorRecord.Exception }
    while ($null -ne $exception) {
        if ($null -ne $exception.Data -and $exception.Data.Contains('UtExitCode')) {
            return [int]$exception.Data['UtExitCode']
        }
        $exception = $exception.InnerException
    }
    return $Default
}

function Write-UtLine {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message)
    Write-Host $Message
}

function Write-UtError {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host $Message -ForegroundColor Red
}

function Write-UtBanner {
    param([string]$Architecture, [version]$WindowsVersion)
    Write-Host 'ChatGPT Desktop updater'
    Write-Host ("Windows:    {0} ({1})" -f $WindowsVersion, $Architecture)
}

function Get-UtRegistryProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

# ---------------------------------------------------------------------------
# Version handling.
# ---------------------------------------------------------------------------
function ConvertTo-UtVersion {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [int]$Code = 5,
        [string]$Label = 'version'
    )
    if ([string]::IsNullOrWhiteSpace($Value)) { Stop-Ut $Code "Missing $Label." }
    $text = $Value.Trim()
    if ($text -notmatch '^[0-9]{1,5}(\.[0-9]{1,5}){3}$') {
        Stop-Ut $Code "Invalid $Label '$Value' (a four-part numeric MSIX version is required)."
    }
    $parts = @($text.Split('.') | ForEach-Object { [int]$_ })
    foreach ($part in $parts) {
        if ($part -lt 0 -or $part -gt 65535) {
            Stop-Ut $Code "$Label '$Value' has a component outside the MSIX range 0-65535."
        }
    }
    return [version]::new($parts[0], $parts[1], $parts[2], $parts[3])
}

function Compare-UtVersion {
    param(
        [Parameter(Mandatory = $true)][version]$A,
        [Parameter(Mandatory = $true)][version]$B
    )
    return $A.CompareTo($B)
}

# ---------------------------------------------------------------------------
# Operating system facts (read-only).
# ---------------------------------------------------------------------------
function Get-UtNativeArchitecture {
    [CmdletBinding()]
    param()
    $raw = $null
    try { $raw = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture } catch { $raw = $null }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $raw = $env:PROCESSOR_ARCHITEW6432
        if ([string]::IsNullOrWhiteSpace($raw)) { $raw = $env:PROCESSOR_ARCHITECTURE }
    }
    switch -Regex ($raw) {
        '^(X64|Amd64|AMD64)$' { return 'x64' }
        '^(Arm64|ARM64)$'     { return 'arm64' }
        default { Stop-Ut $script:UtExitEnvironment "Unsupported or ambiguous Windows architecture '$raw'. Only x64 or Arm64 is supported." }
    }
}

function Get-UtWindowsVersion {
    [CmdletBinding()]
    param()
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $item = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
    $majorRaw = Get-UtRegistryProperty $item 'CurrentMajorVersionNumber'
    $minorRaw = Get-UtRegistryProperty $item 'CurrentMinorVersionNumber'
    $buildRaw = Get-UtRegistryProperty $item 'CurrentBuildNumber'
    $revisionRaw = Get-UtRegistryProperty $item 'UBR'
    if ($null -eq $buildRaw) { Stop-Ut $script:UtExitEnvironment 'Cannot read the Windows build number from the registry.' }
    try {
        $major = if ($null -ne $majorRaw) { [int]$majorRaw } else { 10 }
        $minor = if ($null -ne $minorRaw) { [int]$minorRaw } else { 0 }
        $build = [int]([string]$buildRaw)
        $revision = if ($null -ne $revisionRaw) { [int]$revisionRaw } else { 0 }
    } catch {
        Stop-Ut $script:UtExitEnvironment 'Cannot parse the Windows version from the registry.'
    }
    if ($major -lt 0 -or $minor -lt 0 -or $build -lt 0 -or $revision -lt 0) {
        Stop-Ut $script:UtExitEnvironment 'Windows version contains a negative component.'
    }
    return [version]::new($major, $minor, $build, $revision)
}

# ---------------------------------------------------------------------------
# AppX boundary functions (overridden only inside the offline tests).
# ---------------------------------------------------------------------------
function Get-UtRawAppxPackage {
    param([Parameter(Mandatory = $true)][string]$Name)
    return @(Get-AppxPackage -Name $Name -ErrorAction Stop)
}

function Get-UtInstalledPackage {
    [CmdletBinding()]
    param()
    $raw = $null
    try { $raw = @(Get-UtRawAppxPackage -Name $script:UtPackageName) } catch {
        Stop-Ut $script:UtExitInstalled "Failed to query the installed '$($script:UtPackageName)' package: $($_.Exception.Message)"
    }
    if ($raw.Count -gt 1) {
        Stop-Ut $script:UtExitInstalled "Multiple packages named '$($script:UtPackageName)' were found for the current user; manual inspection is required before making changes."
    }
    if ($raw.Count -eq 0) { return $null }
    $package = $raw[0]
    if ($null -eq $package) { return $null }
    $name = [string]$package.Name
    $family = [string]$package.PackageFamilyName
    if ($name -cne $script:UtPackageName) {
        Stop-Ut $script:UtExitInstalled "Installed package Name '$name' is not '$($script:UtPackageName)'."
    }
    if ($family -cne $script:UtPackageFamily) {
        Stop-Ut $script:UtExitInstalled "Installed package family '$family' does not match the expected family '$($script:UtPackageFamily)'. Stopping for manual inspection."
    }
    $version = ConvertTo-UtVersion -Value ([string]$package.Version) -Code $script:UtExitInstalled -Label 'installed package version'
    $status = [string]$package.Status
    if ($status -ne 'Ok') {
        Stop-Ut $script:UtExitInstalled "Installed package Status is '$status', not Ok. Stopping without attempting to repair it."
    }
    return [pscustomobject]@{
        Name              = $name
        PackageFamilyName = $family
        Version           = $version
        Architecture      = [string]$package.Architecture
        Status            = $status
        PackageFullName   = [string]$package.PackageFullName
    }
}

function Install-UtPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$DeferRegistration
    )
    $parameters = @{ Path = $Path; ErrorAction = 'Stop' }
    # A packaged Windows service can keep the old package active even when no
    # ChatGPT window is open.  Windows can stage the update now and register it
    # when the package is next launched.  This is the non-destructive path: it
    # neither terminates processes nor stops services.  Older systems without
    # the parameter fall back to the normal registration attempt.
    if ($DeferRegistration) {
        $command = Get-Command Add-AppxPackage -ErrorAction Stop
        if ($command.Parameters.ContainsKey('DeferRegistrationWhenPackagesAreInUse')) {
            $parameters['DeferRegistrationWhenPackagesAreInUse'] = $true
        }
    }
    Add-AppxPackage @parameters
}

function Start-UtApp {
    Start-Process -FilePath $script:UtAppAumid -ErrorAction Stop
}

function Get-UtAuthenticodeSignature {
    param([Parameter(Mandatory = $true)][string]$Path)
    return Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
}

# ---------------------------------------------------------------------------
# Network boundary functions.
# ---------------------------------------------------------------------------
function Get-UtCurlPath {
    $candidates = @(
        (Join-Path $env:SystemRoot 'System32\curl.exe'),
        (Join-Path $env:SystemRoot 'Sysnative\curl.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    Stop-Ut $script:UtExitEnvironment 'Trusted Windows curl.exe was not found.'
}

function Read-UtRawHeaderBlocks {
    param([Parameter(Mandatory = $true)][string]$Path)
    $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop)
    $blocks = New-Object System.Collections.ArrayList
    $current = New-Object System.Collections.ArrayList
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($current.Count -gt 0) { [void]$blocks.Add(@($current)); $current.Clear() }
        } else {
            [void]$current.Add([string]$line)
        }
    }
    if ($current.Count -gt 0) { [void]$blocks.Add(@($current)) }
    if ($blocks.Count -eq 0) { Stop-Ut $script:UtExitMetadata 'The HEAD response contained no HTTP header block.' }
    return ,$blocks
}

function ConvertFrom-UtFinalHeaderBlock {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-Ut $script:UtExitMetadata "The response header file '$Path' is missing."
    }
    try {
        $headerItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (($headerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-Ut $script:UtExitMetadata 'The response header file is a reparse point.'
        }
        if ($headerItem.Length -gt $script:UtMaxResponseHeaderBytes) {
            Stop-Ut $script:UtExitMetadata 'The response headers exceeded the bounded size limit.'
        }
    } catch {
        if ((Get-UtErrorCode -ErrorRecord $_ -Default -1) -eq $script:UtExitMetadata) { throw }
        Stop-Ut $script:UtExitMetadata ("The response header file could not be inspected: {0}" -f $_.Exception.Message)
    }
    $blocks = Read-UtRawHeaderBlocks -Path $Path
    $last = $blocks[$blocks.Count - 1]
    $status = $null
    $headers = @{}
    foreach ($line in $last) {
        if ($null -eq $status) {
            if ($line -match '^HTTP/[0-9](?:\.[0-9])?\s+([0-9]{3})') {
                $status = [int]$Matches[1]
                continue
            }
            Stop-Ut $script:UtExitMetadata "Malformed HTTP status line in the HEAD response: '$line'."
        }
        $separator = $line.IndexOf(':')
        if ($separator -lt 1) { continue }
        $headerName = $line.Substring(0, $separator).Trim().ToLowerInvariant()
        if ([string]::IsNullOrEmpty($headerName)) { continue }
        $headerValue = $line.Substring($separator + 1).Trim()
        if (-not $headers.ContainsKey($headerName)) { $headers[$headerName] = New-Object System.Collections.ArrayList }
        [void]$headers[$headerName].Add($headerValue)
    }
    if ($null -eq $status) { Stop-Ut $script:UtExitMetadata 'The HEAD response contained no HTTP status line.' }
    return [pscustomobject]@{ StatusCode = $status; Headers = $headers }
}

function ConvertFrom-UtDownloadHeaderBlock {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            Stop-Ut $script:UtExitDownload "curl did not produce a response header file '$Path'."
        }
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-Ut $script:UtExitDownload 'The download response header file is a reparse point.'
        }
        if ($item.Length -gt $script:UtMaxResponseHeaderBytes) {
            Stop-Ut $script:UtExitDownload 'The download response headers exceeded the bounded size limit.'
        }
        return (ConvertFrom-UtFinalHeaderBlock -Path $Path)
    } catch {
        if ((Get-UtErrorCode -ErrorRecord $_ -Default -1) -eq $script:UtExitDownload) { throw }
        Stop-Ut $script:UtExitDownload ("The download response headers were invalid: {0}" -f $_.Exception.Message)
    }
}

function Get-UtSingleHeader {
    param(
        [Parameter(Mandatory = $true)]$Headers,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$Required
    )
    $key = $Name.ToLowerInvariant()
    if (-not $Headers.ContainsKey($key)) {
        if ($Required) { Stop-Ut $script:UtExitMetadata "Required response header '$Name' is missing." }
        return $null
    }
    $values = @($Headers[$key])
    if ($values.Count -ne 1) {
        Stop-Ut $script:UtExitMetadata "Response header '$Name' is missing, empty or duplicated; refusing to guess."
    }
    $value = [string]$values[0]
    if ([string]::IsNullOrWhiteSpace($value)) {
        if ($Required) { Stop-Ut $script:UtExitMetadata "Required response header '$Name' is empty." }
        return $null
    }
    return $value
}

function ConvertFrom-UtWriteOut {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$RequestedUri,
        [int]$Code = 4
    )
    $codeMatch = [regex]::Match($Text, 'HTTPCODE=([0-9]{3})')
    if (-not $codeMatch.Success) {
        Stop-Ut $Code "curl did not report an HTTP status code for '$RequestedUri'."
    }
    $urlMatch = [regex]::Match($Text, 'FINALURL=([^\r\n]+)')
    if (-not $urlMatch.Success) {
        Stop-Ut $Code "curl did not report a final URL for '$RequestedUri'; the source cannot be confirmed."
    }
    $finalUrl = $urlMatch.Groups[1].Value.Trim()
    $finalUri = Assert-UtOfficialUri -RequestedUri $RequestedUri -ActualUri $finalUrl -Code $Code
    return [pscustomobject]@{ HttpCode = [int]$codeMatch.Groups[1].Value; FinalUrl = $finalUri.AbsoluteUri }
}

function New-UtHeadCurlArguments {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$HeaderFile
    )
    # Deliberately no --location: redirects are never followed. A 3xx response
    # is rejected later by the explicit HTTP 200 requirement.
    return [string[]]@(
        '--disable', '--silent', '--show-error', '--head',
        '--proto', '=https', '--proto-redir', '=https',
        '--connect-timeout', [string]$script:UtHeadConnectTimeout,
        '--max-time', [string]$script:UtHeadMaxTime,
        '--dump-header', $HeaderFile,
        '--output', 'NUL',
        '--write-out', "HTTPCODE=%{http_code}`nFINALURL=%{url_effective}",
        '--url', $Uri
    )
}

function Assert-UtOfficialUri {
    param(
        [Parameter(Mandatory = $true)][string]$RequestedUri,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ActualUri,
        [int]$Code = 4
    )
    $requested = $null
    $actual = $null
    try { $requested = [System.Uri]$RequestedUri } catch { $requested = $null }
    try { $actual = [System.Uri]$ActualUri } catch { $actual = $null }
    if ($null -eq $requested -or $null -eq $actual) {
        Stop-Ut $Code "The source URL could not be parsed: '$ActualUri'."
    }
    foreach ($uri in @($requested, $actual)) {
        if ($uri.Scheme -ine 'https' -or $uri.Host -ine $script:UtAllowedHost) {
            Stop-Ut $Code "The source URL '$($uri.AbsoluteUri)' is not the pinned HTTPS source '$($script:UtAllowedHost)'."
        }
        if ($uri.AbsolutePath -cnotin @('/codex-app-prod/ChatGPT-x64.msix', '/codex-app-prod/ChatGPT-arm64.msix')) {
            Stop-Ut $Code "The source URL '$($uri.AbsoluteUri)' is outside the two pinned ChatGPT package paths."
        }
        if ($uri.Port -ne 443 -and $uri.Port -ne -1) {
            Stop-Ut $Code "The source URL '$($uri.AbsoluteUri)' uses an unexpected port."
        }
        if (-not [string]::IsNullOrEmpty($uri.UserInfo) -or -not [string]::IsNullOrEmpty($uri.Query) -or -not [string]::IsNullOrEmpty($uri.Fragment)) {
            Stop-Ut $Code "The source URL '$($uri.AbsoluteUri)' contains credentials, a query, or a fragment."
        }
    }
    if ($requested.AbsolutePath -cne $actual.AbsolutePath) {
        Stop-Ut $Code "The final URL '$($actual.AbsoluteUri)' does not preserve the requested official path '$($requested.AbsolutePath)'."
    }
    return $actual
}

function Invoke-UtHeadRequest {
    param([Parameter(Mandatory = $true)][string]$Uri)
    $curl = Get-UtCurlPath
    $headerFile = [System.IO.Path]::GetTempFileName()
    $errorFile = [System.IO.Path]::GetTempFileName()
    try {
        $curlArgs = New-UtHeadCurlArguments -Uri $Uri -HeaderFile $headerFile
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $stdout = & $curl @curlArgs 2>$errorFile } finally { $ErrorActionPreference = $previous }
        $curlExit = $LASTEXITCODE
        $text = (@($stdout) | Out-String)
        $errorText = ''
        if (Test-Path -LiteralPath $errorFile) {
            $errorText = [string](Get-Content -LiteralPath $errorFile -Raw -ErrorAction SilentlyContinue)
        }
        if ($curlExit -ne 0) {
            Stop-Ut $script:UtExitNetwork "HEAD request failed (curl exit $curlExit). $($errorText.Trim())"
        }
        $writeOut = ConvertFrom-UtWriteOut -Text $text -RequestedUri $Uri -Code $script:UtExitNetwork
        $parsed = ConvertFrom-UtFinalHeaderBlock -Path $headerFile
        if ($parsed.StatusCode -ne $writeOut.HttpCode) {
            Stop-Ut $script:UtExitMetadata "The HEAD HTTP status was inconsistent (write-out $($writeOut.HttpCode), headers $($parsed.StatusCode))."
        }
        return [pscustomobject]@{ StatusCode = $writeOut.HttpCode; FinalUri = $writeOut.FinalUrl; Headers = $parsed.Headers }
    } finally {
        Remove-Item -LiteralPath $headerFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-UtRemoteMetadata {
    param(
        [Parameter(Mandatory = $true)]$HeadResult,
        [Parameter(Mandatory = $true)][string]$Architecture,
        [Parameter(Mandatory = $true)][string]$RequestedUri
    )
    if ($HeadResult.StatusCode -ne 200) {
        Stop-Ut $script:UtExitMetadata "The HEAD request returned HTTP $($HeadResult.StatusCode); a successful 200 response is required."
    }
    $finalUri = Assert-UtOfficialUri -RequestedUri $RequestedUri -ActualUri ([string]$HeadResult.FinalUri) -Code $script:UtExitMetadata
    $headers = $HeadResult.Headers
    $versionRaw = Get-UtSingleHeader -Headers $headers -Name 'x-ms-meta-package_version' -Required
    $version = ConvertTo-UtVersion -Value $versionRaw -Code $script:UtExitMetadata -Label 'CDN package version'
    $lengthRaw = Get-UtSingleHeader -Headers $headers -Name 'content-length' -Required
    if ($lengthRaw -notmatch '^[0-9]+$') { Stop-Ut $script:UtExitMetadata "Content-Length '$lengthRaw' is not a positive integer." }
    $length = [long]$lengthRaw
    if ($length -le 0) { Stop-Ut $script:UtExitMetadata 'Content-Length must be a positive integer.' }
    $etagHeaderPresent = $headers.ContainsKey('etag')
    $etag = Get-UtSingleHeader -Headers $headers -Name 'etag'
    if ($etagHeaderPresent -and [string]::IsNullOrEmpty($etag)) {
        Stop-Ut $script:UtExitMetadata "The CDN returned an empty ETag header; refusing to treat it as a usable validator."
    }
    $etagKind = 'Missing'
    $etagCommand = Get-Command Get-UtETagKind -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $etagCommand -and -not [string]::IsNullOrEmpty($etag)) {
        $etagKind = [string](Get-UtETagKind -ETag $etag)
    } elseif (-not [string]::IsNullOrEmpty($etag)) {
        if ($etag -cmatch '^W/"(?:[\x21\x23-\x7E]|\\[\x21-\x7E])*"$') { $etagKind = 'Weak' }
        elseif ($etag -cmatch '^"(?:[\x21\x23-\x7E]|\\[\x21-\x7E])*"$') { $etagKind = 'Strong' }
        else { Stop-Ut $script:UtExitMetadata "The CDN returned a malformed ETag; refusing to guess whether it is a strong validator." }
    }
    if ($etagKind -ne 'Strong' -and $etagKind -ne 'Weak' -and $etagKind -ne 'Missing') {
        Stop-Ut $script:UtExitMetadata "The ETag classifier returned an unsupported kind '$etagKind'."
    }
    $strongEtag = ($etagKind -eq 'Strong')
    $architectureHeader = Get-UtSingleHeader -Headers $headers -Name 'x-ms-meta-architecture'
    if (-not [string]::IsNullOrWhiteSpace($architectureHeader) -and $architectureHeader -ine $Architecture) {
        Stop-Ut $script:UtExitMetadata "The CDN reported architecture '$architectureHeader' but this system is '$Architecture'."
    }
    $identityHeader = Get-UtSingleHeader -Headers $headers -Name 'x-ms-meta-package_identity'
    if (-not [string]::IsNullOrWhiteSpace($identityHeader) -and $identityHeader -cne $script:UtPackageName) {
        Stop-Ut $script:UtExitMetadata "The CDN reported package identity '$identityHeader'; expected '$($script:UtPackageName)'."
    }
    return [pscustomobject]@{
        Version       = $version
        ContentLength = $length
        ETag          = $etag
        ETagKind      = $etagKind
        StrongETag    = $strongEtag
        Url           = $RequestedUri
        FinalUri      = $finalUri.AbsoluteUri
        Architecture  = $Architecture
    }
}

function New-UtIfMatchConfigLine {
    param([Parameter(Mandatory = $true)][string]$ETag)
    $value = "If-Match: $ETag"
    $escaped = $value.Replace('\', '\\').Replace('"', '\"')
    return 'header = "' + $escaped + '"'
}

function New-UtDownloadCurlArguments {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [string]$IfMatch,
        [string]$ConfigPath,
        [string]$HeaderFile,
        [switch]$Background
    )
    $arguments = New-Object System.Collections.ArrayList
    [void]$arguments.Add('--disable')
    if (-not [string]::IsNullOrEmpty($ConfigPath)) {
        # Request headers are kept in a temporary curl config. In particular,
        # the quoted ETag must not cross the Windows PowerShell native argv
        # boundary, where its quotes can be stripped. No --location: redirects
        # are never followed.
        [void]$arguments.Add('--config')
        [void]$arguments.Add($ConfigPath)
    }
    if (-not [string]::IsNullOrEmpty($HeaderFile)) {
        [void]$arguments.Add('--dump-header')
        [void]$arguments.Add($HeaderFile)
    }
    $progressArguments = if ($Background) { @('--silent', '--show-error') } else { @('--progress-bar') }
    foreach ($argument in @(
        '--fail', '--proto', '=https', '--proto-redir', '=https',
        '--connect-timeout', [string]$script:UtHeadConnectTimeout,
        '--max-time', [string]$script:UtDownloadMaxTime,
        '--retry', '3', '--retry-delay', '5', '--retry-connrefused'
    ) + $progressArguments + @(
        '--output', $OutputPath,
        '--write-out', "HTTPCODE=%{http_code}`nFINALURL=%{url_effective}",
        '--url', $Url
    )) {
        [void]$arguments.Add($argument)
    }
    return [string[]]$arguments.ToArray()
}

function New-UtAcceptEncodingConfigLine {
    return 'header = "Accept-Encoding: identity"'
}

function Invoke-UtCurlDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [string]$IfMatch,
        [switch]$Background
    )
    $curl = Get-UtCurlPath
    $configPath = $null
    $headerPath = $null
    try {
        $configPath = [System.IO.Path]::GetTempFileName()
        $configLines = New-Object System.Collections.ArrayList
        [void]$configLines.Add((New-UtAcceptEncodingConfigLine))
        if (-not [string]::IsNullOrEmpty($IfMatch)) { [void]$configLines.Add((New-UtIfMatchConfigLine -ETag $IfMatch)) }
        [IO.File]::WriteAllLines($configPath, [string[]]$configLines.ToArray(), [Text.Encoding]::ASCII)
        $headerPath = [System.IO.Path]::GetTempFileName()
        $curlArgs = New-UtDownloadCurlArguments -Url $Url -OutputPath $OutputPath -IfMatch $IfMatch -ConfigPath $configPath -HeaderFile $headerPath -Background:$Background
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $stdout = & $curl @curlArgs } finally { $ErrorActionPreference = $previous }
        $curlExit = $LASTEXITCODE
        $text = (@($stdout) | Out-String)
        $parsed = $null
        if (Test-Path -LiteralPath $headerPath -PathType Leaf) { $parsed = ConvertFrom-UtDownloadHeaderBlock -Path $headerPath }
        return [pscustomobject]@{
            ExitCode = [int]$curlExit
            Text = $text
            Headers = if ($null -eq $parsed) { $null } else { $parsed.Headers }
            HeaderStatusCode = if ($null -eq $parsed) { $null } else { [int]$parsed.StatusCode }
        }
    } finally {
        if ($null -ne $configPath) { Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue }
        if ($null -ne $headerPath) { Remove-Item -LiteralPath $headerPath -Force -ErrorAction SilentlyContinue }
    }
}

function Remove-UtArtifact {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
    } catch { }
}

function Assert-UtDownloadResponse {
    param(
        [Parameter(Mandatory = $true)]$Response,
        [Parameter(Mandatory = $true)]$Metadata
    )
    $headers = $Response.Headers
    if ($null -eq $headers -or -not ($headers -is [System.Collections.IDictionary])) {
        Stop-Ut $script:UtExitDownload 'The download did not expose a bounded HTTP response header object.'
    }
    if ($null -eq $Response.HeaderStatusCode -or [int]$Response.HeaderStatusCode -ne [int]$Response.HttpCode) {
        Stop-Ut $script:UtExitDownload 'The download HTTP status disagreed with its response headers.'
    }

    $metadataKind = [string]$Metadata.ETagKind
    if ([string]::IsNullOrWhiteSpace($metadataKind)) {
        $metadataKind = if ([bool]$Metadata.StrongETag) { 'Strong' } elseif ($null -eq $Metadata.ETag -or [string]::IsNullOrEmpty([string]$Metadata.ETag)) { 'Missing' } else { 'Weak' }
    }
    if ($metadataKind -notin @('Strong','Weak','Missing')) {
        Stop-Ut $script:UtExitDownload "The HEAD ETag kind '$metadataKind' is invalid."
    }

    $responseKind = 'Missing'
    $responseEtag = $null
    if ($headers.ContainsKey('etag')) {
        try { $responseEtag = Get-UtSingleHeader -Headers $headers -Name 'etag' -Required } catch {
            Stop-Ut $script:UtExitDownload ("The download ETag header was missing, empty or duplicated: {0}" -f $_.Exception.Message)
        }
        $etagCommand = Get-Command Get-UtETagKind -CommandType Function -ErrorAction SilentlyContinue
        try {
            if ($null -ne $etagCommand) { $responseKind = [string](Get-UtETagKind -ETag $responseEtag) }
            elseif ($responseEtag -cmatch '^W/"(?:[\x21\x23-\x7E]|\\[\x21-\x7E])*"$') { $responseKind = 'Weak' }
            elseif ($responseEtag -cmatch '^"(?:[\x21\x23-\x7E]|\\[\x21-\x7E])*"$') { $responseKind = 'Strong' }
            else { $responseKind = 'Invalid' }
        } catch {
            $responseKind = 'Invalid'
        }
    }
    $etagMatches = $false
    if ($metadataKind -eq 'Missing') {
        # A HEAD without a validator cannot establish an ETag identity.  A
        # legal GET validator is still useful evidence, but it must not be
        # required for the serial fallback to remain usable.
        $etagMatches = ($responseKind -eq 'Missing' -or $responseKind -eq 'Strong' -or $responseKind -eq 'Weak')
    } else {
        $etagMatches = ($responseKind -eq $metadataKind -and $responseEtag -cne $null -and $responseEtag -cne '' -and $responseEtag -ceq [string]$Metadata.ETag)
    }
    if (-not $etagMatches) {
        Stop-Ut $script:UtExitDownload 'The download ETag is missing, weak, malformed or different from the HEAD snapshot.'
    }

    if ($headers.ContainsKey('content-encoding')) {
        try { $encoding = Get-UtSingleHeader -Headers $headers -Name 'content-encoding' -Required } catch {
            Stop-Ut $script:UtExitDownload ("The download Content-Encoding header was missing or duplicated: {0}" -f $_.Exception.Message)
        }
        if ($encoding -cne 'identity') {
            Stop-Ut $script:UtExitDownload ("The download Content-Encoding '{0}' is not identity." -f $encoding)
        }
    }
}

function Receive-UtCandidate {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$RunDirectory,
        [Parameter(Mandatory = $true)][string]$Architecture,
        [switch]$Background
    )
    $partial = Join-Path $RunDirectory ("ChatGPT-{0}.msix.partial" -f $Architecture)
    $final = Join-Path $RunDirectory ("ChatGPT-{0}.msix" -f $Architecture)
    $ifMatch = $null
    if ($Metadata.StrongETag) { $ifMatch = $Metadata.ETag }
    $downloadCommand = Get-Command Invoke-UtCurlDownload -CommandType Function -ErrorAction Stop
    if ($downloadCommand.Parameters.ContainsKey('Background')) {
        $result = Invoke-UtCurlDownload -Url $Metadata.Url -OutputPath $partial -IfMatch $ifMatch -Background:$Background
    } else {
        $result = Invoke-UtCurlDownload -Url $Metadata.Url -OutputPath $partial -IfMatch $ifMatch
    }
    try {
        $writeOut = ConvertFrom-UtWriteOut -Text $result.Text -RequestedUri $Metadata.Url -Code $script:UtExitDownload
    } catch {
        Remove-UtArtifact $partial
        if ($result.ExitCode -ne 0) {
            Stop-Ut $script:UtExitDownload "Download failed (curl exit $($result.ExitCode)) and no acceptable response metadata was produced. The existing app and user data were not modified."
        }
        throw
    }
    if ($writeOut.HttpCode -eq 412) {
        Remove-UtArtifact $partial
        Stop-Ut $script:UtExitDownload 'The CDN rejected the If-Match precondition (HTTP 412): the package changed between the version check and the download. Re-run the updater.'
    }
    if ($result.ExitCode -ne 0) {
        Remove-UtArtifact $partial
        Stop-Ut $script:UtExitDownload "Download failed (curl exit $($result.ExitCode), HTTP $($writeOut.HttpCode)). The existing app and user data were not modified."
    }
    if ($writeOut.HttpCode -ne 200) {
        Remove-UtArtifact $partial
        Stop-Ut $script:UtExitDownload "The download returned HTTP $($writeOut.HttpCode); a successful 200 response is required."
    }
    $responseForValidation = [pscustomobject]@{
        Headers = $result.Headers
        HeaderStatusCode = $result.HeaderStatusCode
        HttpCode = $writeOut.HttpCode
    }
    try { Assert-UtDownloadResponse -Response $responseForValidation -Metadata $Metadata } catch {
        Remove-UtArtifact $partial
        throw
    }
    if (-not (Test-Path -LiteralPath $partial -PathType Leaf)) {
        Stop-Ut $script:UtExitDownload 'The download finished without producing a file.'
    }
    $length = (Get-Item -LiteralPath $partial).Length
    if ($length -le 0) {
        Remove-UtArtifact $partial
        Stop-Ut $script:UtExitDownload 'The downloaded package is empty.'
    }
    if ($length -ne $Metadata.ContentLength) {
        Remove-UtArtifact $partial
        Stop-Ut $script:UtExitDownload ("The downloaded size $length does not match the expected $($Metadata.ContentLength); the CDN content may have changed. Re-run the updater.")
    }
    if (Test-Path -LiteralPath $final) { Remove-UtArtifact $final }
    Move-Item -LiteralPath $partial -Destination $final -ErrorAction Stop
    return $final
}

# ---------------------------------------------------------------------------
# Locking and run directory.
# ---------------------------------------------------------------------------
function Get-UtRootDirectory {
    $base = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($base)) { Stop-Ut $script:UtExitEnvironment 'LOCALAPPDATA is not set; cannot choose a working directory.' }
    try { $base = [System.IO.Path]::GetFullPath($base) } catch { Stop-Ut $script:UtExitEnvironment "LOCALAPPDATA '$base' is not a valid path." }
    $root = Join-Path $base 'ChatGPTUpdater'
    $pathGuard = Get-Command Assert-UtManagedPath -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $pathGuard) { Assert-UtManagedPath -Path $root -Root $base -AllowMissingLeaf }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop
    }
    if ($null -ne $pathGuard) { Assert-UtManagedPath -Path $root -Root $base }
    return $root
}

function Enter-UtLock {
    $root = Get-UtRootDirectory
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop
    }
    $lockPath = Join-Path $root 'update.lock'
    $pathGuard = Get-Command Assert-UtManagedPath -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $pathGuard) { Assert-UtManagedPath -Path $lockPath -Root $root -AllowMissingLeaf }
    return [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
}

function New-UtRunDirectory {
    $root = Get-UtRootDirectory
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop
    }
    $runDirectory = Join-Path $root ([guid]::NewGuid().ToString('N'))
    $pathGuard = Get-Command Assert-UtManagedPath -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $pathGuard) { Assert-UtManagedPath -Path $runDirectory -Root $root -AllowMissingLeaf }
    $null = New-Item -ItemType Directory -Path $runDirectory -ErrorAction Stop
    if ($null -ne $pathGuard) { Assert-UtManagedPath -Path $runDirectory -Root $root }
    return $runDirectory
}

function Remove-UtRunArtifacts {
    # Removes only the files this run knows about, then the directory if empty.
    param(
        [Parameter(Mandatory = $true)][string]$RunDirectory,
        [Parameter(Mandatory = $true)][string]$Architecture
    )
    foreach ($name in @(("ChatGPT-{0}.msix" -f $Architecture), ("ChatGPT-{0}.msix.partial" -f $Architecture))) {
        $path = Join-Path $RunDirectory $name
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
    Remove-UtRunDirectoryIfEmpty -RunDirectory $RunDirectory
}

function Remove-UtRunDirectoryIfEmpty {
    param([Parameter(Mandatory = $true)][string]$RunDirectory)
    try {
        $entries = @(Get-ChildItem -LiteralPath $RunDirectory -Force -ErrorAction Stop)
        if ($entries.Count -eq 0) { Remove-Item -LiteralPath $RunDirectory -Force -ErrorAction SilentlyContinue }
    } catch { }
}

# ---------------------------------------------------------------------------
# Candidate validation.
# ---------------------------------------------------------------------------
function Open-UtReadLease {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
}

function Assert-UtSignature {
    param([Parameter(Mandatory = $true)][string]$Path)
    $signature = $null
    try { $signature = Get-UtAuthenticodeSignature -Path $Path } catch {
        Stop-Ut $script:UtExitSecurity "Authenticode verification could not be performed: $($_.Exception.Message)"
    }
    if ($null -eq $signature) { Stop-Ut $script:UtExitSecurity 'Authenticode returned no signature for the candidate package.' }
    $status = [string]$signature.Status
    if ($status -ne 'Valid') {
        Stop-Ut $script:UtExitSecurity "The MSIX Authenticode signature is not Valid (Status: $status). Signature checks must never be disabled or bypassed."
    }
    return $signature
}

function Read-UtManifestXml {
    param([Parameter(Mandatory = $true)][string]$Path)
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { }
    if ($null -eq ('System.IO.Compression.ZipFile' -as [type])) {
        Stop-Ut $script:UtExitSecurity 'System.IO.Compression.ZipFile is unavailable; cannot read the package manifest.'
    }
    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        $canonical = @($zip.Entries | Where-Object { [string]$_.FullName -ceq 'AppxManifest.xml' })
        $anyCase = @($zip.Entries | Where-Object { [string]$_.FullName -ieq 'AppxManifest.xml' })
        if ($canonical.Count -ne 1) { Stop-Ut $script:UtExitSecurity 'The MSIX must contain exactly one root AppxManifest.xml.' }
        if ($anyCase.Count -ne 1) { Stop-Ut $script:UtExitSecurity 'The MSIX contains an ambiguous or duplicate manifest entry.' }
        $entry = $canonical[0]
        if ($entry.Length -gt $script:UtMaxManifestBytes) {
            Stop-Ut $script:UtExitSecurity "AppxManifest.xml exceeds the $($script:UtMaxManifestBytes)-byte limit."
        }
        $stream = $null
        $reader = $null
        $document = $null
        try {
            $stream = $entry.Open()
            $settings = New-Object System.Xml.XmlReaderSettings
            $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
            $settings.XmlResolver = $null
            $settings.MaxCharactersInDocument = [long]($script:UtMaxManifestBytes * 2)
            $settings.IgnoreComments = $true
            $settings.IgnoreProcessingInstructions = $true
            $reader = [System.Xml.XmlReader]::Create($stream, $settings)
            $document = New-Object System.Xml.XmlDocument
            $document.XmlResolver = $null
            $document.Load($reader)
        } finally {
            if ($null -ne $reader) { $reader.Dispose() }
            if ($null -ne $stream) { $stream.Dispose() }
        }
        return $document
    } catch {
        if ($null -ne $_.Exception.Data -and $_.Exception.Data.Contains('UtExitCode')) { throw }
        Stop-Ut $script:UtExitSecurity "Failed to read AppxManifest.xml: $($_.Exception.Message)"
    } finally {
        if ($null -ne $zip) { $zip.Dispose() }
    }
}

function Get-UtXmlNamespaceManager {
    param([Parameter(Mandatory = $true)]$Document)
    $manager = New-Object System.Xml.XmlNamespaceManager($Document.NameTable)
    $manager.AddNamespace('a', $script:UtFoundationNs)
    # XmlNamespaceManager is IEnumerable; the unary comma prevents PowerShell from
    # unrolling it into prefix strings on the way out of the function.
    return ,$manager
}

function Read-UtManifestIdentity {
    param([Parameter(Mandatory = $true)]$Document)
    $namespaces = Get-UtXmlNamespaceManager -Document $Document
    $packages = @($Document.SelectNodes('/a:Package', $namespaces))
    if ($packages.Count -ne 1) {
        Stop-Ut $script:UtExitSecurity 'The manifest must contain exactly one Package element in the AppX foundation namespace.'
    }
    $identities = @($Document.SelectNodes('/a:Package/a:Identity', $namespaces))
    if ($identities.Count -ne 1) {
        Stop-Ut $script:UtExitSecurity 'The manifest must contain exactly one Package/Identity element.'
    }
    $identity = $identities[0]
    $name = [string]$identity.GetAttribute('Name')
    $publisher = [string]$identity.GetAttribute('Publisher')
    $architecture = [string]$identity.GetAttribute('ProcessorArchitecture')
    $versionRaw = [string]$identity.GetAttribute('Version')
    if ([string]::IsNullOrWhiteSpace($name)) { Stop-Ut $script:UtExitSecurity 'The manifest Identity is missing Name.' }
    if ([string]::IsNullOrWhiteSpace($publisher)) { Stop-Ut $script:UtExitSecurity 'The manifest Identity is missing Publisher.' }
    if ([string]::IsNullOrWhiteSpace($architecture)) { Stop-Ut $script:UtExitSecurity 'The manifest Identity is missing ProcessorArchitecture.' }
    $version = ConvertTo-UtVersion -Value $versionRaw -Code $script:UtExitSecurity -Label 'manifest Identity Version'
    return [pscustomobject]@{
        Name         = $name
        Publisher    = $publisher
        Architecture = $architecture
        Version      = $version
        RawVersion   = $versionRaw
    }
}

function Assert-UtIdentity {
    param(
        [Parameter(Mandatory = $true)]$Identity,
        [Parameter(Mandatory = $true)][string]$Architecture,
        [Parameter(Mandatory = $true)][version]$ExpectedVersion
    )
    if ($Identity.Name -cne $script:UtPackageName) {
        Stop-Ut $script:UtExitSecurity "The manifest Identity Name '$($Identity.Name)' is not '$($script:UtPackageName)'."
    }
    if ($Identity.Publisher -cne $script:UtManifestPublisher) {
        Stop-Ut $script:UtExitSecurity "The manifest Identity Publisher '$($Identity.Publisher)' does not match the expected publisher."
    }
    if ($Identity.Architecture -ine $Architecture) {
        Stop-Ut $script:UtExitSecurity "The manifest ProcessorArchitecture '$($Identity.Architecture)' does not match this system ('$Architecture')."
    }
    if ((Compare-UtVersion -A $Identity.Version -B $ExpectedVersion) -ne 0) {
        Stop-Ut $script:UtExitDownload "The manifest Version $($Identity.Version) does not match the CDN metadata version $ExpectedVersion; the CDN content may have changed. Re-run the updater."
    }
    return $Identity
}

function Assert-UtCompatibility {
    param(
        [Parameter(Mandatory = $true)]$Document,
        [Parameter(Mandatory = $true)][version]$WindowsVersion
    )
    $namespaces = Get-UtXmlNamespaceManager -Document $Document
    $families = @($Document.SelectNodes('/a:Package/a:Dependencies/a:TargetDeviceFamily', $namespaces))
    if ($families.Count -eq 0) {
        Stop-Ut $script:UtExitCompatibility 'The manifest declares no TargetDeviceFamily; Windows compatibility cannot be established.'
    }
    $desktop = @($families | Where-Object { [string]$_.GetAttribute('Name') -ieq 'Windows.Desktop' })
    $universal = @($families | Where-Object { [string]$_.GetAttribute('Name') -ieq 'Windows.Universal' })
    if ($desktop.Count -gt 1) { Stop-Ut $script:UtExitCompatibility 'The manifest declares Windows.Desktop more than once; the compatibility requirement is ambiguous.' }
    if ($desktop.Count -eq 0 -and $universal.Count -gt 1) { Stop-Ut $script:UtExitCompatibility 'The manifest declares Windows.Universal more than once; the compatibility requirement is ambiguous.' }
    $required = $null
    if ($desktop.Count -eq 1) { $required = $desktop[0] }
    elseif ($universal.Count -eq 1) { $required = $universal[0] }
    else {
        $names = @($families | ForEach-Object { [string]$_.GetAttribute('Name') }) -join ', '
        Stop-Ut $script:UtExitCompatibility "The manifest declares only non-desktop device families ($names); desktop is not supported by this package."
    }
    $minRaw = [string]$required.GetAttribute('MinVersion')
    if ([string]::IsNullOrWhiteSpace($minRaw)) { Stop-Ut $script:UtExitCompatibility 'TargetDeviceFamily is missing MinVersion.' }
    $minimum = ConvertTo-UtVersion -Value $minRaw -Code $script:UtExitCompatibility -Label 'TargetDeviceFamily MinVersion'
    if ((Compare-UtVersion -A $WindowsVersion -B $minimum) -lt 0) {
        Stop-Ut $script:UtExitCompatibility ("This package requires {0} >= {1}, but this system is Windows {2}." -f [string]$required.GetAttribute('Name'), $minimum, $WindowsVersion)
    }
    return $minimum
}

function Get-UtNodeValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertFrom-UtOptionalAttribute {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )
    switch ($Value.Trim().ToLowerInvariant()) {
        'true'  { return $true }
        '1'     { return $true }
        'false' { return $false }
        '0'     { return $false }
        default { Stop-Ut $script:UtExitDependency "PackageDependency '$Name' has an invalid uap6:Optional value '$Value'." }
    }
}

function Assert-UtDependencies {
    param(
        [Parameter(Mandatory = $true)]$Document,
        [Parameter(Mandatory = $true)][string]$Architecture
    )
    $namespaces = Get-UtXmlNamespaceManager -Document $Document
    $containers = @($Document.SelectNodes('/a:Package/a:Dependencies', $namespaces))
    if ($containers.Count -gt 1) {
        Stop-Ut $script:UtExitDependency 'The manifest declares more than one Dependencies container; the requirement is ambiguous.'
    }
    if ($containers.Count -eq 0) { return }
    $dependenciesNode = $containers[0]

    $required = @()
    foreach ($child in @($dependenciesNode.ChildNodes)) {
        if ($null -eq $child -or $child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
        $namespaceUri = [string]$child.NamespaceURI
        $localName = [string]$child.LocalName
        if ($namespaceUri -ceq $script:UtFoundationNs -and $localName -ceq 'TargetDeviceFamily') { continue }
        if ($namespaceUri -cne $script:UtFoundationNs -or $localName -cne 'PackageDependency') {
            Stop-Ut $script:UtExitDependency "Unsupported dependency element '{$namespaceUri}$localName'. This updater refuses to silently ignore unknown dependency semantics."
        }
        # Only the schema attribute uap6:Optional is recognized; a non-namespaced
        # or foreign Optional must never skip a required dependency.
        foreach ($attribute in @($child.Attributes)) {
            if ($null -ne $attribute -and $attribute.LocalName -ieq 'Optional' -and [string]::IsNullOrEmpty($attribute.NamespaceURI)) {
                Stop-Ut $script:UtExitDependency 'A PackageDependency uses a non-namespaced Optional attribute; only the schema uap6:Optional is recognized.'
            }
        }
        $name = [string]$child.GetAttribute('Name')
        $optionalValue = [string]$child.GetAttribute('Optional', $script:UtUap6Ns)
        if (-not [string]::IsNullOrEmpty($optionalValue)) {
            if ((ConvertFrom-UtOptionalAttribute -Value $optionalValue -Name $name)) { continue }
        }
        $required += $child
    }
    if ($required.Count -eq 0) { return }

    $seen = @{}
    foreach ($dependency in $required) {
        $name = [string]$dependency.GetAttribute('Name')
        $publisher = [string]$dependency.GetAttribute('Publisher')
        $key = ($name + '|' + $publisher).ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            Stop-Ut $script:UtExitDependency "The manifest declares dependency '$name' from the same publisher more than once; the requirement is ambiguous."
        }
        $seen[$key] = $true
    }

    $missing = @()
    foreach ($dependency in $required) {
        $name = [string]$dependency.GetAttribute('Name')
        $publisher = [string]$dependency.GetAttribute('Publisher')
        $minRaw = [string]$dependency.GetAttribute('MinVersion')
        if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($publisher) -or [string]::IsNullOrWhiteSpace($minRaw)) {
            Stop-Ut $script:UtExitDependency 'A PackageDependency entry is missing Name, Publisher or MinVersion.'
        }
        $minimum = ConvertTo-UtVersion -Value $minRaw -Code $script:UtExitDependency -Label "dependency '$name' MinVersion"
        $installed = @()
        try { $installed = @(Get-UtRawAppxPackage -Name $name) } catch {
            Stop-Ut $script:UtExitDependency "Failed to query required dependency '$name': $($_.Exception.Message)"
        }
        $match = @($installed | Where-Object {
            ([string](Get-UtNodeValue $_ 'Name') -ceq $name) -and
            ([string]$_.Publisher -ceq $publisher) -and
            ((ConvertTo-UtVersion -Value ([string]$_.Version) -Code $script:UtExitDependency -Label "dependency '$name' installed version").CompareTo($minimum) -ge 0) -and
            (([string]$_.Architecture -ieq $Architecture) -or ([string]$_.Architecture -ieq 'Neutral')) -and
            ([string]$_.Status -eq 'Ok') -and
            ((Get-UtNodeValue $_ 'IsFramework') -eq $true)
        })
        if ($match.Count -eq 0) {
            $missing += ("{0} >= {1} ({2}), Publisher {3}" -f $name, $minimum, $Architecture, $publisher)
        }
    }
    if ($missing.Count -gt 0) {
        Stop-Ut $script:UtExitDependency ("Missing required package dependencies:`n  - " + ($missing -join "`n  - ") + "`nInstall them from their official publisher; this updater will not fetch dependencies or bypass them.")
    }
}

function Open-UtValidatedCandidate {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$Architecture,
        [Parameter(Mandatory = $true)][version]$WindowsVersion,
        [switch]$KeepLease
    )
    $resolved = $null
    try { $resolved = [System.IO.Path]::GetFullPath($Path) } catch { Stop-Ut $script:UtExitSecurity "The candidate path '$Path' could not be resolved." }
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        Stop-Ut $script:UtExitDownload "The candidate package '$resolved' is missing."
    }
    $item = $null
    try { $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop } catch {
        Stop-Ut $script:UtExitDownload "The candidate package '$resolved' could not be read: $($_.Exception.Message)"
    }
    if ($item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        Stop-Ut $script:UtExitSecurity "The candidate path '$resolved' is not a regular file."
    }
    if ([long]$item.Length -ne [long]$Metadata.ContentLength) {
        Stop-Ut $script:UtExitDownload "The candidate size $($item.Length) does not match the expected $($Metadata.ContentLength)."
    }

    $lease = $null
    try {
        $lease = Open-UtReadLease -Path $resolved
        $signature = Assert-UtSignature -Path $resolved
        $document = Read-UtManifestXml -Path $resolved
        $identity = Read-UtManifestIdentity -Document $document
        $null = Assert-UtIdentity -Identity $identity -Architecture $Architecture -ExpectedVersion $Metadata.Version
        $null = Assert-UtCompatibility -Document $document -WindowsVersion $WindowsVersion
        Assert-UtDependencies -Document $document -Architecture $Architecture
        $sha256 = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
        $result = [pscustomobject]@{
            Path         = $resolved
            Identity     = $identity
            Signature    = $signature
            SHA256       = $sha256
            Metadata     = $Metadata
            Lease        = $null
        }
        if ($KeepLease) {
            $result.Lease = $lease
            $lease = $null
        }
        return $result
    } catch {
        if ($null -ne $_.Exception.Data -and $_.Exception.Data.Contains('UtExitCode')) { throw }
        Stop-Ut $script:UtExitSecurity "Candidate validation failed: $($_.Exception.Message)"
    } finally {
        if ($null -ne $lease) { $lease.Dispose() }
    }
}

function Get-UtValidatedCandidate {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$Architecture,
        [Parameter(Mandatory = $true)][version]$WindowsVersion
    )
    return Open-UtValidatedCandidate -Path $Path -Metadata $Metadata -Architecture $Architecture -WindowsVersion $WindowsVersion
}

function Write-UtDeploymentFailure {
    param($ErrorRecord)
    $text = ($ErrorRecord | Out-String)
    Write-UtError ("Deployment error: {0}" -f $ErrorRecord.Exception.Message)
    if ($text -match '0x80073D02') { Write-UtError '0x80073D02: package resources are in use. A background service may still hold them even when no ChatGPT window is open. The updater requested deferred registration where supported, but Windows still rejected this attempt. The update is incomplete; the cached package was retained. Restart Windows and run the updater again. See background.log for details. This updater will not terminate processes or stop services.' }
    if ($text -match '0x80073D06') { Write-UtError '0x80073D06: a higher version is already installed; no downgrade was attempted.' }
    if ($text -match '0x80073D28') { Write-UtError '0x80073D28: a packaged service requires administrator rights. This updater will not self-elevate or switch to provisioning.' }
    if ($text -match '0x80070005' -or $text -match 'Access is denied') { Write-UtError 'Access denied. This updater will not change permissions, policy or service settings.' }
    $activity = [regex]::Match($text, '(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})')
    if ($activity.Success) {
        $activityId = $activity.Groups[1].Value
        Write-UtError ("ActivityId: {0}  (read-only inspection: Get-AppPackageLog -ActivityID {0})" -f $activityId)
    }
    Write-UtError 'The previous version was not uninstalled and user data was not removed.'
}

function Start-UtConfirmationPrompt {
    <#
        Lazy standalone bridge.  The background worker supplies its own
        Start-UtConfirmationPrompt after dot-sourcing this core, so this
        function is only reached by a directly launched updater.  Keeping the
        loader here avoids importing the UI (or Windows Forms) for CheckOnly,
        an already-current install, or a dot-sourced library load.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Prepared,
        [switch]$OpenApp
    )
    # Dot-sourcing confirm-install recursively dot-sources this core.  Its
    # script-level parameter block can reuse the name OpenApp in this dynamic
    # scope, so capture the caller's request before loading the UI.
    $requestedOpenApp = [bool]$OpenApp
    $confirmPath = Join-Path $PSScriptRoot 'confirm-install.ps1'
    if (-not (Test-Path -LiteralPath $confirmPath -PathType Leaf)) {
        Stop-Ut $script:UtExitEnvironment 'The installation confirmation window is unavailable; the verified package remains in the managed cache and no installation was attempted.'
    }

    $metadata = $null
    if ($null -ne $Prepared) { $metadata = Get-UtNodeValue $Prepared 'Metadata' }
    if ($null -eq $metadata) {
        Stop-Ut $script:UtExitEnvironment 'The prepared candidate metadata is unavailable; no installation was attempted.'
    }

    # Capture a test or host-provided detached launcher before confirm-install
    # dot-sources background-common, which defines the production launcher.
    $detachedBefore = Get-Command Start-UbPromptDetached -CommandType Function -ErrorAction SilentlyContinue
    try {
        . $confirmPath
    } catch {
        Stop-Ut $script:UtExitEnvironment "The installation confirmation window could not be loaded; the verified package remains cached: $($_.Exception.Message)"
    }

    $loadedPrompt = Get-Command Start-UtConfirmationPrompt -CommandType Function -ErrorAction SilentlyContinue
    if ($null -eq $loadedPrompt -or $loadedPrompt.ScriptBlock.ToString() -eq $MyInvocation.MyCommand.ScriptBlock.ToString()) {
        Stop-Ut $script:UtExitEnvironment 'The installation confirmation window did not expose its prompt entry point; no installation was attempted.'
    }

    # Windows PowerShell 5.1 is the supported STA UI host.  A PowerShell 7
    # caller must detach a trusted 5.1 child instead of loading WinForms into
    # the current process.
    $useDetachedPrompt = ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ge 6 -or $null -ne $detachedBefore)
    if ($useDetachedPrompt) {
        $detached = $detachedBefore
        if ($null -eq $detached) { $detached = Get-Command Start-UbPromptDetached -CommandType Function -ErrorAction SilentlyContinue }
        if ($null -eq $detached) {
            Stop-Ut $script:UtExitEnvironment 'The Windows PowerShell 5.1 confirmation launcher is unavailable; the verified package remains cached and no installation was attempted.'
        }
        try {
            $architecture = [string](Get-UtNodeValue $metadata 'Architecture')
            if ([string]::IsNullOrWhiteSpace($architecture)) {
                Stop-Ut $script:UtExitEnvironment 'The prepared candidate architecture is missing; no installation was attempted.'
            }
            $root = Get-UbRoot
            $candidate = ConvertTo-UbCandidateFromPrepared -Prepared $Prepared -Metadata $metadata -Architecture $architecture
            $null = Set-UbCandidate -Root $root -Candidate $candidate -Now ([DateTime]::UtcNow)
            $arguments = @{
                ScriptPath = $confirmPath
                Root = $root
                ExpectedKey = [string]$candidate.Key
                ExpectedVersion = [string]$candidate.Version
                CorePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'update-chatgpt.ps1'))
                OpenApp = $requestedOpenApp
            }
            $process = & $detached.ScriptBlock @arguments
            if ($null -eq $process) { throw 'The confirmation process did not start.' }
            return [pscustomobject]@{ Code = $script:UtExitOk; Status = 'Prompted'; Message = 'Confirmation prompt launched; installation requires an explicit button click.' }
        } catch {
            if ((Get-UtErrorCode -ErrorRecord $_ -Default -1) -eq $script:UtExitEnvironment) { throw }
            Stop-Ut $script:UtExitEnvironment "The installation confirmation window could not be launched; the verified package remains cached: $($_.Exception.Message)"
        }
    }

    try {
        return (& $loadedPrompt.ScriptBlock -Prepared $Prepared -OpenApp:$requestedOpenApp)
    } catch {
        Stop-Ut $script:UtExitEnvironment "The installation confirmation window failed before authorization; the verified package remains cached: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Main flow.
# ---------------------------------------------------------------------------
function Invoke-UtUpdater {
    [CmdletBinding()]
    param(
        [switch]$CheckOnly,
        [switch]$DownloadOnly,
        [switch]$OpenApp,
        [int]$Connections = 8
    )
    try {
        if ($CheckOnly -and $DownloadOnly) { Stop-Ut $script:UtExitUsage '-CheckOnly and -DownloadOnly cannot be combined.' }
        if ($OpenApp -and ($CheckOnly -or $DownloadOnly)) { Stop-Ut $script:UtExitUsage '-OpenApp cannot be combined with -CheckOnly or -DownloadOnly.' }
        if (@(1, 4, 8, 16) -notcontains $Connections) { Stop-Ut $script:UtExitUsage '-Connections must be one of 1, 4, 8 or 16.' }

        $architecture = Get-UtNativeArchitecture
        $windowsVersion = Get-UtWindowsVersion
        $url = "{0}/ChatGPT-{1}.msix" -f $script:UtBaseUrl, $architecture

        Write-UtBanner -Architecture $architecture -WindowsVersion $windowsVersion

        $installed = Get-UtInstalledPackage
        if ($null -eq $installed) {
            Write-UtLine 'Installed:  not installed'
        } else {
            Write-UtLine ("Installed:  {0} (Status {1})" -f $installed.Version, $installed.Status)
        }

        $head = Invoke-UtHeadRequest -Uri $url
        $metadata = Get-UtRemoteMetadata -HeadResult $head -Architecture $architecture -RequestedUri $url
        Write-UtLine ("CDN latest: {0}  (HTTP metadata only; not a signature proof)" -f $metadata.Version)

        if ($null -ne $installed) {
            $comparison = Compare-UtVersion -A $installed.Version -B $metadata.Version
            if ($comparison -eq 0) {
                Write-UtLine ("Already up to date with the version reported by the CDN ({0})." -f $installed.Version)
                return $script:UtExitOk
            }
            if ($comparison -gt 0) {
                Write-UtLine ("Installed version {0} is newer than the CDN metadata {1}; refusing to downgrade." -f $installed.Version, $metadata.Version)
                return $script:UtExitOk
            }
        }

        $installedText = if ($null -eq $installed) { '(not installed)' } else { [string]$installed.Version }
        Write-UtLine ("Update available: {0} -> {1}" -f $installedText, $metadata.Version)

        if ($CheckOnly) {
            Write-UtLine 'Check-only: no download and no installation were performed.'
            return $script:UtExitOk
        }

        $prepareLock = $null
        $prepared = $null
        try {
            try { $prepareLock = Enter-UtLock } catch {
                Stop-Ut $script:UtExitLock "Another updater instance holds the lock, or the lock could not be acquired: $($_.Exception.Message)"
            }
            $prepared = Get-UtPreparedCandidate -Metadata $metadata -Architecture $architecture -WindowsVersion $windowsVersion -Connections $Connections
            Write-UtLine ("Candidate:  {0}, {1} bytes" -f $metadata.Version, $metadata.ContentLength)
            Write-UtLine ("SHA256:     {0}" -f $prepared.SHA256)
            Write-UtLine 'Verification: signature, identity, architecture, Windows compatibility and dependencies passed.'
            if ($DownloadOnly) {
                Write-UtLine 'Download-only: the verified package was NOT installed and is kept in the managed cache.'
                Write-UtLine ("Package path: {0}" -f $prepared.Path)
                return $script:UtExitOk
            }
        } finally {
            if ($null -ne $prepareLock) { $prepareLock.Dispose() }
        }

        $promptCommand = Get-Command Start-UtConfirmationPrompt -CommandType Function -ErrorAction SilentlyContinue
        if ($null -eq $promptCommand) {
            Stop-Ut $script:UtExitEnvironment 'The installation confirmation window is unavailable; the verified package remains in the managed cache and no installation was attempted.'
        }
        # The confirmation boundary owns the only user-consent path.  It is
        # invoked only after the preparation lock and all preparation leases
        # have been released; the UI calls Invoke-UtConfirmedInstall only after
        # the user explicitly clicks its install button.
        $installResult = Start-UtConfirmationPrompt -Prepared $prepared -OpenApp:$OpenApp
        if ($null -eq $installResult) {
            Stop-Ut $script:UtExitInternal 'The confirmation window returned no result; installation was not attempted.'
        }
        if ($installResult.Status -eq 'Installed' -or $installResult.Status -eq 'AlreadyCurrent' -or $installResult.Status -eq 'Deferred' -or $installResult.Status -eq 'Prompted') {
            Write-UtLine $installResult.Message
        } else {
            Write-UtError $installResult.Message
        }
        if ($installResult.Status -eq 'Deferred') {
            Write-UtLine 'The update was staged for deferred registration. No restart or service stop was attempted.'
        }
        if ($installResult.Status -eq 'Installed') {
            Write-UtLine 'Open the app to confirm sign-in and UI behavior; package registration does not prove those.'
            if ($OpenApp) {
                try {
                    Start-UtApp
                    Write-UtLine 'Launched ChatGPT.'
                } catch {
                    Write-UtLine ("WARNING: the update succeeded, but launching the app failed: {0}" -f $_.Exception.Message)
                }
            }
        }
        return [int]$installResult.Code
    } catch {
        $code = Get-UtErrorCode -ErrorRecord $_ -Default $script:UtExitInternal
        Write-UtError ("ERROR: {0}" -f $_.Exception.Message)
        return $code
    }
}

# The optional workers are function-only modules.  They are loaded after the
# core definitions so they can call the shared validators and boundaries, while
# dot-sourcing this file still performs no network, download or deployment.
$managedCachePath = Join-Path $PSScriptRoot 'managed-cache.ps1'
if (Test-Path -LiteralPath $managedCachePath -PathType Leaf) { . $managedCachePath }
$segmentedDownloadPath = Join-Path $PSScriptRoot 'segmented-download.ps1'
if (Test-Path -LiteralPath $segmentedDownloadPath -PathType Leaf) { . $segmentedDownloadPath }

# Dot-sourcing must only define the functions above; only a direct invocation
# starts the real updater and returns its exit code.
if ($MyInvocation.InvocationName -ne '.') {
    $selfUpdatePending = Join-Path $PSScriptRoot 'self-update.pending.json'
    if (Test-Path -LiteralPath $selfUpdatePending -PathType Leaf) {
        Write-UtError 'A self-update activation is pending or incomplete. Wait for the helper to finish, then run update-updater.cmd -Status.'
        exit $script:UtExitLock
    }
    $exitCode = Invoke-UtUpdater @PSBoundParameters
    exit ([int]$exitCode)
}
