# 04-todo-list.ps1 - a todo list: add, edit, complete and delete tasks, saved to a JSON file.
#
# Teaches: form `submit` events (the Add button, or Enter in the text field, submits the form),
# one delegated handler for a whole list (-Element todos matches every descendant), HTML-encoding
# user text ([Net.WebUtility]::HtmlEncode) before Set-NativeHTMLKitDocumentHtml, keyboard handling
# (Escape cancels an edit) and in-place editing, and persistence: an atomic JSON write into the
# per-application data folder reported by the host (desktop.paths).
# This is the finished app of the tutorial in docs/tutorials/todo-app.md.
#
# Run:  pwsh -File ./04-todo-list.ps1 [-DataPath todos.json]
#       powershell.exe -NoProfile -File .\04-todo-list.ps1
# Data: <per-user data folder>/todos.json (printed at start-up).
# -SelfTest drives the app through the public API with a temporary data file and quits.
param([string]$DataPath, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Import-Module NativeHTMLKit

$app = Start-NativeHTMLKitScript -Name 'Todo' -AppId 'org.nativehtmlkit.examples.powershell.todo'
try {
    if ($SelfTest -and -not $DataPath) { $DataPath = Join-Path ([IO.Path]::GetTempPath()) ('nhk-todo-' + [guid]::NewGuid().ToString('N') + '.json') }
    if (-not $DataPath) {
        # desktop.paths is a public Core v1 method: per-application config/data/cache folders.
        $DataPath = Join-Path (Invoke-NativeHTMLKitRpc -Application $app -Method 'desktop.paths').data 'todos.json'
        [Console]::Out.WriteLine("Saving todos to $DataPath")
    }
    $window = New-NativeHTMLKitWindow -Application $app -Title 'Todo' -Width 640 -Height 620 -MinWidth 420 -MinHeight 360
    $doc = Open-NativeHTMLKitHtml -Window $window -Html @'
<!doctype html>
<html><head><meta charset="utf-8"><style>
  :root { --bg:#f6f7fb; --card:#fff; --text:#1d2433; --muted:#6b7385; --accent:#3a6ff7; --line:#e3e6ee; }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#141923; --card:#1d2433; --text:#e8ecf5; --muted:#9aa3b5; --accent:#7aa2ff; --line:#2d3546; }
  }
  body { margin:0; background:var(--bg); color:var(--text); font:15px/1.4 sans-serif; }
  main { max-width:560px; margin:32px auto; padding:0 20px; }
  h1 { font-size:28px; margin:0 0 16px; }
  form { display:flex; gap:8px; }
  input[type=text] { flex:1; padding:9px 10px; border:1px solid var(--line); border-radius:6px;
                     background:var(--card); color:var(--text); }
  button { padding:8px 12px; border:0; border-radius:6px; background:var(--accent); color:#fff; cursor:pointer; }
  button.plain { background:transparent; color:var(--muted); padding:4px 8px; }
  ul { list-style:none; padding:0; margin:16px 0; background:var(--card); border-radius:8px; }
  li { display:flex; align-items:center; gap:10px; padding:10px 12px; border-bottom:1px solid var(--line); }
  li:last-child { border-bottom:0; }
  li .text { flex:1; }
  li.done .text { text-decoration:line-through; color:var(--muted); }
  li form { flex:1; }
  .empty { color:var(--muted); padding:16px 12px; }
  footer { display:flex; justify-content:space-between; align-items:center; color:var(--muted); }
  nav button { background:transparent; color:var(--muted); }
  nav button.active { color:var(--accent); font-weight:bold; }
</style></head>
<body><main>
  <h1>Todo</h1>
  <form id="new-form">
    <input id="new-title" type="text" placeholder="What needs doing?" required maxlength="200">
    <button id="add" type="submit">Add</button>
  </form>
  <ul id="todos"></ul>
  <footer>
    <span id="count">0 items left</span>
    <nav id="filters">
      <button id="filter-all" class="active">All</button>
      <button id="filter-active">Active</button>
      <button id="filter-done">Completed</button>
    </nav>
    <button id="clear-done" class="plain">Clear completed</button>
  </footer>
</main></body></html>
'@

    # Read saved todos; a missing or unreadable file starts an empty list.
    function Read-Todos([string]$Path) {
        $list = New-Object System.Collections.ArrayList
        try { $data = @([IO.File]::ReadAllText($Path) | ConvertFrom-Json) } catch { return , $list }
        foreach ($x in $data) {
            if ($null -ne $x.id -and $null -ne $x.title -and $null -ne $x.done) {
                [void]$list.Add(@{ Id = [int]$x.id; Title = [string]$x.title; Done = [bool]$x.done })
            }
        }
        return , $list
    }

    # Write atomically: a crash mid-write never leaves a truncated file.
    function Save-Todos([string]$Path, $Todos) {
        $folder = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder }
        $json = ConvertTo-Json -InputObject @($Todos | ForEach-Object { [ordered]@{ id = $_.Id; title = $_.Title; done = $_.Done } })
        $temporary = $Path + '.tmp'
        [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) } else { [IO.File]::Move($temporary, $Path) }
    }

    $state = @{ Todos = (Read-Todos $DataPath); NextId = 1; Filter = 'all'; Editing = $null }
    if ($state.Todos.Count -gt 0) { $state.NextId = ($state.Todos | ForEach-Object { $_.Id } | Measure-Object -Maximum).Maximum + 1 }

    function Test-Visible($Todo) {
        switch ($state.Filter) { 'active' { return -not $Todo.Done } 'done' { return $Todo.Done } default { return $true } }
    }

    function Get-TodoRow($Todo) {
        $n = $Todo.Id
        $title = [Net.WebUtility]::HtmlEncode($Todo.Title)    # user text is never trusted markup
        if ($n -eq $state.Editing) {
            return ('<li id="todo-{0}"><form id="edit-form-{0}"><input id="edit-title" type="text" value="{1}" maxlength="200"></form>' -f $n, $title) +
                ('<button id="todo-{0}-cancel" class="plain">Cancel</button></li>' -f $n)
        }
        $class = ''; $checked = ''
        if ($Todo.Done) { $class = 'done'; $checked = ' checked' }
        return ('<li id="todo-{0}" class="{1}"><input id="todo-{0}-done" type="checkbox"{2}>' -f $n, $class, $checked) +
            ('<span id="todo-{0}-text" class="text">{1}</span>' -f $n, $title) +
            ('<button id="todo-{0}-edit" class="plain">Edit</button><button id="todo-{0}-delete" class="plain">Delete</button></li>' -f $n)
    }

    function Update-Todos {
        $rows = @($state.Todos | Where-Object { Test-Visible $_ } | ForEach-Object { Get-TodoRow $_ })
        if ($rows.Count -eq 0) { $rows = @('<li class="empty">Nothing here.</li>') }
        $left = @($state.Todos | Where-Object { -not $_.Done }).Count
        $noun = 'items'
        if ($left -eq 1) { $noun = 'item' }
        Set-NativeHTMLKitDocumentHtml -Document $doc -Element todos -Html ($rows -join '')
        Set-NativeHTMLKitDocumentText -Document $doc -Element count -Text "$left $noun left"
    }

    function Complete-Change { Save-Todos $DataPath $state.Todos; Update-Todos }
    function Find-Todo([int]$Id) { return @($state.Todos | Where-Object { $_.Id -eq $Id })[0] }

    # ----- actions (the event handlers only translate events into these calls) -----
    function Add-Todo([string]$Title) {
        $Title = $Title.Trim()
        if (-not $Title) { return }
        [void]$state.Todos.Add(@{ Id = $state.NextId; Title = $Title; Done = $false })
        $state.NextId++
        Complete-Change
    }
    function Set-TodoDone([int]$Id, [bool]$Done) { (Find-Todo $Id).Done = $Done; Complete-Change }
    function Rename-Todo([int]$Id, [string]$Title) {
        $state.Editing = $null
        if ($Title.Trim()) { (Find-Todo $Id).Title = $Title.Trim() }
        Complete-Change
    }
    function Remove-Todo([int]$Id) { $state.Todos.Remove((Find-Todo $Id)); Complete-Change }
    function Clear-DoneTodos {
        foreach ($todo in @($state.Todos | Where-Object { $_.Done })) { $state.Todos.Remove($todo) }
        Complete-Change
    }
    function Set-TodoFilter([string]$Name) {
        $state.Filter = $Name
        foreach ($key in 'all', 'active', 'done') { Set-NativeHTMLKitClass -Document $doc -Element "filter-$key" -Name active -Remove:($key -ne $Name) }
        Update-Todos
    }
    function Start-TodoEdit([int]$Id) {
        $state.Editing = $Id
        Update-Todos
        Set-NativeHTMLKitFocus -Document $doc -Element edit-title
    }
    function Stop-TodoEdit { $state.Editing = $null; Update-Todos }

    # ----- event handlers -----
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type submit -Callback {    # new-form and the inline edit form
        param($evt)
        if ($evt.element -eq 'new-form') {
            Add-Todo (Get-NativeHTMLKitValue -Document $doc -Element new-title)
            Set-NativeHTMLKitDocumentValue -Document $doc -Element new-title -Value ''
        } elseif ($evt.element -match '^edit-form-(\d+)$') {
            Rename-Todo ([int]$Matches[1]) (Get-NativeHTMLKitValue -Document $doc -Element edit-title)
        }
    }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type change -Element todos -Callback {   # checkboxes inside the list
        param($evt)
        if ($evt.element -match '^todo-(\d+)-done$') { Set-TodoDone ([int]$Matches[1]) ([bool]$evt.checked) }
    }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element todos -Callback {
        param($evt)
        if ($evt.element -notmatch '^todo-(\d+)-(edit|delete|cancel)$') { return }
        switch ($Matches[2]) {
            'edit' { Start-TodoEdit ([int]$Matches[1]) }
            'delete' { Remove-Todo ([int]$Matches[1]) }
            'cancel' { Stop-TodoEdit }
        }
    }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type keydown -Element todos -Callback {
        param($evt)
        if ($evt.key -eq 'Escape' -and $null -ne $state.Editing) { Stop-TodoEdit }
    }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element filters -Callback {
        param($evt)
        if ($evt.element -match '^filter-(all|active|done)$') { Set-TodoFilter $Matches[1] }
    }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element clear-done -Callback { Clear-DoneTodos }

    Update-Todos
    Set-NativeHTMLKitReady -Application $app

    if ($SelfTest) {
        function Wait-Events { for ($i = 0; $i -lt 10; $i++) { $null = Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 30 } }
        function Get-Count([string]$Selector) { return (Find-NativeHTMLKitElement -Document $doc -Selector $Selector).matched_nodes }
        if ((Get-NativeHTMLKitDocumentText -Document $doc -Element todos) -ne 'Nothing here.') { throw 'empty state missing' }
        foreach ($title in 'Patch the file server', 'Rotate <backup> keys & certs', 'Review firewall rules') {
            Set-NativeHTMLKitDocumentValue -Document $doc -Element new-title -Value $title
            $null = Submit-NativeHTMLKitForm -Document $doc -Form new-form
            Wait-Events
        }
        if ((Get-Count '#todos li[id]') -ne 3) { throw 'expected 3 rows' }
        $text = Get-NativeHTMLKitDocumentText -Document $doc -Element todo-2-text
        if ($text -ne 'Rotate <backup> keys & certs') { throw "item text was not escaped as text: $text" }
        Set-TodoDone 2 $true
        if ((Get-NativeHTMLKitDocumentText -Document $doc -Element count) -ne '2 items left') { throw 'wrong count' }
        Start-TodoEdit 1
        if ((Get-NativeHTMLKitFocusedElement -Document $doc).element -ne 'edit-title') { throw 'the edit field is not focused' }
        Set-NativeHTMLKitDocumentValue -Document $doc -Element edit-title -Value 'Patch "all" servers'
        $null = Submit-NativeHTMLKitForm -Document $doc -Form edit-form-1
        Wait-Events
        if ((Get-NativeHTMLKitDocumentText -Document $doc -Element todo-1-text) -ne 'Patch "all" servers') { throw 'rename failed' }
        Set-TodoFilter 'done'
        if ((Get-Count '#todos li[id]') -ne 1 -or (Get-Count '#filter-done.active') -ne 1) { throw 'done filter failed' }
        Set-TodoFilter 'all'
        Clear-DoneTodos
        Remove-Todo 3
        if ((Get-NativeHTMLKitDocumentText -Document $doc -Element count) -ne '1 item left') { throw 'wrong count after delete' }
        $saved = Read-Todos $DataPath
        if ($saved.Count -ne 1 -or $saved[0].Title -ne 'Patch "all" servers') { throw 'the JSON file does not match' }
        Remove-Item -LiteralPath $DataPath
        [Console]::Out.WriteLine('SELFTEST PASS 04-todo-list')
        $null = Request-NativeHTMLKitQuit -Application $app
    }

    Wait-NativeHTMLKit -Application $app -UntilShutdown
} finally {
    Close-NativeHTMLKit -Application $app
}
