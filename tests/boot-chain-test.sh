#!/usr/bin/env bash
# =============================================================================
# ghOSt — boot chain consistency
#
# The image only boots when four things agree: the U-Boot script knows where the
# kernel/DTB/root are, the packer puts them exactly there, the partition table
# matches the labels the rootfs fstab mounts, and the bootloader is written where
# the H700 boot ROM looks for it. Each of those lives in a different file, so
# this suite checks them against each other instead of trusting any one of them.
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACK="$ROOT/image/pack-image-rocknix.sh"
BOOTCMD="$ROOT/patches/uboot/boot.cmd"
CONFIGURE="$ROOT/overlay/opt/ghost/scripts/configure.sh"
PASS=0
FAIL=0

ok()  { echo "  ok    $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

for f in "$PACK" "$BOOTCMD" "$CONFIGURE" "$ROOT/config.sh"; do
    [[ -f "$f" ]] || { bad "missing $f"; echo "boot-chain: $PASS passed, $FAIL failed"; exit 1; }
done

# Config values, without running the build.
# shellcheck disable=SC1090
eval "$(bash -c 'set -a; . "$1" >/dev/null 2>&1; \
    printf "DISK_ID=%q\nBOOT_LABEL=%q\nROOT_LABEL=%q\nUBOOT_GAP_MIB=%q\nBOOT_PART_MIB=%q\n" \
    "$DISK_ID" "$BOOT_LABEL" "$ROOT_LABEL" "$UBOOT_GAP_MIB" "$BOOT_PART_MIB"' _ "$ROOT/config.sh")"

# --- 1. U-Boot script ------------------------------------------------------
PLACEHOLDER_COUNT=$(grep -c 'root=/dev/mmcblk0p2' "$BOOTCMD" || true)
if [[ "$PLACEHOLDER_COUNT" == "1" ]]; then
    ok "boot.cmd carries exactly one root placeholder for the packer to rewrite"
else
    bad "boot.cmd has $PLACEHOLDER_COUNT root placeholders (the packer substitution needs exactly one)"
fi

if grep -q 'fatload mmc 0:1 .*Image' "$BOOTCMD" && grep -q 'fatload mmc 0:1 .*dtb.img' "$BOOTCMD"; then
    ok "boot.cmd loads Image and dtb.img from the boot partition"
else
    bad "boot.cmd does not load Image and dtb.img from mmc 0:1"
fi

if grep -q 'fatload mmc 1:1' "$BOOTCMD"; then
    ok "boot.cmd falls back to the second SD slot"
else
    bad "boot.cmd only tries mmc 0:1, so a card in the other slot cannot boot"
fi

if grep -q 'booti ' "$BOOTCMD" && ! grep -q 'bootm ' "$BOOTCMD"; then
    ok "boot.cmd uses booti (raw arm64 Image), not bootm"
else
    bad "boot.cmd must boot the raw Image with booti"
fi

KERNEL_ADDR=$(grep -o 'fatload mmc 0:1 0x[0-9A-Fa-f]* Image' "$BOOTCMD" | awk '{print $4}' | head -1)
DTB_ADDR=$(grep -o 'fatload mmc 0:1 0x[0-9A-Fa-f]* dtb.img' "$BOOTCMD" | awk '{print $4}' | head -1)
if [[ -n "$KERNEL_ADDR" && -n "$DTB_ADDR" && "$KERNEL_ADDR" != "$DTB_ADDR" ]]; then
    ok "kernel and DTB load addresses differ ($KERNEL_ADDR / $DTB_ADDR)"
else
    bad "kernel and DTB would be loaded at the same address"
fi

if grep -qE 'booti 0x[0-9A-Fa-f]+ - 0x[0-9A-Fa-f]+' "$BOOTCMD"; then
    ok "booti is given an explicit DTB address"
else
    bad "booti has no DTB argument"
fi

# --- 2. Packer: kernel, DTBs, boot.scr ------------------------------------
for asset in Image dtb.img dtb-regular.img dtb-rev6.img wifi.txt panel.txt README.txt; do
    if grep -q "$asset" "$PACK"; then
        ok "packer stages $asset on the boot partition"
    else
        bad "packer does not stage $asset"
    fi
done

if grep -q 'mkimage ' "$PACK" && grep -q 'die "mkimage' "$PACK"; then
    ok "packer compiles boot.scr and refuses to ship without mkimage"
else
    bad "packer could fall back to a stale committed boot.scr"
fi

if grep -q "root=PARTUUID=\${PARTUUID_ROOT}" "$PACK"; then
    ok "packer rewrites the kernel root= to a PARTUUID"
else
    bad "packer does not rewrite root= to a PARTUUID"
fi

if grep -q 'grep -q "root=PARTUUID=' "$PACK"; then
    ok "packer verifies the substitution happened"
else
    bad "packer does not verify the root= substitution"
fi

# --- 3. PARTUUID / disk id agree -----------------------------------------
if [[ "$DISK_ID" =~ ^0x[0-9A-Fa-f]{8}$ ]]; then
    ok "DISK_ID is a 32-bit MBR id ($DISK_ID)"
else
    bad "DISK_ID is not a 32-bit MBR id: $DISK_ID"
fi
PARTUUID=$(printf '%08x' "$((DISK_ID))")-02
if [[ "$PARTUUID" =~ ^[0-9a-f]{8}-02$ ]]; then
    ok "PARTUUID derives as ${PARTUUID} (partition 2, the rootfs)"
else
    bad "PARTUUID does not derive cleanly: $PARTUUID"
fi
if grep -q 'label-id: \${DISK_ID}' "$PACK"; then
    ok "sfdisk writes the same disk id the PARTUUID is derived from"
else
    bad "sfdisk does not write DISK_ID, so the PARTUUID would not match the table"
fi

# --- 4. Partition geometry agrees with the bootloader offset --------------
BOOT_START_SECTORS=$(( UBOOT_GAP_MIB * 2048 ))
ROOT_START_SECTORS=$(( (UBOOT_GAP_MIB + BOOT_PART_MIB) * 2048 ))
if grep -q 'start=\$(( BOOT_START_MIB \* 2048 ))' "$PACK" && \
   grep -q 'start=\$(( ROOT_START_MIB \* 2048 ))' "$PACK"; then
    ok "partitions are placed from the configured gap and boot size"
else
    bad "partition start sectors are hardcoded in the packer"
fi
if grep -q 'BOOT_START_MIB="\$UBOOT_GAP_MIB"' "$PACK" && \
   grep -q 'ROOT_START_MIB=\$(( UBOOT_GAP_MIB + BOOT_PART_MIB ))' "$PACK"; then
    ok "boot starts after the U-Boot gap, root starts after the boot partition"
else
    bad "boot/root offsets are not derived from UBOOT_GAP_MIB and BOOT_PART_MIB"
fi
if (( BOOT_START_SECTORS > 16 )) && (( ROOT_START_SECTORS > BOOT_START_SECTORS )); then
    ok "geometry is ordered: SPL gap < boot < root ($BOOT_START_SECTORS < $ROOT_START_SECTORS sectors)"
else
    bad "partition geometry overlaps (boot $BOOT_START_SECTORS, root $ROOT_START_SECTORS sectors)"
fi

if grep -q 'dd if="\$UBOOT_BIN" of="\$IMG" bs=1024 seek=8' "$PACK"; then
    ok "U-Boot SPL is written at 8 KiB, where the H700 boot ROM looks"
else
    bad "U-Boot SPL offset is not 8 KiB"
fi

if grep -q 'type=c, bootable' "$PACK" && grep -q 'type=83' "$PACK"; then
    ok "p1 is a bootable FAT partition and p2 is Linux"
else
    bad "partition types are not FAT-boot + Linux"
fi

# --- 5. Labels agree with the fstab that will mount them -------------------
if grep -q -- "-n \"\$BOOT_LABEL\"" "$PACK"; then
    ok "FAT partition is labelled from BOOT_LABEL ($BOOT_LABEL)"
else
    bad "FAT label does not come from BOOT_LABEL"
fi
if grep -q -- "-L \"\$ROOT_LABEL\"" "$PACK"; then
    ok "ext4 partition is labelled from ROOT_LABEL ($ROOT_LABEL)"
else
    bad "ext4 label does not come from ROOT_LABEL"
fi

FSTAB_ROOT=$(grep -E "^LABEL=[^ ]+ +/ +ext4" "$CONFIGURE" | head -1 | awk '{print $1}')
FSTAB_BOOT=$(grep -E "^LABEL=[^ ]+ +/boot " "$CONFIGURE" | head -1 | awk '{print $1}')
if [[ "$FSTAB_ROOT" == "LABEL=$ROOT_LABEL" ]]; then
    ok "fstab mounts / from LABEL=$ROOT_LABEL, the label the packer writes"
else
    bad "fstab root entry ($FSTAB_ROOT) does not match ROOT_LABEL=$ROOT_LABEL"
fi
if [[ "$FSTAB_BOOT" == "LABEL=$BOOT_LABEL" ]]; then
    ok "fstab mounts /boot from LABEL=$BOOT_LABEL"
else
    bad "fstab /boot entry ($FSTAB_BOOT) does not match BOOT_LABEL=$BOOT_LABEL"
fi

# --- 6. Deliverables ------------------------------------------------------
if grep -q 'bmaptool create' "$PACK"; then
    ok "packer emits a .bmap"
else
    bad "packer emits no .bmap"
fi
if grep -q 'sha256sum' "$PACK" && grep -q 'SHA256SUMS' "$PACK"; then
    ok "packer emits SHA256SUMS"
else
    bad "packer emits no SHA256SUMS"
fi
if grep -q 'xz -T 0' "$PACK" && ! grep -q 'gzip -' "$PACK"; then
    ok "packer compresses to .img.xz"
else
    bad "packer does not compress to .img.xz"
fi
if grep -q 'e2fsck -fn' "$PACK"; then
    ok "packer validates the root filesystem before assembling"
else
    bad "packer ships an unvalidated root filesystem"
fi

echo "boot-chain: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
