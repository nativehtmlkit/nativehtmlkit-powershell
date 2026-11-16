# Reference: live bitmaps

Live bitmaps show pixels you compute in PowerShell (charts, previews, simple animations) inside
the document. Frames travel through a shared memory file mapping that the host creates, not over
the message channel. How-to: [Live bitmaps](../guides/live-bitmaps.md).

A `NativeHTMLKit.LiveBitmap` has read-only properties `Id`, `Width`, `Height`, `Stride`
(`Width * 4`), `SlotBytes` (`Width * Height * 4`), `Slots`, `Sequence` (frames presented),
`Closed` and `Document`. It belongs to its document: it is released when the document is retired
or the window or application closes.

### New-NativeHTMLKitLiveBitmap

Alias: `New-NHKLiveBitmap`

Creates a live image (`bitmap.create`, pixel format RGBA8) that any `<img src="nativehtmlkit-bitmap://ID">`
in the document shows. The `<img>` can exist before or after the bitmap.

```text
New-NativeHTMLKitLiveBitmap [-Document] <Object> [-Id] <string> [-Width] <int> [-Height] <int> [[-Slots] <int>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Id` | `string` | yes | - | Bitmap id: 1-64 ASCII letters, digits, `_` or `-`. |
| `-Width` | `int` | yes | - | Width in pixels. Range 1 to 4096. |
| `-Height` | `int` | yes | - | Height in pixels. Range 1 to 4096. |
| `-Slots` | `int` | no | `2` | Number of frame buffers (2 or 3). One of: `2`, `3`. |

**Returns** `NativeHTMLKit.LiveBitmap`. **Errors** an invalid id; `The host returned invalid bitmap
geometry` (the host's bitmap is closed again); `NativeHTMLKit.RpcException` from the host.

### Send-NativeHTMLKitLiveBitmap

Alias: `Send-NHKLiveBitmap`

Writes one complete frame into the next slot and presents it (`bitmap.present`). Pixels are
**straight (not premultiplied) alpha RGBA8**, row by row from the top-left, exactly `SlotBytes`
bytes. The call returns after the host has taken its copy of the slot (synchronous backpressure),
so the same `byte[]` can be reused for the next frame.

```text
Send-NativeHTMLKitLiveBitmap [-Bitmap] <Object> [-Pixels] <Object> [-Try] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Bitmap` | `NativeHTMLKit.LiveBitmap` | yes | - | The live bitmap. |
| `-Pixels` | `byte[]` | yes | - | `byte[]` of `Width * Height * 4` bytes (an object array of byte values is converted, slower). |
| `-Try` | `switch` | no | off | Return `$null` instead of throwing when a present of this bitmap is already in progress (for example from a callback that runs during that present). |

**Returns** `@{ sequence; presented_to_engine; slot_released }`. **Errors** wrong length
(`Expected N RGBA8 bytes, received M`); a present already in progress (without `-Try`); a closed
bitmap or retired document (`NativeHTMLKit.StaleObjectException`).

```powershell
$bitmap = New-NativeHTMLKitLiveBitmap -Document $doc -Id preview -Width 64 -Height 64
$pixels = New-Object byte[] (64 * 64 * 4)
for ($i = 0; $i -lt $pixels.Length; $i += 4) { $pixels[$i] = 255; $pixels[$i + 3] = 255 }   # opaque red
$null = Send-NativeHTMLKitLiveBitmap -Bitmap $bitmap -Pixels $pixels
```

### Remove-NativeHTMLKitLiveBitmap

Alias: `Remove-NHKLiveBitmap`

Unmaps the shared memory and releases the host bitmap (`bitmap.close`). Idempotent; `$null` is
accepted. When the document, window or application is already gone, only local resources are
released. Errors for a bitmap the host already closed are ignored; `-Quiet` ignores all host errors.

```text
Remove-NativeHTMLKitLiveBitmap [-Bitmap] <Object> [-Quiet] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Bitmap` | `NativeHTMLKit.LiveBitmap` | yes | - | The live bitmap, or `$null`. Accepts `$null`. |
| `-Quiet` | `switch` | no | off | Suppress host errors. |
