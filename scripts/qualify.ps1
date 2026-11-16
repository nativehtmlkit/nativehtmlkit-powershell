# One-command PowerShell SDK qualification for THIS platform and PowerShell edition.
#
#   Linux (inside the KDE Wayland session for -Gui):
#     pwsh -NoProfile -File scripts/qualify.ps1 -HostBinary HOST -HostSha256 HEX -Out DIR [-Gui] [-Package ZIP -PackageHostSha256 HEX]
#   Windows, once per edition (inside the interactive desktop for -Gui):
#     pwsh.exe       -NoProfile -File scripts\qualify.ps1 ...
#     powershell.exe -NoProfile -File scripts\qualify.ps1 ...
#
# Fails closed when the host's SHA-256 differs from -HostSha256. Every gate is recorded in
# DIR/results.json as PASS / FAIL / BLOCKED with command, platform, session, edition, source tree
# hash, host SHA-256, duration, exit code and log path. A missing prerequisite is BLOCKED, never
# PASS; a failed assertion is FAIL. Headless suites are not GUI evidence (only -Gui is).
param(
    [Parameter(Mandatory)][string]$HostBinary,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$HostSha256,
    [Parameter(Mandatory)][string]$Out,
    [switch]$Gui,
    [string]$Package,
    [string]$PackageHostSha256,
    [string]$Label,
    # Only the desktop parts (G6 GUI and the GUI install smoke): run this second, under the desktop
    # lock, after a run without -Gui; results merge by gate id into the same results.json.
    [switch]$GuiOnly,
    # Gallery-style install (G8): PowerShell 7 publishes -Package to a local repository and installs it by
    # name; Windows PowerShell 5.1 installs with Install-Module from this repository folder (made by a PS 7 run).
    [string]$GalleryRepository,
    [string[]]$Suites = @('Unit', 'Transport', 'Faults', 'Tasks', 'Diagnostics', 'Review', 'DirectStart', 'RealHost'),
    # Deadline per step: a hang is recorded as FAIL (timeout) instead of stalling qualification.
    [ValidateRange(60, 7200)][int]$StepTimeoutSeconds = 1200
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$isWin = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$shell = (Get-Process -Id $PID).Path
$editionTag = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' + $PSVersionTable.PSVersion.Major } else { 'ps51' }
$platformTag = if ($isWin) { 'windows' } else { 'linux' }
if (-not $Label) { $Label = "$platformTag-$editionTag" }
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path -LiteralPath $Out).Path
$logs = Join-Path $Out "logs-$Label"; New-Item -ItemType Directory -Force -Path $logs | Out-Null
$HostBinary = (Resolve-Path -LiteralPath $HostBinary).Path

function Get-SourceTreeHash {
    # Same method as scripts/package-local.py: sha256 of sorted "path\0sha256\n" lines.
    $base = [IO.Path]::GetFullPath($root).TrimEnd('\', '/')
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($f in Get-ChildItem -LiteralPath $base -Recurse -File -Force) {
        $rel = $f.FullName.Substring($base.Length + 1).Replace('\', '/')
        $parts = $rel.Split('/')
        if (@($parts | Where-Object { $_ -in 'dist', 'verification', '.git', '__pycache__', '.venv' }).Count) { continue }
        if ($rel -ceq 'README.md' -or $rel -ceq 'docs/QUALIFICATION.md') { continue }   # docs: same rule as package-local.py
        if ($parts.Count -ge 3 -and $parts[0] -eq 'NativeHTMLKit' -and $parts[1] -eq 'runtimes' -and $f.Name -ne 'README.md') { continue }
        $lines.Add($rel + [char]0 + (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant() + "`n")
    }
    $array = $lines.ToArray(); [Array]::Sort($array, [StringComparer]::Ordinal)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (-join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(-join $array)) | ForEach-Object { $_.ToString('x2') })) } finally { $sha.Dispose() }
}

$session = if ($isWin) {
    $p = Get-Process -Id $PID
    "windows session $($p.SessionId) user $env:USERNAME interactive=$([Environment]::UserInteractive) desktop=$(if ($p.SessionId -gt 0 -and $Gui) { 'interactive' } else { 'unknown/none' })"
} else { "XDG_SESSION_TYPE=$env:XDG_SESSION_TYPE WAYLAND_DISPLAY=$env:WAYLAND_DISPLAY DISPLAY=$env:DISPLAY" }
$context = [ordered]@{
    platform = "$platformTag $([Environment]::OSVersion.VersionString)"; edition = "$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
    session = $session; source_tree_hash = (Get-SourceTreeHash); host_sha256 = (Get-FileHash -LiteralPath $HostBinary -Algorithm SHA256).Hash.ToLowerInvariant()
    host_path = $HostBinary; label = $Label
}
$resultsPath = Join-Path $Out 'results.json'
$results = New-Object System.Collections.ArrayList
if (Test-Path -LiteralPath $resultsPath) {
    # Windows PowerShell 5.1's ConvertFrom-Json emits a JSON array as ONE object: unroll it explicitly.
    foreach ($r in @(Get-Content -Raw -LiteralPath $resultsPath | ConvertFrom-Json | ForEach-Object { $_ })) { [void]$results.Add($r) }
}
function Save-Results { [IO.File]::WriteAllText($resultsPath, (ConvertTo-Json -InputObject @($results.ToArray()) -Depth 6), (New-Object Text.UTF8Encoding($false))) }
function Add-Result([string]$Id, [string]$Gate, [string]$Status, [string]$Command, [double]$Seconds, $ExitCode, [string]$Log, $Detail) {
    foreach ($old in @($results | Where-Object { $_.id -eq "$Label/$Id" })) { $results.Remove($old) }   # a rerun replaces that gate
    [void]$results.Add([ordered]@{ id = "$Label/$Id"; label = $Label; gate = $Gate; status = $Status; command = $Command
        platform = $context.platform; session = $context.session; edition = $context.edition; source_tree_hash = $context.source_tree_hash
        host_sha256 = $context.host_sha256; duration_s = [Math]::Round($Seconds, 2); exit_code = $ExitCode; log = $Log; detail = $Detail
        timestamp = [DateTime]::UtcNow.ToString('o') })
    Save-Results
    "{0,-8} {1,-4} {2}" -f $Status, $Gate, $Id
}
function Stop-ProcessTree([int]$ProcessId) {
    if ($isWin) { & taskkill.exe /T /F /PID $ProcessId 2>&1 | Out-Null; return }
    foreach ($child in @(& pgrep -P $ProcessId 2>$null)) { Stop-ProcessTree ([int]$child) }
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}
function Invoke-Logged([string]$Id, [string]$Gate, [string]$Exe, [string[]]$Arguments, [hashtable]$Environment = @{}, $Detail = $null, [scriptblock]$Classify) {
    $log = Join-Path $logs "$Id.log"
    $quoted = @($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + $_.Replace('"', '\"') + '"' } else { $_ } })
    $command = "$Exe $($quoted -join ' ')"
    $saved = @{}
    foreach ($k in $Environment.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Environment[$k]) }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $p = Start-Process -FilePath $Exe -ArgumentList $quoted -NoNewWindow -PassThru -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WorkingDirectory $root
        $null = $p.Handle
        $timedOut = -not $p.WaitForExit($StepTimeoutSeconds * 1000)
        if ($timedOut) { Stop-ProcessTree $p.Id; [void]$p.WaitForExit(30000); $code = 'timeout' } else { $code = $p.ExitCode }
    } finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
    $text = (Get-Content -Raw -LiteralPath $log -ErrorAction SilentlyContinue) + (Get-Content -Raw -LiteralPath "$log.err" -ErrorAction SilentlyContinue)
    $status = if ($timedOut) { 'FAIL' } elseif ($Classify) { & $Classify $code $text } elseif ($code -eq 0) { 'PASS' } else { 'FAIL' }
    if ($timedOut) { $Detail = @{ timeout_s = $StepTimeoutSeconds; note = 'step exceeded its deadline; process tree stopped' } }
    Add-Result $Id $Gate $status $command $clock.Elapsed.TotalSeconds $code $log $Detail
}

"NativeHTMLKit PowerShell qualification $Label"
$context | Format-List | Out-String | Write-Output
$actual = $context.host_sha256
if ($actual -ne $HostSha256.ToLowerInvariant()) {
    Add-Result 'host-sha256' 'G8' 'FAIL' "Get-FileHash $HostBinary" 0 1 $null @{ expected = $HostSha256.ToLowerInvariant(); actual = $actual }
    throw "Host SHA-256 mismatch: expected $HostSha256, got $actual. Refusing to qualify."
}
Add-Result 'host-sha256' 'G8' 'PASS' "Get-FileHash $HostBinary" 0 0 $null @{ sha256 = $actual }

if ($GuiOnly -and -not $Gui) { throw '-GuiOnly requires -Gui' }
if (-not $GuiOnly) {
# G0: manifest, import, C# helper compile, exports (fresh process of this edition).
$g0 = @'
$ErrorActionPreference = 'Stop'
$m = Test-ModuleManifest -Path '__PSD1__'
$t = [Diagnostics.Stopwatch]::StartNew()
Import-Module '__PSD1__' -Force
$importMs = $t.ElapsedMilliseconds
& (Get-Module NativeHTMLKit) { Initialize-NativeHTMLKitHelper }
$compileMs = $t.ElapsedMilliseconds - $importMs
$f = @(Get-Command -Module NativeHTMLKit -CommandType Function); $a = @(Get-Command -Module NativeHTMLKit -CommandType Alias)
$broken = @($a | Where-Object { -not $_.ResolvedCommand })
if ($m.RootModule -ne 'NativeHTMLKit.psm1' -or $f.Count -ne $m.ExportedFunctions.Count -or $a.Count -ne $m.ExportedAliases.Count -or $broken.Count) { throw "export mismatch: functions $($f.Count)/$($m.ExportedFunctions.Count) aliases $($a.Count)/$($m.ExportedAliases.Count) broken $($broken.Count)" }
"G0 root=$($m.RootModule) functions=$($f.Count) aliases=$($a.Count) import_ms=$importMs addtype_ms=$compileMs helper=$([NativeHTMLKit.Transport].Assembly.GetName().Name)"
'@.Replace('__PSD1__', (Join-Path $root 'NativeHTMLKit/NativeHTMLKit.psd1').Replace("'", "''"))
$g0File = Join-Path $logs 'g0-import.ps1'; [IO.File]::WriteAllText($g0File, $g0, (New-Object Text.UTF8Encoding($true)))
Invoke-Logged 'import-compile-exports' 'G0' $shell @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $g0File)

# Pester suites in fresh processes of this edition, against the pinned host (required).
$gates = @{ Unit = 'G0'; Transport = 'G2'; Faults = 'G4'; Tasks = 'G4'; Diagnostics = 'G4'; Review = 'G4'; DirectStart = 'G3'; RealHost = 'G3' }
foreach ($suite in $Suites) {
    $file = Join-Path $root "tests/$suite.Tests.ps1"
    $summary = Join-Path $logs "pester-$suite.json"
    $classify = { param($code, $text) if ($text -match 'BLOCKED: Pester') { 'BLOCKED' } elseif ($code -eq 0) { 'PASS' } else { 'FAIL' } }
    Invoke-Logged "pester-$suite" $gates[$suite] $shell @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'scripts/test-local.ps1'),
        '-Path', $file, '-HostBinary', $HostBinary, '-RequireHost', '-SummaryFile', $summary, '-ResultFile', (Join-Path $logs "pester-$suite.xml")) @{} $null $classify
    if (Test-Path -LiteralPath $summary) { $results[$results.Count - 1].detail = (Get-Content -Raw -LiteralPath $summary | ConvertFrom-Json); Save-Results }
}

}

# G6: native GUI with real input (only meaningful inside a real desktop session).
if ($Gui) {
    # Exit 3 from a driver: the desktop was not exclusive (another app's window present) -> BLOCKED.
    $guiClassify = { param($code, $text) if ($code -eq 3) { 'BLOCKED' } elseif ($code -eq 0) { 'PASS' } else { 'FAIL' } }
    $guiOut = Join-Path $Out "gui-$Label"
    if ($isWin) {
        $edition = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'ps51' }
        $pwshPath = if ($PSVersionTable.PSEdition -eq 'Core') { $shell } else { '' }
        $args6 = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', (Join-Path $root 'tests/native/drive_windows.ps1'), '-Edition', $edition,
            '-Module', (Join-Path $root 'NativeHTMLKit/NativeHTMLKit.psd1'), '-HostBinary', $HostBinary, '-Out', $guiOut, '-Mode', 'full')
        if ($pwshPath) { $args6 += @('-Pwsh', $pwshPath) }
        # The driver uses Windows Forms/UI Automation from Windows PowerShell 5.1 in either case.
        # Windows PowerShell 5.1 must not inherit PowerShell 7's PSModulePath (its core modules would shadow 5.1's).
        $ps51Modules = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules') + ';' + (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules')
        Invoke-Logged 'gui-full' 'G6' (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') $args6 @{ PSModulePath = $ps51Modules } @{ evidence = $guiOut } $guiClassify
    } else {
        Invoke-Logged 'gui-full' 'G6' 'python3' @((Join-Path $root 'tests/native/drive_linux.py'), '--module', (Join-Path $root 'NativeHTMLKit/NativeHTMLKit.psd1'),
            '--host', $HostBinary, '--out', $guiOut, '--mode', 'full', '--pwsh', $shell) @{} @{ evidence = $guiOut } $guiClassify
    }
    $summary = Get-ChildItem -LiteralPath $guiOut -Filter 'summary-full.json' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($summary) { $results[$results.Count - 1].detail = (Get-Content -Raw -LiteralPath $summary.FullName | ConvertFrom-Json); Save-Results }
} else {
    Add-Result 'gui-full' 'G6' 'BLOCKED' 'not requested (-Gui): no real desktop session asserted for this run' 0 $null $null $null
}

# G8: clean install of a packaged module.
if ($Package) {
    if (-not $PackageHostSha256) { throw '-PackageHostSha256 is required with -Package' }
    $modes = if ($GuiOnly) { @('gui') } elseif ($Gui) { @('headless', 'gui') } else { @('headless') }
    foreach ($mode in $modes) {
        $smokeOut = Join-Path $Out "smoke-$Label-$mode"
        $smokeArgs = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'scripts/smoke-installed.ps1'),
            '-Package', (Resolve-Path -LiteralPath $Package).Path, '-ExpectedHostSha256', $PackageHostSha256, '-Out', $smokeOut)
        if ($mode -eq 'gui') { $smokeArgs += '-Gui' }
        Invoke-Logged "installed-smoke-$mode" 'G8' $shell $smokeArgs @{} @{ evidence = $smokeOut; package_sha256 = (Get-FileHash -LiteralPath $Package -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    if (-not $GuiOnly) {
        $galleryOut = Join-Path $Out "gallery-$Label"
        $galleryRepo = if ($GalleryRepository) { $GalleryRepository } else { Join-Path $Out "gallery-repository-$Label" }
        $galleryArgs = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'scripts/test-gallery-install.ps1'),
            '-ExpectedHostSha256', $PackageHostSha256, '-Repository', $galleryRepo, '-Out', $galleryOut)
        if ($PSVersionTable.PSEdition -eq 'Core') {
            Invoke-Logged 'gallery-install' 'G8' $shell ($galleryArgs + @('-Package', (Resolve-Path -LiteralPath $Package).Path)) @{} @{ evidence = $galleryOut; repository = $galleryRepo }
        } elseif ($GalleryRepository -and (Test-Path -LiteralPath $GalleryRepository)) {
            Invoke-Logged 'gallery-install' 'G8' $shell $galleryArgs @{} @{ evidence = $galleryOut; repository = $galleryRepo; installer = 'PowerShellGet Install-Module' }
        } else {
            Add-Result 'gallery-install' 'G8' 'BLOCKED' 'test-gallery-install.ps1 (Windows PowerShell 5.1)' 0 $null $null @{ reason = 'needs -GalleryRepository with the .nupkg published by a PowerShell 7 run' }
        }
    }
}

$mine = @($results | Where-Object { $_.label -eq $Label })
$counts = $mine | ForEach-Object { [string]$_.status } | Group-Object | ForEach-Object { "$($_.Name)=$($_.Count)" }
"RESULT $Label $($counts -join ' ') -> $resultsPath"
exit $(if (@($mine | Where-Object { $_.status -eq 'FAIL' }).Count) { 1 } else { 0 })
