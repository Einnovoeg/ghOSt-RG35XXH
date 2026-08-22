#!/usr/bin/env python3
"""
ghOSt-RG35XXH Battery Manager
- Charge limit enforcement (default 80% for longevity)
- Temperature monitoring with auto-throttle
- Health status reporting
- Low battery notifications
- Configurable via /etc/ghost/battery.conf
"""

import os, sys, time, signal, subprocess, configparser
from pathlib import Path

CONFIG_FILE = Path("/etc/ghost/battery.conf")
NOTIFY = "notify-send"

# Sysfs paths for Anbernic RG35XXH (Allwinner H700)
POWER_SUPPLY = Path("/sys/class/power_supply")

def find_battery():
    for p in POWER_SUPPLY.iterdir():
        try:
            t = (p / "type").read_text().strip()
            if t == "Battery":
                return p
        except Exception:
            pass
    return None

def find_ac():
    for p in POWER_SUPPLY.iterdir():
        try:
            t = (p / "type").read_text().strip()
            if t in ("Mains", "USB"):
                return p
        except Exception:
            pass
    return None

def read_sysfs(path, default=None):
    try:
        return Path(path).read_text().strip()
    except Exception:
        return default

def write_sysfs(path, value):
    try:
        Path(path).write_text(str(value))
        return True
    except Exception:
        return False

def notify(msg, urgency="normal", timeout=5000):
    try:
        env = {**os.environ,
               "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus",
               "DISPLAY": ":0"}
        subprocess.run(
            [NOTIFY, "-u", urgency, "-t", str(timeout),
             "Battery", msg],
            capture_output=True, timeout=3, env=env)
    except Exception:
        pass

def load_config():
    cfg = configparser.ConfigParser()
    cfg.read_dict({
        "battery": {
            "charge_limit":    "80",     # % max charge
            "warn_low":        "20",     # % notify low
            "warn_critical":   "10",     # % notify critical
            "warn_emergency":  "5",      # % suspend
            "temp_warn":       "45",     # C throttle CPU
            "temp_critical":   "55",     # C emergency suspend
            "check_interval":  "60",     # seconds
        }
    })
    if CONFIG_FILE.exists():
        cfg.read(CONFIG_FILE)
    return cfg["battery"]


class BatteryManager:
    def __init__(self):
        self.cfg = load_config()
        self.bat = find_battery()
        self.ac  = find_ac()
        self._last_notif = {}
        self.running = True

    def reload_config(self, *_):
        self.cfg = load_config()

    def get_capacity(self):
        if not self.bat:
            return None
        v = read_sysfs(self.bat / "capacity")
        return int(v) if v else None

    def get_status(self):
        if not self.bat:
            return "Unknown"
        return read_sysfs(self.bat / "status", "Unknown")

    def get_temp_celsius(self):
        # Try battery temp first
        if self.bat:
            v = read_sysfs(self.bat / "temp")
            if v:
                return int(v) / 10.0
        # Fall back to thermal zone
        for tz in Path("/sys/class/thermal").glob("thermal_zone*"):
            try:
                t = (tz / "type").read_text().strip()
                if "battery" in t.lower() or "cpu" in t.lower():
                    v = int((tz / "temp").read_text().strip())
                    return v / 1000.0
            except Exception:
                pass
        return None

    def set_charge_limit(self, pct):
        """Set charge limit via sysfs — H700 specific path"""
        paths = [
            "/sys/class/power_supply/battery/charge_control_end_threshold",
            "/sys/class/power_supply/BAT0/charge_control_end_threshold",
            "/sys/class/power_supply/axp20x-battery/charge_control_end_threshold",
        ]
        for p in paths:
            if write_sysfs(p, pct):
                return True
        # Try via upower if sysfs doesn't work
        try:
            subprocess.run(
                ["upower", "--set-charge-thresholds",
                 f"--charge-end-threshold={pct}"],
                capture_output=True, timeout=5)
            return True
        except Exception:
            pass
        return False

    def set_cpu_governor(self, governor):
        """Set CPU frequency governor for all cores"""
        changed = 0
        for policy in Path("/sys/devices/system/cpu").glob("cpu*/cpufreq"):
            if write_sysfs(policy / "scaling_governor", governor):
                changed += 1
        return changed > 0

    def throttle_cpu(self):
        """Set powersave governor due to high temp"""
        self.set_cpu_governor("powersave")

    def _notif_once(self, key, msg, urgency="normal", cooldown=300):
        """Throttle notifications — don't spam same alert"""
        now = time.monotonic()
        last = self._last_notif.get(key, 0)
        if now - last > cooldown:
            notify(msg, urgency)
            self._last_notif[key] = now

    def check(self):
        cfg = self.cfg
        cap = self.get_capacity()
        status = self.get_status()
        temp = self.get_temp_celsius()
        charging = status in ("Charging", "Full")

        # Enforce charge limit
        limit = int(cfg["charge_limit"])
        if charging and cap is not None and cap >= limit:
            self.set_charge_limit(limit)

        # Temperature
        if temp is not None:
            t_warn = float(cfg["temp_warn"])
            t_crit = float(cfg["temp_critical"])
            if temp >= t_crit:
                self._notif_once("temp_crit",
                    f"⚠️ Temperature critical: {temp:.0f}°C — suspending",
                    "critical", cooldown=120)
                subprocess.run(["systemctl", "suspend"], capture_output=True)
            elif temp >= t_warn:
                self._notif_once("temp_warn",
                    f"🌡️ Temperature high: {temp:.0f}°C — throttling CPU",
                    "normal", cooldown=180)
                self.throttle_cpu()

        # Low battery (only when discharging)
        if cap is not None and not charging:
            emergency = int(cfg["warn_emergency"])
            critical  = int(cfg["warn_critical"])
            low       = int(cfg["warn_low"])

            if cap <= emergency:
                self._notif_once("emergency",
                    f"🔴 BATTERY CRITICAL: {cap}% — suspending NOW",
                    "critical", cooldown=60)
                subprocess.run(["systemctl", "suspend"], capture_output=True)
            elif cap <= critical:
                self._notif_once("critical",
                    f"🟠 Battery critical: {cap}% — save your work!",
                    "critical", cooldown=120)
            elif cap <= low:
                self._notif_once("low",
                    f"🟡 Battery low: {cap}%",
                    "normal", cooldown=300)

    def status_report(self):
        """Print human-readable status"""
        cap    = self.get_capacity()
        status = self.get_status()
        temp   = self.get_temp_celsius()
        cfg    = self.cfg

        print(f"\n ghOSt-RG35XXH Battery Status")
        print(f" {'─'*30}")
        print(f"  Charge:      {cap}%")
        print(f"  Status:      {status}")
        if temp:
            print(f"  Temperature: {temp:.1f}°C")
        print(f"  Charge limit: {cfg['charge_limit']}%")
        print(f"  Warn low:     {cfg['warn_low']}%")

        # CPU governor
        gov_path = "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
        gov = read_sysfs(gov_path, "unknown")
        print(f"  CPU governor: {gov}")

        # Available governors
        avail = read_sysfs(
            "/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors",
            "")
        if avail:
            print(f"  Available:    {avail}")
        print()

    def run(self):
        interval = int(self.cfg["check_interval"])
        signal.signal(signal.SIGHUP, self.reload_config)
        while self.running:
            try:
                self.check()
            except Exception as e:
                pass
            time.sleep(interval)


def main():
    if len(sys.argv) > 1:
        bm = BatteryManager()
        cmd = sys.argv[1]

        if cmd == "status":
            bm.status_report()

        elif cmd == "limit":
            pct = int(sys.argv[2]) if len(sys.argv) > 2 else 80
            if bm.set_charge_limit(pct):
                # Persist to config
                cfg = configparser.ConfigParser()
                cfg.read(CONFIG_FILE)
                if "battery" not in cfg:
                    cfg["battery"] = {}
                cfg["battery"]["charge_limit"] = str(pct)
                CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
                with open(CONFIG_FILE, 'w') as f:
                    cfg.write(f)
                print(f"Charge limit set to {pct}%")
            else:
                print("Failed to set charge limit (may not be supported)")

        elif cmd == "governor":
            gov = sys.argv[2] if len(sys.argv) > 2 else "schedutil"
            if bm.set_cpu_governor(gov):
                print(f"CPU governor set to {gov}")
            else:
                print("Failed — check /sys/devices/system/cpu/cpu0/cpufreq/")
        else:
            print("Usage: ghost-battery [status|limit <pct>|governor <name>]")
        return

    # Daemon mode
    bm = BatteryManager()
    bm.run()


if __name__ == "__main__":
    main()
