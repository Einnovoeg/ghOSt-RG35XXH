#!/usr/bin/env python3
"""
ghOSt-RG35XXH ghost-memkeeper
Aggressive background process manager for 1GB RAM constraint.

Strategy:
- Monitor RAM every 30 seconds
- If free RAM drops below threshold, kill lowest-priority background apps
- Apps have tiers: protected, killable, background-only
- Killed apps can be relaunched from launcher — no data loss (terminal apps)
- Never kills: systemd, NetworkManager, Cage, stealthd, pipewire, bluetooth
- Aggressively kills: security tools left open, browser sessions, heavy CLIs
"""

import os
import sys
import time
import signal
import subprocess
import psutil
import logging
from dataclasses import dataclass, field
from typing import List, Optional
from pathlib import Path

# Setup logging to journal only
logging.basicConfig(
    level=logging.INFO,
    format='[memkeeper] %(message)s',
    stream=sys.stdout
)
log = logging.getLogger("memkeeper")

# =============================================================================
# THRESHOLDS (MB)
# =============================================================================
RAM_TOTAL_MB     = 1024

# Tiers of intervention
WARN_FREE_MB     = 200   # Log warning, no action
KILL_SOFT_MB     = 150   # Kill tier-3 apps (optional background tools)
KILL_HARD_MB     = 100   # Kill tier-2 apps (non-essential foreground)
KILL_PANIC_MB    = 60    # Kill tier-1 apps (everything except protected)

CHECK_INTERVAL   = 30    # Seconds between checks
NOTIFY_CMD       = "notify-send"

# =============================================================================
# APP TIERS
# lower priority_score = kill first
# =============================================================================
@dataclass
class AppRule:
    name: str                    # Process name (matches pgrep -x)
    cmdline_match: str = ""      # Substring match in cmdline (if name not enough)
    priority: int = 50           # 1=kill first, 100=protected
    kill_signal: int = signal.SIGTERM
    notify: bool = True          # Notify user before killing
    description: str = ""


APP_RULES: List[AppRule] = [
    # ==========================================================================
    # TIER 0: NEVER KILL — system critical (priority 100)
    # ==========================================================================
    AppRule("systemd",           priority=100),
    AppRule("systemd-journald",  priority=100),
    AppRule("systemd-udevd",     priority=100),
    AppRule("NetworkManager",    priority=100),
    AppRule("wpa_supplicant",    priority=100),
    AppRule("cage",              priority=100),
    AppRule("pipewire",          priority=100),
    AppRule("wireplumber",       priority=100),
    AppRule("bluetoothd",        priority=100),
    AppRule("dbus-daemon",       priority=100),
    AppRule("kworker",           priority=100),   # Our stealthd disguise
    AppRule("login",             priority=100),
    AppRule("sshd",              priority=100),
    AppRule("dnscrypt-proxy",    priority=100),
    AppRule("mako",              priority=100),
    AppRule("kanshi",            priority=100),
    AppRule("swayidle",          priority=100),
    AppRule("ghost-memkeeper",   priority=100),   # Don't kill ourselves

    # ==========================================================================
    # TIER 1: ESSENTIAL BACKGROUND — kill only in panic (priority 80-90)
    # ==========================================================================
    AppRule("tor",               priority=85,  description="Tor"),
    AppRule("intercept",         priority=85,  description="INTERCEPT"),
    AppRule("python3",
            cmdline_match="intercept",
            priority=85,         description="INTERCEPT"),
    AppRule("syncthing",         priority=80,  description="Syncthing"),

    # ==========================================================================
    # TIER 2: OPTIONAL BACKGROUND — kill when hard threshold hit (priority 40-70)
    # ==========================================================================
    AppRule("kismet",            priority=60,  description="Kismet"),
    AppRule("bettercap",         priority=60,  description="bettercap"),
    AppRule("spiderfoot",        priority=55,  description="Spiderfoot"),
    AppRule("python3",
            cmdline_match="spiderfoot",
            priority=55,         description="Spiderfoot"),
    AppRule("i2pd",              priority=50,  description="i2pd"),
    AppRule("hostapd",           priority=50,  description="hostapd rogue AP"),
    AppRule("airodump-ng",       priority=50,  description="airodump-ng"),

    # ==========================================================================
    # TIER 3: KILLABLE BACKGROUND — kill when soft threshold hit (priority 10-35)
    # ==========================================================================
    AppRule("msfconsole",        priority=30,  description="Metasploit",
            notify=True),
    AppRule("sqlmap",            priority=25,  description="sqlmap"),
    AppRule("nikto",             priority=25,  description="Nikto"),
    AppRule("ffuf",              priority=25,  description="ffuf"),
    AppRule("gobuster",          priority=25,  description="gobuster"),
    AppRule("feroxbuster",       priority=25,  description="feroxbuster"),
    AppRule("hydra",             priority=25,  description="Hydra"),
    AppRule("john",              priority=20,  description="John the Ripper"),
    AppRule("hashcat",           priority=20,  description="Hashcat"),
    AppRule("wine",              priority=20,  description="Wine (Windows app)"),
    AppRule("FEXInterpreter",    priority=20,  description="FEX x86 emulator"),
    AppRule("netsurf-gtk",       priority=15,  description="NetSurf browser"),
    AppRule("w3m",               priority=15,  description="w3m browser"),
    AppRule("mpv",               priority=15,  description="mpv video"),
    AppRule("cmus",              priority=10,  description="cmus music player"),
    AppRule("sdrpp",             priority=10,  description="SDR++"),
    AppRule("inspectrum",        priority=10,  description="inspectrum"),
]

# Build lookup dict
PROTECTED = {r.name for r in APP_RULES if r.priority >= 100}


# =============================================================================
# MEMORY MONITORING
# =============================================================================
def get_free_mb() -> int:
    mem = psutil.virtual_memory()
    return int(mem.available / 1024 / 1024)

def get_free_swap_mb() -> int:
    swap = psutil.swap_memory()
    return int(swap.free / 1024 / 1024)

def notify(msg: str):
    """Send desktop notification"""
    try:
        subprocess.run(
            [NOTIFY_CMD, "-u", "critical", "-t", "5000",
             "ghOSt Memory Manager", msg],
            capture_output=True, timeout=3,
            env={**os.environ, "DBUS_SESSION_BUS_ADDRESS":
                 "unix:path=/run/user/1000/bus"}
        )
    except Exception:
        pass


# =============================================================================
# PROCESS KILLING
# =============================================================================
def find_processes(rule: AppRule) -> List[psutil.Process]:
    """Find processes matching this rule"""
    found = []
    for proc in psutil.process_iter(['pid', 'name', 'cmdline', 'status']):
        try:
            if proc.info['status'] == psutil.STATUS_ZOMBIE:
                continue
            name = proc.info['name'] or ""
            cmdline = " ".join(proc.info['cmdline'] or [])

            name_match = name == rule.name
            cmd_match = (rule.cmdline_match and
                         rule.cmdline_match in cmdline)

            if name_match or (rule.name in name and cmd_match):
                found.append(proc)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass
    return found


def kill_app(rule: AppRule) -> bool:
    """Kill all processes matching rule. Returns True if anything was killed."""
    procs = find_processes(rule)
    if not procs:
        return False

    desc = rule.description or rule.name
    if rule.notify:
        notify(f"Low memory: closing {desc}")

    log.info(f"Killing {desc} (priority {rule.priority}) — freeing RAM")

    for proc in procs:
        try:
            proc.send_signal(rule.kill_signal)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass

    # Give SIGTERM time to work, then SIGKILL
    time.sleep(2)
    for proc in procs:
        try:
            if proc.is_running():
                proc.kill()
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass

    return True


def get_killable_apps(max_priority: int) -> List[AppRule]:
    """Get running apps eligible for killing, sorted lowest priority first"""
    killable = []
    for rule in APP_RULES:
        if rule.priority >= 100:
            continue
        if rule.priority > max_priority:
            continue
        if find_processes(rule):
            killable.append(rule)
    return sorted(killable, key=lambda r: r.priority)


# =============================================================================
# MAIN LOOP
# =============================================================================
def main():
    log.info("ghOSt-RG35XXH memory keeper starting")
    log.info(f"Thresholds: warn={WARN_FREE_MB}MB soft={KILL_SOFT_MB}MB "
             f"hard={KILL_HARD_MB}MB panic={KILL_PANIC_MB}MB")

    # Install psutil if missing
    try:
        import psutil
    except ImportError:
        subprocess.run(["pip3", "install", "psutil", "--break-system-packages"],
                       capture_output=True)
        import psutil

    while True:
        free_mb = get_free_mb()
        free_swap = get_free_swap_mb()

        if free_mb >= WARN_FREE_MB:
            # All good — log occasionally
            pass

        elif free_mb >= KILL_SOFT_MB:
            log.warning(f"RAM low: {free_mb}MB free — warning")
            notify(f"Memory low: {free_mb}MB free. Close unused apps.")

        elif free_mb >= KILL_HARD_MB:
            log.warning(f"RAM critical: {free_mb}MB free — killing tier-3 apps")
            for rule in get_killable_apps(max_priority=35):
                kill_app(rule)
                time.sleep(1)
                if get_free_mb() >= KILL_SOFT_MB:
                    break

        elif free_mb >= KILL_PANIC_MB:
            log.error(f"RAM dangerously low: {free_mb}MB — killing tier-2 apps")
            for rule in get_killable_apps(max_priority=70):
                kill_app(rule)
                time.sleep(1)
                if get_free_mb() >= KILL_HARD_MB:
                    break

        else:
            log.critical(f"RAM PANIC: {free_mb}MB — killing everything possible")
            notify("CRITICAL: Out of memory! Closing all non-essential apps.")
            for rule in get_killable_apps(max_priority=90):
                kill_app(rule)
                time.sleep(0.5)
                if get_free_mb() >= KILL_PANIC_MB:
                    break

        time.sleep(CHECK_INTERVAL)


if __name__ == "__main__":
    main()
