#!/usr/bin/env bash
# =============================================================================
# ghOSt First Boot Interactive Setup
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

clear
cat << 'BANNER'
  ██████╗ ██╗  ██╗ ██████╗ ███████╗████████╗
 ██╔════╝ ██║  ██║██╔═══██╗██╔════╝╚══██╔══╝
 ██║  ███╗███████║██║   ██║███████╗   ██║
 ██║   ██║██╔══██║██║   ██║╚════██║   ██║
 ╚██████╔╝██║  ██║╚██████╔╝███████║   ██║
  ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝   ╚═╝

  Handheld Security and Signal Terminal
  First Boot Setup
BANNER

echo ""
echo -e "${CYAN}Welcome to ghOSt. Let's get you set up.${NC}"
echo -e "${YELLOW}Use your keyboard or the OSK (press Select to toggle)${NC}"
echo ""

GHOST_USER="ghost"

# =============================================================================
# PASSWORD
# =============================================================================
echo -e "${BOLD}[1/6] Set your password${NC}"
echo -e "${YELLOW}(Required — default is empty which is insecure)${NC}"
while true; do
    passwd "$GHOST_USER" && break || echo -e "${RED}Try again...${NC}"
done
echo -e "${GREEN}✓ Password set${NC}\n"

# =============================================================================
# TIMEZONE
# =============================================================================
echo -e "${BOLD}[2/6] Set timezone${NC}"
echo -e "${YELLOW}Examples: America/New_York  Europe/London  Asia/Tokyo${NC}"
read -r -p "Timezone (Enter for UTC): " TZ_INPUT
if [[ -n "$TZ_INPUT" ]] && [[ -f "/usr/share/zoneinfo/$TZ_INPUT" ]]; then
    ln -sf "/usr/share/zoneinfo/$TZ_INPUT" /etc/localtime
    echo "$TZ_INPUT" > /etc/timezone
    echo -e "${GREEN}✓ Timezone set to $TZ_INPUT${NC}\n"
else
    echo -e "${YELLOW}Using UTC${NC}\n"
fi

# =============================================================================
# SSH KEYPAIR
# =============================================================================
echo -e "${BOLD}[3/6] Generate SSH keypair${NC}"
SSH_DIR="/home/$GHOST_USER/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ ! -f "$SSH_DIR/id_ed25519" ]]; then
    ssh-keygen -t ed25519 -C "ghost@$(hostname)" -f "$SSH_DIR/id_ed25519" -N ""
    chown "$GHOST_USER:$GHOST_USER" "$SSH_DIR/id_ed25519" "$SSH_DIR/id_ed25519.pub"
fi

echo -e "${GREEN}✓ SSH keypair generated${NC}"
echo -e "${CYAN}Your public key (copy to authorized_keys on remote servers):${NC}"
echo ""
cat "$SSH_DIR/id_ed25519.pub"
echo ""

# Display as QR code if qrencode is available
if command -v qrencode &>/dev/null; then
    echo -e "${CYAN}QR code for easy transfer:${NC}"
    qrencode -t UTF8 "$(cat "$SSH_DIR/id_ed25519.pub")"
fi
echo ""
read -r -p "Press Enter to continue..."
echo ""

# =============================================================================
# AI SETUP
# =============================================================================
echo -e "${BOLD}[4/6] Configure AI assistant (hey)${NC}"
echo -e "${YELLOW}API keys are stored encrypted via 'pass'${NC}"
echo -e "${YELLOW}Press Enter to skip any provider${NC}"
echo ""

# Initialize pass store
if [[ ! -d "/home/$GHOST_USER/.password-store" ]]; then
    # Create a simple GPG key for pass
    su - "$GHOST_USER" -c "
        gpg --batch --gen-key <<EOF
Key-Type: EdDSA
Key-Curve: ed25519
Subkey-Type: ECDH
Subkey-Curve: cv25519
Name-Real: ghost
Name-Email: ghost@localhost
Expire-Date: 0
%no-protection
%commit
EOF
        GPG_ID=\$(gpg --list-keys --with-colons ghost@localhost | grep ^pub | cut -d: -f5)
        pass init \"\$GPG_ID\"
    " 2>/dev/null || echo -e "${YELLOW}GPG setup skipped, use 'hey --setup' to configure keys later${NC}"
fi

# hey reads the key from config.json ("<provider>_key") or from the pass store.
# Nothing reads a separate key file, so a key written anywhere else is lost.
HEY_CONFIG="/home/$GHOST_USER/.config/ghost/hey/config.json"
mkdir -p "$(dirname "$HEY_CONFIG")"
HEY_KEY_HELPER="$(mktemp /tmp/ghost-hey-key.XXXXXX.py)"
cat > "$HEY_KEY_HELPER" << 'PY'
import json, pathlib, sys
name, cfg_path = sys.argv[1], pathlib.Path(sys.argv[2])
key = sys.stdin.read().strip()
if not key:
    sys.exit(1)
cfg_path.parent.mkdir(parents=True, exist_ok=True)
cfg = json.loads(cfg_path.read_text()) if cfg_path.exists() else {}
cfg[f"{name}_key"] = key
cfg.setdefault("default_model", "claude")
cfg_path.write_text(json.dumps(cfg, indent=2))
cfg_path.chmod(0o600)
PY

trap 'rm -f "$HEY_KEY_HELPER"' EXIT

save_api_key() {   # $1 = provider name used by hey, $2 = key
    local name="$1" key="$2"
    # The key travels on stdin, never on a command line.
    printf '%s' "$key" | python3 "$HEY_KEY_HELPER" "$name" "$HEY_CONFIG" 2>/dev/null || return 1
    chown "$GHOST_USER:$GHOST_USER" "$HEY_CONFIG" 2>/dev/null || true
    chmod 600 "$HEY_CONFIG"
    # Mirror into the pass store too when it is usable; hey accepts either.
    printf '%s\n' "$key" | su - "$GHOST_USER" \
        -c "pass insert -m -f ghost/hey/$name" >/dev/null 2>&1 || true
    return 0
}

for PROVIDER in "Anthropic Claude:anthropic" "OpenAI GPT-4o:openai" "Google Gemini:google"; do
    LABEL="${PROVIDER%%:*}"
    KEY_NAME="${PROVIDER##*:}"
    read -r -p "$LABEL API key (Enter to skip): " API_KEY
    if [[ -n "$API_KEY" ]]; then
        if save_api_key "$KEY_NAME" "$API_KEY"; then
            echo -e "${GREEN}✓ $LABEL key saved${NC}"
        else
            echo -e "${RED}Could not save the $LABEL key — run 'hey --setup' later${NC}"
        fi
    fi
done
unset API_KEY
echo ""

# =============================================================================
# WIFI
# =============================================================================
echo -e "${BOLD}[5/6] Connect to WiFi${NC}"
read -r -p "Connect to WiFi now? [y/N]: " WIFI_NOW
if [[ "$WIFI_NOW" =~ ^[Yy]$ ]]; then
    nmtui-connect
fi
echo ""

# =============================================================================
# STEALTH ROM
# =============================================================================
echo -e "${BOLD}[6/6] Stealth mode setup${NC}"
echo -e "${CYAN}Stealth mode activates with: SELECT + START + L2 (hold 3 seconds)${NC}"
echo -e "${CYAN}Drop a .gba, .gbc, or .gb ROM file into:${NC}"
echo -e "${BOLD}  /home/$GHOST_USER/.stealth/roms/${NC}"
echo -e "${CYAN}The most recently added ROM launches automatically.${NC}"
echo ""
mkdir -p "/home/$GHOST_USER/.stealth/roms"
chown -R "$GHOST_USER:$GHOST_USER" "/home/$GHOST_USER/.stealth"
echo ""
read -r -p "Press Enter to finish setup..."

# =============================================================================
# FINAL CHECKS
# =============================================================================
clear
echo -e "${GREEN}${BOLD}"
cat << 'DONE'
  _____ _____ _____ _   _  _____ 
 |  _  |  |  |     | \ | ||   __|
 |     |  |  |   --|  \| ||__   |
 |__|__|_____|_____|_|\___||_____|

  ghOSt is ready.
DONE
echo -e "${NC}"

# Run dependency check
echo -e "${CYAN}Running dependency check...${NC}"
if [[ -f "/opt/ghost/intercept/intercept.py" ]]; then
    python3 /opt/ghost/intercept/intercept.py --check-deps 2>/dev/null || true
fi

echo ""
echo -e "${GREEN}INTERCEPT:  ${BOLD}http://localhost:5050${NC}"
echo -e "${GREEN}CyberChef:  ${BOLD}http://localhost:8000${NC}"
echo -e "${GREEN}Syncthing:  ${BOLD}http://localhost:8384${NC}"
echo ""
echo -e "${CYAN}Type ${BOLD}hey${NC}${CYAN} for AI, ${BOLD}hey -t${NC}${CYAN} for text mode${NC}"
echo -e "${CYAN}Type ${BOLD}intercept${NC}${CYAN} in launcher to open signal intelligence dashboard${NC}"
echo ""
echo -e "${YELLOW}Restarting launcher in 5 seconds...${NC}"
sleep 5

# Restart the GUI cleanly
systemctl restart ghost-gui.service 2>/dev/null || true

# =============================================================================
# POST-BOOT SETUP SCRIPTS
# =============================================================================
echo -e "${BOLD}Optional post-boot tasks${NC}"
echo ""
if [[ -x "/opt/ghost/portmaster-setup.sh" ]]; then
    echo -e "  ${CYAN}PortMaster extras:${NC}   ${BOLD}bash /opt/ghost/portmaster-setup.sh${NC}"
fi
if [[ -x "/opt/ghost/dosbox/download-games.sh" ]]; then
    echo -e "  ${CYAN}DOS content:${NC}         ${BOLD}bash /opt/ghost/dosbox/download-games.sh${NC}"
fi
echo -e "  ${CYAN}System updates:${NC}      ${BOLD}ghost-update${NC}"
echo ""
echo -e "${YELLOW}Network access is required for optional downloads and updates.${NC}"
