# Reference: documents and DOM updates

Loading HTML, reading and changing elements by id, stylesheets, computed style, environment,
scrolling, focus and text selection. How-to: [DOM updates](../guides/updating-the-page.md).

A `NativeHTMLKit.Document` has read-only properties `Id` (such as `d1`), `Window` and `Retired`.
A window has at most one document. Loading another document into the window (or
`Remove-NativeHTMLKitDocument`, a fatal `document.error`, closing the window) **retires** the old
one: its handlers, nodes and bitmaps are released and every later use throws
`NativeHTMLKit.StaleObjectException` (`This NativeHTMLKit document was replaced, unloaded, or its window closed`).

Commands that take `-Element` address an element by its `id` attribute. An unknown id, invalid
arguments or an operation the element does not support make the host answer with an error, which
surfaces as `NativeHTMLKit.RpcException` (for example code -32602, invalid parameters). Every command
in this page waits for the host's reply and pumps events while waiting (see
[events](events.md#when-callbacks-run)).

### Open-NativeHTMLKitHtml

Alias: `Open-NHKHtml`

Loads an HTML string into the window (`document.load`), atomically replacing any current document.
Use a full document (`<!doctype html><html>...`) or a fragment. Relative URLs (stylesheets, images,
fonts) resolve against `-AssetRoot`. Scripts are not executed: NativeHTMLKit has no JavaScript; all
behaviour is PowerShell callbacks.

```text
Open-NativeHTMLKitHtml [-Window] <Object> [-Html] <string> [[-AssetRoot] <string>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Window` | `NativeHTMLKit.Window` | yes | - | The window to load into. |
| `-Html` | `string` | yes | - | HTML text. May be empty. |
| `-AssetRoot` | `string` | no | - | Folder that relative resource URLs resolve against. Resolved against the PowerShell location. |

**Returns** `NativeHTMLKit.Document`. Waits up to 30 seconds for the host.

### Open-NativeHTMLKitFile

Alias: `Open-NHKFile`

Loads an HTML file into the window, atomically replacing any current document. Relative URLs in
the file (`<link rel="stylesheet" href="style.css">`) resolve against the file's folder unless
`-AssetRoot` is given. The path is resolved against the PowerShell location (`Set-Location`), not
the process working directory.

```text
Open-NativeHTMLKitFile [-Window] <Object> [-Path] <string> [[-AssetRoot] <string>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Window` | `NativeHTMLKit.Window` | yes | - | The window to load into. |
| `-Path` | `string` | yes | - | HTML file path. |
| `-AssetRoot` | `string` | no | - | Folder that relative resource URLs resolve against. |

**Returns** `NativeHTMLKit.Document`. Waits up to 30 seconds.

```powershell
$doc = Open-NativeHTMLKitFile -Window $window -Path (Join-Path $PSScriptRoot 'index.html')
```

### Remove-NativeHTMLKitDocument

Alias: `Remove-NHKDocument`

Unloads the document (`document.unload`); the window stays open and empty, and the document handle
is retired.

```text
Remove-NativeHTMLKitDocument [-Document] <Object> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |

### Get-NativeHTMLKitDocumentText

Alias: `Get-NHKDocumentText`

Returns an element's text content (`get_text`) as `[string]`.

```text
Get-NativeHTMLKitDocumentText [-Document] <Object> [-Element] <string> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Element` | `string` | yes | - | Element id. |

### Set-NativeHTMLKitDocumentText

Alias: `Set-NHKDocumentText`

Replaces an element's children with a single text node (`set_text`). The text is **never parsed
as HTML**, so it is the safe way to show user input, file content or command output.

```text
Set-NativeHTMLKitDocumentText [-Document] <Object> [-Element] <string> [-Text] <string> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Element` | `string` | yes | - | Element id. |
| `-Text` | `string` | yes | - | New text. May be empty. |

### Get-NativeHTMLKitValue

Alias: `Get-NHKValue`

Returns the current value of a form control (`get_value`): text of an `<input>` or `<textarea>`,
the selected value of a `<select>`.

```text
Get-NativeHTMLKitValue [-Document] <Object> [-Element] <string> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Element` | `string` | yes | - | Element id of the control. |

**Returns** `[string]`.

### Set-NativeHTMLKitDocumentValue

Alias: `Set-NHKDocumentValue`

Sets a control's current value (`set_value`). This changes the value the user sees, not the
`value` attribute, and it does not dispatch `input` or `change` events. After setting a text
control's value the caret is at its end.

```text
Set-NativeHTMLKitDocumentValue [-Document] <Object> [-Element] <string> [-Value] <string> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Element` | `string` | yes | - | Element id of the control. |
| `-Value` | `string` | yes | - | New value. May be empty. |

### Get-NativeHTMLKitChecked

Alias: `Get-NHKChecked`

Returns whether a checkbox or radio button is checked (`get_checked`), as `[bool]`.

```text
Get-NativeHTMLKitChecked [-Document] <Object> [-Element] <string> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Element` | `string` | yes | - | Element id of the checkbox or radio button. |

### Set-NativeHTMLKitChecked

Alias: `Set-NHKChecked`

Checks or unchecks a checkbox or radio button (`set_checked`). Does not dispatch events.

```text
Set-NativeHTMLKitChecked [-Document] <Object> [-Element] <string> [-Checked] <bool> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Element` | `string` | yes | - | Element id. |
| `-Checked` | `bool` | yes | - | New state. |

### Set-NativeHTMLKitDocumentAttribute

Alias: `Set-NHKDocumentAttribute`

Sets an attribute (`set_attribute`) or, with `-Remove`, removes it (`remove_attribute`). Use an
empty value for boolean attributes: `-Name disabled` disables a button, `-Name disabled -Remove`
enables it.

```text
Set-NativeHTMLKitDocumentAttribute [-Document] <Object> [-Element] <string> [-Name] <string> [[-Value] <string>] [-Remove] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Element` | `string` | yes | - | Element id. |
| `-Name` | `string` | yes | - | Attribute name. |
| `-Value` | `string` | no | `''` | Attribute value (ignored with `-Remove`). |
| `-Remove` | `switch` | no | off | Remove the attribute instead of setting it. |

### Set-NativeHTMLKitClass

Alias: `Set-NHKClass`

Adds a class (`add_class`) or, with `-Remove`, removes it (`remove_class`).

```text
Set-NativeHTMLKitClass [-Document] <Object> [-Element] <string> [-Name] <string> [-Remove] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Element` | `string` | yes | - | Element id. |
| `-Name` | `string` | yes | - | Class name. |
| `-Remove` | `switch` | no | off | Remove the class instead of adding it. |

```powershell
Set-NativeHTMLKitClass -Document $doc -Element status -Name error -Remove:(-not $failed)
```

### Set-NativeHTMLKitDocumentHtml

Alias: `Set-NHKDocumentHtml`

Replaces an element's children with HTML (`replace_children_html`, the default `-Position replace`)
or inserts HTML relative to it (`insert_html` with `beforebegin`, `afterbegin`, `beforeend` or
`afterend`). The HTML is parsed: only pass **trusted** markup and encode every untrusted value
with `[System.Net.WebUtility]::HtmlEncode()`; see [security](../guides/security.md).

```text
Set-NativeHTMLKitDocumentHtml [-Document] <Object> [-Element] <string> [-Html] <string> [[-Position] <string>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Element` | `string` | yes | - | Element id. |
| `-Html` | `string` | yes | - | HTML to insert. May be empty (clears the element with `replace`). |
| `-Position` | `string` | no | `'replace'` | Where to put the HTML. One of: `replace`, `beforebegin`, `afterbegin`, `beforeend`, `afterend`. |

```powershell
$row = '<li>' + [Net.WebUtility]::HtmlEncode($line) + '</li>'
Set-NativeHTMLKitDocumentHtml -Document $doc -Element log -Html $row -Position beforeend
```

### Remove-NativeHTMLKitElement

Alias: `Remove-NHKElement`

Removes an element and its subtree (`remove_element`).

```text
Remove-NativeHTMLKitElement [-Document] <Object> [-Element] <string> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Element` | `string` | yes | - | Element id. |

### Find-NativeHTMLKitElement

Alias: `Find-NHKElement`

Runs a CSS selector query (`query`). The result counts every matching element but lists only the
**ids** of matches that have one; use `Get-NativeHTMLKitNodes` to address matches without ids.

```text
Find-NativeHTMLKitElement [-Document] <Object> [-Selector] <string> [[-Offset] <int>] [[-Limit] <int>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Selector` | `string` | yes | - | CSS selector. |
| `-Offset` | `int` | no | `0` | Index of the first id to return. Range 0 to 2147483647. |
| `-Limit` | `int` | no | `1024` | Maximum number of ids to return. Range 1 to 4096. |

**Returns** an object: `ids` (array of id strings), `matched_nodes` (number of matching elements),
`total` (number of matching elements that have an id), `offset`, `limit`, `truncated`.

```powershell
$rows = (Find-NativeHTMLKitElement -Document $doc -Selector '#rows tr').matched_nodes
```

### Invoke-NativeHTMLKitBatch

Alias: `Invoke-NHKBatch`

Applies several id-addressed DOM operations as **one atomic transaction** (`batch`): either all of
them apply or none does, and they are painted together. Each operation is a hashtable with `op`
and its fields:

| `op` | Fields |
|---|---|
| `set_text` | `element`, `text` |
| `append_text` | `element`, `text` |
| `set_attribute` | `element`, `name`, `value` |
| `remove_attribute` | `element`, `name` |
| `add_class`, `remove_class` | `element`, `name` |
| `insert_html` | `element`, `position` (`beforebegin`, `afterbegin`, `beforeend`, `afterend`), `html` |
| `replace_children_html` | `element`, `html` |
| `remove_element` | `element` |
| `move_element` | `element`, `target`, `position` |
| `trim_children` | `element`, `keep`, optional `from` (`start` (default) removes the first children, `end` removes the last) |

```text
Invoke-NativeHTMLKitBatch [-Document] <Object> [-Operations] <Object[]> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Operations` | `object[]` | yes | - | Array of operation hashtables. |

**Returns** nothing.

```powershell
Invoke-NativeHTMLKitBatch -Document $doc -Operations @(
    @{ op = 'set_text'; element = 'count'; text = '42' }
    @{ op = 'add_class'; element = 'count'; name = 'changed' }
    @{ op = 'insert_html'; element = 'history'; position = 'afterbegin'; html = '<li>42</li>' }
    @{ op = 'trim_children'; element = 'history'; keep = 10; from = 'end' }
)
```

### Invoke-NativeHTMLKitDocumentCommand

Alias: `Invoke-NHKDocumentCommand`

Runs any document command of the Core wire protocol (`document.command`) and returns its result.
The typed cmdlets cover the common commands; this one gives access to the rest, for example
`get_html`, `get_attribute`, `get_attributes`, `has_element`, `get_rect`, `get_dialog`,
`get_popover`, `check_validity`, `get_validity`, `set_custom_validity`, `scroll_into_view`,
`scroll_by`, `set_scroll_follow`, `replace_control_range`, `select_text` and
`get_accessibility_tree`. The exact fields of all 81 operations are in the
[Core protocol contract](https://github.com/nativehtmlkit/nativehtmlkit-core/blob/main/protocol/README.md)
(`protocol/v1/schemas/document-command.schema.json`).

```text
Invoke-NativeHTMLKitDocumentCommand [-Document] <Object> [-Operation] <string> [[-Parameters] <IDictionary>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Operation` | `string` | yes | - | The command name (the protocol's `op`). |
| `-Parameters` | `System.Collections.IDictionary` | no | `@{}` | Command fields. `op` is not allowed here; use `-Operation`. |

Commands used in this repository's examples (verified with Core 1.0.3):

| Operation | Parameters | Result |
|---|---|---|
| `get_html` | `element` or `node`, optional `outer` (bool), `offset`, `limit` | `html`, `total_bytes`, `truncated`, `offset`, `next_offset` |
| `get_attribute` | `element`, `name` | `value` |
| `get_dialog` | `element` | `open`, `modal`, `return_value` |
| `get_popover` | `element` | `open` |
| `set_scroll_follow` | `element`, `follow` (default `$true`) | keeps a scroll container pinned to its end while content is appended |
| `replace_control_range` | `element` or `node`, `replacement`, optional `start`, `end` (UTF-16), `selection_mode` | replaces the given range, or the current selection, of a text control |

```powershell
$outer = (Invoke-NativeHTMLKitDocumentCommand -Document $doc -Operation get_html -Parameters @{ element = 'status'; outer = $true }).html
```

### Add-NativeHTMLKitStylesheet

Alias: `Add-NHKStylesheet`

Adds an author stylesheet to the document (`add_stylesheet`).

```text
Add-NativeHTMLKitStylesheet [-Document] <Object> [-Css] <string> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Css` | `string` | yes | - | CSS text. May be empty (useful as a placeholder sheet to replace later). |

**Returns** an object with `sheet` (the sheet handle, a number) and `diagnostics` (CSS parse notes).

### Get-NativeHTMLKitStylesheets

Alias: `Get-NHKStylesheets`

Lists the document's stylesheets (`list_stylesheets`). Returned as **one array object** (assign it
and use the variable). Each entry has `sheet`, `kind` (`attached` for sheets added with
`Add-NativeHTMLKitStylesheet`), `length`, `href`, `media`, `element`, `node`.

```text
Get-NativeHTMLKitStylesheets [-Document] <Object> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |

### Set-NativeHTMLKitStylesheet

Alias: `Set-NHKStylesheet`

Replaces the CSS of a sheet (`replace_stylesheet`, parameter set `Replace`) or removes it
(`remove_stylesheet`, set `Remove`).

```text
Set-NativeHTMLKitStylesheet -Document <Object> -Sheet <long> -Css <string> [<CommonParameters>]
Set-NativeHTMLKitStylesheet -Document <Object> -Sheet <long> -Remove [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Sheet` | `long` | yes | - | Sheet handle from `Add-NativeHTMLKitStylesheet` or `Get-NativeHTMLKitStylesheets`. |
| `-Css` | `string` | yes (Replace) | - | New CSS text. Parameter set: Replace. |
| `-Remove` | `switch` | yes (Remove) | off | Remove the sheet. Parameter set: Remove. |

```powershell
$sheet = (Add-NativeHTMLKitStylesheet -Document $doc -Css '').sheet
$null = Set-NativeHTMLKitStylesheet -Document $doc -Sheet $sheet -Css 'body { font-size: 18px; }'
```

### Get-NativeHTMLKitComputedStyle

Alias: `Get-NHKComputedStyle`

Returns computed CSS values (`get_computed_style`) for an element (by id or node) or, without a
target, for the document root.

```text
Get-NativeHTMLKitComputedStyle [-Document] <Object> [-Properties] <string[]> [[-Element] <string>] [[-Node] <Object>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Properties` | `string[]` | yes | - | CSS property names, for example `@('color', 'font-size')`. |
| `-Element` | `string` | no | - | Element id. Use `-Element` or `-Node`, not both. |
| `-Node` | `NativeHTMLKit.Node` | no | - | A `NativeHTMLKit.Node` from `Get-NativeHTMLKitNode`. |

**Returns** `@{ schema = 1; properties = @{ <name> = @{ value; status; inherited } } }`, for example
`(...).properties.'font-size'.value` is `'18px'`. `status` is `supported` for properties the CSS
profile implements.

### Get-NativeHTMLKitEnvironment

Alias: `Get-NHKEnvironment`

Returns the document's media environment (`get_environment`): `color_scheme`, `reduced_motion`,
`high_contrast`, each with a `*_source` (`default`, `app` for an override, or the observed system
value), plus `system_color_scheme`, `system_reduced_motion` and `scale`.

```text
Get-NativeHTMLKitEnvironment [-Document] <Object> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |

### Set-NativeHTMLKitEnvironment

Alias: `Set-NHKEnvironment`

Overrides `prefers-color-scheme` and/or `prefers-reduced-motion` for this document
(`set_environment`). Only the parameters you pass change. Allowed values: color scheme `light`,
`dark` or `system` (removes the override); reduced motion `reduce`, `no-preference` or `system`.
Other values fail with `NativeHTMLKit.RpcException` (-32602).

```text
Set-NativeHTMLKitEnvironment [-Document] <Object> [[-ColorScheme] <string>] [[-ReducedMotion] <string>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-ColorScheme` | `string` | no | - | `light`, `dark` or `system`. |
| `-ReducedMotion` | `string` | no | - | `reduce`, `no-preference` or `system`. |

**Returns** the new environment (same shape as `Get-NativeHTMLKitEnvironment`).

### Get-NativeHTMLKitScroll

Alias: `Get-NHKScroll`

Returns the scroll state of the document or of a scroll container (`get_scroll`): `x`, `y`,
`min_x`, `min_y`, `max_x`, `max_y`, `width`, `height`, `scrollable`, `animating`.

```text
Get-NativeHTMLKitScroll [-Document] <Object> [[-Element] <string>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Element` | `string` | no | - | Element id of a scroll container. Default: the document. |

### Set-NativeHTMLKitScroll

Alias: `Set-NHKScroll`

Scrolls the document or an element (`scroll_to`) to `-X`/`-Y` in CSS pixels. Only the given
coordinates change. Returns the new scroll state.

```text
Set-NativeHTMLKitScroll [-Document] <Object> [[-Element] <string>] [[-X] <double>] [[-Y] <double>] [[-Behavior] <string>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Element` | `string` | no | - | Element id of a scroll container. Default: the document. |
| `-X` | `double` | no | - | Horizontal scroll position. |
| `-Y` | `double` | no | - | Vertical scroll position. |
| `-Behavior` | `string` | no | `'auto'` | Scroll behaviour. One of: `auto`, `instant`, `smooth`. |

### Get-NativeHTMLKitFocusedElement

Alias: `Get-NHKFocusedElement`

Returns the focused element (`get_focused_element`): `element` (its id or `$null`) and `node`.

```text
Get-NativeHTMLKitFocusedElement [-Document] <Object> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |

### Set-NativeHTMLKitFocus

Alias: `Set-NHKFocus`

Focuses an element or node (`focus`), or with `-Blur` removes focus (`blur`). Without `-Blur` a
target is required.

```text
Set-NativeHTMLKitFocus [-Document] <Object> [[-Element] <string>] [[-Node] <Object>] [-Blur] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Element` | `string` | no | - | Element id. |
| `-Node` | `NativeHTMLKit.Node` | no | - | A `NativeHTMLKit.Node`. |
| `-Blur` | `switch` | no | off | Remove focus (from the given element, or from the focused element). |

### Get-NativeHTMLKitSelection

Alias: `Get-NHKSelection`

Returns a text control's selection (`get_control_selection`): `start` and `end` (UTF-16 offsets),
`direction` (`none`, `forward`, `backward`), `node`, and `length`, which is the length of the
control's **whole value**, not of the selection (use `end - start`).

```text
Get-NativeHTMLKitSelection [-Document] <Object> [[-Element] <string>] [[-Node] <Object>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Element` | `string` | no | - | Element id of an `<input>` or `<textarea>`. |
| `-Node` | `NativeHTMLKit.Node` | no | - | A `NativeHTMLKit.Node`. |

### Set-NativeHTMLKitSelection

Alias: `Set-NHKSelection`

Sets a text control's selection (`set_control_selection`); `-Start` equal to `-End` places the caret.

```text
Set-NativeHTMLKitSelection [-Document] <Object> [[-Element] <string>] [[-Node] <Object>] [-Start] <int> [-End] <int> [[-Direction] <string>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Element` | `string` | no | - | Element id of an `<input>` or `<textarea>`. |
| `-Node` | `NativeHTMLKit.Node` | no | - | A `NativeHTMLKit.Node`. |
| `-Start` | `int` | yes | - | Selection start (UTF-16 offset). Range 0 to 2147483647. |
| `-End` | `int` | yes | - | Selection end (UTF-16 offset). Range 0 to 2147483647. |
| `-Direction` | `string` | no | `'none'` | Selection direction. One of: `none`, `forward`, `backward`. |

**Returns** the new selection (same shape as `Get-NativeHTMLKitSelection`).

### Invoke-NativeHTMLKitEditCommand

Alias: `Invoke-NHKEditCommand`

Runs an editing command through the native editor (`edit_command`) on the given element or the
focused one. Core 1.0.3 accepts exactly `undo`, `redo`, `cut`, `copy`, `paste`, `select_all` and
`delete` (other names fail with code -32602; note `select_all`, not `selectAll` as the module's
built-in help says). Commands that change the value dispatch `input` events. Clipboard commands
complete asynchronously: acceptance does not mean the operating-system transfer succeeded.

```text
Invoke-NativeHTMLKitEditCommand [-Document] <Object> [-Command] <string> [[-Element] <string>] [[-Node] <Object>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Command` | `string` | yes | - | `undo`, `redo`, `cut`, `copy`, `paste`, `select_all` or `delete`. |
| `-Element` | `string` | no | - | Element id. Default: the focused element. |
| `-Node` | `NativeHTMLKit.Node` | no | - | A `NativeHTMLKit.Node`. |

**Returns** `@{ accepted; clipboard_pending }`.

### Register-NativeHTMLKitResources

Alias: `Register-NHKResources`

Atomically registers or replaces one document-local resource bundle that HTML and CSS can reference
as `nativehtmlkit-res://NAME/<path>` (`register_resource_bundle`): icons, images or fonts generated
in memory, without temporary files. `-Entries` maps relative paths to `byte[]`, or to
`@{ Bytes = [byte[]]; Mime = 'image/png' }` (default MIME `application/octet-stream`). At most 256
entries and 1 MiB of decoded bytes per registration.

```text
Register-NativeHTMLKitResources [-Document] <Object> [-Name] <string> [-Entries] <IDictionary> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Name` | `string` | yes | - | Bundle name (the host part of the URL). |
| `-Entries` | `System.Collections.IDictionary` | yes | - | Hashtable of relative path to bytes or `@{ Bytes; Mime }`. |

**Returns** `@{ name; replaced }` (`replaced` is `$true` when a bundle of that name existed).

```powershell
$png = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'logo.png'))
$null = Register-NativeHTMLKitResources -Document $doc -Name brand -Entries @{ 'logo.png' = @{ Bytes = $png; Mime = 'image/png' } }
# <img src="nativehtmlkit-res://brand/logo.png">
```

### Unregister-NativeHTMLKitResources

Alias: `Unregister-NHKResources`

Removes a resource bundle (`unregister_resource_bundle`).

```text
Unregister-NativeHTMLKitResources [-Document] <Object> [-Name] <string> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Name` | `string` | yes | - | Bundle name. |
