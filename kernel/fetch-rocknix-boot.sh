#!/usr/bin/env bash
# =============================================================================
# ghOSt boot payload from a proven ROCKNIX release
#
# Why this exists: ghOSt builds a kernel from source, and that kernel has never
# been demonstrated to boot on the hardware. ROCKNIX publishes a release image
# for the H700 that does boot, on units with both screen panels. This script
# takes the kernel, device trees, U-Boot and matching modules out of that image
# and stages them where ghOSt's own packer expects them — so ghOSt ships a
# kernel that is known to work instead of one it hopes works.
#
# Extraction is loop-free on purpose (same constraint as image assembly): the
# partition table is read with sfdisk, the FAT boot partition is read with
# mtools at an offset, and the ext4 partition is copied out and read with
# debugfs. No mount, no losetup, no device-mapper.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.sh"
# shellcheck disable=SC1091
set -a; . "$SCRIPT_DIR/VERSIONS"; set +a

log()   { echo -e "\033[0;32m[boot]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[boot]\033[0m $*"; }
error() { echo -e "\033[0;31m[boot]\033[0m $*" >&2; exit 1; }

CACHE="${ROCKNIX_CACHE_DIR:-$BUILD_DIR/cache}"
BOOT_STAGE="$KERNEL_BUILD_DIR/boot"
OVERLAY="$KERNEL_BUILD_DIR/rootfs-overlay"
WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

for tool in sfdisk dd gzip; do
    command -v "$tool" >/dev/null 2>&1 || error "missing host tool: $tool"
done
for tool in mcopy mdir; do
    command -v "$tool" >/dev/null 2>&1 || error "missing mtools tool: $tool (apt install mtools)"
done
command -v debugfs >/dev/null 2>&1 || error "missing debugfs (apt install e2fsprogs)"

# --- locate the release image ------------------------------------------------
# ROCKNIX_IMAGE_FILE_PATH skips the download (tests, or a local mirror).
SRC_IMAGE="${ROCKNIX_IMAGE_FILE_PATH:-}"
if [[ -z "$SRC_IMAGE" ]]; then
    mkdir -p "$CACHE"
    SRC_IMAGE="$CACHE/$ROCKNIX_IMAGE_FILE"
    if [[ ! -f "$SRC_IMAGE" ]]; then
        log "downloading $ROCKNIX_IMAGE_FILE ($(( ${ROCKNIX_IMAGE_SIZE:-1262674637} / 1024 / 1024 ))MiB)"
        curl -fL --retry 3 --retry-delay 5 -C - -o "${SRC_IMAGE}.part" "$ROCKNIX_IMAGE_URL"
        mv "${SRC_IMAGE}.part" "$SRC_IMAGE"
    else
        log "using cached $SRC_IMAGE"
    fi
fi
[[ -f "$SRC_IMAGE" ]] || error "release image not found: $SRC_IMAGE"

log "verifying kernel payload checksum"
echo "${ROCKNIX_IMAGE_SHA256}  ${SRC_IMAGE}" | sha256sum -c - >/dev/null \
    || error "checksum mismatch for $SRC_IMAGE — refusing to use it"

# --- decompress --------------------------------------------------------------
IMG="$WORK/rocknix.img"
case "$SRC_IMAGE" in
    *.gz) log "decompressing"; gzip -dc "$SRC_IMAGE" > "$IMG" ;;
    *)    IMG="$SRC_IMAGE" ;;
esac

# --- partition table (no mount) ----------------------------------------------
sfdisk -d "$IMG" > "$WORK/sf.txt" 2>/dev/null || error "cannot read the partition table of $IMG"
python3 - "$WORK/sf.txt" > "$WORK/parts.tsv" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
parts = [l for l in text.splitlines() if re.search(r"start=\s*\d+", l)]
for i, line in enumerate(parts, 1):
    start = int(re.search(r"start=\s*(\d+)", line).group(1))
    size = int(re.search(r"size=\s*(\d+)", line).group(1))
    print(f"{i}\t{start}\t{size}")
PY
[[ -s "$WORK/parts.tsv" ]] || error "no partitions found in $IMG"

# --- find the FAT boot partition and the ext4 root partition ----------------
FAT_OFF=""; FAT_INDEX=""
ROOT_OFF=""; ROOT_SIZE=""; ROOT_INDEX=""
while IFS=$'\t' read -r idx start size; do
    off=$(( start * 512 ))
    kind="$(blkid -p -O "$off" -o value -s TYPE "$IMG" 2>/dev/null || true)"
    if [[ -z "$kind" ]]; then
        # blkid -O is not everywhere; identify by trying to read the filesystem.
        if mdir -i "$IMG@@$off" ::/ >/dev/null 2>&1; then kind="vfat"; fi
    fi
    log "partition $idx: offset $off, type ${kind:-unknown}"
    case "$kind" in
        vfat|msdos*) [[ -n "$FAT_OFF" ]] || { FAT_OFF="$off"; FAT_INDEX="$idx"; } ;;
        ext4|ext3|ext2) ROOT_OFF="$off"; ROOT_SIZE="$size"; ROOT_INDEX="$idx" ;;
    esac
done < "$WORK/parts.tsv"

[[ -n "$FAT_OFF" ]] || error "no FAT boot partition found in $IMG"
[[ -n "$ROOT_OFF" ]] || error "no ext4 root partition found in $IMG"
log "boot partition: p$FAT_INDEX (offset $FAT_OFF), rootfs: p$ROOT_INDEX"

# --- pull the boot partition out with mtools (no mount) ---------------------
mkdir -p "$WORK/boot"
log "reading the FAT boot partition"
mdir -b -i "$IMG@@$FAT_OFF" ::/ > "$WORK/boot-listing.txt" 2>/dev/null || true
mcopy -s -i "$IMG@@$FAT_OFF" ::/* "$WORK/boot/" 2>/dev/null || \
    warn "could not copy the whole boot partition; falling back to named files"

# --- pull what we need out of the ext4 rootfs -------------------------------
ROOT_PART="$WORK/root.part"
log "extracting the rootfs partition ($(( ROOT_SIZE * 512 / 1024 / 1024 ))MiB) to read modules and U-Boot"
dd if="$IMG" of="$ROOT_PART" bs=512 skip=$(( ROOT_OFF / 512 )) count="$ROOT_SIZE" status=none
mkdir -p "$WORK/root/usr/share/bootloader" "$WORK/root/lib/modules" "$WORK/root/lib/firmware"
for p in /usr/share/bootloader /lib/modules /lib/firmware /usr/lib/firmware; do
    dest="$WORK/root${p}"
    mkdir -p "$dest"
    debugfs -R "rdump ${p} ${dest}" "$ROOT_PART" >/dev/null 2>&1 || true
done

# --- find the pieces --------------------------------------------------------
find_first() { # $1... = search roots, rest handled by caller predicate
    find "$@" -maxdepth 4 2>/dev/null | head -1
}

IMAGE_SRC="$(find "$WORK/boot" "$WORK/root/usr/share/bootloader" -maxdepth 3 -name 'Image' 2>/dev/null | head -1)"
[[ -n "$IMAGE_SRC" ]] || error "no kernel Image in the boot payload (boot listing: $(head -5 "$WORK/boot-listing.txt" | tr '\n' ' '))"

# bash 3.2 (macOS /bin/bash) has no mapfile, so build the list with a read loop
DTBS=()
while IFS= read -r d; do DTBS+=("$d"); done < <(
    find "$WORK/boot" "$WORK/root/usr/share/bootloader" -maxdepth 4 \
         \( -name '*rg35xx*.dtb' -o -name '*h700*.dtb' \) 2>/dev/null | sort -u)
(( ${#DTBS[@]} )) || error "no device trees in the boot payload"

UBOOT_SRC="$(find "$WORK/root/usr/share/bootloader" -name "*${ROCKNIX_IMAGE_DDR}*u-boot-sunxi-with-spl.bin" 2>/dev/null | head -1)"
[[ -n "$UBOOT_SRC" ]] || UBOOT_SRC="$(find "$WORK/root/usr/share/bootloader" -name '*u-boot-sunxi-with-spl.bin' 2>/dev/null | head -1)"
[[ -n "$UBOOT_SRC" ]] || error "no U-Boot SPL in /usr/share/bootloader"

# --- stage ------------------------------------------------------------------
mkdir -p "$BOOT_STAGE" "$OVERLAY/lib/modules" "$OVERLAY/lib/firmware"
cp "$IMAGE_SRC" "$BOOT_STAGE/Image"
cp "$UBOOT_SRC" "$BOOT_STAGE/u-boot-sunxi-with-spl.bin"
log "kernel: $(basename "$IMAGE_SRC") ($(du -h "$IMAGE_SRC" | cut -f1)), u-boot: $(basename "$UBOOT_SRC")"

regular=""; rev6=""
for d in "${DTBS[@]}"; do
    base="$(basename "$d")"
    log "device tree: $base"
    python3 "$SCRIPT_DIR/scripts/patch-h700-dtb-regulators.py" "$d" || warn "regulator patch failed on $base"
    case "$base" in
        *rev6*) [[ -n "$rev6" ]] || { rev6="$d"; cp "$d" "$BOOT_STAGE/dtb-rev6.img"; } ;;
        *)      [[ -n "$regular" ]] || { regular="$d"; cp "$d" "$BOOT_STAGE/dtb-regular.img"; } ;;
    esac
done
[[ -n "$regular" ]] || error "no regular-panel device tree among: ${DTBS[*]}"
[[ -n "$rev6" ]] || warn "no rev6-panel device tree in this release; rev6 units keep dtb.img"
cp "$BOOT_STAGE/dtb-regular.img" "$BOOT_STAGE/dtb.img"

# modules + firmware must match this kernel exactly, so they come from the same image
# Each module tree is named after its kernel version; keep that directory, or
# modprobe looks in the wrong place and every driver silently fails to load.
mods=0 fw=0
while IFS= read -r m; do
    [[ -d "$m" ]] || continue
    ver="$(basename "$m")"
    rsync -a "$m/" "$OVERLAY/lib/modules/$ver/"
    log "modules: $ver"
    mods=$(( mods + 1 ))
done < <(find "$WORK/root/lib/modules" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
for f in "$WORK/root/lib/firmware" "$WORK/root/usr/lib/firmware"; do
    [[ -d "$f" ]] || continue
    rsync -a "$f/" "$OVERLAY/lib/firmware/"
    fw=$(( fw + 1 ))
done
(( mods > 0 )) || warn "no kernel modules found in the release rootfs"
(( fw > 0 )) || warn "no firmware found in the release rootfs"
log "staged $mods module tree(s) and firmware from $fw path(s)"

log "boot payload ready:"
ls -lh "$BOOT_STAGE" 2>/dev/null || true
