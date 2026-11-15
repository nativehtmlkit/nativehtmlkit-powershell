# PowerShell SDK qualification

Gates (Project G0–G9 model) and how they are exercised:

| Gate | What | How |
|---|---|---|
| G0 | manifest, import, `Add-Type` compile (C# 5 + `NativeHTMLKit_NETFX` on 5.1), every exported function/alias, help, ASCII/BOM rules | `scripts/qualify.ps1` `import-compile-exports`; `tests/Unit.Tests.ps1` |
| G2 | framing, JSON codec, request/response correlation, typed errors, queue bounds | `tests/Transport.Tests.ps1` (local JSON-RPC peer `tests/MockHost.ps1`) |
| G3 | handshake, lifecycle, direct start, multi-window, stale handles, README example, diagnostics propagation, with the **real host headless** | `tests/DirectStart.Tests.ps1`, `tests/RealHost.Tests.ps1` |
| G4 | fault injection (malformed/oversized/truncated frames, unknown codes, dropped replies, peer/host killed, rapid open/close), task faults (ignored cancellation, throwing callbacks, capacity, close/quit races, nested RPC), diagnostics privacy (sentinel secrets), loss counters | `tests/Faults.Tests.ps1`, `tests/Tasks.Tests.ps1`, `tests/Diagnostics.Tests.ps1` |
| G6 | real desktop with real input: window, mouse (left/right/middle), keyboard, form submit, ordered callbacks under input, native save/open dialogs and cancellation, minimize/maximize, frameless drag and 8 resize edges, HTML chrome buttons, accessibility tree (AT-SPI / UI Automation), clipboard with another app, native close veto then allow, clean exit and no leftover processes | `tests/native/Qualify.ps1` driven by `tests/native/drive_linux.py` (KDE Plasma Wayland: KWin scripting, ydotool/uinput, AT-SPI, spectacle) or `tests/native/drive_windows.ps1` (interactive desktop: SendInput, UI Automation, Win32) |
| G8 | package with pinned host hashes, clean install by module name, bundled host SHA-256, protocol version, real window, no Rust | `scripts/package-local.py`, `tests/package/`, `scripts/smoke-installed.ps1` |

One command per platform and edition (fails closed on a host hash mismatch; writes `results.json` with PASS / FAIL / BLOCKED, command, platform, session, edition, source tree hash, host SHA-256, duration, exit code and log per gate):

```text
Linux (inside the KDE Wayland session user's environment; -Gui drives that session):
  pwsh -NoProfile -File scripts/qualify.ps1 -HostBinary HOST -HostSha256 HEX -Out DIR -Gui -Package ZIP -PackageHostSha256 HEX
Windows, inside the interactive desktop, once per edition:
  pwsh.exe       -NoProfile -File scripts\qualify.ps1 -HostBinary HOST.exe -HostSha256 HEX -Out DIR -Gui -Package ZIP -PackageHostSha256 HEX
  powershell.exe -NoProfile -File scripts\qualify.ps1 ...same...
```

Without `-Gui` the G6 gate is recorded as BLOCKED, never PASS. Headless and SSH-only runs are not GUI evidence. Pester 5.5–5.x must be on `PSModulePath` (Pester 6 is not supported by these suites).

## Executed runs — release 0.1.0 (2026-11-15)

Published as a GitHub prerelease: <https://github.com/nativehtmlkit/nativehtmlkit-powershell/releases/tag/v0.1.0> (tag `v0.1.0`
at source commit `5734a3a`). SDK source tree hash `1c36541cc1825caf4cfd3dbcbafc2d860a1187840ed8deeb968357f13a169639`
(README.md and this file are excluded from the hash). Core 1.0.2 hosts from Core commit `8a09875` (clean tree):
Linux `702adafcbfe3c969cb12d0de5d37546727ee13b147c8fc866c7afa18aa741d2a`, Windows `64d4502f27782bd17329ab6d560fc27b4e3d404b719ddd9bafc507d46d8638f4`.
Package `NativeHTMLKit-0.1.0-linux-x64+win-x64.zip` SHA-256 `8e1fe37f589e4f89f3b4381b2cd2f7fdd1eefae8ede91cc84a936b4dadcf397b`
(byte-reproducible, `development_package: false`). Evidence: Project `verification/2026-11-15-sdk/powershell/release/`.

| Runtime / session | Gates | Pester (all suites) | G6 real desktop (one-command run) | G8 installed package |
|---|---|---|---|---|
| PS 7.7.0, Debian 13 workstation (headless) | 11 PASS, 1 BLOCKED (G6: not a desktop) | 154/154 | BLOCKED | PASS; Docker clean room (PS 7.4.2, no network/Rust/Python) 10/10 |
| PS 7.7.0, linuxDEV KDE Plasma 6.6 Wayland | 13/13 PASS | 154/154 | PASS 29/29, clean teardown | PASS headless + GUI |
| PS 7.7.0, winDEV interactive RDP desktop | 13/13 PASS | 154/154 | PASS 29/29, clean teardown | PASS headless + GUI |
| Windows PowerShell 5.1.20348, same desktop | 13/13 PASS | 154/154 | PASS 29/29, clean teardown | PASS headless + GUI |

Not run: IME, `idle` and `bitmap-kill` modes. Core protocol v1 is `1.0-rc`. Release status: 0.1.0 prerelease, published only
via GitHub Releases (not the PowerShell Gallery).

## Superseded run — final2, after the independent final review (2026-11-15)

Superseded by the release run above (same SDK source tree; Core hosts then came from a dirty-tree Core build, so that package was a development package).

Hosts (Core 1.0.2, source tree `4f63398c…`, built from a **dirty** Core tree): Linux `702adafcbfe3c969cb12d0de5d37546727ee13b147c8fc866c7afa18aa741d2a`, Windows `64d4502f27782bd17329ab6d560fc27b4e3d404b719ddd9bafc507d46d8638f4`.
SDK source tree hash `1c36541cc1825caf4cfd3dbcbafc2d860a1187840ed8deeb968357f13a169639` (identical in all 51 results; README.md and this file are excluded from the hash).
Package `NativeHTMLKit-0.1.0-linux-x64+win-x64.zip` SHA-256 `8e8623623b7d0005697f680d838ac75e262cfee5260bf2c0ca402d9b84ac871d`, byte-reproducible, `development_package: true` (dirty Core hosts, built with `--allow-dirty-core`).
Evidence: Project `verification/2026-11-15-sdk/powershell/final2/` (`results.json`, logs, screenshots, mutation results, FR-PS-21/22 experiments); `final/` is superseded.

| Runtime / session | Gates | Pester (all suites incl. Review) | G6 real desktop (one-command run) | G8 installed package |
|---|---|---|---|---|
| PS 7.7.0, Debian 13 workstation (headless) | 11 PASS, 1 BLOCKED (G6: not a desktop) | 154/154 | BLOCKED | PASS; Docker clean room (PS 7.4.2, no network/Rust/Python) 10/10 |
| PS 7.7.0, linuxDEV KDE Plasma 6.6 Wayland | 13/13 PASS | 154/154 | PASS 29/29, clean teardown | PASS headless + GUI |
| PS 7.7.0, winDEV interactive RDP desktop | 13/13 PASS | 154/154 | PASS 29/29, clean teardown | PASS headless + GUI |
| Windows PowerShell 5.1.20348, same desktop | 13/13 PASS | 154/154 | PASS 29/29, clean teardown | PASS headless + GUI |

Mutation testing on this tree: 19/20 mutants killed (the survivor is an equivalent mutant). Not run: IME, `idle` and `bitmap-kill` modes.
**Release status: locally qualified development candidate (dirty Core hosts), not published.** Core protocol v1 remains a release candidate.

Local tests and builds only. No GitHub Actions, no Gallery or GitHub release without express approval.
