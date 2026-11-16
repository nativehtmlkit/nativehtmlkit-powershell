# PowerShell SDK usage

```powershell
Get-Command -Module NativeHTMLKit
Show-NativeHTMLKitHtmlDialog -Document $d -Element about
Show-NativeHTMLKitFileDialog -Window $w -Kind OpenFiles -Title 'Open'
```

For raw bitmap, `New-NativeHTMLKitLiveBitmap`, `Send-NativeHTMLKitLiveBitmap`, `Remove-NativeHTMLKitLiveBitmap`. Full gallery: https://github.com/nativehtmlkit/nativehtmlkit/blob/main/examples/powershell-sdk/gallery.ps1

## Verified rules (module 0.1.2, Core 1.0.3)

- Quit with `Request-NativeHTMLKitQuit`; `Close-NativeHTMLKit` belongs in `finally`. Ending the backend with `Close-NativeHTMLKit` from a callback makes the host report `application failed` and exit 1.
- Callbacks also run inside any waiting SDK command (for example during `Submit-NativeHTMLKitForm`), not only in `Wait-NativeHTMLKit`.
- Script-level callbacks write state with `$script:x`. Callbacks created in functions or loops need `.GetNewClosure()`; inside such a closure `$script:` is a different scope, so share state through a captured hashtable.
- Close/quit policies: the last output decides; a policy that throws counts as a veto.
- `Set-NativeHTMLKitDocumentValue`, `Set-NativeHTMLKitChecked` and `Set-NativeHTMLKitSelectedValues` dispatch no events.
- `Get-NativeHTMLKitSelection` returns `start`/`end`; its `length` is the whole value's length.
- `Invoke-NativeHTMLKitEditCommand -Command` accepts `undo`, `redo`, `cut`, `copy`, `paste`, `select_all`, `delete`.
- A `<dialog>` keeps its previous return value after Escape: decide in button handlers, not in the `close` event.
- `Set-NativeHTMLKitEnvironment -ColorScheme` accepts `light`, `dark`, `system`; `-ReducedMotion` accepts `reduce`, `no-preference`, `system`.
- `Get-NativeHTMLKitWindowList`, `Get-NativeHTMLKitStylesheets`, `Get-NativeHTMLKitSelectOptions` return one array object: assign before use.
- Headless (`NATIVEHTMLKIT_TEST_MODE=1`): clipboard, file dialogs, external open and attention throw `NativeHTMLKit.RpcException` code -32001. Check `Get-NativeHTMLKitCapabilities` and catch it.
- Background tasks: isolated runspace, plain-data `-ArgumentList` (`@(, $array)` for one array), `-OnCompleted { param($result) $result[0] }` runs on the UI runspace.

Runnable examples with `-SelfTest`: https://github.com/nativehtmlkit/nativehtmlkit-powershell/tree/main/examples · Reference: https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/docs/API.md
