# 07-file-preview.ps1 - a text file viewer and editor with native Open, Save As and Choose Folder dialogs.
#
# Teaches: Show-NativeHTMLKitFileDialog -Kind OpenFiles / SaveFile / ChooseFolder with filters and
# a start directory. The call waits without a deadline and keeps pumping events, so the window
# stays responsive while the dialog is open. The dialog result shape (cancelled, paths). Graceful
# degradation: without a desktop session (headless/CI) dialogs throw NativeHTMLKit.RpcException
# code -32001. Showing file content safely as a textarea value (plain text) and encoding file names.
#
# Run:  pwsh -File ./07-file-preview.ps1 [-Path notes.txt]
#       powershell.exe -NoProfile -File .\07-file-preview.ps1
# -Path opens a text file at start. -SelfTest lists, opens and saves files in a temporary folder
# through the public API, checks the dialog fallback and quits.
param([string]$Path, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Import-Module NativeHTMLKit

$app = Start-NativeHTMLKitScript -Name 'File viewer'
try {
    $window = New-NativeHTMLKitWindow -Application $app -Title 'File viewer' -Width 900 -Height 600
    $doc = Open-NativeHTMLKitHtml -Window $window -Html @'
<!doctype html>
<html><head><meta charset="utf-8"><style>
  body { margin:0; font:14px sans-serif; background:#f3f4f7; color:#20242c; display:flex; flex-direction:column; height:100vh; }
  header { display:flex; gap:8px; align-items:center; padding:10px 12px; background:#fff; border-bottom:1px solid #d9dce3; }
  button { padding:6px 12px; border:1px solid #b8bfcc; border-radius:5px; background:#fff; cursor:pointer; }
  #path { margin-left:12px; color:#5b6474; font-family:monospace; }
  .body { flex:1; display:flex; min-height:0; }
  aside { width:220px; overflow:auto; background:#fbfbfd; border-right:1px solid #d9dce3; }
  aside ul { list-style:none; margin:0; padding:6px 0; }
  aside li { padding:4px 12px; cursor:pointer; font-family:monospace; }
  aside li:hover { background:#e8eefc; }
  textarea { flex:1; border:0; padding:12px; font:13px monospace; resize:none; }
  footer { padding:6px 12px; background:#fff; border-top:1px solid #d9dce3; color:#5b6474; }
</style></head>
<body>
  <header>
    <button id="open">Open…</button><button id="save-as">Save As…</button><button id="folder">Folder…</button>
    <span id="path">No file</span>
  </header>
  <div class="body">
    <aside><ul id="files"></ul></aside>
    <textarea id="editor" spellcheck="false" placeholder="Open a text file"></textarea>
  </div>
  <footer id="status">Ready.</footer>
</body></html>
'@

    $script:maxBytes = 512KB
    $script:textSuffixes = @('txt', 'md', 'py', 'json', 'csv', 'log', 'toml')
    $script:textFilters = @(@{ name = 'Text files'; extensions = $script:textSuffixes })   # extensions without the dot
    $script:current = $null          # full path of the open file
    $script:folderFiles = @()
    $script:utf8 = New-Object Text.UTF8Encoding($false, $true)   # no BOM; throws on invalid bytes

    function Set-Status([string]$Text) { Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text $Text }

    function Get-Reason($ErrorRecord) {
        # The .NET exception behind a failed method call, without PowerShell's wrapper.
        $e = $ErrorRecord.Exception
        while ($null -ne $e.InnerException) { $e = $e.InnerException }
        return $e.Message
    }

    function Get-Suffix([string]$Name) {
        # '.bashrc' has no suffix; 'notes.MD' has '.md'.
        $i = $Name.LastIndexOf([char]'.')
        if ($i -le 0 -or $i -eq $Name.Length - 1) { return '' }
        return $Name.Substring($i).ToLowerInvariant()
    }

    # ----- native dialogs -----
    function Invoke-FileDialog([hashtable]$Arguments, [scriptblock]$Action) {
        try {
            # Waits (pumping events) until the user picks or cancels.
            $result = Show-NativeHTMLKitFileDialog -Window $window @Arguments
        } catch [NativeHTMLKit.RpcException] {
            if ($_.Exception.Code -eq -32001) { Set-Status 'Native file dialogs are not available in this session.' }   # e.g. headless
            else { Set-Status "Dialog failed (code $($_.Exception.Code))." }
            return
        }
        $paths = @($result.paths)
        if ($result.cancelled -or $paths.Count -eq 0) { Set-Status 'Cancelled.'; return }
        & $Action ([string]$paths[0])
    }

    function Request-Open {
        $start = [Environment]::GetFolderPath('UserProfile')
        if ($script:current) { $start = [IO.Path]::GetDirectoryName($script:current) }
        Invoke-FileDialog @{ Kind = 'OpenFiles'; Title = 'Open a text file'; Directory = $start; Filters = $script:textFilters; Multiple = $false } { param($p) Import-TextFile $p }
    }

    function Request-SaveAs {
        $name = 'untitled.txt'
        if ($script:current) { $name = [IO.Path]::GetFileName($script:current) }
        Invoke-FileDialog @{ Kind = 'SaveFile'; Title = 'Save as'; FileName = $name; Filters = $script:textFilters } { param($p) Export-TextFile $p }
    }

    function Request-Folder {
        Invoke-FileDialog @{ Kind = 'ChooseFolder'; Title = 'Show the text files of a folder' } { param($p) Show-Folder $p }
    }

    # ----- file operations (also used directly by the self-test) -----
    function Import-TextFile([string]$File) {
        $name = [IO.Path]::GetFileName($File)
        try {
            if ((New-Object IO.FileInfo($File)).Length -gt $script:maxBytes) {
                Set-Status "$name is larger than $($script:maxBytes / 1KB) KiB."
                return
            }
            $text = $script:utf8.GetString([IO.File]::ReadAllBytes($File))
        } catch [Text.DecoderFallbackException] {
            Set-Status "$name is not UTF-8 text."
            return
        } catch {
            Set-Status "Cannot read ${name}: $(Get-Reason $_)"
            return
        }
        # Text-mode reading: CRLF and CR line ends become LF.
        $text = $text.Replace("`r`n", "`n").Replace("`r", "`n")
        $script:current = $File
        Set-NativeHTMLKitDocumentValue -Document $doc -Element editor -Value $text   # plain text: never parsed as HTML
        Set-NativeHTMLKitDocumentText -Document $doc -Element path -Text $File
        $null = Set-NativeHTMLKitWindow -Window $window -Title "$name — File viewer"
        # Characters are Unicode code points: a surrogate pair counts once.
        $characters = $text.Length - [regex]::Matches($text, '[\uDC00-\uDFFF]').Count
        Set-Status "Opened $name ($characters characters)."
    }

    function Export-TextFile([string]$File) {
        $name = [IO.Path]::GetFileName($File)
        # Text-mode writing: LF becomes the platform's line end.
        $text = (Get-NativeHTMLKitValue -Document $doc -Element editor).Replace("`n", [Environment]::NewLine)
        try { [IO.File]::WriteAllText($File, $text, (New-Object Text.UTF8Encoding($false))) }
        catch {
            Set-Status "Cannot save ${name}: $(Get-Reason $_)"
            return
        }
        $script:current = $File
        Set-NativeHTMLKitDocumentText -Document $doc -Element path -Text $File
        Set-Status "Saved $name."
    }

    function Show-Folder([string]$Folder) {
        $comparer = [StringComparer]::Ordinal
        if ([IO.Path]::DirectorySeparatorChar -eq '\') { $comparer = [StringComparer]::OrdinalIgnoreCase }   # Windows names ignore case
        $found = New-Object System.Collections.Generic.List[string]
        foreach ($item in Get-ChildItem -LiteralPath $Folder -File -Force) {
            if ($script:textSuffixes -contains (Get-Suffix $item.Name).TrimStart('.')) { $found.Add($item.FullName) }
        }
        $found.Sort($comparer)
        $script:folderFiles = @($found | Select-Object -First 200)
        $items = for ($i = 0; $i -lt $script:folderFiles.Count; $i++) {
            '<li id="file-' + $i + '">' + [Net.WebUtility]::HtmlEncode([IO.Path]::GetFileName($script:folderFiles[$i])) + '</li>'
        }
        $html = @($items) -join ''
        if (-not $html) { $html = '<li>(no text files)</li>' }
        Set-NativeHTMLKitDocumentHtml -Document $doc -Element files -Html $html
        Set-Status "$($script:folderFiles.Count) text file(s) in $((New-Object IO.DirectoryInfo($Folder)).Name)."
    }

    function Invoke-FileClick($ClickEvent) {
        if ([string]$ClickEvent.element -match '^file-(\d+)$') { Import-TextFile $script:folderFiles[[int]$Matches[1]] }
    }

    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element open -Callback { Request-Open }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element save-as -Callback { Request-SaveAs }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element folder -Callback { Request-Folder }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element files -Callback { param($evt) Invoke-FileClick $evt }

    if ($Path) { Import-TextFile $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
    Set-NativeHTMLKitReady -Application $app

    if ($SelfTest) {
        $folder = Join-Path ([IO.Path]::GetTempPath()) ('nhk-example-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $folder
        $noBom = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText((Join-Path $folder 'notes.md'), "# Notes`n<script>alert(1)</script>`n", $noBom)
        [IO.File]::WriteAllText((Join-Path $folder 'data.json'), '{"a": 1}', $noBom)
        [IO.File]::WriteAllBytes((Join-Path $folder 'image.png'), [byte[]](0x89, 0x50, 0x4E, 0x47))
        [IO.File]::WriteAllBytes((Join-Path $folder 'latin1.txt'), [byte[]](0x63, 0x61, 0x66, 0xE9))   # 'cafe' with a Latin-1 e acute
        Show-Folder $folder
        $listed = Get-NativeHTMLKitDocumentText -Document $doc -Element files
        if ((Find-NativeHTMLKitElement -Document $doc -Selector '#files li').matched_nodes -ne 3 -or $listed -ne 'data.jsonlatin1.txtnotes.md') { throw "unexpected folder list: $listed" }
        Invoke-FileClick ([pscustomobject]@{ element = 'file-2' })
        if ((Get-NativeHTMLKitValue -Document $doc -Element editor) -ne "# Notes`n<script>alert(1)</script>`n") { throw 'file content not loaded verbatim' }
        if (-not (Get-NativeHTMLKitWindow -Window $window).title.StartsWith('notes.md')) { throw 'window title not updated' }
        Import-TextFile (Join-Path $folder 'latin1.txt')
        $status = Get-NativeHTMLKitDocumentText -Document $doc -Element status
        if ($status -ne 'latin1.txt is not UTF-8 text.') { throw "unexpected status: $status" }
        Set-NativeHTMLKitDocumentValue -Document $doc -Element editor -Value "edited`n"
        Export-TextFile (Join-Path $folder 'out.txt')
        if ([IO.File]::ReadAllText((Join-Path $folder 'out.txt')).Replace("`r`n", "`n") -ne "edited`n") { throw 'save failed' }
        if ((Get-NativeHTMLKitCapabilities -Application $app).headless) {
            Request-Open
            $status = Get-NativeHTMLKitDocumentText -Document $doc -Element status
            if ($status -ne 'Native file dialogs are not available in this session.') { throw "unexpected dialog status: $status" }
        }
        Remove-Item -LiteralPath $folder -Recurse -Force
        [Console]::Out.WriteLine('SELFTEST PASS 07-file-preview')
        $null = Request-NativeHTMLKitQuit -Application $app
    }

    Wait-NativeHTMLKit -Application $app -UntilShutdown
} finally {
    Close-NativeHTMLKit -Application $app
}
