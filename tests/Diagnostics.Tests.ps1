# SDK diagnostics: session correlation, level gating, bounded history with disclosed loss,
# privacy of the explicit support bundle (sentinel secrets), and the "Submit did nothing"
# correlation chain against a local peer. Pester 5+. PowerShell 7.2+ or Windows PowerShell 5.1.
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module $script:ModuleManifest -Force -ErrorAction Stop
    $script:Module = Get-Module NativeHTMLKit
    $script:Shell = (Get-Process -Id $PID).Path
    function Clear-Diagnostics { & $script:Module { $script:NHKDiagnosticHistory.Clear(); $script:NHKDiagnosticDropped = [long]0 } }
    function Get-Records { @(& $script:Module { $script:NHKDiagnosticHistory.ToArray() }) }
    function Invoke-Child([string]$Command, [hashtable]$Environment = @{}) {
        $saved = @{}
        foreach ($k in $Environment.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Environment[$k]) }
        # -EncodedCommand: Windows PowerShell 5.1 strips embedded double quotes from native arguments.
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("Import-Module '$($script:ModuleManifest)'; " + $Command))
        try { & $script:Shell -NoProfile -NonInteractive -EncodedCommand $encoded }
        finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
    }
    function Expand-Bundle($Zip) {
        $dir = Join-Path $TestDrive ('bundle-' + [guid]::NewGuid().ToString('N'))
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($Zip, $dir)
        return $dir
    }
}
AfterAll { Remove-Item Env:NATIVEHTMLKIT_DIAGNOSTICS -ErrorAction SilentlyContinue }

Describe 'Diagnostic session identity' {
    It 'keeps a caller-provided ID in the Core alphabet ([A-Za-z0-9._:-], up to 128)' {
        $id = 'cli.run:2026-11-15_ab-01'
        $out = Invoke-Child '$r = Get-NativeHTMLKitDiagnosticReport; "$($r.SessionId)|$($r.SessionReplaced)|$env:NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID"' @{ NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID = $id }
        $out | Should -Be "$id|False|$id"
    }
    It 'replaces an invalid ID, discloses that, and exports the new one to child processes' {
        $out = Invoke-Child '$r = Get-NativeHTMLKitDiagnosticReport; $child = & (Get-Process -Id $PID).Path -NoProfile -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(''$env:NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID''))); "$($r.SessionId)|$($r.SessionReplaced)|$child"' @{ NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID = 'not valid!' }
        $parts = $out -split '\|'
        $parts[0] | Should -Match '^nhk-ps-[0-9a-f]{32}$'
        $parts[1] | Should -Be 'True'
        $parts[2] | Should -Be $parts[0]
    }
}

Describe 'Diagnostic levels, bounds and the explicit support bundle' {
    BeforeAll {
        $script:S = 'NHKSENTINEL7f3a9c'
        $script:SecretToken = '7e57ab1e' * 8   # a distinctive token that must never reach the bundle
        $script:mock = Start-MockHost -Token $script:SecretToken
        $env:NATIVEHTMLKIT_DIAGNOSTICS = 'trace'
        $script:app = Connect-NativeHTMLKit -Endpoint $script:mock.Endpoint -Token $script:SecretToken
        $script:win = New-NativeHTMLKitWindow -Application $script:app -Title "$($script:S) title"
        $script:doc = Open-NativeHTMLKitHtml -Window $script:win -Html "<form id='f'><input id='name' value='$($script:S)'></form><p id='status'></p>"
    }
    AfterAll {
        Close-NativeHTMLKit -Application $script:app; Stop-MockHost $script:mock
        $env:NATIVEHTMLKIT_DIAGNOSTICS = $null
    }

    It 'records nothing below the configured level' {
        Clear-Diagnostics
        $env:NATIVEHTMLKIT_DIAGNOSTICS = 'off'
        $null = Get-NativeHTMLKitWindow -Window $script:win
        try { $null = Invoke-NativeHTMLKitRpc -Application $script:app -Method 'mock.error_echo' -Parameters @{ code = -32003; text = 'x' } } catch { }
        @(Get-Records).Count | Should -Be 0
        $env:NATIVEHTMLKIT_DIAGNOSTICS = 'normal'
        $null = Get-NativeHTMLKitWindow -Window $script:win
        try { $null = Invoke-NativeHTMLKitRpc -Application $script:app -Method 'mock.error_echo' -Parameters @{ code = -32003; text = 'x' } } catch { }
        $events = @(Get-Records | ForEach-Object { $_.event })
        $events | Should -Contain 'rpc.rejected'
        $events | Should -Not -Contain 'rpc.started'
        @(Get-Records | Where-Object { $_.level -notin 'ERROR', 'WARN' }).Count | Should -Be 0
        $rejected = @(Get-Records | Where-Object { $_.event -eq 'rpc.rejected' })[0]
        $rejected.error_code | Should -Be -32003
        $rejected.request_id | Should -Match '^ps-\d+$'
        $env:NATIVEHTMLKIT_DIAGNOSTICS = 'trace'
    }

    It 'bounds the history and discloses every dropped record' {
        Clear-Diagnostics
        & $script:Module { $script:NHKDiagnosticLimit = 10 }
        try {
            for ($i = 0; $i -lt 25; $i++) { & $script:Module { Write-NativeHTMLKitDiagnostic -Event 'test.fill' -Level 'ERROR' } }
            $r = Get-NativeHTMLKitDiagnosticReport
            $r.RecordCount | Should -Be 10
            $r.DroppedRecords | Should -Be 15
            $zip = Join-Path $TestDrive 'overflow.zip'
            $null = Export-NativeHTMLKitSupportBundle -Path $zip
            $manifest = Get-Content -Raw -LiteralPath (Join-Path (Expand-Bundle $zip) 'manifest.json') | ConvertFrom-Json
            $manifest.dropped | Should -Be 15
            $manifest.complete | Should -BeFalse
        } finally { & $script:Module { $script:NHKDiagnosticLimit = 2048 }; Clear-Diagnostics }
    }

    It 'correlates a submit event, its callback, RPCs, a background task and the UI update at trace level' {
        Clear-Diagnostics
        $script:done = $false
        $sub = Register-NativeHTMLKitDocumentEvent -Document $script:doc -Type submit -Element f -Callback {
            Set-NativeHTMLKitDocumentText -Document $script:doc -Element status -Text 'Saving'
            $null = Start-NativeHTMLKitTask -Application $script:app -ScriptBlock { 'saved' } -OnCompleted {
                Set-NativeHTMLKitDocumentText -Document $script:doc -Element status -Text 'Saved'; $script:done = $true }
        }
        $null = Invoke-NativeHTMLKitDocumentCommand -Document $script:doc -Operation emit -Parameters @{ events = @(@{ type = 'submit'; element = 'f' }) }
        Wait-Until { $script:done } $script:app 10 | Should -BeTrue
        Get-NativeHTMLKitDocumentText -Document $script:doc -Element status | Should -Be 'Saved'
        Unregister-NativeHTMLKitDocumentEvent -Subscription $sub
        $records = @(Get-Records)
        function IndexOf([scriptblock]$Where, [int]$After = -1) {
            for ($i = $After + 1; $i -lt $records.Count; $i++) { if (& $Where $records[$i]) { return $i } }
            throw "record not found after index $After"
        }
        $session = (Get-NativeHTMLKitDiagnosticReport).SessionId
        @($records | Where-Object { $_.session_id -ne $session }).Count | Should -Be 0
        $n = IndexOf { param($r) $r.event -eq 'host.notification' -and $r.context.event_type -eq 'submit' -and $r.context.document_id -eq $script:doc.Id }
        $cb = IndexOf { param($r) $r.event -eq 'callback.started' -and $r.context.role -eq 'document_event' -and $r.context.event_type -eq 'submit' } $n
        $rpc = IndexOf { param($r) $r.event -eq 'rpc.started' -and $r.context.method -eq 'document.command' } $cb
        $id = $records[$rpc].request_id
        $ok = IndexOf { param($r) $r.event -eq 'rpc.completed' -and $r.request_id -eq $id } $rpc
        $task = IndexOf { param($r) $r.event -eq 'task.started' } $ok
        $taskId = $records[$task].context.task_id
        $cbEnd = IndexOf { param($r) $r.event -eq 'callback.completed' -and $r.context.role -eq 'document_event' } $task
        $taskDone = IndexOf { param($r) $r.event -eq 'task.completed' -and $r.context.task_id -eq $taskId } $cbEnd
        $ui = IndexOf { param($r) $r.event -eq 'rpc.completed' -and $r.context.method -eq 'document.command' } $taskDone
        $null = IndexOf { param($r) $r.event -eq 'callback.completed' -and $r.context.role -eq 'task_completion' -and $r.context.task_id -eq $taskId } $ui
        $records[$ok].duration_ms | Should -BeGreaterOrEqual 0
    }

    It 'never puts values, tokens, paths, messages or URLs into the bundle, and writes one only on request' {
        $S = $script:S
        $before = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'nativehtmlkit-support-*' -or $_.Name -like '*.zip' } | ForEach-Object FullName)
        Clear-Diagnostics
        $folder = Join-Path $TestDrive "$S folder"
        $null = New-Item -ItemType Directory -Path $folder
        $file = Join-Path $folder "$S.html"; Set-Content -LiteralPath $file -Value '<p>x</p>'
        $script:doc = Open-NativeHTMLKitFile -Window $script:win -Path $file -AssetRoot $folder
        Set-NativeHTMLKitDocumentText -Document $script:doc -Element status -Text "$S text"
        Set-NativeHTMLKitDocumentValue -Document $script:doc -Element name -Value "$S value"
        $null = Invoke-NativeHTMLKitDocumentCommand -Document $script:doc -Operation echo -Parameters @{ url = "https://example.invalid/?q=$S"; html = "<b>$S</b>" }
        try { $null = Invoke-NativeHTMLKitRpc -Application $script:app -Method 'mock.error_echo' -Parameters @{ code = -32003; text = "$S rejected at $folder" } } catch { }
        Register-NativeHTMLKitNotification -Application $script:app -Method 'test.echo' -Callback { param($p) throw "$($p.text) from notification" }
        $null = Invoke-NativeHTMLKitRpc -Application $script:app -Method 'mock.notify_echo' -Parameters @{ text = $S }
        $sub = Register-NativeHTMLKitDocumentEvent -Document $script:doc -Type click -Callback { throw "$S handler at $folder" }
        $null = Invoke-NativeHTMLKitDocumentCommand -Document $script:doc -Operation emit -Parameters @{ events = @(@{ type = 'click'; element = 'name' }) }
        $t = Start-NativeHTMLKitTask -Application $script:app -ArgumentList @($S) -ScriptBlock { param($s) throw "$s task failure" } -OnFailed { param($e) throw "$($e.Message) again" }
        $null = Receive-NativeHTMLKitTask -Task $t -Wait -TimeoutMilliseconds 10000
        [void](Wait-NativeHTMLKit -Application $script:app -TimeoutMilliseconds 200)
        try { $null = Invoke-NativeHTMLKitRpc -Application $script:app -Method 'mock.never' -TimeoutMilliseconds 100 } catch { }
        Unregister-NativeHTMLKitDocumentEvent -Subscription $sub
        Register-NativeHTMLKitNotification -Application $script:app -Method 'test.echo' -Callback $null
        $script:app.CallbackFailures | Should -BeGreaterOrEqual 3

        $after = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'nativehtmlkit-support-*' -or $_.Name -like '*.zip' } | ForEach-Object FullName)
        @($after | Where-Object { $_ -notin $before }).Count | Should -Be 0   # nothing exported implicitly

        $zip = Join-Path $TestDrive 'support.zip'
        $null = Export-NativeHTMLKitSupportBundle -Path $zip -Application $script:app
        $dir = Expand-Bundle $zip
        @(Get-ChildItem -LiteralPath $dir -Recurse -File | ForEach-Object Name | Sort-Object) | Should -Be @('manifest.json', 'timeline.jsonl')
        $all = (Get-ChildItem -LiteralPath $dir -Recurse -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
        $all | Should -Not -Match $S
        $all | Should -Not -Match ([regex]::Escape($TestDrive))
        $all | Should -Not -Match ([regex]::Escape([IO.Path]::GetTempPath().TrimEnd('\', '/')))
        $all | Should -Not -Match 'example\.invalid'
        $all | Should -Not -Match 'secret'
        $all | Should -Not -Match $script:SecretToken
        $timeline = @(Get-Content -LiteralPath (Join-Path $dir 'timeline.jsonl') | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        $events = @($timeline | ForEach-Object { $_.event })
        @($events | Where-Object { $_ -eq 'callback.failed' }).Count | Should -BeGreaterOrEqual 3
        $events | Should -Contain 'rpc.rejected'
        $events | Should -Contain 'rpc.timeout'
        $events | Should -Contain 'task.failed'
        $manifest = Get-Content -Raw -LiteralPath (Join-Path $dir 'manifest.json') | ConvertFrom-Json
        $manifest.sanitized | Should -BeTrue
        $manifest.includes_raw_host_output | Should -BeFalse
        $manifest.connection.CallbackFailures | Should -Be $script:app.CallbackFailures
        $manifest.host_counters.sink_dropped_records | Should -Be 3
        $manifest.host_counters.backend_omitted_records | Should -Be 1
    }

    It 'resolves a relative bundle path against the PowerShell location and refuses to overwrite' {
        Push-Location -LiteralPath $TestDrive
        try {
            $item = Export-NativeHTMLKitSupportBundle -Path 'relative-bundle.zip'
            $item.FullName | Should -Be (Join-Path $TestDrive 'relative-bundle.zip')
            { Export-NativeHTMLKitSupportBundle -Path 'relative-bundle.zip' } | Should -Throw '*already exists*'
            { Export-NativeHTMLKitSupportBundle -Path 'bundle.txt' } | Should -Throw '*.zip*'
        } finally { Pop-Location }
    }

    It 'reports connection loss counters and only the numeric host counters' {
        $r = Get-NativeHTMLKitDiagnosticReport -Application $script:app
        $r.Connection.DroppedNotifications | Should -Be 0
        $r.HostCounters.sink_capacity_records | Should -Be 4096
        $r.HostCounters.dropped_notifications | Should -Be 5        # Core 1.0.3 backpressure counter
        @($r.HostCounters.Keys) | Should -Not -Contain 'note'
    }
}
