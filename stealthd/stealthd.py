#!/usr/bin/env python3
"""
ghOSt-RG35XXH stealthd — Stealth Mode Daemon
- Zero background residue when inactive
- SIGSTOP launcher (instant pause, instant resume)
- Kills entire mGBA process group on exit
- Cleans all traces on deactivate
"""

import os, sys, time, signal, subprocess, glob, ctypes, threading, tempfile
from pathlib import Path

# Process disguise
try:
    ctypes.CDLL("libc.so.6").prctl(15, b"kworker/0:1H", 0, 0, 0)
except Exception:
    pass

try:
    import evdev
    from evdev import InputDevice, ecodes
except ImportError:
    sys.stderr.write("python3-evdev required\n")
    sys.exit(1)

# Config
STEALTH_ROM_DIR  = Path(os.path.expanduser("~/.stealth/roms"))
HOLD_SECONDS     = 3.0
WAYLAND_DISPLAY  = os.environ.get("WAYLAND_DISPLAY", "wayland-1")
XDG_RUNTIME_DIR  = os.environ.get("XDG_RUNTIME_DIR", "/run/user/1000")
BTN_SELECT, BTN_START, BTN_L2 = ecodes.BTN_SELECT, ecodes.BTN_START, ecodes.BTN_TL2
STEALTH_COMBO    = frozenset([BTN_SELECT, BTN_START, BTN_L2])
TMPDIR           = Path(tempfile.gettempdir()) / "ghost-stealth"
STEALTH_ACTIVE   = TMPDIR / "active"

def log(msg):
    try:
        subprocess.run(["systemd-cat", "-t", "kworker", "-p", "info"],
                       input=msg.encode(), capture_output=True, timeout=1)
    except Exception:
        pass

def find_rom():
    STEALTH_ROM_DIR.mkdir(parents=True, exist_ok=True)
    roms = list(STEALTH_ROM_DIR.glob("*.gba")) + \
           list(STEALTH_ROM_DIR.glob("*.gbc")) + \
           list(STEALTH_ROM_DIR.glob("*.gb"))
    return str(max(roms, key=lambda p: p.stat().st_mtime)) if roms else None

def get_launcher_pid():
    try:
        r = subprocess.run(["pgrep", "-f", "launcher.py"],
                           capture_output=True, text=True)
        pids = r.stdout.strip().split()
        return int(pids[0]) if pids else None
    except Exception:
        return None

def reconnect_bt():
    try:
        r = subprocess.run(["bluetoothctl", "devices", "Paired"],
                           capture_output=True, text=True, timeout=5)
        for line in r.stdout.splitlines():
            if "Device" in line:
                mac = line.split()[1]
                subprocess.run(["bluetoothctl", "connect", mac],
                               capture_output=True, timeout=8)
                break
    except Exception:
        pass

class StealthMode:
    def __init__(self):
        self.active = False
        self.mgba_proc = None
        self.launcher_pid = None
        self._lock = threading.Lock()
        TMPDIR.mkdir(parents=True, exist_ok=True)

    def activate(self):
        with self._lock:
            if self.active:
                return
            rom = find_rom()
            if not rom:
                log("No ROM found — stealth cancelled")
                return
            log(f"Activating: {Path(rom).name}")

            # Pause launcher instantly
            self.launcher_pid = get_launcher_pid()
            if self.launcher_pid:
                try:
                    os.kill(self.launcher_pid, signal.SIGSTOP)
                except ProcessLookupError:
                    self.launcher_pid = None

            # BT keyboard (non-blocking)
            threading.Thread(target=reconnect_bt, daemon=True).start()

            # Launch mGBA
            env = {**os.environ,
                   "WAYLAND_DISPLAY": WAYLAND_DISPLAY,
                   "XDG_RUNTIME_DIR": XDG_RUNTIME_DIR,
                   "SDL_VIDEODRIVER": "wayland",
                   "SDL_VIDEO_WAYLAND_WINDOW_TITLE": "System Monitor"}

            self.mgba_proc = subprocess.Popen(
                ["gamescope", "-w", "640", "-h", "480",
                 "-W", "640", "-H", "480", "-f",
                 "--", "mgba-sdl", "-f", rom],
                env=env, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, start_new_session=True)

            self.active = True
            STEALTH_ACTIVE.touch()
            log("Stealth active")
            threading.Thread(target=self._watch_exit, daemon=True).start()

    def deactivate(self, reason="combo"):
        with self._lock:
            if not self.active:
                return
            log(f"Deactivating ({reason})")

            # Kill mGBA process group completely
            if self.mgba_proc and self.mgba_proc.poll() is None:
                try:
                    os.killpg(os.getpgid(self.mgba_proc.pid), signal.SIGKILL)
                except (ProcessLookupError, OSError):
                    pass
                try:
                    self.mgba_proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    pass
            self.mgba_proc = None

            # Kill any orphaned processes
            for name in ["mgba", "mgba-sdl", "gamescope"]:
                subprocess.run(["pkill", "-9", "-x", name],
                               capture_output=True)

            # Resume launcher
            if self.launcher_pid:
                try:
                    os.kill(self.launcher_pid, signal.SIGCONT)
                except ProcessLookupError:
                    subprocess.Popen(
                        ["systemctl", "--user", "restart", "ghost-gui.service"],
                        capture_output=True)
                self.launcher_pid = None

            # Clean traces
            self._clean()
            self.active = False
            STEALTH_ACTIVE.unlink(missing_ok=True)
            log("Stealth deactivated — clean")

    def _watch_exit(self):
        if self.mgba_proc:
            self.mgba_proc.wait()
        if self.active:
            self.deactivate("mgba_exit")

    def _clean(self):
        # Clear fish history of stealth-related commands
        try:
            subprocess.run(
                ["fish", "-c",
                 "builtin history delete --prefix mgba 2>/dev/null; "
                 "builtin history delete --prefix gamescope 2>/dev/null; true"],
                capture_output=True, timeout=3)
        except Exception:
            pass
        # Clear dmesg
        try:
            subprocess.run(["dmesg", "--clear"], capture_output=True, timeout=2)
        except Exception:
            pass
        for f in TMPDIR.glob("stealth-*"):
            f.unlink(missing_ok=True)


class InputMonitor:
    def __init__(self, stealth):
        self.stealth = stealth
        self.pressed = set()
        self.combo_start = 0.0
        self.running = True

    def _get_devices(self):
        devices = []
        for path in glob.glob("/dev/input/event*"):
            try:
                dev = InputDevice(path)
                caps = dev.capabilities()
                if ecodes.EV_KEY in caps:
                    keys = caps[ecodes.EV_KEY]
                    if any(k in keys for k in
                           [BTN_SELECT, BTN_START, BTN_L2, ecodes.BTN_SOUTH]):
                        devices.append(dev)
            except (PermissionError, OSError):
                pass
        return devices

    def _handle(self, ev):
        if ev.type != ecodes.EV_KEY:
            return
        if ev.value == 1:
            self.pressed.add(ev.code)
        elif ev.value == 0:
            self.pressed.discard(ev.code)
            if not STEALTH_COMBO.issubset(self.pressed):
                self.combo_start = 0.0

        if STEALTH_COMBO.issubset(self.pressed):
            if self.combo_start == 0.0:
                self.combo_start = time.monotonic()
            elif time.monotonic() - self.combo_start >= HOLD_SECONDS:
                self.combo_start = 0.0
                if self.stealth.active:
                    self.stealth.deactivate("combo")
                else:
                    self.stealth.activate()
        else:
            self.combo_start = 0.0

    def _monitor(self, dev):
        try:
            for ev in dev.read_loop():
                if not self.running:
                    break
                self._handle(ev)
        except OSError:
            pass

    def run(self):
        while self.running:
            devices = self._get_devices()
            if not devices:
                time.sleep(5)
                continue
            threads = [threading.Thread(target=self._monitor, args=(d,), daemon=True)
                       for d in devices]
            for t in threads:
                t.start()
            for t in threads:
                t.join()
            time.sleep(2)


def main():
    if "--activate" in sys.argv:
        s = StealthMode()
        s.activate()
        if s.mgba_proc:
            s.mgba_proc.wait()
        s.deactivate("direct_exit")
        return
    if "--deactivate" in sys.argv:
        for name in ["mgba", "mgba-sdl", "gamescope"]:
            subprocess.run(["pkill", "-9", "-x", name], capture_output=True)
        STEALTH_ACTIVE.unlink(missing_ok=True)
        return
    if "--status" in sys.argv:
        print("active" if STEALTH_ACTIVE.exists() else "inactive")
        return

    log("ghOSt-RG35XXH stealthd running")
    stealth = StealthMode()
    monitor = InputMonitor(stealth)

    def shutdown(*_):
        monitor.running = False
        if stealth.active:
            stealth.deactivate("shutdown")
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    monitor.run()

if __name__ == "__main__":
    main()
