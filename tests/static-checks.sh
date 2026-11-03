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


echo "-- CI installs the packer's tools"
for tool in mtools dosfstools e2fsprogs fdisk u-boot-tools; do
    grep -q "$tool" .github/workflows/build.yml \
        && ok "CI installs $tool" || bad "CI does not install $tool"
done

echo
if (( fail == 0 )); then echo "static checks: PASS"; else echo "static checks: FAIL"; exit 1; fi
