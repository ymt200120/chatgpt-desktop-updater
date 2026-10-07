#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Success','D02','Changed')]
    [string]$DemoResult = 'Success',
    [ValidateRange(1,120)]
    [int]$TimeoutSeconds = 60,
    [switch]$CompileOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$productionScript = [IO.Path]::GetFullPath((Join-Path $projectRoot 'confirm-install.ps1'))
$uiTest = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Test-UIEvents.ps1'))
$templatePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'MockUiHost.cs'))
if (-not (Test-Path -LiteralPath $productionScript -PathType Leaf)) { throw "Production confirmation script is missing: $productionScript" }
if (-not (Test-Path -LiteralPath $uiTest -PathType Leaf)) { throw "Mandatory UI mock guard test is missing: $uiTest" }
if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) { throw "Mock UI host template is missing: $templatePath" }

# Do not launch a host unless the production UI and its mandatory isolated mock
# guard are both present.  These checks do not alter the production scripts.
$productionText = [IO.File]::ReadAllText($productionScript, [Text.Encoding]::UTF8)
$uiTestText = [IO.File]::ReadAllText($uiTest, [Text.Encoding]::UTF8)
foreach ($required in @('DemoMode','Get-UbDemoInstallResult','MockResult','Invoke-UbInstallBoundary')) {
    if ($productionText.IndexOf($required, [StringComparison]::Ordinal) -lt 0) { throw "Production UI mock boundary is missing: $required" }
}
foreach ($required in @('DemoMode','ForbiddenProductionCalls','TEST/MOCK guard')) {
    if ($uiTestText.IndexOf($required, [StringComparison]::Ordinal) -lt 0) { throw "Mandatory UI mock guard is missing: $required" }
}

$systemRoot = [Environment]::GetEnvironmentVariable('SystemRoot')
if ([string]::IsNullOrWhiteSpace($systemRoot)) { throw 'SystemRoot is not set.' }
$automationCandidates = @(
    (Join-Path $systemRoot 'System32\WindowsPowerShell\v1.0\System.Management.Automation.dll'),
    (Join-Path $systemRoot 'Microsoft.Net\assembly\GAC_MSIL\System.Management.Automation\v4.0_3.0.0.0__31bf3856ad364e35\System.Management.Automation.dll')
)
$automationAssembly = $automationCandidates |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1
if ([string]::IsNullOrWhiteSpace([string]$automationAssembly)) {
    $gacRoot = Join-Path $systemRoot 'Microsoft.Net\assembly\GAC_MSIL\System.Management.Automation'
    if (Test-Path -LiteralPath $gacRoot -PathType Container) {
        $automationAssembly = Get-ChildItem -LiteralPath $gacRoot -Filter 'System.Management.Automation.dll' -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName -First 1
    }
}
if ([string]::IsNullOrWhiteSpace([string]$automationAssembly) -or -not (Test-Path -LiteralPath $automationAssembly -PathType Leaf)) {
    throw "Windows PowerShell automation assembly is missing under $systemRoot."
}
$automationAssembly = [IO.Path]::GetFullPath([string]$automationAssembly)

$compilerCandidates = @(
    (Join-Path $systemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $systemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$compiler = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace([string]$compiler)) { throw 'The Windows .NET Framework csc.exe compiler is unavailable.' }

$evidenceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'evidence\segmented-background'))
$null = [IO.Directory]::CreateDirectory($evidenceRoot)
$runId = [guid]::NewGuid().ToString('N')
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('ChatGPTUpdater-MockUiHost-' + $runId)
$null = [IO.Directory]::CreateDirectory($tempRoot)
$exePath = Join-Path $tempRoot 'ChatGPTUpdater-MockUiHost.exe'
$sourcePath = Join-Path $tempRoot 'MockUiHost.cs'
$compileEvidence = Join-Path $evidenceRoot ('mock-ui-host-' + $DemoResult + '-' + $runId + '-compile.txt')
$outputEvidence = Join-Path $evidenceRoot ('mock-ui-host-' + $DemoResult + '-' + $runId + '-output.txt')
$errorEvidence = Join-Path $evidenceRoot ('mock-ui-host-' + $DemoResult + '-' + $runId + '-errors.txt')
$summaryEvidence = Join-Path $evidenceRoot ('mock-ui-host-' + $DemoResult + '-' + $runId + '-summary.txt')

function ConvertTo-CSharpLiteralBody {
    param([Parameter(Mandatory = $true)][string]$Value)
    return $Value.Replace('\','\\').Replace('"','\"').Replace("`r",'\r').Replace("`n",'\n')
}

try {
    $source = [IO.File]::ReadAllText($templatePath, [Text.Encoding]::UTF8)
    $source = $source.Replace('@@PRODUCTION_SCRIPT@@', (ConvertTo-CSharpLiteralBody $productionScript))
    $source = $source.Replace('@@DEMO_RESULT@@', (ConvertTo-CSharpLiteralBody $DemoResult))
    $source = $source.Replace('@@TIMEOUT_SECONDS@@', ([string]$TimeoutSeconds))
    $source = $source.Replace('@@OUTPUT_PATH@@', (ConvertTo-CSharpLiteralBody $outputEvidence))
    $source = $source.Replace('@@ERROR_PATH@@', (ConvertTo-CSharpLiteralBody $errorEvidence))
    $source = $source.Replace('@@SUMMARY_PATH@@', (ConvertTo-CSharpLiteralBody $summaryEvidence))
    $source = $source.Replace('@@AUTOMATION_ASSEMBLY@@', (ConvertTo-CSharpLiteralBody $automationAssembly))
    [IO.File]::WriteAllText($sourcePath, $source, (New-Object Text.UTF8Encoding($false)))

    $compileArguments = @('/nologo','/target:winexe',('/out:' + $exePath),('/reference:' + $automationAssembly),$sourcePath)
    $compileOutput = @(& $compiler @compileArguments 2>&1)
    $compileExitCode = $LASTEXITCODE
    [IO.File]::WriteAllText($compileEvidence, (($compileOutput | Out-String) + ('ExitCode=' + $compileExitCode)), (New-Object Text.UTF8Encoding($false)))
    if ($compileExitCode -ne 0 -or -not (Test-Path -LiteralPath $exePath -PathType Leaf)) { throw "Mock UI host compilation failed; see $compileEvidence" }

    Write-Host ('[MOCK-UI-HOST] executable: ' + $exePath)
    Write-Host ('[MOCK-UI-HOST] DemoResult: ' + $DemoResult + '; TimeoutSeconds: ' + $TimeoutSeconds)
    Write-Host ('[MOCK-UI-HOST] output evidence: ' + $outputEvidence)
    Write-Host ('[MOCK-UI-HOST] error evidence: ' + $errorEvidence)
    Write-Host ('[MOCK-UI-HOST] summary evidence: ' + $summaryEvidence)
    if ($CompileOnly) { exit 0 }

    $process = Start-Process -FilePath $exePath -WindowStyle Normal -PassThru -ErrorAction Stop
    Write-Host ('[MOCK-UI-HOST] PID: ' + $process.Id)
    $process.WaitForExit()
    Write-Host ('[MOCK-UI-HOST] exit code: ' + $process.ExitCode)
    exit ([int]$process.ExitCode)
}
finally {
    $resolvedTempRoot = [IO.Path]::GetFullPath($tempRoot)
    $expectedTempRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('ChatGPTUpdater-MockUiHost-' + $runId)))
    if ($resolvedTempRoot -cne $expectedTempRoot) { throw 'Mock host cleanup target mismatch.' }
    if (Test-Path -LiteralPath $resolvedTempRoot) {
        $cleanupItem = Get-Item -LiteralPath $resolvedTempRoot -Force
        if (($cleanupItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Mock host cleanup root is a reparse point.' }
        # This directory contains only these three known compiler artifacts.
        foreach ($artifact in @($exePath, $sourcePath, [IO.Path]::ChangeExtension($exePath, '.pdb'))) {
            if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($artifact)) -cne $resolvedTempRoot) { throw 'Mock host artifact escaped its own directory.' }
            if (Test-Path -LiteralPath $artifact -PathType Leaf) { Remove-Item -LiteralPath $artifact -Force -ErrorAction SilentlyContinue }
        }
        if (@(Get-ChildItem -LiteralPath $resolvedTempRoot -Force).Count -eq 0) { Remove-Item -LiteralPath $resolvedTempRoot -Force -ErrorAction SilentlyContinue }
    }
}
