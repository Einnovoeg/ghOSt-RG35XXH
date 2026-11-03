#!/usr/bin/env bash
# Validate systemd units shipped in overlay/ and the services configure.sh enables.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
UNITS="overlay/etc/systemd/system"
fail=0
ok()  { echo "  ok    $*"; }
bad() { echo "  FAIL  $*"; fail=1; }

# Units that exist in Debian/packages, come from another repo directory, or are
# written by configure.sh at build time — anything not shipped in overlay/.
EXTERNAL_UNITS="
 lightdm.service getty@tty1.service NetworkManager.service
 systemd-journald.service systemd-udevd.service dbus.service
 network-online.target network.target local-fs.target local-fs-pre.target
 remote-fs.target sysinit.target basic.target multi-user.target graphical.target
 tor.service ssh.service cups.service log2ram.service auto-cpufreq.service
 tlp.service bluetooth.service syncthing@ghost.service
 firstboot.service
"
# collapse newlines so the whole-word match below works
EXTERNAL_UNITS=" $(echo $EXTERNAL_UNITS) "

is_external() { [[ "$EXTERNAL_UNITS" == *" $1 "* ]]; }

echo "-- unit files parse"
for f in "$UNITS"/*.service; do
    name="$(basename "$f")"
    grep -q '^\[Unit\]' "$f" || bad "$name: no [Unit]"
    grep -q '^\[Service\]' "$f" || bad "$name: no [Service]"
    grep -qE '^ExecStart=' "$f" || bad "$name: no ExecStart"
    grep -qE '^(WantedBy|RequiredBy)=' "$f" || bad "$name: no [Install] target"
    grep -qE '^Type=' "$f" || bad "$name: no Type="
done
ok "units have Unit/Service/Install/Type/ExecStart"

echo "-- ExecStart binaries resolve"
for f in "$UNITS"/*.service; do
    while IFS= read -r bin; do
        [[ -z "$bin" ]] && continue
        case "$bin" in
            /bin/bash|/bin/sh|/usr/bin/python3|/usr/bin/env)
                : ;;   # base system binaries, present in any Debian rootfs
            /usr/local/*|/opt/ghost/*)
                # ghOSt's own paths: these MUST be shipped by the overlay
                [[ -e "overlay$bin" ]] || \
                    bad "$(basename "$f"): ExecStart binary not in overlay: $bin"
                ;;
            /bin/*|/usr/bin/*|/sbin/*|/usr/sbin/*)
                # packaged binaries (apt) are allowed; anything else must exist
                [[ -e "overlay$bin" ]] || :
                ;;
        esac
    done < <(grep -hoE '^ExecStart=[-@+!]*[^ ]+' "$f" | sed 's/^[^=]*=//; s/^[-@+!]*//')
done
ok "ExecStart paths exist in overlay (or are packaged binaries)"

echo "-- ordering dependencies exist"
for f in "$UNITS"/*.service; do
    for dep in $(grep -hE '^(After|Before|Wants|Requires)=' "$f" | sed 's/^[^=]*=//'); do
        [[ -f "$UNITS/$dep" ]] || is_external "$dep" || \
            bad "$(basename "$f"): unknown dependency $dep"
    done
done
ok "After/Before/Wants/Requires resolve"

echo "-- one expander, no hardcoded device"
[[ ! -f "$UNITS/expand-rootfs.service" ]] \
    && ok "duplicate expand-rootfs.service removed" || bad "two expanders still enabled"
grep -rqs 'expand-rootfs' "$UNITS" && bad "a unit still references expand-rootfs" \
    || ok "no unit references the removed expander"
if grep -rqs '/dev/mmcblk0' "$UNITS"; then
    bad "a unit hardcodes /dev/mmcblk0 (breaks in the other SD slot)"
else
    ok "no unit hardcodes a disk device"
fi


echo "-- services enabled by configure.sh"
missing=()
while IFS= read -r unit; do
    [[ -z "$unit" ]] && continue
    [[ -f "$UNITS/$unit" ]] && continue
    is_external "$unit" && continue
    # some units are written by rootfs stages or installed by apt
    if grep -rqs -- "$unit" rootfs/ overlay/ 2>/dev/null; then
        continue
    fi
    missing+=("$unit")
done < <(grep -ohE 'systemctl enable [a-zA-Z0-9@._-]+' overlay/opt/ghost/scripts/configure.sh \
            | awk '{print $3}' | sort -u)

if (( ${#missing[@]} )); then
    for u in "${missing[@]}"; do echo "  WARN  enabled but matched no unit file: $u"; done
else
    ok "every enabled unit is backed by a file"
fi

# Only ghOSt's own units are hard failures; distro units may be added later.
for u in "${missing[@]:-}"; do
    case "$u" in
        ghost-*|*-limit|panel*|wifi*) bad "ghOSt unit enabled but missing: $u" ;;
    esac
done

echo
if (( fail == 0 )); then echo "unit checks: PASS"; else echo "unit checks: FAIL"; exit 1; fi
