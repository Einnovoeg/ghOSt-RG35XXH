#!/usr/bin/env bash
# =============================================================================
# ghOSt ROCKNIX Kernel Builder — Allwinner H700 (RG35XXH)
#
# Proven boot path ported from Einnovoeg/rg35xxh-cyberdeck (Debian Trixie +
# ROCKNIX mainline kernel). This replaces the legacy KNULLI 4.9 vendor chain
# which does not boot reliably with a modern Debian rootfs.
#
# Why this exists (see docs/PITFALLS-cyberdeck.md):
#  1. Upstream ROCKNIX Image embeds a recovery initramfs (CONFIG_INITRAMFS_SOURCE)
#     that drops to busybox / # even when Debian rootfs is present.
#     -> patches/kernel/configure-empty-initramfs.sh empties it + rebuilds Image,
#        flips MMC*=y so kernel mounts mmcblk0p2 without initramfs.
#  2. H700 DTB leaves 7 AXP717 regulators as empty stubs; kernel auto-disables
#     them at ~31s (aldo3: disabling) killing panel/peripherals.
#     -> scripts/patch-h700-dtb-regulators.py injects regulator-always-on.
#  3. console= ordering: console=ttyS0 first, console=tty1 LAST so /dev/console
#     is the screen (no UART on retail units).
#  4. Two screen panels exist: the regular DTB and the rev6-panel DTB both ship in
#     the image (dtb-regular.img / dtb-rev6.img); ghost-panel picks one at boot.
#     Both need the same AXP717 regulator fix, so both are patched here.
#
# Layout: $BUILD_DIR/rocknix (ROCKNIX checkout), $KERNEL_BUILD_DIR artifacts.
# Idempotent: skips rebuild if Image already exists unless RG_FORCE_KERNEL=1.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.sh"
# shellcheck disable=SC1091
set -a; . "$SCRIPT_DIR/VERSIONS"; set +a

log()  { echo -e "\033[0;32m[ROCKNIX-KERNEL]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error(){ echo -e "\033[0;31m[ERROR]\033[0m $*"; exit 1; }

WORK_ROCKNIX="${WORK_ROCKNIX:-$BUILD_DIR/rocknix}"
OUT_IMAGE="$WORK_ROCKNIX/build.ROCKNIX-${DEVICE}.${ARCH}/build/${KERNEL_NAME}/arch/arm64/boot/Image"
ROCKNIX_BUILD="${ROCKNIX_BUILD:-$WORK_ROCKNIX/build.ROCKNIX-${DEVICE}.${ARCH}}"
BOOT_STAGE="$KERNEL_BUILD_DIR/boot"          # consumed by image/pack-image-rocknix.sh
DTB_DIR="$ROCKNIX_BUILD/build/${KERNEL_NAME}/arch/arm64/boot/dts/allwinner"
OUT_DTB="$DTB_DIR/${DTB_NAME}"
OUT_DTB_REV6="$DTB_DIR/${DTB_REV6_NAME}"
REGULAR_DTB=""
REV6_DTB=""

fetch_rocknix() {
    log "Fetching ROCKNIX @$ROCKNIX_COMMIT"
    if [[ ! -d "$WORK_ROCKNIX/.git" ]]; then
        git clone "$ROCKNIX_REPO" "$WORK_ROCKNIX"
    fi
    ( cd "$WORK_ROCKNIX" && git fetch && git checkout "$ROCKNIX_COMMIT" )
}

build_docker_image() {
    log "Ensuring rocknix-builder docker image"
    if docker image inspect rocknix-builder >/dev/null 2>&1; then
        return 0
    fi
    ( cd "$WORK_ROCKNIX" && \
        docker build -t rocknix-builder -f tools/docker/jammy/Dockerfile tools/docker/jammy/ )
    local cid
    cid="$(docker create --user root rocknix-builder \
        bash -c "apt-get update -qq && apt-get install -y -qq wget xmlstarlet automake parted xxd python-is-python3 flex bison bc libssl-dev libelf-dev")"
    docker start -a "$cid"
    docker commit "$cid" rocknix-builder >/dev/null
    docker rm "$cid" >/dev/null
}

build_kernel_uboot() {
    if [[ -f "$OUT_IMAGE" ]] && [[ "${RG_FORCE_KERNEL:-0}" != "1" ]]; then
        log "Kernel Image present, skipping (RG_FORCE_KERNEL=1 to override)"
        return 0
    fi
    log "Building kernel + u-boot (~30-45min on 24-core). This is the long step."
    cp "$SCRIPT_DIR/patches/kernel/configure-empty-initramfs.sh" "$WORK_ROCKNIX/configure-empty-initramfs.sh"

    docker run --rm \
        -v "$WORK_ROCKNIX:/work" \
        -e PROJECT=ROCKNIX -e DEVICE="$DEVICE" -e ARCH="$ARCH" \
        -e CONCURRENCY_MAKE_LEVEL="$(nproc)" -e MAKEFLAGS="-j$(nproc)" \
        --user root -w /work rocknix-builder bash -c "
            chown -R docker:docker /work && su docker -c '
                export PROJECT=ROCKNIX DEVICE=$DEVICE ARCH=$ARCH
                export CONCURRENCY_MAKE_LEVEL=$(nproc) MAKEFLAGS=-j$(nproc)
                ./scripts/build linux 2>&1
                bash /work/configure-empty-initramfs.sh
                ./scripts/build u-boot 2>&1
            '
        "
}

# ROCKNIX installs device trees into its boot payload (usr/share/bootloader or
# boot/device_trees), not into the kernel's dts build directory. Searching both
# is what makes this stage work without knowing the exact internal layout.
candidate_dtbs() {
    local root
    for root in "$ROCKNIX_BUILD/install_pkg" "$DTB_DIR" "$ROCKNIX_BUILD/build"; do
        [[ -d "$root" ]] || continue
        find "$root" -name '*rg35xx*.dtb' 2>/dev/null || true
    done | sort -u
}

select_dtbs() {
    local d base
    REGULAR_DTB=""
    REV6_DTB=""
    while IFS= read -r d; do
        base="$(basename "$d")"
        if [[ "$base" == *rev6* ]]; then
            [[ -n "$REV6_DTB" ]] || REV6_DTB="$d"
        else
            [[ -n "$REGULAR_DTB" ]] || REGULAR_DTB="$d"
        fi
    done < <(candidate_dtbs)
}

# Last resort: compile the DTBs from source with the ROCKNIX toolchain.
build_dtbs() {
    command -v docker >/dev/null 2>&1 || { warn "docker unavailable — cannot compile DTBs"; return 1; }
    local tc kdir
    tc="$(ls -d "$ROCKNIX_BUILD"/toolchain/*/bin/aarch64-rocknix-linux-gnu- 2>/dev/null | head -1)"
    kdir="$(ls -d "$ROCKNIX_BUILD"/build/linux-* 2>/dev/null | head -1)"
    if [[ -z "$tc" || -z "$kdir" ]]; then
        warn "no ROCKNIX toolchain/kernel build tree — cannot compile DTBs"
        return 1
    fi
    log "no prebuilt DTB found; compiling device trees (make dtbs)"
    docker run --rm -v "$WORK_ROCKNIX:/work" --user root -w /work rocknix-builder bash -c \
        "make -C /work/${kdir#$WORK_ROCKNIX/} ARCH=arm64 CROSS_COMPILE=/work/${tc#$WORK_ROCKNIX/} dtbs" \
        || { warn "make dtbs failed"; return 1; }
}

stage_boot_assets() {
    local d base
    select_dtbs
    if [[ -z "$REGULAR_DTB" && "${RG_BUILD_DTBS:-1}" == "1" ]]; then
        build_dtbs && select_dtbs
    fi
    if [[ -z "$REGULAR_DTB" ]]; then
        warn "no rg35xx device tree found under $ROCKNIX_BUILD"
        warn "dtb files that do exist (first 15):"
        find "$ROCKNIX_BUILD" -name '*.dtb' 2>/dev/null | head -15 | while IFS= read -r f; do warn "  $f"; done
        error "cannot continue without a device tree (expected sun50i-h700-anbernic-rg35xx-h*.dtb)"
    fi

    mkdir -p "$BOOT_STAGE"
    for d in "$REGULAR_DTB" "$REV6_DTB"; do
        [[ -n "$d" ]] || continue
        log "Patching DTB (AXP717 regulator-always-on): $(basename "$d")"
        python3 "$SCRIPT_DIR/scripts/patch-h700-dtb-regulators.py" "$d"
        base="$(basename "$d")"
        if [[ "$base" == *rev6* ]]; then
            cp "$d" "$BOOT_STAGE/dtb-rev6.img"
        else
            cp "$d" "$BOOT_STAGE/dtb-regular.img"
        fi
    done

    cp "$OUT_IMAGE" "$BOOT_STAGE/Image"

    local spl
    spl="$(ls -1 "$ROCKNIX_BUILD"/install_pkg/u-boot-*/usr/share/bootloader/*"${UBOOT_DDR}"*u-boot-sunxi-with-spl.bin 2>/dev/null | head -1)"
    if [[ -z "$spl" ]]; then
        spl="$(ls -1 "$ROCKNIX_BUILD"/install_pkg/u-boot-*/usr/share/bootloader/*u-boot-sunxi-with-spl.bin 2>/dev/null | head -1)"
        [[ -n "$spl" ]] && warn "no ${UBOOT_DDR} U-Boot blob; using $(basename "$spl")"
    fi
    if [[ -n "$spl" ]]; then
        cp "$spl" "$BOOT_STAGE/u-boot-sunxi-with-spl.bin"
    else
        warn "u-boot SPL not found under install_pkg (packer will refuse to build)"
    fi

    log "Staged boot assets in $BOOT_STAGE:"
    ls -lh "$BOOT_STAGE" || true
    if [[ -z "$REV6_DTB" ]]; then
        warn "No rev6-panel DTB in this tree; rev6 units keep dtb.img (see docs/panel.md)"
    fi
}

# Allow sourcing without executing, and stage-wise invocation for CI:
#   build-rocknix.sh fetch|docker|kernel|dtb|all
STAGE="${1:-all}"
case "$STAGE" in
    fetch)  fetch_rocknix ;;
    docker) fetch_rocknix; build_docker_image ;;
    kernel) fetch_rocknix; build_docker_image; build_kernel_uboot ;;
    dtb)    stage_boot_assets ;;
    all)    fetch_rocknix; build_docker_image; build_kernel_uboot; stage_boot_assets ;;
    *) error "unknown stage: $STAGE (try: all|fetch|docker|kernel|dtb)" ;;
esac

log "ROCKNIX kernel stage done:"
log "  Image:  $OUT_IMAGE"
log "  staged: $BOOT_STAGE (Image, u-boot SPL, dtb-regular.img, dtb-rev6.img)"
