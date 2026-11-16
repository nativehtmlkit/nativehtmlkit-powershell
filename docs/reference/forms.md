# Reference: forms, select lists, HTML dialogs and popovers

How-to guides: [Forms](../guides/forms-and-validation.md), [HTML dialogs and popovers](../guides/dialogs-and-popovers.md).

Form commands take the form by id (`-Form`) or as a node (`-FormNode`), and an optional submit
button by id (`-Submitter`) or node (`-SubmitterNode`). Exactly one form target is required.

### Get-NativeHTMLKitFormData

Alias: `Get-NHKFormData`

Returns the form's entries as the HTML form-submission algorithm builds them (`get_form_data`):
in document order, with repeated names preserved, unchecked checkboxes and radio buttons
omitted, a checked checkbox without `value` reported as `on`, and file inputs reported as metadata.
The submitter's name/value is included when `-Submitter` is given.

```text
Get-NativeHTMLKitFormData [-Document] <Object> [[-Form] <string>] [[-FormNode] <Object>] [[-Submitter] <string>] [[-SubmitterNode] <Object>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Form` | `string` | no | - | Form element id. |
| `-FormNode` | `NativeHTMLKit.Node` | no | - | Form as a `NativeHTMLKit.Node`. |
| `-Submitter` | `string` | no | - | Id of the submit button to include. |
| `-SubmitterNode` | `NativeHTMLKit.Node` | no | - | Submit button as a node. |

**Returns** `@{ entries = @(@{ name; value; kind }); submitter }`. `kind` is `text` for ordinary
fields; `submitter` is `@{ element; node }` when `-Submitter`/`-SubmitterNode` was given, else `$null`.

```powershell
$values = @{}
foreach ($entry in (Get-NativeHTMLKitFormData -Document $doc -Form signup).entries) { $values[$entry.name] = $entry.value }
```

### Submit-NativeHTMLKitForm

Alias: `Submit-NHKForm`

Requests submission exactly as a submit button would (`request_submit`): native constraint
validation runs first (`required`, `type=email`, `min`/`max`, `minlength`, `pattern`, ...). If the
form is invalid nothing is submitted and an `invalid` event is dispatched for each invalid control
(with `validity.flags` such as `valueMissing`, `validity.message` and `validity.valid`); otherwise a
`submit` event is dispatched to your handlers, with `submitter` set to the submit button's id. No navigation happens: NativeHTMLKit forms never load a URL.

```text
Submit-NativeHTMLKitForm [-Document] <Object> [[-Form] <string>] [[-FormNode] <Object>] [[-Submitter] <string>] [[-SubmitterNode] <Object>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Form` | `string` | no | - | Form element id. |
| `-FormNode` | `NativeHTMLKit.Node` | no | - | Form as a node. |
| `-Submitter` | `string` | no | - | Id of the button that "submits". |
| `-SubmitterNode` | `NativeHTMLKit.Node` | no | - | Submit button as a node. |

**Returns** `@{ submitted; default_prevented }`. `submitted` is `$false` when validation blocked the
submission.

### Reset-NativeHTMLKitForm

Alias: `Reset-NHKForm`

Resets every control of the form to its initial value (`reset_form`), like a reset button.

```text
Reset-NativeHTMLKitForm [-Document] <Object> [[-Form] <string>] [[-FormNode] <Object>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Form` | `string` | no | - | Form element id. |
| `-FormNode` | `NativeHTMLKit.Node` | no | - | Form as a node. |

**Returns** `@{ reset; default_prevented }`.

### Get-NativeHTMLKitSelectOptions

Alias: `Get-NHKSelectOptions`

Returns a `<select>` element's options (`get_options`), each with `value`, `label`, `selected`
and `disabled`. Returned as **one array object** (assign it and use the variable).

```text
Get-NativeHTMLKitSelectOptions [-Document] <Object> [-Element] <string> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Element` | `string` | yes | - | Id of the `<select>`. |

### Set-NativeHTMLKitSelectedValues

Alias: `Set-NHKSelectedValues`

Selects the options whose values are given and deselects the others (`set_selected_values`). For a
single-selection `<select>` pass one value; an empty array clears a multiple selection. Does not
dispatch events.

```text
Set-NativeHTMLKitSelectedValues [-Document] <Object> [-Element] <string> [-Values] <string[]> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Element` | `string` | yes | - | Id of the `<select>`. |
| `-Values` | `string[]` | yes | - | Option values to select. May be empty. |

### Show-NativeHTMLKitHtmlDialog

Alias: `Show-NHKHtmlDialog`

Opens an HTML `<dialog>` element (`show_dialog`), modal by default: a modal dialog enters the top
layer, makes the rest of the document inert and focuses its first focusable element; Escape asks it
to close (`cancel`, then `close` events). With `-Close` it closes the dialog with a return value
(`close_dialog`); the dialog's `close` event carries it as `return_value`. As in HTML, the return
value persists: showing the dialog again or closing it with Escape keeps the previous value, so
decide in your button handlers rather than in the `close` event. This is an in-window
HTML dialog, not a native operating-system dialog (for those see
[Show-NativeHTMLKitFileDialog](desktop.md#show-nativehtmlkitfiledialog)).

```text
Show-NativeHTMLKitHtmlDialog [-Document] <Object> [-Element] <string> [[-Modal] <bool>] [[-ReturnValue] <string>] [-Close] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Element` | `string` | yes | - | Id of the `<dialog>` element. |
| `-Close` | `switch` | no | off | Close the dialog instead of opening it. |
| `-Modal` | `bool` | no | `$true` | `$false` opens it non-modally (`show()` instead of `showModal()`). |
| `-ReturnValue` | `string` | no | `''` | With `-Close`: the return value. |

**Returns** nothing. Inspect state with
`Invoke-NativeHTMLKitDocumentCommand -Operation get_dialog -Parameters @{ element = 'id' }`
(`open`, `modal`, `return_value`).

```powershell
Show-NativeHTMLKitHtmlDialog -Document $doc -Element confirm
# ... in the OK button's click handler:
Show-NativeHTMLKitHtmlDialog -Document $doc -Element confirm -Close -ReturnValue 'ok'
```

### Show-NativeHTMLKitPopover

Alias: `Show-NHKPopover`

Shows, hides or toggles an element with the `popover` attribute (`show_popover`, `hide_popover`,
`toggle_popover`).

```text
Show-NativeHTMLKitPopover [-Document] <Object> [-Element] <string> [[-Action] <string>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Element` | `string` | yes | - | Id of the popover element. |
| `-Action` | `string` | no | `'show'` | What to do. One of: `show`, `hide`, `toggle`. |

**Returns** `[bool]` (new open state) for `-Action toggle`; nothing otherwise. Inspect state with
the `get_popover` document command (`open`).
