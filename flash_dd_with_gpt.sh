#!/usr/bin/env bash
# =============================================================================
# ghOSt Linux Flash Script
# Writes a ghOSt .img or .img.gz file to removable media and repairs GPT.
# This is intended for Linux hosts where raw dd flashes can leave the backup
# GPT header needing recovery on first use.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }

ESUDO="${ESUDO:-sudo}"
SELECTED_IMAGE=""
SELECTED_DEVICE=""

show_images() {
    mapfile -t IMAGES < <(find . -maxdepth 1 -type f \( -iname "*.img" -o -iname "*.img.gz" \) -printf "%f\n" | sort)
    [[ ${#IMAGES[@]} -gt 0 ]] || log_error "No .img or .img.gz files found in $(pwd)"

    log_info "Available images:"
    local i=1
    local image
    for image in "${IMAGES[@]}"; do
        echo "  $i. $image ($(du -h "$image" | awk '{print $1}'))"
        i=$((i + 1))
    done
}

select_image() {
    if [[ ${#IMAGES[@]} -eq 1 ]]; then
        SELECTED_IMAGE="${IMAGES[0]}"
        log_info "Auto-selected: $SELECTED_IMAGE"
        return
    fi

    local choice
    read -r -p "Select image number (1-${#IMAGES[@]}): " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || log_error "Invalid selection"
    (( choice >= 1 && choice <= ${#IMAGES[@]} )) || log_error "Selection out of range"
    SELECTED_IMAGE="${IMAGES[$((choice - 1))]}"
}

show_devices() {
    log_info "Available block devices:"
    lsblk -o NAME,SIZE,TYPE,TRAN,RM,MODEL,MOUNTPOINT | grep -E "^(NAME|sd[a-z]|mmcblk[0-9]+|nvme[0-9]+n[0-9]+)"
    echo
    log_warn "Select the removable SD/USB device, not a system disk."
}

select_device() {
    local device
    while true; do
        read -r -p "Enter target device (for example /dev/sdb): " device
        [[ "$device" =~ ^/dev/(sd[a-z]|mmcblk[0-9]+|nvme[0-9]+n[0-9]+)$ ]] || {
            log_warn "Invalid device path"
            continue
        }
        [[ -b "$device" ]] || {
            log_warn "Block device not found: $device"
            continue
        }

        log_warn "Selected device: $device"
        lsblk -o NAME,SIZE,TYPE,TRAN,RM,MODEL,MOUNTPOINT "$device"
        read -r -p "Type YES to erase this device: " confirm
        [[ "$confirm" == "YES" ]] || continue

        SELECTED_DEVICE="$device"
        return
    done
}

unmount_device() {
    log_info "Unmounting mounted partitions on $SELECTED_DEVICE"
    mapfile -t MOUNTS < <(lsblk -nr -o MOUNTPOINT "${SELECTED_DEVICE}"* 2>/dev/null | awk 'NF')
    local mountpoint
    for mountpoint in "${MOUNTS[@]:-}"; do
        $ESUDO umount "$mountpoint" 2>/dev/null || true
    done
}

flash_image() {
    log_info "Flashing $SELECTED_IMAGE to $SELECTED_DEVICE"
    if [[ "$SELECTED_IMAGE" == *.gz ]]; then
        gzip -dc "$SELECTED_IMAGE" | $ESUDO dd of="$SELECTED_DEVICE" bs=4M status=progress conv=fsync,notrunc
    else
        $ESUDO dd if="$SELECTED_IMAGE" of="$SELECTED_DEVICE" bs=4M status=progress conv=fsync,notrunc
    fi
    sync
    log_success "Image write complete"
}

repair_gpt() {
    log_info "Repairing GPT backup header on $SELECTED_DEVICE"

    if command -v sgdisk >/dev/null 2>&1; then
        $ESUDO sgdisk -e "$SELECTED_DEVICE"
    elif command -v gdisk >/dev/null 2>&1; then
        printf 'x\ne\nw\ny\n' | $ESUDO gdisk "$SELECTED_DEVICE" >/dev/null
    else
        log_warn "Neither sgdisk nor gdisk is installed. GPT repair skipped."
        return 0
    fi

    sync
    if command -v partprobe >/dev/null 2>&1; then
        $ESUDO partprobe "$SELECTED_DEVICE" || true
    fi
    log_success "GPT repair complete"
}

verify_prompt() {
    read -r -p "Show resulting partition table? (y/N): " reply
    if [[ "$reply" =~ ^[Yy]$ ]]; then
        $ESUDO fdisk -l "$SELECTED_DEVICE" || true
    fi
}

main() {
    show_images
    echo
    select_image
    echo
    show_devices
    echo
    select_device
    echo
    unmount_device
    flash_image
    repair_gpt
    verify_prompt
    log_success "Done. Safely eject $SELECTED_DEVICE when ready."
}

main "$@"
