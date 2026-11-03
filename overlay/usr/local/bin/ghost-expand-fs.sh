#!/usr/bin/env bash
# =============================================================================
# ghOSt first-boot root expansion
#
# The shipped image is MBR: p1 FAT "BOOT" (256MiB, fixed) and p2 ext4 "rootfs".
# There is no swap partition (zram handles swap), so nothing here touches swap
# and nothing assumes a partition number beyond the one that holds /.
#
# Safe by construction: the disk and partition number come from the kernel, the
# partition is only ever grown (never deleted and recreated), and the filesystem
# is resized in place. Running it twice, or on a card that is already full size,
# changes nothing.
# =============================================================================
set -euo pipefail

DONE_FILE="/var/lib/ghost/.fs_expanded"
LOG="/var/log/ghost-expand.log"

log() { echo "[expand] $*" | tee -a "$LOG"; }

[[ -f "$DONE_FILE" ]] && exit 0
mkdir -p "$(dirname "$DONE_FILE")"

# /dev/disk/by-uuid/... and /dev/mapper/... must be resolved to a real node.
ROOT_PART="$(findmnt -n -o SOURCE / || true)"
if [[ -n "$ROOT_PART" && -L "$ROOT_PART" ]]; then
    ROOT_PART="$(readlink -f "$ROOT_PART")"
fi
ROOT_PART="${ROOT_PART%%\[*}"          # strip btrfs subvolume suffix if present

if [[ ! -b "$ROOT_PART" ]]; then
    log "cannot resolve the block device for / (got '${ROOT_PART:-nothing}')"
    exit 1
fi

# Derive disk + partition number for mmc, sd/vd and nvme naming.
if [[ "$ROOT_PART" =~ ^(/dev/mmcblk[0-9]+)p([0-9]+)$ ]]; then
    DISK="${BASH_REMATCH[1]}"; PART_NUM="${BASH_REMATCH[2]}"
elif [[ "$ROOT_PART" =~ ^(/dev/nvme[0-9]+n[0-9]+)p([0-9]+)$ ]]; then
    DISK="${BASH_REMATCH[1]}"; PART_NUM="${BASH_REMATCH[2]}"
elif [[ "$ROOT_PART" =~ ^(/dev/[shv]d[a-z])([0-9]+)$ ]]; then
    DISK="${BASH_REMATCH[1]}"; PART_NUM="${BASH_REMATCH[2]}"
else
    log "unsupported partition naming: $ROOT_PART"
    exit 1
fi

log "=== ghOSt root expansion $(date -Is) ==="
log "root=$ROOT_PART disk=$DISK partition=$PART_NUM"

grew=0
if command -v growpart >/dev/null 2>&1; then
    set +e
    out="$(growpart "$DISK" "$PART_NUM" 2>&1)"
    rc=$?
    set -e
    case "$rc" in
        0) log "growpart: $out"; grew=1 ;;
        2) log "partition already fills the card ($out)" ;;
        *) log "growpart failed: $out"; exit 1 ;;
    esac
else
    # growpart (cloud-guest-utils) may be absent; parted can grow in place too.
    if parted -s "$DISK" resizepart "$PART_NUM" 100% 2>/dev/null; then
        log "grew partition $PART_NUM to the end of $DISK with parted"
        grew=1
    else
        log "could not grow partition $PART_NUM (no growpart, parted refused)"
        exit 1
    fi
fi

if (( grew )); then
    partprobe "$DISK" 2>/dev/null || blockdev --rereadpt "$DISK" 2>/dev/null || true
    sleep 1
fi

# Resize unconditionally: growpart reports "no change" when the partition is
# already the full card size, but the filesystem inside it can still be the
# smaller one from the flashed image. resize2fs is a no-op once they match.
resize2fs "$ROOT_PART" || { log "resize2fs failed on $ROOT_PART"; exit 1; }
log "filesystem is now $(df -h / | awk 'NR==2 {print $2}') with $(df -h / | awk 'NR==2 {print $4}') free"

touch "$DONE_FILE"
log "done"
