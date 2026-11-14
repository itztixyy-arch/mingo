# Mingo

Linux that lives on a USB stick: plug in, boot, use, and your changes are saved back to the stick.
BIOS + UEFI (Secure Boot off). Based on Alpine Linux (latest stable), runs from a compressed system file
with a RAM layer on top. Wi-Fi, sound, a macOS-style desktop. Needs 2 GB+ RAM and a 4 GB+ USB stick.

## Build
`wsl -d Ubuntu -u root -- bash /mnt/d/PythonAndStuff/Minigo/build.sh` -> `out\mingo.iso`

## Test VM (QEMU in WSL, window via WSLg)
```
.\run-vm.ps1            # VM window (disk: vm\mingo-vm.img; recreated automatically after a new build)
.\run-vm.ps1 reset      # fresh VM disk
.\run-vm.ps1 uefi       # UEFI boot
.\run-vm.ps1 debug      # serial shell + kernel log in this terminal, gdb stub :1234, Ctrl+A X quits
.\run-vm.ps1 show       # list saved changes on the VM disk
```
`out\mingo.iso` can also be attached as a DVD/CD in VirtualBox or QEMU and booted directly, with no
stick. Booting from a disc is slower (about a minute and a half) and nothing is saved: the disc is
read-only.

## Flash
Write `out\mingo.iso` (from a release: unpack `mingo.iso.xz` with 7-Zip) to a 4 GB+ USB stick with
balenaEtcher or Rufus. **Erases the whole stick.** Both Rufus modes work:
- **DD Image** (and balenaEtcher): partition 1 = the system (read-only), partition 2 = `MINGO` (FAT32)
  for your saved changes and installed updates.
- **ISO Image**: one FAT32 partition with everything.

## What is on the stick
```
boot\                         kernel + small start-up image
EFI\BOOT\                     UEFI loader
mingo\system.sfs              the whole operating system (compressed, read-only)
mingo\current-version.txt     number of the latest save
mingoull-version.txt        save number of the last full snapshot
mingo\changes\changes-N.mingo one file per save (tar.gz of changed files + list of deleted files)
mingo\debug.txt               boot report, only when booted with the mingodebug option
```

## Boot
Graphical boot screen (logo, progress bar, current step), text version where there is no graphics.
Fast: the firmware only loads the kernel and a small start-up image; Linux then reads the system from
the stick itself. It boots straight into the desktop (`mingo autodesktop off` boots to the terminal).
Boot options (GRUB): `toram` (copy the system to RAM), `nosplash`, `mingodebug` (write a boot report to
`mingo\debug.txt` on the stick).

## Troubleshooting
- Black `grub>` prompt: GRUB could not find `boot/vmlinuz`; it now says so and lists the disks it sees.
  Rewrite the stick and let the writer finish.
- If start-up cannot find the system, it stops with a message and the list of disks instead of
  restarting the boot (that looked like a loading bar that loops), and opens a rescue shell.

## Your files
Home folder is `/root` with `Desktop`, `Documents`, `Downloads`, `Pictures`, `Music`, `Videos` (like a Windows
user folder). Everything you change anywhere is saved: at shutdown/reboot, every 3 minutes, or with `mingo save`.
Only changed files are saved; after 25 saves or 128 MB of saves they are merged into one full snapshot.
Not saved: `~/.cache`, `/tmp`, `/var/cache`.

## Desktop
macOS-style: top bar (Mingo menu, search, Wi-Fi, volume, battery, clock), dock at the bottom,
red/yellow/green window buttons, soft shadows and open/close animations, notifications.
- **Dock**: pinned apps plus every open app; a line under apps with an open window (blue = active app).
  Icons grow under the pointer. Right-click an icon: Keep in Dock / Remove from Dock / Quit.
- **Search**: tap **Super** (Windows key) for apps, settings, folders, files and actions; Alt+P pins the
  selected app to the dock; text that matches nothing searches the web.
- **Wi-Fi**: network icon in the top bar (NetworkManager). Common Intel, Realtek, Atheros, MediaTek and
  Broadcom cards work out of the box.
- **Sound**: PipeWire; volume icon in the top bar (click for a slider), volume keys work.
- Keys: Super+Enter terminal, Super+E files, Super+B browser, Super+I settings, Super+Esc power,
  Super+Up maximize, Super+Down minimize, Super+Q close, Print screenshot.
- Settings window: terminal size, keyboard, time zone, desktop at boot, wallpaper, displays, App Center,
  Wi-Fi, sound, dock apps, save now, check for updates.
- **App Center**: tick apps to install (Chromium, Thunderbird, LibreOffice, GIMP, VLC, OBS, ...); they are
  saved to the stick. **Wallpapers**: six built in, or any picture of your own.
- Brightness and media keys (play/pause/next/previous) work.

## Terminal
bash with colored prompt (shows last exit code), persistent history, completion, aliases (`ll`, `la`, `..`,
`mkcd`, `extract`), nano, mc, htop, tmux, curl, wget, ssh, fastfetch, jq. `mingo help` lists system commands.
`tsize 60` makes terminal windows 60% of the screen (default 40).

## Updates
Mingo updates itself from this repo's GitHub releases. On the desktop it offers new versions
automatically; or use Settings > Check for updates, or `mingo update` in a terminal. The new system is
downloaded to `mingo/update/` on the stick, checked, and installed at the next restart (one extra
automatic restart). Saved files and settings are kept.

Release a new version: bump `VERSION`, commit, then `git tag vX.Y.Z && git push origin main --tags`.
GitHub Actions builds it (about 20 min) and publishes the release: `mingo.iso` for flashing, plus
`system.sfs`, `vmlinuz`, `initramfs.gz`, `SHA256SUMS` for the updater.

## Not included
Bluetooth, AMD/NVIDIA GPU drivers (those use the generic display driver).
