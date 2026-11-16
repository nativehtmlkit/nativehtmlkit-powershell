# Keeps the documentation honest without a native host (Pester 5+):
#   * every exported function and alias of the module is documented in docs/reference with a
#     syntax block and a row for each of its parameters;
#   * every titled code excerpt in a tutorial (title="<file>.ps1") appears verbatim in that tested
#     example file;
#   * the docs tree has the shared layout (getting started, the three tutorials, the canonical
#     guide ids listed in order in docs/guides/README.md), and every page starts with one '# ' title;
#   * links resolve: relative links (and #anchors) in README.md, docs/ and examples/README.md, and
#     absolute https://github.com/nativehtmlkit/nativehtmlkit-powershell/(blob|tree)/main/ links,
#     which must point at existing files; pages under docs/ link outside docs/ only absolutely.
BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module $script:ModuleManifest -Force -ErrorAction Stop
    $script:CommandCases = @(Get-Command -Module NativeHTMLKit -CommandType Function | Sort-Object Name | ForEach-Object { @{ Name = $_.Name } })
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module $script:ModuleManifest -Force -ErrorAction Stop
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Sections = @{}
    foreach ($page in Get-ChildItem -LiteralPath (Join-Path $script:Root 'docs/reference') -Filter '*.md') {
        $parts = [regex]::Split([IO.File]::ReadAllText($page.FullName), '(?m)^### ')
        foreach ($part in $parts | Select-Object -Skip 1) {
            $name = ($part -split "\r?\n", 2)[0].Trim()
            $script:Sections[$name] = $part
        }
    }
    function Get-Slug([string]$Heading) {
        # GitHub heading anchors: lower case, punctuation removed, spaces to hyphens.
        $slug = $Heading.Trim().ToLowerInvariant() -replace '[^\p{L}\p{Nd}\s_-]', ''
        return ($slug -replace '\s', '-')
    }
}

Describe 'Cmdlet reference completeness' {
    It '<Name> is documented with its alias, syntax and every parameter' -ForEach $script:CommandCases {
        $script:Sections.ContainsKey($Name) | Should -BeTrue -Because "docs/reference needs a '### $Name' section"
        $section = $script:Sections[$Name]
        $alias = @(Get-Command -Module NativeHTMLKit -CommandType Alias | Where-Object { $_.ResolvedCommandName -eq $Name })
        $alias.Count | Should -Be 1
        $section | Should -Match ([regex]::Escape("Alias: ``$($alias[0].Name)``"))
        $section | Should -Match ([regex]::Escape(($Name + ' ')) )
        $common = [Management.Automation.PSCmdlet]::CommonParameters + [Management.Automation.PSCmdlet]::OptionalCommonParameters
        foreach ($parameter in (Get-Command $Name).Parameters.Keys | Where-Object { $common -notcontains $_ }) {
            $section | Should -Match ([regex]::Escape("| ``-$parameter`` |")) -Because "parameter -$parameter of $Name"
        }
    }
    It 'the alias table lists every alias' {
        $table = [IO.File]::ReadAllText((Join-Path $script:Root 'docs/reference/aliases.md'))
        foreach ($alias in Get-Command -Module NativeHTMLKit -CommandType Alias) { $table | Should -Match ([regex]::Escape("| ``$($alias.Name)`` | ``$($alias.ResolvedCommandName)`` |")) }
    }
}

Describe 'Tutorial excerpts' {
    It 'every titled excerpt in docs/tutorials/<Tutorial>.md appears verbatim in its example file' -ForEach @(
        @{ Tutorial = 'bulk-rename'; Folders = @('examples/bulk-rename'); Minimum = 6 }
        @{ Tutorial = 'todo-app'; Folders = @('examples/todo-tutorial', 'examples'); Minimum = 8 }
        @{ Tutorial = 'process-dashboard'; Folders = @('examples/process-dashboard'); Minimum = 8 }
    ) {
        $tutorial = [IO.File]::ReadAllText((Join-Path $script:Root "docs/tutorials/$Tutorial.md"))
        $blocks = [regex]::Matches($tutorial, '```powershell title="(?<file>[\w.-]+\.ps1)"\r?\n(?<code>.*?)```', 'Singleline')
        $blocks.Count | Should -BeGreaterOrEqual $Minimum
        foreach ($block in $blocks) {
            $source = @($Folders | ForEach-Object { Join-Path (Join-Path $script:Root $_) $block.Groups['file'].Value } | Where-Object { Test-Path -LiteralPath $_ })[0]
            $source | Should -Not -BeNullOrEmpty -Because "no example file $($block.Groups['file'].Value)"
            $app = @([IO.File]::ReadAllLines($source) | ForEach-Object { $_.Trim() })
            $lines = @($block.Groups['code'].Value -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $found = $false
            for ($i = 0; $i -le $app.Count - $lines.Count -and -not $found; $i++) {
                if ($app[$i] -ne $lines[0]) { continue }
                $j = 0; $k = $i
                while ($j -lt $lines.Count -and $k -lt $app.Count) {
                    if (-not $app[$k]) { $k++; continue }
                    if ($app[$k] -ne $lines[$j]) { break }
                    $j++; $k++
                }
                $found = $j -eq $lines.Count
            }
            $found | Should -BeTrue -Because ("excerpt not found in ${source}:`n" + ($lines -join "`n"))
        }
    }
}

Describe 'Documentation layout' {
    It 'has getting started, the three tutorials and every canonical guide, listed in order' {
        foreach ($page in 'getting-started', 'tutorials/todo-app', 'tutorials/bulk-rename', 'tutorials/process-dashboard', 'API', 'guides/README') {
            Test-Path -LiteralPath (Join-Path $script:Root "docs/$page.md") | Should -BeTrue -Because "docs/$page.md"
        }
        $canonical = @('lifecycle', 'events-and-callbacks', 'updating-the-page', 'forms-and-validation', 'windows', 'file-dialogs',
            'dialogs-and-popovers', 'clipboard-and-desktop', 'keyboard-and-focus', 'styling-and-layout', 'live-bitmaps',
            'background-work', 'diagnostics-and-troubleshooting', 'packaging-and-distribution', 'project-scaffolding', 'security')
        $extras = @('windows-powershell-51')
        $present = @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'docs/guides') -Filter '*.md' | Where-Object { $_.Name -ne 'README.md' } | ForEach-Object { $_.BaseName } | Sort-Object)
        ($present -join ',') | Should -Be (@($canonical + $extras | Sort-Object) -join ',')
        $index = [IO.File]::ReadAllText((Join-Path $script:Root 'docs/guides/README.md'))
        $listed = @([regex]::Matches($index, '\]\(([\w-]+)\.md\)') | ForEach-Object { $_.Groups[1].Value })
        ($listed -join ',') | Should -Be (@($canonical + $extras) -join ',')
    }
    It 'every page under docs/ starts with a single # title' {
        foreach ($page in Get-ChildItem -LiteralPath (Join-Path $script:Root 'docs') -Recurse -Filter '*.md') {
            $lines = [IO.File]::ReadAllLines($page.FullName)
            $lines[0] | Should -Match '^# \S' -Because $page.FullName
            $text = [regex]::Replace([IO.File]::ReadAllText($page.FullName), '(?s)```.*?```', '')
            @([regex]::Matches($text, '(?m)^# ')).Count | Should -Be 1 -Because $page.FullName
        }
    }
}

Describe 'Documentation links' {
    It 'relative links and anchors resolve' {
        $files = @(Get-Item -LiteralPath (Join-Path $script:Root 'README.md'), (Join-Path $script:Root 'examples/README.md')) +
            @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'docs') -Recurse -Filter '*.md')
        $broken = New-Object System.Collections.Generic.List[string]
        $docsRoot = [IO.Path]::GetFullPath((Join-Path $script:Root 'docs')) + [IO.Path]::DirectorySeparatorChar
        foreach ($file in $files) {
            $text = [IO.File]::ReadAllText($file.FullName)
            $text = [regex]::Replace($text, '(?s)```.*?```', '')
            foreach ($m in [regex]::Matches($text, '\]\((?<target>[^)\s]+)\)')) {
                $target = $m.Groups['target'].Value
                $own = [regex]::Match($target, '^https://github\.com/nativehtmlkit/nativehtmlkit-powershell/(blob|tree)/main/(?<path>[^#?]+)(#(?<anchor>.*))?$')
                if ($own.Success) {
                    # An absolute link into this repository must name an existing file or folder.
                    $local = Join-Path $script:Root ([Uri]::UnescapeDataString($own.Groups['path'].Value))
                    if (-not (Test-Path -LiteralPath $local)) { $broken.Add("$($file.Name): $target (no such file in this repository)") }
                    continue
                }
                if ($target -match '^(https?:|mailto:)') { continue }
                $path, $anchor = $target -split '#', 2
                $resolved = $file.FullName
                if ($path) { $resolved = [IO.Path]::GetFullPath((Join-Path $file.DirectoryName $path)) }
                if ($file.FullName.StartsWith($docsRoot) -and -not $resolved.StartsWith($docsRoot)) { $broken.Add("$($file.Name): $target (pages under docs/ link outside docs/ with absolute URLs)"); continue }
                if (-not (Test-Path -LiteralPath $resolved)) { $broken.Add("$($file.Name): $target"); continue }
                if ($anchor -and $resolved.EndsWith('.md')) {
                    $slugs = @([regex]::Matches([IO.File]::ReadAllText($resolved), '(?m)^#{1,6}\s+(.+?)\s*$') | ForEach-Object { Get-Slug $_.Groups[1].Value })
                    if ($slugs -notcontains $anchor) { $broken.Add("$($file.Name): $target (anchor)") }
                }
            }
        }
        $broken | Should -BeNullOrEmpty
    }
}
