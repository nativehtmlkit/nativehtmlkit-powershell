# Module, codec, generator and skill-installer tests (no host required). Pester 5+.
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module $script:ModuleManifest -Force -ErrorAction Stop
    & (Get-Module NativeHTMLKit) { Initialize-NativeHTMLKitHelper }
}

Describe 'NativeHTMLKit manifest and exports' {
    It 'has the 0.1.2 identity and matching manifest/module exports' {
        $m = Test-ModuleManifest $script:ModuleManifest
        $m.Version.ToString() | Should -Be '0.1.2'
        (& (Get-Module NativeHTMLKit) { $script:NativeHTMLKitVersion }) | Should -Be '0.1.2'
        $m.CompatiblePSEditions | Should -Contain 'Desktop'
        $m.CompatiblePSEditions | Should -Contain 'Core'
        $declared = @($m.ExportedFunctions.Keys | Sort-Object)
        $actual = @((Get-Command -Module NativeHTMLKit -CommandType Function).Name | Sort-Object)
        ($actual -join ',') | Should -Be ($declared -join ',')
        $actual.Count | Should -Be 88
        # Explicit (no wildcard) so an installed module can auto-load on first use of an alias.
        $declaredAliases = @($m.ExportedAliases.Keys | Sort-Object)
        $aliases = @((Get-Command -Module NativeHTMLKit -CommandType Alias).Name | Sort-Object)
        $aliases.Count | Should -Be 88
        ($declaredAliases -join ',') | Should -Be ($aliases -join ',')
        foreach ($a in Get-Command -Module NativeHTMLKit -CommandType Alias) {
            $a.Name | Should -Match '^[A-Z][a-z]+-NHK'
            # Every short alias maps to the canonical command with the same verb and noun.
            $a.ResolvedCommand.Name | Should -Be ($a.Name -replace '-NHK', '-NativeHTMLKit')
            $a.ResolvedCommand.Module.Name | Should -Be 'NativeHTMLKit'
        }
    }
    It 'auto-loads from PSModulePath on first use of a short alias' {
        $mods = Join-Path $TestDrive 'autoload-modules'
        Copy-Item -LiteralPath (Split-Path -Parent $script:ModuleManifest) -Destination (Join-Path $mods 'NativeHTMLKit') -Recurse
        $shell = (Get-Process -Id $PID).Path
        $cmd = "`$env:PSModulePath = '$mods' + [IO.Path]::PathSeparator + `$env:PSModulePath; `$c = Get-Command New-NHKProject -ErrorAction Stop; `$c.ResolvedCommand.Name + '|' + (Get-Module NativeHTMLKit).ModuleBase"
        $out = & $shell -NoProfile -NonInteractive -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd)))
        $out | Should -Be ('New-NativeHTMLKitProject|' + (Join-Path $mods 'NativeHTMLKit'))
    }
    It 'meets the PowerShell Gallery manifest rules' {
        $m = Test-ModuleManifest $script:ModuleManifest
        $data = Import-PowerShellDataFile -LiteralPath $script:ModuleManifest
        $ps = $data.PrivateData.PSData
        $m.Author | Should -Not -BeNullOrEmpty
        $m.Description.Length | Should -BeGreaterThan 20
        $m.Description.Length | Should -BeLessOrEqual 4000
        $ps.ProjectUri | Should -Match '^https://'
        $ps.LicenseUri | Should -Match '^https://'
        $ps.ContainsKey('Prerelease') | Should -BeFalse
        $m.Version.ToString() | Should -Match '^\d+\.\d+\.\d+$'
        @($ps.Tags).Count | Should -BeLessOrEqual 50
        foreach ($t in $ps.Tags) { $t | Should -Match '^[A-Za-z0-9_.-]{1,64}$' }
        (@($ps.Tags) -join ' ').Length | Should -BeLessOrEqual 4000
        $ps.ReleaseNotes | Should -Match ('^' + [regex]::Escape($m.Version.ToString()))
        $data.ContainsKey('FunctionsToExport') -and @($data.FunctionsToExport) -notcontains '*' | Should -BeTrue
        @($data.AliasesToExport) -notcontains '*' | Should -BeTrue
    }
    It 'documents every exported function (aliases share their target help)' {
        foreach ($c in Get-Command -Module NativeHTMLKit -CommandType Function) {
            (Get-Help $c.Name).Name | Should -Be $c.Name
        }
        foreach ($a in Get-Command -Module NativeHTMLKit -CommandType Alias) {
            (Get-Help $a.Name).Name | Should -Be $a.ResolvedCommand.Name
        }
    }
    It 'keeps module sources ASCII and gives non-ASCII scripts a BOM (Windows PowerShell 5.1 reads BOM-less files as ANSI)' {
        $root = Split-Path -Parent (Split-Path -Parent $script:ModuleManifest)
        foreach ($f in Get-ChildItem -LiteralPath (Split-Path -Parent $script:ModuleManifest) -Recurse -File | Where-Object { $_.Extension -in '.psm1', '.psd1' }) {
            $bytes = [IO.File]::ReadAllBytes($f.FullName)
            @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0 -Because $f.FullName
        }
        $scripts = @(Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File -Filter *.ps1)
        $examples = Join-Path $root 'examples'
        if (Test-Path -LiteralPath $examples) { $scripts += @(Get-ChildItem -LiteralPath $examples -Recurse -File -Filter *.ps1) }
        foreach ($f in $scripts) {
            $bytes = [IO.File]::ReadAllBytes($f.FullName)
            if (@($bytes | Where-Object { $_ -gt 127 }).Count -gt 0) {
                ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue -Because "$($f.FullName) has non-ASCII text"
            }
        }
    }
    It 'rejects connecting without host credentials' {
        { Connect-NativeHTMLKit -Endpoint '' -Token '' } | Should -Throw
    }
}

Describe 'NativeHTMLKit JSON codec' {
    It 'keeps date-like strings and numeric types' {
        $v = [NativeHTMLKit.Json]::Parse('{"d":"2024-01-01T00:00:00Z","i":5,"l":5000000000,"f":1.25,"e":1e3,"u":18446744073709551615}')
        $v.d | Should -BeOfType ([string])
        $v.i | Should -BeOfType ([int])
        $v.l | Should -BeOfType ([long])
        $v.f | Should -Be 1.25
        $v.e | Should -Be 1000
        $v.u | Should -BeOfType ([uint64])
    }
    It 'decodes escapes and surrogate pairs' {
        ([NativeHTMLKit.Json]::Parse('"aé😀\n\"\\\/"')) | Should -BeExactly ("aé😀`n" + '"\/')
    }
    It 'preserves keys that differ only by case' {
        $v = [NativeHTMLKit.Json]::Parse('{"A":1,"a":2}')
        $v['A'] | Should -Be 1
        $v['a'] | Should -Be 2
    }
    It 'rejects invalid input' {
        foreach ($bad in @('{"a":1,"a":2}', '[1,]', '{"a":NaN}', '"\x"', "`"a`nb`"", '01', '1.', '{"a":1} x', '[' * 200 + ']' * 200)) {
            { [NativeHTMLKit.Json]::Parse($bad) } | Should -Throw
        }
    }
    It 'serializes PowerShell values without wrapper artifacts' {
        $json = [NativeHTMLKit.Json]::Serialize([ordered]@{ a = @(1); b = @(); c = [pscustomobject]@{ x = 'y' }; d = $null; e = [double]0.1; f = ('q"' + [char]1) })
        $json | Should -BeExactly '{"a":[1],"b":[],"c":{"x":"y"},"d":null,"e":0.1,"f":"q\"\u0001"}'
    }
    It 'refuses values the host cannot interpret' {
        { [NativeHTMLKit.Json]::Serialize(@{ a = [double]::NaN }) } | Should -Throw
        { [NativeHTMLKit.Json]::Serialize(@{ a = { 1 } }) } | Should -Throw
        { [NativeHTMLKit.Json]::Serialize(@{ a = (Get-Date) }) } | Should -Throw
        { [NativeHTMLKit.Json]::Serialize(@{ 1 = 'x' }) } | Should -Throw
    }
}

Describe 'New-NativeHTMLKitProject' {
    It 'generates a runnable pwsh project' {
        $path = Join-Path $TestDrive 'my app ü'
        $item = New-NativeHTMLKitProject -Path $path -Name 'Mÿ App' -AppId org.example.Generated
        $item.FullName | Should -Be ([IO.Path]::GetFullPath($path))
        $toml = Get-Content -LiteralPath (Join-Path $path 'app.toml') -Raw -Encoding UTF8
        $toml | Should -Match 'program = "pwsh"'
        $toml | Should -Match 'name = "Mÿ App"'
        $toml | Should -Match '"-File", "\{app_dir\}/app.ps1"'
        $toml | Should -Match 'id = "org.example.Generated"'
        Test-Path -LiteralPath (Join-Path $path 'backend.ps1') | Should -BeFalse
        $backendBytes = [IO.File]::ReadAllBytes((Join-Path $path 'app.ps1'))
        $backendBytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        $backend = Get-Content -LiteralPath (Join-Path $path 'app.ps1') -Raw -Encoding UTF8
        $backend | Should -Match "Title 'Mÿ App'"
        # Runs directly; both launch routes share the manifest identity.
        $backend | Should -Match "Start-NativeHTMLKitScript -Name 'Mÿ App' -AppId 'org.example.Generated'"
        $backend | Should -Not -Match 'Connect-NativeHTMLKit'
        $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseInput($backend, [ref]$null, [ref]$errors)
        @($errors).Count | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $path 'index.html') -Raw) | Should -Match 'stylesheet'
        Test-Path -LiteralPath (Join-Path $path 'style.css') | Should -BeTrue
    }
    It 'generates a Windows PowerShell 5.1 project' {
        $path = Join-Path $TestDrive 'ps51'
        $null = New-NativeHTMLKitProject -Path $path -WindowsPowerShell
        (Get-Content -LiteralPath (Join-Path $path 'app.toml') -Raw) | Should -Match 'program = "powershell.exe"'
    }
    It 'refuses to overwrite without -Force and validates names' {
        $path = Join-Path $TestDrive 'twice'
        $null = New-NativeHTMLKitProject -Path $path
        { New-NativeHTMLKitProject -Path $path } | Should -Throw
        { New-NativeHTMLKitProject -Path $path -Force } | Should -Not -Throw
        { New-NativeHTMLKitProject -Path (Join-Path $TestDrive 'bad1') -Name 'a"b' } | Should -Throw
        { New-NativeHTMLKitProject -Path (Join-Path $TestDrive 'bad2') -AppId 'noperiod' } | Should -Throw
    }
}

Describe 'Install-NativeHTMLKitSkill' {
    BeforeAll { $script:project = Join-Path $TestDrive 'proj é' ; $null = New-Item -ItemType Directory -Path $script:project }
    It 'plans without touching the file system' {
        $plan = @(Install-NativeHTMLKitSkill -Agents claude, codex -Scope project -ProjectPath $script:project -DryRun)
        $plan.Count | Should -Be 2
        $plan[0].Action | Should -Be 'would-install'
        Test-Path -LiteralPath (Join-Path $script:project '.claude') | Should -BeFalse
    }
    It 'installs for every agent in project scope' {
        $done = @(Install-NativeHTMLKitSkill -Agents all -Scope project -ProjectPath $script:project)
        $done.Count | Should -Be 6
        foreach ($rel in '.claude/skills', '.agents/skills', '.opencode/skills', '.github/skills', '.cursor/skills', '.gemini/skills') {
            $skill = Join-Path (Join-Path $script:project $rel) 'nativehtmlkit-powershell/SKILL.md'
            Test-Path -LiteralPath $skill | Should -BeTrue
            (Get-Content -LiteralPath $skill -Raw -Encoding UTF8) | Should -Match '(?m)^name: nativehtmlkit-powershell$'
        }
        @(Install-NativeHTMLKitSkill -Action status -Scope project -ProjectPath $script:project | Where-Object State -eq 'installed').Count | Should -Be 6
        # Reinstalling an unmodified install is allowed.
        { Install-NativeHTMLKitSkill -Agents claude -Scope project -ProjectPath $script:project } | Should -Not -Throw
    }
    It 'refuses to replace or remove modified and unmanaged folders' {
        $skill = Join-Path $script:project '.claude/skills/nativehtmlkit-powershell/SKILL.md'
        Add-Content -LiteralPath $skill -Value 'local edit'
        (Install-NativeHTMLKitSkill -Action status -Agents claude -Scope project -ProjectPath $script:project).State | Should -Be 'modified'
        { Install-NativeHTMLKitSkill -Agents claude -Scope project -ProjectPath $script:project } | Should -Throw
        { Install-NativeHTMLKitSkill -Action uninstall -Agents claude -Scope project -ProjectPath $script:project } | Should -Throw
        $unmanaged = Join-Path $script:project '.cursor/skills/nativehtmlkit-powershell'
        Remove-Item -LiteralPath (Join-Path $unmanaged '.nativehtmlkit-managed.json') -Force
        (Install-NativeHTMLKitSkill -Action status -Agents cursor -Scope project -ProjectPath $script:project).State | Should -Be 'unmanaged'
        { Install-NativeHTMLKitSkill -Agents cursor -Scope project -ProjectPath $script:project } | Should -Throw
        $null = Install-NativeHTMLKitSkill -Agents claude, cursor -Scope project -ProjectPath $script:project -Force
        (Get-Content -LiteralPath $skill -Raw) | Should -Not -Match 'local edit'
    }
    It 'uninstalls cleanly and leaves no temporary folders' {
        $removed = @(Install-NativeHTMLKitSkill -Action uninstall -Agents all -Scope project -ProjectPath $script:project)
        @($removed | Where-Object Action -eq 'removed').Count | Should -Be 6
        # The installer stages under .nativehtmlkit-skill-new-*/-old-* names.
        @(Get-ChildItem -LiteralPath $script:project -Recurse -Force | Where-Object { $_.Name -like '.nativehtmlkit-skill-*' }).Count | Should -Be 0
        @(Install-NativeHTMLKitSkill -Action status -Scope project -ProjectPath $script:project | Where-Object State -ne 'missing').Count | Should -Be 0
    }
    It 'validates agents and scope arguments' {
        { Install-NativeHTMLKitSkill -Agents vim -Scope project -ProjectPath $script:project } | Should -Throw
        { Install-NativeHTMLKitSkill -Scope project } | Should -Throw
        { Install-NativeHTMLKitSkill -Scope user -ProjectPath $script:project } | Should -Throw
    }
}

Describe 'Bundled agent skill' {
    It 'has the front matter agents need to discover it' {
        $skill = Join-Path (Split-Path -Parent $script:ModuleManifest) 'skills/nativehtmlkit-powershell/SKILL.md'
        $text = [IO.File]::ReadAllText($skill)
        $text | Should -Match '\A---\r?\nname: nativehtmlkit-powershell\r?\ndescription: \S'
    }
}

Describe 'Get-NativeHTMLKitHostPath' {
    AfterEach { Remove-Item Env:UI4ME_HOST_BINARY, Env:NATIVEHTMLKIT_HOST_BINARY -ErrorAction SilentlyContinue }
    It 'prefers NATIVEHTMLKIT_HOST_BINARY over the legacy UI4ME_HOST_BINARY' {
        $a = Join-Path $TestDrive 'host-a'; $b = Join-Path $TestDrive 'host-b'
        Set-Content -LiteralPath $a -Value 'a'; Set-Content -LiteralPath $b -Value 'b'
        $env:NATIVEHTMLKIT_HOST_BINARY = $a; $env:UI4ME_HOST_BINARY = $b
        Get-NativeHTMLKitHostPath | Should -Be ([IO.Path]::GetFullPath($a))
    }
    It 'verifies a bundled host against HOST-MANIFEST.json and fails closed on mismatch' {
        $copy = Join-Path $TestDrive 'staged/NativeHTMLKit'
        Copy-Item -LiteralPath (Split-Path -Parent $script:ModuleManifest) -Destination $copy -Recurse
        $rid = if ($script:TestIsWindows) { 'win-x64' } else { 'linux-x64' }
        $name = if ($script:TestIsWindows) { 'nativehtmlkit-host.exe' } else { 'nativehtmlkit-host' }
        $hostFile = Join-Path $copy "runtimes/$rid/$name"
        [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $hostFile))
        [IO.File]::WriteAllBytes($hostFile, [byte[]](1..64))
        $good = (Get-FileHash -LiteralPath $hostFile -Algorithm SHA256).Hash.ToLowerInvariant()
        $probe = {
            param($Psd1, $Sha, $Rid)
            $manifest = @{ schema_version = 1; hosts = @{ $Rid = @{ sha256 = $Sha } } } | ConvertTo-Json -Depth 4
            [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $Psd1) 'HOST-MANIFEST.json'), $manifest)
            $shell = (Get-Process -Id $PID).Path
            $cmd = "Remove-Item Env:NATIVEHTMLKIT_HOST_BINARY, Env:UI4ME_HOST_BINARY -ErrorAction SilentlyContinue; Import-Module '$Psd1'; try { Get-NativeHTMLKitHostPath } catch { 'ERROR: ' + `$_.Exception.Message }"
            & $shell -NoProfile -NonInteractive -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd)))
        }
        $psd1 = Join-Path $copy 'NativeHTMLKit.psd1'
        (& $probe $psd1 $good $rid) | Should -Be ([IO.Path]::GetFullPath($hostFile))
        (& $probe $psd1 ('0' * 64) $rid) | Should -Match '^ERROR: The bundled .* does not match HOST-MANIFEST.json'
        (& $probe $psd1 'not-a-hash' $rid) | Should -Match '^ERROR: HOST-MANIFEST.json has no SHA-256'
    }
    It 'honors UI4ME_HOST_BINARY and reports a missing override' {
        $fake = Join-Path $TestDrive 'host-bin'
        Set-Content -LiteralPath $fake -Value 'x'
        $env:UI4ME_HOST_BINARY = $fake
        Get-NativeHTMLKitHostPath | Should -Be ([IO.Path]::GetFullPath($fake))
        $env:UI4ME_HOST_BINARY = Join-Path $TestDrive 'missing'
        { Get-NativeHTMLKitHostPath } | Should -Throw
    }
}
