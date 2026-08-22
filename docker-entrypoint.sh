#!/usr/bin/env bash
# =============================================================================
# ghOSt Docker Entrypoint
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${GREEN}[ghOSt]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${CYAN}${BOLD}━━━ $* ━━━${NC}\n"; }

print_banner() {
    echo -e "${CYAN}"
    cat << 'EOF'
  ██████╗ ██╗  ██╗ ██████╗ ███████╗████████╗
 ██╔════╝ ██║  ██║██╔═══██╗██╔════╝╚══██╔══╝
 ██║  ███╗███████║██║   ██║███████╗   ██║
 ██║   ██║██╔══██║██║   ██║╚════██║   ██║
 ╚██████╔╝██║  ██║╚██████╔╝███████║   ██║
  ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝   ╚═╝
  Handheld Security and Signal Terminal
  Docker Build Environment
EOF
    echo -e "${NC}"
}

check_privileged() {
    # Loop device access requires --privileged
    if ! losetup -f &>/dev/null; then
        error "Container needs --privileged flag for loop device access.
        
  Run with:
    docker run --privileged -v \"\$(pwd)/output:/opt/ghost-build/output\" ghost-rg35xxh-builder:latest

  Or use docker compose:
    docker compose up --build"
    fi
}

check_disk_space() {
    local free_gb
    free_gb=$(df -BG /opt/ghost-build | awk 'NR==2 {print $4}' | tr -d 'G')
    if [[ "$free_gb" -lt 50 ]]; then
        warn "Low disk space: ${free_gb}GB free. Need ~60GB for full build."
        warn "Increase Docker disk image size in Docker Desktop settings."
        if [[ "${GHOST_ALLOW_LOW_DISK:-false}" =~ ^([Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|1)$ ]]; then
            warn "Continuing anyway because GHOST_ALLOW_LOW_DISK is enabled."
        else
            error "Refusing to continue with low disk space. Set GHOST_ALLOW_LOW_DISK=true to override."
        fi
    else
        log "Disk space OK: ${free_gb}GB available"
    fi
}

mode_build() {
    print_banner
    check_privileged
    check_disk_space

    section "Starting ghOSt Build"
    log "Output will appear in ./output/ on your host machine"
    log "This will take 4-6 hours. You can leave it running."
    echo ""

    cd /ghost
    bash build.sh

    # Copy output to volume mount
    if ls /opt/ghost-build/output/*.img.gz &>/dev/null; then
        section "Build Complete"
        log "Image ready:"
        ls -lh /opt/ghost-build/output/*.img.gz
        echo ""
        log "Flash with Balena Etcher (Windows/Mac/Linux)"
        log "Or on Linux/Mac terminal:"
        log "  gunzip -c output/ghOSt-*.img.gz | dd of=/dev/sdX bs=4M status=progress"
    else
        error "Build completed but no .img.gz found in output directory"
    fi
}

mode_shell() {
    print_banner
    check_privileged
    section "Interactive Shell Mode"
    log "You are now inside the ghOSt build environment."
    log "Run './build.sh' to start a full build, or run individual scripts."
    echo ""
    exec /bin/bash
}

mode_check() {
    print_banner
    section "Environment Check"

    log "Checking build tools..."
    local ok=true
    for tool in aarch64-linux-gnu-gcc debootstrap qemu-aarch64-static \
                parted kpartx losetup mkfs.ext4 mkfs.vfat git wget curl; do
        if command -v "$tool" &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} $tool"
        else
            echo -e "  ${RED}✗${NC} $tool MISSING"
            ok=false
        fi
    done

    log "Checking binfmt for ARM64..."
    if [[ -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
        echo -e "  ${GREEN}✓${NC} ARM64 binfmt registered"
    else
        echo -e "  ${YELLOW}⚠${NC} ARM64 binfmt not registered (will register at build time)"
    fi

    log "Checking privileged mode (loop devices)..."
    if losetup -f &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} Loop devices accessible (--privileged OK)"
    else
        echo -e "  ${RED}✗${NC} Loop devices NOT accessible — need --privileged flag"
        ok=false
    fi

    log "Checking disk space..."
    df -h /opt/ghost-build
    echo ""

    if $ok; then
        log "${GREEN}All checks passed — ready to build${NC}"
    else
        warn "Some checks failed. Fix issues before running build."
    fi
}

mode_kernel_only() {
    print_banner
    check_privileged
    section "Kernel-Only Build"
    cd /ghost
    source config.sh
    bash kernel/build-kernel.sh
}

# =============================================================================
# DISPATCH
# =============================================================================
case "${1:-build}" in
    build)        mode_build ;;
    shell|bash)   mode_shell ;;
    check)        mode_check ;;
    kernel)       mode_kernel_only ;;
    *)
        echo "Usage: docker run [options] ghost-rg35xxh-builder:latest [command]"
        echo ""
        echo "Commands:"
        echo "  build   Full build (default) — outputs .img.gz to ./output/"
        echo "  shell   Interactive shell inside build environment"
        echo "  check   Verify build environment is ready"
        echo "  kernel  Build kernel only (for testing)"
        echo ""
        echo "Options required:"
        echo "  --privileged                   Required for loop device access"
        echo "  -v \"\$(pwd)/output:/opt/ghost-build/output\"  Output directory"
        exit 1
        ;;
esac
