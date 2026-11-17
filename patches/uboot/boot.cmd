# boot.cmd for RG35XXH (Allwinner H700)
# Compile: mkimage -A arm64 -O linux -T script -C none -n "rg35xxh-cyberdeck" -d boot.cmd boot.scr
#
# Verbose log on tty1 (no UART on RG35XXH retail) + systemd debug to console.
# console=ttyS0 FIRST, console=tty1 LAST → /dev/console = screen.

setenv bootargs "root=/dev/mmcblk0p2 rw rootwait \
  console=ttyS0,115200 console=tty1 \
  loglevel=8 ignore_loglevel \
  systemd.log_target=kmsg systemd.log_level=debug \
  systemd.journald.forward_to_console=1 printk.devkmsg=on"

# dtb.img is picked at boot by ghost-panel (regular or rev6 screen panel);
# the per-panel copies are dtb-regular.img / dtb-rev6.img on this partition.
# The H700 has two SD slots and the OS card can enumerate as mmc 0 or mmc 1,
# so try the internal slot first and fall back to the second one. root= is a
# PARTUUID, so the kernel mounts the right partition either way.
# initrd.img is ghOSt's own initramfs. It is unpacked after the one built into
# the ROCKNIX kernel, so its /init replaces ROCKNIX's and pivots to root= below
# instead of looking for ROCKNIX's /flash + SYSTEM squashfs.
if fatload mmc 0:1 0x44000000 Image; then
  fatload mmc 0:1 0x48000000 initrd.img
  fatload mmc 0:1 0x4FA00000 dtb.img
  booti 0x44000000 0x48000000 0x4FA00000
else
  fatload mmc 1:1 0x44000000 Image
  fatload mmc 1:1 0x48000000 initrd.img
  fatload mmc 1:1 0x4FA00000 dtb.img
  booti 0x44000000 0x48000000 0x4FA00000
fi
