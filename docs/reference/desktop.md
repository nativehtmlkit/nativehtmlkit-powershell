# Reference: desktop services

Capabilities, desktop preferences, clipboard, opening URLs and files, and native file dialogs.
How-to: [File dialogs](../guides/file-dialogs.md), [Clipboard](../guides/clipboard.md).

Desktop services depend on the operating system and session. In the host's headless test mode
(`NATIVEHTMLKIT_TEST_MODE=1`) clipboard, file dialogs, external open and attention requests are
refused with `NativeHTMLKit.RpcException` (code -32001, unsupported). Check
`Get-NativeHTMLKitCapabilities` and handle `RpcException` instead of assuming a service exists.

### Get-NativeHTMLKitCapabilities

Alias: `Get-NHKCapabilities`

Returns what the running host offers (`host.capabilities`).

```text
Get-NativeHTMLKitCapabilities [-Application] <Object> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Application` | `NativeHTMLKit.Application` | yes | - | The application. |

**Returns** an object. Top-level fields for Core 1.0.3 include `native` and `headless`,
`platform` (`linux`, `windows`), `max_windows`, `max_documents`, `renderer` (`cpu`), `css_profile`,
`window_positioning`, `limits` (`frame_bytes`, `pending_requests`, ...), the service booleans
`clipboard_text`, `file_dialogs`, `external_open`, `drag_drop`, `ime`, `accessibility` (enabled API
surfaces; `$false` in headless mode), `features` (per-feature `supported`/`available` detail; `null`
means not observed) and `native_preferences`.

```powershell
$caps = Get-NativeHTMLKitCapabilities -Application $app
if (-not $caps.file_dialogs) { Set-NativeHTMLKitDocumentAttribute -Document $doc -Element browse -Name disabled }
```

### Get-NativeHTMLKitPreferences

Alias: `Get-NHKPreferences`

Returns the observed desktop preferences (`desktop.preferences`): `color_scheme`,
`reduced_motion`, `high_contrast` (each `$null` when not observed), `available`, `source`
(`headless` in test mode), `revision` and `scope`. Changes are announced by the
`desktop.preferences_changed` notification (see `Register-NativeHTMLKitNotification`). Documents
follow the observed preferences in CSS media queries unless overridden with
`Set-NativeHTMLKitEnvironment`.

```text
Get-NativeHTMLKitPreferences [-Application] <Object> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Application` | `NativeHTMLKit.Application` | yes | - | The application. |

### Get-NativeHTMLKitClipboard

Alias: `Get-NHKClipboard`

Reads plain text from the system clipboard (`clipboard.read_text`).

```text
Get-NativeHTMLKitClipboard [-Application] <Object> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Application` | `NativeHTMLKit.Application` | yes | - | The application. |

**Returns** `[string]` (empty when the clipboard holds no text). **Errors** `NativeHTMLKit.RpcException`
when the clipboard is unavailable (headless: `Clipboard requires a native event loop`).

### Set-NativeHTMLKitClipboard

Alias: `Set-NHKClipboard`

Writes plain text to the system clipboard (`clipboard.write_text`).

```text
Set-NativeHTMLKitClipboard [-Application] <Object> [-Text] <string> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Application` | `NativeHTMLKit.Application` | yes | - | The application. |
| `-Text` | `string` | yes | - | Text to copy. May be empty. |

**Errors** as for `Get-NativeHTMLKitClipboard`.

### Open-NativeHTMLKitExternal

Alias: `Open-NHKExternal`

Opens a URL or a document with the desktop's default handler (`desktop.open_external`), or with
`-Reveal` shows a file in the file manager (`desktop.reveal_file`; the path is resolved against the
PowerShell location). Accepted targets are `http`, `https`, `mailto` and `file` URIs and absolute
local paths; a relative path fails with code -32602, other schemes and executable file types
(programs, scripts, shortcuts) are denied with code -32003.
`-Window` names the parent window for any desktop prompt. Waits up to 60 seconds.

```text
Open-NativeHTMLKitExternal [-Application] <Object> [-Target] <string> [[-Window] <Object>] [-Reveal] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Application` | `NativeHTMLKit.Application` | yes | - | The application. |
| `-Target` | `string` | yes | - | URI or absolute path; with `-Reveal` a file path (relative paths are resolved against the PowerShell location). |
| `-Window` | `NativeHTMLKit.Window` | no | - | Parent window; must belong to `-Application`. |
| `-Reveal` | `switch` | no | off | Show the file in the file manager instead of opening it. |

**Returns** the host result (`accepted`, `cancelled`, ...).

### Show-NativeHTMLKitFileDialog

Alias: `Show-NHKFileDialog`

Shows a native Open, Save or Choose-folder dialog attached to a window (`dialog.open_files`,
`dialog.save_file`, `dialog.choose_folder`) and waits without a deadline while the user decides,
pumping events meanwhile. Only one native dialog per window can be open at a time (a second one
fails with code -32005, busy).

```text
Show-NativeHTMLKitFileDialog [-Window] <Object> [[-Kind] <string>] [[-Title] <string>] [[-Directory] <string>] [[-FileName] <string>] [[-Filters] <Object[]>] [[-Multiple] <bool>] [-NoWait] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Window` | `NativeHTMLKit.Window` | yes | - | Parent window. |
| `-Kind` | `string` | no | `'OpenFiles'` | `OpenFiles`, `SaveFile` or `ChooseFolder`. One of: `OpenFiles`, `SaveFile`, `ChooseFolder`. |
| `-Title` | `string` | no | - | Dialog title. |
| `-Directory` | `string` | no | - | Initial folder (resolved against the PowerShell location). |
| `-FileName` | `string` | no | - | Suggested file name; only with `-Kind SaveFile`. |
| `-Filters` | `object[]` | no | `@()` | Array of `@{ name = 'Images'; extensions = @('png', 'jpg') }` (extensions without dot). Ignored for `ChooseFolder`. |
| `-Multiple` | `bool` | no | `$false` | `OpenFiles` only: allow several files. |
| `-NoWait` | `switch` | no | off | Return a `NativeHTMLKit.Request` immediately instead of waiting. |

**Returns** `@{ cancelled; paths }`: `cancelled` is `$true` and `paths` empty when the user
cancelled. With `-NoWait`, a `NativeHTMLKit.Request`: `Wait-NativeHTMLKitRpc` returns the same
result later, `Stop-NativeHTMLKitRpc` closes the dialog. **Errors** `NativeHTMLKit.RpcException`
when dialogs are unavailable (headless: code -32001 `Native file dialogs are unavailable in headless mode`).

```powershell
try {
    $pick = Show-NativeHTMLKitFileDialog -Window $window -Kind OpenFiles -Multiple $true -Title 'Import logs' -Filters @(@{ name = 'Logs'; extensions = @('log', 'txt') })
    if (-not $pick.cancelled) { foreach ($path in $pick.paths) { Import-Log $path } }
} catch [NativeHTMLKit.RpcException] {
    Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text $_.Exception.RpcMessage
}
```
