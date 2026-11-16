# PowerShell SDK API — cmdlet reference by task

The public module is `NativeHTMLKit`. Import with `Import-Module NativeHTMLKit` and use fully named commands (`New-NativeHTMLKitWindow`, etc.) or the documented `-NHK` aliases.

| Task | Commands |
|---|---|
| Host lifecycle | `Start-NativeHTMLKitScript`, `Connect-NativeHTMLKit`, `Wait-NativeHTMLKit`, `Close-NativeHTMLKit`, `Set-NativeHTMLKitReady` |
| Windows | `New-NativeHTMLKitWindow`, `Get-NativeHTMLKitWindow`, `Set-NativeHTMLKitWindow`, `Close-NativeHTMLKitWindow` |
| Document | `Open-NativeHTMLKitHtml`, `Open-NativeHTMLKitFile`, `Invoke-NativeHTMLKitDocumentCommand`, `Set-NativeHTMLKitDocumentText`, `Set-NativeHTMLKitDocumentValue` |
| Events | `Register-NativeHTMLKitDocumentEvent`, `Unregister-NativeHTMLKitDocumentEvent` |
| Dialogs | `Show-NativeHTMLKitHtmlDialog`, `Show-NativeHTMLKitFileDialog`, `Show-NativeHTMLKitPopover` |
| DOM/forms | `Find-NativeHTMLKitElement`, `Get-NativeHTMLKitFormData`, `Submit-NativeHTMLKitForm`, `Reset-NativeHTMLKitForm` |
| Clipboard | `Get-NativeHTMLKitClipboard`, `Set-NativeHTMLKitClipboard` |
| Live surfaces | `New-NativeHTMLKitLiveBitmap`, `Send-NativeHTMLKitLiveBitmap`, `Remove-NativeHTMLKitLiveBitmap` |
| Diagnostics | `Get-NativeHTMLKitDiagnostics`, `Get-NativeHTMLKitCapabilities`, `Export-NativeHTMLKitSupportBundle` |
| Background tasks | `Start-NativeHTMLKitTask`, `Receive-NativeHTMLKitTask`, `Stop-NativeHTMLKitTask` |

`Show-NativeHTMLKitFileDialog -Window $window -Kind OpenFiles -Multiple $true` uses the OS picker. Add `-NoWait` for a request handle and use the SDK's waiting/cancellation commands. `Show-NativeHTMLKitHtmlDialog -Document ...` controls an HTML `<dialog>` element; confirm exact parameters with `Get-Help` for your installed module.

The source module manifest lists the public exports. Run `Get-Command -Module NativeHTMLKit` for the authoritative installed command list. SDK objects must be used on the owning PowerShell runspace; background tasks must communicate through completion callbacks, not share UI state directly.
