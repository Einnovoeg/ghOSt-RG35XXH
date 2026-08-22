#!/usr/bin/env python3
"""
ghOSt-RG35XXH DOS Game Browser
PortMaster-style menu for the abandonware library.
- Browse by genre or year
- Search by title
- Install individual games from archive.org
- Remove installed games
- Default games list is sacred — this only manages additions/removals
"""

import os
import sys
import json
import curses
import urllib.request
import urllib.error
import subprocess
import shutil
from pathlib import Path
from dataclasses import dataclass, field
from typing import List, Optional

DOSDIR    = Path("/opt/ghost/dosbox/games")
STATEFILE = Path("/var/lib/ghost/dos-games.json")
DOSBOX    = "dosbox-x"

# =============================================================================
# GAME CATALOGUE
# Source: archive.org — all verified freely available abandonware
# =============================================================================
@dataclass
class DOSGame:
    id:       str
    title:    str
    year:     int
    genre:    str
    desc:     str
    url:      str
    size_mb:  int = 0
    installed: bool = False
    default:  bool = False    # Default games — cannot be removed

CATALOGUE: List[DOSGame] = [
    # ── DEFAULT GAMES (installed at build time) ──────────────────────────────
    DOSGame("neuromancer", "Neuromancer", 1988, "RPG/Adventure",
        "Gibson's cyberspace. Seminal cyberpunk RPG.",
        "https://archive.org/download/Neuromancer_1988_Interplay/Neuromancer_1988_Interplay.zip",
        size_mb=2, default=True),
    DOSGame("hacker1", "Hacker", 1985, "Hacking Sim",
        "Original hacking simulator. Break into mainframes.",
        "https://archive.org/download/Hacker_1985_Activision/Hacker_1985_Activision.zip",
        size_mb=1, default=True),
    DOSGame("hacker2", "Hacker II: Doomsday Papers", 1986, "Hacking Sim",
        "Sequel to Hacker. Corporate espionage.",
        "https://archive.org/download/hacker-ii-the-doomsday-papers/Hacker_II_The_Doomsday_Papers_1986_Activision.zip",
        size_mb=1, default=True),
    DOSGame("sshock", "System Shock", 1994, "Action/RPG",
        "SHODAN. Classic immersive sim aboard Citadel Station.",
        "https://archive.org/download/SystemShock1994/SystemShock.zip",
        size_mb=25, default=True),
    DOSGame("cyberia", "Cyberia", 1994, "Action/Puzzle",
        "Cold War thriller. Superweapon in Siberia.",
        "https://archive.org/download/Cyberia_1994_Cyberdreams/Cyberia.zip",
        size_mb=10, default=True),
    DOSGame("toneloc", "ToneLoc", 1994, "Tool/Wardialer",
        "Classic wardialing tool. Historical.",
        "https://archive.org/download/tonelocv110/TONELOCK.ZIP",
        size_mb=1, default=True),

    # ── HACKING / SECURITY (historical tools) ────────────────────────────────
    DOSGame("satan", "SATAN 1.1.1", 1995, "Security Tool",
        "Security Administrator Tool for Analyzing Networks. Historic.",
        "https://simson.net/ref/1995/satan.tar.gz",
        size_mb=2),
    DOSGame("crack", "Crack 5.0", 1992, "Security Tool",
        "Alec Muffett's Unix password cracker. Historical.",
        "https://archive.org/download/crack-5.0/crack5a.zip",
        size_mb=1),
    DOSGame("nmap_old", "NMAP 1.x (DOS)", 1997, "Security Tool",
        "Original NMAP — historical curiosity.",
        "https://archive.org/download/nmap-historical/nmap1.zip",
        size_mb=1),

    # ── CYBERPUNK / HACKER FICTION ────────────────────────────────────────────
    DOSGame("shadowrun_dos", "Shadowrun (DOS)", 1993, "RPG",
        "Cyberpunk/fantasy RPG. Megacorps and magic.",
        "https://archive.org/download/msdos_Shadowrun_1993/Shadowrun_1993.zip",
        size_mb=5),
    DOSGame("circuit_breaker", "Circuit's Edge", 1990, "Adventure",
        "George Alec Effinger's When Gravity Fails. Cyberpunk noir.",
        "https://archive.org/download/msdos_Circuits_Edge_1990/Circuits_Edge_1990.zip",
        size_mb=3),
    DOSGame("deus_ex_dos", "Beneath a Steel Sky", 1994, "Adventure",
        "Cyberpunk point-and-click. Freeware from Revolution Software.",
        "https://archive.org/download/BeneathASteelSky_1020/BeneathASteelSky_1020.zip",
        size_mb=50),
    DOSGame("privateer", "Wing Commander: Privateer", 1993, "Space Sim",
        "Space trading and combat. Classic.",
        "https://archive.org/download/WingCommanderPrivateer1993/WingCommanderPrivateer1993.zip",
        size_mb=30),

    # ── CLASSIC GAMES ────────────────────────────────────────────────────────
    DOSGame("doom", "DOOM Shareware", 1993, "FPS",
        "Episode 1 shareware — free and legal.",
        "https://archive.org/download/DoomsharewareEpisode/doom1.wad",
        size_mb=4),
    DOSGame("quake_dos", "Quake Shareware", 1996, "FPS",
        "id Software classic. Free shareware episode.",
        "https://archive.org/download/quakesw/quake106.zip",
        size_mb=30),
    DOSGame("wolf3d", "Wolfenstein 3D Shareware", 1992, "FPS",
        "Where FPS began. Shareware episodes free.",
        "https://archive.org/download/WolfensteinShareware/wolfshar.zip",
        size_mb=3),
    DOSGame("commander_keen", "Commander Keen 1-3", 1990, "Platformer",
        "Apogee shareware. Mars mission.",
        "https://archive.org/download/Commander_Keen_1-3_1990_Apogee/Commander_Keen_1_1990_Apogee.zip",
        size_mb=3),
    DOSGame("jazz_jackrabbit", "Jazz Jackrabbit Shareware", 1994, "Platformer",
        "Epic's fast platformer. Shareware episode.",
        "https://archive.org/download/JazzJackrabbit/Jazz_Jackrabbit_Shareware.zip",
        size_mb=10),
    DOSGame("tyrian", "Tyrian 2000", 1999, "Shoot-em-up",
        "Epic MegaGames shooter. Officially freeware.",
        "https://archive.org/download/tyrian2000/tyrian21.zip",
        size_mb=10),
    DOSGame("scorched", "Scorched Earth", 1991, "Strategy",
        "Tank artillery strategy. The original Worms.",
        "https://archive.org/download/msdos_Scorched_Earth_1991/Scorched_Earth_1991.zip",
        size_mb=1),
    DOSGame("lemmings", "Lemmings Demo", 1991, "Puzzle",
        "Classic puzzle platformer demo.",
        "https://archive.org/download/msdos_Lemmings_1991/Lemmings_demo_1991.zip",
        size_mb=1),
    DOSGame("xcom_dos", "X-COM: UFO Defense", 1993, "Strategy",
        "Alien invasion strategy. Freeware version available.",
        "https://archive.org/download/msdos_XCOM_UFO_Defense_1994/XCOM_UFO_Defense_1994.zip",
        size_mb=20),

    # ── STRATEGY / SIMULATION ─────────────────────────────────────────────────
    DOSGame("civilization1", "Civilization (DOS)", 1991, "Strategy",
        "Build an empire to stand the test of time.",
        "https://archive.org/download/msdos_Civilization_1991/Civilization_1991.zip",
        size_mb=5),
    DOSGame("simcity_dos", "SimCity Classic", 1989, "Simulation",
        "Original city builder.",
        "https://archive.org/download/msdos_SimCity_1989/SimCity_1989.zip",
        size_mb=3),
    DOSGame("transport_tycoon", "Transport Tycoon", 1994, "Simulation",
        "Build transportation networks. OpenTTD runs this.",
        "https://archive.org/download/msdos_Transport_Tycoon_1994/Transport_Tycoon_1994.zip",
        size_mb=10),

    # ── ADVENTURE ─────────────────────────────────────────────────────────────
    DOSGame("hitchhiker", "Hitchhiker's Guide (Infocom)", 1984, "Text Adventure",
        "Douglas Adams' text adventure. Officially free from BBC.",
        "https://www.bbc.co.uk/programmes/articles/1g84m0sXpnNCv84GpN2PLZG/the-hitchhikers-guide-to-the-galaxy",
        size_mb=1),
    DOSGame("zork1", "Zork I", 1980, "Text Adventure",
        "Original text adventure. Officially freeware.",
        "https://archive.org/download/msdos_Zork_I_-_The_Great_Underground_Empire_1980/Zork_I_-_The_Great_Underground_Empire_1980.zip",
        size_mb=1),
    DOSGame("maniac_mansion", "Maniac Mansion", 1987, "Adventure",
        "LucasArts classic. ScummVM compatible.",
        "https://archive.org/download/msdos_Maniac_Mansion_1987/Maniac_Mansion_1987.zip",
        size_mb=2),
    DOSGame("monkey_island", "Monkey Island (EGA)", 1990, "Adventure",
        "Guybrush Threepwood. EGA shareware demo.",
        "https://archive.org/download/msdos_Secret_of_Monkey_Island_The_1990/Secret_of_Monkey_Island_EGA_1990.zip",
        size_mb=3),

    # ── RPGS ──────────────────────────────────────────────────────────────────
    DOSGame("ultima4", "Ultima IV", 1985, "RPG",
        "Quest of the Avatar. Origin released as freeware.",
        "https://archive.org/download/msdos_Ultima_IV_-_Quest_of_the_Avatar_1985/Ultima_IV_-_Quest_of_the_Avatar_1985.zip",
        size_mb=3),
    DOSGame("wasteland", "Wasteland", 1988, "RPG",
        "Post-apocalyptic RPG. Inspired Fallout. EA released as freeware.",
        "https://archive.org/download/msdos_Wasteland_1988/Wasteland_1988.zip",
        size_mb=4),
]

GENRES = sorted(set(g.genre for g in CATALOGUE))
YEARS  = sorted(set(g.year for g in CATALOGUE))


# =============================================================================
# STATE MANAGEMENT
# =============================================================================
def load_state():
    if STATEFILE.exists():
        try:
            data = json.loads(STATEFILE.read_text())
            installed = set(data.get("installed", []))
            for g in CATALOGUE:
                g.installed = g.id in installed or (DOSDIR / g.id).exists()
        except Exception:
            pass
    else:
        for g in CATALOGUE:
            g.installed = (DOSDIR / g.id).exists()

def save_state():
    STATEFILE.parent.mkdir(parents=True, exist_ok=True)
    installed = [g.id for g in CATALOGUE if g.installed]
    STATEFILE.write_text(json.dumps({"installed": installed}))


# =============================================================================
# INSTALL / REMOVE
# =============================================================================
def install_game(game: DOSGame, stdscr=None):
    dest = DOSDIR / game.id
    dest.mkdir(parents=True, exist_ok=True)

    if stdscr:
        stdscr.clear()
        stdscr.addstr(1, 2, f"Installing: {game.title}")
        stdscr.addstr(3, 2, "Downloading from archive.org...")
        stdscr.refresh()

    try:
        tmp = dest / "_download.zip"
        urllib.request.urlretrieve(game.url, tmp)

        if stdscr:
            stdscr.addstr(4, 2, "Extracting...")
            stdscr.refresh()

        if str(game.url).endswith(".zip"):
            subprocess.run(
                ["unzip", "-q", "-o", str(tmp), "-d", str(dest)],
                capture_output=True)
        elif str(game.url).endswith(".tar.gz"):
            subprocess.run(
                ["tar", "-xzf", str(tmp), "-C", str(dest)],
                capture_output=True)
        tmp.unlink(missing_ok=True)

        game.installed = True
        save_state()

        if stdscr:
            stdscr.addstr(6, 2, f"✓ {game.title} installed!", curses.A_BOLD)
            stdscr.addstr(7, 2, "Press any key...")
            stdscr.refresh()
            stdscr.getch()
        return True

    except Exception as e:
        if stdscr:
            stdscr.addstr(6, 2, f"✗ Failed: {e}")
            stdscr.addstr(7, 2, "Press any key...")
            stdscr.refresh()
            stdscr.getch()
        return False


def remove_game(game: DOSGame, stdscr=None):
    if game.default:
        if stdscr:
            stdscr.clear()
            stdscr.addstr(2, 2, "Cannot remove default games.", curses.A_BOLD)
            stdscr.addstr(3, 2, "Default games are part of ghOSt-RG35XXH.")
            stdscr.addstr(5, 2, "Press any key...")
            stdscr.refresh()
            stdscr.getch()
        return False

    dest = DOSDIR / game.id
    if dest.exists():
        shutil.rmtree(dest)
    game.installed = False
    save_state()
    return True


def launch_game(game: DOSGame):
    """Launch game in DOSBox-X"""
    game_dir = DOSDIR / game.id
    if not game_dir.exists():
        return

    # Find executable
    exes = list(game_dir.rglob("*.exe")) + list(game_dir.rglob("*.EXE"))
    if not exes:
        # Maybe a .bat file
        exes = list(game_dir.rglob("*.bat")) + list(game_dir.rglob("*.BAT"))

    if exes:
        # Prefer files named after the game or main entry points
        preferred = [e for e in exes if
                     e.stem.lower() in [game.id, "start", "game", "play", "run"]]
        exe = preferred[0] if preferred else exes[0]
        subprocess.Popen(
            [DOSBOX, "-conf", "/opt/ghost/dosbox/ghost.conf",
             "-c", f"mount c {game_dir}",
             "-c", f"c:", "-c", exe.name],
            start_new_session=True)
    else:
        subprocess.Popen(
            [DOSBOX, "-conf", "/opt/ghost/dosbox/ghost.conf",
             "-c", f"mount c {game_dir}", "-c", "c:"],
            start_new_session=True)


# =============================================================================
# TUI — curses-based game browser
# =============================================================================
class GameBrowser:
    def __init__(self, stdscr):
        self.scr = stdscr
        self.mode = "main"      # main / genre / year / search / game_detail
        self.games = CATALOGUE[:]
        self.filtered = CATALOGUE[:]
        self.cursor = 0
        self.scroll = 0
        self.search_str = ""
        self.selected_game = None

        load_state()
        curses.curs_set(0)
        self._setup_colors()

    def _setup_colors(self):
        curses.start_color()
        curses.use_default_colors()
        curses.init_pair(1, curses.COLOR_CYAN,    -1)  # Title
        curses.init_pair(2, curses.COLOR_GREEN,   -1)  # Installed
        curses.init_pair(3, curses.COLOR_YELLOW,  -1)  # Default / highlight
        curses.init_pair(4, curses.COLOR_RED,     -1)  # Not installed
        curses.init_pair(5, curses.COLOR_WHITE,   -1)  # Normal
        curses.init_pair(6, curses.COLOR_BLACK,   curses.COLOR_CYAN)  # Selected

    def run(self):
        while True:
            if self.mode == "main":
                result = self.draw_main()
            elif self.mode == "browse_genre":
                result = self.draw_genre_list()
            elif self.mode == "browse_year":
                result = self.draw_year_list()
            elif self.mode == "game_list":
                result = self.draw_game_list()
            elif self.mode == "search":
                result = self.draw_search()
            elif self.mode == "game_detail":
                result = self.draw_game_detail()
            else:
                break

            if result == "quit":
                break

    def draw_header(self, title=""):
        h, w = self.scr.getmaxyx()
        self.scr.clear()
        self.scr.attron(curses.color_pair(1) | curses.A_BOLD)
        header = "  ghOSt-RG35XXH DOS Library  "
        if title:
            header += f"── {title}"
        self.scr.addstr(0, 0, header[:w-1].ljust(w-1))
        self.scr.attroff(curses.color_pair(1) | curses.A_BOLD)

    def draw_footer(self, hints=""):
        h, w = self.scr.getmaxyx()
        self.scr.attron(curses.color_pair(3))
        self.scr.addstr(h-1, 0, hints[:w-1].ljust(w-1))
        self.scr.attroff(curses.color_pair(3))

    def draw_main(self):
        h, w = self.scr.getmaxyx()
        self.draw_header()

        installed = sum(1 for g in CATALOGUE if g.installed)
        total = len(CATALOGUE)

        items = [
            ("🔎", "Search games",     "search"),
            ("📂", "Browse by Genre",  "browse_genre"),
            ("📅", "Browse by Year",   "browse_year"),
            ("✅", f"All Games ({total} total, {installed} installed)", "all"),
            ("💾", "Installed only",   "installed"),
            ("🔒", "Default games",    "defaults"),
        ]

        for i, (icon, label, action) in enumerate(items):
            y = 2 + i * 2
            if i == self.cursor:
                self.scr.attron(curses.color_pair(6) | curses.A_BOLD)
                self.scr.addstr(y, 2, f" {icon} {label} ".ljust(w-4))
                self.scr.attroff(curses.color_pair(6) | curses.A_BOLD)
            else:
                self.scr.addstr(y, 2, f" {icon} {label}")

        self.draw_footer("↑↓ Navigate  Enter Select  Q Quit")
        self.scr.refresh()

        key = self.scr.getch()
        n = len(items)
        if key == curses.KEY_UP:
            self.cursor = (self.cursor - 1) % n
        elif key == curses.KEY_DOWN:
            self.cursor = (self.cursor + 1) % n
        elif key in (curses.KEY_ENTER, 10, 13):
            action = items[self.cursor][2]
            self.cursor = 0
            self.scroll = 0
            if action == "search":
                self.mode = "search"
                self.search_str = ""
            elif action == "browse_genre":
                self.mode = "browse_genre"
            elif action == "browse_year":
                self.mode = "browse_year"
            elif action == "all":
                self.filtered = CATALOGUE[:]
                self.mode = "game_list"
            elif action == "installed":
                self.filtered = [g for g in CATALOGUE if g.installed]
                self.mode = "game_list"
            elif action == "defaults":
                self.filtered = [g for g in CATALOGUE if g.default]
                self.mode = "game_list"
        elif key in (ord('q'), ord('Q'), 27):
            return "quit"

    def draw_genre_list(self):
        h, w = self.scr.getmaxyx()
        self.draw_header("Browse by Genre")

        items = [(g, [x for x in CATALOGUE if x.genre == g]) for g in GENRES]

        visible = items[self.scroll:self.scroll + h - 3]
        for i, (genre, games) in enumerate(visible):
            y = 1 + i
            inst = sum(1 for g in games if g.installed)
            label = f"  {genre:<25} ({len(games)} games, {inst} installed)"
            if i + self.scroll == self.cursor:
                self.scr.attron(curses.color_pair(6) | curses.A_BOLD)
                self.scr.addstr(y, 0, label.ljust(w-1))
                self.scr.attroff(curses.color_pair(6) | curses.A_BOLD)
            else:
                self.scr.addstr(y, 0, label)

        self.draw_footer("↑↓ Navigate  Enter Browse Genre  B Back")
        self.scr.refresh()

        key = self.scr.getch()
        if key == curses.KEY_UP:
            if self.cursor > 0:
                self.cursor -= 1
                if self.cursor < self.scroll:
                    self.scroll -= 1
        elif key == curses.KEY_DOWN:
            if self.cursor < len(items) - 1:
                self.cursor += 1
                if self.cursor >= self.scroll + h - 3:
                    self.scroll += 1
        elif key in (curses.KEY_ENTER, 10, 13):
            genre = items[self.cursor][0]
            self.filtered = items[self.cursor][1]
            self.cursor = 0
            self.scroll = 0
            self.mode = "game_list"
        elif key in (ord('b'), ord('B'), curses.KEY_BACKSPACE, 27):
            self.cursor = 0
            self.mode = "main"

    def draw_year_list(self):
        h, w = self.scr.getmaxyx()
        self.draw_header("Browse by Year")

        items = [(y, [g for g in CATALOGUE if g.year == y]) for y in YEARS]
        visible = items[self.scroll:self.scroll + h - 3]

        for i, (year, games) in enumerate(visible):
            y_pos = 1 + i
            inst = sum(1 for g in games if g.installed)
            label = f"  {year}   {len(games)} game(s), {inst} installed"
            if i + self.scroll == self.cursor:
                self.scr.attron(curses.color_pair(6) | curses.A_BOLD)
                self.scr.addstr(y_pos, 0, label.ljust(w-1))
                self.scr.attroff(curses.color_pair(6) | curses.A_BOLD)
            else:
                self.scr.addstr(y_pos, 0, label)

        self.draw_footer("↑↓ Navigate  Enter Browse Year  B Back")
        self.scr.refresh()

        key = self.scr.getch()
        if key == curses.KEY_UP:
            if self.cursor > 0:
                self.cursor -= 1
                if self.cursor < self.scroll:
                    self.scroll -= 1
        elif key == curses.KEY_DOWN:
            if self.cursor < len(items) - 1:
                self.cursor += 1
                if self.cursor >= self.scroll + h - 3:
                    self.scroll += 1
        elif key in (curses.KEY_ENTER, 10, 13):
            self.filtered = items[self.cursor][1]
            self.cursor = 0
            self.scroll = 0
            self.mode = "game_list"
        elif key in (ord('b'), ord('B'), curses.KEY_BACKSPACE, 27):
            self.cursor = 0
            self.mode = "main"

    def draw_game_list(self):
        h, w = self.scr.getmaxyx()
        games = self.filtered
        if not games:
            self.draw_header("No games found")
            self.scr.addstr(2, 2, "No games match this filter.")
            self.scr.addstr(4, 2, "Press B to go back.")
            self.scr.refresh()
            key = self.scr.getch()
            if key in (ord('b'), ord('B'), 27):
                self.cursor = 0
                self.mode = "main"
            return

        self.draw_header(f"{len(games)} game(s)")
        visible = games[self.scroll:self.scroll + h - 3]

        for i, game in enumerate(visible):
            y = 1 + i
            if game.installed:
                status = "✅" if not game.default else "🔒"
                attr = curses.color_pair(2)
            else:
                status = "  "
                attr = curses.color_pair(5)

            label = f" {status} {game.title:<28} {game.year}  {game.genre}"
            if i + self.scroll == self.cursor:
                self.scr.attron(curses.color_pair(6) | curses.A_BOLD)
                self.scr.addstr(y, 0, label[:w-1].ljust(w-1))
                self.scr.attroff(curses.color_pair(6) | curses.A_BOLD)
            else:
                self.scr.attron(attr)
                self.scr.addstr(y, 0, label[:w-1])
                self.scr.attroff(attr)

        self.draw_footer("↑↓ Navigate  Enter Details  B Back  ✅=installed  🔒=default")
        self.scr.refresh()

        key = self.scr.getch()
        if key == curses.KEY_UP:
            if self.cursor > 0:
                self.cursor -= 1
                if self.cursor < self.scroll:
                    self.scroll -= 1
        elif key == curses.KEY_DOWN:
            if self.cursor < len(games) - 1:
                self.cursor += 1
                if self.cursor >= self.scroll + h - 3:
                    self.scroll += 1
        elif key in (curses.KEY_ENTER, 10, 13):
            self.selected_game = games[self.cursor]
            self.mode = "game_detail"
        elif key in (ord('b'), ord('B'), curses.KEY_BACKSPACE, 27):
            self.cursor = 0
            self.scroll = 0
            self.mode = "main"

    def draw_search(self):
        h, w = self.scr.getmaxyx()
        self.draw_header("Search")
        curses.curs_set(1)

        self.scr.addstr(2, 2, "Search: ")
        self.scr.addstr(2, 10, self.search_str + "_")

        results = [g for g in CATALOGUE
                   if self.search_str.lower() in g.title.lower()
                   or self.search_str.lower() in g.genre.lower()
                   or self.search_str.lower() in g.desc.lower()]

        for i, g in enumerate(results[:h-6]):
            status = "✅" if g.installed else "  "
            self.scr.addstr(4 + i, 4, f"{status} {g.title} ({g.year})")

        if not self.search_str:
            self.scr.addstr(4, 4, "(type to search title, genre, or description)")

        self.draw_footer("Type to search  Enter Browse Results  Esc Cancel")
        self.scr.refresh()

        key = self.scr.getch()
        if key in (curses.KEY_BACKSPACE, 127, 8):
            self.search_str = self.search_str[:-1]
        elif key == 27:
            curses.curs_set(0)
            self.mode = "main"
        elif key in (curses.KEY_ENTER, 10, 13):
            curses.curs_set(0)
            self.filtered = results
            self.cursor = 0
            self.scroll = 0
            self.mode = "game_list"
        elif 32 <= key <= 126:
            self.search_str += chr(key)

    def draw_game_detail(self):
        g = self.selected_game
        h, w = self.scr.getmaxyx()
        self.draw_header(g.title)

        self.scr.addstr(2, 2, f"Title:   {g.title}", curses.A_BOLD)
        self.scr.addstr(3, 2, f"Year:    {g.year}")
        self.scr.addstr(4, 2, f"Genre:   {g.genre}")
        self.scr.addstr(5, 2, f"Size:    ~{g.size_mb}MB")
        self.scr.addstr(6, 2, f"Status:  {'✅ Installed' if g.installed else '  Not installed'}")
        if g.default:
            self.scr.attron(curses.color_pair(3))
            self.scr.addstr(7, 2, "         🔒 Default game (cannot be removed)")
            self.scr.attroff(curses.color_pair(3))

        # Word-wrap description
        desc_words = g.desc.split()
        line = "         "
        y = 9
        for word in desc_words:
            if len(line) + len(word) + 1 > w - 4:
                self.scr.addstr(y, 2, line)
                y += 1
                line = "  " + word
            else:
                line += " " + word
        if line.strip():
            self.scr.addstr(y, 2, line)
            y += 1

        y += 1
        actions = []
        if g.installed:
            actions.append(("[L] Launch", "launch"))
            if not g.default:
                actions.append(("[X] Remove", "remove"))
        else:
            actions.append(("[I] Install", "install"))
        actions.append(("[B] Back", "back"))

        for i, (label, _) in enumerate(actions):
            attr = curses.A_BOLD if i == 0 else curses.A_NORMAL
            self.scr.addstr(y + i, 4, label, attr)

        self.draw_footer("I=Install  L=Launch  X=Remove  B=Back")
        self.scr.refresh()

        key = self.scr.getch()
        if key in (ord('i'), ord('I')) and not g.installed:
            install_game(g, self.scr)
        elif key in (ord('l'), ord('L')) and g.installed:
            launch_game(g)
        elif key in (ord('x'), ord('X')) and g.installed and not g.default:
            remove_game(g, self.scr)
            self.mode = "game_list"
        elif key in (ord('b'), ord('B'), curses.KEY_BACKSPACE, 27):
            self.mode = "game_list"


def main():
    load_state()
    try:
        curses.wrapper(lambda scr: GameBrowser(scr).run())
    except KeyboardInterrupt:
        pass

if __name__ == "__main__":
    main()
