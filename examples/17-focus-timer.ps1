# 17-focus-timer.ps1 - application lifecycle, quit confirmation and saving state on shutdown.
#
# Teaches: a quit policy (Set-NativeHTMLKitBeforeQuit) that vetoes a quit while the timer runs
# and asks with an HTML <dialog>; saving statistics after Wait-NativeHTMLKit -UntilShutdown
# returns (the host has shut down, so no more cmdlet calls that talk to it); per-application
# folders from the host (Invoke-NativeHTMLKitRpc desktop.paths); Request-NativeHTMLKitAttention
# where the platform supports it and Set-NativeHTMLKitWindow -Title; a ticking timer built from a
# background task that stops with the application.
#
# Run:  pwsh -File ./17-focus-timer.ps1 [-StatsPath stats.json]
#       powershell.exe -NoProfile -File .\17-focus-timer.ps1
# Default statistics file: <per-application state folder>/focus-timer.json.
# -SelfTest runs a one-second session, checks the quit veto and the saved file, and quits.
param([string]$StatsPath, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Import-Module NativeHTMLKit

$app = Start-NativeHTMLKitScript -Name 'Focus timer' -AppId 'org.nativehtmlkit.examples.powershell.focus_timer'
try {
    if ($SelfTest -and -not $StatsPath) { $StatsPath = Join-Path ([IO.Path]::GetTempPath()) ('nhk-focus-' + [guid]::NewGuid().ToString('N') + '.json') }
    if (-not $StatsPath) {
        # desktop.paths: XDG folders on Linux, AppData folders on Windows. The host does not create them.
        $StatsPath = Join-Path (Invoke-NativeHTMLKitRpc -Application $app -Method 'desktop.paths').state 'focus-timer.json'
    }
    $window = New-NativeHTMLKitWindow -Application $app -Title 'Focus timer' -Width 420 -Height 360
    $doc = Open-NativeHTMLKitHtml -Window $window -Html @'
<!doctype html>
<html><head><meta charset="utf-8"><style>
  body { margin:0; font:15px sans-serif; background:#1e2233; color:#eef0f7; text-align:center; }
  main { padding:28px 20px; }
  #clock { font-size:64px; font-variant-numeric:tabular-nums; margin:12px 0; }
  form { display:flex; gap:8px; justify-content:center; align-items:center; }
  input { width:60px; padding:6px; }
  button { padding:7px 14px; border:0; border-radius:6px; background:#5b7cfa; color:#fff; cursor:pointer; }
  button.secondary { background:#3a4058; }
  #sessions { color:#a8afc6; margin-top:14px; }
  dialog { border:0; border-radius:10px; padding:20px; background:#2b3047; color:#eef0f7; }
  .running #clock { color:#8ef0b6; }
</style></head>
<body id="body"><main>
  <h1>Focus timer</h1>
  <div id="clock">25:00</div>
  <form id="controls">
    <label>Minutes <input id="minutes" type="number" min="1" max="120" value="25"></label>
    <button id="start" type="submit">Start</button>
    <button id="pause" type="button" class="secondary">Pause</button>
    <button id="reset" type="button" class="secondary">Reset</button>
  </form>
  <p id="sessions">Completed sessions: 0</p>
  <dialog id="confirm-quit"><p>The timer is still running. Quit anyway?</p>
    <button id="quit-anyway">Quit</button> <button id="keep" class="secondary">Keep running</button></dialog>
</main></body></html>
'@

    function Read-Stats {
        try { return @{ completed = [int](Get-Content -LiteralPath $StatsPath -Raw | ConvertFrom-Json).completed } }
        catch { return @{ completed = 0 } }                # missing or unreadable file
    }

    # Everything the callbacks change lives in this hashtable.
    $timer = @{ Stats = (Read-Stats); Saved = 0; Remaining = 25 * 60.0; Deadline = $null; AllowQuit = $false; Stopped = $false }
    $timer.Saved = $timer.Stats.completed

    function Get-Minutes {
        $value = Get-NativeHTMLKitValue -Document $doc -Element minutes
        if ($value -match '^\d+$') { return [Math]::Min(120, [Math]::Max(1, [int]$value)) }
        return 25
    }

    function Show-Clock {
        $left = $timer.Remaining
        if ($null -ne $timer.Deadline) { $left = [Math]::Max(0.0, ($timer.Deadline - [DateTime]::UtcNow).TotalSeconds) }
        $total = [int][Math]::Round($left)
        $text = '{0:D2}:{1:D2}' -f [int][Math]::Floor($total / 60), ($total % 60)
        Set-NativeHTMLKitDocumentText -Document $doc -Element clock -Text $text
        $title = 'Focus timer'
        if ($null -ne $timer.Deadline) { $title = '{0} {1} Focus timer' -f $text, [char]0x2014 }
        $null = Set-NativeHTMLKitWindow -Window $window -Title $title
    }

    function Start-Timer([double]$Seconds) {
        $timer.Remaining = $Seconds
        $timer.Deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
        Set-NativeHTMLKitClass -Document $doc -Element body -Name running
        Show-Clock
    }

    function Suspend-Timer {
        if ($null -eq $timer.Deadline) { return }
        $timer.Remaining = [Math]::Max(0.0, ($timer.Deadline - [DateTime]::UtcNow).TotalSeconds)
        $timer.Deadline = $null
        Set-NativeHTMLKitClass -Document $doc -Element body -Name running -Remove
    }

    function Reset-Timer {
        $timer.Deadline = $null
        $timer.Remaining = (Get-Minutes) * 60.0
        Set-NativeHTMLKitClass -Document $doc -Element body -Name running -Remove
        Show-Clock
    }

    function Complete-Session {
        $timer.Deadline = $null; $timer.Remaining = 0.0
        $timer.Stats.completed++
        Set-NativeHTMLKitClass -Document $doc -Element body -Name running -Remove
        Set-NativeHTMLKitDocumentText -Document $doc -Element sessions -Text "Completed sessions: $($timer.Stats.completed)"
        Show-Clock
        try { Request-NativeHTMLKitAttention -Window $window -Kind informational }
        catch [NativeHTMLKit.RpcException] { $null = $_ }   # not available (headless, some compositors)
    }

    # A periodic tick: a background task that only sleeps; its completion callback runs on this
    # runspace, updates the clock and schedules the next tick. Close-NativeHTMLKit stops it.
    function Start-Tick {
        $null = Start-NativeHTMLKitTask -Application $app -ScriptBlock { Start-Sleep -Milliseconds 250 } -OnCompleted {
            if ($timer.Stopped) { return }
            if ($null -ne $timer.Deadline) {
                if ([DateTime]::UtcNow -ge $timer.Deadline) { Complete-Session } else { Show-Clock }
            }
            Start-Tick
        }
    }

    # The host asks before quitting (last window closed, or Request-NativeHTMLKitQuit).
    Set-NativeHTMLKitBeforeQuit -Application $app -Callback {
        if ($null -ne $timer.Deadline -and -not $timer.AllowQuit) {
            Show-NativeHTMLKitHtmlDialog -Document $doc -Element confirm-quit
            $false
            return
        }
        $true
    }

    function Confirm-Quit {
        $timer.AllowQuit = $true
        Show-NativeHTMLKitHtmlDialog -Document $doc -Element confirm-quit -Close -ReturnValue quit
        $null = Request-NativeHTMLKitQuit -Application $app     # asks the policy again, which now allows it
    }

    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type submit -Element controls -Callback { Start-Timer ((Get-Minutes) * 60) }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element pause -Callback { Suspend-Timer }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element reset -Callback { Reset-Timer }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element quit-anyway -Callback { Confirm-Quit }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element keep -Callback {
        Show-NativeHTMLKitHtmlDialog -Document $doc -Element confirm-quit -Close -ReturnValue keep
    }

    Set-NativeHTMLKitDocumentText -Document $doc -Element sessions -Text "Completed sessions: $($timer.Stats.completed)"
    Show-Clock
    Start-Tick
    Set-NativeHTMLKitReady -Application $app

    if ($SelfTest) {
        function Wait-For([scriptblock]$Condition) {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            while (-not (& $Condition)) {
                if ($clock.ElapsedMilliseconds -gt 20000) { throw "timed out waiting for: $Condition" }
                $null = Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 50
            }
        }
        function Test-DialogOpen { return [bool](Invoke-NativeHTMLKitDocumentCommand -Document $doc -Operation get_dialog -Parameters @{ element = 'confirm-quit' }).open }
        # The form's submit starts the timer with the minutes field.
        Set-NativeHTMLKitDocumentValue -Document $doc -Element minutes -Value '3'
        $null = Submit-NativeHTMLKitForm -Document $doc -Form controls
        Wait-For { $null -ne $timer.Deadline }
        if ((Get-NativeHTMLKitWindow -Window $window).title -notmatch '^0[23]:\d\d .+ Focus timer$') { throw 'the title does not show the time' }
        Suspend-Timer
        if ((Get-NativeHTMLKitDocumentText -Document $doc -Element clock) -notmatch '^0[23]:\d\d$') { throw 'pause lost the time' }
        Reset-Timer
        if ((Get-NativeHTMLKitDocumentText -Document $doc -Element clock) -ne '03:00') { throw 'reset failed' }
        # A one-second session completes through the tick.
        Start-Timer 1
        Wait-For { $timer.Stats.completed -eq 1 }
        if ((Get-NativeHTMLKitDocumentText -Document $doc -Element sessions) -ne 'Completed sessions: 1') { throw 'session not counted' }
        if ((Get-NativeHTMLKitWindow -Window $window).title -ne 'Focus timer') { throw 'title not restored' }
        # While the timer runs, a quit is vetoed and the dialog asks.
        Start-Timer 600
        $null = Request-NativeHTMLKitQuit -Application $app
        Wait-For { Test-DialogOpen }
        if ($app.ShutdownRequested) { throw 'the quit was not vetoed' }
        Show-NativeHTMLKitHtmlDialog -Document $doc -Element confirm-quit -Close -ReturnValue keep
        Confirm-Quit
    }

    Wait-NativeHTMLKit -Application $app -UntilShutdown

    # The host has shut down: plain PowerShell only from here on.
    $timer.Stopped = $true
    if ($timer.Stats.completed -ne $timer.Saved) {
        $folder = Split-Path -Parent $StatsPath
        if (-not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder }
        Set-Content -LiteralPath $StatsPath -Value (ConvertTo-Json @{ completed = $timer.Stats.completed } -Compress) -Encoding UTF8
    }
    if ($SelfTest) {
        if ((Get-Content -LiteralPath $StatsPath -Raw | ConvertFrom-Json).completed -ne 1) { throw 'statistics were not saved' }
        Remove-Item -LiteralPath $StatsPath
        [Console]::Out.WriteLine('SELFTEST PASS 17-focus-timer')
    }
} finally {
    Close-NativeHTMLKit -Application $app
}
