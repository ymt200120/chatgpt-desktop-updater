#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.Path]::GetFullPath($Path)
}

function Assert-Directory {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Label)
    $full = Get-FullPath $Path
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        throw "$Label is missing: $full"
    }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label is a reparse point: $full"
    }
    return $full.TrimEnd('\')
}

function Test-ChildPath {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Root)
    $fullPath = Get-FullPath $Path
    $fullRoot = (Get-FullPath $Root).TrimEnd('\')
    return $fullPath.StartsWith($fullRoot + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-CurrentRuntime {
    $name = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { 'pwsh.exe' }
    $candidate = Join-Path $PSHOME $name
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        $command = Get-Command $name -CommandType Application -ErrorAction Stop
        $candidate = [string]$command.Source
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "The current PowerShell runtime executable was not found: $candidate"
    }
    return Get-FullPath $candidate
}

function Assert-PowerShellParses {
    param([Parameter(Mandatory = $true)][string[]]$Paths)
    $diagnostics = New-Object System.Collections.Generic.List[string]
    foreach ($path in $Paths) {
        $tokens = $null
        $errors = $null
        try {
            [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
        }
        catch {
            [void]$diagnostics.Add(('{0}: parser invocation failed: {1}' -f $path, $_.Exception.Message))
            continue
        }
        foreach ($error in @($errors)) {
            $extent = $error.Extent
            [void]$diagnostics.Add(('{0}:{1}:{2}: {3}' -f $path, $extent.StartLineNumber, $extent.StartColumnNumber, $error.Message))
        }
    }
    if ($diagnostics.Count -gt 0) {
        throw ('PowerShell parse diagnostics:`r`n' + [string]::Join("`r`n", $diagnostics.ToArray()))
    }
}

function Get-SummaryLines {
    param([Parameter(Mandatory = $true)][string]$Text)
    $lines = @($Text -split "`r?`n")
    return @($lines | Where-Object {
        $_ -match '(?i)^\s*All\s+\d+\s+.*test cases passed\.\s*$' -or
        $_ -match '(?i)^\s*\[UI-EVENTS\]\s+(total|evidence:)' -or
        $_ -match '(?i)^\s*\d+\s+of\s+\d+\s+.*failed\.'
    })
}

function Get-SuiteValidation {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][int]$NativeExit,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $problems = New-Object System.Collections.Generic.List[string]
    $positive = $false
    $total = 0

    if ($Text -match '(?im)^\s*All\s+([1-9]\d*)\s+.*test cases passed\.\s*$') {
        $positive = $true
        $total = [int]$Matches[1]
    }
    $uiMatch = [regex]::Match($Text, '(?im)^\s*\[UI-EVENTS\]\s+total=(\d+)\s+failed=(\d+)\s*$')
    if ($uiMatch.Success) {
        $positive = $true
        $total = [int]$uiMatch.Groups[1].Value
        if ([int]$uiMatch.Groups[2].Value -ne 0) {
            [void]$problems.Add(('UI-EVENTS reported failures: {0}' -f $uiMatch.Groups[2].Value))
        }
    }
    if ($NativeExit -ne 0) { [void]$problems.Add(('native exit code was {0}' -f $NativeExit)) }
    if ($Text -match '(?im)^\s*\[UI-EVENTS\]\s+SKIP\s*:') { [void]$problems.Add('UI-EVENTS reported SKIP') }
    if (-not $positive) { [void]$problems.Add('no positive pass summary was found') }
    if ($total -le 0) { [void]$problems.Add('total test count was zero or absent') }
    return [pscustomobject]@{ Name = $Name; NativeExit = $NativeExit; Total = $total; Problems = @($problems) }
}

function Remove-ExactOwnedFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Root)
    $full = Get-FullPath $Path
    if (-not (Test-ChildPath -Path $full -Root $Root)) { throw "Refusing to clean a path outside the tool run root: $full" }
    if (Test-Path -LiteralPath $full -PathType Leaf) { Remove-Item -LiteralPath $full -Force -ErrorAction Stop }
}

function Remove-EmptyOwnedDirectory {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Root)
    $full = Get-FullPath $Path
    if (-not (Test-ChildPath -Path $full -Root $Root)) { throw "Refusing to clean a directory outside the tool run root: $full" }
    if (Test-Path -LiteralPath $full -PathType Container) {
        $children = @(Get-ChildItem -LiteralPath $full -Force -ErrorAction Stop)
        if ($children.Count -eq 0) { Remove-Item -LiteralPath $full -Force -ErrorAction Stop }
    }
}

function Invoke-OfflineRunner {
    $repoRoot = Get-FullPath (Join-Path $PSScriptRoot '..')
    $projectRoot = Assert-Directory -Path (Join-Path $repoRoot 'chatgpt-updater') -Label 'Project root'
    $scriptsRoot = Assert-Directory -Path (Join-Path $repoRoot 'scripts') -Label 'Scripts root'
    $parseItems = @(Get-ChildItem -LiteralPath $projectRoot -Filter '*.ps1' -File -Recurse -Force -ErrorAction Stop)
    $parseItems += @(Get-ChildItem -LiteralPath $scriptsRoot -Filter '*.ps1' -File -Recurse -Force -ErrorAction Stop)
    $parsePaths = @($parseItems | ForEach-Object { Get-FullPath -Path ([string]$_.FullName) } | Sort-Object -Unique)
    if ($parsePaths.Count -eq 0) { throw 'No PowerShell source files were found to parse.' }
    Assert-PowerShellParses -Paths $parsePaths
    Write-Host ('[OFFLINE] parsed {0} PowerShell files' -f $parsePaths.Count)

    $runtime = Get-CurrentRuntime
    $tempRoot = (Get-FullPath ([IO.Path]::GetTempPath())).TrimEnd('\')
    $runRoot = Get-FullPath (Join-Path $tempRoot ('ChatGPTUpdater-offline-' + [guid]::NewGuid().ToString('N')))
    if (-not (Test-ChildPath -Path $runRoot -Root $tempRoot)) { throw "Generated run root escaped TEMP: $runRoot" }
    [void][IO.Directory]::CreateDirectory($runRoot)
    $evidenceRoot = Get-FullPath (Join-Path $runRoot 'ui-evidence')
    [void][IO.Directory]::CreateDirectory($evidenceRoot)

    $suites = @(
        [pscustomobject]@{ Name = 'Updater'; Path = Join-Path $projectRoot 'tests\Test-Updater.ps1'; Arguments = @() },
        [pscustomobject]@{ Name = 'Cache'; Path = Join-Path $projectRoot 'tests\Test-Cache.ps1'; Arguments = @() },
        [pscustomobject]@{ Name = 'SegmentedDownload'; Path = Join-Path $projectRoot 'tests\Test-SegmentedDownload.ps1'; Arguments = @() },
        [pscustomobject]@{ Name = 'Background'; Path = Join-Path $projectRoot 'tests\Test-Background.ps1'; Arguments = @() },
        [pscustomobject]@{ Name = 'UIEvents'; Path = Join-Path $projectRoot 'tests\Test-UIEvents.ps1'; Arguments = @('-EvidenceDirectory', $evidenceRoot) }
    )
    foreach ($suite in $suites) {
        $suitePath = Get-FullPath $suite.Path
        if (-not (Test-Path -LiteralPath $suitePath -PathType Leaf)) { throw "Offline suite is missing: $suitePath" }
    }

    $results = New-Object System.Collections.Generic.List[object]
    $capturedLogs = New-Object System.Collections.Generic.List[string]
    foreach ($suite in $suites) {
        Write-Host ('[OFFLINE] running {0}' -f $suite.Name)
        $output = @()
        $nativeExit = 1
        Push-Location $repoRoot
        try {
            $output = @(& $runtime -NoProfile -STA -ExecutionPolicy Bypass -File (Get-FullPath $suite.Path) @($suite.Arguments) 2>&1 | ForEach-Object { [string]$_ })
            $nativeExit = [int]$LASTEXITCODE
        }
        catch {
            $output += [string]$_.Exception.Message
            $nativeExit = 1
        }
        finally { Pop-Location }
        $text = [string]::Join("`r`n", [string[]]$output)
        $validation = Get-SuiteValidation -Text $text -NativeExit $nativeExit -Name $suite.Name
        foreach ($line in @(Get-SummaryLines -Text $text)) { Write-Host ('  ' + $line.Trim()) }
        if ($validation.Problems.Count -eq 0) {
            Write-Host ('[OFFLINE] {0} passed ({1} cases)' -f $suite.Name, $validation.Total) -ForegroundColor Green
        }
        else {
            Write-Host ('[OFFLINE] {0} failed validation: {1}' -f $suite.Name, ([string]::Join('; ', $validation.Problems))) -ForegroundColor Red
            Write-Host ('[OFFLINE] {0} captured output BEGIN' -f $suite.Name) -ForegroundColor Yellow
            if ($output.Count -eq 0) {
                Write-Host ('[OFFLINE] {0} captured output: <empty>' -f $suite.Name) -ForegroundColor Yellow
            }
            else {
                foreach ($line in $output) {
                    Write-Host ('[OFFLINE] {0} | {1}' -f $suite.Name, [string]$line)
                }
            }
            Write-Host ('[OFFLINE] {0} captured output END' -f $suite.Name) -ForegroundColor Yellow
        }
        [void]$results.Add($validation)
        [void]$capturedLogs.Add(('===== {0} (native exit {1}) =====' -f $suite.Name, $nativeExit))
        [void]$capturedLogs.Add($text)
    }

    $failed = @($results | Where-Object { $_.Problems.Count -gt 0 })
    if ($failed.Count -gt 0) {
        $reportPath = Join-Path $runRoot 'offline-failure-report.txt'
        $report = @(
            'ChatGPT updater offline runner failure report',
            ('Runtime: ' + $runtime),
            ('Repository: ' + $repoRoot),
            ('Run root: ' + $runRoot),
            '',
            'Validation results:',
            ($results | ForEach-Object { '{0}: native={1}, total={2}, problems={3}' -f $_.Name, $_.NativeExit, $_.Total, ([string]::Join('; ', $_.Problems)) }),
            '',
            'Captured suite output:',
            [string]::Join("`r`n", $capturedLogs.ToArray())
        )
        Set-Content -LiteralPath $reportPath -Value $report -Encoding UTF8
        Write-Host ('[OFFLINE] failure report retained at: {0}' -f $reportPath) -ForegroundColor Red
        $nativeFailures = @($failed | Where-Object { $_.NativeExit -ne 0 })
        if ($nativeFailures.Count -gt 0) { return [int]$nativeFailures[0].NativeExit }
        return 1
    }

    $knownEvidence = @(
        (Join-Path $evidenceRoot 'ui-form-fixture.png'),
        (Join-Path $evidenceRoot 'ui-events-summary.json')
    )
    foreach ($path in $knownEvidence) { Remove-ExactOwnedFile -Path $path -Root $runRoot }
    Remove-EmptyOwnedDirectory -Path $evidenceRoot -Root $runRoot
    Remove-EmptyOwnedDirectory -Path $runRoot -Root $tempRoot
    Write-Host '[OFFLINE] all five suites passed; tool-owned temporary evidence was cleaned.' -ForegroundColor Green
    return 0
}

try {
    exit (Invoke-OfflineRunner)
}
catch {
    Write-Error -Message ([string]$_.Exception.Message)
    exit 1
}
