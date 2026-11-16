# Clean-install smoke test of a packaged NativeHTMLKit module (from scripts/package-local.py).
#
#   pwsh -File scripts/smoke-installed.ps1 -Package dist/NativeHTMLKit-<version>-linux-x64.zip -ExpectedHostSha256 <hex> [-Gui] [-Out DIR]
#   powershell.exe -File scripts\smoke-installed.ps1 ...      (Windows PowerShell 5.1)
#
# Expands the ZIP into a fresh module folder, then runs a child process of THIS PowerShell edition
# whose PSModulePath holds only that folder and the edition's own modules, without host overrides
# (NATIVEHTMLKIT_HOST_BINARY / UI4ME_HOST_BINARY) and with Rust toolchains removed from PATH. The
# child imports the module BY NAME, checks the bundled host's SHA-256 and the host protocol version,
# and opens a window through Start-NativeHTMLKitScript. Without -Gui the host runs headless; with
# -Gui (run inside a real desktop session) a native window is required and must be observed by the
# desktop (Win32 window list / KWin). Exit 0 only if every check passed.
#
# -ModulesPath instead of -Package checks a module already installed by a package manager
# (Save-PSResource / Install-PSResource / Install-Module into that folder), e.g. from a NuGet feed,
# which does not preserve the Linux host's executable bit: the module must restore it at launch.
[CmdletBinding(DefaultParameterSetName = 'Zip')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Zip')][string]$Package,
    [Parameter(Mandatory, ParameterSetName = 'Installed')][string]$ModulesPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ExpectedHostSha256,
    [switch]$Gui,
    [string]$Out
)
$ErrorActionPreference = 'Stop'
$isWin = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$rid = if ($isWin) { 'win-x64' } else { 'linux-x64' }
$work = Join-Path ([IO.Path]::GetTempPath()) ('nhk-install-' + [guid]::NewGuid().ToString('N'))
$modules = if ($ModulesPath) { (Resolve-Path -LiteralPath $ModulesPath).Path } else { Join-Path $work 'Modules' }
if (-not $Out) { $Out = Join-Path $work 'evidence' }
New-Item -ItemType Directory -Force -Path $modules, $Out | Out-Null
$Out = (Resolve-Path -LiteralPath $Out).Path
$checks = New-Object System.Collections.ArrayList
function Check([string]$Name, [bool]$Ok, $Detail) { [void]$checks.Add([ordered]@{ name = $Name; status = $(if ($Ok) { 'PASS' } else { 'FAIL' }); detail = $Detail }) }

if ($Package) {
    Expand-Archive -LiteralPath $Package -DestinationPath $modules
    $moduleBase = Join-Path $modules 'NativeHTMLKit'
    Check 'package expands to Modules/NativeHTMLKit' (Test-Path -LiteralPath (Join-Path $moduleBase 'NativeHTMLKit.psd1')) $null
} else {
    # Package managers install into NativeHTMLKit/<version>/.
    $found = @(Get-ChildItem -LiteralPath (Join-Path $modules 'NativeHTMLKit') -Recurse -Filter 'NativeHTMLKit.psd1' -ErrorAction SilentlyContinue)
    Check 'installed module found under the modules path' ($found.Count -eq 1) @{ manifests = @($found | ForEach-Object { $_.FullName.Substring($modules.Length) }) }
    $moduleBase = $found[0].DirectoryName
}
$hostFile = Join-Path $moduleBase "runtimes/$rid/$(if ($isWin) { 'nativehtmlkit-host.exe' } else { 'nativehtmlkit-host' })"
$execBefore = if ($isWin) { 'n/a' } else { [string](& /usr/bin/stat -c '%a' -- $hostFile) }
$sums = @(Get-Content -LiteralPath (Join-Path $moduleBase 'SHA256SUMS'))
$bad = @(foreach ($line in $sums) { $h, $rel = $line -split '  ', 2; $f = Join-Path $moduleBase $rel; if (-not (Test-Path -LiteralPath $f) -or (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash -ne $h) { $rel } })
Check 'every packaged file matches SHA256SUMS' ($bad.Count -eq 0 -and $sums.Count -gt 10) @{ files = $sums.Count; mismatched = $bad }

$title = 'NHK installed smoke ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$appDir = Join-Path $work 'app'; New-Item -ItemType Directory -Path $appDir | Out-Null
$resultFile = Join-Path $Out 'smoke-app.jsonl'
$app = @"
`$ErrorActionPreference = 'Stop'
Import-Module NativeHTMLKit
`$app = Start-NativeHTMLKitScript -Name 'NHK installed smoke' -Instance multiple
function Emit(`$o) { [IO.File]::AppendAllText('$resultFile', (ConvertTo-Json -InputObject `$o -Compress -Depth 6) + "`n") }
`$m = Get-Module NativeHTMLKit
`$hostPath = Get-NativeHTMLKitHostPath
Emit @{ kind = 'env'; module_base = `$m.ModuleBase; module_version = `$m.Version.ToString(); host_path = `$hostPath
    host_sha256 = (Get-FileHash -LiteralPath `$hostPath -Algorithm SHA256).Hash.ToLowerInvariant(); protocol_version = `$app.Hello.protocol_version
    host_info = `$app.Hello.host; edition = `$PSVersionTable.PSEdition; ps_version = `$PSVersionTable.PSVersion.ToString()
    cargo = [bool](Get-Command cargo -ErrorAction SilentlyContinue); rustc = [bool](Get-Command rustc -ErrorAction SilentlyContinue)
    identity = ((& `$hostPath --version --verbose) | Select-Object -Last 1) }
`$w = New-NativeHTMLKitWindow -Application `$app -Title '$title' -Width 480 -Height 320
`$doc = Open-NativeHTMLKitHtml -Window `$w -Html "<h1 id='h'>Installed</h1><p id='p'>NativeHTMLKit</p>"
Set-NativeHTMLKitDocumentText -Document `$doc -Element p -Text 'from the installed module'
Set-NativeHTMLKitReady -Application `$app
`$state = Get-NativeHTMLKitWindow -Window `$w
Emit @{ kind = 'window'; native = `$state.native; visible = `$state.visible; text = (Get-NativeHTMLKitDocumentText -Document `$doc -Element p) }
`$seen = '$resultFile.seen'
`$clock = [Diagnostics.Stopwatch]::StartNew()
while ('$($Gui.IsPresent)' -eq 'True' -and -not (Test-Path -LiteralPath `$seen) -and `$clock.ElapsedMilliseconds -lt 30000) { [void](Wait-NativeHTMLKit -Application `$app -TimeoutMilliseconds 100) }
`$null = Request-NativeHTMLKitQuit -Application `$app
Wait-NativeHTMLKit -Application `$app -UntilShutdown
Close-NativeHTMLKit -Application `$app
Emit @{ kind = 'exit' }
"@
[IO.File]::WriteAllText((Join-Path $appDir 'app.ps1'), $app, (New-Object Text.UTF8Encoding($true)))

$shell = (Get-Process -Id $PID).Path
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = $shell
$info.UseShellExecute = $false
$info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
$info.WorkingDirectory = $appDir
$info.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $appDir 'app.ps1') + '"'
foreach ($k in @($info.EnvironmentVariables.Keys)) { if ($k -like 'NATIVEHTMLKIT_*' -or $k -like 'UI4ME_*') { $info.EnvironmentVariables.Remove($k) } }
$sep = [IO.Path]::PathSeparator
$info.EnvironmentVariables['PSModulePath'] = $modules + $sep + (Join-Path $PSHOME 'Modules')
$info.EnvironmentVariables['PATH'] = (@($env:PATH -split [regex]::Escape($sep) | Where-Object { $_ -and $_ -notmatch '(?i)[\\/]\.cargo[\\/]|rustup' }) -join $sep)
if (-not $Gui) { $info.EnvironmentVariables['NATIVEHTMLKIT_TEST_MODE'] = '1' }
$clock = [Diagnostics.Stopwatch]::StartNew()
$p = [Diagnostics.Process]::Start($info)
$stdout = $p.StandardOutput.ReadToEndAsync(); $stderr = $p.StandardError.ReadToEndAsync()
$observed = $null
if ($Gui) {
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not $observed -and [DateTime]::UtcNow -lt $deadline -and -not $p.HasExited) {
        if ($isWin) {
            $observed = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -eq $title } | ForEach-Object { @{ pid = $_.Id; title = $_.MainWindowTitle } })[0]
        } else {
            $driver = Join-Path $PSScriptRoot '../tests/native/drive_linux.py'
            $json = & python3 $driver --find $title 2>$null
            if ($json -and $json -ne 'null') { $observed = $json | ConvertFrom-Json }
        }
        if (-not $observed) { Start-Sleep -Milliseconds 300 }
    }
    [IO.File]::WriteAllText("$resultFile.seen", 'seen')
}
$exited = $p.WaitForExit(120000)
if (-not $exited) { try { $p.Kill() } catch { $null = $_ } }
$p.WaitForExit()
[IO.File]::WriteAllText((Join-Path $Out 'smoke-stdout.txt'), $stdout.Result)
[IO.File]::WriteAllText((Join-Path $Out 'smoke-stderr.txt'), $stderr.Result)
$records = @(); if (Test-Path -LiteralPath $resultFile) { $records = @(Get-Content -LiteralPath $resultFile | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }) }
$envRecord = @($records | Where-Object { $_.kind -eq 'env' })[0]
$winRecord = @($records | Where-Object { $_.kind -eq 'window' })[0]
Check 'app exited 0' ($exited -and $p.ExitCode -eq 0) @{ exit_code = $p.ExitCode; seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 2) }
Check 'module imported by name from the fresh module path' ($null -ne $envRecord -and [IO.Path]::GetFullPath($envRecord.module_base) -eq [IO.Path]::GetFullPath($moduleBase)) $envRecord
$expectedHost = [IO.Path]::GetFullPath((Join-Path $moduleBase "runtimes/$rid/$(if ($isWin) { 'nativehtmlkit-host.exe' } else { 'nativehtmlkit-host' })"))
Check 'bundled host used (no override)' ($null -ne $envRecord -and [IO.Path]::GetFullPath($envRecord.host_path) -eq $expectedHost) $null
Check 'bundled host SHA-256 is the expected one' ($null -ne $envRecord -and $envRecord.host_sha256 -eq $ExpectedHostSha256.ToLowerInvariant()) $null
$hostManifest = Get-Content -Raw -LiteralPath (Join-Path $moduleBase 'HOST-MANIFEST.json') | ConvertFrom-Json
$recorded = $hostManifest.hosts.$rid.host_identity
if ($null -ne $recorded) {
    $reported = $null; try { $reported = $envRecord.identity | ConvertFrom-Json } catch { $null = $_ }
    $same = $null -ne $reported -and @('version', 'source_commit', 'source_tree', 'source_dirty', 'source_files_sha256' | Where-Object { [string]$reported.$_ -ne [string]$recorded.$_ }).Count -eq 0
    Check 'host source identity (--version --verbose) matches HOST-MANIFEST.json' $same @{ recorded = $recorded; reported = $reported }
}
if (-not $isWin) { Check 'Linux host executable after launch (restored by the module if the installer dropped the bit)' ([string](& /usr/bin/stat -c '%a' -- $hostFile) -match '^[1-7][0-7][0-7]$' -and ((([Convert]::ToInt32([string](& /usr/bin/stat -c '%a' -- $hostFile), 8)) -band 64) -ne 0)) @{ mode_before = $execBefore; mode_after = [string](& /usr/bin/stat -c '%a' -- $hostFile) } }
Check 'host speaks protocol version 1' ($null -ne $envRecord -and $envRecord.protocol_version -eq 1) $null
Check 'no Rust toolchain reachable from the app' ($null -ne $envRecord -and -not $envRecord.cargo -and -not $envRecord.rustc) $null
Check 'window created and document round-trip works' ($null -ne $winRecord -and $winRecord.text -eq 'from the installed module') $winRecord
if ($Gui) {
    Check 'native window reported by the host' ($null -ne $winRecord -and $winRecord.native -eq $true) $null
    Check 'window observed by the desktop' ($null -ne $observed) $observed
}
Check 'app reached orderly exit' ([bool]@($records | Where-Object { $_.kind -eq 'exit' }).Count) $null
$summary = [ordered]@{ package = $(if ($Package) { (Resolve-Path -LiteralPath $Package).Path } else { "installed:$modules" }); package_sha256 = $(if ($Package) { (Get-FileHash -LiteralPath $Package -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null })
    gui = $Gui.IsPresent; edition = $PSVersionTable.PSEdition; ps_version = $PSVersionTable.PSVersion.ToString(); os = [Environment]::OSVersion.VersionString
    checks = $checks; passed = @($checks | Where-Object { $_.status -eq 'PASS' }).Count; failed = @($checks | Where-Object { $_.status -ne 'PASS' }).Count }
$json = ConvertTo-Json -InputObject $summary -Depth 8
[IO.File]::WriteAllText((Join-Path $Out 'smoke-summary.json'), $json)
$json
if ($Package) { Remove-Item -LiteralPath $modules -Recurse -Force -ErrorAction SilentlyContinue }
exit $(if ($summary.failed -eq 0) { 0 } else { 1 })
