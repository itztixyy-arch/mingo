#!/usr/bin/env bash
# Build the Mingo bootable USB image. Run as root inside WSL Ubuntu:
#   wsl -d Ubuntu -u root -- bash /mnt/d/PythonAndStuff/Minigo/build.sh
# Output: out/mingo.iso, a hybrid ISO (BIOS + UEFI). Flash it in DD mode (Rufus "DD Image",
# balenaEtcher) to a USB stick (4 GB or larger).
#
# The ISO holds only the GRUB boot loaders. Appended to it is partition 2, a FAT32 partition
# "MINGO" (readable and writable from Windows) that holds everything else:
#   boot/             kernel, small initramfs
#   EFI/BOOT/         UEFI loader
#   mingo/system.sfs  the whole OS, compressed (mounted read-only under a RAM overlay)
#   mingo/current-version.txt, mingo/full-version.txt, mingo/changes/changes-N.mingo
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root: wsl -d Ubuntu -u root -- bash build.sh"; exit 1; }

SRC="$(cd "$(dirname "$0")" && pwd)"
OUT="$SRC/out"
W="$HOME/.mingo-build"            # build on ext4, not /mnt/d (symlinks, permissions, speed)
MIRROR=https://dl-cdn.alpinelinux.org/alpine/latest-stable
FREE_MB=${FREE_MB:-768}           # space left on the stick for saved changes and updates
VERSION=$(tr -dc '0-9A-Za-z.-' < "$SRC/VERSION")
# GitHub repo the OS updates itself from (owner/name)
REPO=${MINGO_REPO:-${GITHUB_REPOSITORY:-$(tr -dc '0-9A-Za-z._/-' < "$SRC/UPDATE_REPO" 2>/dev/null || true)}}
export MTOOLS_SKIP_CHECK=1

PKGS="kmod bash bash-completion nano less htop mc tmux curl wget openssh-client coreutils util-linux
  pciutils usbutils procps-ng tree jq file e2fsprogs dosfstools gawk grep sed findutils tar unzip zip
  fastfetch ncurses tzdata
  eudev xorg-server xinit xf86-input-libinput xf86-video-fbdev xf86-video-vesa mesa-dri-gallium
  dbus dbus-x11 font-dejavu papirus-icon-theme yad
  openbox tint2 picom conky feh dmenu scrot xdotool lxterminal pcmanfm mousepad firefox-esr
  xterm xdpyinfo xrdb xsetroot xset setxkbmap xdg-utils
  font-inter adw-gtk3 rofi dunst libnotify python3 py3-gobject3 py3-cairo py3-xlib libwnck3 gtk+3.0
  networkmanager networkmanager-wifi networkmanager-tui network-manager-applet wpa_supplicant
  pipewire wireplumber pipewire-pulse pipewire-alsa alsa-utils alsa-ucm-conf pavucontrol sof-firmware
  linux-firmware-intel linux-firmware-i915 linux-firmware-rtw88 linux-firmware-rtw89 linux-firmware-rtlwifi
  linux-firmware-ath10k linux-firmware-ath11k linux-firmware-mediatek linux-firmware-brcm
  linux-firmware-cypress linux-firmware-other"

# storage + filesystem drivers the initramfs needs to find and mount the stick
INITRD_MODS="xhci_pci xhci_hcd ehci_pci ehci_hcd ohci_pci ohci_hcd uhci_hcd usb_storage uas
  sd_mod sr_mod ahci ata_piix ata_generic pata_acpi nvme vmd mmc_block sdhci_pci sdhci_acpi
  virtio_pci virtio_blk virtio_scsi vfat nls_cp437 nls_iso8859_1 nls_utf8 squashfs overlay loop
  isofs usbhid hid_generic"

apt-get update -qq
apt-get install -y -qq curl cpio gzip zstd binutils kmod fdisk dosfstools mtools squashfs-tools python3 \
  xorriso grub-common grub-pc-bin grub-efi-amd64-bin imagemagick fonts-dejavu-core

rm -rf "$W"; mkdir -p "$W/root" "$W/k" "$W/initrd" "$OUT"; cd "$W"

echo "== Mingo $VERSION (updates from: ${REPO:-none})"
echo "== rootfs (Alpine $(curl -fsSL "$MIRROR/releases/x86_64/latest-releases.yaml" | awk '/version:/{print $2; exit}'))"
MR=$(curl -fsSL "$MIRROR/releases/x86_64/" | grep -o 'alpine-minirootfs-[0-9.]*-x86_64\.tar\.gz' | sort -uV | tail -1)
curl -fsSL -o mr.tgz "$MIRROR/releases/x86_64/$MR"
tar -xzf mr.tgz -C root

echo "== packages (apk in chroot)"
printf '%s/main\n%s/community\n' "$MIRROR" "$MIRROR" > root/etc/apk/repositories
cp -L /etc/resolv.conf root/etc/resolv.conf
for n in "null 1 3" "zero 1 5" "random 1 8" "urandom 1 9"; do
  set -- $n; mknod -m 666 "root/dev/$1" c "$2" "$3"
done
# shellcheck disable=SC2086
if ! chroot root /sbin/apk add --no-cache $PKGS; then
  echo "bulk install failed, retrying one by one"
  for p in $PKGS; do chroot root /sbin/apk add --no-cache "$p" >/dev/null 2>&1 && echo "  + $p" || echo "  !! $p FAILED"; done
fi
chroot root udevadm hwdb --update 2>/dev/null || true
rm -rf root/var/cache/apk/* root/usr/share/man root/usr/share/doc root/usr/share/info root/usr/share/gtk-doc
rm -rf root/lib/firmware/intel/ipu* root/lib/firmware/intel/vpu   # camera/AI firmware: large, not needed
rm -f root/dev/null root/dev/zero root/dev/random root/dev/urandom
rm -f root/etc/resolv.conf; ln -s /run/resolv.conf root/etc/resolv.conf   # keeps DHCP DNS out of saved changes

echo "== kernel + modules (Alpine linux-lts)"
KAPK=$(curl -fsSL "$MIRROR/main/x86_64/" | grep -o 'linux-lts-[0-9][^"<]*\.apk' | sort -uV | tail -1)
curl -fsSL -o k.apk "$MIRROR/main/x86_64/$KAPK"
tar -xzf k.apk -C k 2>/dev/null || true
[ -f k/boot/vmlinuz-lts ] || { echo "kernel extract failed"; exit 1; }
KVER=$(ls k/lib/modules)
M=k/lib/modules/$KVER
# trim size: no TV/camera, InfiniBand or big AMD/NVIDIA GPU drivers (display uses i915/efifb/vesa)
rm -rf $M/kernel/drivers/media $M/kernel/drivers/infiniband \
  $M/kernel/drivers/gpu/drm/amd $M/kernel/drivers/gpu/drm/nouveau $M/kernel/drivers/gpu/drm/radeon
mkdir -p root/lib && cp -a k/lib/modules root/lib/
chroot root depmod -a "$KVER"          # Alpine's kmod (handles compressed modules)
grep -qs '^CONFIG_SQUASHFS_ZSTD=y' k/boot/config* && COMP=zstd || COMP=xz

echo "== Mingo overlay"
cp -a "$SRC/overlay/." root/
# files copied from Windows (drvfs) come in as 777 / CRLF-risky: normalize
(cd "$SRC/overlay" && find . -type f) | while read -r f; do sed -i 's/\r$//' "root/$f"; chmod 644 "root/$f"; done
(cd "$SRC/overlay" && find . -mindepth 1 -type d) | while read -r d; do chmod 755 "root/$d"; done
chmod 700 root/root
(cd "$SRC/overlay/usr/bin" && ls) | while read -r f; do chmod 755 "root/usr/bin/$f"; done
chmod 755 root/etc/init.d/rcS root/etc/init.d/rcK root/usr/share/udhcpc/mingo.script root/root/.xinitrc \
  root/root/Desktop/*.desktop
mkdir -p root/root/Documents root/root/Downloads root/root/Music root/root/Pictures root/root/Videos root/mnt/mingo
echo "$VERSION" > root/etc/mingo-release
echo "REPO=$REPO" > root/etc/mingo-update.conf
sed -i "s/@VERSION@/$VERSION/" root/etc/motd
: > root/etc/mingo-autodesktop        # boot straight into the desktop (mingo autodesktop off to disable)
echo "UTC" > root/etc/timezone
[ -x root/bin/bash ] && sed -i 's|^root:\(.*\):/bin/[a-z]*sh$|root:\1:/bin/bash|' root/etc/passwd
for a in reboot poweroff halt; do ln -sf ../bin/busybox "root/sbin/$a"; done
echo "== desktop assets"
bash "$SRC/mkdesktop.sh" root
# hide duplicate launchers (Mingo has its own Terminal entry)
for d in xterm uxterm lxterminal; do
  f=root/usr/share/applications/$d.desktop; [ -f "$f" ] && echo "NoDisplay=true" >> "$f"
done
for f in usr/bin/firefox-esr usr/bin/pcmanfm usr/bin/lxterminal usr/bin/mousepad usr/bin/startx usr/bin/openbox \
         usr/share/applications/firefox-esr.desktop usr/share/applications/org.xfce.mousepad.desktop \
         usr/share/applications/pcmanfm.desktop usr/share/applications/feh.desktop; do
  [ -e "root/$f" ] || echo "  WARN: missing /$f"
done

echo "== initramfs (small: just enough to find the stick)"
I=initrd
mkdir -p $I/bin $I/sbin $I/usr/bin $I/etc $I/lib $I/dev $I/proc $I/sys $I/run $I/tmp
cp root/bin/busybox $I/bin/
for lib in $(readelf -d root/bin/busybox | awk -F'[][]' '/NEEDED/{print $2}') ld-musl-x86_64.so.1; do
  cp -L "$(find root/lib root/usr/lib -maxdepth 1 -name "$lib" | head -1)" $I/lib/
done
for a in $(chroot $I /bin/busybox --list-full); do
  mkdir -p "$I/$(dirname "$a")"; [ -e "$I/$a" ] || ln -s /bin/busybox "$I/$a"
done
cp "$SRC/initramfs/init" $I/init
cp root/usr/bin/mingo-splash $I/usr/bin/mingo-splash
sed -i 's/\r$//' $I/init $I/usr/bin/mingo-splash
chmod 755 $I/init $I/usr/bin/mingo-splash
echo "$INITRD_MODS" | tr -s ' \n' '\n' | sed '/^$/d' > $I/etc/mingo-modules
# copy the wanted modules plus their dependencies, uncompressed (busybox modprobe)
python3 - "root/lib/modules/$KVER" "$I/lib/modules/$KVER" $INITRD_MODS <<'PY'
import gzip, os, shutil, subprocess, sys
src, dst, want = sys.argv[1], sys.argv[2], sys.argv[3:]
dep, byname = {}, {}
for line in open(os.path.join(src, 'modules.dep')):
    k, _, v = line.partition(':')
    k = k.strip(); dep[k] = v.split()
    byname[os.path.basename(k).split('.ko')[0].replace('-', '_')] = k
keep = set()
def add(p):
    if p not in keep:
        keep.add(p)
        for d in dep.get(p, []): add(d)
for w in want:
    if w.replace('-', '_') in byname: add(byname[w.replace('-', '_')])
plain = lambda p: p.split('.ko')[0] + '.ko'
for p in keep:
    out = os.path.join(dst, plain(p)); os.makedirs(os.path.dirname(out), exist_ok=True)
    s = os.path.join(src, p)
    if p.endswith('.gz'):
        with gzip.open(s) as a, open(out, 'wb') as b: shutil.copyfileobj(a, b)
    elif p.endswith('.zst'):
        subprocess.run(['zstd', '-q', '-d', '-f', s, '-o', out], check=True)
    elif p.endswith('.xz'):
        subprocess.run(['sh', '-c', f'xz -dc "{s}" > "{out}"'], check=True)
    else:
        shutil.copy(s, out)
with open(os.path.join(dst, 'modules.dep'), 'w') as f:
    for p in sorted(keep): f.write(plain(p) + ': ' + ' '.join(plain(d) for d in dep[p]) + '\n')
for name in ('modules.alias', 'modules.builtin', 'modules.order'):
    if os.path.exists(os.path.join(src, name)): shutil.copy(os.path.join(src, name), dst)
print(f'  {len(keep)} modules in initramfs')
PY
(cd $I && find . | cpio -o -H newc -R 0:0 --quiet | gzip -9) > initramfs.gz
cp k/boot/vmlinuz-lts vmlinuz

echo "== system.sfs ($COMP)"
mksquashfs root system.sfs -comp $COMP -noappend -all-root -quiet
SFS_MB=$(( $(stat -c %s system.sfs) / 1048576 + 1 ))
echo "  system.sfs: ${SFS_MB} MB"

echo "== boot loader (GRUB, BIOS + UEFI)"
# The config is stored in three places so it is found however the firmware boots us:
#   - built into both loaders (bios.img and BOOTX64.EFI)
#   - as /boot/grub/grub.cfg on the MINGO partition (some firmware boots the FAT
#     partition directly instead of the ISO's El Torito entry)
#   - as /boot/grub/grub.cfg on the ISO itself
# Keep it a flat list of commands: the config the GRUB core runs at start-up is
# executed line by line, where if/then/fi do not exist yet ("Unknown command if").
# The message after `boot` is only reached when the boot failed, so the user
# never gets a bare "grub>" prompt without being told what is wrong.
cat > grub.cfg <<'EOF'
set timeout=0
set timeout_style=hidden
insmod all_video
insmod part_msdos
insmod part_gpt
insmod fat
insmod search_fs_file

# The MINGO partition is the one holding mingo/system.sfs.
search --no-floppy --file --set=root /mingo/system.sfs
linux /boot/vmlinuz quiet loglevel=3 vt.global_cursor_default=0
initrd /boot/initramfs.gz
boot

echo
echo "MINGO: could not boot from this stick."
echo "Either mingo/system.sfs is missing, or the stick is damaged."
echo "If Rufus asked, use DD Image mode - ISO Image mode drops the MINGO"
echo "partition, which is where the system lives. Or use balenaEtcher."
echo
echo "Disks GRUB can see:"
ls
echo
echo "Press any key to continue to the GRUB prompt."
sleep 60
EOF
GRUB_MODS="part_msdos part_gpt fat iso9660 search search_fs_file normal linux echo configfile all_video sleep"
grub-mkstandalone -O x86_64-efi -o BOOTX64.EFI --modules="$GRUB_MODS" "boot/grub/grub.cfg=grub.cfg"
# BIOS: small core image with the config built in (a standalone image is too big for El Torito)
grep -v -e '^insmod all_video' -e '^set timeout' grub.cfg > grub-bios.cfg
grub-mkimage -O i386-pc-eltorito -o bios.img -p /boot/grub -c grub-bios.cfg \
  biosdisk part_msdos part_gpt fat iso9660 search search_fs_file linux normal echo sleep

DATA_MB=$(( SFS_MB + 64 + FREE_MB ))
echo "== MINGO data partition ($DATA_MB MB)"
rm -f data.img; truncate -s ${DATA_MB}M data.img
mkfs.vfat -F 32 -n MINGO data.img >/dev/null
mmd   -i data.img ::/boot ::/boot/grub ::/EFI ::/EFI/BOOT ::/mingo ::/mingo/changes
mcopy -i data.img vmlinuz initramfs.gz ::/boot/
mcopy -i data.img grub.cfg ::/boot/grub/grub.cfg
mcopy -i data.img BOOTX64.EFI ::/EFI/BOOT/BOOTX64.EFI
mcopy -i data.img system.sfs ::/mingo/system.sfs
echo 0 > current-version.txt
mcopy -i data.img current-version.txt ::/mingo/current-version.txt
mcopy -i data.img current-version.txt ::/mingo/full-version.txt

echo "== hybrid ISO"
rm -rf isoroot; mkdir -p isoroot/boot/grub
cp bios.img isoroot/boot/grub/bios.img
cp grub.cfg isoroot/boot/grub/grub.cfg
truncate -s $(( $(stat -c %s BOOTX64.EFI) / 1048576 + 3 ))M isoroot/boot/grub/efi.img && mkfs.vfat -n MINGO_EFI isoroot/boot/grub/efi.img >/dev/null
mmd -i isoroot/boot/grub/efi.img ::/EFI ::/EFI/BOOT
mcopy -i isoroot/boot/grub/efi.img BOOTX64.EFI ::/EFI/BOOT/BOOTX64.EFI
printf 'Mingo %s\r\nFlash this ISO to a USB stick in DD mode (Rufus: "DD Image", or balenaEtcher).\r\nYour files are saved on the stick partition named MINGO.\r\n' "$VERSION" > isoroot/README.TXT
ISO="$OUT/mingo.iso"
rm -f "$ISO" "$OUT/mingo.img"
xorriso -as mkisofs -o "$ISO" -V MINGO_BOOT -R -J -quiet \
  --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img -partition_offset 16 --mbr-force-bootable \
  -b boot/grub/bios.img -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
  -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot \
  -append_partition 2 0x0c data.img \
  isoroot
# release files (what mingo-update downloads)
mkdir -p "$OUT/release" && rm -f "$OUT/release/"*
cp vmlinuz initramfs.gz system.sfs "$OUT/release/"
(cd "$OUT/release" && sha256sum vmlinuz initramfs.gz system.sfs > SHA256SUMS)
fdisk -l "$ISO" | tail -3
echo "DONE: $ISO ($(( $(stat -c %s "$ISO") / 1048576 )) MB, Mingo $VERSION)"
