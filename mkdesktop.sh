#!/usr/bin/env bash
# Generate desktop assets into the rootfs: wallpaper, Openbox theme "Mingo", Openbox rc.xml.
# Usage: mkdesktop.sh <rootdir>   (called by build.sh after the packages are installed)
set -euo pipefail
R=$1

echo "  wallpaper"
mkdir -p "$R/usr/share/mingo"
WP="$R/usr/share/mingo/wallpaper.png"
# soft colour blobs, heavily blurred (drawn small, then scaled up: fast and smooth)
convert -size 480x270 xc:'#0b1026' \
  -fill '#1d4ed8' -draw 'circle 60,40 60,-90' \
  -fill '#5b2bbf' -draw 'circle 150,230 150,80' \
  -fill '#0e7490' -draw 'circle 400,70 400,-60' \
  -fill '#be3a7c' -draw 'circle 330,270 330,170' \
  -fill '#f59e0b' -draw 'circle 470,250 470,215' \
  -blur 0x48 -resize '1920x1080!' -modulate 100,115 "$WP"

echo "  openbox theme"
T="$R/usr/share/themes/Mingo/openbox-3"
mkdir -p "$T"
# window buttons: round "traffic light" dots (12x12 xbm masks)
python3 - "$T" <<'PY'
import sys
d = sys.argv[1]
def xbm(name, fill):
    rows = []
    for y in range(12):
        bits = 0
        for x in range(12):
            if fill(x + 0.5 - 6, y + 0.5 - 6):
                bits |= 1 << x
        rows += [bits & 0xff, bits >> 8]
    data = ', '.join(f'0x{b:02x}' for b in rows)
    with open(f'{d}/{name}.xbm', 'w') as f:
        f.write(f'#define {name}_width 12\n#define {name}_height 12\nstatic unsigned char {name}_bits[] = {{ {data} }};\n')
dot = lambda x, y: x * x + y * y <= 25.5
ring = lambda x, y: 12 <= x * x + y * y <= 25.5
for n in ('close', 'iconify', 'max', 'desk', 'shade'):
    xbm(n, dot)
for n in ('max_toggled', 'desk_toggled', 'shade_toggled'):
    xbm(n, ring)
xbm('bullet', lambda x, y: abs(y) <= 3 - (x + 2) * 0.75 and -2 <= x <= 2)
PY
{
cat <<'EOF'
border.width: 0
padding.width: 12
padding.height: 9
window.handle.width: 0
window.client.padding.width: 0
window.label.text.justify: center
window.active.border.color: #2b313c
window.inactive.border.color: #22272f
window.active.title.separator.color: #262b33
window.inactive.title.separator.color: #20242b
window.active.title.bg: flat solid
window.active.title.bg.color: #262b33
window.inactive.title.bg: flat solid
window.inactive.title.bg.color: #1f232a
window.active.label.bg: parentrelative
window.inactive.label.bg: parentrelative
window.active.label.text.color: #e8edf3
window.inactive.label.text.color: #7d8794
window.active.handle.bg: flat solid
window.active.handle.bg.color: #262b33
window.inactive.handle.bg: flat solid
window.inactive.handle.bg.color: #1f232a
window.active.grip.bg: flat solid
window.active.grip.bg.color: #262b33
window.inactive.grip.bg: flat solid
window.inactive.grip.bg.color: #1f232a
menu.border.width: 1
menu.border.color: #3a404b
menu.overlap: 0
menu.title.bg: flat solid
menu.title.bg.color: #1d2129
menu.title.text.color: #8b97a6
menu.title.text.justify: left
menu.items.bg: flat solid
menu.items.bg.color: #1d2129
menu.items.text.color: #e8edf3
menu.items.disabled.text.color: #5c6672
menu.items.active.bg: flat solid
menu.items.active.bg.color: #3b82f6
menu.items.active.text.color: #ffffff
menu.separator.color: #343a44
menu.separator.width: 1
menu.separator.padding.width: 8
menu.separator.padding.height: 4
osd.border.width: 1
osd.border.color: #3a404b
osd.bg: flat solid
osd.bg.color: #1d2129
osd.label.bg: parentrelative
osd.label.text.color: #e8edf3
osd.hilight.bg: flat solid
osd.hilight.bg.color: #3b82f6
osd.unhilight.bg: flat solid
osd.unhilight.bg.color: #343a44
EOF
for w in active inactive; do
  if [ $w = active ]; then bg='#262b33'; else bg='#1f232a'; fi
  for st in unpressed hover pressed disabled toggled.unpressed toggled.hover toggled.pressed; do
    echo "window.$w.button.$st.bg: parentrelative"
    echo "window.$w.button.$st.bg.color: $bg"
    if [ $w = active ]; then c='#8b95a3'; else c='#4a515c'; fi
    case $st in hover|toggled.hover|pressed|toggled.pressed) c='#c4ccd6' ;; disabled) c='#3a404b' ;; esac
    echo "window.$w.button.$st.image.color: $c"
  done
done
# per-button colours (red / yellow / green) where Openbox supports them
for st in unpressed hover pressed toggled.unpressed toggled.hover; do
  echo "window.active.button.close.$st.image.color: #ff5f57"
  echo "window.active.button.iconify.$st.image.color: #febc2e"
  echo "window.active.button.max.$st.image.color: #28c840"
done
} > "$T/themerc"
# keep only our Openbox theme (GTK themes are left alone)
for t in "$R"/usr/share/themes/*/openbox-3; do
  [ "$t" = "$T" ] || rm -rf "$t"
done
find "$R/usr/share/themes" -mindepth 1 -maxdepth 1 -type d -empty -delete

echo "  openbox rc.xml"
mkdir -p "$R/root/.config/openbox"
x() { printf '<keybind key="%s"><action name="Execute"><command>%s</command></action></keybind>' "$1" "$2"; }
KEYS=$(x W-Return mingo-term)$(x W-e 'pcmanfm /root')$(x W-b firefox-esr)$(x W-i mingo-settings)
KEYS+=$(x Print mingo-shot)$(x W-space mingo-search)$(x W-d mingo-search)$(x A-F2 mingo-search)$(x W-Escape mingo-power)
KEYS+=$(x XF86AudioRaiseVolume 'mingo-volume up')$(x XF86AudioLowerVolume 'mingo-volume down')$(x XF86AudioMute 'mingo-volume mute')
KEYS+='<keybind key="W-Up"><action name="ToggleMaximize"/></keybind><keybind key="W-Down"><action name="Iconify"/></keybind>'
KEYS+='<keybind key="W-q"><action name="Close"/></keybind>'
# Apple-style title bar: close, minimize, zoom on the left, centered title, Inter font
sed -e '/<keybind key="W-e">/,/<\/keybind>/d' \
    -e 's|<name>Clearlooks</name>|<name>Mingo</name>|' \
    -e 's|<titleLayout>NLIMC</titleLayout>|<titleLayout>CIML</titleLayout>|' \
    -e 's|<name>sans</name>|<name>Inter</name>|g' \
    -e 's|<size>8</size>|<size>10</size>|g' \
    -e 's|<weight>bold</weight>|<weight>normal</weight>|g' \
    -e "s|</keyboard>|$KEYS</keyboard>|" \
    "$R/etc/xdg/openbox/rc.xml" > "$R/root/.config/openbox/rc.xml"
