# 03-form-validation.ps1 - an account request form with native and PowerShell validation.
#
# Teaches: the submit event, Get-NativeHTMLKitFormData entries, native constraint checks
# (required, type=email, minlength) that block submission before PowerShell sees it,
# application rules in PowerShell, per-field error text with aria-invalid, and
# Reset-NativeHTMLKitForm.
#
# Run:  pwsh -File ./03-form-validation.ps1     (or powershell.exe -NoProfile -File .\03-form-validation.ps1)
# -SelfTest fills and submits the form through the public API and quits.
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Import-Module NativeHTMLKit

$app = Start-NativeHTMLKitScript -Name 'Account request'
try {
    $window = New-NativeHTMLKitWindow -Application $app -Title 'Request an account' -Width 560 -Height 560
    $doc = Open-NativeHTMLKitHtml -Window $window -Html @'
<!doctype html>
<html><head><style>
  body { font-family: system-ui, sans-serif; margin: 28px; max-width: 460px; }
  label { display: block; margin-top: 12px; font-weight: 600; }
  input, select { width: 100%; padding: 6px 8px; font-size: 15px; box-sizing: border-box; }
  input[aria-invalid="true"] { border: 2px solid #b3261e; }
  .error { color: #b3261e; font-size: 13px; min-height: 1em; display: block; }
  .actions { margin-top: 18px; display: flex; gap: 8px; }
  #status { margin-top: 16px; font-weight: 600; }
</style></head>
<body>
<form id="signup">
  <label for="username">User name</label>
  <input id="username" name="username" required minlength="3" maxlength="20" autocomplete="off">
  <span class="error" id="username-error"></span>

  <label for="email">E-mail</label>
  <input id="email" name="email" type="email" required>
  <span class="error" id="email-error"></span>

  <label for="team">Team</label>
  <select id="team" name="team">
    <option value="">Choose...</option><option>Operations</option><option>Security</option><option>Support</option>
  </select>
  <span class="error" id="team-error"></span>

  <label><input type="checkbox" id="terms" name="terms" value="yes"> I accept the usage policy</label>
  <span class="error" id="terms-error"></span>

  <div class="actions"><button id="submit" type="submit">Request account</button><button id="clear" type="button">Clear</button></div>
</form>
<p id="status" aria-live="polite"></p>
</body></html>
'@

    $script:takenNames = @('admin', 'root', 'administrator', 'guest')
    $script:fields = @('username', 'email', 'team', 'terms')

    function ConvertTo-FormTable($FormData) {
        # Entries keep document order; unchecked checkboxes are absent, like in a browser.
        $table = @{}
        foreach ($entry in $FormData.entries) { $table[$entry.name] = [string]$entry.value }
        return $table
    }

    function Set-FieldError([string]$Field, [string]$Message) {
        Set-NativeHTMLKitDocumentText -Document $doc -Element "$Field-error" -Text $Message
        if ($Message) { Set-NativeHTMLKitDocumentAttribute -Document $doc -Element $Field -Name 'aria-invalid' -Value 'true' }
        else { Set-NativeHTMLKitDocumentAttribute -Document $doc -Element $Field -Name 'aria-invalid' -Remove }
    }

    function Test-Request([hashtable]$Values) {
        # Rules the HTML attributes cannot express. Returns field -> message.
        $problems = @{}
        $name = ([string]$Values['username']).Trim()
        if ($name -notmatch '^[A-Za-z][A-Za-z0-9._-]*$') { $problems.username = 'Start with a letter; use letters, digits, dot, dash or underscore.' }
        elseif ($script:takenNames -contains $name.ToLowerInvariant()) { $problems.username = "'$name' is reserved. Choose another name." }
        if (-not ([string]$Values['email']).EndsWith('@example.org')) { $problems.email = 'Use your @example.org address.' }
        if (-not $Values['team']) { $problems.team = 'Choose a team.' }
        if ($Values['terms'] -ne 'yes') { $problems.terms = 'The usage policy must be accepted.' }
        return $problems
    }

    function Invoke-Submit {
        $values = ConvertTo-FormTable (Get-NativeHTMLKitFormData -Document $doc -Form signup)
        $problems = Test-Request $values
        foreach ($field in $script:fields) { Set-FieldError $field ([string]$problems[$field]) }
        if ($problems.Count -gt 0) {
            Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text "Please correct $($problems.Count) field(s)."
            Set-NativeHTMLKitFocus -Document $doc -Element (@($script:fields | Where-Object { $problems.ContainsKey($_) })[0])
            return
        }
        Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text "Request for $($values['username']) ($($values['team'])) recorded."
    }

    # The host runs native validation first; submit is only dispatched for a valid form.
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type submit -Element signup -Callback { Invoke-Submit }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element clear -Callback {
        $null = Reset-NativeHTMLKitForm -Document $doc -Form signup
        foreach ($field in $script:fields) { Set-FieldError $field '' }
        Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text ''
    }

    Set-NativeHTMLKitReady -Application $app

    if ($SelfTest) {
        function Wait-Events { for ($i = 0; $i -lt 10; $i++) { $null = Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 30 } }
        # 1. Native constraints: an empty required field blocks the submit event entirely.
        $result = Submit-NativeHTMLKitForm -Document $doc -Form signup
        if ($result.submitted) { throw 'an empty form must not submit' }
        # 2. Natively valid, but PowerShell rules fail.
        Set-NativeHTMLKitDocumentValue -Document $doc -Element username -Value 'admin'
        Set-NativeHTMLKitDocumentValue -Document $doc -Element email -Value 'ada@example.com'
        $result = Submit-NativeHTMLKitForm -Document $doc -Form signup
        if (-not $result.submitted) { throw 'a natively valid form must submit' }
        Wait-Events
        $status = Get-NativeHTMLKitDocumentText -Document $doc -Element status
        if ($status -ne 'Please correct 4 field(s).') { throw "unexpected status: $status" }
        if ((Get-NativeHTMLKitFocusedElement -Document $doc).element -ne 'username') { throw 'focus should move to the first invalid field' }
        # 3. Fix everything.
        Set-NativeHTMLKitDocumentValue -Document $doc -Element username -Value 'ada.lovelace'
        Set-NativeHTMLKitDocumentValue -Document $doc -Element email -Value 'ada@example.org'
        Set-NativeHTMLKitSelectedValues -Document $doc -Element team -Values @('Security')
        Set-NativeHTMLKitChecked -Document $doc -Element terms -Checked $true
        $null = Submit-NativeHTMLKitForm -Document $doc -Form signup
        Wait-Events
        $status = Get-NativeHTMLKitDocumentText -Document $doc -Element status
        if ($status -ne 'Request for ada.lovelace (Security) recorded.') { throw "unexpected status: $status" }
        if (Get-NativeHTMLKitDocumentText -Document $doc -Element username-error) { throw 'error text should be cleared' }
        [Console]::Out.WriteLine('SELFTEST PASS 03-form-validation')
        $null = Request-NativeHTMLKitQuit -Application $app
    }

    Wait-NativeHTMLKit -Application $app -UntilShutdown
} finally {
    Close-NativeHTMLKit -Application $app
}
