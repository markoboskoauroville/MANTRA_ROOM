#!/usr/bin/env python3
"""Render-ahead buffer for the Meditation Room (Linux) stream: a busy machine never starves the viewers.

Marko, 15.11.2026: "the stream is getting kind of... It's changed the speed and the dropouts, because now we are generating
images and so many things transcribing. So if that can be solved by buffering, maybe... Let's say 20 seconds of finished
video and then streaming it. ... We can be 20-30 seconds in delay, no problem."

Two processes instead of one real-time encoder:

  encode   the SAME encoder as meditation_room_linux.py (imported, not copied: picture, poster cycle, cards, gain fades all
           stay there), but its ffmpeg writes finished 2 s MPEG-TS segments into a RAM ring (/dev/shm/mrbuf/run-<ms>/)
           instead of SRT, and its PCM feeder may run up to MAX (30 s) ahead of the playout. When the CPU is free it renders
           faster than real time; when the machine is busy it falls behind for a while without harm. The clock in the picture
           and the pre-show countdown are drawn for the moment the frame PLAYS (epoch + pts), not when it is rendered.
  publish  the light paced publisher (Python + one `ffmpeg -c copy`): waits until the ring holds >= START (20 s), then sends
           the segments at exact real time to the relay (vmtest by default). Timestamps are rewritten so the output is one
           continuous stream across encoder restarts (poster on/off). If the ring runs dry it never stops: it repeats the last
           segment's picture with silence (a filler of the same codec) and logs it; below WARN (5 s) it logs a warning.

State: <ring>/publisher.json (queued_s, buffered_s, until, fillers, min_buffer_s ...), read by `mrbuffer status` and by the
encoder (a restarted encoder continues where the buffer ends). Every number here is an env var (MRB_*), so a private test
instance (path buftest, own ring and cache) runs beside the real one without touching it.
"""
import csv
import glob
import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time

LIB = os.path.dirname(os.path.abspath(__file__))
RING = os.environ.get("MRB_RING", "/dev/shm/mrbuf")
OUT = os.environ.get("MRB_OUT", "srt://127.0.0.1:8991?streamid=publish:vmtest&pkt_size=1316&latency=400000&transtype=live")
SEG = float(os.environ.get("MRB_SEG", "2"))          # segment length (the GOP is 2 s, so segments are 2 s)
START = float(os.environ.get("MRB_START", "20"))     # the publisher starts when this much finished video is queued
MAX = float(os.environ.get("MRB_MAX", "30"))         # the encoder never runs further ahead of the playout than this
WARN = float(os.environ.get("MRB_WARN", "5"))        # below this a warning goes to the log
FIRST = float(os.environ.get("MRB_FIRST", "25"))     # a fresh start plays its first frame this long after the encoder starts
LEAD = float(os.environ.get("MRB_LEAD", "1.0"))      # the publisher hands each piece to the relay this much early
STATE = RING + "/publisher.json"
TS = 188
P90 = 90000
WRAP = 1 << 33


def log(msg):
    print(f"[mrbuffer] {time.strftime('%H:%M:%S')} {msg}", flush=True)


def wjson(path, d):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(d, f, indent=1)
    os.replace(tmp, path)


def read_state(max_age=5.0):
    try:
        d = json.load(open(STATE))
        return d if time.time() - d.get("t", 0) < max_age else None
    except Exception:
        return None


# ------------------------------------------------------------------ encode ----------------------------------------------

def encode():
    """Run meditation_room_linux.run() with the buffered encoder plugged in through its hooks."""
    sys.path.insert(0, LIB)
    import meditation_room_linux as mrl
    if os.environ.get("MRB_CACHE"):                  # a private test instance keeps its own text/status files
        mrl.CACHE = os.environ["MRB_CACHE"]
    os.makedirs(mrl.CACHE, exist_ok=True)
    os.makedirs(RING, exist_ok=True)
    cur = [None]

    class BufferedEncoder(mrl.Encoder):
        def start(self):
            now = time.time()
            st = read_state()
            if st and st.get("state") == "playing":
                epoch = max(now + 1.0, st["until"])  # continue exactly where the queued video ends
            else:
                epoch = now + FIRST
            self.epoch = epoch
            self.lead = MAX - (epoch - now)          # run()'s pacing: playout of what is fed <= MAX ahead of now
            self.rundir = f"{RING}/run-{int(now * 1000)}"
            os.makedirs(self.rundir)
            wjson(self.rundir + "/run.json", {"epoch": epoch, "pid": os.getpid(), "created": now})
            mrl.CLOCK = f"%{{pts\\:localtime\\:{epoch:.3f}\\:%T}}"   # the clock of the moment the frame plays
            cur[0] = self
            log(f"encoder run {os.path.basename(self.rundir)}: first frame plays in {epoch - now:.1f} s, lead {self.lead:.1f} s")
            super().start()

        def out_args(self):
            return ["-f", "segment", "-segment_time", str(SEG), "-segment_format", "mpegts",
                    "-segment_format_options", "mpegts_flags=+resend_headers",
                    "-segment_list", self.rundir + "/list.csv", "-segment_list_type", "csv",
                    "-segment_list_flags", "+live", self.rundir + "/seg%06d.ts"]

    def ahead_loop():
        """How far ahead of the playout the encoder is now (the pre-show countdown is computed for the playout)."""
        while True:
            e = cur[0]
            if e is not None:
                mrl.AHEAD[0] = max(0.0, e.epoch + mrl.STREAM_T[0] - time.time())
            time.sleep(1)

    def prune_loop():
        """Orphans only (publisher down): segments older than 4x MAX, and empty old runs."""
        while True:
            time.sleep(10)
            old = time.time() - 4 * MAX
            for p in glob.glob(RING + "/run-*/seg*.ts"):
                try:
                    if os.path.getmtime(p) < old:
                        os.remove(p)
                except OSError:
                    pass
            for d in glob.glob(RING + "/run-*"):
                if cur[0] is not None and d == cur[0].rundir:
                    continue
                try:
                    if not glob.glob(d + "/seg*.ts") and os.path.getmtime(d) < old:
                        shutil.rmtree(d, ignore_errors=True)
                except OSError:
                    pass

    mrl.Encoder = BufferedEncoder
    threading.Thread(target=ahead_loop, daemon=True).start()
    threading.Thread(target=prune_loop, daemon=True).start()
    log(f"encode: ring {RING}, segments {SEG:g} s, max {MAX:g} s ahead")
    mrl.run()


# ------------------------------------------------------------------ MPEG-TS restamp -------------------------------------

def _rd_ts(b, i):
    return (((b[i] >> 1) & 7) << 30) | (b[i + 1] << 22) | ((b[i + 2] >> 1) << 15) | (b[i + 3] << 7) | (b[i + 4] >> 1)


def _wr_ts(b, i, v):
    v %= WRAP
    b[i] = (b[i] & 0xF1) | (((v >> 30) & 7) << 1)
    b[i + 1] = (v >> 22) & 0xFF
    b[i + 2] = (((v >> 15) & 0x7F) << 1) | 1
    b[i + 3] = (v >> 7) & 0xFF
    b[i + 4] = ((v & 0x7F) << 1) | 1


def scan(data):
    """Per PID: first/last PTS (unwrapped against the first) and the typical step. Returns {pid: [first, last, step]}."""
    st = {}
    for o in range(0, len(data) - TS + 1, TS):
        b1, b3 = data[o + 1], data[o + 3]
        if data[o] != 0x47 or not (b1 & 0x40):
            continue
        pid = ((b1 & 0x1F) << 8) | data[o + 2]
        p = o + 4
        if b3 & 0x20:
            p += 1 + data[o + 4]
        if p + 14 > o + TS or data[p:p + 3] != b"\x00\x00\x01" or data[p + 3] < 0xBC:
            continue
        if not (data[p + 7] & 0x80):
            continue
        pts = _rd_ts(data, p + 9)
        s = st.get(pid)
        if s is None:
            st[pid] = [pts, pts, 0]
        else:
            if pts < s[1] - WRAP // 2:
                pts += WRAP
            if pts > s[1]:
                d = pts - s[1]
                s[2] = d if s[2] == 0 else min(s[2], d)
                s[1] = pts
    return st


def restamp(data, off):
    """Add `off` (90 kHz) to every PTS, DTS and PCR. Returns new bytes."""
    b = bytearray(data)
    for o in range(0, len(b) - TS + 1, TS):
        if b[o] != 0x47:
            continue
        b1, b3 = b[o + 1], b[o + 3]
        p = o + 4
        if b3 & 0x20:
            alen = b[o + 4]
            if alen >= 7 and (b[o + 5] & 0x10):      # PCR: 33 bit base, 6 reserved, 9 bit extension
                q = o + 6
                base = (b[q] << 25) | (b[q + 1] << 17) | (b[q + 2] << 9) | (b[q + 3] << 1) | (b[q + 4] >> 7)
                base = (base + off) % WRAP
                b[q], b[q + 1], b[q + 2], b[q + 3] = (base >> 25) & 0xFF, (base >> 17) & 0xFF, (base >> 9) & 0xFF, (base >> 1) & 0xFF
                b[q + 4] = ((base & 1) << 7) | (b[q + 4] & 0x7F)
            p += 1 + alen
        if not (b1 & 0x40) or p + 14 > o + TS or b[p:p + 3] != b"\x00\x00\x01" or b[p + 3] < 0xBC:
            continue
        flags = b[p + 7] >> 6
        if flags & 2:
            _wr_ts(b, p + 9, _rd_ts(b, p + 9) + off)
        if flags == 3:
            _wr_ts(b, p + 14, _rd_ts(b, p + 14) + off)
    return bytes(b)


# ------------------------------------------------------------------ publish ---------------------------------------------

class Item:
    def __init__(self, path, run=None, name=None, start=0.0, dur=SEG, filler=False):
        self.path, self.run, self.name, self.start, self.dur, self.filler = path, run, name, start, dur, filler


class Publisher:
    def __init__(self):
        self.down = None
        self.anchor = None            # (monotonic, out_pts90): when the output clock value plays
        self.last_end = {}            # pid -> end of the last sent PTS (out clock, unwrapped)
        self.last_off = None
        self.prev = None              # (run, index) of the last sent real segment
        self.done = {}                # run dir -> set of sent names
        self.filler = RING + "/filler.ts"
        self.last_seg = RING + "/last.ts"
        self.st = {"state": "waiting", "fillers": 0, "filler_s": 0.0, "sent": 0, "warnings": 0, "min_buffer_s": None,
                   "downstream_restarts": 0, "out": OUT.split("?")[0]}
        self.end_mono = None
        self.queued = 0.0
        self.last_warn = 0.0
        self.stop = threading.Event()
        self.lock = threading.Lock()

    # the relay side: ffmpeg copies our paced TS to SRT (restarted if it dies; the publisher never stops)
    def downstream(self):
        if self.down is None or self.down.poll() is not None:
            if self.down is not None:
                self.st["downstream_restarts"] += 1
                log(f"downstream ffmpeg ended ({self.down.returncode}), starting again")
            self.down = subprocess.Popen(
                ["ffmpeg", "-hide_banner", "-nostdin", "-v", "error", "-probesize", "1000000", "-analyzeduration", "1500000",
                 "-f", "mpegts", "-i", "pipe:0", "-map", "0", "-c", "copy", "-f", "mpegts", "-mpegts_flags", "+resend_headers",
                 OUT], stdin=subprocess.PIPE)
        return self.down

    def write(self, chunk):
        try:
            d = self.downstream()
            d.stdin.write(chunk)
            d.stdin.flush()
        except (BrokenPipeError, OSError, ValueError):
            try:
                self.down.kill()
            except Exception:
                pass
            self.down = None

    def queue(self):
        """Finished segments not yet sent, oldest first, across runs."""
        out = []
        for run in sorted(glob.glob(RING + "/run-*")):
            done = self.done.setdefault(run, set())
            try:
                rows = list(csv.reader(open(run + "/list.csv")))
            except OSError:
                rows = []
            for i, r in enumerate(rows):
                if len(r) < 3 or r[0] in done:
                    continue
                p = os.path.join(run, r[0])
                if os.path.exists(p):
                    out.append(Item(p, run, r[0], float(r[1]), max(0.04, float(r[2]) - float(r[1]))))
                    out[-1].index = i
        return out

    def cleanup(self, keep_run):
        for run in list(self.done):
            if run < keep_run and not glob.glob(run + "/seg*.ts"):
                shutil.rmtree(run, ignore_errors=True)
                self.done.pop(run, None)

    def make_filler(self, src):
        """The last segment's picture with silence, same codecs (copied video, Opus silence)."""
        tmp = RING + "/filler.tmp.ts"
        r = subprocess.run(["nice", "-n", "5", "ffmpeg", "-hide_banner", "-nostdin", "-v", "error", "-i", src,
                            "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo", "-map", "0:v:0", "-map", "1:a:0",
                            "-c:v", "copy", "-c:a", "libopus", "-b:a", "128k", "-ar", "48000", "-ac", "2", "-shortest",
                            "-f", "mpegts", "-y", tmp])
        if r.returncode == 0 and os.path.getsize(tmp) > 10000:
            os.replace(tmp, self.filler)

    def buffered(self):
        """Seconds of finished video that will play after now: queued segments + what the relay already has."""
        ahead = max(0.0, self.end_mono - time.monotonic()) if self.end_mono else 0.0
        return self.queued + ahead

    def state_loop(self):
        while not self.stop.is_set():
            with self.lock:
                b = self.buffered()
                self.st.update({"queued_s": round(self.queued, 2), "buffered_s": round(b, 2), "until": time.time() + b,
                                "t": time.time(), "updated": time.strftime("%Y-%m-%d %H:%M:%S")})
                if self.st["state"] == "playing":
                    m = self.st["min_buffer_s"]
                    self.st["min_buffer_s"] = round(b, 2) if m is None else min(m, round(b, 2))
                    if b < WARN and time.time() - self.last_warn > 10:
                        self.last_warn = time.time()
                        self.st["warnings"] += 1
                        log(f"WARNING buffer low: {b:.1f} s of finished video (encoder behind; filler if it runs dry)")
                wjson(STATE, self.st)
            self.stop.wait(1)

    def send(self, it, data):
        """Restamp `it` onto the output clock and send it paced over its own duration."""
        info = scan(data)
        if not info:
            return False
        contiguous = (not it.filler and self.prev is not None and self.prev[0] == it.run and self.prev[1] == it.index - 1
                      and self.last_off is not None)
        if contiguous:
            off = self.last_off
        elif not self.last_end:
            off = 0
        else:                                   # a jump (new run, filler, lost segment): just after the last sent pts
            off = max(self.last_end[pid] - s[0] for pid, s in info.items() if pid in self.last_end) \
                if any(pid in self.last_end for pid in info) else max(self.last_end.values()) - min(s[0] for s in info.values())
        out = restamp(data, off)
        start = min(s[0] for s in info.values()) + off
        end = max(s[1] + (s[2] or 1800) for s in info.values()) + off
        if self.anchor is None:
            self.anchor = (time.monotonic(), start)
        t_start = self.anchor[0] + (start - self.anchor[1]) / P90 - LEAD
        t_end = self.anchor[0] + (end - self.anchor[1]) / P90 - LEAD
        n = max(1, int((t_end - t_start) / 0.04))
        pk = len(out) // TS
        for i in range(n):
            a, z = (pk * i // n) * TS, (pk * (i + 1) // n) * TS
            wait = t_start + i * (t_end - t_start) / n - time.monotonic()
            if wait > 0:
                time.sleep(wait)
            self.write(out[a:z])
        for pid, s in info.items():
            self.last_end[pid] = s[1] + (s[2] or 1800) + off
        self.last_off = off
        with self.lock:
            self.end_mono = self.anchor[0] + (end - self.anchor[1]) / P90
        return True

    def run(self):
        os.makedirs(RING, exist_ok=True)
        signal.signal(signal.SIGTERM, lambda *_: self.stop.set())
        signal.signal(signal.SIGINT, lambda *_: self.stop.set())
        threading.Thread(target=self.state_loop, daemon=True).start()
        log(f"publish: ring {RING} -> {OUT.split('?')[0]}, start at {START:g} s queued, warn below {WARN:g} s")
        while not self.stop.is_set():                # 1) wait for START seconds of finished video
            q = self.queue()
            with self.lock:
                self.queued = sum(i.dur for i in q)
            if self.queued >= START:
                try:
                    run = json.load(open(q[0].run + "/run.json"))
                    wait = run["epoch"] + q[0].start - LEAD - time.time()   # play when the encoder meant it to (the clock)
                except Exception:
                    wait = 0
                if 0 < wait < MAX:
                    self.stop.wait(wait)
                break
            self.stop.wait(0.5)
        if self.stop.is_set():
            return
        log(f"buffer holds {self.queued:.1f} s: publishing")
        self.st["state"] = "playing"
        while not self.stop.is_set():                # 2) at real time, forever
            q = self.queue()
            with self.lock:
                self.queued = sum(i.dur for i in q)
            if q:
                it = q[0]
                with self.lock:
                    self.queued -= it.dur
                try:
                    data = open(it.path, "rb").read()
                except OSError:
                    continue
                ok = self.send(it, data)
                self.done[it.run].add(it.name)
                self.prev = (it.run, it.index)
                try:
                    os.replace(it.path, self.last_seg)   # keep the newest as the filler's source
                except OSError:
                    pass
                if ok:
                    self.st["sent"] += 1
                    fresh = os.path.exists(self.filler) and time.time() - os.path.getmtime(self.filler) < 10
                    if (not os.path.exists(self.filler) or (self.buffered() < WARN and not fresh)) and self._snap():
                        threading.Thread(target=self.make_filler, args=(self.last_seg + ".f",), daemon=True).start()
                self.cleanup(it.run)
                continue
            if self.end_mono and time.monotonic() < self.end_mono - LEAD - 0.1:
                self.stop.wait(0.05)                 # the relay still has video: give the encoder a moment
                continue
            if os.path.exists(self.filler):          # 3) dry: repeat the last picture with silence, never cut
                data = open(self.filler, "rb").read()
                it = Item(self.filler, filler=True)
                e0 = self.end_mono
                self.send(it, data)
                self.prev = None
                self.st["fillers"] += 1
                self.st["filler_s"] = round(self.st["filler_s"] + (self.end_mono - e0 if e0 else SEG), 2)
                log(f"RAN DRY: filler {self.st['fillers']} sent (last picture, silence)")
            else:
                self.stop.wait(0.05)
        log("publisher stopped")

    def _snap(self):
        try:
            shutil.copyfile(self.last_seg, self.last_seg + ".f")
            return True
        except OSError:
            return False


def status():
    st = read_state(1e9) or {}
    age = time.time() - st.get("t", 0) if st else None
    print(json.dumps({**st, "age_s": round(age, 1) if age is not None else None}, indent=1))


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd == "encode":
        encode()
    elif cmd == "publish":
        Publisher().run()
    elif cmd == "status":
        status()
    else:
        sys.exit("usage: mrbuffer.py encode|publish|status")
