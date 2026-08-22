# ghOSt — Agent Documentation

## Current Handoff Status (2026-04-07)

### 1. Point of this project

ghOSt is a custom Debian Bookworm ARM64 image for the Anbernic RG35XXH. The goal is to turn the device into a portable security, RF, wireless, and privacy workstation with a controller-friendly launcher, stealth mode, and a curated set of tools that still fit within the hardware limits of the H700 platform.

### 2. What has been done

- The build now reliably gets through kernel staging, rootfs bootstrap, overlay application, and in-chroot configuration.
- The earlier cached-rootfs failures were fixed in the build scripts:
  - broken git clone wrapper
  - stale DNS state in resumed rootfs builds
  - stale `dpkg-statoverride` entries and missing service accounts
  - missing ARM64 loader symlinks required for the configure-stage chroot
  - `wireguard` meta-package pulling incompatible kernel packages from Kali
  - dead or prompt-hanging source clones such as `sixpair` and `aptdec`
  - cleanup failures caused by scanning mounted pseudo-filesystems
- The configure stage was fixed so it now completes successfully:
  - missing config directories are created before writing files
  - theme/wallpaper generation bugs were fixed
  - ASCII-safe wallpaper glyphs were restored for Pillow's default font
  - rootfs theme assets and launcher wallpaper generation now complete cleanly
- The image-assembly stage was investigated inside the Docker container:
  - isolated loop-device and device-mapper repros succeed
  - the full 20GB partition layout also formats successfully in isolation
  - this means the current `mkfs.ext4: Operation not permitted while trying to determine filesystem size` failure looks transient in the live build path, not like a fundamental Docker/macOS incompatibility
- `build.sh` was hardened after that verification:
  - image assembly now waits for mapper devices to report a readable block size before formatting
  - image assembly now uses a cleanup trap so loop and mapper devices are detached even if the stage fails partway through
  - this change is syntax-checked and based on successful isolated repros, but it still needs confirmation in a full build run

### 3. Steps that need to be taken next

1. Re-run the full Docker build from the cached state and see whether the new mapper-readiness checks clear the final image-assembly failure:
   `docker compose up --build`
   Do not use `SKIP_KERNEL=true` for the verification run unless `/opt/ghost-build/boot0.img` and the other staged boot assets already exist, because the image-only path currently stops early when those files are absent.
2. If the build still fails in `assemble_image()`, collect live state from inside the failed container before restarting:
   - `ls -l /dev/mapper`
   - `blockdev --getsize64 /dev/mapper/loop0p3`
   - `dmsetup table`
   - `losetup -a`
3. If the mapper path still flakes, switch `assemble_image()` to use direct loop partition nodes when available, with mapper nodes as fallback. This has not been necessary in isolated repros yet, so do not change it blindly.
4. Once the image is produced, verify the artifact in `/Volumes/Mac Stick/Projects/ghOSt-RG35XXH/output/`, update the release notes and README if needed, and only then move on to the broader repo-cleanup and licensing work.

### Files most recently changed during this recovery work

- `build.sh`
- `rootfs/build-rootfs.sh`
- `kernel/build-kernel.sh`
- `docker-entrypoint.sh`
- `overlay/opt/ghost/scripts/configure.sh`
- `overlay/opt/ghost/scripts/ram-audit.sh`
- `overlay/opt/ghost/themes/ghost-theme.py`
- `overlay/opt/ghost/themes/generate-wallpaper.py`

## Project Overview

**ghOSt** (Handheld Security and Signal Terminal) is a custom Linux distribution for the **Anbernic RG35XXH** handheld gaming device. It transforms the stock Anbernic firmware into a portable security research, signal intelligence, and wireless tooling platform.

**Target hardware:** Anbernic RG35XXH (Allwinner H700, 1GB RAM, 640×480 display)
**Base OS:** Debian Bookworm ARM64
**Build system:** Native shell scripts + optional Docker container

---

## Repository Structure

```
ghOSt-RG35XXH/
├── build.sh                  # Main build orchestrator (5-stage pipeline)
├── config.sh                 # All build-time configuration variables
├── Dockerfile                # Docker container for cross-compilation
├── docker-compose.yml
├── DOCKER_BUILD.md           # Docker-specific build instructions
├── README.md                 # Project overview and quick-start
│
├── kernel/
│   ├── build-kernel.sh       # Stages KNULLI prebuilt boot chain + kernel modules
│   └── boot/uEnv.txt         # U-Boot environment
│
├── rootfs/
│   └── build-rootfs.sh       # Debootstrap + all package installation (17 stages)
│
├── overlay/                  # Files applied to rootfs before chroot configure
│   ├── etc/
│   │   ├── neofetch/config.conf
│   │   ├── sway/config
│   │   └── systemd/system/ghost-expand-fs.service
│   ├── home/user/.config/fish/   # Fish shell + Tide prompt + fzf config
│   ├── home/user/.config/tmux/    # Catppuccin tmux config
│   ├── home/user/.config/btop/   # btop catppuccin theme
│   ├── home/user/.config/ranger/ # Ranger file manager config
│   ├── home/user/.config/foot/   # foot terminal Catppuccin config
│   ├── opt/ghost/
│   │   ├── assets/                # Logo images (plymouth, wallpaper)
│   │   ├── battery/ghost-battery.py    # Battery charge limiting (80%)
│   │   ├── memkeeper/ghost-memkeeper.py  # RAM pressure manager
│   │   ├── themes/ghost-theme.py       # Theme manager (catppuccin, cybersec, etc.)
│   │   ├── themes/generate-wallpaper.py
│   │   ├── dosbox/ghost.conf
│   │   ├── dos-library/dos-library.py
│   │   ├── hey/hey.py             # AI CLI (Claude/GPT/Gemini + whisper.cpp + piper)
│   │   ├── scripts/configure.sh    # In-chroot system configuration
│   │   └── wallpapers/shodan.jpg
│   └── usr/local/bin/
│       ├── ghost-expand-fs.sh     # First-boot root partition expander
│       ├── ghost-power             # CPU governor + power profile manager
│       └── ghost-wallpaper         # Theme wallpaper regenerator
│
├── launcher/
│   └── launcher.py                 # SDL2 gamepad-navigable menu (736 lines)
│                                   # Categories: Signal Int, Recon, Wireless, Tools,
│                                   # AI, Privacy, Browser, Games, Terminal, Display,
│                                   # Android, Camera, Comms, Power, Themes, System
├── stealthd/
│   ├── stealthd.py                 # Stealth mode daemon (284 lines)
│   │                               # Button combo (SELECT+START+L2, 3s) triggers mGBA
│   │                               # Process disguise: kworker/0:1H via prctl
│   │                               # Cleans traces on exit (fish history, dmesg, temp)
│   └── stealthd.service            # systemd unit
│
└── firstboot/
    ├── firstboot.sh                # First-boot orchestrator
    ├── firstboot-interactive.sh   # Interactive SSH key + WiFi + timezone setup
    └── firstboot.service           # systemd unit
```

---

## Build System

### Build Stages (build.sh)

1. **build_kernel()** — Stages KNULLI prebuilt H700 boot chain (boot0, boot_package, boot.img, env.img) and kernel modules
2. **build_rootfs()** — Deboots Debian Bookworm ARM64, runs 17 install stages
3. **apply_overlay()** — Rsyncs overlay/, installs launcher/, stealthd/, hey/, firstboot/
4. **configure_chroot()** — Runs configure.sh inside ARM64 chroot
5. **assemble_image()** — Partitions GPT image, writes boot chain, rsyncs rootfs, compresses

### Rootfs Build Stages (rootfs/build-rootfs.sh)

| Stage | Name | Key Packages |
|-------|------|--------------|
| 1 | Debootstrap | Debian Bookworm ARM64 |
| 2 | APT config | Debian + Kali rolling sources |
| 3 | Base | systemd, network-manager, openssh-server, python3, golang, lua, ruby |
| 4 | Shell | fish, tmux, micro, vim, bat, ripgrep, fzf, zoxide, atuin, btop, ncdu, duf, glow |
| 5 | GUI | cage, weston, wayland, pipewire, bluez, libsdl2, gamescope |
| 6 | Remote | mosh, autossh, sshuttle, tigervnc, freerdp, bluetuith |
| 7 | VPN/Privacy | wireguard, openvpn, tor, torsocks, i2pd, dnscrypt-proxy |
| 8 | **SDR/RF** | rtl-sdr, rtl-433, dump1090, multimon-ng, direwolf, fldigi, inspectrum, kalibrate-rtl (source), **SDR++ Brown (source)** |
| 9 | **Security** | nmap, masscan, rustscan, recon-ng, exploitdb, metasploit-framework, sqlmap, hydra, aircrack-ng, hcxdumptool, bettercap, **kismet** (Bookworm fallback), termshark, responder |
| 10 | Wordlists | rockyou.txt, SecLists (sparse checkout: Discovery/Passwords/Fuzzing) |
| 11 | TUI | calcurse, taskwarrior, ranger, visidata, irssi, newsboat, aerc, syncthing |
| 12 | AI | whisper.cpp (source, tiny.en model), piper TTS (source, en_US-lessac-medium) |
| 13 | Gaming | mGBA (stealth), PortMaster (optional), DOSBox-X (optional) |
| 14 | Compat | box64, FEX-Emu (optional), Wine ARM64 (optional) |
| 15 | CyberChef | CyberChef server at :8000 |
| 16 | Power | tlp, acpi, auto-cpufreq, handheld-daemon |
| 16a | Controllers | antimicrox, SDL2 GameControllerDB, udev rules (PS3/PS4/PS5/Xbox/Switch/8BitDo) |
| 16b | Firmware | atheros, ralink, mediatek, realtek, brcm80211 |
| 16c | GPS | gpsd, gpsd-clients, foxtrotgps |
| 16d | Modem | modemmanager, usb-modeswitch, mobile-broadband-provider-info |
| 16e | Camera | v4l2loopback, ffmpeg, motion, guvcview, libfreenect (Kinect v1), OpenCV |
| 16f | Android | adb, fastboot, scrcpy, apktool, jadx, frida, androguard, dex2jar |
| 16g | UX | wl-clipboard, swaylock, swayidle, mako, zathura, qrencode |
| 16h | Security extras | macchanger, ettercap, yersinia, sslstrip, reaver, bully, wpscan, droopescan, xsstrike, dalfox, dnsrecon, responder, mimikatz (wine), nishang, powersploit |
| 16i | DOS content | dosbox download-games.sh (Neuromancer, Hacker I/II, System Shock) |
| 16j | PortMaster setup | portmaster-setup.sh |
| 16k | Screen lock | swaylock + swayidle config |
| 16l | Update script | ghost-update (git pull + pip upgrade) |
| 16m | Notifications | mako notification daemon |

---

## Key Components

### Launcher (launcher.py)

SDL2-based gamepad-navigable menu running at 640×480. Uses evdev for input.

- **Categories:** Signal Int, Recon, Wireless, Tools, AI, Privacy, Browser, Games, Terminal, Display, Android, Camera, Comms, Power, Themes, System
- **Dynamic UI:** Entries with `requires` dict are hidden if the binary/path is absent
- **Stealth combo:** SELECT + START + L2 held 3 seconds triggers stealthd
- **Navigation:** D-pad/left stick to navigate, A/South to select, B/East to back

### Stealth Mode (stealthd.py)

Daemon that monitors button combo and disguises the device as a game console:

- **Trigger:** SELECT + START + L2 held for 3 seconds
- **Disguise:** mGBA appears as `kworker/0:1H` via `prctl(PR_SET_NAME, ...)`
- **mGBA launch:** `gamescope -w 640 -h 480 -f -- mgba-sdl -f <rom>`
- **ROM location:** `~/.stealth/roms/*.gba|*.gbc|*.gb` (most recent used)
- **BT keyboard:** Auto-reconnects paired devices on stealth activation
- **Trace cleanup:** Clears fish history, dmesg, temp files on exit
- **Signals:** SIGSTOP to launcher (instant pause), SIGCONT on resume
- **Exit:** Same button combo or mGBA exit → clean traces → resume launcher

### hey AI Assistant (hey/hey.py)

Voice and text AI assistant with multi-provider support:

- **Providers:** Anthropic Claude (default), OpenAI GPT-4o, Google Gemini
- **Voice pipeline:** BT mic → arecord → whisper.cpp (tiny.en) → API → piper TTS → speaker
- **BT headset detection:** `pactl list sources short` checks for bluez
- **Modes:** `hey` (voice, auto-BT-detect), `hey -t` (text), `hey -m` (model select), `hey --setup` (API keys)
- **API key storage:** `pass` (password manager) or plaintext config
- **Conversation history:** Saved in `~/.local/share/ghost/conversations/`
- **Launcher integration:** AI category with voice/text/model entries

### ghost-power (usr/local/bin/ghost-power)

CPU governor and power profile manager:

- **Profiles:** `balanced` (default), `performance`, `powersave`, `gaming`, `sdr`
- **CPU governors:** schedutil (balanced), performance, powersave
- **Stored in:** `/var/lib/ghost/power_profile`
- **Frequency range per profile:** 480MHz–1800MHz (balanced), 480MHz–1200MHz (powersave)

### ghost-battery (opt/ghost/battery/ghost-battery.py)

Battery charge limiter and monitor:

- **Charge limit:** 80% (configurable) — writes to AXP20X sysfs
- **Warns at:** 20% (low), 10% (critical), 5% (emergency)
- **Temp warn:** 45°C
- **Check interval:** 60 seconds
- **Memory limit:** 20MB via systemd

### ghost-memkeeper (opt/ghost/memkeeper/ghost-memkeeper.py)

RAM pressure manager:

- Monitors available memory
- Kills or restarts services when memory is low
- MemoryMax=30MB via systemd

### ghost-theme (opt/ghost/themes/ghost-theme.py)

Wallpaper and theme manager:

- **Themes:** catppuccin, cybersec, kali, blackarch, parrot, dragonos, steamos, ghost
- Generates themed wallpapers using Pillow
- Updates swaylock and swayidle backgrounds

### INTERCEPT (opt/ghost/intercept/)

Network reconnaissance and signal intelligence platform (from smittix/intercept):

- **Service:** `intercept.service` — `python3 intercept.py --host 127.0.0.1 --port 5050`
- **URL:** `http://localhost:5050`
- **Requirements:** Flask, requests (installed via pip)

### ghost-expand-fs (usr/local/bin/ghost-expand-fs.sh)

First-boot root partition expander:

- Runs on first boot after ghost-gui starts
- Resizes root partition to fill available SD card space
- Disables itself after running

---

## Memory Management Strategy

**Total virtual memory on 1GB device: ~6.5GB effective**
- **zram:** 512MB lz4-compressed swap in RAM (priority 100, 50% of RAM)
- **SD swap:** 4GB partition (priority 10, overflow only)
- **RAM:** 1GB physical

**Key sysctl settings (98-ghost-swap.conf, 99-ghost.conf):**
- `vm.swappiness=10` — prefer zram before SD swap
- `vm.vfs_cache_pressure=50` — reclaim inode/dentry cache aggressively
- `vm.dirty_writeback_centisecs=60000` — flush every 10 minutes
- `vm.min_free_kbytes=65536` — keep 64MB for kernel
- Transparent huge pages: **disabled**
- `vm.overcommit_memory=1` — always allow overcommit

---

## SD Card Longeuity

**tmpfs mounts (in fstab):**
- `/tmp` — 128MB
- `/var/tmp` — 64MB
- `/var/log` — 32MB
- `/run` — 32MB

**log2ram:** 40MB RAM buffer for /var/log (rsync-based)
**atime:** disabled via `noatime,nodiratime` in fstab
**Journal:** commit interval 600s (`commit=600`)
**zswap:** disabled (zram handles compression)

---

## USB-C Host Mode

The USB-C port supports OTG peripheral modes when a USB-C cable is detected:

**Supported peripherals:**
- USB keyboards (HID)
- USB Ethernet: AX88179, CDC_NCM, RTL8152
- RTL-SDR dongles (RTL2838)
- USB serial: CH341, CP210x, FTDI, PL2303
- Powered USB hubs
- USB mass storage

**Kernel modules built/included:**
- `rtl8187` (Realtek 8187L USB WiFi)
- `rtl8188eu` (Realtek 8188EU)
- `ath9k_htc` (Atheros AR9271 USB WiFi)
- `rt2800usb` (Ralink RT2870 USB)
- `mt7601u` (MediaTek MT7601U USB)
- `rtl_sdr` (RTL2838 DVB-T USB)
- `airspy` (Airspy SDR)
- `hackrf` (HackRF SDR)
- `usbserial` (FTDI, CH341, CP210x, PL2303)
- `cdc_ether` (CDC Ethernet)
- `usbnet` (generic USB Ethernet)
- `btusb` (Bluetooth HCI)

**Bluetooth:**
- BlueZ stack with FastConnectable enabled
- AutoEnable=true
- Auto-reconnect on stealth activation
- BT keyboard pairing via bluetoothctl

---

## Network Services

| Service | Port | Auto-start |
|---------|------|------------|
| openssh-server | 22 | Yes (key-auth only) |
| intercept | 5050 | Yes |
| cyberchef | 8000 | Yes |
| syncthing | 8384 | Yes |
| ghost-gui | — | Yes (Cage + launcher) |
| stealthd | — | Yes |
| tor | — | Yes (daemon) |
| dnscrypt-proxy | 53 | Yes |
| bluetooth | — | Yes |
| ghost-battery | — | Yes |
| ghost-memkeeper | — | Yes |

---

## Build Configuration (config.sh)

Key toggles:

```bash
KALI_SIZE="default"       # ~5GB tools | "large" ~9GB
GAMES_PROFILE="lean"      # "lean" minimal | "full"
INCLUDE_AI=true            # whisper.cpp + piper
INCLUDE_FEX=false          # x86 emulation layer
INCLUDE_WINE=false         # Windows tooling
INCLUDE_PORTMASTER=false   # Gaming launcher
INCLUDE_DOSBOX=false       # DOSBox-X
INCLUDE_WORDLISTS=true     # rockyou + SecLists
INCLUDE_CYBERCHEF=true     # Offline CyberChef
INCLUDE_STEALTH=true       # mGBA + stealthd
ROOT_SIZE_MB=16384         # 16GB root partition
SWAP_SIZE_MB=4096          # 4GB swap partition
WHISPER_MODEL="tiny.en"    # tiny.en | base.en | small.en
STEALTH_TRIGGER="select+start+l2"
STEALTH_HOLD_SECS=3
BATTERY_CHARGE_LIMIT=80
```

---

## First Boot Flow (firstboot/)

1. Set `ghost` user password
2. Pick timezone
3. Generate ed25519 SSH keypair → display as text + QR code
4. Configure `hey` API keys (optional)
5. Join WiFi (optional)
6. Create `~/.stealth/roms/` directory
7. Explain stealth hotkey (SELECT+START+L2)
8. Expand filesystem to fill SD card
9. Disable firstboot service

---

## Build Commands

**Docker (recommended):**
```bash
docker compose up --build
```

**Native:**
```bash
sudo ./build.sh
```

**Custom build with options:**
```bash
sudo KALI_SIZE=large INCLUDE_AI=true ./build.sh
```

**Output:** `build/output/ghOSt-RG35XXH-1.0.0.img.gz`

**Flash (Linux):**
```bash
./flash_dd_with_gpt.sh /path/to/ghOSt-1.0.0-rg35xxh.img.gz /dev/sdX
```

**Flash (macOS):**
```bash
./flash_dd_with_gpt.MacOS.sh /path/to/ghOSt-1.0.0-rg35xxh.img.gz /dev/diskN
```

---

## Package Manager Notes

- **Kali packages:** Priority pinned to 100 (install only when explicitly requested)
- **anonsurf:** Intentionally **not** installed — its installer mutates apt sources and breaks builds
- **kismet:** Kali package depends on newer glibc; falls back to Bookworm native if available
- **kalibrate-rtl:** Kali package incompatible with Bookworm → built from source instead
- **whisper.cpp:** Built from source (not in repos)
- **SDR++ Brown:** Built from source (not in repos)
- **auto-cpufreq:** Built from source (not in Debian repos)
- **Wordlists:** SecLists uses git sparse-checkout to avoid downloading everything

---

## Known Compatibility Issues

1. **kismet** — Kali package needs t64/glibc newer than Bookworm. Install from Bookworm native if available.
2. **anonsurf** — Installer writes unsigned I2P apt source. Skip entirely; use Tor/i2pd/proxychains instead.
3. **kalibrate-rtl** — Kali package incompatible. Falls back to source build.
4. **SDR++ Brown** — Built from source; FFT/SDR headers must be installed before source build (done in stage 8).
5. ** atuin** — Kali package needs newer glibc. Uses static upstream release binary instead.
6. **FEX rootfs** — Downloads Ubuntu 24.04 x86_64 rootfs (~300MB) at build time.

---

## Directory Aliases (for agent reference)

- **Overlay root:** `$GHOST/overlay/` = `/path/to/repo/overlay/`
- **Launcher:** `$GHOST/launcher/launcher.py`
- **Stealth daemon:** `$GHOST/stealthd/stealthd.py`
- **Hey AI:** `$GHOST/hey/hey.py`
- **Configure script:** `$GHOST/overlay/opt/ghost/scripts/configure.sh`
- **Build rootfs script:** `$GHOST/rootfs/build-rootfs.sh`
- **Build main script:** `$GHOST/build.sh`
