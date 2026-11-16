# 06-log-tail.ps1 - follow a growing log file, highlight warnings and errors.
#
# Teaches: polling without blocking the window - a background task reads new bytes from
# the file (plain data in, plain data out) and its -OnCompleted callback appends lines and
# schedules the next poll; appending with -Position beforeend; bounding the view with
# trim_children; keeping the view scrolled to the end with set_scroll_follow.
#
# Run:  pwsh -File ./06-log-tail.ps1 -Path /var/log/syslog
#       powershell.exe -NoProfile -File .\06-log-tail.ps1 -Path C:\Logs\app.log
# -SelfTest writes a temporary log, checks that new lines appear, and quits.
param([string]$Path, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Import-Module NativeHTMLKit

$app = Start-NativeHTMLKitScript -Name 'Log tail'
$selfTestLog = $null
try {
    if ($SelfTest) {
        $selfTestLog = Join-Path ([IO.Path]::GetTempPath()) ('nhk-log-tail-' + [guid]::NewGuid().ToString('N') + '.log')
        [IO.File]::WriteAllText($selfTestLog, "INFO service started`nINFO listening on port 8080`n<script>not markup</script>`n")
        $Path = $selfTestLog
    }
    if (-not $Path) { throw 'Pass the log file to follow: -Path <file>' }
    $Path = (Resolve-Path -LiteralPath $Path).ProviderPath

    $window = New-NativeHTMLKitWindow -Application $app -Title ('Log - ' + [IO.Path]::GetFileName($Path)) -Width 900 -Height 560
    $doc = Open-NativeHTMLKitHtml -Window $window -Html @'
<!doctype html>
<html><head><style>
  body { font-family: system-ui, sans-serif; margin: 0; display: flex; flex-direction: column; height: 100vh; }
  header { display: flex; gap: 12px; align-items: center; padding: 8px 12px; background: #eef1f6; }
  #file { flex: 1; font-size: 13px; color: #444; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
  #log { flex: 1; overflow: auto; margin: 0; padding: 8px 12px; list-style: none; font: 12px/1.45 monospace; }
  #log li { white-space: pre-wrap; }
  #log li.warn { background: #fff4ce; }
  #log li.error { background: #fde7e9; color: #8a1c1c; }
  footer { padding: 4px 12px; font-size: 12px; color: #555; }
</style></head>
<body>
  <header><span id="file"></span><label><input type="checkbox" id="paused"> Pause</label><button id="clear">Clear</button></header>
  <ul id="log"></ul>
  <footer id="status">Waiting for data...</footer>
</body></html>
'@
    Set-NativeHTMLKitDocumentText -Document $doc -Element file -Text $Path
    # Keep the list pinned to its end while new lines arrive (unless the user scrolls up).
    $null = Invoke-NativeHTMLKitDocumentCommand -Document $doc -Operation set_scroll_follow -Parameters @{ element = 'log'; follow = $true }

    $script:offset = [long]0
    $script:lineCount = 0
    $script:maxLines = 500

    # Runs in a separate runspace: no access to $doc or any variable of this script.
    $readNewText = {
        param([string]$File, [long]$Offset, [int]$DelayMilliseconds)
        Start-Sleep -Milliseconds $DelayMilliseconds
        $stream = New-Object IO.FileStream($File, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
        try {
            if ($stream.Length -lt $Offset) { $Offset = 0 }          # file was truncated or rotated
            [void]$stream.Seek($Offset, [IO.SeekOrigin]::Begin)
            $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
            $text = $reader.ReadToEnd()
            # Only complete lines; a partial last line is read again next time.
            $end = $text.LastIndexOf("`n")
            if ($end -lt 0) { $text = '' } else { $text = $text.Substring(0, $end + 1) }
            @{ Offset = $Offset + [Text.Encoding]::UTF8.GetByteCount($text); Text = $text }
        } finally { $stream.Dispose() }
    }

    function Add-LogLines([string]$Text) {
        $html = New-Object System.Text.StringBuilder
        $added = 0
        foreach ($line in ($Text -split "\r?\n")) {
            if (-not $line) { continue }
            $class = ''
            if ($line -match '\b(ERROR|FATAL|FAIL(ED)?)\b') { $class = ' class="error"' }
            elseif ($line -match '\bWARN(ING)?\b') { $class = ' class="warn"' }
            [void]$html.Append("<li$class>" + [Net.WebUtility]::HtmlEncode($line) + '</li>')
            $added++
        }
        if ($added -eq 0) { return }
        Set-NativeHTMLKitDocumentHtml -Document $doc -Element log -Html $html.ToString() -Position beforeend
        $script:lineCount += $added
        if ($script:lineCount -gt $script:maxLines) {
            # Drop the oldest lines (from the start) and keep the newest.
            Invoke-NativeHTMLKitBatch -Document $doc -Operations @(@{ op = 'trim_children'; element = 'log'; keep = $script:maxLines; from = 'start' })
            $script:lineCount = $script:maxLines
        }
    }

    function Start-Poll([int]$DelayMilliseconds = 500) {
        $null = Start-NativeHTMLKitTask -Application $app -ScriptBlock $readNewText -ArgumentList @($Path, $script:offset, $DelayMilliseconds) -OnCompleted {
            param($result)
            $chunk = $result[0]
            if (-not (Get-NativeHTMLKitChecked -Document $doc -Element paused)) {
                Add-LogLines $chunk.Text
                $script:offset = $chunk.Offset
            }
            Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text ("$script:lineCount lines shown. Last check " + (Get-Date).ToString('T') + '.')
            Start-Poll
        } -OnFailed {
            param($failure)
            Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text ('Cannot read the file: ' + $failure.Message + ' Retrying...')
            Start-Poll 2000
        }
    }

    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element clear -Callback {
        Set-NativeHTMLKitDocumentHtml -Document $doc -Element log -Html ''
        $script:lineCount = 0
    }

    Start-Poll 0
    Set-NativeHTMLKitReady -Application $app

    if ($SelfTest) {
        function Wait-For([scriptblock]$Condition) {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            while (-not (& $Condition)) {
                if ($clock.ElapsedMilliseconds -gt 15000) { throw "timed out waiting for: $Condition" }
                $null = Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 100
            }
        }
        Wait-For { $script:lineCount -eq 3 }
        [IO.File]::AppendAllText($selfTestLog, "WARN disk 91% full`nERROR backup job failed`n")
        Wait-For { $script:lineCount -eq 5 }
        if ((Find-NativeHTMLKitElement -Document $doc -Selector '#log li.error').matched_nodes -ne 1) { throw 'error line not highlighted' }
        if ((Find-NativeHTMLKitElement -Document $doc -Selector '#log li.warn').matched_nodes -ne 1) { throw 'warning line not highlighted' }
        $third = Get-NativeHTMLKitNodes -Document $doc -Selector '#log li' -Offset 2 -Limit 1
        $html = (Invoke-NativeHTMLKitDocumentCommand -Document $doc -Operation get_html -Parameters @{ node = $third.nodes[0].node }).html
        if ($html -ne '&lt;script&gt;not markup&lt;/script&gt;') { throw "log text was not encoded: $html" }
        [Console]::Out.WriteLine('SELFTEST PASS 06-log-tail')
        $null = Request-NativeHTMLKitQuit -Application $app
    }

    Wait-NativeHTMLKit -Application $app -UntilShutdown
} finally {
    Close-NativeHTMLKit -Application $app
    if ($selfTestLog) { Remove-Item -LiteralPath $selfTestLog -Force -ErrorAction SilentlyContinue }
}
