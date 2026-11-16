# Reference: objects, errors, threading and limits

Applies to `NativeHTMLKit` 0.1.2 with Core 1.0.3 (wire protocol v1).

## Handle objects

The SDK returns `PSCustomObject` handles whose first type name identifies them
(`$x.PSObject.TypeNames[0]`). Use the documented read-only properties; other properties are SDK
internals and may change.

| Type name | Returned by | Documented properties | Becomes stale when |
|---|---|---|---|
| `NativeHTMLKit.Application` | `Start-NativeHTMLKitScript`, `Connect-NativeHTMLKit` | `Hello` (host.hello result) | `Close-NativeHTMLKit`; the host disconnects (`DisconnectedException`) |
| `NativeHTMLKit.Window` | `New-NativeHTMLKitWindow` | `Id`, `Closed`, `Application`, `Document` | the window closes, `app.shutdown`, application close |
| `NativeHTMLKit.Document` | `Open-NativeHTMLKitHtml`, `Open-NativeHTMLKitFile` | `Id`, `Window`, `Retired` | another document is loaded into the window, `Remove-NativeHTMLKitDocument`, a fatal `document.error`, window close |
| `NativeHTMLKit.Node` | `Get-NativeHTMLKitNode` | `Id` (reference string), `Document` | its document is retired (SDK); the element is removed or replaced (host, code -32004) |
| `NativeHTMLKit.Subscription` | `Register-NativeHTMLKitDocumentEvent` | `Type`, `Element`, `Document` | its document is retired |
| `NativeHTMLKit.LiveBitmap` | `New-NativeHTMLKitLiveBitmap` | `Id`, `Width`, `Height`, `Stride`, `SlotBytes`, `Slots`, `Sequence`, `Closed`, `Document` | `Remove-NativeHTMLKitLiveBitmap`, its document is retired |
| `NativeHTMLKit.Request` | `Start-NativeHTMLKitRpc`, `Show-NativeHTMLKitFileDialog -NoWait` | `Id`, `Method`, `Completed`, `Cancelled`, `Failed` | awaited once, or stopped |
| `NativeHTMLKit.Task` | `Start-NativeHTMLKitTask` | `Id` | - (inspect with `Receive-NativeHTMLKitTask`) |

Results of host queries (`Get-NativeHTMLKitWindow`, `Get-NativeHTMLKitCapabilities`, document
commands, ...) are plain `PSCustomObject`s parsed from the host's JSON: field names are the
protocol's snake_case names, JSON arrays become `object[]`, numbers become `[long]` or `[double]`.

**One-array results.** `Get-NativeHTMLKitWindowList`, `Get-NativeHTMLKitStylesheets` and
`Get-NativeHTMLKitSelectOptions` return their list as one array object (`return ,@(...)`). Assign
the result to a variable and use it; `@(Get-NativeHTMLKitWindowList ...)` or piping produces a
single element that contains the whole array.

## Exceptions

All failures are terminating errors. The SDK's own exception types live in the `NativeHTMLKit`
namespace and are available after the first connection (`Start-NativeHTMLKitScript` loads them),
so `catch [NativeHTMLKit.RpcException] { }` works in scripts.

| Exception | Base type | Thrown when |
|---|---|---|
| `NativeHTMLKit.RpcException` | `System.Exception` | The host answered a request with an error. Properties: `Method`, `Code`, `RpcMessage`, `RpcData`. |
| `NativeHTMLKit.StaleObjectException` | `InvalidOperationException` | A window, document, node, bitmap or request handle is no longer current. |
| `NativeHTMLKit.DisconnectedException` | `System.IO.IOException` | The connection is closed or the host went away; a waiting request's outcome is unknown. |
| `NativeHTMLKit.RpcTimeoutException` | `TimeoutException` | A request wait expired (cancellation was requested; the host may still complete it). |
| `NativeHTMLKit.BusyException` | `InvalidOperationException` | 128 requests are outstanding; await or stop earlier ones. |
| `NativeHTMLKit.ProtocolException` | `System.Exception` | The peer sent a malformed or unexpected message; fatal to the connection. |
| `System.TimeoutException` | | `Receive-NativeHTMLKitTask -Wait -TimeoutMilliseconds` expired; a task deadline (`-OnFailed`). |
| `System.OperationCanceledException` | | A stopped task (`-OnFailed`). |
| `System.Management.Automation.RuntimeException` | | Parameter misuse detected by the SDK, for example `Expected a NativeHTMLKit.Window from New-NativeHTMLKitWindow`, `Use -Element or -Node, not both`. |

### Host error codes (`RpcException.Code`)

| Code | Name | Typical cause |
|---|---|---|
| -32601 | method not found | Unknown method in `Invoke-NativeHTMLKitRpc`. |
| -32602 | invalid params | Unknown element id (`Unknown element ID: x`), invalid value (`color_scheme must be light, dark or system`). |
| -32603 | internal error | Host-side failure. |
| -32001 | unsupported | The service is not available in this session (headless: clipboard, file dialogs, external open, attention). |
| -32002 | unavailable | A resource or service is temporarily unavailable. |
| -32003 | denied | Refused by host policy (for example an executable as open target). |
| -32004 | closed | The window, document, bitmap or node no longer exists (`Stale node reference`). |
| -32005 | busy | A limit was reached, for example a second native dialog on one window. |
| -32006 | cancelled | The request was cancelled. |
| -32008 | invalid state | Not allowed in the current lifecycle phase, for example `Set-NativeHTMLKitReady` without a window. |
| -32009 | timeout | A host-side deadline expired. |

## Threading and runspaces

- Every SDK object belongs to the runspace that created the application. Use it only from that
  runspace: your script and the callbacks the SDK runs for it.
- A .NET reader thread receives frames; it never runs PowerShell code.
- Callbacks (document events, notifications, close/quit policies, task completions) run one at a
  time on the owning runspace while it pumps: inside `Wait-NativeHTMLKit` or inside any command
  that waits for a host reply. See [events](events.md#when-callbacks-run).
- Background work runs in separate runspaces through `Start-NativeHTMLKitTask` and communicates by
  plain data and completion callbacks. Do not use `Start-Job`, `Start-ThreadJob`,
  `ForEach-Object -Parallel` or your own runspaces to call SDK commands.

## Limits

| Limit | Value |
|---|---|
| Message frame | 2 MiB (2,097,152 bytes) of JSON per request or reply |
| Outstanding requests per application | 128 |
| Deferred notifications while a callback runs | 128 (more are dropped and counted) |
| Callback nesting depth | 32 |
| Subscriptions per document | 256 |
| Background tasks | 8 unfinished per application, 32 per process |
| Windows | `Start-NativeHTMLKitScript -MaxWindows` (1-64, default 16) |
| Live bitmap size | 1-4096 x 1-4096 pixels, 2 or 3 slots |
| Resource bundle | 256 entries, 1 MiB decoded per registration |
| SDK diagnostic history | 2048 records |
| Default request timeout | 15 s; document loads 30 s; external open 60 s; dialogs unlimited |
