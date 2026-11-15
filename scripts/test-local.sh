#!/usr/bin/env bash
# PowerShell 7 on Linux: runs the Pester suites (arguments are passed to scripts/test-local.ps1).
set -euo pipefail
cd "$(dirname "$0")/.."
command -v pwsh >/dev/null || { echo 'BLOCKED: PowerShell 7 (pwsh) is not installed' >&2; exit 2; }
exec pwsh -NoLogo -NoProfile -File scripts/test-local.ps1 "$@"
