# bulk-rename/app.ps1 - rename many files with find/replace, a live preview and undo.
# This is the finished app of the tutorial docs/tutorials/bulk-rename.md.
#
# Teaches: an app split into index.html + style.css + app.ps1 (Open-NativeHTMLKitFile),
# a pure planning function that is easy to test, live preview on input events, the native
# folder picker with a capability fallback, a confirmation <dialog>, per-file error
# handling, and undo.
#
# Run:  pwsh -File ./app.ps1 [-Folder C:\Photos]
#       powershell.exe -NoProfile -File .\app.ps1
# -SelfTest renames files in a temporary folder, undoes it, and quits.
param([string]$Folder, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Import-Module NativeHTMLKit

# ---------------------------------------------------------------- planning (no UI) --

function Get-RenamePlan {
    # Returns one row per file: Old, New, Status (unchanged | rename | conflict | invalid | error), Note.
    param([string[]]$Names, [string]$Find, [string]$Replace, [bool]$Regex, [bool]$MatchCase)
    $options = [Text.RegularExpressions.RegexOptions]::None
    if (-not $MatchCase) { $options = [Text.RegularExpressions.RegexOptions]::IgnoreCase }
    $pattern = $Find
    $replacement = $Replace
    if (-not $Regex) {
        $pattern = [regex]::Escape($Find)
        $replacement = $Replace.Replace('$', '$$')   # literal text, not $1 group references
    }
    $matcher = $null
    $patternError = $null
    if ($Find) {
        try { $matcher = New-Object Text.RegularExpressions.Regex($pattern, $options) }
        catch {
            $reason = $_.Exception
            if ($null -ne $reason.InnerException) { $reason = $reason.InnerException }
            $patternError = 'Invalid pattern: ' + $reason.Message
        }
    }
    $comparer = [StringComparer]::Ordinal
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $comparer = [StringComparer]::OrdinalIgnoreCase }
    $existing = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList @(, $comparer)
    foreach ($name in $Names) { [void]$existing.Add($name) }
    $claimed = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList @(, $comparer)
    $invalid = [IO.Path]::GetInvalidFileNameChars()

    foreach ($name in $Names) {
        $row = [pscustomobject]@{ Old = $name; New = $name; Status = 'unchanged'; Note = '' }
        if ($patternError) { $row.Status = 'error'; $row.Note = $patternError }
        elseif ($null -ne $matcher) {
            $new = $matcher.Replace($name, $replacement)
            $row.New = $new
            if ($new -cne $name) {
                if (-not $new -or $new.IndexOfAny($invalid) -ge 0 -or $new -eq '.' -or $new -eq '..') { $row.Status = 'invalid'; $row.Note = 'Not a valid file name' }
                elseif (($existing.Contains($new) -and -not $comparer.Equals($new, $name)) -or -not $claimed.Add($new)) { $row.Status = 'conflict'; $row.Note = 'Name already used' }
                else { $row.Status = 'rename' }
            }
        }
        $row
    }
}

# --------------------------------------------------------------------- the app --

$app = Start-NativeHTMLKitScript -Name 'Bulk rename'
$selfTestFolder = $null
try {
    if ($SelfTest) {
        $selfTestFolder = Join-Path ([IO.Path]::GetTempPath()) ('nhk-rename-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $selfTestFolder
        foreach ($n in 'IMG_0001.jpg', 'IMG_0002.jpg', 'img_0003.JPG', 'notes.txt', 'holiday_0001.jpg') { [IO.File]::WriteAllText((Join-Path $selfTestFolder $n), $n) }
        $Folder = $selfTestFolder
    }

    $window = New-NativeHTMLKitWindow -Application $app -Title 'Bulk rename' -Width 900 -Height 620 -MinWidth 640 -MinHeight 400
    # Relative URLs in index.html (style.css) resolve against the file's folder.
    $doc = Open-NativeHTMLKitFile -Window $window -Path (Join-Path $PSScriptRoot 'index.html')

    $state = @{ Folder = $null; Names = @(); Plan = @(); Undo = @() }
    $caps = Get-NativeHTMLKitCapabilities -Application $app
    if (-not $caps.file_dialogs) { Set-NativeHTMLKitDocumentAttribute -Document $doc -Element browse -Name disabled }

    function Read-Rule {
        return @{
            Find = Get-NativeHTMLKitValue -Document $doc -Element find
            Replace = Get-NativeHTMLKitValue -Document $doc -Element replace
            Regex = Get-NativeHTMLKitChecked -Document $doc -Element regex
            MatchCase = Get-NativeHTMLKitChecked -Document $doc -Element case
        }
    }

    function Update-Preview {
        $rule = Read-Rule
        $state.Plan = @(Get-RenamePlan -Names $state.Names -Find $rule.Find -Replace $rule.Replace -Regex $rule.Regex -MatchCase $rule.MatchCase)
        $html = New-Object System.Text.StringBuilder
        foreach ($row in $state.Plan) {
            $status = $row.Status
            if ($row.Note) { $status = $row.Note }
            [void]$html.Append("<tr class=`"$($row.Status)`"><td>" + [Net.WebUtility]::HtmlEncode($row.Old) + '</td><td>' +
                [Net.WebUtility]::HtmlEncode($row.New) + '</td><td>' + [Net.WebUtility]::HtmlEncode($status) + '</td></tr>')
        }
        Set-NativeHTMLKitDocumentHtml -Document $doc -Element preview -Html $html.ToString()
        $count = @($state.Plan | Where-Object { $_.Status -eq 'rename' }).Count
        $blocked = @($state.Plan | Where-Object { $_.Status -in 'conflict', 'invalid', 'error' }).Count
        $summary = "$($state.Names.Count) file(s), $count to rename"
        if ($blocked) { $summary += ", $blocked skipped" }
        Set-NativeHTMLKitDocumentText -Document $doc -Element summary -Text $summary
        Set-NativeHTMLKitDocumentText -Document $doc -Element apply -Text "Rename $count"
        if ($count -gt 0) { Set-NativeHTMLKitDocumentAttribute -Document $doc -Element apply -Name disabled -Remove }
        else { Set-NativeHTMLKitDocumentAttribute -Document $doc -Element apply -Name disabled }
    }

    function Update-FileList {
        $state.Names = @(Get-ChildItem -LiteralPath $state.Folder -File | Sort-Object Name | ForEach-Object { $_.Name })
        Update-Preview
    }

    function Open-Folder([string]$Path) {
        if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
            Set-NativeHTMLKitDocumentText -Document $doc -Element summary -Text 'That folder does not exist.'
            return
        }
        $state.Folder = (Resolve-Path -LiteralPath $Path).ProviderPath
        Set-NativeHTMLKitDocumentValue -Document $doc -Element folder -Value $state.Folder
        Set-Undo @()
        Update-FileList
    }

    function Set-Undo($Steps) {
        $state.Undo = @($Steps)
        if ($state.Undo.Count -gt 0) { Set-NativeHTMLKitDocumentAttribute -Document $doc -Element undo -Name disabled -Remove }
        else { Set-NativeHTMLKitDocumentAttribute -Document $doc -Element undo -Name disabled }
    }

    function Invoke-Rename {
        $done = New-Object System.Collections.ArrayList
        $failed = 0
        foreach ($row in @($state.Plan | Where-Object { $_.Status -eq 'rename' })) {
            try {
                Rename-Item -LiteralPath (Join-Path $state.Folder $row.Old) -NewName $row.New
                [void]$done.Add(@{ From = $row.Old; To = $row.New })
            } catch { $failed++ }   # in use, permission denied, or changed since the preview
        }
        Set-Undo $done.ToArray()
        Update-FileList
        $message = "Renamed $($done.Count) file(s)."
        if ($failed) { $message += " $failed failed (in use, permission denied or changed)." }
        Set-NativeHTMLKitDocumentText -Document $doc -Element summary -Text $message
    }

    function Undo-Rename {
        if ($state.Undo.Count -eq 0) { return }
        $restored = 0
        # Reverse order, so chains such as a->b, b->c are undone correctly.
        foreach ($step in $state.Undo[($state.Undo.Count - 1)..0]) {
            try { Rename-Item -LiteralPath (Join-Path $state.Folder $step.To) -NewName $step.From; $restored++ } catch { $null = $_ }
        }
        Set-Undo @()
        Update-FileList
        Set-NativeHTMLKitDocumentText -Document $doc -Element summary -Text "Restored $restored file name(s)."
    }

    function Confirm-Rename([bool]$Yes) {
        Show-NativeHTMLKitHtmlDialog -Document $doc -Element confirm -Close -ReturnValue ''
        if ($Yes) { Invoke-Rename }
    }

    # Live preview: every keystroke or checkbox change in the rule form.
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type input -Element rule -Callback { Update-Preview }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type change -Element rule -Callback { Update-Preview }
    # Enter in a rule field submits the form: treat it as "update preview", nothing else.
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type submit -Element rule -Callback { Update-Preview }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element load -Callback { Open-Folder (Get-NativeHTMLKitValue -Document $doc -Element folder) }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element browse -Callback {
        try { $picked = Show-NativeHTMLKitFileDialog -Window $window -Kind ChooseFolder -Title 'Folder with files to rename' }
        catch [NativeHTMLKit.RpcException] { Set-NativeHTMLKitDocumentText -Document $doc -Element summary -Text $_.Exception.RpcMessage; return }
        if (-not $picked.cancelled) { Open-Folder @($picked.paths)[0] }
    }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element apply -Callback {
        $count = @($state.Plan | Where-Object { $_.Status -eq 'rename' }).Count
        Set-NativeHTMLKitDocumentText -Document $doc -Element confirm-text -Text "Rename $count file(s) in $($state.Folder)?"
        Show-NativeHTMLKitHtmlDialog -Document $doc -Element confirm
    }
    # Decide in the button handlers, not in the dialog's close event: a <dialog> keeps its
    # previous return value when the user dismisses it with Escape.
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element confirm-no -Callback { Confirm-Rename $false }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element confirm-yes -Callback { Confirm-Rename $true }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Element undo -Callback { Undo-Rename }

    if ($Folder) { Open-Folder $Folder }
    Set-NativeHTMLKitReady -Application $app

    if ($SelfTest) {
        Set-NativeHTMLKitDocumentValue -Document $doc -Element find -Value '^img_(\d+)'
        Set-NativeHTMLKitDocumentValue -Document $doc -Element replace -Value 'photo-$1'
        Set-NativeHTMLKitChecked -Document $doc -Element regex -Checked $true
        Update-Preview
        if ((Get-NativeHTMLKitDocumentText -Document $doc -Element summary) -ne '5 file(s), 3 to rename') { throw 'unexpected regex preview' }
        Set-NativeHTMLKitChecked -Document $doc -Element case -Checked $true
        Update-Preview
        if ((Get-NativeHTMLKitDocumentText -Document $doc -Element summary) -ne '5 file(s), 1 to rename') { throw 'match case not applied' }
        Set-NativeHTMLKitDocumentValue -Document $doc -Element find -Value '('
        Update-Preview
        if ((Find-NativeHTMLKitElement -Document $doc -Selector '#preview tr.error').matched_nodes -ne 5) { throw 'invalid pattern not reported' }
        # Literal mode: '0001' -> 'notes' clashes with nothing, but two files would get the same name.
        Set-NativeHTMLKitChecked -Document $doc -Element regex -Checked $false
        Set-NativeHTMLKitChecked -Document $doc -Element case -Checked $false
        Set-NativeHTMLKitDocumentValue -Document $doc -Element find -Value 'holiday'
        Set-NativeHTMLKitDocumentValue -Document $doc -Element replace -Value 'IMG'
        Update-Preview
        if ((Find-NativeHTMLKitElement -Document $doc -Selector '#preview tr.conflict').matched_nodes -ne 1) { throw 'conflict not detected' }
        Set-NativeHTMLKitDocumentValue -Document $doc -Element find -Value 'IMG_'
        Set-NativeHTMLKitDocumentValue -Document $doc -Element replace -Value '2026 $ '
        Update-Preview
        # The confirm path: the dialog opens, the user picks "Rename".
        Show-NativeHTMLKitHtmlDialog -Document $doc -Element confirm
        Confirm-Rename $true
        if ((Invoke-NativeHTMLKitDocumentCommand -Document $doc -Operation get_dialog -Parameters @{ element = 'confirm' }).open) { throw 'dialog still open' }
        $names = @(Get-ChildItem -LiteralPath $selfTestFolder -File | ForEach-Object { $_.Name } | Sort-Object)
        if (-not ($names -contains '2026 $ 0001.jpg') -or -not ($names -contains '2026 $ 0003.JPG')) { throw "rename failed: $($names -join ', ')" }
        Undo-Rename
        if ((Get-NativeHTMLKitDocumentText -Document $doc -Element summary) -ne 'Restored 3 file name(s).') { throw 'undo failed' }
        if (-not (Test-Path -LiteralPath (Join-Path $selfTestFolder 'img_0003.JPG'))) { throw 'original name not restored' }
        [Console]::Out.WriteLine('SELFTEST PASS bulk-rename')
        $null = Request-NativeHTMLKitQuit -Application $app
    }

    Wait-NativeHTMLKit -Application $app -UntilShutdown
} finally {
    Close-NativeHTMLKit -Application $app
    if ($selfTestFolder) { Remove-Item -LiteralPath $selfTestFolder -Recurse -Force -ErrorAction SilentlyContinue }
}
