#!/bin/sh
xrdb -merge "$HOME/.Xresources"
xset s off -dpms
xsetroot -solid '#0e1822' -cursor_name left_ptr
k=$(cat "$HOME/.config/mingo/keyboard" 2>/dev/null) && [ -n "$k" ] && setxkbmap "$k"
if command -v dbus-launch >/dev/null 2>&1; then
  exec dbus-launch --exit-with-session /usr/bin/mingo-session
fi
exec /usr/bin/mingo-session
