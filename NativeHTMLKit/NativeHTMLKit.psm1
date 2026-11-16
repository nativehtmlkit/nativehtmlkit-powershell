# NativeHTMLKit Core - PowerShell binding for the versioned native host protocol.
#
# Supported: PowerShell 7.2+ on Linux and Windows, Windows PowerShell 5.1.
# The Rust host owns windows, input, layout, rendering and accessibility. This
# module owns the backend side of the private, authenticated JSON-RPC channel.
#
# Threading: a .NET reader thread parses frames into a queue. Every user
# scriptblock runs on the caller's PowerShell runspace while it pumps the
# queue (Wait-NativeHTMLKit, or any RPC that waits for its reply). Notifications are
# delivered one at a time in host order; while a callback runs, nested pumps
# still answer replies and host lifecycle requests but defer further
# notifications until the callback returns.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:NativeHTMLKitVersion = '0.1.1'
$script:NativeHTMLKitHelperLoaded = $false
$script:NativeHTMLKitIsWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$script:MaximumDeferred = 128
if ($PSVersionTable.PSEdition -eq 'Core' -and $PSVersionTable.PSVersion -lt [version]'7.2') {
    throw "NativeHTMLKit requires PowerShell 7.2 or later (or Windows PowerShell 5.1); this is $($PSVersionTable.PSVersion)"
}

# Source-only PowerShell SDK helpers; no Python, Rust or remote runtime required.
. (Join-Path $PSScriptRoot 'Private/Diagnostics.ps1')
. (Join-Path $PSScriptRoot 'Private/Tasks.ps1')

# ---------------------------------------------------------------- internals --

function Initialize-NativeHTMLKitHelper {
    if ($script:NativeHTMLKitHelperLoaded) { return }
    $existing = 'NativeHTMLKit.Transport' -as [type]
    if ($null -eq $existing) {
        $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Private/NativeHTMLKit.Transport.cs'), [Text.Encoding]::UTF8)
        if ($PSVersionTable.PSEdition -ne 'Core') { $source = "#define NativeHTMLKit_NETFX`n" + $source }
        Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
        $existing = 'NativeHTMLKit.Transport' -as [type]
    }
    if ($null -eq $existing -or $null -eq $existing.GetMethod('Register') -or $null -eq ('NativeHTMLKit.MappedBitmap' -as [type]) -or $null -eq ('NativeHTMLKit.HostProcess' -as [type])) {
        throw 'An incompatible NativeHTMLKit helper is already loaded in this process. Start a new PowerShell process.'
    }
    $script:NativeHTMLKitHelperLoaded = $true
}

function Write-NativeHTMLKitLog {
    param([string]$Message)
    Write-NativeHTMLKitDiagnostic -Event 'sdk.console_message' -Level 'WARN' -Context @{ message = '[REDACTED]' }
    try { [Console]::Error.WriteLine("NativeHTMLKit: $Message"); [Console]::Error.Flush() } catch { $null = $_ }  # logging must never fail the app
}

function Format-NativeHTMLKitError {
    param($ErrorRecord)
    $text = "$($ErrorRecord.Exception.GetType().Name): $($ErrorRecord.Exception.Message)"
    $position = $ErrorRecord.InvocationInfo
    if ($null -ne $position -and $position.ScriptName) {
        $text += " ($($position.ScriptName):$($position.ScriptLineNumber))"
    }
    return $text
}

function Register-NativeHTMLKitCallbackFailure {
    # One place for every isolated user-callback failure: counted on the application
    # (Get-NativeHTMLKitDiagnosticReport -Application), recorded as a redacted
    # callback.failed diagnostic, and described on stderr for the developer.
    param($Application, [string]$Role, $ErrorRecord, [hashtable]$Context = @{})
    $Application.CallbackFailures++
    $Context.role = $Role
    $Context.exception_type = $ErrorRecord.Exception.GetType().Name
    Write-NativeHTMLKitDiagnostic -Event 'callback.failed' -Level 'ERROR' -Context $Context
    Write-NativeHTMLKitLog "$Role callback failed: $(Format-NativeHTMLKitError $ErrorRecord)"
}

function Get-NativeHTMLKitField {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -ne $p) { return $p.Value }
    return $Default
}

function New-NativeHTMLKitStaleError {
    param([string]$Message)
    Initialize-NativeHTMLKitHelper
    return (New-Object -TypeName 'NativeHTMLKit.StaleObjectException' -ArgumentList $Message)
}

function Test-NativeHTMLKitType {
    param($Value, [string]$TypeName)
    return ($null -ne $Value -and $Value -is [psobject] -and $Value.PSObject.TypeNames.Count -gt 0 -and
        $Value.PSObject.TypeNames[0] -eq $TypeName)
}

function Assert-NativeHTMLKitApplication {
    param($Application)
    if (-not (Test-NativeHTMLKitType $Application 'NativeHTMLKit.Application')) { throw 'Expected a NativeHTMLKit.Application from Connect-NativeHTMLKit' }
    if ($Application.Closed) { throw (New-NativeHTMLKitStaleError 'The NativeHTMLKit application connection was closed') }
    if ($Application.Disconnected) {
        throw (New-Object -TypeName 'NativeHTMLKit.DisconnectedException' -ArgumentList $Application.Transport.Failure)
    }
}
function Assert-NativeHTMLKitWindow {
    param($Window)
    if (-not (Test-NativeHTMLKitType $Window 'NativeHTMLKit.Window')) { throw 'Expected a NativeHTMLKit.Window from New-NativeHTMLKitWindow' }
    Assert-NativeHTMLKitApplication $Window.Application
    if ($Window.Closed) { throw (New-NativeHTMLKitStaleError "NativeHTMLKit window $($Window.Id) is closed") }
}
function Assert-NativeHTMLKitDocument {
    param($Document)
    if (-not (Test-NativeHTMLKitType $Document 'NativeHTMLKit.Document')) { throw 'Expected a NativeHTMLKit.Document from Open-NativeHTMLKitFile or Open-NativeHTMLKitHtml' }
    Assert-NativeHTMLKitWindow $Document.Window
    if ($Document.Retired -or $null -eq $Document.Window.Document -or
        -not [object]::ReferenceEquals($Document.Window.Document, $Document)) {
        throw (New-NativeHTMLKitStaleError 'This NativeHTMLKit document was replaced, unloaded, or its window closed')
    }
}
function Assert-NativeHTMLKitNode {
    param($Node)
    if (-not (Test-NativeHTMLKitType $Node 'NativeHTMLKit.Node')) { throw 'Expected a NativeHTMLKit.Node from Get-NativeHTMLKitNode' }
    Assert-NativeHTMLKitDocument $Node.Document
}
function Get-NativeHTMLKitDocumentIds {
    param($Document)
    Assert-NativeHTMLKitDocument $Document
    return @{ window_id = $Document.Window.Id; document_id = $Document.Id }
}

# Adds element/node targeting for commands that accept either.
function Add-NativeHTMLKitTarget {
    param([hashtable]$Parameters, $Document, [string]$Element, $Node, [switch]$Required,
          [string]$ElementKey = 'element', [string]$NodeKey = 'node')
    if ($Element -and $null -ne $Node) { throw 'Use -Element or -Node, not both' }
    if ($null -ne $Node) {
        Assert-NativeHTMLKitNode $Node
        if (-not [object]::ReferenceEquals($Node.Document, $Document)) { throw 'The node belongs to another document' }
        $Parameters[$NodeKey] = $Node.Id
    } elseif ($Element) {
        $Parameters[$ElementKey] = $Element
    } elseif ($Required) {
        throw 'An -Element id or a -Node is required'
    }
}

function Set-NativeHTMLKitDisconnected {
    param($Application)
    if ($Application.Disconnected) { return }
    $Application.Disconnected = $true
    $pending = @($Application.Pending.Values)
    foreach ($request in $pending) { $request.Failed = $true }
    # Every waiter observes Failed; nothing may stay registered on a dead connection.
    $Application.Pending.Clear()
    Write-NativeHTMLKitDiagnostic -Event 'transport.disconnected' -Level 'ERROR' -Context @{ pending_failed = $pending.Count }
    foreach ($window in @($Application.Windows.Values)) {
        $window.Closed = $true
        if ($null -ne $window.Document) { Remove-NativeHTMLKitDocumentState $window.Document }
    }
    $Application.Windows.Clear()
}

function Set-NativeHTMLKitShutdown {
    # Protocol v1: app.shutdown makes every window/document handle stale. The host sends no
    # window.event "closed" for the last window (documented v1 behaviour), so retire them here;
    # a later use throws NativeHTMLKit.StaleObjectException instead of reaching the host.
    param($Application)
    if ($Application.ShutdownRequested) { return }
    $Application.ShutdownRequested = $true
    $windows = @($Application.Windows.Values)
    foreach ($window in $windows) {
        $window.Closed = $true
        if ($null -ne $window.Document) { Remove-NativeHTMLKitDocumentState $window.Document }
    }
    $Application.Windows.Clear()
    Write-NativeHTMLKitDiagnostic -Event 'app.shutdown_received' -Level 'DEBUG' -Context @{ windows_retired = $windows.Count }
}

function Invoke-NativeHTMLKitCallback {
    # Runs one user scriptblock; returns its output as an array.
    param($Application, [scriptblock]$Callback, [object[]]$Arguments)
    if ($Application.Depth -ge $Application.MaxDepth) { throw 'NativeHTMLKit callback nesting limit (32) exceeded' }
    $Application.Depth++
    $wasDispatching = $Application.Dispatching
    $Application.Dispatching = $true
    $out = $null; $finished = $false
    try {
        # The one-shot loop is a boundary: `break`/`continue` in user code ends here instead of
        # unwinding an SDK loop (e.g. an RPC wait) and faking its result.
        do { $out = @(& $Callback @Arguments); $finished = $true } while ($false)
    } finally {
        $Application.Dispatching = $wasDispatching
        $Application.Depth--
    }
    if (-not $finished) { throw 'A NativeHTMLKit callback used break or continue outside a loop; it was stopped there' }
    return ,$out
}

function Remove-NativeHTMLKitWindowState {
    # Local bookkeeping for window.event {type:"closed"}; idempotent.
    param($Application, [string]$WindowId)
    if (-not $WindowId -or -not $Application.Windows.ContainsKey($WindowId)) { return }
    $win = $Application.Windows[$WindowId]
    $win.Closed = $true
    if ($null -ne $win.Document) { Remove-NativeHTMLKitDocumentState $win.Document }
    [void]$Application.Windows.Remove($WindowId)
}

function Invoke-NativeHTMLKitDocumentHandlers {
    param($Application, $Document, $EventObject)
    if ($null -eq $EventObject) { return }
    foreach ($pair in @(@('window_id', $Document.Window.Id), @('document_id', $Document.Id))) {
        if ($null -eq $EventObject.PSObject.Properties[$pair[0]]) {
            $EventObject.PSObject.Properties.Add((New-Object Management.Automation.PSNoteProperty($pair[0], $pair[1])))
        }
    }
    $kind = Get-NativeHTMLKitField $EventObject 'type'
    $target = Get-NativeHTMLKitField $EventObject 'element'
    $route = @(Get-NativeHTMLKitField $EventObject 'path' @())
    foreach ($entry in @($Document.Handlers.ToArray())) {
        if ($Document.Retired) { break }
        if ($entry.Type -ne $kind) { continue }
        if (-not $entry.Element -or $entry.Element -eq $target -or $route -contains $entry.Element) {
            $trace = Test-NativeHTMLKitDiagnosticEnabled 'TRACE'
            $clock = [Diagnostics.Stopwatch]::StartNew()
            if ($trace) { Write-NativeHTMLKitDiagnostic -Event 'callback.started' -Level 'TRACE' -Context @{ role = 'document_event'; event_type = $kind; document_id = $Document.Id } }
            try {
                $null = Invoke-NativeHTMLKitCallback $Application $entry.Callback @($EventObject)
                if ($trace) { Write-NativeHTMLKitDiagnostic -Event 'callback.completed' -Level 'TRACE' -DurationMs $clock.ElapsedMilliseconds -Context @{ role = 'document_event'; event_type = $kind; document_id = $Document.Id } }
            } catch { Register-NativeHTMLKitCallbackFailure $Application 'document_event' $_ @{ event_type = $kind; document_id = $Document.Id } }
        }
    }
}

function Invoke-NativeHTMLKitNotification {
    param($Application, $Message)
    $method = $Message.Method
    $params = $Message.Params
    if (Test-NativeHTMLKitDiagnosticEnabled 'TRACE') {
        $eventObject = Get-NativeHTMLKitField $params 'event'
        Write-NativeHTMLKitDiagnostic -Event 'host.notification' -Level 'TRACE' -Context @{ method = $method
            window_id = (Get-NativeHTMLKitField $params 'window_id'); document_id = (Get-NativeHTMLKitField $params 'document_id')
            type = (Get-NativeHTMLKitField $params 'type'); event_type = (Get-NativeHTMLKitField $eventObject 'type')
            }
    }
    switch -Exact ($method) {
        'app.shutdown' { Set-NativeHTMLKitShutdown $Application }
        'window.event' {
            if ((Get-NativeHTMLKitField $params 'type') -eq 'closed') { Remove-NativeHTMLKitWindowState $Application ([string](Get-NativeHTMLKitField $params 'window_id')) }
        }
        { $_ -eq 'document.event' -or $_ -eq 'document.error' } {
            $windowId = Get-NativeHTMLKitField $params 'window_id'
            if (-not $windowId -or -not $Application.Windows.ContainsKey($windowId)) { break }
            $win = $Application.Windows[$windowId]
            $doc = $win.Document
            if ($win.Closed -or $null -eq $doc -or $doc.Retired -or $doc.Id -ne (Get-NativeHTMLKitField $params 'document_id')) { break }
            if ($method -eq 'document.event') {
                $evt = Get-NativeHTMLKitField $params 'event'
                if ($null -ne $evt -and $evt -is [psobject]) { Invoke-NativeHTMLKitDocumentHandlers $Application $doc $evt }
            } else {
                $text = [string](Get-NativeHTMLKitField $params 'message' 'Document operation failed')
                if ($text.Length -gt 4096) { $text = $text.Substring(0, 4096) }
                $fatal = [bool](Get-NativeHTMLKitField $params 'fatal' $false)
                Write-NativeHTMLKitLog "document error ($($win.Id), $($doc.Id)): $text"
                try {
                    Invoke-NativeHTMLKitDocumentHandlers $Application $doc ([pscustomobject]@{ type = 'error'; message = $text; fatal = $fatal })
                } finally {
                    if ($fatal) {
                        # The host already unloaded the failed renderer. An error
                        # handler may have loaded a replacement; keep that one.
                        Remove-NativeHTMLKitDocumentState $doc
                        if ([object]::ReferenceEquals($win.Document, $doc)) { $win.Document = $null }
                    }
                }
            }
        }
    }
    if ($Application.Closed) { return }   # a handler above closed the application
    if ($Application.Notifications.ContainsKey($method)) {
        try { $null = Invoke-NativeHTMLKitCallback $Application $Application.Notifications[$method] @($params) }
        catch { Register-NativeHTMLKitCallbackFailure $Application 'notification' $_ @{ method = $method } }
    }
}

function ConvertTo-NativeHTMLKitDecision {
    param([object[]]$Output)
    if ($Output.Count -eq 0) { return $false }
    return [bool]$Output[$Output.Count - 1]
}

function Invoke-NativeHTMLKitHostRequest {
    param($Application, $Message)
    $params = $Message.Params
    $result = $null
    $failure = $null
    try {
        switch -Exact ($Message.Method) {
            'window.before_close' {
                $id = Get-NativeHTMLKitField $params 'window_id'
                $callback = $null
                if ($id -and $Application.BeforeClose.ContainsKey($id)) { $callback = $Application.BeforeClose[$id] }
                if ($null -eq $callback) { $result = @{ allow = $true } }
                else { $result = @{ allow = (ConvertTo-NativeHTMLKitDecision (Invoke-NativeHTMLKitCallback $Application $callback @($params))) } }
            }
            'app.before_quit' {
                if ($null -eq $Application.BeforeQuit) { $result = @{ allow = $true } }
                else { $result = @{ allow = (ConvertTo-NativeHTMLKitDecision (Invoke-NativeHTMLKitCallback $Application $Application.BeforeQuit @($params))) } }
            }
            'app.shutdown' { Set-NativeHTMLKitShutdown $Application; $result = @{ ok = $true } }
            default { $failure = @{ code = -32601; message = "Unknown method: $($Message.Method)" } }
        }
    } catch {
        Register-NativeHTMLKitCallbackFailure $Application 'host_request' $_ @{ method = $Message.Method }
        $failure = @{ code = -32603; message = "Callback failed: $($_.Exception.GetType().Name)" }
    }
    $allowed = $null
    if ($null -ne $result -and $result.ContainsKey('allow')) { $allowed = [bool]$result.allow }
    Write-NativeHTMLKitDiagnostic -Event 'host.request' -Level 'DEBUG' -RequestId $Message.Id -Context @{ method = $Message.Method; allow = $allowed; failed = ($null -ne $failure) }
    $envelope = @{ jsonrpc = '2.0'; id = $Message.Id }
    if ($null -ne $failure) { $envelope.error = $failure } else { $envelope.result = $result }
    try { $Application.Transport.Send($envelope) }
    catch { Set-NativeHTMLKitDisconnected $Application }
}

# Processes at most one queued message. Returns $true when one was handled.
function Invoke-NativeHTMLKitPump {
    param($Application, [int]$TimeoutMilliseconds)
    # After Close-NativeHTMLKit (also from inside a callback) nothing more is dispatched.
    if ($Application.Closed) { return $false }
    # Task completion callbacks are user code: like notifications they never run
    # inside another callback's nested pump.
    if (-not $Application.Dispatching -and $script:NHKTaskStates.Count -gt 0) {
        if ((Invoke-NativeHTMLKitTaskCompletions -Application $Application) -gt 0) { return $true }
        if ($Application.Closed) { return $false }
    }
    if (-not $Application.Dispatching -and $Application.Deferred.Count -gt 0) {
        Invoke-NativeHTMLKitNotification $Application $Application.Deferred.Dequeue()
        return $true
    }
    if ($Application.Disconnected) {
        throw (New-Object -TypeName 'NativeHTMLKit.DisconnectedException' -ArgumentList $Application.Transport.Failure)
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        # While background tasks exist, wait in short slices so a finished worker's completion
        # (or its deadline) is handled promptly even when the host sends nothing.
        $slice = $TimeoutMilliseconds
        $watchTasks = -not $Application.Dispatching -and $script:NHKTaskStates.Count -gt 0
        if ($watchTasks) {
            $left = if ($TimeoutMilliseconds -lt 0) { 50 } else { [int][Math]::Max(0, $TimeoutMilliseconds - $clock.ElapsedMilliseconds) }
            $slice = [Math]::Min(50, $left)
        }
        try { $message = $Application.Transport.Receive($slice) }
        catch {
            Set-NativeHTMLKitDisconnected $Application
            throw (New-Object -TypeName 'NativeHTMLKit.DisconnectedException' -ArgumentList $Application.Transport.Failure)
        }
        if ($null -ne $message) { break }
        if ($watchTasks -and (Invoke-NativeHTMLKitTaskCompletions -Application $Application) -gt 0) { return $true }
        if ($Application.Closed) { return $false }
        if ($TimeoutMilliseconds -ge 0 -and $clock.ElapsedMilliseconds -ge $TimeoutMilliseconds) { return $false }
        if (-not $watchTasks) { return $false }
    }
    switch -Exact ($message.Kind) {
        'response' {
            if ($Application.Pending.ContainsKey($message.Id)) { $Application.Replies[$message.Id] = $message }
        }
        'request' { Invoke-NativeHTMLKitHostRequest $Application $message }
        default {
            if ($message.Method -eq 'app.shutdown') { Set-NativeHTMLKitShutdown $Application }
            # Lifecycle bookkeeping never depends on whether the notification is deferred or dropped.
            if ($message.Method -eq 'window.event' -and (Get-NativeHTMLKitField $message.Params 'type') -eq 'closed') {
                Remove-NativeHTMLKitWindowState $Application ([string](Get-NativeHTMLKitField $message.Params 'window_id'))
            }
            if ($Application.Dispatching) {
                if ($Application.Deferred.Count -ge $script:MaximumDeferred) { $Application.DroppedNotifications++ }
                else { $Application.Deferred.Enqueue($message) }
            } else {
                Invoke-NativeHTMLKitNotification $Application $message
            }
        }
    }
    return $true
}

# ------------------------------------------------------------ connection/RPC --

function Connect-NativeHTMLKit {
    <#
    .SYNOPSIS
    Connects this PowerShell backend to the native NativeHTMLKit host that launched it.
    .DESCRIPTION
    Reads UI4ME_ENDPOINT and UI4ME_TOKEN, opens the private Unix socket or Windows
    named pipe, and authenticates with host.hello (protocol version 1). Protocol v1 is the
    public-stable wire contract (1.0) since Core 1.0.3; this module version requires Core 1.0.3
    behaviour and bundles that host.
    #>
    [CmdletBinding()]
    param(
        [string]$Endpoint = $env:UI4ME_ENDPOINT,
        [string]$Token = $env:UI4ME_TOKEN,
        [ValidateRange(1, 120000)][int]$ConnectTimeoutMilliseconds = 15000,
        # Test peers only: accept a token that is not the 64-hex-digit shape the Core host issues.
        [switch]$SkipTokenValidation
    )
    # Launch secrets leave the process environment before anything can fail, so no failure
    # path (missing value, bad shape, endpoint not listening, failed hello) leaves them for
    # child processes.
    Clear-NativeHTMLKitLaunchEnvironment
    if ([string]::IsNullOrWhiteSpace($Endpoint) -or [string]::IsNullOrWhiteSpace($Token)) {
        throw 'UI4ME_ENDPOINT and UI4ME_TOKEN come from the native host. To run a script directly, use $app = Start-NativeHTMLKitScript instead of Connect-NativeHTMLKit; or start it with Start-NativeHTMLKitHost -Manifest app.toml.'
    }
    if (-not $SkipTokenValidation -and $Token -cnotmatch '^[0-9a-fA-F]{64}$') {
        throw (New-Object -TypeName 'System.ArgumentException' -ArgumentList 'The launch token does not have the 64-hex-digit shape issued by the NativeHTMLKit host')
    }
    Initialize-NativeHTMLKitHelper
    try { $transport = New-Object -TypeName 'NativeHTMLKit.Transport' -ArgumentList @($Endpoint, $ConnectTimeoutMilliseconds) }
    catch {
        $inner = $_.Exception
        if ($inner -is [System.Management.Automation.MethodInvocationException] -and $null -ne $inner.InnerException) { $inner = $inner.InnerException }
        Write-NativeHTMLKitDiagnostic -Event 'transport.connect_failed' -Level 'ERROR' -Context @{ exception_type = $inner.GetType().Name }
        throw (New-Object -TypeName 'NativeHTMLKit.DisconnectedException' -ArgumentList @("Cannot connect to the native host endpoint ($($inner.GetType().Name))", $inner))
    }
    $app = [pscustomobject]@{
        Transport = $transport
        Hello = $null
        Windows = @{}
        Replies = @{}
        Pending = @{}
        Deferred = (New-Object 'System.Collections.Generic.Queue[object]')
        NextId = [long]0
        Depth = 0
        MaxDepth = 32
        Dispatching = $false
        Closed = $false
        Disconnected = $false
        ShutdownRequested = $false
        Ready = $false
        BeforeQuit = $null
        BeforeClose = @{}
        Notifications = @{}
        DroppedNotifications = [long]0
        CallbackFailures = [long]0
        DirectStart = $false
    }
    $app.PSObject.TypeNames.Insert(0, 'NativeHTMLKit.Application')
    try {
        $app.Hello = Invoke-NativeHTMLKitRpc -Application $app -Method 'host.hello' -Parameters @{
            token = $Token; protocol_version = 1
            client = @{ name = 'nativehtmlkit-powershell'; version = $script:NativeHTMLKitVersion }
        }
        if ($app.Hello.protocol_version -ne 1) { throw 'Unsupported NativeHTMLKit Core protocol version' }
        Write-NativeHTMLKitDiagnostic -Event 'host.authenticated' -Level 'DEBUG' -Context @{ protocol_version = 1 }
        return $app
    } catch {
        $app.Closed = $true
        $transport.Dispose()
        throw
    }
}

function Clear-NativeHTMLKitLaunchEnvironment {
    foreach ($wireName in @('UI4ME_ENDPOINT', 'UI4ME_TOKEN', 'UI4ME_APP_ID', 'UI4ME_PROTOCOL_VERSION')) {
        [Environment]::SetEnvironmentVariable($wireName, $null)
    }
}

function Start-NativeHTMLKitRpc {
    <# .SYNOPSIS Sends a host request without waiting; returns a NativeHTMLKit.Request for Wait-NativeHTMLKitRpc or Stop-NativeHTMLKitRpc. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Application, [Parameter(Mandatory)][string]$Method,
          [System.Collections.IDictionary]$Parameters = @{})
    Assert-NativeHTMLKitApplication $Application
    # Unawaited requests keep their reply until awaited or stopped: bound them (documented 128).
    if ($Application.Pending.Count -ge 128) {
        throw (New-Object -TypeName 'NativeHTMLKit.BusyException' -ArgumentList 'NativeHTMLKit has 128 outstanding host requests; await (Wait-NativeHTMLKitRpc) or stop (Stop-NativeHTMLKitRpc) earlier ones first')
    }
    $Application.NextId++
    $id = 'ps-' + $Application.NextId.ToString([Globalization.CultureInfo]::InvariantCulture)
    $request = [pscustomobject]@{ Application = $Application; Id = $id; Method = $Method
        Completed = $false; Cancelled = $false; Failed = $false; Clock = [Diagnostics.Stopwatch]::StartNew() }
    $request.PSObject.TypeNames.Insert(0, 'NativeHTMLKit.Request')
    $Application.Transport.Register($id)
    $Application.Pending[$id] = $request
    try {
        $Application.Transport.Send(@{ jsonrpc = '2.0'; id = $id; method = $Method; params = $Parameters })
    } catch {
        [void]$Application.Pending.Remove($id)
        $Application.Transport.Forget($id)
        Write-NativeHTMLKitDiagnostic -Event 'rpc.send_failed' -Level 'ERROR' -RequestId $id -Context @{ method = $Method; exception_type = $_.Exception.GetType().Name }
        throw
    }
    if (Test-NativeHTMLKitDiagnosticEnabled 'TRACE') { Write-NativeHTMLKitDiagnostic -Event 'rpc.started' -Level 'TRACE' -RequestId $id -Context @{ method = $Method } }
    return $request
}

function Stop-NativeHTMLKitRpc {
    <# .SYNOPSIS Requests cancellation (for example closes a native dialog). Not a rollback. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request)
    if (-not (Test-NativeHTMLKitType $Request 'NativeHTMLKit.Request')) { throw 'Expected a NativeHTMLKit.Request from Start-NativeHTMLKitRpc' }
    if ($Request.Completed -or $Request.Cancelled) { return }
    $app = $Request.Application
    $Request.Cancelled = $true
    [void]$app.Pending.Remove($Request.Id)
    [void]$app.Replies.Remove($Request.Id)
    $app.Transport.Forget($Request.Id)
    if (-not $app.Closed -and -not $app.Disconnected) {
        try { $app.Transport.Send(@{ jsonrpc = '2.0'; method = 'request.cancel'; params = @{ id = $Request.Id } }) }
        catch { Set-NativeHTMLKitDisconnected $app }
    }
}

function Wait-NativeHTMLKitRpc {
    <#
    .SYNOPSIS
    Waits for a request's result while pumping events. -1 waits indefinitely.
    .DESCRIPTION
    On timeout the request is cancelled and NativeHTMLKit.RpcTimeoutException is thrown;
    the native outcome is then unknown. Host errors throw NativeHTMLKit.RpcException
    with Code, RpcMessage and RpcData.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request, [ValidateRange(-1, 2147483647)][int]$TimeoutMilliseconds = 15000)
    if (-not (Test-NativeHTMLKitType $Request 'NativeHTMLKit.Request')) { throw 'Expected a NativeHTMLKit.Request from Start-NativeHTMLKitRpc' }
    $app = $Request.Application
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        if ($Request.Cancelled) { throw (New-NativeHTMLKitStaleError "NativeHTMLKit request $($Request.Method) was cancelled") }
        if ($Request.Completed) { throw 'This NativeHTMLKit request was already awaited' }
        if ($app.Replies.ContainsKey($Request.Id)) {
            $message = $app.Replies[$Request.Id]
            [void]$app.Replies.Remove($Request.Id)
            [void]$app.Pending.Remove($Request.Id)
            $Request.Completed = $true
            if ($message.IsError) {
                Write-NativeHTMLKitDiagnostic -Event 'rpc.rejected' -Level 'ERROR' -RequestId $Request.Id -DurationMs $Request.Clock.ElapsedMilliseconds -ErrorCode $message.ErrorCode -Context @{ method = $Request.Method }
                throw (New-Object -TypeName 'NativeHTMLKit.RpcException' -ArgumentList @(
                    $Request.Method, $message.ErrorCode, $message.ErrorMessage, $message.ErrorData))
            }
            if (Test-NativeHTMLKitDiagnosticEnabled 'TRACE') { Write-NativeHTMLKitDiagnostic -Event 'rpc.completed' -Level 'TRACE' -RequestId $Request.Id -DurationMs $Request.Clock.ElapsedMilliseconds -Context @{ method = $Request.Method } }
            return $message.Result
        }
        if ($Request.Failed -or $app.Closed -or $app.Disconnected) {
            [void]$app.Pending.Remove($Request.Id)
            Write-NativeHTMLKitDiagnostic -Event 'rpc.disconnected' -Level 'ERROR' -RequestId $Request.Id -DurationMs $Request.Clock.ElapsedMilliseconds -Context @{ method = $Request.Method; outcome_unknown = $true }
            $reason = if ($app.Closed) { 'the application connection was closed' } else { $app.Transport.Failure }
            throw (New-Object -TypeName 'NativeHTMLKit.DisconnectedException' -ArgumentList "NativeHTMLKit $($Request.Method) did not complete: $reason")
        }
        $interval = 250
        if ($TimeoutMilliseconds -ge 0) {
            $remaining = $TimeoutMilliseconds - $clock.ElapsedMilliseconds
            if ($remaining -le 0) {
                Write-NativeHTMLKitDiagnostic -Event 'rpc.timeout' -Level 'ERROR' -RequestId $Request.Id -DurationMs $Request.Clock.ElapsedMilliseconds -Context @{ method = $Request.Method; outcome_unknown = $true }
                Stop-NativeHTMLKitRpc $Request
                throw (New-Object -TypeName 'NativeHTMLKit.RpcTimeoutException' -ArgumentList "NativeHTMLKit $($Request.Method) timed out after $TimeoutMilliseconds ms. Its outcome is unknown; cancellation was requested.")
            }
            $interval = [int][Math]::Min(250, $remaining)
        }
        try { [void](Invoke-NativeHTMLKitPump $app $interval) }
        catch [NativeHTMLKit.DisconnectedException] {
            # Loop once more: a reply that arrived before the disconnect still wins;
            # otherwise the Failed branch reports this request and unregisters it.
            $Request.Failed = $true
        }
    }
}

function Invoke-NativeHTMLKitRpc {
    <#
    .SYNOPSIS
    Calls a native host JSON-RPC method and returns its result.
    .DESCRIPTION
    Events and lifecycle requests keep being processed while waiting. The default
    timeout is 15 seconds, or unlimited for dialog.* methods (user operated).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Application, [Parameter(Mandatory)][string]$Method,
          [System.Collections.IDictionary]$Parameters = @{}, [ValidateRange(-1, 2147483647)][int]$TimeoutMilliseconds = 15000)
    if (-not $PSBoundParameters.ContainsKey('TimeoutMilliseconds') -and $Method.StartsWith('dialog.')) { $TimeoutMilliseconds = -1 }
    # Start/Wait record rpc.started, rpc.completed, rpc.rejected, rpc.timeout and
    # rpc.disconnected with the request ID; nothing about parameters or results.
    $request = Start-NativeHTMLKitRpc -Application $Application -Method $Method -Parameters $Parameters
    return (Wait-NativeHTMLKitRpc -Request $request -TimeoutMilliseconds $TimeoutMilliseconds)
}

function Send-NativeHTMLKitNotification {
    <# .SYNOPSIS Sends a JSON-RPC notification (no reply) to the host. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Application, [Parameter(Mandatory)][string]$Method,
          [System.Collections.IDictionary]$Parameters = @{})
    Assert-NativeHTMLKitApplication $Application
    $Application.Transport.Send(@{ jsonrpc = '2.0'; method = $Method; params = $Parameters })
}

function Wait-NativeHTMLKit {
    <#
    .SYNOPSIS
    Pumps host events and runs callbacks on this PowerShell runspace.
    .DESCRIPTION
    Waits up to -TimeoutMilliseconds for the first message, then drains up to 64
    queued messages and returns how many were handled. -UntilShutdown pumps until
    the host requests shutdown, returns no output, and throws
    NativeHTMLKit.DisconnectedException if the host disappears first. -Once handles at
    most one message.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Pump')]
    param([Parameter(Mandatory)]$Application,
          [Parameter(ParameterSetName = 'Pump')][ValidateRange(-1, 2147483647)][int]$TimeoutMilliseconds = 100,
          [Parameter(ParameterSetName = 'Pump')][switch]$Once,
          [Parameter(ParameterSetName = 'Run')][switch]$UntilShutdown)
    if (-not (Test-NativeHTMLKitType $Application 'NativeHTMLKit.Application')) { throw 'Expected a NativeHTMLKit.Application from Connect-NativeHTMLKit' }
    if ($UntilShutdown) {
        # No output: a script's last statement must not print a stray value.
        if ($Application.Closed) { return }
        # A local Close-NativeHTMLKit (for example from a Quit button callback) ends the loop normally.
        while (-not $Application.ShutdownRequested -and -not $Application.Closed) {
            try { [void](Invoke-NativeHTMLKitPump $Application 1000) }
            catch [NativeHTMLKit.DisconnectedException] {
                if ($Application.ShutdownRequested -or $Application.Closed) { break }
                throw
            }
        }
        return
    }
    if ($Application.Closed) { return 0 }
    $processed = 0
    try {
        if (Invoke-NativeHTMLKitPump $Application $TimeoutMilliseconds) {
            $processed++
            while (-not $Once -and -not $Application.Closed -and $processed -lt 64 -and (Invoke-NativeHTMLKitPump $Application 0)) { $processed++ }
        }
    } catch [NativeHTMLKit.DisconnectedException] {
        if (-not $Application.ShutdownRequested -and -not $Application.Closed) { throw }
    }
    return $processed
}

function Close-NativeHTMLKit {
    <# .SYNOPSIS Closes the host connection and retires every window, document and bitmap handle. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$Application)
    if ($null -eq $Application -or -not (Test-NativeHTMLKitType $Application 'NativeHTMLKit.Application') -or $Application.Closed) { return }
    $Application.Closed = $true
    Stop-NativeHTMLKitTasks -Application $Application
    Write-NativeHTMLKitDiagnostic -Event 'application.closed' -Level 'DEBUG'
    foreach ($win in @($Application.Windows.Values)) {
        $win.Closed = $true
        if ($null -ne $win.Document) { Remove-NativeHTMLKitDocumentState $win.Document }
    }
    $Application.Windows.Clear(); $Application.Pending.Clear(); $Application.Replies.Clear(); $Application.Deferred.Clear()
    # No user callback may run after close.
    $Application.Notifications.Clear(); $Application.BeforeClose.Clear(); $Application.BeforeQuit = $null
    if ($Application.DirectStart -and -not $Application.ShutdownRequested -and -not $Application.Disconnected) {
        # A Start-NativeHTMLKitScript backend is a dedicated pwsh -File process that ends with the script.
        # Closing early (an error is usually unwinding through a finally block) would make the
        # host stop this process before PowerShell reports that error: process exit closes it.
        return
    }
    $Application.Transport.Dispose()
}

# ------------------------------------------------------------------ windows --

$script:WindowFields = [ordered]@{
    Title = 'title'; Width = 'width'; Height = 'height'; Visible = 'visible'; Resizable = 'resizable'
    Decorations = 'decorations'; Minimized = 'minimized'; Maximized = 'maximized'; Fullscreen = 'fullscreen'
    Focus = 'focus'; X = 'x'; Y = 'y'; MinWidth = 'min_width'; MinHeight = 'min_height'
    MaxWidth = 'max_width'; MaxHeight = 'max_height'
}

function New-NativeHTMLKitWindow {
    <# .SYNOPSIS Creates a native window. Load content with Open-NativeHTMLKitFile or Open-NativeHTMLKitHtml. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Application, [string]$Title = '',
          [ValidateRange(1, 8192)][int]$Width = 900, [ValidateRange(1, 8192)][int]$Height = 600,
          [bool]$Visible = $true, [bool]$Resizable = $true, [bool]$Decorations = $true,
          [ValidateRange(1, 8192)][int]$MinWidth, [ValidateRange(1, 8192)][int]$MinHeight,
          [ValidateRange(1, 8192)][int]$MaxWidth, [ValidateRange(1, 8192)][int]$MaxHeight)
    Assert-NativeHTMLKitApplication $Application
    $p = @{ title = $Title; width = $Width; height = $Height; visible = $Visible; resizable = $Resizable; decorations = $Decorations }
    foreach ($key in @('MinWidth', 'MinHeight', 'MaxWidth', 'MaxHeight')) {
        if ($PSBoundParameters.ContainsKey($key)) { $p[$script:WindowFields[$key]] = $PSBoundParameters[$key] }
    }
    $res = Invoke-NativeHTMLKitRpc -Application $Application -Method 'window.create' -Parameters $p
    $id = [string](Get-NativeHTMLKitField $res 'window_id')
    if ([string]::IsNullOrEmpty($id)) { throw 'The host did not return a window_id' }
    $win = [pscustomobject]@{ Application = $Application; Id = $id; Document = $null; Closed = $false }
    $win.PSObject.TypeNames.Insert(0, 'NativeHTMLKit.Window')
    $Application.Windows[$id] = $win
    return $win
}

function Set-NativeHTMLKitWindow {
    <#
    .SYNOPSIS
    Changes native window state: title, size, position, minimized/maximized/fullscreen, focus, constraints.
    .DESCRIPTION
    Pass typed parameters or a -Properties hashtable of host field names. Size constraints
    are set in pairs; pass $null in -Properties (e.g. @{min_width=$null;min_height=$null}) to clear.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Window, [System.Collections.IDictionary]$Properties = @{},
          [string]$Title, [ValidateRange(1, 8192)][int]$Width, [ValidateRange(1, 8192)][int]$Height,
          [bool]$Visible, [bool]$Resizable, [bool]$Decorations, [bool]$Minimized, [bool]$Maximized,
          [bool]$Fullscreen, [bool]$Focus, [int]$X, [int]$Y,
          [ValidateRange(1, 8192)][int]$MinWidth, [ValidateRange(1, 8192)][int]$MinHeight,
          [ValidateRange(1, 8192)][int]$MaxWidth, [ValidateRange(1, 8192)][int]$MaxHeight)
    Assert-NativeHTMLKitWindow $Window
    $p = @{}
    foreach ($key in $Properties.Keys) { $p[[string]$key] = $Properties[$key] }
    foreach ($key in $script:WindowFields.Keys) {
        if ($PSBoundParameters.ContainsKey($key)) { $p[$script:WindowFields[$key]] = $PSBoundParameters[$key] }
    }
    $p.window_id = $Window.Id
    return (Invoke-NativeHTMLKitRpc -Application $Window.Application -Method 'window.set' -Parameters $p)
}

function Get-NativeHTMLKitWindow {
    <# .SYNOPSIS Returns the host's description of a native window. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Window)
    Assert-NativeHTMLKitWindow $Window
    return (Invoke-NativeHTMLKitRpc -Application $Window.Application -Method 'window.get' -Parameters @{ window_id = $Window.Id })
}

function Get-NativeHTMLKitWindowList {
    <#
    .SYNOPSIS
    Lists the host's open windows of this application.
    .DESCRIPTION
    Returns the list as ONE array object (legacy contract): assign it and use the variable,
    e.g. $list = Get-NativeHTMLKitWindowList ...; $list.Count. Wrapping the call in @() or piping it yields a single item.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Application)
    return ,@(Invoke-NativeHTMLKitRpc -Application $Application -Method 'window.list')
}

function Close-NativeHTMLKitWindow {
    <# .SYNOPSIS Requests a graceful close; Set-NativeHTMLKitBeforeClose policy may veto it. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Window)
    Assert-NativeHTMLKitWindow $Window
    $null = Invoke-NativeHTMLKitRpc -Application $Window.Application -Method 'window.request_close' -Parameters @{ window_id = $Window.Id }
}

function Request-NativeHTMLKitAttention {
    <# .SYNOPSIS Asks the desktop to flag the window (informational or critical). #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Window,
        [ValidateSet('informational', 'critical', 'none')][string]$Kind = 'informational')
    Assert-NativeHTMLKitWindow $Window
    $value = if ($Kind -eq 'none') { $null } else { $Kind }
    return (Invoke-NativeHTMLKitRpc -Application $Window.Application -Method 'window.request_attention' -Parameters @{ window_id = $Window.Id; kind = $value })
}

function Set-NativeHTMLKitBeforeClose {
    <# .SYNOPSIS Sets the window close policy. The scriptblock's last output decides (true = allow). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Window, [Parameter(Mandatory)][AllowNull()][scriptblock]$Callback)
    Assert-NativeHTMLKitWindow $Window
    if ($null -eq $Callback) { [void]$Window.Application.BeforeClose.Remove($Window.Id) }
    else { $Window.Application.BeforeClose[$Window.Id] = $Callback }
}

function Set-NativeHTMLKitBeforeQuit {
    <# .SYNOPSIS Sets the application quit policy. The scriptblock's last output decides (true = allow). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Application, [Parameter(Mandatory)][AllowNull()][scriptblock]$Callback)
    Assert-NativeHTMLKitApplication $Application
    $Application.BeforeQuit = $Callback
}

function Set-NativeHTMLKitReady {
    <# .SYNOPSIS Tells the host that startup finished. Requires at least one window. #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Application)
    Assert-NativeHTMLKitApplication $Application
    if (-not $Application.Ready) {
        $null = Invoke-NativeHTMLKitRpc -Application $Application -Method 'app.ready'
        $Application.Ready = $true
    }
}

function Request-NativeHTMLKitQuit {
    <# .SYNOPSIS Requests an orderly application quit; Set-NativeHTMLKitBeforeQuit policy may veto it. #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Application)
    return (Invoke-NativeHTMLKitRpc -Application $Application -Method 'app.request_quit')
}

function Register-NativeHTMLKitNotification {
    <#
    .SYNOPSIS
    Runs a scriptblock for a host notification method, e.g. desktop.preferences_changed or window.event.
    .DESCRIPTION
    One callback per method; pass $null to remove it. Built-in window and document
    bookkeeping always runs first.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Application, [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][AllowNull()][scriptblock]$Callback)
    Assert-NativeHTMLKitApplication $Application
    if ($null -eq $Callback) { [void]$Application.Notifications.Remove($Method) }
    else { $Application.Notifications[$Method] = $Callback }
}

# ---------------------------------------------------------------- documents --

function New-NativeHTMLKitDocumentObject {
    param($Window, $Result)
    $id = [string](Get-NativeHTMLKitField $Result 'document_id')
    if ([string]::IsNullOrEmpty($id)) { throw 'The host did not return a document_id' }
    $doc = [pscustomobject]@{ Window = $Window; Id = $id; Retired = $false
        Handlers = (New-Object System.Collections.ArrayList); Bitmaps = (New-Object System.Collections.ArrayList) }
    $doc.PSObject.TypeNames.Insert(0, 'NativeHTMLKit.Document')
    # Retire the previous facade only after the atomic replacement succeeded.
    if ($null -ne $Window.Document) { Remove-NativeHTMLKitDocumentState $Window.Document }
    $Window.Document = $doc
    return $doc
}

function Remove-NativeHTMLKitDocumentState {
    param($Document)
    if ($null -eq $Document -or $Document.Retired) { return }
    $Document.Retired = $true
    $Document.Handlers.Clear()
    foreach ($bitmap in @($Document.Bitmaps.ToArray())) { Remove-NativeHTMLKitLiveBitmap -Bitmap $bitmap -Quiet }
}

function Open-NativeHTMLKitHtml {
    <#
    .SYNOPSIS
    Loads generated HTML into a window, atomically replacing its document.
    .DESCRIPTION
    -AssetRoot names the folder that relative stylesheet, image and font URLs resolve against.
    The previous document object, its handlers, nodes and bitmaps become stale.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Window, [Parameter(Mandatory)][AllowEmptyString()][string]$Html, [string]$AssetRoot)
    Assert-NativeHTMLKitWindow $Window
    $p = @{ window_id = $Window.Id; html = $Html }
    if ($AssetRoot) { $p.asset_root = Resolve-NativeHTMLKitPath $AssetRoot }
    $res = Invoke-NativeHTMLKitRpc -Application $Window.Application -Method 'document.load' -Parameters $p -TimeoutMilliseconds 30000
    return (New-NativeHTMLKitDocumentObject $Window $res)
}

function Open-NativeHTMLKitFile {
    <# .SYNOPSIS Loads an HTML file into a window, atomically replacing its document. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Window, [Parameter(Mandatory)][string]$Path, [string]$AssetRoot)
    Assert-NativeHTMLKitWindow $Window
    $p = @{ window_id = $Window.Id; path = (Resolve-NativeHTMLKitPath $Path) }
    if ($AssetRoot) { $p.asset_root = Resolve-NativeHTMLKitPath $AssetRoot }
    $res = Invoke-NativeHTMLKitRpc -Application $Window.Application -Method 'document.load' -Parameters $p -TimeoutMilliseconds 30000
    return (New-NativeHTMLKitDocumentObject $Window $res)
}

function Resolve-NativeHTMLKitPath {
    # Resolves against the PowerShell location (not the process directory), keeping non-ASCII names intact.
    param([string]$Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Remove-NativeHTMLKitDocument {
    <# .SYNOPSIS Unloads the window's document; the window stays open and empty. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Document)
    $ids = Get-NativeHTMLKitDocumentIds $Document
    $null = Invoke-NativeHTMLKitRpc -Application $Document.Window.Application -Method 'document.unload' -Parameters $ids
    Remove-NativeHTMLKitDocumentState $Document
    if ([object]::ReferenceEquals($Document.Window.Document, $Document)) { $Document.Window.Document = $null }
}

function Register-NativeHTMLKitDocumentEvent {
    <#
    .SYNOPSIS
    Subscribes a scriptblock to document events (click, input, change, keydown, contextmenu, auxclick, submit, ...).
    .DESCRIPTION
    -Element delegates to an element id on the event's route. The callback receives the event
    object (type, element, path, plus window_id and document_id) after native dispatch. Inside a
    function, pass ({ ... }.GetNewClosure()) to capture local variables.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$Type,
          [Parameter(Mandatory)][scriptblock]$Callback, [string]$Element)
    Assert-NativeHTMLKitDocument $Document
    if ($Document.Handlers.Count -ge 256) { throw 'Document callback limit (256) reached' }
    $sub = [pscustomobject]@{ Document = $Document; Type = $Type; Element = $Element; Callback = $Callback }
    $sub.PSObject.TypeNames.Insert(0, 'NativeHTMLKit.Subscription')
    [void]$Document.Handlers.Add($sub)
    return $sub
}

function Unregister-NativeHTMLKitDocumentEvent {
    <# .SYNOPSIS Removes a subscription returned by Register-NativeHTMLKitDocumentEvent. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Subscription)
    if (-not (Test-NativeHTMLKitType $Subscription 'NativeHTMLKit.Subscription')) { throw 'Expected a NativeHTMLKit.Subscription' }
    [void]$Subscription.Document.Handlers.Remove($Subscription)
}

function Invoke-NativeHTMLKitDocumentCommand {
    <#
    .SYNOPSIS
    Runs any document command from the Core protocol (docs/reference/protocol.md) and returns its result.
    .EXAMPLE
    Invoke-NativeHTMLKitDocumentCommand -Document $doc -Operation get_html -Parameters @{ element = 'status'; outer = $true }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$Operation,
          [System.Collections.IDictionary]$Parameters = @{})
    $p = Get-NativeHTMLKitDocumentIds $Document
    $cmd = @{ op = $Operation }
    foreach ($key in $Parameters.Keys) {
        if ($key -eq 'op') { throw 'The operation is given by -Operation' }
        $cmd[[string]$key] = $Parameters[$key]
    }
    $p.command = $cmd
    return (Invoke-NativeHTMLKitRpc -Application $Document.Window.Application -Method 'document.command' -Parameters $p)
}

function Invoke-NativeHTMLKitBatch {
    <# .SYNOPSIS Applies several id-addressed DOM operations as one atomic transaction. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][object[]]$Operations)
    $null = Invoke-NativeHTMLKitDocumentCommand -Document $Document -Operation 'batch' -Parameters @{ ops = $Operations }
}

function Get-NativeHTMLKitDocumentText {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$Element)
    return [string](Get-NativeHTMLKitField (Invoke-NativeHTMLKitDocumentCommand $Document 'get_text' @{ element = $Element }) 'text')
}
function Set-NativeHTMLKitDocumentText {
    <# .SYNOPSIS Replaces an element's content with text (never parsed as HTML). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$Element,
          [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $null = Invoke-NativeHTMLKitDocumentCommand $Document 'set_text' @{ element = $Element; text = $Text }
}
function Get-NativeHTMLKitValue {
    [CmdletBinding()] param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$Element)
    return [string](Get-NativeHTMLKitField (Invoke-NativeHTMLKitDocumentCommand $Document 'get_value' @{ element = $Element }) 'value')
}
function Set-NativeHTMLKitDocumentValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$Element,
          [Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $null = Invoke-NativeHTMLKitDocumentCommand $Document 'set_value' @{ element = $Element; value = $Value }
}
function Get-NativeHTMLKitChecked {
    [CmdletBinding()] param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$Element)
    return [bool](Get-NativeHTMLKitField (Invoke-NativeHTMLKitDocumentCommand $Document 'get_checked' @{ element = $Element }) 'checked')
}
function Set-NativeHTMLKitChecked {
    [CmdletBinding()] param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$Element,
        [Parameter(Mandatory)][bool]$Checked)
    $null = Invoke-NativeHTMLKitDocumentCommand $Document 'set_checked' @{ element = $Element; checked = $Checked }
}
function Set-NativeHTMLKitDocumentAttribute {
    <# .SYNOPSIS Sets or (-Remove) removes an attribute. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$Element,
          [Parameter(Mandatory)][string]$Name, [AllowEmptyString()][string]$Value = '', [switch]$Remove)
    if ($Remove) { $null = Invoke-NativeHTMLKitDocumentCommand $Document 'remove_attribute' @{ element = $Element; name = $Name } }
    else { $null = Invoke-NativeHTMLKitDocumentCommand $Document 'set_attribute' @{ element = $Element; name = $Name; value = $Value } }
}
function Set-NativeHTMLKitClass {
    <# .SYNOPSIS Adds a class to an element, or removes it with -Remove. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$Element,
          [Parameter(Mandatory)][string]$Name, [switch]$Remove)
    $op = if ($Remove) { 'remove_class' } else { 'add_class' }
    $null = Invoke-NativeHTMLKitDocumentCommand $Document $op @{ element = $Element; name = $Name }
}
function Set-NativeHTMLKitDocumentHtml {
    <# .SYNOPSIS Replaces (default) or inserts trusted HTML. Use Set-NativeHTMLKitDocumentText for untrusted text. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$Element,
          [Parameter(Mandatory)][AllowEmptyString()][string]$Html,
          [ValidateSet('replace', 'beforebegin', 'afterbegin', 'beforeend', 'afterend')][string]$Position = 'replace')
    if ($Position -eq 'replace') {
        $null = Invoke-NativeHTMLKitDocumentCommand $Document 'replace_children_html' @{ element = $Element; html = $Html }
    } else {
        $null = Invoke-NativeHTMLKitDocumentCommand $Document 'insert_html' @{ element = $Element; html = $Html; position = $Position }
    }
}
function Remove-NativeHTMLKitElement {
    <# .SYNOPSIS Removes an element (and its subtree) by id. #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$Element)
    $null = Invoke-NativeHTMLKitDocumentCommand $Document 'remove_element' @{ element = $Element }
}
function Find-NativeHTMLKitElement {
    <# .SYNOPSIS Runs a CSS selector query; returns paginated element ids. #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$Selector,
        [ValidateRange(0, 2147483647)][int]$Offset = 0, [ValidateRange(1, 4096)][int]$Limit = 1024)
    return (Invoke-NativeHTMLKitDocumentCommand $Document 'query' @{ selector = $Selector; offset = $Offset; limit = $Limit })
}
function Add-NativeHTMLKitStylesheet {
    <# .SYNOPSIS Adds a stylesheet; returns its sheet handle for Set-NativeHTMLKitStylesheet. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][AllowEmptyString()][string]$Css)
    return (Invoke-NativeHTMLKitDocumentCommand $Document 'add_stylesheet' @{ css = $Css })
}
function Get-NativeHTMLKitStylesheets {
    <#
    .SYNOPSIS
    Lists the document's stylesheet handles.
    .DESCRIPTION
    Returns the list as ONE array object (legacy contract): assign it and use the variable,
    e.g. $list = Get-NativeHTMLKitStylesheets ...; $list.Count. Wrapping the call in @() or piping it yields a single item.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Document)
    return ,@(Get-NativeHTMLKitField (Invoke-NativeHTMLKitDocumentCommand $Document 'list_stylesheets') 'sheets' @())
}
function Set-NativeHTMLKitStylesheet {
    <# .SYNOPSIS Replaces the CSS of a sheet, or removes it with -Remove. #>
    [CmdletBinding(DefaultParameterSetName = 'Replace')]
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][long]$Sheet,
        [Parameter(Mandatory, ParameterSetName = 'Replace')][AllowEmptyString()][string]$Css,
        [Parameter(Mandatory, ParameterSetName = 'Remove')][switch]$Remove)
    if ($Remove) { $null = Invoke-NativeHTMLKitDocumentCommand $Document 'remove_stylesheet' @{ sheet = $Sheet }; return }
    return (Invoke-NativeHTMLKitDocumentCommand $Document 'replace_stylesheet' @{ sheet = $Sheet; css = $Css })
}
function Get-NativeHTMLKitComputedStyle {
    [CmdletBinding()] param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string[]]$Properties,
        [string]$Element, $Node)
    $p = @{ properties = $Properties }
    Add-NativeHTMLKitTarget $p $Document $Element $Node
    return (Invoke-NativeHTMLKitDocumentCommand $Document 'get_computed_style' $p)
}
function Get-NativeHTMLKitEnvironment {
    [CmdletBinding()] param([Parameter(Mandatory)]$Document)
    return (Invoke-NativeHTMLKitDocumentCommand $Document 'get_environment')
}
function Set-NativeHTMLKitEnvironment {
    <# .SYNOPSIS Overrides prefers-color-scheme / prefers-reduced-motion for this document. #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Document, [string]$ColorScheme, [string]$ReducedMotion)
    $p = @{}
    if ($PSBoundParameters.ContainsKey('ColorScheme')) { $p.color_scheme = $ColorScheme }
    if ($PSBoundParameters.ContainsKey('ReducedMotion')) { $p.reduced_motion = $ReducedMotion }
    return (Invoke-NativeHTMLKitDocumentCommand $Document 'set_environment' $p)
}
function Get-NativeHTMLKitScroll {
    [CmdletBinding()] param([Parameter(Mandatory)]$Document, [string]$Element)
    $p = @{}
    if ($Element) { $p.element = $Element }
    return (Invoke-NativeHTMLKitDocumentCommand $Document 'get_scroll' $p)
}
function Set-NativeHTMLKitScroll {
    <# .SYNOPSIS Scrolls the document or an element to X/Y (CSS px). #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Document, [string]$Element, [double]$X, [double]$Y,
        [ValidateSet('auto', 'instant', 'smooth')][string]$Behavior = 'auto')
    $p = @{ behavior = $Behavior }
    if ($Element) { $p.element = $Element }
    if ($PSBoundParameters.ContainsKey('X')) { $p.x = $X }
    if ($PSBoundParameters.ContainsKey('Y')) { $p.y = $Y }
    return (Invoke-NativeHTMLKitDocumentCommand $Document 'scroll_to' $p)
}
function Get-NativeHTMLKitFocusedElement {
    [CmdletBinding()] param([Parameter(Mandatory)]$Document)
    return (Invoke-NativeHTMLKitDocumentCommand $Document 'get_focused_element')
}
function Set-NativeHTMLKitFocus {
    <# .SYNOPSIS Focuses an element or node, or with -Blur removes focus. #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Document, [string]$Element, $Node, [switch]$Blur)
    $p = @{}
    Add-NativeHTMLKitTarget $p $Document $Element $Node -Required:(-not $Blur)
    $op = if ($Blur) { 'blur' } else { 'focus' }
    $null = Invoke-NativeHTMLKitDocumentCommand $Document $op $p
}
function Get-NativeHTMLKitSelection {
    <# .SYNOPSIS Returns a text control's selection (UTF-16 offsets). #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Document, [string]$Element, $Node)
    $p = @{}
    Add-NativeHTMLKitTarget $p $Document $Element $Node -Required
    return (Invoke-NativeHTMLKitDocumentCommand $Document 'get_control_selection' $p)
}
function Set-NativeHTMLKitSelection {
    [CmdletBinding()] param([Parameter(Mandatory)]$Document, [string]$Element, $Node,
        [Parameter(Mandatory)][ValidateRange(0, 2147483647)][int]$Start, [Parameter(Mandatory)][ValidateRange(0, 2147483647)][int]$End,
        [ValidateSet('none', 'forward', 'backward')][string]$Direction = 'none')
    $p = @{ start = $Start; end = $End; direction = $Direction }
    Add-NativeHTMLKitTarget $p $Document $Element $Node -Required
    return (Invoke-NativeHTMLKitDocumentCommand $Document 'set_control_selection' $p)
}
function Invoke-NativeHTMLKitEditCommand {
    <#
    .SYNOPSIS
    Runs an editing command (undo, redo, cut, copy, paste, selectAll, delete, ...) through the native editor.
    .DESCRIPTION
    Clipboard commands complete asynchronously; observe input/error events. Acceptance does not
    mean the OS transfer succeeded.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$Command,
        [string]$Element, $Node)
    $p = @{ command = $Command }
    Add-NativeHTMLKitTarget $p $Document $Element $Node
    return (Invoke-NativeHTMLKitDocumentCommand $Document 'edit_command' $p)
}
function Get-NativeHTMLKitFormData {
    <# .SYNOPSIS Returns ordered form entries (repeated names and file metadata preserved). #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Document, [string]$Form, $FormNode, [string]$Submitter, $SubmitterNode)
    $p = @{}
    Add-NativeHTMLKitTarget $p $Document $Form $FormNode -Required
    Add-NativeHTMLKitTarget $p $Document $Submitter $SubmitterNode -ElementKey 'submitter' -NodeKey 'submitter_node'
    return (Invoke-NativeHTMLKitDocumentCommand $Document 'get_form_data' $p)
}
function Submit-NativeHTMLKitForm {
    <# .SYNOPSIS Requests form submission (validation, then a submit event). #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Document, [string]$Form, $FormNode, [string]$Submitter, $SubmitterNode)
    $p = @{}
    Add-NativeHTMLKitTarget $p $Document $Form $FormNode -Required
    Add-NativeHTMLKitTarget $p $Document $Submitter $SubmitterNode -ElementKey 'submitter' -NodeKey 'submitter_node'
    return (Invoke-NativeHTMLKitDocumentCommand $Document 'request_submit' $p)
}
function Reset-NativeHTMLKitForm {
    [CmdletBinding()] param([Parameter(Mandatory)]$Document, [string]$Form, $FormNode)
    $p = @{}
    Add-NativeHTMLKitTarget $p $Document $Form $FormNode -Required
    return (Invoke-NativeHTMLKitDocumentCommand $Document 'reset_form' $p)
}
function Get-NativeHTMLKitSelectOptions {
    <#
    .SYNOPSIS
    Returns a select element's options (value, label, selected, disabled).
    .DESCRIPTION
    Returns the list as ONE array object (legacy contract): assign it and use the variable,
    e.g. $list = Get-NativeHTMLKitSelectOptions ...; $list.Count. Wrapping the call in @() or piping it yields a single item.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$Element)
    return ,@(Get-NativeHTMLKitField (Invoke-NativeHTMLKitDocumentCommand $Document 'get_options' @{ element = $Element }) 'options' @())
}
function Set-NativeHTMLKitSelectedValues {
    [CmdletBinding()] param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$Element,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Values)
    $null = Invoke-NativeHTMLKitDocumentCommand $Document 'set_selected_values' @{ element = $Element; values = $Values }
}
function Show-NativeHTMLKitPopover {
    [CmdletBinding()] param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$Element,
        [ValidateSet('show', 'hide', 'toggle')][string]$Action = 'show')
    $op = switch ($Action) { 'show' { 'show_popover' } 'hide' { 'hide_popover' } 'toggle' { 'toggle_popover' } }
    $res = Invoke-NativeHTMLKitDocumentCommand $Document $op @{ element = $Element }
    if ($Action -eq 'toggle') { return [bool](Get-NativeHTMLKitField $res 'open') }
}
function Show-NativeHTMLKitHtmlDialog {
    <# .SYNOPSIS Shows an HTML <dialog> (modal by default) or closes it with -Close. #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$Element,
        [switch]$Close, [bool]$Modal = $true, [AllowEmptyString()][string]$ReturnValue = '')
    if ($Close) { $null = Invoke-NativeHTMLKitDocumentCommand $Document 'close_dialog' @{ element = $Element; return_value = $ReturnValue }; return }
    $null = Invoke-NativeHTMLKitDocumentCommand $Document 'show_dialog' @{ element = $Element; modal = $Modal }
}
function Set-NativeHTMLKitPreventDefault {
    <# .SYNOPSIS Registers, before input happens, whether the native default action of an event is prevented. #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$Element,
        [Parameter(Mandatory)][Alias('Event')][string]$EventType, [bool]$Prevent = $true, [string]$Key,
        [bool]$Shift, [bool]$Ctrl, [bool]$Alt, [bool]$Meta)
    $p = @{ element = $Element; event = $EventType; prevent = $Prevent }
    if ($PSBoundParameters.ContainsKey('Key')) { $p.key = $Key }
    foreach ($m in @('Shift', 'Ctrl', 'Alt', 'Meta')) {
        if ($PSBoundParameters.ContainsKey($m)) { $p[$m.ToLowerInvariant()] = $PSBoundParameters[$m] }
    }
    $null = Invoke-NativeHTMLKitDocumentCommand $Document 'set_default_action' $p
}
function Get-NativeHTMLKitDiagnostics {
    [CmdletBinding()] param([Parameter(Mandatory)]$Document)
    return (Invoke-NativeHTMLKitDocumentCommand $Document 'get_diagnostics')
}
function Get-NativeHTMLKitResourceStats {
    [CmdletBinding()] param([Parameter(Mandatory)]$Document)
    return (Invoke-NativeHTMLKitDocumentCommand $Document 'get_resource_stats')
}
function Clear-NativeHTMLKitUnusedResources {
    [CmdletBinding()] param([Parameter(Mandatory)]$Document, [string]$Url)
    $p = @{}
    if ($Url) { $p.url = $Url }
    return (Invoke-NativeHTMLKitDocumentCommand $Document 'purge_unused_resources' $p)
}

function ConvertTo-NativeHTMLKitBytes {
    # PowerShell unrolls byte[] returned from functions into object[]; accept that.
    param($Value, [string]$What)
    if ($Value -is [byte[]]) { return ,$Value }
    if ($Value -is [System.Collections.IList]) {
        try { return ,([byte[]]$Value) } catch { throw "$What must contain only byte values 0-255" }
    }
    throw "$What must be a byte[]"
}

function Register-NativeHTMLKitResources {
    <#
    .SYNOPSIS
    Atomically replaces one document-local nativehtmlkit-res://NAME/ bundle.
    .DESCRIPTION
    -Entries maps relative paths to byte[] or @{ Bytes = [byte[]]; Mime = 'image/png' }.
    At most 256 entries and 1 MiB decoded per registration.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$Name,
          [Parameter(Mandatory)][System.Collections.IDictionary]$Entries)
    Assert-NativeHTMLKitDocument $Document
    if ($Entries.Count -gt 256) { throw 'A resource registration permits at most 256 entries' }
    $size = 0
    $items = New-Object System.Collections.ArrayList
    foreach ($key in $Entries.Keys) {
        $entry = $Entries[$key]
        $mime = 'application/octet-stream'
        if ($entry -is [System.Collections.IDictionary]) {
            $bytes = Get-NativeHTMLKitField $entry 'Bytes'; $mime = [string](Get-NativeHTMLKitField $entry 'Mime' $mime)
        } else { $bytes = $entry }
        $bytes = ConvertTo-NativeHTMLKitBytes $bytes "Resource '$key'"
        if ($mime -notmatch '^[^,\r\n]+$') { throw "Resource '$key' has an invalid MIME type" }
        $size += $bytes.Length
        if ($size -gt 1048576) { throw 'A resource registration permits at most 1 MiB of decoded bytes' }
        [void]$items.Add(@{ path = [string]$key; data_url = ('data:' + $mime + ';base64,' + [Convert]::ToBase64String($bytes)) })
    }
    return (Invoke-NativeHTMLKitDocumentCommand $Document 'register_resource_bundle' @{ name = $Name; entries = $items.ToArray() })
}
function Unregister-NativeHTMLKitResources {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$Name)
    return (Invoke-NativeHTMLKitDocumentCommand $Document 'unregister_resource_bundle' @{ name = $Name })
}

# ------------------------------------------------------------------- nodes --

function Get-NativeHTMLKitNode {
    <# .SYNOPSIS Resolves an element id (or the root) to a generation-bound node, or wraps a host reference. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Document, [string]$Element, [string]$Reference)
    Assert-NativeHTMLKitDocument $Document
    if ($Element -and $Reference) { throw 'Use -Element or -Reference, not both' }
    if ($Reference) { $ref = $Reference } else {
        $p = @{}
        if ($Element) { $p.element = $Element }
        $ref = [string](Get-NativeHTMLKitField (Invoke-NativeHTMLKitDocumentCommand $Document 'node_of' $p) 'node')
    }
    if (-not $ref) { throw 'The host did not return a node reference' }
    $node = [pscustomobject]@{ Document = $Document; Id = $ref }
    $node.PSObject.TypeNames.Insert(0, 'NativeHTMLKit.Node')
    return $node
}
function Get-NativeHTMLKitNodes {
    <# .SYNOPSIS Paginated node references for a selector, including elements without ids. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$Selector,
        [ValidateRange(0, 2147483647)][int]$Offset = 0, [ValidateRange(1, 4096)][int]$Limit = 1024)
    return (Invoke-NativeHTMLKitDocumentCommand $Document 'query_nodes' @{ selector = $Selector; offset = $Offset; limit = $Limit })
}
function Get-NativeHTMLKitNodeInfo {
    [CmdletBinding()] param([Parameter(Mandatory)]$Node)
    Assert-NativeHTMLKitNode $Node
    return (Invoke-NativeHTMLKitDocumentCommand $Node.Document 'get_node' @{ node = $Node.Id })
}
function Get-NativeHTMLKitNodeChildren {
    [CmdletBinding()] param([Parameter(Mandatory)]$Node,
        [ValidateRange(0, 2147483647)][int]$Offset = 0, [ValidateRange(1, 4096)][int]$Limit = 256)
    Assert-NativeHTMLKitNode $Node
    return (Invoke-NativeHTMLKitDocumentCommand $Node.Document 'node_children' @{ node = $Node.Id; offset = $Offset; limit = $Limit })
}
function Invoke-NativeHTMLKitNodeBatch {
    <# .SYNOPSIS Applies node-addressed operations (@{op=...;node=...}) as one atomic transaction. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][object[]]$Operations)
    $null = Invoke-NativeHTMLKitDocumentCommand -Document $Document -Operation 'node_batch' -Parameters @{ ops = $Operations }
}
function Invoke-NativeHTMLKitNodeOperation {
    <#
    .SYNOPSIS
    Applies one node operation: set_text, append_text, set_attribute, remove_attribute, add_class,
    remove_class, insert_html, replace_children_html, trim_children, move_element, remove_element.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Node, [Parameter(Mandatory)][string]$Operation,
        [System.Collections.IDictionary]$Parameters = @{})
    Assert-NativeHTMLKitNode $Node
    $p = @{ op = $Operation; node = $Node.Id }
    foreach ($key in $Parameters.Keys) {
        if ($key -in @('op', 'node')) { throw "Reserved node operation key: $key" }
        $value = $Parameters[$key]
        if (Test-NativeHTMLKitType $value 'NativeHTMLKit.Node') {
            Assert-NativeHTMLKitNode $value
            if (-not [object]::ReferenceEquals($value.Document, $Node.Document)) { throw 'Cannot move nodes between documents' }
            $value = $value.Id
        }
        $p[[string]$key] = $value
    }
    $null = Invoke-NativeHTMLKitDocumentCommand $Node.Document 'node_batch' @{ ops = @($p) }
}

# ----------------------------------------------------------- desktop services --

function Get-NativeHTMLKitCapabilities {
    [CmdletBinding()] param([Parameter(Mandatory)]$Application)
    return (Invoke-NativeHTMLKitRpc -Application $Application -Method 'host.capabilities')
}
function Get-NativeHTMLKitPreferences {
    <# .SYNOPSIS Observed desktop preferences (color scheme, contrast, motion, ...) and their source. #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Application)
    return (Invoke-NativeHTMLKitRpc -Application $Application -Method 'desktop.preferences')
}
function Get-NativeHTMLKitClipboard {
    [CmdletBinding()] param([Parameter(Mandatory)]$Application)
    return [string](Get-NativeHTMLKitField (Invoke-NativeHTMLKitRpc -Application $Application -Method 'clipboard.read_text') 'text')
}
function Set-NativeHTMLKitClipboard {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Application, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $null = Invoke-NativeHTMLKitRpc -Application $Application -Method 'clipboard.write_text' -Parameters @{ text = $Text }
}
function Open-NativeHTMLKitExternal {
    <#
    .SYNOPSIS
    Opens a URL or document with the desktop's default handler, or with -Reveal shows a file in the file manager.
    .DESCRIPTION
    Host policy refuses executables, scripts and shortcuts as open targets.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Application, [Parameter(Mandatory)][string]$Target, $Window, [switch]$Reveal)
    Assert-NativeHTMLKitApplication $Application
    $p = @{}
    if ($Reveal) { $p.path = Resolve-NativeHTMLKitPath $Target; $method = 'desktop.reveal_file' }
    else { $p.target = $Target; $method = 'desktop.open_external' }
    if ($null -ne $Window) {
        Assert-NativeHTMLKitWindow $Window
        if (-not [object]::ReferenceEquals($Window.Application, $Application)) { throw 'The window belongs to another application' }
        $p.window_id = $Window.Id
    }
    return (Invoke-NativeHTMLKitRpc -Application $Application -Method $method -Parameters $p -TimeoutMilliseconds 60000)
}
function Show-NativeHTMLKitFileDialog {
    <#
    .SYNOPSIS
    Shows a native open/save/folder dialog. Returns the host result (paths), waiting without a deadline.
    .DESCRIPTION
    -NoWait returns a NativeHTMLKit.Request; Wait-NativeHTMLKitRpc awaits it and Stop-NativeHTMLKitRpc closes the dialog.
    -Filters takes @(@{name='Images';extensions=@('png','jpg')}).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Window,
        [ValidateSet('OpenFiles', 'SaveFile', 'ChooseFolder')][string]$Kind = 'OpenFiles',
        [string]$Title, [string]$Directory, [string]$FileName, [object[]]$Filters = @(), [bool]$Multiple = $false,
        [switch]$NoWait)
    Assert-NativeHTMLKitWindow $Window
    $method = switch ($Kind) { 'OpenFiles' { 'dialog.open_files' } 'SaveFile' { 'dialog.save_file' } 'ChooseFolder' { 'dialog.choose_folder' } }
    $p = @{ window_id = $Window.Id }
    if ($PSBoundParameters.ContainsKey('Title')) { $p.title = $Title }
    if ($PSBoundParameters.ContainsKey('Directory')) { $p.directory = Resolve-NativeHTMLKitPath $Directory }
    if ($PSBoundParameters.ContainsKey('FileName')) {
        if ($Kind -ne 'SaveFile') { throw '-FileName applies to -Kind SaveFile' }
        $p.file_name = $FileName
    }
    if ($Kind -eq 'OpenFiles') { $p.multiple = $Multiple }
    if ($Kind -ne 'ChooseFolder') { $p.filters = $Filters }
    if ($NoWait) { return (Start-NativeHTMLKitRpc -Application $Window.Application -Method $method -Parameters $p) }
    return (Invoke-NativeHTMLKitRpc -Application $Window.Application -Method $method -Parameters $p -TimeoutMilliseconds -1)
}

# ------------------------------------------------------------ live bitmaps --

function New-NativeHTMLKitLiveBitmap {
    <#
    .SYNOPSIS
    Creates a bounded RGBA8 live image for <img src="nativehtmlkit-bitmap://ID">, shared through a host-created file mapping.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateRange(1, 4096)][int]$Width, [Parameter(Mandatory)][ValidateRange(1, 4096)][int]$Height,
        [ValidateSet(2, 3)][int]$Slots = 2)
    Assert-NativeHTMLKitDocument $Document
    if ($Id -cnotmatch '^[A-Za-z0-9_-]{1,64}$') { throw 'Bitmap ID must be 1-64 ASCII letters, digits, _ or -' }
    $app = $Document.Window.Application
    $ids = @{ window_id = $Document.Window.Id; document_id = $Document.Id; bitmap_id = $Id }
    $p = @{ window_id = $Document.Window.Id; document_id = $Document.Id; bitmap_id = $Id
        width = $Width; height = $Height; slots = $Slots; pixel_format = 'RGBA8' }
    $res = Invoke-NativeHTMLKitRpc -Application $app -Method 'bitmap.create' -Parameters $p
    $bytes = [long]$Width * [long]$Height * 4
    $stride = [long](Get-NativeHTMLKitField $res 'stride' 0)
    $slotBytes = [long](Get-NativeHTMLKitField $res 'slot_bytes' 0)
    $slotCount = [int](Get-NativeHTMLKitField $res 'slots' 0)
    $mapping = $null
    try {
        if ($stride -ne [long]$Width * 4 -or $slotBytes -ne $bytes -or $slotCount -ne $Slots) {
            throw 'The host returned invalid bitmap geometry'
        }
        $mapping = New-Object -TypeName 'NativeHTMLKit.MappedBitmap' -ArgumentList @(
            [string](Get-NativeHTMLKitField $res 'path'), [long]($bytes * $Slots), [bool]$script:NativeHTMLKitIsWindows)
    } catch {
        # A successful bitmap.create owns host resources even if mapping fails.
        try { $null = Invoke-NativeHTMLKitRpc -Application $app -Method 'bitmap.close' -Parameters $ids } catch { $null = $_ }  # best effort; the original error is rethrown
        throw
    }
    $bitmap = [pscustomobject]@{ Document = $Document; Id = $Id; Width = $Width; Height = $Height
        Stride = [int]$stride; SlotBytes = $slotBytes; Slots = $Slots; Sequence = [long]0
        Closed = $false; Busy = $false; Mapping = $mapping }
    $bitmap.PSObject.TypeNames.Insert(0, 'NativeHTMLKit.LiveBitmap')
    [void]$Document.Bitmaps.Add($bitmap)
    return $bitmap
}

function Send-NativeHTMLKitLiveBitmap {
    <#
    .SYNOPSIS
    Writes one complete straight-alpha RGBA8 frame into the next slot and presents it.
    .DESCRIPTION
    Returns after the host has snapshotted the slot (synchronous backpressure). With -Try,
    returns $null instead of re-entering while this bitmap's previous present is in progress
    (for example from a callback that runs during that present).
    #>
    [CmdletBinding()]
    # -Pixels is deliberately untyped: Windows PowerShell 5.1 inspects every element when a
    # mandatory parameter is typed [byte[]] (about 150 ms for a 1024x768 frame).
    param([Parameter(Mandatory)]$Bitmap, [Parameter(Mandatory)]$Pixels, [switch]$Try)
    if (-not (Test-NativeHTMLKitType $Bitmap 'NativeHTMLKit.LiveBitmap')) { throw 'Expected a NativeHTMLKit.LiveBitmap from New-NativeHTMLKitLiveBitmap' }
    if ($Pixels -isnot [byte[]]) { $Pixels = ConvertTo-NativeHTMLKitBytes $Pixels 'Pixels' }
    if ($Pixels.LongLength -ne $Bitmap.SlotBytes) { throw "Expected $($Bitmap.SlotBytes) RGBA8 bytes, received $($Pixels.LongLength)" }
    if ($Bitmap.Busy) {
        if ($Try) { return $null }
        throw 'A present of this bitmap is already in progress (use -Try from callbacks)'
    }
    if ($Bitmap.Closed) { throw (New-NativeHTMLKitStaleError "Live bitmap $($Bitmap.Id) is closed") }
    Assert-NativeHTMLKitDocument $Bitmap.Document
    $Bitmap.Busy = $true
    try {
        $Bitmap.Sequence++
        $slot = [int]($Bitmap.Sequence % $Bitmap.Slots)
        $Bitmap.Mapping.Write([long]$slot * $Bitmap.SlotBytes, $Pixels)
        $doc = $Bitmap.Document
        return (Invoke-NativeHTMLKitRpc -Application $doc.Window.Application -Method 'bitmap.present' -Parameters @{
            window_id = $doc.Window.Id; document_id = $doc.Id; bitmap_id = $Bitmap.Id; sequence = $Bitmap.Sequence; slot = $slot })
    } finally { $Bitmap.Busy = $false }
}

function Remove-NativeHTMLKitLiveBitmap {
    <# .SYNOPSIS Unmaps and releases a live bitmap. Idempotent. -Quiet suppresses host errors. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$Bitmap, [switch]$Quiet)
    if ($null -eq $Bitmap -or $Bitmap.Closed) { return }
    $Bitmap.Closed = $true
    if ($null -ne $Bitmap.Mapping) { $Bitmap.Mapping.Dispose() }
    $doc = $Bitmap.Document
    [void]$doc.Bitmaps.Remove($Bitmap)
    $app = $doc.Window.Application
    # Closing a document or window releases its bitmaps in the host already.
    if ($doc.Retired -or $doc.Window.Closed -or $app.Closed -or $app.Disconnected) { return }
    try {
        $null = Invoke-NativeHTMLKitRpc -Application $app -Method 'bitmap.close' -Parameters @{
            window_id = $doc.Window.Id; document_id = $doc.Id; bitmap_id = $Bitmap.Id }
    } catch {
        $code = $null
        if ($_.Exception -is [NativeHTMLKit.RpcException]) { $code = $_.Exception.Code }
        $benign = ($_.Exception -is [NativeHTMLKit.DisconnectedException]) -or ($code -in @(-32004, -32008))
        if (-not $Quiet -and -not $benign) { throw }
    }
}

# --------------------------------------------------- host, projects, skills --

function Get-NativeHTMLKitHostPath {
    <# .SYNOPSIS Returns the bundled native host for this platform (or UI4ME_HOST_BINARY). #>
    [CmdletBinding()]
    param()
    $configuredHost = $env:NATIVEHTMLKIT_HOST_BINARY
    if (-not $configuredHost) { $configuredHost = $env:UI4ME_HOST_BINARY }
    if ($configuredHost) {
        # One resolution (against the PowerShell location) for both the check and the result.
        $resolved = [IO.Path]::GetFullPath((Resolve-NativeHTMLKitPath $configuredHost))
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "NATIVEHTMLKIT_HOST_BINARY does not exist: $resolved" }
        return $resolved
    }
    $arch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    if ($arch -ne [Runtime.InteropServices.Architecture]::X64) { throw "NativeHTMLKit ships x64 hosts only; this system is $arch" }
    if ($script:NativeHTMLKitIsWindows) { $rid = 'win-x64'; $relative = 'runtimes/win-x64/nativehtmlkit-host.exe' }
    elseif ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)) {
        $rid = 'linux-x64'; $relative = 'runtimes/linux-x64/nativehtmlkit-host'
    } else { throw 'NativeHTMLKit supports Linux and Windows only' }
    $found = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $relative))
    if (-not (Test-Path -LiteralPath $found -PathType Leaf)) {
        throw 'The native NativeHTMLKit host is missing. Install the qualified NativeHTMLKit module or set NATIVEHTMLKIT_HOST_BINARY.'
    }
    Assert-NativeHTMLKitBundledHost -Path $found -RuntimeId $rid
    if (-not $script:NativeHTMLKitIsWindows) {
        # NuGet package extraction drops Unix execute permissions.
        & /bin/sh -c 'test -x "$1" || chmod u+x -- "$1"' nativehtmlkit-host-check $found
        if ($LASTEXITCODE -ne 0) { throw "The native host is not executable and could not be made executable: $found" }
    }
    return $found
}

function Assert-NativeHTMLKitBundledHost {
    # A packaged module records the SHA-256 of each bundled host in HOST-MANIFEST.json.
    # Fail closed on a mismatch (corrupted or replaced file); this is an integrity
    # check of the installed copy, not proof of who built it. Hashed once per process.
    param([string]$Path, [string]$RuntimeId)
    $manifestPath = Join-Path $PSScriptRoot 'HOST-MANIFEST.json'
    # A bundled host exists (the caller checked), so a missing manifest is an incomplete or
    # altered install: fail closed. Re-hashed on every call, no cache. Residual risk: the file
    # could still be swapped between this hash and the moment the OS executes it.
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "The bundled $RuntimeId native host has no HOST-MANIFEST.json to verify it against; reinstall the NativeHTMLKit module"
    }
    $manifest = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8))
    $entry = $null
    if ($null -ne $manifest.hosts) { $entry = $manifest.hosts.PSObject.Properties[$RuntimeId] }
    if ($null -eq $entry -or [string]$entry.Value.sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "HOST-MANIFEST.json has no SHA-256 for the $RuntimeId host; reinstall the NativeHTMLKit module"
    }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if (-not [string]::Equals($actual, [string]$entry.Value.sha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The bundled $RuntimeId native host does not match HOST-MANIFEST.json (SHA-256 $actual); refusing to run it. Reinstall the NativeHTMLKit module."
    }
}

function Start-NativeHTMLKitHost {
    <#
    .SYNOPSIS
    Runs an app manifest (app.toml) through the native host and waits for it to exit.
    .DESCRIPTION
    -NoWait starts the host and returns its process object.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Manifest, [switch]$NoWait)
    $hostBinary = Get-NativeHTMLKitHostPath
    $full = Resolve-NativeHTMLKitPath $Manifest
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Manifest not found: $full" }
    if ($NoWait) {
        $quoted = '"' + $full.Replace('"', '\"') + '"'
        return (Start-Process -FilePath $hostBinary -ArgumentList @('run', '--app', $quoted) -PassThru)
    }
    & $hostBinary run --app $full
    if ($LASTEXITCODE -ne 0) { throw "NativeHTMLKit host exited with code $LASTEXITCODE" }
}

function ConvertTo-NativeHTMLKitTomlString {
    # A TOML basic string: escape quotes, backslashes and control characters; keep Unicode literal.
    param([AllowEmptyString()][string]$Text)
    if ($Text.IndexOf([char]0) -ge 0) { throw 'Paths and arguments must not contain NUL characters' }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    foreach ($c in $Text.ToCharArray()) {
        if ($c -eq '"') { [void]$builder.Append('\"') }
        elseif ($c -eq '\') { [void]$builder.Append('\\') }
        elseif ([int]$c -lt 32 -or [int]$c -eq 127) { [void]$builder.Append(('\u{0:X4}' -f [int]$c)) }
        else { [void]$builder.Append($c) }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Get-NativeHTMLKitDefaultAppId {
    # Stable per script: a second launch of the same script reaches the running instance.
    param([string]$ScriptPath, [string]$Label)
    $identity = if ($script:NativeHTMLKitIsWindows) { $ScriptPath.ToLowerInvariant() } else { $ScriptPath }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('script:' + $identity)) } finally { $sha.Dispose() }
    $digest = (-join ($bytes | ForEach-Object { $_.ToString('x2') })).Substring(0, 12)
    $folded = $Label.Normalize([Text.NormalizationForm]::FormD)
    $folded = -join ($folded.ToCharArray() | Where-Object { [int]$_ -lt 128 })
    $slug = ($folded -replace '[^A-Za-z0-9]+', '-').Trim('-')
    if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).Trim('-') }
    if (-not $slug) { $slug = 'app' } elseif ($slug -notmatch '^[A-Za-z]') { $slug = 'app-' + $slug }
    return "local.nativehtmlkit.$slug.h$digest"
}

function Get-NativeHTMLKitScriptArguments {
    # Arguments that followed the script on this process's command line
    # (pwsh -File app.ps1 a b). A script started from an open prompt has none here.
    param([string]$ScriptPath)
    $all = [Environment]::GetCommandLineArgs()
    $comparison = if ($script:NativeHTMLKitIsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    for ($i = 1; $i -lt $all.Count; $i++) {
        try { $full = [IO.Path]::GetFullPath([IO.Path]::Combine([Environment]::CurrentDirectory, $all[$i])) } catch { continue }
        if ([string]::Equals($full, $ScriptPath, $comparison)) {
            if ($i + 1 -ge $all.Count) { return ,@() }
            return ,@($all[($i + 1)..($all.Count - 1)])
        }
    }
    return ,@()
}

function Clear-NativeHTMLKitStaleStartFolders {
    # Manifests left behind by a launcher that was killed outright. The host
    # reads its manifest only while starting, so a day-old one is never in use.
    $limit = [DateTime]::UtcNow.AddDays(-1)
    try { $folders = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'nativehtmlkit-start-*' -ErrorAction Stop) } catch { return }
    foreach ($folder in $folders) {
        if ($folder.LastWriteTimeUtc -lt $limit) {
            try { Remove-NativeHTMLKitTreeSafely $folder.FullName } catch { Write-NativeHTMLKitDiagnostic -Event 'launcher.stale_cleanup_failed' -Level 'WARN' -Context @{ exception_type = $_.Exception.GetType().Name } }
        }
    }
}

function Remove-NativeHTMLKitTreeSafely {
    # Deletes a folder tree without ever following a link: a reparse point (symlink or
    # junction) is removed as a link, never descended into. Remove-Item -Recurse on
    # Windows PowerShell 5.1 does not guarantee that.
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return }
    if (([int]$item.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
        if ($item.PSIsContainer) { [IO.Directory]::Delete($item.FullName, $false) } else { [IO.File]::Delete($item.FullName) }
        return
    }
    if (-not $item.PSIsContainer) { $item.Attributes = 'Normal'; [IO.File]::Delete($item.FullName); return }
    foreach ($child in @($item.EnumerateFileSystemInfos())) { Remove-NativeHTMLKitTreeSafely $child.FullName }
    [IO.Directory]::Delete($item.FullName, $false)
}

function New-NativeHTMLKitPrivateDirectory {
    # The launcher manifest names the backend program, script, arguments and working directory:
    # it must not be replaceable by other users. Unix: created atomically with mode 0700 (fail
    # closed). Windows: the per-user %TEMP% folder's ACL (owner, SYSTEM, Administrators) is
    # inherited; tests check that no broad group is granted access.
    param([string]$Path)
    if ($script:NativeHTMLKitIsWindows) { [void](New-Item -ItemType Directory -Path $Path); return }
    $mkdir = @('/usr/bin/mkdir', '/bin/mkdir') | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $mkdir) { throw 'Cannot create a private launch folder: mkdir not found' }
    & $mkdir -m 700 -- $Path
    if ($LASTEXITCODE -ne 0) { throw "Cannot create a private launch folder (mkdir exit $LASTEXITCODE)" }
    $mode = (& /usr/bin/stat -c '%a' -- $Path 2>$null)
    if ([string]$mode -ne '700') { Remove-NativeHTMLKitTreeSafely $Path; throw "The launch folder is not private (mode $mode)" }
}

function Start-NativeHTMLKitScript {
    <#
    .SYNOPSIS
    Runs a normal .ps1 file as a NativeHTMLKit app: starts the native host when needed, returns the connected application.
    .DESCRIPTION
    Call it near the top of a script that you run directly (pwsh -File ./app.ps1, or
    powershell.exe -File .\app.ps1 on Windows PowerShell 5.1):

        $app = Start-NativeHTMLKitScript -Name 'My App'

    Run directly, it writes a private temporary manifest, starts the packaged native host and
    waits. The host runs the same script again, with the same PowerShell edition and arguments,
    as its supervised backend; the first run then ends with the host's exit code, so the code
    below this call never runs there. In the second run, Start-NativeHTMLKitScript connects to the
    host and returns the application object (like Connect-NativeHTMLKit).

    Everything above this call runs twice: keep side effects below it. Inside a backend started
    by a manifest (Start-NativeHTMLKitHost, nativehtmlkit-host run --app) it only connects.
    .PARAMETER Name
    Application name (default: the script file name).
    .PARAMETER AppId
    Reverse-DNS identity such as org.example.MyApp. Default: a stable ID derived from the script path.
    .PARAMETER Instance
    single (default) forwards a second launch to the running app; multiple allows several.
    .PARAMETER ArgumentList
    Arguments for the backend run. By default, the arguments that followed the script on the
    pwsh/powershell.exe command line are reused.
    .EXAMPLE
    $app = Start-NativeHTMLKitScript -Name 'Hello NativeHTMLKit'
    #>
    [CmdletBinding()]
    param(
        [string]$Name, [string]$AppId, [string]$Version, [string]$Icon,
        [ValidateSet('single', 'multiple')][string]$Instance = 'single',
        [ValidateRange(1000, 300000)][int]$StartupTimeoutMilliseconds = 30000,
        [ValidateRange(100, 120000)][int]$ShutdownTimeoutMilliseconds = 5000,
        [ValidateRange(1, 64)][int]$MaxWindows = 16,
        [string[]]$ArgumentList,
        [string]$ScriptPath,
        [ValidateSet('Off','Normal','Debug','Trace')][string]$Diagnostics = 'Normal'
    )
    foreach ($pair in @(@('Name', $Name), @('Version', $Version))) {
        if ($pair[1] -and ($pair[1].Trim().Length -eq 0 -or $pair[1].Length -gt 128 -or $pair[1] -match '[\x00-\x1f\x7f]')) {
            throw "$($pair[0]) must be 1-128 characters without control characters"
        }
    }
    if ($AppId -and ($AppId.Length -gt 128 -or $AppId -cnotmatch '^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z][A-Za-z0-9_-]*)+$')) {
        throw 'AppId must be a dot-separated ASCII identity such as org.example.MyApp'
    }
    if ($PSBoundParameters.ContainsKey('Diagnostics') -and $Diagnostics -ne 'Normal') {
        $env:NATIVEHTMLKIT_DIAGNOSTICS = $Diagnostics.ToLowerInvariant()
    }
    $endpoint = $env:UI4ME_ENDPOINT
    $token = $env:UI4ME_TOKEN
    if ($endpoint -and $token) {
        # Backend role: started by the native host.
        if ($script:NativeHTMLKitIsWindows) { try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch { $null = $_ } }  # no console attached: nothing to configure
        $app = Connect-NativeHTMLKit -Endpoint $endpoint -Token $token
        $app.DirectStart = $true
        # Keep the connection secret out of processes this script starts.
        foreach ($variable in @('UI4ME_ENDPOINT', 'UI4ME_TOKEN', 'UI4ME_APP_ID', 'UI4ME_PROTOCOL_VERSION', 'UI4ME_DIRECT_START')) {
            [Environment]::SetEnvironmentVariable($variable, $null)
        }
        return $app
    }
    if ($endpoint -or $token) {
        Clear-NativeHTMLKitLaunchEnvironment
        throw 'Incomplete NativeHTMLKit host environment: UI4ME_ENDPOINT and UI4ME_TOKEN must both be set by the native host. Remove them to run the script directly.'
    }
    if ($env:UI4ME_DIRECT_START) {
        throw 'This backend was started by a NativeHTMLKit launcher but received no host connection. Refusing to start a second native host.'
    }

    # Launcher role.
    if (-not $ScriptPath) { $ScriptPath = $MyInvocation.PSCommandPath }
    if (-not $ScriptPath) { throw 'Start-NativeHTMLKitScript must be called from a .ps1 script file (for example pwsh -File ./app.ps1).' }
    $ScriptPath = [IO.Path]::GetFullPath((Resolve-NativeHTMLKitPath $ScriptPath))
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { throw "Script not found: $ScriptPath" }
    if ($Icon) {
        $Icon = [IO.Path]::GetFullPath((Resolve-NativeHTMLKitPath $Icon))
        if (-not (Test-Path -LiteralPath $Icon -PathType Leaf)) { throw "Application icon not found: $Icon" }
    }
    if (-not $PSBoundParameters.ContainsKey('ArgumentList')) { $ArgumentList = Get-NativeHTMLKitScriptArguments $ScriptPath }
    if ($null -eq $ArgumentList) { $ArgumentList = @() }
    $label = [IO.Path]::GetFileNameWithoutExtension($ScriptPath)
    if (-not $Name) { $Name = $label }
    if (-not $AppId) { $AppId = Get-NativeHTMLKitDefaultAppId -ScriptPath $ScriptPath -Label $Name }
    $edition = if ($PSVersionTable.PSEdition -eq 'Core') { if ($script:NativeHTMLKitIsWindows) { 'pwsh.exe' } else { 'pwsh' } } else { 'powershell.exe' }
    $shell = Join-Path $PSHOME $edition
    if (-not (Test-Path -LiteralPath $shell -PathType Leaf)) { throw "Cannot find this PowerShell executable: $shell" }
    $hostBinary = Get-NativeHTMLKitHostPath
    Initialize-NativeHTMLKitHelper

    $backendArguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + @($ArgumentList)
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('[app]'); $lines.Add('id = ' + (ConvertTo-NativeHTMLKitTomlString $AppId)); $lines.Add('name = ' + (ConvertTo-NativeHTMLKitTomlString $Name))
    if ($Version) { $lines.Add('version = ' + (ConvertTo-NativeHTMLKitTomlString $Version)) }
    if ($Icon) { $lines.Add('icon = ' + (ConvertTo-NativeHTMLKitTomlString $Icon)) }
    $lines.Add(''); $lines.Add('[backend]'); $lines.Add('program = ' + (ConvertTo-NativeHTMLKitTomlString $shell))
    $lines.Add('args = [' + ((@($backendArguments) | ForEach-Object { ConvertTo-NativeHTMLKitTomlString $_ }) -join ', ') + ']')
    $lines.Add('cwd = ' + (ConvertTo-NativeHTMLKitTomlString ([IO.Path]::GetFullPath((Get-Location -PSProvider FileSystem).ProviderPath))))
    $lines.Add(''); $lines.Add('[host]')
    $lines.Add("startup_timeout_ms = $StartupTimeoutMilliseconds"); $lines.Add("shutdown_timeout_ms = $ShutdownTimeoutMilliseconds")
    $lines.Add("max_windows = $MaxWindows"); $lines.Add('instance = ' + (ConvertTo-NativeHTMLKitTomlString $Instance)); $lines.Add('')

    Clear-NativeHTMLKitStaleStartFolders
    $folder = Join-Path ([IO.Path]::GetTempPath()) ('nativehtmlkit-start-' + [guid]::NewGuid().ToString('N'))
    New-NativeHTMLKitPrivateDirectory $folder
    $runner = $null
    $code = 1
    $previousMarker = $env:UI4ME_DIRECT_START
    try {
        $manifest = Join-Path $folder 'app.toml'
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($lines -join "`n"))
        $stream = New-Object IO.FileStream($manifest, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        $hostArguments = @('run', '--app', $manifest)
        if ($env:NATIVEHTMLKIT_TEST_MODE -eq '1') { $hostArguments += '--headless' }
        $program = $hostBinary
        if (-not $script:NativeHTMLKitIsWindows) {
            # If this PowerShell process dies, even by SIGKILL, the host is told to stop.
            # Absolute path only: PATH is never searched for anything that runs the host.
            $setpriv = @('/usr/bin/setpriv', '/bin/setpriv') | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
            if ($setpriv) { $program = $setpriv; $hostArguments = @('--pdeathsig', 'TERM', '--', $hostBinary) + $hostArguments }
        }
        $verbose = @('', '0', 'false', 'no') -notcontains ([string]$env:NATIVEHTMLKIT_VERBOSE).Trim().ToLowerInvariant()
        $env:UI4ME_DIRECT_START = [string]$PID
        try {
            $runner = New-Object NativeHTMLKit.HostProcess -ArgumentList @($program, [string[]]$hostArguments, [Environment]::CurrentDirectory, $verbose)
        } finally {
            $env:UI4ME_DIRECT_START = $previousMarker
        }
        # Short waits keep Ctrl+C responsive; the finally block stops the host.
        while (-not $runner.WaitForExit(200)) { }
        $code = $runner.ExitCode
    } finally {
        if ($null -ne $runner) {
            if (-not $runner.HasExited) { $runner.Stop() }
            $runner.Dispose()
        }
        try { Remove-NativeHTMLKitTreeSafely $folder } catch { $null = $_ }   # stale-folder cleanup retries later
    }
    exit $code
}

function New-NativeHTMLKitProject {
    <#
    .SYNOPSIS
    Generates a runnable HTML + CSS + PowerShell app (app.ps1, index.html, style.css, optional app.toml).
    .DESCRIPTION
    Run the generated app directly: pwsh -File ./app.ps1 (or powershell.exe -File .\app.ps1 on
    Windows PowerShell 5.1). app.toml is optional, for launchers and deployments that start the
    host explicitly with Start-NativeHTMLKitHost; it names pwsh, or powershell.exe with -WindowsPowerShell.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string]$Name = 'NativeHTMLKit PowerShell App',
          [string]$AppId = 'org.example.PowerShellApp', [Alias('WindowsPowerShell51')][switch]$WindowsPowerShell, [switch]$Force)
    if ($AppId -cnotmatch '^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z][A-Za-z0-9_-]*)+$' -or $AppId.Length -gt 128) {
        throw 'AppId must be a reverse-domain ASCII identifier such as org.example.MyApp'
    }
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 128 -or $Name -match '[\x00-\x1f"\\]') {
        throw 'Name must be 1-128 characters without quotes, backslashes or control characters'
    }
    $folder = Resolve-NativeHTMLKitPath $Path
    $files = @('app.ps1', 'app.toml', 'index.html', 'style.css')
    if (Test-Path -LiteralPath $folder -PathType Leaf) { throw "Path is a file: $folder" }
    if (-not $Force) {
        foreach ($f in $files) { if (Test-Path -LiteralPath (Join-Path $folder $f)) { throw "Refusing to overwrite $f in $folder; use -Force" } }
    }
    [void](New-Item -ItemType Directory -Path $folder -Force)
    $program = if ($WindowsPowerShell) { 'powershell.exe' } else { 'pwsh' }
    $htmlName = [Net.WebUtility]::HtmlEncode($Name)
    $psName = $Name.Replace("'", "''")
    $manifest = @"
# Optional. For daily development just run: pwsh -File ./app.ps1
# This manifest lets a launcher or deployment start the app explicitly with:
#   Start-NativeHTMLKitHost -Manifest ./app.toml
[app]
id = "$AppId"
name = "$Name"
version = "1.0.0"

[backend]
program = "$program"
args = ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "{app_dir}/app.ps1"]
cwd = "{app_dir}"

[host]
startup_timeout_ms = 30000
shutdown_timeout_ms = 5000
max_windows = 8
instance = "single"
"@
    $backend = @"
# $psName - a native desktop window built with HTML, CSS and PowerShell.
#
# Run it:  pwsh -File ./app.ps1
#     or:  powershell.exe -NoProfile -File .\app.ps1   (Windows PowerShell 5.1)
#
# NativeHTMLKit starts its native window host, which runs this script a second time to
# connect it to the window. Keep start-up work below Start-NativeHTMLKitScript.
`$ErrorActionPreference = 'Stop'
Import-Module NativeHTMLKit -MinimumVersion 0.1.0

`$app = Start-NativeHTMLKitScript -Name '$psName' -AppId '$AppId'

`$window = New-NativeHTMLKitWindow -Application `$app -Title '$psName' -Width 840 -Height 540
`$doc = Open-NativeHTMLKitFile -Window `$window -Path (Join-Path `$PSScriptRoot 'index.html')

`$script:clicks = 0
`$null = Register-NativeHTMLKitDocumentEvent -Document `$doc -Type click -Element greet -Callback {
    `$script:clicks++
    `$name = (Get-NativeHTMLKitValue -Document `$doc -Element name).Trim()
    if (-not `$name) { `$name = 'world' }
    # Text is never parsed as HTML, so user input is safe here.
    Set-NativeHTMLKitDocumentText -Document `$doc -Element result -Text "Hello, `$name! (`$(`$script:clicks))"
}

Set-NativeHTMLKitReady -Application `$app
Wait-NativeHTMLKit -Application `$app -UntilShutdown
Close-NativeHTMLKit -Application `$app
"@
    $html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>$htmlName</title>
<link rel="stylesheet" href="style.css">
</head>
<body>
<main>
  <h1>$htmlName</h1>
  <p>Native HTML and CSS with PowerShell logic. No browser or JavaScript.</p>
  <label for="name">Your name</label>
  <div class="row"><input id="name" type="text" autocomplete="off"><button id="greet">Greet</button></div>
  <p id="result" aria-live="polite">Ready.</p>
</main>
</body>
</html>
"@
    $css = @'
:root { color-scheme: light dark; --bg: #f4f6fb; --card: #ffffff; --text: #17233a; --accent: #3268d8; }
@media (prefers-color-scheme: dark) { :root { --bg: #151a24; --card: #1f2633; --text: #e6ebf5; --accent: #6f9bff; } }
body { margin: 0; padding: 32px; font-family: system-ui, sans-serif; background: var(--bg); color: var(--text); }
main { max-width: 640px; margin: 0 auto; padding: 28px 32px; background: var(--card); border-radius: 14px; }
.row { display: flex; gap: 10px; margin-top: 6px; }
input { flex: 1; padding: 9px 11px; font-size: 15px; border-radius: 8px; border: 1px solid #8894a8; }
button { padding: 9px 18px; font-size: 15px; border: 0; border-radius: 8px; background: var(--accent); color: #fff; }
button:focus-visible, input:focus-visible { outline: 3px solid var(--accent); outline-offset: 2px; }
'@
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $folder 'app.toml'), $manifest.Replace("`r`n", "`n"), $utf8)
    # Windows PowerShell 5.1 reads BOM-less scripts as the ANSI code page.
    [IO.File]::WriteAllText((Join-Path $folder 'app.ps1'), $backend, (New-Object Text.UTF8Encoding($true)))
    [IO.File]::WriteAllText((Join-Path $folder 'index.html'), $html.Replace("`r`n", "`n"), $utf8)
    [IO.File]::WriteAllText((Join-Path $folder 'style.css'), $css.Replace("`r`n", "`n"), $utf8)
    return (Get-Item -LiteralPath $folder)
}

function Get-NativeHTMLKitSkillHashes {
    param([string]$Path)
    $hashes = @{}
    $root = [IO.Path]::GetFullPath($Path).TrimEnd([char]'\', [char]'/')
    foreach ($entry in @(Get-ChildItem -LiteralPath $root -Recurse -Force)) {
        if (([int]$entry.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Links are not supported in skill folders: $($entry.FullName)" }
        if ($entry.PSIsContainer -or $entry.Name -eq '.nativehtmlkit-managed.json') { continue }
        $relative = $entry.FullName.Substring($root.Length).TrimStart([char]'\', [char]'/').Replace('\', '/')
        $hashes[$relative] = (Get-FileHash -LiteralPath $entry.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    if (-not $hashes.ContainsKey('SKILL.md')) { throw 'A skill must contain SKILL.md' }
    return $hashes
}
function Get-NativeHTMLKitSkillState {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 'missing' }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer -or (([int]$item.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0)) { return 'unmanaged' }
    $marker = Join-Path $Path '.nativehtmlkit-managed.json'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { return 'unmanaged' }
    try {
        $record = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($marker, [Text.Encoding]::UTF8))
        if ($record.name -ne 'nativehtmlkit-powershell') { return 'unmanaged' }
        $actual = Get-NativeHTMLKitSkillHashes $Path
        $known = @($record.files.PSObject.Properties)
        if ($actual.Count -ne $known.Count) { return 'modified' }
        foreach ($e in $known) { if (-not $actual.ContainsKey($e.Name) -or $actual[$e.Name] -ne $e.Value) { return 'modified' } }
        return 'installed'
    } catch { return 'modified' }
}
function Get-NativeHTMLKitSkillSource {
    # A Gallery install bundles skills/ in the module; a source checkout keeps it at the repo root.
    foreach ($candidate in @((Join-Path $PSScriptRoot 'skills/nativehtmlkit-powershell'), (Join-Path $PSScriptRoot '../../skills/nativehtmlkit-powershell'))) {
        $full = [IO.Path]::GetFullPath($candidate)
        if (Test-Path -LiteralPath (Join-Path $full 'SKILL.md') -PathType Leaf) { return $full }
    }
    return $null
}

function Install-NativeHTMLKitSkill {
    <#
    .SYNOPSIS
    Installs, inspects or removes the nativehtmlkit-powershell coding-agent skill for Claude Code, Codex,
    OpenCode, GitHub Copilot, Cursor and Gemini CLI.
    .DESCRIPTION
    User scope writes under your home directory; project scope under -ProjectPath. Folders that were
    not installed by this command, or were edited since, are never replaced or removed without -Force.
    .EXAMPLE
    Install-NativeHTMLKitSkill -Agents all -Scope user
    .EXAMPLE
    Install-NativeHTMLKitSkill -Action status -Agents claude,codex -Scope project -ProjectPath .
    #>
    [CmdletBinding()]
    param([ValidateSet('install', 'status', 'uninstall')][string]$Action = 'install',
      [string[]]$Agents = @('all'), [ValidateSet('user', 'project')][string]$Scope = 'user',
      [string]$ProjectPath, [switch]$Force, [switch]$DryRun)
    if ($Scope -eq 'project' -and -not $ProjectPath) { throw '-ProjectPath is required with -Scope project' }
    if ($Scope -eq 'user' -and $ProjectPath) { throw '-ProjectPath applies only to -Scope project' }
    $source = Get-NativeHTMLKitSkillSource
    if ($Action -eq 'install' -and $null -eq $source) {
        throw 'The nativehtmlkit-powershell skill is missing from this module. Reinstall NativeHTMLKit from the qualified package.'
    }
    $supported = @('claude', 'codex', 'opencode', 'copilot', 'cursor', 'gemini')
    $tokens = @($Agents | ForEach-Object { $_.Split(',') } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
    $targets = if ($tokens -contains 'all') { $supported } else { $tokens }
    foreach ($n in $targets) { if ($n -notin $supported) { throw "Unsupported agent '$n'. Use: $($supported -join ', '), all" } }
    $map = @{ claude = '.claude/skills'; codex = '.agents/skills'; opencode = '.config/opencode/skills'
        copilot = '.copilot/skills'; cursor = '.cursor/skills'; gemini = '.gemini/skills' }
    if ($Scope -eq 'project') {
        $base = Resolve-NativeHTMLKitPath $ProjectPath
        if (-not (Test-Path -LiteralPath $base -PathType Container)) { throw "-ProjectPath must be an existing folder: $base" }
        $map.opencode = '.opencode/skills'; $map.copilot = '.github/skills'
    } else {
        $base = [Environment]::GetFolderPath('UserProfile')
        if (-not $base) { $base = $HOME }
    }
    foreach ($agent in $targets) {
        $dest = [IO.Path]::GetFullPath((Join-Path (Join-Path $base $map[$agent]) 'nativehtmlkit-powershell'))
        # Never write through a link/junction in the destination path.
        $ancestor = $dest
        while ($ancestor) {
            if (Test-Path -LiteralPath $ancestor) {
                $f = Get-Item -LiteralPath $ancestor -Force
                if (([int]$f.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0 -and $ancestor.Length -gt $base.TrimEnd([char]'\', [char]'/').Length) {
                    throw "Refusing to use a linked folder: $ancestor"
                }
            }
            $parent = Split-Path -Parent $ancestor
            if (-not $parent -or $parent -eq $ancestor) { break }
            $ancestor = $parent
        }
        $state = Get-NativeHTMLKitSkillState $dest
        if ($Action -eq 'status' -or $DryRun) {
            [pscustomobject]@{ Agent = $agent; Scope = $Scope; State = $state; Path = $dest
                Action = $(if ($DryRun) { "would-$Action" } else { 'status' }) }
            continue
        }
        if ($Action -eq 'uninstall') {
            if ($state -eq 'missing') { [pscustomobject]@{ Agent = $agent; Scope = $Scope; State = 'missing'; Path = $dest; Action = 'none' }; continue }
            if ($state -ne 'installed' -and -not $Force) { throw "Refusing to remove $state skill folder $dest (use -Force)" }
            Remove-Item -LiteralPath $dest -Recurse -Force
            [pscustomobject]@{ Agent = $agent; Scope = $Scope; State = 'missing'; Path = $dest; Action = 'removed' }
            continue
        }
        if ($state -in @('modified', 'unmanaged') -and -not $Force) {
            throw "Refusing to overwrite $state skill folder $dest; inspect it or use -Force"
        }
        $parent = Split-Path -Parent $dest
        [void](New-Item -ItemType Directory -Path $parent -Force)
        $temp = Join-Path $parent ('.nativehtmlkit-skill-new-' + [guid]::NewGuid().ToString('N'))
        $backup = Join-Path $parent ('.nativehtmlkit-skill-old-' + [guid]::NewGuid().ToString('N'))
        try {
            Copy-Item -LiteralPath $source -Destination $temp -Recurse
            $files = Get-NativeHTMLKitSkillHashes $temp
            $record = @{ name = 'nativehtmlkit-powershell'; version = $script:NativeHTMLKitVersion; files = $files } | ConvertTo-Json -Depth 5
            [IO.File]::WriteAllText((Join-Path $temp '.nativehtmlkit-managed.json'), $record, (New-Object Text.UTF8Encoding($false)))
            if (Test-Path -LiteralPath $dest) { Move-Item -LiteralPath $dest -Destination $backup }
            try { Move-Item -LiteralPath $temp -Destination $dest }
            catch { if (Test-Path -LiteralPath $backup) { Move-Item -LiteralPath $backup -Destination $dest }; throw }
            if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
            [pscustomobject]@{ Agent = $agent; Scope = $Scope; State = 'installed'; Path = $dest; Action = 'installed' }
        } finally {
            if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
        }
    }
}

Export-ModuleMember -Function @(
    'Connect-NativeHTMLKit', 'Close-NativeHTMLKit', 'Wait-NativeHTMLKit', 'Invoke-NativeHTMLKitRpc', 'Send-NativeHTMLKitNotification',
    'Start-NativeHTMLKitRpc', 'Wait-NativeHTMLKitRpc', 'Stop-NativeHTMLKitRpc',
    'New-NativeHTMLKitWindow', 'Set-NativeHTMLKitWindow', 'Get-NativeHTMLKitWindow', 'Get-NativeHTMLKitWindowList', 'Close-NativeHTMLKitWindow',
    'Request-NativeHTMLKitAttention', 'Set-NativeHTMLKitBeforeClose', 'Set-NativeHTMLKitBeforeQuit', 'Set-NativeHTMLKitReady', 'Request-NativeHTMLKitQuit',
    'Register-NativeHTMLKitNotification',
    'Open-NativeHTMLKitHtml', 'Open-NativeHTMLKitFile', 'Remove-NativeHTMLKitDocument',
    'Register-NativeHTMLKitDocumentEvent', 'Unregister-NativeHTMLKitDocumentEvent', 'Invoke-NativeHTMLKitDocumentCommand', 'Invoke-NativeHTMLKitBatch',
    'Get-NativeHTMLKitDocumentText', 'Set-NativeHTMLKitDocumentText', 'Get-NativeHTMLKitValue', 'Set-NativeHTMLKitDocumentValue',
    'Get-NativeHTMLKitChecked', 'Set-NativeHTMLKitChecked', 'Set-NativeHTMLKitDocumentAttribute', 'Set-NativeHTMLKitClass', 'Set-NativeHTMLKitDocumentHtml',
    'Remove-NativeHTMLKitElement', 'Find-NativeHTMLKitElement',
    'Add-NativeHTMLKitStylesheet', 'Get-NativeHTMLKitStylesheets', 'Set-NativeHTMLKitStylesheet', 'Get-NativeHTMLKitComputedStyle',
    'Get-NativeHTMLKitEnvironment', 'Set-NativeHTMLKitEnvironment', 'Get-NativeHTMLKitScroll', 'Set-NativeHTMLKitScroll',
    'Get-NativeHTMLKitFocusedElement', 'Set-NativeHTMLKitFocus', 'Get-NativeHTMLKitSelection', 'Set-NativeHTMLKitSelection', 'Invoke-NativeHTMLKitEditCommand',
    'Get-NativeHTMLKitFormData', 'Submit-NativeHTMLKitForm', 'Reset-NativeHTMLKitForm', 'Get-NativeHTMLKitSelectOptions', 'Set-NativeHTMLKitSelectedValues',
    'Show-NativeHTMLKitPopover', 'Show-NativeHTMLKitHtmlDialog', 'Set-NativeHTMLKitPreventDefault',
    'Get-NativeHTMLKitDiagnostics', 'Get-NativeHTMLKitResourceStats', 'Clear-NativeHTMLKitUnusedResources',
    'Register-NativeHTMLKitResources', 'Unregister-NativeHTMLKitResources',
    'Get-NativeHTMLKitNode', 'Get-NativeHTMLKitNodes', 'Get-NativeHTMLKitNodeInfo', 'Get-NativeHTMLKitNodeChildren', 'Invoke-NativeHTMLKitNodeBatch', 'Invoke-NativeHTMLKitNodeOperation',
    'Get-NativeHTMLKitCapabilities', 'Get-NativeHTMLKitPreferences', 'Get-NativeHTMLKitClipboard', 'Set-NativeHTMLKitClipboard',
    'Open-NativeHTMLKitExternal', 'Show-NativeHTMLKitFileDialog',
    'New-NativeHTMLKitLiveBitmap', 'Send-NativeHTMLKitLiveBitmap', 'Remove-NativeHTMLKitLiveBitmap',
    'Get-NativeHTMLKitHostPath', 'Start-NativeHTMLKitHost', 'Start-NativeHTMLKitScript', 'New-NativeHTMLKitProject', 'Install-NativeHTMLKitSkill', 'Start-NativeHTMLKitTask', 'Receive-NativeHTMLKitTask', 'Stop-NativeHTMLKitTask',
    'Export-NativeHTMLKitSupportBundle', 'Get-NativeHTMLKitDiagnosticReport'
)



# Short-form command aliases: full module/API names remain canonical.
Set-Alias -Name 'Add-NHKStylesheet' -Value 'Add-NativeHTMLKitStylesheet' -Scope Script
Set-Alias -Name 'Clear-NHKUnusedResources' -Value 'Clear-NativeHTMLKitUnusedResources' -Scope Script
Set-Alias -Name 'Close-NHK' -Value 'Close-NativeHTMLKit' -Scope Script
Set-Alias -Name 'Close-NHKWindow' -Value 'Close-NativeHTMLKitWindow' -Scope Script
Set-Alias -Name 'Connect-NHK' -Value 'Connect-NativeHTMLKit' -Scope Script
Set-Alias -Name 'Export-NHKSupportBundle' -Value 'Export-NativeHTMLKitSupportBundle' -Scope Script
Set-Alias -Name 'Find-NHKElement' -Value 'Find-NativeHTMLKitElement' -Scope Script
Set-Alias -Name 'Get-NHKCapabilities' -Value 'Get-NativeHTMLKitCapabilities' -Scope Script
Set-Alias -Name 'Get-NHKChecked' -Value 'Get-NativeHTMLKitChecked' -Scope Script
Set-Alias -Name 'Get-NHKClipboard' -Value 'Get-NativeHTMLKitClipboard' -Scope Script
Set-Alias -Name 'Get-NHKComputedStyle' -Value 'Get-NativeHTMLKitComputedStyle' -Scope Script
Set-Alias -Name 'Get-NHKDiagnosticReport' -Value 'Get-NativeHTMLKitDiagnosticReport' -Scope Script
Set-Alias -Name 'Get-NHKDiagnostics' -Value 'Get-NativeHTMLKitDiagnostics' -Scope Script
Set-Alias -Name 'Get-NHKDocumentText' -Value 'Get-NativeHTMLKitDocumentText' -Scope Script
Set-Alias -Name 'Get-NHKEnvironment' -Value 'Get-NativeHTMLKitEnvironment' -Scope Script
Set-Alias -Name 'Get-NHKFocusedElement' -Value 'Get-NativeHTMLKitFocusedElement' -Scope Script
Set-Alias -Name 'Get-NHKFormData' -Value 'Get-NativeHTMLKitFormData' -Scope Script
Set-Alias -Name 'Get-NHKHostPath' -Value 'Get-NativeHTMLKitHostPath' -Scope Script
Set-Alias -Name 'Get-NHKNode' -Value 'Get-NativeHTMLKitNode' -Scope Script
Set-Alias -Name 'Get-NHKNodeChildren' -Value 'Get-NativeHTMLKitNodeChildren' -Scope Script
Set-Alias -Name 'Get-NHKNodeInfo' -Value 'Get-NativeHTMLKitNodeInfo' -Scope Script
Set-Alias -Name 'Get-NHKNodes' -Value 'Get-NativeHTMLKitNodes' -Scope Script
Set-Alias -Name 'Get-NHKPreferences' -Value 'Get-NativeHTMLKitPreferences' -Scope Script
Set-Alias -Name 'Get-NHKResourceStats' -Value 'Get-NativeHTMLKitResourceStats' -Scope Script
Set-Alias -Name 'Get-NHKScroll' -Value 'Get-NativeHTMLKitScroll' -Scope Script
Set-Alias -Name 'Get-NHKSelectOptions' -Value 'Get-NativeHTMLKitSelectOptions' -Scope Script
Set-Alias -Name 'Get-NHKSelection' -Value 'Get-NativeHTMLKitSelection' -Scope Script
Set-Alias -Name 'Get-NHKStylesheets' -Value 'Get-NativeHTMLKitStylesheets' -Scope Script
Set-Alias -Name 'Get-NHKValue' -Value 'Get-NativeHTMLKitValue' -Scope Script
Set-Alias -Name 'Get-NHKWindow' -Value 'Get-NativeHTMLKitWindow' -Scope Script
Set-Alias -Name 'Get-NHKWindowList' -Value 'Get-NativeHTMLKitWindowList' -Scope Script
Set-Alias -Name 'Install-NHKSkill' -Value 'Install-NativeHTMLKitSkill' -Scope Script
Set-Alias -Name 'Invoke-NHKBatch' -Value 'Invoke-NativeHTMLKitBatch' -Scope Script
Set-Alias -Name 'Invoke-NHKDocumentCommand' -Value 'Invoke-NativeHTMLKitDocumentCommand' -Scope Script
Set-Alias -Name 'Invoke-NHKEditCommand' -Value 'Invoke-NativeHTMLKitEditCommand' -Scope Script
Set-Alias -Name 'Invoke-NHKNodeBatch' -Value 'Invoke-NativeHTMLKitNodeBatch' -Scope Script
Set-Alias -Name 'Invoke-NHKNodeOperation' -Value 'Invoke-NativeHTMLKitNodeOperation' -Scope Script
Set-Alias -Name 'Invoke-NHKRpc' -Value 'Invoke-NativeHTMLKitRpc' -Scope Script
Set-Alias -Name 'New-NHKLiveBitmap' -Value 'New-NativeHTMLKitLiveBitmap' -Scope Script
Set-Alias -Name 'New-NHKProject' -Value 'New-NativeHTMLKitProject' -Scope Script
Set-Alias -Name 'New-NHKWindow' -Value 'New-NativeHTMLKitWindow' -Scope Script
Set-Alias -Name 'Open-NHKExternal' -Value 'Open-NativeHTMLKitExternal' -Scope Script
Set-Alias -Name 'Open-NHKFile' -Value 'Open-NativeHTMLKitFile' -Scope Script
Set-Alias -Name 'Open-NHKHtml' -Value 'Open-NativeHTMLKitHtml' -Scope Script
Set-Alias -Name 'Receive-NHKTask' -Value 'Receive-NativeHTMLKitTask' -Scope Script
Set-Alias -Name 'Register-NHKDocumentEvent' -Value 'Register-NativeHTMLKitDocumentEvent' -Scope Script
Set-Alias -Name 'Register-NHKNotification' -Value 'Register-NativeHTMLKitNotification' -Scope Script
Set-Alias -Name 'Register-NHKResources' -Value 'Register-NativeHTMLKitResources' -Scope Script
Set-Alias -Name 'Remove-NHKDocument' -Value 'Remove-NativeHTMLKitDocument' -Scope Script
Set-Alias -Name 'Remove-NHKElement' -Value 'Remove-NativeHTMLKitElement' -Scope Script
Set-Alias -Name 'Remove-NHKLiveBitmap' -Value 'Remove-NativeHTMLKitLiveBitmap' -Scope Script
Set-Alias -Name 'Request-NHKAttention' -Value 'Request-NativeHTMLKitAttention' -Scope Script
Set-Alias -Name 'Request-NHKQuit' -Value 'Request-NativeHTMLKitQuit' -Scope Script
Set-Alias -Name 'Reset-NHKForm' -Value 'Reset-NativeHTMLKitForm' -Scope Script
Set-Alias -Name 'Send-NHKLiveBitmap' -Value 'Send-NativeHTMLKitLiveBitmap' -Scope Script
Set-Alias -Name 'Send-NHKNotification' -Value 'Send-NativeHTMLKitNotification' -Scope Script
Set-Alias -Name 'Set-NHKBeforeClose' -Value 'Set-NativeHTMLKitBeforeClose' -Scope Script
Set-Alias -Name 'Set-NHKBeforeQuit' -Value 'Set-NativeHTMLKitBeforeQuit' -Scope Script
Set-Alias -Name 'Set-NHKChecked' -Value 'Set-NativeHTMLKitChecked' -Scope Script
Set-Alias -Name 'Set-NHKClass' -Value 'Set-NativeHTMLKitClass' -Scope Script
Set-Alias -Name 'Set-NHKClipboard' -Value 'Set-NativeHTMLKitClipboard' -Scope Script
Set-Alias -Name 'Set-NHKDocumentAttribute' -Value 'Set-NativeHTMLKitDocumentAttribute' -Scope Script
Set-Alias -Name 'Set-NHKDocumentHtml' -Value 'Set-NativeHTMLKitDocumentHtml' -Scope Script
Set-Alias -Name 'Set-NHKDocumentText' -Value 'Set-NativeHTMLKitDocumentText' -Scope Script
Set-Alias -Name 'Set-NHKDocumentValue' -Value 'Set-NativeHTMLKitDocumentValue' -Scope Script
Set-Alias -Name 'Set-NHKEnvironment' -Value 'Set-NativeHTMLKitEnvironment' -Scope Script
Set-Alias -Name 'Set-NHKFocus' -Value 'Set-NativeHTMLKitFocus' -Scope Script
Set-Alias -Name 'Set-NHKPreventDefault' -Value 'Set-NativeHTMLKitPreventDefault' -Scope Script
Set-Alias -Name 'Set-NHKReady' -Value 'Set-NativeHTMLKitReady' -Scope Script
Set-Alias -Name 'Set-NHKScroll' -Value 'Set-NativeHTMLKitScroll' -Scope Script
Set-Alias -Name 'Set-NHKSelectedValues' -Value 'Set-NativeHTMLKitSelectedValues' -Scope Script
Set-Alias -Name 'Set-NHKSelection' -Value 'Set-NativeHTMLKitSelection' -Scope Script
Set-Alias -Name 'Set-NHKStylesheet' -Value 'Set-NativeHTMLKitStylesheet' -Scope Script
Set-Alias -Name 'Set-NHKWindow' -Value 'Set-NativeHTMLKitWindow' -Scope Script
Set-Alias -Name 'Show-NHKFileDialog' -Value 'Show-NativeHTMLKitFileDialog' -Scope Script
Set-Alias -Name 'Show-NHKHtmlDialog' -Value 'Show-NativeHTMLKitHtmlDialog' -Scope Script
Set-Alias -Name 'Show-NHKPopover' -Value 'Show-NativeHTMLKitPopover' -Scope Script
Set-Alias -Name 'Start-NHKHost' -Value 'Start-NativeHTMLKitHost' -Scope Script
Set-Alias -Name 'Start-NHKRpc' -Value 'Start-NativeHTMLKitRpc' -Scope Script
Set-Alias -Name 'Start-NHKScript' -Value 'Start-NativeHTMLKitScript' -Scope Script
Set-Alias -Name 'Start-NHKTask' -Value 'Start-NativeHTMLKitTask' -Scope Script
Set-Alias -Name 'Stop-NHKTask' -Value 'Stop-NativeHTMLKitTask' -Scope Script
Set-Alias -Name 'Stop-NHKRpc' -Value 'Stop-NativeHTMLKitRpc' -Scope Script
Set-Alias -Name 'Submit-NHKForm' -Value 'Submit-NativeHTMLKitForm' -Scope Script
Set-Alias -Name 'Unregister-NHKDocumentEvent' -Value 'Unregister-NativeHTMLKitDocumentEvent' -Scope Script
Set-Alias -Name 'Unregister-NHKResources' -Value 'Unregister-NativeHTMLKitResources' -Scope Script
Set-Alias -Name 'Wait-NHK' -Value 'Wait-NativeHTMLKit' -Scope Script
Set-Alias -Name 'Wait-NHKRpc' -Value 'Wait-NativeHTMLKitRpc' -Scope Script

Export-ModuleMember -Alias @('Add-NHKStylesheet', 'Clear-NHKUnusedResources', 'Close-NHK', 'Close-NHKWindow', 'Connect-NHK', 'Export-NHKSupportBundle', 'Find-NHKElement', 'Get-NHKCapabilities', 'Get-NHKChecked', 'Get-NHKClipboard', 'Get-NHKComputedStyle', 'Get-NHKDiagnosticReport', 'Get-NHKDiagnostics', 'Get-NHKDocumentText', 'Get-NHKEnvironment', 'Get-NHKFocusedElement', 'Get-NHKFormData', 'Get-NHKHostPath', 'Get-NHKNode', 'Get-NHKNodeChildren', 'Get-NHKNodeInfo', 'Get-NHKNodes', 'Get-NHKPreferences', 'Get-NHKResourceStats', 'Get-NHKScroll', 'Get-NHKSelectOptions', 'Get-NHKSelection', 'Get-NHKStylesheets', 'Get-NHKValue', 'Get-NHKWindow', 'Get-NHKWindowList', 'Install-NHKSkill', 'Invoke-NHKBatch', 'Invoke-NHKDocumentCommand', 'Invoke-NHKEditCommand', 'Invoke-NHKNodeBatch', 'Invoke-NHKNodeOperation', 'Invoke-NHKRpc', 'New-NHKLiveBitmap', 'New-NHKProject', 'New-NHKWindow', 'Open-NHKExternal', 'Open-NHKFile', 'Open-NHKHtml', 'Receive-NHKTask', 'Register-NHKDocumentEvent', 'Register-NHKNotification', 'Register-NHKResources', 'Remove-NHKDocument', 'Remove-NHKElement', 'Remove-NHKLiveBitmap', 'Request-NHKAttention', 'Request-NHKQuit', 'Reset-NHKForm', 'Send-NHKLiveBitmap', 'Send-NHKNotification', 'Set-NHKBeforeClose', 'Set-NHKBeforeQuit', 'Set-NHKChecked', 'Set-NHKClass', 'Set-NHKClipboard', 'Set-NHKDocumentAttribute', 'Set-NHKDocumentHtml', 'Set-NHKDocumentText', 'Set-NHKDocumentValue', 'Set-NHKEnvironment', 'Set-NHKFocus', 'Set-NHKPreventDefault', 'Set-NHKReady', 'Set-NHKScroll', 'Set-NHKSelectedValues', 'Set-NHKSelection', 'Set-NHKStylesheet', 'Set-NHKWindow', 'Show-NHKFileDialog', 'Show-NHKHtmlDialog', 'Show-NHKPopover', 'Start-NHKHost', 'Start-NHKRpc', 'Start-NHKScript', 'Start-NHKTask', 'Stop-NHKRpc', 'Stop-NHKTask', 'Submit-NHKForm', 'Unregister-NHKDocumentEvent', 'Unregister-NHKResources', 'Wait-NHK', 'Wait-NHKRpc')
