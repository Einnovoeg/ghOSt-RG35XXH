#!/usr/bin/env bash
# =============================================================================
# ghOSt Boot Asset Stager — Allwinner H700 (RG35XXH)
#
# KNULLI ships known-good RG35XXH boot partitions and matching 4.9.170
# runtime modules in its distribution tree. We stage those assets directly
# for this branch instead of rebuilding the vendor boot chain in-tree.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/../config.sh"

log()   { echo -e "\033[0;32m[KERNEL]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m   $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m  $*"; exit 1; }

KNULLI_SRC="$KERNEL_BUILD_DIR/knulli-distribution"
STAGED_ROOTFS_OVERLAY="$KERNEL_BUILD_DIR/rootfs-overlay"

# =============================================================================
reset_dir_contents() {
    local dir="$1"
    mkdir -p "$dir"
    find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
}

git_retry() {
    local attempt=1
    local max_attempts=5

    while (( attempt <= max_attempts )); do
        if GIT_TERMINAL_PROMPT=0 timeout 600 git \
            -c http.version=HTTP/1.1 \
            -c http.lowSpeedLimit=1000 \
            -c http.lowSpeedTime=30 \
            "$@"; then
            return 0
        fi

        warn "Git command failed (attempt ${attempt}/${max_attempts}), retrying..."
        sleep $(( attempt * 5 ))
        attempt=$(( attempt + 1 ))
    done

    return 1
}

# =============================================================================
fetch_knulli_distribution() {
    if [[ -d "$KNULLI_SRC/.git" ]]; then
        log "Refreshing KNULLI distribution checkout..."
        if ! git_retry -C "$KNULLI_SRC" remote set-url origin "$KNULLI_DIST_REPO" || \
           ! git_retry -C "$KNULLI_SRC" fetch --depth=1 --no-tags origin "$KNULLI_DIST_BRANCH" || \
           ! git -C "$KNULLI_SRC" checkout -f FETCH_HEAD; then
            warn "Cached KNULLI checkout is unusable, recloning..."
            reset_dir_contents "$KNULLI_SRC"
        fi
    fi

    if [[ ! -d "$KNULLI_SRC/.git" ]]; then
        reset_dir_contents "$KNULLI_SRC"
        log "Cloning KNULLI distribution assets..."
        git_retry clone --depth=1 --no-tags --single-branch --sparse \
            -b "$KNULLI_DIST_BRANCH" "$KNULLI_DIST_REPO" "$KNULLI_SRC" || \
            error "Failed to clone KNULLI distribution from $KNULLI_DIST_REPO"
    fi

    git -C "$KNULLI_SRC" sparse-checkout set \
        "$KNULLI_H700_BOARD_PATH" \
        "$KNULLI_H700_COMMON_PATH/fsoverlay/lib/firmware" \
        "$KNULLI_H700_COMMON_PATH/fsoverlay/lib/modules"
}

# =============================================================================
stage_knulli_boot_assets() {
    local board_dir="$KNULLI_SRC/$KNULLI_H700_BOARD_PATH"
    local part_dir="$board_dir/partitions"

    [[ -f "$part_dir/boot0.img" ]] || error "Missing KNULLI boot0.img"
    [[ -f "$part_dir/boot_package.fex" ]] || error "Missing KNULLI boot_package.fex"
    [[ -f "$part_dir/boot.img" ]] || error "Missing KNULLI boot.img"
    [[ -f "$part_dir/env.img" ]] || error "Missing KNULLI env.img"

    mkdir -p "$KERNEL_BUILD_DIR"
    cp "$part_dir/boot0.img" "$KERNEL_BUILD_DIR/"
    cp "$part_dir/boot_package.fex" "$KERNEL_BUILD_DIR/"
    cp "$part_dir/boot.img" "$KERNEL_BUILD_DIR/"
    cp "$part_dir/env.img" "$KERNEL_BUILD_DIR/"

    log "Staged RG35XXH boot chain artifacts"
}

# =============================================================================
stage_knulli_runtime() {
    local common_dir="$KNULLI_SRC/$KNULLI_H700_COMMON_PATH/fsoverlay"

    mkdir -p "$STAGED_ROOTFS_OVERLAY/lib"

    if [[ -d "$common_dir/lib/firmware" ]]; then
        rsync -a "$common_dir/lib/firmware/" "$STAGED_ROOTFS_OVERLAY/lib/firmware/"
    fi

    if [[ -d "$common_dir/lib/modules" ]]; then
        rsync -a "$common_dir/lib/modules/" "$STAGED_ROOTFS_OVERLAY/lib/modules/"
    fi

    log "Staged KNULLI runtime modules and firmware"
}

# =============================================================================
configure_kernel() {
    log "Configuring kernel with KNULLI base + ghOSt additions..."
    cd "$KERNEL_SRC"
    make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig

    # Security / networking
    scripts/config --enable  CONFIG_TUN
    scripts/config --enable  CONFIG_VETH
    scripts/config --enable  CONFIG_BRIDGE
    scripts/config --enable  CONFIG_NF_TABLES
    scripts/config --enable  CONFIG_IP_NF_NAT
    scripts/config --enable  CONFIG_BPF_SYSCALL
    scripts/config --enable  CONFIG_USER_NS
    scripts/config --enable  CONFIG_NET_NS
    scripts/config --enable  CONFIG_PID_NS
    scripts/config --enable  CONFIG_OVERLAY_FS
    scripts/config --enable  CONFIG_ZRAM
    scripts/config --enable  CONFIG_ZSMALLOC
    scripts/config --enable  CONFIG_CRYPTO_LZ4

    # SDR drivers
    scripts/config --enable  CONFIG_MEDIA_USB_SUPPORT
    scripts/config --enable  CONFIG_MEDIA_SDR_SUPPORT
    scripts/config --enable  CONFIG_MEDIA_DIGITAL_TV_SUPPORT
    scripts/config --module  CONFIG_DVB_USB_RTL28XXU
    scripts/config --module  CONFIG_DVB_USB_RTL2832
    scripts/config --module  CONFIG_DVB_USB_RTL2832_SDR
    scripts/config --module  CONFIG_USB_AIRSPY
    scripts/config --module  CONFIG_USB_HACKRF

    # WiFi pentest (monitor + injection)
    scripts/config --module  CONFIG_RTL8187
    scripts/config --module  CONFIG_R8188EU
    scripts/config --module  CONFIG_ATH9K_HTC
    scripts/config --module  CONFIG_RT2800USB
    scripts/config --module  CONFIG_MT7601U
    scripts/config --enable  CONFIG_MAC80211_MONITOR
    scripts/config --enable  CONFIG_CFG80211_WEXT

    # USB serial (hardware hacking tools)
    scripts/config --module  CONFIG_USB_SERIAL_FTDI_SIO
    scripts/config --module  CONFIG_USB_SERIAL_CH341
    scripts/config --module  CONFIG_USB_SERIAL_CP210X
    scripts/config --module  CONFIG_USB_SERIAL_PL2303

    # USB ethernet
    scripts/config --module  CONFIG_USB_NET_AX88179_178A
    scripts/config --module  CONFIG_USB_NET_CDC_NCM
    scripts/config --module  CONFIG_USB_RTL8152

    # Controllers
    scripts/config --enable  CONFIG_USB_HID
    scripts/config --enable  CONFIG_INPUT_UINPUT
    scripts/config --module  CONFIG_JOYSTICK_XPAD
    scripts/config --module  CONFIG_HID_SONY
    scripts/config --module  CONFIG_HID_NINTENDO

    # Bluetooth
    scripts/config --module  CONFIG_BT_HCIBTUSB
    scripts/config --module  CONFIG_BT_HCIBTUSB_RTL
    scripts/config --enable  CONFIG_BT_RFCOMM
    scripts/config --enable  CONFIG_BT_LE

    make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
    log "Kernel configured"
}

# =============================================================================
stage_knulli_build() {
    fetch_knulli_distribution
    stage_knulli_boot_assets
    stage_knulli_runtime

    log "Boot asset staging complete"
    log "  boot0:         $KERNEL_BUILD_DIR/boot0.img"
    log "  boot package:  $KERNEL_BUILD_DIR/boot_package.fex"
    log "  boot partition:$KERNEL_BUILD_DIR/boot.img"
    log "  env partition: $KERNEL_BUILD_DIR/env.img"
}

# =============================================================================
stage_knulli_build
