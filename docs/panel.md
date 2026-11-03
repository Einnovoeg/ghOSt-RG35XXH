# Screen panel selection (`ghost-panel`)

RG35XX H units ship with one of two screen panels. They use the same connector but
need a different set-up sequence, so each has its own device tree:
`sun50i-h700-anbernic-rg35xx-h.dtb` ("regular") and
`sun50i-h700-anbernic-rg35xx-h-rev6-panel.dtb` ("rev6"). With the wrong one the screen
shows garbled lines or stays black while the rest of the system boots normally.

The image carries both as `dtb-regular.img` and `dtb-rev6.img` on the FAT boot
partition, and U-Boot always loads `dtb.img`. `ghost-panel.service` keeps `dtb.img`
pointing at the right one.

## What it does every boot

1. **Which panel does the board have?** It reads pin **PE6** with its pull-up on:
   high = regular, low = rev6. This is the same signal Anbernic's stock U-Boot reads
   (`lcd_panel_uboot_fj035fhd05_v1_init`). `panel.txt` on the boot partition overrides
   detection (`regular` / `rev6`; default `auto`).
2. **Which one is installed?** It compares `dtb.img` with `dtb-regular.img` and
   `dtb-rev6.img`.
3. **Match** (almost every boot): nothing is written, a few milliseconds.
4. **Mismatch:** it copies the right file over `dtb.img`, notes it in
   `logs/panel.txt` on the boot partition, and restarts once. That boot is garbled;
   after the restart it is correct. Moving a card to a unit with the other panel works
   the same way, in both directions.

| Situation | Result |
|---|---|
| `dtb.img` is neither `dtb-regular.img` nor `dtb-rev6.img` (edited by hand) | Left alone, logged to the journal |
| PE6 unreadable, or the reads disagree | Nothing changed |
| `dtb-regular.img` / `dtb-rev6.img` missing (older image) | Nothing changed |
| Switched on the last boot and the pin now says the other panel | Not switched again: no restart loop; logged until the two match |
| `panel.txt` says `regular` / `rev6` | That panel, whatever the pin says |

## Safety

- PE6 is unclaimed in the H700 device tree (`pinmux-pins`: UNCLAIMED). The script
  requests it as an input through the GPIO character device and then requests it once
  more with the bias disabled, which is how the kernel leaves it.
- It runs before `lightdm`/`getty@tty1`, so no program holding hardware is running
  yet, and after the first-boot jobs and the Wi-Fi import (which write to the same
  partition).
- `dtb.img` is replaced by an fsync'ed copy that is read back, then renamed, then the
  directory is synced; a power cut leaves the old or the new file.
- An unreadable pin, a missing source file, a failed copy or a failed restart change
  nothing and are logged. A leftover `dtb.img.new` from a power cut is overwritten.
- The boot partition still holds both `dtb-*-.img` files, so a unit can always be
  fixed from a PC by writing `panel.txt`.

## Files

| File | What |
|---|---|
| `overlay/usr/local/sbin/ghost-panel` | The check (Python, GPIO uAPI v2 via `ioctl`) |
| `overlay/etc/systemd/system/ghost-panel.service` | Unit, enabled in `overlay/opt/ghost/scripts/configure.sh` |
| `image/pack-image-rocknix.sh` | Ships both DTBs and `panel.txt` / `wifi.txt` / `README.txt` |
| `image/bootfiles/panel.txt` | Override on the boot partition |
| `/var/lib/ghost/panel-switched` | Set after an automatic switch; removed once `dtb.img` matches |

Test hooks: `GHOST_PANEL_BOOT`, `GHOST_PANEL_STATE`, `GHOST_PANEL_TEST_PE6` (0/1) and
`GHOST_PANEL_DRYRUN=1` (no restart).
