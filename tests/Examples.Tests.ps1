# Runs every example under examples/ the way a user does (pwsh -File / powershell.exe -File),
# with the real native host in its headless test mode (NATIVEHTMLKIT_TEST_MODE=1) and the
# example's -SelfTest switch. Each example drives itself through the public API, prints
# 'SELFTEST PASS <name>' and requests a quit. A case passes when the example
#   * exits with code 0 and prints its PASS line,
#   * writes no error, exception, warning or failed-callback text to stderr,
#   * leaves no host or backend process behind and removes its launch manifest.
# Headless: this proves startup, document state read back through the API, background
# work and clean shutdown. It is NOT evidence of native input, painting or dialogs.
# Needs a host (NATIVEHTMLKIT_HOST_BINARY or a staged module); skipped otherwise unless
# NATIVEHTMLKIT_REQUIRE_HOST=1.
BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:SkipNative = -not (Find-NativeHTMLKitTestHost) -and $env:NATIVEHTMLKIT_REQUIRE_HOST -ne '1'
    $examplesRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'examples'
    $script:ExampleCases = @(
        @(Get-ChildItem -LiteralPath $examplesRoot -Filter '*.ps1' -File) +
        @(Get-ChildItem -LiteralPath $examplesRoot -Directory | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter 'app.ps1' -File })
    ) | Sort-Object FullName | ForEach-Object {
        $name = if ($_.Name -eq 'app.ps1') { $_.Directory.Name } else { $_.BaseName }
        @{ Name = $name; Path = $_.FullName }
    }
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module $script:ModuleManifest -Force -ErrorAction Stop
    & (Get-Module NativeHTMLKit) { Initialize-NativeHTMLKitHelper }
    $script:HostBinary = Find-NativeHTMLKitTestHost
    if (-not $script:HostBinary -and $env:NATIVEHTMLKIT_REQUIRE_HOST -eq '1') { throw 'BLOCKED: no native host (set NATIVEHTMLKIT_HOST_BINARY)' }
    # Examples use `Import-Module NativeHTMLKit`; the folder that holds the module under test
    # goes first on PSModulePath so that exact copy is the one they load.
    $script:ModuleParent = Split-Path -Parent (Split-Path -Parent $script:ModuleManifest)

    function Get-NhkProcessLines {
        # Id + command line of every process this user can see.
        if ($script:TestIsWindows) {
            return @(Get-CimInstance -ClassName Win32_Process | ForEach-Object { [pscustomobject]@{ Id = [int]$_.ProcessId; CommandLine = [string]$_.CommandLine } })
        }
        $lines = foreach ($dir in [IO.Directory]::GetDirectories('/proc')) {
            $leaf = [IO.Path]::GetFileName($dir)
            if ($leaf -notmatch '^\d+$') { continue }
            try { $raw = [IO.File]::ReadAllText((Join-Path $dir 'cmdline')) } catch { continue }
            [pscustomobject]@{ Id = [int]$leaf; CommandLine = $raw.Replace([char]0, ' ') }
        }
        return @($lines)
    }

    function Invoke-Example {
        param([string]$Path, [string[]]$Arguments = @('-SelfTest'), [int]$TimeoutSeconds = 180)
        $temp = Join-Path $TestDrive ('tmp-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        [void](New-Item -ItemType Directory -Path $temp)
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = (Get-Process -Id $PID).Path
        $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
        $info.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
        $info.WorkingDirectory = Split-Path -Parent $Path
        $all = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Path) + $Arguments
        $info.Arguments = (@($all | ForEach-Object { [NativeHTMLKit.HostProcess]::QuoteWindowsArgument($_) }) -join ' ')
        foreach ($k in @($info.EnvironmentVariables.Keys)) { if ($k -like 'NativeHTMLKit_*' -or $k -like 'UI4ME_*') { $info.EnvironmentVariables.Remove($k) } }
        $info.EnvironmentVariables['NATIVEHTMLKIT_TEST_MODE'] = '1'
        $info.EnvironmentVariables['NATIVEHTMLKIT_HOST_BINARY'] = $script:HostBinary
        $info.EnvironmentVariables['PSModulePath'] = $script:ModuleParent + [IO.Path]::PathSeparator + [string]$info.EnvironmentVariables['PSModulePath']
        foreach ($k in 'TMPDIR', 'TEMP', 'TMP') { $info.EnvironmentVariables[$k] = $temp }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $process = [Diagnostics.Process]::Start($info)
        $stderr = $process.StandardError.ReadToEndAsync()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { try { $process.Kill() } catch { $null = $_ }; throw "Example did not finish within $TimeoutSeconds s: $Path" }
        $process.WaitForExit()
        # The launcher waits for the host and the host for its backend; allow a moment for
        # process teardown, then anything still mentioning this run is an orphan.
        $orphans = @()
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            $orphans = @(Get-NhkProcessLines | Where-Object { $_.Id -ne $PID -and $_.CommandLine -and ($_.CommandLine.Contains($temp) -or $_.CommandLine.Contains($Path)) })
            if ($orphans.Count -eq 0) { break }
            Start-Sleep -Milliseconds 200
        } while ([DateTime]::UtcNow -lt $deadline)
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Out = $stdout.Result; Err = $stderr.Result
            Orphans = $orphans; Leftovers = @(Get-ChildItem -LiteralPath $temp -Force | Where-Object { $_.Name -like 'nativehtmlkit-start-*' } | ForEach-Object Name)
            Seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1) }
    }
}

Describe 'Examples run against the real host (headless self-test)' -Skip:$script:SkipNative {
    It '<Name> passes its self-test and exits cleanly' -ForEach $script:ExampleCases {
        $r = Invoke-Example -Path $Path
        $detail = "exit=$($r.ExitCode) seconds=$($r.Seconds)`nSTDOUT:`n$($r.Out)`nSTDERR:`n$($r.Err)"
        $r.ExitCode | Should -Be 0 -Because $detail
        $r.Out | Should -Match ('(?m)^SELFTEST PASS ' + [regex]::Escape($Name) + '\s*$') -Because $detail
        $r.Err | Should -Not -Match '(?i)error|exception|warning|failed' -Because $detail
        @($r.Orphans).Count | Should -Be 0 -Because ('orphan processes: ' + (@($r.Orphans | ForEach-Object { "$($_.Id) $($_.CommandLine)" }) -join '; '))
        @($r.Leftovers).Count | Should -Be 0
    }
}

Describe 'Every example is valid for Windows PowerShell 5.1 and PowerShell 7' {
    It '<Name> parses, is ASCII or UTF-8 with BOM, and avoids PowerShell 7-only syntax' -ForEach $script:ExampleCases {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        if (-not $bom) { @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0 -Because 'Windows PowerShell 5.1 reads BOM-less scripts in the ANSI code page' }
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
        # Operators that Windows PowerShell 5.1 cannot parse: ternary ?:, ?? and ??=, && and ||, ?. and ?[].
        $modern = @($tokens | Where-Object { $_.Kind -in @('QuestionMark', 'QuestionQuestion', 'QuestionQuestionEquals', 'AndAnd', 'OrOr', 'QuestionDot', 'QuestionLBracket') })
        $modern.Count | Should -Be 0 -Because (($modern | ForEach-Object { "$($_.Text) at line $($_.Extent.StartLineNumber)" }) -join ', ')
        # Variables that do not exist in Windows PowerShell 5.1.
        $vars = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.VariableExpressionAst] }, $true) | Where-Object { $_.VariablePath.UserPath -in @('IsWindows', 'IsLinux', 'IsMacOS', 'IsCoreCLR') })
        $vars.Count | Should -Be 0
    }
}

Describe 'Generated projects run against the real host' -Skip:$script:SkipNative {
    It 'New-NativeHTMLKitProject output starts, reaches ready and quits cleanly' {
        $folder = Join-Path $TestDrive 'generated app'
        $null = New-NativeHTMLKitProject -Path $folder -Name 'Generated App' -AppId 'org.example.GeneratedApp'
        $app = Join-Path $folder 'app.ps1'
        # The scaffold waits for the user to close the window; replace that one wait by a
        # read-back, a quit request and the same wait.
        $text = [IO.File]::ReadAllText($app)
        $text = $text.Replace('Wait-NativeHTMLKit -Application $app -UntilShutdown',
            "[Console]::Out.WriteLine('SELFTEST PASS generated ' + (Get-NativeHTMLKitDocumentText -Document `$doc -Element result))`n`$null = Request-NativeHTMLKitQuit -Application `$app`nWait-NativeHTMLKit -Application `$app -UntilShutdown")
        [IO.File]::WriteAllText($app, $text, (New-Object Text.UTF8Encoding($true)))
        $r = Invoke-Example -Path $app -Arguments @()
        $detail = "STDOUT:`n$($r.Out)`nSTDERR:`n$($r.Err)"
        $r.ExitCode | Should -Be 0 -Because $detail
        $r.Out | Should -Match 'SELFTEST PASS generated Ready\.' -Because $detail
        @($r.Orphans).Count | Should -Be 0
    }
}

Describe 'Tutorial checkpoints run against the real host' -Skip:$script:SkipNative {
    It 'the step 3 skeleton of docs/tutorials/bulk-rename.md loads the page and quits cleanly' {
        $root = Split-Path -Parent $PSScriptRoot
        $tutorial = [IO.File]::ReadAllText((Join-Path $root 'docs/tutorials/bulk-rename.md'))
        $match = [regex]::Match($tutorial, '```powershell title="app\.ps1 \(step 3\)"\r?\n(?<code>.*?)```', 'Singleline')
        $match.Success | Should -BeTrue
        $folder = Join-Path $TestDrive 'tutorial step 3'
        $null = New-Item -ItemType Directory -Path $folder
        foreach ($f in 'index.html', 'style.css') { Copy-Item -LiteralPath (Join-Path $root "examples/bulk-rename/$f") -Destination $folder }
        $code = $match.Groups['code'].Value.Replace('Wait-NativeHTMLKit -Application $app -UntilShutdown',
            "[Console]::Out.WriteLine('SELFTEST PASS tutorial ' + (Get-NativeHTMLKitDocumentText -Document `$doc -Element summary))`n    `$null = Request-NativeHTMLKitQuit -Application `$app`n    Wait-NativeHTMLKit -Application `$app -UntilShutdown")
        $app = Join-Path $folder 'app.ps1'
        [IO.File]::WriteAllText($app, $code, (New-Object Text.UTF8Encoding($true)))
        $r = Invoke-Example -Path $app -Arguments @()
        $detail = "STDOUT:`n$($r.Out)`nSTDERR:`n$($r.Err)"
        $r.ExitCode | Should -Be 0 -Because $detail
        $r.Out | Should -Match 'SELFTEST PASS tutorial Choose a folder to begin\.' -Because $detail
        @($r.Orphans).Count | Should -Be 0
    }
}
