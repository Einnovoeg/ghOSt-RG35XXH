# ghOSt — Handheld Security and Signal Terminal

ghOSt is a security-first handheld distro for the Anbernic RG35XXH. The default build prioritizes signal intelligence, recon, wireless tooling, stealth workflows, and low-RAM operation on a 1GB ARM device. Gaming and compatibility layers remain optional extras, not the center of the image.

## Build

Docker is the fastest path:

```bash
cd ghOSt-RG35XXH
docker compose up --build
```

Native builds are still supported on Ubuntu 22.04 or 24.04 x86_64:

```bash
sudo ./build.sh
```

When the build completes, flash `output/ghOSt-RG35XXH-1.0.0.img.gz` to an SD card.

## Host Requirements

| | Minimum | Recommended |
|---|---|---|
| Host OS | Ubuntu 22.04 x86_64 | Ubuntu 24.04 x86_64 |
| Host RAM | 4GB | 8GB+ |
| Host Disk | 60GB free | 100GB free |
| Build time | 4-6 hours | 2-4 hours |
| SD card | 64GB | 128GB |

## Default Build Profile

The shipped defaults are intentionally security-first:

```bash
KALI_SIZE="default"
GAMES_PROFILE="lean"
INCLUDE_AI=true
INCLUDE_FEX=false
INCLUDE_WINE=false
INCLUDE_PORTMASTER=false
INCLUDE_DOSBOX=false
INCLUDE_WORDLISTS=true
INCLUDE_CYBERCHEF=true
INCLUDE_STEALTH=true
ROOT_SIZE_MB=16384
SWAP_SIZE_MB=4096
```

The launcher now hides optional entries when the underlying tool is not present, so the UI matches the actual image contents.

## Included by Default

### Core platform
- Debian Bookworm ARM64 rootfs
- KNULLI H700 boot chain and runtime assets for the RG35XXH
- Cage/Wayland launcher stack with SDL2 frontend
- zram plus a dedicated swap partition
- `noatime`, long journal commit interval, and tmpfs/log reductions for SD-card longevity

### Shell and operator workflow
- Fish, tmux, micro, vim, bat, ripgrep, fzf, zoxide, btop, ncdu, duf, glow
- `foot` terminal with Catppuccin styling and Terminus fonts
- QR-based SSH key bootstrap on first boot

### Security and recon
- nmap, masscan, recon-ng, dnsenum, fierce, smbmap, enum4linux, wafw00f, whatweb
- metasploit, sqlmap, hydra, medusa, nikto, responder, mitmproxy, pwntools, impacket
- ffuf, gobuster, httpx, dnsx, subfinder, rustscan, feroxbuster
- SpiderFoot and theHarvester isolated in dedicated virtual environments

### Wireless, RF, and signal
- rtl-sdr, rtl_433, dump1090, multimon-ng, direwolf, fldigi, inspectrum, kalibrate-rtl
- aircrack-ng, hcxdumptool, hcxtools, bettercap, wifite, mdk4, wavemon, airgeddon
- INTERCEPT at `http://localhost:5050`
- SDR++ Brown is built from source when its dependency chain resolves during the image build

### Privacy and remote access
- Tor, torsocks, WireGuard, OpenVPN, i2pd, dnscrypt-proxy, proxychains4, secure-delete
- OpenSSH, mosh, autossh, sshuttle, wayvnc, TigerVNC viewer, FreeRDP

## Optional Extras

These are available, but disabled by default because they are secondary to the handheld security workflow:

- FEX and Wine for x86 or Windows tooling
- PortMaster and DOSBox-X
- PortMaster-delivered content like Rockbox

Enable them explicitly in `config.sh` or `docker-compose.yml` if you want them in a custom image.

## Current Compatibility Notes

- `kismet` now prefers a Debian package on Bookworm and falls back to an official source build when the package chain is incompatible.
- `anonsurf` is intentionally not installed because its installer mutates apt sources and breaks repeatable builds.
- Optional launcher entries such as `kismet`, `anonsurf`, `SDR++ Brown`, `SpiderFoot`, `x64dbg`, `PortMaster`, and `DOSBox-X` only appear when the underlying binaries or paths exist.

## First Boot

The first-boot flow focuses on operator setup:

1. Set the `ghost` password.
2. Pick a timezone.
3. Generate an ed25519 SSH keypair and show it as text and QR.
4. Configure `hey` API keys if you want AI features.
5. Join WiFi.
6. Create the stealth ROM directory and explain the stealth hotkey.

## Partition Layout

Default image layout:

```text
mmcblk0p1   FAT32     64MB    boot assets
mmcblk0p2   ext4      16GB    rootfs
mmcblk0p3   swap       4GB    swap at the end of the card
```

If you want a larger root partition in the generated image, raise `ROOT_SIZE_MB` before building.

## USB-C Host Mode

The RG35XXH USB-C port works with common OTG peripherals:

- USB keyboards
- USB Ethernet adapters
- RTL-SDR dongles
- USB serial adapters such as CH341, CP210x, and FTDI
- Powered hubs

## Services

Default services exposed by the image:

| Service | Port | Purpose |
|---|---|---|
| intercept | 5050 | Signal intelligence dashboard |
| cyberchef | 8000 | Browser-based transform and decode toolkit |
| syncthing | 8384 | File sync |
| openssh-server | 22 | Remote shell |
| tor | - | Privacy network |
| dnscrypt-proxy | 53 | Encrypted DNS |
| stealthd | - | Stealth mode daemon |
| ghost-gui | - | Launcher and compositor |

## Support

If the project is useful, support it here: [buymeacoffee.com/einnovoeg](https://buymeacoffee.com/einnovoeg)

## License and Legal

The repository license and third-party attribution still need a full compliance pass. Until that is completed, treat the bundled third-party tools as retaining their own upstream licenses and attribution requirements.

Use ghOSt only for authorized security research, lab work, CTFs, and education.
