#!/usr/bin/env bash
# =============================================================================
# ghOSt RAM Audit & Constraints
# Applied in configure.sh to ensure 1GB RAM discipline
#
# Budget at steady state (target: <600MB used, leaving 400MB for tools):
#   Cage compositor:    ~8MB
#   fish + tmux:        ~12MB
#   pipewire:           ~15MB
#   NetworkManager:     ~12MB
#   zram daemon:        ~2MB
#   bluetooth:          ~8MB
#   tor:                ~25MB
#   dnscrypt-proxy:     ~15MB
#   log2ram:            ~2MB
#   syncthing:          ~40MB  ← heaviest always-on service
#   intercept:          ~35MB
#   stealthd:           ~5MB
#   ─────────────────────────
#   Base overhead:      ~179MB
#   Available for tools: ~821MB (before zram compression)
#   With 50% zram lz4:  effectively ~1.3GB usable
#
# Problem apps (too heavy for 1GB, removed or constrained):
#   MobSF:          ~400MB+ (Java/Django) — REMOVED, replaced by androguard
#   Metasploit:     ~500MB+ at rest      — CONSTRAINED: msfconsole only, no GUI
#   spiderfoot:     ~120MB               — CONSTRAINED: isolated venv wrapper
#   kismet:         ~80MB                — CONSTRAINED: headless only
#   wireshark GUI:  ~200MB               — REMOVED: termshark used instead ✅
#   GNU Radio:      ~600MB+              — REMOVED ✅
#   Ghidra:         ~1GB+                — REMOVED: radare2 used instead ✅
#   Bloodhound:     ~400MB+              — REMOVED
#   autopsy:        ~800MB+              — REMOVED
#   OpenVAS:        ~300MB+              — REMOVED
#   BeEF:           ~300MB+ (Rails)      — REMOVED
#   jadx GUI:       ~200MB+              — CONSTRAINED: jadx-gui removed, jadx CLI only
#   x64dbg:         ~100MB via Wine      — OK (run on demand, not resident)
#   FEX + rootfs:   ~300MB              — OK (only active when running x86 binary)
#   Wine:           ~150MB               — OK (only active when running Windows binary)
# =============================================================================

set -euo pipefail

log() { echo "[ram-audit] $*"; }

log "Applying RAM constraints..."

# =============================================================================
# REMOVE: MobSF — too heavy (Django + static analysis engine ~400MB+)
# Replaced by androguard + apkleaks + jadx CLI which together do 90% of what
# MobSF does at a fraction of the memory
# =============================================================================
rm -rf /opt/ghost/mobsf 2>/dev/null || true
pip3 uninstall -y mobsf 2>/dev/null || true
log "MobSF removed (use androguard + apkleaks + jadx instead)"

# =============================================================================
# CONSTRAIN: Metasploit
# msfconsole loads ~500MB when active — fine as an on-demand tool
# but we disable the background postgresql service it wants
# =============================================================================
systemctl disable postgresql 2>/dev/null || true
systemctl disable metasploit 2>/dev/null || true
# msfdb (Metasploit's postgres) not auto-started — user runs manually if needed
# MSF still works without the DB, just no history/workspace persistence
cat > /etc/profile.d/msf-nodatabase.sh << 'MSF'
# ghOSt: Metasploit runs without postgresql by default to save RAM
# To enable the database: sudo systemctl start postgresql && msfdb init
export MSF_DATABASE_CONFIG=""
MSF
log "Metasploit constrained — no background postgresql"

# =============================================================================
# CONSTRAIN: SpiderFoot — keep it isolated inside its own venv wrapper
# so heavier Python dependencies do not contaminate the system toolchain.
# =============================================================================
cat > /usr/local/bin/spiderfoot << 'SF'
#!/usr/bin/env bash
# ghOSt SpiderFoot wrapper — prefer the dedicated venv, fall back gracefully.
set -euo pipefail
[[ -d /opt/ghost/spiderfoot ]] || {
    echo "SpiderFoot is not installed." >&2
    exit 1
}
cd /opt/ghost/spiderfoot
if [[ -x /opt/ghost/venvs/spiderfoot/bin/python ]]; then
    exec /opt/ghost/venvs/spiderfoot/bin/python sf.py "$@"
fi
exec python3 sf.py "$@"
SF
chmod +x /usr/local/bin/spiderfoot
log "SpiderFoot wrapper points at its dedicated venv"

# =============================================================================
# CONSTRAIN: Kismet — headless only when it is actually installed
# =============================================================================
if command -v kismet >/dev/null 2>&1; then
    mkdir -p /etc/kismet
    cat > /etc/kismet/kismet_site.conf << 'KISMET'
# ghOSt Kismet config — headless optimized for 1GB RAM
# Disable features we don't use
dot11_view_persistent_handshakes=false
kis_log_phyname_in_title=true
alertbacklog=50
packet_dedup_size=512
kis_data_components=kismet.base.device,kismet.base.signal
# Web UI disabled by default — start with: kismet --override ghost_webui
KISMET

    cat > /etc/kismet/kismet_ghost_webui.conf << 'KISMET_WEB'
# Enable web UI — loads extra ~20MB, accessible at http://localhost:2501
httpd_serve_files=true
httpd_port=2501
KISMET_WEB
    log "Kismet constrained to headless mode (web UI optional)"
else
    log "Kismet not installed; skipping headless profile"
fi

# =============================================================================
# CONSTRAIN: jadx — CLI only, remove GUI jar
# jadx-gui is a Swing app that loads ~200MB of Java heap
# =============================================================================
find /opt/ghost/jadx/ -name "jadx-gui*.jar" -delete 2>/dev/null || true
find /opt/ghost/jadx/ -name "*-gui*" -delete 2>/dev/null || true
log "jadx-gui removed (use jadx CLI: jadx -d output/ file.apk)"

# =============================================================================
# CONSTRAIN: Syncthing — reduce memory usage
# Default syncthing uses 40-80MB. With these settings: ~25MB
# =============================================================================
mkdir -p /home/ghost/.config/syncthing
cat > /home/ghost/.config/syncthing/config.xml << 'SYNC'
<configuration version="35">
  <options>
    <maxFolderConcurrency>1</maxFolderConcurrency>
    <progressUpdateIntervalS>60</progressUpdateIntervalS>
    <autoUpgradeIntervalH>0</autoUpgradeIntervalH>
    <relaysEnabled>false</relaysEnabled>
    <globalAnnounceEnabled>false</globalAnnounceEnabled>
    <localAnnounceEnabled>true</localAnnounceEnabled>
    <minHomeDiskFree unit="%">1</minHomeDiskFree>
    <databaseTuning>small</databaseTuning>
  </options>
</configuration>
SYNC
log "Syncthing constrained to low-memory mode"

# =============================================================================
# CONSTRAIN: Tor — reduce memory footprint
# Default tor uses ~25MB. With these: ~15MB
# =============================================================================
cat >> /etc/tor/torrc << 'TOR'
# ghOSt memory constraints
AvoidDiskWrites 1
CircuitBuildTimeout 10
LearnCircuitBuildTimeout 0
MaxCircuitDirtiness 600
NewCircuitPeriod 30
NumEntryGuards 1
CircuitStreamTimeout 10
TOR
log "Tor memory-constrained"

# =============================================================================
# CONSTRAIN: dnscrypt-proxy
# =============================================================================
sed -i 's/max_clients = .*/max_clients = 50/' /etc/dnscrypt-proxy/dnscrypt-proxy.toml
log "dnscrypt-proxy max clients reduced"

# =============================================================================
# CONSTRAIN: pipewire
# Reduce audio buffer sizes to save a few MB
# =============================================================================
mkdir -p /home/ghost/.config/pipewire/pipewire.conf.d
cat > /home/ghost/.config/pipewire/pipewire.conf.d/ghost-memory.conf << 'PW'
context.properties = {
    default.clock.quantum        = 1024
    default.clock.min-quantum    = 512
    default.clock.max-quantum    = 2048
    mem.mlock-all                = false
}
PW
log "pipewire buffer constrained"

# =============================================================================
# SET SYSTEMD MEMORY LIMITS on heavy services
# Prevents any single service from eating all RAM
# =============================================================================

# Intercept capped at 100MB
mkdir -p /etc/systemd/system/intercept.service.d
cat > /etc/systemd/system/intercept.service.d/memory.conf << 'SYSD'
[Service]
MemoryMax=100M
MemorySwapMax=200M
SYSD

# Syncthing capped at 80MB
mkdir -p /etc/systemd/system/syncthing@ghost.service.d
cat > /etc/systemd/system/syncthing@ghost.service.d/memory.conf << 'SYSD'
[Service]
MemoryMax=80M
MemorySwapMax=150M
SYSD

# Tor capped at 60MB
mkdir -p /etc/systemd/system/tor.service.d
cat > /etc/systemd/system/tor.service.d/memory.conf << 'SYSD'
[Service]
MemoryMax=60M
MemorySwapMax=100M
SYSD

# dnscrypt capped at 30MB
mkdir -p /etc/systemd/system/dnscrypt-proxy.service.d
cat > /etc/systemd/system/dnscrypt-proxy.service.d/memory.conf << 'SYSD'
[Service]
MemoryMax=30M
SYSD

log "Systemd memory caps applied to all background services"

# =============================================================================
# KERNEL OOM SCORE TUNING
# Ensure tools get killed before critical system processes if OOM hits
# =============================================================================
cat > /etc/systemd/system/ghost-oom-tune.service << 'OOM'
[Unit]
Description=ghOSt OOM score tuning
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
    # Low score = protected from OOM killer \
    echo -500 > /proc/$(pgrep -x NetworkManager | head -1)/oom_score_adj 2>/dev/null || true; \
    echo -500 > /proc/$(pgrep -x systemd | head -1)/oom_score_adj 2>/dev/null || true; \
    echo -300 > /proc/$(pgrep -x cage | head -1)/oom_score_adj 2>/dev/null || true; \
    # High score = kill these first if OOM \
    echo 500 > /proc/$(pgrep -x syncthing | head -1)/oom_score_adj 2>/dev/null || true; \
    echo 300 > /proc/$(pgrep -x tor | head -1)/oom_score_adj 2>/dev/null || true;'

[Install]
WantedBy=multi-user.target
OOM
systemctl enable ghost-oom-tune.service

log "OOM tuning configured"
log "RAM audit and constraints complete"
