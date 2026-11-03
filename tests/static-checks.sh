#!/usr/bin/env bash
# Static consistency checks: syntax, boot-chain naming, docs/output naming.
# Catches the class of bug where two files disagree about a file name or path.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
fail=0
ok()  { echo "  ok    $*"; }
bad() { echo "  FAIL  $*"; fail=1; }

echo "-- shell syntax"
sh_fail=0
while IFS= read -r f; do
    # flash_dd_with_gpt.MacOS.sh is zsh (glob qualifiers), everything else is bash
    if head -1 "$f" | grep -q 'zsh'; then
        if command -v zsh >/dev/null 2>&1; then
            zsh -n "$f" || { bad "zsh -n $f"; sh_fail=1; }
        fi
    else
        bash -n "$f" || { bad "bash -n $f"; sh_fail=1; }
    fi
done < <(git ls-files --cached --others --exclude-standard '*.sh' | grep -v '^build/')
(( sh_fail == 0 )) && ok "every shell script parses"

echo "-- python syntax"
while IFS= read -r f; do
    python3 -m py_compile "$f" || bad "py_compile $f"
done < <(git ls-files '*.py' | grep -v '^tests/')
python3 -m py_compile overlay/usr/local/sbin/ghost-panel || bad "py_compile ghost-panel"
python3 -m py_compile overlay/usr/local/sbin/ghost-wifi-import 2>/dev/null || true
find . -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
ok "all python compiles"

echo "-- boot chain agreement"
grep -q 'fatload .*0x4FA00000 dtb.img' patches/uboot/boot.cmd \
    && ok "boot.cmd loads dtb.img" || bad "boot.cmd does not load dtb.img"
grep -q 'dtb-regular.img' image/pack-image-rocknix.sh \
    && ok "packer ships dtb-regular.img" || bad "packer does not ship dtb-regular.img"
grep -q 'dtb-rev6.img' image/pack-image-rocknix.sh \
    && ok "packer ships dtb-rev6.img" || bad "packer does not ship dtb-rev6.img"
grep -q '^DTB_REV6_NAME=' config.sh \
    && ok "config.sh defines DTB_REV6_NAME" || bad "config.sh missing DTB_REV6_NAME"
for f in wifi.txt panel.txt README.txt; do
    [[ -f "image/bootfiles/$f" ]] && ok "bootfile $f exists" || bad "bootfile $f missing"
done
for tool in mcopy sfdisk mkimage mkfs.vfat mkfs.ext4 e2fsck; do
    grep -q "command -v $tool\|for tool in .*$tool" image/pack-image-rocknix.sh \
        || bad "packer does not require $tool"
done
ok "packer tool requirements"

echo "-- root expansion matches the shipped MBR layout"
EXPAND=overlay/usr/local/bin/ghost-expand-fs.sh
grep -q 'findmnt' $EXPAND && grep -q 'growpart' $EXPAND \
    && ok "expander derives disk and grows partition" || bad "expander not layout-agnostic"
grep -qE 'SWAP_PART|mkswap|swapoff' $EXPAND \
    && bad "expander still manipulates a swap partition" || ok "expander leaves swap alone"
grep -q 'resize2fs' $EXPAND && ok "expander resizes the filesystem" || bad "no resize2fs"
grep -q 'cloud-guest-utils' rootfs/build-rootfs.sh \
    && ok "growpart (cloud-guest-utils) is installed" || bad "growpart missing from the rootfs"

echo "-- arm64 chroots work without binfmt"
for f in rootfs/build-ui-xfce.sh build.sh; do
    grep -q 'qemu-aarch64-static' "$f" \
        && ok "$(basename "$f") uses the static qemu" || bad "$(basename "$f") chroots without qemu"
done
grep -q 'rm ' $EXPAND && bad "expander deletes partitions" || ok "expander never deletes a partition"


echo "-- fstab and module indexing"
CONF=overlay/opt/ghost/scripts/configure.sh
grep -q 'depmod' $CONF && ok "module index built at configure time" || bad "no depmod: modules never load"
grep -q 'BOOT_FLOW' $CONF && ok "fstab chosen by BOOT_FLOW" || bad "fstab still guessed from lightdm"
grep -q 'env "BOOT_FLOW' build.sh && ok "BOOT_FLOW reaches the chroot" || bad "BOOT_FLOW not passed to chroot"
[[ "$(grep -c 'UUID=SWAP_UUID' $CONF)" == "1" ]] \
    && ok "swap-partition fstab limited to the legacy branch" \
    || bad "swap-partition fstab leaks into the MBR layout"
grep -q 'LABEL=BOOT' $CONF && ok "MBR fstab uses LABELs" || bad "fstab not label based"


echo "-- panel service wiring"
grep -q 'ghost-panel.service' overlay/opt/ghost/scripts/configure.sh \
    && ok "ghost-panel.service enabled" || bad "ghost-panel.service not enabled"
grep -q 'ghost-wifi-import.service' overlay/opt/ghost/scripts/configure.sh \
    && ok "ghost-wifi-import.service enabled" || bad "ghost-wifi-import.service not enabled"
grep -q 'ExecStart=/usr/local/sbin/ghost-panel' overlay/etc/systemd/system/ghost-panel.service \
    && ok "panel unit points at ghost-panel" || bad "panel unit ExecStart wrong"

echo "-- output naming (must be .img.xz, MBR image)"
for f in docker-entrypoint.sh docker-compose.yml README.md DOCKER_BUILD.md; do
    if grep -q 'img\.gz' "$f"; then
        bad "$f still mentions .img.gz"
    else
        ok "$f has no .img.gz"
    fi
done
grep -q 'img\.xz' docker-entrypoint.sh && ok "entrypoint reports .img.xz" || bad "entrypoint not updated"
for f in flash_dd_with_gpt.sh flash_dd_with_gpt.MacOS.sh; do
    grep -q 'img\.xz' "$f" && ok "$f accepts .img.xz" || bad "$f rejects .img.xz"
done

echo "-- licence compliance"
[[ -f LICENSE ]] && grep -q 'MIT License' LICENSE && ok "LICENSE present (MIT)" || bad "LICENSE missing"
[[ -f NOTICE ]] && ok "NOTICE present" || bad "NOTICE missing"
[[ -f LICENSES/MIT-handtop.txt ]] && ok "handtop MIT notice kept" || bad "handtop notice missing"
grep -q 'Copyright (c) 2026 Handtop contributors' LICENSES/MIT-handtop.txt \
    && ok "handtop copyright line intact" || bad "handtop copyright missing"
# every file derived from handtop must point at the preserved notice
for f in image/pack-image-rocknix.sh overlay/usr/local/sbin/ghost-panel \
         overlay/usr/local/sbin/ghost-wifi-import; do
    grep -q 'LICENSES/MIT-handtop.txt' "$f" \
        && ok "$(basename "$f") attributes handtop" || bad "$(basename "$f") lacks attribution"
done
[[ -f LICENSES/GPL-2.0.txt ]] && grep -q 'GNU GENERAL PUBLIC LICENSE' LICENSES/GPL-2.0.txt \
    && ok "GPL-2.0 text kept" || bad "GPL-2.0 text missing"
grep -q 'GPL-2.0' NOTICE && grep -q 'hataketsu' NOTICE \
    && ok "cyberdeck GPL-2.0 lineage documented" || bad "cyberdeck licence not documented"
for f in patches/kernel/configure-empty-initramfs.sh scripts/patch-h700-dtb-regulators.py \
         rootfs/build-ui-xfce.sh; do
    grep -q 'GPL-2.0' "$f" && ok "$(basename "$f") marked GPL-2.0" \
        || bad "$(basename "$f") lacks GPL notice"
done
grep -q 'smittix/intercept' NOTICE && ok "Apache-2.0 intercept documented in NOTICE" \
    || bad "intercept not documented"
grep -qi 'apache-2.0' NOTICE && ok "intercept licence named" || bad "intercept licence not named"


echo "-- shellcheck (advisory: reports, never fails the suite yet)"
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -S error -x image/pack-image-rocknix.sh tests/*.sh \
           kernel/build-rocknix.sh 2>/dev/null; then
        ok "no shellcheck errors in packer/tests/kernel"
    else
        echo "  WARN  shellcheck reported errors (advisory for now)"
    fi
else
    echo "  skip  shellcheck not installed on this host"
fi

echo "-- proven boot payload is the default"
BOOTSRC=kernel/fetch-rocknix-boot.sh
[[ -f $BOOTSRC ]] && ok "release payload extractor exists" || bad "extractor missing"
grep -q '^GHOST_BOOT_SOURCE=' config.sh && grep -q 'release' config.sh \
    && ok "release payload is the default source" || bad "default boot source not set"
grep -q 'fetch-rocknix-boot.sh' build.sh && ok "build.sh uses the extractor" || bad "build.sh ignores it"
grep -q 'fetch-rocknix-boot.sh' .github/workflows/build.yml \
    && ok "CI stages the release payload" || bad "CI does not use the extractor"
grep -q '^ROCKNIX_IMAGE_SHA256=' VERSIONS && ok "release image is pinned with a checksum" \
    || bad "no release checksum pin"
grep -q 'sha256sum -c' $BOOTSRC && ok "extractor verifies the checksum" || bad "no checksum check"
grep -qE '^[[:space:]]*(losetup|kpartx|mount)[[:space:]]' $BOOTSRC \
    && bad "extractor uses loop devices or mounts" || ok "extractor is loop-free"


echo "-- boot asset staging (ROCKNIX layout)"
KERNEL_BOOT_REF=image/pack-image-rocknix.sh
grep -q 'KERNEL_BOOT="\$KERNEL_BUILD_DIR/boot"' $KERNEL_BOOT_REF \
    && ok "packer prefers staged boot assets" || bad "packer does not use staged assets"
grep -q 'UBOOT_DDR' $KERNEL_BOOT_REF && grep -q '^UBOOT_DDR=' config.sh \
    && ok "U-Boot blob selected by RAM type" || bad "U-Boot DDR selection missing"
grep -q 'candidate_dtbs' kernel/build-rocknix.sh \
    && ok "kernel stage discovers ROCKNIX device trees" || bad "no DTB discovery"
grep -q 'BOOT_STAGE' kernel/build-rocknix.sh \
    && ok "kernel stage stages Image/SPL/DTBs" || bad "no boot asset staging"
grep -q 'rootfs-overlay' kernel/build-rocknix.sh \
    && grep -q 'lib/modules' kernel/build-rocknix.sh \
    && grep -q 'lib/firmware' kernel/build-rocknix.sh \
    && ok "kernel modules and firmware staged into the rootfs overlay" \
    || bad "modules never reach the image"
grep -q 'rootfs-overlay' build.sh \
    && ok "build.sh applies the staged kernel overlay" || bad "staged overlay is not applied"


echo "-- CI installs the packer's tools"
for tool in mtools dosfstools e2fsprogs fdisk u-boot-tools; do
    grep -q "$tool" .github/workflows/build.yml \
        && ok "CI installs $tool" || bad "CI does not install $tool"
done

echo
if (( fail == 0 )); then echo "static checks: PASS"; else echo "static checks: FAIL"; exit 1; fi
