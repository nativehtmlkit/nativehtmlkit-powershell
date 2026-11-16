# PowerShell SDK architecture

This page explains how the `NativeHTMLKit` module turns a PowerShell script into a native desktop
app, so that the rules in the guides (side effects below `Start-NativeHTMLKitScript`, callbacks on
one runspace, plain data for background work) make sense. It describes module 0.1.2 with Core
1.0.3 and wire protocol v1.

## Two processes

```text
 +---------------------------+        private local channel         +---------------------------+
 | nativehtmlkit-host (Rust) |  <--- length-prefixed JSON-RPC  --->  | PowerShell backend        |
 | windows, input, layout,   |       Unix socket / named pipe       | your script + this module |
 | rendering, accessibility, |                                      | state, logic, callbacks   |
 | native dialogs, clipboard |                                      |                           |
 +---------------------------+                                      +---------------------------+
```

- The **host** is the native NativeHTMLKit Core executable bundled in the module
  (`runtimes/linux-x64`, `runtimes/win-x64`). It owns everything the user sees and touches: the
  windows, the HTML/CSS engine (no browser and no JavaScript), input methods, accessibility trees and
  operating-system services.
- The **backend** is a PowerShell process running your script. It holds your data and logic and
  tells the host what to show. The module is the backend half of the protocol: a C# transport
  compiled at import (`Private/NativeHTMLKit.Transport.cs`), the cmdlets (`NativeHTMLKit.psm1`),
  background tasks and diagnostics.
- They talk over a **private, authenticated local channel**: a Unix-domain socket (Linux) or a
  restricted named pipe (Windows), never TCP or HTTP. The host creates it, starts the backend with
  `UI4ME_ENDPOINT` and a one-time `UI4ME_TOKEN`, and the backend proves the token in `host.hello`.
  Messages are 4-byte length prefixes plus UTF-8 JSON-RPC 2.0, at most 2 MiB each.

The host supervises the backend: it enforces startup and shutdown deadlines, stops it when the app
quits, and reports a backend that disappears without an accepted quit as an application failure.

## How a script becomes a backend

`Start-NativeHTMLKitScript` makes a normal `.ps1` file both launcher and backend:

```text
pwsh -File app.ps1 args            (launcher run)
  Start-NativeHTMLKitScript
    writes private app.toml  ->  starts nativehtmlkit-host run --app app.toml
                                   host starts: pwsh -NoProfile -NonInteractive -File app.ps1 args   (backend run)
                                     Start-NativeHTMLKitScript -> Connect -> returns $app
                                     ... your code: windows, documents, handlers, ready, wait ...
    waits for the host; exit <host exit code>
```

The launcher role is chosen when the `UI4ME_*` variables are absent; it validates the options,
resolves and verifies the host binary (SHA-256 against `HOST-MANIFEST.json`), writes the manifest
into a folder only the current user can access, starts the host (on Linux through
`setpriv --pdeathsig` so the host stops if the launcher is killed), relays the host's records to
the console as plain text, and finally exits with the host's exit code. The backend role connects
and removes the launch secrets from its environment so programs it starts cannot inherit them.

Everything above the call therefore runs twice, which is why side effects belong below it.
Manifest-based deployments skip the launcher: the host is started with an explicit `app.toml` and
the backend only connects.

## One owner runspace, one event pump

The transport's reader is a .NET thread that parses frames into a bounded queue; it never runs
PowerShell code. PowerShell code runs only on the **owner runspace**, the one that created the
application, when it pumps the queue:

- `Wait-NativeHTMLKit` pumps explicitly;
- every SDK command that needs a reply pumps while it waits, so events can be handled in the middle
  of, for example, `Get-NativeHTMLKitValue`.

Messages are handled in host order. Replies complete waiting requests; host **requests**
(`window.before_close`, `app.before_quit`) run your policy scriptblock and are answered at once,
even inside a nested wait, so the host is never left waiting on a decision; host
**notifications** (`document.event`, `window.event`, `desktop.preferences_changed`, ...) run your
callbacks one at a time. While a callback runs, further notifications are deferred until it
returns (bounded at 128; extra ones are dropped and counted). A failing callback is isolated:
logged, counted, and the app continues.

This single-threaded model is why SDK objects must not be shared with other runspaces, why long
work in a callback freezes the window, and why `Start-NativeHTMLKitTask` exists.

## Handles and their lifetime

The SDK mirrors host objects as small handle objects: application, window, document, node, live
bitmap, request, subscription, task. Each handle knows its owner and whether it is still current.
The host's lifecycle events retire them: a closed window retires its document; loading a new
document retires the previous one together with its subscriptions, nodes and bitmaps;
`app.shutdown` retires every window (the host sends no separate `closed` event for the last
window); `Close-NativeHTMLKit` retires everything and removes all callbacks. A retired handle
throws `NativeHTMLKit.StaleObjectException` locally instead of sending a request the host would
reject.

## Documents and commands

A document is HTML and CSS rendered by the host. The backend changes it with **document commands**
(`document.command` with an `op` such as `set_text`, `insert_html`, `batch`, `get_form_data`); the
typed cmdlets are thin wrappers that build these commands, and `Invoke-NativeHTMLKitDocumentCommand`
reaches the rest of the 81 operations. Elements are addressed by `id`, or by generation-bound node
references for elements without ids. Events travel the other way as `document.event` notifications
that carry the element id, the id path, the target node reference and event-specific fields;
the SDK matches them against subscriptions (type plus id on the path) after native dispatch.

Live bitmaps bypass the message channel for pixels: the host creates a file mapping with two or
three frame slots, the backend writes a frame into the next slot and sends a small `bitmap.present`
request.

## Background work

`Start-NativeHTMLKitTask` runs a scriptblock in a fresh runspace (its text is re-parsed there, so no
variables, functions or modules carry over) and refuses SDK objects among its arguments. The pump
checks for finished tasks between messages and runs `-OnCompleted`/`-OnFailed` on the owner
runspace, never inside another callback. Limits (8 per application, 32 per process) count workers
until their thread really ends, because cancellation is only a request.

## Diagnostics

The SDK records redacted, allow-listed events into an in-memory ring (2048 records) according to
`NATIVEHTMLKIT_DIAGNOSTICS`. A session ID shared through the environment correlates SDK records,
host records and the backend. `Export-NativeHTMLKitSupportBundle` writes these records and counters
to a ZIP only when called; nothing leaves the machine.

## Boundaries

- The SDK depends only on the public Core wire protocol v1; it does not use Core internals.
- The [NativeHTMLKit.UI](https://github.com/nativehtmlkit/nativehtmlkit_ui) module (declarative
  components, reactive state) builds on the public cmdlets of this SDK only.
- Platforms: PowerShell 7.2+ on Linux x64 and Windows x64; Windows PowerShell 5.1 on Windows
  (the C# transport compiles against .NET Framework there). Native behaviour is qualified per
  platform; see the
  [capability matrix](https://github.com/nativehtmlkit/nativehtmlkit/blob/main/docs/capabilities/matrix.md).
