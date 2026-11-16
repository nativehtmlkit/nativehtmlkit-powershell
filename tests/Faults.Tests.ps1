# Failure injection against a local JSON-RPC peer: malformed frames, protocol violations,
# unknown error codes, a peer killed mid-request, lost replies, rapid open/close and
# credential scrubbing. Pester 5+. PowerShell 7.2+ or Windows PowerShell 5.1.
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module $script:ModuleManifest -Force -ErrorAction Stop
    function Get-ReaderThreads($Application) {
        $t = $Application.Transport
        foreach ($name in 'reader', 'rejecter') {
            $t.GetType().GetField($name, [Reflection.BindingFlags]'NonPublic, Instance').GetValue($t)
        }
    }
    # Connects, runs one mock fault method, and returns the application after the
    # connection failed (or $null if it stayed healthy within the timeout).
    function Invoke-Fault([string]$Method) {
        $mock = Start-MockHost
        $app = Connect-NativeHTMLKit -Endpoint $mock.Endpoint -Token $script:MockToken
        try {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $null = Invoke-NativeHTMLKitRpc -Application $app -Method $Method -TimeoutMilliseconds 5000
            $thrown = $null
            # Bounded: a regression that stops rejecting the frame must FAIL here, not hang the suite.
            try {
                while ($clock.ElapsedMilliseconds -lt 10000 -and -not $app.Disconnected) { [void](Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 100) }
                if (-not $app.Disconnected) { $thrown = 'still connected after 10 s' }
                else { [void](Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 0) }
            } catch { $thrown = $_.Exception }
            return [pscustomobject]@{ App = $app; Thrown = $thrown; Ms = $clock.ElapsedMilliseconds; Failure = $app.Transport.Failure }
        } finally { Close-NativeHTMLKit -Application $app; Stop-MockHost $mock }
    }
}

Describe 'Malformed and hostile host frames are fatal, never silent success' {
    It 'rejects <Method> by closing the connection with a classified failure' -ForEach @(
        @{ Method = 'mock.oversized'; Pattern = 'Invalid frame length' }
        @{ Method = 'mock.zero_frame'; Pattern = 'Invalid frame length' }
        @{ Method = 'mock.truncated'; Pattern = 'inside a frame' }
        @{ Method = 'mock.bad_utf8'; Pattern = 'not valid UTF-8' }
        @{ Method = 'mock.null_id_error'; Pattern = 'invalid request ID' }
        @{ Method = 'mock.garbage'; Pattern = 'invalid request ID' }
    ) {
        $r = Invoke-Fault $Method
        $r.Thrown | Should -BeOfType ([NativeHTMLKit.DisconnectedException])
        $r.Failure | Should -Match $Pattern
        $r.App.Disconnected | Should -BeTrue
        $r.Ms | Should -BeLessThan 5000
        foreach ($thread in Get-ReaderThreads $r.App) { $thread.IsAlive | Should -BeFalse }
    }

    It 'fails the pending request when its own response is malformed (<Method>)' -ForEach @(
        @{ Method = 'mock.bad_error_code'; Pattern = 'Invalid JSON-RPC error object' }
        @{ Method = 'mock.both_result_error'; Pattern = 'result or error' }
    ) {
        $mock = Start-MockHost
        $app = Connect-NativeHTMLKit -Endpoint $mock.Endpoint -Token $script:MockToken
        try {
            { Invoke-NativeHTMLKitRpc -Application $app -Method $Method -TimeoutMilliseconds 5000 } | Should -Throw -ExceptionType ([NativeHTMLKit.DisconnectedException])
            $app.Transport.Failure | Should -Match $Pattern
            $app.Pending.Count | Should -Be 0
        } finally { Close-NativeHTMLKit -Application $app; Stop-MockHost $mock }
    }
}

Describe 'Host errors and lost replies' {
    BeforeAll {
        $script:mock = Start-MockHost
        $script:app = Connect-NativeHTMLKit -Endpoint $script:mock.Endpoint -Token $script:MockToken
    }
    AfterAll { Close-NativeHTMLKit -Application $script:app; Stop-MockHost $script:mock }

    It 'preserves an unknown numeric host error code instead of mapping or hiding it' {
        $caught = $null
        try { $null = Invoke-NativeHTMLKitRpc -Application $script:app -Method 'mock.error_echo' -Parameters @{ code = -39999; text = 'future error' } } catch { $caught = $_.Exception }
        $caught | Should -BeOfType ([NativeHTMLKit.RpcException])
        $caught.Code | Should -Be -39999
        $caught.Method | Should -Be 'mock.error_echo'
        $script:app.Transport.IsDisconnected | Should -BeFalse
    }

    It 'correlates replies by id, not order (a later request answered first, as Core 1.0.3 path loads can be)' {
        $held = Start-NativeHTMLKitRpc -Application $script:app -Method 'mock.hold'
        $release = Start-NativeHTMLKitRpc -Application $script:app -Method 'mock.release'
        (Wait-NativeHTMLKitRpc -Request $held).held | Should -BeTrue           # awaited first, answered second
        (Wait-NativeHTMLKitRpc -Request $release).released | Should -BeTrue
        $script:app.Pending.Count | Should -Be 0
    }

    It 'reports a dropped reply as a timeout whose outcome is unknown, and cancels it' {
        $caught = $null
        try { $null = Invoke-NativeHTMLKitRpc -Application $script:app -Method 'mock.never' -TimeoutMilliseconds 200 } catch { $caught = $_.Exception }
        $caught | Should -BeOfType ([NativeHTMLKit.RpcTimeoutException])
        $caught.Message | Should -Match 'outcome is unknown'
        $script:app.Pending.Count | Should -Be 0
        $script:app.Transport.PendingCount | Should -Be 0
    }

    It 'refuses more than 128 outstanding requests without corrupting state' {
        $requests = @(1..128 | ForEach-Object { Start-NativeHTMLKitRpc -Application $script:app -Method 'mock.never' })
        { Start-NativeHTMLKitRpc -Application $script:app -Method 'mock.never' } | Should -Throw '*128 outstanding*'
        foreach ($r in $requests) { Stop-NativeHTMLKitRpc -Request $r }
        $script:app.Transport.PendingCount | Should -Be 0
        (Invoke-NativeHTMLKitRpc -Application $script:app -Method 'mock.echo' -Parameters @{ a = 1 }).params.a | Should -Be 1
    }

    It 'survives rapid document replacement without leaking handlers or handles' {
        $win = New-NativeHTMLKitWindow -Application $script:app -Title 'rapid'
        $docs = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt 60; $i++) {
            $d = Open-NativeHTMLKitHtml -Window $win -Html "<p id='p'>$i</p>"
            $null = Register-NativeHTMLKitDocumentEvent -Document $d -Type click -Callback { }
            [void]$docs.Add($d)
        }
        @($docs | Where-Object { -not $_.Retired }).Count | Should -Be 1
        @($docs | Where-Object { $_.Retired -and $_.Handlers.Count -gt 0 }).Count | Should -Be 0
        $script:app.Pending.Count | Should -Be 0
        $script:app.Windows.Count | Should -Be 1
    }
}

Describe 'Peer killed in the middle of requests' {
    It 'fails every pending request promptly with a disconnect and stops the transport threads' {
        $mock = Start-MockHost
        $app = Connect-NativeHTMLKit -Endpoint $mock.Endpoint -Token $script:MockToken
        try {
            $pending = @(1..3 | ForEach-Object { Start-NativeHTMLKitRpc -Application $app -Method 'mock.never' })
            Start-Sleep -Milliseconds 100
            Stop-Process -Id $mock.Process.Id -Force
            $clock = [Diagnostics.Stopwatch]::StartNew()
            foreach ($r in $pending) {
                { Wait-NativeHTMLKitRpc -Request $r -TimeoutMilliseconds 10000 } | Should -Throw -ExceptionType ([NativeHTMLKit.DisconnectedException])
            }
            $clock.ElapsedMilliseconds | Should -BeLessThan 3000
            $app.Disconnected | Should -BeTrue
            $app.Pending.Count | Should -Be 0
            { Invoke-NativeHTMLKitRpc -Application $app -Method 'mock.echo' } | Should -Throw -ExceptionType ([NativeHTMLKit.DisconnectedException])
            Close-NativeHTMLKit -Application $app
            foreach ($thread in Get-ReaderThreads $app) { $thread.IsAlive | Should -BeFalse }
        } finally { Close-NativeHTMLKit -Application $app; Stop-MockHost $mock }
    }

    It 'reports an abrupt peer exit (no close handshake) while idle' {
        $mock = Start-MockHost
        $app = Connect-NativeHTMLKit -Endpoint $mock.Endpoint -Token $script:MockToken
        try {
            $null = Start-NativeHTMLKitRpc -Application $app -Method 'mock.exit'
            { Wait-NativeHTMLKit -Application $app -UntilShutdown } | Should -Throw -ExceptionType ([NativeHTMLKit.DisconnectedException])
        } finally { Close-NativeHTMLKit -Application $app; Stop-MockHost $mock }
    }

    It 'opens and closes connections repeatedly without leaking transport threads' {
        $threads = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt 5; $i++) {
            $mock = Start-MockHost
            $app = Connect-NativeHTMLKit -Endpoint $mock.Endpoint -Token $script:MockToken
            $null = New-NativeHTMLKitWindow -Application $app
            foreach ($t in Get-ReaderThreads $app) { [void]$threads.Add($t) }
            Close-NativeHTMLKit -Application $app
            Stop-MockHost $mock
        }
        @($threads | Where-Object { $_.IsAlive }).Count | Should -Be 0
    }
}

Describe 'Launch credentials' {
    It 'scrubs every UI4ME_* wire variable from the process even when host.hello fails' {
        $mock = Start-MockHost
        try {
            $env:UI4ME_ENDPOINT = $mock.Endpoint; $env:UI4ME_TOKEN = ('e' * 64); $env:UI4ME_APP_ID = 'org.example.X'; $env:UI4ME_PROTOCOL_VERSION = '1'
            { Connect-NativeHTMLKit } | Should -Throw -ExceptionType ([NativeHTMLKit.RpcException])
            foreach ($k in 'UI4ME_ENDPOINT', 'UI4ME_TOKEN', 'UI4ME_APP_ID', 'UI4ME_PROTOCOL_VERSION') { [Environment]::GetEnvironmentVariable($k) | Should -BeNullOrEmpty }
        } finally { Stop-MockHost $mock }
    }
    It 'scrubs them after a successful connection' {
        $mock = Start-MockHost
        try {
            $env:UI4ME_ENDPOINT = $mock.Endpoint; $env:UI4ME_TOKEN = $script:MockToken; $env:UI4ME_APP_ID = 'org.example.X'; $env:UI4ME_PROTOCOL_VERSION = '1'
            $app = Connect-NativeHTMLKit
            $app.Hello.protocol_version | Should -Be 1
            foreach ($k in 'UI4ME_ENDPOINT', 'UI4ME_TOKEN', 'UI4ME_APP_ID', 'UI4ME_PROTOCOL_VERSION') { [Environment]::GetEnvironmentVariable($k) | Should -BeNullOrEmpty }
            Close-NativeHTMLKit -Application $app
        } finally { Stop-MockHost $mock }
    }
}
