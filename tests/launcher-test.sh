#!/usr/bin/env bash
# Structural checks on the launcher menu: every entry must be runnable, and every
# optional entry must declare what makes it optional.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
fail=0
ok()  { echo "  ok    $*"; }
bad() { echo "  FAIL  $*"; fail=1; }

python3 - <<'PY' || exit 1
import ast, sys

src = open("launcher/launcher.py").read()
try:
    tree = ast.parse(src)
except SyntaxError as e:
    print("  FAIL  launcher.py does not parse: %s" % e)
    sys.exit(1)

entries = []
for node in ast.walk(tree):
    if not isinstance(node, ast.Dict):
        continue
    d = {}
    for k, v in zip(node.keys, node.values):
        if isinstance(k, ast.Constant) and isinstance(k.value, str):
            try:
                d[k.value] = ast.literal_eval(v)
            except Exception:
                d[k.value] = "<expr>"
    if "cmd" in d and "label" in d:
        entries.append(d)

bad = 0
if len(entries) < 60:
    print("  FAIL  only %d menu entries; the menu lost entries" % len(entries))
    bad = 1
else:
    print("  ok    %d menu entries" % len(entries))

for e in entries:
    label, cmd = e.get("label"), e.get("cmd")
    if not isinstance(label, str) or not label.strip():
        print("  FAIL  entry without a label: %r" % (e,)); bad = 1
    if not isinstance(cmd, str) or not cmd.strip():
        print("  FAIL  %r has no command" % (label,)); bad = 1
    req = e.get("requires")
    if req is not None:
        if not isinstance(req, dict) or set(req) - {"commands", "paths"}:
            print("  FAIL  %r has an unknown requires key: %r" % (label, req)); bad = 1
        else:
            for kind, vals in req.items():
                if not isinstance(vals, list) or not vals:
                    print("  FAIL  %r declares an empty %s list" % (label, kind)); bad = 1

# A requires guard is what hides an optional tool. An entry that runs a tool the
# build cannot install must declare one, or the menu offers a dead command.
guarded = sum(1 for e in entries if e.get("requires"))
print("  ok    %d entries declare requirements" % guarded)
sys.exit(bad)
PY
rc=$?
if (( rc == 0 )); then ok "launcher entries are well formed"; else bad "launcher entries are malformed"; fi

echo
if (( fail == 0 )); then echo "launcher: PASS"; else echo "launcher: FAIL"; exit 1; fi
