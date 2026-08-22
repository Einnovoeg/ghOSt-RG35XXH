# ghOSt — Docker Build Guide
## Windows & macOS Quick Start

---

## Prerequisites

### Windows
1. Install **Docker Desktop for Windows**
   - https://www.docker.com/products/docker-desktop/
   - During install, enable WSL2 backend when prompted
   - After install, open Docker Desktop → Settings → Resources
     - **CPUs:** set to at least half your cores (e.g. 8 of 16)
     - **Memory:** set to at least 6GB
     - **Disk image size:** set to at least 80GB ← critical
   - Click Apply & Restart

2. Install **Balena Etcher** for flashing
   - https://etcher.balena.io/

### macOS
1. Install **Docker Desktop for Mac**
   - https://www.docker.com/products/docker-desktop/
   - Apple Silicon (M1/M2/M3): download the Apple Silicon version
   - After install: Docker Desktop → Settings → Resources
     - **CPUs:** half your cores
     - **Memory:** 6GB+
     - **Disk image size:** 80GB+ ← critical
   - Click Apply & Restart

2. Install **Balena Etcher** for flashing
   - https://etcher.balena.io/

---

## Build Instructions

### Option A — Docker Compose (easiest)

```bash
# 1. Extract the ghOSt zip you downloaded

# 2. Open Terminal (Mac) or PowerShell/CMD (Windows) in the ghOSt folder

# 3. Create output folder
mkdir output

# 4. Build (takes 4-6 hours, leave it running)
docker compose up --build

# 5. Watch the output — your image appears in ./output/ when done
```

### Option B — docker run (manual)

```bash
# Build the container image first (one time)
docker build -t ghost-rg35xxh-builder:latest .

# Create output folder
mkdir output

# Run the build
docker run --privileged \
  -v "$(pwd)/output:/opt/ghost-build/output" \
  ghost-rg35xxh-builder:latest build
```

### Windows PowerShell version of Option B
```powershell
mkdir output
docker build -t ghost-rg35xxh-builder:latest .
docker run --privileged `
  -v "${PWD}/output:/opt/ghost-build/output" `
  ghost-rg35xxh-builder:latest build
```

---

## Monitoring the Build

In a separate terminal window while the build is running:

```bash
docker compose logs -f ghost-builder
docker compose ps
```

---

## Customising Before Build

Edit `config.sh` before running `docker compose up --build`:

```bash
KALI_SIZE="default"     # "default" = ~5GB tools, "large" = ~9GB tools
GAMES_PROFILE="lean"    # keep gaming extras secondary by default
INCLUDE_AI=true         # whisper.cpp + piper TTS
INCLUDE_FEX=false       # optional x86 emulation
INCLUDE_WINE=false      # optional Windows app compatibility
INCLUDE_PORTMASTER=false
INCLUDE_DOSBOX=false
INCLUDE_WORDLISTS=true  # rockyou + seclists
GHOST_TIMEZONE="UTC"    # Change to your timezone e.g. America/New_York
```

Or override via `docker-compose.yml` environment section without editing files:
```yaml
environment:
  - KALI_SIZE=large
  - GHOST_TIMEZONE=America/New_York
  - INCLUDE_PORTMASTER=true
```

---

## Check Build Environment (optional pre-flight)

```bash
docker run --privileged ghost-rg35xxh-builder:latest check
```

---

## Interactive Shell (for debugging or manual steps)

```bash
docker run --privileged \
  -v "$(pwd)/output:/opt/ghost-build/output" \
  -it ghost-rg35xxh-builder:latest shell
```

---

## Flashing the Image

When the build finishes, `./output/ghOSt-RG35XXH-1.0.0.img.gz` appears.

### Windows — Balena Etcher
1. Open Balena Etcher
2. Click **Flash from file** → select the `.img.gz` file
3. Select your SD card
4. Click **Flash**

### macOS — Balena Etcher
Same as above.

### macOS — Terminal (faster)
```bash
# Find your SD card device
diskutil list

# Flash (replace diskN with your SD card, e.g. disk4)
diskutil unmountDisk /dev/diskN
gunzip -c output/ghOSt-RG35XXH-1.0.0.img.gz | \
  sudo dd of=/dev/rdiskN bs=4m status=progress
diskutil eject /dev/diskN
```

Use `/dev/rdiskN` not `/dev/diskN` on Mac — the `r` prefix is 3-4x faster.

---

## Troubleshooting

### "not enough disk space" during build
Docker Desktop's virtual disk is too small.
- Docker Desktop → Settings → Resources → Disk image size → set to 100GB
- Click Apply & Restart
- Delete old containers: `docker system prune -a`
- Try again

### Build fails on kernel compilation
Usually a network issue downloading the KNULLI source. Re-run and it will resume:
```bash
docker compose up --build
```
The build scripts are designed to skip already-completed steps.

### "operation not permitted" / loop device errors
Container needs `--privileged`. If using `docker compose`, this is already set.
If running manually, make sure you included `--privileged` in your command.

### Very slow on Mac with Apple Silicon
The compose file now uses your host Docker architecture by default, so Apple
Silicon Macs run a native ARM64 builder instead of an emulated x86_64 one.
OrbStack can still improve disk and networking performance on macOS:
- https://orbstack.dev/

### Build interruption / resume
The build saves progress. If it stops for any reason, just run it again:
```bash
docker compose up --build
```
It will skip already-completed stages and continue from where it left off.

---

## Estimated Build Times

| Machine | Time |
|---|---|
| Windows i7 (12 cores, 16GB RAM) | ~3-4 hours |
| macOS Intel (8 cores, 16GB RAM) | ~4-5 hours |
| macOS Apple Silicon (M2, 16GB) | ~2-4 hours |
| macOS Apple Silicon + OrbStack | ~2-3 hours |

The kernel compilation is the longest step (~45 min).
The rootfs package installation is the most variable (~2-3 hours, depends on download speed).

---

## After Flashing

1. Insert SD card into RG35XXH
2. Power on — first boot takes about 90 seconds (filesystem init)
3. First boot setup wizard launches automatically:
   - Set your password
   - Set timezone
   - SSH keypair generates (shown as QR code)
   - Optional: configure AI API keys
   - Optional: connect to WiFi
4. You land in the ghOSt launcher

**Stealth mode:** SELECT + START + L2 (hold 3 seconds)
Drop a `.gba/.gbc/.gb` ROM into `~/.stealth/roms/` first.

**AI assistant:** type `hey` in any terminal
**Signal intelligence:** INTERCEPT category in launcher → `localhost:5050`
