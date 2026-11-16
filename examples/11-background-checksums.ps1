# 11-background-checksums.ps1 - hash every file in a folder without freezing the window.
#
# Teaches: Start-NativeHTMLKitTask (work in an isolated runspace, plain data in and out),
# progress by splitting the work into batches (each -OnCompleted renders a result and
# starts the next batch), cancellation with Stop-NativeHTMLKitTask (-OnFailed receives an
# OperationCanceledException), -TimeoutMilliseconds, and Receive-NativeHTMLKitTask.
#
# Run:  pwsh -File ./11-background-checksums.ps1 [-Folder C:\Tools]
#       powershell.exe -NoProfile -File .\11-background-checksums.ps1
# -SelfTest hashes this examples folder, checks one hash, tests cancel, and quits.
param([string]$Folder, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Import-Module NativeHTMLKit

$app = Start-NativeHTMLKitScript -Name 'Checksums'
try {
    if (-not $Folder) { $Folder = $PSScriptRoot }
    $window = New-NativeHTMLKitWindow -Application $app -Title 'Checksums' -Width 860 -Height 600
    $doc = Open-NativeHTMLKitHtml -Window $window -Html @'
<!doctype html>
<html><head><style>
  body { font-family: system-ui, sans-serif; margin: 16px; }
  .bar { display: flex; gap: 8px; align-items: center; }
  #folder { flex: 1; padding: 5px 8px; }
  progress { width: 100%; height: 14px; margin: 10px 0 4px; }
  table { border-collapse: collapse; width: 100%; font-size: 12px; }
  td, th { text-align: left; padding: 3px 6px; border-bottom: 1px solid #e3e3e3; }
  td.hash { font-family: monospace; }
  td.error { color: #8a1c1c; }
  #status { font-size: 13px; color: #444; }
</style></head>
<body>
  <div class="bar">
    <input id="folder" aria-label="Folder">
    <button id="start">Compute SHA-256</button>
    <button id="cancel" disabled>Cancel</button>
  </div>
  <progress id="progress" max="1" value="0"></progress>
  <p id="status" role="status">Choose a folder and press Compute.</p>
  <table><thead><tr><th>File</th><th>SHA-256</th></tr></thead><tbody id="rows"></tbody></table>
</body></html>
'@
    Set-NativeHTMLKitDocumentValue -Document $doc -Element folder -Value $Folder

    # Background work: an isolated runspace without this script's variables or modules.
    $hashBatch = {
        param([string[]]$Files)
        foreach ($file in $Files) {
            try {
                $stream = [IO.File]::OpenRead($file)
                try { $sha = [Security.Cryptography.SHA256]::Create(); $bytes = $sha.ComputeHash($stream) } finally { $stream.Dispose() }
                [pscustomobject]@{ File = $file; Hash = ([BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant(); Error = $null }
            } catch {
                [pscustomobject]@{ File = $file; Hash = $null; Error = $_.Exception.Message }
            }
        }
    }

    $job = @{ Files = @(); Next = 0; Done = 0; Task = $null; Running = $false; Root = ''; Results = @{} }

    function Set-Running([bool]$Running) {
        $job.Running = $Running
        if ($Running) {
            Set-NativeHTMLKitDocumentAttribute -Document $doc -Element start -Name disabled
            Set-NativeHTMLKitDocumentAttribute -Document $doc -Element cancel -Name disabled -Remove
        } else {
            Set-NativeHTMLKitDocumentAttribute -Document $doc -Element start -Name disabled -Remove
            Set-NativeHTMLKitDocumentAttribute -Document $doc -Element cancel -Name disabled
        }
    }

    function Add-ResultRows($Items) {
        $html = New-Object System.Text.StringBuilder
        foreach ($item in $Items) {
            $job.Results[$item.File] = $item
            $name = [Net.WebUtility]::HtmlEncode($item.File.Substring($job.Root.Length).TrimStart('\', '/'))
            if ($item.Error) { [void]$html.Append("<tr><td>$name</td><td class=`"error`">" + [Net.WebUtility]::HtmlEncode($item.Error) + '</td></tr>') }
            else { [void]$html.Append("<tr><td>$name</td><td class=`"hash`">$($item.Hash)</td></tr>") }
        }
        Set-NativeHTMLKitDocumentHtml -Document $doc -Element rows -Html $html.ToString() -Position beforeend
    }

    function Start-NextBatch {
        if ($job.Next -ge $job.Files.Count) {
            Set-Running $false
            Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text "Done: $($job.Done) file(s)."
            return
        }
        $batch = @($job.Files[$job.Next..([Math]::Min($job.Files.Count, $job.Next + 10) - 1)])
        $job.Next += $batch.Count
        # ,$batch passes the array as ONE argument (the scriptblock's -Files parameter).
        $job.Task = Start-NativeHTMLKitTask -Application $app -ScriptBlock $hashBatch -ArgumentList @(, [string[]]$batch) -TimeoutMilliseconds 60000 -OnCompleted {
            param($items)
            Add-ResultRows $items
            $job.Done += @($items).Count
            Set-NativeHTMLKitDocumentAttribute -Document $doc -Element progress -Name value -Value ([string]$job.Done)
            Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text "Hashed $($job.Done) of $($job.Files.Count) file(s)..."
            if ($job.Running) { Start-NextBatch }
        } -OnFailed {
            param($failure)
            Set-Running $false
            $text = 'Stopped: ' + $failure.Message
            if ($failure -is [OperationCanceledException]) { $text = "Cancelled after $($job.Done) of $($job.Files.Count) file(s)." }
            Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text $text
        }
    }

    function Start-Hashing {
        $root = (Get-NativeHTMLKitValue -Document $doc -Element folder).Trim()
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text 'That folder does not exist.'
            return
        }
        $job.Root = (Resolve-Path -LiteralPath $root).ProviderPath
        $job.Files = @(Get-ChildItem -LiteralPath $job.Root -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 2000 | ForEach-Object { $_.FullName })
        $job.Next = 0; $job.Done = 0; $job.Results = @{}
        Set-NativeHTMLKitDocumentHtml -Document $doc -Element rows -Html ''
        Set-NativeHTMLKitDocumentAttribute -Document $doc -Element progress -Name max -Value ([string][Math]::Max(1, $job.Files.Count))
        Set-NativeHTMLKitDocumentAttribute -Document $doc -Element progress -Name value -Value '0'
        Set-Running $true
        Start-NextBatch
    }

    function Stop-Hashing {
        if (-not $job.Running) { return }
        $job.Running = $false
        # A request, not a guarantee: the worker may finish its current file first.
        if ($null -ne $job.Task) { Stop-NativeHTMLKitTask -Task $job.Task }
    }

    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element start -Callback { Start-Hashing }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element cancel -Callback { Stop-Hashing }

    Set-NativeHTMLKitReady -Application $app

    if ($SelfTest) {
        function Wait-For([scriptblock]$Condition) {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            while (-not (& $Condition)) {
                if ($clock.ElapsedMilliseconds -gt 60000) { throw "timed out waiting for: $Condition" }
                $null = Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 100
            }
        }
        Start-Hashing
        Wait-For { -not $job.Running }
        $status = Get-NativeHTMLKitDocumentText -Document $doc -Element status
        if ($status -ne "Done: $($job.Files.Count) file(s).") { throw "unexpected status: $status" }
        $me = $job.Results[$PSCommandPath]
        $expected = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($null -eq $me -or $me.Hash -ne $expected) { throw 'hash of this script is wrong' }
        if ((Find-NativeHTMLKitElement -Document $doc -Selector '#rows tr').matched_nodes -ne $job.Files.Count) { throw 'row count mismatch' }
        # Cancellation: a slow worker that is stopped reports OperationCanceledException.
        $script:cancelled = $null
        $slow = Start-NativeHTMLKitTask -Application $app -ScriptBlock { Start-Sleep -Seconds 30 } -OnFailed { param($f) $script:cancelled = $f.GetType().Name }
        Stop-NativeHTMLKitTask -Task $slow
        Wait-For { $null -ne $script:cancelled }
        if ($script:cancelled -ne 'OperationCanceledException') { throw "unexpected failure type: $script:cancelled" }
        $state = Receive-NativeHTMLKitTask -Task $slow
        if (-not $state.Completed) { throw 'a stopped task is reported as completed' }
        [Console]::Out.WriteLine('SELFTEST PASS 11-background-checksums')
        $null = Request-NativeHTMLKitQuit -Application $app
    }

    Wait-NativeHTMLKit -Application $app -UntilShutdown
} finally {
    Close-NativeHTMLKit -Application $app
}
