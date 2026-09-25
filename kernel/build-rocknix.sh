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
#  4. Retail units need sun50i-h700-anbernic-rg35xx-h.dtb (NOT rev6-panel).
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
OUT_DTB="$WORK_ROCKNIX/build.ROCKNIX-${DEVICE}.${ARCH}/build/${KERNEL_NAME}/arch/arm64/boot/dts/allwinner/${DTB_NAME}"

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

patch_dtb() {
    log "Patching DTB (AXP717 regulator-always-on)"
    [[ -f "$OUT_DTB" ]] || error "DTB not found: $OUT_DTB (kernel build failed?)"
    python3 "$SCRIPT_DIR/scripts/patch-h700-dtb-regulators.py" "$OUT_DTB"
}

# Allow sourcing without executing, and stage-wise invocation for CI:
#   build-rocknix.sh fetch|docker|kernel|dtb|all
STAGE="${1:-all}"
case "$STAGE" in
    fetch)  fetch_rocknix ;;
    docker) fetch_rocknix; build_docker_image ;;
    kernel) fetch_rocknix; build_docker_image; build_kernel_uboot ;;
    dtb)    patch_dtb ;;
    all)    fetch_rocknix; build_docker_image; build_kernel_uboot; patch_dtb ;;
    *) error "unknown stage: $STAGE (try: all|fetch|docker|kernel|dtb)" ;;
esac

log "ROCKNIX kernel stage done:"
log "  Image: $OUT_IMAGE"
log "  DTB:   $OUT_DTB"
