#!/bin/bash
# Private test of the changing visuals (mrvisuals.py) on chromium-vm: the encoder FROM THIS CHECKOUT (not the installed copy)
# publishes to its own MediaMTX path vistest (SRT 127.0.0.1:8993, HLS 127.0.0.1:8989), never vmtest or santoshi; Nice 19,
# CPUWeight 20, so a real stream always wins the CPU. Records the stream, then frames every 2 s for a contact sheet.
#   [POSTER=every,for] bash linux/vistest.sh [seconds=180] [preshow HH:MM]
# Result: ~/mrvistest/{rec.ts,enc.log,report.txt,shots/}
set -f
SECS=${1:-180}; PRE=$2; D=$(cd "$(dirname "$0")" && pwd); W=~/mrvistest
rm -rf "$W" ~/.cache/mrvistest; mkdir -p "$W/shots" ~/.cache/mrvistest; cd "$W"
[ -n "$PRE" ] && echo "$PRE" > ~/.cache/mrvistest/preshow
# POSTER="every,for" (env): the poster cycle in the test too (it fades over the visuals, the music goes on)
[ -n "$POSTER" ] && printf '{"on": true, "every": %s, "for": %s}\n' "${POSTER%,*}" "${POSTER#*,}" > ~/.cache/mrvistest/poster.json
ENV="--setenv=MRL_CACHE=/home/ubuntu/.cache/mrvistest --setenv=TZ=Europe/Zagreb --setenv=MRL_VISUALS=library"
ENV="$ENV --setenv=MRL_SRT=srt://127.0.0.1:8993?streamid=publish:vistest&pkt_size=1316&latency=400000&transtype=live"
cleanup() { sudo systemctl stop mrvistest-enc mrvistest-relay 2>/dev/null; sudo systemctl reset-failed 'mrvistest-*' 2>/dev/null; }
trap cleanup EXIT
cleanup
sudo systemd-run -q --unit=mrvistest-relay -p User=ubuntu -p Nice=5 /opt/mediamtx/current/mediamtx "$D/vistest-relay.yml"
sleep 1
sudo systemd-run -q --unit=mrvistest-enc -p User=ubuntu -p Nice=19 -p CPUWeight=20 -p CPUQuota=150% $ENV /usr/bin/python3 "$D/meditation_room_linux.py" run
for i in $(seq 1 60); do curl -s http://127.0.0.1:9994/v3/paths/get/vistest | grep -q '"ready":true' && break; sleep 1; done
echo "published after $i s" > report.txt
ffmpeg -hide_banner -nostdin -v error -i "http://127.0.0.1:8989/vistest/index.m3u8" -c copy -t "$SECS" -f mpegts rec.ts 2> rec.log
journalctl -u mrvistest-enc --since "-$((SECS/60+3)) min" -o cat > enc.log
cp ~/.cache/mrvistest/status.json status.json 2>/dev/null
{
  echo "recording: $(ffprobe -v error -show_entries format=duration -of csv=p=0 rec.ts) s"
  echo "encoder: $(python3 -c "import json;d=json.load(open('status.json'));print('speed',d.get('speed'),'fps',d.get('fps'),'drop',d.get('drop_frames'),'dup',d.get('dup_frames'))")"
  ffprobe -v error -select_streams a -show_entries packet=pts_time -of csv=p=0 rec.ts | awk 'NR>1{d=$1-p; if(d>0.045||d<0) {g++}} {p=$1} END{print "audio packets",NR,"gaps",g+0}'
  echo "clips: $(grep -c 'clip:' enc.log), text blocks: $(grep -c 'text:' enc.log)"; grep -E "clip:|text:" enc.log
} >> report.txt
for t in $(seq 1 2 "$SECS"); do ffmpeg -v error -nostdin -y -ss "$t" -i rec.ts -frames:v 1 -vf scale=320:-2 "shots/s$(printf %04d "$t").jpg"; done
cat report.txt
