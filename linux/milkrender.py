#!/usr/bin/env python3
"""milkrender: the desktop app's MilkDrop presets (butterchurn) rendered OFFLINE into a clip library for the Linux stream.

Marko, 15.11.2026: "our Mantra room in virtual machine is playing always the same visuals. It needs to act the same as
desktop app and the same as my phone app. It needs to change the visuals and have text, everything the same."

The VM has no GPU: butterchurn draws 2.7 fps at 720p in headless Chromium (SwiftShader), far too slow to stream live. But a
clip does not have to be drawn in real time. Each preset is rendered here frame by frame (page.html steps the preset's clock
exactly 1/25 s per frame and gives it the sound of a meditation track at that moment, so it moves as in the apps), read back
and encoded into a silent H.264 clip. The stream (mrvisuals.py) then only decodes and cross-fades clips: cheap.

  milkrender.py list                                 the preset keys, the desktop's order (the twelve calm ones first)
  milkrender.py bench [--size 1280x720] [--frames 100] [--gl swiftshader|egl|default] [--send 0|1]
  milkrender.py render <preset-key> [--secs 75] [--size 1280x720] [--track f] [--from s] [--crf 24] [--lib DIR]
  milkrender.py night [--until 07:00] [--max N]      the night job: every preset not yet in the library, one clip at a time,
                                                     only while no stream runs (checked before and during every clip)
  milkrender.py status                               clips in the library

Library: $MRV_LIB (default ~ubuntu/mrvisuals/clips): <slug>.mp4 + <slug>.json {kind, preset, name, secs, frames, track, ...}.
Chrome: $MILK_CHROME (default google-chrome, chromium, or the Mac's Chrome), own throwaway profile, headless.
"""
import argparse
import datetime as dt
import http.server
import json
import os
import random
import re
import shutil
import socketserver
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
if not os.path.isdir(REPO + "/android"):          # the installed copy (/usr/local/lib/...) reads the VM's checkout
    REPO = os.path.expanduser("~ubuntu") + "/MANTRA_ROOM"
VENDOR = os.environ.get("MILK_VENDOR", REPO + "/android/app/src/main/assets/web/vendor")
AUDIO = os.environ.get("MRL_AUDIO", REPO + "/android/app/src/main/assets/web/audio")
LIB = os.environ.get("MRV_LIB", os.path.expanduser("~ubuntu") + "/mrvisuals/clips")
LOG = os.environ.get("MILK_LOG", os.path.expanduser("~") + "/.cache/mrlinux/milkrender.log")
SR, FPS = 48000, 25
# the desktop's twelve calm presets, in its order (mac/web/index.html CALM), with its plain names
CALM = [
    ("Mandala", "Phat+fiShbRaiN+Eo.S_Mandala_Chasers_remix"),
    ("Lotus", "Aderrasi - Songflower (Moss Posy)"),
    ("Stained glass", "Eo.S. + Zylot - skylight (Stained Glass Majesty mix)"),
    ("Angel flight", "martin - angel flight"),
    ("Castle in the air", "martin - castle in the air"),
    ("Spiral", "Flexi - infused with the spiral"),
    ("Mother of pearl", "cope + martin - mother-of-pearl"),
    ("Star ornament", "Zylot - Star Ornament"),
    ("Nebula", "TonyMilkdrop - Magellan's Nebula [Flexi - you enter first + multiverse]"),
    ("Frosty caves", "martin - frosty caves 2"),
    ("Potion of spirits", "Aderrasi - Potion of Spirits"),
    ("Sunflower", "suksma - Rovastar - Sunflower Passion (Enlightment Mix)_Phat_edit + flexi und martin shaders - "
                  "circumflex in character classes in regular expression"),
]
# the sound that drives a clip: the meditation set (the long raga songs and the guide), a random minute of one
TRACKS = ["guide.mp3", "earth-raga.ogg", "water-raga.ogg", "fire-raga.ogg", "air-raga.ogg", "ether-raga.ogg", "aum-raga.ogg"]


def log(msg):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}"
    print(line, flush=True)
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def slug(key):
    s = re.sub(r"[^a-z0-9]+", "-", key.lower()).strip("-")
    return "milk-" + s[:70]


def chrome_bin():
    for c in (os.environ.get("MILK_CHROME"), "google-chrome", "chromium",
              "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"):
        if c and (shutil.which(c) or os.path.exists(c)):
            return shutil.which(c) or c
    sys.exit("no Chrome found (set MILK_CHROME)")


def chrome_flags(gl):
    f = ["--headless=new", "--no-first-run", "--no-default-browser-check", "--disable-extensions", "--mute-audio",
         "--ignore-gpu-blocklist", "--disable-background-timer-throttling", "--disable-renderer-backgrounding",
         "--disable-backgrounding-occluded-windows", "--autoplay-policy=no-user-gesture-required"]
    if gl == "swiftshader":
        f += ["--use-angle=swiftshader", "--enable-unsafe-swiftshader"]
    elif gl == "egl":   # Mesa (llvmpipe) through ANGLE's GL-on-EGL backend, surfaceless
        f += ["--use-gl=angle", "--use-angle=gl-egl", "--enable-unsafe-swiftshader"]
    return f


class Job:
    """One page run: serves page + vendor + PCM, takes the frames, reports progress."""

    def __init__(self, pcm=b"", sink=None):
        self.pcm, self.sink = pcm, sink
        self.done, self.fail, self.keys, self.gl = None, None, None, None
        self.frames, self.last = 0, time.monotonic()
        self.fin = threading.Event()
        job = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, code, body=b"", ctype="text/plain"):
                self.send_response(code)
                self.send_header("content-type", ctype)
                self.send_header("content-length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                p = self.path.split("?")[0]
                if p == "/page.html":
                    return self._send(200, open(HERE + "/milkrender/page.html", "rb").read(), "text/html")
                if p.startswith("/vendor/") and "/.." not in p:
                    f = VENDOR + "/" + os.path.basename(p)
                    if os.path.exists(f):
                        return self._send(200, open(f, "rb").read(), "application/javascript")
                if p == "/pcm":
                    return self._send(200, job.pcm, "application/octet-stream")
                self._send(404)

            def do_POST(self):
                n = int(self.headers.get("content-length") or 0)
                body = self.rfile.read(n) if n else b""
                p = self.path
                ok = True
                if p == "/frame":
                    try:
                        if job.sink:
                            job.sink(body)
                        job.frames += 1
                        job.last = time.monotonic()
                    except Exception as e:
                        job.fail, ok = f"sink: {e}", False
                        job.fin.set()
                elif p == "/log":
                    d = json.loads(body or b"{}")
                    if "gl" in d:
                        job.gl = d["gl"]
                        log(f"  renderer: {d['gl']} {d.get('w')}x{d.get('h')}")
                    else:
                        log(f"  frame {d.get('k')}/{d.get('of')}  {d.get('fps', 0):.2f} fps")
                    job.last = time.monotonic()
                elif p == "/keys":
                    job.keys = json.loads(body)
                    job.fin.set()
                elif p == "/done":
                    job.done = json.loads(body)
                    job.fin.set()
                elif p == "/fail":
                    job.fail = body.decode(errors="replace")
                    job.fin.set()
                self._send(200 if ok else 500)

        class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
            daemon_threads = True
        self.srv = S(("127.0.0.1", 0), H)
        self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def run(self, query, gl="swiftshader", timeout=3600, abort=None, stall=120):
        prof = tempfile.mkdtemp(prefix="milkrender-")
        url = f"http://127.0.0.1:{self.port}/page.html?{query}"
        env = dict(os.environ)
        proc = subprocess.Popen([chrome_bin(), f"--user-data-dir={prof}", *chrome_flags(gl), url],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env, start_new_session=True)
        t0 = time.monotonic()
        why = None
        try:
            while not self.fin.wait(5):
                if proc.poll() is not None:
                    why = f"chrome exited ({proc.returncode})"
                    break
                if time.monotonic() - t0 > timeout:
                    why = "timeout"
                    break
                if time.monotonic() - self.last > stall:
                    why = f"no progress for {stall} s"
                    break
                if abort:
                    a = abort()
                    if a:
                        why = "aborted: " + a
                        break
        finally:
            try:
                os.killpg(proc.pid, 15)
                proc.wait(10)
            except Exception:
                try:
                    os.killpg(proc.pid, 9)
                except Exception:
                    pass
            self.srv.shutdown()
            shutil.rmtree(prof, ignore_errors=True)
        if why and not self.fail:
            self.fail = why
        return self


def preset_keys():
    j = Job().run("list=1", timeout=120)
    if not j.keys:
        sys.exit(f"could not list presets: {j.fail}")
    calm = [k for _, k in CALM if k in j.keys]
    return calm + [k for k in j.keys if k not in calm]


def pcm_of(track, start, secs):
    return subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-ss", f"{start:.2f}", "-t", f"{secs:.2f}", "-i",
                           os.path.join(AUDIO, track), "-f", "u8", "-ac", "2", "-ar", str(SR), "pipe:1"],
                          capture_output=True, check=True).stdout


def duration(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
                         capture_output=True, text=True).stdout.strip()
    return float(out or 0)


def name_of(key):
    for n, k in CALM:
        if k == key:
            return n
    return key


def render(key, out_dir=LIB, secs=75, size="1280x720", track=None, start=None, crf=24, gl="swiftshader",
           abort=None, warm=50):
    w, h = map(int, size.split("x"))
    track = track or random.choice(TRACKS)
    length = duration(os.path.join(AUDIO, track))
    if start is None:
        start = random.uniform(5, max(5.0, length - secs - 5))
    pre = warm / FPS
    pcm = pcm_of(track, max(0.0, start - pre), secs + pre)
    os.makedirs(out_dir, exist_ok=True)
    base = os.path.join(out_dir, slug(key))
    tmp = base + ".part.mp4"
    vf = "vflip" + ("" if (w, h) == (1280, 720) else ",scale=1280:720:flags=lanczos") + ",format=yuv420p"
    enc = subprocess.Popen(["ffmpeg", "-hide_banner", "-nostdin", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgba",
                            "-s", f"{w}x{h}", "-r", str(FPS), "-i", "pipe:0", "-vf", vf, "-c:v", "libx264",
                            "-preset", "medium", "-crf", str(crf), "-maxrate", "3000k", "-bufsize", "6000k", "-g", "50", "-pix_fmt", "yuv420p", "-threads", "1",
                            "-movflags", "+faststart", "-an", tmp], stdin=subprocess.PIPE)
    frames = int(secs * FPS)
    log(f"render {name_of(key)!r} {w}x{h} {secs}s from {track}@{start:.0f}s gl={gl}")
    t0 = time.monotonic()
    j = Job(pcm, enc.stdin.write).run(f"preset={_q(key)}&w={w}&h={h}&frames={frames}&warm={warm}&sr={SR}",
                                      gl=gl, timeout=6 * 3600, abort=abort)
    try:
        enc.stdin.close()
    except OSError:
        pass
    enc.wait()
    took = time.monotonic() - t0
    if j.fail or not j.done or j.frames != frames or enc.returncode != 0:
        log(f"  FAILED {name_of(key)!r}: {j.fail or 'incomplete'} ({j.frames}/{frames} frames, x264 {enc.returncode})")
        try:
            os.remove(tmp)
        except OSError:
            pass
        return None
    os.replace(tmp, base + ".mp4")
    meta = {"kind": "milkdrop", "preset": key, "name": name_of(key), "secs": secs, "frames": frames, "size": size,
            "track": track, "from": round(start, 1), "gl": j.gl, "render_s": round(took, 1),
            "render_fps": round(frames / took, 2), "bytes": os.path.getsize(base + ".mp4"),
            "made": time.strftime("%Y-%m-%d %H:%M:%S"), "host": os.uname().nodename}
    with open(base + ".json.tmp", "w") as f:
        json.dump(meta, f, indent=1)
    os.replace(base + ".json.tmp", base + ".json")
    log(f"  done {name_of(key)!r}: {frames} frames in {took:.0f} s = {meta['render_fps']} fps, {meta['bytes'] / 1e6:.1f} MB")
    try:   # the brightness grade the player applies (a blown-out white preset sinks to a calm range)
        sys.path.insert(0, HERE)
        import mrvisuals
        log(f"  grade {mrvisuals.grade_clip(base + '.json')}")
    except Exception as e:
        log(f"  grade failed: {e}")
    return meta


def _q(s):
    from urllib.parse import quote
    return quote(s, safe="")


def bench(size="1280x720", frames=100, gl="swiftshader", send=1, key=None):
    w, h = map(int, size.split("x"))
    key = key or CALM[0][1]
    pcm = pcm_of("earth-raga.ogg", 60, frames / FPS + 4)
    got = [0]
    t0 = time.monotonic()
    j = Job(pcm, lambda b: got.__setitem__(0, got[0] + 1)).run(
        f"preset={_q(key)}&w={w}&h={h}&frames={frames}&warm=10&send={send}", gl=gl, timeout=3600)
    took = time.monotonic() - t0
    page = j.done or {}
    r = {"size": size, "gl": gl, "renderer": j.gl, "frames": frames, "send": send, "wall_s": round(took, 1),
         "page_s": page.get("secs"), "fps": round((frames + 10) / page["secs"], 2) if page.get("secs") else None,
         "fail": j.fail}
    log("bench " + json.dumps(r))
    return r


# ------------------------------------------------------------------ the night job -----------------------------------------

# units that mean "a stream is being made" (the cloud-mixer daemon and studio-ladder idle all day: they count only when they
# publish, which the santoshi path and the studio HLS folder below show)
BUSY_UNITS = ["meditation-room-linux", "mrlinux-live", "mrbuffer-publish", "cloud-mixer-show"]


def busy():
    """A reason not to render now (a stream runs), or None."""
    for u in BUSY_UNITS:
        r = subprocess.run(["systemctl", "is-active", "--quiet", u])
        if r.returncode == 0:
            return f"{u} is running"
    try:   # the public relay path has a publisher (the Pixel, the mixer, a concert replay)
        import ssl
        import urllib.request
        ctx = ssl.create_default_context()
        ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE
        p = json.load(urllib.request.urlopen("https://127.0.0.1:8443/v3/paths/get/santoshi", context=ctx, timeout=5))
        if p.get("ready") or p.get("source"):
            return "relay path santoshi has a publisher"
    except Exception:
        pass
    try:   # the studio ladder is writing HLS (a master comes from the Mac)
        hls = "/dev/shm/studio-hls"
        if os.path.isdir(hls) and any(time.time() - os.path.getmtime(os.path.join(hls, f)) < 60 for f in os.listdir(hls)):
            return "studio-ladder is publishing"
    except OSError:
        pass
    # (no load-average test: the render's own Chrome threads raise it; Nice 19 + CPUWeight 1 already yield to any other job)
    return None


def library():
    out = []
    try:
        names = os.listdir(LIB)
    except OSError:
        return out
    for n in sorted(names):
        if n.endswith(".json"):
            try:
                out.append(json.load(open(os.path.join(LIB, n))))
            except Exception:
                pass
    return out


def night(until="07:00", maxn=0, secs=75, size="1280x720", gl="swiftshader"):
    h, m = map(int, until.split(":"))
    now = dt.datetime.now()
    end = now.replace(hour=h, minute=m, second=0, microsecond=0)
    if end <= now:
        end += dt.timedelta(days=1)
    have = {c.get("preset") for c in library() if c.get("kind") == "milkdrop"}
    todo = [k for k in preset_keys() if k not in have]
    log(f"night: {len(have)} presets in the library, {len(todo)} to go, until {end:%H:%M}")
    done = 0
    per_clip = None
    for k in todo:
        if maxn and done >= maxn:
            break
        left = (end - dt.datetime.now()).total_seconds()
        if per_clip and left < per_clip * 1.1:
            log(f"night: {left / 60:.0f} min left, a clip takes ~{per_clip / 60:.0f} min: stop")
            break
        why = busy()
        if why:
            log(f"night: not now ({why}); stop for tonight")
            break
        meta = render(k, secs=secs, size=size, gl=gl, abort=lambda: busy() or (
            "07:00 reached" if dt.datetime.now() >= end + dt.timedelta(minutes=20) else None))
        if meta is None:
            if busy():
                log("night: a stream started: stop for tonight")
                break
            continue
        done += 1
        per_clip = meta["render_s"]
    log(f"night: {done} new clips; library {len([c for c in library() if c.get('kind') == 'milkdrop'])} MilkDrop clips")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["list", "bench", "render", "night", "status"])
    ap.add_argument("key", nargs="?")
    ap.add_argument("--size", default="1280x720")
    ap.add_argument("--frames", type=int, default=100)
    ap.add_argument("--secs", type=float, default=75)
    ap.add_argument("--gl", default="swiftshader")
    ap.add_argument("--send", type=int, default=1)
    ap.add_argument("--track")
    ap.add_argument("--from", dest="start", type=float)
    ap.add_argument("--crf", type=int, default=24)
    ap.add_argument("--lib")
    ap.add_argument("--until", default="07:00")
    ap.add_argument("--max", type=int, default=0)
    a = ap.parse_args()
    global LIB
    if a.lib:
        LIB = a.lib
    if a.cmd == "list":
        for i, k in enumerate(preset_keys()):
            print(f"{i + 1:3d}  {name_of(k)}" + ("" if name_of(k) == k else f"  ({k})"))
    elif a.cmd == "bench":
        print(json.dumps(bench(a.size, a.frames, a.gl, a.send, a.key)))
    elif a.cmd == "render":
        if not a.key:
            sys.exit("render <preset-key> (see list)")
        sys.exit(0 if render(a.key, LIB, a.secs, a.size, a.track, a.start, a.crf, a.gl) else 1)
    elif a.cmd == "night":
        night(a.until, a.max, a.secs, a.size, a.gl)
    elif a.cmd == "status":
        lib = library()
        mk = [c for c in lib if c.get("kind") == "milkdrop"]
        print(f"{len(lib)} clips in {LIB}: {len(mk)} MilkDrop, {len(lib) - len(mk)} other styles")
        for c in lib:
            print(f"  {c.get('kind'):8s} {c.get('name')!s:40.40s} {c.get('secs')} s  {c.get('render_fps', '')} fps")


if __name__ == "__main__":
    main()
