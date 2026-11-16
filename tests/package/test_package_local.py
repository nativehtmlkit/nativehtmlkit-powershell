"""Tests for scripts/package-local.py (packaging tool only; run: python3 -m unittest discover tests/package)."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import stat
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("package_local", ROOT / "scripts" / "package-local.py")
pkg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pkg)


def fake_elf() -> bytes:
    header = bytearray(64)
    header[:4] = b"\x7fELF"; header[4] = 2; header[18:20] = (0x3E).to_bytes(2, "little")
    return bytes(header) + b"host" * 100


def fake_pe() -> bytes:
    data = bytearray(512)
    data[:2] = b"MZ"; data[0x3C:0x40] = (0x80).to_bytes(4, "little")
    data[0x80:0x84] = b"PE\0\0"; data[0x84:0x86] = (0x8664).to_bytes(2, "little")
    return bytes(data)


class PackageLocal(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.rel = self.tmp / "core-release-linux"
        (self.rel / "licenses").mkdir(parents=True)
        self.host = self.rel / "nativehtmlkit-host"
        self.host.write_bytes(fake_elf())
        self.sha = hashlib.sha256(self.host.read_bytes()).hexdigest()
        (self.rel / "LICENSE").write_text("MIT core")
        (self.rel / "THIRD_PARTY_NOTICES.md").write_text("notices")
        (self.rel / "licenses" / "MPL-2.0.txt").write_text("mpl")
        (self.rel / "release-manifest.json").write_text(json.dumps({"component": "nativehtmlkit-core", "version": "1.0.2", "host_sha256": self.sha, "protocol_version": 1, "source_dirty": False}))
        self.ident = {"name": "nativehtmlkit-host", "version": "1.0.3", "source_identity": "git", "source_commit": "c" * 40, "source_tree": "t" * 40, "source_dirty": False, "source_files_sha256": None}
        self.identity_file = self.tmp / "identity.json"; self.identity_file.write_text(json.dumps(self.ident))

    def stage(self, out="out", **kw):
        hosts = kw.pop("hosts", {"linux-x64": str(self.host)})
        shas = kw.pop("shas", {"linux-x64": self.sha})
        return pkg.stage(hosts, shas, self.tmp / out, kw.pop("allow", False))

    def test_stages_module_with_manifest_licences_and_checksums(self):
        r = self.stage()
        dest = self.tmp / "out" / "NativeHTMLKit"
        manifest = json.loads((dest / "HOST-MANIFEST.json").read_text())
        self.assertEqual(manifest["hosts"]["linux-x64"]["sha256"], self.sha)
        self.assertEqual(manifest["core_version"], "1.0.2")
        self.assertEqual(manifest["protocol_version"], 1)
        self.assertRegex(manifest["sdk_source_tree"]["sha256"], r"^[0-9a-f]{64}$")
        self.assertFalse(manifest["development_package"])
        for rel in ("licenses/core/linux-x64/LICENSE", "licenses/core/linux-x64/THIRD_PARTY_NOTICES.md", "licenses/core/linux-x64/MPL-2.0.txt", "LICENSE"):
            self.assertTrue((dest / rel).is_file(), rel)
        sums = (dest / "SHA256SUMS").read_text().splitlines()
        listed = {line.split("  ", 1)[1]: line.split("  ", 1)[0] for line in sums}
        for path in dest.rglob("*"):
            if path.is_file() and path.name != "SHA256SUMS":
                self.assertEqual(listed[path.relative_to(dest).as_posix()], hashlib.sha256(path.read_bytes()).hexdigest())
        with zipfile.ZipFile(r["artifact"]) as z:
            info = z.getinfo("NativeHTMLKit/runtimes/linux-x64/nativehtmlkit-host")
            self.assertTrue((info.external_attr >> 16) & stat.S_IXUSR)
            self.assertIn("NativeHTMLKit/NativeHTMLKit.psd1", z.namelist())
            self.assertFalse(any(n.startswith("NativeHTMLKit/tests") for n in z.namelist()))
        outer = (self.tmp / "out" / "SHA256SUMS").read_text().split()
        self.assertEqual(outer[0], r["sha256"])

    def test_zip_is_byte_reproducible(self):
        a = self.stage("a"); b = self.stage("b")
        self.assertEqual(a["sha256"], b["sha256"])   # no timestamp inside the archive

    def test_dirty_core_needs_flag_and_marks_development_package(self):
        (self.rel / "release-manifest.json").write_text(json.dumps({"version": "1.0.2", "host_sha256": self.sha, "protocol_version": 1, "source_dirty": True}))
        with self.assertRaisesRegex(SystemExit, "dirty source tree"):
            self.stage("d1")
        r = pkg.stage({"linux-x64": str(self.host)}, {"linux-x64": self.sha}, self.tmp / "d2", False, True)
        self.assertTrue(r["development_package"])
        manifest = json.loads((self.tmp / "d2" / "NativeHTMLKit" / "HOST-MANIFEST.json").read_text())
        self.assertTrue(manifest["development_package"])

    def manifest_103(self, **ident_overrides):
        embedded = {k: self.ident[k] for k in ("source_identity", "source_commit", "source_tree", "source_dirty", "source_files_sha256")}
        embedded.update(ident_overrides)
        (self.rel / "release-manifest.json").write_text(json.dumps({"version": "1.0.3", "host_sha256": self.sha, "protocol_version": 1,
            "source_dirty": False, "source_commit": self.ident["source_commit"], "source_tree": self.ident["source_tree"], "host_embedded_source": embedded}))

    def test_records_and_cross_checks_the_host_source_identity(self):
        self.manifest_103()
        pkg.stage({"linux-x64": str(self.host)}, {"linux-x64": self.sha}, self.tmp / "i1", False, False, {"linux-x64": str(self.identity_file)})
        m = json.loads((self.tmp / "i1" / "NativeHTMLKit" / "HOST-MANIFEST.json").read_text())
        self.assertEqual(m["hosts"]["linux-x64"]["host_identity"]["source_commit"], "c" * 40)
        self.assertEqual(m["hosts"]["linux-x64"]["host_identity"]["obtained_by"], "supplied")

    def test_release_package_needs_hosts_from_one_source(self):
        self.manifest_103()
        win = self.tmp / "core-release-win"; (win / "licenses").mkdir(parents=True)
        exe = win / "nativehtmlkit-host.exe"; exe.write_bytes(fake_pe()); wsha = hashlib.sha256(exe.read_bytes()).hexdigest()
        (win / "LICENSE").write_text("MIT")
        other = dict(self.ident, source_tree="u" * 40)
        (win / "release-manifest.json").write_text(json.dumps({"version": "1.0.3", "host_sha256": wsha, "protocol_version": 1, "source_dirty": False,
            "source_commit": other["source_commit"], "source_tree": other["source_tree"],
            "host_embedded_source": {k: other[k] for k in ("source_identity", "source_commit", "source_tree", "source_dirty", "source_files_sha256")}}))
        wid = self.tmp / "win-identity.json"; wid.write_text(json.dumps(other))
        args = ({"linux-x64": str(self.host), "win-x64": str(exe)}, {"linux-x64": self.sha, "win-x64": wsha})
        with self.assertRaisesRegex(SystemExit, "different Core sources"):
            pkg.stage(*args, self.tmp / "s1", False, False, {"linux-x64": str(self.identity_file), "win-x64": str(wid)})

    def test_fails_when_host_identity_disagrees_or_cannot_be_read(self):
        self.manifest_103(source_commit="d" * 40)
        with self.assertRaisesRegex(SystemExit, "source_commit"):
            pkg.stage({"linux-x64": str(self.host)}, {"linux-x64": self.sha}, self.tmp / "i2", False, False, {"linux-x64": str(self.identity_file)})
        self.manifest_103()
        with self.assertRaisesRegex(SystemExit, "version|cannot run|failed|Exec format|exec format|OSError|No such"):
            pkg.stage({"linux-x64": str(self.host)}, {"linux-x64": self.sha}, self.tmp / "i3", False, False, {})

    def test_fails_closed_on_sha_mismatch(self):
        with self.assertRaisesRegex(SystemExit, "SHA-256 mismatch"):
            self.stage(shas={"linux-x64": "0" * 64})
        self.assertFalse((self.tmp / "out").exists())

    def test_rejects_release_manifest_disagreement(self):
        (self.rel / "release-manifest.json").write_text(json.dumps({"host_sha256": "1" * 64, "protocol_version": 1, "source_dirty": False}))
        with self.assertRaisesRegex(SystemExit, "names host_sha256"):
            self.stage()

    def test_rejects_wrong_architecture_or_format(self):
        self.host.write_bytes(fake_pe())
        sha = hashlib.sha256(self.host.read_bytes()).hexdigest()
        (self.rel / "release-manifest.json").write_text(json.dumps({"host_sha256": sha, "protocol_version": 1, "source_dirty": False}))
        with self.assertRaisesRegex(SystemExit, "not an x86-64 ELF"):
            self.stage(shas={"linux-x64": sha})

    def test_requires_licences_unless_development(self):
        bare = self.tmp / "bare"; bare.mkdir()
        host = bare / "nativehtmlkit-host"; host.write_bytes(fake_elf())
        with self.assertRaisesRegex(SystemExit, "no Core release licences"):
            self.stage(hosts={"linux-x64": str(host)})
        r = self.stage("dev", hosts={"linux-x64": str(host)}, allow=True)
        self.assertTrue(r["development_package"])

    def test_multi_runtime_and_refuses_nonempty_output(self):
        win = self.tmp / "core-release-win"; (win / "licenses").mkdir(parents=True)
        exe = win / "nativehtmlkit-host.exe"; exe.write_bytes(fake_pe())
        wsha = hashlib.sha256(exe.read_bytes()).hexdigest()
        (win / "LICENSE").write_text("MIT")
        (win / "release-manifest.json").write_text(json.dumps({"version": "1.0.2", "host_sha256": wsha, "protocol_version": 1, "source_dirty": False}))
        r = self.stage(hosts={"linux-x64": str(self.host), "win-x64": str(exe)}, shas={"linux-x64": self.sha, "win-x64": wsha})
        self.assertTrue(r["artifact"].endswith("NativeHTMLKit-0.1.2-linux-x64+win-x64.zip"))
        with self.assertRaisesRegex(SystemExit, "new or empty"):
            self.stage()


if __name__ == "__main__":
    unittest.main()
