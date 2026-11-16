# Keeps the documentation honest without a native host (Pester 5+):
#   * every exported function and alias of the module is documented in docs/reference with a
#     syntax block and a row for each of its parameters;
#   * every app.ps1 excerpt in the tutorial is part of the tested examples/bulk-rename/app.ps1;
#   * relative links (and #anchors) in README.md, docs/ and examples/README.md resolve.
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
    It 'every app.ps1 excerpt in docs/tutorials/bulk-rename.md appears verbatim in examples/bulk-rename/app.ps1' {
        $tutorial = [IO.File]::ReadAllText((Join-Path $script:Root 'docs/tutorials/bulk-rename.md'))
        $app = @([IO.File]::ReadAllLines((Join-Path $script:Root 'examples/bulk-rename/app.ps1')) | ForEach-Object { $_.Trim() })
        $blocks = [regex]::Matches($tutorial, '```powershell title="app\.ps1"\r?\n(?<code>.*?)```', 'Singleline')
        $blocks.Count | Should -BeGreaterThan 5
        foreach ($block in $blocks) {
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
            $found | Should -BeTrue -Because ("excerpt not found in app.ps1:`n" + ($lines -join "`n"))
        }
    }
}

Describe 'Documentation links' {
    It 'relative links and anchors resolve' {
        $files = @(Get-Item -LiteralPath (Join-Path $script:Root 'README.md'), (Join-Path $script:Root 'examples/README.md')) +
            @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'docs') -Recurse -Filter '*.md')
        $broken = New-Object System.Collections.Generic.List[string]
        foreach ($file in $files) {
            $text = [IO.File]::ReadAllText($file.FullName)
            $text = [regex]::Replace($text, '(?s)```.*?```', '')
            foreach ($m in [regex]::Matches($text, '\]\((?<target>[^)\s]+)\)')) {
                $target = $m.Groups['target'].Value
                if ($target -match '^(https?:|mailto:)') { continue }
                $path, $anchor = $target -split '#', 2
                $resolved = $file.FullName
                if ($path) { $resolved = [IO.Path]::GetFullPath((Join-Path $file.DirectoryName $path)) }
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
