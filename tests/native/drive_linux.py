#!/usr/bin/env python3
"""Drive tests/native/Qualify.ps1 in a real KDE Plasma Wayland session.

Test tooling only; Python is not part of the PowerShell runtime. Real pointer and keyboard
events go through uinput (ydotool) and the compositor; window geometry and state come from
KWin scripting; accessibility from AT-SPI; screenshots from spectacle. Nothing is synthesised
inside the application. Screenshots are supporting evidence; every check is a behavioral
assertion made by Qualify.ps1 or by this driver.

usage: drive_linux.py --module PSD1 --host HOST --out DIR [--mode full|auto] [--pwsh PATH]
Exit 0 only if every check passed, the launcher exited 0, and no host/backend process or
systemd unit was left behind.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

LAB = Path.home() / "lab" / "bin"
KEYS = {"Tab": 15, "Enter": 28, "Escape": 1}
BUTTONS = {"left": "1", "middle": "2", "right": "3"}


def session_env() -> dict:
    uid = os.getuid()
    env = dict(os.environ)
    env.update(XDG_RUNTIME_DIR=f"/run/user/{uid}", WAYLAND_DISPLAY="wayland-0",
               DBUS_SESSION_BUS_ADDRESS=f"unix:path=/run/user/{uid}/bus", XDG_SESSION_TYPE="wayland",
               XDG_CURRENT_DESKTOP="KDE", YDOTOOL_SOCKET=f"/run/user/{uid}/.ydotool_socket",
               QT_QPA_PLATFORM="wayland")
    env.pop("DISPLAY", None)
    return env


ENV = session_env()


def run(*args, timeout=30, check=True):
    return subprocess.run([str(a) for a in args], env=ENV, capture_output=True, text=True, timeout=timeout, check=check)


def kwin(js: str, wait: float = 0.4) -> list[str]:
    tag = "NHKPS" + uuid.uuid4().hex[:8]
    path = Path(tempfile.gettempdir()) / f"kwin-{tag}.js"
    path.write_text(js.replace("OUT(", f"print('{tag} ' + "))
    since = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(time.time() - 1))
    number = run("qdbus6", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.loadScript", path, tag).stdout.strip()
    run("qdbus6", "org.kde.KWin", f"/Scripting/Script{number}", "org.kde.kwin.Script.run", check=False)
    time.sleep(wait)
    run("qdbus6", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.unloadScript", tag, check=False)
    path.unlink(missing_ok=True)
    out = run("journalctl", "--user", "-q", "--since", since, "-o", "cat", "--no-pager", check=False).stdout
    return [line.split(tag + " ", 1)[1] for line in out.splitlines() if tag + " " in line]


def windows() -> list[dict]:
    lines = kwin(r"""var ws = workspace.windowList(); var r = [];
for (var i = 0; i < ws.length; i++) { var w = ws[i]; if (!w.normalWindow && !w.dialog) continue;
 var area = workspace.clientArea(KWin.MaximizeArea, w);
 r.push({caption: w.caption, pid: w.pid, x: w.frameGeometry.x, y: w.frameGeometry.y, w: w.frameGeometry.width,
 h: w.frameGeometry.height, cx: w.clientGeometry.x, cy: w.clientGeometry.y, cw: w.clientGeometry.width,
 ch: w.clientGeometry.height, active: w.active, minimized: w.minimized, dialog: w.dialog,
 ax: area.x, ay: area.y, aw: area.width, ah: area.height}); }
OUT(JSON.stringify(r));""")
    return json.loads(lines[-1]) if lines else []


def find(title: str):
    return next((w for w in windows() if title in w["caption"]), None)


def wait_for(pred, timeout=15.0, step=0.3):
    end = time.time() + timeout
    while time.time() < end:
        value = pred()
        if value:
            return value
        time.sleep(step)
    return None


def activate(title: str):
    kwin("var ws = workspace.windowList(); for (var i=0;i<ws.length;i++){ if (ws[i].caption.indexOf(%s)>=0)"
         "{ ws[i].minimized = false; workspace.activeWindow = ws[i]; OUT('ok'); break; } }" % json.dumps(title), wait=0.3)
    time.sleep(0.3)


def click(x, y, button="left"):
    run(LAB / "lab-click", int(round(x)), int(round(y)), BUTTONS[button])
    time.sleep(0.25)


def ydo(*args):
    run("ydotool", *args)


def drag(x0, y0, x1, y1, steps=25):
    run(LAB / "lab-move", int(round(x0)), int(round(y0)))
    ydo("click", "0x40")
    time.sleep(0.25)
    px, py = int(round(x0)), int(round(y0))
    for i in range(1, steps + 1):
        nx, ny = int(round(x0 + (x1 - x0) * i / steps)), int(round(y0 + (y1 - y0) * i / steps))
        ydo("mousemove", "-x", nx - px, "-y", ny - py)
        px, py = nx, ny
        time.sleep(0.03)
    time.sleep(0.25)
    ydo("click", "0x80")
    time.sleep(0.5)


def shot(out: Path, name: str):
    target = out / "screenshots" / f"{name}.png"
    target.parent.mkdir(exist_ok=True)
    run(LAB / "lab-shot", target, check=False)
    return str(target.name) if target.exists() else None


ATSPI = r"""
import json, sys, gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi
title, button, expect = sys.argv[1], sys.argv[2], sys.argv[3]
found = {'button_found': False, 'value_matches': False, 'texts': []}
def walk(node, depth=0):
    if node is None or depth > 40: return
    try:
        role = node.get_role(); name = node.get_name() or ''
        if role == Atspi.Role.PUSH_BUTTON and name == button: found['button_found'] = True
        if role in (Atspi.Role.ENTRY, Atspi.Role.TEXT, Atspi.Role.PASSWORD_TEXT) and node.is_text():
            # Accessible.get_text() returns the Text interface; call Text.get_text(start, end) on it.
            value = Atspi.Text.get_text(node, 0, Atspi.Text.get_character_count(node))
            found['texts'].append(value)
            if value == expect: found['value_matches'] = True
    except Exception as error:
        found.setdefault('errors', []).append(type(error).__name__ + ': ' + str(error)[:120])
    try:
        for i in range(node.get_child_count()): walk(node.get_child_at_index(i), depth + 1)
    except Exception as error:
        found.setdefault('errors', []).append(type(error).__name__ + ': ' + str(error)[:120])
desktop = Atspi.get_desktop(0)
for i in range(desktop.get_child_count()):
    app = desktop.get_child_at_index(i)
    for j in range(app.get_child_count() if app else 0):
        frame = app.get_child_at_index(j)
        if frame is not None and title in (frame.get_name() or ''):
            found['app'] = app.get_name(); found['frame'] = frame.get_name(); walk(frame)
print(json.dumps(found))
"""


def a11y(title, button, expect):
    run("busctl", "--user", "set-property", "org.a11y.Bus", "/org/a11y/bus", "org.a11y.Status", "IsEnabled", "b", "true", check=False)
    for _ in range(10):
        out = run("/usr/bin/python3", "-c", ATSPI, title, button, expect, timeout=60, check=False)
        try:
            result = json.loads(out.stdout.strip().splitlines()[-1])
        except (ValueError, IndexError):
            result = {"button_found": False, "value_matches": False, "error": out.stderr[-300:]}
        if result.get("button_found") and result.get("value_matches"):
            return result
        time.sleep(1)
    return result


def records(path: Path):
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def ack(out: Path, rid: int, **fields):
    with (out / "acks.jsonl").open("a", encoding="utf-8") as f:
        f.write(json.dumps({"ack": rid, **fields}, ensure_ascii=False) + "\n")


def perform(r: dict, out: Path, title: str) -> dict:
    action, rid = r["action"], r["id"]
    obs = {"request": r}
    try:
        if action in ("click", "clicks"):
            activate(title)
            w = find(title)
            for p in (r["points"] if action == "clicks" else [r]):
                click(w["cx"] + p["x"], w["cy"] + p["y"], r.get("button", "left"))
            ack(out, rid, done=True, client=[w["cx"], w["cy"]])
        elif action == "type":
            run(LAB / "lab-type", r["text"])
            time.sleep(0.3)
            ack(out, rid, done=True)
        elif action == "key":
            code = KEYS[r["key"]]
            ydo("key", f"{code}:1", f"{code}:0")
            time.sleep(0.3)
            ack(out, rid, done=True)
        elif action == "a11y":
            result = a11y(title, r["button"], r["expect_value"])
            obs["a11y"] = result
            ack(out, rid, **result)
        elif action == "dialog-accept":
            w = wait_for(lambda: find(r["title"]), 30)
            obs["dialog"] = w
            if w:
                activate(r["title"])
                time.sleep(0.8)
                obs["screenshot"] = shot(out, "dialog-save")
                ydo("key", "28:1", "28:0")
            ack(out, rid, seen=bool(w), caption=w["caption"] if w else None)
        elif action == "dialog-observe":
            w = wait_for(lambda: find(r["title"]), 30)
            obs["dialog"] = w
            if w:
                obs["screenshot"] = shot(out, "dialog-open")
            ack(out, rid, seen=bool(w), caption=w["caption"] if w else None)
        elif action == "dialog-gone":
            gone = wait_for(lambda: find(r["title"]) is None, 15) is not None
            ack(out, rid, gone=gone)
        elif action == "observe-window":
            want = r["expect"]

            def state():
                w = find(title)
                if not w:
                    return None
                maximized = (w["x"], w["y"], w["w"], w["h"]) == (w["ax"], w["ay"], w["aw"], w["ah"])
                s = "minimized" if w["minimized"] else ("maximized" if maximized else "normal")
                return w if s == want else None
            w = wait_for(state, 10)
            ack(out, rid, ok=bool(w), window=w)
        elif action == "drag":
            activate(title)
            before = find(title)
            x0, y0 = before["cx"] + r["x"], before["cy"] + r["y"]
            drag(x0, y0, x0 + r["dx"], y0 + r["dy"])
            after = find(title)
            moved = (after["x"], after["y"]) != (before["x"], before["y"]) and (after["w"], after["h"]) == (before["w"], before["h"])
            resized = (after["w"], after["h"]) != (before["w"], before["h"])
            if r.get("measure") == "move" or r.get("edge") == "se":
                obs["screenshot"] = shot(out, "frameless-" + (r.get("edge") or "move"))
            ack(out, rid, moved=moved, resized=resized, before=before, after=after, edge=r.get("edge"))
        elif action == "clipboard-read":
            text = run("wl-paste", "-n", "-t", "text/plain;charset=utf-8", check=False).stdout
            ack(out, rid, text=text)
        elif action == "clipboard-write":
            subprocess.Popen(["wl-copy", "--", r["text"]], env=ENV, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(0.6)
            ack(out, rid, done=True)
        elif action == "activate":
            activate(title)
            ack(out, rid, done=True)
        elif action == "native-close":
            # Real keyboard Alt+F4 on the active window: KWin sends the native close request.
            activate(title)
            obs["screenshot"] = shot(out, "before-native-close-final" if r.get("final") else "before-native-close")
            ydo("key", "56:1", "62:1", "62:0", "56:0")
            ack(out, rid, done=True, input="Alt+F4")
        else:
            ack(out, rid, error=f"unsupported action {action}")
    except Exception as error:  # reported to the backend, which fails the check
        obs["error"] = repr(error)
        ack(out, rid, error=repr(error))
    return obs


def leftovers(host: str) -> dict:
    """Processes running the host executable or the Qualify.ps1 backend (by exe and argv, not by
    matching this driver's own command line), plus any transient host systemd unit."""
    real = os.path.realpath(host)
    procs, backends = [], []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit() or int(entry.name) == os.getpid():
            continue
        try:
            exe = os.path.realpath(entry / "exe")
            argv = (entry / "cmdline").read_bytes().split(b"\0")
        except OSError:
            continue
        if exe == real:
            procs.append(int(entry.name))
        elif os.path.basename(exe) == "pwsh" and any(a.endswith(b"Qualify.ps1") for a in argv):
            backends.append(int(entry.name))
    units = run("systemctl", "--user", "list-units", "nativehtmlkit-host-*", "--no-legend", "--plain", check=False).stdout.strip()
    return {"host_processes": procs, "units": [u for u in units.splitlines() if u], "backend_processes": backends}


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "--find":
        # Used by scripts/smoke-installed.ps1 -Gui: print the KWin window whose caption matches.
        print(json.dumps(find(sys.argv[2])))
        return 0
    ap = argparse.ArgumentParser()
    ap.add_argument("--module", required=True)
    ap.add_argument("--host", required=True)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--mode", default="full")
    ap.add_argument("--pwsh", default="pwsh")
    ap.add_argument("--timeout", type=float, default=900)
    a = ap.parse_args()
    out: Path = a.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    for name in ("results.jsonl", "acks.jsonl"):
        (out / name).unlink(missing_ok=True)
    script = Path(__file__).with_name("Qualify.ps1")
    env = dict(ENV, NATIVEHTMLKIT_PS_RESULTS=str(out), NATIVEHTMLKIT_PS_MODULE=a.module, NATIVEHTMLKIT_PS_MODE=a.mode,
               NATIVEHTMLKIT_HOST_BINARY=a.host)
    for key in [k for k in env if k.startswith("UI4ME_")]:
        env.pop(key)
    harness = {"mode": a.mode, "host": a.host, "host_sha256": sha256(a.host), "module": a.module,
               "pwsh": run(a.pwsh, "-NoProfile", "-Command", "$PSVersionTable.PSVersion.ToString()").stdout.strip(),
               "session": run(LAB / "lab-status", check=False).stdout, "before": leftovers(a.host), "observations": []}
    # The desktop must be exclusive: another NativeHTMLKit app (left by another test run) steals
    # focus and input. Refuse to run (exit 3 = BLOCKED) instead of producing a contaminated result.
    foreign = [w for w in windows() if w["caption"] and any(k in w["caption"] for k in ("NativeHTMLKit", "nhk", "NHK"))]
    other_hosts = [p for p in run("pgrep", "-u", str(os.getuid()), "-x", "nativehtmlkit-h", check=False).stdout.split()]
    if harness["before"]["units"] or harness["before"]["host_processes"] or other_hosts or foreign:
        harness["blocked"] = {"units": harness["before"]["units"], "host_processes": other_hosts, "windows": foreign}
        (out / f"harness-{a.mode}.json").write_text(json.dumps(harness, indent=2, ensure_ascii=False))
        print(json.dumps({"mode": a.mode, "blocked": "desktop not exclusive: another NativeHTMLKit host/window is running", **harness["blocked"]}, indent=2))
        return 3
    log = (out / f"launcher-{a.mode}.log").open("w")
    t0 = time.time()
    launcher = subprocess.Popen([a.pwsh, "-NoLogo", "-NoProfile", "-File", str(script)], env=env, stdout=log, stderr=subprocess.STDOUT,
                                cwd=str(out))
    done, title = set(), None
    results = out / "results.jsonl"
    try:
        while launcher.poll() is None and time.time() - t0 < a.timeout:
            for r in records(results):
                if r.get("kind") == "ready" and title is None:
                    title = r["title"]
                    harness["ready_s"] = round(time.time() - t0, 3)
                    w = wait_for(lambda: find(title), 20)
                    harness["window_at_ready"] = w
                    activate(title)
                    time.sleep(0.5)
                    harness["screenshot_ready"] = shot(out, f"ready-{a.mode}")
                if r.get("kind") != "request" or r["id"] in done:
                    continue
                done.add(r["id"])
                harness["observations"].append(perform(r, out, title))
            time.sleep(0.15)
        if launcher.poll() is None:
            harness["timeout"] = True
            launcher.terminate()
        harness["launcher_exit"] = launcher.wait(30)
    finally:
        if launcher.poll() is None:
            launcher.kill()
        time.sleep(2)
        harness["total_s"] = round(time.time() - t0, 3)
        harness["windows_after_exit"] = [w for w in windows() if title and title in w["caption"]]
        harness["after"] = leftovers(a.host)
        (out / f"harness-{a.mode}.json").write_text(json.dumps(harness, indent=2, ensure_ascii=False))
        log.close()
    recs = records(results)
    checks = [r for r in recs if r.get("kind") == "check"]
    failed = [c for c in checks if c["status"] != "pass"]
    clean = not harness["after"]["host_processes"] and not harness["after"]["units"] and not harness["after"]["backend_processes"] \
        and not harness["windows_after_exit"]
    summary = {"mode": a.mode, "checks": len(checks), "passed": len(checks) - len(failed),
               "failed": [c["name"] + ": " + c.get("error", "") for c in failed],
               "launcher_exit": harness.get("launcher_exit"), "timeout": harness.get("timeout", False),
               "fatal": [r for r in recs if r.get("kind") == "fatal"], "clean_teardown": clean,
               "done": any(r.get("kind") == "done" for r in recs), "shutdown": [r for r in recs if r.get("kind") == "shutdown"]}
    (out / f"summary-{a.mode}.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False))
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    ok = checks and not failed and harness.get("launcher_exit") == 0 and not harness.get("timeout") and clean and summary["done"] \
        and not summary["fatal"]
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
