# Changelog

All notable changes to this project are documented in this file.

## Unreleased

- Rebuilt image assembly without loop devices, device-mapper or mounts. Docker Desktop on macOS failed the old path with `mkfs.ext4: Operation not permitted while trying to determine filesystem size`; partitions are now built as files (`mkfs.vfat -C` + mtools, `mkfs.ext4 -d <rootfs>`) and written into the MBR image at fixed offsets, following the approach used by junsulee119/handtop. `e2fsck -fn` validates the root filesystem before assembly.
- `boot.scr` is regenerated from `patches/uboot/boot.cmd` at pack time with `root=PARTUUID=<disk-id>-02`, replacing `root=/dev/mmcblk0p2` so the card boots from either SD slot.
- Image packing now strips host identity (`machine-id`, ssh host keys, build-only `qemu-aarch64-static`, apt caches, stale `/boot`) and sizes partitions from the actual rootfs, with `IMAGE_SIZE_GB` acting as a floor instead of a cap.
- Build environment: `mtools` added to the Dockerfile, `ROOTFS_DIR` is env-overridable, and `IMAGE_SIZE_GB` is no longer pinned in `VERSIONS`.
- Screen-panel safety ported from handtop: the image ships `dtb-regular.img` and `dtb-rev6.img`, U-Boot loads `dtb.img`, and `ghost-panel.service` reads board pin PE6 each boot, switches `dtb.img` when the unit has the other panel and restarts once (loop-guarded, logged to `logs/panel.txt`).
- Pre-boot provisioning from the FAT partition: `wifi.txt` is imported into NetworkManager by `ghost-wifi-import.service` and the password is blanked afterwards; `panel.txt` overrides panel detection. Both files plus a `README.txt` are written to the boot partition with CRLF line endings.
- Both device trees are patched for the AXP717 regulator fix, not just the regular one, and the kernel stage says so when a tree has no rev6 DTB.
- Test suite under `tests/`: static naming/syntax consistency, systemd unit and `ExecStart` resolution, and an image-packing test that inspects a real image (partition offsets, FAT contents, `boot.scr` payload, CRLF boot files, ext4 label, rootfs sanitisation) on Linux and asserts the issued commands with stubs elsewhere. CI runs it as a `static` job that gates the long build.
- First-boot expansion matches the shipped MBR layout: `ghost-expand-fs.sh` derives the disk from `findmnt /`, grows only the partition holding `/` (growpart, `parted` fallback) and resizes ext4 in place. The duplicate `expand-rootfs.service`, which hardcoded `/dev/mmcblk0` and treated partition 3 as root with partition 4 as swap, is removed — on the MBR image it would have deleted the root filesystem on first boot.
- Pipeline fixes found by that suite: CI now installs `mtools`/`fdisk`/`e2fsprogs` (image assembly would have failed without them), `build.sh` and the Docker entrypoint require the loop-free tools instead of loop devices, the flash helpers accept `.img.xz` and only attempt GPT repair when a GPT header is present, and the macOS helper's quoted zsh regex that made disk selection always fail is fixed.

## 1.0.0 - 2026-03-28

- Re-centered the default build around the original handheld security and signal-intelligence goal instead of gaming-first defaults.
- Set the shipped profile to `GAMES_PROFILE=lean` with PortMaster, DOSBox-X, FEX, and Wine disabled unless explicitly requested.
- Updated the launcher so optional entries only appear when the corresponding binaries or paths are present in the image.
- Isolated Python-heavy security tools such as SpiderFoot and theHarvester in dedicated virtual environments.
- Reworked multiple upstream download and packaging paths to reduce breakage from current Bookworm, Kali, and GitHub release drift.
- Added an official-source fallback build for Kismet when the Bookworm package path is incompatible.
- Corrected project documentation and Docker output references to the generated image name `ghOSt-RG35XXH-1.0.0.img.gz`.
