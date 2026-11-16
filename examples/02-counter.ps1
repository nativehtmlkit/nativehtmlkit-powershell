# 02-counter.ps1 - a counter with a step selector, limits and a change history.
#
# Teaches: script-scoped state shared by callbacks ($script:), one click handler for
# several buttons (event delegation through the event's element id), reading a <select>,
# and atomic multi-element updates with Invoke-NativeHTMLKitBatch.
#
# Run:  pwsh -File ./02-counter.ps1        (or powershell.exe -NoProfile -File .\02-counter.ps1)
# -SelfTest drives the app through the public API and quits.
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Import-Module NativeHTMLKit

$app = Start-NativeHTMLKitScript -Name 'Counter'
try {
    $window = New-NativeHTMLKitWindow -Application $app -Title 'Counter' -Width 460 -Height 420 -MinWidth 360 -MinHeight 320
    $doc = Open-NativeHTMLKitHtml -Window $window -Html @'
<!doctype html>
<html><head><style>
  body { font-family: system-ui, sans-serif; margin: 28px; }
  #value { font-size: 56px; font-weight: 600; margin: 8px 0 16px; }
  #value.negative { color: #b3261e; }
  #value.at-limit { text-decoration: underline; }
  .row { display: flex; gap: 8px; align-items: center; }
  button { min-width: 44px; padding: 6px 12px; font-size: 16px; }
  #history { color: #555; font-size: 13px; }
</style></head>
<body>
  <div id="value" aria-live="polite">0</div>
  <div class="row" id="buttons">
    <button id="dec" aria-label="Decrease">-</button>
    <button id="inc" aria-label="Increase">+</button>
    <button id="reset">Reset</button>
    <label for="step">Step</label>
    <select id="step"><option>1</option><option>5</option><option>10</option></select>
  </div>
  <p id="limits">Range -50 to 50.</p>
  <ol id="history" reversed></ol>
</body></html>
'@

    $script:count = 0
    $script:minimum = -50
    $script:maximum = 50

    function Set-Count([int]$Value, [string]$Reason) {
        $Value = [Math]::Max($script:minimum, [Math]::Min($script:maximum, $Value))
        $script:count = $Value
        $negativeOp = 'remove_class'
        if ($Value -lt 0) { $negativeOp = 'add_class' }
        $limitOp = 'remove_class'
        if ($Value -eq $script:minimum -or $Value -eq $script:maximum) { $limitOp = 'add_class' }
        # One transaction: the value, its classes and the history entry change together.
        Invoke-NativeHTMLKitBatch -Document $doc -Operations @(
            @{ op = 'set_text'; element = 'value'; text = [string]$Value }
            @{ op = $negativeOp; element = 'value'; name = 'negative' }
            @{ op = $limitOp; element = 'value'; name = 'at-limit' }
            @{ op = 'insert_html'; element = 'history'; position = 'afterbegin'
               html = '<li>' + [Net.WebUtility]::HtmlEncode("$Reason -> $Value") + '</li>' }
            @{ op = 'trim_children'; element = 'history'; keep = 8; from = 'end' }
        )
    }

    # One handler on the button row: $evt.element is the id of the clicked element.
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element buttons -Callback {
        param($evt)
        $step = [int](Get-NativeHTMLKitValue -Document $doc -Element step)
        switch ($evt.element) {
            'inc'   { Set-Count ($script:count + $step) "+$step" }
            'dec'   { Set-Count ($script:count - $step) "-$step" }
            'reset' { Set-Count 0 'reset' }
        }
    }

    Set-NativeHTMLKitReady -Application $app

    if ($SelfTest) {
        Set-NativeHTMLKitSelectedValues -Document $doc -Element step -Values @('10')
        $step = [int](Get-NativeHTMLKitValue -Document $doc -Element step)
        for ($i = 0; $i -lt 7; $i++) { Set-Count ($script:count - $step) "-$step" }
        if ((Get-NativeHTMLKitDocumentText -Document $doc -Element value) -ne '-50') { throw 'value was not clamped to -50' }
        $classes = (Invoke-NativeHTMLKitDocumentCommand -Document $doc -Operation get_attribute -Parameters @{ element = 'value'; name = 'class' }).value
        if ($classes -notmatch 'negative' -or $classes -notmatch 'at-limit') { throw "unexpected classes: $classes" }
        $items = (Find-NativeHTMLKitElement -Document $doc -Selector '#history li').matched_nodes
        if ($items -ne 7) { throw "expected 7 history entries, found $items" }
        Set-Count 0 'reset'
        Set-Count 3 '+3'
        if ((Find-NativeHTMLKitElement -Document $doc -Selector '#history li').matched_nodes -ne 8) { throw 'history was not trimmed to 8' }
        $newest = Get-NativeHTMLKitNodes -Document $doc -Selector '#history li' -Limit 1
        $first = Invoke-NativeHTMLKitDocumentCommand -Document $doc -Operation get_html -Parameters @{ node = $newest.nodes[0].node }
        if ($first.html -ne '+3 -&gt; 3') { throw "newest entry should be first: $($first.html)" }
        [Console]::Out.WriteLine('SELFTEST PASS 02-counter')
        $null = Request-NativeHTMLKitQuit -Application $app
    }

    Wait-NativeHTMLKit -Application $app -UntilShutdown
} finally {
    Close-NativeHTMLKit -Application $app
}
