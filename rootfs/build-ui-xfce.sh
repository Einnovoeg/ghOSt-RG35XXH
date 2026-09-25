#!/usr/bin/env bash
# =============================================================================
# ghOSt UI Stage — XFCE + LightDM + handheld enablement
# Ported from rg35xxh-cyberdeck rootfs/stages/{10,20,30,50} + overlay.
# Runs inside the ARM64 chroot (called from rootfs/build-rootfs.sh or CI).
# Idempotent: safe to re-run. Uses TARGET_USER=ghost from VERSIONS/config.
# =============================================================================
set -euo pipefail
ROOTFS="${1:-${ROOTFS_DIR:-}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
set -a; . "$SCRIPT_DIR/VERSIONS" 2>/dev/null || true; set +a
TARGET_USER="${TARGET_USER:-${GHOST_USER:-ghost}}"

[[ -n "$ROOTFS" ]] || { echo "Usage: $0 <rootfs-dir>"; exit 1; }
[[ "$(id -u)" = "0" ]] || { echo "must be root"; exit 1; }

run_chroot() {
    for m in proc sys dev dev/pts; do mount --bind /$m "$ROOTFS/$m" 2>/dev/null || true; done
    cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null || true
    # shellcheck disable=SC2064
    trap 'for m in dev/pts dev sys proc; do umount -l "$ROOTFS/$m" 2>/dev/null || true; done' EXIT
    DEBIAN_FRONTEND=noninteractive chroot "$ROOTFS" /bin/bash -e -c "$1"
    for m in dev/pts dev sys proc; do umount -l "$ROOTFS/$m" 2>/dev/null || true; done
    trap - EXIT
}

echo "[ghOSt-UI] Installing XFCE desktop + LightDM autologin (user: $TARGET_USER)"

run_chroot "
set -e
apt-get update
apt-get install -y --no-install-recommends \
    xfce4 xfce4-goodies xfce4-battery-plugin xfce4-power-manager xfce4-power-manager-plugins \
    lightdm lightdm-gtk-greeter \
    xserver-xorg-video-fbdev xserver-xorg-input-evdev xserver-xorg-input-libinput \
    mpv pavucontrol thunar-volman gvfs-backends mtp-tools \
    evtest joystick ffmpeg \
    pulseaudio pulseaudio-utils alsa-utils \
    network-manager network-manager-gnome dnsmasq-base \
    bluez bluez-tools blueman rfkill \
    python3 python3-evdev \
    upower brightnessctl bmap-tools \
    sudo

# Create desktop user if missing (ghOSt configure.sh also creates ghost; keep in sync)
if ! id '$TARGET_USER' >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo,video,audio,plugdev,dialout,input,netdev,bluetooth '$TARGET_USER'
    echo '$TARGET_USER:CaptainCrunch' | chpasswd
fi
echo '$TARGET_USER ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/90-'$TARGET_USER'
chmod 440 /etc/sudoers.d/90-'$TARGET_USER'

# LightDM autologin to XFCE
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-autologin.conf <<EOF
[Seat:*]
autologin-user=$TARGET_USER
autologin-user-timeout=0
user-session=xfce
EOF

# SSH on for first boot (WiFi via panel applet, then optional tailscale)
systemctl enable ssh || true
systemctl enable NetworkManager || true
systemctl enable lightdm || true

# Battery plugin false-low fix: H700 sysfs lacks charge_full so plugin computes
# 0% and spams critical popups. Disable low/critical actions; overlay chattr +i
# protects the rc (see docs/PITFALLS-cyberdeck.md #5).
mkdir -p /home/$TARGET_USER/.config/xfce4/panel
chown -R $TARGET_USER:$TARGET_USER /home/$TARGET_USER/.config || true
"

echo "[ghOSt-UI] Applying handheld overlay (joy2mouse, watchdog, MTP, power)..."

OVERLAY_SRC="$SCRIPT_DIR/overlay-cyberdeck"
# Primary source is overlay/ (merged below); fallback to overlay-cyberdeck/ for CI cache
if [[ -d "$OVERLAY_SRC" ]]; then
    rsync -aHAX "$OVERLAY_SRC/" "$ROOTFS/"
elif [[ -d "$SCRIPT_DIR/overlay" ]]; then
    echo "[ghOSt-UI] overlay-cyberdeck/ not found, overlay/ already applied by build.sh — skipping rsync"
fi

chmod +x "$ROOTFS"/usr/local/bin/joy2mouse "$ROOTFS"/usr/local/bin/play480 \
         "$ROOTFS"/usr/local/bin/setvol "$ROOTFS"/usr/local/bin/usb-mtp-setup \
         "$ROOTFS"/usr/local/bin/usb-mtp-stop "$ROOTFS"/usr/local/sbin/wifi-watchdog.sh \
         "$ROOTFS"/usr/local/sbin/dump-boot-logs.sh 2>/dev/null || true

run_chroot "
systemctl enable joy2mouse.service || true
systemctl enable wifi-watchdog.service || true
systemctl enable expand-rootfs.service || true
# MTP on by default (port 1); mass-storage left disabled (conflicts)
systemctl enable usb-mtp.service || true
systemctl disable usb-massstorage.service || true

# fstab — LABELs set by image/pack-image-rocknix.sh (MBR: BOOT vfat + rootfs ext4)
cat > /etc/fstab <<EOF
LABEL=rootfs   /        ext4   defaults,noatime,errors=remount-ro  0 1
LABEL=BOOT     /boot    vfat   defaults,noatime,umask=0022          0 2
proc           /proc    proc   defaults                             0 0
tmpfs          /tmp     tmpfs  defaults,nosuid,nodev,size=256M      0 0
EOF

# Persistent journal
install -d -o root -g systemd-journal -m 2755 /var/log/journal || install -d -m 2755 /var/log/journal || true

# Ghost launcher desktop entries (XFCE menu + desktop)
mkdir -p /home/$TARGET_USER/Desktop
chown -R $TARGET_USER:$TARGET_USER /home/$TARGET_USER || true
"

# chattr +i the battery rc if it exists (plugin overwrites on quit otherwise)
if [[ -f "$ROOTFS/home/$TARGET_USER/.config/xfce4/panel/battery-*.rc" ]]; then
    chattr +i "$ROOTFS"/home/"$TARGET_USER"/.config/xfce4/panel/battery-*.rc 2>/dev/null || true
fi

echo "[ghOSt-UI] UI stage complete. Boot target: LightDM -> XFCE ($TARGET_USER)."
echo "[ghOSt-UI] ghOSt launcher available as XFCE menu entry + /opt/ghost/launcher/launcher.py"
