# Reference: raw host requests

Low-level access to the Core wire protocol v1 for methods without a dedicated cmdlet. Normal
applications do not need these commands. The method list and parameter schemas are in the
[Core protocol contract](https://github.com/nativehtmlkit/nativehtmlkit-core/blob/main/protocol/README.md).
Do not send `host.hello` or lifecycle replies yourself; the SDK owns them.

A `NativeHTMLKit.Request` has read-only properties `Id` (`ps-<n>`), `Method`, `Completed`,
`Cancelled` and `Failed`. At most 128 requests may be outstanding per application; more fail with
`NativeHTMLKit.BusyException`.

### Invoke-NativeHTMLKitRpc

Alias: `Invoke-NHKRpc`

Sends a request and waits for its result, pumping events meanwhile.

```text
Invoke-NativeHTMLKitRpc [-Application] <Object> [-Method] <string> [[-Parameters] <IDictionary>] [[-TimeoutMilliseconds] <int>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Application` | `NativeHTMLKit.Application` | yes | - | The application. |
| `-Method` | `string` | yes | - | Host method, for example `host.capabilities` or `desktop.paths`. |
| `-Parameters` | `System.Collections.IDictionary` | no | `@{}` | Request parameters. |
| `-TimeoutMilliseconds` | `int` | no | `15000` | How long to wait; `-1` waits indefinitely. When not given, `dialog.*` methods wait indefinitely. Range -1 to 2147483647. |

**Returns** the host's `result` object. **Errors** `NativeHTMLKit.RpcException` (properties
`Method`, `Code`, `RpcMessage`, `RpcData`) when the host answers with an error;
`NativeHTMLKit.RpcTimeoutException` after the timeout (cancellation is requested; the outcome is
unknown); `NativeHTMLKit.DisconnectedException` when the connection is lost or closed meanwhile.

```powershell
$paths = Invoke-NativeHTMLKitRpc -Application $app -Method 'desktop.paths'
```

### Start-NativeHTMLKitRpc

Alias: `Start-NHKRpc`

Sends a request without waiting and returns a `NativeHTMLKit.Request`.

```text
Start-NativeHTMLKitRpc [-Application] <Object> [-Method] <string> [[-Parameters] <IDictionary>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Application` | `NativeHTMLKit.Application` | yes | - | The application. |
| `-Method` | `string` | yes | - | Host method. |
| `-Parameters` | `System.Collections.IDictionary` | no | `@{}` | Request parameters. |

### Wait-NativeHTMLKitRpc

Alias: `Wait-NHKRpc`

Waits for a request started with `Start-NativeHTMLKitRpc` (or `Show-NativeHTMLKitFileDialog -NoWait`),
pumping events. Each request can be awaited once. Errors as for `Invoke-NativeHTMLKitRpc`; a
cancelled request throws `NativeHTMLKit.StaleObjectException`.

```text
Wait-NativeHTMLKitRpc [-Request] <Object> [[-TimeoutMilliseconds] <int>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Request` | `NativeHTMLKit.Request` | yes | - | The request. |
| `-TimeoutMilliseconds` | `int` | no | `15000` | How long to wait; `-1` waits indefinitely. Range -1 to 2147483647. |

### Stop-NativeHTMLKitRpc

Alias: `Stop-NHKRpc`

Requests cancellation of an outstanding request (`request.cancel`), for example to close a native
dialog. It is not a rollback: the host may already have acted. Does nothing for a completed or
cancelled request.

```text
Stop-NativeHTMLKitRpc [-Request] <Object> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Request` | `NativeHTMLKit.Request` | yes | - | The request. |

### Send-NativeHTMLKitNotification

Alias: `Send-NHKNotification`

Sends a JSON-RPC notification (no reply) to the host.

```text
Send-NativeHTMLKitNotification [-Application] <Object> [-Method] <string> [[-Parameters] <IDictionary>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Application` | `NativeHTMLKit.Application` | yes | - | The application. |
| `-Method` | `string` | yes | - | Notification method. |
| `-Parameters` | `System.Collections.IDictionary` | no | `@{}` | Notification parameters. |
