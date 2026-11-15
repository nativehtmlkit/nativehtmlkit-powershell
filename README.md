# NativeHTMLKit — PowerShell SDK

Independent PowerShell SDK for the [NativeHTMLKit Core](https://github.com/nativehtmlkit/nativehtmlkit-core) native HTML/CSS host: native desktop windows from local HTML and CSS, driven by ordinary PowerShell scripts. Targets: **PowerShell 7.2+ on Linux and Windows, and Windows PowerShell 5.1**. End users need no Python, Rust compiler, browser, JavaScript runtime or HTTP server; a packaged module carries a prebuilt Core host.

**Status: 0.1.0, unreleased, not a qualified release.** What was actually executed, on which runtime and against which host SHA-256, is recorded in [docs/QUALIFICATION.md](docs/QUALIFICATION.md). The Core wire protocol v1 is still a release candidate.

## Quick start

```powershell
$env:NATIVEHTMLKIT_HOST_BINARY = '/absolute/path/to/nativehtmlkit-host'   # development only; a packaged module bundles its host
Import-Module ./NativeHTMLKit/NativeHTMLKit.psd1
$app = Start-NativeHTMLKitScript -Name 'PowerShell Example' -Diagnostics Debug
$window = New-NativeHTMLKitWindow -Application $app -Title 'PowerShell Example'
$doc = Open-NativeHTMLKitHtml -Window $window -Html '<button id="go">Go</button><p id="status">Ready</p>'
$null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element go -Callback {
    Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text 'Clicked'
}
Set-NativeHTMLKitReady -Application $app
Wait-NativeHTMLKit -Application $app -UntilShutdown
Close-NativeHTMLKit -Application $app
```

Save it as `app.ps1` and run `pwsh -File app.ps1` (or `powershell.exe -File app.ps1`). `Start-NativeHTMLKitScript` writes a private temporary manifest, starts the host, and the host runs the same script a second time as its backend; keep side effects below that call. Call `Set-NativeHTMLKitReady` once the first window is set up: the Core host treats closing a window or quitting *before* `app.ready` as cancelling startup. `New-NativeHTMLKitProject -Path ./MyApp` generates a complete app (`app.ps1`, `index.html`, `style.css`, optional `app.toml`).

Canonical commands are `Verb-NativeHTMLKitNoun` (88 functions); every one has a short alias `Verb-NHKNoun` (`New-NHKWindow`, `Open-NHKHtml`, `Wait-NHK`, `Start-NHKScript`, ...). The aliases are listed explicitly in the manifest, so they auto-load the installed module.

## Concurrency, callbacks and background work

- The C# transport (compiled once per process with `Add-Type`, about 0.2-0.5 s) reads and writes on .NET threads but **never runs PowerShell code**. Every user scriptblock runs on the owning runspace while it pumps: `Wait-NativeHTMLKit`, or any command that waits for a host reply.
- Notifications are delivered one at a time in host order. While a callback runs, nested pumps still answer replies and host lifecycle requests (`window.before_close`, `app.before_quit`) but defer further notifications, and also task completions, until the callback returns.
- `Close-NativeHTMLKit` may be called from inside a callback (for example a Quit button): no further callback runs, and `Wait-NativeHTMLKit -UntilShutdown` returns normally. `break`/`continue` in a callback stop only that callback (counted as a callback failure; for a close/quit policy it is a veto) and never leak into SDK loops.
- A callback that throws is isolated: it is logged to stderr, recorded as a `callback.failed` diagnostic and counted (`(Get-NativeHTMLKitDiagnosticReport -Application $app).Connection.CallbackFailures`); it never surfaces from an unrelated RPC. A throwing `before_close`/`before_quit` policy answers the host with an error, which the host treats as a veto.
- `Start-NativeHTMLKitTask -Application $app -ScriptBlock {...} -OnCompleted {...} -OnFailed {...}` runs work in an isolated runspace (no caller variables or modules; pass plain data with `-ArgumentList`, never SDK objects). Completion callbacks run later on the owning runspace. `-TimeoutMilliseconds` and `Stop-NativeHTMLKitTask` only *request* cancellation: a worker that ignores it keeps one of the 8 per-application (32 per-process) slots until its thread really ends, and is never disposed while running, so neither the pump nor `Close-NativeHTMLKit` blocks on it. `Receive-NativeHTMLKitTask -Wait [-TimeoutMilliseconds]` keeps pumping host messages while it waits and reports `CancellationPending` and the worker's non-terminating `Errors`. No task callback runs after `Close-NativeHTMLKit`.

## Errors

| Situation | Exception |
|---|---|
| Host rejected a request | `NativeHTMLKit.RpcException` with `Code` (numeric Core code, unknown codes preserved), `RpcMessage`, `RpcData`, `Method` |
| Reply not received within the deadline (default 15 s; dialogs wait indefinitely) | `NativeHTMLKit.RpcTimeoutException` (a `TimeoutException`): cancellation was requested, the outcome is unknown |
| Host disconnected, crashed, sent a malformed frame, or the endpoint could not be connected | `NativeHTMLKit.DisconnectedException` (the cause as `InnerException`); every pending request fails with it and `$app.Transport.Failure` names the cause |
| 128 requests are outstanding (started with `Start-NativeHTMLKitRpc`/`-NoWait` and neither awaited nor stopped) | `NativeHTMLKit.BusyException` |
| Window, document, node or bitmap no longer current (replaced, closed, or the host sent `app.shutdown`) | `NativeHTMLKit.StaleObjectException` |

These are terminating errors (thrown .NET exceptions), catchable by type with `try { } catch [NativeHTMLKit.RpcException] { }`. They are not mapped to PowerShell `ErrorCategory` values.

Commands that return a list (`Get-NativeHTMLKitWindowList`, `Get-NativeHTMLKitStylesheets`, `Get-NativeHTMLKitSelectOptions`) return it as **one array object**, as the legacy module did (a pinned contract): use `$list = Get-NativeHTMLKitWindowList -Application $app; $list.Count`. `@(Get-NativeHTMLKitWindowList ...)` or piping the call yields a single item (the array).

Protocol v1 sends no `closed` event for the last window; `app.shutdown` itself retires every window and document handle, so using one afterwards throws `StaleObjectException`.

## Diagnostics

```powershell
$app = Start-NativeHTMLKitScript -Name 'My App' -Diagnostics Trace   # or: $env:NATIVEHTMLKIT_DIAGNOSTICS = 'trace'
# ... reproduce the problem ...
Get-NativeHTMLKitDiagnosticReport -Application $app                    # counters, including loss counters
Export-NativeHTMLKitSupportBundle -Path ./report.zip -Application $app # local ZIP, only when you call it
```

- `-Diagnostics` / `NATIVEHTMLKIT_DIAGNOSTICS` (`off|normal|debug|trace`) is inherited by the Core host and by the backend process; `NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID` (generated as `nhk-ps-<guid>` when absent; a caller-provided ID in the Core alphabet `[A-Za-z0-9._:-]{1,128}` is kept) correlates launcher, host stderr records (`diagnostic_session_id`) and backend.
- At `trace` the SDK timeline links host notification → callback → `rpc.started`/`rpc.completed` (same `request_id`) → task → UI update RPC. Records hold only fixed event names, identifiers, numbers and short tokens: never RPC parameters or results, form values, text, exception messages, paths, URLs or credentials.
- `off` turns SDK records off. Interim rule (Core NHK-CROSS-0007): the Core host would also drop the script's own output and fatal error at `off`, so a host started by `Start-NativeHTMLKitScript`/`Start-NativeHTMLKitHost` is given `normal` while the backend's SDK records stay off (`NATIVEHTMLKIT_SDK_DIAGNOSTICS=off`).
- Context values are allow-listed per key (protocol method names, DOM/window event types, callback roles, exception type names, task/window/document ids); any other string, element ids included, is exported as `[REDACTED]`.
- The history is bounded (2048 records); dropped records are counted and the bundle manifest says `complete: false`. The bundle contains `manifest.json` and `timeline.jsonl` only; raw host/backend stderr is never included (it can contain application output) and nothing is uploaded.
- The Core host itself logs only lifecycle records, even at `trace` (Project bug NHK-CROSS-0004).

## Security notes

- The v1 launch variables `UI4ME_ENDPOINT`, `UI4ME_TOKEN`, `UI4ME_APP_ID` and `UI4ME_PROTOCOL_VERSION` are removed from the process environment before connecting, so no failure path leaves them to child processes; they are never logged. The token must have the 64-hex-digit shape the host issues (`-SkipTokenValidation` exists for test peers only).
- On Windows the named pipe is opened at impersonation level *Identification* (the server cannot act as you) and must be owned by you (or a group of your token) before the token is sent.
- `Start-NativeHTMLKitScript` writes its temporary manifest (program, script, arguments, working directory) into a new folder created with mode 0700 on Linux (fail closed); on Windows the folder inherits the per-user `%TEMP%` ACL. Stale folders are deleted without following links.
- The host is `NATIVEHTMLKIT_HOST_BINARY` (legacy `UI4ME_HOST_BINARY`) when set, otherwise the module's bundled `runtimes/<rid>/` host (a relative override is resolved against the PowerShell location). `PATH` is never searched, also not for `setpriv` (only `/usr/bin/setpriv` or `/bin/setpriv`). A packaged module re-hashes the bundled host against `HOST-MANIFEST.json` on every launch and refuses a mismatch or a missing manifest (an integrity check of the installed copy, not proof of who built it; the file could still be swapped between the hash and the moment it is executed).

## Test, qualify and package (local only)

- `pwsh -File scripts/test-local.ps1 [-HostBinary HOST -RequireHost]` (and `powershell.exe -File scripts\test-local.ps1`) runs the Pester 5.x suites: `Unit`, `Transport` (mock peer), `Faults`, `Tasks`, `Diagnostics`, and with a host `DirectStart` and `RealHost` (headless real host).
- `scripts/qualify.ps1 -HostBinary HOST -HostSha256 HEX -Out DIR [-Gui] [-Package ZIP -PackageHostSha256 HEX]` is the one command per platform and edition; it writes `DIR/results.json` (PASS/FAIL/BLOCKED per gate). `-Gui` runs `tests/native/` with real input and must run inside a real desktop session (KDE Wayland; interactive Windows desktop).
- `python3 scripts/package-local.py --out dist/X --host linux-x64=PATH --sha256 linux-x64=HEX [--host win-x64=PATH --sha256 win-x64=HEX]` stages the module with pinned hosts (fails closed on hash mismatch), Core licences, `HOST-MANIFEST.json` and `SHA256SUMS`. Python is used only by this build tool. `scripts/smoke-installed.ps1` checks a package as a clean install.

No GitHub Actions, PowerShell Gallery publishing or remote releases without explicit approval.
