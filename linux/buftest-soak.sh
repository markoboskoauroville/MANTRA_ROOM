#!/bin/bash
# Soak test of the render-ahead buffer on the PRIVATE path buftest (never vmtest/santoshi), with the production unit
# properties (encoder Nice 10 CPUWeight 400, publisher Nice -5 CPUWeight 1000) and a CPU hog as an ordinary system job.
#   bash linux/buftest-soak.sh [minutes=10] [hog_at_s=120] [hog_s=180]
# Result: ~/mrbuftest/soak/{report.txt,rec.ts,speed.csv,*.log}. Needs stress-ng. Uses the INSTALLED mrbuffer.py.
set -f
M=${1:-10}; HA=${2:-120}; HS=${3:-180}; W=~/mrbuftest/soak; LIB=/usr/local/lib/meditation-room-linux
rm -rf "$W" /dev/shm/mrbuftest; mkdir -p "$W" ~/.cache/mrbuftest; cd "$W"
ENV="--setenv=MRB_RING=/dev/shm/mrbuftest --setenv=MRB_CACHE=/home/ubuntu/.cache/mrbuftest --setenv=TZ=Europe/Zagreb"
ENV="$ENV --setenv=MRB_OUT=srt://127.0.0.1:8992?streamid=publish:buftest&pkt_size=1316&latency=400000&transtype=live"
cleanup() { sudo systemctl stop mrbuftest-hog mrbuftest-pub mrbuftest-enc mrbuftest-relay 2>/dev/null; sudo systemctl reset-failed 'mrbuftest-*' 2>/dev/null; }
trap cleanup EXIT
cleanup
sudo systemd-run -q --unit=mrbuftest-relay -p User=ubuntu -p Nice=5 /opt/mediamtx/current/mediamtx $LIB/buftest-relay.yml
sleep 1
sudo systemd-run -q --unit=mrbuftest-enc -p User=ubuntu -p Nice=10 -p CPUWeight=400 -p CPUQuota=190% $ENV /usr/bin/python3 $LIB/mrbuffer.py encode
sudo systemd-run -q --unit=mrbuftest-pub -p User=ubuntu -p Nice=-5 -p CPUWeight=1000 $ENV /usr/bin/python3 $LIB/mrbuffer.py publish
for i in $(seq 1 120); do curl -s http://127.0.0.1:9997/v3/paths/get/buftest | grep -q '"ready":true' && break; sleep 1; done
T0=$(date +%s); echo "published after $i s" > report.txt
ffmpeg -hide_banner -nostdin -v error -i "http://127.0.0.1:8988/buftest/index.m3u8" -c copy -t $((M*60)) -f mpegts rec.ts 2> rec.log &
REC=$!
( while kill -0 $REC 2>/dev/null; do
    s=$(python3 -c "import json;d=json.load(open('/home/ubuntu/.cache/mrbuftest/status.json'));print(d.get('speed',''))" 2>/dev/null)
    b=$(python3 -c "import json;d=json.load(open('/dev/shm/mrbuftest/publisher.json'));print(d['buffered_s'],d['fillers'])" 2>/dev/null)
    echo "$(( $(date +%s) - T0 )),$s,$b,$(cut -d' ' -f1 /proc/loadavg)" >> speed.csv; sleep 5; done ) &
sleep "$HA"
echo "hog: stress-ng --cpu 2 for ${HS} s (system job, Nice 0, default CPUWeight) at +${HA} s" >> report.txt
sudo systemd-run -q --unit=mrbuftest-hog -p Nice=0 /usr/bin/stress-ng --cpu 2 --timeout "${HS}s" --quiet
wait $REC
journalctl -u mrbuftest-enc --since "-$((M+3)) min" -o cat > enc.log; journalctl -u mrbuftest-pub --since "-$((M+3)) min" -o cat > pub.log
cp /dev/shm/mrbuftest/publisher.json publisher.json
{
  echo "recording: $(ffprobe -v error -show_entries format=duration -of csv=p=0 rec.ts) s"
  ffprobe -v error -select_streams a -show_entries packet=pts_time -of csv=p=0 rec.ts | awk 'NR>1{d=$1-p; if(d>0.045||d<0) {g++; print "audio gap at",p,"s:",d}} {p=$1} END{print "audio packets",NR,"gaps",g+0}'
  ffprobe -v error -select_streams v -show_entries packet=pts_time -of csv=p=0 rec.ts | awk 'NR>1{d=$1-p; if(d>0.05||d<0) {g++; print "video gap at",p,"s:",d}} {p=$1} END{print "video packets",NR,"gaps",g+0}'
  echo "silences (-60 dB, >= 0.3 s): $(ffmpeg -nostdin -v info -i rec.ts -map 0:a -af silencedetect=n=-60dB:d=0.3 -f null - 2>&1 | grep -c silence_start)"
  ffmpeg -nostdin -v info -i rec.ts -map 0:a -af silencedetect=n=-60dB:d=0.3 -f null - 2>&1 | grep -E "silence_(start|end)" | head -20
  echo "publisher: $(python3 -c "import json;d=json.load(open('publisher.json'));print('fillers',d['fillers'],'filler_s',d['filler_s'],'warnings',d['warnings'],'min_buffer_s',d['min_buffer_s'],'sent',d['sent'],'downstream_restarts',d['downstream_restarts'])")"
  echo "encoder speed during the hog (s,speed,buffered,fillers,load):"; awk -F, -v a="$HA" -v b="$((HA+HS))" '$1>=a && $1<=b+30' speed.csv | sed -n '1~6p'
} >> report.txt
cat report.txt
