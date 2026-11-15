# NativeHTMLKit PowerShell SDK — agent policy

1. Read `README.md`, `docs/QUALIFICATION.md`, and the published Core v1 protocol. The SDK must remain independently cloneable and buildable.
2. Canonical module is `NativeHTMLKit`, canonical commands `Verb-NativeHTMLKitNoun`, exported aliases `Verb-NHKNoun`; the host transport retains v1 `UI4ME_*` names **internally**.
3. No Python runtime, Rust compilation or Core source dependency for SDK consumers. Package exactly qualified Core binary artifacts with hashes and licenses.
4. Keep all user scriptblocks on the owning PowerShell runspace. Never execute application code on a transport reader; background tasks are runspaces and return through the pump. Preserve host close/quit handling under nested RPC.
5. Preserve working legacy semantics while upgrading diagnostics, error propagation and concurrency. Task completions run on the owning runspace, never inside another callback and never after `Close-NativeHTMLKit`; cancelled workers keep their slot until they really end and are never disposed while running. `tests/Tasks.Tests.ps1` pins this; run it on PS 5.1 and 7.
6. Diagnostics records are bounded, redacted and opt-in for detail. Do not log tokens or values. Errors must preserve Core codes, operation and cause; failed callbacks must be discoverable.
7. Run Pester and native acceptance on Linux Wayland, Windows Server 2022 PowerShell 7 and Windows PowerShell 5.1: `scripts/qualify.ps1` is the one command per platform/edition (`-Gui` only inside a real desktop session). Record evidence; blocked is not pass. Never mark a skipped real-host suite as passed: qualification runs use `-RequireHost`.
8. Keep code, UI widgets, and future plugin architecture separate. Core defects are reported in Project bug registry with reproducer.
9. No GitHub Actions, gallery publish or remote release unless user explicitly requests. Test/package locally.
10. From a project workspace read `../../AGENTS.md`; standalone clients use their own rules and published contract.
11. Packages come only from `scripts/package-local.py` with hosts pinned by SHA-256 (fails closed); a packaged module verifies its bundled host against `HOST-MANIFEST.json` before use. Check packages with `scripts/smoke-installed.ps1`.
