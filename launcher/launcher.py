#!/usr/bin/env python3
"""
ghOSt Launcher
Button-navigable application launcher for 640x480 display
SDL2-based, evdev input, Wayland/Cage compatible
"""

import os
import sys
import subprocess
import threading
import json
import time
import signal
import shutil
from pathlib import Path

try:
    import sdl2
    import sdl2.ext
    import sdl2.sdlttf as ttf
    import sdl2.sdlimage as img
    import ctypes
except ImportError:
    print("SDL2 not found, install python3-sdl2")
    sys.exit(1)

# =============================================================================
# CONFIGURATION
# =============================================================================
SCREEN_W, SCREEN_H = 640, 480
FPS = 30
FONT_PATH = "/usr/share/fonts/X11/misc/ter-x14b.pcf.gz"
FONT_SIZE = 14

# Catppuccin Mocha palette
COLORS = {
    "bg":        (30,  30,  46,  255),   # #1e1e2e
    "surface0":  (49,  50,  68,  255),   # #313244
    "surface1":  (69,  71,  90,  255),   # #45475a
    "overlay":   (108, 112, 134, 255),   # #6c7086
    "text":      (205, 214, 244, 255),   # #cdd6f4
    "subtext":   (166, 173, 200, 255),   # #a6adc8
    "blue":      (137, 180, 250, 255),   # #89b4fa
    "green":     (166, 227, 161, 255),   # #a6e3a1
    "red":       (243, 139, 168, 255),   # #f38ba8
    "yellow":    (249, 226, 175, 255),   # #f9e2af
    "mauve":     (203, 166, 247, 255),   # #cba6f7
    "teal":      (148, 226, 213, 255),   # #94e2d5
    "pink":      (245, 194, 231, 255),   # #f5c2e7
    "peach":     (250, 179, 135, 255),   # #fab387
}

# =============================================================================
# MENU STRUCTURE
# =============================================================================
MENU_TEMPLATE = [
    {
        "label": "SIGNAL INT",
        "icon": "📡",
        "color": "teal",
        "items": [
            {"label": "INTERCEPT",      "cmd": "netsurf-gtk http://localhost:5050",  "icon": "🔭", "requires": {"paths": ["/opt/ghost/intercept/intercept.py"]}},
            {"label": "SDR++ Brown",    "cmd": "sdrpp",                              "icon": "📻", "requires": {"commands": ["sdrpp"]}},
            {"label": "dump1090 ADS-B", "cmd": "foot dump1090 --interactive",        "icon": "✈️", "requires": {"commands": ["dump1090"]}},
            {"label": "Kismet",         "cmd": "foot kismet",                        "icon": "📶", "requires": {"commands": ["kismet"]}},
            {"label": "inspectrum",     "cmd": "inspectrum",                         "icon": "🔬", "requires": {"commands": ["inspectrum"]}},
            {"label": "fldigi",         "cmd": "fldigi",                             "icon": "📟", "requires": {"commands": ["fldigi"]}},
        ]
    },
    {
        "label": "RECON",
        "icon": "🔍",
        "color": "yellow",
        "items": [
            {"label": "nmap scan",      "cmd": "foot fish -C 'nmap -sV -sC '",       "icon": "🗺️"},
            {"label": "bettercap",      "cmd": "foot sudo bettercap",                "icon": "🕸️"},
            {"label": "termshark",      "cmd": "foot sudo termshark -i any",         "icon": "🦈"},
            {"label": "Metasploit",     "cmd": "foot sudo msfconsole",               "icon": "💀"},
            {"label": "sqlmap",         "cmd": "foot sqlmap --wizard",               "icon": "💉"},
            {"label": "mitmproxy",      "cmd": "foot mitmproxy",                     "icon": "🎭"},
        ]
    },
    {
        "label": "WIRELESS",
        "icon": "📶",
        "color": "blue",
        "items": [
            {"label": "airmon-ng",      "cmd": "foot sudo airmon-ng",               "icon": "🔓"},
            {"label": "airodump-ng",    "cmd": "foot sudo airodump-ng",             "icon": "📡"},
            {"label": "wifite2",        "cmd": "foot sudo wifite",                  "icon": "🔑"},
            {"label": "airgeddon",      "cmd": "foot sudo bash /opt/ghost/airgeddon/airgeddon.sh", "icon": "⚡", "requires": {"paths": ["/opt/ghost/airgeddon/airgeddon.sh"]}},
            {"label": "wavemon",        "cmd": "foot wavemon",                      "icon": "〰️"},
            {"label": "bluetuith",      "cmd": "foot bluetuith",                    "icon": "🔵", "requires": {"commands": ["bluetuith"]}},
        ]
    },
    {
        "label": "TOOLS",
        "icon": "🛠️",
        "color": "mauve",
        "items": [
            {"label": "CyberChef",      "cmd": "netsurf-gtk http://localhost:8000",  "icon": "🧪"},
            {"label": "radare2",        "cmd": "foot r2",                            "icon": "🔧"},
            {"label": "hashcat",        "cmd": "foot hashcat",                       "icon": "🔐"},
            {"label": "john",           "cmd": "foot john",                          "icon": "🗝️"},
            {"label": "SpiderFoot",     "cmd": "foot spiderfoot -l 127.0.0.1:5001", "icon": "🕷️", "requires": {"commands": ["spiderfoot"]}},
            {"label": "x64dbg",         "cmd": "wine /opt/ghost/wine-apps/x64dbg/x64/x64dbg.exe", "icon": "🐛", "requires": {"commands": ["wine"], "paths": ["/opt/ghost/wine-apps/x64dbg/x64/x64dbg.exe"]}},
        ]
    },
    {
        "label": "AI",
        "icon": "🤖",
        "color": "pink",
        "items": [
            {"label": "hey (voice)",    "cmd": "foot hey",                           "icon": "🎙️", "requires": {"commands": ["hey"]}},
            {"label": "hey (text)",     "cmd": "foot hey -t",                        "icon": "💬", "requires": {"commands": ["hey"]}},
            {"label": "hey (model)",    "cmd": "foot hey -m",                        "icon": "⚙️", "requires": {"commands": ["hey"]}},
        ]
    },
    {
        "label": "PRIVACY",
        "icon": "👻",
        "color": "overlay",
        "items": [
            {"label": "Tor Browser",    "cmd": "foot torsocks w3m https://check.torproject.org", "icon": "🧅"},
            {"label": "anonsurf on",    "cmd": "foot sudo anonsurf start",           "icon": "🔒", "requires": {"commands": ["anonsurf"]}},
            {"label": "anonsurf off",   "cmd": "foot sudo anonsurf stop",            "icon": "🔓", "requires": {"commands": ["anonsurf"]}},
            {"label": "WireGuard",      "cmd": "foot sudo wg-quick up wg0",          "icon": "🛡️"},
            {"label": "ProtonVPN",      "cmd": "foot sudo protonvpn-cli connect",    "icon": "⚡", "requires": {"commands": ["protonvpn-cli"]}},
            {"label": "i2pd",           "cmd": "foot sudo systemctl start i2pd",     "icon": "🌐", "requires": {"commands": ["i2pd"]}},
        ]
    },
    {
        "label": "BROWSER",
        "icon": "🌐",
        "color": "blue",
        "items": [
            {"label": "NetSurf",        "cmd": "netsurf-gtk https://start.duckduckgo.com", "icon": "🌊"},
            {"label": "w3m",            "cmd": "foot w3m https://start.duckduckgo.com",    "icon": "📄"},
            {"label": "w3m Tor",        "cmd": "foot torsocks w3m https://3g2upl4pq6kufc4m.onion", "icon": "🧅"},
        ]
    },
    {
        "label": "GAMES",
        "icon": "🎮",
        "color": "peach",
        "items": [
            {"label": "PortMaster",     "cmd": "/opt/portmaster/PortMaster.sh",      "icon": "🎮", "requires": {"paths": ["/opt/portmaster/PortMaster.sh"]}},
            {"label": "DOSBox-X",       "cmd": "dosbox-x /opt/ghost/dosbox/ghost.conf", "icon": "💾", "requires": {"commands": ["dosbox-x"]}},
            {"label": "Rockbox",        "cmd": "/opt/portmaster/ports/Rockbox/Rockbox.sh", "icon": "🎵", "requires": {"paths": ["/opt/portmaster/ports/Rockbox/Rockbox.sh"]}},
        ]
    },
    {
        "label": "TERMINAL",
        "icon": "⬛",
        "color": "green",
        "items": [
            {"label": "Fish Shell",     "cmd": "foot fish",                         "icon": "🐟"},
            {"label": "Tmux Session",   "cmd": "foot tmux new-session -A -s main",  "icon": "📺"},
            {"label": "btop",           "cmd": "foot btop",                         "icon": "📊"},
            {"label": "Ranger Files",   "cmd": "foot ranger",                       "icon": "📁"},
            {"label": "micro Editor",   "cmd": "foot micro",                        "icon": "✏️"},
        ]
    },
    {
        "label": "DISPLAY",
        "icon": "🖥️",
        "color": "blue",
        "items": [
            {"label": "List outputs",   "cmd": "foot display list",                  "icon": "📋"},
            {"label": "Mirror HDMI",    "cmd": "foot display mirror",                "icon": "📺"},
            {"label": "Extend HDMI",    "cmd": "foot display extend",               "icon": "↔️"},
            {"label": "HDMI only",      "cmd": "foot display hdmi-only",            "icon": "🖥️"},
            {"label": "Internal only",  "cmd": "foot display internal",             "icon": "📱"},
            {"label": "Displays off",   "cmd": "display off",                       "icon": "⭕"},
            {"label": "Displays on",    "cmd": "display on",                        "icon": "✅"},
        ]
    },
    {
        "label": "ANDROID",
        "icon": "🤖",
        "color": "green",
        "items": [
            {"label": "ADB shell",      "cmd": "foot adb shell",                     "icon": "📱"},
            {"label": "ADB devices",    "cmd": "foot adb devices",                   "icon": "🔍"},
            {"label": "scrcpy mirror",  "cmd": "scrcpy",                             "icon": "🖥️", "requires": {"commands": ["scrcpy"]}},
            {"label": "fastboot",       "cmd": "foot fastboot devices",              "icon": "⚡"},
            {"label": "androguard",     "cmd": "foot python3 -c 'import androguard; help()'", "icon": "🔬"},
            {"label": "apkleaks",       "cmd": "foot apkleaks",                      "icon": "🔑"},
        ]
    },
    {
        "label": "CAMERA",
        "icon": "📷",
        "color": "peach",
        "items": [
            {"label": "v4l2 list",      "cmd": "foot v4l2-ctl --list-devices",       "icon": "📋"},
            {"label": "fswebcam snap",  "cmd": "foot fswebcam -r 1280x720 ~/snap.jpg && imv ~/snap.jpg", "icon": "📸"},
            {"label": "ffmpeg stream",  "cmd": "foot ffmpeg -f v4l2 -i /dev/video0 -vframes 1 ~/frame.jpg", "icon": "🎬"},
            {"label": "Kinect v1",      "cmd": "foot freenect-glview",               "icon": "🌊"},
            {"label": "Kinect v2",      "cmd": "foot Protonect",                     "icon": "🌊"},
            {"label": "motion detect",  "cmd": "foot sudo motion",                   "icon": "🎯"},
        ]
    },
    {
        "label": "COMMS",
        "icon": "💬",
        "color": "teal",
        "items": [
            {"label": "aerc email",     "cmd": "foot aerc",                          "icon": "📧"},
            {"label": "irssi IRC",      "cmd": "foot irssi",                         "icon": "💬"},
            {"label": "DeltaChat",      "cmd": "foot deltachat",                     "icon": "✉️"},
            {"label": "newsboat RSS",   "cmd": "foot newsboat",                      "icon": "📰"},
        ]
    },
    {
        "label": "POWER",
        "icon": "⚡",
        "color": "yellow",
        "items": [
            {"label": "Power menu",     "cmd": "foot ghost-power",               "icon": "⚡"},
            {"label": "Performance",    "cmd": "ghost-power performance",        "icon": "🚀"},
            {"label": "Balanced",       "cmd": "ghost-power balanced",           "icon": "⚖️"},
            {"label": "Power save",     "cmd": "ghost-power powersave",          "icon": "🔋"},
            {"label": "Max performance","cmd": "ghost-power gaming",             "icon": "🎮"},
            {"label": "SDR mode",       "cmd": "ghost-power sdr",               "icon": "📡"},
            {"label": "Battery status", "cmd": "foot ghost-battery status",      "icon": "🔋"},
            {"label": "Charge limit",   "cmd": "foot ghost-battery limit 80",    "icon": "⚙️"},
        ]
    },
    {
        "label": "THEMES",
        "icon": "🎨",
        "color": "mauve",
        "items": [
            {"label": "Theme menu",     "cmd": "foot ghost-theme",               "icon": "🎨"},
            {"label": "Catppuccin",     "cmd": "ghost-theme catppuccin",         "icon": "🌙"},
            {"label": "Cybersec",       "cmd": "ghost-theme cybersec",           "icon": "💚"},
            {"label": "Kali",           "cmd": "ghost-theme kali",               "icon": "🔵"},
            {"label": "BlackArch",      "cmd": "ghost-theme blackarch",          "icon": "🔴"},
            {"label": "ParrotOS",       "cmd": "ghost-theme parrot",             "icon": "🦜"},
            {"label": "DragonOS",       "cmd": "ghost-theme dragonos",           "icon": "🐉"},
            {"label": "SteamOS",        "cmd": "ghost-theme steamos",            "icon": "🎮"},
            {"label": "ghOSt Stealth",  "cmd": "ghost-theme ghost",              "icon": "👻"},
        ]
    },
    {
        "label": "SYSTEM",
        "icon": "⚙️",
        "color": "subtext",
        "items": [
            {"label": "nmtui (WiFi)",   "cmd": "foot nmtui",                         "icon": "📶"},
            {"label": "SSH keys",       "cmd": "foot fish -C 'cat ~/.ssh/id_ed25519.pub | qrencode -t UTF8'", "icon": "🔑"},
            {"label": "Syncthing",      "cmd": "netsurf-gtk http://localhost:8384",   "icon": "🔄"},
            {"label": "Power off",      "cmd": "sudo poweroff",                      "icon": "⭕"},
            {"label": "Reboot",         "cmd": "sudo reboot",                        "icon": "🔁"},
        ]
    },
]

# =============================================================================
# LAUNCHER CLASS
# =============================================================================
class GhOStLauncher:
    def __init__(self):
        sdl2.SDL_Init(sdl2.SDL_INIT_VIDEO | sdl2.SDL_INIT_JOYSTICK |
                      sdl2.SDL_INIT_GAMECONTROLLER | sdl2.SDL_INIT_AUDIO)
        ttf.TTF_Init()

        self.window = sdl2.SDL_CreateWindow(
            b"ghOSt",
            sdl2.SDL_WINDOWPOS_CENTERED, sdl2.SDL_WINDOWPOS_CENTERED,
            SCREEN_W, SCREEN_H,
            sdl2.SDL_WINDOW_SHOWN | sdl2.SDL_WINDOW_FULLSCREEN_DESKTOP
        )
        self.renderer = sdl2.SDL_CreateRenderer(
            self.window, -1,
            sdl2.SDL_RENDERER_ACCELERATED | sdl2.SDL_RENDERER_PRESENTVSYNC
        )

        # Try to load a good font, fall back to built-in
        self.font_large = self._load_font(18)
        self.font_medium = self._load_font(14)
        self.font_small = self._load_font(11)

        self.menu = self._build_menu()
        if not self.menu:
            self.menu = [{
                "label": "TERMINAL",
                "icon": "⬛",
                "color": "green",
                "items": [{"label": "Fish Shell", "cmd": "foot fish", "icon": "🐟"}],
            }]

        self.cat_idx = self._default_category_index()  # Selected category
        self.item_idx = 0         # Selected item in category
        self.mode = "categories"  # "categories" or "items"
        self.status_msg = ""
        self.status_time = 0

        # Battery & status
        self.battery_pct = self._read_battery()
        self.battery_timer = 0

        # Button state for stealth combo detection
        self.btn_state = set()
        self.stealth_hold_start = 0

        self.running = True

        # Wallpaper texture (SHODAN)
        self.wallpaper = self._load_wallpaper()

    def _item_available(self, item):
        """Keep optional UI entries honest by hiding tools that were not built."""
        requirements = item.get("requires", {})
        for path in requirements.get("paths", []):
            if not Path(path).exists():
                return False
        for command in requirements.get("commands", []):
            if shutil.which(command) is None:
                return False
        return True

    def _build_menu(self):
        """Drop categories and entries for optional components that are absent."""
        filtered_menu = []
        for category in MENU_TEMPLATE:
            items = [item for item in category["items"] if self._item_available(item)]
            if not items:
                continue
            filtered_menu.append({
                "label": category["label"],
                "icon": category["icon"],
                "color": category["color"],
                "items": items,
            })
        return filtered_menu

    def _default_category_index(self):
        """Open on the security workflow first instead of on general-purpose tools."""
        preferred_labels = ["SIGNAL INT", "RECON", "WIRELESS", "TOOLS", "PRIVACY", "TERMINAL"]
        for label in preferred_labels:
            for index, category in enumerate(self.menu):
                if category["label"] == label:
                    return index
        return 0

    def _load_wallpaper(self):
        """Load wallpaper PNG as SDL texture. Regenerate if missing."""
        WALL_PATH = "/opt/ghost/launcher/wallpaper.png"
        GEN_PATH  = "/opt/ghost/themes/generate-wallpaper.py"
        import os as _os
        # Generate if missing
        if not _os.path.exists(WALL_PATH) and _os.path.exists(GEN_PATH):
            try:
                import subprocess as _sp
                _sp.run(["python3", GEN_PATH, WALL_PATH, "cybersec"],
                        capture_output=True, timeout=20)
            except Exception:
                pass
        if not _os.path.exists(WALL_PATH):
            return None
        try:
            img.IMG_Init(img.IMG_INIT_PNG)
            surface = img.IMG_Load(WALL_PATH.encode())
            if not surface:
                return None
            texture = sdl2.SDL_CreateTextureFromSurface(self.renderer, surface)
            sdl2.SDL_FreeSurface(surface)
            # Semi-transparent overlay: multiply alpha for menu readability
            sdl2.SDL_SetTextureAlphaMod(texture, 210)
            return texture
        except Exception:
            return None

    def _load_font(self, size):
        fonts = [
            "/usr/share/fonts/X11/misc/ter-x14b.pcf.gz",
            "/usr/share/fonts/truetype/terminus/TerminusTTF-Bold.ttf",
            "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf",
            "/usr/share/fonts/truetype/liberation/LiberationMono-Bold.ttf",
        ]
        for f in fonts:
            if Path(f).exists():
                font = ttf.TTF_OpenFont(f.encode(), size)
                if font:
                    return font
        return None

    def _read_battery(self):
        paths = [
            "/sys/class/power_supply/axp20x-battery/capacity",
            "/sys/class/power_supply/BAT0/capacity",
        ]
        for p in paths:
            try:
                return int(Path(p).read_text().strip())
            except:
                pass
        return -1

    def _color(self, name):
        c = COLORS.get(name, COLORS["text"])
        return sdl2.SDL_Color(c[0], c[1], c[2], c[3])

    def _set_color(self, name):
        c = COLORS.get(name, COLORS["text"])
        sdl2.SDL_SetRenderDrawColor(self.renderer, c[0], c[1], c[2], c[3])

    def _render_text(self, text, font, color_name, x, y):
        if not font:
            return
        surface = ttf.TTF_RenderUTF8_Blended(
            font, text.encode('utf-8', errors='replace'),
            self._color(color_name)
        )
        if not surface:
            return
        texture = sdl2.SDL_CreateTextureFromSurface(self.renderer, surface)
        sdl2.SDL_FreeSurface(surface)
        if not texture:
            return
        w, h = ctypes.c_int(), ctypes.c_int()
        sdl2.SDL_QueryTexture(texture, None, None, ctypes.byref(w), ctypes.byref(h))
        dst = sdl2.SDL_Rect(x, y, w.value, h.value)
        sdl2.SDL_RenderCopy(self.renderer, texture, None, dst)
        sdl2.SDL_DestroyTexture(texture)
        return w.value, h.value

    def _fill_rect(self, x, y, w, h, color_name, alpha=255):
        c = COLORS.get(color_name, COLORS["surface0"])
        sdl2.SDL_SetRenderDrawBlendMode(self.renderer, sdl2.SDL_BLENDMODE_BLEND)
        sdl2.SDL_SetRenderDrawColor(self.renderer, c[0], c[1], c[2], alpha)
        rect = sdl2.SDL_Rect(x, y, w, h)
        sdl2.SDL_RenderFillRect(self.renderer, rect)

    def draw_status_bar(self):
        """Top status bar: hostname, battery, time"""
        self._fill_rect(0, 0, SCREEN_W, 24, "surface0")

        import datetime
        now = datetime.datetime.now().strftime("%H:%M")

        # Left: hostname
        self._render_text(" ghOSt", self.font_small, "blue", 4, 5)

        # Center: status message
        if self.status_msg and time.time() - self.status_time < 3:
            self._render_text(self.status_msg, self.font_small, "green",
                              SCREEN_W // 2 - 80, 5)

        # Right: battery + time
        bat_str = f"🔋{self.battery_pct}%  {now} " if self.battery_pct >= 0 else f" {now} "
        bat_color = "green" if self.battery_pct > 30 else "yellow" if self.battery_pct > 15 else "red"
        self._render_text(bat_str, self.font_small, bat_color,
                          SCREEN_W - len(bat_str) * 8 - 4, 5)

    def draw_categories(self):
        """Left sidebar: category list"""
        sidebar_w = 150

        # Background
        self._fill_rect(0, 24, sidebar_w, SCREEN_H - 48, "surface0")

        for i, cat in enumerate(self.menu):
            y = 24 + i * 40
            is_selected = (i == self.cat_idx)

            if is_selected:
                self._fill_rect(0, y, sidebar_w, 40, "surface1")
                # Left accent bar
                self._fill_rect(0, y, 3, 40, cat.get("color", "blue"))

            color = cat.get("color", "blue") if is_selected else "subtext"
            label = f" {cat['icon']} {cat['label']}"
            self._render_text(label, self.font_small, color, 8, y + 13)

    def draw_items(self):
        """Right panel: items in selected category"""
        cat = self.menu[self.cat_idx]
        panel_x = 155
        panel_w = SCREEN_W - panel_x

        # Category header
        self._fill_rect(panel_x, 24, panel_w, 36, "surface1")
        header = f" {cat['icon']}  {cat['label']}"
        self._render_text(header, self.font_large,
                          cat.get("color", "blue"), panel_x + 8, 30)

        # Items
        for i, item in enumerate(cat["items"]):
            y = 64 + i * 46
            is_selected = (i == self.item_idx) and self.mode == "items"

            if is_selected:
                self._fill_rect(panel_x, y - 2, panel_w - 4, 44,
                                "surface1")
                self._fill_rect(panel_x, y - 2, 3, 44,
                                cat.get("color", "blue"))

            label_color = "text" if is_selected else "subtext"
            icon_color = cat.get("color", "blue") if is_selected else "overlay"

            self._render_text(f" {item['icon']}", self.font_medium,
                              icon_color, panel_x + 8, y + 4)
            self._render_text(item["label"], self.font_medium,
                              label_color, panel_x + 36, y + 4)

            # Show command hint if selected
            if is_selected:
                cmd_preview = item["cmd"][:50] + "..." if len(item["cmd"]) > 50 else item["cmd"]
                self._render_text(f"  {cmd_preview}", self.font_small,
                                  "overlay", panel_x + 8, y + 24)

    def draw_button_hints(self):
        """Bottom bar: button hints"""
        self._fill_rect(0, SCREEN_H - 24, SCREEN_W, 24, "surface0")

        hints = " [A] Launch  [B] Back  [D-pad] Navigate  [Start] Terminal  [Select+Start+L2] Stealth"
        self._render_text(hints, self.font_small, "overlay", 4, SCREEN_H - 18)

    def draw(self):
        # Clear with bg color
        c = COLORS["bg"]
        sdl2.SDL_SetRenderDrawColor(self.renderer, c[0], c[1], c[2], 255)
        sdl2.SDL_RenderClear(self.renderer)

        # Blit wallpaper
        if self.wallpaper:
            dst = sdl2.SDL_Rect(0, 0, SCREEN_W, SCREEN_H)
            sdl2.SDL_RenderCopy(self.renderer, self.wallpaper, None, dst)
            # Dark overlay so UI text stays readable
            sdl2.SDL_SetRenderDrawBlendMode(self.renderer, sdl2.SDL_BLENDMODE_BLEND)
            sdl2.SDL_SetRenderDrawColor(self.renderer, 0, 0, 0, 140)
            sdl2.SDL_RenderFillRect(self.renderer, dst)
            sdl2.SDL_SetRenderDrawBlendMode(self.renderer, sdl2.SDL_BLENDMODE_NONE)

        self.draw_status_bar()
        self.draw_categories()
        self.draw_items()
        self.draw_button_hints()

        sdl2.SDL_RenderPresent(self.renderer)

    def launch(self, cmd):
        """Launch application"""
        self.status_msg = f"Launching..."
        self.status_time = time.time()
        threading.Thread(
            target=subprocess.run,
            args=(["/bin/fish", "-c", cmd],),
            kwargs={"env": {**os.environ}},
            daemon=True
        ).start()

    def enter_stealth(self):
        """Activate stealth mode via stealthd"""
        subprocess.Popen(["python3", "/opt/ghost/stealthd/stealthd.py", "--activate"])

    def handle_button(self, btn, pressed):
        """Handle gamepad button events"""
        # Button mappings for RG35XXH
        # These evdev codes are device-specific
        BTN_A      = 304  # Cross/A
        BTN_B      = 305  # Circle/B
        BTN_X      = 307
        BTN_Y      = 308
        BTN_START  = 315
        BTN_SELECT = 314
        BTN_L1     = 310
        BTN_L2     = 312
        BTN_R1     = 311
        BTN_R2     = 313
        DPAD_UP    = sdl2.SDL_CONTROLLER_BUTTON_DPAD_UP
        DPAD_DOWN  = sdl2.SDL_CONTROLLER_BUTTON_DPAD_DOWN
        DPAD_LEFT  = sdl2.SDL_CONTROLLER_BUTTON_DPAD_LEFT
        DPAD_RIGHT = sdl2.SDL_CONTROLLER_BUTTON_DPAD_RIGHT

        if pressed:
            self.btn_state.add(btn)
        else:
            self.btn_state.discard(btn)

        # Stealth combo: SELECT + START + L2
        stealth_combo = {BTN_SELECT, BTN_START, BTN_L2}
        if stealth_combo.issubset(self.btn_state):
            if self.stealth_hold_start == 0:
                self.stealth_hold_start = time.time()
            elif time.time() - self.stealth_hold_start >= 3:
                self.enter_stealth()
                self.stealth_hold_start = 0
                return
        else:
            self.stealth_hold_start = 0

        if not pressed:
            return

        # Navigation
        if btn in (sdl2.SDL_CONTROLLER_BUTTON_DPAD_UP,):
            if self.mode == "categories":
                self.cat_idx = (self.cat_idx - 1) % len(self.menu)
                self.item_idx = 0
            else:
                items = self.menu[self.cat_idx]["items"]
                self.item_idx = (self.item_idx - 1) % len(items)

        elif btn in (sdl2.SDL_CONTROLLER_BUTTON_DPAD_DOWN,):
            if self.mode == "categories":
                self.cat_idx = (self.cat_idx + 1) % len(self.menu)
                self.item_idx = 0
            else:
                items = self.menu[self.cat_idx]["items"]
                self.item_idx = (self.item_idx + 1) % len(items)

        elif btn in (sdl2.SDL_CONTROLLER_BUTTON_DPAD_RIGHT,
                     sdl2.SDL_CONTROLLER_BUTTON_A):
            if self.mode == "categories":
                self.mode = "items"
                self.item_idx = 0
            else:
                # Launch selected item
                item = self.menu[self.cat_idx]["items"][self.item_idx]
                self.launch(item["cmd"])

        elif btn in (sdl2.SDL_CONTROLLER_BUTTON_DPAD_LEFT,
                     sdl2.SDL_CONTROLLER_BUTTON_B):
            self.mode = "categories"

        elif btn == sdl2.SDL_CONTROLLER_BUTTON_START:
            # Direct terminal launch
            self.launch("foot fish")

    def handle_events(self):
        event = sdl2.SDL_Event()
        while sdl2.SDL_PollEvent(ctypes.byref(event)):
            if event.type == sdl2.SDL_QUIT:
                self.running = False

            elif event.type == sdl2.SDL_CONTROLLERBUTTONDOWN:
                self.handle_button(event.cbutton.button, True)

            elif event.type == sdl2.SDL_CONTROLLERBUTTONUP:
                self.handle_button(event.cbutton.button, False)

            elif event.type == sdl2.SDL_KEYDOWN:
                # Keyboard support (USB/BT keyboard)
                k = event.key.keysym.sym
                if k == sdl2.SDLK_UP:
                    self.handle_button(sdl2.SDL_CONTROLLER_BUTTON_DPAD_UP, True)
                elif k == sdl2.SDLK_DOWN:
                    self.handle_button(sdl2.SDL_CONTROLLER_BUTTON_DPAD_DOWN, True)
                elif k == sdl2.SDLK_RIGHT:
                    self.handle_button(sdl2.SDL_CONTROLLER_BUTTON_DPAD_RIGHT, True)
                elif k == sdl2.SDLK_LEFT:
                    self.handle_button(sdl2.SDL_CONTROLLER_BUTTON_DPAD_LEFT, True)
                elif k in (sdl2.SDLK_RETURN, sdl2.SDLK_KP_ENTER):
                    self.handle_button(sdl2.SDL_CONTROLLER_BUTTON_A, True)
                elif k == sdl2.SDLK_ESCAPE:
                    self.handle_button(sdl2.SDL_CONTROLLER_BUTTON_B, True)
                elif k == sdl2.SDLK_t:
                    self.launch("foot fish")

    def run(self):
        # Open first gamepad
        if sdl2.SDL_NumJoysticks() > 0:
            controller = sdl2.SDL_GameControllerOpen(0)

        clock_start = sdl2.SDL_GetTicks()

        while self.running:
            self.handle_events()

            # Update battery every 60s
            self.battery_timer += 1
            if self.battery_timer >= FPS * 60:
                self.battery_pct = self._read_battery()
                self.battery_timer = 0

            self.draw()

            # Cap at FPS
            elapsed = sdl2.SDL_GetTicks() - clock_start
            delay = max(0, (1000 // FPS) - elapsed)
            sdl2.SDL_Delay(delay)
            clock_start = sdl2.SDL_GetTicks()

        self.cleanup()

    def cleanup(self):
        if self.font_large: ttf.TTF_CloseFont(self.font_large)
        if self.font_medium: ttf.TTF_CloseFont(self.font_medium)
        if self.font_small: ttf.TTF_CloseFont(self.font_small)
        sdl2.SDL_DestroyRenderer(self.renderer)
        sdl2.SDL_DestroyWindow(self.window)
        ttf.TTF_Quit()
        sdl2.SDL_Quit()


if __name__ == "__main__":
    launcher = GhOStLauncher()
    _launcher_instance = launcher  # expose for SIGUSR1 handler
    signal.signal(signal.SIGTERM, lambda *_: setattr(launcher, 'running', False))
    launcher.run()

# Theme reload signal handler (called by ghost-theme after applying)
import signal as _signal
import json as _json
from pathlib import Path as _Path

_launcher_instance = None  # Set by GhOStLauncher.__init__

def _reload_theme(signum, frame):
    """Called via SIGUSR1 when ghost-theme applies a new theme"""
    theme_file = _Path("/opt/ghost/launcher/theme.json")
    if theme_file.exists():
        try:
            theme = _json.loads(theme_file.read_text())
            global COLORS
            COLORS = {k: tuple(v[:3]) for k, v in theme.items()
                      if isinstance(v, list) and len(v) >= 3}
        except Exception:
            pass
    # Reload wallpaper (theme change regenerates it)
    global _launcher_instance
    if _launcher_instance:
        try:
            if _launcher_instance.wallpaper:
                import sdl2 as _sdl2
                _sdl2.SDL_DestroyTexture(_launcher_instance.wallpaper)
            _launcher_instance.wallpaper = _launcher_instance._load_wallpaper()
        except Exception:
            pass

_signal.signal(_signal.SIGUSR1, _reload_theme)
