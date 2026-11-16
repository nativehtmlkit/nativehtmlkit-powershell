# 03-form-validation.ps1 - a sign-up form: native HTML constraint validation plus a cross-field rule.
#
# Teaches: built-in validation (required, minlength, type=email, min/max) runs on submit; an
# invalid form fires one 'invalid' event per failing control and no 'submit'. The
# set_custom_validity document command for a rule HTML cannot express (passwords must match).
# Reading the submitted values with Get-NativeHTMLKitFormData (ordered entries, repeated names
# kept), showing an error summary and a result with encoded user text, Reset-NativeHTMLKitForm.
#
# Run:  pwsh -File ./03-form-validation.ps1     (or powershell.exe -NoProfile -File .\03-form-validation.ps1)
# -SelfTest submits the empty, the mismatched and the valid form through the public API and quits.
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Import-Module NativeHTMLKit

$app = Start-NativeHTMLKitScript -Name 'Sign-up form'
try {
    $window = New-NativeHTMLKitWindow -Application $app -Title 'Sign up' -Width 600 -Height 820
    $doc = Open-NativeHTMLKitHtml -Window $window -Html @'
<!doctype html>
<html><head><meta charset="utf-8"><style>
  body { margin:0; background:#eef1f6; color:#1f2633; font:14px/1.45 sans-serif; }
  main { max-width:520px; margin:28px auto; padding:24px; background:#fff; border-radius:10px; }
  h1 { margin:0 0 4px; font-size:24px; }
  .hint { color:#68708a; margin:0 0 18px; }
  label { display:block; margin:12px 0 4px; font-weight:bold; }
  input[type=text], input[type=email], input[type=password], input[type=number], select {
    width:100%; box-sizing:border-box; padding:8px; border:1px solid #c7cddb; border-radius:6px; }
  .check { font-weight:normal; display:flex; gap:8px; align-items:center; }
  fieldset { border:1px solid #d8dce6; border-radius:6px; margin-top:12px; }
  button { margin-top:18px; padding:10px 18px; border:0; border-radius:6px; background:#2f6fec; color:#fff; }
  #errors { color:#b3261e; }
  #errors:empty, #result:empty { display:none; }
  #result { background:#e9f6ec; border-radius:6px; padding:10px 14px; margin-top:16px; }
</style></head>
<body><main>
  <h1>Create an account</h1>
  <p class="hint">All fields except the newsletter are required.</p>
  <ul id="errors" role="alert"></ul>
  <form id="signup">
    <label for="name">Name</label>
    <input id="name" name="name" type="text" required minlength="2" maxlength="80">
    <label for="email">Email</label>
    <input id="email" name="email" type="email" required>
    <label for="password">Password (8+ characters)</label>
    <input id="password" name="password" type="password" required minlength="8">
    <label for="confirm">Repeat password</label>
    <input id="confirm" name="confirm" type="password" required>
    <label for="age">Age</label>
    <input id="age" name="age" type="number" required min="13" max="120">
    <label for="country">Country</label>
    <select id="country" name="country" required>
      <option value="">Choose…</option><option value="de">Germany</option>
      <option value="fr">France</option><option value="jp">Japan</option><option value="us">United States</option>
    </select>
    <fieldset><legend>Interests</legend>
      <label class="check"><input type="checkbox" name="topic" value="news"> News</label>
      <label class="check"><input type="checkbox" name="topic" value="releases"> Releases</label>
      <label class="check"><input type="checkbox" name="topic" value="events"> Events</label>
    </fieldset>
    <label class="check"><input id="terms" name="terms" type="checkbox" required> I accept the terms</label>
    <button id="submit" type="submit">Sign up</button>
  </form>
  <div id="result"></div>
</main></body></html>
'@

    $script:labels = @{ name = 'Name'; email = 'Email'; password = 'Password'; confirm = 'Repeat password'
        age = 'Age'; country = 'Country'; terms = 'Terms' }
    $script:errors = New-Object System.Collections.Generic.List[string]
    $script:accounts = New-Object System.Collections.Generic.List[object]
    $mismatch = 'The passwords do not match.'

    function ConvertTo-Html([string]$Text) { return [Net.WebUtility]::HtmlEncode($Text) }

    function Show-Errors {
        $items = @($script:errors | ForEach-Object { '<li>' + (ConvertTo-Html $_) + '</li>' })
        Set-NativeHTMLKitDocumentHtml -Document $doc -Element errors -Html ($items -join '')
    }

    function Update-PasswordMatch {
        # A custom validity message makes the control invalid until it is cleared again.
        $same = (Get-NativeHTMLKitValue -Document $doc -Element password) -ceq (Get-NativeHTMLKitValue -Document $doc -Element confirm)
        $message = ''
        if (-not $same) { $message = $mismatch }
        $null = Invoke-NativeHTMLKitDocumentCommand -Document $doc -Operation set_custom_validity -Parameters @{ element = 'confirm'; message = $message }
    }

    function Invoke-SignupSubmit {
        # Runs the same path as clicking "Sign up" (also used by the self-test).
        Update-PasswordMatch
        $script:errors.Clear()
        Set-NativeHTMLKitDocumentHtml -Document $doc -Element errors -Html ''
        return (Submit-NativeHTMLKitForm -Document $doc -Form signup -Submitter submit)
    }

    # 'invalid' does not bubble: its path holds only the control itself, so subscribe
    # document-wide (no -Element) and keep the controls of this form.
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type invalid -Callback {
        param($evt)
        # One event per invalid control, in document order, before (instead of) 'submit'.
        $element = [string]$evt.element
        if (-not $script:labels.ContainsKey($element)) { return }
        $message = 'Invalid value'
        if ($null -ne $evt.validity -and $evt.validity.message) { $message = [string]$evt.validity.message }
        $script:errors.Add($script:labels[$element] + ': ' + $message)
        Show-Errors
        Set-NativeHTMLKitDocumentText -Document $doc -Element result -Text ''
    }

    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type submit -Element signup -Callback {
        # Callbacks run after native dispatch, so a fast typist can submit before the last
        # 'input' event updated the custom validity. Validate again here.
        if ((Get-NativeHTMLKitValue -Document $doc -Element password) -cne (Get-NativeHTMLKitValue -Document $doc -Element confirm)) {
            Update-PasswordMatch
            $script:errors.Clear()
            $script:errors.Add("Repeat password: $mismatch")
            Show-Errors
            return
        }
        $values = @{}
        foreach ($entry in @((Get-NativeHTMLKitFormData -Document $doc -Form signup).entries)) {
            # Ordered; checkboxes may repeat a name.
            if (-not $values.ContainsKey($entry.name)) { $values[$entry.name] = New-Object System.Collections.Generic.List[string] }
            $values[$entry.name].Add([string]$entry.value)
        }
        $topics = @()
        if ($values.ContainsKey('topic')) { $topics = $values['topic'].ToArray() }
        $account = [pscustomobject]@{ name = $values['name'][0]; email = $values['email'][0]
            country = $values['country'][0]; topics = $topics }
        $script:accounts.Add($account)
        $script:errors.Clear()
        Set-NativeHTMLKitDocumentHtml -Document $doc -Element errors -Html ''
        $interests = $topics -join ', '
        if (-not $interests) { $interests = 'none' }
        Set-NativeHTMLKitDocumentHtml -Document $doc -Element result -Html (
            '<strong>Welcome, ' + (ConvertTo-Html $account.name) + '!</strong><br>' +
            'We will write to ' + (ConvertTo-Html $account.email) + '. Interests: ' + (ConvertTo-Html $interests) + '.')
        $null = Reset-NativeHTMLKitForm -Document $doc -Form signup
    }

    # Re-check the cross-field rule whenever either password changes.
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type input -Element password -Callback { Update-PasswordMatch }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type input -Element confirm -Callback { Update-PasswordMatch }

    Set-NativeHTMLKitReady -Application $app

    if ($SelfTest) {
        function Wait-Until([scriptblock]$Condition) {
            for ($i = 0; $i -lt 100; $i++) {
                if (& $Condition) { return $true }
                $null = Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 20
            }
            return [bool](& $Condition)
        }
        function Get-Count([string]$Selector) { return (Find-NativeHTMLKitElement -Document $doc -Selector $Selector).matched_nodes }
        # 1. Empty form: native constraints block 'submit' and list one error per control. Core 1.0.3
        #    in headless test mode may not report the required checkbox ('terms'); a desktop host does.
        $result = Invoke-SignupSubmit
        if ($result.submitted) { throw 'an empty form must not submit' }
        if (-not (Wait-Until { $script:errors.Count -eq 6 -or $script:errors.Count -eq 7 })) { throw "unexpected errors: $($script:errors -join ' | ')" }
        if (-not (Wait-Until { (Get-Count '#errors li') -eq $script:errors.Count })) { throw 'error summary not rendered' }
        # 2. Natively valid, but the passwords differ: the custom validity blocks the submit.
        Set-NativeHTMLKitDocumentValue -Document $doc -Element name -Value 'Ada <Lovelace>'
        Set-NativeHTMLKitDocumentValue -Document $doc -Element email -Value 'ada@example.org'
        Set-NativeHTMLKitDocumentValue -Document $doc -Element password -Value 'correct horse'
        Set-NativeHTMLKitDocumentValue -Document $doc -Element confirm -Value 'wrong horse'
        Set-NativeHTMLKitDocumentValue -Document $doc -Element age -Value '36'
        Set-NativeHTMLKitSelectedValues -Document $doc -Element country -Values @('fr')
        Set-NativeHTMLKitChecked -Document $doc -Element terms -Checked $true
        $result = Invoke-SignupSubmit
        if ($result.submitted -or -not (Wait-Until { $script:errors.Count -eq 1 -and $script:errors[0] -eq "Repeat password: $mismatch" })) {
            throw "a password mismatch must block: $($script:errors -join ' | ')"
        }
        # 3. Valid, with two of the repeated 'topic' checkboxes checked.
        Set-NativeHTMLKitDocumentValue -Document $doc -Element confirm -Value 'correct horse'
        foreach ($topic in @((Get-NativeHTMLKitNodes -Document $doc -Selector 'input[name=topic]').nodes)[0..1]) {
            Invoke-NativeHTMLKitNodeBatch -Document $doc -Operations @(@{ op = 'set_attribute'; node = $topic.node; name = 'checked'; value = '' })
        }
        $result = Invoke-SignupSubmit
        if (-not $result.submitted) { throw 'a valid form must submit' }
        if (-not (Wait-Until { $script:accounts.Count -eq 1 -and (Get-NativeHTMLKitValue -Document $doc -Element name) -eq '' })) { throw 'account not recorded' }
        $account = $script:accounts[0]
        if ($account.name -ne 'Ada <Lovelace>' -or $account.country -ne 'fr' -or (@($account.topics) -join ',') -ne 'news,releases') {
            throw "unexpected form data: $($account | ConvertTo-Json -Compress)"
        }
        if (-not (Get-NativeHTMLKitDocumentText -Document $doc -Element result).StartsWith('Welcome, Ada <Lovelace>!') -or (Get-Count '#result Lovelace') -ne 0) {
            throw 'the result must show the name as encoded text'
        }
        if ((Get-NativeHTMLKitValue -Document $doc -Element name) -ne '') { throw 'the form should be reset after success' }
        [Console]::Out.WriteLine('SELFTEST PASS 03-form-validation')
        $null = Request-NativeHTMLKitQuit -Application $app
    }

    Wait-NativeHTMLKit -Application $app -UntilShutdown
} finally {
    Close-NativeHTMLKit -Application $app
}
