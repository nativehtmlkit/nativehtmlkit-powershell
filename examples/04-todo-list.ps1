# 04-todo-list.ps1 - a todo list with add, complete, delete, filter and clear-completed.
#
# Teaches: keeping the model in PowerShell and rendering it as HTML, HTML-encoding every
# untrusted string ([Net.WebUtility]::HtmlEncode), one delegated click handler for a list
# whose items change (the event's element id identifies the row and the action), and a
# form submit (Enter key) as the "add" action.
#
# Run:  pwsh -File ./04-todo-list.ps1     (or powershell.exe -NoProfile -File .\04-todo-list.ps1)
# -SelfTest drives the app through the public API and quits.
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Import-Module NativeHTMLKit

$app = Start-NativeHTMLKitScript -Name 'Todo list'
try {
    $window = New-NativeHTMLKitWindow -Application $app -Title 'Todo' -Width 520 -Height 560
    $doc = Open-NativeHTMLKitHtml -Window $window -Html @'
<!doctype html>
<html><head><style>
  body { font-family: system-ui, sans-serif; margin: 24px; }
  form { display: flex; gap: 8px; }
  #title { flex: 1; padding: 6px 8px; font-size: 15px; }
  ul { list-style: none; padding: 0; }
  li { display: flex; align-items: center; gap: 8px; padding: 6px 0; border-bottom: 1px solid #ddd; }
  li span { flex: 1; }
  li.done span { text-decoration: line-through; color: #777; }
  .filters button.active { font-weight: 700; }
  footer { display: flex; justify-content: space-between; align-items: center; color: #555; }
</style></head>
<body>
  <form id="add-form"><input id="title" placeholder="What needs doing?" required maxlength="200"><button type="submit">Add</button></form>
  <ul id="todos"></ul>
  <footer>
    <span id="left">0 items left</span>
    <span class="filters" id="filters"><button id="show-all" class="active">All</button><button id="show-active">Active</button><button id="show-done">Done</button></span>
    <button id="clear-done">Clear completed</button>
  </footer>
</body></html>
'@

    $script:todos = New-Object System.Collections.ArrayList   # @{ Id; Title; Done }
    $script:nextId = 1
    $script:filter = 'all'

    function Update-TodoView {
        $rows = New-Object System.Text.StringBuilder
        foreach ($todo in $script:todos) {
            if ($script:filter -eq 'active' -and $todo.Done) { continue }
            if ($script:filter -eq 'done' -and -not $todo.Done) { continue }
            $class = ''; $checked = ''
            if ($todo.Done) { $class = ' class="done"'; $checked = ' checked' }
            $title = [Net.WebUtility]::HtmlEncode($todo.Title)   # never trust item text
            [void]$rows.Append("<li id=`"todo-$($todo.Id)`"$class><input type=`"checkbox`" id=`"todo-$($todo.Id)-toggle`" aria-label=`"Done`"$checked><span>$title</span><button id=`"todo-$($todo.Id)-delete`" aria-label=`"Delete`">x</button></li>")
        }
        Set-NativeHTMLKitDocumentHtml -Document $doc -Element todos -Html $rows.ToString()
        $left = @($script:todos | Where-Object { -not $_.Done }).Count
        $noun = 'items'
        if ($left -eq 1) { $noun = 'item' }
        Set-NativeHTMLKitDocumentText -Document $doc -Element left -Text "$left $noun left"
    }

    function Add-Todo([string]$Title) {
        $Title = $Title.Trim()
        if (-not $Title) { return }
        [void]$script:todos.Add(@{ Id = $script:nextId; Title = $Title; Done = $false })
        $script:nextId++
        Update-TodoView
    }

    function Find-Todo([int]$Id) { return @($script:todos | Where-Object { $_.Id -eq $Id })[0] }

    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type submit -Element add-form -Callback {
        Add-Todo (Get-NativeHTMLKitValue -Document $doc -Element title)
        Set-NativeHTMLKitDocumentValue -Document $doc -Element title -Value ''
        Set-NativeHTMLKitFocus -Document $doc -Element title
    }

    # Rows are replaced on every render, so the handler sits on the stable <ul> and
    # reads the clicked element's id: todo-<n>-toggle or todo-<n>-delete.
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element todos -Callback {
        param($evt)
        if ($evt.element -notmatch '^todo-(\d+)-(toggle|delete)$') { return }
        $todo = Find-Todo ([int]$Matches[1])
        if ($null -eq $todo) { return }
        if ($Matches[2] -eq 'delete') { $script:todos.Remove($todo) }
        else { $todo.Done = Get-NativeHTMLKitChecked -Document $doc -Element $evt.element }
        Update-TodoView
    }

    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element filters -Callback {
        param($evt)
        if ($evt.element -notmatch '^show-(all|active|done)$') { return }
        $script:filter = $Matches[1]
        foreach ($name in 'all', 'active', 'done') { Set-NativeHTMLKitClass -Document $doc -Element "show-$name" -Name active -Remove:($name -ne $script:filter) }
        Update-TodoView
    }

    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element clear-done -Callback {
        foreach ($todo in @($script:todos | Where-Object { $_.Done })) { $script:todos.Remove($todo) }
        Update-TodoView
    }

    Set-NativeHTMLKitReady -Application $app

    if ($SelfTest) {
        function Wait-Events { for ($i = 0; $i -lt 10; $i++) { $null = Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 30 } }
        foreach ($title in 'Patch the file server', 'Rotate <backup> keys & certs', 'Review firewall rules') {
            Set-NativeHTMLKitDocumentValue -Document $doc -Element title -Value $title
            $null = Submit-NativeHTMLKitForm -Document $doc -Form add-form
            Wait-Events
        }
        if ((Find-NativeHTMLKitElement -Document $doc -Selector '#todos li').matched_nodes -ne 3) { throw 'expected 3 rows' }
        $text = Get-NativeHTMLKitDocumentText -Document $doc -Element todo-2
        if ($text -ne 'Rotate <backup> keys & certs' + 'x') { throw "item text was not escaped as text: $text" }
        (Find-Todo 2).Done = $true
        Update-TodoView
        if ((Get-NativeHTMLKitDocumentText -Document $doc -Element left) -ne '2 items left') { throw 'wrong count' }
        $script:filter = 'done'; Update-TodoView
        if ((Find-NativeHTMLKitElement -Document $doc -Selector '#todos li.done').matched_nodes -ne 1) { throw 'done filter failed' }
        $script:filter = 'all'
        foreach ($todo in @($script:todos | Where-Object { $_.Done })) { $script:todos.Remove($todo) }
        Update-TodoView
        if ((Find-NativeHTMLKitElement -Document $doc -Selector '#todos li').matched_nodes -ne 2) { throw 'clear completed failed' }
        [Console]::Out.WriteLine('SELFTEST PASS 04-todo-list')
        $null = Request-NativeHTMLKitQuit -Application $app
    }

    Wait-NativeHTMLKit -Application $app -UntilShutdown
} finally {
    Close-NativeHTMLKit -Application $app
}
