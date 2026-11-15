# Regression tests for the independent final review (verification/2026-11-15-sdk/final-review/POWERSHELL.md),
# one test (or more) per finding FR-PS-xx, ported from the reviewer's exp1..exp6 experiments, plus
# tests that kill the surviving mutants m5a/m5b/m5c, m6, m7, m9, m22, m23. Pester 5+.
# PowerShell 7.2+ (Linux/Windows) or Windows PowerShell 5.1; platform-specific cases say so.
BeforeDiscovery {
    # -Skip conditions are evaluated during discovery: the platform flag must exist then.
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module $script:ModuleManifest -Force -ErrorAction Stop
    $script:Module = Get-Module NativeHTMLKit
    & $script:Module { Initialize-NativeHTMLKitHelper }
    $script:Shell = (Get-Process -Id $PID).Path
    function Invoke-Encoded([string]$Command) {
        & $script:Shell -NoProfile -NonInteractive -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command)))
    }
    function New-Connected { $m = Start-MockHost; $a = Connect-NativeHTMLKit -Endpoint $m.Endpoint -Token $script:MockToken; return @($m, $a) }
    function Get-Records { @(& $script:Module { $script:NHKDiagnosticHistory.ToArray() }) }
    function Clear-Records { & $script:Module { $script:NHKDiagnosticHistory.Clear(); $script:NHKDiagnosticDropped = [long]0 } }
    $script:WireNames = @('UI4ME_ENDPOINT', 'UI4ME_TOKEN', 'UI4ME_APP_ID', 'UI4ME_PROTOCOL_VERSION')
    function Set-WireEnv([string]$Endpoint, [string]$Token) {
        $env:UI4ME_ENDPOINT = $Endpoint; $env:UI4ME_TOKEN = $Token; $env:UI4ME_APP_ID = 'org.example.Review'; $env:UI4ME_PROTOCOL_VERSION = '1'
    }
    function Get-AbsentEndpoint {
        if ($script:TestIsWindows) { '\\.\pipe\nhk-absent-' + [guid]::NewGuid().ToString('N') } else { Join-Path ([IO.Path]::GetTempPath()) ('nhk-absent-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.sock') }
    }
}
AfterAll { foreach ($k in $script:WireNames) { [Environment]::SetEnvironmentVariable($k, $null) } }

Describe 'FR-PS-01 Close-NativeHTMLKit from inside a callback' {
    It 'runs no further callback after a callback closed the application' {
        $m, $app = New-Connected
        try {
            $script:after = New-Object Collections.ArrayList
            Register-NativeHTMLKitNotification -Application $app -Method 'test.a' -Callback { Close-NativeHTMLKit -Application $app; [void]$script:after.Add('a') }
            Register-NativeHTMLKitNotification -Application $app -Method 'test.b' -Callback { [void]$script:after.Add('b') }
            Register-NativeHTMLKitNotification -Application $app -Method 'test.c' -Callback { [void]$script:after.Add('c') }
            $null = Start-NativeHTMLKitRpc -Application $app -Method 'mock.two_notifies'
            Start-Sleep -Milliseconds 400
            { [void](Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 500) } | Should -Not -Throw
            ($script:after -join ',') | Should -Be 'a'
            $app.Closed | Should -BeTrue
        } finally { Close-NativeHTMLKit -Application $app; Stop-MockHost $m }
    }
    It 'returns normally from Wait-NativeHTMLKit -UntilShutdown after a local close' {
        $m, $app = New-Connected
        try {
            Register-NativeHTMLKitNotification -Application $app -Method 'test.a' -Callback { Close-NativeHTMLKit -Application $app }
            $null = Start-NativeHTMLKitRpc -Application $app -Method 'mock.two_notifies'
            { Wait-NativeHTMLKit -Application $app -UntilShutdown } | Should -Not -Throw
            $app.Closed | Should -BeTrue
        } finally { Close-NativeHTMLKit -Application $app; Stop-MockHost $m }
    }
}

Describe 'FR-PS-02 / FR-PS-18 / FR-PS-20 connect failures' {
    AfterEach { foreach ($k in $script:WireNames) { [Environment]::SetEnvironmentVariable($k, $null) } }
    It 'scrubs the launch variables when the endpoint is not listening, and child processes do not inherit them' {
        Set-WireEnv (Get-AbsentEndpoint) ('ab' * 32)
        $caught = $null
        try { Connect-NativeHTMLKit -ConnectTimeoutMilliseconds 300 } catch { $caught = $_.Exception }
        $caught | Should -BeOfType ([NativeHTMLKit.DisconnectedException])            # FR-PS-18: a documented type
        $caught.InnerException | Should -Not -BeNullOrEmpty
        foreach ($k in $script:WireNames) { [Environment]::GetEnvironmentVariable($k) | Should -BeNullOrEmpty -Because $k }
        (Invoke-Encoded '[bool]$env:UI4ME_TOKEN') | Should -Be 'False'
    }
    It 'scrubs them when Start-NativeHTMLKitScript fails to connect (backend role)' {
        Set-WireEnv (Get-AbsentEndpoint) ('ab' * 32)
        { Start-NativeHTMLKitScript -ScriptPath $PSCommandPath } | Should -Throw
        foreach ($k in $script:WireNames) { [Environment]::GetEnvironmentVariable($k) | Should -BeNullOrEmpty -Because $k }
    }
    It 'scrubs them when only one of endpoint/token is set' {
        $env:UI4ME_TOKEN = 'ab' * 32
        { Start-NativeHTMLKitScript -ScriptPath $PSCommandPath } | Should -Throw '*Incomplete*'
        [Environment]::GetEnvironmentVariable('UI4ME_TOKEN') | Should -BeNullOrEmpty
        $env:UI4ME_ENDPOINT = Get-AbsentEndpoint
        { Connect-NativeHTMLKit } | Should -Throw
        [Environment]::GetEnvironmentVariable('UI4ME_ENDPOINT') | Should -BeNullOrEmpty
    }
    It 'rejects a token that is not 64 hex digits, without contacting the endpoint, and scrubs it' {
        Set-WireEnv (Get-AbsentEndpoint) 'not-a-host-token'
        { Connect-NativeHTMLKit } | Should -Throw -ExceptionType ([ArgumentException])
        [Environment]::GetEnvironmentVariable('UI4ME_TOKEN') | Should -BeNullOrEmpty
        $m = Start-MockHost -Token 'short-test-token'
        try {
            $app = Connect-NativeHTMLKit -Endpoint $m.Endpoint -Token 'short-test-token' -SkipTokenValidation
            $app.Hello.protocol_version | Should -Be 1
            Close-NativeHTMLKit -Application $app
        } finally { Stop-MockHost $m }
    }
}

Describe 'FR-PS-04 bundled host verification fails closed' {
    BeforeAll {
        $script:copy = Join-Path $TestDrive 'pkg/NativeHTMLKit'
        Copy-Item -LiteralPath (Split-Path -Parent $script:ModuleManifest) -Destination $script:copy -Recurse
        $rid = if ($script:TestIsWindows) { 'win-x64' } else { 'linux-x64' }
        $name = if ($script:TestIsWindows) { 'nativehtmlkit-host.exe' } else { 'nativehtmlkit-host' }
        $script:hostFile = Join-Path $script:copy "runtimes/$rid/$name"
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:hostFile)
        [IO.File]::WriteAllBytes($script:hostFile, [byte[]](1..200))
        $sha = (Get-FileHash -LiteralPath $script:hostFile -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:manifest = Join-Path $script:copy 'HOST-MANIFEST.json'
        [IO.File]::WriteAllText($script:manifest, (@{ schema_version = 1; hosts = @{ $rid = @{ sha256 = $sha } } } | ConvertTo-Json -Depth 4))
        $script:psd1 = Join-Path $script:copy 'NativeHTMLKit.psd1'
    }
    It 'detects a host swapped after a successful check in the same process (no stamp cache)' {
        $cmd = @"
Remove-Item Env:NATIVEHTMLKIT_HOST_BINARY, Env:UI4ME_HOST_BINARY -ErrorAction SilentlyContinue
Import-Module '$($script:psd1)'
`$first = Get-NativeHTMLKitHostPath
`$t = (Get-Item '$($script:hostFile)').LastWriteTimeUtc
`$b = [IO.File]::ReadAllBytes('$($script:hostFile)'); `$b[10] = `$b[10] -bxor 1; [IO.File]::WriteAllBytes('$($script:hostFile)', `$b)
(Get-Item '$($script:hostFile)').LastWriteTimeUtc = `$t
try { 'second accepted: ' + (Get-NativeHTMLKitHostPath) } catch { 'ERROR: ' + `$_.Exception.Message }
`$b[10] = `$b[10] -bxor 1; [IO.File]::WriteAllBytes('$($script:hostFile)', `$b)
"@
        (Invoke-Encoded $cmd) | Should -Match '^ERROR: The bundled .* does not match HOST-MANIFEST.json'
    }
    It 'refuses a bundled host when HOST-MANIFEST.json is missing' {
        Remove-Item -LiteralPath $script:manifest
        $cmd = "Remove-Item Env:NATIVEHTMLKIT_HOST_BINARY, Env:UI4ME_HOST_BINARY -ErrorAction SilentlyContinue; Import-Module '$($script:psd1)'; try { Get-NativeHTMLKitHostPath } catch { 'ERROR: ' + `$_.Exception.Message }"
        (Invoke-Encoded $cmd) | Should -Match '^ERROR: The bundled .* has no HOST-MANIFEST.json'
    }
}

Describe 'FR-PS-05 / FR-PS-06 diagnostic redaction is allow-list based' {
    BeforeEach { Clear-Records; $env:NATIVEHTMLKIT_DIAGNOSTICS = 'trace' }
    AfterEach { $env:NATIVEHTMLKIT_DIAGNOSTICS = $null; Clear-Records }
    It 'redacts <Name>' -ForEach @(
        @{ Name = 'a path'; Key = 'method'; Value = '/home/alice/secret.txt' }
        @{ Name = 'a URL'; Key = 'event_type'; Value = 'https://example.invalid/?q=1' }
        @{ Name = 'spaced text'; Key = 'type'; Value = 'two words' }
        @{ Name = 'a long string'; Key = 'window_id'; Value = ('a' * 200) }
        @{ Name = 'an unknown key with a token-shaped value'; Key = 'note'; Value = 'hunter2SENTINELpw' }
        @{ Name = 'a sentinel in the method position'; Key = 'method'; Value = 'SENTINEL-4111111111111111' }
        @{ Name = 'a sentinel in the event-type position'; Key = 'event_type'; Value = 'hunter2SENTINELpw' }
        @{ Name = 'a sentinel in the type position'; Key = 'type'; Value = 'hunter2SENTINELpw' }
        @{ Name = 'a sentinel in a window id with separators'; Key = 'window_id'; Value = 'alice.smith:SENTINEL' }
        @{ Name = 'an element id'; Key = 'element'; Value = 'alice.smith:SENTINEL' }
        @{ Name = 'a free-text role'; Key = 'role'; Value = 'SENTINEL' }
        @{ Name = 'an exception type with spaces'; Key = 'exception_type'; Value = 'Bad Thing SENTINEL!' }
    ) {
        & $script:Module { param($k, $v) Write-NativeHTMLKitDiagnostic -Event 'test.redact' -Level 'ERROR' -Context @{ $k = $v } } $Key $Value
        $r = @(Get-Records)[0]
        $r.context[$Key] | Should -Be '[REDACTED]'
    }
    It 'redacts every blacklisted key name even when the value is a valid identifier' {
        foreach ($key in 'token', 'password', 'secret', 'credential', 'authorization', 'cookie', 'api_key', 'apikey', 'content', 'payload', 'body', 'html', 'path', 'url', 'text', 'value', 'filename', 'message') {
            Clear-Records
            # Numbers too (a PIN or account number under a 'value'/'secret' key).
            & $script:Module { param($k) Write-NativeHTMLKitDiagnostic -Event 'test.redact' -Level 'ERROR' -Context @{ $k = 4111; "${k}_flag" = $true } } $key
            @(Get-Records)[0].context[$key] | Should -Be '[REDACTED]' -Because $key
            @(Get-Records)[0].context["${key}_flag"] | Should -Be '[REDACTED]' -Because "${key}_flag"
        }
    }
    It 'keeps allow-listed identifiers, numbers and booleans' {
        & $script:Module { Write-NativeHTMLKitDiagnostic -Event 'test.keep' -Level 'ERROR' -RequestId 'ps-17' -Context @{ method = 'document.command'; event_type = 'submit'; type = 'closed'; role = 'document_event'; exception_type = 'RpcException'; task_id = ('0123456789abcdef' * 2); window_id = 'w1'; document_id = 'd-2'; count = 3; ok = $true } }
        $r = @(Get-Records)[0]
        $r.request_id | Should -Be 'ps-17'
        foreach ($k in 'method', 'event_type', 'type', 'role', 'exception_type', 'task_id', 'window_id', 'document_id') { $r.context[$k] | Should -Not -Be '[REDACTED]' -Because $k }
        $r.context.count | Should -Be 3
        $r.context.ok | Should -BeTrue
    }
    It 'keeps sentinels from identifier positions out of an exported bundle (reviewer exp3 P1)' {
        $S1 = 'hunter2SENTINELpw'; $S2 = 'alice.smith:SENTINEL'; $S3 = 'SENTINEL-4111111111111111'
        $m, $app = New-Connected
        try {
            $win = New-NativeHTMLKitWindow -Application $app; $doc = Open-NativeHTMLKitHtml -Window $win -Html '<p id="x">x</p>'
            $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element $S2 -Callback { }
            $null = Invoke-NativeHTMLKitDocumentCommand -Document $doc -Operation emit -Parameters @{ events = @(@{ type = 'click'; element = $S2 }) }
            [void](Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 300)
            $null = Invoke-NativeHTMLKitRpc -Application $app -Method 'mock.notify_raw' -Parameters @{ method = 'desktop.custom'; params = @{ type = $S1 } }
            [void](Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 300)
            try { $null = Invoke-NativeHTMLKitRpc -Application $app -Method $S3 } catch { $null = $_ }
            $zip = Join-Path $TestDrive ('p1-' + [guid]::NewGuid().ToString('N') + '.zip')
            $null = Export-NativeHTMLKitSupportBundle -Path $zip -Application $app
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $dir = "$zip.d"; [IO.Compression.ZipFile]::ExtractToDirectory($zip, $dir)
            $all = (Get-ChildItem -LiteralPath $dir -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
            $all | Should -Not -Match 'SENTINEL'
            @(Get-Records | Where-Object { $_.event -eq 'host.notification' }).Count | Should -BeGreaterThan 0   # the records exist, redacted
        } finally { Close-NativeHTMLKit -Application $app; Stop-MockHost $m }
    }
}

Describe 'FR-PS-07 break/continue in a callback' {
    It 'does not unwind an SDK loop or fake an RPC result (reviewer exp2)' {
        $m, $app = New-Connected
        try {
            $win = New-NativeHTMLKitWindow -Application $app; $doc = Open-NativeHTMLKitHtml -Window $win -Html '<p id="x">x</p>'
            Set-NativeHTMLKitDocumentText -Document $doc -Element x -Text 'real-text'
            Register-NativeHTMLKitNotification -Application $app -Method 'test.echo' -Callback { break }
            $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Callback {
                $null = Invoke-NativeHTMLKitRpc -Application $app -Method 'mock.notify_echo' -Parameters @{ text = 't' }
                $null = Invoke-NativeHTMLKitRpc -Application $app -Method 'mock.echo'
            }
            $null = Invoke-NativeHTMLKitDocumentCommand -Document $doc -Operation emit -Parameters @{ events = @(@{ type = 'click'; element = 'x' }) }
            $n = 0; while ($app.Deferred.Count -eq 0 -and $n++ -lt 50) { & $script:Module { param($a) [void](Invoke-NativeHTMLKitPump $a 100) } $app }
            $app.Deferred.Count | Should -BeGreaterThan 0
            $before = $app.CallbackFailures
            Get-NativeHTMLKitDocumentText -Document $doc -Element x | Should -Be 'real-text'
            $app.Pending.Count | Should -Be 0
            $app.CallbackFailures | Should -Be ($before + 1)
        } finally { Close-NativeHTMLKit -Application $app; Stop-MockHost $m }
    }
    It 'treats continue in a close policy as a failed callback (veto), not as an answer' {
        $m, $app = New-Connected
        try {
            $win = New-NativeHTMLKitWindow -Application $app
            Set-NativeHTMLKitBeforeClose -Window $win -Callback { continue }
            Close-NativeHTMLKitWindow -Window $win
            [void](Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 300)
            $win.Closed | Should -BeFalse
            $app.CallbackFailures | Should -Be 1
        } finally { Close-NativeHTMLKit -Application $app; Stop-MockHost $m }
    }
}

Describe 'FR-PS-08 / FR-PS-09 / FR-PS-11 queue and request bounds' {
    It 'fails the connection when the host floods lifecycle frames beyond their own cap (reviewer exp1 E4)' {
        $m, $app = New-Connected
        try {
            $null = Start-NativeHTMLKitRpc -Application $app -Method 'mock.flood_closed' -Parameters @{ count = 2000 }
            $deadline = [DateTime]::UtcNow.AddSeconds(20)
            while (-not $app.Transport.IsDisconnected -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
            $app.Transport.IsDisconnected | Should -BeTrue
            $app.Transport.Failure | Should -Match 'lifecycle'
            $app.Transport.QueuedLifecycleMessages | Should -BeLessOrEqual 1024
            $app.Transport.QueuedBytes.GetType() | Should -Be ([long])
        } finally { Close-NativeHTMLKit -Application $app; Stop-MockHost $m }
    }
    It 'bounds unawaited requests at 128 with a typed busy error (reviewer exp1 E3)' {
        $m, $app = New-Connected
        try {
            $requests = @(1..128 | ForEach-Object { Start-NativeHTMLKitRpc -Application $app -Method 'mock.echo' })
            while ((Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 100) -gt 0) { }
            $app.Transport.PendingCount | Should -Be 0          # the host answered all of them
            { Start-NativeHTMLKitRpc -Application $app -Method 'mock.echo' } | Should -Throw -ExceptionType ([NativeHTMLKit.BusyException])
            $app.Pending.Count | Should -Be 128
            $app.Replies.Count | Should -BeLessOrEqual 128
            foreach ($r in $requests) { $null = Wait-NativeHTMLKitRpc -Request $r }
            $app.Pending.Count | Should -Be 0
            (Invoke-NativeHTMLKitRpc -Application $app -Method 'mock.echo' -Parameters @{ a = 1 }).params.a | Should -Be 1
        } finally { Close-NativeHTMLKit -Application $app; Stop-MockHost $m }
    }
    It 'bounds deferred notifications at 128 while a callback runs (mutant m6)' {
        $m, $app = New-Connected
        try {
            $win = New-NativeHTMLKitWindow -Application $app; $doc = Open-NativeHTMLKitHtml -Window $win -Html '<p id="x">x</p>'
            $script:deferredSeen = -1
            $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Callback {
                $before = $app.Transport.DroppedNotifications
                $null = Invoke-NativeHTMLKitRpc -Application $app -Method 'mock.flood_notifications' -Parameters @{ count = 200 }
                $script:deferredSeen = $app.Deferred.Count
                $script:lost = $app.DroppedNotifications + ($app.Transport.DroppedNotifications - $before)
            }
            $null = Invoke-NativeHTMLKitDocumentCommand -Document $doc -Operation emit -Parameters @{ events = @(@{ type = 'click'; element = 'x' }) }
            Wait-Until { $script:deferredSeen -ge 0 } $app 10 | Should -BeTrue
            $script:deferredSeen | Should -Be 128
            $script:lost | Should -Be 72
        } finally { Close-NativeHTMLKit -Application $app; Stop-MockHost $m }
    }
    It 'applies the 8 MiB byte bound to queued notifications (mutant m9)' {
        $m, $app = New-Connected
        try {
            $r = Start-NativeHTMLKitRpc -Application $app -Method 'mock.flood_big' -Parameters @{ count = 100; size = 200000 }
            Start-Sleep -Milliseconds 2500   # not pumping: the reader applies the bounds
            $app.Transport.QueuedMessages | Should -BeLessThan 100
            $app.Transport.QueuedBytes | Should -BeLessOrEqual (8MB)
            $app.Transport.DroppedNotifications | Should -BeGreaterThan 0
            $null = Wait-NativeHTMLKitRpc -Request $r
            while ((Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 50) -gt 0) { }
            $app.Transport.IsDisconnected | Should -BeFalse
        } finally { Close-NativeHTMLKit -Application $app; Stop-MockHost $m }
    }
    It 'stops nested callbacks at the 32-level limit (mutant m22)' {
        $count = & $script:Module {
            $fake = [pscustomobject]@{ Depth = 0; MaxDepth = 32; Dispatching = $false }
            $script:levels = 0
            $script:recurse = { $script:levels++; $null = Invoke-NativeHTMLKitCallback $fake $script:recurse @() }
            try { $null = Invoke-NativeHTMLKitCallback $fake $script:recurse @() } catch { $null = $_ }
            [pscustomobject]@{ Levels = $script:levels; Depth = $fake.Depth }
        }
        $count.Levels | Should -Be 32
        $count.Depth | Should -Be 0
    }
    It 'serializes concurrent writers so frames never interleave (mutant m23)' {
        $m, $app = New-Connected
        try {
            # Frames larger than the socket/pipe buffer are written in several chunks; without the
            # write lock, chunks of different frames interleave and the peer sees garbage.
            $pad = 'y' * 1500000
            $jobs = foreach ($w in 1..4) {
                $ps = [PowerShell]::Create()
                [void]$ps.AddScript({ param($t, $pad, $w) for ($i = 0; $i -lt 6; $i++) { $t.Send(@{ jsonrpc = '2.0'; method = 'test.write'; params = @{ w = $w; i = $i; pad = $pad } }) } }).AddArgument($app.Transport).AddArgument($pad).AddArgument($w)
                [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
            }
            foreach ($j in $jobs) { $j.PS.EndInvoke($j.Handle); $j.PS.Dispose() }
            $stats = Invoke-NativeHTMLKitRpc -Application $app -Method 'mock.stats' -TimeoutMilliseconds 30000
            $stats.notifications | Should -Be 24
            $app.Transport.IsDisconnected | Should -BeFalse
        } finally { Close-NativeHTMLKit -Application $app; Stop-MockHost $m }
    }
}

Describe 'FR-PS-12 / FR-PS-13 / FR-PS-14 background tasks' {
    It 'keeps waiting for a healthy local worker when the host dies during Receive -Wait (reviewer exp5 X2)' {
        $m, $app = New-Connected
        try {
            $t = Start-NativeHTMLKitTask -Application $app -ScriptBlock { Start-Sleep -Milliseconds 1500; 'local result' }
            Stop-Process -Id $m.Process.Id -Force
            (Receive-NativeHTMLKitTask -Task $t -Wait -TimeoutMilliseconds 10000).Result | Should -Be 'local result'
        } finally { Close-NativeHTMLKit -Application $app; Stop-MockHost $m }
    }
    It 'refuses SDK handles nested inside task arguments (reviewer exp5 X3)' {
        $m, $app = New-Connected
        try {
            $win = New-NativeHTMLKitWindow -Application $app
            { Start-NativeHTMLKitTask -Application $app -ArgumentList @(@{ w = $win }) -ScriptBlock { 1 } } | Should -Throw '*cannot be passed to a background task*'
            { Start-NativeHTMLKitTask -Application $app -ArgumentList @(, @(1, @($app.Transport))) -ScriptBlock { 1 } } | Should -Throw '*cannot be passed*'
            { Start-NativeHTMLKitTask -Application $app -ArgumentList @([pscustomobject]@{ inner = [pscustomobject]@{ w = $win } }) -ScriptBlock { 1 } } | Should -Throw '*cannot be passed*'
            $t = Start-NativeHTMLKitTask -Application $app -ArgumentList @(@{ a = @(1, 2); b = 'x' }) -ScriptBlock { param($h) $h.a.Count }
            (Receive-NativeHTMLKitTask -Task $t -Wait -TimeoutMilliseconds 10000).Result | Should -Be 2
        } finally { Close-NativeHTMLKit -Application $app; Stop-MockHost $m }
    }
    It 'delivers a completion promptly while the host is idle (reviewer exp6)' {
        $m, $app = New-Connected
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew(); $script:at = -1
            $null = Start-NativeHTMLKitTask -Application $app -ScriptBlock { Start-Sleep -Milliseconds 300; 'x' } -OnCompleted { $script:at = $sw.ElapsedMilliseconds }
            $n = Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 3000
            $n | Should -BeGreaterOrEqual 1
            $script:at | Should -BeGreaterThan 0
            $script:at | Should -BeLessThan 1500
            $sw.ElapsedMilliseconds | Should -BeLessThan 2500
        } finally { Close-NativeHTMLKit -Application $app; Stop-MockHost $m }
    }
}

Describe 'FR-PS-15 closed windows are retired even when their notification is dropped' {
    It 'retires the window although the deferred queue was full when "closed" arrived' {
        $m, $app = New-Connected
        try {
            $win = New-NativeHTMLKitWindow -Application $app; $doc = Open-NativeHTMLKitHtml -Window $win -Html '<p id="x">x</p>'
            $script:state = $null
            $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Callback {
                $null = Invoke-NativeHTMLKitRpc -Application $app -Method 'mock.flood_then_close' -Parameters @{ count = 200; window_id = $win.Id }
                $script:state = [pscustomobject]@{ Closed = $win.Closed; Dropped = $app.DroppedNotifications + $app.Transport.DroppedNotifications }
            }
            $null = Invoke-NativeHTMLKitDocumentCommand -Document $doc -Operation emit -Parameters @{ events = @(@{ type = 'click'; element = 'x' }) }
            Wait-Until { $null -ne $script:state } $app 10 | Should -BeTrue
            $script:state.Dropped | Should -BeGreaterThan 0
            $script:state.Closed | Should -BeTrue
            { Get-NativeHTMLKitWindow -Window $win } | Should -Throw -ExceptionType ([NativeHTMLKit.StaleObjectException])
        } finally { Close-NativeHTMLKit -Application $app; Stop-MockHost $m }
    }
}

Describe 'FR-PS-16 / FR-PS-17 host resolution' {
    AfterEach { Remove-Item Env:NATIVEHTMLKIT_HOST_BINARY -ErrorAction SilentlyContinue }
    It 'resolves a relative NATIVEHTMLKIT_HOST_BINARY once, against the PowerShell location (reviewer exp3 H2)' {
        $a = Join-Path $TestDrive 'cwd-a'; $b = Join-Path $TestDrive 'cwd-b'
        $null = New-Item -ItemType Directory -Force -Path $a, $b
        Set-Content -LiteralPath (Join-Path $b 'h') -Value 'x'
        $savedCwd = [Environment]::CurrentDirectory
        Push-Location -LiteralPath $b
        try {
            [Environment]::CurrentDirectory = $a
            $env:NATIVEHTMLKIT_HOST_BINARY = 'h'
            Get-NativeHTMLKitHostPath | Should -Be ([IO.Path]::GetFullPath((Join-Path $b 'h')))
        } finally { Pop-Location; [Environment]::CurrentDirectory = $savedCwd }
    }
    It 'never takes setpriv from PATH' -Tag 'LinuxOnly' {
        $src = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $script:ModuleManifest) 'NativeHTMLKit.psm1'))
        $src | Should -Not -Match 'Get-Command setpriv'
        $src | Should -Match "'/usr/bin/setpriv', '/bin/setpriv'"
    }
}

Describe 'FR-PS-22 stale launch-folder cleanup never follows links' {
    It 'removes an old nativehtmlkit-start folder but not the target of a link inside it' {
        $temp = Join-Path $TestDrive 'tmp'; $outside = Join-Path $TestDrive 'outside'
        $null = New-Item -ItemType Directory -Force -Path $temp, $outside
        Set-Content -LiteralPath (Join-Path $outside 'keep.txt') -Value 'must survive'
        $stale = Join-Path $temp 'nativehtmlkit-start-0000stale'
        $null = New-Item -ItemType Directory -Path $stale
        Set-Content -LiteralPath (Join-Path $stale 'app.toml') -Value 'x'
        if ($script:TestIsWindows) { cmd /c mklink /J (Join-Path $stale 'link') $outside | Out-Null } else { $null = New-Item -ItemType SymbolicLink -Path (Join-Path $stale 'link') -Target $outside }
        (Get-Item -LiteralPath (Join-Path $stale 'link') -Force).Attributes.ToString() | Should -Match 'ReparsePoint'
        (Get-Item -LiteralPath $stale).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2)
        $saved = @{}; foreach ($k in 'TMP', 'TEMP', 'TMPDIR') { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $temp + [IO.Path]::DirectorySeparatorChar) }
        try { & $script:Module { Clear-NativeHTMLKitStaleStartFolders } }
        finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
        Test-Path -LiteralPath $stale | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $outside 'keep.txt') | Should -BeTrue
    }
}

Describe 'FR-PS-21 Windows named pipe: identification only, owner checked' -Tag 'WindowsOnly' {
    It 'lets a pipe server identify but not impersonate the client' {
        # The rogue server is another process, as an attacker's would be.
        $name = 'nhk-rogue-' + [guid]::NewGuid().ToString('N')
        $out = Join-Path $TestDrive 'rogue.txt'
        $server = @"
`$s = New-Object IO.Pipes.NamedPipeServerStream('$name', [IO.Pipes.PipeDirection]::InOut, 1, [IO.Pipes.PipeTransmissionMode]::Byte, [IO.Pipes.PipeOptions]::None)
[IO.File]::WriteAllText('$out.ready', 'ready')
`$s.WaitForConnection()
`$b = New-Object byte[] 4; [void]`$s.Read(`$b, 0, 4)
`$script:level = 'unset'
try { `$s.RunAsClient([IO.Pipes.PipeStreamImpersonationWorker]{ `$script:level = [Security.Principal.WindowsIdentity]::GetCurrent(`$true).ImpersonationLevel }) } catch { `$script:level = 'error:' + `$_.Exception.GetType().Name }
[IO.File]::WriteAllText('$out', [string]`$script:level)
`$s.Dispose()
"@
        $p = Start-Process -FilePath $script:Shell -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($server))) -PassThru -WindowStyle Hidden
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while (-not (Test-Path -LiteralPath "$out.ready") -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
            $client = New-Object -TypeName 'NativeHTMLKit.Transport' -ArgumentList @("\\.\pipe\$name", 10000)
            # The rogue server reads the 4-byte header, probes and closes: the rest of this write may hit a closed pipe.
            try { $client.Send(@{ jsonrpc = '2.0'; method = 'test.ping'; params = @{} }) } catch { $null = $_ }
            while (-not (Test-Path -LiteralPath $out) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
            $client.Dispose()
            [IO.File]::ReadAllText($out) | Should -Be 'Identification'
        } finally { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force } }
    }
    It 'reads the pipe owner and accepts only this user or one of its groups' {
        $name = 'nhk-owner-' + [guid]::NewGuid().ToString('N')
        $server = New-Object IO.Pipes.NamedPipeServerStream($name, [IO.Pipes.PipeDirection]::InOut, 1, [IO.Pipes.PipeTransmissionMode]::Byte, [IO.Pipes.PipeOptions]::Asynchronous)
        try {
            $pending = $server.BeginWaitForConnection($null, $null)
            $pipe = New-Object IO.Pipes.NamedPipeClientStream('.', $name, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous, [Security.Principal.TokenImpersonationLevel]::Identification)
            $pipe.Connect(5000); $server.EndWaitForConnection($pending)
            $owner = [NativeHTMLKit.Transport]::PipeOwner($pipe)
            $me = [Security.Principal.WindowsIdentity]::GetCurrent()
            $owner | Should -Not -BeNullOrEmpty
            ($owner.Equals($me.User) -or $me.Groups.Contains($owner)) | Should -BeTrue
            $pipe.Dispose()
        } finally { $server.Dispose() }
    }
}
