#!/usr/bin/env bash
# Build the Mingo bootable USB image. Run as root inside WSL Ubuntu:
#   wsl -d Ubuntu -u root -- bash /mnt/d/PythonAndStuff/Minigo/build.sh
# Output: out/mingo.img (BIOS + UEFI). Flash it to a USB stick (2 GB or larger).
#
# Layout on the stick (FAT32, readable from Windows):
#   boot/             kernel, small initramfs, syslinux
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
  xterm xdpyinfo xrdb xsetroot xset setxkbmap"

# storage + filesystem drivers the initramfs needs to find and mount the stick
INITRD_MODS="xhci_pci xhci_hcd ehci_pci ehci_hcd ohci_pci ohci_hcd uhci_hcd usb_storage uas
  sd_mod sr_mod ahci ata_piix ata_generic pata_acpi nvme vmd mmc_block sdhci_pci sdhci_acpi
  virtio_pci virtio_blk virtio_scsi vfat nls_cp437 nls_iso8859_1 nls_utf8 squashfs overlay loop
  isofs usbhid hid_generic"

apt-get update -qq
apt-get install -y -qq curl cpio gzip zstd binutils kmod fdisk dosfstools mtools squashfs-tools python3 \
  syslinux syslinux-common grub-common grub-efi-amd64-bin imagemagick fonts-dejavu-core

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
rm -f root/dev/null root/dev/zero root/dev/random root/dev/urandom
rm -f root/etc/resolv.conf; ln -s /run/resolv.conf root/etc/resolv.conf   # keeps DHCP DNS out of saved changes

echo "== kernel + modules (Alpine linux-lts)"
KAPK=$(curl -fsSL "$MIRROR/main/x86_64/" | grep -o 'linux-lts-[0-9][^"<]*\.apk' | sort -uV | tail -1)
curl -fsSL -o k.apk "$MIRROR/main/x86_64/$KAPK"
tar -xzf k.apk -C k 2>/dev/null || true
[ -f k/boot/vmlinuz-lts ] || { echo "kernel extract failed"; exit 1; }
KVER=$(ls k/lib/modules)
M=k/lib/modules/$KVER
# trim size: no sound/media/wifi/staging/big GPU drivers (display uses efifb/vesa/simpledrm)
rm -rf $M/kernel/sound $M/kernel/drivers/media $M/kernel/drivers/infiniband \
  $M/kernel/drivers/staging $M/kernel/net/wireless $M/kernel/drivers/net/wireless \
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

echo "== boot configs"
cat > syslinux.cfg <<'EOF'
DEFAULT mingo
PROMPT 0
TIMEOUT 0
NOESCAPE 0
# hold Shift while booting to get a boot: prompt and type one of these labels
LABEL mingo
  KERNEL /boot/vmlinuz
  INITRD /boot/initramfs.gz
  APPEND quiet loglevel=3 vt.global_cursor_default=0
LABEL toram
  KERNEL /boot/vmlinuz
  INITRD /boot/initramfs.gz
  APPEND quiet loglevel=3 vt.global_cursor_default=0 toram
LABEL safe
  KERNEL /boot/vmlinuz
  INITRD /boot/initramfs.gz
  APPEND nomodeset nosplash
EOF
cat > grub.cfg <<'EOF'
set timeout=0
set timeout_style=hidden
search --no-floppy --file --set=root /mingo/system.sfs
linux /boot/vmlinuz quiet loglevel=3 vt.global_cursor_default=0
initrd /boot/initramfs.gz
boot
EOF
grub-mkstandalone -O x86_64-efi -o BOOTX64.EFI \
  --modules="part_msdos part_gpt fat search search_fs_file normal linux echo" \
  "boot/grub/grub.cfg=grub.cfg"

IMG_MB=$(( SFS_MB + 64 + FREE_MB ))
echo "== disk image ($IMG_MB MB)"
IMG="$OUT/mingo.img"; OFF=$((2048*512))
rm -f "$IMG"; truncate -s ${IMG_MB}M "$IMG"
printf 'label: dos\nstart=2048, type=c, bootable\n' | sfdisk -q "$IMG"
mkfs.vfat -F 32 -n MINGO --offset 2048 "$IMG" $(( (IMG_MB*2048 - 2048) / 2 )) >/dev/null
mmd   -i "$IMG@@$OFF" ::/boot ::/boot/syslinux ::/EFI ::/EFI/BOOT ::/mingo ::/mingo/changes
syslinux --offset $OFF --directory /boot/syslinux --install "$IMG"
dd if=/usr/lib/syslinux/mbr/mbr.bin of="$IMG" bs=440 count=1 conv=notrunc status=none
mcopy -i "$IMG@@$OFF" vmlinuz initramfs.gz ::/boot/
mcopy -i "$IMG@@$OFF" syslinux.cfg ::/boot/syslinux/syslinux.cfg
mcopy -i "$IMG@@$OFF" BOOTX64.EFI ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG@@$OFF" system.sfs ::/mingo/system.sfs
echo 0 > current-version.txt
mcopy -i "$IMG@@$OFF" current-version.txt ::/mingo/current-version.txt
mcopy -i "$IMG@@$OFF" current-version.txt ::/mingo/full-version.txt
# release files (what mingo-update downloads)
mkdir -p "$OUT/release" && rm -f "$OUT/release/"*
cp vmlinuz initramfs.gz system.sfs "$OUT/release/"
(cd "$OUT/release" && sha256sum vmlinuz initramfs.gz system.sfs > SHA256SUMS)
mdir -i "$IMG@@$OFF" -/ ::
echo "DONE: $IMG (Mingo $VERSION)"
