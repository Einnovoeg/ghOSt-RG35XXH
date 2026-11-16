# ghOSt — Gaming, Hacking Operating System Terminal

ghOSt is a cyberdeck build for the Anbernic RG35XXH: one Debian Trixie ARM64 image that carries offensive security, OpSec, recon tooling, software-defined radio and a console-first gamepad UI, on hardware with a 1GHz quad-core SoC and 1GB of RAM. The security stack is the default focus; the gaming layer is part of the image because a handheld you cannot hand to a kid is a handheld that gets left at home.

> **Boot fix (2026-09):** default `BOOT_FLOW=rocknix` ports the proven
> [rg35xxh-cyberdeck](https://github.com/Einnovoeg/rg35xxh-cyberdeck) boot chain
> (ROCKNIX mainline kernel 7.x without embedded initramfs, AXP717
> regulator-always-on DTB fix, MBR + SPL@8KB + FAT /boot + ext4 rootfs) and its
> XFCE UI (LightDM autologin, joy2mouse, WiFi watchdog, MTP, battery widget).
> Legacy KNULLI 4.9 + GPT (`BOOT_FLOW=legacy`) is kept for experiments only.
> See `docs/PITFALLS-cyberdeck.md`, `VERSIONS`, `image/pack-image-rocknix.sh`.

## The five pillars

ghOSt is not a re-spin of another distribution. It is a single Debian rootfs that
takes the defining idea of five specialist distributions and implements it for a
1GB handheld:

| Pillar | Taken from | How it appears in ghOSt |
|---|---|---|
| Offensive security | Kali Linux | `kali-rolling` repo pinned to low priority: nmap, masscan, rustscan, metasploit, sqlmap, hydra, aircrack-ng, hcxdumptool, bettercap, responder, wifite, airgeddon |
| OpSec and anonymity | ParrotOS | NetworkManager MAC randomisation, `macchanger`, Tor + `torsocks`, i2pd, proxychains4, WireGuard/OpenVPN, `dnscrypt-proxy`, `secure-delete`, stealth mode in `stealthd` |
| Modular recon tooling | BlackArch | everything that is not a Debian package lives under `/opt/ghost/` — INTERCEPT, CyberChef, airgeddon, SpiderFoot and theHarvester in their own venvs — and is reached from the launcher |
| RF and SDR | DragonOS | rtl-sdr, rtl_433, dump1090, multimon-ng, direwolf, fldigi, inspectrum, kalibrate-rtl, SDR++ Brown, `soapysdr-tools`, plus in-kernel drivers for RTL-SDR, HackRF and Airspy dongles |
| Console-first handheld UX | Bazzite | gamepad-driven Cage/XFCE launcher, RetroArch with libretro cores, mGBA for stealth mode, optional PortMaster and DOSBox-X, joy2mouse and handheld-daemon |

Deliberate gaps, so the table is not read as more than it is: `gnuradio` is not
installed (its dependency chain does not fit a 1GB device — the SDR pillar uses the
lighter rtl-sdr, SoapySDR and SDR++ stack), `anonsurf` is not installed because its
installer rewrites apt sources, `RetroArch` cores are limited to the GBA/SNES/Genesis
set that the H700 runs at full speed, and there is no BlackArch repository: BlackArch
contributes the layout and tooling style, not packages.

## Kernel and boot payload

ghOSt does not ship a self-built kernel. The kernel, both device trees, the U-Boot
SPL and the kernel modules come from the official ROCKNIX release image for this
hardware, pinned in `VERSIONS` by asset name and SHA-256, extracted without loop
devices or mounts, and patched for the AXP717 regulators. That payload is the part
that is known to boot on real RG35XXH units, including both screen panels; ghOSt
supplies everything above it (rootfs, tools, launcher, stealth mode, UI).

`GHOST_BOOT_SOURCE=source` builds ROCKNIX's kernel tree in a container instead,
for experiments; it is not the supported path.

## Licence

MIT — see `LICENSE`. A few files carry MIT notices from other projects; the image
also ships ROCKNIX builds (GPL-2.0) and tools cloned at build time. `NOTICE` lists
every source, what was used and under which licence, and `LICENSES/` keeps the
upstream notices verbatim.

## Build (local)

Docker is the fastest path:

```bash
cd ghOSt-RG35XXH
docker compose up --build
```

Native builds are still supported on Ubuntu 22.04 or 24.04 x86_64:

```bash
sudo ./build.sh
# BOOT_FLOW=rocknix UI_MODE=xfce is the default (boots).
# BOOT_FLOW=legacy is experimental only.
```

When the build completes, flash `build/output/ghOSt-RG35XXH-*.img.xz` to an SD card:

```bash
xz -d build/output/ghOSt-*.img.xz
sudo bmaptool copy build/output/ghOSt-*.img /dev/sdX
```

## Boot partition (no keyboard needed)

The FAT partition (label `BOOT`, mounted at `/boot`) carries the kernel, `dtb*.img`,
`boot.scr` and three files you can edit from any PC:

- `wifi.txt` — `SSID`, `PASSWORD`, optional `COUNTRY`. Imported into NetworkManager
  on the next boot; the password is then removed from the file.
- `panel.txt` — `auto` (default), `regular` or `rev6`. Retail units ship with one of
  two screens; `ghost-panel.service` reads board pin PE6 on every boot and swaps
  `dtb.img` for the matching device tree if needed, restarting once.
- `README.txt` — the same instructions, on the card.

Diagnostics (`logs/panel.txt`, boot logs) are written back to this partition, so a
garbled screen or missing Wi-Fi can be diagnosed from Windows/macOS.

## Build from GitHub (CI — no local Linux needed)

1. Push to `main` (builds + uploads `ghost-rg35xxh-image` artifact), or
2. Tag `v*` (e.g. `git tag v1.0.1 && git push origin v1.0.1`) for a Release with
   `.img.xz + .bmap + SHA256SUMS`, or
3. Actions → `build` → Run workflow (choose `boot_flow` / `ui_mode`).

Workflow: `.github/workflows/build.yml` (cache keyed on `VERSIONS`; kernel
rebuild only when pins change). Artifacts retained 14 days. The build job runs on a
native ARM64 runner (`ubuntu-24.04-arm`) because the aarch64 chroot takes about seven
hours under qemu emulation on x86_64 and a hosted job is capped at six.

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

### Core platform (rocknix boot flow)
- Debian Trixie ARM64 rootfs (Bookworm gcc-12 cannot build modules for the gcc-15 kernel)
- ROCKNIX mainline kernel 7.x + U-Boot SPL@8KB, patched DTB (regulator-always-on)
- MBR layout: p1 FAT32 BOOT (Image+DTB+boot.scr), p2 ext4 rootfs (LABEL-based fstab)
- XFCE 4.20 + LightDM autologin to `ghost` (joy2mouse: left stick=mouse, A/B/Y=click, R-stick=scroll)
- ghOSt launcher kept as XFCE menu entry (`ghost-launcher.desktop`) + cage fallback (`UI_MODE=cage`)
- zram (prio 100) + tmpfs/log reductions for SD-card longevity
- WiFi watchdog, MTP gadget (port 1), UPower battery fix, backlight polkit, `play480`/`setvol`

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

## Partition Layout (rocknix, bootable)

Default image layout (`IMAGE_SIZE_GB=12`, expands to fill SD on first boot via `ghost-expand-fs.service`):

```text
mmcblk0p1   FAT32     256MB   BOOT (Image, DTB, boot.scr/boot.cmd)
mmcblk0p2   ext4      rest    rootfs (LABEL=rootfs)
```

Legacy GPT layout (`BOOT_FLOW=legacy`, experimental, does not boot reliably):

```text
mmcblk0p1   raw       20MB    boot0
mmcblk0p2   raw       16MB    env
mmcblk0p3   ext4      16GB    rootfs (ROOT_SIZE_MB)
mmcblk0p4   swap       4GB    swap (SWAP_SIZE_MB)
```

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

ghOSt's own code is MIT — see `LICENSE`. The image also carries GPL-2.0 ROCKNIX
boot components, MIT-licensed work ported from other projects, and tools cloned at
build time; `NOTICE` records every source, what was used and under which licence, and
`LICENSES/` keeps the upstream notices verbatim. Tools installed from Debian and Kali
repositories keep their own upstream licences.

Use ghOSt only for authorized security research, lab work, CTFs, and education.
