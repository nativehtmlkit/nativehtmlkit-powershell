# PowerShell Gallery-style install test of a packaged NativeHTMLKit module, without the Gallery:
# the module folder from the release ZIP is published to a LOCAL file repository as a .nupkg (as the
# publish workflow does with Publish-PSResource), then installed BY NAME from that repository and smoke-
# tested (scripts/smoke-installed.ps1 -ModulesPath). NuGet packages do not keep the Linux host's
# executable bit; the module must restore it at launch.
#
#   PowerShell 7 (PSResourceGet):  pwsh -File scripts/test-gallery-install.ps1 -Package ZIP -ExpectedHostSha256 HEX [-Repository DIR] [-Out DIR] [-Gui]
#   Windows PowerShell 5.1:        powershell.exe -File scripts\test-gallery-install.ps1 -Repository DIR -ExpectedHostSha256 HEX [-Out DIR]
#     (5.1 uses PowerShellGet's Install-Module from a repository DIR that already holds the .nupkg made on PS 7;
#      it installs for the current user and uninstalls again afterwards.)
# Exit 0 only if publishing, the package content checks, the install and the smoke all passed.
param(
    [string]$Package,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ExpectedHostSha256,
    [string]$Repository,
    [string]$Out,
    [switch]$Gui
)
$ErrorActionPreference = 'Stop'
$work = Join-Path ([IO.Path]::GetTempPath()) ('nhk-gallery-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null
if (-not $Out) { $Out = Join-Path $work 'evidence' }
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path -LiteralPath $Out).Path
if (-not $Repository) { $Repository = Join-Path $work 'repository' }
New-Item -ItemType Directory -Force -Path $Repository | Out-Null
$Repository = (Resolve-Path -LiteralPath $Repository).Path
$repoName = 'nhk-local-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$checks = New-Object System.Collections.ArrayList
function Check([string]$Name, [bool]$Ok, $Detail) { [void]$checks.Add([ordered]@{ name = $Name; status = $(if ($Ok) { 'PASS' } else { 'FAIL' }); detail = $Detail }) }
$smokeExit = $null
$modules = Join-Path $work 'Modules'
$desktop = $PSVersionTable.PSEdition -eq 'Desktop'
try {
    if ($Package) {
        # Publish (PowerShell 7 / PSResourceGet), as .github/workflows/psgallery_publish.yml does with the release ZIP.
        if ($desktop) { throw '-Package (publishing) needs PowerShell 7 with PSResourceGet; on 5.1 pass -Repository with the .nupkg' }
        Import-Module Microsoft.PowerShell.PSResourceGet -ErrorAction Stop
        $stage = Join-Path $work 'stage'
        Expand-Archive -LiteralPath $Package -DestinationPath $stage
        $manifest = Test-ModuleManifest -Path (Join-Path $stage 'NativeHTMLKit/NativeHTMLKit.psd1')
        Check 'module manifest passes Test-ModuleManifest' ($null -ne $manifest) @{ version = $manifest.Version.ToString() }
        Register-PSResourceRepository -Name $repoName -Uri $Repository -Trusted
        Publish-PSResource -Path (Join-Path $stage 'NativeHTMLKit') -Repository $repoName
        $nupkg = @(Get-ChildItem -LiteralPath $Repository -Filter "NativeHTMLKit.$($manifest.Version).nupkg")
        Check 'Publish-PSResource produced the .nupkg' ($nupkg.Count -eq 1) @{ files = @($nupkg | ForEach-Object Name) }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($nupkg[0].FullName)
        try {
            $entries = @($zip.Entries | ForEach-Object FullName)
            $hosts = @($entries | Where-Object { $_ -match '^runtimes/(linux-x64/nativehtmlkit-host|win-x64/nativehtmlkit-host\.exe)$' })
            $odd = @($entries | Where-Object { $_ -match '(^|/)\.|\.(nupkg|ps1xml\.bak)$' -and $_ -notmatch '^(_rels|package)/|^\[Content_Types\]\.xml$' })
            $expectedHosts = @((Get-Content -Raw -LiteralPath (Join-Path $stage 'NativeHTMLKit/HOST-MANIFEST.json') | ConvertFrom-Json).hosts.PSObject.Properties).Count
            Check 'the .nupkg carries the module, every bundled host, HOST-MANIFEST.json, SHA256SUMS and the licences' ($hosts.Count -eq $expectedHosts -and $expectedHosts -ge 1 -and $entries -contains 'HOST-MANIFEST.json' -and $entries -contains 'SHA256SUMS' -and @($entries | Where-Object { $_ -like 'licenses/core/*' }).Count -ge 2) @{ entries = $entries.Count }
            Check 'the .nupkg holds no hidden or nested-package files the Gallery would reject' ($odd.Count -eq 0) @{ suspicious = $odd }
        } finally { $zip.Dispose() }
        Check '.nupkg size below the Gallery limit (250 MB)' ($nupkg[0].Length -lt 250MB) @{ bytes = $nupkg[0].Length }
        # Install BY NAME from the repository, as `Install-PSResource NativeHTMLKit` does from the Gallery.
        New-Item -ItemType Directory -Force -Path $modules | Out-Null
        Save-PSResource -Name NativeHTMLKit -Repository $repoName -Path $modules -TrustRepository
        Check 'Save-PSResource -Name NativeHTMLKit installed the module from the repository' (@(Get-ChildItem -LiteralPath (Join-Path $modules 'NativeHTMLKit') -Recurse -Filter NativeHTMLKit.psd1).Count -eq 1) $null
        $installPath = $modules
    } else {
        # Windows PowerShell 5.1: PowerShellGet's Install-Module from the local repository (current user), uninstalled afterwards.
        if (-not $desktop) { throw 'Without -Package this script installs with PowerShellGet on Windows PowerShell 5.1' }
        if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue | Where-Object { $_.Version -ge [version]'2.8.5.201' })) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
        }
        Register-PSRepository -Name $repoName -SourceLocation $Repository -InstallationPolicy Trusted
        Install-Module -Name NativeHTMLKit -Repository $repoName -Scope CurrentUser -Force -AllowClobber
        $installed = Get-InstalledModule -Name NativeHTMLKit -ErrorAction Stop
        Check 'Install-Module -Name NativeHTMLKit installed the module from the repository (PowerShellGet)' ($null -ne $installed) @{ version = $installed.Version.ToString(); location = $installed.InstalledLocation }
        $installPath = Split-Path -Parent (Split-Path -Parent $installed.InstalledLocation)
    }
    $smokeArgs = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'smoke-installed.ps1'), '-ModulesPath', $installPath, '-ExpectedHostSha256', $ExpectedHostSha256, '-Out', (Join-Path $Out 'smoke'))
    if ($Gui) { $smokeArgs += '-Gui' }
    $shell = (Get-Process -Id $PID).Path
    & $shell @smokeArgs | Out-Null
    $smokeExit = $LASTEXITCODE
    Check 'smoke test of the installed module (by name, bundled host, protocol, window)' ($smokeExit -eq 0) @{ exit_code = $smokeExit; summary = 'smoke/smoke-summary.json' }
} catch {
    Check 'gallery-style install completed' $false @{ error = $_.Exception.Message }
} finally {
    if ($desktop) {
        try { Uninstall-Module -Name NativeHTMLKit -AllVersions -Force -ErrorAction SilentlyContinue } catch { $null = $_ }
        try { Unregister-PSRepository -Name $repoName -ErrorAction SilentlyContinue } catch { $null = $_ }
    } else {
        try { Unregister-PSResourceRepository -Name $repoName -ErrorAction SilentlyContinue } catch { $null = $_ }
    }
}
$summary = [ordered]@{ edition = [string]$PSVersionTable.PSEdition; ps_version = $PSVersionTable.PSVersion.ToString(); repository = $Repository
    checks = $checks; passed = @($checks | Where-Object { $_.status -eq 'PASS' }).Count; failed = @($checks | Where-Object { $_.status -ne 'PASS' }).Count }
$json = ConvertTo-Json -InputObject $summary -Depth 8
[IO.File]::WriteAllText((Join-Path $Out 'gallery-summary.json'), $json)
$json
exit $(if ($summary.failed -eq 0) { 0 } else { 1 })
