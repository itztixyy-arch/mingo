# Mingo 0.4

Linux that lives on a USB stick: plug in, boot, use, and your changes are saved back to the stick.
BIOS + UEFI (Secure Boot off). Based on Alpine Linux (latest stable), runs from a compressed system file
with a RAM layer on top. Needs 2 GB+ RAM and a 2 GB+ USB stick.

## Build
`wsl -d Ubuntu -u root -- bash /mnt/d/PythonAndStuff/Minigo/build.sh` -> `out\mingo.img`

## Test VM (QEMU in WSL, window via WSLg)
```
.\run-vm.ps1            # VM window (disk: vm\mingo-vm.img; recreated automatically after a new build)
.\run-vm.ps1 reset      # fresh VM disk
.\run-vm.ps1 uefi       # UEFI boot
.\run-vm.ps1 debug      # serial shell + kernel log in this terminal, gdb stub :1234, Ctrl+A X quits
.\run-vm.ps1 show       # list saved changes on the VM disk
```

## Flash
Rufus (DD Image mode) or balenaEtcher -> `out\mingo.img`. **Erases the whole stick.**

## What is on the stick (FAT32, open it from Windows)
```
boot\                         kernel + small start-up image
EFI\BOOT\                     UEFI loader
mingo\system.sfs              the whole operating system (compressed, read-only)
mingo\current-version.txt     number of the latest save
mingo\full-version.txt        save number of the last full snapshot
mingo\changes\changes-N.mingo one file per save (tar.gz of changed files + list of deleted files)
```

## Boot
Fast: the BIOS only loads the kernel and a small start-up image; Linux then reads the system from
the stick itself. Boot animation shows progress. It boots straight into the desktop
(`mingo autodesktop off` boots to the terminal instead).
Hold Shift while it starts (BIOS) and type: `toram` (copy the system to RAM) or `safe` (no graphics mode,
no animation).

## Your files
Home folder is `/root` with `Desktop`, `Documents`, `Downloads`, `Pictures`, `Music`, `Videos` (like a Windows
user folder). Everything you change anywhere is saved: at shutdown/reboot, every 3 minutes, or with `mingo save`.
Only changed files are saved; after 25 saves or 128 MB of saves they are merged into one full snapshot.
Not saved: `~/.cache`, `/tmp`, `/var/cache`.

## Desktop
Openbox + tint2 dock + pcmanfm desktop icons + conky widget, dark theme, Papirus icons.
- Dock: Terminal, Files, Web Browser (Firefox ESR), Text Editor, System Monitor, Settings, Power.
- Right-click desktop: menu. Middle-click: window list. Left-click: select icons.
- Keys: Super+Enter terminal, Super+E files, Super+B browser, Super+I settings, Super+D / Alt+F2 run,
  Super+Esc power, Super+Space menu, Print screenshot (to ~/Pictures), Alt+F4 close.
- Settings: terminal size, keyboard layout, time zone, desktop on boot, save now / full snapshot.

## Terminal
bash with colored prompt (shows last exit code), persistent history, completion, aliases (`ll`, `la`, `..`,
`mkcd`, `extract`), nano, mc, htop, tmux, curl, wget, ssh, fastfetch, jq. `mingo help` lists system commands.
`tsize 60` makes terminal windows 60% of the screen (default 40).

## Not included
Wi-Fi, sound, GPU firmware (graphics use the generic driver).
