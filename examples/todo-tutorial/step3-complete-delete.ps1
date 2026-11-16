# Todo tutorial, step 3: complete and delete items with one delegated handler.
#
# Teaches: element ids that carry the item number and the action (todo-7-delete), one handler on
# the list for events from all its descendants (delegation), the `checked` field of a checkbox's
# `change` event, and state shared by callbacks through one hashtable.
# Run:   pwsh -File ./step3-complete-delete.ps1   (Windows PowerShell 5.1: powershell.exe -File .\step3-complete-delete.ps1)
# Guide: docs/tutorials/todo-app.md (step 3 of 5)
$ErrorActionPreference = 'Stop'
Import-Module NativeHTMLKit

$page = @'
<!doctype html>
<html><head><meta charset="utf-8"><style>
  body { margin:0; background:#f6f7fb; color:#1d2433; font:15px/1.4 sans-serif; }
  main { max-width:560px; margin:32px auto; padding:0 20px; }
  form { display:flex; gap:8px; }
  input[type=text] { flex:1; padding:9px 10px; border:1px solid #e3e6ee; border-radius:6px; }
  button { padding:8px 12px; border:0; border-radius:6px; background:#3a6ff7; color:#fff; }
  button.plain { background:transparent; color:#6b7385; }
  ul { list-style:none; padding:0; background:#fff; border-radius:8px; }
  li { display:flex; align-items:center; gap:10px; padding:10px 12px; border-bottom:1px solid #e3e6ee; }
  li .text { flex:1; }
  li.done .text { text-decoration:line-through; color:#6b7385; }
</style></head>
<body><main>
  <h1>Todo</h1>
  <form id="new-form">
    <input id="new-title" type="text" placeholder="What needs doing?" required>
    <button id="add" type="submit">Add</button>
  </form>
  <ul id="todos"></ul>
  <p id="count">0 items left</p>
</main></body></html>
'@

$app = Start-NativeHTMLKitScript -Name 'Todo'
try {
    $window = New-NativeHTMLKitWindow -Application $app -Title 'Todo' -Width 640 -Height 480
    $doc = Open-NativeHTMLKitHtml -Window $window -Html $page
    # Callbacks change entries of this hashtable; assigning $x = ... in a callback would only
    # create a local variable.
    $state = @{ Todos = New-Object System.Collections.ArrayList; NextId = 1 }

    function Get-TodoRow($Todo) {
        $n = $Todo.Id; $class = ''; $checked = ''
        if ($Todo.Done) { $class = 'done'; $checked = ' checked' }
        return ('<li id="todo-{0}" class="{1}"><input id="todo-{0}-done" type="checkbox"{2}>' -f $n, $class, $checked) +
            ('<span class="text">{0}</span><button id="todo-{1}-delete" class="plain">Delete</button></li>' -f [Net.WebUtility]::HtmlEncode($Todo.Title), $n)
    }

    function Update-Todos {
        Set-NativeHTMLKitDocumentHtml -Document $doc -Element todos -Html (($state.Todos | ForEach-Object { Get-TodoRow $_ }) -join '')
        $left = @($state.Todos | Where-Object { -not $_.Done }).Count
        Set-NativeHTMLKitDocumentText -Document $doc -Element count -Text "$left items left"
    }

    function Find-Todo([int]$Id) { return @($state.Todos | Where-Object { $_.Id -eq $Id })[0] }

    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type submit -Element new-form -Callback {
        $title = (Get-NativeHTMLKitValue -Document $doc -Element new-title).Trim()
        if ($title) {
            [void]$state.Todos.Add(@{ Id = $state.NextId; Title = $title; Done = $false })
            $state.NextId++
            Set-NativeHTMLKitDocumentValue -Document $doc -Element new-title -Value ''
            Update-Todos
        }
    }
    # -Element todos also matches events whose target is INSIDE the list: the event's path lists
    # every identified ancestor, and $evt.element is the nearest one.
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type change -Element todos -Callback {
        param($evt)
        if ($evt.element -match '^todo-(\d+)-done$') {
            (Find-Todo ([int]$Matches[1])).Done = [bool]$evt.checked
            Update-Todos
        }
    }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element todos -Callback {
        param($evt)
        if ($evt.element -match '^todo-(\d+)-delete$') {
            $state.Todos.Remove((Find-Todo ([int]$Matches[1])))
            Update-Todos
        }
    }

    Set-NativeHTMLKitReady -Application $app
    Wait-NativeHTMLKit -Application $app -UntilShutdown
} finally {
    Close-NativeHTMLKit -Application $app
}
