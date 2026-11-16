# NativeHTMLKit for PowerShell

**Real native HTML/CSS desktop windows driven by PowerShell scripts.** No browser, JavaScript, local HTTP server or Python runtime.

[PowerShell Gallery](https://www.powershellgallery.com/packages/NativeHTMLKit) · [Getting started](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/docs/getting-started.md) · [Cmdlet reference](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/docs/API.md) · [Tutorials](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/docs/tutorials/todo-app.md) · [Examples](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/README.md) · [Project site](https://github.com/nativehtmlkit/nativehtmlkit)

## Install

```powershell
Install-Module NativeHTMLKit -Scope CurrentUser
# Or, with PSResourceGet: Install-PSResource NativeHTMLKit -Scope CurrentUser
Import-Module NativeHTMLKit
```

PowerShell 7.2+ on Linux KDE Wayland and Windows; Windows PowerShell 5.1 on Windows. Supported published packages bundle the Rust Core host. Verify the platform/runtime before using these scripts in automation.

## Quick start

```powershell
Import-Module NativeHTMLKit
$app = Start-NativeHTMLKitScript -Name 'PowerShell Hello'
try {
    $window = New-NativeHTMLKitWindow -Application $app -Title 'PowerShell Hello'
    $doc = Open-NativeHTMLKitHtml -Window $window -Html '<button id="go">Click</button><p id="status">Ready</p>'
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element go -Callback {
        Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text 'Clicked!'
    }
    Set-NativeHTMLKitReady -Application $app
    Wait-NativeHTMLKit -Application $app -UntilShutdown
} finally {
    Close-NativeHTMLKit -Application $app
}
```

Save as `app.ps1` and run `pwsh -File app.ps1` (or `powershell.exe -File app.ps1` on Windows). `Start-NativeHTMLKitScript` invokes the app script under a supervised host/backend arrangement; keep side effects below that call.

## How it works in one paragraph

The bundled native host draws the windows and renders HTML/CSS; your script is its backend. You
create windows, load HTML, subscribe PowerShell scriptblocks to DOM events (`click`, `input`,
`submit`, `keydown`, ...) and change the document by element id (`Set-NativeHTMLKitDocumentText`,
`Set-NativeHTMLKitDocumentHtml`, `Invoke-NativeHTMLKitBatch`). Callbacks run on your script's
runspace while `Wait-NativeHTMLKit` pumps events; slow work goes to `Start-NativeHTMLKitTask`.
[Architecture](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/docs/ARCHITECTURE.md).

## Main capabilities

- Windows, native file dialogs, close and quit policies, several windows per app.
- Document events with delegation, DOM updates and atomic batches, forms with native validation,
  HTML `<dialog>` and popovers, stylesheets, colour-scheme overrides, selection and editing.
- Clipboard, accessibility integration, diagnostics and live RGBA bitmap updates.
- Background tasks with explicit owner-runspace callbacks.
- `New-NativeHTMLKitProject` scaffolding and a coding-agent skill (`Install-NativeHTMLKitSkill`).

For declarative layouts and reactive state use the separate [NativeHTMLKit.UI](https://github.com/nativehtmlkit/nativehtmlkit_ui) module. The SDK is not a UI component library.

## Examples

Twenty runnable apps, each verified against the real host on Linux and Windows (PowerShell 7 and Windows PowerShell 5.1):
[hello](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/01-hello.ps1),
[counter](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/02-counter.ps1),
[sign-up form](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/03-form-validation.ps1),
[todo list](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/04-todo-list.ps1),
[process viewer](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/05-process-viewer.ps1),
[log viewer](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/06-log-tail.ps1),
[file viewer](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/07-file-preview.ps1),
[window manager](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/08-multi-window.ps1),
[settings dialog](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/09-settings-dialog.ps1),
[clipboard tool](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/10-clipboard-tool.ps1),
[background checksums](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/11-background-checksums.ps1),
[live chart](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/12-live-chart.ps1),
[keyboard shortcuts](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/13-keyboard-shortcuts.ps1),
[diagnostics](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/14-diagnostics.ps1),
[data table](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/15-data-table.ps1),
[DOM explorer](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/16-dom-explorer.ps1),
[focus timer](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/17-focus-timer.ps1),
[background jobs](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/18-background-jobs.ps1), and the tutorial apps
[bulk-rename](https://github.com/nativehtmlkit/nativehtmlkit-powershell/tree/main/examples/bulk-rename) and [process-dashboard](https://github.com/nativehtmlkit/nativehtmlkit-powershell/tree/main/examples/process-dashboard).
[catalog.toml](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/catalog.toml) lists them with the ids shared with the Python SDK.

## Documentation

| Documentation | What it covers |
|---|---|
| [Getting started](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/docs/getting-started.md) | Install, first window, run, test without a desktop |
| Tutorials | [Todo app](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/docs/tutorials/todo-app.md) (forms, lists, editing, JSON), [process dashboard](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/docs/tutorials/process-dashboard.md) (background refresh), [bulk rename](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/docs/tutorials/bulk-rename.md) (multi-file project) |
| [How-to guides](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/docs/guides/README.md) | Lifecycle, events, updating the page, forms, windows, dialogs, clipboard, keyboard and focus, styling, bitmaps, background work, diagnostics, packaging, scaffolding, security, Windows PowerShell 5.1 |
| [Cmdlet reference](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/docs/API.md) | All 88 cmdlets and aliases: syntax, parameters, outputs, errors |
| [Architecture](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/docs/ARCHITECTURE.md) | Host, launcher/backend, runspaces, handles |
| [Examples](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/docs/EXAMPLES.md) | Examples by task |
| [Verification](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/docs/BUILD.md) | Local test and package pipeline |
| [Skills](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/NativeHTMLKit/skills/nativehtmlkit-powershell/SKILL.md) | AI agent use |

**Module version:** 0.1.2 (bundles NativeHTMLKit Core 1.0.3, public wire protocol v1). 0.1.2 refreshes the Gallery description and documentation; the cmdlet API is unchanged from 0.1.1.

## Project navigation

- [Overview and tutorials](https://github.com/nativehtmlkit/nativehtmlkit) — public developer landing page.
- [Capability and platform matrix](https://github.com/nativehtmlkit/nativehtmlkit/blob/main/docs/capabilities/matrix.md) — which API works where.
- [Known limitations](https://github.com/nativehtmlkit/nativehtmlkit/blob/main/docs/capabilities/limitations.md) — known defects and qualification limits.
- Active private development work is tracked in `nativehtmlkit-project`, not in this repository's documentation.
