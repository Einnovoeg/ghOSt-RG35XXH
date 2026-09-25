#!/usr/bin/env bash
# =============================================================================
# ghOSt Image Packer (ROCKNIX proven layout)
# Compose final SD image: MBR, u-boot SPL @ 8KB, FAT boot p1, ext4 rootfs p2.
# Ported from rg35xxh-cyberdeck image/pack-image.sh, adapted to ghOSt paths:
#   $BUILD_DIR/rocknix  (kernel build tree)
#   $ROOTFS_DIR         (Debian Trixie + XFCE + ghOSt tools)
#   $OUTPUT_DIR         (dist artifacts)
#
# Why MBR and not GPT: H700 ROM + ROCKNIX u-boot SPL overlap GPT header at
# LBA1-33 (8KB offset). Stock/ROCKNIX images use MBR. GPT was a boot failure.
# Why FAT /boot: u-boot fatload mmc 0:1 Image + DTB + boot.scr (see boot.cmd).
# Why no separate swap partition: MBR + swap-at-end complicated first-boot
# expand; ghOSt keeps zram (prio 100) + optional swapfile inside rootfs.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.sh"
# shellcheck disable=SC1091
set -a; . "$SCRIPT_DIR/VERSIONS"; set +a

WORK="${RG_WORK:-$BUILD_DIR}"
DIST="${RG_DIST:-$OUTPUT_DIR}"
ROOTFS="${ROOTFS_DIR}"

[ "$(id -u)" = 0 ] || { echo "must be root"; exit 1; }
[[ -d "$ROOTFS/etc" ]] || { echo "rootfs not found at $ROOTFS"; ls -la "$WORK" 2>/dev/null || true; exit 1; }

mkdir -p "$DIST"
GIT_SHA="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || date +%Y%m%d)"
IMG="$DIST/ghOSt-RG35XXH-${GHOST_VERSION:-1.0.0}-${GIT_SHA}.img"
SIZE_BYTES=$(( IMAGE_SIZE_GB * 1024 * 1024 * 1024 ))

echo "[pack] creating $IMG (${IMAGE_SIZE_GB} GB)"
rm -f "$IMG"
truncate -s "$SIZE_BYTES" "$IMG"

# MBR: u-boot in gap 8KB..16MB, p1 FAT 256MB, p2 ext4 rest
parted -s "$IMG" mklabel msdos
parted -s "$IMG" mkpart primary fat32 16MiB 272MiB
parted -s "$IMG" mkpart primary ext4  272MiB 100%
parted -s "$IMG" set 1 boot on

LOOP=$(losetup --find --show "$IMG")
KPMAP=$(basename "$LOOP")
# shellcheck disable=SC2064
trap 'kpartx -d "$LOOP" 2>/dev/null || true; losetup -d "$LOOP" 2>/dev/null || true' EXIT
kpartx -a -s "$LOOP"
udevadm settle 2>/dev/null || true
P1=/dev/mapper/${KPMAP}p1
P2=/dev/mapper/${KPMAP}p2
for i in 1 2 3 4 5; do
  [ -b "$P2" ] && break
  sleep 1
  udevadm settle 2>/dev/null || true
done
[ -b "$P2" ] || { echo "kpartx failed to create $P2"; ls -la /dev/mapper/; exit 1; }

echo "[pack] formatting (BOOT vfat, rootfs ext4)..."
mkfs.vfat -F 32 -n BOOT   "$P1"
mkfs.ext4 -F -L rootfs "$P2"

# Install u-boot SPL @ 8KB
UBOOT_GLOB="$WORK/rocknix/build.ROCKNIX-${DEVICE}.${ARCH}/install_pkg/u-boot-"*"/usr/share/bootloader/u-boot-sunxi-with-spl.bin"
UBOOT=$(ls -1 $UBOOT_GLOB 2>/dev/null | head -1 || true)
[[ -n "${UBOOT:-}" && -f "$UBOOT" ]] || { echo "[pack] u-boot SPL not found: $UBOOT_GLOB"; ls "$WORK/rocknix/build.ROCKNIX-"* 2>/dev/null || true; exit 1; }
echo "[pack] u-boot: $UBOOT"
dd if="$UBOOT" of="$LOOP" bs=1024 seek=8 conv=notrunc status=none

# Mount and populate
MNT=$(mktemp -d)
mount "$P2" "$MNT"
mkdir -p "$MNT/boot"
mount "$P1" "$MNT/boot"

# Kernel + DTB (patched) + boot.scr/boot.cmd
KSRC="$WORK/rocknix/build.ROCKNIX-${DEVICE}.${ARCH}/build/${KERNEL_NAME}"
[[ -f "$KSRC/arch/arm64/boot/Image" ]] || { echo "[pack] kernel Image missing: $KSRC"; exit 1; }
cp "$KSRC/arch/arm64/boot/Image" "$MNT/boot/"
cp "$KSRC/arch/arm64/boot/dts/allwinner/${DTB_NAME}" "$MNT/boot/"
cp "$SCRIPT_DIR/patches/uboot/boot.scr" "$MNT/boot/"
cp "$SCRIPT_DIR/patches/uboot/boot.cmd" "$MNT/boot/"

# Rootfs (exclude /boot which is the FAT mount)
rsync -aHAX "$ROOTFS/" "$MNT/" --exclude=/boot/\*

# Modules from ROCKNIX install_pkg + KNULLI firmware if staged
MODS="$WORK/rocknix/build.ROCKNIX-${DEVICE}.${ARCH}/install_pkg/${KERNEL_NAME}/usr/lib/kernel-overlays/base/lib/modules"
if [[ -d "$MODS" ]]; then
  echo "[pack] installing kernel modules..."
  rsync -aHAX "$MODS/" "$MNT/lib/modules/"
fi
if [[ -d "$BUILD_DIR/kernel/rootfs-overlay/lib/modules" ]]; then
  echo "[pack] merging KNULLI firmware/modules overlay (WiFi fw)..."
  rsync -aHAX "$BUILD_DIR/kernel/rootfs-overlay/" "$MNT/" 2>/dev/null || true
fi

# Joypad module (built separately by scripts/build-joypad-module.sh)
JOYMOD="$WORK/rocknix-joypad-build/rocknix-singleadc-joypad.ko"
if [[ -f "$JOYMOD" ]]; then
  KVER=$(ls "$MNT/lib/modules/" | head -1)
  echo "[pack] installing joypad module -> $KVER/extra"
  install -d "$MNT/lib/modules/$KVER/extra"
  cp "$JOYMOD" "$MNT/lib/modules/$KVER/extra/"
  chroot "$MNT" depmod -a "$KVER" 2>/dev/null || true
  echo rocknix-singleadc-joypad > "$MNT/etc/modules-load.d/rocknix-joypad.conf"
else
  echo "[pack] joypad .ko not found (run scripts/build-joypad-module.sh) — joy2mouse will retry at boot"
fi

# Ensure fstab matches MBR LABEL layout (UI stage already writes this, reinforce)
cat > "$MNT/etc/fstab" <<'EOF'
LABEL=rootfs   /        ext4   defaults,noatime,errors=remount-ro  0 1
LABEL=BOOT     /boot    vfat   defaults,noatime,umask=0022          0 2
proc           /proc    proc   defaults                             0 0
tmpfs          /tmp     tmpfs  defaults,nosuid,nodev,size=256M      0 0
EOF

sync
umount "$MNT/boot"
umount "$MNT"
rmdir "$MNT"
kpartx -d "$LOOP" 2>/dev/null || true
losetup -d "$LOOP"; trap - EXIT

echo "[pack] creating bmap"
bmaptool create -o "$IMG.bmap" "$IMG" 2>/dev/null || echo "[pack] bmaptool missing, skipping bmap"

echo "[pack] compressing -> ${IMG}.xz"
xz -T 0 -6 -k "$IMG"
( cd "$DIST" && sha256sum "$(basename "$IMG").xz" "$(basename "$IMG").bmap" > SHA256SUMS 2>/dev/null || sha256sum "$(basename "$IMG").xz" > SHA256SUMS )
ls -lh "$IMG"*
echo "[pack] done. Flash with: sudo bmaptool copy ${IMG}.xz /dev/sdX  (or xz -d + dd)"
