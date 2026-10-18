#requires -Version 5.1
<#
Small live transport acceptance using the production range/process/response
and stream-merge functions. Each batch fetches only the first 64 KiB, while
Content-Range is checked against the real complete HEAD object length.
These prefixes are NOT complete packages or signature/deployment evidence.
#>
[CmdletBinding()]
param([string]$EvidenceDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) { $EvidenceDirectory = Join-Path $PSScriptRoot 'evidence\segmented-background' }
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'update-chatgpt.ps1')
function Install-UtPackage { param([string]$Path, [switch]$DeferRegistration) throw 'Live range acceptance MUST NOT deploy.' }
$architecture = Get-UtNativeArchitecture
$url = '{0}/ChatGPT-{1}.msix' -f $script:UtBaseUrl,$architecture
$metadata = Get-UtRemoteMetadata -HeadResult (Invoke-UtHeadRequest -Uri $url) -Architecture $architecture -RequestedUri $url
if (-not $metadata.StrongETag) { throw 'This live parallel acceptance needs a legal strong ETag.' }
$prefixLength = [long][Math]::Min(65536L,[long]$metadata.ContentLength)
$lock = $null
$run = $null
$handles = New-Object Collections.ArrayList
$knownFiles = New-Object Collections.ArrayList
$knownDirectories = New-Object Collections.ArrayList
$batches = @()
try {
    $lock = Enter-UtLock
    $run = New-UtRunDirectory
    foreach ($connections in @(8,16)) {
        $unicode = [string][char]0x6D4B + [string][char]0x8BD5
        $segments = Join-Path $run ('live range ' + $unicode + ' [brackets] ' + $connections)
        [void]$knownDirectories.Add($segments)
        $ranges = @(New-UtRangePlan -TotalLength $prefixLength -Connections $connections)
        $batchHandles = @()
        foreach ($range in $ranges) {
            $handle = Start-UtRangeDownload -Metadata $metadata -RunDirectory $run -Architecture $architecture -Range $range -Index $range.Index -SegmentDirectory $segments
            [void]$handles.Add($handle)
            $batchHandles += $handle
        }
        $responses = @{}
        # Complete in reverse order so merging cannot rely on completion order.
        for ($index = $batchHandles.Count - 1; $index -ge 0; $index--) {
            $handle = $batchHandles[$index]
            $response = Complete-UtRangeDownload -Handle $handle
            if (@($response).Count -ne 1) { throw 'A range completed with ambiguous response output.' }
            $responses[[int]$handle.Request.Index] = $response
        }
        $merged = Join-Path $run ('transport-prefix-' + $connections + '.partial')
        [void]$knownFiles.Add($merged)
        $null = Merge-UtRangeFiles -Ranges $ranges -Responses $responses -PartialPath $merged -TotalLength $prefixLength
        if ((Get-Item -LiteralPath $merged).Length -ne $prefixLength) { throw 'The merged prefix has the wrong length.' }
        $rangesEvidence = @()
        foreach ($range in $ranges) {
            $response = $responses[[int]$range.Index]
            $rangesEvidence += [ordered]@{
                Start = $range.Start
                End = $range.End
                ActualLength = (Get-Item -LiteralPath $response.OutputPath).Length
                ExitCode = $response.ExitCode
                HttpCode = $response.HttpCode
                FinalUri = $response.FinalUri
                ContentRange = (Get-UtParallelHeaderValue -Headers $response.Headers -Name 'content-range' -Required)
                ETag = (Get-UtParallelHeaderValue -Headers $response.Headers -Name 'etag' -Required)
            }
        }
        $batches += [ordered]@{
            Connections = $connections
            RangeCount = $ranges.Count
            Bytes = $prefixLength
            SHA256 = (Get-FileHash -LiteralPath $merged -Algorithm SHA256).Hash
            Ranges = $rangesEvidence
        }
    }
    if ($batches[0].SHA256 -cne $batches[1].SHA256) { throw 'The 8/16 connection prefixes differ.' }
    $report = [ordered]@{
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
        Runtime = $PSVersionTable.PSVersion.ToString()
        Architecture = $architecture
        Version = [string]$metadata.Version
        FullObjectLength = $metadata.ContentLength
        ETag = $metadata.ETag
        TotalBodyBytes = ($prefixLength * 2)
        MatchingPrefixHashes = $true
        TransportOnly = $true
        SignatureAcceptance = $false
        Deployed = $false
        Batches = $batches
    }
    [IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($EvidenceDirectory)) | Out-Null
    $json = $report | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'live-ranges.json'),$json,(New-Object Text.UTF8Encoding($false)))
    [pscustomobject]@{ Batches=2; Connections='8,16'; Bytes=$report.TotalBodyBytes; SameHash=$true; Deployed=$false } | ConvertTo-Json -Compress
} finally {
    Stop-UtParallelOwnedProcesses -Handles @($handles)
    foreach ($handle in $handles) { Remove-UtParallelHandleArtifacts -Handle $handle }
    foreach ($file in $knownFiles) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    foreach ($directory in $knownDirectories) { Remove-UtRunDirectoryIfEmpty -RunDirectory $directory }
    if ($null -ne $run) { Remove-UtRunDirectoryIfEmpty -RunDirectory $run }
    if ($null -ne $lock) { $lock.Dispose() }
}
