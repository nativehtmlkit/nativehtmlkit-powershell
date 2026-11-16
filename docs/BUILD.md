# Verification and Gallery publication

```powershell
Import-Module ./NativeHTMLKit/NativeHTMLKit.psd1 -Force
Test-ModuleManifest ./NativeHTMLKit/NativeHTMLKit.psd1
Invoke-Pester ./tests
```

Run the repository's `scripts/qualify.ps1` and native journey tests on Linux PowerShell 7 and both Windows editions with exact Core host binaries. Package from the locally qualified binaries; validate the SHA256SUMS and the manifest, and attach the build to the relevant GitHub Release. The existing Gallery workflow only uploads prebuilt release assets; it does not build/test them on GitHub. Requires a new patch version to update the Gallery description or release notes.

## Documentation and examples

```powershell
# Reference completeness, tutorial excerpts and links (no host needed):
pwsh -NoProfile -File scripts/test-local.ps1 -Path tests/Documentation.Tests.ps1
# Every example, the scaffold and the tutorial checkpoint against the real host, headless:
pwsh -NoProfile -File scripts/test-local.ps1 -Path tests/Examples.Tests.ps1 -HostBinary <host> -RequireHost
```

Run the example suite with both `pwsh` and `powershell.exe` on Windows. See [examples/README.md](../examples/README.md).
