# 16-dom-explorer.ps1 - browse the live element tree and edit nodes that have no HTML id.
#
# Teaches: node references for elements without an id (Get-NativeHTMLKitNode -Element and
# -Reference, Get-NativeHTMLKitNodes), walking the tree with Get-NativeHTMLKitNodeInfo and the
# paginated Get-NativeHTMLKitNodeChildren, node mutations with Invoke-NativeHTMLKitNodeOperation
# (add_class, remove_class, set_text, move_element, remove_element), and the rule that node
# references belong to ONE document generation: after the element is removed or replaced they are
# stale.
#
# Run:  pwsh -File ./16-dom-explorer.ps1      (or powershell.exe -NoProfile -File .\16-dom-explorer.ps1)
# Click a node in the tree on the left; the matching element in the sample is highlighted.
# -SelfTest selects, moves, edits and deletes nodes through the public API and quits.
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Import-Module NativeHTMLKit

$app = Start-NativeHTMLKitScript -Name 'DOM explorer'
try {
    $window = New-NativeHTMLKitWindow -Application $app -Title 'DOM explorer' -Width 900 -Height 560
    $doc = Open-NativeHTMLKitHtml -Window $window -Html @'
<!doctype html>
<html><head><meta charset="utf-8"><style>
  body { margin:0; font:13px sans-serif; display:flex; height:100vh; color:#1d2230; }
  #tree { width:320px; overflow:auto; background:#f3f4f8; border-right:1px solid #d9dde6; padding:8px 0; font-family:monospace; }
  .item { padding:2px 8px; cursor:pointer; white-space:nowrap; }
  .item:hover { background:#e1e8fa; } .item.current { background:#c9d8fb; }
  .tag { color:#7c3aa8; } .attr { color:#9a6a00; } .text { color:#4a7a2a; }
  .right { flex:1; display:flex; flex-direction:column; }
  .tools { padding:8px 12px; display:flex; gap:6px; border-bottom:1px solid #d9dde6; align-items:center; }
  #info { color:#5c6577; margin-left:8px; font-family:monospace; }
  #sample { padding:16px 20px; overflow:auto; }
  .highlight { outline:2px solid #e8590c; background:#fff4e6; }
</style></head>
<body>
  <div id="tree"></div>
  <div class="right">
    <div class="tools"><button id="up">Move up</button><button id="shout">UPPERCASE text</button>
      <button id="delete">Delete</button><button id="reset">Reset sample</button><span id="info">Nothing selected</span></div>
    <div id="sample"></div>
  </div>
</body></html>
'@

    $sample = @'
<article><h2>Release notes</h2>
<p>Elements in this sample have <em>no</em> id attributes.</p>
<ul><li>Faster layout</li><li>Smaller binaries</li><li>Better <code>dialog</code> support</li></ul>
<blockquote>Node references work without ids.</blockquote></article>
'@

    # Tree row index -> node reference; the current node. Callbacks change these entries.
    $explorer = @{ Items = New-Object System.Collections.Generic.List[object]; Current = $null }

    function ConvertTo-HtmlText([string]$Text) { return [Net.WebUtility]::HtmlEncode($Text) }
    function Get-Info($Node) { return Get-NativeHTMLKitNodeInfo -Node $Node }
    function Get-Ref([string]$Reference) { return Get-NativeHTMLKitNode -Document $doc -Reference $Reference }

    function Reset-Sample {
        Set-NativeHTMLKitDocumentHtml -Document $doc -Element sample -Html $sample
        $explorer.Current = $null
        Set-NativeHTMLKitDocumentText -Document $doc -Element info -Text 'Nothing selected'
        Update-Tree
    }

    # Walk the sample subtree with Get-NativeHTMLKitNodeChildren and render one row per node.
    function Add-TreeRows($Node, [int]$Depth, [Text.StringBuilder]$Rows) {
        $listing = Get-NativeHTMLKitNodeChildren -Node $Node -Limit 256
        foreach ($child in @($listing.children)) {
            $ref = Get-Ref $child.node
            $info = Get-Info $ref
            if ($info.type -eq 'text') {
                $text = ([string]$info.text).Trim()            # text nodes report their text
                if (-not $text) { continue }                   # skip whitespace between tags
                if ($text.Length -gt 40) { $text = $text.Substring(0, 40) }
                $label = '<span class="text">"' + (ConvertTo-HtmlText $text) + '"</span>'
            } elseif ($info.type -eq 'element') {
                $attrs = ''
                if ($info.attributes) {
                    # Host replies are objects: attributes are its properties.
                    foreach ($p in $info.attributes.PSObject.Properties) {
                        $attrs += ' <span class="attr">' + (ConvertTo-HtmlText $p.Name) + '="' + (ConvertTo-HtmlText ([string]$p.Value)) + '"</span>'
                    }
                }
                $label = '<span class="tag">&lt;' + (ConvertTo-HtmlText $info.name) + '&gt;</span>' + $attrs
            } else {
                continue
            }
            $current = ''
            if ($null -ne $explorer.Current -and $explorer.Current.Id -eq $ref.Id) { $current = ' current' }
            [void]$Rows.Append(('<div id="item-{0}" class="item{1}" style="padding-left:{2}px">{3}</div>' -f $explorer.Items.Count, $current, (8 + $Depth * 14), $label))
            $explorer.Items.Add($ref)
            if ($info.type -eq 'element') { Add-TreeRows $ref ($Depth + 1) $Rows }
        }
    }

    function Update-Tree {
        $explorer.Items.Clear()
        $rows = New-Object System.Text.StringBuilder
        Add-TreeRows (Get-NativeHTMLKitNode -Document $doc -Element sample) 0 $rows
        Set-NativeHTMLKitDocumentHtml -Document $doc -Element tree -Html $rows.ToString()
    }

    function Select-TreeItem([int]$Index) {
        if ($null -ne $explorer.Current) {
            try { Invoke-NativeHTMLKitNodeOperation -Node $explorer.Current -Operation remove_class -Parameters @{ name = 'highlight' } }
            catch { $null = $_ }                     # the previous node may have been deleted
        }
        $explorer.Current = $explorer.Items[$Index]
        $info = Get-Info $explorer.Current
        if ($info.type -eq 'element') { Invoke-NativeHTMLKitNodeOperation -Node $explorer.Current -Operation add_class -Parameters @{ name = 'highlight' } }
        $name = $info.name
        if (-not $name) { $name = $info.type }
        Set-NativeHTMLKitDocumentText -Document $doc -Element info -Text ('{0} {1} {2}' -f $name, [char]0x00B7, $info.node)
        Update-Tree
    }

    function Move-CurrentUp {
        if ($null -eq $explorer.Current) { return }
        $previous = (Get-Info $explorer.Current).previous
        # Skip whitespace text nodes; move before the previous ELEMENT sibling.
        while ($previous -and (Get-Info (Get-Ref $previous)).type -ne 'element') { $previous = (Get-Info (Get-Ref $previous)).previous }
        if ($previous) {
            Invoke-NativeHTMLKitNodeOperation -Node $explorer.Current -Operation move_element -Parameters @{ target_node = (Get-Ref $previous); position = 'beforebegin' }
            Update-Tree
        }
    }

    # Uppercase an element whose only child is text (set_text replaces ALL children).
    function Set-CurrentUppercase {
        if ($null -eq $explorer.Current -or (Get-Info $explorer.Current).type -ne 'element') { return }
        $children = @((Get-NativeHTMLKitNodeChildren -Node $explorer.Current).children)
        if ($children.Count -eq 1 -and $children[0].type -eq 'text') {
            $text = (Get-Info (Get-Ref $children[0].node)).text
            Invoke-NativeHTMLKitNodeOperation -Node $explorer.Current -Operation set_text -Parameters @{ text = ([string]$text).ToUpperInvariant() }
            Update-Tree
        }
    }

    function Remove-Current {
        if ($null -eq $explorer.Current) { return }
        Invoke-NativeHTMLKitNodeOperation -Node $explorer.Current -Operation remove_element
        $explorer.Current = $null
        Set-NativeHTMLKitDocumentText -Document $doc -Element info -Text 'Deleted'
        Update-Tree
    }

    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element tree -Callback {
        param($evt)
        if ($evt.element -match '^item-(\d+)$') { Select-TreeItem ([int]$Matches[1]) }
    }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element up -Callback { Move-CurrentUp }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element shout -Callback { Set-CurrentUppercase }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element delete -Callback { Remove-Current }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element reset -Callback { Reset-Sample }

    Reset-Sample
    Set-NativeHTMLKitReady -Application $app

    if ($SelfTest) {
        function Find-Item([string]$Tag, [string]$Text) {
            for ($i = 0; $i -lt $explorer.Items.Count; $i++) {
                $info = Get-Info $explorer.Items[$i]
                if ($info.name -eq $Tag -and (Get-NativeHTMLKitDocumentText -Document $doc -Element "item-$i") -eq "<$Tag>") {
                    if (-not $Text) { return $i }
                    $first = @((Get-NativeHTMLKitNodeChildren -Node $explorer.Items[$i]).children)[0]
                    if ($first -and (Get-Info (Get-Ref $first.node)).text -eq $Text) { return $i }
                }
            }
            throw "no tree item <$Tag> $Text"
        }
        # The text of every <li>: get_html accepts a node reference; strip the tags.
        function Get-ListText { return @((Get-NativeHTMLKitNodes -Document $doc -Selector '#sample li').nodes | ForEach-Object {
            (Invoke-NativeHTMLKitDocumentCommand -Document $doc -Operation get_html -Parameters @{ node = $_.node }).html -replace '<[^>]*>', '' }) -join '|' }
        # article, h2, "Release notes", p, "Elements...", em, "no", "id attributes.", ul, 3 x (li + text) + code + "dialog" + " support", blockquote, text
        if ($explorer.Items.Count -lt 18) { throw "tree has only $($explorer.Items.Count) rows" }
        Select-TreeItem (Find-Item 'li' 'Smaller binaries')
        if ((Find-NativeHTMLKitElement -Document $doc -Selector '#sample .highlight').matched_nodes -ne 1) { throw 'highlight missing' }
        if ((Find-NativeHTMLKitElement -Document $doc -Selector '#tree .current').matched_nodes -ne 1) { throw 'current tree row missing' }
        Move-CurrentUp
        if ((Get-ListText) -ne 'Smaller binaries|Faster layout|Better dialog support') { throw "move failed: $(Get-ListText)" }
        Set-CurrentUppercase
        if ((Get-ListText) -ne 'SMALLER BINARIES|Faster layout|Better dialog support') { throw "uppercase failed: $(Get-ListText)" }
        $removed = $explorer.Current
        Remove-Current
        if ((Get-ListText) -ne 'Faster layout|Better dialog support') { throw "delete failed: $(Get-ListText)" }
        $stale = $false
        try { $null = Get-Info $removed } catch { $stale = $true }
        if (-not $stale) { throw 'a removed node should be stale' }
        Reset-Sample
        if ((Get-ListText) -ne 'Faster layout|Smaller binaries|Better dialog support') { throw 'reset failed' }
        [Console]::Out.WriteLine('SELFTEST PASS 16-dom-explorer')
        $null = Request-NativeHTMLKitQuit -Application $app
    }

    Wait-NativeHTMLKit -Application $app -UntilShutdown
} finally {
    Close-NativeHTMLKit -Application $app
}
