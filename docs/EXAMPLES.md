# Example applications

The [public native demo gallery](https://github.com/nativehtmlkit/nativehtmlkit/blob/main/examples/powershell-sdk/gallery.ps1) shows native window creation, event registration, document updates, dialogs, secondary windows and a bitmap surface. For a smaller copy/paste example, use the module [README](../README.md).

Generate an app skeleton using `New-NativeHTMLKitProject -Path ./MyApp`. For reuse, group application-specific helpers into ordinary `.ps1` files; keep UI state and desktop callbacks on the owning runspace.
