#!/usr/bin/env python3
"""Stage a local NativeHTMLKit PowerShell module package from pinned, prebuilt Core hosts.

No download, compilation or publication. Each host is given by path and its expected SHA-256
and fails closed on any mismatch. When the host sits in a Core release directory (next to
release-manifest.json) its LICENSE, THIRD_PARTY_NOTICES.md and licenses/ are bundled and the
release manifest's host_sha256 must agree; without them packaging fails unless
--allow-missing-core-licenses is given (development only, marked in the manifest).

  python3 scripts/package-local.py --out dist/linux \
      --host linux-x64=/path/to/nativehtmlkit-core-v1.0.3-linux-x64/nativehtmlkit-host \
      --sha256 linux-x64=742d10e3...

Repeat --host/--sha256 for win-x64 to build one multi-runtime package. Output (a new or empty
directory): NativeHTMLKit/ (the staged module), NativeHTMLKit-<version>-<runtimes>.zip and
SHA256SUMS. The module carries HOST-MANIFEST.json (host hashes, Core and protocol versions,
SDK source tree hash) and SHA256SUMS for every packaged file. Packaging is not qualification.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import platform
import shutil
import stat
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNTIMES = {
    "linux-x64": {"name": "nativehtmlkit-host", "magic": b"\x7fELF"},
    "win-x64": {"name": "nativehtmlkit-host.exe", "magic": b"MZ"},
}
SOURCE_EXCLUDES = {"dist", "verification", ".git", "__pycache__", ".venv"}
# Documentation does not change behaviour: excluded so docs written after a qualification run
# do not invalidate the recorded tree hash (scripts/qualify.ps1 uses the same rule).
SOURCE_EXCLUDED_FILES = {"README.md", "docs/QUALIFICATION.md"}
ZIP_TIME = (2026, 1, 1, 0, 0, 0)


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def machine_ok(path: Path, rid: str) -> bool:
    data = path.read_bytes()[:4096]
    if rid == "linux-x64":
        return data[:4] == b"\x7fELF" and data[4] == 2 and int.from_bytes(data[18:20], "little") == 0x3E
    if data[:2] != b"MZ":
        return False
    pe = int.from_bytes(data[0x3C:0x40], "little")
    return data[pe:pe + 4] == b"PE\0\0" and int.from_bytes(data[pe + 4:pe + 6], "little") == 0x8664


def source_tree() -> dict:
    """SHA-256 over the sorted (path, file SHA-256) list of the SDK source checkout."""
    files = []
    for path in sorted(ROOT.rglob("*"), key=lambda p: p.relative_to(ROOT).as_posix()):
        rel = path.relative_to(ROOT)
        if path.is_dir() or any(part in SOURCE_EXCLUDES for part in rel.parts) or rel.as_posix() in SOURCE_EXCLUDED_FILES:
            continue
        if rel.parts[:2] == ("NativeHTMLKit", "runtimes") and path.name != "README.md":
            continue
        files.append((rel.as_posix(), sha256(path)))
    files.sort()   # ordinal order of POSIX relative paths (scripts/qualify.ps1 computes the same)
    digest = hashlib.sha256("".join(f"{p}\0{h}\n" for p, h in files).encode()).hexdigest()
    return {"sha256": digest, "files": len(files), "method": "sha256 of sorted 'path\\0sha256\\n' lines, excluding dist/, verification/, bundled hosts, README.md and docs/QUALIFICATION.md"}


def module_version() -> str:
    text = (ROOT / "NativeHTMLKit" / "NativeHTMLKit.psd1").read_text(encoding="utf-8")
    match = re.search(r"ModuleVersion\s*=\s*'([^']+)'", text)
    if not match:
        raise SystemExit("ModuleVersion not found in NativeHTMLKit.psd1")
    return match.group(1)


def parse_pairs(values: list[str], what: str) -> dict:
    pairs = {}
    for value in values:
        rid, sep, rest = value.partition("=")
        if not sep or rid not in RUNTIMES:
            raise SystemExit(f"{what} must be RID=VALUE with RID in {sorted(RUNTIMES)}: {value}")
        if rid in pairs:
            raise SystemExit(f"duplicate {what} for {rid}")
        pairs[rid] = rest
    return pairs


IDENTITY_FIELDS = ("source_commit", "source_tree", "source_dirty", "source_files_sha256")


def native_rid() -> str:
    machine = platform.machine().lower()
    if machine not in ("x86_64", "amd64"):
        return ""
    return "win-x64" if sys.platform.startswith("win") else ("linux-x64" if sys.platform.startswith("linux") else "")


def host_identity(rid: str, host: Path, supplied: str | None) -> tuple[dict, str]:
    """`nativehtmlkit-host --version --verbose` JSON: executed here when the host runs on this OS,
    otherwise taken from a file captured on the host's own platform (--identity RID=FILE)."""
    if supplied:
        return json.loads(Path(supplied).read_text(encoding="utf-8-sig")), "supplied"
    if rid != native_rid():
        raise SystemExit(f"{rid}: cannot run this host here to read its source identity; capture "
                         f"`nativehtmlkit-host --version --verbose` on {rid} and pass --identity {rid}=FILE")
    try:
        out = subprocess.run([str(host), "--version", "--verbose"], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise SystemExit(f"{rid}: cannot run the host to read its source identity: {error}")
    if out.returncode != 0:
        raise SystemExit(f"{rid}: `--version --verbose` failed (exit {out.returncode})")
    return json.loads(out.stdout.strip().splitlines()[-1]), "executed"


def verify_host(rid: str, host: Path, expected: str, allow_missing_licenses: bool, allow_dirty: bool = False, identity: str | None = None) -> dict:
    if not re.fullmatch(r"[0-9a-fA-F]{64}", expected or ""):
        raise SystemExit(f"{rid}: expected SHA-256 must be 64 hex digits")
    if not host.is_file():
        raise SystemExit(f"{rid}: host not found: {host}")
    actual = sha256(host)
    if actual != expected.lower():
        raise SystemExit(f"{rid}: SHA-256 mismatch for {host}: expected {expected.lower()}, got {actual}")
    if not machine_ok(host, rid):
        raise SystemExit(f"{rid}: {host} is not an x86-64 {'ELF' if rid == 'linux-x64' else 'PE'} executable")
    info = {"name": RUNTIMES[rid]["name"], "sha256": actual, "size": host.stat().st_size, "core_release": None, "licenses": []}
    release = host.parent / "release-manifest.json"
    if release.is_file():
        manifest = json.loads(release.read_text(encoding="utf-8"))
        if manifest.get("host_sha256", "").lower() != actual:
            raise SystemExit(f"{rid}: {release} names host_sha256 {manifest.get('host_sha256')}, not {actual}")
        if manifest.get("protocol_version") != 1:
            raise SystemExit(f"{rid}: Core release protocol_version is {manifest.get('protocol_version')}, this SDK speaks 1")
        if manifest.get("source_dirty") is not False and not allow_dirty:
            raise SystemExit(f"{rid}: the Core release was built from a dirty source tree (source_dirty={manifest.get('source_dirty')}); "
                             "pass --allow-dirty-core to build a development package from it")
        info["dirty_core"] = manifest.get("source_dirty") is not False
        embedded = manifest.get("host_embedded_source")
        if embedded is not None:
            # Core >= 1.0.3: the binary reports the source it was built from; it must agree with the
            # release manifest (and the manifest's own top-level source fields).
            ident, how = host_identity(rid, host, identity)
            for key in IDENTITY_FIELDS:
                if ident.get(key) != embedded.get(key):
                    raise SystemExit(f"{rid}: host identity {key}={ident.get(key)!r} differs from the release manifest ({embedded.get(key)!r})")
            if ident.get("version") != manifest.get("version"):
                raise SystemExit(f"{rid}: host reports version {ident.get('version')!r}, release manifest says {manifest.get('version')!r}")
            for key in ("source_commit", "source_tree", "source_dirty"):
                if key in manifest and manifest[key] != ident.get(key):
                    raise SystemExit(f"{rid}: host identity {key} differs from the release manifest's {key}")
            info["host_identity"] = {**{k: ident.get(k) for k in ("name", "version", "source_identity", *IDENTITY_FIELDS)}, "obtained_by": how}
        info["core_release"] = {k: manifest.get(k) for k in ("component", "version", "platform", "build_target", "protocol_version",
                                                             "protocol_status", "source_commit", "source_tree", "source_dirty", "host_reproducible")}
        notices = [p for p in (host.parent / "LICENSE", host.parent / "THIRD_PARTY_NOTICES.md") if p.is_file()]
        if (host.parent / "licenses").is_dir():
            notices += sorted(p for p in (host.parent / "licenses").iterdir() if p.is_file())
        info["license_sources"] = notices
    if not info.get("license_sources"):
        if not allow_missing_licenses:
            raise SystemExit(f"{rid}: no Core release licences next to {host} (LICENSE, THIRD_PARTY_NOTICES.md, licenses/); "
                             "pass a host from a Core release directory or --allow-missing-core-licenses for a development package")
        info["license_sources"] = []
        info["licenses_missing"] = True
    return info


def stage(hosts: dict, shas: dict, out: Path, allow_missing_licenses: bool, allow_dirty: bool = False, identities: dict | None = None) -> dict:
    if set(hosts) != set(shas):
        raise SystemExit("every --host needs a matching --sha256 and vice versa")
    if not hosts:
        raise SystemExit("at least one --host RID=PATH is required")
    if out.exists() and any(out.iterdir()):
        raise SystemExit(f"output directory must be new or empty: {out}")
    identities = identities or {}
    unknown = set(identities) - set(hosts)
    if unknown:
        raise SystemExit(f"--identity given for runtimes without --host: {sorted(unknown)}")
    infos = {rid: verify_host(rid, Path(hosts[rid]), shas[rid], allow_missing_licenses, allow_dirty, identities.get(rid)) for rid in sorted(hosts)}
    versions = {i["core_release"]["version"] for i in infos.values() if i["core_release"]}
    if len(versions) > 1:
        raise SystemExit(f"hosts come from different Core versions: {sorted(versions)}")
    sources = {(i["host_identity"]["source_commit"], i["host_identity"]["source_tree"]) for i in infos.values() if i.get("host_identity")}
    if len(sources) > 1 and not allow_dirty:
        raise SystemExit(f"hosts were built from different Core sources {sorted(sources)}; a release package needs one source "
                         "(--allow-dirty-core builds a development package)")
    version = module_version()
    out.mkdir(parents=True, exist_ok=True)
    dest = out / "NativeHTMLKit"
    shutil.copytree(ROOT / "NativeHTMLKit", dest, ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "nativehtmlkit-host", "nativehtmlkit-host.exe", "HOST-MANIFEST.json", "SHA256SUMS"))
    for name in ("LICENSE", "README.md"):
        shutil.copy2(ROOT / name, dest / name)
    manifest_hosts = {}
    for rid, info in infos.items():
        target = dest / "runtimes" / rid / info["name"]
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(hosts[rid], target)
        target.chmod(0o755 if rid == "linux-x64" else 0o644)
        if sha256(target) != info["sha256"]:
            raise SystemExit(f"{rid}: copied host changed")
        licdir = dest / "licenses" / "core" / rid
        for src in info.pop("license_sources"):
            licdir.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, licdir / src.name)
            info["licenses"].append(f"licenses/core/{rid}/{src.name}")
        manifest_hosts[rid] = info
    core_version = versions.pop() if versions else None
    host_manifest = {
        "schema_version": 1, "module": "NativeHTMLKit", "module_version": version, "protocol_version": 1,
        "core_version": core_version, "hosts": manifest_hosts, "sdk_source_tree": source_tree(),
        "qualification": "NOT RECORDED HERE: packaging verifies hashes only; see the qualification evidence for this host SHA-256",
        # A host from a dirty Core tree or without licences can only make a development package.
        "development_package": any(i.get("licenses_missing") or i.get("dirty_core") for i in manifest_hosts.values()),
    }
    (dest / "HOST-MANIFEST.json").write_text(json.dumps(host_manifest, indent=2) + "\n", encoding="utf-8")
    files = sorted(p for p in dest.rglob("*") if p.is_file())
    (dest / "SHA256SUMS").write_text("".join(f"{sha256(p)}  {p.relative_to(dest).as_posix()}\n" for p in files), encoding="utf-8")
    artifact = out / f"NativeHTMLKit-{version}-{'+'.join(sorted(hosts))}.zip"
    with zipfile.ZipFile(artifact, "w", zipfile.ZIP_DEFLATED) as z:
        for path in sorted(p for p in dest.rglob("*") if p.is_file()):
            entry = zipfile.ZipInfo(path.relative_to(out).as_posix(), ZIP_TIME)
            entry.compress_type = zipfile.ZIP_DEFLATED
            mode = 0o755 if (path.name == "nativehtmlkit-host" and path.parent.name == "linux-x64") else 0o644
            entry.external_attr = (stat.S_IFREG | mode) << 16
            z.writestr(entry, path.read_bytes())
    with zipfile.ZipFile(artifact) as z:
        if z.testzip() is not None:
            raise SystemExit("ZIP self-test failed")
    (out / "SHA256SUMS").write_text(f"{sha256(artifact)}  {artifact.name}\n", encoding="utf-8")
    result = {"artifact": str(artifact), "sha256": sha256(artifact), "module_version": version, "core_version": core_version,
              "hosts": {rid: i["sha256"] for rid, i in manifest_hosts.items()}, "sdk_source_tree": host_manifest["sdk_source_tree"]["sha256"],
              "development_package": host_manifest["development_package"],
              "packaged_utc": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()}
    (out / "PACKAGE.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return result


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", action="append", default=[], metavar="RID=PATH", help="prebuilt Core host (linux-x64 / win-x64)")
    ap.add_argument("--sha256", action="append", default=[], metavar="RID=HEX", help="expected SHA-256 of that host")
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--allow-missing-core-licenses", action="store_true")
    ap.add_argument("--allow-dirty-core", action="store_true", help="accept a Core release built from a dirty tree (marks the package development_package)")
    ap.add_argument("--identity", action="append", default=[], metavar="RID=FILE", help="`nativehtmlkit-host --version --verbose` output captured on that runtime (for a host that cannot run here)")
    a = ap.parse_args(argv)
    print(json.dumps(stage(parse_pairs(a.host, "--host"), parse_pairs(a.sha256, "--sha256"), a.out, a.allow_missing_core_licenses, a.allow_dirty_core, parse_pairs(a.identity, "--identity")), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
