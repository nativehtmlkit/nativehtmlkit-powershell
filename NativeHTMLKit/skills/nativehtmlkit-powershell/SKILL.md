---
name: nativehtmlkit-powershell
description: Create desktop HTML/CSS applications using the public NativeHTMLKit PowerShell SDK cmdlets.
---

# NativeHTMLKit PowerShell SDK

Target PowerShell 7.2+ on Linux KDE Wayland/Windows, or Windows PowerShell 5.1 on Windows. Import `NativeHTMLKit` and use **public exported cmdlets**.

```powershell
Import-Module NativeHTMLKit
$app = Start-NativeHTMLKitScript -Name 'MyApp'
try {
  $w = New-NativeHTMLKitWindow -Application $app -Title 'Hello'
  $d = Open-NativeHTMLKitHtml -Window $w -Html '<p id="p">Ready</p>'
  $null = Register-NativeHTMLKitDocumentEvent -Document $d -Type click -Element p -Callback ({
    param($eventObject) Set-NativeHTMLKitDocumentText -Document $d -Element p -Text 'Clicked'
  }.GetNewClosure())
  Set-NativeHTMLKitReady -Application $app
  Wait-NativeHTMLKit -Application $app -UntilShutdown
} finally { Close-NativeHTMLKit -Application $app }
```

Document event handlers use a single event parameter, **not** a generic `-Data` parameter (that belongs to the UI-layer event helper). Inside functions use `.GetNewClosure()` when local bindings must survive invocation.

Use SDK cmdlets for window/clipboard/dialog/bitmap operations. The backend PowerShell script can be restarted by the launcher; keep side effects below `Start-NativeHTMLKitScript`. Do not use the private transport or add a server. Reactive components belong to `nativehtmlkit-ui-powershell`.

See [examples](references/examples.md) and [docs](https://github.com/nativehtmlkit/nativehtmlkit-powershell).
