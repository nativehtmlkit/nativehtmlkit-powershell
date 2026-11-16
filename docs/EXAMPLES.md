# Examples by task

The runnable example apps live in [examples/](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/README.md): twenty small, complete
programs from a greeting form to a multi-window notes app, a live bitmap chart and the tutorials'
final apps. Each one states what it teaches in its header, accepts `-SelfTest`, and is run against
the real host on Linux (PowerShell 7) and Windows (PowerShell 7 and Windows PowerShell 5.1) by
`tests/Examples.Tests.ps1`. [catalog.toml](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/catalog.toml) lists them with the ids
shared with the Python SDK.

| Task | Example (id) | Guide |
|---|---|---|
| First app, lifecycle | [01-hello.ps1](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/01-hello.ps1) (`hello`) | [Lifecycle](guides/lifecycle.md) |
| Event delegation, batches | [02-counter.ps1](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/02-counter.ps1) (`counter`) | [Events](guides/events-and-callbacks.md), [Updating the page](guides/updating-the-page.md) |
| Forms and validation | [03-form-validation.ps1](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/03-form-validation.ps1) (`signup-form`) | [Forms and validation](guides/forms-and-validation.md) |
| Dynamic lists, editing, saving to JSON | [04-todo-list.ps1](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/04-todo-list.ps1) (`todo`) | [Todo tutorial](tutorials/todo-app.md), [Security](guides/security.md) |
| Data tables | [05-process-viewer.ps1](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/05-process-viewer.ps1) (`process-viewer`) | [Updating the page](guides/updating-the-page.md) |
| Search, sort and page through records | [15-data-table.ps1](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/15-data-table.ps1) (`data-table`) | [Updating the page](guides/updating-the-page.md) |
| Polling, growing views | [06-log-tail.ps1](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/06-log-tail.ps1) (`log-viewer`) | [Background work](guides/background-work.md) |
| Native file dialogs | [07-file-preview.ps1](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/07-file-preview.ps1) (`file-viewer`) | [File dialogs](guides/file-dialogs.md) |
| Several windows, close policies | [08-multi-window.ps1](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/08-multi-window.ps1) (`multi-window`) | [Windows](guides/windows.md) |
| HTML dialogs, popovers, theming | [09-settings-dialog.ps1](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/09-settings-dialog.ps1) (`settings-dialog`) | [Dialogs and popovers](guides/dialogs-and-popovers.md), [Styling and layout](guides/styling-and-layout.md) |
| Clipboard | [10-clipboard-tool.ps1](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/10-clipboard-tool.ps1) (`clipboard-tool`) | [Clipboard and desktop](guides/clipboard-and-desktop.md) |
| Background work with progress | [11-background-checksums.ps1](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/11-background-checksums.ps1) (`checksums`) | [Background work](guides/background-work.md) |
| Several background jobs, queue, cancel | [18-background-jobs.ps1](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/18-background-jobs.ps1) (`background-jobs`) | [Background work](guides/background-work.md#several-jobs-at-once) |
| Periodic background refresh | [process-dashboard/app.ps1](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/process-dashboard/app.ps1) (`process-dashboard`) | [Process dashboard tutorial](tutorials/process-dashboard.md) |
| Live bitmaps | [12-live-chart.ps1](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/12-live-chart.ps1) (`live-chart`) | [Live bitmaps](guides/live-bitmaps.md) |
| Keyboard shortcuts | [13-keyboard-shortcuts.ps1](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/13-keyboard-shortcuts.ps1) (`keyboard-shortcuts`) | [Keyboard and focus](guides/keyboard-and-focus.md) |
| Diagnostics, support bundles | [14-diagnostics.ps1](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/14-diagnostics.ps1) (`diagnostics`) | [Diagnostics and troubleshooting](guides/diagnostics-and-troubleshooting.md) |
| Elements without ids (nodes) | [16-dom-explorer.ps1](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/16-dom-explorer.ps1) (`dom-explorer`) | [Updating the page](guides/updating-the-page.md#elements-without-ids-nodes) |
| Quit confirmation, saving on shutdown | [17-focus-timer.ps1](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/17-focus-timer.ps1) (`focus-timer`) | [Lifecycle](guides/lifecycle.md#ask-before-quitting-save-after-shutdown) |
| Multi-file app (HTML + CSS + PS) | [bulk-rename/](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/bulk-rename/app.ps1) (`bulk-rename`) | [Bulk rename tutorial](tutorials/bulk-rename.md) |

Generate your own starting point with `New-NativeHTMLKitProject -Path ./MyApp`
([project scaffolding](guides/project-scaffolding.md)). The cross-language
[public demo gallery](https://github.com/nativehtmlkit/nativehtmlkit/blob/main/examples/powershell-sdk/gallery.ps1)
shows several features in one window. For declarative layouts and reactive state, see the
separate [NativeHTMLKit.UI](https://github.com/nativehtmlkit/nativehtmlkit_ui) module.
