# Process dashboard tutorial, step 2: filter and sort the table.
#
# Teaches: Register-NativeHTMLKitDocumentEvent for "input" and "submit" events, reading controls with
#          Get-NativeHTMLKitValue, keeping view state in one object that callbacks can change,
#          Set-NativeHTMLKitDocumentText for untrusted text.
# Run:     pwsh -File step2-filter.ps1        (Windows PowerShell 5.1: powershell.exe -File step2-filter.ps1)
# Guide:   docs/tutorials/process-dashboard.md (step 2 of 3)
$ErrorActionPreference = 'Stop'
Import-Module NativeHTMLKit -ErrorAction Stop
$app = Start-NativeHTMLKitScript -Name 'Process Dashboard'

$page = @'
<!doctype html>
<html><head><meta charset="utf-8"><style>
  body { font: 14px sans-serif; margin: 0; background: #11161f; color: #e6ebf3; }
  main { padding: 18px 22px; }
  h1 { font-size: 20px; margin: 0 0 12px; }
  form { display: flex; gap: 8px; margin-bottom: 10px; }
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
  <h1>Processes</h1>
  <form id="view-form">
    <input id="filter" type="search" placeholder="Filter by name" aria-label="Filter by name">
    <select id="sort" aria-label="Sort by">
      <option value="memory">Memory</option><option value="cpu">CPU time</option><option value="name">Name</option>
    </select>
    <button id="apply">Refresh</button>
  </form>
  <p id="summary"></p>
  <table>
    <thead><tr><th>Name</th><th class="num">Id</th><th class="num">Memory (MB)</th><th class="num">CPU (s)</th></tr></thead>
    <tbody id="rows"></tbody>
  </table>
</main></body></html>
'@

function ConvertTo-HtmlText([string]$Text) { return [System.Net.WebUtility]::HtmlEncode($Text) }

function Update-View {
    $filter = (Get-NativeHTMLKitValue -Document $doc -Element filter).Trim()
    $sort = Get-NativeHTMLKitValue -Document $doc -Element sort
    $all = @(Get-Process)
    $shown = @($all | Where-Object { $filter -eq '' -or $_.ProcessName.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    $sorted = switch ($sort) {
        'cpu'  { $shown | Sort-Object { [double]$_.CPU } -Descending }
        'name' { $shown | Sort-Object ProcessName }
        default { $shown | Sort-Object WorkingSet64 -Descending }
    }
    $html = @($sorted | Select-Object -First 25 | ForEach-Object {
        '<tr><td>{0}</td><td class="num">{1}</td><td class="num">{2:N1}</td><td class="num">{3:N1}</td></tr>' -f `
            (ConvertTo-HtmlText $_.ProcessName), $_.Id, ($_.WorkingSet64 / 1MB), [double]$_.CPU
    }) -join ''
    Set-NativeHTMLKitDocumentHtml -Document $doc -Element rows -Html $html
    Set-NativeHTMLKitDocumentText -Document $doc -Element summary -Text ("Showing {0} of {1} processes" -f [Math]::Min(25, $shown.Count), $all.Count)
}

try {
    $window = New-NativeHTMLKitWindow -Application $app -Title 'Process Dashboard' -Width 720 -Height 600
    $doc = Open-NativeHTMLKitHtml -Window $window -Html $page
    # Callbacks run later, inside Wait-NativeHTMLKit, and can call the functions defined above.
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type input -Element filter -Callback { param($eventObject) Update-View }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type change -Element sort -Callback { param($eventObject) Update-View }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type submit -Element 'view-form' -Callback { param($eventObject) Update-View }
    Update-View
    Set-NativeHTMLKitReady -Application $app
    Wait-NativeHTMLKit -Application $app -UntilShutdown
} finally {
    Close-NativeHTMLKit -Application $app
}
