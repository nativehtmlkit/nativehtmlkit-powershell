# Windows PowerShell 5.1 and PowerShell 7: writing scripts that run on both

The module supports PowerShell 7.2+ on Linux x64 and Windows x64, and Windows PowerShell 5.1 on
Windows (manifest: `PowerShellVersion = '5.1'`, `CompatiblePSEditions = Desktop, Core`, .NET
Framework 4.7.2). The cmdlets, parameters and results are the same on both editions. All examples
in this repository are checked on both by `tests/Examples.Tests.ps1`.

## Which edition runs your backend

`Start-NativeHTMLKitScript` relaunches the script with the **same edition** that started it:
`powershell.exe -File app.ps1` gives a Windows PowerShell 5.1 backend, `pwsh -File app.ps1` a
PowerShell 7 backend. A manifest names its program explicitly (`pwsh` or `powershell.exe`).

## Language features to avoid for 5.1

| PowerShell 7 only | Write instead |
|---|---|
| `$a ? $b : $c` | `if ($a) { $b } else { $c }` |
| `$x ?? 'default'`, `$x ??= 1` | `if ($null -eq $x) { 'default' } else { $x }` |
| `cmd1 && cmd2`, `cmd1 \|\| cmd2` | separate statements, `if ($?) { ... }` |
| `$obj?.Prop`, `$arr?[0]` | explicit `$null` checks |
| `$IsWindows`, `$IsLinux` | `[Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT` |
| `ForEach-Object -Parallel` | `Start-NativeHTMLKitTask` for background work |
| `ConvertFrom-Json -AsHashtable` | read `PSCustomObject` properties, or copy into a hashtable |
| `Join-Path a b c` (several children) | `Join-Path (Join-Path a b) c` |
| `Get-Content -Raw` default UTF-8 | 5.1 defaults to the ANSI code page for BOM-less files; pass `-Encoding UTF8` |

The example harness rejects the ternary, null-coalescing, pipeline-chain and null-conditional
operators and the `$Is*` variables by parsing every example.

## File encoding

Windows PowerShell 5.1 reads a `.ps1` without a byte-order mark in the system ANSI code page.
Non-ASCII characters in string literals (`'Prüfung'`, `'–'`) then turn into other characters. Save
scripts that contain non-ASCII text as **UTF-8 with BOM** (`New-NativeHTMLKitProject` does), or keep
them ASCII and put text in `index.html` (which is read as UTF-8). When writing files yourself on
5.1, pass an explicit encoding: `[IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))`.

## Console output

In a backend started by `Start-NativeHTMLKitScript` on Windows, the SDK sets
`[Console]::OutputEncoding` to UTF-8, so `[Console]::Out.WriteLine()` relays Unicode exactly.
Windows PowerShell's own formatting (`Write-Output` of objects) may still use a legacy code page;
prefer showing text in the window.

## Other differences you may meet

- **Execution policy.** The relaunch uses `-ExecutionPolicy Bypass` for the backend process only.
  The first run (`powershell.exe -File app.ps1`) still follows your machine's policy; downloaded
  scripts may need `Unblock-File`.
- **Performance.** Windows PowerShell 5.1 is slower at loops and runspace creation. Keep live
  bitmap frames small and polling periods at a few hundred milliseconds or more.
- **Linux.** Only PowerShell 7 exists; the bundled host is `runtimes/linux-x64/nativehtmlkit-host`
  and needs a graphical session (KDE Plasma on Wayland is the qualified desktop).
- **Paths.** Use `Join-Path` and `[IO.Path]` instead of hard-coded `\` or `/`; file names are
  case-sensitive on Linux.
