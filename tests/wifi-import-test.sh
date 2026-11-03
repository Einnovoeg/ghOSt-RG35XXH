#!/usr/bin/env bash
# Behaviour test for ghost-wifi-import: importing wifi.txt from the boot partition
# and blanking the password. nmcli and iw are stubbed, so no radio is needed.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
fail=0
ok()  { echo "  ok    $*"; }
bad() { echo "  FAIL  $*"; fail=1; }

H="$(mktemp -d)"; trap 'rm -rf "$H"' EXIT
mkdir -p "$H/bin"

cat > "$H/bin/nmcli" <<'EOS'
#!/bin/sh
echo "nmcli $*" >> "$NM_LOG"
case "$*" in
  "-t -f NAME connection show") echo "wifi-Existing" ;;
  *"connection add"*) [ "${NM_FAIL:-0}" = "1" ] && exit 1 ;;
esac
exit 0
EOS
printf '#!/bin/sh\nexit 0\n' > "$H/bin/iw"
chmod +x "$H/bin"/*
export PATH="$H/bin:$PATH" NM_LOG="$H/nm.log"
: > "$NM_LOG"

WIFI="$H/wifi.txt"
# CRLF and a BOM, as written from Windows
printf '\xEF\xBB\xBFS S I D = 0\r' > /dev/null 2>&1 || true
printf 'SSID = TestNet\r\nPASSWORD = secret123\r\nCOUNTRY = US\r\n' > "$WIFI"

run() { WIFI_FILE="$WIFI" NMCLI="$H/bin/nmcli" IW="$H/bin/iw" bash overlay/usr/local/sbin/ghost-wifi-import; }

run >/dev/null 2>&1; rc=$?
(( rc == 0 )) && ok "import succeeds" || bad "import exited $rc"
grep -q 'TestNet' "$NM_LOG" && ok "SSID handed to NetworkManager" || bad "SSID never reached nmcli"
grep -q 'wifi-sec.psk secret123' "$NM_LOG" && ok "password handed to NetworkManager" || bad "password not passed"
grep -q 'PASSWORD=$' "$WIFI" && ok "password blanked in wifi.txt" || bad "password still in wifi.txt"
grep -q '^# imported' "$WIFI" && ok "import noted in the file" || bad "no import marker"
grep -qi $'\r' "$WIFI" && bad "CRLF left behind" || ok "written back with clean line endings"

# NetworkManager refuses the settings (short WPA password): the old password must
# stay in the file so the user can fix it instead of losing it silently.
printf 'SSID = OtherNet\r\nPASSWORD = x\r\n' > "$WIFI"
: > "$NM_LOG"
NM_FAIL=1 run >/dev/null 2>&1; rc=$?
(( rc != 0 )) && ok "refusal reported as failure" || bad "refusal looked like success"
grep -q 'PASSWORD = x' "$WIFI" && ok "password kept when the import is refused" || bad "password lost on refusal"

# Nothing to import: an empty SSID must not touch NetworkManager at all.
printf 'COUNTRY = US\r\n' > "$WIFI"
: > "$NM_LOG"
run >/dev/null 2>&1; rc=$?
(( rc == 0 )) && ok "empty SSID is a no-op" || bad "empty SSID exited $rc"
grep -q 'connection add' "$NM_LOG" && bad "created a connection without an SSID" || ok "no connection created without an SSID"

echo
if (( fail == 0 )); then echo "wifi import: PASS"; else echo "wifi import: FAIL"; exit 1; fi
