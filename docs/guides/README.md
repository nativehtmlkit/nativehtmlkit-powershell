# How-to guides

Task-oriented recipes for the NativeHTMLKit PowerShell SDK 0.1.2 (module `NativeHTMLKit`, Core
1.0.3). New to the SDK? Start with [getting started](../getting-started.md) and the
[todo tutorial](../tutorials/todo-app.md). Exact syntax is in the [cmdlet reference](../API.md).

| Guide | You want to... |
|---|---|
| [Application lifecycle](lifecycle.md) | structure a script: start, ready, wait, quit, close; ask before quitting; save on shutdown |
| [Events and callbacks](events-and-callbacks.md) | react to clicks and typing; delegate events; understand closures and scope |
| [Updating the page](updating-the-page.md) | change text, attributes and classes; render lists safely; batch updates; nodes without ids |
| [Forms and validation](forms-and-validation.md) | read form values, use HTML validation, add your own rules |
| [Windows](windows.md) | open several windows, keep per-window state, veto closing |
| [Native file dialogs](file-dialogs.md) | let the user open, save or choose a folder |
| [HTML dialogs and popovers](dialogs-and-popovers.md) | show modal `<dialog>`s and `popover` elements |
| [Clipboard and desktop](clipboard-and-desktop.md) | copy and paste text, open links and files, read desktop preferences |
| [Keyboard and focus](keyboard-and-focus.md) | add shortcuts, stop default key actions, move the focus, work with the caret |
| [Styling and layout](styling-and-layout.md) | lay out an app window, use stylesheets and dark mode, know what HTML/CSS the host supports |
| [Live bitmaps](live-bitmaps.md) | draw charts or images from PowerShell pixels |
| [Background work](background-work.md) | run slow work without freezing the window; progress, cancel, timers, several jobs |
| [Diagnostics and troubleshooting](diagnostics-and-troubleshooting.md) | find out why something does not happen; collect a support bundle |
| [Packaging and distribution](packaging-and-distribution.md) | ship an app to users, with or without the PowerShell Gallery |
| [Project scaffolding](project-scaffolding.md) | generate a multi-file project and its manifest |
| [Security](security.md) | handle untrusted text, HTML, files and secrets safely |

PowerShell-specific:

| Guide | You want to... |
|---|---|
| [Windows PowerShell 5.1 and PowerShell 7](windows-powershell-51.md) | write scripts that run unchanged on both editions |

Every guide links to runnable applications in the
[examples](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/README.md).
