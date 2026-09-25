#!/usr/bin/env bash
# =============================================================================
# ghOSt Build Configuration
# Edit this file to customize your build
# =============================================================================

# -----------------------------------------------------------------------------
# VERSION & TARGET
# -----------------------------------------------------------------------------
GHOST_VERSION="1.0.0"
GHOST_BRANCH="RG35XXH"
GHOST_FULL_NAME="ghOSt-RG35XXH"
DEVICE_TARGET="rg35xxh"               # rg35xxh | rg40xxh | rg35xx-2024

# -----------------------------------------------------------------------------
# BUILD DIRECTORIES
# Use local paths to avoid requiring root/sudo
# -----------------------------------------------------------------------------
BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build"
ROOTFS_DIR="$BUILD_DIR/rootfs"
KERNEL_BUILD_DIR="$BUILD_DIR/kernel"
UBOOT_BUILD_DIR="$BUILD_DIR/uboot"
OUTPUT_DIR="$BUILD_DIR/output"

# -----------------------------------------------------------------------------
# IMAGE PARTITION SIZES (MB)
# -----------------------------------------------------------------------------
BOOT_SIZE_MB=64
ROOT_SIZE_MB="${ROOT_SIZE_MB:-16384}"   # 16GB base image, expands on first boot
SWAP_SIZE_MB="${SWAP_SIZE_MB:-4096}"    # 4GB swap at end of card

# -----------------------------------------------------------------------------
# BUILD OPTIONS
# Toggle features to adjust image size / build time
# -----------------------------------------------------------------------------

# Kali tools profile: "default" (~5GB) | "large" (~9GB)
KALI_SIZE="${KALI_SIZE:-default}"

# Games profile: "lean" | "full"
GAMES_PROFILE="${GAMES_PROFILE:-lean}"

# Include AI voice/text stack (whisper.cpp + piper)
INCLUDE_AI="${INCLUDE_AI:-true}"

# Include FEX x86 emulation layer
INCLUDE_FEX="${INCLUDE_FEX:-false}"

# Include Wine + Windows tools (requires FEX or box64)
INCLUDE_WINE="${INCLUDE_WINE:-false}"

# Include PortMaster gaming
INCLUDE_PORTMASTER="${INCLUDE_PORTMASTER:-false}"

# Include DOSBox-X + themed DOS content
INCLUDE_DOSBOX="${INCLUDE_DOSBOX:-false}"

# Include wordlists (rockyou + seclists subset ~1GB)
INCLUDE_WORDLISTS="${INCLUDE_WORDLISTS:-true}"

# Include offline CyberChef server
INCLUDE_CYBERCHEF="${INCLUDE_CYBERCHEF:-true}"

# Stealth mode (mGBA + stealthd)
INCLUDE_STEALTH="${INCLUDE_STEALTH:-true}"

# Compress final image with gzip
COMPRESS_IMAGE="${COMPRESS_IMAGE:-true}"

# -----------------------------------------------------------------------------
# BOOT FLOW (boot fix ported from rg35xxh-cyberdeck)
# "rocknix" (default, boots): ROCKNIX mainline kernel 7.x + U-Boot SPL @8KB +
#   MBR + FAT /boot (Image+DTB+boot.scr) + ext4 rootfs + DTB regulator fix.
# "legacy" (does not boot reliably): KNULLI 4.9 vendor chain + GPT layout.
#   Kept only for comparison / hardware bring-up experiments.
# -----------------------------------------------------------------------------
BOOT_FLOW="${BOOT_FLOW:-rocknix}"

# Desktop UI: "xfce" (default, boots + usable) | "cage" (minimal launcher-only)
# XFCE = LightDM autologin + joy2mouse + battery widget + audio + brightness.
# Cage fallback still available via ghost-gui.service when UI_MODE=cage.
UI_MODE="${UI_MODE:-xfce}"
INCLUDE_XFCE="${INCLUDE_XFCE:-true}"

# Final image size for rocknix flow (GB). Rootfs expands to fill SD on 1st boot.
IMAGE_SIZE_GB="${IMAGE_SIZE_GB:-12}"

# -----------------------------------------------------------------------------
# H700 BOOT CHAIN SOURCE
# Legacy KNULLI path (BOOT_FLOW=legacy only). Rocknix path uses VERSIONS pins.
# -----------------------------------------------------------------------------
KNULLI_DIST_REPO="https://github.com/knulli-cfw/distribution"
KNULLI_DIST_BRANCH="knulli-main"
KNULLI_H700_BOARD_PATH="board/batocera/allwinner/h700/rg35xx-h"
KNULLI_H700_COMMON_PATH="board/batocera/allwinner/h700"

# Reference kernel version from the staged KNULLI runtime (legacy only).
KERNEL_VERSION="4.9.170"

# Cross compiler
CROSS_COMPILE="aarch64-linux-gnu-"
ARCH="arm64"

# -----------------------------------------------------------------------------
# DEBIAN BOOTSTRAP
# Trixie default: Bookworm gcc-12 cannot build out-of-tree modules with flags
# emitted by the ROCKNIX gcc-15 toolchain. Override to bookworm only for
# BOOT_FLOW=legacy experiments.
# -----------------------------------------------------------------------------
DEBIAN_MIRROR="http://deb.debian.org/debian"
DEBIAN_RELEASE="${DEBIAN_RELEASE:-trixie}"
DEBIAN_ARCH="arm64"

# DTB for retail RG35XXH (NOT rev6-panel which shows 1 white line on retail).
DTB_NAME="${DTB_NAME:-sun50i-h700-anbernic-rg35xx-h.dtb}"

# -----------------------------------------------------------------------------
# KALI REPOSITORY
# -----------------------------------------------------------------------------
KALI_MIRROR="http://http.kali.org/kali"
KALI_RELEASE="kali-rolling"

# -----------------------------------------------------------------------------
# DEFAULT USER
# -----------------------------------------------------------------------------
GHOST_USER="ghost"
GHOST_USER_ID=1000
GHOST_HOSTNAME="ubuntu-desktop"       # Boring hostname for stealth
GHOST_TIMEZONE="UTC"                  # Change to your timezone
GHOST_LOCALE="en_US.UTF-8"

# -----------------------------------------------------------------------------
# AI CONFIGURATION
# (API keys set during firstboot, not hardcoded here)
# -----------------------------------------------------------------------------
WHISPER_MODEL="tiny.en"               # tiny.en | base.en | small.en
PIPER_VOICE="en_US-lessac-medium"     # TTS voice model

# -----------------------------------------------------------------------------
# HOST SYSTEM REQUIREMENTS
# -----------------------------------------------------------------------------
MIN_DISK_GB=60
MIN_RAM_GB=4

# -----------------------------------------------------------------------------
# SDR++ BROWN SOURCE
# -----------------------------------------------------------------------------
SDRPP_BROWN_REPO="https://github.com/cropinghigh/SDRPlusPlus"
SDRPP_BROWN_BRANCH="master"

# -----------------------------------------------------------------------------
# FEX SOURCE
# -----------------------------------------------------------------------------
FEX_REPO="https://github.com/FEX-Emu/FEX"
FEX_BRANCH="main"
FEX_ROOTFS_URL="https://rootfs.fex-emu.com/file/fex-rootfs/ubuntu_24_04.tar.zst"

# -----------------------------------------------------------------------------
# BOX64 SOURCE
# -----------------------------------------------------------------------------
BOX64_REPO="https://github.com/ptitSeb/box64"
BOX64_BRANCH="main"

# -----------------------------------------------------------------------------
# INTERCEPT SOURCE
# -----------------------------------------------------------------------------
INTERCEPT_REPO="https://github.com/smittix/intercept"
INTERCEPT_BRANCH="main"
INTERCEPT_PORT=5050

# -----------------------------------------------------------------------------
# KISMET SOURCE
# -----------------------------------------------------------------------------
KISMET_REPO="https://github.com/kismetwireless/kismet"
KISMET_TAG="kismet-2025-09-R1"

# -----------------------------------------------------------------------------
# CYBERCHEF SOURCE
# -----------------------------------------------------------------------------
CYBERCHEF_REPO="https://github.com/gchq/CyberChef"
CYBERCHEF_PORT=8000

# -----------------------------------------------------------------------------
# PORTMASTER SOURCE
# -----------------------------------------------------------------------------
PORTMASTER_REPO="https://github.com/PortsMaster/PortMaster-New"

# -----------------------------------------------------------------------------
# STEALTH MODE CONFIG
# -----------------------------------------------------------------------------
STEALTH_TRIGGER="select+start+l2"     # Button combo to enter stealth
STEALTH_HOLD_SECS=3                   # How long to hold combo
STEALTH_ROM_DIR="/home/$GHOST_USER/.stealth/roms"
STEALTH_PROCESS_NAME="kworker/0:1"   # What mGBA appears as in ps

# -----------------------------------------------------------------------------
# BATTERY MANAGEMENT
# -----------------------------------------------------------------------------
BATTERY_CHARGE_LIMIT=80              # Max charge % (longevity)
CPU_GOVERNOR_DEFAULT="schedutil"
CPU_GOVERNOR_GAMING="performance"
CPU_GOVERNOR_IDLE="powersave"
