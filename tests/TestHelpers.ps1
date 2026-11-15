# Dot-sourced by the Pester suites (Pester 5+).
# NATIVEHTMLKIT_TEST_MODULE tests a staged or installed module instead of the source tree.
$script:ModuleManifest = if ($env:NATIVEHTMLKIT_TEST_MODULE) { (Resolve-Path $env:NATIVEHTMLKIT_TEST_MODULE).Path } else { (Resolve-Path (Join-Path $PSScriptRoot '../NativeHTMLKit/NativeHTMLKit.psd1')).Path }
$script:TestIsWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT

$script:MockToken = '5a1e7c0de5a1e7c0de5a1e7c0de5a1e7c0de5a1e7c0de5a1e7c0de5a1e7c0de0'   # the 64-hex shape the host issues

function Start-MockHost([string]$Token = $script:MockToken) {
    $name = [guid]::NewGuid().ToString('N')
    $endpoint = if ($script:TestIsWindows) { '\\.\pipe\ui4me-test-' + $name } else { Join-Path ([IO.Path]::GetTempPath()) ('ui4me-' + $name.Substring(0, 12) + '.sock') }
    $ready = Join-Path ([IO.Path]::GetTempPath()) ('ui4me-ready-' + $name)
    $exe = (Get-Process -Id $PID).Path
    $mock = Join-Path $PSScriptRoot 'MockHost.ps1'
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $mock + '"'),
        '-Endpoint', ('"' + $endpoint + '"'), '-ReadyFile', ('"' + $ready + '"'), '-ModulePath', ('"' + $script:ModuleManifest + '"'), '-Token', ('"' + $Token + '"'), '-Tag', $name.Substring(0, 12))
    $log = Join-Path ([IO.Path]::GetTempPath()) ('ui4me-mock-' + $name + '.log')
    $launch = @{ FilePath = $exe; ArgumentList = $arguments; PassThru = $true; RedirectStandardError = $log }
    if ($script:TestIsWindows) { $launch.WindowStyle = 'Hidden' }
    $process = Start-Process @launch
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    while (-not (Test-Path -LiteralPath $ready) -and [DateTime]::UtcNow -lt $deadline -and -not $process.HasExited) { Start-Sleep -Milliseconds 25 }
    if (-not (Test-Path -LiteralPath $ready)) {
        $detail = if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Raw } else { '' }
        throw "Mock host failed to start: $detail"
    }
    return [pscustomobject]@{ Process = $process; Endpoint = $endpoint; Ready = $ready; Log = $log; Tag = $name.Substring(0, 12) }
}

function Stop-MockHost($Mock) {
    # Also removes what a killed mock could not: its Unix socket and its bitmap files.
    if ($null -eq $Mock) { return }
    if (-not $Mock.Process.WaitForExit(5000)) { Stop-Process -Id $Mock.Process.Id -Force -ErrorAction SilentlyContinue; [void]$Mock.Process.WaitForExit(5000) }
    Remove-Item -LiteralPath $Mock.Ready, $Mock.Log -Force -ErrorAction SilentlyContinue
    if (-not $script:TestIsWindows) { Remove-Item -LiteralPath $Mock.Endpoint -Force -ErrorAction SilentlyContinue }
    Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter ('ui4me-mock-' + $Mock.Tag + '-*') -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}

function Wait-Until([scriptblock]$Condition, $Application, [int]$Seconds = 5) {
    $end = [DateTime]::UtcNow.AddSeconds($Seconds)
    while (-not (& $Condition) -and [DateTime]::UtcNow -lt $end) { [void](Wait-NativeHTMLKit -Application $Application -TimeoutMilliseconds 20) }
    return [bool](& $Condition)
}

function Find-NativeHTMLKitTestHost {
    # NATIVEHTMLKIT_HOST_BINARY / UI4ME_HOST_BINARY, else the host bundled in the module
    # under test (a staged package), else nothing. Never searches PATH.
    foreach ($candidate in @($env:NATIVEHTMLKIT_HOST_BINARY, $env:UI4ME_HOST_BINARY)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return [IO.Path]::GetFullPath($candidate) }
    }
    $rid = if ($script:TestIsWindows) { 'win-x64/nativehtmlkit-host.exe' } else { 'linux-x64/nativehtmlkit-host' }
    $bundled = Join-Path (Split-Path -Parent $script:ModuleManifest) "runtimes/$rid"
    if (Test-Path -LiteralPath $bundled -PathType Leaf) { return [IO.Path]::GetFullPath($bundled) }
    return $null
}

function Invoke-NativeHTMLKitDirectScript {
# Runs a script the way a user does (pwsh -File / powershell.exe -File) with the real host in
# headless test mode, a private TEMP, and a clean NATIVEHTMLKIT_*/UI4ME_* environment.
param([string]$Body, [string[]]$Arguments = @(), [hashtable]$Environment = @{}, [string]$HostBinary, [string]$Root, [int]$TimeoutSeconds = 120)
    $folder = Join-Path $Root ('direct ü ' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    [void](New-Item -ItemType Directory -Path $folder)
    $script = Join-Path $folder 'app.ps1'
    $text = $Body.Replace('__MODULE__', $script:ModuleManifest.Replace("'", "''"))
    [IO.File]::WriteAllText($script, $text, (New-Object Text.UTF8Encoding($true)))
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = (Get-Process -Id $PID).Path
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $info.WorkingDirectory = $folder
    $all = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script) + $Arguments
    $info.Arguments = (@($all | ForEach-Object { [NativeHTMLKit.HostProcess]::QuoteWindowsArgument($_) }) -join ' ')
    foreach ($k in @($info.EnvironmentVariables.Keys)) { if ($k -like 'NativeHTMLKit_*' -or $k -like 'UI4ME_*') { $info.EnvironmentVariables.Remove($k) } }
    $info.EnvironmentVariables['NATIVEHTMLKIT_TEST_MODE'] = '1'
    $info.EnvironmentVariables['NATIVEHTMLKIT_HOST_BINARY'] = $HostBinary
    # A private temporary folder: the launcher's manifest must appear and vanish only there.
    $temp = Join-Path $folder 'tmp'
    [void](New-Item -ItemType Directory -Path $temp)
    foreach ($k in 'TMPDIR', 'TEMP', 'TMP') { $info.EnvironmentVariables[$k] = $temp }
    foreach ($k in $Environment.Keys) { $info.EnvironmentVariables[$k] = $Environment[$k] }
    $process = [Diagnostics.Process]::Start($info)
    $stderr = $process.StandardError.ReadToEndAsync()
    $stdout = $process.StandardOutput.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { try { $process.Kill() } catch { $null = $_ }; throw "Direct-start script did not finish within $TimeoutSeconds s" }
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Out = $stdout.Result; Err = $stderr.Result; Folder = $folder
        Leftovers = @(Get-ChildItem -LiteralPath $temp -Force | ForEach-Object Name) }
}
