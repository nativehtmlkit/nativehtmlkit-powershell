# How to use the clipboard and desktop services

Reference: [desktop](../reference/desktop.md) (clipboard, external open, preferences, capabilities).
Example: [10-clipboard-tool.ps1](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/10-clipboard-tool.ps1).

This guide covers the clipboard, opening links and files with the desktop's default handler, and
reading desktop preferences.

## Copy and paste text

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

## Open links and files

Links in the page never navigate. Activating an `<a href>` gives the backend a `link_activated`
document event with the `href` and the resolved `url` (as described in the
[Core guide](https://github.com/nativehtmlkit/nativehtmlkit-core/blob/main/docs/guides/html-css-support.md#elements-and-links));
your handler decides what happens, typically opening it in the user's browser:

```powershell
$null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type link_activated -Callback {
    param($evt)
    try { $null = Open-NativeHTMLKitExternal -Application $app -Target ([string]$evt.url) -Window $window }
    catch [NativeHTMLKit.RpcException] { Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text $_.Exception.RpcMessage }
}
```

`Open-NativeHTMLKitExternal` accepts `http`, `https`, `mailto` and `file` URIs and absolute local
paths, and refuses programs, scripts and shortcuts (code -32003). `-Reveal` shows a file in the file
manager instead of opening it. In headless mode both throw `NativeHTMLKit.RpcException` -32001
(`External open requires a desktop session`). Headless runs have no pointer input, so the
`link_activated` path itself is checked on a desktop.

## Desktop preferences and capabilities

```powershell
$prefs = Get-NativeHTMLKitPreferences -Application $app     # color_scheme, reduced_motion, high_contrast, available, source
$caps  = Get-NativeHTMLKitCapabilities -Application $app    # clipboard_text, external_open, file_dialogs, headless, ...
Register-NativeHTMLKitNotification -Application $app -Method 'desktop.preferences_changed' -Callback {
    param($params)
    Update-ThemeLabel
}
```

Each preference is `$null` when the host has not observed it; in headless mode `available` is
`$false` and `source` is `headless`. Pages follow the observed colour scheme through CSS media
queries without any code ([styling and layout](styling-and-layout.md#light-and-dark)). Use the
capabilities to hide buttons for services that the current session does not offer.
[14-diagnostics.ps1](https://github.com/nativehtmlkit/nativehtmlkit-powershell/blob/main/examples/14-diagnostics.ps1) shows both in an About window.

## Privacy

Clipboard content can be sensitive. The SDK's diagnostics never record it. Avoid writing it to
logs yourself, and read the clipboard only in response to a user action.
