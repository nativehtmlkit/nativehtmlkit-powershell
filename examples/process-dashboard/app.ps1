# Process dashboard: a live process monitor built with the NativeHTMLKit PowerShell SDK (tutorial final code).
#
# Teaches: collecting data in the background with Start-NativeHTMLKitTask (an isolated runspace that
#          gets plain data in and returns plain objects), updating the page in -OnCompleted on the
#          owning runspace, scheduling the next refresh, pausing with a checkbox, filtering a cached
#          snapshot, and copying the table to the clipboard with Set-NativeHTMLKitClipboard.
# Run:     pwsh -File app.ps1 [-RefreshSeconds 3]
#          (Windows PowerShell 5.1: powershell.exe -File app.ps1)
# Guide:   docs/tutorials/process-dashboard.md (step 3 of 3)
# -SelfTest waits for two refreshes, filters, sorts, pauses, copies and quits.
param([ValidateRange(1, 3600)][int]$RefreshSeconds = 3, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Import-Module NativeHTMLKit -ErrorAction Stop
$app = Start-NativeHTMLKitScript -Name 'Process Dashboard'

$page = @'
<!doctype html>
<html><head><meta charset="utf-8"><style>
  body { font: 14px sans-serif; margin: 0; background: #11161f; color: #e6ebf3; }
  main { padding: 18px 22px; }
  header { display: flex; align-items: baseline; gap: 12px; }
  h1 { font-size: 20px; margin: 0 0 12px; }
  #status { color: #9fb0c8; }
  form { display: flex; gap: 8px; align-items: center; margin-bottom: 10px; }
  input, select { background: #1b2331; color: #e6ebf3; border: 1px solid #3a475c; border-radius: 5px; padding: 6px; }
  #filter { flex: 1; }
  button { background: #3574c6; color: white; border: 0; border-radius: 5px; padding: 6px 12px; }
  table { border-collapse: collapse; width: 100%; }
  th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid #2a3445; }
  th { color: #9fb0c8; font-weight: 600; }
  td.num, th.num { text-align: right; }
  #summary { color: #9fb0c8; }
</style></head>
<body><main>
  <header><h1>Processes</h1><span id="status" role="status">Collecting...</span></header>
  <form id="view-form">
    <input id="filter" type="search" placeholder="Filter by name" aria-label="Filter by name">
    <select id="sort" aria-label="Sort by">
      <option value="memory">Memory</option><option value="cpu">CPU time</option><option value="name">Name</option>
    </select>
    <label><input type="checkbox" id="paused"> Pause</label>
    <button id="copy" type="button">Copy table</button>
  </form>
  <p id="summary"></p>
  <table>
    <thead><tr><th>Name</th><th class="num">Id</th><th class="num">Memory (MB)</th><th class="num">CPU (s)</th></tr></thead>
    <tbody id="rows"></tbody>
  </table>
</main></body></html>
'@

# Runs in a separate runspace: no access to $app, $doc or this script's variables and functions.
$collect = {
    param([int]$DelayMilliseconds)
    if ($DelayMilliseconds -gt 0) { Start-Sleep -Milliseconds $DelayMilliseconds }
    Get-Process | ForEach-Object {
        [pscustomobject]@{ Name = $_.ProcessName; Id = $_.Id
            MemoryMB = [Math]::Round($_.WorkingSet64 / 1MB, 1); Cpu = [Math]::Round([double]$_.CPU, 1) }
    }
}

# Everything the callbacks change lives in one object, so they never need to assign script variables.
$view = [pscustomobject]@{ Rows = @(); Refreshes = 0; Task = $null; Shown = @() }

function ConvertTo-HtmlText([string]$Text) { return [System.Net.WebUtility]::HtmlEncode($Text) }

function Update-View {
    $filter = (Get-NativeHTMLKitValue -Document $doc -Element filter).Trim()
    $shown = @($view.Rows | Where-Object { $filter -eq '' -or $_.Name.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    $sorted = switch (Get-NativeHTMLKitValue -Document $doc -Element sort) {
        'cpu'  { $shown | Sort-Object Cpu -Descending }
        'name' { $shown | Sort-Object Name }
        default { $shown | Sort-Object MemoryMB -Descending }
    }
    $view.Shown = @($sorted | Select-Object -First 25)
    $html = @($view.Shown | ForEach-Object {
        '<tr><td>{0}</td><td class="num">{1}</td><td class="num">{2:N1}</td><td class="num">{3:N1}</td></tr>' -f `
            (ConvertTo-HtmlText $_.Name), $_.Id, $_.MemoryMB, $_.Cpu
    }) -join ''
    $total = ($view.Rows | Measure-Object MemoryMB -Sum).Sum
    Set-NativeHTMLKitDocumentHtml -Document $doc -Element rows -Html $html
    Set-NativeHTMLKitDocumentText -Document $doc -Element summary -Text ("Showing {0} of {1} processes, {2:N0} MB in total" -f $view.Shown.Count, $view.Rows.Count, $total)
}

function Start-Refresh([int]$DelayMilliseconds) {
    $view.Task = Start-NativeHTMLKitTask -Application $app -ScriptBlock $collect -ArgumentList @($DelayMilliseconds) -OnCompleted {
        param($rows)
        $view.Task = $null
        $view.Rows = @($rows)
        $view.Refreshes++
        Update-View
        Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text ("Updated {0:HH:mm:ss} (refresh #{1})" -f (Get-Date), $view.Refreshes)
        if (-not (Get-NativeHTMLKitChecked -Document $doc -Element paused)) { Start-Refresh ($RefreshSeconds * 1000) }
    } -OnFailed {
        param($failure)
        $view.Task = $null
        Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text ('Refresh failed: ' + $failure.Message)
    }
}

function Copy-Table {
    $lines = @("Name`tId`tMemoryMB`tCpu") + @($view.Shown | ForEach-Object { "$($_.Name)`t$($_.Id)`t$($_.MemoryMB)`t$($_.Cpu)" })
    try {
        Set-NativeHTMLKitClipboard -Application $app -Text ($lines -join [Environment]::NewLine)
        Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text "Copied $($view.Shown.Count) rows"
    } catch {
        Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text 'The clipboard is not available in this session'
    }
}

try {
    $window = New-NativeHTMLKitWindow -Application $app -Title 'Process Dashboard' -Width 760 -Height 640
    $doc = Open-NativeHTMLKitHtml -Window $window -Html $page
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type input -Element filter -Callback { param($eventObject) Update-View }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type change -Element sort -Callback { param($eventObject) Update-View }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type submit -Element 'view-form' -Callback { param($eventObject) Update-View }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type change -Element paused -Callback {
        param($eventObject)
        if ([bool]$eventObject.checked) {
            Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text 'Paused'
        } elseif ($null -eq $view.Task) {
            Start-Refresh 0
        }
    }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element copy -Callback { param($eventObject) Copy-Table }
    Start-Refresh 0
    Set-NativeHTMLKitReady -Application $app

    if ($SelfTest) {
        function Wait-For([scriptblock]$Condition) {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            while (-not (& $Condition)) {
                if ($clock.ElapsedMilliseconds -gt 30000) { throw "timed out waiting for: $Condition" }
                $null = Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 50
            }
        }
        Wait-For { $view.Refreshes -ge 2 }
        if ((Get-NativeHTMLKitDocumentText -Document $doc -Element status) -notmatch '^Updated \d\d:\d\d:\d\d \(refresh #\d+\)$') { throw 'status not updated' }
        if ((Find-NativeHTMLKitElement -Document $doc -Selector '#rows tr').matched_nodes -lt 1) { throw 'no rows' }
        # Filter on this backend's own process name; the filter is a substring, never a wildcard.
        $me = (Get-Process -Id $PID).ProcessName
        Set-NativeHTMLKitDocumentValue -Document $doc -Element filter -Value $me
        Update-View
        if (@($view.Shown | Where-Object { $_.Id -eq $PID }).Count -ne 1) { throw 'own process not shown by the filter' }
        Set-NativeHTMLKitDocumentValue -Document $doc -Element filter -Value '[*'
        Update-View
        if ((Get-NativeHTMLKitDocumentText -Document $doc -Element summary) -notmatch '^Showing 0 of \d+ processes') { throw 'wildcard characters matched' }
        Set-NativeHTMLKitDocumentValue -Document $doc -Element filter -Value ''
        Set-NativeHTMLKitSelectedValues -Document $doc -Element sort -Values @('name')
        Update-View
        $names = @($view.Shown | ForEach-Object { $_.Name })
        if (($names -join '|') -ne (@($names | Sort-Object) -join '|')) { throw 'not sorted by name' }
        Set-NativeHTMLKitChecked -Document $doc -Element paused -Checked $true
        Copy-Table
        if ((Get-NativeHTMLKitDocumentText -Document $doc -Element status) -notmatch '^(Copied \d+ rows|The clipboard is not available in this session)$') { throw 'copy status missing' }
        [Console]::Out.WriteLine('SELFTEST PASS process-dashboard')
        $null = Request-NativeHTMLKitQuit -Application $app
    }

    Wait-NativeHTMLKit -Application $app -UntilShutdown
} finally {
    Close-NativeHTMLKit -Application $app
}
