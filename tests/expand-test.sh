#!/usr/bin/env bash
# =============================================================================
# ghost-expand-fs.sh — first-boot root expansion
#
# The script is exercised as a rewritten copy: DONE_FILE and LOG point into a
# temporary directory, its block-device test becomes a non-empty test, and
# findmnt/growpart/resize2fs/partprobe/blockdev/df are stubs, because /var and
# block devices are not usable from the host that runs the suite. Everything
# this checks is control flow: when the filesystem is resized, when the flag is
# written, and that a second run is a no-op.
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/overlay/usr/local/bin/ghost-expand-fs.sh"
TMP="$(mktemp -d)"

pass=0
fail=0
ok() { printf '  ok    %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$*"; fail=$((fail + 1)); }
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

[[ -f "$SRC" ]] || { echo "  FAIL  $SRC is missing"; exit 1; }

BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/findmnt" << 'EOF'
#!/bin/sh
printf '%s\n' "${FINDMNT_SOURCE:-/dev/mmcblk0p2}"
EOF
cat > "$BIN/growpart" << 'EOF'
#!/bin/sh
printf 'NOCHANGE: partition 2 is already the size of the disk\n' >&2
exit "${GROWPART_RC:-2}"
EOF
cat > "$BIN/parted" << 'EOF'
#!/bin/sh
exit "${PARTED_RC:-0}"
EOF
cat > "$BIN/resize2fs" << 'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RESIZE_LOG"
EOF
cat > "$BIN/df" << 'EOF'
#!/bin/sh
printf 'Filesystem      Size  Used Avail Use%% Mounted on\n'
printf '/dev/mmcblk0p2  110G   9G  100G   9%% /\n'
EOF
for stub in partprobe blockdev sleep; do
    printf '#!/bin/sh\nexit 0\n' > "$BIN/$stub"
done
chmod +x "$BIN"/*

sed -e "s|^DONE_FILE=.*|DONE_FILE=\"$TMP/state/.fs_expanded\"|" \
    -e "s|^LOG=.*|LOG=\"$TMP/expand.log\"|" \
    -e 's|\[\[ ! -b "$ROOT_PART" \]\]|[[ -z "$ROOT_PART" ]]|' \
    "$SRC" > "$TMP/expand.sh"
chmod +x "$TMP/expand.sh"

# The rewritten block-device test must actually be in the copy, or every case
# below would pass trivially because the script never reaches the resize.
grep -q '\[\[ -z "$ROOT_PART" \]\]' "$TMP/expand.sh" \
    && ok "harness rewrote the block-device test" \
    || { bad "harness could not rewrite the block-device test"; exit 1; }

RESIZE_LOG="$TMP/resize.log"
: > "$RESIZE_LOG"

run() {
    PATH="$BIN:$PATH" RESIZE_LOG="$RESIZE_LOG" "$@" bash "$TMP/expand.sh" \
        > "$TMP/out" 2>&1
}
resizes() { wc -l < "$RESIZE_LOG" | tr -d ' '; }

# --- 1. partition already fills the card (growpart rc 2) ---------------------
run env
rc=$?
if [[ $rc -eq 0 ]]; then
    ok "exits 0 when the partition needs no growth"
else
    bad "exits 0 when the partition needs no growth (got $rc)"
fi
[[ "$(resizes)" == "1" ]] \
    && ok "resizes the filesystem even when the partition did not move" \
    || bad "resizes the filesystem even when the partition did not move (resize2fs ran $(resizes)x)"
[[ -f "$TMP/state/.fs_expanded" ]] \
    && ok "writes the idempotence flag" \
    || bad "writes the idempotence flag"

# --- 2. second run is a no-op ------------------------------------------------
run env
rc=$?
[[ $rc -eq 0 && "$(resizes)" == "1" ]] \
    && ok "second run exits 0 without touching the filesystem again" \
    || bad "second run must be a no-op (exit $rc, resize2fs ran $(resizes)x)"

# --- 3. a real growpart failure is fatal and leaves no flag ------------------
rm -f "$TMP/state/.fs_expanded"
before="$(resizes)"
run env GROWPART_RC=1
rc=$?
[[ $rc -ne 0 ]] \
    && ok "fails when growpart fails" \
    || bad "fails when growpart fails (exit $rc)"
[[ "$(resizes)" == "$before" ]] \
    && ok "does not resize after a failed grow" \
    || bad "does not resize after a failed grow"
[[ ! -f "$TMP/state/.fs_expanded" ]] \
    && ok "leaves the flag unset after a failure so the next boot retries" \
    || bad "leaves the flag unset after a failure so the next boot retries"

# --- 4. without growpart, parted grows and the filesystem is resized --------
NOPART="$TMP/nogrow"
mkdir -p "$NOPART"
for stub in findmnt parted resize2fs df partprobe blockdev sleep; do
    cp "$BIN/$stub" "$NOPART/$stub"
done
chmod +x "$NOPART"/*
rm -f "$TMP/state/.fs_expanded"
: > "$RESIZE_LOG"
PATH="$NOPART:/usr/bin:/bin" RESIZE_LOG="$RESIZE_LOG" bash "$TMP/expand.sh" > "$TMP/out" 2>&1
rc=$?
[[ $rc -eq 0 && "$(resizes)" == "1" ]] \
    && ok "falls back to parted and still resizes the filesystem" \
    || bad "falls back to parted and still resizes the filesystem (exit $rc, resize2fs ran $(resizes)x)"

# --- 5. an unknown partition naming is refused before anything runs --------
rm -f "$TMP/state/.fs_expanded"
: > "$RESIZE_LOG"
run env FINDMNT_SOURCE=/dev/weird0p2
rc=$?
[[ $rc -ne 0 ]] \
    && ok "refuses an unrecognised partition name" \
    || bad "refuses an unrecognised partition name (exit $rc)"
[[ "$(resizes)" == "0" && ! -f "$TMP/state/.fs_expanded" ]] \
    && ok "touches nothing when the disk cannot be derived" \
    || bad "touches nothing when the disk cannot be derived"

echo
if [[ $fail -eq 0 ]]; then
    echo "  expand: $pass checks passed"
    exit 0
fi
echo "  expand: $fail of $((pass + fail)) checks failed"
exit 1
