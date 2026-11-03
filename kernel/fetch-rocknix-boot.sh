#!/usr/bin/env bash
# =============================================================================
# ghOSt boot payload from a proven ROCKNIX release
#
# Why this exists: ghOSt used to build a kernel from source, and that kernel was
# never demonstrated to boot on the hardware. ROCKNIX publishes a release image
# for the H700 that does boot, on units with both screen panels. This script
# takes the kernel, device trees, U-Boot and the matching modules and firmware
# out of that image and stages them where ghOSt's own packer expects them — so
# ghOSt ships a kernel that is known to work instead of one it hopes works.
#
# Extraction is loop-free on purpose (same constraint as image assembly): the
# partition table is read with sfdisk, the FAT boot partition is read with
# mtools at an offset, an ext4 partition is copied out and read with debugfs,
# and a squashfs root filesystem is read with unsquashfs. No mount, no losetup,
# no device-mapper.
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
ROOT_OFF=""; ROOT_SIZE=0; ROOT_INDEX=""
while IFS=$'\t' read -r idx start size; do
    off=$(( start * 512 ))
    kind="$(blkid -p -O "$off" -o value -s TYPE "$IMG" 2>/dev/null || true)"
    if [[ -z "$kind" ]]; then
        # blkid -O is not everywhere; identify by trying to read the filesystem.
        if mdir -i "$IMG@@$off" ::/ >/dev/null 2>&1; then kind="vfat"; fi
    fi
    log "partition $idx: offset $off, $(( size * 512 / 1024 / 1024 ))MiB, type ${kind:-unknown}"
    case "$kind" in
        vfat|msdos*) [[ -n "$FAT_OFF" ]] || { FAT_OFF="$off"; FAT_INDEX="$idx"; } ;;
        # a release can carry several ext4 partitions (recovery, storage); the
        # root filesystem, when there is one, is the big one
        ext4|ext3|ext2) if (( size > ROOT_SIZE )); then
                            ROOT_OFF="$off"; ROOT_SIZE="$size"; ROOT_INDEX="$idx"
                        fi ;;
    esac
done < "$WORK/parts.tsv"

[[ -n "$FAT_OFF" ]] || error "no FAT boot partition found in $IMG (table: $(tr '\n' ' ' < "$WORK/sf.txt"))"
log "boot partition: p$FAT_INDEX (offset $FAT_OFF)"

# --- pull the boot partition out with mtools (no mount) ---------------------
BOOT_SRC="$WORK/boot"
mkdir -p "$BOOT_SRC"
log "reading the FAT boot partition"
mdir -b -i "$IMG@@$FAT_OFF" ::/ > "$WORK/boot-listing.txt" 2>/dev/null || true
mdir -i "$IMG@@$FAT_OFF" ::/ > "$WORK/boot-sizes.txt" 2>/dev/null || true
sed 's/^/    /' "$WORK/boot-sizes.txt" | head -20
# Copy every entry by name. An mtools wildcard (::/* or ::*) skips top-level
# files on some builds while still copying directories, which loses the kernel
# image without any error, so each entry is resolved explicitly.
copied=0
while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    if mcopy -s -o -i "$IMG@@$FAT_OFF" "::/$entry" "$BOOT_SRC/" 2>/dev/null; then
        copied=$(( copied + 1 ))
    fi
done < <(mdir -b -i "$IMG@@$FAT_OFF" ::/ 2>/dev/null | sed 's#^::/##; s#\r$##')
if (( copied == 0 )); then
    mcopy -s -i "$IMG@@$FAT_OFF" "::*" "$BOOT_SRC/" 2>/dev/null || \
        warn "could not copy the boot partition"
fi
log "boot partition entries copied: $copied"

# --- the root filesystem: an ext4 partition, or a squashfs image on FAT ----
ROOT_SRC=""
if [[ -n "$ROOT_OFF" ]]; then
    ROOT_PART="$WORK/root.part"
    log "extracting the ext4 partition p$ROOT_INDEX ($(( ROOT_SIZE * 512 / 1024 / 1024 ))MiB)"
    if (( ROOT_OFF % 1048576 == 0 && ROOT_SIZE % 2048 == 0 )); then
        dd if="$IMG" of="$ROOT_PART" bs=1M skip=$(( ROOT_OFF / 1048576 )) \
           count=$(( ROOT_SIZE / 2048 )) status=none
    else
        dd if="$IMG" of="$ROOT_PART" bs=512 skip=$(( ROOT_OFF / 512 )) count="$ROOT_SIZE" status=none
    fi
    mkdir -p "$WORK/root" "$WORK/x"
    for p in /usr/share/bootloader /lib/modules /lib/firmware /usr/lib/firmware; do
        debugfs -R "rdump ${p} $WORK/x" "$ROOT_PART" > "$WORK/dbg.log" 2>&1 || true
        src="$WORK/x/$(basename "$p")"
        if [[ -d "$src" ]]; then
            mkdir -p "$WORK/root$(dirname "$p")"
            rm -rf "$WORK/root$p"
            mv "$src" "$WORK/root$p"
        fi
        n="$(find "$WORK/root$p" -type f 2>/dev/null | wc -l | tr -d ' ' || true)"
        log "ext4 ${p}: ${n} file(s)"
        (( n > 0 )) || warn "  debugfs: $(head -2 "$WORK/dbg.log" | tr '\n' ' ')"
    done
    # keep it only if it actually held something we need; a small ext4 may be a
    # recovery or storage partition rather than the root filesystem
    if [[ -d "$WORK/root/lib/modules" || -d "$WORK/root/usr/lib/modules" \
       || -d "$WORK/root/usr/share/bootloader" ]]; then
        ROOT_SRC="$WORK/root"
    else
        warn "ext4 partition p$ROOT_INDEX holds no root filesystem; continuing"
    fi
fi

# ROCKNIX-style images keep the root filesystem as a squashfs image on the boot
# partition, so look for one and read only the paths that matter out of it.
SQUASH=""
while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    [[ "$(head -c 4 "$f" 2>/dev/null)" == "hsqs" ]] && { SQUASH="$f"; break; }
done < <(find "$BOOT_SRC" -type f -size +1M 2>/dev/null | sort)
if [[ -n "$SQUASH" ]]; then
    log "squashfs root filesystem: $(basename "$SQUASH") ($(du -h "$SQUASH" | cut -f1))"
    if command -v unsquashfs >/dev/null 2>&1; then
        mkdir -p "$WORK/sq"
        # Debian merges /usr, so modules and firmware usually live under
        # usr/lib; ask for both spellings and use whichever the image has.
        unsquashfs -q -d "$WORK/sq" "$SQUASH" \
            lib/modules usr/lib/modules lib/firmware usr/lib/firmware \
            usr/share/bootloader \
            > "$WORK/unsquash.log" 2>&1 || warn "unsquashfs reported: $(tail -2 "$WORK/unsquash.log" | tr '\n' ' ')"
        ROOT_SRC="$WORK/sq"
    else
        warn "unsquashfs is missing (apt install squashfs-tools); cannot read modules from the squashfs"
    fi
fi
[[ -n "$ROOT_SRC" ]] || error "no root filesystem found: no large ext4 partition and no squashfs image on the boot partition"

# --- find the pieces --------------------------------------------------------
# ROCKNIX calls the kernel KERNEL; other builds call it Image.
IMAGE_SRC=""
for name in Image KERNEL kernel.img; do
    IMAGE_SRC="$(find "$BOOT_SRC" "$ROOT_SRC/usr/share/bootloader" -maxdepth 3 -name "$name" 2>/dev/null | head -1 || true)"
    [[ -n "$IMAGE_SRC" ]] && break
done
[[ -n "$IMAGE_SRC" ]] || error "no kernel image (Image/KERNEL) in the payload (boot listing: $(head -8 "$WORK/boot-listing.txt" | tr '\n' ' '))"

# bash 3.2 (macOS /bin/bash) has no mapfile, so build the list with a read loop
DTBS=()
while IFS= read -r d; do DTBS+=("$d"); done < <(
    find "$BOOT_SRC" "$ROOT_SRC/usr/share/bootloader" -maxdepth 4 \
         \( -name '*rg35xx*.dtb' -o -name '*h700*.dtb' \) 2>/dev/null | sort -u)
(( ${#DTBS[@]} )) || error "no device trees in the payload"

UBOOT_SRC="$(find "$ROOT_SRC/usr/share/bootloader" -name "*${ROCKNIX_IMAGE_DDR}*u-boot-sunxi-with-spl.bin" 2>/dev/null | head -1 || true)"
[[ -n "$UBOOT_SRC" ]] || UBOOT_SRC="$(find "$BOOT_SRC" "$ROOT_SRC/usr/share/bootloader" -name '*u-boot-sunxi-with-spl.bin' 2>/dev/null | head -1 || true)"
# ROCKNIX does not keep U-Boot as a file: it is written to the raw sectors that
# the boot ROM reads (8 KiB in, before the first partition). Take it from there.
if [[ -z "$UBOOT_SRC" ]]; then
    dd if="$IMG" of="$WORK/uboot.bin" bs=1024 skip=8 count=1008 status=none 2>/dev/null || true
    case "$(head -c 8 "$WORK/uboot.bin" 2>/dev/null)" in
        eGON*) UBOOT_SRC="$WORK/uboot.bin"
               log "u-boot taken from the raw image at 8KiB (eGON header)" ;;
    esac
fi
[[ -n "$UBOOT_SRC" ]] || warn "no U-Boot SPL in the payload; the packer needs one"

# --- stage ------------------------------------------------------------------
mkdir -p "$BOOT_STAGE" "$OVERLAY/lib/modules" "$OVERLAY/lib/firmware"
cp "$IMAGE_SRC" "$BOOT_STAGE/Image"
if [[ -n "$UBOOT_SRC" ]]; then
    cp "$UBOOT_SRC" "$BOOT_STAGE/u-boot-sunxi-with-spl.bin"
fi
log "kernel: $(basename "$IMAGE_SRC") ($(du -h "$IMAGE_SRC" | cut -f1)), u-boot: ${UBOOT_SRC:+$(basename "$UBOOT_SRC")}"
# ROCKNIX builds its kernel with CONFIG_INITRAMFS_SOURCE, so the released Image
# can carry a cpio archive that looks for /flash and /storage and drops to a
# busybox shell even when the Debian rootfs is mounted right underneath it.
# Detect it here, because a kernel like that boots to `#`, not to ghOSt.
if grep -aq 'TRAILER!!!' "$BOOT_STAGE/Image"; then
    warn "kernel carries an embedded initramfs (cpio trailer found in Image)"
    warn "  it will look for ROCKNIX's /flash + SYSTEM rootfs, not ghOSt's Debian rootfs"
    warn "  rebuild it without one: GHOST_BOOT_SOURCE=source uses"
    warn "  patches/kernel/configure-empty-initramfs.sh to empty INITRAMFS_SOURCE"
    echo "embedded-initramfs" > "$BOOT_STAGE/EMBEDDED-INITRAMFS"
fi

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

# modules + firmware must match this kernel exactly, so they come from the same
# image. Each module tree is named after its kernel version; keep that
# directory, or modprobe looks in the wrong place and no driver loads.
mods=0 fw=0
while IFS= read -r m; do
    [[ -d "$m" ]] || continue
    ver="$(basename "$m")"
    rsync -a "$m/" "$OVERLAY/lib/modules/$ver/"
    log "modules: $ver ($(find "$m" -type f 2>/dev/null | wc -l | tr -d ' ' || true) files)"
    mods=$(( mods + 1 ))
done < <(find "$ROOT_SRC/lib/modules" "$ROOT_SRC/usr/lib/modules" \
              -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -u)
for f in "$ROOT_SRC/lib/firmware" "$ROOT_SRC/usr/lib/firmware"; do
    [[ -d "$f" ]] || continue
    rsync -a "$f/" "$OVERLAY/lib/firmware/"
    fw=$(( fw + 1 ))
done
(( mods > 0 )) || warn "no kernel modules found in the release root filesystem"
(( fw > 0 )) || warn "no firmware found in the release root filesystem"
log "staged $mods module tree(s) and firmware from $fw path(s)"

log "boot payload ready:"
ls -lh "$BOOT_STAGE" 2>/dev/null || true
