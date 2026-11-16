# 12-live-chart.ps1 - a live line chart drawn into an RGBA bitmap.
#
# Teaches: New-NativeHTMLKitLiveBitmap + <img src="nativehtmlkit-bitmap://ID">, drawing
# straight-alpha RGBA8 pixels into a byte[] quickly from PowerShell (copy a prepared
# background, then draw short vertical spans), presenting frames with
# Send-NativeHTMLKitLiveBitmap, a periodic tick built from a background task, and
# Remove-NativeHTMLKitLiveBitmap.
#
# The chart shows this PowerShell process's working set, sampled twice per second.
#
# Run:  pwsh -File ./12-live-chart.ps1     (or powershell.exe -NoProfile -File .\12-live-chart.ps1)
# -SelfTest presents a few frames, checks the host accepted them, and quits.
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Import-Module NativeHTMLKit

$app = Start-NativeHTMLKitScript -Name 'Live chart'
try {
    $width = 360; $height = 120
    $window = New-NativeHTMLKitWindow -Application $app -Title 'Live chart' -Width 440 -Height 300
    $doc = Open-NativeHTMLKitHtml -Window $window -Html @"
<!doctype html>
<html><head><style>
  body { font-family: system-ui, sans-serif; margin: 20px; }
  img { width: ${width}px; height: ${height}px; border: 1px solid #ccc; display: block; }
  #legend { font-size: 13px; color: #444; margin-top: 8px; }
</style></head>
<body>
  <h3>Working set of this backend process</h3>
  <img id="chart" src="nativehtmlkit-bitmap://memory" alt="Memory use over time">
  <p id="legend" role="status">Starting...</p>
  <button id="pause">Pause</button>
</body></html>
"@

    # The bitmap belongs to this document; it is released with the document or explicitly.
    $bitmap = New-NativeHTMLKitLiveBitmap -Document $doc -Id memory -Width $width -Height $height

    # Prepare the background once (white with grid lines); each frame starts as a copy of it.
    $background = New-Object byte[] ($width * $height * 4)
    for ($i = 0; $i -lt $background.Length; $i++) { $background[$i] = 255 }
    foreach ($y in 30, 60, 90) {
        for ($x = 0; $x -lt $width; $x++) {
            $o = ($y * $width + $x) * 4
            $background[$o] = 225; $background[$o + 1] = 229; $background[$o + 2] = 236
        }
    }
    $frame = New-Object byte[] $background.Length
    $samples = New-Object System.Collections.Generic.List[double]
    $chart = @{ Paused = $false; Frames = 0 }

    function Write-Frame {
        [Buffer]::BlockCopy($background, 0, $frame, 0, $background.Length)
        if ($samples.Count -gt 0) {
            $stats = $samples | Measure-Object -Minimum -Maximum
            $low = $stats.Minimum; $high = $stats.Maximum
            $range = [Math]::Max(1.0, $high - $low)
            $previous = -1
            for ($i = 0; $i -lt $samples.Count; $i++) {
                $x = $width - $samples.Count + $i
                $y = [int](($height - 6) - (($samples[$i] - $low) / $range) * ($height - 12))
                if ($previous -lt 0) { $previous = $y }
                # A vertical span from the previous point keeps the line connected.
                $top = [Math]::Min($previous, $y); $bottom = [Math]::Max($previous, $y)
                for ($row = $top; $row -le $bottom; $row++) {
                    $o = ($row * $width + $x) * 4
                    $frame[$o] = 50; $frame[$o + 1] = 104; $frame[$o + 2] = 216; $frame[$o + 3] = 255
                }
                $previous = $y
            }
        }
        $result = Send-NativeHTMLKitLiveBitmap -Bitmap $bitmap -Pixels $frame
        $chart.Frames++
        return $result
    }

    function Add-Sample {
        $process = [Diagnostics.Process]::GetCurrentProcess()
        $mb = $process.WorkingSet64 / 1MB
        $samples.Add($mb)
        while ($samples.Count -gt $width) { $samples.RemoveAt(0) }
        Set-NativeHTMLKitDocumentText -Document $doc -Element legend -Text ('{0:N1} MB now, {1} samples' -f $mb, $samples.Count)
    }

    # A periodic tick: a tiny background task that only sleeps; its completion callback
    # runs on this runspace, does the UI work and schedules the next tick.
    function Start-Tick {
        $null = Start-NativeHTMLKitTask -Application $app -ScriptBlock { Start-Sleep -Milliseconds 500 } -OnCompleted {
            if (-not $chart.Paused) { Add-Sample; $null = Write-Frame }
            Start-Tick
        }
    }

    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element pause -Callback {
        $chart.Paused = -not $chart.Paused
        $label = 'Pause'
        if ($chart.Paused) { $label = 'Resume' }
        Set-NativeHTMLKitDocumentText -Document $doc -Element pause -Text $label
    }

    Add-Sample
    $null = Write-Frame
    Start-Tick
    Set-NativeHTMLKitReady -Application $app

    if ($SelfTest) {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while ($chart.Frames -lt 4) {
            if ($clock.ElapsedMilliseconds -gt 20000) { throw 'ticks did not arrive' }
            $null = Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 100
        }
        $presented = Write-Frame
        if (-not $presented.presented_to_engine) { throw 'the host did not accept the frame' }
        if ($samples.Count -lt 4) { throw 'samples missing' }
        Remove-NativeHTMLKitLiveBitmap -Bitmap $bitmap
        Remove-NativeHTMLKitLiveBitmap -Bitmap $bitmap   # idempotent
        $chart.Paused = $true
        [Console]::Out.WriteLine('SELFTEST PASS 12-live-chart')
        $null = Request-NativeHTMLKitQuit -Application $app
    }

    Wait-NativeHTMLKit -Application $app -UntilShutdown
} finally {
    Close-NativeHTMLKit -Application $app
}
