# 09-settings-dialog.ps1 - a settings dialog that applies and remembers preferences.
#
# Teaches: an HTML <dialog> opened modally with Show-NativeHTMLKitHtmlDialog and closed with
# a return value, a popover help tip
# (Show-NativeHTMLKitPopover), reading a form inside the dialog, applying a colour scheme
# with Set-NativeHTMLKitEnvironment, replacing one stylesheet in place
# (Add-/Set-NativeHTMLKitStylesheet), and saving settings as JSON.
#
# Run:  pwsh -File ./09-settings-dialog.ps1 [-SettingsPath settings.json]
#       powershell.exe -NoProfile -File .\09-settings-dialog.ps1
# Default settings file: <ApplicationData>/NativeHTMLKit-Examples/settings.json.
# -SelfTest uses a temporary settings file, changes settings and quits.
param([string]$SettingsPath, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Import-Module NativeHTMLKit

$app = Start-NativeHTMLKitScript -Name 'Settings dialog'
try {
    if ($SelfTest) { $SettingsPath = Join-Path ([IO.Path]::GetTempPath()) ('nhk-settings-' + [guid]::NewGuid().ToString('N') + '.json') }
    if (-not $SettingsPath) {
        $SettingsPath = Join-Path (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'NativeHTMLKit-Examples') 'settings.json'
    }

    $window = New-NativeHTMLKitWindow -Application $app -Title 'Settings dialog' -Width 640 -Height 480
    $doc = Open-NativeHTMLKitHtml -Window $window -Html @'
<!doctype html>
<html><head><style>
  :root { color-scheme: light dark; }
  body { font-family: system-ui, sans-serif; margin: 24px; background: Canvas; color: CanvasText; }
  @media (prefers-color-scheme: dark) { body { background: #1d222b; color: #e7ebf3; } }
  dialog { padding: 20px 24px; border-radius: 10px; min-width: 320px; }
  dialog label { display: block; margin: 10px 0 4px; }
  .actions { display: flex; justify-content: flex-end; gap: 8px; margin-top: 18px; }
  #help-tip { max-width: 260px; padding: 10px; font-size: 13px; }
  #saved { color: #2e7d32; }
</style></head>
<body>
  <h1>Report viewer</h1>
  <p id="sample">This paragraph follows the chosen text size.</p>
  <p><button id="open-settings">Settings...</button> <span id="saved" role="status"></span></p>

  <dialog id="settings" aria-labelledby="settings-title">
    <h2 id="settings-title">Settings</h2>
    <form id="settings-form">
      <label for="theme">Colour scheme <button type="button" id="help" aria-label="Help">?</button></label>
      <select id="theme" name="theme"><option value="system">Follow the system</option><option value="light">Light</option><option value="dark">Dark</option></select>
      <label for="size">Text size (px)</label>
      <input id="size" name="size" type="number" min="11" max="24" required>
      <label><input type="checkbox" id="motion" name="motion" value="reduce"> Reduce motion</label>
      <div class="actions"><button type="button" id="cancel">Cancel</button><button type="submit" id="apply">Save</button></div>
    </form>
  </dialog>
  <div id="help-tip" popover>"Follow the system" uses the desktop colour preference when the host can observe it.</div>
</body></html>
'@

    $defaults = @{ theme = 'system'; size = 15; motion = $false }
    function Read-Settings {
        $settings = $defaults.Clone()
        if (Test-Path -LiteralPath $SettingsPath) {
            try {
                $saved = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
                foreach ($name in @('theme', 'size', 'motion')) {
                    if ($null -ne $saved.PSObject.Properties[$name]) { $settings[$name] = $saved.$name }
                }
            } catch { Write-Verbose "Ignoring unreadable settings: $($_.Exception.Message)" }
        }
        return $settings
    }

    $script:settings = Read-Settings
    $script:sizeSheet = (Add-NativeHTMLKitStylesheet -Document $doc -Css '').sheet

    function Set-Appearance([hashtable]$Settings) {
        # 'system' removes the app override so the observed desktop preference applies again.
        $motion = 'system'
        if ($Settings.motion) { $motion = 'reduce' }
        $null = Set-NativeHTMLKitEnvironment -Document $doc -ColorScheme $Settings.theme -ReducedMotion $motion
        # Replace one app stylesheet in place instead of adding a new one each time.
        $null = Set-NativeHTMLKitStylesheet -Document $doc -Sheet $script:sizeSheet -Css ('body { font-size: ' + [int]$Settings.size + 'px; }')
    }

    function Show-Settings {
        Set-NativeHTMLKitSelectedValues -Document $doc -Element theme -Values @([string]$script:settings.theme)
        Set-NativeHTMLKitDocumentValue -Document $doc -Element size -Value ([string]$script:settings.size)
        Set-NativeHTMLKitChecked -Document $doc -Element motion -Checked ([bool]$script:settings.motion)
        Show-NativeHTMLKitHtmlDialog -Document $doc -Element settings      # modal by default
    }

    function Save-Settings {
        $entries = @{}
        foreach ($entry in (Get-NativeHTMLKitFormData -Document $doc -Form settings-form).entries) { $entries[$entry.name] = $entry.value }
        $script:settings = @{ theme = [string]$entries['theme']; size = [int]$entries['size']; motion = $entries.ContainsKey('motion') }
        $folder = Split-Path -Parent $SettingsPath
        if (-not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder }
        [IO.File]::WriteAllText($SettingsPath, (ConvertTo-Json -InputObject $script:settings), (New-Object Text.UTF8Encoding($false)))
        Set-Appearance $script:settings
        Show-NativeHTMLKitHtmlDialog -Document $doc -Element settings -Close -ReturnValue 'saved'
        # Report here, not in the dialog's close event: a <dialog> keeps its previous return
        # value when the user dismisses it with Escape, so 'saved' would be reported again.
        Set-NativeHTMLKitDocumentText -Document $doc -Element saved -Text ('Settings saved to ' + $SettingsPath)
    }

    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element open-settings -Callback { Show-Settings }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element cancel -Callback {
        Show-NativeHTMLKitHtmlDialog -Document $doc -Element settings -Close -ReturnValue 'cancelled'
        Set-NativeHTMLKitDocumentText -Document $doc -Element saved -Text 'Settings unchanged.'
    }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element help -Callback { $null = Show-NativeHTMLKitPopover -Document $doc -Element help-tip -Action toggle }
    # Native validation (min/max/required) runs before this submit event is dispatched.
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type submit -Element settings-form -Callback { Save-Settings }
    Set-Appearance $script:settings
    Set-NativeHTMLKitReady -Application $app

    if ($SelfTest) {
        function Wait-Events { for ($i = 0; $i -lt 10; $i++) { $null = Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 30 } }
        Show-Settings
        if (-not (Invoke-NativeHTMLKitDocumentCommand -Document $doc -Operation get_dialog -Parameters @{ element = 'settings' }).open) { throw 'dialog did not open' }
        Set-NativeHTMLKitSelectedValues -Document $doc -Element theme -Values @('dark')
        Set-NativeHTMLKitDocumentValue -Document $doc -Element size -Value '40'
        if ((Submit-NativeHTMLKitForm -Document $doc -Form settings-form).submitted) { throw 'size 40 is above max=24 and must not submit' }
        Set-NativeHTMLKitDocumentValue -Document $doc -Element size -Value '18'
        Set-NativeHTMLKitChecked -Document $doc -Element motion -Checked $true
        $null = Submit-NativeHTMLKitForm -Document $doc -Form settings-form
        Wait-Events
        $environment = Get-NativeHTMLKitEnvironment -Document $doc
        if ($environment.color_scheme -ne 'dark' -or $environment.reduced_motion -ne 'reduce') { throw "environment not applied: $($environment.color_scheme) $($environment.reduced_motion)" }
        $size = (Get-NativeHTMLKitComputedStyle -Document $doc -Element sample -Properties @('font-size')).properties.'font-size'.value
        if ($size -ne '18px') { throw "font size not applied: $size" }
        if ((Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json).size -ne 18) { throw 'settings not saved' }
        if (-not (Get-NativeHTMLKitDocumentText -Document $doc -Element saved).StartsWith('Settings saved')) { throw 'save not reported' }
        $dialog = Invoke-NativeHTMLKitDocumentCommand -Document $doc -Operation get_dialog -Parameters @{ element = 'settings' }
        if ($dialog.open -or $dialog.return_value -ne 'saved') { throw 'dialog not closed with its return value' }
        if (-not (Show-NativeHTMLKitPopover -Document $doc -Element help-tip -Action toggle)) { throw 'popover did not open' }
        Remove-Item -LiteralPath $SettingsPath -Force
        [Console]::Out.WriteLine('SELFTEST PASS 09-settings-dialog')
        $null = Request-NativeHTMLKitQuit -Application $app
    }

    Wait-NativeHTMLKit -Application $app -UntilShutdown
} finally {
    Close-NativeHTMLKit -Application $app
}
