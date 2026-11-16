# Reference: diagnostics and support

Local diagnostics only: nothing is sent anywhere. How-to:
[Diagnostics and support bundles](../guides/diagnostics-and-troubleshooting.md).

## Levels and records

One switch controls the SDK, the host and the backend: `NATIVEHTMLKIT_DIAGNOSTICS` = `off`,
`normal` (default when unset), `debug` or `trace`; `Start-NativeHTMLKitScript -Diagnostics` sets it
for the host and backend. The SDK keeps the last 2048 records in memory (older ones are dropped
and counted). Records hold fixed event names, identifiers, numbers and allow-listed short tokens
only: never RPC parameters or results, form values, HTML, text, paths, URLs, tokens or exception
messages (`[REDACTED]`).

| Level | SDK records |
|---|---|
| `off` | Nothing. |
| `normal` | Errors and warnings (`callback.failed`, `rpc.rejected`, `rpc.timeout`, `transport.disconnected`, `task.failed`, ...). |
| `debug` | Also lifecycle (`host.authenticated`, `host.request`, `task.started`, `task.completed`, `application.closed`, ...). |
| `trace` | Also every request (`rpc.started`, `rpc.completed` with duration), notification (`host.notification`) and callback (`callback.started`, `callback.completed`). |

A diagnostic session ID (`NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID`, generated as `nhk-ps-<32 hex>` when
unset) is shared by the launcher, the host's records (`diagnostic_session_id`) and the backend.

### Get-NativeHTMLKitDiagnosticReport

Alias: `Get-NHKDiagnosticReport`

Returns the SDK's diagnostic counters. With `-Application`, adds that connection's counters and, when
connected, the host's own loss counters (`host.diagnostics`).

```text
Get-NativeHTMLKitDiagnosticReport [[-Application] <Object>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Application` | `NativeHTMLKit.Application` | no | - | Optional application to include. |

**Returns** `SchemaVersion`, `SessionId`, `Level`, `RecordCount`, `RecordLimit`, `DroppedRecords`,
`SessionReplaced`; with `-Application` also `Connection` (`Closed`, `Disconnected`,
`ShutdownRequested`, `ReceivedMessages`, `PendingRequests`, `QueuedMessages`, `DroppedNotifications`,
`RejectedHostRequests`, `DeferredDropped`, `CallbackFailures`, `ActiveTasks`,
`CancellationPendingTasks`), `HostCounters` (`dropped_notifications`, `sink_dropped_records`,
`backend_omitted_records`, `sink_capacity_records`, `backend_records_per_pump`) and
`HostCountersError` (`NotConnected` or an exception type name).

### Export-NativeHTMLKitSupportBundle

Alias: `Export-NHKSupportBundle`

Writes a sanitized ZIP with `manifest.json` (versions, counters, level, whether records were
dropped) and `timeline.jsonl` (the redacted SDK records), only when called. It contains no RPC
parameters or results, form values, tokens, file paths, screenshots, or raw host/backend output.

```text
Export-NativeHTMLKitSupportBundle [-Path] <string> [[-Application] <Object>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Path` | `string` | yes | - | Destination `.zip` path; the file must not exist and its folder must. |
| `-Application` | `NativeHTMLKit.Application` | no | - | Optional application whose counters to include. |

**Returns** the `System.IO.FileInfo` of the bundle. **Errors** `Support bundle already exists`;
`The support bundle path must end with .zip`; `Destination directory missing`.

### Get-NativeHTMLKitDiagnostics

Alias: `Get-NHKDiagnostics`

Returns the document's renderer diagnostics (`get_diagnostics`): `css_profile_version` and
`diagnostics`, a list of `@{ code; stage; message }` notes such as unsupported CSS features or
pending resources.

```text
Get-NativeHTMLKitDiagnostics [-Document] <Object> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |

### Get-NativeHTMLKitResourceStats

Alias: `Get-NHKResourceStats`

Returns the document's resource cache statistics (`get_resource_stats`): `bundles` (`count`,
`entries`, `bytes`), `cache` (`entries`, `bytes`, `hits`, `misses`, `evictions`, ...) and
`svg_rasters`.

```text
Get-NativeHTMLKitResourceStats [-Document] <Object> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |

### Clear-NativeHTMLKitUnusedResources

Alias: `Clear-NHKUnusedResources`

Releases cached resources that no element references (`purge_unused_resources`), or only the
given URL.

```text
Clear-NativeHTMLKitUnusedResources [-Document] <Object> [[-Url] <string>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Url` | `string` | no | - | Purge only this resource URL. |

**Returns** `@{ purged; stats }` (`stats` as from `Get-NativeHTMLKitResourceStats`).
