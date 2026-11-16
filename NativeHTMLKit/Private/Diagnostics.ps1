# Local-first diagnostics (in-memory bounded history; export explicitly).
# Not a telemetry service. Never records RPC parameters/results, form data,
# exception messages, paths, URLs or credentials: only fixed event names,
# identifiers, numbers and short [A-Za-z0-9_.:-] tokens survive redaction.
$script:NHKDiagnosticHistory = New-Object 'System.Collections.Generic.Queue[object]'
$script:NHKDiagnosticDropped = [long]0
$script:NHKDiagnosticLimit = 2048
# Same alphabet and length as the Core host accepts, so one ID correlates the
# launcher, the host's stderr records ("diagnostic_session_id") and the backend.
$script:NHKSessionPattern = '^[A-Za-z0-9._:-]{1,128}$'
$script:NHKDiagnosticSessionReplaced = $false
$script:NHKDiagnosticSession = [Environment]::GetEnvironmentVariable('NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID')
if ([string]::IsNullOrEmpty($script:NHKDiagnosticSession) -or $script:NHKDiagnosticSession -cnotmatch $script:NHKSessionPattern) {
    $script:NHKDiagnosticSessionReplaced = -not [string]::IsNullOrEmpty($script:NHKDiagnosticSession)
    $script:NHKDiagnosticSession = 'nhk-ps-' + [guid]::NewGuid().ToString('N')
    # Inherited by the native host and, through it, by the backend process.
    [Environment]::SetEnvironmentVariable('NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID', $script:NHKDiagnosticSession)
}

# Allow-lists for identifier-position context values. Anything else in these keys, and any
# string under a key not listed in $script:NHKDiagnosticKeyRules, is exported as [REDACTED]:
# the shape of a value never decides whether caller- or host-supplied text is exported.
$script:NHKProtocolMethods = @(
    'app.activate','app.activated','app.before_quit','app.force_quit','app.ready','app.request_quit','app.shutdown',
    'bitmap.close','bitmap.create','bitmap.present','clipboard.read_text','clipboard.write_text','desktop.open_external',
    'desktop.paths','desktop.preferences','desktop.preferences_changed','desktop.reveal_file','dialog.choose_folder',
    'dialog.open_files','dialog.save_file','document.command','document.error','document.event','document.get',
    'document.load','document.unload','host.capabilities','host.diagnostics','host.hello','probe.get_text','probe.set_text',
    'request.cancel','request.cancelled','window.before_close','window.create','window.event','window.get','window.list',
    'window.request_attention','window.request_close','window.set')
$script:NHKDomEventTypes = @(
    'click','dblclick','auxclick','contextmenu','input','beforeinput','change','submit','reset','invalid','keydown','keyup',
    'focus','blur','focusin','focusout','pointerdown','pointerup','pointermove','pointerover','pointerout','pointerenter',
    'pointerleave','pointercancel','mousedown','mouseup','mousemove','mouseover','mouseout','mouseenter','mouseleave',
    'wheel','scroll','compositionstart','compositionupdate','compositionend','dragstart','drag','dragenter','dragover',
    'dragleave','dragend','drop','toggle','close','cancel','select','selectionchange','copy','cut','paste','error','load')
$script:NHKWindowEventTypes = @('closed','close_requested','focused','resized','moved','dropped_files','dropped_text','text',
    'scale_factor_changed','theme_changed','minimized','maximized','restored')
$script:NHKCallbackRoles = @('document_event','notification','host_request','task_completion')
$script:NHKDiagnosticKeyRules = @{
    method = { param($v) $script:NHKProtocolMethods -ccontains $v }
    event_type = { param($v) $script:NHKDomEventTypes -ccontains $v }
    type = { param($v) $script:NHKWindowEventTypes -ccontains $v }
    role = { param($v) $script:NHKCallbackRoles -ccontains $v }
    exception_type = { param($v) $v -cmatch '^[A-Za-z][A-Za-z0-9]{0,63}$' }
    task_id = { param($v) $v -cmatch '^[0-9a-f]{32}$' }
    window_id = { param($v) $v -cmatch '^[A-Za-z0-9-]{1,24}$' }
    document_id = { param($v) $v -cmatch '^[A-Za-z0-9-]{1,24}$' }
}

function Get-NativeHTMLKitDiagnosticRank {
    param([string]$Level)
    switch (([string]$Level).Trim().ToLowerInvariant()) { 'trace' { 3 } 'debug' { 2 } 'off' { 0 } default { 1 } }
}

function Test-NativeHTMLKitDiagnosticEnabled {
    # Cheap gate so hot paths do not build context tables that would be discarded.
    param([ValidateSet('ERROR','WARN','INFO','DEBUG','TRACE')][string]$Level = 'DEBUG')
    $required = switch ($Level) { 'TRACE' { 3 } 'DEBUG' { 2 } 'INFO' { 2 } default { 1 } }
    return ((Get-NativeHTMLKitDiagnosticRank (Get-NativeHTMLKitSdkDiagnosticLevel)) -ge $required)
}

function Get-NativeHTMLKitSdkDiagnosticLevel {
    # One switch for SDK, host and backend. (The 0.1.0 interim off->normal mapping is gone:
    # Core 1.0.3 relays backend output at every level, NHK-CROSS-0007.)
    return [Environment]::GetEnvironmentVariable('NATIVEHTMLKIT_DIAGNOSTICS')
}

function ConvertTo-NativeHTMLKitSafeValue {
    # Allow-list redaction of one context value. Numbers and booleans are kept; strings only when
    # their key has a rule and the value passes it.
    param([string]$Key, $Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool] -or $Value -is [int] -or $Value -is [long]) { return $Value }
    if ($Value -is [double]) { return [Math]::Round($Value, 3) }
    $rule = $script:NHKDiagnosticKeyRules[$Key]
    if ($null -ne $rule -and (& $rule ([string]$Value))) { return [string]$Value }
    return '[REDACTED]'
}


function Write-NativeHTMLKitDiagnostic {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Alias('Event')][string]$EventName,
          [ValidateSet('ERROR','WARN','INFO','DEBUG','TRACE')][string]$Level = 'DEBUG',
          [hashtable]$Context = @{}, [string]$RequestId, $DurationMs, $ErrorCode)
    # Diagnostics must never throw into application/transport paths.
    try {
        if (-not (Test-NativeHTMLKitDiagnosticEnabled $Level)) { return }
        if ($EventName -cnotmatch '^[A-Za-z][A-Za-z0-9_.-]{0,63}$') { $EventName = 'diagnostics.invalid_event_name' }
        $safe = @{}
        foreach ($key in $Context.Keys) {
            $name = [string]$key
            if ($name -cnotmatch '^[A-Za-z][A-Za-z0-9_.-]{0,63}$') { continue }
            if ($name -match '(?i)token|password|secret|credential|authorization|cookie|api.?key|content|payload|body|html|path|url|text|value|filename|message') {
                $safe[$name] = '[REDACTED]'
            } else {
                $safe[$name] = ConvertTo-NativeHTMLKitSafeValue $name $Context[$key]
            }
        }
        if ($script:NHKDiagnosticHistory.Count -ge $script:NHKDiagnosticLimit) {
            [void]$script:NHKDiagnosticHistory.Dequeue()
            $script:NHKDiagnosticDropped++
        }
        $record = [ordered]@{
            schema_version = 1; timestamp = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            session_id = $script:NHKDiagnosticSession; component = 'powershell-sdk'
            pid = $PID; level = $Level; event = $EventName
        }
        if ($RequestId) { $record.request_id = $(if ($RequestId -cmatch '^(ps-[0-9]{1,12}|host:[a-z_]{1,24}:[0-9]{1,12})$') { $RequestId } else { '[REDACTED]' }) }
        if ($null -ne $DurationMs) { $record.duration_ms = [long]$DurationMs }
        if ($null -ne $ErrorCode) { $record.error_code = [long]$ErrorCode }
        $record.context = $safe
        $script:NHKDiagnosticHistory.Enqueue($record)
    } catch { $null = $_ }  # by design: a diagnostics failure must not fail the app
}

function Get-NativeHTMLKitHostLossCounters {
    # Only the numeric loss/capacity counters of host.diagnostics; nothing else from the host.
    param($Application)
    $counters = [ordered]@{}
    $result = Invoke-NativeHTMLKitRpc -Application $Application -Method 'host.diagnostics' -TimeoutMilliseconds 5000
    $source = Get-NativeHTMLKitField $result 'logging' $result
    # dropped_notifications (Core 1.0.3): window/document events the host dropped under backpressure.
    foreach ($name in @('dropped_notifications', 'sink_dropped_records', 'backend_omitted_records', 'sink_capacity_records', 'backend_records_per_pump')) {
        $value = Get-NativeHTMLKitField $source $name
        if ($null -eq $value) { $value = Get-NativeHTMLKitField $result $name }
        if ($value -is [int] -or $value -is [long] -or $value -is [uint64]) { $counters[$name] = [long]$value }
    }
    return $counters
}

function Get-NativeHTMLKitDiagnosticReport {
    <#
    .SYNOPSIS
    Returns local SDK diagnostic counters (session, record and loss counts), optionally for one application.
    .DESCRIPTION
    With -Application the report adds that connection's queue-loss and callback-failure counters and,
    when the host is connected, the host's own logging loss counters (host.diagnostics). Values,
    tokens and paths are never included.
    #>
    [CmdletBinding()]
    param([object]$Application)
    $report = [ordered]@{
        SchemaVersion = 1; SessionId = $script:NHKDiagnosticSession
        Level = Get-NativeHTMLKitSdkDiagnosticLevel
        RecordCount = $script:NHKDiagnosticHistory.Count
        RecordLimit = $script:NHKDiagnosticLimit
        DroppedRecords = $script:NHKDiagnosticDropped
        SessionReplaced = $script:NHKDiagnosticSessionReplaced
    }
    if ($null -ne $Application) {
        if (-not (Test-NativeHTMLKitType $Application 'NativeHTMLKit.Application')) { throw 'Expected a NativeHTMLKit.Application from Connect-NativeHTMLKit' }
        $t = $Application.Transport
        $report.Connection = [ordered]@{
            Closed = $Application.Closed; Disconnected = $Application.Disconnected
            ShutdownRequested = $Application.ShutdownRequested
            ReceivedMessages = $t.ReceivedMessages; PendingRequests = $t.PendingCount
            QueuedMessages = $t.QueuedMessages
            DroppedNotifications = $t.DroppedNotifications; RejectedHostRequests = $t.RejectedRequests
            DeferredDropped = $Application.DroppedNotifications
            CallbackFailures = $Application.CallbackFailures
            ActiveTasks = @(Get-NativeHTMLKitTaskStates $Application | Where-Object { -not $_.Completed }).Count
            CancellationPendingTasks = @(Get-NativeHTMLKitTaskStates $Application | Where-Object { $_.StopRequested -and -not $_.AsyncResult.IsCompleted }).Count
        }
        $report.HostCounters = $null
        $report.HostCountersError = $null
        if (-not $Application.Closed -and -not $Application.Disconnected) {
            try { $report.HostCounters = Get-NativeHTMLKitHostLossCounters $Application }
            catch { $report.HostCountersError = $_.Exception.GetType().Name }
        } else { $report.HostCountersError = 'NotConnected' }
    }
    return [pscustomobject]$report
}

function Export-NativeHTMLKitSupportBundle {
    <#
    .SYNOPSIS
    Saves a local, sanitized diagnostics ZIP (manifest.json, timeline.jsonl) only when called. No upload.
    .DESCRIPTION
    The bundle holds redacted SDK records and counters only: no RPC parameters or results, form
    values, tokens, file paths, screenshots, or raw host/backend stdout/stderr (which may contain
    personal data). -Application adds that connection's loss counters.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [object]$Application)
    # Resolve against the PowerShell location, not the process working directory.
    $destination = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
    if (Test-Path -LiteralPath $destination) { throw "Support bundle already exists: $destination" }
    if (-not $destination.EndsWith('.zip', [StringComparison]::OrdinalIgnoreCase)) { throw 'The support bundle path must end with .zip' }
    $parent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "Destination directory missing: $parent" }
    $report = Get-NativeHTMLKitDiagnosticReport -Application $Application
    $stage = Join-Path ([IO.Path]::GetTempPath()) ('nativehtmlkit-support-' + [guid]::NewGuid().ToString('N'))
    try {
        [void](New-Item -ItemType Directory -Path $stage -Force)
        $manifest = [ordered]@{
            schema_version = 1; session_id = $script:NHKDiagnosticSession
            component = 'powershell-sdk'; module_version = $script:NativeHTMLKitVersion
            record_count = $report.RecordCount; record_limit = $report.RecordLimit
            dropped = $report.DroppedRecords; complete = ($report.DroppedRecords -eq 0); sanitized = $true
            includes_raw_host_output = $false
            diagnostics_level = $(if (@('off', 'normal', 'debug', 'trace') -ccontains ([string]$report.Level).Trim().ToLowerInvariant()) { ([string]$report.Level).Trim().ToLowerInvariant() } else { 'normal' })
            powershell_version = $PSVersionTable.PSVersion.ToString()
            powershell_edition = [string]$PSVersionTable.PSEdition
        }
        if ($report.PSObject.Properties['Connection']) {
            $manifest.connection = $report.Connection
            $manifest.host_counters = $report.HostCounters
            $manifest.host_counters_error = $report.HostCountersError
        }
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText((Join-Path $stage 'manifest.json'), ($manifest | ConvertTo-Json -Depth 6), $utf8)
        $lines = @($script:NHKDiagnosticHistory.ToArray() | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 6 -Compress })
        [IO.File]::WriteAllText((Join-Path $stage 'timeline.jsonl'), (($lines -join "`n") + "`n"), $utf8)
        Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $destination -ErrorAction Stop
        return (Get-Item -LiteralPath $destination)
    } finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
