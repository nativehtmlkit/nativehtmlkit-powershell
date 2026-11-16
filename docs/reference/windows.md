# Reference: windows

Creating, changing, listing and closing native windows, and the close policy. How-to:
[Multiple windows](../guides/multiple-windows.md).

A `NativeHTMLKit.Window` has read-only properties `Id` (host window id such as `w1`), `Closed`,
`Application` and `Document` (the current `NativeHTMLKit.Document` or `$null`). After the window
closes (user close, `Close-NativeHTMLKitWindow`, shutdown or `Close-NativeHTMLKit`) `Closed` is
`$true` and every command that takes the window throws `NativeHTMLKit.StaleObjectException`.

### New-NativeHTMLKitWindow

Alias: `New-NHKWindow`

Creates a native window (`window.create`). It is empty until you load a document with
`Open-NativeHTMLKitHtml` or `Open-NativeHTMLKitFile`. The number of windows is limited by
`Start-NativeHTMLKitScript -MaxWindows` (default 16).

```text
New-NativeHTMLKitWindow [-Application] <Object> [[-Title] <string>] [[-Width] <int>] [[-Height] <int>] [[-Visible] <bool>] [[-Resizable] <bool>] [[-Decorations] <bool>] [[-MinWidth] <int>] [[-MinHeight] <int>] [[-MaxWidth] <int>] [[-MaxHeight] <int>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Application` | `NativeHTMLKit.Application` | yes | - | The application. |
| `-Title` | `string` | no | `''` | Window title. |
| `-Width` | `int` | no | `900` | Initial width in logical pixels. Range 1 to 8192. |
| `-Height` | `int` | no | `600` | Initial height in logical pixels. Range 1 to 8192. |
| `-Visible` | `bool` | no | `$true` | Show the window when created. |
| `-Resizable` | `bool` | no | `$true` | Allow the user to resize the window. |
| `-Decorations` | `bool` | no | `$true` | Show the title bar and frame. |
| `-MinWidth` | `int` | no | - | Minimum width; sent only when given. Range 1 to 8192. |
| `-MinHeight` | `int` | no | - | Minimum height; sent only when given. Range 1 to 8192. |
| `-MaxWidth` | `int` | no | - | Maximum width; sent only when given. Range 1 to 8192. |
| `-MaxHeight` | `int` | no | - | Maximum height; sent only when given. Range 1 to 8192. |

**Returns** `NativeHTMLKit.Window`.

```powershell
$window = New-NativeHTMLKitWindow -Application $app -Title 'Inventory' -Width 1000 -Height 700 -MinWidth 640 -MinHeight 400
```

### Set-NativeHTMLKitWindow

Alias: `Set-NHKWindow`

Changes window state (`window.set`): only the parameters you pass are sent. `-Properties` passes
host field names directly (`title`, `width`, `height`, `visible`, `resizable`, `decorations`,
`minimized`, `maximized`, `fullscreen`, `focus`, `x`, `y`, `min_width`, `min_height`, `max_width`,
`max_height`); typed parameters override the same field. Size constraints are set in pairs; pass
`$null` values in `-Properties`, for example `@{ min_width = $null; min_height = $null }`, to clear
them. Window positioning (`-X`/`-Y`) is honoured only where the platform allows it (reported by
`window_positioning` in `Get-NativeHTMLKitCapabilities`; Wayland does not let applications
position windows).

```text
Set-NativeHTMLKitWindow [-Window] <Object> [[-Properties] <IDictionary>] [[-Title] <string>] [[-Width] <int>] [[-Height] <int>] [[-Visible] <bool>] [[-Resizable] <bool>] [[-Decorations] <bool>] [[-Minimized] <bool>] [[-Maximized] <bool>] [[-Fullscreen] <bool>] [[-Focus] <bool>] [[-X] <int>] [[-Y] <int>] [[-MinWidth] <int>] [[-MinHeight] <int>] [[-MaxWidth] <int>] [[-MaxHeight] <int>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Window` | `NativeHTMLKit.Window` | yes | - | The window. |
| `-Properties` | `System.Collections.IDictionary` | no | `@{}` | Hashtable of host field names and values. |
| `-Title` | `string` | no | - | New title. |
| `-Width` | `int` | no | - | New width. Range 1 to 8192. |
| `-Height` | `int` | no | - | New height. Range 1 to 8192. |
| `-Visible` | `bool` | no | - | Show or hide. |
| `-Resizable` | `bool` | no | - | Allow resizing. |
| `-Decorations` | `bool` | no | - | Show or hide the frame. |
| `-Minimized` | `bool` | no | - | Minimize or restore. |
| `-Maximized` | `bool` | no | - | Maximize or restore. |
| `-Fullscreen` | `bool` | no | - | Enter or leave full screen. |
| `-Focus` | `bool` | no | - | `$true` asks the desktop to focus the window. |
| `-X` | `int` | no | - | Horizontal position. |
| `-Y` | `int` | no | - | Vertical position. |
| `-MinWidth` | `int` | no | - | Minimum width. Range 1 to 8192. |
| `-MinHeight` | `int` | no | - | Minimum height. Range 1 to 8192. |
| `-MaxWidth` | `int` | no | - | Maximum width. Range 1 to 8192. |
| `-MaxHeight` | `int` | no | - | Maximum height. Range 1 to 8192. |

**Returns** the host's window description (same shape as `Get-NativeHTMLKitWindow`).

### Get-NativeHTMLKitWindow

Alias: `Get-NHKWindow`

Returns the host's description of the window (`window.get`).

```text
Get-NativeHTMLKitWindow [-Window] <Object> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Window` | `NativeHTMLKit.Window` | yes | - | The window. |

**Returns** an object with, for Core 1.0.3: `window_id`, `title`, `width`, `height`, `visible`,
`closing`, `native` (false in headless mode), `scale_factor`, `physical_size`, `requested`
(`decorations`, `resizable`, `visible`, `size_constraints`) and `observed` (what the desktop
reported: `focused`, `minimized`, `maximized`, `fullscreen`, `position`, `theme`, ...; `null` means
not observed).

### Get-NativeHTMLKitWindowList

Alias: `Get-NHKWindowList`

Lists the application's open windows (`window.list`), each with the same shape as
`Get-NativeHTMLKitWindow`.

The list is returned as **one array object**: assign it and use the variable
(`$list = Get-NativeHTMLKitWindowList -Application $app; $list.Count`). Wrapping the call in `@()`
or piping it yields a single item that contains the array.

```text
Get-NativeHTMLKitWindowList [-Application] <Object> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Application` | `NativeHTMLKit.Application` | yes | - | The application. |

### Close-NativeHTMLKitWindow

Alias: `Close-NHKWindow`

Requests a graceful close (`window.request_close`, reason `backend_request`). After
`Set-NativeHTMLKitReady`, the host first asks the window's `Set-NativeHTMLKitBeforeClose` policy,
which can veto; without a policy the window closes. The close completes while events are pumped:
the handle's `Closed` becomes `$true` when the host reports `window.event` `closed`. Before ready,
closing one of several windows closes it without asking the policy, and closing the last window
cancels startup (the app shuts down).

```text
Close-NativeHTMLKitWindow [-Window] <Object> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Window` | `NativeHTMLKit.Window` | yes | - | The window. |

**Returns** nothing.

### Set-NativeHTMLKitBeforeClose

Alias: `Set-NHKBeforeClose`

Sets the window's close policy. The host asks it (request `window.before_close`, parameters
`window_id` and `reason`: `native_close` for the title-bar button or window manager,
`backend_request` for `Close-NativeHTMLKitWindow`). The **last output value** of the scriptblock
decides: truthy closes, `$false` or no output keeps the window open. A policy that throws is
reported as a callback failure and the host receives an error reply. Keep policies fast: the host
waits for the answer. Pass `$null` to remove the policy.

```text
Set-NativeHTMLKitBeforeClose [-Window] <Object> [-Callback] <scriptblock> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Window` | `NativeHTMLKit.Window` | yes | - | The window. |
| `-Callback` | `scriptblock` | yes | - | Policy scriptblock, or `$null` to remove it. Accepts `$null`. |

```powershell
Set-NativeHTMLKitBeforeClose -Window $window -Callback {
    param($request)              # $request.reason: native_close or backend_request
    -not $script:dirty           # last output decides
}
```

### Request-NativeHTMLKitAttention

Alias: `Request-NHKAttention`

Asks the desktop to flag the window, for example by flashing its taskbar entry
(`window.request_attention`). `none` clears a previous request. Not available in headless mode
(`NativeHTMLKit.RpcException`, code -32001 `Attention requires a native desktop window`).

```text
Request-NativeHTMLKitAttention [-Window] <Object> [[-Kind] <string>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Window` | `NativeHTMLKit.Window` | yes | - | The window. |
| `-Kind` | `string` | no | `'informational'` | `informational`, `critical`, or `none` to clear. One of: `informational`, `critical`, `none`. |
