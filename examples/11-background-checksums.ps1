# 11-background-checksums.ps1 - hash every file of a folder in background tasks, with
# progress and cancel.
#
# Teaches: keeping slow work OFF the event callback (callbacks run one at a time, so a long
# job there would delay every later event); Start-NativeHTMLKitTask (work in an isolated
# runspace, plain data in and out) split into batches of about 0.2 s, so each -OnCompleted
# updates the document a few times per second and starts the next batch; cancelling with
# Stop-NativeHTMLKitTask (-OnFailed receives an OperationCanceledException); one atomic
# Invoke-NativeHTMLKitBatch per progress update; Set-NativeHTMLKitBeforeQuit asking before
# quitting while a job is running; the native folder dialog; file names are untrusted text,
# encoded with [Net.WebUtility]::HtmlEncode.
#
# Run:  pwsh -File ./11-background-checksums.ps1 [[-Folder] C:\Tools]    (default: the current directory;
#       -Path is accepted as an alias, and the folder may also be given without a name)
#       powershell.exe -NoProfile -File .\11-background-checksums.ps1
# Type or browse to a folder, then press Start.
# -SelfTest hashes a scratch folder, checks hashes, rows, escaping, progress, a bad folder,
# cancel and the quit veto, and quits.
param([Alias('Path')][string]$Folder, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Import-Module NativeHTMLKit

$app = Start-NativeHTMLKitScript -Name 'Checksums'
try {
    $window = New-NativeHTMLKitWindow -Application $app -Title 'Checksums' -Width 760 -Height 560
    $doc = Open-NativeHTMLKitHtml -Window $window -Html @'
<!doctype html>
<html><head><meta charset="utf-8"><style>
  body { margin:0; padding:16px 20px; font:14px sans-serif; background:#f5f6f9; color:#1d2230; }
  h1 { font-size:20px; margin:0 0 10px; }
  form { display:flex; gap:8px; }
  input[type=text] { flex:1; padding:7px; font-family:monospace; }
  button { padding:6px 12px; }
  .progress { height:8px; background:#e0e4ec; border-radius:4px; margin:12px 0 6px; }
  #bar { height:8px; width:0%; background:#3b74e8; border-radius:4px; }
  #warning { display:none; background:#fff0c9; padding:8px 12px; border-radius:6px; }
  #warning.shown { display:block; }
  table { width:100%; border-collapse:collapse; background:#fff; font-size:12px; }
  td { padding:4px 8px; border-bottom:1px solid #e6e8ee; font-family:monospace; }
  td.size { text-align:right; color:#5f6879; }
</style></head>
<body>
  <h1>Folder checksums (SHA-256)</h1>
  <form id="job"><input id="folder" type="text" placeholder="Folder path" required>
    <button id="browse" type="button">Browse…</button>
    <button id="start" type="submit">Start</button><button id="cancel" type="button">Cancel</button></form>
  <div class="progress"><div id="bar"></div></div>
  <p id="status">Idle.</p>
  <p id="warning">A job is still running. Cancel it, or quit again to stop it.</p>
  <table><tbody id="results"></tbody></table>
</body></html>
'@

    # ----- background work: isolated runspaces without this script's variables or modules -----
    # Lists the files below Root as relative '/' names, sorted like paths (part by part).
    $listFiles = {
        param([string]$Root)
        $comparer = [StringComparer]::Ordinal
        if ([IO.Path]::DirectorySeparatorChar -eq '\') { $comparer = [StringComparer]::OrdinalIgnoreCase }
        [string[]]$names = @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/') })
        [string[]]$keys = @($names | ForEach-Object { $_.Replace('/', [string][char]0) })   # '/' sorts before every character
        if ($names.Count -gt 1) { [Array]::Sort($keys, $names, $comparer) }
        $names
    }
    # Hashes files in order until about BudgetMilliseconds have passed (at least one file).
    # Reading 1 MB chunks in a PowerShell loop lets Stop-NativeHTMLKitTask stop it between chunks.
    $hashFiles = {
        param([string]$Root, [string[]]$Names, [int]$BudgetMilliseconds)
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $buffer = New-Object byte[] (1024 * 1024)
        foreach ($name in $Names) {
            $path = [IO.Path]::Combine($Root, $name)
            $size = [long]0
            try {
                $size = (New-Object IO.FileInfo $path).Length
                $sha = [Security.Cryptography.SHA256]::Create()
                $stream = [IO.File]::OpenRead($path)
                try {
                    while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) { [void]$sha.TransformBlock($buffer, 0, $read, $null, 0) }
                    [void]$sha.TransformFinalBlock($buffer, 0, 0)
                    $digest = ([BitConverter]::ToString($sha.Hash) -replace '-', '').ToLowerInvariant()
                } finally { $stream.Dispose(); $sha.Dispose() }
            } catch [Management.Automation.PipelineStoppedException] {
                throw                                        # Stop-NativeHTMLKitTask: end now
            } catch {
                $digest = 'unreadable (' + $_.Exception.Message + ')'
            }
            [pscustomobject]@{ Name = $name; Hash = $digest; Size = $size }
            if ($clock.ElapsedMilliseconds -gt $BudgetMilliseconds) { break }
        }
    }

    # ----- UI side: everything below runs on this runspace -----
    $job = @{ Task = $null; Running = $false; Cancel = $false; QuitWarned = $false; Root = ''; Files = @(); Next = 0; Results = [ordered]@{} }

    function Set-Status([string]$Text) { Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text $Text }

    function Send-Progress([string]$Rows, [int]$Done, [int]$Total) {
        $operations = @(
            @{ op = 'set_attribute'; element = 'bar'; name = 'style'; value = ('width:' + [Math]::Floor($Done * 100 / [Math]::Max($Total, 1)) + '%') }
            @{ op = 'set_text'; element = 'status'; text = "Hashing… $Done/$Total" })
        if ($Rows) { $operations = @(@{ op = 'insert_html'; element = 'results'; position = 'beforeend'; html = $Rows }) + $operations }
        Invoke-NativeHTMLKitBatch -Document $doc -Operations $operations
    }

    function Complete-Job {
        $job.Running = $false
        $job.Task = $null
        Send-Progress '' $job.Results.Count $job.Files.Count
        $word = 'Done:'
        if ($job.Cancel) { $word = 'Cancelled after' }
        Set-Status "$word $($job.Results.Count) of $($job.Files.Count) file(s)."
        Set-NativeHTMLKitClass -Document $doc -Element warning -Name shown -Remove
    }

    function Start-NextBatch {
        $names = @($job.Files[$job.Next..($job.Files.Count - 1)])
        # Inside @(...) the array stays ONE argument (the scriptblock's -Names parameter).
        $job.Task = Start-NativeHTMLKitTask -Application $app -ScriptBlock $hashFiles -ArgumentList @($job.Root, [string[]]$names, 200) -OnCompleted {
            param($items)
            $rows = New-Object System.Text.StringBuilder
            foreach ($item in @($items)) {
                $job.Results[$item.Name] = $item.Hash
                [void]$rows.Append('<tr><td>' + [Net.WebUtility]::HtmlEncode($item.Hash) + '</td><td>' + [Net.WebUtility]::HtmlEncode($item.Name) + '</td>' +
                    '<td class="size">' + ([long]$item.Size).ToString('N0', [Globalization.CultureInfo]::InvariantCulture) + '</td></tr>')
            }
            $job.Next += @($items).Count
            Send-Progress $rows.ToString() $job.Results.Count $job.Files.Count
            if ($job.Cancel -or $job.Next -ge $job.Files.Count) { Complete-Job } else { Start-NextBatch }
        } -OnFailed {
            param($failure)
            if ($failure -is [OperationCanceledException]) { Complete-Job; return }
            $job.Running = $false
            Set-Status ('Failed: ' + $failure.Message)
        }
    }

    function Start-Checksums([string]$Path) {
        if ($job.Running) { Set-Status 'A job is already running.'; return $null }
        if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container)) { Set-Status "Not a folder: $Path"; return $null }
        $job.Root = (Resolve-Path -LiteralPath $Path).ProviderPath
        $job.Cancel = $false; $job.QuitWarned = $false; $job.Results = [ordered]@{}; $job.Files = @(); $job.Next = 0
        $job.Running = $true
        Set-NativeHTMLKitDocumentHtml -Document $doc -Element results -Html ''
        $job.Task = Start-NativeHTMLKitTask -Application $app -ScriptBlock $listFiles -ArgumentList @($job.Root) -OnCompleted {
            param($names)
            $job.Files = @($names)
            if ($job.Cancel -or $job.Files.Count -eq 0) { Complete-Job } else { Start-NextBatch }
        } -OnFailed {
            param($failure)
            $job.Running = $false
            Set-Status ('Failed: ' + $failure.Message)
        }
        return $job.Task
    }

    function Stop-Checksums {
        if (-not $job.Running) { return }
        $job.Cancel = $true
        # Listing is left to finish so the total is known; a hashing batch is stopped.
        if ($job.Files.Count -gt 0 -and $null -ne $job.Task) { Stop-NativeHTMLKitTask -Task $job.Task }
    }

    function Select-Folder {
        try {
            # Waits (pumping events) until the user picks or cancels.
            $result = Show-NativeHTMLKitFileDialog -Window $window -Kind ChooseFolder -Title 'Choose a folder to hash'
        } catch [NativeHTMLKit.RpcException] {
            Set-Status "Folder dialog unavailable (code $($_.Exception.Code)); type a path instead."
            return
        }
        $paths = @($result.paths)
        if (-not $result.cancelled -and $paths.Count -gt 0) { Set-NativeHTMLKitDocumentValue -Document $doc -Element folder -Value ([string]$paths[0]) }
    }

    # The host's quit request: the first while busy is refused with a warning, a second is allowed.
    function Test-MayQuit {
        if ($job.Running -and -not $job.QuitWarned) {
            $job.QuitWarned = $true
            Set-NativeHTMLKitClass -Document $doc -Element warning -Name shown
            return $false
        }
        $job.Cancel = $true
        if ($null -ne $job.Task) { Stop-NativeHTMLKitTask -Task $job.Task }
        return $true
    }

    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type submit -Element job -Callback {
        $null = Start-Checksums (Get-NativeHTMLKitValue -Document $doc -Element folder).Trim()
    }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element cancel -Callback { Stop-Checksums }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element browse -Callback { Select-Folder }
    Set-NativeHTMLKitBeforeQuit -Application $app -Callback { Test-MayQuit }

    if (-not $Folder) { $Folder = (Get-Location).ProviderPath }
    Set-NativeHTMLKitDocumentValue -Document $doc -Element folder -Value $Folder
    Set-NativeHTMLKitReady -Application $app

    if ($SelfTest) {
        function Wait-For([scriptblock]$Condition, [int]$TimeoutMilliseconds = 30000) {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            while (-not (& $Condition)) {
                if ($clock.ElapsedMilliseconds -gt $TimeoutMilliseconds) { return $false }
                $null = Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 50
            }
            return $true
        }
        function Assert-Check([string]$Name, [bool]$Ok, [string]$Detail = '') { if (-not $Ok) { throw "check failed: $Name $Detail" } }
        function Get-Sha256([byte[]]$Bytes) {
            $sha = [Security.Cryptography.SHA256]::Create()
            try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose() }
        }
        function Test-WarningShown { return ([string](Invoke-NativeHTMLKitDocumentCommand -Document $doc -Operation get_attribute -Parameters @{ element = 'warning'; name = 'class' }).value) -match '\bshown\b' }

        $scratch = Join-Path ([IO.Path]::GetTempPath()) ('nhk-checksums-' + [guid]::NewGuid().ToString('N'))
        $unsafe = 'sub/b & <x>.bin'
        if ([IO.Path]::DirectorySeparatorChar -eq '\') { $unsafe = "sub/b & 'x' &amp;.bin" }
        $big = New-Object byte[] (256 * 4000)
        for ($i = 0; $i -lt $big.Length; $i++) { $big[$i] = [byte]($i % 256) }
        $files = [ordered]@{ 'a.txt' = [Text.Encoding]::ASCII.GetBytes('alpha'); $unsafe = $big; 'c.md' = (New-Object byte[] 0) }
        try {
            foreach ($name in $files.Keys) {
                $path = [IO.Path]::Combine($scratch, $name)
                $null = New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($path))
                [IO.File]::WriteAllBytes($path, $files[$name])
            }
            $worker = Start-Checksums $scratch
            Assert-Check 'checksum.worker_started' ($null -ne $worker)
            Assert-Check 'checksum.finished' (Wait-For { -not $job.Running })
            $ok = $job.Results.Count -eq $files.Count
            foreach ($name in $files.Keys) { if (-not $job.Results.Contains($name) -or $job.Results[$name] -ne (Get-Sha256 $files[$name])) { $ok = $false } }
            Assert-Check 'checksum.hashes_correct' $ok
            Assert-Check 'checksum.rows_rendered' ((Find-NativeHTMLKitElement -Document $doc -Selector '#results tr').matched_nodes -eq 3)
            Assert-Check 'checksum.names_escaped' ((Get-NativeHTMLKitDocumentText -Document $doc -Element results).Contains($unsafe))
            $status = Get-NativeHTMLKitDocumentText -Document $doc -Element status
            Assert-Check 'checksum.status_done' ($status -eq 'Done: 3 of 3 file(s).') $status
            $style = (Invoke-NativeHTMLKitDocumentCommand -Document $doc -Operation get_attribute -Parameters @{ element = 'bar'; name = 'style' }).value
            Assert-Check 'checksum.progress_full' ($style -eq 'width:100%') $style
            Assert-Check 'checksum.bad_folder' ($null -eq (Start-Checksums (Join-Path $scratch 'missing')) -and (Get-NativeHTMLKitDocumentText -Document $doc -Element status).StartsWith('Not a folder'))
            # Cancel during listing: the listing finishes, then nothing is hashed.
            $null = Start-Checksums $scratch
            Stop-Checksums
            Assert-Check 'checksum.cancel' ((Wait-For { -not $job.Running }) -and (Get-NativeHTMLKitDocumentText -Document $doc -Element status) -eq 'Cancelled after 0 of 3 file(s).')
            Select-Folder   # headless: no folder dialog, the fallback message is shown
            $status = Get-NativeHTMLKitDocumentText -Document $doc -Element status
            Assert-Check 'checksum.browse_handled' ($status -match '^Folder dialog unavailable \(code -?\d+\); type a path instead\.$' -or $status -eq 'Cancelled after 0 of 3 file(s).') $status
            # Quit while busy: simulate a running job; the first quit is refused, the second allowed.
            $job.Task = Start-NativeHTMLKitTask -Application $app -ScriptBlock { Start-Sleep -Milliseconds 1500 } -OnFailed { param($failure) $null = $failure }
            $job.Running = $true; $job.QuitWarned = $false
            Assert-Check 'checksum.quit_vetoed_while_busy' (-not (Test-MayQuit) -and (Test-WarningShown))
            Assert-Check 'checksum.second_quit_allowed' (Test-MayQuit)
        } finally {
            Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
        }
        [Console]::Out.WriteLine('SELFTEST PASS 11-background-checksums')
        $null = Request-NativeHTMLKitQuit -Application $app
    }

    Wait-NativeHTMLKit -Application $app -UntilShutdown
} finally {
    Close-NativeHTMLKit -Application $app
}
