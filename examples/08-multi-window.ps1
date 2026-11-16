# 08-multi-window.ps1 - a window manager: open note windows and inspect, rename, resize and
# close them from a main window.
#
# Teaches: several windows in one application, each with its own document and handlers;
# Get-NativeHTMLKitWindow / Set-NativeHTMLKitWindow and the live window list; the
# window.event notification (close_requested, closed, resized, focused, ...); per-window
# state in a hashtable with callbacks created inside a function by .GetNewClosure() (and why
# $script: must not be used inside such closures); Set-NativeHTMLKitBeforeClose vetoing the
# close of a note with unsaved changes; "closing the main window quits the app" even while
# other windows are open; NativeHTMLKit.RpcException from window operations.
#
# Run:  pwsh -File ./08-multi-window.ps1     (or powershell.exe -NoProfile -File .\08-multi-window.ps1)
# Platform note: Wayland compositors own window placement and focus, so position/focus requests
# are refused there (RpcException code -32001); size, title, maximize and close work everywhere.
# -SelfTest opens, renames, resizes and closes note windows through the public API, checks the
# close vetoes, closes the main window and expects the application to quit.
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Import-Module NativeHTMLKit

$inspectorHtml = @'
<!doctype html>
<html><head><meta charset="utf-8"><style>
  body { margin:0; padding:18px 22px; font:14px sans-serif; background:#f4f5f8; color:#1e2430; }
  h1 { font-size:20px; margin:0 0 12px; }
  .bar { display:flex; gap:8px; margin-bottom:12px; }
  input { padding:6px; border:1px solid #c2c8d4; border-radius:5px; }
  button { padding:6px 10px; border:1px solid #aab3c3; border-radius:5px; background:#fff; cursor:pointer; }
  table { width:100%; border-collapse:collapse; background:#fff; }
  th, td { text-align:left; padding:6px 8px; border-bottom:1px solid #e1e4ea; }
  td.actions button { padding:3px 7px; font-size:12px; }
  #events { font:12px monospace; color:#596273; max-height:120px; overflow:auto; }
</style></head>
<body>
  <h1>Windows</h1>
  <div class="bar">
    <button id="new-note">New note window</button>
    <input id="rename-to" type="text" placeholder="New title for Rename">
  </div>
  <table><thead><tr><th>ID</th><th>Title</th><th>Size</th><th>State</th><th></th></tr></thead>
    <tbody id="rows"></tbody></table>
  <h2>Window events</h2>
  <div id="events"></div>
  <p id="status"></p>
</body></html>
'@

$noteHtml = @'
<!doctype html>
<html><head><meta charset="utf-8"><style>
  body { margin:0; font:14px sans-serif; display:flex; flex-direction:column; height:100vh; background:#fffbea; }
  #warning { display:none; padding:8px 12px; background:#ffe2b8; }
  #warning.shown { display:block; }
  textarea { flex:1; border:0; padding:12px; background:transparent; font:14px sans-serif; resize:none; }
  footer { padding:6px 12px; display:flex; gap:8px; align-items:center; color:#6f6440; }
  button { padding:4px 10px; }
</style></head>
<body>
  <div id="warning">Unsaved changes. <button id="discard">Discard and close</button></div>
  <textarea id="text" placeholder="Type a note…"></textarea>
  <footer><button id="save">Save</button><span id="note-status">Saved</span></footer>
</body></html>
'@

$app = Start-NativeHTMLKitScript -Name 'Window manager'
try {
    $main = New-NativeHTMLKitWindow -Application $app -Title 'Window manager' -Width 760 -Height 520
    $mainDoc = Open-NativeHTMLKitHtml -Window $main -Html $inspectorHtml

    # One shared, mutable state object. Closures capture the reference, so every window's
    # callbacks see the same notes; $script: variables would NOT work inside .GetNewClosure().
    # Notes keeps insertion order, so the table lists windows in the order they were opened.
    $state = @{ App = $app; Main = $main; MainDoc = $mainDoc; Notes = [ordered]@{}; Next = 1; NoteHtml = $noteHtml }

    function Set-NoteDirty {
        param($Note)
        $Note.Dirty = $true
        Set-NativeHTMLKitDocumentText -Document $Note.Document -Element note-status -Text 'Edited'
    }

    function Save-Note {
        param($Note)
        $Note.SavedText = Get-NativeHTMLKitValue -Document $Note.Document -Element text
        $Note.Dirty = $false
        Set-NativeHTMLKitClass -Document $Note.Document -Element warning -Name shown -Remove
        Set-NativeHTMLKitDocumentText -Document $Note.Document -Element note-status -Text 'Saved'
    }

    function Close-NoteDiscarding {
        param($Note)
        $Note.Dirty = $false
        Close-NativeHTMLKitWindow -Window $Note.Window
    }

    function Update-WindowTable {
        param($State)
        $rows = New-Object System.Text.StringBuilder
        $windows = @($State.Main) + @($State.Notes.Values | ForEach-Object { $_.Window })
        foreach ($window in $windows) {
            try { $info = Get-NativeHTMLKitWindow -Window $window }
            catch [NativeHTMLKit.StaleObjectException], [NativeHTMLKit.RpcException] { continue }   # closed meanwhile
            $flags = @()
            if ($null -ne $info.observed) {
                foreach ($name in 'maximized', 'minimized', 'fullscreen', 'focused') {
                    $property = $info.observed.PSObject.Properties[$name]
                    if ($null -ne $property -and $property.Value) { $flags += $name }
                }
            }
            if ($info.closing) { $flags += 'closing' }
            $flagText = '-'
            if ($flags.Count -gt 0) { $flagText = $flags -join ', ' }
            $wid = [Net.WebUtility]::HtmlEncode($window.Id)
            $actions = ''
            if (-not [object]::ReferenceEquals($window, $State.Main)) {
                $actions = "<button id=`"row-$wid-rename`">Rename</button>" +
                    "<button id=`"row-$wid-grow`">640×480</button>" +
                    "<button id=`"row-$wid-max`">Maximize</button>" +
                    "<button id=`"row-$wid-close`">Close</button>"
            }
            [void]$rows.Append("<tr><td>$wid</td><td>" + [Net.WebUtility]::HtmlEncode([string]$info.title) + '</td>' +
                "<td>$($info.width)×$($info.height)</td><td>$flagText</td>" +
                "<td class=`"actions`">$actions</td></tr>")
        }
        Set-NativeHTMLKitDocumentHtml -Document $State.MainDoc -Element rows -Html $rows.ToString()
    }

    function New-NoteWindow {
        param($State)
        $number = $State.Next
        $State.Next++
        $window = New-NativeHTMLKitWindow -Application $State.App -Title "Note $number" -Width 360 -Height 300
        $document = Open-NativeHTMLKitHtml -Window $window -Html $State.NoteHtml
        $note = @{ Window = $window; Document = $document; Dirty = $false; SavedText = '' }
        $State.Notes[$window.Id] = $note

        # $note is a local of this function: without .GetNewClosure() it would be gone (or
        # point at another note) when the callback runs later.
        $null = Register-NativeHTMLKitDocumentEvent -Document $document -Type input -Element text -Callback { Set-NoteDirty $note }.GetNewClosure()
        $null = Register-NativeHTMLKitDocumentEvent -Document $document -Type click -Element save -Callback { Save-Note $note }.GetNewClosure()
        $null = Register-NativeHTMLKitDocumentEvent -Document $document -Type click -Element discard -Callback { Close-NoteDiscarding $note }.GetNewClosure()

        # Asked by the host before the window closes. The last output decides: $true closes,
        # $false keeps the window open.
        Set-NativeHTMLKitBeforeClose -Window $window -Callback {
            if ($note.Dirty) {
                Set-NativeHTMLKitClass -Document $note.Document -Element warning -Name shown
                $false
                return
            }
            $true
        }.GetNewClosure()
        Update-WindowTable $State
        return $note
    }

    function Invoke-RowAction {
        param($State, [string]$Element)
        $parts = $Element.Split('-')
        if ($parts.Count -ne 3 -or -not $State.Notes.Contains($parts[1])) { return }
        $window = $State.Notes[$parts[1]].Window
        $action = $parts[2]
        try {
            switch ($action) {
                'rename' {
                    $title = (Get-NativeHTMLKitValue -Document $State.MainDoc -Element rename-to).Trim()
                    if ($title) { $null = Set-NativeHTMLKitWindow -Window $window -Title $title }
                }
                'grow' { $null = Set-NativeHTMLKitWindow -Window $window -Width 640 -Height 480 }
                'max' {
                    $observed = (Get-NativeHTMLKitWindow -Window $window).observed
                    $maximized = $false
                    if ($null -ne $observed -and $null -ne $observed.PSObject.Properties['maximized']) { $maximized = [bool]$observed.maximized }
                    $null = Set-NativeHTMLKitWindow -Window $window -Maximized (-not $maximized)
                }
                'close' { Close-NativeHTMLKitWindow -Window $window }   # the note may veto (unsaved changes)
            }
        } catch [NativeHTMLKit.RpcException] {
            Set-NativeHTMLKitDocumentText -Document $State.MainDoc -Element status -Text "$action refused by the platform (code $($_.Exception.Code))."
        }
        Update-WindowTable $State
    }

    $null = Register-NativeHTMLKitDocumentEvent -Document $mainDoc -Type click -Element new-note -Callback { $null = New-NoteWindow $state }
    $null = Register-NativeHTMLKitDocumentEvent -Document $mainDoc -Type click -Element rows -Callback {
        param($evt)
        Invoke-RowAction $state ([string]$evt.element)
    }

    Set-NativeHTMLKitBeforeClose -Window $main -Callback {
        $dirty = @($state.Notes.Values | Where-Object { $_.Dirty }).Count
        if ($dirty -gt 0) {
            Set-NativeHTMLKitDocumentText -Document $mainDoc -Element status -Text "$dirty note(s) have unsaved changes; save or close them first."
            $false
            return
        }
        $true
    }

    Register-NativeHTMLKitNotification -Application $app -Method 'window.event' -Callback {
        param($params)
        $kind = [string]$params.type
        $wid = [string]$params.window_id
        if ($kind -eq 'closed' -and $wid -eq $main.Id) {
            # The SDK has already retired the main window's handles; just quit, which closes
            # the remaining note windows too.
            $null = Request-NativeHTMLKitQuit -Application $app
            return
        }
        if ($kind -eq 'closed' -and $state.Notes.Contains($wid)) { $state.Notes.Remove($wid) }
        try {
            Set-NativeHTMLKitDocumentHtml -Document $mainDoc -Element events -Position beforeend -Html ('<div>' + [Net.WebUtility]::HtmlEncode($wid) + ': ' + [Net.WebUtility]::HtmlEncode($kind) + '</div>')
            $null = Invoke-NativeHTMLKitDocumentCommand -Document $mainDoc -Operation trim_children -Parameters @{ element = 'events'; keep = 30 }   # keep the 30 newest entries
            if ($kind -in @('closed', 'resized', 'close_requested', 'focused')) { Update-WindowTable $state }
        } catch [NativeHTMLKit.StaleObjectException], [NativeHTMLKit.DisconnectedException], [NativeHTMLKit.RpcException] {
            $null = $_                                       # the application is shutting down
        }
    }

    Update-WindowTable $state
    Set-NativeHTMLKitReady -Application $app

    if ($SelfTest) {
        # Window operations run after Set-NativeHTMLKitReady: before it, closing the LAST usable
        # window cancels start-up.
        function Wait-For([scriptblock]$Condition, [int]$TimeoutMilliseconds = 5000) {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            while (-not (& $Condition)) {
                if ($clock.ElapsedMilliseconds -gt $TimeoutMilliseconds) { return $false }
                $null = Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 50
            }
            return $true
        }
        function Assert-Check([string]$Name, [bool]$Ok) { if (-not $Ok) { throw "check failed: $Name" } }
        function Get-RowCount { return (Find-NativeHTMLKitElement -Document $mainDoc -Selector '#rows tr').matched_nodes }
        function Test-ShutdownRequested { return [bool](Get-NativeHTMLKitDiagnosticReport -Application $app).Connection.ShutdownRequested }

        $first = New-NoteWindow $state
        $second = New-NoteWindow $state
        Assert-Check 'windows.three_listed' ((Get-RowCount) -eq 3)
        $list = Get-NativeHTMLKitWindowList -Application $app   # one array object
        Assert-Check 'windows.host_window_list' ($list.Count -eq 3)
        Set-NativeHTMLKitDocumentValue -Document $mainDoc -Element rename-to -Value 'Shopping <list>'
        Invoke-RowAction $state "row-$($first.Window.Id)-rename"
        Assert-Check 'windows.rename_sets_title' ((Get-NativeHTMLKitWindow -Window $first.Window).title -eq 'Shopping <list>')
        Assert-Check 'windows.title_escaped_in_table' ((Get-NativeHTMLKitDocumentText -Document $mainDoc -Element rows).Contains('Shopping <list>'))
        Invoke-RowAction $state "row-$($first.Window.Id)-grow"
        $info = Get-NativeHTMLKitWindow -Window $first.Window
        Assert-Check 'windows.resize' ($info.width -eq 640 -and $info.height -eq 480)
        Invoke-RowAction $state "row-$($first.Window.Id)-max"   # granted, or reported in #status
        $status = Get-NativeHTMLKitDocumentText -Document $mainDoc -Element status
        Assert-Check 'windows.maximize_handled' ($status -eq '' -or $status -match '^max refused by the platform \(code -?\d+\)\.$')
        Set-NoteDirty $second
        Invoke-RowAction $state "row-$($second.Window.Id)-close"
        Assert-Check 'windows.dirty_note_vetoes_close' (Wait-For { [string](Invoke-NativeHTMLKitDocumentCommand -Document $second.Document -Operation get_attribute -Parameters @{ element = 'warning'; name = 'class' }).value -match '\bshown\b' })
        Assert-Check 'windows.dirty_note_still_open' (-not $second.Window.Closed)
        Close-NoteDiscarding $second
        Assert-Check 'windows.discard_closes' (Wait-For { $second.Window.Closed })
        Assert-Check 'windows.table_updated_on_closed' (Wait-For { (Get-RowCount) -eq 2 })
        Assert-Check 'windows.events_logged' ((Get-NativeHTMLKitDocumentText -Document $mainDoc -Element events).Contains('close_requested'))
        Set-NoteDirty $first
        Close-NativeHTMLKitWindow -Window $main
        Assert-Check 'windows.main_close_blocked_by_dirty_note' ((Wait-For { (Get-NativeHTMLKitDocumentText -Document $mainDoc -Element status).Contains('unsaved changes') }) -and -not $main.Closed)
        Save-Note $first
        Close-NativeHTMLKitWindow -Window $main   # main closed with a note open -> Request-NativeHTMLKitQuit
        Assert-Check 'windows.main_close_quits_app' (Wait-For { Test-ShutdownRequested } 10000)
        [Console]::Out.WriteLine('SELFTEST PASS 08-multi-window')
    }

    Wait-NativeHTMLKit -Application $app -UntilShutdown
} finally {
    Close-NativeHTMLKit -Application $app
}
