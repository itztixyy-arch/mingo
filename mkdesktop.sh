#!/usr/bin/env bash
# Generate desktop assets into the rootfs: wallpaper, Openbox theme "Mingo", Openbox rc.xml.
# Usage: mkdesktop.sh <rootdir>   (called by build.sh after the packages are installed)
set -euo pipefail
R=$1

echo "  wallpaper"
mkdir -p "$R/usr/share/mingo"
WP="$R/usr/share/mingo/wallpaper.png"
convert -size 1920x1080 radial-gradient:'#27506f-#09131c' \
  -font DejaVu-Sans-Bold -pointsize 280 -fill '#ffffff10' -gravity center -annotate +0+0 'mingo' "$WP" 2>/dev/null \
  || convert -size 1920x1080 radial-gradient:'#27506f-#09131c' "$WP"

echo "  openbox theme"
T="$R/usr/share/themes/Mingo/openbox-3"
mkdir -p "$T"
# button glyphs (xbm) and menu bullet come from stock themes
cp "$R"/usr/share/themes/Bear2/openbox-3/*.xbm "$T"/ 2>/dev/null || true
cp "$R"/usr/share/themes/Mikachu/openbox-3/bullet.xbm "$T"/ 2>/dev/null || true
{
cat <<'EOF'
border.width: 1
padding.width: 10
padding.height: 7
window.handle.width: 0
window.client.padding.width: 0
window.label.text.justify: left
window.active.border.color: #3a5f82
window.inactive.border.color: #1b2a38
window.active.title.separator.color: #1b2b3a
window.inactive.title.separator.color: #121c27
window.active.title.bg: flat solid
window.active.title.bg.color: #1b2b3a
window.inactive.title.bg: flat solid
window.inactive.title.bg.color: #121c27
window.active.label.bg: parentrelative
window.inactive.label.bg: parentrelative
window.active.label.text.color: #e6eef7
window.inactive.label.text.color: #6f8396
window.active.handle.bg: flat solid
window.active.handle.bg.color: #1b2b3a
window.inactive.handle.bg: flat solid
window.inactive.handle.bg.color: #121c27
window.active.grip.bg: flat solid
window.active.grip.bg.color: #1b2b3a
window.inactive.grip.bg: flat solid
window.inactive.grip.bg.color: #121c27
menu.border.width: 1
menu.border.color: #3a5f82
menu.overlap: 0
menu.title.bg: flat solid
menu.title.bg.color: #1b2b3a
menu.title.text.color: #e6eef7
menu.title.text.justify: center
menu.items.bg: flat solid
menu.items.bg.color: #101a24
menu.items.text.color: #d8e2ec
menu.items.disabled.text.color: #55677a
menu.items.active.bg: flat solid
menu.items.active.bg.color: #3b6ea5
menu.items.active.text.color: #ffffff
menu.separator.color: #2a4157
menu.separator.width: 1
menu.separator.padding.width: 6
menu.separator.padding.height: 3
osd.border.width: 1
osd.border.color: #3a5f82
osd.bg: flat solid
osd.bg.color: #101a24
osd.label.bg: parentrelative
osd.label.text.color: #e6eef7
osd.hilight.bg: flat solid
osd.hilight.bg.color: #3b6ea5
osd.unhilight.bg: flat solid
osd.unhilight.bg.color: #2a4157
EOF
for w in active inactive; do
  if [ $w = active ]; then base='#1b2b3a'; img='#9fb4c8'; hov='#2f4a63'; else base='#121c27'; img='#55677a'; hov='#1b2b3a'; fi
  for s in unpressed:"$base":"$img" hover:"$hov":'#ffffff' pressed:'#3b6ea5':'#ffffff' disabled:"$base":'#3a4a5a' \
           toggled.unpressed:"$base":'#5aa9e6' toggled.hover:"$hov":'#5aa9e6' toggled.pressed:'#3b6ea5':'#ffffff'; do
    IFS=: read -r st bg ic <<<"$s"
    echo "window.$w.button.$st.bg: flat solid"
    echo "window.$w.button.$st.bg.color: $bg"
    echo "window.$w.button.$st.image.color: $ic"
  done
done
} > "$T/themerc"
# keep only our Openbox theme (GTK themes are left alone)
for t in "$R"/usr/share/themes/*/openbox-3; do
  [ "$t" = "$T" ] || rm -rf "$t"
done
find "$R/usr/share/themes" -mindepth 1 -maxdepth 1 -type d -empty -delete

echo "  openbox rc.xml"
mkdir -p "$R/root/.config/openbox"
KEYS='<keybind key="W-Return"><action name="Execute"><command>mingo-term</command></action></keybind>'
KEYS+='<keybind key="W-e"><action name="Execute"><command>pcmanfm /root</command></action></keybind>'
KEYS+='<keybind key="W-b"><action name="Execute"><command>firefox-esr</command></action></keybind>'
KEYS+='<keybind key="W-i"><action name="Execute"><command>mingo-settings</command></action></keybind>'
KEYS+='<keybind key="Print"><action name="Execute"><command>mingo-shot</command></action></keybind>'
KEYS+='<keybind key="W-d"><action name="Execute"><command>mingo-run</command></action></keybind>'
KEYS+='<keybind key="A-F2"><action name="Execute"><command>mingo-run</command></action></keybind>'
KEYS+='<keybind key="W-Escape"><action name="Execute"><command>mingo-power</command></action></keybind>'
KEYS+='<keybind key="W-space"><action name="ShowMenu"><menu>root-menu</menu></action></keybind>'
# drop the stock Super+E binding (we bind it to the file manager) and stock theme
sed -e '/<keybind key="W-e">/,/<\/keybind>/d' \
    -e 's|<name>Clearlooks</name>|<name>Mingo</name>|' \
    -e 's|<size>8</size>|<size>10</size>|g' \
    -e "s|</keyboard>|$KEYS</keyboard>|" \
    "$R/etc/xdg/openbox/rc.xml" > "$R/root/.config/openbox/rc.xml"
