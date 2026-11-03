#!/usr/bin/env bash
# Exercise the panel selection logic in docs/panel.md without hardware.
# Test hooks: GHOST_PANEL_BOOT, GHOST_PANEL_STATE, GHOST_PANEL_TEST_PE6, GHOST_PANEL_DRYRUN.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PANEL="$ROOT/overlay/usr/local/sbin/ghost-panel"
fail=0
ok()  { echo "  ok    $*"; }
bad() { echo "  FAIL  $*"; fail=1; }

H="$(mktemp -d)"; trap 'rm -rf "$H"' EXIT
BOOT="$H/boot"; mkdir -p "$BOOT"
printf 'REGULAR-DTB' > "$BOOT/dtb-regular.img"
printf 'REV6-DTB'    > "$BOOT/dtb-rev6.img"
cp "$BOOT/dtb-regular.img" "$BOOT/dtb.img"

run() { # $1 = PE6 reading
    GHOST_PANEL_BOOT="$BOOT" GHOST_PANEL_STATE="$H/state" \
    GHOST_PANEL_DRYRUN=1 GHOST_PANEL_TEST_PE6="$1" python3 "$PANEL" 2>&1
}

# 1. A low pin on a retail unit must not silently move it onto the rev6 tree.
out="$(run 0)"
if cmp -s "$BOOT/dtb.img" "$BOOT/dtb-regular.img"; then
    ok "auto refuses the rev6 tree on a pin reading alone"
else
    bad "auto switched to the rev6 tree"
fi
case "$out" in
    *"not switching automatically"*|*"automatic switch to the rev6 tree is refused"*)
        ok "says why it did not switch" ;;
    *) bad "no explanation in output" ;;
esac

# 2. panel.txt is the override, so a real rev6 unit can still be set up.
printf 'rev6\n' > "$BOOT/panel.txt"
run 0 >/dev/null
if cmp -s "$BOOT/dtb.img" "$BOOT/dtb-rev6.img"; then
    ok "panel.txt rev6 switches the tree"
else
    bad "panel.txt rev6 was ignored"
fi

# 3. A card moved to a regular unit is restored (panel.txt back to auto).
rm -f "$BOOT/panel.txt"
run 1 >/dev/null
if cmp -s "$BOOT/dtb.img" "$BOOT/dtb-regular.img"; then
    ok "PE6 high restores the regular tree"
else
    bad "did not restore the regular tree"
fi

# 4. A hand-edited dtb.img is never overwritten.
rm -f "$BOOT/panel.txt"
printf 'HAND-EDITED' > "$BOOT/dtb.img"
run 1 >/dev/null
if [ "$(cat "$BOOT/dtb.img")" = "HAND-EDITED" ]; then
    ok "hand-edited dtb.img left alone"
else
    bad "hand-edited dtb.img was overwritten"
fi

echo
if (( fail == 0 )); then echo "panel logic: PASS"; else echo "panel logic: FAIL"; exit 1; fi
