#!/bin/bash
# Installs the render-ahead buffer next to the Meditation Room (Linux) (run after linux/install.sh). Does NOT switch it on:
# `mrbuffer on` does (it restarts the encoder). Run on the VM from a checkout of MANTRA_ROOM: bash ~/MANTRA_ROOM/linux/install-mrbuffer.sh
set -e
D=$(cd "$(dirname "$0")" && pwd)
sudo install -d /usr/local/lib/meditation-room-linux
# the encoder hooks (out_args, CLOCK, AHEAD, getattr(enc, "lead")) must be in the installed meditation_room_linux.py
if ! grep -q "def out_args" /usr/local/lib/meditation-room-linux/meditation_room_linux.py 2>/dev/null; then
  sudo install -m 755 "$D/meditation_room_linux.py" /usr/local/lib/meditation-room-linux/
  echo "meditation_room_linux.py updated (hooks); the running encoder keeps the old copy until it restarts"
fi
sudo install -m 755 "$D/mrbuffer.py" "$D/mrbuffer" /usr/local/lib/meditation-room-linux/
sudo install -m 644 "$D/systemd/meditation-room-linux.mrbuffer.conf" "$D/buftest-relay.yml" /usr/local/lib/meditation-room-linux/
sudo install -m 644 "$D/systemd/mrbuffer-publish.service" /etc/systemd/system/
sudo ln -sf /usr/local/lib/meditation-room-linux/mrbuffer /usr/local/bin/mrbuffer
sudo systemctl daemon-reload
echo "installed: mrbuffer on|off|status (render-ahead is switched on only by 'mrbuffer on')"
