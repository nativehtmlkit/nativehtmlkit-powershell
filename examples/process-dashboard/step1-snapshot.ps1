# Process dashboard tutorial, step 1: show a table of the busiest processes in a native window.
#
# Teaches: Start-NativeHTMLKitScript, New-NativeHTMLKitWindow, Open-NativeHTMLKitHtml, building
#          HTML rows from objects with HtmlEncode, Set-NativeHTMLKitDocumentHtml, Wait-NativeHTMLKit.
# Run:     pwsh -File step1-snapshot.ps1      (Windows PowerShell 5.1: powershell.exe -File step1-snapshot.ps1)
# Guide:   docs/tutorials/process-dashboard.md (step 1 of 3)
$ErrorActionPreference = 'Stop'
Import-Module NativeHTMLKit -ErrorAction Stop
# The host runs this script again as its backend: everything below this line runs in that backend.
$app = Start-NativeHTMLKitScript -Name 'Process Dashboard'

$page = @'
<!doctype html>
<html><head><meta charset="utf-8"><style>
  body { font: 14px sans-serif; margin: 0; background: #11161f; color: #e6ebf3; }
  main { padding: 18px 22px; }
  h1 { font-size: 20px; margin: 0 0 12px; }
  table { border-collapse: collapse; width: 100%; }
  th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid #2a3445; }
  th { color: #9fb0c8; font-weight: 600; }
  td.num, th.num { text-align: right; }
</style></head>
<body><main>
  <h1>Top processes by memory</h1>
  <table>
    <thead><tr><th>Name</th><th class="num">Id</th><th class="num">Memory (MB)</th><th class="num">CPU (s)</th></tr></thead>
    <tbody id="rows"></tbody>
  </table>
</main></body></html>
'@

function ConvertTo-HtmlText([string]$Text) { return [System.Net.WebUtility]::HtmlEncode($Text) }

function Get-ProcessRowsHtml([int]$Top) {
    $rows = Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First $Top | ForEach-Object {
        '<tr><td>{0}</td><td class="num">{1}</td><td class="num">{2:N1}</td><td class="num">{3:N1}</td></tr>' -f `
            (ConvertTo-HtmlText $_.ProcessName), $_.Id, ($_.WorkingSet64 / 1MB), [double]$_.CPU
    }
    return ($rows -join '')
}

try {
    $window = New-NativeHTMLKitWindow -Application $app -Title 'Process Dashboard' -Width 720 -Height 560
    $doc = Open-NativeHTMLKitHtml -Window $window -Html $page
    Set-NativeHTMLKitDocumentHtml -Document $doc -Element rows -Html (Get-ProcessRowsHtml -Top 15)
    Set-NativeHTMLKitReady -Application $app
    Wait-NativeHTMLKit -Application $app -UntilShutdown
} finally {
    Close-NativeHTMLKit -Application $app
}
