# Todo tutorial, step 1: a native window that shows HTML and CSS.
#
# Teaches: Start-NativeHTMLKitScript (the host runs this script a second time as its backend),
# New-NativeHTMLKitWindow, Open-NativeHTMLKitHtml, Set-NativeHTMLKitReady, Wait-NativeHTMLKit.
# Run:   pwsh -File ./step1-window.ps1      (Windows PowerShell 5.1: powershell.exe -File .\step1-window.ps1)
# Guide: docs/tutorials/todo-app.md (step 1 of 5)
$ErrorActionPreference = 'Stop'
Import-Module NativeHTMLKit

$page = @'
<!doctype html>
<html><head><meta charset="utf-8"><style>
  body { margin:0; background:#f6f7fb; color:#1d2433; font:15px/1.4 sans-serif; }
  main { max-width:560px; margin:32px auto; padding:0 20px; }
  ul { list-style:none; padding:0; background:#fff; border-radius:8px; }
  li { padding:10px 12px; border-bottom:1px solid #e3e6ee; }
</style></head>
<body><main>
  <h1>Todo</h1>
  <ul id="todos"><li>Learn NativeHTMLKit</li><li>Build an app</li></ul>
</main></body></html>
'@

$app = Start-NativeHTMLKitScript -Name 'Todo'
try {
    $window = New-NativeHTMLKitWindow -Application $app -Title 'Todo' -Width 640 -Height 480
    $doc = Open-NativeHTMLKitHtml -Window $window -Html $page
    Set-NativeHTMLKitReady -Application $app
    Wait-NativeHTMLKit -Application $app -UntilShutdown     # returns when the user closes the window
} finally {
    Close-NativeHTMLKit -Application $app
}
