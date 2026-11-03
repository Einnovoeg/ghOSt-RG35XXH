#!/usr/bin/env bash
# A shipped Python tool that imports a module the image never installs dies with
# ImportError on first use — usually inside a systemd unit, where nobody sees it.
# Check the imports that matter against what the build actually installs.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
fail=0
ok()  { echo "  ok    $*"; }
bad() { echo "  FAIL  $*"; fail=1; }

imports() { # $1 = module name -> exit 0 if any shipped python file imports it
    python3 - "$1" <<'PY'
import ast, glob, sys
mod = sys.argv[1]
for f in glob.glob("**/*.py", recursive=True):
    if f.startswith("build/"):
        continue
    try:
        tree = ast.parse(open(f).read())
    except SyntaxError:
        continue
    for n in ast.walk(tree):
        names = []
        if isinstance(n, ast.Import):
            names = [a.name.split(".")[0] for a in n.names]
        elif isinstance(n, ast.ImportFrom) and n.module and n.level == 0:
            names = [n.module.split(".")[0]]
        if mod in names:
            sys.exit(0)
sys.exit(1)
PY
}

check() { # $1 = module, $2 = token the build must install
    if imports "$1"; then
        if grep -rqs -- "$2" rootfs/*.sh overlay/opt/ghost/scripts/*.sh; then
            ok "$1 is imported and installed ($2)"
        else
            bad "$1 is imported by a shipped tool but nothing installs $2"
        fi
    fi
}

check sdl2   python3-sdl2
check evdev  python3-evdev
check psutil python3-psutil
check PIL    Pillow
check flask  flask
check curses "python3 "   # stdlib, but confirm python3 itself is installed

echo
if (( fail == 0 )); then echo "python deps: PASS"; else echo "python deps: FAIL"; exit 1; fi
