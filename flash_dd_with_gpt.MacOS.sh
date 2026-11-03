#!/bin/zsh
# =============================================================================
# ghOSt macOS Flash Script
# Writes a ghOSt .img / .img.xz / .img.gz to removable media.
# The shipped image is MBR (no GPT), so GPT recovery only runs when the media
# actually has a GPT header; .xz is decompressed on the fly (brew install xz).
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
    IMAGES=(*.img(.N) *.img.xz(.N) *.img.gz(.N))
    (( ${#IMAGES[@]} > 0 )) || log_error "No .img, .img.xz or .img.gz files found in $(pwd)"

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
    # zsh treats a quoted =~ pattern literally, so this must stay unquoted.
    [[ "$choice" =~ ^[0-9]+$ ]] || log_error "Invalid selection"
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
        [[ "$diskname" =~ ^disk[0-9]+$ ]] || {
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

    case "$SELECTED_IMAGE" in
        *.xz)
            command -v xz >/dev/null 2>&1 || \
                log_error "xz not found — install it with: brew install xz"
            xz -dc "$SELECTED_IMAGE" | $ESUDO dd of="$RDISK" bs=4m conv=sync
            ;;
        *.gz)
            gzip -dc "$SELECTED_IMAGE" | $ESUDO dd of="$RDISK" bs=4m conv=sync
            ;;
        *)
            $ESUDO dd if="$SELECTED_IMAGE" of="$RDISK" bs=4m conv=sync
            ;;
    esac
    sync
    log_success "Image write complete"
}

has_gpt() {
    [[ "$(LC_ALL=C dd if="$DISK" bs=512 skip=1 count=1 2>/dev/null | head -c 8)" == "EFI PART" ]]
}

repair_gpt() {
    if ! has_gpt; then
        log_info "Image uses MBR partitions — no GPT table to recover"
        return 0
    fi
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
