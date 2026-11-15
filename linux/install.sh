#!/bin/bash
# Installs the Meditation Room (Linux) test stream on chromium-vm. Run on the VM from a checkout of MANTRA_ROOM:
#   bash ~/MANTRA_ROOM/linux/install.sh
# Audio = the repo's own files (git, the VM's own download; never from the Mac's SIM). Units are NOT enabled at boot.
set -e
D=$(cd "$(dirname "$0")" && pwd)
sudo install -d /usr/local/lib/meditation-room-linux
sudo install -m 755 "$D/meditation_room_linux.py" "$D/mrlinux" /usr/local/lib/meditation-room-linux/
sudo install -m 644 "$D/mrlinux-relay.yml" /usr/local/lib/meditation-room-linux/
sudo ln -sf /usr/local/lib/meditation-room-linux/mrlinux /usr/local/bin/mrlinux
sudo install -m 644 "$D"/systemd/*.service /etc/systemd/system/
sudo systemctl daemon-reload
# the site token of the paired camera "VM Test": made here, root only, never printed; only its SHA-256 is shown,
# which goes into the site's KV as camtoken:<sha256> (same as /admin > PAIR CAMERA)
sudo install -d -m 700 /etc/meditation-room-linux
if ! sudo test -s /etc/meditation-room-linux/site-token; then
  sudo sh -c 'umask 077; python3 -c "import secrets,base64;print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip(\"=\"))" > /etc/meditation-room-linux/site-token'
  echo "new site token made; its sha256 (for KV camtoken:<sha256>):"
fi
sudo sh -c 'tr -d "\n" < /etc/meditation-room-linux/site-token | sha256sum | cut -d" " -f1'
mkdir -p /home/ubuntu/.cache/mrlinux
echo "installed: mrlinux start|stop|status|go-live|stop-live|text|preshow (units not enabled at boot)"
