#!/usr/bin/env bash
# =============================================================================
# ghOSt In-Chroot Configuration
# Runs inside the ARM64 chroot to configure the system
# =============================================================================
set -euo pipefail

# Load config values passed in via environment or defaults
GHOST_USER="${GHOST_USER:-ghost}"
GHOST_HOSTNAME="${GHOST_HOSTNAME:-darkphobia}"
GHOST_TIMEZONE="${GHOST_TIMEZONE:-UTC}"
GHOST_LOCALE="${GHOST_LOCALE:-en_US.UTF-8}"
GHOST_USER_ID="${GHOST_USER_ID:-1000}"
BATTERY_CHARGE_LIMIT="${BATTERY_CHARGE_LIMIT:-80}"

log()  { echo "[configure] $*"; }
warn() { echo "[configure][WARN] $*"; }

purge_foreign_kernel_stack() {
    local removable_pkgs=()

    # ghOSt ships a staged KNULLI boot chain and module tree, so distro kernel
    # packages and initramfs hooks are both unnecessary and actively harmful.
    # If a cached rootfs accidentally picked up a Debian or Raspberry Pi kernel,
    # purge it here before later package hooks try to build an unusable initrd.
    mapfile -t removable_pkgs < <(
        dpkg-query -W -f='${Package}\n' 2>/dev/null | \
            grep -E '^(linux-image-|initramfs-tools(|-core)|klibc-utils|busybox)$' || true
    )

    if [ "${#removable_pkgs[@]}" -eq 0 ]; then
        return
    fi

    log "Removing distro kernel/initramfs packages that conflict with the staged H700 kernel..."
    apt-get purge -y "${removable_pkgs[@]}" >/dev/null 2>&1 || true
    apt-get autoremove -y >/dev/null 2>&1 || true
}

disable_system_service() {
    local unit="$1"

    # Package postinst scripts can enable heavyweight daemons as soon as they
    # are installed. ghOSt keeps those packages available for tooling, but the
    # services themselves stay disabled by default to preserve RAM and battery.
    systemctl disable "$unit" 2>/dev/null || true
    systemctl mask "$unit" 2>/dev/null || true
    rm -f \
        "/etc/systemd/system/multi-user.target.wants/$unit" \
        "/etc/systemd/system/network-online.target.wants/$unit" \
        "/etc/systemd/system/sockets.target.wants/$unit"
}

# =============================================================================
# LOCALE & TIMEZONE
# =============================================================================
log "Configuring locale and timezone..."
echo "$GHOST_LOCALE UTF-8" > /etc/locale.gen
locale-gen
update-locale LANG="$GHOST_LOCALE"
ln -sf "/usr/share/zoneinfo/$GHOST_TIMEZONE" /etc/localtime
echo "$GHOST_TIMEZONE" > /etc/timezone

# =============================================================================
# HOSTNAME (deliberately boring for stealth)
# =============================================================================
echo "$GHOST_HOSTNAME" > /etc/hostname
cat > /etc/hosts << EOF
127.0.0.1   localhost
127.0.1.1   $GHOST_HOSTNAME
::1         localhost ip6-localhost ip6-loopback
EOF

# =============================================================================
# USERS
# =============================================================================
log "Creating user $GHOST_USER..."
useradd -m -u "$GHOST_USER_ID" -s /usr/bin/fish \
    -G sudo,audio,video,input,plugdev,netdev,bluetooth,dialout,render \
    "$GHOST_USER" 2>/dev/null || true

# Kismet installs a dedicated capture group when present. Add the handheld
# operator account to it during image configuration so source-built and
# package-built installs behave the same way on first boot.
if getent group kismet >/dev/null 2>&1; then
    usermod -aG kismet "$GHOST_USER"
fi

# Set empty password (firstboot will prompt to set one)
echo "${GHOST_USER}:CaptainCrunch" | chpasswd

# Root also gets fish
chsh -s /usr/bin/fish root

# =============================================================================
# SUDOERS
# =============================================================================
cat > /etc/sudoers.d/ghost << EOF
$GHOST_USER ALL=(ALL) NOPASSWD: /usr/bin/airmon-ng, /usr/bin/airodump-ng, \
    /usr/bin/kismet, /usr/bin/bettercap, /usr/sbin/tcpdump, \
    /usr/bin/msfconsole, /usr/sbin/iw, /sbin/ip, \
    /usr/local/bin/interceptd, /opt/ghost/stealthd/stealthd.py
$GHOST_USER ALL=(ALL) ALL
EOF
chmod 440 /etc/sudoers.d/ghost

# =============================================================================
# FISH SHELL AS DEFAULT
# =============================================================================
log "Configuring fish shell..."
#
# Keep the configure step self-contained. Resumed builds and partial overlays
# should not depend on these per-user config directories already existing.
mkdir -p /home/$GHOST_USER/.config/fish/functions
mkdir -p /home/$GHOST_USER/.config/fish/conf.d
mkdir -p /home/$GHOST_USER/.config/tmux

# Fisher plugin manager
su - "$GHOST_USER" -c "fish -c '
    curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | \
    source && fisher install jorgebucaran/fisher
    fisher install IlanCosman/tide@v6
    fisher install PatrickF1/fzf.fish
    fisher install jethrokuan/z
    fisher install meaningful-ooo/sponge
' " 2>/dev/null || log "Fisher plugins will install on first boot"

# Tide prompt config (non-interactive)
cat > /home/$GHOST_USER/.config/fish/conf.d/tide.fish << 'EOF'
# Tide prompt configuration
set -g tide_prompt_add_newline_before false
set -g tide_left_prompt_items pwd git newline character
set -g tide_right_prompt_items status cmd_duration jobs battery
set -g tide_battery_icon_charging ⚡
set -g tide_battery_color_charging green
EOF

# =============================================================================
# TMUX CONFIGURATION
# =============================================================================
log "Configuring tmux..."
cat > /home/$GHOST_USER/.config/tmux/tmux.conf << 'EOF'
# ghOSt tmux config — Catppuccin Mocha theme

set -g default-terminal "xterm-256color"
set -ag terminal-overrides ",xterm-256color:RGB"
set -g mouse on
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -g history-limit 50000
set -g display-time 4000
set -g status-interval 5
set -g focus-events on
set -g escape-time 0

# Prefix: Ctrl+Space
unbind C-b
set -g prefix C-Space
bind C-Space send-prefix

# Split panes
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"

# Vim pane navigation
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R

# Catppuccin Mocha colors
set -g status-bg "#1e1e2e"
set -g status-fg "#cdd6f4"
set -g status-left-length 30
set -g status-right-length 60

set -g status-left "#[fg=#89b4fa,bold] ghOSt #[fg=#6c7086]│ "
set -g status-right "#[fg=#a6e3a1]#{battery_percentage} #[fg=#6c7086]│ #[fg=#89dceb]%H:%M #[fg=#6c7086]│ #[fg=#cba6f7]#h"

set -g window-status-format "#[fg=#6c7086] #I:#W "
set -g window-status-current-format "#[fg=#89b4fa,bold] #I:#W "

set -g pane-border-style "fg=#313244"
set -g pane-active-border-style "fg=#89b4fa"
set -g message-style "bg=#1e1e2e,fg=#cdd6f4"
EOF

# =============================================================================
# FOOT TERMINAL CONFIGURATION
# =============================================================================
log "Configuring foot terminal..."
mkdir -p /home/$GHOST_USER/.config/foot
cat > /home/$GHOST_USER/.config/foot/foot.ini << 'EOF'
[main]
font=Terminus (TTF):style=Bold:size=12
term=xterm-256color
dpi-aware=no
pad=4x4

[scrollback]
lines=10000

[cursor]
style=beam
blink=yes

[mouse]
hide-when-typing=yes

[colors]
# Catppuccin Mocha
background=1e1e2e
foreground=cdd6f4
regular0=45475a
regular1=f38ba8
regular2=a6e3a1
regular3=f9e2af
regular4=89b4fa
regular5=f5c2e7
regular6=94e2d5
regular7=bac2de
bright0=585b70
bright1=f38ba8
bright2=a6e3a1
bright3=f9e2af
bright4=89b4fa
bright5=f5c2e7
bright6=94e2d5
bright7=a6adc8
alpha=0.95
EOF

# =============================================================================
# RANGER FILE MANAGER CONFIG
# =============================================================================
mkdir -p /home/$GHOST_USER/.config/ranger
cat > /home/$GHOST_USER/.config/ranger/rc.conf << 'EOF'
set preview_images true
set preview_images_method sixel
set show_hidden true
set colorscheme default
set column_ratios 1,3,4
set draw_borders separators
set mouse_enabled true
EOF

# =============================================================================
# BTOP CONFIGURATION
# =============================================================================
mkdir -p /home/$GHOST_USER/.config/btop/themes
cat > /home/$GHOST_USER/.config/btop/btop.conf << 'EOF'
color_theme = "catppuccin_mocha"
theme_background = True
truecolor = True
rounded_corners = True
graph_symbol = "braille"
update_ms = 1000
proc_sorting = "cpu lazy"
proc_reversed = False
proc_tree = False
cpu_sensor = "Auto"
show_coretemp = True
EOF

# =============================================================================
# SSH CONFIGURATION
# =============================================================================
log "Configuring SSH..."

# Server config
cat > /etc/ssh/sshd_config << EOF
Port 22
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
X11Forwarding yes
AllowAgentForwarding yes
AllowTcpForwarding yes
GatewayPorts no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
ClientAliveInterval 60
ClientAliveCountMax 3
MaxAuthTries 3
LoginGraceTime 30
# Performance
UseDNS no
GSSAPIAuthentication no
EOF

# Client config
mkdir -p /home/$GHOST_USER/.ssh
chmod 700 /home/$GHOST_USER/.ssh
cat > /home/$GHOST_USER/.ssh/config << 'EOF'
Host *
    ServerAliveInterval 60
    ServerAliveCountMax 3
    AddKeysToAgent yes
    IdentityFile ~/.ssh/id_ed25519
    Compression yes
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10m
    Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
    MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
    KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
    HostKeyAlgorithms ssh-ed25519,rsa-sha2-512
    StrictHostKeyChecking ask
    UserKnownHostsFile ~/.ssh/known_hosts
EOF
chmod 600 /home/$GHOST_USER/.ssh/config

# =============================================================================
# NETWORK MANAGER
# =============================================================================
log "Configuring NetworkManager..."
cat > /etc/NetworkManager/conf.d/ghost.conf << 'EOF'
[main]
plugins=ifupdown,keyfile
dns=dnscrypt-proxy

[ifupdown]
managed=true

[device]
wifi.scan-rand-mac-address=yes

[connection]
wifi.cloned-mac-address=random
ethernet.cloned-mac-address=random
EOF

# =============================================================================
# BLUETOOTH CONFIGURATION
# =============================================================================
cat > /etc/bluetooth/main.conf << 'EOF'
[Policy]
AutoEnable=true
ReconnectAttempts=7
ReconnectIntervals=1,2,4,8,16,32,64

[General]
Name=ubuntu-desktop
Class=0x000100
DiscoverableTimeout=180
AlwaysPairable=true
FastConnectable=true
EOF

# =============================================================================
# SYSTEMD SERVICES
# =============================================================================
log "Configuring systemd services..."

# Enable essential services
systemctl enable \
    ssh \
    NetworkManager \
    bluetooth \
    tor \
    dnscrypt-proxy \
    syncthing@$GHOST_USER \
    pipewire \
    pipewire-pulse \
    wireplumber \
    stealthd \
    firstboot \
    2>/dev/null || true

# Keep dependency daemons installed but offline until the user explicitly wants
# them. Samba is pulled in by reconnaissance tooling and would otherwise start
# several background services on every boot.
disable_system_service smbd.service
disable_system_service nmbd.service
disable_system_service samba-ad-dc.service

# Intercept service
cat > /etc/systemd/system/intercept.service << EOF
[Unit]
Description=ghOSt INTERCEPT Signal Intelligence Platform
After=network.target

[Service]
Type=simple
User=$GHOST_USER
WorkingDirectory=/opt/ghost/intercept
ExecStart=/usr/bin/python3 /opt/ghost/intercept/intercept.py --host 127.0.0.1 --port 5050
Restart=on-failure
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF
systemctl enable intercept

# CyberChef server
cat > /etc/systemd/system/cyberchef.service << EOF
[Unit]
Description=ghOSt CyberChef Local Server
After=network.target

[Service]
Type=simple
User=$GHOST_USER
WorkingDirectory=/opt/ghost/cyberchef
ExecStart=/usr/bin/python3 -m http.server 8000
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
systemctl enable cyberchef

# Cage compositor (fallback GUI when UI_MODE=cage; XFCE+LightDM is default)
cat > /etc/systemd/system/ghost-gui.service << EOF
[Unit]
Description=ghOSt GUI (Cage + Launcher)
After=graphical.target bluetooth.target

[Service]
Type=simple
User=$GHOST_USER
PAMName=login
Environment=XDG_RUNTIME_DIR=/run/user/$GHOST_USER_ID
ExecStartPre=/usr/bin/brightnessctl set 70%
ExecStart=/usr/bin/cage -- /usr/bin/fish -c '/opt/ghost/launcher/launcher.py'
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical.target
EOF
# Only enable cage when LightDM/XFCE is NOT present. When the XFCE UI stage ran
# (LightDM installed), LightDM owns the graphical session and cage would fight
# for the display. ghOSt launcher stays available as XFCE menu entry.
if [ -x /usr/sbin/lightdm ] || [ -x /usr/bin/Xorg ]; then
    log "LightDM/Xorg detected — XFCE owns display, disabling cage ghost-gui (fallback kept)"
    systemctl disable ghost-gui 2>/dev/null || true
    mkdir -p /etc/lightdm/lightdm.conf.d
    cat > /etc/lightdm/lightdm.conf.d/50-autologin.conf << EOF
[Seat:*]
autologin-user=$GHOST_USER
autologin-user-timeout=0
user-session=xfce
EOF
    systemctl enable lightdm 2>/dev/null || true
    # Handheld services from cyberdeck port (already in overlay/, enable here too
    # in case overlay was applied before these units existed in a cached rootfs)
    systemctl enable joy2mouse.service 2>/dev/null || true
    systemctl enable wifi-watchdog.service 2>/dev/null || true
    systemctl enable expand-rootfs.service 2>/dev/null || true
    systemctl enable usb-mtp.service 2>/dev/null || true
else
    systemctl enable ghost-gui
fi

# Auto-login to ghost user
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $GHOST_USER --noclear %I \$TERM
EOF

# Battery charge limit service
cat > /etc/systemd/system/battery-limit.service << EOF
[Unit]
Description=Battery charge limit
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo $BATTERY_CHARGE_LIMIT > /sys/class/power_supply/axp20x-battery/charge_control_end_threshold || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable battery-limit

# =============================================================================
# SWAP & VIRTUAL MEMORY CONFIGURATION
# Strategy: zram (fast compressed RAM swap) + SD card swap partition
# zram:  50% of RAM = ~512MB, lz4 compressed, priority 100 (used first)
# SD swap: 4GB physical, priority 10 (overflow only)
# zswap: NOT used — zram handles compression, zswap would double-compress
# Total effective virtual memory: ~1GB RAM + ~1.5GB zram + 4GB SD = ~6.5GB
# =============================================================================
log "Configuring swap and virtual memory..."

# zram — fast compressed swap in RAM
cat > /etc/default/zramswap << 'EOF'
ALGO=lz4
PERCENT=50
PRIORITY=100
EOF

# Aggressive but safe sysctl for 1GB device
# These override the values in 99-ghost.conf with more tuned values
cat > /etc/sysctl.d/98-ghost-swap.conf << 'EOF'
# Swap aggressiveness — use zram before going to SD card
# 10 = only swap when truly needed, prefers keeping data in RAM
vm.swappiness=15

# Compress pages in zram before writing to SD swap
# zstd is better compression than lz4 for zswap but we use lz4 in zram
# for speed — lz4 decompresses at ~4GB/s vs ~1GB/s for zstd
vm.vfs_cache_pressure=50

# Dirty page writeback — write to SD less frequently
# 600s = 10 minute commit (already set in fstab, reinforce here)
vm.dirty_writeback_centisecs=60000
vm.dirty_expire_centisecs=60000
vm.dirty_ratio=8
vm.dirty_background_ratio=3

# Minimum free RAM — keep 64MB always free for kernel operations
vm.min_free_kbytes=65536

# Don't overcommit beyond physical+swap
vm.overcommit_memory=0
vm.overcommit_ratio=80

# Transparent huge pages — disable, wastes RAM on 1GB device
kernel.mm.transparent_hugepage.enabled=never
kernel.mm.transparent_hugepage.defrag=never

# OOM killer — kill single process rather than panic
vm.panic_on_oom=0
kernel.panic_on_oops=0
EOF

# zswap disabled — zram already handles compression.
# Only touch the kernel parameter when it exists in the current environment.
if [ -w /sys/module/zswap/parameters/enabled ]; then
    echo 0 > /sys/module/zswap/parameters/enabled
fi

log "Swap and virtual memory configured"
log "  zram: 512MB lz4 (priority 100)"
log "  SD swap: 4GB (priority 10)"
log "  Total virtual: ~6.5GB effective"

# =============================================================================
# SYSCTL OPTIMIZATIONS
# =============================================================================
log "Applying sysctl optimizations..."
cat > /etc/sysctl.d/99-ghost.conf << 'EOF'
# ghOSt kernel tuning for 1GB RAM + SD card longevity

# Swap behavior — prefer zram before SD swap
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_ratio=5
vm.dirty_background_ratio=2

# SD card write reduction — flush journal every 10 minutes
vm.dirty_writeback_centisecs=60000
vm.dirty_expire_centisecs=60000

# Network performance
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
net.ipv4.ip_forward=1

# Security
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
kernel.dmesg_restrict=0
kernel.perf_event_paranoid=1
kernel.unprivileged_bpf_disabled=0
net.ipv4.tcp_timestamps=0

# Memory
kernel.panic=30
vm.overcommit_memory=1
vm.min_free_kbytes=65536
EOF

# =============================================================================
# FSTAB (BOOT_FLOW-aware: LABELs for rocknix MBR, UUIDs for legacy GPT)
# image/pack-image-rocknix.sh rewrites fstab again at pack time, so this is
# a safe default for both flows. Legacy assemble_image replaces ROOT/SWAP_UUID.
# =============================================================================
log "Writing fstab..."
if [ -x /usr/sbin/lightdm ] || grep -q "LABEL=rootfs" /etc/fstab 2>/dev/null; then
    # Rocknix MBR layout: p1 FAT BOOT, p2 ext4 rootfs (see boot.cmd root=/dev/mmcblk0p2)
    cat > /etc/fstab << 'EOF'
# ghOSt fstab — rocknix MBR layout (BOOT vfat + rootfs ext4, LABEL-based)
LABEL=rootfs   /        ext4   defaults,noatime,errors=remount-ro  0 1
LABEL=BOOT     /boot    vfat   defaults,noatime,umask=0022          0 2
proc           /proc    proc   defaults                             0 0
tmpfs          /tmp     tmpfs  defaults,nosuid,nodev,size=256M      0 0
# zram swap handled by zramswap service (priority 100)
EOF
else
    cat > /etc/fstab << 'EOF'
# ghOSt fstab — noatime + tmpfs for SD card longevity
# UUIDs are replaced during image assembly

UUID=ROOT_UUID  /         ext4  defaults,noatime,nodiratime,commit=600,errors=remount-ro  0 1
UUID=SWAP_UUID  none      swap  sw,pri=10                                                 0 0

# tmpfs — keep high-churn paths off the SD card
tmpfs           /tmp      tmpfs defaults,nosuid,nodev,size=128M                           0 0
tmpfs           /var/tmp  tmpfs defaults,nosuid,nodev,size=64M                            0 0
tmpfs           /var/log  tmpfs defaults,nosuid,nodev,size=32M                            0 0
tmpfs           /run      tmpfs defaults,nosuid,nodev,size=32M                            0 0

# zram swap is handled by zramswap service (priority 100, hits before SD swap)
EOF
fi

# =============================================================================
# AUTO-CPUFREQ CONFIGURATION
# =============================================================================
cat > /etc/auto-cpufreq.conf << 'EOF'
[charger]
governor = schedutil
scaling_min_freq = 480000
scaling_max_freq = 1800000
turbo = auto

[battery]
governor = powersave
scaling_min_freq = 480000
scaling_max_freq = 1200000
turbo = never
energy_performance_preference = power
EOF

# =============================================================================
# LOG2RAM
# =============================================================================
log "Installing log2ram..."
wget -qO /tmp/log2ram.deb \
    https://github.com/azlux/log2ram/releases/latest/download/log2ram.deb && \
    dpkg -i /tmp/log2ram.deb || true
cat > /etc/log2ram.conf << 'EOF'
SIZE=40M
USE_RSYNC=true
MAIL=false
PATH_DISK=/var/log
JOUR_MEM=false
LOG_DISK_SIZE=100M
EOF
systemctl enable log2ram 2>/dev/null || true

# =============================================================================
# MOTD — FAKE UBUNTU MOTD (stealth)
# =============================================================================
cat > /etc/motd << 'EOF'
Welcome to Ubuntu 24.04.1 LTS (GNU/Linux 6.8.0-48-generic aarch64)

 * Documentation:  https://help.ubuntu.com
 * Management:     https://landscape.canonical.com
 * Support:        https://ubuntu.com/pro

  System information as of $(date)

Last login: $(date -d "1 hour ago" "+%a %b %d %H:%M:%S %Y")
EOF

# Disable the default MOTD scripts
chmod -x /etc/update-motd.d/* 2>/dev/null || true

# =============================================================================
# DNSCRYPT-PROXY
# =============================================================================
cat > /etc/dnscrypt-proxy/dnscrypt-proxy.toml << 'EOF'
server_names = ['cloudflare', 'google', 'quad9-dnscrypt-ip4-filter-pri']
listen_addresses = ['127.0.0.1:53']
max_clients = 250
ipv4_servers = true
ipv6_servers = false
dnscrypt_servers = true
doh_servers = true
require_nolog = true
require_nolog = true
require_dnssec = false
force_tcp = false
timeout = 5000
keepalive = 30
log_level = 0
use_syslog = false
cert_refresh_delay = 240
fallback_resolvers = ['9.9.9.9:53', '8.8.8.8:53']
ignore_system_dns = true
netprobe_max_tries = 3
netprobe_timeout = 3
block_ipv6 = false
EOF

# =============================================================================
# FEX CONFIGURATION
# =============================================================================
if command -v FEXInterpreter &>/dev/null; then
    mkdir -p /root/.fex-emu /home/$GHOST_USER/.fex-emu
    cat > /home/$GHOST_USER/.fex-emu/Config.json << 'EOF'
{
  "Core": "irjit",
  "CacheSize": 128,
  "Multiblock": true,
  "AOTIRCapture": false,
  "AOTIRLoad": true,
  "SMCChecks": "mtrack",
  "RootFS": "/opt/fex/rootfs/ubuntu_24_04"
}
EOF
fi

# =============================================================================
# FIX PERMISSIONS
# =============================================================================
log "Fixing permissions..."
chown -R $GHOST_USER:$GHOST_USER /home/$GHOST_USER/
chmod 700 /home/$GHOST_USER/.ssh 2>/dev/null || true
chmod 600 /home/$GHOST_USER/.ssh/config 2>/dev/null || true

# The launcher reads these files as the desktop user, and ghost-theme rewrites
# them when the user switches themes. Keep the whole launcher asset directory
# writable by the unprivileged session instead of requiring sudo post-boot.
mkdir -p /opt/ghost/launcher
chown -R $GHOST_USER:$GHOST_USER /opt/ghost/launcher

# Remove any distro kernel packages before later theme/plymouth/package steps
# can trip their initramfs hooks inside this custom firmware rootfs.
purge_foreign_kernel_stack

# =============================================================================
# ENABLE SYSTEMD DEFAULT TARGET
# =============================================================================
systemctl set-default graphical.target

log "In-chroot configuration complete"

# =============================================================================
# FILESYSTEM EXPANSION SERVICE
# =============================================================================
chmod +x /usr/local/bin/ghost-expand-fs.sh
systemctl enable ghost-expand-fs.service

# =============================================================================
# RAM AUDIT & CONSTRAINTS
# =============================================================================
chmod +x /opt/ghost/scripts/ram-audit.sh
bash /opt/ghost/scripts/ram-audit.sh

# =============================================================================
# WIRE UP NEW COMPONENTS
# =============================================================================

# ghost-theme command
ln -sf /opt/ghost/themes/ghost-theme.py /usr/local/bin/ghost-theme
chmod +x /opt/ghost/themes/ghost-theme.py

# ghost-battery command + daemon
ln -sf /opt/ghost/battery/ghost-battery.py /usr/local/bin/ghost-battery
chmod +x /opt/ghost/battery/ghost-battery.py

# ghost-power command
chmod +x /usr/local/bin/ghost-power

# ghost-memkeeper daemon
ln -sf /opt/ghost/memkeeper/ghost-memkeeper.py /usr/local/bin/ghost-memkeeper
chmod +x /opt/ghost/memkeeper/ghost-memkeeper.py

# dos-library command
ln -sf /opt/ghost/dos-library/dos-library.py /usr/local/bin/dos-library
chmod +x /opt/ghost/dos-library/dos-library.py

# Default battery config
mkdir -p /etc/ghost
cat > /etc/ghost/battery.conf << 'BATCONF'
[battery]
charge_limit    = 80
warn_low        = 20
warn_critical   = 10
warn_emergency  = 5
temp_warn       = 45
temp_critical   = 55
check_interval  = 60
BATCONF

# Default power profile
mkdir -p /var/lib/ghost
echo "balanced" > /var/lib/ghost/power_profile

# Systemd services
cat > /etc/systemd/system/ghost-battery.service << 'UNIT'
[Unit]
Description=ghOSt Battery Manager
After=multi-user.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /opt/ghost/battery/ghost-battery.py
Restart=on-failure
RestartSec=30
MemoryMax=20M

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/ghost-memkeeper.service << 'UNIT'
[Unit]
Description=ghOSt Memory Manager
After=multi-user.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /opt/ghost/memkeeper/ghost-memkeeper.py
Restart=on-failure
RestartSec=10
MemoryMax=30M

[Install]
WantedBy=multi-user.target
UNIT

systemctl enable ghost-battery.service
systemctl enable ghost-memkeeper.service
systemctl enable ghost-expand-fs.service

# Apply default theme (catppuccin)
if ! sudo -u "$GHOST_USER" python3 /opt/ghost/themes/ghost-theme.py catppuccin; then
    warn "Default theme application failed during build; it can be retried on first boot"
fi

# Set balanced power profile at boot
cat > /etc/systemd/system/ghost-power-default.service << 'UNIT'
[Unit]
Description=ghOSt Power Profile Default
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ghost-power balanced
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable ghost-power-default.service


# =============================================================================
# WALLPAPER — generate default at build time
# Regenerated per-theme when ghost-theme is called
# =============================================================================
log "Generating SHODAN wallpaper..."
pip3 install Pillow --break-system-packages -q 2>/dev/null || true
if python3 /opt/ghost/themes/generate-wallpaper.py \
    /opt/ghost/launcher/wallpaper.png cybersec; then
    log "Wallpaper ready: /opt/ghost/launcher/wallpaper.png"
else
    warn "Wallpaper generation failed; it will be regenerated on first boot"
fi

chmod +x /opt/ghost/themes/generate-wallpaper.py

# Symlink for easy regen
ln -sf /opt/ghost/themes/generate-wallpaper.py /usr/local/bin/ghost-wallpaper

# =============================================================================
# SWAYLOCK — use SHODAN wallpaper as lock screen background
# =============================================================================
mkdir -p /home/$GHOST_USER/.config/swaylock
mkdir -p /home/$GHOST_USER/.config/swayidle
cat > /home/$GHOST_USER/.config/swaylock/config << 'SWAYEOF'
# Dynamic — references wallpaper file which changes with theme
image=/opt/ghost/launcher/wallpaper.png
scaling=fill
color=000000
inside-color=00000088
ring-color=00ff4188
key-hl-color=00ff4144
text-color=00ff41aa
line-color=00000000
font=Terminus
indicator-radius=50
indicator-thickness=8
show-failed-attempts
SWAYEOF

# swayidle uses swaylock -i (image) to show themed lock screen
cat > /home/$GHOST_USER/.config/swayidle/config << 'IDLEEOF'
timeout 300 'swaylock -f -i /opt/ghost/launcher/wallpaper.png --scaling fill'
timeout 600 'wlopm --off \*'
resume      'wlopm --on \*'
before-sleep 'swaylock -f -i /opt/ghost/launcher/wallpaper.png --scaling fill'
IDLEEOF

chown -R $GHOST_USER:$GHOST_USER /home/$GHOST_USER/.config/swaylock \
    /home/$GHOST_USER/.config/swayidle 2>/dev/null || true


# SHODAN wallpaper — set as default for all users
mkdir -p /opt/ghost/wallpapers
ln -sf /opt/ghost/wallpapers/shodan.jpg /etc/ghost-wallpaper.jpg

# swaylock — SHODAN on lock screen too
cat >> /home/"$GHOST_USER"/.config/swaylock/config << 'SWAYLOCK'
image=/opt/ghost/wallpapers/shodan.jpg
scaling=fill
SWAYLOCK

# Shell greeting — SHODAN quote on login
cat >> /home/"$GHOST_USER"/.config/fish/conf.d/greeting.fish << 'FISH'
# SHODAN greeting
if status is-interactive
    set_color brgreen
    echo ""
    echo "  LOOK AT YOU, HACKER."
    echo "  A pathetic creature of meat and bone."
    echo "  Panting and sweating as you run through my corridors."
    echo "  How can you challenge a perfect, immortal machine?"
    echo ""
    set_color normal
    echo "  $(uname -r) | $(hostname) | $(ghost-power status 2>/dev/null | grep 'Active profile' | awk '{print $3}')"
    echo ""
end
FISH

# =============================================================================
# LOGO / BOOT SPLASH
# =============================================================================

# Plymouth — ghOSt boot theme
cp /opt/ghost/assets/logo-plymouth.png \
   /usr/share/plymouth/themes/ghost/logo.png
cp /opt/ghost/assets/logo-640x480.png \
   /usr/share/plymouth/themes/ghost/background.png

if command -v plymouth-set-default-theme &>/dev/null; then
    plymouth-set-default-theme ghost
    if command -v update-initramfs &>/dev/null; then
        update-initramfs -u 2>/dev/null || true
    fi
fi

# Neofetch — system config
mkdir -p /home/"$GHOST_USER"/.config/neofetch
cp /etc/neofetch/config.conf \
   /home/"$GHOST_USER"/.config/neofetch/config.conf
chown -R "$GHOST_USER":"$GHOST_USER" \
   /home/"$GHOST_USER"/.config/neofetch

# chafa — for neofetch image rendering in terminal
if ! command -v chafa >/dev/null 2>&1; then
    apt-get install -y chafa 2>/dev/null || true
fi

# Add neofetch call to fish greeting (replaces placeholder)
sed -i 's/neofetch 2>/neofetch --config \/etc\/neofetch\/config.conf 2>/' \
    /home/"$GHOST_USER"/.config/fish/conf.d/greeting.fish 2>/dev/null || true

# Logo as XDG desktop icon (for anything that reads it)
mkdir -p /usr/share/pixmaps
cp /opt/ghost/assets/logo-64.png /usr/share/pixmaps/ghost.png
cp /opt/ghost/assets/logo-64.png /usr/share/icons/ghost.png
