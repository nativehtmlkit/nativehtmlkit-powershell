# 08-multi-window.ps1 - a notes app: one main window that lists notes, one window per note.
#
# Teaches: several windows each with its own document and handlers, per-window state in a
# hashtable, callbacks created inside a function with .GetNewClosure() (and why $script:
# must not be used inside such closures), a close policy that vetoes closing a note with
# unsaved changes (Set-NativeHTMLKitBeforeClose), window.event notifications for windows the
# user closed, and Get-NativeHTMLKitWindowList.
#
# Run:  pwsh -File ./08-multi-window.ps1     (or powershell.exe -NoProfile -File .\08-multi-window.ps1)
# -SelfTest opens, edits and closes note windows through the public API and quits.
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Import-Module NativeHTMLKit

$app = Start-NativeHTMLKitScript -Name 'Notes' -MaxWindows 12
try {
    $main = New-NativeHTMLKitWindow -Application $app -Title 'Notes' -Width 420 -Height 480
    $mainDoc = Open-NativeHTMLKitHtml -Window $main -Html @'
<!doctype html>
<html><head><style>
  body { font-family: system-ui, sans-serif; margin: 20px; }
  ul { padding-left: 18px; } li { margin: 4px 0; }
  .muted { color: #666; font-size: 13px; }
</style></head>
<body>
  <button id="new">New note</button>
  <h2>Open notes</h2>
  <ul id="notes"></ul>
  <p class="muted" id="count"></p>
</body></html>
'@

    # One shared, mutable state object. Closures capture the reference, so every window's
    # callbacks see the same notes; $script: variables would NOT work inside .GetNewClosure().
    $state = @{ Notes = @{}; Next = 1; App = $app; MainDoc = $mainDoc }

    function Update-NoteList {
        param($State)
        $html = New-Object System.Text.StringBuilder
        foreach ($note in @($State.Notes.Values | Sort-Object Number)) {
            $flag = ''
            if ($note.Dirty) { $flag = ' (unsaved)' }
            [void]$html.Append('<li>' + [Net.WebUtility]::HtmlEncode("Note $($note.Number): $($note.Title)$flag") + '</li>')
        }
        Set-NativeHTMLKitDocumentHtml -Document $State.MainDoc -Element notes -Html $html.ToString()
        $windows = Get-NativeHTMLKitWindowList -Application $State.App   # one array object
        Set-NativeHTMLKitDocumentText -Document $State.MainDoc -Element count -Text "$($windows.Count) window(s) open."
    }

    function Save-Note {
        param($State, $Note)
        $Note.Text = Get-NativeHTMLKitValue -Document $Note.Document -Element body
        $Note.Title = Get-NativeHTMLKitValue -Document $Note.Document -Element title
        if (-not $Note.Title) { $Note.Title = 'Untitled' }
        $Note.Dirty = $false
        Set-NativeHTMLKitWindow -Window $Note.Window -Title "Note $($Note.Number): $($Note.Title)" | Out-Null
        Set-NativeHTMLKitDocumentText -Document $Note.Document -Element status -Text ('Saved at ' + (Get-Date).ToString('T'))
        Update-NoteList $State
    }

    function Set-NoteDirty {
        param($State, $Note)
        if ($Note.Dirty) { return }
        $Note.Dirty = $true
        Set-NativeHTMLKitDocumentText -Document $Note.Document -Element status -Text 'Unsaved changes'
        Update-NoteList $State
    }

    function New-NoteWindow {
        param($State)
        $number = $State.Next
        $State.Next++
        $window = New-NativeHTMLKitWindow -Application $State.App -Title "Note $number" -Width 460 -Height 360
        $document = Open-NativeHTMLKitHtml -Window $window -Html @'
<!doctype html>
<html><head><style>
  body { font-family: system-ui, sans-serif; margin: 14px; display: flex; flex-direction: column; height: calc(100vh - 28px); gap: 8px; }
  #title { font-size: 16px; padding: 4px 6px; }
  #body { flex: 1; font: 14px/1.4 system-ui, sans-serif; padding: 6px; }
  .row { display: flex; gap: 8px; align-items: center; }
  #status { flex: 1; color: #666; font-size: 13px; }
</style></head>
<body>
  <input id="title" placeholder="Title">
  <textarea id="body" placeholder="Write here..."></textarea>
  <div class="row"><span id="status" role="status">New note</span><button id="discard">Discard changes</button><button id="save">Save</button></div>
</body></html>
'@
        $note = @{ Number = $number; Window = $window; Document = $document; Title = 'Untitled'; Text = ''; Dirty = $false }
        $State.Notes[$window.Id] = $note

        # $State and $note are locals of this function: without .GetNewClosure() they would
        # be gone (or point at another note) when the callback runs later.
        $null = Register-NativeHTMLKitDocumentEvent -Document $document -Type input -Callback { Set-NoteDirty $State $note }.GetNewClosure()
        $null = Register-NativeHTMLKitDocumentEvent -Document $document -Type click -Element save -Callback { Save-Note $State $note }.GetNewClosure()
        $null = Register-NativeHTMLKitDocumentEvent -Document $document -Type click -Element discard -Callback {
            Set-NativeHTMLKitDocumentValue -Document $note.Document -Element title -Value $note.Title
            Set-NativeHTMLKitDocumentValue -Document $note.Document -Element body -Value $note.Text
            $note.Dirty = $false
            Set-NativeHTMLKitDocumentText -Document $note.Document -Element status -Text 'Changes discarded'
            Update-NoteList $State
        }.GetNewClosure()

        # The last output decides: $true closes, $false keeps the window open.
        Set-NativeHTMLKitBeforeClose -Window $window -Callback {
            if ($note.Dirty) {
                Set-NativeHTMLKitDocumentText -Document $note.Document -Element status -Text 'Save or discard your changes before closing.'
                $false
                return
            }
            $true
        }.GetNewClosure()
        Update-NoteList $State
        return $note
    }

    # A note window that closed (user, or Close-NativeHTMLKitWindow) leaves the list.
    Register-NativeHTMLKitNotification -Application $app -Method 'window.event' -Callback {
        param($params)
        if ($params.type -ne 'closed' -or -not $state.Notes.ContainsKey($params.window_id)) { return }
        $state.Notes.Remove($params.window_id)
        Update-NoteList $state
    }

    # Closing the main window quits the app (and so closes every note).
    Set-NativeHTMLKitBeforeClose -Window $main -Callback {
        $null = Request-NativeHTMLKitQuit -Application $app
        $false
    }
    Set-NativeHTMLKitBeforeQuit -Application $app -Callback {
        $dirty = @($state.Notes.Values | Where-Object { $_.Dirty }).Count
        if ($dirty -gt 0) {
            Set-NativeHTMLKitDocumentText -Document $mainDoc -Element count -Text "$dirty note(s) have unsaved changes; save or discard them first."
            $false
            return
        }
        $true
    }

    $null = Register-NativeHTMLKitDocumentEvent -Document $mainDoc -Type click -Element new -Callback { $null = New-NoteWindow $state }
    Update-NoteList $state
    Set-NativeHTMLKitReady -Application $app

    if ($SelfTest) {
        function Wait-Events { for ($i = 0; $i -lt 10; $i++) { $null = Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 30 } }
        $first = New-NoteWindow $state
        $second = New-NoteWindow $state
        if ((Get-NativeHTMLKitWindowList -Application $app).Count -ne 3) { throw 'expected three windows' }
        Set-NativeHTMLKitDocumentValue -Document $second.Document -Element title -Value 'Shopping'
        Set-NoteDirty $state $second
        Close-NativeHTMLKitWindow -Window $second.Window
        Wait-Events
        if ($second.Window.Closed) { throw 'a note with unsaved changes must stay open' }
        if ((Get-NativeHTMLKitDocumentText -Document $second.Document -Element status) -notmatch '^Save or discard') { throw 'veto message missing' }
        $null = Request-NativeHTMLKitQuit -Application $app
        Wait-Events
        if ((Get-NativeHTMLKitDocumentText -Document $mainDoc -Element count) -notmatch 'unsaved changes') { throw 'quit veto message missing' }
        Save-Note $state $second
        Close-NativeHTMLKitWindow -Window $second.Window
        Close-NativeHTMLKitWindow -Window $first.Window
        Wait-Events
        if (-not $second.Window.Closed -or -not $first.Window.Closed) { throw 'saved notes should close' }
        if ($state.Notes.Count -ne 0) { throw 'closed notes should leave the list' }
        if ((Get-NativeHTMLKitDocumentText -Document $mainDoc -Element count) -ne '1 window(s) open.') { throw 'window count not updated' }
        [Console]::Out.WriteLine('SELFTEST PASS 08-multi-window')
        Close-NativeHTMLKitWindow -Window $main   # the main window's policy turns this into a quit
    }

    Wait-NativeHTMLKit -Application $app -UntilShutdown
} finally {
    Close-NativeHTMLKit -Application $app
}
