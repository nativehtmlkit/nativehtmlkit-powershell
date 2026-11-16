# 10-clipboard-tool.ps1 - a text transformer with Paste and Copy buttons.
#
# Teaches: Get-/Set-NativeHTMLKitClipboard (plain text), checking clipboard_text in
# Get-NativeHTMLKitCapabilities before offering clipboard buttons, handling a refused
# clipboard request (NativeHTMLKit.RpcException), and textarea values.
#
# Run:  pwsh -File ./10-clipboard-tool.ps1     (or powershell.exe -NoProfile -File .\10-clipboard-tool.ps1)
# -SelfTest transforms text through the public API and quits. In the host's headless test
# mode the clipboard is unavailable, so the self-test checks the fallback message instead.
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Import-Module NativeHTMLKit

$app = Start-NativeHTMLKitScript -Name 'Clipboard tool'
try {
    $window = New-NativeHTMLKitWindow -Application $app -Title 'Clipboard tool' -Width 720 -Height 520
    $doc = Open-NativeHTMLKitHtml -Window $window -Html @'
<!doctype html>
<html><head><style>
  body { font-family: system-ui, sans-serif; margin: 16px; display: grid; grid-template-rows: auto 1fr auto 1fr auto; gap: 8px; height: calc(100vh - 32px); }
  textarea { font: 13px/1.4 monospace; padding: 6px; resize: none; }
  .row { display: flex; gap: 6px; flex-wrap: wrap; align-items: center; }
  #status { color: #555; font-size: 13px; }
</style></head>
<body>
  <div class="row"><button id="paste">Paste from clipboard</button><span>Input</span></div>
  <textarea id="input" aria-label="Input text"></textarea>
  <div class="row" id="actions">
    <button id="t-upper">UPPER</button><button id="t-lower">lower</button><button id="t-trim">Trim lines</button>
    <button id="t-sort">Sort unique</button><button id="t-b64">Base64 encode</button><button id="t-unb64">Base64 decode</button>
    <button id="t-json">Pretty JSON</button>
  </div>
  <textarea id="output" aria-label="Result" readonly></textarea>
  <div class="row"><button id="copy">Copy result</button><span id="status" role="status"></span></div>
</body></html>
'@

    $caps = Get-NativeHTMLKitCapabilities -Application $app
    if (-not $caps.clipboard_text) {
        foreach ($id in 'paste', 'copy') { Set-NativeHTMLKitDocumentAttribute -Document $doc -Element $id -Name disabled }
        Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text 'The clipboard is not available in this session.'
    }

    function Convert-Text([string]$Name, [string]$Text) {
        $lines = $Text -split "\r?\n"
        switch ($Name) {
            'upper' { return $Text.ToUpperInvariant() }
            'lower' { return $Text.ToLowerInvariant() }
            'trim'  { return (($lines | ForEach-Object { $_.Trim() }) -join "`n") }
            'sort'  { return ((@($lines | Where-Object { $_ }) | Sort-Object -Unique) -join "`n") }
            'b64'   { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)) }
            'unb64' { return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Text.Trim())) }
            'json'  { return (ConvertTo-Json -InputObject (ConvertFrom-Json -InputObject $Text) -Depth 32) }
        }
    }

    function Invoke-Transform([string]$Name) {
        $text = Get-NativeHTMLKitValue -Document $doc -Element input
        try {
            Set-NativeHTMLKitDocumentValue -Document $doc -Element output -Value (Convert-Text $Name $text)
            Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text "Applied '$Name'."
        } catch {
            # Bad Base64 or JSON input is a user error, not an application failure.
            Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text ("Cannot apply '$Name': " + $_.Exception.Message)
        }
    }

    function Invoke-Copy {
        $text = Get-NativeHTMLKitValue -Document $doc -Element output
        try {
            Set-NativeHTMLKitClipboard -Application $app -Text $text
            Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text "Copied $($text.Length) characters."
        } catch [NativeHTMLKit.RpcException] {
            Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text ('Copy failed: ' + $_.Exception.RpcMessage)
        }
    }

    function Invoke-Paste {
        try {
            Set-NativeHTMLKitDocumentValue -Document $doc -Element input -Value (Get-NativeHTMLKitClipboard -Application $app)
            Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text 'Pasted.'
        } catch [NativeHTMLKit.RpcException] {
            Set-NativeHTMLKitDocumentText -Document $doc -Element status -Text ('Paste failed: ' + $_.Exception.RpcMessage)
        }
    }

    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element actions -Callback {
        param($evt)
        if ($evt.element -match '^t-(\w+)$') { Invoke-Transform $Matches[1] }
    }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element copy -Callback { Invoke-Copy }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element paste -Callback { Invoke-Paste }

    Set-NativeHTMLKitReady -Application $app

    if ($SelfTest) {
        Set-NativeHTMLKitDocumentValue -Document $doc -Element input -Value "  beta`n alpha `nbeta"
        Invoke-Transform 'trim'
        Set-NativeHTMLKitDocumentValue -Document $doc -Element input -Value (Get-NativeHTMLKitValue -Document $doc -Element output)
        Invoke-Transform 'sort'
        if ((Get-NativeHTMLKitValue -Document $doc -Element output) -ne "alpha`nbeta") { throw 'trim + sort unique failed' }
        Set-NativeHTMLKitDocumentValue -Document $doc -Element input -Value 'not json'
        Invoke-Transform 'json'
        if (-not (Get-NativeHTMLKitDocumentText -Document $doc -Element status).StartsWith("Cannot apply 'json'")) { throw 'bad input should be reported' }
        Invoke-Copy
        $status = Get-NativeHTMLKitDocumentText -Document $doc -Element status
        if ($caps.clipboard_text) {
            if ($status -notmatch '^Copied ' -or (Get-NativeHTMLKitClipboard -Application $app) -ne "alpha`nbeta") { throw "copy failed: $status" }
        } elseif (-not $status.StartsWith('Copy failed: ')) { throw "unexpected status: $status" }
        [Console]::Out.WriteLine('SELFTEST PASS 10-clipboard-tool')
        $null = Request-NativeHTMLKitQuit -Application $app
    }

    Wait-NativeHTMLKit -Application $app -UntilShutdown
} finally {
    Close-NativeHTMLKit -Application $app
}
