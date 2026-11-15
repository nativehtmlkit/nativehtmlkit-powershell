# Optional bounded background work. The transport reader never runs user code.
# PS scriptblocks execute in isolated worker runspaces; completion callbacks are
# dispatched on the owning application runspace by the ordinary event pump, never
# inside another callback (like notifications) and never after Close-NativeHTMLKit.
#
# Timeout and Stop-NativeHTMLKitTask are cancellation REQUESTS. A worker that ignores
# them keeps its slot (per application and per process) until its thread really
# finishes; only then is it disposed. Disposal never waits on a running worker, so
# neither the pump nor Close-NativeHTMLKit can block on one.
$script:NHKTaskStates = New-Object 'System.Collections.Generic.List[object]'
$script:NHKMaximumTasks = 8
$script:NHKMaximumProcessTasks = 32

function Get-NativeHTMLKitTaskStates {
    param($Application)
    return @($script:NHKTaskStates.ToArray() | Where-Object { [object]::ReferenceEquals($_.Application, $Application) })
}

function Remove-NativeHTMLKitFinishedTasks {
    # Reaps every worker (of any application) whose thread has ended and whose outcome
    # was delivered or abandoned. Dispose of an idle runspace does not block.
    foreach ($task in @($script:NHKTaskStates.ToArray())) {
        if (-not $task.AsyncResult.IsCompleted) { continue }
        if (-not ($task.Completed -and ($task.CallbackDelivered -or $task.Abandoned))) { continue }
        [void]$script:NHKTaskStates.Remove($task)
        try { $task.PowerShell.Dispose() } catch { Write-NativeHTMLKitDiagnostic -Event 'task.dispose_failed' -Level 'WARN' -Context @{ task_id = $task.Id; exception_type = $_.Exception.GetType().Name } }
        try { $task.Runspace.Dispose() } catch { Write-NativeHTMLKitDiagnostic -Event 'task.dispose_failed' -Level 'WARN' -Context @{ task_id = $task.Id; exception_type = $_.Exception.GetType().Name } }
        Write-NativeHTMLKitDiagnostic -Event 'task.reaped' -Level 'DEBUG' -Context @{ task_id = $task.Id; was_stopped = [bool]$task.StopRequested }
    }
}

function Request-NativeHTMLKitTaskStop {
    param($Task)
    if ($Task.StopRequested -or $Task.AsyncResult.IsCompleted) { return }
    $Task.StopRequested = $true
    try { [void]$Task.PowerShell.BeginStop($null, $null) }
    catch { Write-NativeHTMLKitDiagnostic -Event 'task.stop_request_failed' -Level 'ERROR' -Context @{ task_id = $Task.Id; exception_type = $_.Exception.GetType().Name } }
}

function Assert-NativeHTMLKitTaskArgument {
    # SDK objects belong to the owning runspace; refuse them anywhere inside the arguments
    # (arrays, lists, dictionaries, PSCustomObject properties), to a bounded depth.
    param($Value, [int]$Depth)
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) { return }
    if ($Depth -gt 8) { throw 'Background task arguments are nested too deeply (more than 8 levels) to check; pass plain data' }
    foreach ($typeName in @('NativeHTMLKit.Application', 'NativeHTMLKit.Window', 'NativeHTMLKit.Document', 'NativeHTMLKit.Node', 'NativeHTMLKit.LiveBitmap', 'NativeHTMLKit.Request', 'NativeHTMLKit.Task', 'NativeHTMLKit.Subscription')) {
        if (Test-NativeHTMLKitType $Value $typeName) { throw "A $typeName belongs to the owning runspace and cannot be passed to a background task; pass plain data and update the UI in -OnCompleted" }
    }
    # `-is` sees through the PSObject wrapper (`.PSObject.BaseObject` would member-enumerate a collection).
    if ($Value -is [NativeHTMLKit.Transport] -or $Value -is [NativeHTMLKit.MappedBitmap]) { throw 'NativeHTMLKit transport objects cannot be passed to a background task' }
    if ($Value -is [System.Collections.IDictionary]) { foreach ($k in @($Value.Keys)) { Assert-NativeHTMLKitTaskArgument $Value[$k] ($Depth + 1) }; return }
    if ($Value -is [System.Collections.IEnumerable]) { foreach ($item in $Value) { Assert-NativeHTMLKitTaskArgument $item ($Depth + 1) }; return }
    if ($Value -is [System.Management.Automation.PSCustomObject]) { foreach ($p in $Value.PSObject.Properties) { Assert-NativeHTMLKitTaskArgument $p.Value ($Depth + 1) } }
}

function Start-NativeHTMLKitTask {
    <#
    .SYNOPSIS
    Starts bounded background PowerShell work in an isolated runspace; -OnCompleted/-OnFailed run later on this runspace.
    .DESCRIPTION
    The scriptblock runs in a new runspace without the caller's variables or modules and must not
    receive NativeHTMLKit window/document/application objects; pass plain data with -ArgumentList.
    Completion callbacks run on the owning runspace during the event pump (Wait-NativeHTMLKit or any
    waiting RPC), never inside another callback. -TimeoutMilliseconds and Stop-NativeHTMLKitTask only
    request cancellation: a worker that ignores it keeps occupying one of the 8 per-application
    (32 per-process) slots until it really ends.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Application,
          [Parameter(Mandatory)][scriptblock]$ScriptBlock,
          [object[]]$ArgumentList = @(),
          [scriptblock]$OnCompleted, [scriptblock]$OnFailed,
          [ValidateRange(0, 3600000)][int]$TimeoutMilliseconds = 0)
    Assert-NativeHTMLKitApplication $Application
    Assert-NativeHTMLKitTaskArgument $ArgumentList 0
    Remove-NativeHTMLKitFinishedTasks
    # Workers whose cancellation was requested STILL occupy a slot until their thread exits.
    if (@(Get-NativeHTMLKitTaskStates $Application).Count -ge $script:NHKMaximumTasks) {
        throw "NativeHTMLKit background task limit ($script:NHKMaximumTasks per application) reached; previous workers, including cancelled ones that are still running, must finish first"
    }
    if ($script:NHKTaskStates.Count -ge $script:NHKMaximumProcessTasks) {
        throw "NativeHTMLKit background task limit ($script:NHKMaximumProcessTasks per process) reached; previous workers, including cancelled ones that are still running, must finish first"
    }
    $runspace = $null; $runner = $null
    try {
        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $runspace.Open()
        $runner = [System.Management.Automation.PowerShell]::Create()
        $runner.Runspace = $runspace
        [void]$runner.AddScript($ScriptBlock.ToString())
        foreach ($argument in $ArgumentList) { [void]$runner.AddArgument($argument) }
        $state = [pscustomobject]@{
            Id = [guid]::NewGuid().ToString('N'); Application = $Application
            PowerShell = $runner; Runspace = $runspace
            AsyncResult = $null; OnCompleted = $OnCompleted; OnFailed = $OnFailed
            StartedUtc = [DateTime]::UtcNow; TimeoutMilliseconds = $TimeoutMilliseconds
            Completed = $false; Result = $null; Failure = $null; Errors = @()
            StopRequested = $false; CallbackDelivered = $false; Abandoned = $false
        }
        $state.PSObject.TypeNames.Insert(0, 'NativeHTMLKit.Task')
        $state.AsyncResult = $runner.BeginInvoke()
        $script:NHKTaskStates.Add($state)
    } catch {
        if ($null -ne $runner) { $runner.Dispose() }
        if ($null -ne $runspace) { $runspace.Dispose() }
        throw
    }
    Write-NativeHTMLKitDiagnostic -Event 'task.started' -Level 'DEBUG' -Context @{ task_id = $state.Id; timeout_ms = $TimeoutMilliseconds }
    return $state
}

function Update-NativeHTMLKitTaskState {
    # Detects completion or deadline expiry. Runs no user code.
    param($Task)
    if ($Task.Completed) { return }
    if ($Task.AsyncResult.IsCompleted) {
        try { $Task.Result = @($Task.PowerShell.EndInvoke($Task.AsyncResult)) }
        catch {
            # EndInvoke wraps the worker's terminating error; report the worker's own exception.
            $failure = $_.Exception
            if ($failure -is [System.Management.Automation.MethodInvocationException] -and $null -ne $failure.InnerException) { $failure = $failure.InnerException }
            $Task.Failure = $failure
        }
        $Task.Errors = @($Task.PowerShell.Streams.Error.ReadAll())
        $Task.Completed = $true
    } elseif ($Task.TimeoutMilliseconds -gt 0 -and ([DateTime]::UtcNow - $Task.StartedUtc).TotalMilliseconds -gt $Task.TimeoutMilliseconds) {
        $Task.Failure = New-Object -TypeName 'System.TimeoutException' -ArgumentList 'Background task exceeded its deadline; cancellation was requested but the worker may still be running'
        $Task.Completed = $true
        Request-NativeHTMLKitTaskStop $Task
        Write-NativeHTMLKitDiagnostic -Event 'task.timeout' -Level 'WARN' -Context @{ task_id = $Task.Id; timeout_ms = $Task.TimeoutMilliseconds }
    }
}

function Invoke-NativeHTMLKitTaskCompletions {
    # Must execute ONLY on the application owner runspace, outside other callbacks.
    # Returns how many task outcomes were delivered.
    param($Application)
    $delivered = 0
    foreach ($task in @(Get-NativeHTMLKitTaskStates $Application)) {
        Update-NativeHTMLKitTaskState $task
        if (-not $task.Completed -or $task.CallbackDelivered -or $task.Abandoned) { continue }
        if ($Application.Closed) { continue }
        $task.CallbackDelivered = $true
        $delivered++
        $started = [Diagnostics.Stopwatch]::StartNew()
        try {
            if ($null -ne $task.Failure) {
                Write-NativeHTMLKitDiagnostic -Event 'task.failed' -Level 'ERROR' -Context @{ task_id = $task.Id; exception_type = $task.Failure.GetType().Name }
                if ($null -ne $task.OnFailed) { $null = Invoke-NativeHTMLKitCallback $Application $task.OnFailed @($task.Failure) }
                else { Write-Warning ('NativeHTMLKit background task failed: ' + $task.Failure.GetType().Name) }
            } else {
                Write-NativeHTMLKitDiagnostic -Event 'task.completed' -Level 'DEBUG' -DurationMs ([long]([DateTime]::UtcNow - $task.StartedUtc).TotalMilliseconds) -Context @{ task_id = $task.Id; errors = $task.Errors.Count }
                if ($null -ne $task.OnCompleted) { $null = Invoke-NativeHTMLKitCallback $Application $task.OnCompleted @(,$task.Result) }
            }
            Write-NativeHTMLKitDiagnostic -Event 'callback.completed' -Level 'TRACE' -DurationMs $started.ElapsedMilliseconds -Context @{ role = 'task_completion'; task_id = $task.Id }
        } catch {
            # Isolated like document event handlers: logged, counted, never thrown into
            # an unrelated RPC wait that happened to pump this completion.
            Register-NativeHTMLKitCallbackFailure $Application 'task_completion' $_ @{ task_id = $task.Id }
        }
    }
    Remove-NativeHTMLKitFinishedTasks
    return $delivered
}

function Receive-NativeHTMLKitTask {
    <#
    .SYNOPSIS
    Reports a background task's state and result; -Wait keeps pumping host messages until it completes.
    .DESCRIPTION
    CancellationPending is true while a timed-out or stopped worker is still running. -Wait pumps the
    application's host messages (so lifecycle requests are answered) and throws System.TimeoutException
    after -TimeoutMilliseconds (-1 waits indefinitely) without cancelling the task. Errors holds the
    worker's non-terminating error records.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Task, [switch]$Wait, [ValidateRange(-1, 2147483647)][int]$TimeoutMilliseconds = -1)
    if (-not (Test-NativeHTMLKitType $Task 'NativeHTMLKit.Task')) { throw 'Expected a NativeHTMLKit.Task from Start-NativeHTMLKitTask' }
    $app = $Task.Application
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Update-NativeHTMLKitTaskState $Task
    while ($Wait -and -not $Task.Completed) {
        if ($TimeoutMilliseconds -ge 0 -and $clock.ElapsedMilliseconds -ge $TimeoutMilliseconds) {
            throw (New-Object -TypeName 'System.TimeoutException' -ArgumentList "NativeHTMLKit background task did not complete within $TimeoutMilliseconds ms; it was not cancelled")
        }
        if (-not $app.Closed -and -not $app.Disconnected) {
            # A lost host does not stop a healthy local worker: keep waiting for it.
            try { [void](Invoke-NativeHTMLKitPump $app 25) } catch [NativeHTMLKit.DisconnectedException] { Start-Sleep -Milliseconds 25 }
        } else { Start-Sleep -Milliseconds 25 }
        Update-NativeHTMLKitTaskState $Task
    }
    if (-not $app.Dispatching -and -not $app.Closed) { $null = Invoke-NativeHTMLKitTaskCompletions -Application $app }
    else { Remove-NativeHTMLKitFinishedTasks }
    return [pscustomobject]@{ Id = $Task.Id; Completed = $Task.Completed; Result = $Task.Result
        Failure = $Task.Failure; Errors = $Task.Errors
        CancellationPending = ($Task.StopRequested -and -not $Task.AsyncResult.IsCompleted) }
}

function Stop-NativeHTMLKitTask {
    <#
    .SYNOPSIS
    Requests cancellation of a background task; -OnFailed later receives an OperationCanceledException.
    .DESCRIPTION
    Not a guarantee: a worker blocked in native or .NET code may keep running and keeps its slot until
    it ends (Receive-NativeHTMLKitTask reports CancellationPending). Its result is discarded.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Task)
    if (-not (Test-NativeHTMLKitType $Task 'NativeHTMLKit.Task')) { throw 'Expected a NativeHTMLKit.Task from Start-NativeHTMLKitTask' }
    Update-NativeHTMLKitTaskState $Task
    if ($Task.Completed) { return }
    $Task.Failure = New-Object -TypeName 'System.OperationCanceledException' -ArgumentList 'Background task cancellation was requested; the worker may still be running'
    $Task.Completed = $true
    Request-NativeHTMLKitTaskStop $Task
    Write-NativeHTMLKitDiagnostic -Event 'task.stop_requested' -Level 'DEBUG' -Context @{ task_id = $Task.Id }
}

function Stop-NativeHTMLKitTasks {
    # Close-NativeHTMLKit: request stop of every unfinished worker without waiting; no callback
    # runs after close. Finished workers are disposed now, the rest by a later reap.
    param($Application)
    foreach ($task in @(Get-NativeHTMLKitTaskStates $Application)) {
        Update-NativeHTMLKitTaskState $task
        if (-not $task.Completed) {
            $task.Failure = New-Object -TypeName 'System.OperationCanceledException' -ArgumentList 'The NativeHTMLKit application was closed before the background task finished'
            $task.Completed = $true
        }
        $task.Abandoned = $true
        Request-NativeHTMLKitTaskStop $task
    }
    Remove-NativeHTMLKitFinishedTasks
}
