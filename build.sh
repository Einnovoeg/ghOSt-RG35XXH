#!/usr/bin/env bash
# =============================================================================
#  ██████╗ ██╗  ██╗ ██████╗ ███████╗████████╗
# ██╔════╝ ██║  ██║██╔═══██╗██╔════╝╚══██╔══╝
# ██║  ███╗███████║██║   ██║███████╗   ██║
# ██║   ██║██╔══██║██║   ██║╚════██║   ██║
# ╚██████╔╝██║  ██║╚██████╔╝███████║   ██║
#  ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝   ╚═╝
#
# Handheld Security and Signal Terminal
# Build Script v1.0
# Target: Anbernic RG35XXH (Allwinner H700)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${GREEN}[ghOSt]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${CYAN}${BOLD}━━━ $* ━━━${NC}\n"; }

is_enabled() {
    case "${1:-false}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

ensure_arm64_loader_link() {
    local loader_link="$ROOTFS_DIR/lib/ld-linux-aarch64.so.1"
    local loader_target="../usr/lib/ld-linux-aarch64.so.1"
    local multiarch_link="$ROOTFS_DIR/lib/aarch64-linux-gnu"
    local multiarch_target="../usr/lib/aarch64-linux-gnu"
    local current_target=""

    # The later configure-stage chroot runs outside the rootfs builder script,
    # so repair the canonical loader path here as well before invoking qemu.
    [[ -e "$ROOTFS_DIR/usr/lib/ld-linux-aarch64.so.1" ]] || return 0

    mkdir -p "$ROOTFS_DIR/lib"

    if [[ -L "$loader_link" ]]; then
        current_target=$(readlink "$loader_link" || true)
        if [[ "$current_target" != "$loader_target" ]] && \
           [[ "$current_target" != "/usr/lib/ld-linux-aarch64.so.1" ]]; then
            rm -f "$loader_link"
        fi
    fi

    if [[ ! -e "$loader_link" ]]; then
        ln -s "$loader_target" "$loader_link"
    fi

    if [[ -L "$multiarch_link" ]]; then
        current_target=$(readlink "$multiarch_link" || true)
        if [[ "$current_target" != "$multiarch_target" ]] && \
           [[ "$current_target" != "/usr/lib/aarch64-linux-gnu" ]]; then
            rm -f "$multiarch_link"
        fi
    elif [[ -d "$multiarch_link" ]] && [[ ! -e "$multiarch_link/ld-linux-aarch64.so.1" ]]; then
        rm -rf "$multiarch_link"
    fi

    if [[ ! -e "$multiarch_link" ]] && [[ -d "$ROOTFS_DIR/usr/lib/aarch64-linux-gnu" ]]; then
        ln -s "$multiarch_target" "$multiarch_link"
    fi
}

wait_for_block_device() {
    local device="$1"
    local label="${2:-$1}"
    local attempt
    local size=""

    # Device-mapper nodes can appear before the kernel reports a readable size.
    # Wait until blkgetsize succeeds so mkfs does not fail on a transient EPERM.
    for attempt in {1..20}; do
        if [[ -b "$device" ]] && size=$(blockdev --getsize64 "$device" 2>/dev/null); then
            if [[ "$size" -gt 0 ]]; then
                log "Ready: ${label} (${size} bytes)"
                return 0
            fi
        fi
        sleep 1
    done

    return 1
}

# =============================================================================
# PREFLIGHT CHECKS
# =============================================================================
preflight() {
    section "Preflight Checks"

    [[ "$(id -u)" == "0" ]] || error "Must run as root (sudo ./build.sh)"

    local required_tools=(
        debootstrap qemu-user-static binfmt-support
        parted kpartx rsync git wget curl
        python3 python3-pip make gcc flex bison bc
        libssl-dev libelf-dev lzop u-boot-tools
        crossbuild-essential-arm64 gcc-aarch64-linux-gnu
        zip unzip xz-utils lz4 zstd pv
    )

    log "Checking required host tools..."
    local missing=()
    for tool in "${required_tools[@]}"; do
        if ! dpkg -l "$tool" &>/dev/null; then
            missing+=("$tool")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Installing missing tools: ${missing[*]}"
        apt-get update -qq
        apt-get install -y "${missing[@]}"
    fi

    log "Checking disk space (need ~${MIN_DISK_GB}GB free)..."
    local free_gb
    free_gb=$(df -BG "$BUILD_DIR" | awk 'NR==2 {print $4}' | tr -d 'G')
    [[ "$free_gb" -ge "$MIN_DISK_GB" ]] || \
        error "Need ${MIN_DISK_GB}GB free, only ${free_gb}GB available in $BUILD_DIR"

    log "Checking RAM (need ~${MIN_RAM_GB}GB for build)..."
    local ram_gb
    ram_gb=$(free -g | awk '/^Mem:/{print $2}')
    [[ "$ram_gb" -ge "$MIN_RAM_GB" ]] || \
        warn "Low RAM (${ram_gb}GB), build may be slow"

    # Register ARM64 binfmt
    update-binfmts --enable qemu-aarch64 2>/dev/null || true
    cp /usr/bin/qemu-aarch64-static "$ROOTFS_DIR/usr/bin/" 2>/dev/null || true

    # Network check — needed to clone kernel source
    log "Checking network (needed for kernel clone)..."
    if ! curl -sf --max-time 10 https://github.com 2>/dev/null | grep -q "github"; then
        if ! wget -q --timeout=10 --spider https://github.com 2>/dev/null; then
            warn "Cannot reach github.com — kernel clone may fail"
            warn "If cached kernel source exists in volumes, build will continue"
            warn "Otherwise: check Docker network settings in docker-compose.yml"
        fi
    fi

    log "Preflight OK"
}

# =============================================================================
# STEP 1: KERNEL BUILD (BOOT_FLOW dispatch — rocknix boots, legacy does not)
# =============================================================================
build_kernel() {
    if [[ "${BOOT_FLOW:-rocknix}" == "rocknix" ]]; then
        section "Building H700 Kernel (ROCKNIX mainline — proven boot path)"
        bash "$SCRIPT_DIR/kernel/build-rocknix.sh" all
        if command -v docker >/dev/null 2>&1; then
            bash "$SCRIPT_DIR/scripts/build-joypad-module.sh" || \
                warn "Joypad module build failed — joy2mouse will retry at boot"
        else
            warn "Docker unavailable — skipping joypad .ko (CI builds it)"
        fi
        log "Kernel build complete"
    else
        section "Building H700 Kernel (LEGACY KNULLI 4.9 — experimental)"
        warn "BOOT_FLOW=legacy does not boot reliably; use rocknix for flashing."
        bash "$SCRIPT_DIR/kernel/build-kernel.sh"
        log "Kernel build complete"
    fi
}

# =============================================================================
# STEP 2: ROOTFS BOOTSTRAP
# =============================================================================
build_rootfs() {
    section "Bootstrapping Debian ${DEBIAN_RELEASE} ARM64 Rootfs"
    bash "$SCRIPT_DIR/rootfs/build-rootfs.sh"
    if is_enabled "${INCLUDE_XFCE:-true}"; then
        section "Installing XFCE UI (cyberdeck port — joystick mouse, LightDM)"
        bash "$SCRIPT_DIR/rootfs/build-ui-xfce.sh" "$ROOTFS_DIR"
    else
        warn "INCLUDE_XFCE=false — keeping cage-only UI (no desktop)"
    fi
    log "Rootfs build complete"
}

# =============================================================================
# STEP 3: APPLY OVERLAY
# =============================================================================
apply_overlay() {
    section "Applying ghOSt Overlay"

    if [[ -d "$KERNEL_BUILD_DIR/rootfs-overlay" ]]; then
        log "Applying staged H700 runtime overlay..."
        rsync -av --chown=root:root "$KERNEL_BUILD_DIR/rootfs-overlay/" "$ROOTFS_DIR/"
    fi

    log "Copying overlay files..."
    rsync -av --chown=root:root "$SCRIPT_DIR/overlay/" "$ROOTFS_DIR/"

    log "Installing launcher..."
    cp -r "$SCRIPT_DIR/launcher/" "$ROOTFS_DIR/opt/ghost/launcher/"
    chmod +x "$ROOTFS_DIR/opt/ghost/launcher/launcher.py"

    log "Installing stealthd..."
    cp -r "$SCRIPT_DIR/stealthd/" "$ROOTFS_DIR/opt/ghost/stealthd/"
    chmod +x "$ROOTFS_DIR/opt/ghost/stealthd/stealthd.py"
    cp "$SCRIPT_DIR/stealthd/stealthd.service" \
       "$ROOTFS_DIR/etc/systemd/system/"

    log "Installing hey AI CLI..."
    cp -r "$SCRIPT_DIR/hey/" "$ROOTFS_DIR/opt/ghost/hey/"
    chmod +x "$ROOTFS_DIR/opt/ghost/hey/hey.py"
    ln -sf /opt/ghost/hey/hey.py "$ROOTFS_DIR/usr/local/bin/hey"

    log "Installing firstboot script..."
    cp "$SCRIPT_DIR/firstboot/firstboot.sh" "$ROOTFS_DIR/usr/local/bin/"
    cp "$SCRIPT_DIR/firstboot/firstboot.service" \
       "$ROOTFS_DIR/etc/systemd/system/"
    chmod +x "$ROOTFS_DIR/usr/local/bin/firstboot.sh"

    log "Overlay applied"
}

# =============================================================================
# STEP 4: IN-CHROOT CONFIGURATION
# =============================================================================
configure_chroot() {
    section "Configuring System (chroot)"
    local chroot_status=0

    cleanup_configure_chroot() {
        umount "$ROOTFS_DIR/tmp"  2>/dev/null || true
        umount "$ROOTFS_DIR/run"  2>/dev/null || true
        umount "$ROOTFS_DIR/sys"  2>/dev/null || true
        umount "$ROOTFS_DIR/proc" 2>/dev/null || true
        umount "$ROOTFS_DIR/dev/pts" 2>/dev/null || true
        umount "$ROOTFS_DIR/dev"  2>/dev/null || true
        rm -f "$ROOTFS_DIR/usr/bin/qemu-aarch64-static"
    }

    mkdir -p \
        "$ROOTFS_DIR/dev" \
        "$ROOTFS_DIR/dev/pts" \
        "$ROOTFS_DIR/proc" \
        "$ROOTFS_DIR/sys" \
        "$ROOTFS_DIR/run" \
        "$ROOTFS_DIR/tmp"

    ensure_arm64_loader_link
    cp /usr/bin/qemu-aarch64-static "$ROOTFS_DIR/usr/bin/"

    # Mount necessary filesystems
    mount --bind /dev "$ROOTFS_DIR/dev"
    mount --bind /dev/pts "$ROOTFS_DIR/dev/pts"
    mount --bind /proc "$ROOTFS_DIR/proc"
    mount --bind /sys "$ROOTFS_DIR/sys"
    mount --bind /run "$ROOTFS_DIR/run"
    mount -t tmpfs tmpfs "$ROOTFS_DIR/tmp"

    # Run chroot configuration script
    chroot "$ROOTFS_DIR" /usr/bin/qemu-aarch64-static \
        /bin/bash /opt/ghost/scripts/configure.sh || chroot_status=$?

    cleanup_configure_chroot

    if (( chroot_status != 0 )); then
        return "$chroot_status"
    fi

    log "Chroot configuration complete"
}

# =============================================================================
# STEP 5: ASSEMBLE IMAGE (BOOT_FLOW dispatch)
# rocknix: MBR + SPL@8KB + FAT BOOT + ext4 rootfs (proven to boot, see
#   docs/PITFALLS-cyberdeck.md). Produces .img + .bmap + .img.xz + SHA256SUMS.
# legacy: GPT + KNULLI boot0/boot_package blobs (kept for experiments).
# =============================================================================
assemble_image() {
    if [[ "${BOOT_FLOW:-rocknix}" == "rocknix" ]]; then
        section "Assembling Flash Image (ROCKNIX MBR — bootable)"
        bash "$SCRIPT_DIR/image/pack-image-rocknix.sh"
        log "Image created in $OUTPUT_DIR (flash: sudo bmaptool copy *.img /dev/sdX)"
        return 0
    fi
    assemble_image_legacy
}

assemble_image_legacy() {
    section "Assembling Flash Image"

    local img="$OUTPUT_DIR/ghOSt-RG35XXH-${GHOST_VERSION}.img"
    local img_size_mb=$(( ROOT_SIZE_MB + SWAP_SIZE_MB + 160 ))
    local boot0_img="$KERNEL_BUILD_DIR/boot0.img"
    local boot_pkg_img="$KERNEL_BUILD_DIR/boot_package.fex"
    local boot_part_img="$KERNEL_BUILD_DIR/boot.img"
    local env_part_img="$KERNEL_BUILD_DIR/env.img"
    local lodev=""
    local root_mnt=""

    [[ -f "$boot0_img" ]] || error "Missing prebuilt boot0 image: $boot0_img"
    [[ -f "$boot_pkg_img" ]] || error "Missing prebuilt boot package: $boot_pkg_img"
    [[ -f "$boot_part_img" ]] || error "Missing prebuilt boot partition image: $boot_part_img"
    [[ -f "$env_part_img" ]] || error "Missing prebuilt env image: $env_part_img"

    cleanup_assemble_image() {
        set +e
        if [[ -n "$root_mnt" ]] && mountpoint -q "$root_mnt" 2>/dev/null; then
            umount "$root_mnt"
        fi
        if [[ -n "$root_mnt" ]] && [[ -d "$root_mnt" ]]; then
            rmdir "$root_mnt" 2>/dev/null || true
        fi
        if [[ -n "$lodev" ]]; then
            kpartx -dv "$lodev" 2>/dev/null || true
            losetup -d "$lodev" 2>/dev/null || true
        fi
    }

    trap cleanup_assemble_image RETURN

    log "Creating image file: $(( img_size_mb / 1024 ))GB..."
    dd if=/dev/null of="$img" bs=1M seek="$img_size_mb" status=progress

    log "Partitioning..."
    parted -s "$img" \
        mklabel gpt \
        mkpart primary 36MiB 56MiB \
        mkpart primary 56MiB 72MiB \
        mkpart primary ext4 72MiB $(( 72 + ROOT_SIZE_MB ))MiB \
        mkpart primary linux-swap $(( 72 + ROOT_SIZE_MB ))MiB 100%

    # Attach loop device
    lodev=$(losetup -f --show -P "$img")
    kpartx -av "$lodev"
    command -v udevadm >/dev/null 2>&1 && udevadm settle || true

    local boot_dev="/dev/mapper/$(basename ${lodev})p1"
    local env_dev="/dev/mapper/$(basename ${lodev})p2"
    local root_dev="/dev/mapper/$(basename ${lodev})p3"
    local swap_dev="/dev/mapper/$(basename ${lodev})p4"

    wait_for_block_device "$boot_dev" "boot partition" || \
        error "Timed out waiting for boot partition device: $boot_dev"
    wait_for_block_device "$env_dev" "env partition" || \
        error "Timed out waiting for env partition device: $env_dev"
    wait_for_block_device "$root_dev" "root partition" || \
        error "Timed out waiting for root partition device: $root_dev"
    wait_for_block_device "$swap_dev" "swap partition" || \
        error "Timed out waiting for swap partition device: $swap_dev"

    log "Formatting partitions..."
    mkfs.ext4 -F -L "GHOST_ROOT" -O "^has_journal" \
              -E "lazy_itable_init=0,lazy_journal_init=0" \
              -m 1 "$root_dev"
    mkswap -L "GHOST_SWAP" "$swap_dev"

    log "Writing H700 boot chain..."
    dd if="$boot0_img" of="$lodev" bs=512 seek=512 conv=notrunc status=progress
    dd if="$boot_pkg_img" of="$lodev" bs=512 seek=32800 conv=notrunc status=progress
    dd if="$boot_part_img" of="$boot_dev" bs=4M conv=fsync status=progress
    dd if="$env_part_img" of="$env_dev" bs=4M conv=fsync status=progress

    log "Writing root filesystem..."
    root_mnt=$(mktemp -d)
    mount -o noatime "$root_dev" "$root_mnt"
    rsync -aHAX --info=progress2 "$ROOTFS_DIR/" "$root_mnt/"

    # Write fstab with correct UUIDs
    local root_uuid swap_uuid
    root_uuid=$(blkid -s UUID -o value "$root_dev")
    swap_uuid=$(blkid -s UUID -o value "$swap_dev")
    sed -i "s/ROOT_UUID/$root_uuid/g; s/SWAP_UUID/$swap_uuid/g" \
        "$root_mnt/etc/fstab"

    cleanup_assemble_image
    trap - RETURN

    log "Compressing image..."
    pv "$img" | gzip -9 > "${img}.gz"
    local size
    size=$(du -h "${img}.gz" | cut -f1)
    rm "$img"

    log "Image created: ${img}.gz (${size})"
    log ""
    log "Recommended flashing:"
    log "  Linux: ./flash_dd_with_gpt.sh"
    log "  macOS: ./flash_dd_with_gpt.MacOS.sh"
    log "Raw dd still works, but the helper scripts also repair GPT after writing."
}

# =============================================================================
# MAIN (+ CI stage dispatch: ./build.sh [all|fetch|docker|kernel|rootfs|image])
# GitHub Actions calls individual stages; local default (no arg) runs all.
# SKIP_* envs still honored for Docker/local iteration.
# =============================================================================
main() {
    local stage="${1:-all}"
    # CI stage-only mode (no preflight banner duplication)
    case "$stage" in
        fetch|docker|kernel|rootfs|image)
            mkdir -p "$BUILD_DIR" "$OUTPUT_DIR" "$ROOTFS_DIR" \
                     "$KERNEL_BUILD_DIR" "$UBOOT_BUILD_DIR"
            case "$stage" in
                fetch)  bash "$SCRIPT_DIR/kernel/build-rocknix.sh" fetch ;;
                docker) bash "$SCRIPT_DIR/kernel/build-rocknix.sh" docker ;;
                kernel) build_kernel ;;
                rootfs)
                    # rootfs stage assumes debootstrap base exists; build full rootfs+UI
                    build_rootfs
                    apply_overlay
                    configure_chroot
                    ;;
                image)  assemble_image ;;
            esac
            return 0
            ;;
        all|"") ;;
        *) error "unknown stage: $stage (try: all|fetch|docker|kernel|rootfs|image)" ;;
    esac

    echo -e "${CYAN}"
    cat << 'EOF'
  ██████╗ ██╗  ██╗ ██████╗ ███████╗████████╗
 ██╔════╝ ██║  ██║██╔═══██╗██╔════╝╚══██╔══╝
 ██║  ███╗███████║██║   ██║███████╗   ██║
 ██║   ██║██╔══██║██║   ██║╚════██║   ██║
 ╚██████╔╝██║  ██║╚██████╔╝███████║   ██║
  ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝   ╚═╝
  Handheld Security and Signal Terminal
EOF
    echo -e "${NC}"
    echo -e "  Device:  ${BOLD}${DEVICE_TARGET}${NC}"
    echo -e "  Version: ${BOLD}${GHOST_VERSION}${NC}"
    echo -e "  Boot:    ${BOLD}${BOOT_FLOW:-rocknix}${NC} (rocknix=boots, legacy=experimental)"
    echo -e "  UI:      ${BOLD}${UI_MODE:-xfce}${NC} (xfce=LightDM desktop, cage=launcher-only)"
    echo -e "  Toolset: ${BOLD}${KALI_SIZE}${NC}"
    echo -e "  Extras:  ${BOLD}${GAMES_PROFILE}${NC}"
    echo ""

    local start_time=$SECONDS

    mkdir -p "$BUILD_DIR" "$OUTPUT_DIR" "$ROOTFS_DIR" \
             "$KERNEL_BUILD_DIR" "$UBOOT_BUILD_DIR"

    preflight

    if is_enabled "${SKIP_KERNEL:-false}"; then
        warn "SKIP_KERNEL is enabled — reusing existing staged kernel assets"
    else
        build_kernel
    fi

    if is_enabled "${SKIP_ROOTFS:-false}"; then
        warn "SKIP_ROOTFS is enabled — reusing existing rootfs"
    else
        build_rootfs
    fi

    if is_enabled "${SKIP_OVERLAY:-false}"; then
        warn "SKIP_OVERLAY is enabled — skipping overlay application"
    else
        apply_overlay
    fi

    if is_enabled "${SKIP_CONFIGURE:-false}"; then
        warn "SKIP_CONFIGURE is enabled — skipping in-chroot configuration"
    else
        configure_chroot
    fi

    if is_enabled "${SKIP_IMAGE:-false}"; then
        warn "SKIP_IMAGE is enabled — skipping image assembly"
    else
        assemble_image
    fi

    local elapsed=$(( SECONDS - start_time ))
    local elapsed_fmt
    elapsed_fmt=$(printf '%02d:%02d:%02d' \
        $(( elapsed/3600 )) $(( elapsed%3600/60 )) $(( elapsed%60 )))

    section "Build Complete"
    echo -e "${GREEN}${BOLD}ghOSt build finished in ${elapsed_fmt}${NC}"
    echo -e "Output: ${BOLD}${OUTPUT_DIR}/${NC}"
}

main "$@"
