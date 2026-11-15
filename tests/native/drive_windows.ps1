# Drives tests/native/Qualify.ps1 INSIDE an interactive Windows desktop (RDP or console).
# Start it in that desktop, e.g. from administrative SSH with the lab helper:
#   start_interactive.ps1 -UserName <desktop user> -ScriptPath <wrapper that calls this file>
# SSH alone has no desktop and is not GUI evidence. All actions are real OS input
# (SendInput mouse/keyboard) on the real window; UI Automation only reads the accessibility
# tree. Screenshots are supporting evidence; every check is a behavioral assertion.
#
# Exit code 0 only if every check passed, the launcher exited 0, and no host or backend
# process was left behind. Writes summary-<mode>.json and harness-<mode>.json to -Out.
param(
    [Parameter(Mandatory)][ValidateSet('pwsh', 'ps51')][string]$Edition,
    [Parameter(Mandatory)][string]$Module,
    [Parameter(Mandatory)][string]$HostBinary,
    [Parameter(Mandatory)][string]$Out,
    [string]$Mode = 'full',
    [string]$Pwsh,
    [int]$TimeoutSeconds = 900
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
if (-not ('NhkPsInput' -as [type])) {
Add-Type @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class NhkPsInput {
  [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint data, flags, time; public IntPtr extra; }
  [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort vk, scan; public uint flags, time; public IntPtr extra; }
  [StructLayout(LayoutKind.Explicit)] struct UNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
  [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public UNION u; }
  [DllImport("user32.dll", SetLastError=true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  public static IntPtr Find(string part) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      if (!IsWindowVisible(h) && !IsIconic(h)) return true;
      StringBuilder s = new StringBuilder(512); GetWindowText(h, s, 512);
      if (s.ToString().IndexOf(part, StringComparison.Ordinal) >= 0) { found = h; return false; }
      return true; }, IntPtr.Zero);
    return found;
  }
  static void Send(INPUT[] a) { SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT))); }
  public static void Button(uint down, uint up) {
    INPUT[] a = new INPUT[2]; a[0].type = 0; a[0].u.mi.flags = down; a[1].type = 0; a[1].u.mi.flags = up; Send(a);
  }
  public static void Down() { INPUT[] a = new INPUT[1]; a[0].type = 0; a[0].u.mi.flags = 0x0002; Send(a); }
  public static void Up() { INPUT[] a = new INPUT[1]; a[0].type = 0; a[0].u.mi.flags = 0x0004; Send(a); }
  public static void Key(ushort vk, bool up) {
    INPUT[] a = new INPUT[1]; a[0].type = 1; a[0].u.ki.vk = vk; if (up) a[0].u.ki.flags = 0x0002; Send(a);
  }
  public static void Text(string s) {
    foreach (char c in s) {
      INPUT[] a = new INPUT[2];
      a[0].type = 1; a[0].u.ki.scan = c; a[0].u.ki.flags = 0x0004;
      a[1].type = 1; a[1].u.ki.scan = c; a[1].u.ki.flags = 0x0004 | 0x0002;
      Send(a); System.Threading.Thread.Sleep(20);
    }
  }
}
'@
}
$UIA = [System.Windows.Automation.AutomationElement]
New-Item -ItemType Directory -Force -Path $Out, (Join-Path $Out 'screenshots') | Out-Null
$Out = (Resolve-Path -LiteralPath $Out).Path
$results = Join-Path $Out 'results.jsonl'; $acks = Join-Path $Out 'acks.jsonl'
Remove-Item -LiteralPath $results, $acks -ErrorAction SilentlyContinue
$utf8 = New-Object Text.UTF8Encoding($false)
$script:log = Join-Path $Out "driver-$Mode.log"
function Log($m) { [IO.File]::AppendAllText($script:log, "$([DateTime]::UtcNow.ToString('o')) $m`r`n", $utf8) }
function ConvertTo-JsonLine($o) { ConvertTo-Json -InputObject $o -Depth 8 -Compress }
function Read-Records([string]$Path) {
    # Qualify.ps1 appends while we read: share ReadWrite and retry a transient conflict.
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        try {
            $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
            try { $text = (New-Object IO.StreamReader($stream, $utf8)).ReadToEnd() } finally { $stream.Dispose() }
            return @($text -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
        } catch [IO.IOException] { Start-Sleep -Milliseconds 25 }
    }
    throw "Cannot read $Path"
}
function Write-Shared([string]$Path, [string]$Line) {
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        try { [IO.File]::AppendAllText($Path, $Line, $utf8); return } catch [IO.IOException] { Start-Sleep -Milliseconds 25 }
    }
    throw "Cannot append to $Path"
}
function Ack([int]$Id, [hashtable]$Fields) { $Fields.ack = $Id; Write-Shared $acks ((ConvertTo-JsonLine $Fields) + "`n") }

function Get-Win([string]$Title) {
    $h = [NhkPsInput]::Find($Title)
    if ($h -eq [IntPtr]::Zero) { return $null }
    $r = New-Object NhkPsInput+RECT; [void][NhkPsInput]::GetWindowRect($h, [ref]$r)
    $p = New-Object NhkPsInput+POINT; [void][NhkPsInput]::ClientToScreen($h, [ref]$p)
    $dpi = 96; try { $dpi = [NhkPsInput]::GetDpiForWindow($h) } catch { $dpi = 96 }
    [pscustomobject]@{ hwnd = [int64]$h; x = $r.Left; y = $r.Top; w = $r.Right - $r.Left; h = $r.Bottom - $r.Top
        cx = $p.X; cy = $p.Y; scale = $dpi / 96.0; minimized = [NhkPsInput]::IsIconic($h); maximized = [NhkPsInput]::IsZoomed($h)
        foreground = ([NhkPsInput]::GetForegroundWindow() -eq $h) }
}
function Wait-For([scriptblock]$Pred, [int]$Seconds = 15) {
    $end = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $end) { $v = & $Pred; if ($v) { return $v }; Start-Sleep -Milliseconds 250 }
    return $null
}
function Focus([string]$Title) {
    $w = Get-Win $Title; if (-not $w) { return $null }
    if ($w.minimized) { [void][NhkPsInput]::ShowWindow([IntPtr]$w.hwnd, 9) }
    # A real Alt tap lets this desktop process move the foreground (Windows foreground lock).
    [NhkPsInput]::Key(0x12, $false); [NhkPsInput]::Key(0x12, $true)
    [void][NhkPsInput]::SetForegroundWindow([IntPtr]$w.hwnd)
    Start-Sleep -Milliseconds 300
    return (Get-Win $Title)
}
function Click([double]$X, [double]$Y, [string]$Button = 'left') {
    [void][NhkPsInput]::SetCursorPos([int][Math]::Round($X), [int][Math]::Round($Y)); Start-Sleep -Milliseconds 80
    switch ($Button) { 'left' { [NhkPsInput]::Button(0x0002, 0x0004) } 'right' { [NhkPsInput]::Button(0x0008, 0x0010) } 'middle' { [NhkPsInput]::Button(0x0020, 0x0040) } }
    Start-Sleep -Milliseconds 250
}
function Shot([string]$Name, $Win) {
    try {
        $b = if ($Win) { New-Object Drawing.Rectangle($Win.x, $Win.y, $Win.w, $Win.h) } else { [Windows.Forms.SystemInformation]::VirtualScreen }
        $bmp = New-Object Drawing.Bitmap($b.Width, $b.Height); $g = [Drawing.Graphics]::FromImage($bmp)
        try { $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $b.Size); $bmp.Save((Join-Path $Out "screenshots\$Name.png"), [Drawing.Imaging.ImageFormat]::Png) } finally { $g.Dispose(); $bmp.Dispose() }
        return "$Name.png"
    } catch { Log "screenshot $Name failed: $($_.Exception.Message)"; return $null }
}
function Invoke-A11y([string]$Title, [string]$Button, [string]$Expect) {
    $result = @{ button_found = $false; value_matches = $false; values = @() }
    for ($attempt = 0; $attempt -lt 10 -and -not ($result.button_found -and $result.value_matches); $attempt++) {
        $w = Get-Win $Title
        $root = $UIA::FromHandle([IntPtr]$w.hwnd)
        $all = $root.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
        $result.values = @()
        foreach ($e in $all) {
            $c = $e.Current
            if ($c.ControlType -eq [Windows.Automation.ControlType]::Button -and $c.Name -eq $Button) { $result.button_found = $true }
            if ($c.ControlType -eq [Windows.Automation.ControlType]::Edit) {
                $pattern = $null
                if ($e.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
                    $v = $pattern.Current.Value; $result.values += $v
                    if ($v -eq $Expect) { $result.value_matches = $true }
                }
            }
        }
        if (-not ($result.button_found -and $result.value_matches)) { Start-Sleep -Seconds 1 }
    }
    return $result
}
function Get-Leftovers {
    $full = [IO.Path]::GetFullPath($HostBinary)
    $hosts = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -and [IO.Path]::GetFullPath($_.Path) -eq $full } catch { $false } } | ForEach-Object Id)
    # Exactly the harness backend script (not scripts\qualify.ps1, which -like would match case-insensitively).
    $harnessScript = Join-Path $PSScriptRoot 'Qualify.ps1'
    $backends = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($harnessScript, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | ForEach-Object ProcessId)
    @{ host_processes = $hosts; backend_processes = $backends }
}

function Invoke-Request($r, [string]$Title) {
    $obs = @{ request = $r }
    try {
        switch ([string]$r.action) {
            { $_ -in 'click', 'clicks' } {
                $w = Focus $Title
                $points = if ($r.action -eq 'clicks') { @($r.points) } else { @($r) }
                $button = if ($r.PSObject.Properties['button']) { [string]$r.button } else { 'left' }
                foreach ($p in $points) { Click ($w.cx + [double]$p.x * $w.scale) ($w.cy + [double]$p.y * $w.scale) $button; Start-Sleep -Milliseconds 60 }
                Ack $r.id @{ done = $true; client = @($w.cx, $w.cy); scale = $w.scale; foreground = $w.foreground }
            }
            'type' { [NhkPsInput]::Text([string]$r.text); Start-Sleep -Milliseconds 300; Ack $r.id @{ done = $true } }
            'key' {
                $vk = @{ Tab = 0x09; Enter = 0x0D; Escape = 0x1B }[[string]$r.key]
                [NhkPsInput]::Key([uint16]$vk, $false); [NhkPsInput]::Key([uint16]$vk, $true); Start-Sleep -Milliseconds 300
                Ack $r.id @{ done = $true }
            }
            'a11y' { $res = Invoke-A11y $Title ([string]$r.button) ([string]$r.expect_value); $obs.a11y = $res; Ack $r.id $res }
            'dialog-accept' {
                $d = Wait-For { Get-Win ([string]$r.title) } 30
                $how = $null
                if ($d) {
                    $d = Focus ([string]$r.title); Start-Sleep -Milliseconds 800; $obs.screenshot = Shot 'dialog-save' $d
                    # Real mouse click on the dialog's Save button, located by UIA (name 'Save' on this
                    # English desktop, else the IDOK AutomationId). Enter alone did not commit the dialog.
                    $root = $UIA::FromHandle([IntPtr]$d.hwnd)
                    $ok = $null
                    foreach ($cond in @((New-Object Windows.Automation.PropertyCondition($UIA::NameProperty, 'Save')), (New-Object Windows.Automation.PropertyCondition($UIA::AutomationIdProperty, '1')))) {
                        if (-not $ok) { $ok = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $cond) }
                    }
                    if ($ok) { $b = $ok.Current.BoundingRectangle; Click ($b.X + $b.Width / 2) ($b.Y + $b.Height / 2); $how = "click:$($ok.Current.Name)" }
                    else { [NhkPsInput]::Key(0x0D, $false); [NhkPsInput]::Key(0x0D, $true); $how = 'Enter' }
                }
                Ack $r.id @{ seen = [bool]$d; input = $how }
            }
            'dialog-observe' {
                $d = Wait-For { Get-Win ([string]$r.title) } 30
                if ($d) { $obs.screenshot = Shot 'dialog-open' $d }
                Ack $r.id @{ seen = [bool]$d }
            }
            'dialog-gone' { $gone = [bool](Wait-For { -not (Get-Win ([string]$r.title)) } 15); Ack $r.id @{ gone = $gone } }
            'observe-window' {
                $want = [string]$r.expect
                $w = Wait-For { $x = Get-Win $Title; if ($x) { $s = if ($x.minimized) { 'minimized' } elseif ($x.maximized) { 'maximized' } else { 'normal' }; if ($s -eq $want) { $x } } } 10
                Ack $r.id @{ ok = [bool]$w; window = $w }
            }
            'drag' {
                $before = Focus $Title
                $x0 = $before.cx + [double]$r.x * $before.scale; $y0 = $before.cy + [double]$r.y * $before.scale
                $dx = [double]$r.dx * $before.scale; $dy = [double]$r.dy * $before.scale
                [void][NhkPsInput]::SetCursorPos([int]$x0, [int]$y0); Start-Sleep -Milliseconds 250
                [NhkPsInput]::Down(); Start-Sleep -Milliseconds 200
                for ($i = 1; $i -le 25; $i++) { [void][NhkPsInput]::SetCursorPos([int]($x0 + $dx * $i / 25), [int]($y0 + $dy * $i / 25)); Start-Sleep -Milliseconds 30 }
                Start-Sleep -Milliseconds 200; [NhkPsInput]::Up(); Start-Sleep -Milliseconds 700
                $after = Get-Win $Title
                $moved = ($after.x -ne $before.x -or $after.y -ne $before.y) -and $after.w -eq $before.w -and $after.h -eq $before.h
                $resized = $after.w -ne $before.w -or $after.h -ne $before.h
                if ($r.measure -eq 'move' -or $r.edge -eq 'se') { $obs.screenshot = Shot ('frameless-' + $(if ($r.edge) { $r.edge } else { 'move' })) $after }
                Ack $r.id @{ moved = $moved; resized = $resized; before = $before; after = $after; edge = $r.edge }
            }
            'clipboard-read' { Ack $r.id @{ text = [Windows.Forms.Clipboard]::GetText() } }
            'clipboard-write' { [Windows.Forms.Clipboard]::SetText([string]$r.text); Start-Sleep -Milliseconds 300; Ack $r.id @{ done = $true } }
            'activate' { $null = Focus $Title; Ack $r.id @{ done = $true } }
            'native-close' {
                $w = Focus $Title
                $obs.screenshot = Shot $(if ($r.PSObject.Properties['final']) { 'before-native-close-final' } else { 'before-native-close' }) $w
                # Real Alt+F4 on the foreground window.
                [NhkPsInput]::Key(0x12, $false); [NhkPsInput]::Key(0x73, $false); [NhkPsInput]::Key(0x73, $true); [NhkPsInput]::Key(0x12, $true)
                Ack $r.id @{ done = $true; input = 'Alt+F4'; foreground = $w.foreground }
            }
            default { Ack $r.id @{ error = "unsupported action $($r.action)" } }
        }
    } catch {
        $obs.error = $_.Exception.Message
        Log "request $($r.id) $($r.action) failed: $($_.Exception.Message)"
        Ack $r.id @{ error = $_.Exception.Message }
    }
    return $obs
}

$qualify = Join-Path $PSScriptRoot 'Qualify.ps1'
$shell = if ($Edition -eq 'pwsh') { if ($Pwsh) { $Pwsh } else { (Get-Command pwsh -ErrorAction Stop).Source } } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
$harness = [ordered]@{ edition = $Edition; mode = $Mode; shell = $shell; host = $HostBinary; host_sha256 = (Get-FileHash -LiteralPath $HostBinary -Algorithm SHA256).Hash.ToLowerInvariant()
    module = $Module; user = $env:USERNAME; session_id = (Get-Process -Id $PID).SessionId; before = (Get-Leftovers); observations = @() }
foreach ($k in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'UI4ME_*' } | ForEach-Object Name)) { Remove-Item "Env:$k" }
# The desktop must be exclusive: a NativeHTMLKit host left by another run steals focus and input.
$mySession = (Get-Process -Id $PID).SessionId
$foreign = @(Get-Process -Name nativehtmlkit-host, nhk, nativehtmlkit -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $mySession } | ForEach-Object { "$($_.Name):$($_.Id):$($_.MainWindowTitle)" })
if ($foreign.Count) {
    $harness.blocked = @{ foreign = $foreign }
    [IO.File]::WriteAllText((Join-Path $Out "harness-$Mode.json"), (ConvertTo-Json -InputObject $harness -Depth 8), $utf8)
    [IO.File]::WriteAllText((Join-Path $Out "summary-$Mode.json"), (ConvertTo-Json -InputObject @{ blocked = 'desktop not exclusive'; foreign = $foreign } -Depth 4), $utf8)
    exit 3
}
$env:NATIVEHTMLKIT_PS_RESULTS = $Out; $env:NATIVEHTMLKIT_PS_MODULE = $Module; $env:NATIVEHTMLKIT_PS_MODE = $Mode; $env:NATIVEHTMLKIT_HOST_BINARY = $HostBinary
$launcherLog = Join-Path $Out "launcher-$Mode.log"
$p = Start-Process -FilePath $shell -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $qualify + '"')) -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $launcherLog -RedirectStandardError (Join-Path $Out "launcher-$Mode.err.log") -WorkingDirectory $Out
$null = $p.Handle   # keep the handle so ExitCode is available after exit
Log "launched $shell pid=$($p.Id)"
$clock = [Diagnostics.Stopwatch]::StartNew(); $done = @{}; $title = $null
try {
    while (-not $p.HasExited -and $clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $records = Read-Records $results
        foreach ($r in $records) {
            if ($r.kind -eq 'ready' -and -not $title) {
                $title = [string]$r.title; $harness.ready_s = [Math]::Round($clock.Elapsed.TotalSeconds, 3)
                $w = Wait-For { Get-Win $title } 20
                $harness.window_at_ready = $w
                $w = Focus $title; $harness.screenshot_ready = Shot "ready-$Mode" $w
            }
            if ($r.kind -ne 'request' -or $done.ContainsKey([string]$r.id)) { continue }
            $done[[string]$r.id] = $true
            $harness.observations += (Invoke-Request $r $title)
        }
        Start-Sleep -Milliseconds 150
    }
    if (-not $p.HasExited) { $harness.timeout = $true; Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    $p.WaitForExit(30000) | Out-Null
    $harness.launcher_exit = $p.ExitCode
} finally {
    Start-Sleep -Seconds 2
    $harness.total_s = [Math]::Round($clock.Elapsed.TotalSeconds, 3)
    $harness.window_after_exit = if ($title) { Get-Win $title } else { $null }
    $harness.after = Get-Leftovers
    [IO.File]::WriteAllText((Join-Path $Out "harness-$Mode.json"), (ConvertTo-Json -InputObject $harness -Depth 8), $utf8)
}
$records = Read-Records $results
$checks = @($records | Where-Object { $_.kind -eq 'check' })
$failed = @($checks | Where-Object { $_.status -ne 'pass' })
$newHosts = @($harness.after.host_processes | Where-Object { $_ -notin $harness.before.host_processes })
$newBackends = @($harness.after.backend_processes | Where-Object { $_ -notin $harness.before.backend_processes })
$clean = $newHosts.Count -eq 0 -and $newBackends.Count -eq 0 -and $null -eq $harness.window_after_exit
$summary = [ordered]@{ edition = $Edition; mode = $Mode; checks = $checks.Count; passed = $checks.Count - $failed.Count
    failed = @($failed | ForEach-Object { "$($_.name): $($_.error)" }); launcher_exit = $harness.launcher_exit; timeout = [bool]$harness.timeout
    fatal = @($records | Where-Object { $_.kind -eq 'fatal' }); clean_teardown = $clean; done = [bool](@($records | Where-Object { $_.kind -eq 'done' }).Count)
    shutdown = @($records | Where-Object { $_.kind -eq 'shutdown' }) }
[IO.File]::WriteAllText((Join-Path $Out "summary-$Mode.json"), (ConvertTo-Json -InputObject $summary -Depth 6), $utf8)
$ok = $checks.Count -gt 0 -and $failed.Count -eq 0 -and $harness.launcher_exit -eq 0 -and -not $harness.timeout -and $clean -and $summary.done -and $summary.fatal.Count -eq 0
exit $(if ($ok) { 0 } else { 1 })
