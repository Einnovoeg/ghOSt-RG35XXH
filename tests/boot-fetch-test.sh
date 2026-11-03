#!/usr/bin/env bash
# Exercise kernel/fetch-rocknix-boot.sh.
#
# With real mkfs/mtools/debugfs (Linux CI) it builds a synthetic release image
# shaped like a ROCKNIX H700 release and runs the extractor against it. Without
# those tools it stubs them and asserts the same staging behaviour, so the
# control flow (partition detection, checksum gate, staging) is checked too.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
fail=0
ok()  { echo "  ok    $*"; }
bad() { echo "  FAIL  $*"; fail=1; }

H="$(mktemp -d)"; trap 'rm -rf "$H"' EXIT

assert_staged() { # $1 = build dir
    local BOOT="$1/kernel/boot" OVL="$1/kernel/rootfs-overlay"
    [[ -s "$BOOT/Image" ]] && ok "kernel Image staged" || bad "kernel Image missing"
    [[ -s "$BOOT/u-boot-sunxi-with-spl.bin" ]] && ok "U-Boot SPL staged" || bad "U-Boot missing"
    [[ -s "$BOOT/dtb-regular.img" ]] && ok "regular DTB staged" || bad "regular DTB missing"
    [[ -s "$BOOT/dtb-rev6.img" ]] && ok "rev6 DTB staged" || bad "rev6 DTB missing"
    [[ -s "$BOOT/dtb.img" ]] && ok "dtb.img present" || bad "dtb.img missing"
    if [[ -e "$OVL/lib/modules/7.1.2/kernel/drivers/net/test.ko" ]]; then
        ok "modules staged"
    else
        bad "modules missing"
        find "$OVL" -maxdepth 6 2>/dev/null | head -20 | sed 's/^/    ovl: /'
    fi
    if [[ -e "$OVL/lib/firmware/brcm/test.bin" ]]; then
        ok "firmware staged"
    else
        bad "firmware missing"
        find "$OVL" -maxdepth 6 2>/dev/null | head -20 | sed 's/^/    ovl: /'
    fi
}

HAVE=1
for t in mkfs.vfat mcopy mdir mkfs.ext4 debugfs sfdisk dd gzip blkid rsync python3 sha256sum; do
    command -v "$t" >/dev/null 2>&1 || HAVE=0
done

if (( HAVE )); then
    echo "-- mode: real tools"
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
    SRC="$H/release.img.gz"
    SHA="$(sha256sum "$SRC" | awk '{print $1}')"
else
    echo "-- mode: stubs (no Linux mkfs/mtools/debugfs on this host)"
    mkdir -p "$H/bin"
    SRC="$H/release.img"; : > "$SRC"
    SHA="$(printf '0%.0s' {1..64})"

    cat > "$H/bin/sha256sum" <<'EOS'
#!/bin/sh
cat >/dev/null; exit 0
EOS
    cat > "$H/bin/sfdisk" <<'EOS'
#!/bin/sh
case "$*" in
  *"-d"*) echo "label: dos"
          echo "/x1 : start=     2048, size=    32768, type=c, bootable"
          echo "/x2 : start=    34816, size=   131072, type=83" ;;
esac
exit 0
EOS
    cat > "$H/bin/blkid" <<'EOS'
#!/bin/sh
off=""; prev=""
for a in "$@"; do [ "$prev" = "-O" ] && off="$a"; prev="$a"; done
case "$off" in 1048576) echo vfat ;; 17825792) echo ext4 ;; *) exit 2 ;; esac
EOS
    cat > "$H/bin/mcopy" <<'EOS'
#!/bin/sh
dest=""
for a in "$@"; do case "$a" in /*) dest="$a";; esac; done
mkdir -p "$dest/device_trees"
head -c 4096 /dev/zero | tr '\0' 'K' > "$dest/Image"
printf 'DTB-REGULAR' > "$dest/device_trees/sun50i-h700-anbernic-rg35xx-h.dtb"
printf 'DTB-REV6' > "$dest/device_trees/sun50i-h700-anbernic-rg35xx-h-rev6-panel.dtb"
exit 0
EOS
    cat > "$H/bin/debugfs" <<'EOS'
#!/bin/sh
req=""; prev=""
for a in "$@"; do [ "$prev" = "-R" ] && req="$a"; prev="$a"; done
src=$(printf '%s' "$req" | awk '{print $2}')
dest=$(printf '%s' "$req" | awk '{print $3}')
# real rdump copies the directory itself into dest: dest/<basename>/...
dest="$dest/$(basename "$src")"
mkdir -p "$dest"
case "$src" in
  /usr/share/bootloader) printf 'UBOOT-SPL' > "$dest/H700_DDR4_u-boot-sunxi-with-spl.bin" ;;
  /lib/modules) mkdir -p "$dest/7.1.2/kernel/drivers/net"
                printf 'MODULE' > "$dest/7.1.2/kernel/drivers/net/test.ko" ;;
  /lib/firmware) mkdir -p "$dest/brcm"
                 printf 'FIRMWARE' > "$dest/brcm/test.bin" ;;
esac
exit 0
EOS
    cat > "$H/bin/mdir" <<'EOS'
#!/bin/sh
case "$*" in
  *"-b"*) echo '::/Image'; echo '::/device_trees/' ;;
  *) echo 'Volume in drive : is GHOST'; echo ' Image        4096 2026-11-01' ;;
esac
exit 0
EOS
    printf '#!/bin/sh\nexit 0\n' > "$H/bin/gzip"
    printf '#!/bin/sh\nexit 0\n' > "$H/bin/dd"
    chmod +x "$H/bin"/*
    export PATH="$H/bin:$PATH"
fi

BUILD="$H/build"
if ! ROCKNIX_IMAGE_FILE_PATH="$SRC" ROCKNIX_IMAGE_SHA256="$SHA" BUILD_DIR="$BUILD" \
     bash kernel/fetch-rocknix-boot.sh > "$H/out.log" 2>&1; then
    bad "extractor failed"; tail -20 "$H/out.log"; exit 1
fi
ok "extractor completed"
if (( HAVE )); then
    # the fixture itself must be sane before blaming the extractor
    mdir -b -i "$H/boot.fat" ::/ 2>/dev/null | sed 's/^/    fat: /'
    sed 's/^/    log: /' "$H/out.log"
fi
assert_staged "$BUILD"

# staging must be usable by the packer: dtb.img is the regular tree, SPL is DDR4
if (( HAVE )); then
    [[ "$(cat "$BUILD/kernel/boot/dtb.img")" == DTB-REGULAR ]] && ok "dtb.img is the regular tree" || bad "dtb.img wrong"
    [[ "$(cat "$BUILD/kernel/boot/u-boot-sunxi-with-spl.bin")" == UBOOT-SPL ]] && ok "U-Boot content intact" || bad "U-Boot content wrong"
fi

# a wrong checksum must abort rather than stage an unverified kernel
if (( ! HAVE )); then
    printf '#!/bin/sh\nexit 1\n' > "$H/bin/sha256sum"; chmod +x "$H/bin/sha256sum"
    if ROCKNIX_IMAGE_FILE_PATH="$SRC" ROCKNIX_IMAGE_SHA256="bad" BUILD_DIR="$H/build2" \
         bash kernel/fetch-rocknix-boot.sh > "$H/bad.log" 2>&1; then
        bad "accepted an image with the wrong checksum"
    else
        grep -q "checksum mismatch" "$H/bad.log" && ok "wrong checksum rejected" || bad "unclear checksum failure"
    fi
else
    if ROCKNIX_IMAGE_FILE_PATH="$SRC" ROCKNIX_IMAGE_SHA256="$(printf '0%.0s' {1..64})" \
         BUILD_DIR="$H/build2" bash kernel/fetch-rocknix-boot.sh > "$H/bad.log" 2>&1; then
        bad "accepted an image with the wrong checksum"
    else
        grep -q "checksum mismatch" "$H/bad.log" && ok "wrong checksum rejected" || bad "unclear checksum failure"
    fi
fi

echo
if (( fail == 0 )); then echo "boot extraction: PASS"; else echo "boot extraction: FAIL"; exit 1; fi
