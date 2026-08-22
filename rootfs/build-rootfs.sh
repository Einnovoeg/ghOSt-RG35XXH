#!/usr/bin/env bash
# =============================================================================
# ghOSt Rootfs Builder
# Debootstrap Debian Bookworm ARM64 + all packages
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/../config.sh"

log()     { echo -e "\033[0;32m[ROOTFS]\033[0m $*"; }
warn()    { echo -e "\033[1;33m[WARN]\033[0m   $*"; }
section() { echo -e "\n\033[0;36m--- $* ---\033[0m\n"; }

CHROOT="chroot $ROOTFS_DIR"

apt_install() {
    local pkg
    local success_count=0

    if [[ $# -eq 0 ]]; then
        return 0
    fi

    if $CHROOT apt-get -y --no-install-recommends install "$@"; then
        return 0
    fi

    warn "Batch install failed, retrying per-package: $*"
    for pkg in "$@"; do
        if $CHROOT apt-get -y --no-install-recommends install "$pkg"; then
            success_count=$((success_count + 1))
        else
            warn "Package unavailable or failed to install: $pkg"
        fi
    done

    if (( success_count == 0 )); then
        return 1
    fi

    return 0
}

APT="apt_install"
CHROOT_MOUNTS=()

mkdir_rootfs_parent() {
    mkdir -p "$(dirname "$1")"
}

ensure_arm64_loader_link() {
    local loader_link="$ROOTFS_DIR/lib/ld-linux-aarch64.so.1"
    local loader_target="../usr/lib/ld-linux-aarch64.so.1"
    local multiarch_link="$ROOTFS_DIR/lib/aarch64-linux-gnu"
    local multiarch_target="../usr/lib/aarch64-linux-gnu"
    local current_target=""

    # qemu-user expects the canonical ARM64 loader path to exist inside the
    # rootfs. Some cached rootfs states only retain the usr/lib location.
    [[ -e "$ROOTFS_DIR/usr/lib/ld-linux-aarch64.so.1" ]] || return 0

    mkdir -p "$ROOTFS_DIR/lib"

    if [[ -L "$loader_link" ]]; then
        current_target=$(readlink "$loader_link" || true)
        if [[ "$current_target" != "$loader_target" ]] && \
           [[ "$current_target" != "/usr/lib/ld-linux-aarch64.so.1" ]]; then
            rm -f "$loader_link"
        fi
    fi

    if [[ ! -e "$loader_link" ]]; then
        ln -s "$loader_target" "$loader_link"
    fi

    # PAM and other runtime loaders still resolve modules through /lib on the
    # target system. Keep the multiarch libdir reachable from the canonical
    # location even when the debootstrap cache lost the usrmerge symlink.
    if [[ -L "$multiarch_link" ]]; then
        current_target=$(readlink "$multiarch_link" || true)
        if [[ "$current_target" != "$multiarch_target" ]] && \
           [[ "$current_target" != "/usr/lib/aarch64-linux-gnu" ]]; then
            rm -f "$multiarch_link"
        fi
    elif [[ -d "$multiarch_link" ]] && [[ ! -e "$multiarch_link/ld-linux-aarch64.so.1" ]]; then
        rm -rf "$multiarch_link"
    fi

    if [[ ! -e "$multiarch_link" ]] && [[ -d "$ROOTFS_DIR/usr/lib/aarch64-linux-gnu" ]]; then
        ln -s "$multiarch_target" "$multiarch_link"
    fi
}

mount_chroot_fs() {
    mkdir -p \
        "$ROOTFS_DIR/dev" \
        "$ROOTFS_DIR/dev/pts" \
        "$ROOTFS_DIR/proc" \
        "$ROOTFS_DIR/sys" \
        "$ROOTFS_DIR/run"

    if ! mountpoint -q "$ROOTFS_DIR/dev"; then
        mount --bind /dev "$ROOTFS_DIR/dev"
        CHROOT_MOUNTS+=("$ROOTFS_DIR/dev")
    fi

    if ! mountpoint -q "$ROOTFS_DIR/dev/pts"; then
        mount --bind /dev/pts "$ROOTFS_DIR/dev/pts"
        CHROOT_MOUNTS+=("$ROOTFS_DIR/dev/pts")
    fi

    if ! mountpoint -q "$ROOTFS_DIR/proc"; then
        mount --bind /proc "$ROOTFS_DIR/proc"
        CHROOT_MOUNTS+=("$ROOTFS_DIR/proc")
    fi

    if ! mountpoint -q "$ROOTFS_DIR/sys"; then
        mount --bind /sys "$ROOTFS_DIR/sys"
        CHROOT_MOUNTS+=("$ROOTFS_DIR/sys")
    fi

    if ! mountpoint -q "$ROOTFS_DIR/run"; then
        mount --bind /run "$ROOTFS_DIR/run"
        CHROOT_MOUNTS+=("$ROOTFS_DIR/run")
    fi
}

cleanup_chroot_fs() {
    local mountpoint_path
    local i
    for (( i=${#CHROOT_MOUNTS[@]}-1; i>=0; i-- )); do
        mountpoint_path="${CHROOT_MOUNTS[$i]}"
        umount "$mountpoint_path" 2>/dev/null || umount -lf "$mountpoint_path" 2>/dev/null || true
    done
}

trap cleanup_chroot_fs EXIT

enable_rootfs_service() {
    local unit="$1"
    local src=""
    local candidate

    for candidate in \
        "$ROOTFS_DIR/etc/systemd/system/$unit" \
        "$ROOTFS_DIR/lib/systemd/system/$unit" \
        "$ROOTFS_DIR/usr/lib/systemd/system/$unit"; do
        if [[ -e "$candidate" ]]; then
            src="${candidate#$ROOTFS_DIR}"
            break
        fi
    done

    if [[ -z "$src" ]]; then
        warn "Service unit $unit not found in rootfs, skipping enable"
        return 0
    fi

    mkdir -p "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants"
    ln -sf "$src" "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/$unit"
}

clone_repo_clean() {
    local repo_url="$1"
    local dest_path="$2"
    local branch="${3:-}"
    local git_clone_cmd=""

    if [[ -n "$branch" ]]; then
        git_clone_cmd="clone --depth=1 --single-branch -b '$branch' '$repo_url' '$dest_path'"
    else
        git_clone_cmd="clone --depth=1 --single-branch '$repo_url' '$dest_path'"
    fi

    $CHROOT bash -c "rm -rf '$dest_path' && \
        GIT_TERMINAL_PROMPT=0 timeout 300 \
        git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 \
        -c advice.detachedHead=false \
        $git_clone_cmd"
}

repair_rootfs_identities() {
    local override_file="$ROOTFS_DIR/var/lib/dpkg/statoverride"
    local override_user=""
    local override_group=""
    local override_mode=""
    local override_path=""
    local remove_override=0

    # Never copy the container account database into the target rootfs. That
    # clobbers Debian-created users/groups like messagebus and breaks dpkg.
    cp -f /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf" 2>/dev/null || true
    cp -f /etc/hosts "$ROOTFS_DIR/etc/hosts" 2>/dev/null || true
    cp /usr/bin/qemu-aarch64-static "$ROOTFS_DIR/usr/bin/" 2>/dev/null || true
    ensure_arm64_loader_link

    # Restore Debian's packaged passwd/group entries, then recreate any
    # package-managed service users from sysusers.d (for example messagebus).
    $CHROOT /usr/sbin/update-passwd || true
    systemd-sysusers --root="$ROOTFS_DIR" || true

    # Some packages install service users via sysusers.d but the cached rootfs
    # may still miss them after an interrupted build resume. Seed the critical
    # service accounts explicitly when they are absent.
    $CHROOT bash -c "if ! getent group crontab >/dev/null 2>&1; then \
        addgroup --system crontab >/dev/null 2>&1 || true; \
    fi; \
    if ! grep -q '^messagebus:' /etc/passwd 2>/dev/null; then \
        adduser --system --group --disabled-login --no-create-home \
            --home /nonexistent --shell /usr/sbin/nologin \
            messagebus >/dev/null 2>&1 || true; \
    fi; \
    if ! grep -q '^polkitd:' /etc/passwd 2>/dev/null; then \
        adduser --system --group --disabled-login --no-create-home \
            --home /nonexistent --shell /usr/sbin/nologin \
            polkitd >/dev/null 2>&1 || true; \
    fi; \
    if ! grep -q '^stunnel4:' /etc/passwd 2>/dev/null; then \
        adduser --system --group --disabled-login --no-create-home \
            --home /var/run/stunnel4 --shell /usr/sbin/nologin \
            stunnel4 >/dev/null 2>&1 || true; \
    fi"

    if [[ ! -f "$override_file" ]]; then
        return 0
    fi

    while read -r override_user override_group override_mode override_path; do
        remove_override=0

        [[ -z "$override_path" ]] && continue

        if [[ "$override_user" != "-" ]] && ! $CHROOT getent passwd "$override_user" >/dev/null 2>&1; then
            remove_override=1
        fi

        if [[ "$override_group" != "-" ]] && ! $CHROOT getent group "$override_group" >/dev/null 2>&1; then
            remove_override=1
        fi

        if (( remove_override )); then
            warn "Removing stale statoverride for $override_path ($override_user:$override_group)"
            $CHROOT dpkg-statoverride --remove "$override_path" 2>/dev/null || true
        fi
    done < "$override_file"
}

ensure_runit_helper_shim() {
    local helper_path="$ROOTFS_DIR/lib/runit-helper/runit-helper"

    if [[ -x "$helper_path" ]]; then
        return 0
    fi

    # Some cached resumes leave packages marked installed while the dh_runit
    # helper path is missing from the filesystem. During an offline chroot build
    # we do not want maintainer scripts trying to start services anyway, so a
    # no-op helper is sufficient to let dpkg and apt recover cleanly.
    mkdir -p "$ROOTFS_DIR/lib/runit-helper"
    cat > "$helper_path" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$helper_path"
}

purge_cached_kernel_packages() {
    local removable_pkgs=()

    # This image ships its own staged H700 boot chain and module tree. If a
    # resumed cached rootfs accidentally picks up distro kernel packages, purge
    # them before dpkg recovery so later apt operations do not keep re-triggering
    # foreign initramfs and DKMS hooks.
    mapfile -t removable_pkgs < <(
        awk '
            /^Package: / { pkg=$2 }
            /^Status: / {
                if ($0 ~ /^(Status: )(install|hold) (ok|reinstreq|half-configured|half-installed|unpacked|triggers-awaited|triggers-pending)/ &&
                    pkg ~ /^(linux-image-|linux-headers-|wireguard$|initramfs-tools$|initramfs-tools-core$|klibc-utils$|libklibc$|busybox$)/) {
                    print pkg
                }
            }
        ' "$ROOTFS_DIR/var/lib/dpkg/status" 2>/dev/null | sort -u
    )

    if [[ "${#removable_pkgs[@]}" -eq 0 ]]; then
        return 0
    fi

    log "Purging cached distro kernel packages that conflict with the staged H700 kernel..."
    $CHROOT bash -c "dpkg --remove --force-remove-reinstreq ${removable_pkgs[*]} >/dev/null 2>&1 || true"
    $CHROOT bash -c "apt-get purge -y ${removable_pkgs[*]} >/dev/null 2>&1 || true"
    $CHROOT bash -c "apt-get autoremove -y >/dev/null 2>&1 || true"
}

install_archive_binary() {
    local url="$1"
    local archive_name="$2"
    local search_name="$3"
    local install_name="${4:-$3}"

    $CHROOT bash -c "set -e; \
        tmpdir=\$(mktemp -d); \
        trap 'rm -rf \"\$tmpdir\"' EXIT; \
        mkdir -p \"\$tmpdir/extract\"; \
        wget -qO \"\$tmpdir/$archive_name\" '$url'; \
        case '$archive_name' in \
            *.zip) unzip -q \"\$tmpdir/$archive_name\" -d \"\$tmpdir/extract\" ;; \
            *.tar.gz) tar -xzf \"\$tmpdir/$archive_name\" -C \"\$tmpdir/extract\" ;; \
            *.tar.bz2) tar -xjf \"\$tmpdir/$archive_name\" -C \"\$tmpdir/extract\" ;; \
            *.7z) 7z x -y \"\$tmpdir/$archive_name\" -o\"\$tmpdir/extract\" >/dev/null ;; \
            *) echo 'Unsupported archive format: $archive_name' >&2; exit 1 ;; \
        esac; \
        binary_path=\$(find \"\$tmpdir/extract\" -type f -name '$search_name' -print -quit); \
        if [[ -z \"\$binary_path\" ]]; then \
            echo 'Binary $search_name not found in $archive_name' >&2; \
            exit 1; \
        fi; \
        install -m 0755 \"\$binary_path\" /usr/local/bin/'$install_name'"
}

install_downloaded_file() {
    local url="$1"
    local dest_path="$2"
    local mode="${3:-0644}"

    $CHROOT bash -c "set -e; \
        tmpfile=\$(mktemp); \
        trap 'rm -f \"\$tmpfile\"' EXIT; \
        wget -qO \"\$tmpfile\" '$url'; \
        mkdir -p '$(dirname "$dest_path")'; \
        install -m '$mode' \"\$tmpfile\" '$dest_path'"
}

install_downloaded_deb() {
    local url="$1"
    local package_name="${2:-package.deb}"

    $CHROOT bash -c "set -e; \
        tmpfile=\$(mktemp --suffix=.deb); \
        trap 'rm -f \"\$tmpfile\"' EXIT; \
        wget -qO \"\$tmpfile\" '$url'; \
        apt-get -y install \"\$tmpfile\""
}

github_latest_asset_url() {
    local repo="$1"
    local pattern="$2"

    python3 - "$repo" "$pattern" <<'PY'
import json
import re
import sys
import time
import urllib.error
import urllib.request
import urllib.parse

repo, pattern = sys.argv[1], sys.argv[2]
# Most call sites pass shell-friendly regex fragments like `\\.zip`. When those
# arrive via argv they are double-escaped for Python's regex engine, which makes
# the matcher look for a literal backslash in the filename. Normalize them once
# here so every release lookup uses the intended pattern.
pattern = pattern.replace("\\\\", "\\")
matcher = re.compile(pattern)

def matches(name: str) -> bool:
    return bool(matcher.fullmatch(name) or matcher.search(name))

def canonical_repo_from_url(url: str, fallback: str) -> str:
    parsed = urllib.parse.urlparse(url)
    parts = [part for part in parsed.path.split("/") if part]
    if len(parts) >= 2:
        return "/".join(parts[:2])
    return fallback

def fetch_url(request: urllib.request.Request, retries: int = 4):
    last_error = None
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(request) as response:
                return response.geturl(), response.read().decode("utf-8", errors="ignore")
        except urllib.error.HTTPError as exc:
            last_error = exc
            if exc.code < 500 or attempt == retries - 1:
                raise
        except urllib.error.URLError as exc:
            last_error = exc
            if attempt == retries - 1:
                raise
        time.sleep(1 + attempt)
    raise last_error

def from_api() -> str | None:
    request = urllib.request.Request(
        f"https://api.github.com/repos/{repo}/releases/latest",
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "ghOSt-builder",
        },
    )

    with urllib.request.urlopen(request) as response:
        data = json.load(response)

    for asset in data.get("assets", []):
        name = asset.get("name", "")
        if matches(name):
            return asset["browser_download_url"]
    return None

def from_release_html() -> str | None:
    request = urllib.request.Request(
        f"https://github.com/{repo}/releases/latest",
        headers={"User-Agent": "ghOSt-builder"},
    )

    resolved_url, page = fetch_url(request)
    resolved_repo = canonical_repo_from_url(resolved_url, repo)

    expanded_assets_match = re.search(
        rf'(?P<href>/{re.escape(resolved_repo)}/releases/expanded_assets/[^"#?]+)',
        page,
    )
    pages = [page]

    if expanded_assets_match:
        expanded_request = urllib.request.Request(
            "https://github.com" + expanded_assets_match.group("href"),
            headers={"User-Agent": "ghOSt-builder"},
        )
        _, expanded_page = fetch_url(expanded_request)
        pages.insert(0, expanded_page)

    href_pattern = re.compile(
        rf'href="(?P<href>/{re.escape(resolved_repo)}/releases/download/[^"]+/(?P<name>[^"/]+))"'
    )
    for source_page in pages:
        for match in href_pattern.finditer(source_page):
            if matches(match.group("name")):
                return "https://github.com" + match.group("href")
    return None

try:
    asset_url = from_api()
except urllib.error.HTTPError as exc:
    asset_url = None
    if exc.code != 403:
        raise
except Exception:
    asset_url = None

if not asset_url:
    asset_url = from_release_html()

if not asset_url:
    sys.exit(f"No asset matching {pattern!r} found for {repo}")

print(asset_url)
PY
}

# =============================================================================
# STAGE 1: DEBOOTSTRAP
# =============================================================================
debootstrap_stage() {
    local bootstrap_marker="$ROOTFS_DIR/.ghost-debootstrap-complete"

    section "Debootstrap Stage 1 (host)"

    if [[ -f "$bootstrap_marker" ]]; then
        log "Rootfs already bootstrapped, skipping..."
        return
    fi

    if [[ ! -x "$ROOTFS_DIR/debootstrap/debootstrap" ]]; then
        if find "$ROOTFS_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
            warn "Incomplete rootfs detected without bootstrap marker, cleaning and restarting debootstrap"
            find "$ROOTFS_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
        fi

        log "Running debootstrap first stage..."
        debootstrap \
            --arch="$DEBIAN_ARCH" \
            --foreign \
            --include=ca-certificates,curl,wget,gnupg2,lsb-release \
            "$DEBIAN_RELEASE" \
            "$ROOTFS_DIR" \
            "$DEBIAN_MIRROR"
    else
        log "Existing debootstrap payload found, resuming second stage..."
    fi

    log "Copying qemu static binary..."
    cp /usr/bin/qemu-aarch64-static "$ROOTFS_DIR/usr/bin/"

    log "Copying DNS and network config..."
    cp -f /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"
    cp -f /etc/hosts "$ROOTFS_DIR/etc/hosts" 2>/dev/null || true

    section "Debootstrap Stage 2 (chroot)"
    $CHROOT /debootstrap/debootstrap --second-stage
    ensure_arm64_loader_link
    touch "$bootstrap_marker"

    log "Debootstrap complete"
}

# =============================================================================
# BUILD RECOVERY
# =============================================================================
recover_rootfs_state() {
    section "Recovering Cached Rootfs State"

    # Repeated Docker resumes can interrupt apt/dpkg in the cached rootfs.
    # Clear stale locks and repair package state before the next install stage.
    repair_rootfs_identities
    ensure_runit_helper_shim
    purge_cached_kernel_packages

    $CHROOT bash -c "rm -f \
        /var/lib/dpkg/lock \
        /var/lib/dpkg/lock-frontend \
        /var/cache/apt/archives/lock \
        /var/lib/apt/lists/lock"

    $CHROOT bash -c "dpkg --configure -a || true"
    $CHROOT bash -c "apt-get -y --fix-broken install || true"
    $CHROOT bash -c "rm -rf \
        /tmp/aptdec \
        /tmp/box64 \
        /tmp/displaylink \
        /tmp/dl-extracted \
        /tmp/fex \
        /tmp/inspectrum \
        /tmp/kalibrate-rtl \
        /tmp/kismet \
        /tmp/libfreenect \
        /tmp/libfreenect2 \
        /tmp/mgba \
        /tmp/sdrpp-brown \
        /tmp/sixad \
        /tmp/sixpair \
        /tmp/wlopm \
        /tmp/*.zip \
        /tmp/*.tar.gz \
        /tmp/*.tar.bz2 \
        /tmp/*.tar.zst 2>/dev/null || true"

    log "Cached rootfs state recovered"
}

# =============================================================================
# STAGE 2: CONFIGURE APT SOURCES
# =============================================================================
configure_apt() {
    section "Configuring APT Sources"

    # Clean up any third-party apt sources a previous failed run may have left
    # behind in the cached rootfs. The kali-anonsurf installer writes its own
    # I2P repository config, which breaks later apt updates on Bookworm.
    $CHROOT bash -c "rm -f /etc/apt/sources.list.d/*i2p*.list \
        /etc/apt/sources.list.d/*anonsurf*.list \
        /etc/apt/sources.list.d/kali.list \
        /etc/apt/preferences.d/kali \
        /etc/apt/trusted.gpg.d/*i2p* \
        /etc/apt/keyrings/*i2p*"

    # Purge any half-installed kali-anonsurf package left by a previous failed
    # run so the cached rootfs can recover without manual cleanup.
    $CHROOT bash -c "if dpkg -s kali-anonsurf >/dev/null 2>&1; then \
        dpkg --remove --force-remove-reinstreq kali-anonsurf || true; \
        apt-get -y --fix-broken install || true; \
    fi"

    # Debian sources
    cat > "$ROOTFS_DIR/etc/apt/sources.list" << EOF
deb $DEBIAN_MIRROR $DEBIAN_RELEASE main contrib non-free non-free-firmware
deb $DEBIAN_MIRROR $DEBIAN_RELEASE-updates main contrib non-free non-free-firmware
deb $DEBIAN_MIRROR $DEBIAN_RELEASE-backports main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security $DEBIAN_RELEASE-security main contrib non-free non-free-firmware
EOF

    if [[ -n "$KALI_SIZE" ]]; then
        # Kali repository
        cat > "$ROOTFS_DIR/etc/apt/sources.list.d/kali.list" << EOF
deb $KALI_MIRROR $KALI_RELEASE main contrib non-free
EOF

        # Add Kali GPG key
    $CHROOT bash -c "rm -f /etc/apt/trusted.gpg.d/kali-archive-keyring.gpg && \
        curl -fsSL https://archive.kali.org/archive-key.asc | \
        gpg --batch --yes --dearmor -o /etc/apt/trusted.gpg.d/kali-archive-keyring.gpg"

        # Pin Kali lower priority — only install explicitly requested packages
        cat > "$ROOTFS_DIR/etc/apt/preferences.d/kali" << EOF
Package: *
Pin: release a=kali-rolling
Pin-Priority: 100

Package: kali-linux-headless
Pin: release a=kali-rolling
Pin-Priority: 500
EOF
    fi

    # Update
    $CHROOT bash -c 'echo "Acquire::http::Timeout \"30\";" > /etc/apt/apt.conf.d/99timeout'
    $CHROOT bash -c 'echo "Acquire::Retries \"3\";" >> /etc/apt/apt.conf.d/99timeout'
    timeout 120 $CHROOT apt-get update -qq || {
        warn "apt-get update timed out or failed"
        $CHROOT bash -c "cat /etc/apt/sources.list"
    }
    $CHROOT apt-get -y upgrade

    log "APT configured"
}

# =============================================================================
# STAGE 3: BASE SYSTEM PACKAGES
# =============================================================================
install_base() {
    section "Installing Base System"

    $APT \
        locales tzdata keyboard-configuration console-setup \
        systemd systemd-sysv dbus udev \
        sudo passwd login \
        network-manager iproute2 iputils-ping \
        openssh-server openssh-client \
        apt-utils apt-transport-https software-properties-common \
        lsb-release ca-certificates gnupg2 \
        bash-completion man-db manpages \
        cron logrotate \
        upower acpi \
        firmware-linux \
        firmware-realtek firmware-misc-nonfree \
        zram-tools \
        lz4 zstd \
        e2fsprogs dosfstools parted \
        util-linux procps \
        libpam-systemd \
        policykit-1 \
        python3 python3-pip python3-venv \
        ruby ruby-dev \
        nodejs npm \
        golang-go \
        lua5.4 liblua5.4-dev \
        unzip p7zip-full bzip2 \
        gcc g++ make cmake ninja-build \
        git curl wget \
        libssl-dev libffi-dev \
        build-essential pkg-config

    log "Base system installed"
}

# =============================================================================
# STAGE 4: SHELL & TERMINAL EXPERIENCE
# =============================================================================
install_shell() {
    section "Installing Shell & Terminal Tools"

    $APT fish tmux micro vim

    # Install fisher (fish plugin manager) + plugins post-boot via firstboot
    # eza (modern ls)
    local eza_url=""
    eza_url=$(github_latest_asset_url "eza-community/eza" 'eza_aarch64-unknown-linux-gnu\\.tar\\.gz') && \
        install_archive_binary "$eza_url" "eza.tar.gz" "eza" || warn "eza install failed"

    # bat (syntax highlighting cat)
    $APT bat

    # delta (syntax highlighting diff)
    local delta_url=""
    delta_url=$(github_latest_asset_url "dandavison/delta" 'git-delta_.*_arm64\\.deb') && \
        install_downloaded_deb "$delta_url" "delta.deb" || \
        warn "delta install failed"

    # ripgrep
    $APT ripgrep

    # fzf
    $APT fzf

    # zoxide (smart cd)
    $APT zoxide || \
        $CHROOT bash -c "curl -sS https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash"

    # atuin (shell history)
    # The Kali package now targets a newer glibc than Bookworm ships, so skip
    # apt entirely here and install the static upstream release directly.
    local atuin_url=""
    atuin_url=$(github_latest_asset_url "atuinsh/atuin" 'atuin-aarch64-unknown-linux-musl\\.tar\\.gz') && \
    $CHROOT bash -c "set -e; \
        tmpdir=\$(mktemp -d); \
        atuin_bin=''; \
        atuin_update_bin=''; \
        trap 'rm -rf \"\$tmpdir\"' EXIT; \
        wget -qO \"\$tmpdir/atuin.tar.gz\" '$atuin_url'; \
        tar -xzf \"\$tmpdir/atuin.tar.gz\" -C \"\$tmpdir\"; \
        atuin_bin=\$(find \"\$tmpdir\" -type f -name atuin -print -quit); \
        if [[ -z \"\$atuin_bin\" ]]; then \
            echo 'atuin binary not found in release tarball' >&2; \
            exit 1; \
        fi; \
        install -m 0755 \"\$atuin_bin\" /usr/local/bin/atuin; \
        atuin_update_bin=\$(find \"\$tmpdir\" -type f -name atuin-update -print -quit || true); \
        if [[ -n \"\$atuin_update_bin\" ]]; then \
            install -m 0755 \"\$atuin_update_bin\" /usr/local/bin/atuin-update; \
        fi" || warn "atuin install failed"

    # thefuck
    $CHROOT pip3 install thefuck --break-system-packages || \
        warn "thefuck install failed"

    # carapace-bin (completions)
    local carapace_url=""
    carapace_url=$(github_latest_asset_url "carapace-sh/carapace-bin" 'carapace-bin_.*_linux_arm64\\.deb') && \
        install_downloaded_deb "$carapace_url" "carapace.deb" || \
        warn "carapace install failed"

    # hexyl (hex viewer)
    $APT hexyl

    # btop
    $APT btop

    # duf (disk usage)
    if ! $APT duf; then
        local duf_url=""
        duf_url=$(github_latest_asset_url "muesli/duf" 'duf_.*_linux_arm64\\.deb') && \
            install_downloaded_deb "$duf_url" "duf.deb" || \
            warn "duf install failed"
    fi

    # ncdu
    $APT ncdu

    # nethogs, iftop, lm-sensors
    $APT nethogs iftop lm-sensors

    # glow (markdown renderer)
    if ! $APT glow; then
        local glow_url=""
        glow_url=$(github_latest_asset_url "charmbracelet/glow" 'glow_.*_arm64\\.deb') && \
            install_downloaded_deb "$glow_url" "glow.deb" || \
            warn "glow install failed"
    fi

    log "Shell tools installed"
}

# =============================================================================
# STAGE 5: GUI LAYER
# =============================================================================
install_gui() {
    section "Installing GUI Layer (Wayland/Cage)"

    $APT \
        cage weston wayland-utils \
        libwayland-dev \
        wvkbd \
        pipewire pipewire-pulse pipewire-audio \
        wireplumber \
        bluez bluez-tools bluetooth \
        grim slurp \
        wf-recorder \
        brightnessctl \
        wayvnc \
        fonts-terminus \
        xdg-user-dirs \
        libsdl2-dev libsdl2-image-dev libsdl2-ttf-dev \
        python3-sdl2 python3-evdev \
        mangohud \
        gamescope || warn "Some GUI packages unavailable, continuing..."

    # NetSurf
    $APT netsurf-gtk || $APT netsurf || warn "NetSurf unavailable, using w3m only"

    # w3m
    $APT w3m w3m-img

    log "GUI layer installed"
}

# =============================================================================
# STAGE 6: REMOTE ACCESS
# =============================================================================
install_remote() {
    section "Installing Remote Access Tools"

    $APT \
        mosh autossh sshuttle \
        tigervnc-viewer ssvnc \
        freerdp2-x11

    # bluetuith from source if not in repos
    if ! $CHROOT bash -lc "command -v bluetuith >/dev/null 2>&1"; then
        local bluetuith_url=""
        bluetuith_url=$(github_latest_asset_url "darkhz/bluetuith" 'bluetuith_.*_Linux_arm64\\.tar\\.gz') && \
            install_archive_binary "$bluetuith_url" "bluetuith.tar.gz" "bluetuith" || true
    fi

    # stormssh (SSH bookmark manager)
    $CHROOT pip3 install stormssh --break-system-packages || true

    log "Remote access installed"
}

# =============================================================================
# STAGE 7: VPN & PRIVACY
# =============================================================================
install_vpn() {
    section "Installing VPN & Privacy Tools"

    # Install the userspace tooling only. The wireguard meta-package can pull in
    # distro kernel images from Kali to satisfy virtual wireguard-modules
    # dependencies, which conflicts with ghOSt's staged H700 kernel.
    $APT \
        wireguard-tools \
        openvpn network-manager-openvpn \
        tor torsocks proxychains4 \
        i2pd \
        dnscrypt-proxy \
        secure-delete \
        onionshare || true

    # ProtonVPN CLI
    $CHROOT pip3 install protonvpn-cli --break-system-packages || true

    # anonsurf
    # The legacy kali-anonsurf installer mutates apt sources inside the rootfs
    # and currently pulls an unsigned I2P repo, which breaks repeatable builds.
    # Keep the Tor/i2pd/proxychains toolchain and skip the installer itself.
    $CHROOT bash -c "rm -f /etc/apt/sources.list.d/*i2p*.list \
        /etc/apt/sources.list.d/*anonsurf*.list" || true

    log "VPN & privacy installed"
}

# =============================================================================
# STAGE 8: SDR & RF TOOLS
# =============================================================================
install_sdr() {
    section "Installing SDR & RF Tools"

    $APT \
        rtl-sdr \
        rtl-433 \
        dump1090-mutability \
        multimon-ng \
        direwolf \
        fldigi

    # SDR++ Brown is built in this stage, so its OpenGL/FFT/SDR development
    # headers need to exist before the source build starts. Several of these
    # were only being installed much later for unrelated features, which caused
    # the Brown build to fail immediately on Bookworm.
    $APT \
        build-essential \
        cmake \
        pkg-config \
        autoconf \
        automake \
        libtool \
        libfftw3-dev \
        libglfw3-dev \
        libglew-dev \
        libiio-dev \
        libad9361-dev \
        libvolk2-dev \
        libzstd-dev \
        librtaudio-dev \
        librtlsdr-dev \
        libsoapysdr-dev \
        libairspy-dev \
        libairspyhf-dev \
        libhackrf-dev \
        libusb-1.0-0-dev || true

    # The Kali kalibrate-rtl package currently depends on a newer libc than
    # Debian Bookworm ships. Keep the tool in the image by falling back to a
    # local source build instead of retrying the impossible package every run.
    if ! $CHROOT apt-get -y --no-install-recommends install kalibrate-rtl; then
        warn "kalibrate-rtl package is incompatible with Bookworm, building from source"
        $CHROOT bash -c "
            rm -rf /tmp/kalibrate-rtl && \
            git clone --depth=1 https://github.com/steve-m/kalibrate-rtl /tmp/kalibrate-rtl && \
            cd /tmp/kalibrate-rtl && \
            ./bootstrap && \
            ./configure && \
            make -j\$(nproc) && \
            make install && \
            rm -rf /tmp/kalibrate-rtl" || warn "kalibrate-rtl source build failed"
    fi

    # SDR++ Brown (build from source)
    log "Building SDR++ Brown..."
    local sdrpp_pluto_flag="-DOPT_BUILD_PLUTOSDR_SOURCE=OFF"
    if $CHROOT bash -lc "pkg-config --exists libad9361"; then
        sdrpp_pluto_flag="-DOPT_BUILD_PLUTOSDR_SOURCE=ON"
    else
        warn "libad9361 development files are unavailable, building SDR++ Brown without PlutoSDR support"
    fi
    $CHROOT bash -c "
        rm -rf /tmp/sdrpp-brown && \
        git clone --depth=1 -b $SDRPP_BROWN_BRANCH $SDRPP_BROWN_REPO /tmp/sdrpp-brown && \
        cd /tmp/sdrpp-brown && \
        mkdir build && cd build && \
        cmake .. -DOPT_BUILD_AUDIO_SINK=ON \
                 -DOPT_BUILD_RTL_SDR_SOURCE=ON \
                 $sdrpp_pluto_flag \
                 -DOPT_BUILD_FILE_SOURCE=ON \
                 -DOPT_BUILD_RECORDER=ON \
                 -DOPT_BUILD_FREQUENCY_MANAGER=ON \
                 -DOPT_BUILD_SCANNER=ON \
                 -DOPT_BUILD_DISCORD_PRESENCE=OFF \
                 -DCMAKE_BUILD_TYPE=Release && \
        make -j\$(nproc) && \
        make install && \
        rm -rf /tmp/sdrpp-brown" || warn "SDR++ Brown build failed, install manually"

    # inspectrum (signal analysis)
    $APT inspectrum || \
        $CHROOT bash -c "
            git clone https://github.com/miek/inspectrum /tmp/inspectrum && \
            cd /tmp/inspectrum && mkdir build && cd build && \
            cmake .. && make -j\$(nproc) && make install && \
            rm -rf /tmp/inspectrum" || true

    # INTERCEPT
    log "Installing INTERCEPT (smittix)..."
    $CHROOT bash -c "
        rm -rf /opt/ghost/intercept && \
        git clone --depth=1 $INTERCEPT_REPO /opt/ghost/intercept && \
        cd /opt/ghost/intercept && \
        pip3 install --no-cache-dir -r requirements.txt --break-system-packages" || \
        warn "INTERCEPT install failed"

    log "SDR tools installed"
}

# =============================================================================
# STAGE 9: SECURITY TOOLS (KALI + BLACKARCH)
# =============================================================================
install_security() {
    section "Installing Security Tools"

    # --- RECON ---
    log "Installing recon tools..."
    $APT \
        nmap masscan \
        recon-ng \
        dnsenum \
        fierce \
        smbmap \
        enum4linux \
        dmitry \
        wafw00f \
        whatweb \
        whois dnsutils \
        netcat-openbsd socat \
        traceroute

    # Rust-based fast tools
    local rustscan_url=""
    rustscan_url=$(github_latest_asset_url "RustScan/RustScan" 'aarch64-linux-rustscan\\.zip') && \
        install_archive_binary "$rustscan_url" "rustscan.zip" "rustscan" || \
        warn "rustscan install failed"

    # ProjectDiscovery now requires a newer Go toolchain than Bookworm ships.
    # Use upstream arm64 release archives so the build stays reproducible.
    local subfinder_url=""
    subfinder_url=$(github_latest_asset_url "projectdiscovery/subfinder" 'subfinder_.*_linux_arm64\\.zip') && \
        install_archive_binary "$subfinder_url" "subfinder.zip" "subfinder" || \
        warn "subfinder install failed"
    local dnsx_url=""
    dnsx_url=$(github_latest_asset_url "projectdiscovery/dnsx" 'dnsx_.*_linux_arm64\\.zip') && \
        install_archive_binary "$dnsx_url" "dnsx.zip" "dnsx" || \
        warn "dnsx install failed"
    local httpx_url=""
    httpx_url=$(github_latest_asset_url "projectdiscovery/httpx" 'httpx_.*_linux_arm64\\.zip') && \
        install_archive_binary "$httpx_url" "httpx.zip" "httpx" || \
        warn "httpx install failed"

    # sherlock (OSINT)
    $CHROOT pip3 install sherlock-project --break-system-packages || true

    # theHarvester
    # Upstream now requires Python 3.12+, so pin the newest Python 3.11-friendly
    # release and isolate it in a venv so it does not pollute the system stack.
    clone_repo_clean https://github.com/laramies/theHarvester /opt/ghost/theHarvester 4.8.0 && \
        $CHROOT bash -c "
            rm -rf /opt/ghost/venvs/theharvester && \
            mkdir -p /opt/ghost/venvs && \
            python3 -m venv /opt/ghost/venvs/theharvester && \
            /opt/ghost/venvs/theharvester/bin/pip install --upgrade pip setuptools wheel && \
            /opt/ghost/venvs/theharvester/bin/pip install --no-cache-dir /opt/ghost/theHarvester && \
            cat > /usr/local/bin/theHarvester << 'EOF'
#!/usr/bin/env bash
exec /opt/ghost/venvs/theharvester/bin/theHarvester \"\$@\"
EOF
            chmod +x /usr/local/bin/theHarvester" || \
        warn "theHarvester source install failed"

    # spiderfoot
    clone_repo_clean https://github.com/smicallef/spiderfoot /opt/ghost/spiderfoot && \
        $CHROOT bash -c "
            rm -rf /opt/ghost/venvs/spiderfoot && \
            mkdir -p /opt/ghost/venvs && \
            python3 -m venv /opt/ghost/venvs/spiderfoot && \
            /opt/ghost/venvs/spiderfoot/bin/pip install --upgrade pip setuptools wheel && \
            /opt/ghost/venvs/spiderfoot/bin/pip install --no-cache-dir -r /opt/ghost/spiderfoot/requirements.txt && \
            cat > /usr/local/bin/spiderfoot << 'EOF'
#!/usr/bin/env bash
cd /opt/ghost/spiderfoot
exec /opt/ghost/venvs/spiderfoot/bin/python sf.py \"\$@\"
EOF
            chmod +x /usr/local/bin/spiderfoot" || \
        warn "spiderfoot install failed"

    # SpiderFoot's constraints pull an old cryptography build. Keep that pinned
    # inside its venv and restore the global Python toolchain for INTERCEPT,
    # Paramiko, and the rest of the security stack.
    $CHROOT pip3 install --no-cache-dir "cryptography>=41,<47" --break-system-packages || true

    # --- WIRELESS ---
    log "Installing wireless tools..."
    $APT \
        aircrack-ng \
        hcxdumptool hcxtools \
        bettercap \
        wifite \
        mdk4 \
        wavemon \
        wireless-tools iw

    # Kali's current kismet package depends on newer t64/glibc packages than
    # Bookworm provides. Prefer a Debian-native install if available and fall
    # back to the official source build so the handheld keeps its core RF UI.
    if ! $CHROOT apt-get -y --no-install-recommends install -t "$DEBIAN_RELEASE" kismet; then
        warn "kismet package is not available in a Bookworm-compatible form, building from source"
        $APT \
            build-essential git pkg-config \
            zlib1g-dev \
            libwebsockets-dev \
            libnl-3-dev libnl-genl-3-dev \
            libcap-dev libpcap-dev \
            libnm-dev libdw-dev \
            libsqlite3-dev \
            libsensors-dev \
            libusb-1.0-0-dev \
            libubertooth-dev libbtbb-dev \
            libmosquitto-dev \
            librtlsdr-dev \
            libprotobuf-c-dev || true

        clone_repo_clean "$KISMET_REPO" /tmp/kismet "$KISMET_TAG" && \
            $CHROOT bash -c "
                cd /tmp/kismet && \
                ./configure --prefix=/usr --sysconfdir=/etc && \
                make -j2 && \
                make suidinstall && \
                rm -rf /tmp/kismet" || \
            warn "kismet source build failed"
    fi

    # airgeddon
    clone_repo_clean https://github.com/v1s1t0r1sh3r3/airgeddon /opt/ghost/airgeddon || true

    # wifi-honey
    clone_repo_clean https://github.com/nismara/wifi-honey /opt/ghost/wifi-honey || true

    # --- BLUETOOTH ---
    log "Installing Bluetooth tools..."
    $APT bluelog || true
    clone_repo_clean https://github.com/digitalmunition/blueranger /opt/ghost/blueranger || true
    clone_repo_clean https://github.com/zenware/bluesnarfer /opt/ghost/bluesnarfer || true

    # --- EXPLOITATION ---
    log "Installing exploitation tools..."
    $APT \
        metasploit-framework \
        exploitdb \
        sqlmap \
        hydra medusa \
        nikto \
        termshark \
        responder

    # Python-based tools
    $CHROOT pip3 install \
        impacket \
        pwntools \
        scapy \
        crackmapexec \
        evil-winrm \
        pwncat-cs \
        --break-system-packages || true

    # Go-based web tools shipped as release binaries to avoid Go toolchain drift.
    local ffuf_url=""
    ffuf_url=$(github_latest_asset_url "ffuf/ffuf" 'ffuf_.*_linux_arm64\\.tar\\.gz') && \
        install_archive_binary "$ffuf_url" "ffuf.tar.gz" "ffuf" || \
        warn "ffuf install failed"
    local gobuster_url=""
    gobuster_url=$(github_latest_asset_url "OJ/gobuster" 'gobuster_.*_Linux_arm64\\.tar\\.gz|gobuster_Linux_arm64\\.tar\\.gz') && \
        install_archive_binary "$gobuster_url" "gobuster.tar.gz" "gobuster" || \
        warn "gobuster install failed"

    # feroxbuster (Rust)
    local feroxbuster_url=""
    feroxbuster_url=$(github_latest_asset_url "epi052/feroxbuster" 'aarch64-linux-feroxbuster\\.zip') && \
        install_archive_binary "$feroxbuster_url" "feroxbuster.zip" "feroxbuster" || \
        warn "feroxbuster install failed"

    # ROPgadget
    $CHROOT pip3 install ROPgadget --break-system-packages || true

    # routersploit
    clone_repo_clean https://github.com/threat9/routersploit /opt/ghost/routersploit && \
        $CHROOT pip3 install --no-cache-dir -r /opt/ghost/routersploit/requirements.txt \
        --break-system-packages || true

    # mitmproxy
    $CHROOT pip3 install mitmproxy --break-system-packages || true

    # Network recon
    $APT \
        dnschef \
        iodine \
        ptunnel || true

    # enum4linux-ng
    clone_repo_clean https://github.com/cddmp/enum4linux-ng /opt/ghost/enum4linux-ng && \
        $CHROOT pip3 install --no-cache-dir -r /opt/ghost/enum4linux-ng/requirements.txt \
        --break-system-packages || true

    # --- FORENSICS & RE ---
    log "Installing forensics & RE tools..."
    $APT \
        binwalk foremost \
        exiftool \
        steghide \
        strace ltrace \
        gdb gdb-multiarch \
        radare2 \
        rizin \
        apktool \
        volatility3 \
        binutils \
        file

    # stegseek
    local stegseek_url=""
    stegseek_url=$(github_latest_asset_url "RickdeJager/stegseek" 'stegseek_.*\\.deb') && \
        install_downloaded_deb "$stegseek_url" "stegseek.deb" || \
        true

    # jadx (Android RE)
    local jadx_url=""
    jadx_url=$(github_latest_asset_url "skylot/jadx" 'jadx-.*\\.zip') && \
        $CHROOT bash -c "rm -rf /opt/ghost/jadx && wget -qO /tmp/jadx.zip '$jadx_url' && unzip -q /tmp/jadx.zip -d /opt/ghost/jadx && ln -sf /opt/ghost/jadx/bin/jadx /usr/local/bin/jadx" || \
        warn "jadx install failed"

    # frida
    $CHROOT pip3 install frida-tools objection --break-system-packages || true

    # pwndbg
    clone_repo_clean https://github.com/pwndbg/pwndbg /opt/ghost/pwndbg && \
        $CHROOT bash -c "cd /opt/ghost/pwndbg && ./setup.sh" || true

    # --- PASSWORD ---
    log "Installing password tools..."
    $APT \
        hashcat john \
        cewl \
        pass \
        gnupg2

    # princeprocessor, statsprocessor, rsmangler
    local prince_url=""
    prince_url=$(github_latest_asset_url "hashcat/princeprocessor" 'princeprocessor_arm64\\.7z') && \
        install_archive_binary "$prince_url" "prince.7z" "princeprocessor" || true

    # pack (password analysis)
    clone_repo_clean https://github.com/iphelix/pack /opt/ghost/pack || true

    # --- CRYPTO & ENCODING ---
    log "Installing crypto tools..."
    $APT age openssl gpg

    # firejail (sandboxing)
    $APT firejail || true

    log "Security tools installed"
}

# =============================================================================
# STAGE 10: WORDLISTS
# =============================================================================
install_wordlists() {
    if [[ "$INCLUDE_WORDLISTS" != "true" ]]; then
        warn "Wordlists disabled in config, skipping..."
        return
    fi

    section "Installing Wordlists"
    mkdir -p "$ROOTFS_DIR/opt/wordlists"

    # rockyou.txt
    log "Downloading rockyou.txt..."
    $CHROOT bash -c "
        rm -f /opt/wordlists/rockyou.txt /opt/wordlists/rockyou.txt.gz && \
        wget -qO /opt/wordlists/rockyou.txt.gz \
        https://github.com/praetorian-inc/Hob0Rules/raw/master/wordlists/rockyou.txt.gz && \
        gunzip -f /opt/wordlists/rockyou.txt.gz" || true

    # SecLists subset (Discovery + Passwords + Fuzzing only — not everything)
    log "Downloading SecLists subset..."
    $CHROOT bash -c "
        rm -rf /opt/wordlists/seclists && \
        git clone --depth=1 --filter=blob:none --sparse \
        https://github.com/danielmiessler/SecLists /opt/wordlists/seclists && \
        cd /opt/wordlists/seclists && \
        git sparse-checkout set Discovery Passwords Fuzzing" || true

    log "Wordlists installed"
}

# =============================================================================
# STAGE 11: TUI PRODUCTIVITY
# =============================================================================
install_tui() {
    section "Installing TUI Productivity Apps"

    $APT \
        calcurse \
        taskwarrior \
        ranger \
        visidata \
        irssi \
        newsboat \
        cmus \
        mpv ffmpeg \
        imagemagick \
        chafa \
        syncthing

    # aerc (modern TUI email)
    $APT aerc || warn "aerc install failed"

    # visidata (already in apt but get latest)
    $CHROOT pip3 install visidata --break-system-packages || true

    # mapscii is not packaged on Bookworm ARM64; fall back to npm when needed.
    if ! $CHROOT bash -lc "command -v mapscii >/dev/null 2>&1"; then
        $CHROOT bash -lc "npm install -g mapscii" || warn "mapscii install failed"
    fi

    # yt-dlp
    $CHROOT pip3 install yt-dlp --break-system-packages || \
        warn "yt-dlp install failed"

    # haxor-news (HN TUI)
    $CHROOT pip3 install haxor-news --break-system-packages || true

    # taskwarrior extras
    $APT timewarrior || true

    # deltachat-cli
    local deltachat_rpc_url=""
    deltachat_rpc_url=$(github_latest_asset_url "deltachat/deltachat-core-rust" 'deltachat-rpc-server-aarch64-linux') && \
        $CHROOT bash -c "wget -qO /usr/local/bin/deltachat-rpc-server '$deltachat_rpc_url' && chmod +x /usr/local/bin/deltachat-rpc-server" || \
        warn "deltachat-rpc-server install failed"

    log "TUI apps installed"
}

# =============================================================================
# STAGE 12: AI STACK
# =============================================================================
install_ai() {
    if [[ "$INCLUDE_AI" != "true" ]]; then
        warn "AI stack disabled in config, skipping..."
        return
    fi

    section "Installing AI Stack (whisper.cpp + piper)"

    $APT libopenblas-dev liblapack-dev

    # whisper.cpp
    log "Building whisper.cpp..."
    $CHROOT bash -c "
        rm -rf /opt/ghost/whisper.cpp && \
        git clone --depth=1 https://github.com/ggerganov/whisper.cpp \
        /opt/ghost/whisper.cpp && \
        cd /opt/ghost/whisper.cpp && \
        make -j\$(nproc) && \
        whisper_bin=''; \
        if [[ -x /opt/ghost/whisper.cpp/build/bin/whisper-cli ]]; then \
            whisper_bin=/opt/ghost/whisper.cpp/build/bin/whisper-cli; \
        elif [[ -x /opt/ghost/whisper.cpp/main ]]; then \
            whisper_bin=/opt/ghost/whisper.cpp/main; \
        else \
            echo 'whisper.cpp CLI binary not found after build' >&2; \
            exit 1; \
        fi; \
        ln -sf \"\$whisper_bin\" /usr/local/bin/whisper && \
        # Download tiny.en model (~75MB)
        bash models/download-ggml-model.sh $WHISPER_MODEL" || warn "whisper.cpp build failed"

    # piper TTS
    log "Installing piper TTS..."
    local piper_url=""
    piper_url=$(github_latest_asset_url "rhasspy/piper" 'piper_linux_aarch64\\.tar\\.gz') && \
    $CHROOT bash -c "
        rm -rf /opt/ghost/piper && \
        wget -qO /tmp/piper.tar.gz '$piper_url' && \
        tar -xzf /tmp/piper.tar.gz -C /opt/ghost/ && \
        ln -sf /opt/ghost/piper/piper /usr/local/bin/piper && \
        # Download voice model
        mkdir -p /opt/ghost/piper/voices && \
        wget -qO /opt/ghost/piper/voices/${PIPER_VOICE}.onnx \
        https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx && \
        wget -qO /opt/ghost/piper/voices/${PIPER_VOICE}.onnx.json \
        https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json" || \
        warn "piper install failed"

    log "AI stack installed"
}

# =============================================================================
# STAGE 13: GAMING
# =============================================================================
install_gaming() {
    section "Installing Gaming Layer"

    if [[ "$INCLUDE_STEALTH" != "true" && "$INCLUDE_PORTMASTER" != "true" && "$INCLUDE_DOSBOX" != "true" ]]; then
        warn "Gaming layer disabled in config, skipping..."
        return
    fi

    if [[ "$INCLUDE_STEALTH" == "true" ]]; then
        log "Installing mGBA (stealth mode emulator)..."
        $APT mgba-qt || $APT mgba-sdl || \
            $CHROOT bash -c "
                git clone --depth=1 https://github.com/mgba-emu/mgba /tmp/mgba && \
                cd /tmp/mgba && mkdir build && cd build && \
                cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_SDL=ON \
                         -DBUILD_QT=OFF -DBUILD_LIBRETRO=OFF && \
                make -j\$(nproc) && make install && \
                rm -rf /tmp/mgba" || warn "mGBA build failed"

        mkdir -p "$ROOTFS_DIR/home/$GHOST_USER/.stealth/roms"
    fi

    if [[ "$INCLUDE_PORTMASTER" == "true" ]]; then
        log "Installing PortMaster..."
        local portmaster_url=""
        portmaster_url=$(github_latest_asset_url "PortsMaster/PortMaster-New" 'PortMaster\\.zip') && \
        $CHROOT bash -c "
            rm -rf /opt/portmaster && \
            mkdir -p /opt/portmaster && \
            wget -qO /tmp/portmaster.zip \
            '$portmaster_url' && \
            unzip -q /tmp/portmaster.zip -d /opt/portmaster/" || \
            warn "PortMaster install failed"

        # Gamemode (Feral)
        $APT gamemode libgamemode0 || true
    fi

    if [[ "$INCLUDE_DOSBOX" == "true" ]]; then
        log "Installing DOS compatibility layer..."
        # DOSBox-X no longer publishes a Linux ARM64 .deb asset. Use the Debian
        # DOSBox package on Bookworm ARM64 so optional DOS tooling still lands.
        $APT dosbox || warn "DOSBox install failed"
    fi

    log "Gaming layer installed"
}

# =============================================================================
# STAGE 14: COMPATIBILITY LAYERS
# =============================================================================
install_compat() {
    section "Installing Compatibility Layers (FEX + box64 + Wine)"

    if [[ "$INCLUDE_FEX" != "true" && "$INCLUDE_WINE" != "true" ]]; then
        warn "Compatibility layers disabled in config, skipping..."
        return
    fi

    # box64
    log "Building box64..."
    $CHROOT bash -c "
        git clone --depth=1 $BOX64_REPO /tmp/box64 && \
        cd /tmp/box64 && mkdir build && cd build && \
        cmake .. -DARM_DYNAREC=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo \
                 -DRPI4ARM64=1 && \
        make -j\$(nproc) && make install && \
        rm -rf /tmp/box64" || warn "box64 build failed"

    if [[ "$INCLUDE_FEX" == "true" ]]; then
        log "Building FEX-Emu..."
        $APT libepoxy-dev libgbm-dev libdrm-dev libsdl2-dev
        $CHROOT bash -c "
            git clone --depth=1 $FEX_REPO /tmp/fex && \
            cd /tmp/fex && \
            git submodule update --init --depth=1 && \
            mkdir build && cd build && \
            cmake .. -DCMAKE_BUILD_TYPE=RelWithDebInfo \
                     -DENABLE_LTO=True \
                     -DBUILD_TESTS=False && \
            make -j\$(nproc) && make install && \
            rm -rf /tmp/fex" || warn "FEX build failed"

        # FEX rootfs (Ubuntu 24.04 x86-64 minimal, ~300MB compressed)
        log "Downloading FEX x86-64 rootfs..."
        mkdir -p "$ROOTFS_DIR/opt/fex/rootfs"
        $CHROOT bash -c "
            rm -rf /opt/fex/rootfs/* && \
            wget -qO /tmp/fex-rootfs.tar.zst $FEX_ROOTFS_URL && \
            tar -xf /tmp/fex-rootfs.tar.zst -C /opt/fex/rootfs/ && \
            rm /tmp/fex-rootfs.tar.zst && \
            mkdir -p /root/.fex-emu && \
            rootfs_dir=\$(find /opt/fex/rootfs -mindepth 1 -maxdepth 1 -type d | head -n1) && \
            # Register rootfs with FEX
            FEXRootFSFetcher -y 2>/dev/null || \
            echo '{\"RootFS\":\"'\"\$rootfs_dir\"'\"}' > \
            /root/.fex-emu/Config.json" || warn "FEX rootfs download failed"
    fi

    if [[ "$INCLUDE_WINE" == "true" ]]; then
        log "Installing Wine (ARM64)..."
        $APT wine wine32 wine64 winbind || \
            $CHROOT bash -c "
                dpkg --add-architecture armhf && \
                apt-get update -qq && \
                apt-get install -y wine" || warn "Wine install failed"

        # Windows tools via Wine+FEX
        log "Installing Windows tools (x64dbg, CFF Explorer, DIE)..."
        mkdir -p "$ROOTFS_DIR/opt/ghost/wine-apps"
        $CHROOT bash -c "
            rm -rf /opt/ghost/wine-apps/x64dbg /opt/ghost/wine-apps/die /opt/ghost/wine-apps/cff-explorer && \
            # x64dbg
            wget -qO /tmp/x64dbg.zip \
            https://github.com/x64dbg/x64dbg/releases/latest/download/snapshot_$(date +%Y-%m-%d).zip && \
            unzip -q /tmp/x64dbg.zip -d /opt/ghost/wine-apps/x64dbg/ 2>/dev/null || \
            wget -qO /tmp/x64dbg.zip \
            https://github.com/x64dbg/x64dbg/releases/download/snapshot/snapshot_2024-01-01.zip && \
            unzip -q /tmp/x64dbg.zip -d /opt/ghost/wine-apps/x64dbg/ || true

            # Detect It Easy
            wget -qO /tmp/die.zip \
            https://github.com/horsicq/DIE-engine/releases/latest/download/die_win64_portable.zip && \
            unzip -q /tmp/die.zip -d /opt/ghost/wine-apps/die/ || true

            # CFF Explorer (via wine)
            wget -qO /tmp/cff-explorer.zip \
            https://ntcore.com/files/CFF_Explorer.zip && \
            unzip -q /tmp/cff-explorer.zip -d /opt/ghost/wine-apps/cff-explorer/ && \
            rm -f /tmp/cff-explorer.zip || true" || \
            warn "Some Wine app downloads failed"
    fi

    log "Compatibility layers installed"
}

# =============================================================================
# STAGE 15: CYBERCHEF SERVER
# =============================================================================
install_cyberchef() {
    if [[ "$INCLUDE_CYBERCHEF" != "true" ]]; then return; fi

    section "Installing CyberChef Server"

    $CHROOT bash -c "
        cyberchef_url=\$(python3 - << 'PY'
import json
import re
import sys
import urllib.request

with urllib.request.urlopen('https://api.github.com/repos/gchq/CyberChef/releases/latest') as resp:
    data = json.load(resp)

for asset in data.get('assets', []):
    name = asset.get('name', '')
    if re.fullmatch(r'CyberChef_v[0-9.]+\.zip', name):
        print(asset['browser_download_url'])
        break
else:
    sys.exit('CyberChef release asset not found')
PY
        ) && \
        wget -qO /tmp/cyberchef.zip \"\$cyberchef_url\" && \
        rm -rf /opt/ghost/cyberchef && \
        mkdir -p /opt/ghost/cyberchef && \
        unzip -q /tmp/cyberchef.zip -d /opt/ghost/cyberchef/ && \
        rm /tmp/cyberchef.zip" || warn "CyberChef download failed"

    log "CyberChef installed (localhost:$CYBERCHEF_PORT)"
}

# =============================================================================
# STAGE 16: POWER & PERFORMANCE MANAGEMENT
# =============================================================================
install_power() {
    section "Installing Power Management"

    $APT tlp acpi upower

    # auto-cpufreq
    $CHROOT bash -c "
        rm -rf /opt/ghost/auto-cpufreq && \
        git clone --depth=1 https://github.com/AdnanHodzic/auto-cpufreq \
        /opt/ghost/auto-cpufreq && \
        cd /opt/ghost/auto-cpufreq && \
        ./auto-cpufreq-installer --install" || \
        warn "auto-cpufreq install failed, using tlp only"

    # handheld-daemon (from Bazzite)
    $CHROOT bash -c "
        pip3 install hhd --break-system-packages" || \
        warn "handheld-daemon unavailable, install manually post-boot"
    enable_rootfs_service "hhd.service"

    log "Power management installed"
}

# =============================================================================
# STAGE 16_DISPLAY: DISPLAY SUPPORT
# USB displays, HDMI, USB-C docks
# NOTE: No Xorg, no Weston full — Cage/Wayland only to save RAM
# =============================================================================
install_display() {
    section "Installing Display Support"

    # Wayland output management (switch outputs, rotate, mirror)
    $APT wlr-randr || true          # wlr-randr — like xrandr but for wlroots/Cage
    $APT kanshi || true             # kanshi — automatic output config profiles
                                    # auto-switches layout when HDMI connected

    # DisplayLink userspace library (works with evdi kernel driver)
    log "Installing DisplayLink userspace..."
    $CHROOT bash -c "
        wget -qO /tmp/displaylink.zip         https://www.synaptics.com/sites/default/files/exe_files/2024-05/DisplayLink%20USB%20Graphics%20Software%20for%20Ubuntu6.0-EXE.zip &&
        unzip -q /tmp/displaylink.zip -d /tmp/displaylink/ &&
        cd /tmp/displaylink &&
        # Extract the run installer and get just the library
        chmod +x *.run &&
        ./*.run --noexec --target /tmp/dl-extracted 2>/dev/null || true &&
        # Copy libraries manually
        find /tmp/dl-extracted -name '*.so*' -exec cp {} /usr/local/lib/ \; &&
        ldconfig &&
        rm -rf /tmp/displaylink /tmp/dl-extracted" ||     warn "DisplayLink userspace install failed — USB displays need manual setup"

    # displaylink-manager service
    $CHROOT bash -c "
        rm -rf /opt/ghost/displaylink-debian && \
        git clone --depth=1 https://github.com/AdnanHodzic/displaylink-debian         /opt/ghost/displaylink-debian" || true

    # Type-C / DisplayPort Alt Mode userspace
    $APT \
        usbutils \
        libdrm-dev \
        libdrm-tests || true

    # wlopm — turn displays on/off (used by swayidle for screen off)
    $CHROOT bash -c "
        git clone --depth=1 https://git.sr.ht/~leon_plickat/wlopm /tmp/wlopm &&
        cd /tmp/wlopm &&
        make &&
        make install &&
        rm -rf /tmp/wlopm" || true

    # kanshi config — auto-detects internal + external display
    mkdir -p "$ROOTFS_DIR/home/$GHOST_USER/.config/kanshi"
    cat > "$ROOTFS_DIR/home/$GHOST_USER/.config/kanshi/config" << 'EOF'
# ghOSt kanshi display profiles
# Automatically switches when displays connect/disconnect

profile internal_only {
    output * enable
}

profile hdmi_extended {
    output * enable
    # Internal display
    output "Unknown Unknown Unknown" enable position 0,0 scale 1
    # External HDMI — position to the right
    output "HDMI-A-1" enable position 640,0
}

profile hdmi_mirror {
    output * enable scale 1
}

profile usb_display {
    output * enable
    output "DisplayLink" enable position 640,0
}
EOF

    # Add kanshi to GUI startup
    local gui="$ROOTFS_DIR/etc/systemd/system/ghost-gui.service"
    if grep -q "ExecStart=" "$gui" 2>/dev/null; then
        sed -i '/\[Service\]/a ExecStartPost=/usr/bin/kanshi \&' "$gui" || true
    fi

    # wlr-randr wrapper script — easy display switching from terminal
    cat > "$ROOTFS_DIR/usr/local/bin/display" << 'DISPLAYSCRIPT'
#!/usr/bin/env bash
# ghOSt display management wrapper
case "${1:-list}" in
    list)
        echo "Connected outputs:"
        wlr-randr
        ;;
    mirror)
        # Mirror internal to HDMI
        wlr-randr --output HDMI-A-1 --same-as DSI-1
        echo "Mirroring to HDMI"
        ;;
    extend)
        # Extend to HDMI on the right
        wlr-randr --output HDMI-A-1 --pos 640,0
        echo "Extending to HDMI (right)"
        ;;
    hdmi-only)
        wlr-randr --output DSI-1 --off --output HDMI-A-1 --on
        echo "HDMI only"
        ;;
    internal)
        wlr-randr --output HDMI-A-1 --off --output DSI-1 --on
        echo "Internal display only"
        ;;
    off)
        wlopm --off \*
        echo "All displays off"
        ;;
    on)
        wlopm --on \*
        echo "All displays on"
        ;;
    rotate)
        wlr-randr --output "${2:-DSI-1}" --transform "${3:-normal}"
        echo "Rotated ${2:-DSI-1} to ${3:-normal}"
        ;;
    *)
        echo "Usage: display [list|mirror|extend|hdmi-only|internal|off|on|rotate]"
        ;;
esac
DISPLAYSCRIPT
    chmod +x "$ROOTFS_DIR/usr/local/bin/display"

    # udev rule — run kanshi on display hotplug
    cat > "$ROOTFS_DIR/etc/udev/rules.d/95-display-hotplug.rules" << 'EOF'
# Reload display config when HDMI/DP connects
ACTION=="change", SUBSYSTEM=="drm", RUN+="/usr/bin/systemctl --user reload kanshi.service 2>/dev/null || true"
# DisplayLink USB display
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="17e9",     RUN+="/usr/bin/modprobe evdi 2>/dev/null || true"
EOF

    log "Display support installed"
}

# =============================================================================
# STAGE 16a: GAME CONTROLLER SUPPORT
# =============================================================================
install_controllers() {
    section "Installing Game Controller Support"

    # Core tools
    $APT         joystick         evtest         python3-pygame         python3-sdl2 || true

    # AntiMicroX no longer publishes Linux ARM64 assets. Use Debian's
    # antimicro package when available and expose it under the expected
    # antimicrox name so controller-remapping integrations can still find it.
    $APT antimicro || warn "antimicro is unavailable on Bookworm ARM64"
    $CHROOT bash -c "
        if command -v antimicro >/dev/null 2>&1; then
            ln -sf \$(command -v antimicro) /usr/local/bin/antimicrox
        fi" || true

    # SDL2 GameController database — community maintained, covers 1000s of controllers
    log "Installing SDL GameController database..."
    mkdir -p "$ROOTFS_DIR/opt/ghost"
    $CHROOT bash -c "
        wget -qO /opt/ghost/gamecontrollerdb.txt         https://raw.githubusercontent.com/gabomdq/SDL_GameControllerDB/master/gamecontrollerdb.txt" ||         warn "GameControllerDB download failed"

    # Add SDL_GAMECONTROLLERCONFIG_FILE to fish config
    mkdir -p "$ROOTFS_DIR/home/$GHOST_USER/.config/fish"
    cat >> "$ROOTFS_DIR/home/$GHOST_USER/.config/fish/config.fish" << 'EOF'

# SDL2 GameController database — enables most controllers automatically
set -gx SDL_GAMECONTROLLERCONFIG_FILE /opt/ghost/gamecontrollerdb.txt
EOF

    # PS3 DualShock 3 Bluetooth pairing tools
    log "Installing PS3 Bluetooth pairing tools..."
    # RetroPie's standalone sixpair repository no longer exists. Build both
    # the pairing helper and the sixad daemon from the maintained sixad tree.
    if clone_repo_clean https://github.com/RetroPie/sixad /tmp/sixad; then
        $CHROOT bash -c "
            # sixpair — pairs PS3 controller (connect via USB first, run once)
            apt-get install -y libusb-dev 2>/dev/null || true
            cd /tmp/sixad &&
            gcc -o /usr/local/bin/sixpair sixpair.c \$(pkg-config --cflags --libs libusb) &&
            chmod +x /usr/local/bin/sixpair" || warn "sixpair build failed"

        $CHROOT bash -c "
            # sixad — PS3 Bluetooth daemon
            cd /tmp/sixad &&
            make &&
            make install" || warn "sixad build failed"

        $CHROOT bash -c "rm -rf /tmp/sixad"
    else
        warn "sixad source clone failed, skipping PS3 Bluetooth pairing tools"
    fi

    # udev rules for all common controllers
    cat > "$ROOTFS_DIR/etc/udev/rules.d/52-controllers.rules" << 'EOF'
# =============================================================================
# ghOSt Game Controller udev rules
# =============================================================================

# Sony PlayStation
# PS3 DualShock 3
SUBSYSTEM=="usb", ATTR{idVendor}=="054c", ATTR{idProduct}=="0268", MODE="0666", GROUP="input"
# PS4 DualShock 4 v1
SUBSYSTEM=="usb", ATTR{idVendor}=="054c", ATTR{idProduct}=="05c4", MODE="0666", GROUP="input"
# PS4 DualShock 4 v2
SUBSYSTEM=="usb", ATTR{idVendor}=="054c", ATTR{idProduct}=="09cc", MODE="0666", GROUP="input"
# PS5 DualSense
SUBSYSTEM=="usb", ATTR{idVendor}=="054c", ATTR{idProduct}=="0ce6", MODE="0666", GROUP="input"
# PS5 DualSense Edge
SUBSYSTEM=="usb", ATTR{idVendor}=="054c", ATTR{idProduct}=="0df2", MODE="0666", GROUP="input"

# Microsoft Xbox
# Xbox 360 wired
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="028e", MODE="0666", GROUP="input"
# Xbox 360 wireless receiver
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="0719", MODE="0666", GROUP="input"
# Xbox One
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02d1", MODE="0666", GROUP="input"
# Xbox One S
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02ea", MODE="0666", GROUP="input"
# Xbox Series X/S
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="0b12", MODE="0666", GROUP="input"

# Nintendo
# Switch Pro Controller
SUBSYSTEM=="usb", ATTR{idVendor}=="057e", ATTR{idProduct}=="2009", MODE="0666", GROUP="input"
# Joy-Con L
SUBSYSTEM=="usb", ATTR{idVendor}=="057e", ATTR{idProduct}=="2006", MODE="0666", GROUP="input"
# Joy-Con R
SUBSYSTEM=="usb", ATTR{idVendor}=="057e", ATTR{idProduct}=="2007", MODE="0666", GROUP="input"
# Gamecube adapter
SUBSYSTEM=="usb", ATTR{idVendor}=="057e", ATTR{idProduct}=="0337", MODE="0666", GROUP="input"

# 8BitDo
SUBSYSTEM=="usb", ATTR{idVendor}=="2dc8", MODE="0666", GROUP="input"

# Valve Steam Controller
SUBSYSTEM=="usb", ATTR{idVendor}=="28de", MODE="0666", GROUP="input"

# Logitech
SUBSYSTEM=="usb", ATTR{idVendor}=="046d", MODE="0666", GROUP="input"

# Mayflash adapters
SUBSYSTEM=="usb", ATTR{idVendor}=="0079", MODE="0666", GROUP="input"
SUBSYSTEM=="usb", ATTR{idVendor}=="33df", MODE="0666", GROUP="input"

# Generic HID gamepad catchall
SUBSYSTEM=="input", GROUP="input", MODE="0666"
KERNEL=="js[0-9]*", GROUP="input", MODE="0666"
KERNEL=="event[0-9]*", GROUP="input", MODE="0666"
EOF

    # Add ghost user to input group (already done in configure.sh but reinforce)
    $CHROOT usermod -aG input "$GHOST_USER" 2>/dev/null || true

    log "Game controller support installed"
}

# =============================================================================
# STAGE 16b: MISSING FIRMWARE (CRITICAL)
# =============================================================================
install_firmware() {
    section "Installing Critical Firmware"

    $APT         firmware-atheros         firmware-ralink         firmware-mediatek         firmware-realtek         firmware-brcm80211         firmware-iwlwifi         firmware-libertas-usb         firmware-misc-nonfree         firmware-linux-nonfree || true

    log "Firmware installed"
}

# =============================================================================
# STAGE 16c: GPS SUPPORT
# =============================================================================
install_gps() {
    section "Installing GPS Support"

    $APT         gpsd         gpsd-clients         python3-gps         foxtrotgps || true

    # Enable gpsd
    mkdir_rootfs_parent "$ROOTFS_DIR/etc/default/gpsd"
    cat > "$ROOTFS_DIR/etc/default/gpsd" << EOF
START_DAEMON="true"
GPSD_OPTIONS="-n"
DEVICES="/dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyACM0"
USBAUTO="true"
GPSD_SOCKET="/var/run/gpsd.sock"
EOF

    log "GPS support installed"
}

# =============================================================================
# STAGE 16d: MOBILE BROADBAND / LTE
# =============================================================================
install_modem() {
    section "Installing Mobile Broadband Support"

    $APT         modemmanager         libmm-glib0         usb-modeswitch         usb-modeswitch-data         mobile-broadband-provider-info         ppp || true

    enable_rootfs_service "ModemManager.service"

    log "Mobile broadband installed"
}

# =============================================================================
# STAGE 16e: USB CAMERA & KINECT
# =============================================================================
install_camera() {
    section "Installing Camera & Kinect Support"

    # V4L2 utils and camera tools
    $APT         v4l-utils         v4l2loopback-dkms         v4l2loopback-utils         ffmpeg         python3-v4l2capture || true

    # fswebcam — simple webcam capture
    $APT fswebcam || true

    # motion — motion detection daemon
    $APT motion || true

    # guvcview — V4L2 camera viewer (lightweight Qt)
    $APT guvcview || true

    # OpenCV for Python (camera processing)
    $CHROOT pip3 install opencv-python-headless --break-system-packages || true

    # -------------------------------------------------------------------------
    # KINECT v1 — libfreenect
    # -------------------------------------------------------------------------
    log "Installing Kinect v1 support (libfreenect)..."
    $APT         libfreenect-dev         freenect         libfreenect-demos ||     $CHROOT bash -c "
        apt-get install -y libusb-1.0-0-dev libudev-dev &&
        git clone --depth=1 https://github.com/OpenKinect/libfreenect /tmp/libfreenect &&
        cd /tmp/libfreenect &&
        mkdir build && cd build &&
        cmake .. -DBUILD_EXAMPLES=ON -DBUILD_PYTHON3=ON                  -DCMAKE_BUILD_TYPE=Release &&
        make -j\$(nproc) &&
        make install &&
        ldconfig &&
        # Python bindings
        cd ../wrappers/python &&
        pip3 install . --break-system-packages &&
        rm -rf /tmp/libfreenect" || warn "libfreenect build failed"

    # Kinect v1 udev rules
    cat > "$ROOTFS_DIR/etc/udev/rules.d/51-kinect.rules" << 'EOF'
# Kinect v1 — Xbox 360 Kinect
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02ae", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02bf", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02c2", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02be", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02b0", MODE="0666", GROUP="plugdev"
# Kinect v2 — Xbox One Kinect
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02c4", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02d8", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02d9", MODE="0666", GROUP="plugdev"
EOF

    # -------------------------------------------------------------------------
    # KINECT v2 — libfreenect2
    # -------------------------------------------------------------------------
    log "Installing Kinect v2 support (libfreenect2)..."
    $APT         libusb-1.0-0-dev         libturbojpeg0-dev         libglfw3-dev         libopenni2-dev || true

    $CHROOT bash -c "
        git clone --depth=1 https://github.com/OpenKinect/libfreenect2             /tmp/libfreenect2 &&
        cd /tmp/libfreenect2 &&
        mkdir build && cd build &&
        cmake .. -DCMAKE_BUILD_TYPE=Release                  -DENABLE_CXX11=ON                  -DENABLE_OPENGL=OFF                  -DENABLE_VAAPI=OFF                  -DENABLE_TEGRA=OFF &&
        make -j\$(nproc) &&
        make install &&
        ldconfig &&
        rm -rf /tmp/libfreenect2" || warn "libfreenect2 build failed"

    # PyKinect2 (Python bindings for Kinect v2)
    $CHROOT pip3 install pykinect2 --break-system-packages || true

    # -------------------------------------------------------------------------
    # OpenNI2 (common Kinect/depth camera framework)
    # -------------------------------------------------------------------------
    $APT libopenni2-dev openni2-utils || true

    # NiTE2 skeleton tracking (if available)
    # NiTE2 is proprietary but the library is freely downloadable
    $CHROOT bash -c "
        rm -rf /opt/ghost/NiTE-Linux-aarch64-* && \
        wget -qO /tmp/nite2.tar.bz2         https://sourceforge.net/projects/roboticslab/files/External/nite/NiTE-Linux-aarch64-2.2.tar.bz2 &&
        tar -xjf /tmp/nite2.tar.bz2 -C /opt/ghost/ &&
        rm /tmp/nite2.tar.bz2" || warn "NiTE2 download failed - install manually"

    # Point Cloud Library (PCL) for Kinect depth data processing
    $APT libpcl-dev pcl-tools || true

    log "Camera and Kinect support installed"
}

# =============================================================================
# STAGE 16f: ANDROID TOOLS
# =============================================================================
install_android() {
    section "Installing Android Tools (ADB/Fastboot + more)"

    # Core ADB and Fastboot
    $APT         adb         fastboot         android-tools-adb         android-tools-fastboot || true

    # udev rules for common Android devices
    $APT android-sdk-platform-tools-common || {
        mkdir_rootfs_parent "$ROOTFS_DIR/etc/udev/rules.d/51-android.rules"
        cat > "$ROOTFS_DIR/etc/udev/rules.d/51-android.rules" << 'EOF'
# Android ADB/Fastboot udev rules
# Generic Android
SUBSYSTEM=="usb", ATTR{idVendor}=="0bb4", MODE="0666", GROUP="plugdev"  # HTC
SUBSYSTEM=="usb", ATTR{idVendor}=="04e8", MODE="0666", GROUP="plugdev"  # Samsung
SUBSYSTEM=="usb", ATTR{idVendor}=="22b8", MODE="0666", GROUP="plugdev"  # Motorola
SUBSYSTEM=="usb", ATTR{idVendor}=="1004", MODE="0666", GROUP="plugdev"  # LG
SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", MODE="0666", GROUP="plugdev"  # Google/Nexus/Pixel
SUBSYSTEM=="usb", ATTR{idVendor}=="2717", MODE="0666", GROUP="plugdev"  # Xiaomi
SUBSYSTEM=="usb", ATTR{idVendor}=="12d1", MODE="0666", GROUP="plugdev"  # Huawei
SUBSYSTEM=="usb", ATTR{idVendor}=="19d2", MODE="0666", GROUP="plugdev"  # ZTE
SUBSYSTEM=="usb", ATTR{idVendor}=="2916", MODE="0666", GROUP="plugdev"  # OnePlus
SUBSYSTEM=="usb", ATTR{idVendor}=="0fce", MODE="0666", GROUP="plugdev"  # Sony
SUBSYSTEM=="usb", ATTR{idVendor}=="0489", MODE="0666", GROUP="plugdev"  # Fairphone
EOF
    }

    if [[ -f "$ROOTFS_DIR/etc/udev/rules.d/51-android.rules" ]]; then
        chmod a+r "$ROOTFS_DIR/etc/udev/rules.d/51-android.rules"
    fi

    # scrcpy — mirror/control Android screen over ADB (incredibly useful)
    $APT scrcpy || warn "scrcpy package unavailable on Bookworm ARM64, skipping binary install"

    # apktool — already in ✅
    # jadx   — already in ✅
    # frida  — already in ✅

    # Additional Android security tools
    $CHROOT pip3 install         androguard         apkleaks         --break-system-packages || true

    # MobSF dependencies (Mobile Security Framework — runs as web service)
    $CHROOT pip3 install mobsf --break-system-packages ||     $CHROOT bash -c "
        rm -rf /opt/ghost/mobsf &&
        git clone --depth=1 https://github.com/MobSF/Mobile-Security-Framework-MobSF         /opt/ghost/mobsf &&
        cd /opt/ghost/mobsf &&
        pip3 install -r requirements.txt --break-system-packages" ||         warn "MobSF install failed"

    # Objection (runtime mobile exploration via frida) — already in ✅

    # dex2jar
    local dex2jar_url=""
    dex2jar_url=$(github_latest_asset_url "pxb1988/dex2jar" 'dex-tools-v[0-9.]+\\.zip') && \
    $CHROOT bash -c "
        rm -rf /opt/ghost/dex-tools-* &&
        wget -qO /tmp/dex2jar.zip         '$dex2jar_url' &&
        unzip -q /tmp/dex2jar.zip -d /opt/ghost/ &&
        ln -sf /opt/ghost/dex-tools-*/d2j-dex2jar.sh /usr/local/bin/dex2jar &&
        chmod +x /opt/ghost/dex-tools-*/*.sh &&
        rm /tmp/dex2jar.zip" || warn "dex2jar install failed"

    # Ghidra-style Android analysis — already covered by jadx + radare2

    log "Android tools installed"
}

# =============================================================================
# STAGE 16g: SYSTEM UX GAPS
# =============================================================================
install_ux() {
    section "Installing UX Components"

    # Wayland clipboard
    $APT wl-clipboard xclip xsel

    # Screen lock + idle
    $APT swaylock swayidle || true

    # Notification daemon
    $APT mako-notifier libnotify-bin ||     $APT dunst libnotify-bin || true   # dunst as fallback

    # PDF viewer
    $APT zathura zathura-pdf-mupdf ||     $APT zathura zathura-pdf-poppler || true

    # Image viewer
    $APT imv ||     $APT feh || true                   # feh as fallback

    # QR tools
    $APT qrencode zbar-tools

    # Backup
    $APT borgbackup || true
    $APT restic || {
        local restic_url=""
        restic_url=$(github_latest_asset_url "restic/restic" 'restic_.*_linux_arm64\\.bz2') && \
            $CHROOT bash -c "wget -qO /usr/local/bin/restic.bz2 '$restic_url' && bunzip2 -f /usr/local/bin/restic.bz2 && chmod +x /usr/local/bin/restic" || \
            warn "restic install failed"
    }

    log "UX components installed"
}

# =============================================================================
# STAGE 16h: MISSING SECURITY TOOLS
# =============================================================================
install_security_extras() {
    section "Installing Additional Security Tools"

    # --- NETWORK ATTACK ---
    $APT         macchanger         ettercap-text-only         yersinia         sslstrip         netsniff-ng         tcpreplay         dsniff || true

    # --- WIRELESS EXTRAS ---
    $APT         reaver         bully         pixiewps         cowpatty || true

    # --- WEB APP ---
    $APT         wpscan         joomscan         davtest         cadaver || true

    $CHROOT pip3 install         droopescan         commix         xsstrike         --break-system-packages || true

    # dalfox is shipped as an arm64 release binary because its latest source
    # build also outruns Bookworm's Go toolchain.
    local dalfox_url=""
    dalfox_url=$(github_latest_asset_url "hahwul/dalfox" 'dalfox-linux-arm64\\.tar\\.gz') && \
        install_archive_binary "$dalfox_url" "dalfox.tar.gz" "dalfox" || true

    # --- RECON EXTRAS ---
    $APT         dnsrecon         onesixtyone         snmp         snmpd         nbtscan         arp-scan         swaks         smtp-user-enum || true

    $CHROOT pip3 install         maigret         holehe         phoneinfoga         socialscan         --break-system-packages || true

    # twint (Twitter OSINT)
    $CHROOT pip3 install         twint         --break-system-packages || true

    # --- PASSWORD EXTRAS ---
    $APT crunch || true

    $CHROOT pip3 install         hashid         name-that-hash         cupp         --break-system-packages || true

    # --- POST EXPLOITATION ---
    # Windows tools via Wine+FEX
    mkdir -p "$ROOTFS_DIR/opt/ghost/wine-apps/postex"
    local mimikatz_url=""
    local winpeas_url=""
    mimikatz_url=$(github_latest_asset_url "gentilkiwi/mimikatz" 'mimikatz_trunk\\.zip') || true
    winpeas_url=$(github_latest_asset_url "peass-ng/PEASS-ng" 'winPEASx64\\.exe') || true
    $CHROOT bash -c "
        rm -rf /opt/ghost/wine-apps/postex/mimikatz && \
        # mimikatz
        wget -qO /tmp/mimikatz.zip         '$mimikatz_url' &&
        unzip -q /tmp/mimikatz.zip -d /opt/ghost/wine-apps/postex/mimikatz/ &&
        rm /tmp/mimikatz.zip

        # winPEAS
        wget -qO /opt/ghost/wine-apps/postex/winpeas.exe         '$winpeas_url'

        # Seatbelt
        wget -qO /opt/ghost/wine-apps/postex/Seatbelt.exe         https://github.com/r3motecontrol/Ghostpack-CompiledBinaries/raw/master/Seatbelt.exe" ||         warn "Some Windows post-exploitation tools failed to download"

    # nishang (PowerShell scripts — no binary needed, just clone)
    $CHROOT bash -c "
        rm -rf /opt/ghost/nishang && \
        git clone --depth=1 https://github.com/samratashok/nishang         /opt/ghost/nishang" || true

    # PowerSploit
    $CHROOT bash -c "
        rm -rf /opt/ghost/powersploit && \
        git clone --depth=1 https://github.com/PowerShellMafia/PowerSploit         /opt/ghost/powersploit" || true

    # --- SDR/RF EXTRAS ---
    $CHROOT pip3 install meshtastic --break-system-packages || true

    # noaa-apt (NOAA weather satellite decoder — Rust binary)
    local noaa_apt_url=""
    noaa_apt_url=$(github_latest_asset_url "martinber/noaa-apt" 'noaa-apt-.*-aarch64-linux-gnu\\.zip') && \
        install_archive_binary "$noaa_apt_url" "noaa-apt.zip" "noaa-apt" || \
        warn "noaa-apt install failed"

    # aptdec (APT signal decoder). The historical csete/aptdec repo is gone,
    # so use the maintained Xerbo fork and disable git credential prompts.
    $APT libsndfile-dev libpng-dev || true
    $CHROOT bash -c "
        set -e
        rm -rf /tmp/aptdec &&
        GIT_TERMINAL_PROMPT=0 timeout 300 \
        git clone --depth=1 --recursive --single-branch https://github.com/Xerbo/aptdec /tmp/aptdec &&
        cd /tmp/aptdec &&
        cmake -B build &&
        cmake --build build -j\$(nproc) &&
        cmake --install build &&
        rm -rf /tmp/aptdec" || warn "aptdec build failed"

    # hostapd + dnsmasq (rogue AP)
    $APT hostapd dnsmasq || true

    # tshark (CLI Wireshark)
    $APT tshark || true

    # chirp (radio programming)
    $CHROOT pip3 install chirp --break-system-packages ||     $APT chirp || true

    # --- SCREEN LOCK COMBO ---
    # Add swaylock trigger to launcher: Select+Start+R1
    # Handled in stealthd patch below

    log "Additional security tools installed"
}

# =============================================================================
# STAGE 16i: DOS CONTENT SETUP SCRIPT
# =============================================================================
install_dos_content() {
    if [[ "$INCLUDE_DOSBOX" != "true" ]]; then
        warn "DOS content setup disabled in config, skipping..."
        return
    fi

    section "Installing DOS Content Setup Script"

    mkdir -p "$ROOTFS_DIR/opt/ghost/dosbox"
    cat > "$ROOTFS_DIR/opt/ghost/dosbox/download-games.sh" << 'DOSSCRIPT'
#!/usr/bin/env bash
# ghOSt DOS Content Downloader
# Downloads abandonware titles from archive.org
# Run this after first boot with internet connection

DOSDIR="/opt/ghost/dosbox/games"
mkdir -p "$DOSDIR"

log() { echo "[dos-setup] $*"; }

log "Downloading themed DOS content from archive.org..."

# Neuromancer (1988) — Interplay/Gibson
log "Neuromancer (1988)..."
wget -qO /tmp/neuro.zip     "https://archive.org/download/Neuromancer_1988_Interplay/Neuromancer_1988_Interplay.zip" &&     unzip -q /tmp/neuro.zip -d "$DOSDIR/neuromancer/" &&     rm /tmp/neuro.zip || log "Neuromancer download failed"

# Hacker (1985) — Activision
log "Hacker (1985)..."
wget -qO /tmp/hacker1.zip     "https://archive.org/download/Hacker_1985_Activision/Hacker_1985_Activision.zip" &&     unzip -q /tmp/hacker1.zip -d "$DOSDIR/hacker1/" &&     rm /tmp/hacker1.zip || log "Hacker I download failed"

# Hacker II (1986) — Activision
log "Hacker II (1986)..."
wget -qO /tmp/hacker2.zip     "https://archive.org/download/hacker-ii-the-doomsday-papers/Hacker_II_The_Doomsday_Papers_1986_Activision.zip" &&     unzip -q /tmp/hacker2.zip -d "$DOSDIR/hacker2/" &&     rm /tmp/hacker2.zip || log "Hacker II download failed"

# System Shock (1994) — Looking Glass Studios
log "System Shock (1994)..."
wget -qO /tmp/sshock.zip     "https://archive.org/download/SystemShock1994/SystemShock.zip" &&     unzip -q /tmp/sshock.zip -d "$DOSDIR/sshock/" &&     rm /tmp/sshock.zip || log "System Shock download failed"

# Cyberia (1994) — Cyberdreams
log "Cyberia (1994)..."
wget -qO /tmp/cyberia.zip     "https://archive.org/download/Cyberia_1994_Cyberdreams/Cyberia.zip" &&     unzip -q /tmp/cyberia.zip -d "$DOSDIR/cyberia/" &&     rm /tmp/cyberia.zip || log "Cyberia download failed"

# SATAN 1.1.1 (1995) — Cheswick & Farmer network scanner
log "SATAN 1.1.1 (1995)..."
wget -qO /tmp/satan.tar.gz     "https://simson.net/ref/1995/satan.tar.gz" &&     tar -xzf /tmp/satan.tar.gz -C "$DOSDIR/" &&     rm /tmp/satan.tar.gz || log "SATAN download failed"

# ToneLoc v1.10 (1994) — war dialer
log "ToneLoc v1.10..."
wget -qO "$DOSDIR/TONELOCK.ZIP"     "https://archive.org/download/tonelocv110/TONELOCK.ZIP" &&     unzip -q "$DOSDIR/TONELOCK.ZIP" -d "$DOSDIR/toneloc/" || log "ToneLoc download failed"

log "DOS content download complete"
log "Launch DOSBox-X from the optional Games menu when those extras are enabled"
DOSSCRIPT
    chmod +x "$ROOTFS_DIR/opt/ghost/dosbox/download-games.sh"

    log "DOS content setup script installed — run after first boot with WiFi"
}

# =============================================================================
# STAGE 16j: PORTMASTER FIRST RUN SCRIPT
# =============================================================================
install_portmaster_setup() {
    if [[ "$INCLUDE_PORTMASTER" != "true" ]]; then
        warn "PortMaster setup disabled in config, skipping..."
        return
    fi

    section "Installing PortMaster First Run Script"

    mkdir -p "$ROOTFS_DIR/opt/ghost"
    cat > "$ROOTFS_DIR/opt/ghost/portmaster-setup.sh" << 'PMSCRIPT'
#!/usr/bin/env bash
# ghOSt PortMaster Game Setup
# Run after first boot with internet connection

log() { echo "[portmaster] $*"; }

PMDIR="/opt/portmaster"
PORTSDIR="$PMDIR/ports"

[[ -d "$PMDIR" ]] || { log "PortMaster not installed"; exit 1; }

log "Updating PortMaster..."
cd "$PMDIR" && python3 PortMaster.py --update 2>/dev/null || true

log "Installing free games..."

# Cave Story (freeware original)
python3 "$PMDIR/PortMaster.py" --install "Cave Story" || true

# Quake (shareware ep1 — free)
python3 "$PMDIR/PortMaster.py" --install "Quake" || true

# Doom (shareware — free)
python3 "$PMDIR/PortMaster.py" --install "DOOM" || true

# Tyrian 2000 (freeware)
python3 "$PMDIR/PortMaster.py" --install "Tyrian 2000" || true

# Cataclysm: Dark Days Ahead (free, open source)
python3 "$PMDIR/PortMaster.py" --install "Cataclysm DDA" || true

# NetHack (free, open source)
python3 "$PMDIR/PortMaster.py" --install "NetHack" || true

# Zork Trilogy (freeware Infocom releases)
python3 "$PMDIR/PortMaster.py" --install "Zork I" || true
python3 "$PMDIR/PortMaster.py" --install "Zork II" || true
python3 "$PMDIR/PortMaster.py" --install "Zork III" || true

# Decker (cyberpunk hacking RPG — free on itch.io)
python3 "$PMDIR/PortMaster.py" --install "Decker" || true

# Commander Keen 4 (freeware episode)
python3 "$PMDIR/PortMaster.py" --install "Commander Keen" || true

# Rockbox (music player via PortMaster)
python3 "$PMDIR/PortMaster.py" --install "Rockbox" || true

log "PortMaster game installation complete"
PMSCRIPT
    chmod +x "$ROOTFS_DIR/opt/ghost/portmaster-setup.sh"

    log "PortMaster setup script installed — run after first boot with WiFi"
}

# =============================================================================
# STAGE 16k: SCREEN LOCK CONFIG
# =============================================================================
install_screenlock() {
    section "Configuring Screen Lock"

    # swayidle config — auto lock after 5 minutes
    mkdir -p "$ROOTFS_DIR/home/$GHOST_USER/.config/swayidle"
    mkdir -p "$ROOTFS_DIR/home/$GHOST_USER/.config/swaylock"
    cat > "$ROOTFS_DIR/home/$GHOST_USER/.config/swayidle/config" << 'EOF'
timeout 300 'swaylock -f -c 000000 --indicator-radius 50'
timeout 600 'wlopm --off \*' resume 'wlopm --on \*'
before-sleep 'swaylock -f -c 000000'
EOF

    # swaylock config — minimal black screen lock
    cat > "$ROOTFS_DIR/home/$GHOST_USER/.config/swaylock/config" << 'EOF'
color=1e1e2e
inside-color=1e1e2e
ring-color=89b4fa
key-hl-color=a6e3a1
text-color=cdd6f4
line-color=1e1e2e
font=Terminus
indicator-radius=50
indicator-thickness=8
show-failed-attempts
EOF

    log "Screen lock configured"
}

# =============================================================================
# STAGE 16l: GHOST UPDATE SCRIPT
# =============================================================================
install_update_script() {
    section "Installing ghOSt Update Script"

    mkdir -p "$ROOTFS_DIR/usr/local/bin"
    cat > "$ROOTFS_DIR/usr/local/bin/ghost-update" << 'UPDATESCRIPT'
#!/usr/bin/env bash
# ghOSt Update Script
# Updates system packages, Python tools, and git-based tools

set -euo pipefail

RED='[0;31m'
GREEN='[0;32m'
CYAN='[0;36m'
NC='[0m'

log()     { echo -e "${GREEN}[update]${NC} $*"; }
section() { echo -e "
${CYAN}--- $* ---${NC}
"; }

section "System Packages"
sudo apt-get update -qq
sudo apt-get upgrade -y
sudo apt-get autoremove -y

section "Python Tools"
pip3 install --upgrade     mitmproxy pwntools scapy impacket     bettercap maigret holehe sherlock-project     frida-tools objection androguard     yt-dlp --break-system-packages 2>/dev/null || true

section "Git-based Tools"
for repo in     /opt/ghost/intercept     /opt/ghost/spiderfoot     /opt/ghost/airgeddon     /opt/ghost/nishang     /opt/ghost/powersploit     /opt/ghost/pwndbg     /opt/ghost/routersploit; do
    if [[ -d "$repo/.git" ]]; then
        log "Updating $(basename $repo)..."
        git -C "$repo" pull --ff-only 2>/dev/null || true
    fi
done

section "Wordlists"
log "Checking for SecLists updates..."
git -C /opt/wordlists/seclists pull --ff-only 2>/dev/null || true

section "ghOSt Update Complete"
echo -e "${GREEN}System is up to date${NC}"
UPDATESCRIPT
    chmod +x "$ROOTFS_DIR/usr/local/bin/ghost-update"

    log "ghost-update script installed"
}

# =============================================================================
# STAGE 16m: MAKO NOTIFICATION CONFIG
# =============================================================================
install_notifications() {
    section "Configuring Notifications"

    mkdir -p "$ROOTFS_DIR/home/$GHOST_USER/.config/mako"
    cat > "$ROOTFS_DIR/home/$GHOST_USER/.config/mako/config" << 'EOF'
# ghOSt mako notification config — Catppuccin Mocha
sort=-time
layer=overlay
background-color=#1e1e2e
text-color=#cdd6f4
border-color=#89b4fa
border-radius=8
border-size=2
default-timeout=5000
max-visible=3
width=280
height=100
margin=8
padding=8
font=Terminus 11

[urgency=high]
border-color=#f38ba8
default-timeout=0
EOF

    # Enable mako in GUI startup
    local gui_service="$ROOTFS_DIR/etc/systemd/system/ghost-gui.service"
    if [[ -f "$gui_service" ]]; then
        sed -i 's|ExecStart=|ExecStartPost=/usr/bin/mako \&
ExecStart=|'             "$gui_service" 2>/dev/null || true
    fi

    log "Notifications configured"
}

# =============================================================================
# STAGE 17: FINAL CLEANUP
# =============================================================================
cleanup() {
    section "Cleanup"

    $CHROOT apt-get autoremove -y
    $CHROOT apt-get autoclean
    $CHROOT bash -c "find /var/cache/apt -type f -delete"
    $CHROOT bash -c "find /tmp -mindepth 1 -delete 2>/dev/null || true"
    $CHROOT bash -c "find /var/log -type f -exec truncate -s 0 {} \;"

    # Remove qemu static
    rm -f "$ROOTFS_DIR/usr/bin/qemu-aarch64-static"

    local rootfs_size
    rootfs_size=$(du -sh \
        --exclude="$ROOTFS_DIR/dev" \
        --exclude="$ROOTFS_DIR/proc" \
        --exclude="$ROOTFS_DIR/run" \
        --exclude="$ROOTFS_DIR/sys" \
        "$ROOTFS_DIR" 2>/dev/null | cut -f1)
    [[ -n "$rootfs_size" ]] || rootfs_size="unknown"
    log "Rootfs size: $rootfs_size"
}

# =============================================================================
# RUN ALL STAGES
# =============================================================================
debootstrap_stage
mount_chroot_fs
recover_rootfs_state
configure_apt
install_base
install_shell
install_gui
install_remote
install_vpn
install_sdr
install_security
install_wordlists
install_tui
install_ai
install_gaming
install_compat
install_cyberchef
install_power
install_display
install_controllers
install_firmware
install_gps
install_modem
install_camera
install_android
install_ux
install_security_extras
install_dos_content
install_portmaster_setup
install_screenlock
install_update_script
install_notifications
cleanup

log "Rootfs build complete"
