# How to copy and paste text

Reference: [Get-/Set-NativeHTMLKitClipboard](../reference/desktop.md#get-nativehtmlkitclipboard).
Example: [10-clipboard-tool.ps1](../../examples/10-clipboard-tool.ps1).

The SDK reads and writes **plain text** on the system clipboard through the host. Text controls in
your documents handle the usual editing shortcuts themselves; you need these cmdlets for actions
such as a "Copy result" or "Paste from clipboard" button.

```powershell
function Invoke-Copy {
    $text = Get-NativeHTMLKitValue -Document $doc -Element output
    try {
        Set-NativeHTMLKitClipboard -Application $app -Text $text
        Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text "Copied $($text.Length) characters."
    } catch [NativeHTMLKit.RpcException] {
        Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text ('Copy failed: ' + $_.Exception.RpcMessage)
    }
}

function Invoke-Paste {
    try { Set-NativeHTMLKitDocumentValue -Document $doc -Element input -Value (Get-NativeHTMLKitClipboard -Application $app) }
    catch [NativeHTMLKit.RpcException] { Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text $_.Exception.RpcMessage }
}
```

## Availability

Check `clipboard_text` in `Get-NativeHTMLKitCapabilities` and disable the buttons when it is
`$false`. In headless test mode the clipboard is unavailable and both cmdlets throw
`NativeHTMLKit.RpcException` (code -32001, `Clipboard requires a native event loop`); always
handle that exception, because desktop clipboard owners can also refuse a request.

## Editing commands

To copy the **selection** of a text control, or paste into it at the caret, use the native editor:

```powershell
Invoke-NativeHTMLKitEditCommand -Document $doc -Element editor -Command copy
Invoke-NativeHTMLKitEditCommand -Document $doc -Element editor -Command paste
```

These complete asynchronously; the cmdlet accepting the command does not mean the transfer
succeeded. Observe `input` events (paste) or the control's value.

## Privacy

Clipboard content can be sensitive. The SDK's diagnostics never record it. Avoid writing it to
logs yourself, and read the clipboard only in response to a user action.
