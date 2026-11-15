#!/bin/bash
# Installs the Meditation Room (Linux) test stream on chromium-vm. Run on the VM from a checkout of MANTRA_ROOM:
#   bash ~/MANTRA_ROOM/linux/install.sh
# Audio = the repo's own files (git, the VM's own download; never from the Mac's SIM). Units are NOT enabled at boot.
set -e
D=$(cd "$(dirname "$0")" && pwd)
sudo install -d /usr/local/lib/meditation-room-linux
sudo install -m 755 "$D/meditation_room_linux.py" "$D/mrlinux" "$D/mrvisuals.py" "$D/milkrender.py" /usr/local/lib/meditation-room-linux/
# the changing visuals: the clip player (mrvisuals.py) and the offline MilkDrop renderer (milkrender.py + page), which read the
# vendor (butterchurn), the audio and the guide's spoken lines from ~ubuntu/MANTRA_ROOM (this sparse checkout)
sudo install -d /usr/local/lib/meditation-room-linux/milkrender
sudo install -m 644 "$D/milkrender/page.html" /usr/local/lib/meditation-room-linux/milkrender/
R=$(dirname "$D")
if git -C "$R" sparse-checkout list >/dev/null 2>&1 && ! git -C "$R" sparse-checkout list | grep -qx "mac/web/lines"; then
  git -C "$R" sparse-checkout add mac/web/lines
fi
mkdir -p /home/ubuntu/mrvisuals/clips
sudo install -m 644 "$D/mrlinux-relay.yml" /usr/local/lib/meditation-room-linux/
sudo ln -sf /usr/local/lib/meditation-room-linux/mrlinux /usr/local/bin/mrlinux
sudo install -m 644 "$D"/systemd/*.service "$D"/systemd/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
# the night render (01:00-07:00, only while no stream runs) is the one timer here (Marko's brief, 15.11.2026)
sudo systemctl enable --now mrvisuals-night.timer
sudo install -d -m 700 /etc/meditation-room-linux
# the site token of the paired camera "VM Test": made here, root only, never printed; only its SHA-256 is shown,
# which goes into the site's KV as camtoken:<sha256> (same as /admin > PAIR CAMERA)
if ! sudo test -s /etc/meditation-room-linux/site-token; then
  sudo sh -c 'umask 077; python3 -c "import secrets,base64;print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip(\"=\"))" > /etc/meditation-room-linux/site-token'
  echo "new site token made; its sha256 (for KV camtoken:<sha256>):"
fi
sudo sh -c 'tr -d "\n" < /etc/meditation-room-linux/site-token | sha256sum | cut -d" " -f1'
mkdir -p /home/ubuntu/.cache/mrlinux
echo "installed: mrlinux start|stop|status|go-live|stop-live|text|preshow|visuals (stream units not enabled at boot; mrvisuals-night.timer 01:00)"
