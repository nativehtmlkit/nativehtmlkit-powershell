# Reference: document events

Subscribing PowerShell scriptblocks to DOM events and controlling native default actions.
How-to: [Events and callbacks](../guides/events-and-callbacks.md).

## When callbacks run

The host delivers events as notifications. The SDK queues them on a reader thread and runs your
scriptblocks **on the runspace that pumps the queue**, one at a time, in host order:

- inside `Wait-NativeHTMLKit` (the normal case), and
- inside **any command that waits for a host reply** (every document, window and desktop command).
  An event can therefore run in the middle of, for example, `Submit-NativeHTMLKitForm` or
  `Get-NativeHTMLKitValue` called from your script's top level.

While a callback runs, nested waits still answer replies and host decisions (close/quit policies),
but further notifications and task completions are deferred until the callback returns (at most
128 deferred notifications; beyond that they are dropped and counted in
`Get-NativeHTMLKitDiagnosticReport` as `DeferredDropped`). Callbacks can nest at most 32 deep.

A callback that throws does not stop the app: the error is written to stderr as
`NativeHTMLKit: document_event callback failed: <type>: <message> (<script>:<line>)`, recorded
as a `callback.failed` diagnostic and counted in `CallbackFailures`. `break` or `continue` outside a
loop inside a callback stops only that callback.

Events are delivered **after** native dispatch: the native default action (typing, focus
movement, checkbox toggling, form submission) has already happened when your scriptblock runs. To
cancel a default action, register it beforehand with `Set-NativeHTMLKitPreventDefault`.

## The event object

The callback receives one argument, a `PSCustomObject`. Fields present for Core 1.0.3:

| Field | Present | Meaning |
|---|---|---|
| `type` | always | Event type, such as `click`, `input`, `submit`. |
| `element` | always | Id of the nearest element **with an id**, starting at the target and walking up; empty string if none. |
| `path` | always | Ids of the elements with ids along the event route, target first. |
| `node` | always | Node reference of the actual target (use with `Get-NativeHTMLKitNode -Reference`). |
| `window_id`, `document_id` | always | Added by the SDK. |
| `ctrl`, `shift`, `alt`, `meta` | always | Modifier keys. |
| `cancelable`, `default_prevented` | cancelable events | Whether the default action could be / was prevented. |
| `detail` | always | Click count for mouse events. |
| `value` | target is a text control or `<select>` | The control's current value (no extra request needed). |
| `checked` | checkbox/radio | Current checked state. |
| `selection` | text control | `start`, `end`, `direction`. |
| `key`, `code`, `repeat` | keyboard events | DOM key name (`a`, `Enter`, `Tab`, `Escape`, `F1`, `ArrowUp`, ...), physical key code, auto-repeat. |
| `x`, `y`, `button`, `buttons` | pointer/mouse events | Position in CSS pixels and buttons. |
| `delta_x`, `delta_y` | `wheel` | Scroll amounts. |
| `data`, `input_type`, `is_composing` | `input`, `beforeinput`, composition | Inserted text and input kind. |
| `submitter` | `submit` | Id of the submit button, when it has one. |
| `old_state`, `new_state` | `toggle` (popover, `<details>`) | Open state change. |
| `return_value` | `close` of a `<dialog>` | The dialog's return value. |
| `validity` | `invalid` | `flags` (`valueMissing`, `typeMismatch`, `patternMismatch`, `tooShort`, `tooLong`, `rangeUnderflow`, `rangeOverflow`, `stepMismatch`, `badInput`, `customError`), `message`, `valid`. |
| `files` | file input | Selected file metadata. |

Fields whose names start with `_` are internal. Use `$evt` or `$e` as the parameter name:
`$event` is a PowerShell automatic variable.

Typical event types: `click`, `dblclick`, `auxclick`, `contextmenu`, `input`, `beforeinput`,
`change`, `submit`, `reset`, `invalid`, `keydown`, `keyup`, `focus`, `blur`, `focusin`, `focusout`,
`pointerdown`/`up`/`move`/`over`/`out`/`enter`/`leave`/`cancel`, `mousedown`/`up`/`move`/...,
`wheel`, `scroll`, `compositionstart`/`update`/`end`, `dragstart`/`drag`/`dragenter`/`dragover`/
`dragleave`/`dragend`/`drop`, `toggle`, `close`, `cancel`, `select`, `selectionchange`, `copy`, `cut`,
`paste`, `load`, and `error` (see below).

### Register-NativeHTMLKitDocumentEvent

Alias: `Register-NHKDocumentEvent`

Subscribes a scriptblock to events of one type in a document. With `-Element`, the callback runs
only when that id is the event's `element` **or appears in its `path`**, so one handler on a
container (a list, a toolbar, a table) receives events from all its descendants: delegation.
Without `-Element`, every event of that type in the document is delivered. At most 256
subscriptions per document; they are released when the document is retired.

```text
Register-NativeHTMLKitDocumentEvent [-Document] <Object> [-Type] <string> [-Callback] <scriptblock> [[-Element] <string>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Type` | `string` | yes | - | Event type, for example `click`. |
| `-Callback` | `scriptblock` | yes | - | Scriptblock; receives the event object as its single argument. |
| `-Element` | `string` | no | - | Element id to filter on (target or ancestor). |

**Returns** a `NativeHTMLKit.Subscription` (`Type`, `Element`, `Document`) for
`Unregister-NativeHTMLKitDocumentEvent`. Use `$null = Register-...` to discard it.

```powershell
# Delegation: one handler for every button in #toolbar.
$null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element toolbar -Callback {
    param($evt)
    switch ($evt.element) {
        'save'   { Save-Report }
        'export' { Export-Report }
    }
}
```

Variable lookup inside the scriptblock happens **when it runs**, not when it was registered. A
scriptblock written at script level sees script variables (`$doc`, `$app`) and functions; a
scriptblock created inside a function needs `.GetNewClosure()` to keep that function's locals. See
[closures and scope](../guides/events-and-callbacks.md#closures-and-scope).

#### Document errors

The host reports document failures as `document.error`. The SDK writes the message to stderr and
delivers it to handlers registered for type `error` as `@{ type = 'error'; message; fatal }`. When
`fatal` is `$true` the host has already unloaded the document: it is retired, and an `error`
handler may load a replacement.

### Unregister-NativeHTMLKitDocumentEvent

Alias: `Unregister-NHKDocumentEvent`

Removes a subscription.

```text
Unregister-NativeHTMLKitDocumentEvent [-Subscription] <Object> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Subscription` | `NativeHTMLKit.Subscription` | yes | - | The `NativeHTMLKit.Subscription` returned by `Register-NativeHTMLKitDocumentEvent`. |

### Set-NativeHTMLKitPreventDefault

Alias: `Set-NHKPreventDefault`

Registers, **before** input happens, that the native default action of an event on an element (and
its descendants) is prevented (`set_default_action`). Because callbacks run after native dispatch,
this is the only way to stop, for example, Tab moving focus out of an editor or Enter submitting a
form. `-Key` and the modifier switches narrow the rule; a modifier you do not pass matches either
state. `-Prevent $false` registers a rule that allows the default action again.

```text
Set-NativeHTMLKitPreventDefault [-Document] <Object> [-Element] <string> [-EventType] <string> [[-Prevent] <bool>] [[-Key] <string>] [[-Shift] <bool>] [[-Ctrl] <bool>] [[-Alt] <bool>] [[-Meta] <bool>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Element` | `string` | yes | - | Element id; the rule applies to events whose route contains it. |
| `-EventType` | `string` | yes | - | Event type, for example `keydown` or `submit`. Alias: `-Event`. |
| `-Prevent` | `bool` | no | `$true` | `$true` prevents the default action; `$false` allows it. |
| `-Key` | `string` | no | - | DOM key name to match, case-sensitive (`Tab`, `Enter`, `s`). |
| `-Shift` | `bool` | no | - | Match only when Shift is (`$true`) or is not (`$false`) pressed. |
| `-Ctrl` | `bool` | no | - | Match the Ctrl state. |
| `-Alt` | `bool` | no | - | Match the Alt state. |
| `-Meta` | `bool` | no | - | Match the Meta (Windows/Super) state. |

```powershell
# Tab indents in the editor instead of moving focus; the keydown handler inserts spaces.
Set-NativeHTMLKitPreventDefault -Document $doc -Element editor -EventType keydown -Key Tab -Shift $false
```
