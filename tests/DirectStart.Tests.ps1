# Start-NativeHTMLKitScript: launcher/backend roles, manifests and lifecycle (Pester 5+).
# The integration cases run real scripts through the real native host in its headless
# test mode (NATIVEHTMLKIT_TEST_MODE=1). They need a host binary: NATIVEHTMLKIT_HOST_BINARY
# (or legacy UI4ME_HOST_BINARY), or the host bundled in a staged module; otherwise they are
# skipped, unless NATIVEHTMLKIT_REQUIRE_HOST=1 makes the missing host a failure.
BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    # A qualification run sets NATIVEHTMLKIT_REQUIRE_HOST=1: then a missing host fails the
    # run (reported BLOCKED by the harness) instead of silently skipping the native cases.
    $script:SkipNative = -not (Find-NativeHTMLKitTestHost) -and $env:NATIVEHTMLKIT_REQUIRE_HOST -ne '1'
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module $script:ModuleManifest -Force -ErrorAction Stop
    & (Get-Module NativeHTMLKit) { Initialize-NativeHTMLKitHelper }
    $script:HostBinary = Find-NativeHTMLKitTestHost
    if (-not $script:HostBinary -and $env:NATIVEHTMLKIT_REQUIRE_HOST -eq '1') { throw 'BLOCKED: no native host (set NATIVEHTMLKIT_HOST_BINARY)' }
    $script:Shell = (Get-Process -Id $PID).Path

    function Invoke-DirectScript {
        param([string]$Body, [string[]]$Arguments = @(), [hashtable]$Environment = @{})
        Invoke-NativeHTMLKitDirectScript -Body $Body -Arguments $Arguments -Environment $Environment -HostBinary $script:HostBinary -Root $TestDrive
    }
}

Describe 'Start-NativeHTMLKitScript roles and validation' {
    It 'is exported with help' {
        (Get-Command Start-NativeHTMLKitScript -Module NativeHTMLKit).Name | Should -Be 'Start-NativeHTMLKitScript'
        (Get-Help Start-NativeHTMLKitScript).Synopsis | Should -Match 'native host'
    }
    It 'refuses incomplete or looping host environments' {
        $saved = @{}
        foreach ($k in 'UI4ME_ENDPOINT', 'UI4ME_TOKEN', 'UI4ME_DIRECT_START') { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }
        try {
            foreach ($case in @(@{ UI4ME_ENDPOINT = 'x' }, @{ UI4ME_TOKEN = 'x' }, @{ UI4ME_DIRECT_START = '1' })) {
                foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $null) }
                foreach ($k in $case.Keys) { [Environment]::SetEnvironmentVariable($k, $case[$k]) }
                { Start-NativeHTMLKitScript -ScriptPath $PSCommandPath } | Should -Throw
            }
        } finally {
            foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
        }
    }
    It 'validates options before starting anything' {
        { Start-NativeHTMLKitScript -AppId 'noperiod' } | Should -Throw
        { Start-NativeHTMLKitScript -AppId 'org.1bad' } | Should -Throw
        { Start-NativeHTMLKitScript -Name "tab`tname" } | Should -Throw
        { Start-NativeHTMLKitScript -Instance many } | Should -Throw
        { Start-NativeHTMLKitScript -MaxWindows 0 } | Should -Throw
    }
    It 'writes TOML strings that keep Unicode, quotes and backslashes' {
        $module = Get-Module NativeHTMLKit
        $value = & $module { ConvertTo-NativeHTMLKitTomlString ('C:\Zoë\"q"' + [char]9 + '😀') }
        $value | Should -BeExactly ('"C:\\Zoë\\\"q\"\u0009😀"')
    }
    It 'derives a stable, valid identity per script' {
        $module = Get-Module NativeHTMLKit
        $a = & $module { Get-NativeHTMLKitDefaultAppId -ScriptPath '/home/a/app.ps1' -Label 'Café app' }
        $b = & $module { Get-NativeHTMLKitDefaultAppId -ScriptPath '/home/b/app.ps1' -Label 'Café app' }
        $a | Should -Match '^local\.nativehtmlkit\.Cafe-app\.h[0-9a-f]{12}$'
        $a | Should -Not -Be $b
        (& $module { Get-NativeHTMLKitDefaultAppId -ScriptPath '/x.ps1' -Label '日本語' }) | Should -Match '^local\.nativehtmlkit\.app\.h'
        (& $module { Get-NativeHTMLKitDefaultAppId -ScriptPath '/x.ps1' -Label '123' }) | Should -Match '^local\.nativehtmlkit\.app-123\.h'
    }
    It 'quotes Windows command-line arguments like CommandLineToArgvW' {
        [NativeHTMLKit.HostProcess]::QuoteWindowsArgument('plain') | Should -BeExactly 'plain'
        [NativeHTMLKit.HostProcess]::QuoteWindowsArgument('') | Should -BeExactly '""'
        [NativeHTMLKit.HostProcess]::QuoteWindowsArgument('a b') | Should -BeExactly '"a b"'
        [NativeHTMLKit.HostProcess]::QuoteWindowsArgument('say "hi"') | Should -BeExactly '"say \"hi\""'
        [NativeHTMLKit.HostProcess]::QuoteWindowsArgument('C:\dir with space\') | Should -BeExactly '"C:\dir with space\\"'
    }
    It 'relays host records as plain text' {
        $out = New-Object IO.StringWriter; $err = New-Object IO.StringWriter
        [NativeHTMLKit.HostProcess]::RelayLine('{"level":"INFO","fields":{"message":"backend output","source":"backend","stream":"stdout","text":"Příliš"}}', $false, $out, $err)
        [NativeHTMLKit.HostProcess]::RelayLine('{"level":"INFO","fields":{"message":"window created"}}', $false, $out, $err)
        [NativeHTMLKit.HostProcess]::RelayLine('{"level":"ERROR","fields":{"message":"application failed","reason":"x"}}', $false, $out, $err)
        [NativeHTMLKit.HostProcess]::RelayLine('nativehtmlkit-host: plain failure', $false, $out, $err)
        $out.ToString().Trim() | Should -BeExactly 'Příliš'
        $lines = @($err.ToString().Trim() -split "\r?\n")
        $lines | Should -Be @('nativehtmlkit-host error: application failed (reason=x)', 'nativehtmlkit-host: plain failure')
    }
}

Describe 'Start-NativeHTMLKitScript with the real native host (headless test mode)' -Skip:$script:SkipNative {
    BeforeAll {
        $script:AppBody = @'
param([string]$Greeting = 'none', [string]$Other)
$ErrorActionPreference = 'Stop'
Import-Module '__MODULE__'
# Exact Unicode on every platform: in a process without a console, Windows PowerShell's
# own output (Write-Output, Write-Host) uses a legacy code page; [Console]::Out follows
# the UTF-8 encoding that Start-NativeHTMLKitScript selects for the app process.
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
"ROLE $(if ($env:UI4ME_ENDPOINT) { 'backend' } else { 'launcher' })"
$app = Start-NativeHTMLKitScript -Name 'Direct test' -Instance multiple
[Console]::Out.WriteLine("PARAMS [$Greeting] [$Other] secret=$([bool]$env:UI4ME_TOKEN)")
$window = New-NativeHTMLKitWindow -Application $app -Title 'Direct test'
$doc = Open-NativeHTMLKitHtml -Window $window -Html "<p id='t'>Hello Příliš</p>"
[Console]::Out.WriteLine("TEXT $(Get-NativeHTMLKitDocumentText -Document $doc -Element t)")
if ($Greeting -eq 'crash') { throw 'deliberate failure' }
Set-NativeHTMLKitReady -Application $app
$null = Request-NativeHTMLKitQuit -Application $app
Wait-NativeHTMLKit -Application $app -UntilShutdown
Close-NativeHTMLKit -Application $app
[Console]::Error.WriteLine('ORDERLY')
'@
    }
    It 'runs the script twice, keeps its arguments and exits cleanly' {
        $r = Invoke-DirectScript -Body $script:AppBody -Arguments @('-Greeting', 'hello world', '-Other', 'Ünï "q"')
        $r.ExitCode | Should -Be 0 -Because $r.Err
        $lines = @($r.Out -split "\r?\n" | Where-Object { $_ })
        $lines[0..1] | Should -Be @('ROLE launcher', 'ROLE backend')
        $lines | Should -Contain 'PARAMS [hello world] [Ünï "q"] secret=False'
        $lines | Should -Contain 'TEXT Hello Příliš'
        $r.Err | Should -Match 'ORDERLY'
        $r.Err | Should -Not -Match '"level"'
    }
    It 'reports a backend error and a nonzero exit code' {
        $r = Invoke-DirectScript -Body $script:AppBody -Arguments @('-Greeting', 'crash')
        $r.ExitCode | Should -Not -Be 0
        $r.Err | Should -Match 'deliberate failure'
        $r.Err | Should -Match 'nativehtmlkit-host error: application failed'
    }
    It 'fails clearly when the host is missing' {
        $r = Invoke-DirectScript -Body $script:AppBody -Environment @{ NATIVEHTMLKIT_HOST_BINARY = (Join-Path $TestDrive 'missing-host') }
        $r.ExitCode | Should -Not -Be 0
        $r.Err | Should -Match 'NATIVEHTMLKIT_HOST_BINARY does not exist'
        @($r.Out -split "\r?\n" | Where-Object { $_ }) | Should -Be @('ROLE launcher')
    }
    It 'removes its temporary manifest' {
        $r = Invoke-DirectScript -Body $script:AppBody
        $r.ExitCode | Should -Be 0
        @($r.Leftovers | Where-Object { $_ -like 'nativehtmlkit-start-*' }).Count | Should -Be 0
    }
}
