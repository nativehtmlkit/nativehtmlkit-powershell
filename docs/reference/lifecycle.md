# Reference: application lifecycle

Module `NativeHTMLKit` 0.1.2 (Core 1.0.3, wire protocol v1). Starting the host, connecting,
signalling readiness, pumping events, quitting and closing. Task-oriented explanation:
[Script lifecycle guide](../guides/script-lifecycle.md).

All commands in this module are advanced functions: parameters bind by name or by position in
the order shown in the syntax blocks, and common parameters (`-Verbose`, `-ErrorAction`, ...) are
accepted. The module sets `$ErrorActionPreference = 'Stop'` internally, so every failure
described below is a terminating error that `try`/`catch` can handle.

## Typical order

```powershell
Import-Module NativeHTMLKit
$app = Start-NativeHTMLKitScript -Name 'My tool'          # 1. host + backend connection
try {
    $window = New-NativeHTMLKitWindow -Application $app    # 2. at least one window
    $doc = Open-NativeHTMLKitHtml -Window $window -Html '<p id="s">Ready</p>'
    # 3. register events, policies, notifications
    Set-NativeHTMLKitReady -Application $app               # 4. startup finished
    Wait-NativeHTMLKit -Application $app -UntilShutdown    # 5. run callbacks until quit
} finally {
    Close-NativeHTMLKit -Application $app                  # 6. retire every handle
}
```

### Start-NativeHTMLKitScript

Alias: `Start-NHKScript`

Runs an ordinary `.ps1` file as a NativeHTMLKit app and returns the connected
`NativeHTMLKit.Application`. It has two roles, chosen from the process environment:

- **Launcher role** (you ran the script with `pwsh -File app.ps1` or `powershell.exe -File app.ps1`):
  writes a private temporary `app.toml`, starts the native host (`run --app`, plus `--headless`
  when `NATIVEHTMLKIT_TEST_MODE=1`), and waits. The host runs **the same script again** with the
  same PowerShell edition (`-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File`) and
  the same arguments, as its supervised backend. When the host exits, the launcher calls
  `exit <host exit code>`: code below this call never runs in the launcher process.
- **Backend role** (`UI4ME_ENDPOINT` and `UI4ME_TOKEN` are set by the host): connects like
  `Connect-NativeHTMLKit`, removes the launch variables from the process environment so child
  processes cannot see them, and returns the application.

Everything above the call runs twice. Keep side effects (files, prompts, network calls) below it.
On Linux the launcher starts the host through `setpriv --pdeathsig TERM` when available, so the
host stops even if the launcher is killed. The temporary manifest folder is created with mode
0700 (Linux) or in the per-user `%TEMP%` (Windows) and removed afterwards; folders left by a
killed launcher are removed after one day.

```text
Start-NativeHTMLKitScript [[-Name] <string>] [[-AppId] <string>] [[-Version] <string>] [[-Icon] <string>] [[-Instance] <string>] [[-StartupTimeoutMilliseconds] <int>] [[-ShutdownTimeoutMilliseconds] <int>] [[-MaxWindows] <int>] [[-ArgumentList] <string[]>] [[-ScriptPath] <string>] [[-Diagnostics] <string>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Name` | `string` | no | - | Application name shown by the desktop (1-128 characters, no control characters). Default: the script file name without extension. |
| `-AppId` | `string` | no | - | Reverse-DNS identity such as `org.example.MyTool` (letters, digits, `_`, `-`, dot-separated, at most 128). Default: `local.nativehtmlkit.<name-slug>.h<12 hex digits of the script path hash>`, stable per script path. |
| `-Version` | `string` | no | - | Application version string (1-128 characters). |
| `-Icon` | `string` | no | - | Path of an application icon file; must exist. |
| `-Instance` | `string` | no | `'single'` | `single` forwards a second launch of the same AppId to the running app; `multiple` allows several instances. One of: `single`, `multiple`. |
| `-StartupTimeoutMilliseconds` | `int` | no | `30000` | Host limit for the backend to connect and call `Set-NativeHTMLKitReady`. Range 1000 to 300000. |
| `-ShutdownTimeoutMilliseconds` | `int` | no | `5000` | Host limit for the backend to exit after shutdown. Range 100 to 120000. |
| `-MaxWindows` | `int` | no | `16` | Maximum number of windows the host allows for this app. Range 1 to 64. |
| `-ArgumentList` | `string[]` | no | - | Arguments for the backend run. Default: the arguments that followed the script on the `pwsh`/`powershell.exe` command line. |
| `-ScriptPath` | `string` | no | - | Script to run as the backend. Default: the calling script (`$MyInvocation.PSCommandPath`). Required when called outside a script file. |
| `-Diagnostics` | `string` | no | `'Normal'` | Sets `NATIVEHTMLKIT_DIAGNOSTICS` for the host and backend when not `Normal` (`Off`, `Debug`, `Trace`). See [diagnostics](diagnostics.md). One of: `Off`, `Normal`, `Debug`, `Trace`. |

**Returns** `NativeHTMLKit.Application` (backend role only).

**Errors**

- Invalid `-Name`, `-Version` or `-AppId`: `Name must be 1-128 characters...`, `AppId must be a dot-separated ASCII identity...`.
- Called from the console instead of a file: `Start-NativeHTMLKitScript must be called from a .ps1 script file`.
- Only one of `UI4ME_ENDPOINT`/`UI4ME_TOKEN` set, or a backend started by a launcher without a connection: refuses to start a second host.
- Host binary missing or failing its integrity check: see [Get-NativeHTMLKitHostPath](#get-nativehtmlkithostpath).
- Connection failure in the backend role: as for `Connect-NativeHTMLKit`.

```powershell
param([string]$Folder)                       # parameters are forwarded to the backend run
Import-Module NativeHTMLKit
$app = Start-NativeHTMLKitScript -Name 'Folder report' -AppId 'org.example.FolderReport' -Instance multiple
```

### Connect-NativeHTMLKit

Alias: `Connect-NHK`

Connects a backend that a manifest-based launch started (`Start-NativeHTMLKitHost`, or
`nativehtmlkit-host run --app app.toml`). It reads the endpoint and token, clears the four
`UI4ME_*` launch variables from the process environment before anything can fail, opens the Unix
socket or Windows named pipe and authenticates with `host.hello` (protocol version 1). Most
scripts use `Start-NativeHTMLKitScript`, which calls this in its backend role.

```text
Connect-NativeHTMLKit [[-Endpoint] <string>] [[-Token] <string>] [[-ConnectTimeoutMilliseconds] <int>] [-SkipTokenValidation] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Endpoint` | `string` | no | `$env:UI4ME_ENDPOINT` | Socket path or pipe name. Default: `$env:UI4ME_ENDPOINT`. |
| `-Token` | `string` | no | `$env:UI4ME_TOKEN` | Launch token (64 hexadecimal digits). Default: `$env:UI4ME_TOKEN`. |
| `-ConnectTimeoutMilliseconds` | `int` | no | `15000` | How long to wait for the endpoint. Range 1 to 120000. |
| `-SkipTokenValidation` | `switch` | no | off | For test peers only: accept a token that is not 64 hexadecimal digits. |

**Returns** `NativeHTMLKit.Application`. Its `Hello` property holds the host's `host.hello` result.

**Errors** missing endpoint/token (message explains to use `Start-NativeHTMLKitScript`);
`System.ArgumentException` for a malformed token; `NativeHTMLKit.DisconnectedException`
(`Cannot connect to the native host endpoint (...)`) when the endpoint does not answer;
`NativeHTMLKit.RpcException` when authentication fails; `Unsupported NativeHTMLKit Core protocol version`.

### Set-NativeHTMLKitReady

Alias: `Set-NHKReady`

Tells the host that startup finished (`app.ready`). Call it once, after creating at least one
window and registering the event handlers the first frame needs. Repeated calls do nothing.
Until ready, the host treats closing the last window as cancelling startup, and closes extra
windows without asking their close policy.

```text
Set-NativeHTMLKitReady [-Application] <Object> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Application` | `NativeHTMLKit.Application` | yes | - | The application. |

**Returns** nothing. **Errors** `NativeHTMLKit.RpcException` from the host (for example when no window exists).

### Wait-NativeHTMLKit

Alias: `Wait-NHK`

Pumps host messages on the calling runspace: every document event, notification, close/quit
decision and background-task completion callback runs inside this call (or inside any other
command that waits for a host reply). Two parameter sets:

- **Run** (`-UntilShutdown`): pumps until the host requests shutdown or `Close-NativeHTMLKit` is
  called (for example from a callback). Returns no output. Throws
  `NativeHTMLKit.DisconnectedException` if the host disappears first.
- **Pump** (default): waits up to `-TimeoutMilliseconds` for the first message, then handles up to
  64 queued messages without waiting, and returns how many it handled (`0` on timeout or after
  close). `-Once` handles at most one message. Use this for your own loop with periodic work.

```text
Wait-NativeHTMLKit -Application <Object> [-TimeoutMilliseconds <int>] [-Once] [<CommonParameters>]
Wait-NativeHTMLKit -Application <Object> [-UntilShutdown] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Application` | `NativeHTMLKit.Application` | yes | - | The application. |
| `-TimeoutMilliseconds` | `int` | no | `100` | How long to wait for the first message; `-1` waits indefinitely. Range -1 to 2147483647. Parameter set: Pump. |
| `-Once` | `switch` | no | off | Handle at most one message. Parameter set: Pump. |
| `-UntilShutdown` | `switch` | no | off | Pump until shutdown or close. Parameter set: Run. |

**Returns** `[int]` (Pump set) or nothing (Run set).

```powershell
# A custom loop: do periodic work between pumps (prefer a background task for real work).
while (-not $done) {
    $handled = Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 250
    if ($handled -eq 0) { Update-Clock }
}
```

### Request-NativeHTMLKitQuit

Alias: `Request-NHKQuit`

Asks the host for an orderly quit (`app.request_quit`). The host asks the
`Set-NativeHTMLKitBeforeQuit` policy (if any); when allowed it sends `app.shutdown`, which makes
`Wait-NativeHTMLKit -UntilShutdown` return. Use it for a Quit button or menu item.

```text
Request-NativeHTMLKitQuit [-Application] <Object> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Application` | `NativeHTMLKit.Application` | yes | - | The application. |

**Returns** the host result, `@{ requested = $true }` when the request was accepted. The quit
itself happens later, while events are pumped.

### Set-NativeHTMLKitBeforeQuit

Alias: `Set-NHKBeforeQuit`

Sets the application's quit policy. The host asks it (request `app.before_quit`) when a quit is
requested, for example by `Request-NativeHTMLKitQuit` (`reason = 'backend_request'`). The
scriptblock receives the host parameters (with a `reason` property); its **last output value**
decides: truthy allows the quit, `$false` or no output vetoes it. A throwing policy is reported as a
callback failure and the host receives an error reply. Pass `$null` to remove the policy.

```text
Set-NativeHTMLKitBeforeQuit [-Application] <Object> [-Callback] <scriptblock> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Application` | `NativeHTMLKit.Application` | yes | - | The application. |
| `-Callback` | `scriptblock` | yes | - | Policy scriptblock, or `$null` to remove it. Accepts `$null`. |

```powershell
Set-NativeHTMLKitBeforeQuit -Application $app -Callback {
    param($request)
    if ($script:unsaved) { Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text 'Save first.'; $false; return }
    $true
}
```

### Register-NativeHTMLKitNotification

Alias: `Register-NHKNotification`

Runs a scriptblock for every host notification with the given method, for example
`window.event` (window state changes, including `type = 'closed'`) or
`desktop.preferences_changed`. One callback per method; registering again replaces it; `$null`
removes it. The SDK's own bookkeeping (closing window handles, retiring documents, dispatching
document events) always runs before your callback. The callback receives the notification's
`params` object.

```text
Register-NativeHTMLKitNotification [-Application] <Object> [-Method] <string> [-Callback] <scriptblock> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Application` | `NativeHTMLKit.Application` | yes | - | The application. |
| `-Method` | `string` | yes | - | Notification method name, for example `window.event`. |
| `-Callback` | `scriptblock` | yes | - | Scriptblock receiving the notification parameters, or `$null` to remove it. Accepts `$null`. |

`window.event` parameters observed with Core 1.0.3: `window_id`, `type` (for example `closed`,
`close_requested`, `focused`, `resized`, `moved`, `dropped_files`, `theme_changed`) and `data`.

```powershell
Register-NativeHTMLKitNotification -Application $app -Method 'window.event' -Callback {
    param($params)
    if ($params.type -eq 'closed') { Write-Verbose "window $($params.window_id) closed" }
}
```

### Close-NativeHTMLKit

Alias: `Close-NHK`

Closes the application connection and retires every window, document, node and bitmap handle
(later use throws `NativeHTMLKit.StaleObjectException`). It removes all callbacks, requests
cancellation of unfinished background tasks without waiting for them, and is idempotent; `$null`
is accepted, so it is safe in a `finally` block even when startup failed. In a backend started by
`Start-NativeHTMLKitScript` before shutdown, the connection is left for process exit to close, so
an error that is unwinding through `finally` is still reported by PowerShell before the host stops
the process. Calling it inside a callback ends `Wait-NativeHTMLKit -UntilShutdown` normally.

```text
Close-NativeHTMLKit [-Application] <Object> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Application` | `NativeHTMLKit.Application` | yes | - | The application, or `$null`. Accepts `$null`. |

### Start-NativeHTMLKitHost

Alias: `Start-NHKHost`

Runs an app manifest (`app.toml`) through the native host and waits for it to exit (throws
`NativeHTMLKit host exited with code N` on a nonzero exit). With `-NoWait` it starts the host and
returns its `System.Diagnostics.Process`. The manifest's backend must call `Connect-NativeHTMLKit`
or `Start-NativeHTMLKitScript` (which only connects in that case). `New-NativeHTMLKitProject`
writes a suitable `app.toml`.

```text
Start-NativeHTMLKitHost [-Manifest] <string> [-NoWait] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Manifest` | `string` | yes | - | Path of the `app.toml` manifest; must exist. |
| `-NoWait` | `switch` | no | off | Start the host and return its process object instead of waiting. |

### Get-NativeHTMLKitHostPath

Alias: `Get-NHKHostPath`

Returns the full path of the native host this module will run: `NATIVEHTMLKIT_HOST_BINARY` (or the
legacy `UI4ME_HOST_BINARY`) when set, otherwise the bundled `runtimes/linux-x64/nativehtmlkit-host`
or `runtimes/win-x64/nativehtmlkit-host.exe`. A bundled host is checked against the SHA-256 in
`HOST-MANIFEST.json` on every call (fail closed), and on Linux made executable if a package
extraction dropped the execute bit.

```text
Get-NativeHTMLKitHostPath [<CommonParameters>]
```

_No parameters (common parameters only)._

**Errors** `NATIVEHTMLKIT_HOST_BINARY does not exist: <path>`; `NativeHTMLKit ships x64 hosts only`;
`NativeHTMLKit supports Linux and Windows only`; `The native NativeHTMLKit host is missing` (a source
checkout without hosts: set `NATIVEHTMLKIT_HOST_BINARY`); a missing or mismatching `HOST-MANIFEST.json`.

## Environment variables

| Variable | Used by | Effect |
|---|---|---|
| `NATIVEHTMLKIT_HOST_BINARY` | `Get-NativeHTMLKitHostPath`, launcher | Use this host binary instead of the bundled one. |
| `NATIVEHTMLKIT_TEST_MODE=1` | `Start-NativeHTMLKitScript` | Start the host with `--headless`: the full protocol runs without windows on screen. No native input, clipboard, file dialogs, external open or attention requests. |
| `NATIVEHTMLKIT_DIAGNOSTICS` | SDK, host, backend | `off`, `normal` (default), `debug` or `trace`. |
| `NATIVEHTMLKIT_VERBOSE` | launcher | Any value other than empty, `0`, `false`, `no` relays the host's informational records to stderr. |
| `NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID` | SDK, host | Correlation ID shared by launcher, host and backend; generated when absent. |
| `UI4ME_ENDPOINT`, `UI4ME_TOKEN`, `UI4ME_APP_ID`, `UI4ME_PROTOCOL_VERSION` | backend | Set by the host for its backend (wire v1 names). Removed from the environment on connect. |
