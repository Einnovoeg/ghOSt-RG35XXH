# Features — what the image is supposed to do, and where it stands

Inventory of everything ghOSt promises, checked against the code that implements it.
Status values:

- **done** — implemented and wired into the build (evidence path listed)
- **optional** — implemented but off unless its `INCLUDE_*` flag is enabled
- **conflict** — a documented behaviour contradicts another document; needs a decision
- **open** — not implemented, or not verified on hardware

## Boot and platform

| Feature | Status | Where |
|---|---|---|
| Kernel, U-Boot, DTBs and modules from the official ROCKNIX release (SHA-256 pinned) | done | `kernel/fetch-rocknix-boot.sh`, `VERSIONS` |
| Loop-free extraction (no `losetup`, `kpartx`, `mount`) | done | same; `tests/boot-fetch-test.sh` asserts it |
| Root filesystem read from the `SYSTEM` squashfs, modules from `usr/lib/modules` | done | same |
| U-Boot taken from the raw 8 KiB region when it is not a file | done | same |
| Both panel DTBs patched for AXP717 `regulator-always-on` | done | `scripts/patch-h700-dtb-regulators.py` |
| `boot.scr` regenerated with `root=PARTUUID=<disk-id>-02` | done | `image/pack-image-rocknix.sh`, `patches/uboot/boot.cmd` |
| Console ordering `ttyS0` first, `tty1` last so the screen is `/dev/console` | done | `patches/uboot/boot.cmd` |
| MBR layout, fixed disk id, SPL at 8 KiB, FAT at 16 MiB, ext4 at 272 MiB | done | `image/pack-image-rocknix.sh`; asserted by `tests/pack-image-test.sh` |
| Host identity stripped (`machine-id`, ssh host keys, qemu static, apt caches) | done | same |
| First-boot root partition expansion, works in either SD slot | done | `overlay/usr/local/bin/ghost-expand-fs.sh` |
| Embedded-initramfs kernel detection (ROCKNIX ships one; it bypasses our rootfs) | done | `kernel/fetch-rocknix-boot.sh` writes `EMBEDDED-INITRAMFS` and warns |
| Image that actually boots on a unit | open | no hardware run yet |

## Panel handling

| Feature | Status | Where |
|---|---|---|
| Read PE6 at boot, pick `dtb.img` for the panel present | done | `overlay/usr/local/sbin/ghost-panel` |
| `panel.txt` override (`auto`/`regular`/`rev6`), CRLF, editable from Windows | done | `image/bootfiles/panel.txt`, `docs/panel.md` |
| One-shot switch with loop guard and `logs/panel.txt` diagnostics | done | same |
| Automatic switching can never land on the rev6 tree by itself | done | `ghost-panel` refuses it and says so; `tests/panel-test.sh` proves it |
| Which tree retail units need | open | `docs/panel.md` says both exist; `docs/PITFALLS-cyberdeck.md` §4 says rev6 garbles retail. The code now prefers `regular` unless `panel.txt` says otherwise; hardware settles the rest |

## Desktop, input, UI

| Feature | Status | Where |
|---|---|---|
| XFCE + LightDM autologin to `ghost` (default `UI_MODE=xfce`) | done | `rootfs/build-ui-xfce.sh` |
| Cage fallback with the launcher as the session (`UI_MODE=cage`) | done | `configure.sh` writes and enables `ghost-gui.service` |
| Joystick-as-mouse (`joy2mouse`, stick/scroll/click mapping) | done | `overlay/usr/local/bin/joy2mouse`, `joy2mouse.service` |
| Launcher: 90 entries, 16 categories, gamepad navigation, dynamic hiding | done | `launcher/launcher.py` |
| Launcher reachable from the desktop | done | `overlay/usr/share/applications/ghost-launcher.desktop` |
| `play480` transcode-and-cache helper (no working VPU on mainline) | done | `overlay/usr/local/bin/play480` |
| Backlight control without a password prompt | done | `overlay/etc/polkit-1/rules.d/49-backlight.rules` |
| UPower battery reporting fix for the H700 sysfs | done | `overlay/etc/UPower/UPower.conf` |
| xfce4-battery-plugin popup spam suppressed and rc pinned | done | `rootfs/build-ui-xfce.sh` (`action_on_low`/`critical`, `chattr +i`) |
| Needs `snd`, `setvol` volume helper | done | `overlay/usr/local/bin/setvol` |

## Network, wireless, Bluetooth

| Feature | Status | Where |
|---|---|---|
| NetworkManager with Wi-Fi powersave off, USB gadget interface unmanaged | done | `overlay/etc/NetworkManager/conf.d/*` |
| `wifi.txt` imported from the boot partition, password blanked afterwards | done | `ghost-wifi-import`, its unit, `image/bootfiles/wifi.txt` |
| Wi-Fi watchdog that recovers a dropped association | done | `wifi-watchdog.sh`, `wifi-watchdog.service` |
| Bluetooth stack with auto-enable, BT keyboard and headset support | done | `build-rootfs.sh` stage 5, `bluetuith` in stage 6 |
| USB-C gadget: MTP over `ffs.mtp` plus ECM (no RNDIS: one MUSB controller) | done | `usb-mtp-setup`, `usb-mtp.service` |
| USB mass-storage mode | done | `usb-massstorage-setup`, `usb-massstorage.service` |
| USB-C host mode drivers (RTL-SDR, AX88179, CH341/CP210x/FTDI, hubs) | done | firmware/module stages 16b; ROCKNIX modules |

## RF, SDR, signal

| Feature | Status | Where |
|---|---|---|
| rtl-sdr, rtl_433, dump1090, multimon-ng, direwolf, fldigi, inspectrum | done | `build-rootfs.sh` stage 8 |
| kalibrate-rtl from source (Kali package incompatible) | done | stage 8 |
| SDR++ Brown from source | done | stage 8 |
| GPS via gpsd + clients | done | stage 16c |
| ModemManager + usb-modeswitch | done | stage 16d |
| INTERCEPT dashboard on `:5050` | done | cloned in stage 9, unit in `configure.sh`, launcher entry gated on `intercept.py` |

## Security tooling

| Feature | Status | Where |
|---|---|---|
| nmap, masscan, rustscan, recon-ng, metasploit, sqlmap, hydra, nikto, responder | done | stages 9, 16h |
| Wireless: aircrack-ng, hcxdumptool, bettercap, wifite, mdk4, airgeddon | done | stages 9, 16h; airgeddon cloned |
| kismet from package with source fallback | done | stage 16h |
| radare2, pwndbg, routersploit, nishang, powersploit | done | stages 9, 16h |
| Wordlists: rockyou + SecLists sparse checkout | done | stage 10 |
| SpiderFoot and theHarvester in isolated venvs | done | stage 16h |
| Android: adb, fastboot, scrcpy, apktool, jadx, frida, androguard, dex2jar | done | stage 16f |
| Camera: v4l2loopback, ffmpeg, motion, guvcview | done | stage 16e |
| Kinect v1 (libfreenect) and v2 (libfreenect2) | done | stage 16e |
| CyberChef server on `:8000` | done | stage 15, unit in `configure.sh` |
| Syncthing | done | stage 11 |

## Privacy and remote access

| Feature | Status | Where |
|---|---|---|
| Tor, torsocks, i2pd, dnscrypt-proxy, proxychains | done | stage 7 |
| WireGuard (`wireguard-tools`, not the meta-package) and OpenVPN | done | stage 7 |
| OpenSSH key-only, mosh, autossh, sshuttle | done | stages 3, 6 |
| VNC/RDP viewers | done | stage 6 |
| `secure-delete` | done | stage 7 |

## AI

| Feature | Status | Where |
|---|---|---|
| `hey` CLI: text, voice, model select, `--setup`, quick query | done | `hey/hey.py` |
| Local speech-to-text (whisper.cpp `tiny.en`) and TTS (piper) | done | stage 12 |
| Launcher AI entries appear only when `hey` is on `PATH` | done | `build.sh` symlinks `/usr/local/bin/hey` |

## Power, memory, SD-card longevity

| Feature | Status | Where |
|---|---|---|
| `ghost-power` profiles: performance, balanced, powersave, gaming, stealth, sdr | done | `overlay/usr/local/bin/ghost-power` |
| Balanced profile applied at boot | done | `ghost-power-default.service` |
| Battery charge limit (80%) and low/critical/emergency/temperature warnings | done | `overlay/opt/ghost/battery/ghost-battery.py`, `ghost-battery.service` |
| RAM pressure manager that never kills system services | done | `ghost-memkeeper.py`, `ghost-memkeeper.service` |
| zram, log2ram, tmpfs `/tmp` and `/var/tmp`, `noatime`, long journal commit | done | `configure.sh` fstab/sysctl block |
| TLP / auto-cpufreq | done | stage 16 |

## Gaming (secondary, never the default focus)

| Feature | Status | Where |
|---|---|---|
| mGBA launched by stealth mode with process disguise | done | `stealthd/stealthd.py` |
| `dosbox-x` available even when only classic DOSBox is packaged | done | `build-rootfs.sh` shim; launcher and `dos-library` call `dosbox-x` |
| DOS game library and download script | done | `overlay/opt/ghost/dos-library`, stage 16i |
| PortMaster and Rockbox | optional | `INCLUDE_PORTMASTER=false`; launcher entries hide themselves |
| FEX and Wine | optional | `INCLUDE_FEX=false`, `INCLUDE_WINE=false` |

## Stealth mode

| Feature | Status | Where |
|---|---|---|
| SELECT+START+L2 held 3 s activates stealth | done | `stealthd/stealthd.py`, `config.sh` |
| Disguise as `kworker/0:1H`, pause the launcher, resume on exit | done | same |
| Trace cleanup (shell history, dmesg, temp files) | done | same |
| Bluetooth keyboard reconnection on activation | done | same |

## First boot and provisioning

| Feature | Status | Where |
|---|---|---|
| Operator setup: password, timezone, SSH keypair + QR, API keys, Wi-Fi, ROM dir, hotkey | done | `firstboot/firstboot.sh` + `firstboot-interactive.sh` (both installed) |
| Runs once, then disables itself | done | `firstboot.service`, `/var/lib/ghost/.firstboot_done` |
| Boot-partition provisioning readable from Windows/macOS | done | `image/bootfiles/{wifi,panel,README}.txt`, CRLF |
| Boot diagnostics copied back to the FAT partition | done | `dump-boot-logs.sh`, `dump-boot-logs.service` |

## Build, CI, licensing

| Feature | Status | Where |
|---|---|---|
| One command local build (Docker or native) | done | `build.sh`, `docker-compose.yml` |
| CI builds, caches the release image, uploads an artifact, releases on tag | done | `.github/workflows/build.yml` |
| Fast suite gates the long build | done | `tests/run-all.sh` in the `static` job |
| Licence compliance for derived files | done | `LICENSE`, `NOTICE`, `LICENSES/`, per-file headers, enforced by `tests/static-checks.sh` |
| No passwordless root | done | both stages write the same restricted command list; the suite fails if `NOPASSWD: ALL` reappears |
| No shipped default password | open | still `CaptainCrunch`; SSH is key-only, so this is a local-only exposure until first boot sets a real password |
| Image produced by this pipeline, flashed and booted | open | packing in progress; hardware untested |

## How this list was checked

- Every launcher entry (90) was resolved: the program it runs is either installed by a
  build stage, shipped in `overlay/`, or hidden by a `requires` guard.
- Every systemd unit in `overlay/` and every unit `configure.sh` writes has an
  `ExecStart` that exists.
- Boot-chain file names agree across `boot.cmd`, the packer, `config.sh` and the
  extractor; `tests/static-checks.sh` enforces this.
- The pitfalls file was re-read against the code: console ordering, MUSB composition,
  battery-plugin pinning and the initramfs hazard each have their fix in place, except
  the panel question in §4, which contradicts `docs/panel.md` and needs hardware.
