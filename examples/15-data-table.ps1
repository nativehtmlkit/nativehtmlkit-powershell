# 15-data-table.ps1 - search, sort, page through and inspect a list of records.
#
# Teaches: re-rendering a table body from escaped data ([Net.WebUtility]::HtmlEncode), live
# search with the `input` event (the event carries the control's current `value`), a <select>
# `change` event, sortable column headers and pagination buttons through delegated click
# handlers, a details pane updated with Set-NativeHTMLKitDocumentText (always plain text), and one
# Invoke-NativeHTMLKitBatch per render (one round trip, one atomic document update).
# PowerShell extra: -Path loads the records from a CSV file with Import-Csv.
#
# Run:  pwsh -File ./15-data-table.ps1 [-Path inventory.csv]
#       powershell.exe -NoProfile -File .\15-data-table.ps1
# The CSV needs the columns sku, name, category, stock, price. Without -Path the app shows 240
# generated inventory records (the same ones on every start).
# -SelfTest (with or without -Path) drives search, filter, sort, paging and selection through the public API and quits.
param([string]$Path, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Import-Module NativeHTMLKit

# Validate arguments before starting the host, so a wrong path is reported on the console.
if ($Path -and -not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "CSV file not found: $Path" }

$app = Start-NativeHTMLKitScript -Name 'Inventory'
try {
    $columns = @(
        @{ Key = 'sku'; Label = 'SKU' }, @{ Key = 'name'; Label = 'Product' }, @{ Key = 'category'; Label = 'Category' },
        @{ Key = 'stock'; Label = 'Stock' }, @{ Key = 'price'; Label = 'Price' })
    $invariant = [Globalization.CultureInfo]::InvariantCulture

    function New-SampleInventory([int]$Count = 240, [int]$Seed = 7) {
        $random = New-Object Random $Seed          # deterministic: the same rows on every start
        $adjectives = 'Compact', 'Deluxe', 'Eco', 'Heavy-duty', 'Mini', 'Smart', 'Travel', 'Ultra'
        $things = [ordered]@{ Audio = 'speaker', 'headset', 'radio'; Garden = 'hose', 'rake', 'planter'
            Kitchen = 'kettle', 'blender', 'toaster'; Office = 'stapler', 'lamp', 'chair' }
        $categories = @($things.Keys)
        for ($n = 1; $n -le $Count; $n++) {
            $category = $categories[$random.Next($categories.Count)]
            $items = $things[$category]
            [pscustomobject]@{ sku = 'SKU-{0:D4}' -f $n
                name = $adjectives[$random.Next($adjectives.Count)] + ' ' + $items[$random.Next($items.Count)]
                category = $category; stock = $random.Next(0, 501); price = [Math]::Round(3 + $random.NextDouble() * 397, 2) }
        }
    }

    function Import-Inventory([string]$File) {
        Import-Csv -LiteralPath $File | ForEach-Object {
            [pscustomobject]@{ sku = [string]$_.sku; name = [string]$_.name; category = [string]$_.category
                stock = [int]$_.stock; price = [double]::Parse($_.price, $invariant) }
        }
    }

    $headers = ($columns | ForEach-Object { '<th id="col-{0}">{1}</th>' -f $_.Key, $_.Label }) -join ''
    $window = New-NativeHTMLKitWindow -Application $app -Title 'Inventory' -Width 980 -Height 640
    $doc = Open-NativeHTMLKitHtml -Window $window -Html (@'
<!doctype html>
<html><head><meta charset="utf-8"><style>
  body { margin:0; font:13px sans-serif; background:#f4f5f8; color:#1e2330; display:flex; height:100vh; }
  .main { flex:1; display:flex; flex-direction:column; padding:14px 16px; min-width:0; }
  .tools { display:flex; gap:10px; align-items:center; margin-bottom:10px; }
  input[type=search] { flex:1; padding:7px; border:1px solid #c3c9d6; border-radius:5px; }
  .scroll { flex:1; overflow:auto; background:#fff; border-radius:6px; }
  table { width:100%; border-collapse:collapse; }
  th { position:sticky; top:0; background:#e9ecf2; text-align:left; padding:7px 8px; cursor:pointer; }
  th.sorted-asc::after { content:" \25B2"; } th.sorted-desc::after { content:" \25BC"; }
  td { padding:6px 8px; border-bottom:1px solid #eceef3; }
  td.num { text-align:right; font-variant-numeric:tabular-nums; }
  tr.low td { color:#b03a2e; }
  tr.selected td { background:#dce7fd; }
  .pager { display:flex; gap:8px; align-items:center; margin-top:8px; }
  button { padding:4px 10px; }
  aside { width:240px; padding:16px; background:#fff; border-left:1px solid #dde1e8; }
  aside dt { color:#6a7284; margin-top:8px; } aside dd { margin:2px 0 0; font-weight:bold; }
</style></head>
<body>
  <div class="main">
    <div class="tools">
      <input id="search" type="search" placeholder="Search name, SKU or category">
      <label>Category <select id="category"><option value="">All</option></select></label>
    </div>
    <div class="scroll"><table>
      <thead><tr id="headers">%HEADERS%</tr></thead><tbody id="rows"></tbody></table></div>
    <div class="pager"><button id="prev">&lsaquo; Previous</button><span id="page">-</span>
      <button id="next">Next &rsaquo;</button><span id="matches"></span></div>
  </div>
  <aside><h2>Details</h2><dl>
    <dt>SKU</dt><dd id="d-sku">-</dd><dt>Product</dt><dd id="d-name">-</dd>
    <dt>Category</dt><dd id="d-category">-</dd><dt>Stock</dt><dd id="d-stock">-</dd><dt>Price</dt><dd id="d-price">-</dd>
  </dl></aside>
</body></html>
'@).Replace('%HEADERS%', $headers)

    # All view state lives in one hashtable: callbacks change its entries, never script variables.
    $table = @{ Records = @(); Query = ''; Category = ''; SortKey = 'sku'; Descending = $false
        Page = 0; PageSize = 25; Selected = $null; Matches = 0 }
    if ($Path) { $table.Records = @(Import-Inventory $Path) } else { $table.Records = @(New-SampleInventory) }

    function ConvertTo-HtmlText([string]$Text) { return [Net.WebUtility]::HtmlEncode($Text) }

    function Get-VisibleRecords {
        $needle = $table.Query
        $rows = @($table.Records | Where-Object {
            ($table.Category -eq '' -or $_.category -eq $table.Category) -and
            ($needle -eq '' -or $_.sku.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $_.name.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $_.category.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) })
        # The SKU as second key keeps equal values in a stable order (Windows PowerShell 5.1 has no -Stable).
        return @($rows | Sort-Object -Property @{ Expression = $table.SortKey; Descending = $table.Descending }, @{ Expression = 'sku'; Descending = $false })
    }

    function Update-Table {
        $rows = Get-VisibleRecords
        $table.Matches = $rows.Count
        $pages = [Math]::Max(1, [int][Math]::Ceiling($rows.Count / $table.PageSize))
        $table.Page = [Math]::Max(0, [Math]::Min($table.Page, $pages - 1))
        $body = New-Object System.Text.StringBuilder
        $start = $table.Page * $table.PageSize
        foreach ($r in @($rows | Select-Object -Skip $start -First $table.PageSize)) {
            $classes = @()
            if ($r.stock -lt 20) { $classes += 'low' }
            if ($r.sku -eq $table.Selected) { $classes += 'selected' }
            $sku = ConvertTo-HtmlText $r.sku
            [void]$body.Append(('<tr id="row-{0}" class="{1}"><td>{0}</td><td>{2}</td><td>{3}</td><td class="num">{4}</td><td class="num">{5}</td></tr>' -f
                $sku, ($classes -join ' '), (ConvertTo-HtmlText $r.name), (ConvertTo-HtmlText $r.category), $r.stock, $r.price.ToString('F2', $invariant)))
        }
        $html = $body.ToString()
        if (-not $html) { $html = '<tr><td colspan="5">No matching records.</td></tr>' }
        # One batch = one round trip and one atomic document update (all or nothing).
        $ops = New-Object System.Collections.Generic.List[object]
        $ops.Add(@{ op = 'replace_children_html'; element = 'rows'; html = $html })
        foreach ($column in $columns) {
            $ops.Add(@{ op = 'remove_class'; element = "col-$($column.Key)"; name = 'sorted-asc' })
            $ops.Add(@{ op = 'remove_class'; element = "col-$($column.Key)"; name = 'sorted-desc' })
        }
        $direction = 'sorted-asc'
        if ($table.Descending) { $direction = 'sorted-desc' }
        $ops.Add(@{ op = 'add_class'; element = "col-$($table.SortKey)"; name = $direction })
        $ops.Add(@{ op = 'set_text'; element = 'page'; text = "Page $($table.Page + 1) of $pages" })
        $ops.Add(@{ op = 'set_text'; element = 'matches'; text = "$($rows.Count) of $($table.Records.Count) records" })
        Invoke-NativeHTMLKitBatch -Document $doc -Operations $ops.ToArray()
    }

    function Set-Query([string]$Text) { $table.Query = $Text.Trim(); $table.Page = 0; Update-Table }
    function Set-Category([string]$Name) { $table.Category = $Name; $table.Page = 0; Update-Table }
    function Move-Page([int]$Delta) { $table.Page += $Delta; Update-Table }

    function Set-SortColumn([string]$Key) {
        if ($Key -eq $table.SortKey) { $table.Descending = -not $table.Descending } else { $table.Descending = $false }
        $table.SortKey = $Key; $table.Page = 0
        Update-Table
    }

    function Select-Record([string]$Sku) {
        $record = @($table.Records | Where-Object { $_.sku -eq $Sku })[0]
        if ($null -eq $record) { return }
        $table.Selected = $Sku
        foreach ($column in $columns) {
            $value = $record.($column.Key)
            if ($column.Key -eq 'price') { $value = $value.ToString('F2', $invariant) }
            Set-NativeHTMLKitDocumentText -Document $doc -Element "d-$($column.Key)" -Text ([string]$value)
        }
        Update-Table
    }

    # The category list comes from the data (the CSV may have other categories).
    $options = @($table.Records | ForEach-Object { $_.category } | Sort-Object -Unique | ForEach-Object { '<option>' + (ConvertTo-HtmlText $_) + '</option>' })
    Set-NativeHTMLKitDocumentHtml -Document $doc -Element category -Html ($options -join '') -Position beforeend

    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type input -Element search -Callback { param($evt) Set-Query ([string]$evt.value) }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type change -Element category -Callback { param($evt) Set-Category ([string]$evt.value) }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element headers -Callback {
        param($evt)
        if ($evt.element -like 'col-*') { Set-SortColumn $evt.element.Substring(4) }
    }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element prev -Callback { Move-Page -1 }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element next -Callback { Move-Page 1 }
    # A click on a <td> (no id) reports the nearest identified ancestor: the row.
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element rows -Callback {
        param($evt)
        if ($evt.element -like 'row-*') { Select-Record $evt.element.Substring(4) }
    }

    Update-Table
    Set-NativeHTMLKitReady -Application $app

    if ($SelfTest) {
        function Assert-Text([string]$Element, [string]$Expected) {
            $actual = Get-NativeHTMLKitDocumentText -Document $doc -Element $Element
            if ($actual -ne $Expected) { throw "#$Element is '$actual', expected '$Expected'" }
        }
        function Get-RowCount { return (Find-NativeHTMLKitElement -Document $doc -Selector '#rows tr[id]').matched_nodes }
        if ($Path) {
            # With a CSV file: every record is loaded and the first one can be selected.
            $n = $table.Records.Count
            Assert-Text matches "$n of $n records"
            Select-Record $table.Records[0].sku
            Assert-Text d-name $table.Records[0].name
            [Console]::Out.WriteLine('SELFTEST PASS 15-data-table')
            $null = Request-NativeHTMLKitQuit -Application $app
            Wait-NativeHTMLKit -Application $app -UntilShutdown
            return
        }
        Assert-Text page 'Page 1 of 10'
        Assert-Text matches '240 of 240 records'
        if ((Get-RowCount) -ne 25) { throw 'expected 25 rows on the first page' }
        Move-Page 1; Move-Page 1
        Assert-Text page 'Page 3 of 10'
        Move-Page 99
        Assert-Text page 'Page 10 of 10'
        Set-Category 'Garden'
        $garden = @($table.Records | Where-Object { $_.category -eq 'Garden' }).Count
        Assert-Text matches "$garden of 240 records"
        if ((Find-NativeHTMLKitElement -Document $doc -Selector '#category option').matched_nodes -ne 5) { throw 'expected 5 category options' }
        Set-Category ''
        Set-Query 'sku-000'
        Assert-Text matches '9 of 240 records'
        Set-Query 'no such product <b>'
        Assert-Text matches '0 of 240 records'
        if ((Find-NativeHTMLKitElement -Document $doc -Selector '#rows td[colspan]').matched_nodes -ne 1) { throw 'empty state missing' }
        Set-Query ''
        Set-SortColumn 'price'; Set-SortColumn 'price'
        if ((Find-NativeHTMLKitElement -Document $doc -Selector '#col-price.sorted-desc').matched_nodes -ne 1) { throw 'sort indicator missing' }
        $top = @($table.Records | Sort-Object price -Descending)[0]
        $first = (Get-NativeHTMLKitNodes -Document $doc -Selector '#rows tr' -Limit 1).nodes[0].element
        if ($first -ne "row-$($top.sku)") { throw "most expensive record should be first, got $first" }
        Select-Record $top.sku
        Assert-Text d-sku $top.sku
        Assert-Text d-price $top.price.ToString('F2', $invariant)
        if ((Find-NativeHTMLKitElement -Document $doc -Selector '#rows tr.selected').matched_nodes -ne 1) { throw 'selection not shown' }
        [Console]::Out.WriteLine('SELFTEST PASS 15-data-table')
        $null = Request-NativeHTMLKitQuit -Application $app
    }

    Wait-NativeHTMLKit -Application $app -UntilShutdown
} finally {
    Close-NativeHTMLKit -Application $app
}
