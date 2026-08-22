#!/usr/bin/env bash
# =============================================================================
# ghOSt Filesystem Expander
# Runs once on first boot — expands root partition to fill the entire SD card
# Similar to raspi-config's expand_rootfs but designed for our partition layout
#
# Partition layout:
#   p1  raw     20MB    Android boot image
#   p2  raw     16MB    U-Boot environment
#   p3  ext4    ROOT    ← expand this to fill remaining space
#   p4  swap    4GB     ← at END of card — must be moved/recreated after expand
# =============================================================================
set -euo pipefail

DONE_FILE="/var/lib/ghost/.fs_expanded"
LOG="/var/log/ghost-expand.log"

log() { echo "[expand] $*" | tee -a "$LOG"; }

# Already done
[[ -f "$DONE_FILE" ]] && exit 0

log "ghOSt filesystem expansion starting..."
log "$(date)"

# Find our root device
ROOT_PART="$(findmnt -n -o SOURCE /)"
log "Root partition: $ROOT_PART"

# Derive the disk device from partition (e.g. /dev/mmcblk0p3 → /dev/mmcblk0)
if [[ "$ROOT_PART" =~ ^(/dev/mmcblk[0-9]+)p([0-9]+)$ ]]; then
    DISK="${BASH_REMATCH[1]}"
    ROOT_PART_NUM="${BASH_REMATCH[2]}"
    SWAP_PART_NUM=$(( ROOT_PART_NUM + 1 ))
    SWAP_PART="${DISK}p${SWAP_PART_NUM}"
elif [[ "$ROOT_PART" =~ ^(/dev/sd[a-z])([0-9]+)$ ]]; then
    DISK="${BASH_REMATCH[1]}"
    ROOT_PART_NUM="${BASH_REMATCH[2]}"
    SWAP_PART_NUM=$(( ROOT_PART_NUM + 1 ))
    SWAP_PART="${DISK}${SWAP_PART_NUM}"
else
    log "ERROR: Cannot determine disk device from $ROOT_PART"
    exit 1
fi

log "Disk: $DISK"
log "Root partition number: $ROOT_PART_NUM"
log "Swap partition number: $SWAP_PART_NUM"

# Get total disk size in sectors
TOTAL_SECTORS=$(cat "/sys/block/$(basename $DISK)/size")
SECTOR_SIZE=$(cat "/sys/block/$(basename $DISK)/queue/hw_sector_size" 2>/dev/null || echo 512)
TOTAL_GB=$(( TOTAL_SECTORS * SECTOR_SIZE / 1024 / 1024 / 1024 ))
log "Disk total: ${TOTAL_GB}GB (${TOTAL_SECTORS} sectors of ${SECTOR_SIZE}B)"

# Get current partition boundaries (sectors)
ROOT_START=$(parted -s "$DISK" unit s print | awk -v part="$ROOT_PART_NUM" '$1 == part {print $2}' | tr -d 's')
ROOT_END_CURR=$(parted -s "$DISK" unit s print | awk -v part="$ROOT_PART_NUM" '$1 == part {print $3}' | tr -d 's')
SWAP_START_CURR=$(parted -s "$DISK" unit s print | awk -v part="$SWAP_PART_NUM" '$1 == part {print $2}' | tr -d 's')

SWAP_SIZE_SECTORS=$(( 4 * 1024 * 1024 * 1024 / SECTOR_SIZE ))  # 4GB in sectors
ALIGNMENT=2048  # 1MB alignment

# New layout:
# root: from ROOT_START to (TOTAL_SECTORS - SWAP_SIZE_SECTORS - 1MB alignment - 1)
# swap: from there to end

NEW_SWAP_START=$(( TOTAL_SECTORS - SWAP_SIZE_SECTORS - ALIGNMENT ))
NEW_ROOT_END=$(( NEW_SWAP_START - 1 ))
NEW_SWAP_END=$(( TOTAL_SECTORS - ALIGNMENT ))

log "New root: sectors $ROOT_START — $NEW_ROOT_END"
log "New swap: sectors $NEW_SWAP_START — $NEW_SWAP_END"

# Sanity check — only expand if there's meaningful space to gain
CURRENT_ROOT_SIZE=$(( (ROOT_END_CURR - ROOT_START) * SECTOR_SIZE / 1024 / 1024 / 1024 ))
NEW_ROOT_SIZE=$(( (NEW_ROOT_END - ROOT_START) * SECTOR_SIZE / 1024 / 1024 / 1024 ))
GAIN=$(( NEW_ROOT_SIZE - CURRENT_ROOT_SIZE ))

if [[ $GAIN -lt 1 ]]; then
    log "Partition already at maximum size (gain would be <1GB). Skipping."
    mkdir -p "$(dirname $DONE_FILE)"
    touch "$DONE_FILE"
    exit 0
fi

log "Will gain approximately ${GAIN}GB"

# =============================================================================
# STEP 1: Disable swap
# =============================================================================
log "Disabling swap..."
swapoff -a || true

# =============================================================================
# STEP 2: Delete swap partition and root partition
#         Recreate both at new sizes
#         CRITICAL: do NOT touch p1/p2 (boot chain + environment)
# =============================================================================
log "Repartitioning..."

# Use parted in script mode — delete swap then root, recreate both
parted -s "$DISK" \
    rm "$SWAP_PART_NUM" \
    rm "$ROOT_PART_NUM" \
    mkpart primary ext4 "${ROOT_START}s" "${NEW_ROOT_END}s" \
    mkpart primary linux-swap "${NEW_SWAP_START}s" "${NEW_SWAP_END}s"

log "Partition table updated"

# Inform kernel of partition table change
partprobe "$DISK" 2>/dev/null || \
    hdparm -z "$DISK" 2>/dev/null || \
    blockdev --rereadpt "$DISK" 2>/dev/null || true

sleep 2

# =============================================================================
# STEP 3: Expand the ext4 filesystem to fill new partition size
# =============================================================================
log "Expanding ext4 filesystem..."

# Must run e2fsck before resize2fs on a live filesystem
# We do this online since kernel 5.x supports online resize for ext4
e2fsck -f -y "$ROOT_PART" 2>/dev/null || true
resize2fs "$ROOT_PART"

log "Filesystem expanded to $(df -h / | awk 'NR==2{print $2}')"

# =============================================================================
# STEP 4: Recreate swap at new location
# =============================================================================
log "Recreating swap partition..."
mkswap -L "GHOST_SWAP" "$SWAP_PART"

# Update /etc/fstab with new swap UUID
NEW_SWAP_UUID=$(blkid -s UUID -o value "$SWAP_PART")
if [[ -n "$NEW_SWAP_UUID" ]]; then
    sed -i "s|UUID=[a-f0-9-]*\( *none *swap\)|UUID=${NEW_SWAP_UUID}\1|g" /etc/fstab
    log "fstab swap UUID updated to $NEW_SWAP_UUID"
fi

# Re-enable swap
swapon "$SWAP_PART" || true

# =============================================================================
# STEP 5: Mark done
# =============================================================================
mkdir -p "$(dirname $DONE_FILE)"
touch "$DONE_FILE"

log "Filesystem expansion complete"
log "Root: $(df -h / | awk 'NR==2{print $2}') total, $(df -h / | awk 'NR==2{print $4}') free"
log "Swap: $(swapon --show 2>/dev/null | tail -1)"
log ""
log "Rebooting to ensure clean state..."

# Short delay then reboot — ensures expanded FS is cleanly mounted from scratch
sleep 3
reboot
