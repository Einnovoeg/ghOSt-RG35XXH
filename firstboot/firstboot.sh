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

# Launch firstboot in foot terminal
foot -- bash /usr/local/bin/firstboot-interactive.sh &
wait $!

mkdir -p /var/lib/ghost
touch "$SETUP_DONE"
systemctl disable firstboot.service 2>/dev/null || true
