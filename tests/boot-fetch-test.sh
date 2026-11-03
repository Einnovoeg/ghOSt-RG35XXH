#!/usr/bin/env bash
# Exercise kernel/fetch-rocknix-boot.sh against a synthetic release image with
# the same shape as a ROCKNIX H700 release (FAT boot partition + ext4 rootfs).
# Needs real mkfs/mtools/debugfs; skipped with a message where they are absent.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
fail=0
ok()  { echo "  ok    $*"; }
bad() { echo "  FAIL  $*"; fail=1; }

HAVE=1
for t in mkfs.vfat mcopy mkfs.ext4 debugfs sfdisk dd gzip blkid rsync python3 sha256sum; do
    command -v "$t" >/dev/null 2>&1 || HAVE=0
done
if (( ! HAVE )); then
    echo "-- skip: no Linux mkfs/mtools/debugfs on this host (CI runs this for real)"
    echo "group extraction: SKIP"
    exit 0
fi

H="$(mktemp -d)"; trap 'rm -rf "$H"' EXIT
PAY="$H/payload"
mkdir -p "$PAY/boot/device_trees" "$PAY/root/usr/share/bootloader" \
         "$PAY/root/lib/modules/7.1.2/kernel/drivers/net" "$PAY/root/lib/firmware/brcm"

head -c 8192 /dev/zero | tr '\0' 'K' > "$PAY/boot/Image"
printf 'DTB-REGULAR' > "$PAY/boot/device_trees/sun50i-h700-anbernic-rg35xx-h.dtb"
printf 'DTB-REV6'    > "$PAY/boot/device_trees/sun50i-h700-anbernic-rg35xx-h-rev6-panel.dtb"
printf 'UBOOT-SPL'   > "$PAY/root/usr/share/bootloader/H700_DDR4_u-boot-sunxi-with-spl.bin"
printf 'MODULE'      > "$PAY/root/lib/modules/7.1.2/kernel/drivers/net/test.ko"
printf 'FIRMWARE'    > "$PAY/root/lib/firmware/brcm/test.bin"

mkfs.vfat -C -F 32 "$H/boot.fat" 16384 >/dev/null || { bad "mkfs.vfat"; exit 1; }
mcopy -s -i "$H/boot.fat" "$PAY/boot"/* ::/ || { bad "mcopy boot"; exit 1; }
mkfs.ext4 -q -F -d "$PAY/root" "$H/root.ext4" 64M || { bad "mkfs.ext4"; exit 1; }

truncate -s 128M "$H/release.img"
sfdisk -q "$H/release.img" <<'SFDISK'
label: dos
start=2048, size=32768, type=c, bootable
start=34816, size=131072, type=83
SFDISK
dd if="$H/boot.fat"  of="$H/release.img" bs=512 seek=2048  conv=notrunc status=none
dd if="$H/root.ext4" of="$H/release.img" bs=512 seek=34816 conv=notrunc status=none
gzip -c "$H/release.img" > "$H/release.img.gz"
SHA="$(sha256sum "$H/release.img.gz" | awk '{print $1}')"

BUILD="$H/build"
if ! ROCKNIX_IMAGE_FILE_PATH="$H/release.img.gz" \
     ROCKNIX_IMAGE_SHA256="$SHA" \
     BUILD_DIR="$BUILD" \
     bash kernel/fetch-rocknix-boot.sh > "$H/out.log" 2>&1; then
    bad "extractor failed"
    tail -15 "$H/out.log"
    exit 1
fi
ok "extractor completed"

BOOT="$BUILD/kernel/boot"; OVL="$BUILD/kernel/rootfs-overlay"
[[ "$(cat "$BOOT/Image")" == KKKKKKKK ]] && ok "kernel Image staged" || bad "kernel Image missing"
[[ "$(cat "$BOOT/u-boot-sunxi-with-spl.bin")" == UBOOT-SPL ]] && ok "U-Boot SPL staged" || bad "U-Boot missing"
[[ "$(cat "$BOOT/dtb-regular.img")" == DTB-REGULAR ]] && ok "regular DTB staged" || bad "regular DTB missing"
[[ "$(cat "$BOOT/dtb-rev6.img")" == DTB-REV6 ]] && ok "rev6 DTB staged" || bad "rev6 DTB missing"
[[ "$(cat "$BOOT/dtb.img")" == DTB-REGULAR ]] && ok "dtb.img defaults to regular" || bad "dtb.img wrong"
[[ -f "$OVL/lib/modules/7.1.2/kernel/drivers/net/test.ko" ]] && ok "modules staged" || bad "modules missing"
[[ -f "$OVL/lib/firmware/brcm/test.bin" ]] && ok "firmware staged" || bad "firmware missing"

# a wrong checksum must abort rather than ship an unverified kernel
if ROCKNIX_IMAGE_FILE_PATH="$H/release.img.gz" ROCKNIX_IMAGE_SHA256="$(printf '0%.0s' {1..64})" \
     BUILD_DIR="$H/build2" bash kernel/fetch-rocknix-boot.sh > "$H/bad.log" 2>&1; then
    bad "accepted an image with the wrong checksum"
else
    grep -q "checksum mismatch" "$H/bad.log" && ok "wrong checksum rejected" || bad "unclear checksum failure"
fi

echo
if (( fail == 0 )); then echo "boot extraction: PASS"; else echo "boot extraction: FAIL"; exit 1; fi
