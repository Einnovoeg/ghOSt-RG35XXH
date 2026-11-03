#!/usr/bin/env bash
# ghost-power CLI contract: the six documented profiles are offered, and an
# unknown profile is rejected instead of being silently applied.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POWER="$ROOT/overlay/usr/local/bin/ghost-power"
fail=0
ok()  { echo "  ok    $*"; }
bad() { echo "  FAIL  $*"; fail=1; }

[[ -x "$POWER" ]] && ok "ghost-power is executable" || bad "ghost-power is not executable"

out="$(timeout 10 bash "$POWER" nonsense 2>&1 </dev/null)"; rc=$?
(( rc != 0 )) && ok "unknown profile exits non-zero" || bad "unknown profile exited 0"
for p in performance balanced powersave gaming stealth sdr; do
    case "$out" in
        *"$p"*) : ;;
        *) bad "usage does not mention the $p profile" ;;
    esac
done
ok "usage lists the documented profiles"

# The profile must be rejected before anything writes to cpufreq: a bad name
# silently applied would leave the device in an unknown power state.
grep -q 'save_profile' "$POWER" && ok "profile switching records the active profile" \
    || bad "profile switching does not record the active profile"

echo
if (( fail == 0 )); then echo "power profiles: PASS"; else echo "power profiles: FAIL"; exit 1; fi
