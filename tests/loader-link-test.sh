#!/usr/bin/env bash
# =============================================================================
# ghOSt — ARM64 loader link repair
#
# ensure_arm64_loader_link() runs before every chroot. It used to `rm -rf`
# /lib/aarch64-linux-gnu whenever that directory held no loader; under usrmerge
# /lib is a symlink to usr/lib, so the command deleted the real multiarch libdir
# and every subsequent chroot died with "Could not open
# '/lib/ld-linux-aarch64.so.1'" and exit 255. These cases pin the behaviour:
# create missing links, never remove data, and leave an unusable rootfs alone.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/rootfs/build-rootfs.sh"
PASS=0
FAIL=0

ok()  { echo "  ok    $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

if [[ ! -f "$BUILD" ]]; then
    bad "rootfs/build-rootfs.sh is missing"
    echo "loader-link: $PASS checks passed, $FAIL failed"
    exit 1
fi

FN="$(sed -n '/^ensure_arm64_loader_link() {/,/^}/p' "$BUILD")"
if [[ -z "$FN" ]]; then
    bad "ensure_arm64_loader_link() not found in build-rootfs.sh"
    echo "loader-link: $PASS checks passed, $FAIL failed"
    exit 1
fi
ok "ensure_arm64_loader_link() is defined"

WARNINGS=""
warn() { WARNINGS="$WARNINGS$1"$'\n'; }

# Run the extracted function against a fixture rootfs.
run_fix() {
    ROOTFS_DIR="$1" WARNINGS="" bash -c "warn() { :; }; $FN; ensure_arm64_loader_link"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- case 1: usrmerge layout, /lib -> usr/lib -------------------------------
R1="$WORK/usrmerge"
mkdir -p "$R1/usr/lib/aarch64-linux-gnu"
: > "$R1/usr/lib/ld-linux-aarch64.so.1"
: > "$R1/usr/lib/aarch64-linux-gnu/libc.so.6"
ln -s usr/lib "$R1/lib"
run_fix "$R1"

if [[ -f "$R1/usr/lib/aarch64-linux-gnu/libc.so.6" ]]; then
    ok "usrmerge: the real multiarch libdir survives"
else
    bad "usrmerge: the multiarch libdir was deleted through the /lib symlink"
fi
if [[ -e "$R1/lib/ld-linux-aarch64.so.1" ]]; then
    ok "usrmerge: /lib/ld-linux-aarch64.so.1 resolves"
else
    bad "usrmerge: /lib/ld-linux-aarch64.so.1 does not resolve"
fi

# --- case 2: split layout, loader only under /usr/lib ----------------------
R2="$WORK/split"
mkdir -p "$R2/lib/aarch64-linux-gnu" "$R2/usr/lib"
: > "$R2/lib/aarch64-linux-gnu/libc.so.6"
: > "$R2/usr/lib/ld-linux-aarch64.so.1"
run_fix "$R2"

if [[ -f "$R2/lib/aarch64-linux-gnu/libc.so.6" ]]; then
    ok "split: existing libc survives"
else
    bad "split: existing libc was removed"
fi
if [[ -L "$R2/lib/ld-linux-aarch64.so.1" ]] && [[ -e "$R2/lib/ld-linux-aarch64.so.1" ]]; then
    ok "split: /lib/ld-linux-aarch64.so.1 links to the loader"
else
    bad "split: no working /lib/ld-linux-aarch64.so.1"
fi

# --- case 3: loader only in the multiarch dir -----------------------------
R3="$WORK/multiarch"
mkdir -p "$R3/lib/aarch64-linux-gnu"
: > "$R3/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1"
run_fix "$R3"

if [[ -e "$R3/lib/ld-linux-aarch64.so.1" ]]; then
    ok "multiarch: the loader in /lib/aarch64-linux-gnu is linked"
else
    bad "multiarch: the loader was not linked"
fi

# --- case 4: /lib is real, multiarch dir absent ---------------------------
R4="$WORK/mkdir"
mkdir -p "$R4/lib" "$R4/usr/lib/aarch64-linux-gnu"
: > "$R4/usr/lib/ld-linux-aarch64.so.1"
run_fix "$R4"

if [[ -e "$R4/lib/aarch64-linux-gnu" ]]; then
    ok "mkdir: a missing multiarch path is linked into /usr/lib"
else
    bad "mkdir: the multiarch path was not created"
fi

# --- case 5: no loader anywhere, nothing may be deleted -------------------
R5="$WORK/noloader"
mkdir -p "$R5/lib/aarch64-linux-gnu"
: > "$R5/lib/aarch64-linux-gnu/libc.so.6"
if run_fix "$R5" 2>/dev/null; then
    ok "no loader: the function still succeeds (a later stage stages the loader)"
else
    bad "no loader: the function failed instead of leaving the rootfs alone"
fi
if [[ -f "$R5/lib/aarch64-linux-gnu/libc.so.6" ]]; then
    ok "no loader: the rootfs is untouched"
else
    bad "no loader: files were removed"
fi

# --- static guards --------------------------------------------------------
if sed -n '/^ensure_arm64_loader_link() {/,/^}/p' "$BUILD" | grep -q 'rm -rf'; then
    bad "the loader repair removes directories again"
else
    ok "the loader repair never removes a directory"
fi

RECOVER="$(sed -n '/^recover_rootfs_state() {/,/^}/p' "$BUILD")"
if printf '%s\n' "$RECOVER" | grep -q 'CHROOT true'; then
    ok "cached-rootfs recovery proves the chroot runs before using it"
else
    bad "cached-rootfs recovery chroots without a preflight"
fi

echo "loader-link: $PASS checks passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
