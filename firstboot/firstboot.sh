#!/usr/bin/env bash
# =============================================================================
# ghOSt First Boot Setup
# Runs once on first boot to configure device
# =============================================================================
set -euo pipefail

GHOST_USER="${GHOST_USER:-ghost}"
SETUP_DONE="/var/lib/ghost/.firstboot_done"

[[ -f "$SETUP_DONE" ]] && {
    systemctl disable firstboot.service 2>/dev/null
    exit 0
}

# Give the GUI a moment to start
sleep 5

# Launch the interactive setup in a terminal. XFCE images have foot; a cage-only
# image (INCLUDE_XFCE=false) does not, and the setup must still run on the console
# instead of being skipped entirely.
if command -v foot >/dev/null 2>&1; then
    foot -- bash /usr/local/bin/firstboot-interactive.sh &
else
    setsid -w bash /usr/local/bin/firstboot-interactive.sh </dev/tty1 >/dev/tty1 2>&1 &
fi
wait $!

mkdir -p /var/lib/ghost
touch "$SETUP_DONE"
systemctl disable firstboot.service 2>/dev/null || true
