ghOSt - boot partition
======================

Files you may edit from any PC:

  wifi.txt     Wi-Fi network. Imported at the next boot; the password is then
               removed from the file and stored on the device.
  panel.txt    Screen panel: auto (default), regular or rev6.

Screen garbled or black?  RG35XX H units have one of two screens. ghOSt picks
the right one by itself and restarts once if it had to switch (logs/panel.txt).
If it stays garbled, write rev6 (or regular) in panel.txt instead of auto.
Use "Safely remove" / Eject before taking the card out.

Diagnostics live in logs/ on this partition (readable from Windows).

Do not edit Image, dtb*.img or boot.scr unless you know what you are doing.

ghOSt is an unofficial hobby project, not affiliated with or endorsed by
Anbernic or any other company named in the documentation. It comes "as is",
without warranty; see the README on the project page.
