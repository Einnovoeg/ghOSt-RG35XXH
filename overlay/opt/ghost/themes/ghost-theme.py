#!/usr/bin/env python3
"""
ghOSt-RG35XXH Theme Manager
Applies complete visual themes across:
  foot terminal, tmux, btop, mako notifications,
  swaylock, fish prompt, launcher, neofetch

Themes:
  catppuccin   — default, Catppuccin Mocha (dark purple)
  cybersec     — Matrix green on black
  kali         — Kali Linux official (black/blue/white)
  blackarch    — BlackArch (dark, red accents)
  parrot       — ParrotOS (teal/cyan)
  dragonos     — DragonOS (orange/dark)
  steamos      — SteamOS (blue gradient)
  ghost        — ghOSt stealth (near-black, minimal)
"""

import os
import sys
import json
import shutil
import subprocess
from pathlib import Path
from dataclasses import dataclass, field

HOME = Path(os.path.expanduser("~"))
CONFIG = HOME / ".config"
GHOST_DIR = Path("/opt/ghost")
THEME_STATE = HOME / ".config/ghost/current_theme"

# =============================================================================
# THEME DEFINITIONS
# All colors in hex without #
# =============================================================================
@dataclass
class Theme:
    name: str
    label: str
    description: str

    # Terminal palette (16 colors)
    bg:          str = "1e1e2e"
    fg:          str = "cdd6f4"
    # Cursor
    cursor:      str = "f5e0dc"
    # Selection
    selection:   str = "585b70"
    # Normal colors
    black:       str = "45475a"
    red:         str = "f38ba8"
    green:       str = "a6e3a1"
    yellow:      str = "f9e2af"
    blue:        str = "89b4fa"
    magenta:     str = "f5c2e7"
    cyan:        str = "94e2d5"
    white:       str = "bac2de"
    # Bright colors
    br_black:    str = "585b70"
    br_red:      str = "f38ba8"
    br_green:    str = "a6e3a1"
    br_yellow:   str = "f9e2af"
    br_blue:     str = "89b4fa"
    br_magenta:  str = "f5c2e7"
    br_cyan:     str = "94e2d5"
    br_white:    str = "a6adc8"

    # UI accent colors
    accent:      str = "89b4fa"   # Primary accent (borders, highlights)
    accent2:     str = "cba6f7"   # Secondary accent
    warning:     str = "f9e2af"   # Warning color
    error:       str = "f38ba8"   # Error color
    success:     str = "a6e3a1"   # Success color

    # Transparency (0.0-1.0)
    alpha:       float = 0.95

    # tmux status bar style
    tmux_left:   str = "ghOSt"
    tmux_status_bg: str = "1e1e2e"

    # btop color theme name (must match a btop theme file)
    btop_theme:  str = "catppuccin_mocha"

    # Fish prompt tide colors
    tide_prompt_color: str = "89b4fa"

    # Launcher-specific
    launcher_bg:      str = "1e1e2e"
    launcher_surface: str = "313244"
    launcher_text:    str = "cdd6f4"
    launcher_accent:  str = "89b4fa"


THEMES = {
    "catppuccin": Theme(
        name="catppuccin", label="Catppuccin Mocha",
        description="Default — warm dark purple",
        bg="1e1e2e", fg="cdd6f4", cursor="f5e0dc",
        black="45475a", red="f38ba8", green="a6e3a1",
        yellow="f9e2af", blue="89b4fa", magenta="f5c2e7",
        cyan="94e2d5", white="bac2de",
        br_black="585b70", br_red="f38ba8", br_green="a6e3a1",
        br_yellow="f9e2af", br_blue="89b4fa", br_magenta="f5c2e7",
        br_cyan="94e2d5", br_white="a6adc8",
        accent="89b4fa", accent2="cba6f7",
        btop_theme="catppuccin_mocha",
    ),

    "cybersec": Theme(
        name="cybersec", label="Cybersecurity",
        description="Matrix green — classic hacker aesthetic",
        bg="000000", fg="00ff41", cursor="00ff41",
        selection="003300",
        black="000000", red="cc0000", green="00ff41",
        yellow="ffff00", blue="0088ff", magenta="ff00ff",
        cyan="00ffff", white="cccccc",
        br_black="333333", br_red="ff0000", br_green="00ff41",
        br_yellow="ffff00", br_blue="4488ff", br_magenta="ff44ff",
        br_cyan="44ffff", br_white="ffffff",
        accent="00ff41", accent2="00cc33",
        warning="ffff00", error="ff0000", success="00ff41",
        alpha=0.92,
        btop_theme="matrix",
        tmux_left="ghOSt",
        tmux_status_bg="001100",
        tide_prompt_color="00ff41",
        launcher_bg="000000", launcher_surface="001100",
        launcher_text="00ff41", launcher_accent="00cc33",
    ),

    "kali": Theme(
        name="kali", label="Kali Linux",
        description="Official Kali Linux color scheme",
        bg="1a1a2e", fg="e0e0e0", cursor="557cff",
        selection="2d2d4e",
        black="1a1a2e", red="e95678", green="29d398",
        yellow="fab795", blue="557cff", magenta="b877db",
        cyan="59e3e3", white="e0e0e0",
        br_black="2d2d4e", br_red="ec6a88", br_green="3fdaa4",
        br_yellow="fbc3a7", br_blue="6e91ff", br_magenta="c488e8",
        br_cyan="6bebe4", br_white="ffffff",
        accent="557cff", accent2="b877db",
        warning="fab795", error="e95678", success="29d398",
        btop_theme="kali",
        tmux_status_bg="1a1a2e",
        tide_prompt_color="557cff",
        launcher_bg="1a1a2e", launcher_surface="2d2d4e",
        launcher_text="e0e0e0", launcher_accent="557cff",
    ),

    "blackarch": Theme(
        name="blackarch", label="BlackArch",
        description="BlackArch Linux — dark with red accents",
        bg="0d0d0d", fg="d4d4d4", cursor="cc0000",
        selection="1a0000",
        black="0d0d0d", red="cc0000", green="4e9a06",
        yellow="c4a000", blue="3465a4", magenta="75507b",
        cyan="06989a", white="d3d7cf",
        br_black="555753", br_red="ff0000", br_green="8ae234",
        br_yellow="fce94f", br_blue="729fcf", br_magenta="ad7fa8",
        br_cyan="34e2e2", br_white="eeeeec",
        accent="cc0000", accent2="ff4444",
        warning="c4a000", error="ff0000", success="4e9a06",
        alpha=0.97,
        btop_theme="blackarch",
        tmux_status_bg="0d0d0d",
        tide_prompt_color="cc0000",
        launcher_bg="0d0d0d", launcher_surface="1a0000",
        launcher_text="d4d4d4", launcher_accent="cc0000",
    ),

    "parrot": Theme(
        name="parrot", label="ParrotOS",
        description="ParrotOS — teal and cyan",
        bg="1b2229", fg="dfdfdf", cursor="00b4d8",
        selection="2d3748",
        black="1b2229", red="e06c75", green="00b4d8",
        yellow="e5c07b", blue="0077b6", magenta="c678dd",
        cyan="56b6c2", white="abb2bf",
        br_black="2d3748", br_red="e06c75", br_green="00d4f8",
        br_yellow="e5c07b", br_blue="0096c7", br_magenta="c678dd",
        br_cyan="56d4e2", br_white="dfdfdf",
        accent="00b4d8", accent2="0077b6",
        warning="e5c07b", error="e06c75", success="00b4d8",
        btop_theme="parrot",
        tmux_status_bg="1b2229",
        tide_prompt_color="00b4d8",
        launcher_bg="1b2229", launcher_surface="2d3748",
        launcher_text="dfdfdf", launcher_accent="00b4d8",
    ),

    "dragonos": Theme(
        name="dragonos", label="DragonOS",
        description="DragonOS — orange and dark for SDR work",
        bg="1c1c1c", fg="e8e8e8", cursor="ff6d00",
        selection="2c2200",
        black="1c1c1c", red="ff4444", green="76b041",
        yellow="ff6d00", blue="4488cc", magenta="cc44cc",
        cyan="44cccc", white="cccccc",
        br_black="444444", br_red="ff6666", br_green="88cc55",
        br_yellow="ff8c00", br_blue="66aaee", br_magenta="ee66ee",
        br_cyan="66eeee", br_white="eeeeee",
        accent="ff6d00", accent2="ff8c00",
        warning="ff6d00", error="ff4444", success="76b041",
        btop_theme="dracula",
        tmux_status_bg="1c1c1c",
        tide_prompt_color="ff6d00",
        launcher_bg="1c1c1c", launcher_surface="2c1a00",
        launcher_text="e8e8e8", launcher_accent="ff6d00",
    ),

    "steamos": Theme(
        name="steamos", label="SteamOS",
        description="Valve SteamOS — blue gradient",
        bg="1a1f2e", fg="c7d5e0", cursor="1b2838",
        selection="2a475e",
        black="1b2838", red="c94545", green="5ba85a",
        yellow="c7b56e", blue="4d8cc7", magenta="8b6dab",
        cyan="4d9c8c", white="c7d5e0",
        br_black="2a475e", br_red="e05c5c", br_green="6ec96d",
        br_yellow="d9c878", br_blue="66a8e0", br_magenta="a285c4",
        br_cyan="66b5a5", br_white="dce8f0",
        accent="4d8cc7", accent2="66a8e0",
        warning="c7b56e", error="c94545", success="5ba85a",
        btop_theme="steam",
        tmux_status_bg="1a1f2e",
        tide_prompt_color="4d8cc7",
        launcher_bg="1a1f2e", launcher_surface="2a475e",
        launcher_text="c7d5e0", launcher_accent="4d8cc7",
    ),

    "ghost": Theme(
        name="ghost", label="ghOSt Stealth",
        description="Near-black minimal — blend in anywhere",
        bg="0a0a0a", fg="888888", cursor="555555",
        selection="1a1a1a",
        black="0a0a0a", red="555555", green="555555",
        yellow="555555", blue="555555", magenta="555555",
        cyan="555555", white="888888",
        br_black="222222", br_red="666666", br_green="666666",
        br_yellow="666666", br_blue="666666", br_magenta="666666",
        br_cyan="666666", br_white="999999",
        accent="555555", accent2="444444",
        warning="666666", error="777777", success="555555",
        alpha=0.99,
        btop_theme="default",
        tmux_left="system",
        tmux_status_bg="0a0a0a",
        tide_prompt_color="555555",
        launcher_bg="0a0a0a", launcher_surface="111111",
        launcher_text="888888", launcher_accent="555555",
    ),
}

# =============================================================================
# THEME APPLICATION
# =============================================================================
class ThemeApplicator:

    def __init__(self, theme: Theme):
        self.t = theme

    def _hex(self, h):
        return h.lstrip('#')

    def apply_foot(self):
        """Update foot terminal colors"""
        foot_config = CONFIG / "foot" / "foot.ini"
        if not foot_config.exists():
            return

        t = self.t
        colors_section = f"""[colors]
background={t.bg}
foreground={t.fg}
regular0={t.black}
regular1={t.red}
regular2={t.green}
regular3={t.yellow}
regular4={t.blue}
regular5={t.magenta}
regular6={t.cyan}
regular7={t.white}
bright0={t.br_black}
bright1={t.br_red}
bright2={t.br_green}
bright3={t.br_yellow}
bright4={t.br_blue}
bright5={t.br_magenta}
bright6={t.br_cyan}
bright7={t.br_white}
alpha={t.alpha}
"""
        content = foot_config.read_text()
        # Replace existing colors section
        if "[colors]" in content:
            start = content.index("[colors]")
            # Find next section or end
            next_section = content.find("\n[", start + 1)
            if next_section == -1:
                content = content[:start] + colors_section
            else:
                content = content[:start] + colors_section + "\n" + content[next_section+1:]
        else:
            content += "\n" + colors_section

        foot_config.write_text(content)

    def apply_tmux(self):
        """Update tmux colors"""
        tmux_config = CONFIG / "tmux" / "tmux.conf"
        if not tmux_config.exists():
            return

        t = self.t
        new_colors = f"""
# Theme: {t.label}
set -g status-bg "#{t.tmux_status_bg}"
set -g status-fg "#{t.fg}"
set -g status-left "#[fg=#{t.accent},bold] {t.tmux_left} #[fg=#{t.br_black}]│ "
set -g status-right "#[fg=#{t.success}]{{battery_percentage}} #[fg=#{t.br_black}]│ #[fg=#{t.cyan}]%H:%M #[fg=#{t.br_black}]│ #[fg=#{t.accent2}]#h"
set -g window-status-current-format "#[fg=#{t.accent},bold] #I:#W "
set -g window-status-format "#[fg=#{t.br_black}] #I:#W "
set -g pane-border-style "fg=#{t.launcher_surface}"
set -g pane-active-border-style "fg=#{t.accent}"
set -g message-style "bg=#{t.tmux_status_bg},fg=#{t.fg}"
"""
        content = tmux_config.read_text()
        # Remove old theme block
        if "# Theme:" in content:
            start = content.index("# Theme:")
            content = content[:start]
        content += new_colors
        tmux_config.write_text(content)

    def apply_mako(self):
        """Update mako notification colors"""
        mako_config = CONFIG / "mako" / "config"
        mako_config.parent.mkdir(parents=True, exist_ok=True)
        t = self.t
        mako_config.write_text(f"""# ghOSt-RG35XXH mako — {t.label}
sort=-time
layer=overlay
background-color=#{t.bg}
text-color=#{t.fg}
border-color=#{t.accent}
border-radius=8
border-size=2
default-timeout=5000
max-visible=3
width=280
height=100
margin=8
padding=8
font=Terminus 11

[urgency=high]
border-color=#{t.error}
default-timeout=0
""")

    def apply_swaylock(self):
        """Update swaylock colors"""
        sl_config = CONFIG / "swaylock" / "config"
        sl_config.parent.mkdir(parents=True, exist_ok=True)
        t = self.t
        sl_config.write_text(f"""color={t.bg}
inside-color={t.bg}
ring-color={t.accent}
key-hl-color={t.success}
text-color={t.fg}
line-color={t.bg}
font=Terminus
indicator-radius=50
indicator-thickness=8
show-failed-attempts
""")

    def apply_btop(self):
        """Update btop theme setting"""
        btop_config = CONFIG / "btop" / "btop.conf"
        if not btop_config.exists():
            return
        content = btop_config.read_text()
        import re
        content = re.sub(
            r'^color_theme\s*=.*$',
            f'color_theme = "{self.t.btop_theme}"',
            content, flags=re.MULTILINE
        )
        btop_config.write_text(content)

    def apply_fish(self):
        """Update fish shell theme colors"""
        t = self.t
        theme_file = CONFIG / "fish" / "conf.d" / "ghost_theme.fish"
        theme_file.parent.mkdir(parents=True, exist_ok=True)
        theme_file.write_text(f"""# ghOSt-RG35XXH theme: {t.label}
# Applied by ghost-theme command

# Fish color variables
set -g fish_color_normal          {t.fg}
set -g fish_color_command         {t.accent}
set -g fish_color_keyword         {t.accent}
set -g fish_color_quote           {t.green}
set -g fish_color_redirection     {t.cyan}
set -g fish_color_end             {t.accent2}
set -g fish_color_error           {t.error}
set -g fish_color_param           {t.fg}
set -g fish_color_comment         {t.br_black}
set -g fish_color_selection       --background={t.selection}
set -g fish_color_search_match    --background={t.selection}
set -g fish_color_operator        {t.accent}
set -g fish_color_escape          {t.magenta}
set -g fish_color_autosuggestion  {t.br_black}
set -g fish_pager_color_progress  {t.accent}
set -g fish_pager_color_prefix    {t.accent}
set -g fish_pager_color_completion {t.fg}
set -g fish_pager_color_description {t.br_black}

# Tide prompt colors
set -g tide_pwd_color_anchors     {t.accent}
set -g tide_pwd_color_dirs        {t.accent}
set -g tide_pwd_color_truncated_dirs {t.br_black}
set -g tide_git_color_branch      {t.success}
set -g tide_git_color_conflicted  {t.error}
set -g tide_git_color_dirty       {t.warning}
set -g tide_git_color_staged      {t.yellow}
set -g tide_git_color_untracked   {t.cyan}
set -g tide_cmd_duration_color    {t.br_black}
set -g tide_status_color          {t.success}
set -g tide_status_color_failure  {t.error}
set -g tide_battery_color_charging {t.success}
set -g tide_battery_color_discharging {t.warning}
set -g tide_battery_color_critical {t.error}

# Current theme name
set -gx GHOST_THEME "{t.name}"
""")

    def apply_launcher_theme(self):
        """Write launcher theme config"""
        t = self.t
        theme_json = Path("/opt/ghost/launcher/theme.json")
        theme_json.parent.mkdir(parents=True, exist_ok=True)
        # Convert hex to RGB tuples for SDL2
        def h2rgb(h):
            h = h.lstrip('#')
            return [int(h[i:i+2], 16) for i in (0, 2, 4)] + [255]

        theme_data = {
            "name": t.name,
            "label": t.label,
            "bg":        h2rgb(t.launcher_bg),
            "surface0":  h2rgb(t.launcher_surface),
            "surface1":  h2rgb(t.selection),
            "text":      h2rgb(t.launcher_text),
            "subtext":   h2rgb(t.br_black),
            "accent":    h2rgb(t.launcher_accent),
            "accent2":   h2rgb(t.accent2),
            "green":     h2rgb(t.green),
            "red":       h2rgb(t.red),
            "yellow":    h2rgb(t.yellow),
            "blue":      h2rgb(t.blue),
            "mauve":     h2rgb(t.magenta),
            "teal":      h2rgb(t.cyan),
            "pink":      h2rgb(t.magenta),
            "peach":     h2rgb(t.yellow),
            "overlay":   h2rgb(t.br_black),
        }
        theme_json.write_text(json.dumps(theme_data, indent=2))

    def apply_all(self):
        """Apply theme to all components"""
        self.apply_foot()
        self.apply_tmux()
        self.apply_mako()
        self.apply_swaylock()
        self.apply_btop()
        self.apply_fish()
        self.apply_launcher_theme()

        # Save current theme name
        THEME_STATE.parent.mkdir(parents=True, exist_ok=True)
        THEME_STATE.write_text(self.t.name)

        # Reload running processes
        self.apply_wallpaper()
        self._reload_live()
        print(f"✓ Theme applied: {self.t.label}")

    def _reload_live(self):
        """Reload running apps to pick up new theme without restart"""
        # Reload foot via signal (new windows get new colors automatically)
        # Reload tmux
        try:
            subprocess.run(
                ["tmux", "source-file", str(CONFIG / "tmux" / "tmux.conf")],
                capture_output=True, timeout=3
            )
        except Exception:
            pass

    def apply_wallpaper(self):
        """Regenerate the launcher wallpaper for the active theme."""
        wallpaper_gen = Path("/opt/ghost/themes/generate-wallpaper.py")
        wallpaper_out = Path("/opt/ghost/launcher/wallpaper.png")

        if wallpaper_gen.exists():
            try:
                subprocess.run(
                    ["python3", str(wallpaper_gen), str(wallpaper_out), self.t.name],
                    capture_output=True,
                    timeout=30,
                    check=False,
                )
                print(f"✓ Wallpaper regenerated for {self.t.label}")
            except Exception as exc:
                print(f"  wallpaper regen skipped: {exc}")
        # Reload mako
        try:
            subprocess.run(["makoctl", "reload"], capture_output=True, timeout=3)
        except Exception:
            pass
        # Reload fish theme in running shells via universal variable
        try:
            subprocess.run(
                ["fish", "-c", f"set -Ux GHOST_THEME {self.t.name}"],
                capture_output=True, timeout=3
            )
        except Exception:
            pass
        # Signal launcher to reload theme
        try:
            result = subprocess.run(
                ["pgrep", "-f", "launcher.py"],
                capture_output=True, text=True
            )
            if result.stdout.strip():
                pid = int(result.stdout.strip().split()[0])
                os.kill(pid, 10)  # SIGUSR1 — launcher watches for this
        except Exception:
            pass


# =============================================================================
# CLI INTERFACE
# =============================================================================
def show_menu():
    """Interactive theme picker for terminal use"""
    current = THEME_STATE.read_text().strip() if THEME_STATE.exists() else "catppuccin"

    print("\n\033[0;36m ghOSt-RG35XXH Theme Manager\033[0m\n")
    for i, (key, theme) in enumerate(THEMES.items(), 1):
        marker = "\033[0;32m▶\033[0m" if key == current else " "
        print(f"  {marker} [{i}] \033[0;1m{theme.label}\033[0m")
        print(f"       {theme.description}")
    print(f"\n  [0] Cancel\n")

    try:
        choice = input("Select theme: ").strip()
        if choice == "0":
            return
        idx = int(choice) - 1
        key = list(THEMES.keys())[idx]
        theme = THEMES[key]
        print(f"\nApplying \033[0;1m{theme.label}\033[0m...")
        ThemeApplicator(theme).apply_all()
    except (ValueError, IndexError, KeyboardInterrupt):
        print("Cancelled")


def main():
    if len(sys.argv) < 2:
        show_menu()
        return

    cmd = sys.argv[1]

    if cmd == "list":
        current = THEME_STATE.read_text().strip() if THEME_STATE.exists() else "catppuccin"
        for key, theme in THEMES.items():
            marker = "▶" if key == current else " "
            print(f" {marker} {key:15} {theme.label}")
        return

    if cmd == "current":
        current = THEME_STATE.read_text().strip() if THEME_STATE.exists() else "catppuccin"
        print(current)
        return

    if cmd in THEMES:
        theme = THEMES[cmd]
        print(f"Applying {theme.label}...")
        ThemeApplicator(theme).apply_all()
        return

    if cmd == "help":
        print("ghost-theme [name|list|current|help]")
        print("Themes:", " ".join(THEMES.keys()))
        return

    print(f"Unknown theme: {cmd}")
    print("Available:", " ".join(THEMES.keys()))
    sys.exit(1)


if __name__ == "__main__":
    main()
