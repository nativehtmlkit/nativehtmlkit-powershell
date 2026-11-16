# Todo tutorial, step 4: edit in place, with the keyboard.
#
# Teaches: one `submit` handler for two forms (the event's element says which), an inline edit
# form, moving the keyboard focus with Set-NativeHTMLKitFocus, and the `keydown` event (Escape
# cancels the edit).
# Run:   pwsh -File ./step4-edit-keyboard.ps1   (Windows PowerShell 5.1: powershell.exe -File .\step4-edit-keyboard.ps1)
# Guide: docs/tutorials/todo-app.md (step 4 of 5). Step 5 (persistence and styling) is ../04-todo-list.ps1.
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
  li form { flex:1; }
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
    $state = @{ Todos = New-Object System.Collections.ArrayList; NextId = 1; Editing = $null }

    function Get-TodoRow($Todo) {
        $n = $Todo.Id
        $title = [Net.WebUtility]::HtmlEncode($Todo.Title)    # also escapes quotes for value="..."
        if ($n -eq $state.Editing) {
            # Enter in this field submits its form; Escape is handled by the keydown handler.
            return '<li id="todo-{0}"><form id="edit-form-{0}"><input id="edit-title" type="text" value="{1}"></form></li>' -f $n, $title
        }
        $class = ''; $checked = ''
        if ($Todo.Done) { $class = 'done'; $checked = ' checked' }
        return ('<li id="todo-{0}" class="{1}"><input id="todo-{0}-done" type="checkbox"{2}>' -f $n, $class, $checked) +
            ('<span class="text">{0}</span><button id="todo-{1}-edit" class="plain">Edit</button>' -f $title, $n) +
            ('<button id="todo-{0}-delete" class="plain">Delete</button></li>' -f $n)
    }

    function Update-Todos {
        Set-NativeHTMLKitDocumentHtml -Document $doc -Element todos -Html (($state.Todos | ForEach-Object { Get-TodoRow $_ }) -join '')
        $left = @($state.Todos | Where-Object { -not $_.Done }).Count
        Set-NativeHTMLKitDocumentText -Document $doc -Element count -Text "$left items left"
    }

    function Find-Todo([int]$Id) { return @($state.Todos | Where-Object { $_.Id -eq $Id })[0] }

    # Without -Element: every form in the document. $evt.element names the submitted form.
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type submit -Callback {
        param($evt)
        if ($evt.element -eq 'new-form') {
            $title = (Get-NativeHTMLKitValue -Document $doc -Element new-title).Trim()
            if ($title) {
                [void]$state.Todos.Add(@{ Id = $state.NextId; Title = $title; Done = $false })
                $state.NextId++
                Set-NativeHTMLKitDocumentValue -Document $doc -Element new-title -Value ''
            }
        } elseif ($evt.element -like 'edit-form-*') {
            $title = (Get-NativeHTMLKitValue -Document $doc -Element edit-title).Trim()
            if ($title) { (Find-Todo $state.Editing).Title = $title }
            $state.Editing = $null
        }
        Update-Todos
    }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type change -Element todos -Callback {
        param($evt)
        if ($evt.element -match '^todo-(\d+)-done$') {
            (Find-Todo ([int]$Matches[1])).Done = [bool]$evt.checked
            Update-Todos
        }
    }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element todos -Callback {
        param($evt)
        if ($evt.element -notmatch '^todo-(\d+)-(edit|delete)$') { return }
        $id = [int]$Matches[1]
        if ($Matches[2] -eq 'delete') {
            $state.Todos.Remove((Find-Todo $id))
            Update-Todos
        } else {
            $state.Editing = $id
            Update-Todos
            Set-NativeHTMLKitFocus -Document $doc -Element edit-title
        }
    }
    # keydown events carry `key` (for example "Enter", "Escape", "a") and modifier flags.
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type keydown -Element todos -Callback {
        param($evt)
        if ($evt.key -eq 'Escape' -and $null -ne $state.Editing) {
            $state.Editing = $null
            Update-Todos
        }
    }

    Set-NativeHTMLKitReady -Application $app
    Wait-NativeHTMLKit -Application $app -UntilShutdown
} finally {
    Close-NativeHTMLKit -Application $app
}
