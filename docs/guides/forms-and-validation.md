# How to build forms with validation

Reference: [forms](../reference/forms.md). Examples:
[03-form-validation.ps1](../../examples/03-form-validation.ps1),
[09-settings-dialog.ps1](../../examples/09-settings-dialog.ps1).

## Let the native form validate first

Write the HTML constraints you can (`required`, `type="email"`, `min`/`max`, `minlength`,
`maxlength`, `pattern`) and handle the `submit` event. The host validates before it dispatches
`submit`; for an invalid form it dispatches `invalid` events instead and your submit handler does not
run. Pressing Enter in a field or clicking a `type="submit"` button submits; there is no page
navigation.

```powershell
$null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type submit -Element signup -Callback { Invoke-Submit }
```

## Read all values at once

```powershell
function ConvertTo-FormTable($FormData) {
    $table = @{}
    foreach ($entry in $FormData.entries) { $table[$entry.name] = [string]$entry.value }
    return $table
}
$values = ConvertTo-FormTable (Get-NativeHTMLKitFormData -Document $doc -Form signup)
```

Entries follow the HTML rules: unchecked checkboxes are absent, a checked checkbox without a
`value` attribute reports `on`, and repeated names (multi-select, several checkboxes with one name)
appear several times; collect those into arrays if you use them.

## Add your own rules

Rules HTML cannot express (reserved names, cross-field checks, lookups) run in PowerShell. Show
messages next to the fields and mark them for assistive technology:

```powershell
function Set-FieldError([string]$Field, [string]$Message) {
    Set-NativeHTMLKitDocumentText -Document $doc -Element "$Field-error" -Text $Message
    if ($Message) { Set-NativeHTMLKitDocumentAttribute -Document $doc -Element $Field -Name 'aria-invalid' -Value 'true' }
    else { Set-NativeHTMLKitDocumentAttribute -Document $doc -Element $Field -Name 'aria-invalid' -Remove }
}
```

Move focus to the first invalid field with `Set-NativeHTMLKitFocus`. To reuse the native validation
UI for a PowerShell rule, set a custom validity message:
`Invoke-NativeHTMLKitDocumentCommand -Document $doc -Operation set_custom_validity -Parameters @{ element = 'username'; message = 'Name is taken' }`
(an empty message clears it).

## Fill, reset and drive a form

- `Set-NativeHTMLKitDocumentValue`, `Set-NativeHTMLKitChecked`, `Set-NativeHTMLKitSelectedValues`
  prefill controls. They do not dispatch `input`/`change` events.
- `Reset-NativeHTMLKitForm` restores the initial values; clear your own error texts as well.
- `Submit-NativeHTMLKitForm` submits programmatically with validation, returning
  `submitted = $false` when blocked. Scripted checks use it to exercise the real submit path
  without input devices.

## Long-running submit

Do not block the submit handler with slow work (a REST call, a directory query). Disable the
button, start a [background task](background-tasks.md), and re-enable it in `-OnCompleted`:

```powershell
$null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type submit -Element request -Callback {
    $values = ConvertTo-FormTable (Get-NativeHTMLKitFormData -Document $doc -Form request)
    Set-NativeHTMLKitDocumentAttribute -Document $doc -Element send -Name disabled
    $null = Start-NativeHTMLKitTask -Application $app -ArgumentList @($values['user']) -ScriptBlock {
        param($user) Start-Sleep -Seconds 2; "Ticket created for $user"
    } -OnCompleted {
        param($result)
        Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text $result[0]
        Set-NativeHTMLKitDocumentAttribute -Document $doc -Element send -Name disabled -Remove
    }
}
```
