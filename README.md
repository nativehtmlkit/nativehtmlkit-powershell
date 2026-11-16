# NativeHTMLKit for PowerShell

**Real native HTML/CSS desktop windows driven by PowerShell scripts.** No browser, JavaScript, local HTTP server or Python runtime.

[PowerShell Gallery](https://www.powershellgallery.com/packages/NativeHTMLKit) · [Public guides](https://github.com/nativehtmlkit/nativehtmlkit) · [API reference](docs/API.md)

## Install

```powershell
Install-Module NativeHTMLKit -Scope CurrentUser
# Or, with PSResourceGet: Install-PSResource NativeHTMLKit -Scope CurrentUser
Import-Module NativeHTMLKit
```

PowerShell 7.2+ on Linux KDE Wayland and Windows; Windows PowerShell 5.1 on Windows. Supported published packages bundle the Rust Core host. Verify the platform/runtime before using these scripts in automation.

## First native window

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

## Main capabilities

- Windows, native dialogs and lifecycle hooks.
- Document events and mutations, forms and selection.
- Clipboard, accessibility integration, diagnostics and live RGBA bitmap updates.
- Background tasks with explicit owner-runspace callbacks.

For declarative layouts and reactive state use the separate [NativeHTMLKit.UI](https://github.com/nativehtmlkit/nativehtmlkit_ui) module. The SDK is not a UI component library.

## Continue

| Documentation | What it covers |
|---|---|
| [API](docs/API.md) | Cmdlet groups, parameters, lifecycle |
| [Architecture](docs/ARCHITECTURE.md) | Host, PowerShell script lifecycle, runspaces |
| [Examples](docs/EXAMPLES.md) | Working gallery and modules |
| [Verification](docs/BUILD.md) | Local test and package pipeline |
| [Skills](NativeHTMLKit/skills/nativehtmlkit-powershell/SKILL.md) | AI agent use |

**Module version:** 0.1.2 (bundles NativeHTMLKit Core 1.0.3, public wire protocol v1). 0.1.2 refreshes the Gallery description and documentation; the cmdlet API is unchanged from 0.1.1.

## Project navigation

- [Overview and tutorials](https://github.com/nativehtmlkit/nativehtmlkit) — public developer landing page.
- [Capability and platform matrix](https://github.com/nativehtmlkit/nativehtmlkit/blob/main/docs/capabilities/matrix.md) — which API works where.
- [Known limitations](https://github.com/nativehtmlkit/nativehtmlkit/blob/main/docs/capabilities/limitations.md) — known defects and qualification limits.
- Active private development work is tracked in `nativehtmlkit-project`, not in this repository's documentation.
