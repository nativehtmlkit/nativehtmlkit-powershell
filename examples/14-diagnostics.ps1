# 14-diagnostics.ps1 - an "About / Support" window: capabilities, counters, support bundle.
#
# Teaches: Get-NativeHTMLKitCapabilities (feature detection), Get-NativeHTMLKitPreferences,
# Get-NativeHTMLKitDiagnosticReport -Application (loss and failure counters),
# Get-NativeHTMLKitDiagnostics (document CSS/resource notes), and
# Export-NativeHTMLKitSupportBundle (a local, redacted ZIP - nothing is uploaded).
#
# Run:  pwsh -File ./14-diagnostics.ps1 [-OutputFolder C:\Temp]
#       powershell.exe -NoProfile -File .\14-diagnostics.ps1
# Tip: start with -Diagnostics Trace on Start-NativeHTMLKitScript (or set
# NATIVEHTMLKIT_DIAGNOSTICS=trace) to record callback and request timing in the bundle.
# -SelfTest exports a bundle to a temporary folder, inspects it, and quits.
param([string]$OutputFolder, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Import-Module NativeHTMLKit

$app = Start-NativeHTMLKitScript -Name 'Diagnostics'
try {
    if ($SelfTest) {
        $OutputFolder = Join-Path ([IO.Path]::GetTempPath()) ('nhk-diag-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $OutputFolder
    }
    if (-not $OutputFolder) { $OutputFolder = [IO.Path]::GetTempPath() }

    $window = New-NativeHTMLKitWindow -Application $app -Title 'About and support' -Width 760 -Height 640
    $doc = Open-NativeHTMLKitHtml -Window $window -Html @'
<!doctype html>
<html><head><style>
  body { font-family: system-ui, sans-serif; margin: 18px; font-size: 14px; }
  h2 { font-size: 16px; margin: 18px 0 6px; }
  table { border-collapse: collapse; }
  td, th { text-align: left; padding: 2px 12px 2px 0; vertical-align: top; }
  td.yes { color: #2e7d32; } td.no { color: #8a1c1c; }
  #bundle { font-family: monospace; font-size: 12px; }
</style></head>
<body>
  <h2>Host</h2><table id="host"></table>
  <h2>Features</h2><table id="features"></table>
  <h2>Desktop preferences</h2><table id="prefs"></table>
  <h2>Connection counters</h2><table id="counters"></table>
  <h2>Support</h2>
  <p><button id="refresh">Refresh</button> <button id="export">Save support bundle</button></p>
  <p id="bundle" role="status"></p>
</body></html>
'@

    # Top-level capability flag -> its entry in $caps.features (the host names drops differently).
    $script:featureKeys = [ordered]@{ clipboard_text = 'clipboard_text'; file_dialogs = 'file_dialogs'; external_open = 'external_open'
        drag_drop = 'incoming_drop'; ime = 'ime'; accessibility = 'accessibility' }

    function Get-FeatureState($Caps, [string]$Flag) {
        # The top-level flag says whether the host offers the API in this session. The feature
        # entry's 'available' is $true/$false when the host has observed the native service and
        # $null ("not observed") otherwise; on a native desktop Core 1.0.3 reports $null here.
        # $null is not $false.
        if (-not $Caps.$Flag) { return @{ Text = 'not available'; Usable = $false } }
        $entry = $null
        if ($null -ne $Caps.features) { $entry = $Caps.features.($script:featureKeys[$Flag]) }
        $available = $null
        if ($null -ne $entry) { $available = $entry.available }
        if ($null -eq $available) { return @{ Text = 'enabled (not observed)'; Usable = $true } }
        if ($available) { return @{ Text = 'available'; Usable = $true } }
        return @{ Text = 'unavailable'; Usable = $false }
    }

    function ConvertTo-Rows($Pairs) {
        # Values from the host are data: always encoded, never trusted as markup.
        $html = New-Object System.Text.StringBuilder
        foreach ($pair in $Pairs) {
            $value = $pair.Value
            $class = ''
            if ($value -is [bool]) { $class = ' class="no"'; if ($value) { $class = ' class="yes"' } }
            if ($null -eq $value) { $value = 'unknown' }
            [void]$html.Append('<tr><th>' + [Net.WebUtility]::HtmlEncode([string]$pair.Name) + "</th><td$class>" + [Net.WebUtility]::HtmlEncode([string]$value) + '</td></tr>')
        }
        return $html.ToString()
    }

    function Update-Diagnostics {
        $caps = Get-NativeHTMLKitCapabilities -Application $app
        $hostInfo = @(
            @{ Name = 'Platform'; Value = $caps.platform }, @{ Name = 'Native session'; Value = $caps.native },
            @{ Name = 'Headless'; Value = $caps.headless }, @{ Name = 'Renderer'; Value = $caps.renderer },
            @{ Name = 'CSS profile'; Value = $caps.css_profile }, @{ Name = 'Max windows'; Value = $caps.max_windows },
            @{ Name = 'PowerShell'; Value = "$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)" },
            @{ Name = 'Module'; Value = [string](Get-Module NativeHTMLKit).Version })
        Set-NativeHTMLKitDocumentHtml -Document $doc -Element host -Html (ConvertTo-Rows $hostInfo)
        $featureHtml = New-Object System.Text.StringBuilder
        foreach ($flag in $script:featureKeys.Keys) {
            $state = Get-FeatureState $caps $flag
            $class = 'no'
            if ($state.Usable) { $class = 'yes' }
            [void]$featureHtml.Append('<tr><th>' + [Net.WebUtility]::HtmlEncode($flag) + "</th><td class=`"$class`">" + [Net.WebUtility]::HtmlEncode($state.Text) + '</td></tr>')
        }
        Set-NativeHTMLKitDocumentHtml -Document $doc -Element features -Html $featureHtml.ToString()

        $prefs = Get-NativeHTMLKitPreferences -Application $app
        Set-NativeHTMLKitDocumentHtml -Document $doc -Element prefs -Html (ConvertTo-Rows @(
            @{ Name = 'Source'; Value = $prefs.source }, @{ Name = 'Colour scheme'; Value = $prefs.color_scheme },
            @{ Name = 'Reduced motion'; Value = $prefs.reduced_motion }, @{ Name = 'High contrast'; Value = $prefs.high_contrast }))

        $report = Get-NativeHTMLKitDiagnosticReport -Application $app
        $counters = @(foreach ($p in $report.Connection.GetEnumerator()) { @{ Name = $p.Key; Value = $p.Value } })
        $counters += @{ Name = 'SDK records (dropped)'; Value = "$($report.RecordCount) ($($report.DroppedRecords))" }
        $notes = @((Get-NativeHTMLKitDiagnostics -Document $doc).diagnostics).Count
        $counters += @{ Name = 'Document diagnostics'; Value = $notes }
        Set-NativeHTMLKitDocumentHtml -Document $doc -Element counters -Html (ConvertTo-Rows $counters)
        return $report
    }

    function Export-Bundle {
        $file = Join-Path $OutputFolder ('nativehtmlkit-support-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.zip')
        try {
            $item = Export-NativeHTMLKitSupportBundle -Path $file -Application $app
            Set-NativeHTMLKitDocumentText -Document $doc -Element bundle -Text ('Saved ' + $item.FullName + ' (' + $item.Length + ' bytes). Attach it to a bug report.')
            return $item
        } catch {
            Set-NativeHTMLKitDocumentText -Document $doc -Element bundle -Text ('Could not save the bundle: ' + $_.Exception.Message)
        }
    }

    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element refresh -Callback { $null = Update-Diagnostics }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element export -Callback { $null = Export-Bundle }

    $null = Update-Diagnostics
    Set-NativeHTMLKitReady -Application $app

    if ($SelfTest) {
        $report = Update-Diagnostics
        if ($report.Connection.CallbackFailures -ne 0) { throw 'no callback should have failed' }
        if ((Find-NativeHTMLKitElement -Document $doc -Selector '#features tr').matched_nodes -ne 6) { throw 'feature table incomplete' }
        # The shape a native desktop reports (Core 1.0.3): top-level flags true, availability null.
        $native = [pscustomobject]@{ clipboard_text = $true; file_dialogs = $true; external_open = $true; drag_drop = $true; ime = $true; accessibility = $true
            features = [pscustomobject]@{ clipboard_text = [pscustomobject]@{ available = $null }; file_dialogs = [pscustomobject]@{ available = $null }
                external_open = [pscustomobject]@{ available = $null }; incoming_drop = [pscustomobject]@{ available = $false }
                ime = [pscustomobject]@{ available = $null }; accessibility = [pscustomobject]@{ available = $null } } }
        if ((Get-FeatureState $native 'file_dialogs').Text -ne 'enabled (not observed)') { throw 'null availability must not be reported as unavailable' }
        if ((Get-FeatureState $native 'drag_drop').Text -ne 'unavailable') { throw 'drag_drop must read features.incoming_drop' }
        $caps = Get-NativeHTMLKitCapabilities -Application $app
        $expected = (@($script:featureKeys.Keys | ForEach-Object { $_ + (Get-FeatureState $caps $_).Text }) -join '')
        if ((Get-NativeHTMLKitDocumentText -Document $doc -Element features) -ne $expected) { throw 'feature rows do not match the capabilities' }
        $item = Export-Bundle
        if ($null -eq $item -or -not (Test-Path -LiteralPath $item.FullName)) { throw 'bundle not written' }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($item.FullName)
        try { $names = @($zip.Entries | ForEach-Object { $_.FullName } | Sort-Object) } finally { $zip.Dispose() }
        if (($names -join ',') -ne 'manifest.json,timeline.jsonl') { throw "unexpected bundle entries: $($names -join ',')" }
        Remove-Item -LiteralPath $OutputFolder -Recurse -Force
        [Console]::Out.WriteLine('SELFTEST PASS 14-diagnostics')
        $null = Request-NativeHTMLKitQuit -Application $app
    }

    Wait-NativeHTMLKit -Application $app -UntilShutdown
} finally {
    Close-NativeHTMLKit -Application $app
}
