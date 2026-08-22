#!/bin/zsh
# =============================================================================
# ghOSt macOS Flash Script
# Writes a ghOSt .img or .img.gz file to removable media and repairs GPT.
# Use this instead of plain dd on macOS so the written card gets a recovered
# backup GPT table after flashing.
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
DISK=""
RDISK=""

show_images() {
    IMAGES=(*.img(.N) *.img.gz(.N))
    (( ${#IMAGES[@]} > 0 )) || log_error "No .img or .img.gz files found in $(pwd)"

    log_info "Available images:"
    local idx=1
    local img
    for img in "${IMAGES[@]}"; do
        echo "  ${idx}. ${img} ($(du -h "$img" | awk '{print $1}'))"
        (( idx++ ))
    done
}

select_image() {
    if (( ${#IMAGES[@]} == 1 )); then
        SELECTED_IMAGE="${IMAGES[1]}"
        log_info "Auto-selected: $SELECTED_IMAGE"
        return
    fi

    local choice
    read "choice?Select image number (1-${#IMAGES[@]}): "
    [[ "$choice" =~ '^[0-9]+$' ]] || log_error "Invalid selection"
    (( choice >= 1 && choice <= ${#IMAGES[@]} )) || log_error "Selection out of range"
    SELECTED_IMAGE="${IMAGES[$choice]}"
}

show_devices() {
    log_info "Available disks:"
    diskutil list
    echo
    log_warn "Only select the removable target disk, never the internal system disk."
}

select_device() {
    local diskname
    while true; do
        read "diskname?Enter target disk (for example disk2): "
        [[ "$diskname" =~ '^disk[0-9]+$' ]] || {
            log_warn "Invalid disk name"
            continue
        }

        DISK="/dev/${diskname}"
        RDISK="/dev/r${diskname}"

        diskutil info "$DISK" >/dev/null 2>&1 || {
            log_warn "Disk not found: $DISK"
            continue
        }

        [[ "$DISK" != "/dev/disk0" ]] || log_error "disk0 is the system disk. Aborting."

        diskutil info "$DISK" | egrep "Device / Media Name|Disk Size|Protocol|Removable Media"
        read "confirm?Type YES to erase ${DISK}: "
        [[ "$confirm" == "YES" ]] || continue
        return
    done
}

unmount_disk() {
    log_info "Unmounting ${DISK}"
    $ESUDO diskutil unmountDisk "$DISK"
}

flash_image() {
    log_info "Writing ${SELECTED_IMAGE} to ${RDISK}"
    log_info "macOS dd does not always show progress; press Ctrl+T for a status update if needed."

    if [[ "$SELECTED_IMAGE" == *.gz ]]; then
        gzip -dc "$SELECTED_IMAGE" | $ESUDO dd of="$RDISK" bs=4m conv=sync
    else
        $ESUDO dd if="$SELECTED_IMAGE" of="$RDISK" bs=4m conv=sync
    fi
    sync
    log_success "Image write complete"
}

repair_gpt() {
    log_info "Recovering GPT backup table on ${DISK}"
    $ESUDO gpt recover "$DISK"
    sync
    log_success "GPT recovery complete"
}

finish() {
    diskutil list "$DISK" || true
    log_success "Done. Eject ${DISK} when ready."
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
    unmount_disk
    flash_image
    repair_gpt
    finish
}

main "$@"
