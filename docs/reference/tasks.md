# Reference: background tasks

Run slow PowerShell work (file scans, hashing, web requests, `Get-WinEvent` queries) without
freezing the window. How-to: [Background tasks](../guides/background-work.md).

## Rules

- The `-ScriptBlock` runs in a **new, isolated runspace**: none of the caller's variables,
  functions or imported modules exist there (import what it needs inside the block). Its text is
  re-parsed in that runspace, so a closure's captured variables do not travel either.
- Pass inputs with `-ArgumentList` as plain data. NativeHTMLKit objects (application, window,
  document, node, bitmap, request, task, subscription) are refused anywhere inside the arguments
  (checked 8 levels deep) because they belong to the owning runspace.
- The task's output becomes the result. `-OnCompleted` and `-OnFailed` run later **on the owning
  runspace**, while it pumps events (`Wait-NativeHTMLKit` or any waiting command), never inside
  another callback, and never after `Close-NativeHTMLKit`. Update the UI there.
- At most **8** unfinished tasks per application and **32** per process. A worker whose
  cancellation was requested still occupies its slot until its thread really ends.
- `-TimeoutMilliseconds` and `Stop-NativeHTMLKitTask` only **request** cancellation (PowerShell
  `BeginStop`). Interruptible commands such as `Start-Sleep` stop; a worker blocked in .NET or
  native code may keep running. Its eventual result is discarded.

### Start-NativeHTMLKitTask

Alias: `Start-NHKTask`

Starts the scriptblock in an isolated runspace and returns a task handle.

```text
Start-NativeHTMLKitTask [-Application] <Object> [-ScriptBlock] <scriptblock> [[-ArgumentList] <Object[]>] [[-OnCompleted] <scriptblock>] [[-OnFailed] <scriptblock>] [[-TimeoutMilliseconds] <int>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Application` | `NativeHTMLKit.Application` | yes | - | The application that owns the task and runs its callbacks. |
| `-ScriptBlock` | `scriptblock` | yes | - | Work to run. Receives the `-ArgumentList` values as positional arguments. |
| `-ArgumentList` | `object[]` | no | `@()` | Plain-data arguments. Pass one array argument as `@(, $array)`. |
| `-OnCompleted` | `scriptblock` | no | - | Runs on the owning runspace after success; receives the task output as one array (`param($result)`; `$result[0]` is the first output object). |
| `-OnFailed` | `scriptblock` | no | - | Runs on the owning runspace after a terminating error, a timeout (`System.TimeoutException`) or a stop (`System.OperationCanceledException`); receives the exception. Without it, a failure is written as a warning. |
| `-TimeoutMilliseconds` | `int` | no | `0` | Deadline after which cancellation is requested and the task fails with `TimeoutException`; `0` means no deadline. Range 0 to 3600000. |

**Returns** `NativeHTMLKit.Task` (property `Id`; use the cmdlets below to inspect it).
**Errors** a refused argument (`A NativeHTMLKit.Window belongs to the owning runspace...`); the task
limit (`NativeHTMLKit background task limit (8 per application) reached...`).

Non-terminating errors written by the worker (`Write-Error`) do not fail the task; they are
available as `Errors` from `Receive-NativeHTMLKitTask`. Exceptions thrown by `-OnCompleted` or
`-OnFailed` are isolated like event callbacks (stderr message, `CallbackFailures` counter).

```powershell
$null = Start-NativeHTMLKitTask -Application $app -ArgumentList @($computer) -TimeoutMilliseconds 30000 -ScriptBlock {
    param([string]$Name)
    Get-CimInstance -ClassName Win32_Service -ComputerName $Name | Select-Object Name, State, StartMode
} -OnCompleted {
    param($services)
    Show-Services $services          # runs on the UI runspace
} -OnFailed {
    param($failure)
    Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text ('Query failed: ' + $failure.Message)
}
```

### Receive-NativeHTMLKitTask

Alias: `Receive-NHKTask`

Reports a task's state and, with `-Wait`, pumps host messages until it completes. Calling it also
delivers any due completion callbacks (when not called from inside a callback).

```text
Receive-NativeHTMLKitTask [-Task] <Object> [[-TimeoutMilliseconds] <int>] [-Wait] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Task` | `NativeHTMLKit.Task` | yes | - | The task. |
| `-Wait` | `switch` | no | off | Wait (pumping events) until the task completes. |
| `-TimeoutMilliseconds` | `int` | no | `-1` | With `-Wait`: give up after this time with `System.TimeoutException` (the task is not cancelled); `-1` waits indefinitely. Range -1 to 2147483647. |

**Returns** `@{ Id; Completed; Result; Failure; Errors; CancellationPending }`.
`CancellationPending` is `$true` while a stopped or timed-out worker is still running.

### Stop-NativeHTMLKitTask

Alias: `Stop-NHKTask`

Requests cancellation. The task is marked completed with an `OperationCanceledException`, which
`-OnFailed` receives; does nothing for a completed task.

```text
Stop-NativeHTMLKitTask [-Task] <Object> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Task` | `NativeHTMLKit.Task` | yes | - | The task. |
