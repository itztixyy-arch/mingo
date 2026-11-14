#!/usr/bin/env bash
# Mingo test VM (QEMU in WSL).  bash run-vm.sh [reset] [uefi] [debug] [show]
#   reset : discard the VM disk and start from a fresh out/mingo.img
#   uefi  : boot via UEFI (OVMF) instead of BIOS
#   debug : serial console in this terminal, full kernel log, gdb stub on :1234 (Ctrl+A X quits)
#   show  : list the mingo/ folder on the VM disk (version file + changes-N.mingo) and exit
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
VM="$D/vm"; DISK="$VM/mingo-vm.img"; W="$HOME/.mingo-build"
SUDO=""; [ "$(id -u)" = 0 ] || SUDO=sudo
mkdir -p "$VM"
reset=0; uefi=0; debug=0; show=0
for a in "$@"; do case $a in reset) reset=1;; uefi) uefi=1;; debug) debug=1;; show) show=1;; *) echo "bad arg $a"; exit 1;; esac; done

command -v qemu-system-x86_64 >/dev/null || $SUDO apt-get install -y -qq qemu-system-x86 qemu-system-gui ovmf mtools
[ "$reset" = 1 ] && rm -f "$DISK"
# VM disk older than the latest build -> recreate it (saved VM changes are dropped)
if [ -f "$DISK" ] && [ "$D/out/mingo.iso" -nt "$DISK" ]; then
  echo "run-vm: new build found, updating VM disk (old saved changes dropped)"; rm -f "$DISK"
fi
[ -f "$DISK" ] || cp "$D/out/mingo.iso" "$DISK"

if [ "$show" = 1 ]; then
  export MTOOLS_SKIP_CHECK=1
  mdir -i "$DISK@@1048576" -/ ::/mingo/changes; mdir -i "$DISK@@1048576" ::/mingo
  echo "--- current-version.txt:"; mtype -i "$DISK@@1048576" ::/mingo/current-version.txt
  exit 0
fi

# no network boot ROM (removes the iPXE delay), disk boots first
ARGS=(-name Mingo-VM -m 3G -smp 2 -usb -device usb-tablet -drive file="$DISK",format=raw -device intel-hda -audiodev pa,id=snd0 -device hda-duplex,audiodev=snd0
      -netdev user,id=n0 -device virtio-net-pci,netdev=n0,romfile= -boot order=c,menu=off)
[ -e /dev/kvm ] && ARGS+=(-enable-kvm -cpu host)
[ "$uefi" = 1 ] && ARGS+=(-bios /usr/share/ovmf/OVMF.fd)
if [ "$debug" = 1 ]; then
  ARGS+=(-nographic -s -kernel "$W/vmlinuz" -initrd "$W/initramfs.gz" -append "console=ttyS0 loglevel=7 nosplash")
else
  ARGS+=(-display gtk)
fi
exec qemu-system-x86_64 "${ARGS[@]}"
