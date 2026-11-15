---
name: nativehtmlkit-powershell
description: Build native desktop windows from local HTML/CSS with the NativeHTMLKit PowerShell module (Verb-NativeHTMLKitNoun commands, Verb-NHKNoun aliases), including callbacks, background tasks and diagnostics.
---

# NativeHTMLKit PowerShell SDK

Use the NativeHTMLKit module's canonical `Verb-NativeHTMLKitNoun` functions and short `Verb-NHKNoun` aliases. v1 Core host environment variables are `UI4ME_ENDPOINT`, `UI4ME_TOKEN`, `UI4ME_APP_ID`, `UI4ME_PROTOCOL_VERSION`; preserve them in the transport (the module removes them from the environment after connecting).

App shape: `$app = Start-NativeHTMLKitScript -Name 'App'` near the top of a `.ps1` run with `pwsh -File` (the host runs the script a second time as backend; keep side effects below that line), create windows and documents, register callbacks, then `Set-NativeHTMLKitReady -Application $app` (closing or quitting before ready cancels startup), `Wait-NativeHTMLKit -Application $app -UntilShutdown`, `Close-NativeHTMLKit -Application $app`. `New-NativeHTMLKitProject` generates a working app.

Callbacks run on the owning runspace during the pump. A throwing callback is logged and counted, not rethrown. Use `Start-NativeHTMLKitTask` (plain data in `-ArgumentList`, UI updates in `-OnCompleted`) for slow work; `Stop-NativeHTMLKitTask` and `-TimeoutMilliseconds` only request cancellation. Never pass SDK window/document handles into worker runspaces.

Errors: `NativeHTMLKit.RpcException` (Code, RpcMessage, RpcData), `NativeHTMLKit.RpcTimeoutException` (outcome unknown), `NativeHTMLKit.DisconnectedException`, `NativeHTMLKit.StaleObjectException`.

Diagnostics: `-Diagnostics Trace` on `Start-NativeHTMLKitScript` (or `$env:NATIVEHTMLKIT_DIAGNOSTICS='trace'`), reproduce, then `Export-NativeHTMLKitSupportBundle -Path ./report.zip -Application $app` saves a local sanitized archive. Never upload automatically.

No Python runtime, no Rust compilation, and no GitHub Actions. Only qualified Core release artifacts should be packaged.
