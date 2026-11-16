# PowerShell SDK architecture

PowerShell controls an independent native Rust host through local wire-v1 IPC. `Start-NativeHTMLKitScript` starts a host and relaunches the script as the backend, so effects above that call may occur more than once. Register document events and call `Set-NativeHTMLKitReady` before `Wait-NativeHTMLKit`.

The underlying PowerShell module contains transport and launcher logic. The UI convenience module imports only these public commands; it may not call host protocol methods independently. Avoid modifying Core or transport internals to add an application component.

On Linux use PowerShell 7.2+. Windows supports PowerShell 7.2+ and Windows PowerShell 5.1. The latter needs .NET Framework compatibility and native desktop session; not supported on Linux.
