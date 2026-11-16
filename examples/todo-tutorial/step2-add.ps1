# Todo tutorial, step 2: add items with a form and keep user text safe.
#
# Teaches: the form `submit` event, Get-NativeHTMLKitValue / Set-NativeHTMLKitDocumentValue,
# rendering a list with Set-NativeHTMLKitDocumentHtml and [Net.WebUtility]::HtmlEncode,
# Set-NativeHTMLKitDocumentText (never parses markup).
# Run:   pwsh -File ./step2-add.ps1      (Windows PowerShell 5.1: powershell.exe -File .\step2-add.ps1)
# Guide: docs/tutorials/todo-app.md (step 2 of 5)
$ErrorActionPreference = 'Stop'
Import-Module NativeHTMLKit

$page = @'
<!doctype html>
<html><head><meta charset="utf-8"><style>
  body { margin:0; background:#f6f7fb; color:#1d2433; font:15px/1.4 sans-serif; }
  main { max-width:560px; margin:32px auto; padding:0 20px; }
  form { display:flex; gap:8px; }
  input { flex:1; padding:9px 10px; border:1px solid #e3e6ee; border-radius:6px; }
  button { padding:8px 12px; border:0; border-radius:6px; background:#3a6ff7; color:#fff; }
  ul { list-style:none; padding:0; background:#fff; border-radius:8px; }
  li { padding:10px 12px; border-bottom:1px solid #e3e6ee; }
</style></head>
<body><main>
  <h1>Todo</h1>
  <form id="new-form">
    <input id="new-title" type="text" placeholder="What needs doing?" required>
    <button id="add" type="submit">Add</button>
  </form>
  <ul id="todos"></ul>
  <p id="count">0 items</p>
</main></body></html>
'@

$app = Start-NativeHTMLKitScript -Name 'Todo'
try {
    $window = New-NativeHTMLKitWindow -Application $app -Title 'Todo' -Width 640 -Height 480
    $doc = Open-NativeHTMLKitHtml -Window $window -Html $page
    $titles = New-Object System.Collections.Generic.List[string]

    function Update-Todos {
        # HtmlEncode: a title such as "<b>" is shown as text, never parsed as markup.
        $html = ($titles | ForEach-Object { '<li>' + [Net.WebUtility]::HtmlEncode($_) + '</li>' }) -join ''
        Set-NativeHTMLKitDocumentHtml -Document $doc -Element todos -Html $html
        Set-NativeHTMLKitDocumentText -Document $doc -Element count -Text "$($titles.Count) items"   # never parses markup
    }

    # Clicking Add, or pressing Enter in the field, submits the form.
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type submit -Element new-form -Callback {
        $title = (Get-NativeHTMLKitValue -Document $doc -Element new-title).Trim()
        if ($title) {
            $titles.Add($title)
            Set-NativeHTMLKitDocumentValue -Document $doc -Element new-title -Value ''
            Update-Todos
        }
    }

    Set-NativeHTMLKitReady -Application $app
    Wait-NativeHTMLKit -Application $app -UntilShutdown
} finally {
    Close-NativeHTMLKit -Application $app
}
