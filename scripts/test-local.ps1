# Runs the Pester suites against the source module (or NATIVEHTMLKIT_TEST_MODULE) in THIS edition.
#   pwsh -NoProfile -File scripts/test-local.ps1 [-Path tests/Unit.Tests.ps1,...] [-HostBinary PATH] [-RequireHost] [-ResultFile x.xml] [-SummaryFile x.json]
#   powershell.exe -NoProfile -File scripts\test-local.ps1 ...      (Windows PowerShell 5.1)
# Pester 5.5-5.x is required (Pester 6 is not supported by these suites). With -RequireHost a
# missing native host fails the run instead of skipping the real-host cases.
param(
    [string[]]$Path,
    [string]$HostBinary,
    [switch]$RequireHost,
    [string]$ResultFile,
    [string]$SummaryFile
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$module = if ($env:NATIVEHTMLKIT_TEST_MODULE) { $env:NATIVEHTMLKIT_TEST_MODULE } else { Join-Path $root 'NativeHTMLKit/NativeHTMLKit.psd1' }
Test-ModuleManifest -Path $module -ErrorAction Stop | Out-Null
$pester = Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.5.0' -and $_.Version.Major -eq 5 } | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) { throw 'BLOCKED: Pester 5.5+ (5.x) must be installed locally (Install-Module Pester -RequiredVersion 5.x -Scope CurrentUser)' }
Import-Module $pester.Path -ErrorAction Stop
$env:NATIVEHTMLKIT_TEST_MODULE = $module
if ($HostBinary) { $env:NATIVEHTMLKIT_HOST_BINARY = (Resolve-Path -LiteralPath $HostBinary).Path }
if ($RequireHost) { $env:NATIVEHTMLKIT_REQUIRE_HOST = '1' }
$config = New-PesterConfiguration
$config.Run.Path = if ($Path) { @($Path | ForEach-Object { (Resolve-Path -LiteralPath $_).Path }) } else { Join-Path $root 'tests' }
$config.Run.PassThru = $true
# Platform-specific tests are excluded (not skipped) on the other OS, so a skip only ever means "no host".
$config.Filter.ExcludeTag = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { @('LinuxOnly') } else { @('WindowsOnly') }
$config.Output.Verbosity = 'Detailed'
if ($ResultFile) { $config.TestResult.Enabled = $true; $config.TestResult.OutputPath = $ResultFile; $config.TestResult.OutputFormat = 'NUnitXml' }
$result = Invoke-Pester -Configuration $config
$summary = [ordered]@{ pester = $pester.Version.ToString(); edition = [string]$PSVersionTable.PSEdition; ps_version = $PSVersionTable.PSVersion.ToString()
    passed = $result.PassedCount; failed = $result.FailedCount; skipped = $result.SkippedCount; not_run = $result.NotRunCount
    container_failures = @($result.Containers | Where-Object { $_.Result -eq 'Failed' -and $_.ErrorRecord.Count -gt 0 }).Count
    failed_tests = @($result.Failed | ForEach-Object { $_.ExpandedPath }) }
if ($SummaryFile) { [IO.File]::WriteAllText($SummaryFile, (ConvertTo-Json -InputObject $summary -Depth 4)) }
"TOTAL passed=$($summary.passed) failed=$($summary.failed) skipped=$($summary.skipped) notrun=$($summary.not_run)"
$bad = $summary.failed -gt 0 -or $summary.container_failures -gt 0 -or ($RequireHost -and $summary.skipped -gt 0)
exit $(if ($bad) { 1 } else { 0 })
