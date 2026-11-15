# Start-/Receive-/Stop-NativeHTMLKitTask lifecycle and fault behavior against a local peer.
# Pester 5+. PowerShell 7.2+ (Linux/Windows) or Windows PowerShell 5.1.
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module $script:ModuleManifest -Force -ErrorAction Stop
    $script:Module = Get-Module NativeHTMLKit
    function Get-TaskCount($Application) { & $script:Module { param($a) @(Get-NativeHTMLKitTaskStates $a).Count } $Application }
    function Get-ProcessTaskCount { & $script:Module { $script:NHKTaskStates.Count } }
    # A worker that ignores PowerShell's stop request: Thread.Sleep is not interruptible.
    $script:Stubborn = { param($ms) [System.Threading.Thread]::Sleep([int]$ms); 'finished' }
    function Pump-For($Application, [int]$Milliseconds) {
        $clock = [Diagnostics.Stopwatch]::StartNew(); $longest = 0
        while ($clock.ElapsedMilliseconds -lt $Milliseconds) {
            $one = [Diagnostics.Stopwatch]::StartNew()
            [void](Wait-NativeHTMLKit -Application $Application -TimeoutMilliseconds 20)
            $longest = [Math]::Max($longest, $one.ElapsedMilliseconds)
        }
        return $longest
    }
}

Describe 'NativeHTMLKit background tasks' {
    BeforeAll {
        $script:mock = Start-MockHost
        $script:app = Connect-NativeHTMLKit -Endpoint $script:mock.Endpoint -Token $script:MockToken
        $script:win = New-NativeHTMLKitWindow -Application $script:app -Title 'tasks'
        $script:doc = Open-NativeHTMLKitHtml -Window $script:win -Html '<p id="x">x</p>'
    }
    AfterAll {
        if ($null -ne $script:app) { Close-NativeHTMLKit -Application $script:app }
        Stop-MockHost $script:mock
    }

    It 'runs completion callbacks on the owning runspace and returns worker output' {
        $script:owner = $null; $script:got = $null
        $t = Start-NativeHTMLKitTask -Application $script:app -ArgumentList @(20) -ScriptBlock { param($n) [runspace]::DefaultRunspace.InstanceId.Guid; $n * 2 } -OnCompleted { param($r) $script:owner = [runspace]::DefaultRunspace.InstanceId.Guid; $script:got = $r }
        Wait-Until { $null -ne $script:got } $script:app | Should -BeTrue
        $script:owner | Should -Be ([runspace]::DefaultRunspace.InstanceId.Guid)
        $script:got[0] | Should -Not -Be $script:owner   # the worker ran in another runspace
        $script:got[1] | Should -Be 40
        (Receive-NativeHTMLKitTask -Task $t).Completed | Should -BeTrue
        Get-TaskCount $script:app | Should -Be 0
    }

    It 'passes the worker''s own terminating error to -OnFailed' {
        $script:failure = $null
        $null = Start-NativeHTMLKitTask -Application $script:app -ScriptBlock { throw 'worker broke' } -OnFailed { param($e) $script:failure = $e }
        Wait-Until { $null -ne $script:failure } $script:app | Should -BeTrue
        $script:failure.Message | Should -Be 'worker broke'
        $script:failure | Should -Not -BeOfType ([System.Management.Automation.MethodInvocationException])
    }

    It 'reports non-terminating worker errors instead of dropping them' {
        $t = Start-NativeHTMLKitTask -Application $script:app -ScriptBlock { Write-Error 'soft failure'; 'value' }
        $r = Receive-NativeHTMLKitTask -Task $t -Wait -TimeoutMilliseconds 10000
        $r.Result | Should -Be 'value'
        @($r.Errors).Count | Should -Be 1
        $r.Failure | Should -BeNullOrEmpty
    }

    It 'isolates a throwing completion callback, counts it, and keeps the connection usable' {
        $before = $script:app.CallbackFailures
        $null = Start-NativeHTMLKitTask -Application $script:app -ScriptBlock { 1 } -OnCompleted { throw 'callback exploded' }
        $null = Start-NativeHTMLKitTask -Application $script:app -ScriptBlock { 2 } -OnFailed { throw 'never' } -OnCompleted { $script:second = $true }
        $script:second = $false
        { Pump-For $script:app 1500 } | Should -Not -Throw
        $script:app.CallbackFailures | Should -Be ($before + 1)
        $script:second | Should -BeTrue
        Set-NativeHTMLKitDocumentText -Document $script:doc -Element x -Text 'still works'
        Get-NativeHTMLKitDocumentText -Document $script:doc -Element x | Should -Be 'still works'
    }

    It 'never runs a completion callback inside another callback''s nested pump' {
        $script:order = New-Object System.Collections.ArrayList
        $sub = Register-NativeHTMLKitDocumentEvent -Document $script:doc -Type click -Element go -Callback {
            [void]$script:order.Add('handler-start')
            $clock = [Diagnostics.Stopwatch]::StartNew()
            # Nested RPCs pump for ~1 s while the worker below finishes.
            while ($clock.ElapsedMilliseconds -lt 1000) { $null = Get-NativeHTMLKitDocumentText -Document $script:doc -Element x; Start-Sleep -Milliseconds 20 }
            [void]$script:order.Add('handler-end')
        }
        $null = Start-NativeHTMLKitTask -Application $script:app -ScriptBlock { Start-Sleep -Milliseconds 300; 'w' } -OnCompleted { [void]$script:order.Add('task') }
        $null = Invoke-NativeHTMLKitDocumentCommand -Document $script:doc -Operation emit -Parameters @{ events = @(@{ type = 'click'; element = 'go' }) }
        Wait-Until { $script:order.Count -ge 3 } $script:app 10 | Should -BeTrue
        ($script:order -join ',') | Should -Be 'handler-start,handler-end,task'
        Unregister-NativeHTMLKitDocumentEvent -Subscription $sub
    }

    It 'allows host RPCs from inside a completion callback' {
        $script:readBack = $null
        $null = Start-NativeHTMLKitTask -Application $script:app -ScriptBlock { 'from worker' } -OnCompleted {
            param($r)
            Set-NativeHTMLKitDocumentText -Document $script:doc -Element x -Text ([string]$r[0])
            $script:readBack = Get-NativeHTMLKitDocumentText -Document $script:doc -Element x
        }
        Wait-Until { $null -ne $script:readBack } $script:app | Should -BeTrue
        $script:readBack | Should -Be 'from worker'
    }

    It 'keeps timed-out workers that ignore cancellation in their slots without blocking the pump' {
        $script:timeouts = 0
        $tasks = @(1..8 | ForEach-Object {
            Start-NativeHTMLKitTask -Application $script:app -ScriptBlock $script:Stubborn -ArgumentList @(2500) -TimeoutMilliseconds 150 -OnFailed { param($e) if ($e -is [TimeoutException]) { $script:timeouts++ } } -OnCompleted { throw 'a timed-out task must not complete' }
        })
        { Start-NativeHTMLKitTask -Application $script:app -ScriptBlock { 1 } } | Should -Throw '*limit*'
        $longest = Pump-For $script:app 700
        $longest | Should -BeLessThan 400      # the owner pump never waits for a worker
        $script:timeouts | Should -Be 8
        foreach ($t in $tasks) { (Receive-NativeHTMLKitTask -Task $t).CancellationPending | Should -BeTrue }
        Get-TaskCount $script:app | Should -Be 8
        { Start-NativeHTMLKitTask -Application $script:app -ScriptBlock { 1 } } | Should -Throw '*cancelled ones that are still running*'
        # Once the threads really end, their slots are released and nothing leaks.
        Wait-Until { (Get-TaskCount $script:app) -eq 0 } $script:app 10 | Should -BeTrue
        $script:app.CallbackFailures | Should -Be 1   # only the deliberate one above
        $t = Start-NativeHTMLKitTask -Application $script:app -ScriptBlock { 'free again' }
        (Receive-NativeHTMLKitTask -Task $t -Wait -TimeoutMilliseconds 10000).Result | Should -Be 'free again'
    }

    It 'stops a cooperative worker on request and frees its slot' {
        $script:cancelled = $null
        $t = Start-NativeHTMLKitTask -Application $script:app -ScriptBlock { Start-Sleep -Seconds 30 } -OnFailed { param($e) $script:cancelled = $e }
        Start-Sleep -Milliseconds 200
        Stop-NativeHTMLKitTask -Task $t
        Wait-Until { $null -ne $script:cancelled } $script:app | Should -BeTrue
        $script:cancelled | Should -BeOfType ([OperationCanceledException])
        Wait-Until { (Get-TaskCount $script:app) -eq 0 } $script:app 5 | Should -BeTrue
    }

    It 'pumps host requests while Receive -Wait waits, and times out without cancelling' {
        $script:asked = 0
        Set-NativeHTMLKitBeforeClose -Window $script:win -Callback { $script:asked++; $false }
        $t = Start-NativeHTMLKitTask -Application $script:app -ScriptBlock { Start-Sleep -Milliseconds 600; 'slow' }
        $close = Start-NativeHTMLKitRpc -Application $script:app -Method 'window.request_close' -Parameters @{ window_id = $script:win.Id }
        { Receive-NativeHTMLKitTask -Task $t -Wait -TimeoutMilliseconds 100 } | Should -Throw -ExceptionType ([TimeoutException])
        $t.StopRequested | Should -BeFalse
        (Receive-NativeHTMLKitTask -Task $t -Wait -TimeoutMilliseconds 10000).Result | Should -Be 'slow'
        $script:asked | Should -Be 1           # the veto request was answered during the wait
        $null = Wait-NativeHTMLKitRpc -Request $close
        $script:win.Closed | Should -BeFalse
        Set-NativeHTMLKitBeforeClose -Window $script:win -Callback $null
    }

    It 'refuses SDK handles as worker arguments' {
        { Start-NativeHTMLKitTask -Application $script:app -ScriptBlock { 1 } -ArgumentList @($script:doc) } | Should -Throw '*cannot be passed to a background task*'
    }

    It 'does not accumulate finished workers' {
        for ($i = 0; $i -lt 40; $i++) {
            $t = Start-NativeHTMLKitTask -Application $script:app -ScriptBlock { param($n) $n } -ArgumentList @($i)
            (Receive-NativeHTMLKitTask -Task $t -Wait -TimeoutMilliseconds 10000).Result | Should -Be $i
        }
        Get-TaskCount $script:app | Should -Be 0
    }
}

Describe 'NativeHTMLKit tasks during close and quit' {
    It 'returns promptly from Close-NativeHTMLKit with a busy worker, runs no callback afterwards, and reaps it later' {
        $mock = Start-MockHost
        $app = Connect-NativeHTMLKit -Endpoint $mock.Endpoint -Token $script:MockToken
        try {
            $script:late = 0
            $t = Start-NativeHTMLKitTask -Application $app -ScriptBlock $script:Stubborn -ArgumentList @(1500) -OnCompleted { $script:late++ } -OnFailed { $script:late++ }
            $clock = [Diagnostics.Stopwatch]::StartNew()
            Close-NativeHTMLKit -Application $app
            $clock.ElapsedMilliseconds | Should -BeLessThan 1000
            $r = Receive-NativeHTMLKitTask -Task $t
            $r.Completed | Should -BeTrue
            $r.Failure | Should -BeOfType ([OperationCanceledException])
            $r.CancellationPending | Should -BeTrue
            Get-TaskCount $app | Should -Be 1     # still counted while its thread runs
            $r = Receive-NativeHTMLKitTask -Task $t -Wait -TimeoutMilliseconds 100   # completed already: returns at once
            Start-Sleep -Milliseconds 2000
            (Receive-NativeHTMLKitTask -Task $t).CancellationPending | Should -BeFalse
            Get-TaskCount $app | Should -Be 0
            $script:late | Should -Be 0
        } finally { Close-NativeHTMLKit -Application $app; Stop-MockHost $mock }
    }

    It 'answers a throwing quit policy with a veto, then quits and shuts down with a worker still running' {
        $mock = Start-MockHost
        $app = Connect-NativeHTMLKit -Endpoint $mock.Endpoint -Token $script:MockToken
        try {
            Set-NativeHTMLKitBeforeQuit -Application $app -Callback { throw 'policy bug' }
            (Request-NativeHTMLKitQuit -Application $app).allowed | Should -BeFalse
            $app.CallbackFailures | Should -Be 1
            $t = Start-NativeHTMLKitTask -Application $app -ScriptBlock $script:Stubborn -ArgumentList @(1500)
            Set-NativeHTMLKitBeforeQuit -Application $app -Callback { $true }
            (Request-NativeHTMLKitQuit -Application $app).allowed | Should -BeTrue
            Wait-NativeHTMLKit -Application $app -UntilShutdown
            $clock = [Diagnostics.Stopwatch]::StartNew()
            Close-NativeHTMLKit -Application $app
            $clock.ElapsedMilliseconds | Should -BeLessThan 1000
            (Receive-NativeHTMLKitTask -Task $t).Failure | Should -BeOfType ([OperationCanceledException])
        } finally { Close-NativeHTMLKit -Application $app; Stop-MockHost $mock }
    }

    It 'bounds the process-wide worker count across applications' {
        $limit = & $script:Module { $script:NHKMaximumProcessTasks }
        $limit | Should -Be 32
        & $script:Module { $script:NHKMaximumProcessTasks = 3 }
        $mock = Start-MockHost
        $app = Connect-NativeHTMLKit -Endpoint $mock.Endpoint -Token $script:MockToken
        try {
            Wait-Until { (Get-ProcessTaskCount) -eq 0 } $app 5 | Out-Null
            $base = Get-ProcessTaskCount
            1..(3 - $base) | ForEach-Object { $null = Start-NativeHTMLKitTask -Application $app -ScriptBlock { Start-Sleep -Milliseconds 800 } }
            { Start-NativeHTMLKitTask -Application $app -ScriptBlock { 1 } } | Should -Throw '*per process*'
        } finally {
            & $script:Module { $script:NHKMaximumProcessTasks = 32 }
            Close-NativeHTMLKit -Application $app; Stop-MockHost $mock
        }
    }
}
