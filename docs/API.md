# NativeHTMLKit PowerShell SDK: cmdlet reference

Module `NativeHTMLKit` **0.1.2**, bundling NativeHTMLKit Core **1.0.3** (public wire protocol v1).
PowerShell 7.2+ on Linux and Windows, Windows PowerShell 5.1 on Windows.

This page is the entry point of the reference: every exported command, grouped by task, with a link
to its full description (syntax, parameters with types and defaults, output, errors, examples).
88 functions are exported, each with one short `-NHK` alias ([alias table](reference/aliases.md)).
Run `Get-Command -Module NativeHTMLKit` and `Get-Help <command>` for the installed copy.

New here? Start with the [tutorial](tutorials/bulk-rename.md) or the
[examples](../examples/README.md). Concepts: [architecture](ARCHITECTURE.md).

## Conventions

- Handles (`NativeHTMLKit.Application`, `.Window`, `.Document`, `.Node`, ...) belong to the runspace
  that created the application. Callbacks run on that runspace while it pumps events.
  [Objects, errors, threading and limits](reference/objects-and-errors.md).
- Parameter tables name the expected handle type (`NativeHTMLKit.Document`, ...). Those parameters
  are declared as `[object]` (see the syntax blocks) and checked when the command runs; passing the
  wrong handle throws, for example, `Expected a NativeHTMLKit.Window from New-NativeHTMLKitWindow`.
- `-Element` always means an element **id**. Elements without ids are reached through
  [nodes](reference/nodes.md).
- Text you show is safe with `Set-NativeHTMLKitDocumentText`; HTML you build must encode untrusted
  values. [Security guide](guides/security.md).
- Failures are terminating errors; host refusals are `NativeHTMLKit.RpcException` with a `Code`.

## Application lifecycle - [reference/lifecycle.md](reference/lifecycle.md)

| Command | Purpose |
|---|---|
| [`Start-NativeHTMLKitScript`](reference/lifecycle.md#start-nativehtmlkitscript) | Run a `.ps1` as an app: start the host, relaunch the script as backend, return the application. |
| [`Connect-NativeHTMLKit`](reference/lifecycle.md#connect-nativehtmlkit) | Connect a backend started from an `app.toml` manifest. |
| [`Set-NativeHTMLKitReady`](reference/lifecycle.md#set-nativehtmlkitready) | Tell the host startup finished. |
| [`Wait-NativeHTMLKit`](reference/lifecycle.md#wait-nativehtmlkit) | Pump events and run callbacks (`-UntilShutdown`, or a timed pump). |
| [`Request-NativeHTMLKitQuit`](reference/lifecycle.md#request-nativehtmlkitquit) | Ask for an orderly quit. |
| [`Set-NativeHTMLKitBeforeQuit`](reference/lifecycle.md#set-nativehtmlkitbeforequit) | Quit policy (veto with `$false`). |
| [`Register-NativeHTMLKitNotification`](reference/lifecycle.md#register-nativehtmlkitnotification) | Callback for host notifications such as `window.event`. |
| [`Close-NativeHTMLKit`](reference/lifecycle.md#close-nativehtmlkit) | Close the connection and retire all handles. |
| [`Start-NativeHTMLKitHost`](reference/lifecycle.md#start-nativehtmlkithost) | Run an `app.toml` manifest through the host. |
| [`Get-NativeHTMLKitHostPath`](reference/lifecycle.md#get-nativehtmlkithostpath) | Path of the (verified) host binary. |

## Windows - [reference/windows.md](reference/windows.md)

| Command | Purpose |
|---|---|
| [`New-NativeHTMLKitWindow`](reference/windows.md#new-nativehtmlkitwindow) | Create a window. |
| [`Set-NativeHTMLKitWindow`](reference/windows.md#set-nativehtmlkitwindow) | Title, size, state, constraints. |
| [`Get-NativeHTMLKitWindow`](reference/windows.md#get-nativehtmlkitwindow) | The host's description of a window. |
| [`Get-NativeHTMLKitWindowList`](reference/windows.md#get-nativehtmlkitwindowlist) | All open windows (one array object). |
| [`Close-NativeHTMLKitWindow`](reference/windows.md#close-nativehtmlkitwindow) | Graceful close (policy may veto). |
| [`Set-NativeHTMLKitBeforeClose`](reference/windows.md#set-nativehtmlkitbeforeclose) | Close policy per window. |
| [`Request-NativeHTMLKitAttention`](reference/windows.md#request-nativehtmlkitattention) | Flag the window on the desktop. |

## Documents and DOM - [reference/documents.md](reference/documents.md)

| Command | Purpose |
|---|---|
| [`Open-NativeHTMLKitHtml`](reference/documents.md#open-nativehtmlkithtml), [`Open-NativeHTMLKitFile`](reference/documents.md#open-nativehtmlkitfile) | Load a document (replaces the current one). |
| [`Remove-NativeHTMLKitDocument`](reference/documents.md#remove-nativehtmlkitdocument) | Unload the document. |
| [`Get-NativeHTMLKitDocumentText`](reference/documents.md#get-nativehtmlkitdocumenttext), [`Set-NativeHTMLKitDocumentText`](reference/documents.md#set-nativehtmlkitdocumenttext) | Read / set text (never parsed as HTML). |
| [`Get-NativeHTMLKitValue`](reference/documents.md#get-nativehtmlkitvalue), [`Set-NativeHTMLKitDocumentValue`](reference/documents.md#set-nativehtmlkitdocumentvalue) | Control values. |
| [`Get-NativeHTMLKitChecked`](reference/documents.md#get-nativehtmlkitchecked), [`Set-NativeHTMLKitChecked`](reference/documents.md#set-nativehtmlkitchecked) | Checkboxes and radio buttons. |
| [`Set-NativeHTMLKitDocumentAttribute`](reference/documents.md#set-nativehtmlkitdocumentattribute), [`Set-NativeHTMLKitClass`](reference/documents.md#set-nativehtmlkitclass) | Attributes and classes. |
| [`Set-NativeHTMLKitDocumentHtml`](reference/documents.md#set-nativehtmlkitdocumenthtml), [`Remove-NativeHTMLKitElement`](reference/documents.md#remove-nativehtmlkitelement) | Replace/insert trusted HTML, remove elements. |
| [`Find-NativeHTMLKitElement`](reference/documents.md#find-nativehtmlkitelement) | CSS selector query (ids and counts). |
| [`Invoke-NativeHTMLKitBatch`](reference/documents.md#invoke-nativehtmlkitbatch) | Several DOM operations atomically. |
| [`Invoke-NativeHTMLKitDocumentCommand`](reference/documents.md#invoke-nativehtmlkitdocumentcommand) | Any of the 81 Core document commands. |
| [`Add-NativeHTMLKitStylesheet`](reference/documents.md#add-nativehtmlkitstylesheet), [`Get-NativeHTMLKitStylesheets`](reference/documents.md#get-nativehtmlkitstylesheets), [`Set-NativeHTMLKitStylesheet`](reference/documents.md#set-nativehtmlkitstylesheet) | Stylesheets. |
| [`Get-NativeHTMLKitComputedStyle`](reference/documents.md#get-nativehtmlkitcomputedstyle) | Computed CSS values. |
| [`Get-NativeHTMLKitEnvironment`](reference/documents.md#get-nativehtmlkitenvironment), [`Set-NativeHTMLKitEnvironment`](reference/documents.md#set-nativehtmlkitenvironment) | Colour scheme and reduced-motion overrides. |
| [`Get-NativeHTMLKitScroll`](reference/documents.md#get-nativehtmlkitscroll), [`Set-NativeHTMLKitScroll`](reference/documents.md#set-nativehtmlkitscroll) | Scrolling. |
| [`Get-NativeHTMLKitFocusedElement`](reference/documents.md#get-nativehtmlkitfocusedelement), [`Set-NativeHTMLKitFocus`](reference/documents.md#set-nativehtmlkitfocus) | Focus. |
| [`Get-NativeHTMLKitSelection`](reference/documents.md#get-nativehtmlkitselection), [`Set-NativeHTMLKitSelection`](reference/documents.md#set-nativehtmlkitselection), [`Invoke-NativeHTMLKitEditCommand`](reference/documents.md#invoke-nativehtmlkiteditcommand) | Text selection and editing commands. |
| [`Register-NativeHTMLKitResources`](reference/documents.md#register-nativehtmlkitresources), [`Unregister-NativeHTMLKitResources`](reference/documents.md#unregister-nativehtmlkitresources) | In-memory images, icons, fonts (`nativehtmlkit-res://`). |

## Events - [reference/events.md](reference/events.md)

| Command | Purpose |
|---|---|
| [`Register-NativeHTMLKitDocumentEvent`](reference/events.md#register-nativehtmlkitdocumentevent) | Run a scriptblock for DOM events (with delegation by id). |
| [`Unregister-NativeHTMLKitDocumentEvent`](reference/events.md#unregister-nativehtmlkitdocumentevent) | Remove a subscription. |
| [`Set-NativeHTMLKitPreventDefault`](reference/events.md#set-nativehtmlkitpreventdefault) | Cancel a native default action (registered in advance). |

The [event object fields](reference/events.md#the-event-object) and
[when callbacks run](reference/events.md#when-callbacks-run) are described there.

## Forms, dialogs and popovers - [reference/forms.md](reference/forms.md)

| Command | Purpose |
|---|---|
| [`Get-NativeHTMLKitFormData`](reference/forms.md#get-nativehtmlkitformdata) | Form entries in submission order. |
| [`Submit-NativeHTMLKitForm`](reference/forms.md#submit-nativehtmlkitform), [`Reset-NativeHTMLKitForm`](reference/forms.md#reset-nativehtmlkitform) | Submit (with native validation) or reset. |
| [`Get-NativeHTMLKitSelectOptions`](reference/forms.md#get-nativehtmlkitselectoptions), [`Set-NativeHTMLKitSelectedValues`](reference/forms.md#set-nativehtmlkitselectedvalues) | `<select>` options. |
| [`Show-NativeHTMLKitHtmlDialog`](reference/forms.md#show-nativehtmlkithtmldialog) | Open/close an HTML `<dialog>`. |
| [`Show-NativeHTMLKitPopover`](reference/forms.md#show-nativehtmlkitpopover) | Show/hide/toggle a `popover` element. |

## Nodes - [reference/nodes.md](reference/nodes.md)

[`Get-NativeHTMLKitNode`](reference/nodes.md#get-nativehtmlkitnode),
[`Get-NativeHTMLKitNodes`](reference/nodes.md#get-nativehtmlkitnodes),
[`Get-NativeHTMLKitNodeInfo`](reference/nodes.md#get-nativehtmlkitnodeinfo),
[`Get-NativeHTMLKitNodeChildren`](reference/nodes.md#get-nativehtmlkitnodechildren),
[`Invoke-NativeHTMLKitNodeOperation`](reference/nodes.md#invoke-nativehtmlkitnodeoperation),
[`Invoke-NativeHTMLKitNodeBatch`](reference/nodes.md#invoke-nativehtmlkitnodebatch): address and
change elements that have no id.

## Desktop services - [reference/desktop.md](reference/desktop.md)

| Command | Purpose |
|---|---|
| [`Get-NativeHTMLKitCapabilities`](reference/desktop.md#get-nativehtmlkitcapabilities) | What this host and session offer. |
| [`Get-NativeHTMLKitPreferences`](reference/desktop.md#get-nativehtmlkitpreferences) | Observed colour scheme, contrast, motion. |
| [`Get-NativeHTMLKitClipboard`](reference/desktop.md#get-nativehtmlkitclipboard), [`Set-NativeHTMLKitClipboard`](reference/desktop.md#set-nativehtmlkitclipboard) | Plain-text clipboard. |
| [`Open-NativeHTMLKitExternal`](reference/desktop.md#open-nativehtmlkitexternal) | Open a URL/document, or reveal a file. |
| [`Show-NativeHTMLKitFileDialog`](reference/desktop.md#show-nativehtmlkitfiledialog) | Native Open / Save / Choose-folder dialogs. |

## Live bitmaps - [reference/bitmaps.md](reference/bitmaps.md)

[`New-NativeHTMLKitLiveBitmap`](reference/bitmaps.md#new-nativehtmlkitlivebitmap),
[`Send-NativeHTMLKitLiveBitmap`](reference/bitmaps.md#send-nativehtmlkitlivebitmap),
[`Remove-NativeHTMLKitLiveBitmap`](reference/bitmaps.md#remove-nativehtmlkitlivebitmap): RGBA
pixels you compute, shown by `<img src="nativehtmlkit-bitmap://ID">`.

## Background tasks - [reference/tasks.md](reference/tasks.md)

[`Start-NativeHTMLKitTask`](reference/tasks.md#start-nativehtmlkittask),
[`Receive-NativeHTMLKitTask`](reference/tasks.md#receive-nativehtmlkittask),
[`Stop-NativeHTMLKitTask`](reference/tasks.md#stop-nativehtmlkittask): work in isolated runspaces
with completion callbacks on the UI runspace.

## Diagnostics - [reference/diagnostics.md](reference/diagnostics.md)

| Command | Purpose |
|---|---|
| [`Get-NativeHTMLKitDiagnosticReport`](reference/diagnostics.md#get-nativehtmlkitdiagnosticreport) | SDK, connection and host loss counters. |
| [`Export-NativeHTMLKitSupportBundle`](reference/diagnostics.md#export-nativehtmlkitsupportbundle) | Local, redacted ZIP for bug reports. |
| [`Get-NativeHTMLKitDiagnostics`](reference/diagnostics.md#get-nativehtmlkitdiagnostics) | Document CSS/resource notes. |
| [`Get-NativeHTMLKitResourceStats`](reference/diagnostics.md#get-nativehtmlkitresourcestats), [`Clear-NativeHTMLKitUnusedResources`](reference/diagnostics.md#clear-nativehtmlkitunusedresources) | Resource cache. |

## Raw protocol access - [reference/rpc.md](reference/rpc.md)

[`Invoke-NativeHTMLKitRpc`](reference/rpc.md#invoke-nativehtmlkitrpc),
[`Start-NativeHTMLKitRpc`](reference/rpc.md#start-nativehtmlkitrpc),
[`Wait-NativeHTMLKitRpc`](reference/rpc.md#wait-nativehtmlkitrpc),
[`Stop-NativeHTMLKitRpc`](reference/rpc.md#stop-nativehtmlkitrpc),
[`Send-NativeHTMLKitNotification`](reference/rpc.md#send-nativehtmlkitnotification).

## Tooling - [reference/tooling.md](reference/tooling.md)

[`New-NativeHTMLKitProject`](reference/tooling.md#new-nativehtmlkitproject) (app scaffold) and
[`Install-NativeHTMLKitSkill`](reference/tooling.md#install-nativehtmlkitskill) (coding-agent skill).

## Guides

[Script lifecycle](guides/script-lifecycle.md) ·
[Events and callbacks](guides/events-and-callbacks.md) ·
[DOM updates](guides/dom-updates.md) ·
[Forms](guides/forms.md) ·
[Multiple windows](guides/multiple-windows.md) ·
[File dialogs](guides/file-dialogs.md) ·
[HTML dialogs and popovers](guides/html-dialogs-and-popovers.md) ·
[Clipboard](guides/clipboard.md) ·
[Live bitmaps](guides/live-bitmaps.md) ·
[Background tasks](guides/background-tasks.md) ·
[Diagnostics](guides/diagnostics.md) ·
[Project scaffolding](guides/project-scaffolding.md) ·
[Windows PowerShell 5.1 and PowerShell 7](guides/windows-powershell-51.md) ·
[Security](guides/security.md)
