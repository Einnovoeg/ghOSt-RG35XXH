#!/usr/bin/env bash
# Exercise image/pack-image-rocknix.sh.
#
# With real mkfs/mtools/sfdisk (Linux CI, run as root) the image is built and
# inspected: partition table, FAT contents, ext4 label, boot.scr payload, CRLF
# boot files and rootfs sanitisation. Without those tools (e.g. macOS) the same
# run uses stubs and asserts the commands the packer issued instead.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
H="$(mktemp -d)"
trap 'rm -rf "$H"' EXIT
fail=0
ok()  { echo "  ok    $*"; }
bad() { echo "  FAIL  $*"; fail=1; }

# --- fixture: a tiny Debian-looking rootfs --------------------------------
R="$H/rootfs"
mkdir -p "$R/etc/ssh" "$R/usr/bin" "$R/boot" "$R/var/lib/dbus"
echo "13.0" > "$R/etc/debian_version"
echo "host-identity" > "$R/etc/machine-id"
echo "host-identity" > "$R/var/lib/dbus/machine-id"
echo "KEY" > "$R/etc/ssh/ssh_host_ed25519_key"
echo "qemu" > "$R/usr/bin/qemu-aarch64-static"
echo "stale-boot" > "$R/boot/Image"
dd if=/dev/zero of="$R/usr/data.bin" bs=1M count=24 status=none

A="$H/artifacts"; mkdir -p "$A"
printf 'UBOOT-SPL-BLOB' > "$A/u-boot.bin"
head -c 65536 /dev/zero | tr '\0' 'I' > "$A/Image"
printf 'DTB-REGULAR' > "$A/dtb-regular"
printf 'DTB-REV6' > "$A/dtb-rev6"

# --- mode selection ------------------------------------------------------
HAVE_REAL=1
for t in mkfs.vfat mcopy mdir mtype mkfs.ext4 e2fsck dumpe2fs debugfs sfdisk mkimage; do
    command -v "$t" >/dev/null 2>&1 || HAVE_REAL=0
done
[[ "$(id -u)" == "0" ]] || HAVE_REAL=0

run_packer() { # $1 = rev6 dtb path
    PATH="$H/bin:$PATH" \
    GHOST_UBOOT_BIN="$A/u-boot.bin" \
    GHOST_KERNEL_IMAGE="$A/Image" \
    GHOST_DTB_FILE="$A/dtb-regular" \
    GHOST_DTB_REV6_FILE="$1" \
    ROOTFS_DIR="$R" RG_DIST="$H/dist" RG_WORK="$H/work" \
    IMAGE_SIZE_GB=0 KEEP_RAW_IMAGE=true \
    bash image/pack-image-rocknix.sh
}

if (( HAVE_REAL )); then
    echo "-- mode: real tools ($(mkfs.vfat --version 2>&1 | head -1))"
    mkdir -p "$H/dist"
    if ! run_packer "$A/dtb-rev6" > "$H/pack.log" 2>&1; then
        bad "packer failed"
        tail -20 "$H/pack.log"
        exit 1
    fi
    ok "packer completed"
    IMG="$(ls "$H"/dist/*.img | head -1)"
    [[ -f "$IMG" ]] && ok "raw image kept" || bad "no raw image"

    # partition table: MBR, bootable FAT at 16MiB, ext4 at 272MiB
    sfdisk -d "$IMG" > "$H/sf.txt" 2>/dev/null
    grep -q "label: dos" "$H/sf.txt" && ok "MBR (dos) partition table" || bad "not MBR"
    grep -q "start=32768" "$H/sf.txt" && ok "p1 starts at 16MiB" || bad "p1 offset wrong"
    grep -q "start=557056" "$H/sf.txt" && ok "p2 starts at 272MiB" || bad "p2 offset wrong"
    grep -qE "start=32768,.*bootable" "$H/sf.txt" && ok "p1 marked bootable" || bad "p1 not bootable"
    grep -q "label-id: 0x47334f53" "$H/sf.txt" && ok "fixed disk id" || bad "disk id wrong"

    # extract partitions for inspection
    python3 - "$IMG" "$H" <<'PY'
import re, subprocess, sys
img, out = sys.argv[1], sys.argv[2]
txt = subprocess.run(["sfdisk", "-d", img], capture_output=True, text=True).stdout
parts = re.findall(r"start=\s*(\d+),\s*size=\s*(\d+)", txt)
for i, (start, size) in enumerate(parts[:2], 1):
    with open(f"{out}/p{i}.part", "wb") as fh:
        subprocess.run(["dd", f"if={img}", f"of={out}/p{i}.part", "bs=512",
                        f"skip={start}", f"count={size}", "status=none"], check=True)
print("extracted", len(parts[:2]), "partitions")
PY

    # FAT boot partition contents
    mdir -i "$H/p1.part" ::/ > "$H/fat.txt" 2>/dev/null
    for f in Image dtb.img dtb-regular.img dtb-rev6.img boot.scr boot.cmd \
             wifi.txt panel.txt README.txt logs; do
        grep -qi "$f" "$H/fat.txt" && ok "boot partition has $f" || bad "boot partition missing $f"
    done
    [[ "$(mtype -i "$H/p1.part" ::/dtb.img)" == "DTB-REGULAR" ]] \
        && ok "dtb.img starts as the regular panel DTB" || bad "dtb.img content wrong"
    [[ "$(mtype -i "$H/p1.part" ::/dtb-rev6.img)" == "DTB-REV6" ]] \
        && ok "rev6 DTB shipped" || bad "rev6 DTB wrong"

    # boot.scr must be a compiled U-Boot script that loads dtb.img
    mcopy -i "$H/p1.part" ::/boot.scr "$H/boot.scr" 2>/dev/null
    python3 - "$H/boot.scr" <<'PY' && ok "boot.scr is a U-Boot script loading dtb.img" || bad "boot.scr invalid"
import sys
d = open(sys.argv[1], "rb").read()
assert d[:4] == bytes.fromhex("27051956"), "bad uImage magic"
assert b"dtb.img" in d, "boot.scr does not load dtb.img"
assert b"PARTUUID=47334f53-02" in d, "boot.scr lacks PARTUUID root="
sys.exit(0)
PY

    # CRLF so the files are editable from Windows
    mcopy -i "$H/p1.part" ::/panel.txt "$H/panel.txt" 2>/dev/null
    python3 - "$H/panel.txt" <<'PY' && ok "panel.txt staged with CRLF" || bad "panel.txt not CRLF"
import sys
d = open(sys.argv[1], "rb").read()
assert b"\r\n" in d, "no CRLF"
sys.exit(0)
PY

    # ext4 root partition
    e2fsck -fn "$H/p2.part" > "$H/fsck.log" 2>&1 && ok "ext4 filesystem clean" || { bad "e2fsck failed"; tail -5 "$H/fsck.log"; }
    dumpe2fs -h "$H/p2.part" 2>/dev/null | grep -q "volume name:.*rootfs" \
        && ok "ext4 label rootfs" || bad "ext4 label wrong"

    # host identity stripped from the shipped rootfs
    [[ -z "$(debugfs -R 'cat /etc/machine-id' "$H/p2.part" 2>/dev/null | tr -d '\0' | tr -d '\n')" ]] \
        && ok "machine-id emptied" || bad "machine-id still set"
    debugfs -R 'ls -l /etc/ssh' "$H/p2.part" 2>/dev/null | grep -q 'ssh_host_' \
        && bad "ssh host keys shipped" || ok "no ssh host keys shipped"
    debugfs -R 'stat /usr/bin/qemu-aarch64-static' "$H/p2.part" 2>/dev/null | grep -q 'Inode:' \
        && bad "qemu binary shipped" || ok "qemu-aarch64-static stripped"
    debugfs -R 'ls -l /boot' "$H/p2.part" 2>/dev/null | grep -q 'Image' \
        && bad "stale /boot payload on ext4" || ok "no second kernel copy on ext4"

    # outputs
    ls "$H"/dist/*.img.xz >/dev/null 2>&1 && ok ".img.xz written" || bad "no .img.xz"
    grep -q . "$H"/dist/SHA256SUMS 2>/dev/null && ok "SHA256SUMS written" || bad "no SHA256SUMS"
else
    echo "-- mode: stub tools (no Linux mkfs/mtools on this host)"
    mkdir -p "$H/bin" "$H/dist"
    LOG="$H/stub.log"; : > "$LOG"

    for t in id mkfs.vfat mcopy mkfs.ext4 e2fsck sfdisk dd truncate mountpoint \
             git xz sha256sum bmaptool mkimage; do
        cat > "$H/bin/$t" <<EOF
#!/bin/sh
case "$t" in
  id) echo 0; exit 0 ;;
  mountpoint) exit 1 ;;
  git) echo stubsha; exit 0 ;;
esac
echo "STUB $t \$*" >> "\$STUBLOG"
case "$t:\$*" in
  sfdisk:-d*) echo "label: dos"; echo "label-id: 0x47334f53"
              echo "/dev/x1 : start=32768, size=524288, type=c, bootable"
              echo "/dev/x2 : start=557056, size=1048576, type=83" ;;
  sfdisk:-l*) : ;;                  # never read stdin here: sfdisk -d above does
  sfdisk:*) cat >> "\$STUBLOG" ;;   # capture the partition script fed on stdin
esac
case "$t" in
  truncate)
    out=""; for a in "\$@"; do case "\$a" in /*) out="\$a";; esac; done
    [ -n "\$out" ] && : > "\$out" ;;
  mkfs.vfat)
    out=""; prev=""
    for a in "\$@"; do [ "\$prev" = "-C" ] && out="\$a"; prev="\$a"; done
    [ -n "\$out" ] && : > "\$out" ;;
  xz)
    for a in "\$@"; do case "\$a" in *.img) : > "\$a.xz";; esac; done ;;
esac
exit 0
EOF
        chmod +x "$H/bin/$t"
    done
    export STUBLOG="$LOG"

    if ! run_packer "$A/dtb-rev6" > "$H/pack.log" 2>&1; then
        bad "packer failed"
        tail -20 "$H/pack.log"
        exit 1
    fi
    ok "packer completed"
    for pat in "dtb-regular.img" "dtb-rev6.img" "dtb.img" "wifi.txt" "panel.txt" \
               "README.txt" "mkfs.vfat -F 32 -n BOOT" "mkfs.ext4 -q -F -L rootfs" \
               "start=32768, size=524288, type=c, bootable" "bs=1024 seek=8" \
               "bs=1M seek=16" "bs=1M seek=272"; do
        grep -qF -- "$pat" "$LOG" && ok "issued: $pat" || bad "missing: $pat"
    done
    grep -q "0x4FA00000 dtb.img" patches/uboot/boot.cmd \
        && ok "boot.cmd loads dtb.img" || bad "boot.cmd wrong"

    # missing rev6 DTB must warn, not abort
    run_packer "$A/does-not-exist" > "$H/run2.log" 2>&1
    rc=$?
    (( rc == 0 )) && ok "builds without the rev6 DTB" || bad "rev6-less build failed ($rc)"
    grep -q "rev6 DTB not found" "$H/run2.log" && ok "missing rev6 DTB warned" || bad "no warning"
fi

echo
if (( fail == 0 )); then echo "image packing: PASS"; else echo "image packing: FAIL"; exit 1; fi
