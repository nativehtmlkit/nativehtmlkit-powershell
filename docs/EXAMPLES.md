# Examples

The runnable example apps live in [examples/](../examples/README.md): fifteen small, complete
programs from a greeting form to a multi-window notes app, a live bitmap chart and the tutorial's
bulk file renamer. Each one states what it teaches in its header, accepts `-SelfTest`, and is run
against the real host on Linux (PowerShell 7) and Windows (PowerShell 7 and Windows PowerShell 5.1)
by `tests/Examples.Tests.ps1`.

| Task | Example | Guide |
|---|---|---|
| First app, lifecycle | [01-hello.ps1](../examples/01-hello.ps1) | [Script lifecycle](guides/script-lifecycle.md) |
| Event delegation, batches | [02-counter.ps1](../examples/02-counter.ps1) | [Events](guides/events-and-callbacks.md), [DOM updates](guides/dom-updates.md) |
| Forms and validation | [03-form-validation.ps1](../examples/03-form-validation.ps1) | [Forms](guides/forms.md) |
| Dynamic lists, safe HTML | [04-todo-list.ps1](../examples/04-todo-list.ps1) | [Security](guides/security.md) |
| Data tables | [05-process-viewer.ps1](../examples/05-process-viewer.ps1) | [DOM updates](guides/dom-updates.md) |
| Polling, growing views | [06-log-tail.ps1](../examples/06-log-tail.ps1) | [Background tasks](guides/background-tasks.md) |
| Native file dialogs | [07-file-preview.ps1](../examples/07-file-preview.ps1) | [File dialogs](guides/file-dialogs.md) |
| Several windows, close policies | [08-multi-window.ps1](../examples/08-multi-window.ps1) | [Multiple windows](guides/multiple-windows.md) |
| HTML dialogs, popovers, theming | [09-settings-dialog.ps1](../examples/09-settings-dialog.ps1) | [HTML dialogs and popovers](guides/html-dialogs-and-popovers.md) |
| Clipboard | [10-clipboard-tool.ps1](../examples/10-clipboard-tool.ps1) | [Clipboard](guides/clipboard.md) |
| Background work with progress | [11-background-checksums.ps1](../examples/11-background-checksums.ps1) | [Background tasks](guides/background-tasks.md) |
| Live bitmaps | [12-live-chart.ps1](../examples/12-live-chart.ps1) | [Live bitmaps](guides/live-bitmaps.md) |
| Keyboard shortcuts | [13-keyboard-shortcuts.ps1](../examples/13-keyboard-shortcuts.ps1) | [Events](guides/events-and-callbacks.md#keyboard-shortcuts) |
| Diagnostics, support bundles | [14-diagnostics.ps1](../examples/14-diagnostics.ps1) | [Diagnostics](guides/diagnostics.md) |
| Multi-file app (HTML + CSS + PS) | [bulk-rename/](../examples/bulk-rename/app.ps1) | [Tutorial](tutorials/bulk-rename.md) |

Generate your own starting point with `New-NativeHTMLKitProject -Path ./MyApp`
([project scaffolding](guides/project-scaffolding.md)). The cross-language
[public demo gallery](https://github.com/nativehtmlkit/nativehtmlkit/blob/main/examples/powershell-sdk/gallery.ps1)
shows several features in one window. For declarative layouts and reactive state, see the
separate [NativeHTMLKit.UI](https://github.com/nativehtmlkit/nativehtmlkit_ui) module.
