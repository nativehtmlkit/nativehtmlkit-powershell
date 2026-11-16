# PowerShell SDK usage

```powershell
Get-Command -Module NativeHTMLKit
Show-NativeHTMLKitHtmlDialog -Document $d -Element about
Show-NativeHTMLKitFileDialog -Window $w -Kind OpenFiles -Title 'Open'
```

For raw bitmap, `New-NativeHTMLKitLiveBitmap`, `Send-NativeHTMLKitLiveBitmap`, `Remove-NativeHTMLKitLiveBitmap`. Full gallery: https://github.com/nativehtmlkit/nativehtmlkit/blob/main/examples/powershell-sdk/gallery.ps1
