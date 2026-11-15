# End-to-end behavior with the REAL native host in its headless test mode: diagnostics
# propagation across launcher -> host -> backend, the "Submit did nothing" correlation,
# multiple windows, rapid open/close, stale handles, throwing policies and host death.
# Needs a host (NATIVEHTMLKIT_HOST_BINARY or a staged module); skipped otherwise unless
# NATIVEHTMLKIT_REQUIRE_HOST=1. Headless: this is protocol/lifecycle evidence, NOT GUI evidence.
BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:SkipNative = -not (Find-NativeHTMLKitTestHost) -and $env:NATIVEHTMLKIT_REQUIRE_HOST -ne '1'
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module $script:ModuleManifest -Force -ErrorAction Stop
    & (Get-Module NativeHTMLKit) { Initialize-NativeHTMLKitHelper }
    $script:HostBinary = Find-NativeHTMLKitTestHost
    if (-not $script:HostBinary -and $env:NATIVEHTMLKIT_REQUIRE_HOST -eq '1') { throw 'BLOCKED: no native host (set NATIVEHTMLKIT_HOST_BINARY)' }
    $script:Sentinel = 'NHKSENTINEL5e2b71'
    function Invoke-App([string]$Body, [hashtable]$Environment = @{}, [int]$TimeoutSeconds = 120) {
        $text = "`$ErrorActionPreference = 'Stop'`nImport-Module '__MODULE__'`n[Console]::OutputEncoding = New-Object Text.UTF8Encoding(`$false)`n" + $Body
        Invoke-NativeHTMLKitDirectScript -Body $text -Environment $Environment -HostBinary $script:HostBinary -Root $TestDrive -TimeoutSeconds $TimeoutSeconds
    }
    function Get-Lines($Result, [string]$Prefix) { return ,@($Result.Out -split "\r?\n" | Where-Object { $_.StartsWith($Prefix) }) }
    function Read-Bundle([string]$Zip) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $dir = Join-Path $TestDrive ('b-' + [guid]::NewGuid().ToString('N'))
        [IO.Compression.ZipFile]::ExtractToDirectory($Zip, $dir)
        $text = (Get-ChildItem -LiteralPath $dir -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
        $timeline = @(Get-Content -LiteralPath (Join-Path $dir 'timeline.jsonl') | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        [pscustomobject]@{ Text = $text; Timeline = $timeline; Manifest = (Get-Content -Raw -LiteralPath (Join-Path $dir 'manifest.json') | ConvertFrom-Json) }
    }
    # Runs the host directly (`run --app --headless`) with a PowerShell backend script and returns
    # the host's RAW stderr (JSON records), which the direct-start relay would reformat.
    function Invoke-RawHost([string]$Body, [hashtable]$Environment = @{}) {
        $folder = Join-Path $TestDrive ('raw ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $folder
        $backend = Join-Path $folder 'backend.ps1'
        [IO.File]::WriteAllText($backend, "`$ErrorActionPreference = 'Stop'`nImport-Module '$($script:ModuleManifest)'`n" + $Body.Replace('__OUT__', $folder), (New-Object Text.UTF8Encoding($true)))
        $q = { param($s) '"' + $s.Replace('\', '\\').Replace('"', '\"') + '"' }
        $shell = (Get-Process -Id $PID).Path
        $toml = Join-Path $folder 'app.toml'
        [IO.File]::WriteAllText($toml, "[app]`nid = `"org.example.RawHost`"`nname = `"Raw`"`n[backend]`nprogram = $(& $q $shell)`nargs = [`"-NoProfile`", `"-NonInteractive`", `"-ExecutionPolicy`", `"Bypass`", `"-File`", $(& $q $backend)]`ncwd = $(& $q $folder)`n[host]`ninstance = `"multiple`"`n")
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $script:HostBinary
        $info.Arguments = "run --app `"$toml`" --headless"
        $info.UseShellExecute = $false; $info.RedirectStandardError = $true
        foreach ($k in @($info.EnvironmentVariables.Keys)) { if ($k -like 'NativeHTMLKit_*' -or $k -like 'UI4ME_*') { $info.EnvironmentVariables.Remove($k) } }
        $info.EnvironmentVariables['UI4ME_TEST_MODE'] = '1'
        foreach ($k in $Environment.Keys) { $info.EnvironmentVariables[$k] = $Environment[$k] }
        $p = [Diagnostics.Process]::Start($info)
        $stderr = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(120000)) { $p.Kill(); throw 'raw host run did not finish' }
        $p.WaitForExit()
        $records = @($stderr.Result -split "\r?\n" | Where-Object { $_.StartsWith('{') } | ForEach-Object { $_ | ConvertFrom-Json })
        [pscustomobject]@{ ExitCode = $p.ExitCode; Stderr = $stderr.Result; Records = $records; Folder = $folder }
    }
    # Sends a decision reply the host never asked for. The host logs it only at debug/trace
    # ("ignored stale decision response"), which proves which filter the host applied.
    $script:StaleDecision = '$app.Transport.Send(@{ jsonrpc = ''2.0''; id = ''nhk-unsolicited''; result = @{ allow = $true } }); $null = Get-NativeHTMLKitWindowList -Application $app'
}

Describe 'Diagnostics propagation through the real host' -Skip:$script:SkipNative {
    It 'Start-NativeHTMLKitScript -Diagnostics Trace reaches the host and the backend with one session ID' {
        $body = @"
"LAUNCHER session=`$((Get-NativeHTMLKitDiagnosticReport).SessionId)"
`$app = Start-NativeHTMLKitScript -Name 'Diag' -Instance multiple -Diagnostics Trace
[Console]::Out.WriteLine("BACKEND session=`$((Get-NativeHTMLKitDiagnosticReport).SessionId) level=`$env:NATIVEHTMLKIT_DIAGNOSTICS")
`$w = New-NativeHTMLKitWindow -Application `$app -Title 'diag'
$($script:StaleDecision)
`$null = Request-NativeHTMLKitQuit -Application `$app
Wait-NativeHTMLKit -Application `$app -UntilShutdown
Close-NativeHTMLKit -Application `$app
"@
        $r = Invoke-App $body @{ NATIVEHTMLKIT_VERBOSE = '1' }
        $r.ExitCode | Should -Be 0 -Because $r.Err
        $launcher = (Get-Lines $r 'LAUNCHER session=')[0] -replace '^LAUNCHER session=', ''
        $launcher | Should -Match '^nhk-ps-[0-9a-f]{32}$'
        (Get-Lines $r 'BACKEND ')[0] | Should -Be "BACKEND session=$launcher level=trace"
        $r.Err | Should -Match 'nativehtmlkit-host debug: ignored stale decision response'
    }

    It 'leaves the host at its normal level without -Diagnostics' {
        $body = @"
`$app = Start-NativeHTMLKitScript -Name 'Diag' -Instance multiple
[Console]::Out.WriteLine("BACKEND level=[`$env:NATIVEHTMLKIT_DIAGNOSTICS]")
`$w = New-NativeHTMLKitWindow -Application `$app -Title 'diag'
$($script:StaleDecision)
`$null = Request-NativeHTMLKitQuit -Application `$app
Wait-NativeHTMLKit -Application `$app -UntilShutdown
Close-NativeHTMLKit -Application `$app
"@
        $r = Invoke-App $body @{ NATIVEHTMLKIT_VERBOSE = '1' }
        $r.ExitCode | Should -Be 0 -Because $r.Err
        (Get-Lines $r 'BACKEND ')[0] | Should -Be 'BACKEND level=[]'
        $r.Err | Should -Match 'nativehtmlkit-host info: host started'
        $r.Err | Should -Not -Match 'nativehtmlkit-host debug:'
    }

    It 'tags every host record with the session ID the SDK reports' {
        $folder = Join-Path $TestDrive 'raw host'
        $null = New-Item -ItemType Directory -Path $folder
        $backend = Join-Path $folder 'backend.ps1'
        $out = Join-Path $folder 'backend-session.txt'
        [IO.File]::WriteAllText($backend, @"
`$ErrorActionPreference = 'Stop'
Import-Module '$($script:ModuleManifest)'
`$app = Connect-NativeHTMLKit
[IO.File]::WriteAllText('$out', (Get-NativeHTMLKitDiagnosticReport).SessionId)
`$w = New-NativeHTMLKitWindow -Application `$app -Title 'raw'
`$null = Request-NativeHTMLKitQuit -Application `$app
Wait-NativeHTMLKit -Application `$app -UntilShutdown
Close-NativeHTMLKit -Application `$app
"@, (New-Object Text.UTF8Encoding($true)))
        $shell = (Get-Process -Id $PID).Path
        $toml = Join-Path $folder 'app.toml'
        $q = { param($s) '"' + $s.Replace('\', '\\').Replace('"', '\"') + '"' }
        [IO.File]::WriteAllText($toml, "[app]`nid = `"org.example.RawDiag`"`nname = `"Raw`"`n[backend]`nprogram = $(& $q $shell)`nargs = [`"-NoProfile`", `"-NonInteractive`", `"-ExecutionPolicy`", `"Bypass`", `"-File`", $(& $q $backend)]`ncwd = $(& $q $folder)`n[host]`ninstance = `"multiple`"`n")
        $session = 'nhk-raw.' + [guid]::NewGuid().ToString('N') + ':1'
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $script:HostBinary
        $info.Arguments = "run --app `"$toml`" --headless"
        $info.UseShellExecute = $false; $info.RedirectStandardError = $true
        $info.EnvironmentVariables['NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID'] = $session
        $info.EnvironmentVariables['UI4ME_TEST_MODE'] = '1'
        $p = [Diagnostics.Process]::Start($info)
        $stderr = $p.StandardError.ReadToEndAsync()
        $p.WaitForExit(120000) | Should -BeTrue
        $p.WaitForExit()
        $p.ExitCode | Should -Be 0 -Because $stderr.Result
        [IO.File]::ReadAllText($out) | Should -Be $session
        $records = @($stderr.Result -split "\r?\n" | Where-Object { $_.StartsWith('{') } | ForEach-Object { $_ | ConvertFrom-Json })
        $records.Count | Should -BeGreaterThan 0
        @($records | Where-Object { $_.diagnostic_session_id -ne $session }).Count | Should -Be 0
    }
}

Describe 'The "Submit did nothing" scenario with the real host' -Skip:$script:SkipNative {
    BeforeAll {
        $script:SubmitApp = @"
`$app = Start-NativeHTMLKitScript -Name 'Submit' -Instance multiple
`$w = New-NativeHTMLKitWindow -Application `$app -Title 'submit'
`$doc = Open-NativeHTMLKitHtml -Window `$w -Html "<form id='f'><input id='name' name='name' value='$($script:Sentinel)-value'><button id='go' type='submit'>Save</button></form><p id='status'>idle</p>"
Set-NativeHTMLKitDocumentValue -Document `$doc -Element name -Value '$($script:Sentinel)-typed'
`$script:done = `$false
`$null = Register-NativeHTMLKitDocumentEvent -Document `$doc -Type submit -Element f -Callback {
    `$data = Get-NativeHTMLKitFormData -Document `$doc -Form f
    Set-NativeHTMLKitDocumentText -Document `$doc -Element status -Text 'Saving'
    `$null = Start-NativeHTMLKitTask -Application `$app -ArgumentList @([string](`$data.entries[0].value)) -ScriptBlock { param(`$v) Start-Sleep -Milliseconds 100; `$v.Length } -OnCompleted {
        param(`$n) Set-NativeHTMLKitDocumentText -Document `$doc -Element status -Text "Saved `$(`$n[0])"; `$script:done = `$true }
}
Set-NativeHTMLKitReady -Application `$app
`$null = Submit-NativeHTMLKitForm -Document `$doc -Form f
`$clock = [Diagnostics.Stopwatch]::StartNew()
while (-not `$script:done -and `$clock.ElapsedMilliseconds -lt 15000) { [void](Wait-NativeHTMLKit -Application `$app -TimeoutMilliseconds 50) }
[Console]::Out.WriteLine("STATUS `$(Get-NativeHTMLKitDocumentText -Document `$doc -Element status)")
`$null = Export-NativeHTMLKitSupportBundle -Path `$env:NHK_BUNDLE -Application `$app
`$null = Request-NativeHTMLKitQuit -Application `$app
Wait-NativeHTMLKit -Application `$app -UntilShutdown
Close-NativeHTMLKit -Application `$app
"@
    }
    It 'correlates session, host event, submit callback, RPCs, task and UI update at trace level' {
        $zip = Join-Path $TestDrive 'submit-trace.zip'
        $r = Invoke-App $script:SubmitApp @{ NATIVEHTMLKIT_DIAGNOSTICS = 'trace'; NHK_BUNDLE = $zip }
        $r.ExitCode | Should -Be 0 -Because $r.Err
        (Get-Lines $r 'STATUS ')[0] | Should -Be "STATUS Saved $("$($script:Sentinel)-typed".Length)"
        $b = Read-Bundle $zip
        $b.Text | Should -Not -Match $script:Sentinel
        $b.Manifest.complete | Should -BeTrue
        $b.Manifest.host_counters.sink_dropped_records | Should -Be 0
        $t = $b.Timeline
        function Next([scriptblock]$Where) {
            for ($j = $script:cursor; $j -lt $t.Count; $j++) { if (& $Where $t[$j]) { $script:cursor = $j + 1; return $t[$j] } }
            throw "missing record after index $($script:cursor): $Where"
        }
        $script:cursor = 0
        $n = Next { param($x) $x.event -eq 'host.notification' -and $x.context.method -eq 'document.event' -and $x.context.event_type -eq 'submit' }
        $null = Next { param($x) $x.event -eq 'callback.started' -and $x.context.event_type -eq 'submit' -and $x.context.document_id -eq $n.context.document_id }
        $rpc = Next { param($x) $x.event -eq 'rpc.started' -and $x.context.method -eq 'document.command' }
        $null = Next { param($x) $x.event -eq 'rpc.completed' -and $x.request_id -eq $rpc.request_id }
        $task = Next { param($x) $x.event -eq 'task.started' }
        $null = Next { param($x) $x.event -eq 'callback.completed' -and $x.context.role -eq 'document_event' }
        $null = Next { param($x) $x.event -eq 'task.completed' -and $x.context.task_id -eq $task.context.task_id }
        $null = Next { param($x) $x.event -eq 'rpc.completed' -and $x.context.method -eq 'document.command' }
        $null = Next { param($x) $x.event -eq 'callback.completed' -and $x.context.role -eq 'task_completion' }
        @($t | Where-Object { $_.session_id -ne $b.Manifest.session_id }).Count | Should -Be 0
    }
    It 'correlates SDK request ids and events with the host''s own trace records (metadata only, no values)' {
        $session = 'nhk-ps-corr.' + [guid]::NewGuid().ToString('N')
        $body = @"
`$app = Connect-NativeHTMLKit
`$w = New-NativeHTMLKitWindow -Application `$app -Title 'corr'
`$doc = Open-NativeHTMLKitHtml -Window `$w -Html "<form id='f'><input id='name' name='name' value='$($script:Sentinel)-value'><button id='go' type='submit'>Save</button></form><p id='status'>idle</p>"
Set-NativeHTMLKitDocumentValue -Document `$doc -Element name -Value '$($script:Sentinel)-typed'
Set-NativeHTMLKitReady -Application `$app
`$script:done = `$false
`$null = Register-NativeHTMLKitDocumentEvent -Document `$doc -Type submit -Element f -Callback {
    Set-NativeHTMLKitDocumentText -Document `$doc -Element status -Text 'Saving'
    `$null = Start-NativeHTMLKitTask -Application `$app -ScriptBlock { 'ok' } -OnCompleted { Set-NativeHTMLKitDocumentText -Document `$doc -Element status -Text 'Saved'; `$script:done = `$true }
}
`$null = Submit-NativeHTMLKitForm -Document `$doc -Form f
`$clock = [Diagnostics.Stopwatch]::StartNew()
while (-not `$script:done -and `$clock.ElapsedMilliseconds -lt 15000) { [void](Wait-NativeHTMLKit -Application `$app -TimeoutMilliseconds 50) }
`$null = Export-NativeHTMLKitSupportBundle -Path '__OUT__/bundle.zip' -Application `$app
`$null = Request-NativeHTMLKitQuit -Application `$app
Wait-NativeHTMLKit -Application `$app -UntilShutdown
Close-NativeHTMLKit -Application `$app
"@
        $r = Invoke-RawHost $body @{ NATIVEHTMLKIT_DIAGNOSTICS = 'trace'; NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID = $session }
        $r.ExitCode | Should -Be 0 -Because $r.Stderr
        $r.Stderr | Should -Not -Match $script:Sentinel
        $b = Read-Bundle (Join-Path $r.Folder 'bundle.zip')
        $b.Text | Should -Not -Match $script:Sentinel
        $b.Manifest.session_id | Should -Be $session
        @($r.Records | Where-Object { $_.diagnostic_session_id -ne $session }).Count | Should -Be 0
        $hostRecords = @($r.Records | Where-Object { $_.fields })
        # Host -> SDK: the submit notification the host sent is the one the SDK dispatched.
        $sent = @($hostRecords | Where-Object { $_.fields.event -eq 'notify.sent' -and $_.fields.method -eq 'document.event' -and $_.fields.type -eq 'submit' })
        $sent.Count | Should -Be 1
        $got = @($b.Timeline | Where-Object { $_.event -eq 'host.notification' -and $_.context.event_type -eq 'submit' })
        $got.Count | Should -Be 1
        $got[0].context.window_id | Should -Be $sent[0].fields.window_id
        $got[0].context.document_id | Should -Be $sent[0].fields.document_id
        # SDK -> host: every request the SDK started was received and completed by the host under the same id.
        $started = @($b.Timeline | Where-Object { $_.event -eq 'rpc.started' })
        $started.Count | Should -BeGreaterThan 3
        foreach ($s in $started) {
            @($hostRecords | Where-Object { $_.fields.event -eq 'rpc.received' -and $_.fields.id -eq $s.request_id -and $_.fields.method -eq $s.context.method }).Count | Should -Be 1 -Because "host rpc.received for $($s.request_id)"
            $done = @($hostRecords | Where-Object { $_.fields.event -eq 'rpc.completed' -and $_.fields.id -eq $s.request_id })
            $done.Count | Should -Be 1 -Because "host rpc.completed for $($s.request_id)"
            $done[0].fields.duration_us | Should -BeGreaterOrEqual 0
        }
        # The UI mutations issued from the submit callback and from the task completion both reached the host.
        $cb = @($b.Timeline | Where-Object { $_.event -eq 'callback.started' -and $_.context.event_type -eq 'submit' })[0]
        $after = @($started | Where-Object { [DateTime]$_.timestamp -ge [DateTime]$cb.timestamp -and $_.context.method -eq 'document.command' })
        $after.Count | Should -BeGreaterOrEqual 2
    }
    It 'records no trace detail at the normal level, yet still completes' {
        $zip = Join-Path $TestDrive 'submit-normal.zip'
        $r = Invoke-App $script:SubmitApp @{ NHK_BUNDLE = $zip }
        $r.ExitCode | Should -Be 0 -Because $r.Err
        (Get-Lines $r 'STATUS ')[0] | Should -Match '^STATUS Saved \d+$'
        $b = Read-Bundle $zip
        $b.Text | Should -Not -Match $script:Sentinel
        @($b.Timeline | Where-Object { $_.level -notin 'ERROR', 'WARN' }).Count | Should -Be 0
    }
}

Describe 'Documented examples run against the real host' -Skip:$script:SkipNative {
    It 'runs the README quick start unchanged except for host path, module path and an automatic quit' {
        $readme = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'README.md'))
        $match = [regex]::Match($readme, '## Quick start\s+```powershell\r?\n(?<code>.*?)```', 'Singleline')
        $match.Success | Should -BeTrue
        $code = $match.Groups['code'].Value
        $code | Should -Match 'Start-NativeHTMLKitScript'
        $code | Should -Match 'Wait-NativeHTMLKit -Application \$app -UntilShutdown'
        $code = ($code -split "\r?\n" | Where-Object { $_ -notmatch '^\$env:NATIVEHTMLKIT_HOST_BINARY' -and $_ -notmatch '^Import-Module ' }) -join "`n"
        $code = $code.Replace('Wait-NativeHTMLKit -Application $app -UntilShutdown',
            "[Console]::Out.WriteLine('STATUS ' + (Get-NativeHTMLKitDocumentText -Document `$doc -Element status)); `$null = Request-NativeHTMLKitQuit -Application `$app`nWait-NativeHTMLKit -Application `$app -UntilShutdown")
        $r = Invoke-App $code
        $r.ExitCode | Should -Be 0 -Because $r.Err
        (Get-Lines $r 'STATUS ')[0] | Should -Be 'STATUS Ready'
    }
}

Describe 'Launcher hardening with the real host' -Skip:$script:SkipNative {
    It 'writes the launch manifest into a folder only this user can use (FR-PS-03)' {
        $body = @'
param([string]$ApiKey)
$ErrorActionPreference = 'Stop'
Import-Module '__MODULE__'
$app = Start-NativeHTMLKitScript -Name 'Perm' -Instance multiple
foreach ($d in Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'nativehtmlkit-start-*') {
    if ($IsLinux) { [Console]::Out.WriteLine("MODE " + (& /usr/bin/stat -c '%a' -- $d.FullName)) }
    else {
        $broad = @((Get-Acl -LiteralPath $d.FullName).Access | Where-Object { $_.IdentityReference.Value -match '(?i)^(Everyone|BUILTIN\\Users|NT AUTHORITY\\Authenticated Users|NT AUTHORITY\\INTERACTIVE)$' })
        [Console]::Out.WriteLine("BROAD " + $broad.Count)
    }
    foreach ($f in Get-ChildItem -LiteralPath $d.FullName) { [Console]::Out.WriteLine("ARG " + ((Get-Content -Raw -LiteralPath $f.FullName) -match 'SECRETARG')) }
}
$null = Request-NativeHTMLKitQuit -Application $app
Wait-NativeHTMLKit -Application $app -UntilShutdown
Close-NativeHTMLKit -Application $app
'@
        $r = Invoke-NativeHTMLKitDirectScript -Body $body -Arguments @('-ApiKey', 'SECRETARG-1') -HostBinary $script:HostBinary -Root $TestDrive -Environment @{}
        $r.ExitCode | Should -Be 0 -Because $r.Err
        (Get-Lines $r 'ARG ')[0] | Should -Be 'ARG True'    # the manifest does hold arguments, hence the folder protection
        if ($script:TestIsWindows) { (Get-Lines $r 'BROAD ')[0] | Should -Be 'BROAD 0' } else { (Get-Lines $r 'MODE ')[0] | Should -Be 'MODE 700' }
    }
    It 'never runs a setpriv found through PATH (FR-PS-17)' -Tag 'LinuxOnly' {
        $fake = Join-Path $TestDrive 'fakebin'; $null = New-Item -ItemType Directory -Force -Path $fake
        $marker = Join-Path $TestDrive 'fake-setpriv-ran'
        [IO.File]::WriteAllText((Join-Path $fake 'setpriv'), "#!/bin/sh`ntouch '$marker'`nexit 99`n")
        & /bin/chmod 755 (Join-Path $fake 'setpriv')
        $body = "`$app = Start-NativeHTMLKitScript -Name 'Path' -Instance multiple`n`$null = Request-NativeHTMLKitQuit -Application `$app`nWait-NativeHTMLKit -Application `$app -UntilShutdown`nClose-NativeHTMLKit -Application `$app"
        $r = Invoke-App $body @{ PATH = ($fake + ':' + $env:PATH) }
        $r.ExitCode | Should -Be 0 -Because $r.Err
        Test-Path -LiteralPath $marker | Should -BeFalse
    }
    It 'keeps script output and a fatal error visible at diagnostics level <Level> (NHK-CROSS-0007 interim rule)' -ForEach @(
        @{ Level = 'off' }, @{ Level = 'normal' }, @{ Level = 'debug' }, @{ Level = 'trace' }
    ) {
        $body = @'
$app = Start-NativeHTMLKitScript -Name 'Levels' -Instance multiple
$r = Get-NativeHTMLKitDiagnosticReport
[Console]::Out.WriteLine("APP-OUTPUT sdk_level=$($r.Level)")
throw 'APP-FATAL deliberate'
'@
        $r = Invoke-App $body @{ NATIVEHTMLKIT_DIAGNOSTICS = $Level }
        $r.ExitCode | Should -Not -Be 0
        (Get-Lines $r 'APP-OUTPUT ')[0] | Should -Be "APP-OUTPUT sdk_level=$Level"
        $r.Err | Should -Match 'APP-FATAL deliberate'
    }
}

Describe 'Lifecycle and fault behavior with the real host' -Skip:$script:SkipNative {
    It 'handles several windows, rapid open/close and stale handles' {
        $body = @'
$app = Start-NativeHTMLKitScript -Name 'Multi' -Instance multiple -MaxWindows 8
$hostPid = if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Parent.Id } else { (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId }
[Console]::Out.WriteLine("PIDS host=$hostPid backend=$PID")
$wins = @(1..3 | ForEach-Object { New-NativeHTMLKitWindow -Application $app -Title "multi $_" })
$docs = @($wins | ForEach-Object { Open-NativeHTMLKitHtml -Window $_ -Html "<p id='p'>$($_.Id)</p>" })
Set-NativeHTMLKitReady -Application $app
$texts = @($docs | ForEach-Object { Get-NativeHTMLKitDocumentText -Document $_ -Element p })
$list = Get-NativeHTMLKitWindowList -Application $app   # one array object, as in the legacy module
[Console]::Out.WriteLine("LIST $($list.Count) TEXTS $(($texts | Sort-Object -Unique).Count)")
Close-NativeHTMLKitWindow -Window $wins[1]
$clock = [Diagnostics.Stopwatch]::StartNew()
while (-not $wins[1].Closed -and $clock.ElapsedMilliseconds -lt 5000) { [void](Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 50) }
$local = try { $null = Get-NativeHTMLKitDocumentText -Document $docs[1] -Element p; 'none' } catch { $_.Exception.GetType().Name }
$remote = try { $null = Invoke-NativeHTMLKitRpc -Application $app -Method 'window.get' -Parameters @{ window_id = $wins[1].Id }; 'none' } catch { "$($_.Exception.GetType().Name):$($_.Exception.Code)" }
[Console]::Out.WriteLine("CLOSED $($wins[1].Closed) LOCAL $local REMOTE $remote")
for ($i = 0; $i -lt 25; $i++) {
    $w = New-NativeHTMLKitWindow -Application $app -Title "rapid $i"
    $d = Open-NativeHTMLKitHtml -Window $w -Html "<p id='p'>$i</p>"
    $d = Open-NativeHTMLKitHtml -Window $w -Html "<p id='p'>again $i</p>"
    Close-NativeHTMLKitWindow -Window $w
    while (-not $w.Closed) { [void](Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 50) }
}
$list = Get-NativeHTMLKitWindowList -Application $app
[Console]::Out.WriteLine("AFTER $($list.Count) PENDING $($app.Pending.Count) TRACKED $($app.Windows.Count)")
$null = Request-NativeHTMLKitQuit -Application $app
Wait-NativeHTMLKit -Application $app -UntilShutdown
Close-NativeHTMLKit -Application $app
'@
        $r = Invoke-App $body
        $r.ExitCode | Should -Be 0 -Because $r.Err
        (Get-Lines $r 'LIST ')[0] | Should -Be 'LIST 3 TEXTS 3'
        (Get-Lines $r 'CLOSED ')[0] | Should -Match '^CLOSED True LOCAL StaleObjectException REMOTE RpcException:-\d+$'
        (Get-Lines $r 'AFTER ')[0] | Should -Be 'AFTER 2 PENDING 0 TRACKED 2'
        # Exactly this app's host and backend must be gone (other runs may use the same host binary).
        $null = (Get-Lines $r 'PIDS ')[0] -match '^PIDS host=(\d+) backend=(\d+)$'
        Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Get-Process -Id ([int]$Matches[2]) -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'lets the backend close a secondary window before app.ready (Core 1.0.2, NHK-CROSS-0002)' {
        $body = @'
$app = Start-NativeHTMLKitScript -Name 'EarlyClose' -Instance multiple
$main = New-NativeHTMLKitWindow -Application $app -Title 'main'
$extra = New-NativeHTMLKitWindow -Application $app -Title 'extra'
Close-NativeHTMLKitWindow -Window $extra
$clock = [Diagnostics.Stopwatch]::StartNew()
while (-not $extra.Closed -and $clock.ElapsedMilliseconds -lt 5000) { [void](Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 50) }
Set-NativeHTMLKitReady -Application $app
$list = Get-NativeHTMLKitWindowList -Application $app
[Console]::Out.WriteLine("EARLY extra_closed=$($extra.Closed) shutdown=$($app.ShutdownRequested) windows=$($list.Count)")
$null = Request-NativeHTMLKitQuit -Application $app
Wait-NativeHTMLKit -Application $app -UntilShutdown
[Console]::Out.WriteLine("AFTER main_closed=$($main.Closed) stale=$(try { $null = Get-NativeHTMLKitWindow -Window $main; 'no' } catch { $_.Exception.GetType().Name })")
Close-NativeHTMLKit -Application $app
'@
        $r = Invoke-App $body
        $r.ExitCode | Should -Be 0 -Because $r.Err
        (Get-Lines $r 'EARLY ')[0] | Should -Be 'EARLY extra_closed=True shutdown=False windows=1'
        (Get-Lines $r 'AFTER ')[0] | Should -Be 'AFTER main_closed=True stale=StaleObjectException'
    }

    It 'treats a throwing quit policy as a veto, isolates throwing handlers, then quits' {
        $body = @'
$app = Start-NativeHTMLKitScript -Name 'Policy' -Instance multiple
$w = New-NativeHTMLKitWindow -Application $app -Title 'policy'
$doc = Open-NativeHTMLKitHtml -Window $w -Html "<form id='f'><button id='go'>Go</button></form><p id='s'>x</p>"
Set-NativeHTMLKitReady -Application $app
$null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type submit -Callback { throw 'handler bug' }
$null = Submit-NativeHTMLKitForm -Document $doc -Form f
Set-NativeHTMLKitBeforeQuit -Application $app -Callback { throw 'policy bug' }
$null = Request-NativeHTMLKitQuit -Application $app
$clock = [Diagnostics.Stopwatch]::StartNew()
while ($clock.ElapsedMilliseconds -lt 1500) { [void](Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 50) }
[Console]::Out.WriteLine("AFTER-VETO shutdown=$($app.ShutdownRequested) failures=$($app.CallbackFailures) windows=$((Get-NativeHTMLKitWindowList -Application $app).Count)")
Set-NativeHTMLKitBeforeQuit -Application $app -Callback { $true }
$null = Request-NativeHTMLKitQuit -Application $app
Wait-NativeHTMLKit -Application $app -UntilShutdown
Close-NativeHTMLKit -Application $app
[Console]::Error.WriteLine('ORDERLY')
'@
        $r = Invoke-App $body
        $r.ExitCode | Should -Be 0 -Because $r.Err
        (Get-Lines $r 'AFTER-VETO ')[0] | Should -Be 'AFTER-VETO shutdown=False failures=2 windows=1'
        $r.Err | Should -Match 'ORDERLY'
    }

    It 'fails waiting requests promptly when the host dies and leaves no host or backend process' {
        $marker = Join-Path $TestDrive ('kill-' + [guid]::NewGuid().ToString('N') + '.txt')
        $body = @'
$app = Start-NativeHTMLKitScript -Name 'Kill' -Instance multiple
$w = New-NativeHTMLKitWindow -Application $app -Title 'kill'
$hostPid = if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Parent.Id } else { (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId }
[IO.File]::WriteAllText($env:NHK_MARKER, "BACKEND $PID HOST $hostPid`n")
$pending = @(1..3 | ForEach-Object { Start-NativeHTMLKitRpc -Application $app -Method 'window.list' })
Stop-Process -Id $hostPid -Force
$clock = [Diagnostics.Stopwatch]::StartNew()
$outcomes = foreach ($p in $pending) { try { $null = Wait-NativeHTMLKitRpc -Request $p -TimeoutMilliseconds 10000; 'ok' } catch { $_.Exception.GetType().Name } }
$after = try { $null = Get-NativeHTMLKitWindowList -Application $app; 'ok' } catch { $_.Exception.GetType().Name }
[IO.File]::AppendAllText($env:NHK_MARKER, "OUTCOMES $($outcomes -join ',') AFTER $after MS $($clock.ElapsedMilliseconds)`n")
'@
        $r = Invoke-App $body @{ NHK_MARKER = $marker } 60
        $r.ExitCode | Should -Not -Be 0
        $lines = @(Get-Content -LiteralPath $marker)
        Write-Host ("host-kill evidence: " + ($lines -join ' | '))
        $lines[0] | Should -Match '^BACKEND (\d+) HOST (\d+)$'
        $null = $lines[0] -match '^BACKEND (\d+) HOST (\d+)$'
        $backendPid = [int]$Matches[1]; $hostPid = [int]$Matches[2]
        Start-Sleep -Seconds 3
        Get-Process -Id $hostPid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Get-Process -Id $backendPid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        if ($lines.Count -gt 1) {
            # The backend outlived the host long enough to observe the loss (no host job/PDEATHSIG kill).
            $lines[1] | Should -Match '^OUTCOMES ((ok|DisconnectedException),){2}(ok|DisconnectedException) AFTER DisconnectedException MS \d+$'
            [int]($lines[1] -replace '.* MS ', '') | Should -BeLessThan 3000
        }
    }
}
