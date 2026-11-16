# 07-file-preview.ps1 - pick a text file with the native Open dialog and preview it.
#
# Teaches: Show-NativeHTMLKitFileDialog with filters and its result (paths, or none when
# cancelled), feature detection with Get-NativeHTMLKitCapabilities, handling
# NativeHTMLKit.RpcException, showing file content as text (never as HTML), and opening
# the folder in the desktop file manager with Open-NativeHTMLKitExternal -Reveal.
#
# Run:  pwsh -File ./07-file-preview.ps1 [-Path some.txt]
#       powershell.exe -NoProfile -File .\07-file-preview.ps1
# -SelfTest previews this script file, checks the dialog fallback and quits.
param([string]$Path, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Import-Module NativeHTMLKit

$app = Start-NativeHTMLKitScript -Name 'File preview'
try {
    $window = New-NativeHTMLKitWindow -Application $app -Title 'File preview' -Width 820 -Height 600
    $doc = Open-NativeHTMLKitHtml -Window $window -Html @'
<!doctype html>
<html><head><style>
  body { font-family: system-ui, sans-serif; margin: 0; display: flex; flex-direction: column; height: 100vh; }
  header { display: flex; gap: 8px; align-items: center; padding: 10px 12px; background: #eef1f6; }
  #name { flex: 1; font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  dl { display: grid; grid-template-columns: max-content 1fr; gap: 2px 12px; margin: 10px 12px; font-size: 13px; }
  dt { color: #555; }
  #content { flex: 1; overflow: auto; margin: 0 12px 12px; padding: 10px; background: #f7f7f7; border: 1px solid #ddd; font: 12px/1.4 monospace; white-space: pre; }
  #message { margin: 0 12px; color: #8a1c1c; min-height: 1.2em; }
</style></head>
<body>
  <header>
    <button id="open">Open...</button>
    <span id="name">No file</span>
    <button id="reveal" disabled>Show in folder</button>
  </header>
  <p id="message" role="status"></p>
  <dl><dt>Size</dt><dd id="size">-</dd><dt>Modified</dt><dd id="modified">-</dd><dt>Lines</dt><dd id="lines">-</dd></dl>
  <pre id="content"></pre>
</body></html>
'@

    $script:current = $null
    $script:maxPreviewBytes = 256KB
    $caps = Get-NativeHTMLKitCapabilities -Application $app
    if (-not $caps.file_dialogs) {
        # For example in the host's headless test mode.
        Set-NativeHTMLKitDocumentAttribute -Document $doc -Element open -Name disabled
        Set-NativeHTMLKitDocumentText -Document $doc -Element message -Text 'Native file dialogs are not available in this session; pass -Path instead.'
    }

    function Show-Preview([string]$File) {
        $item = Get-Item -LiteralPath $File
        $script:current = $item.FullName
        Set-NativeHTMLKitDocumentText -Document $doc -Element name -Text $item.Name
        Set-NativeHTMLKitDocumentText -Document $doc -Element size -Text ('{0:N0} bytes' -f $item.Length)
        Set-NativeHTMLKitDocumentText -Document $doc -Element modified -Text $item.LastWriteTime.ToString('g')
        $bytes = [IO.File]::ReadAllBytes($item.FullName)
        $truncated = $bytes.Length -gt $script:maxPreviewBytes
        $count = [Math]::Min($bytes.Length, $script:maxPreviewBytes)
        if (@($bytes[0..([Math]::Max(0, [Math]::Min($count, 4096) - 1))] | Where-Object { $_ -eq 0 }).Count -gt 0) {
            Set-NativeHTMLKitDocumentText -Document $doc -Element content -Text '(binary file - no text preview)'
            Set-NativeHTMLKitDocumentText -Document $doc -Element lines -Text '-'
        } else {
            $text = [Text.Encoding]::UTF8.GetString($bytes, 0, $count)
            if ($truncated) { $text += "`n... (preview limited to $($script:maxPreviewBytes / 1KB) KB)" }
            # Set-NativeHTMLKitDocumentText never interprets markup, so any file content is safe.
            Set-NativeHTMLKitDocumentText -Document $doc -Element content -Text $text
            Set-NativeHTMLKitDocumentText -Document $doc -Element lines -Text ([string]@($text -split "`n").Count)
        }
        Set-NativeHTMLKitDocumentAttribute -Document $doc -Element reveal -Name disabled -Remove
        Set-NativeHTMLKitDocumentText -Document $doc -Element message -Text ''
    }

    function Invoke-OpenDialog {
        try {
            # Waits (pumping events) until the user picks or cancels.
            $result = Show-NativeHTMLKitFileDialog -Window $window -Kind OpenFiles -Title 'Preview a file' -Filters @(
                @{ name = 'Text and logs'; extensions = @('txt', 'log', 'md', 'csv', 'json', 'xml', 'ps1', 'psm1', 'psd1') })
        } catch [NativeHTMLKit.RpcException] {
            Set-NativeHTMLKitDocumentText -Document $doc -Element message -Text ('The file dialog is unavailable: ' + $_.Exception.RpcMessage)
            return
        }
        if ($result.cancelled) { return }
        $paths = @($result.paths)
        Show-Preview $paths[0]
    }

    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element open -Callback { Invoke-OpenDialog }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element reveal -Callback {
        if (-not $script:current) { return }
        try { $null = Open-NativeHTMLKitExternal -Application $app -Target $script:current -Reveal -Window $window }
        catch [NativeHTMLKit.RpcException] { Set-NativeHTMLKitDocumentText -Document $doc -Element message -Text ('Cannot show the file: ' + $_.Exception.RpcMessage) }
    }

    if ($Path) { Show-Preview $Path }
    Set-NativeHTMLKitReady -Application $app

    if ($SelfTest) {
        Show-Preview $PSCommandPath
        if ((Get-NativeHTMLKitDocumentText -Document $doc -Element name) -ne '07-file-preview.ps1') { throw 'name not shown' }
        $content = Get-NativeHTMLKitDocumentText -Document $doc -Element content
        if (-not $content.Contains('<pre id="content"></pre>')) { throw 'content was not shown verbatim' }
        Invoke-OpenDialog
        if (-not $caps.file_dialogs) {
            $message = Get-NativeHTMLKitDocumentText -Document $doc -Element message
            if (-not $message.StartsWith('The file dialog is unavailable')) { throw "unexpected message: $message" }
        }
        [Console]::Out.WriteLine('SELFTEST PASS 07-file-preview')
        $null = Request-NativeHTMLKitQuit -Application $app
    }

    Wait-NativeHTMLKit -Application $app -UntilShutdown
} finally {
    Close-NativeHTMLKit -Application $app
}
