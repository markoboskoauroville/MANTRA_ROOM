#!/usr/bin/env python3
"""Meditation Room (Linux): the Mac app's sound and a MilkDrop-like picture, headless, as a TEST STREAM on chromium-vm.

Marko, 15.11.2026: "make the Linux version of this meditation room and install it on a virtual machine as a test stream
... so I don't spend my SIM card." Everything runs on the VM; nothing goes over the Mac's 4G.

  run    the encoder (systemd meditation-room-linux, user ubuntu): the thirteen tracks of the Mac app (the guide, then each
         element Mantra Voice + Indian Raga, OM) decoded one after another into one paced PCM stream -> ffmpeg draws the
         picture from the sound (avectorscope mirrored four ways = a mandala, over a slow gradient), the clock, the track,
         the text written over it, and the pre-show countdown -> H.264 baseline + Opus, 1280x720 25p -> SRT to the
         PRIVATE test relay (mrlinux-relay, MediaMTX 127.0.0.1:8991, path vmtest). Never the public path by itself.
  live   the go-live (systemd mrlinux-live, root): checks (not 11:50-13:50 Zagreb, site not live, public path santoshi
         free), copies vmtest -> the public relay path santoshi (-c copy, no second encoder), then GO on the site as the
         paired camera "VM Test" (via relay). Stops by itself after N minutes, at the noon window, or on stop-live;
         on every exit the site gets STOP first.
  status the numbers (speed, fps, bitrate, track) as JSON.

Files: ~/.cache/mrlinux/{status.json,text.txt,now.txt,block.txt,preshow}. Site token: /etc/meditation-room-linux/site-token
(root 600, never printed). Relay key: /etc/santoshi-relay/key (root:ubuntu 640, never printed).
"""
import warnings
warnings.filterwarnings("ignore", category=DeprecationWarning)
import audioop  # noqa: E402 (Python 3.12: still there; the gain of the poster fades)
import datetime as dt
import json
import os
import signal
import ssl
import subprocess
import sys
import threading
import time
import urllib.request
from zoneinfo import ZoneInfo

HOME = os.path.expanduser("~ubuntu")
AUDIO = os.environ.get("MRL_AUDIO", HOME + "/MANTRA_ROOM/android/app/src/main/assets/web/audio")
CACHE = HOME + "/.cache/mrlinux"
FONT = "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf"
SR, CH = 48000, 2
LOCAL_SRT = "srt://127.0.0.1:8991?streamid=publish:vmtest&pkt_size=1316&latency=400000&transtype=live"
LOCAL_READ = "srt://127.0.0.1:8991?streamid=read:vmtest&latency=400000&transtype=live"
PUBLIC_KEY = "/etc/santoshi-relay/key"
SITE = "https://santoshi-band.pages.dev/api/live"
SITE_TOKEN = "/etc/meditation-room-linux/site-token"
ZAGREB = ZoneInfo("Europe/Zagreb")
CARDS = os.environ.get("MRL_CARDS", HOME + "/MANTRA_ROOM/preshow/cards.json")  # shared with the Mac app (v13+)
# Marko 15.11.2026: ONE block at a time, max 5 words, fade in 3 s, at least 5 s readable, fade out 3 s, then 90-120 s of visuals only
CARD_P, FADE_IN, HOLD, FADE_OUT = 120, 3.0, 5.0, 3.0
CARD_ON = FADE_IN + HOLD + FADE_OUT
# the noon replay owns the site (CLOUD MIXER show: mixer starts 11:57, live 12:00). From 15.11.2026 the pre-show may run
# until 11:56 and then stops the site itself; MRL_NOON_FROM changes the start of the window.
NOON = (dt.time(*map(int, os.environ.get("MRL_NOON_FROM", "11:56").split(":"))), dt.time(13, 50))
HANDOVER = dt.time(11, 58, 30)   # latest end of a pre-show that hands the live site over to the noon replay (--until)
NO_SITE_STOP = os.environ.get("MRL_NO_SITE_STOP") == "1"   # hand-over: the site stays live, the mixer's GO joins it

ELEMENTS = [("earth", "Earth · A"), ("water", "Water · U"), ("fire", "Fire · I"), ("air", "Air · O"),
            ("ether", "Ether · A-U-I-O"), ("aum", "OM")]
TRACKS = [("guide.mp3", "The guide")] + [t for e, n in ELEMENTS for t in
                                         ((f"{e}-voice.ogg", f"{n} · Mantra Voice"), (f"{e}-raga.ogg", f"{n} · Indian Raga"))]


def wfile(path, text):
    """Atomic write (drawtext re-reads these files while we change them)."""
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text if text.strip() else "")  # empty = nothing drawn (a space would draw an empty box)
    os.replace(tmp, path)


def esc(p):
    return p.replace("\\", "\\\\").replace(":", "\\:").replace("'", "\\'")


# Hooks for the render-ahead buffer (linux/mrbuffer.py); the defaults are the direct real-time encoder.
CLOCK = "%{localtime\\:%T}"   # drawtext text of the clock; mrbuffer draws the time the frame PLAYS (pts + epoch)
AHEAD = [0.0]                 # seconds between rendering and playout (the pre-show countdown is computed for the playout)


def now_playout():
    return dt.datetime.now(ZAGREB) + dt.timedelta(seconds=AHEAD[0])


def graph(pc=None):
    t = lambda name: esc(f"{CACHE}/{name}")
    f = esc(FONT)
    ph = f"mod(t\\,{CARD_P})"
    alpha = (f"if(lt({ph}\\,{FADE_IN})\\,{ph}/{FADE_IN}\\,if(lt({ph}\\,{FADE_IN + HOLD})\\,1\\,"
             f"if(lt({ph}\\,{CARD_ON})\\,({CARD_ON}-{ph})/{FADE_OUT}\\,0)))")

    def card(name, font, size, dy):
        return (f"drawtext=fontfile={font}:textfile='{t(name)}':reload=25:text_align=C:x=(w-tw)/2:"
                f"y=h*0.42+{dy}-({ph}*0.8):fontsize={size}:line_spacing=10:fontcolor=white:box=1:boxcolor=black@0.38:"
                f"boxborderw=14:alpha='{alpha}',")
    # the mandala: the stereo picture of the sound (lissajous), mirrored left-right and up-down, softened, warm gold
    scope = ("[av]aformat=channel_layouts=stereo,avectorscope=s=320x320:r=25:mode=lissajous:draw=line:scale=sqrt:zoom=0.9:"
             "rc=200:gc=150:bc=70:ac=170:rf=30:gf=34:bf=40:af=20,format=gbrp,split=2[s1][s2];[s2]hflip[s2f];"
             "[s1][s2f]blend=all_mode=lighten,split=2[m1][m2];[m2]vflip[m2f];[m1][m2f]blend=all_mode=lighten,"
             "gblur=sigma=1.0,pad=640:360:160:20:black[scope]")
    bg = ("gradients=s=160x90:r=25:c0=0x1a0b2e:c1=0x3d1a0a:c2=0x0a2a2a:c3=0x2a0a1e:nb_colors=4:speed=0.003,"
          "scale=640:360,format=gbrp[bg]")
    out = ("[bg][scope]blend=all_mode=screen:shortest=1,format=yuv420p,scale=1280:720:flags=bicubic,"
           f"drawtext=fontfile={f}:textfile='{t('title.txt')}':reload=25:x=40:y=34:fontsize=26:fontcolor=white@0.7,"
           f"drawtext=fontfile={f}:text='{CLOCK}':x=w-tw-40:y=34:fontsize=26:fontcolor=white@0.7,"
           f"drawtext=fontfile={f}:textfile='{t('now.txt')}':reload=25:x=40:y=h-60:fontsize=24:fontcolor=white@0.6,"
           # the ONE text block (a countdown or a teaching card, max 5 words): fades in, holds, fades out, drifts up a little
           # (a slow 'melt'), then visuals only until the next CARD_P cycle. No Devanagari: Ubuntu's ffmpeg cannot shape it.
           + card("block.txt", f, 48, 0) +
           f"drawtext=fontfile={f}:textfile='{t('text.txt')}':reload=25:text_align=C:x=(w-tw)/2:y=h*0.72:fontsize=48:fontcolor=white:"
           "box=1:boxcolor=black@0.38:boxborderw=20:line_spacing=10[vout]")
    g = f"[0:a]asplit=2[aout][av];{scope};{bg};{out}"
    if pc:   # the poster over everything (picture, clock, text) for `for` s of every cycle; one decoded frame, looped
        cyc = pc["every"] + pc["for"]
        g = g.replace("[vout]", "[vmain]") + (
            f";movie='{esc(pc['frame'])}',loop=loop=-1:size=1:start=0,setpts=N/25/TB,fps=25,format=yuv420p[pst];"
            f"[vmain][pst]overlay=0:0:eof_action=pass:enable='gte(mod(t\\,{cyc})\\,{pc['every']})'[vout]")
    return g


class Encoder:
    def __init__(self, url, pc=None):
        self.url, self.proc, self.status, self.pc = url, None, {}, pc
        self.track = ""

    def start(self):
        cmd = ["ffmpeg", "-hide_banner", "-nostdin", "-v", "warning", "-progress", "pipe:1", "-stats_period", "2",
               "-f", "s16le", "-ar", str(SR), "-ac", str(CH), "-i", "pipe:0",
               "-filter_complex", graph(self.pc), "-map", "[vout]", "-map", "[aout]",
               "-c:v", "libx264", "-preset", "veryfast", "-tune", "zerolatency", "-profile:v", "baseline", "-bf", "0",
               "-g", "50", "-keyint_min", "50", "-r", "25", "-b:v", "2500k", "-maxrate", "2500k", "-bufsize", "2500k",
               "-pix_fmt", "yuv420p", "-threads", "2",
               "-c:a", "libopus", "-b:a", "128k", "-ar", str(SR), "-ac", "2",
               *self.out_args()]
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        threading.Thread(target=self._progress, daemon=True).start()

    def out_args(self):
        return ["-f", "mpegts", "-mpegts_flags", "+resend_headers", self.url]

    def _progress(self):
        cur = {}
        for line in self.proc.stdout:
            k, _, v = line.decode(errors="replace").strip().partition("=")
            cur[k] = v
            if k == "progress":
                self.status = {"speed": cur.get("speed", "").strip(), "fps": cur.get("fps"), "bitrate": cur.get("bitrate"),
                               "out_time": cur.get("out_time"), "frame": cur.get("frame"),
                               "drop_frames": cur.get("drop_frames"), "dup_frames": cur.get("dup_frames")}
                write_status({"state": "encoding", "track": self.track, "target": "vmtest (private test relay :8991)",
                              **self.status, "pid": self.proc.pid, "updated": time.strftime("%Y-%m-%d %H:%M:%S")})


def write_status(d):
    wfile(CACHE + "/status.json", json.dumps(d, indent=1))


def poster_cfg():
    """~/.cache/mrlinux/poster.json {on, every, for, src}: every `every` s of music and visuals, the poster full frame for
    `for` s in silence (Marko, 15.11.2026: "every two minutes put the poster for one minute in the silence")."""
    try:
        c = json.load(open(CACHE + "/poster.json"))
    except Exception:
        return None
    if not c.get("on"):
        return None
    c.setdefault("every", 120); c.setdefault("for", 60)
    c.setdefault("src", "/srv/cloud-mixer/media/subic/poster-next-2026-11-21.jpg")
    return c if os.path.exists(c["src"]) else None


def poster_frame(src):
    """The poster fitted into 1280x720 over a blurred, darkened copy of itself (made once)."""
    out = CACHE + "/poster-720.jpg"
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", src, "-filter_complex",
                    "[0]scale=1280:720:force_original_aspect_ratio=increase,crop=1280:720,gblur=sigma=30,eq=brightness=-0.25[b];"
                    "[0]scale=-2:720[f];[b][f]overlay=(W-w)/2:0", "-frames:v", "1", "-q:v", "2", "-y", out], check=True)
    return out


def gain_at(st, pc):
    """Music gain at stream time st: 1, a 1 s fade out before the poster, 0 during it, a 1 s fade in after."""
    if not pc:
        return 1.0
    cyc = pc["every"] + pc["for"]
    ph = st % cyc
    if ph >= pc["every"]:
        return 0.0
    if ph >= pc["every"] - 1:
        return pc["every"] - ph
    if st >= cyc and ph < 1:
        return ph
    return 1.0


STREAM_T = [0.0]   # seconds of sound sent to the current encoder = drawtext's t


def preshow_left():
    """Seconds until the --preshow-until time (Zagreb), or None when the pre-show is off or over."""
    try:
        hhmm = open(CACHE + "/preshow").read().strip()
        h, m = map(int, hhmm.split(":"))
        now = now_playout()
        left = (now.replace(hour=h, minute=m, second=0, microsecond=0) - now).total_seconds()
        return left if left > 0 else None
    except Exception:
        return None


def preshow_hhmm():
    try:
        return open(CACHE + "/preshow").read().strip()
    except OSError:
        return ""


def countdown_line(left, n=0):
    """Max 5 words. Alternates "Concert live at 12:00" and "Concert in N minutes"."""
    if left <= 90:
        return "Concert begins in a moment"
    if n % 2 == 0:
        return f"Concert live at {preshow_hhmm()}"
    mins = int((left + 59) // 60)
    return f"Concert in {mins} minutes" if mins > 1 else "Concert in one minute"


def five_words(c):
    """A card's text when it has at most 5 words, else its title; never more than 5 words."""
    for k in ("text", "title"):
        w = str(c.get(k, "")).split()
        if 0 < len(w) <= 5:
            return " ".join(w)
    return " ".join(str(c.get("title") or c.get("text") or "").split()[:5])


def preshow_on():
    try:
        hhmm = open(CACHE + "/preshow").read().strip()
        h, m = map(int, hhmm.split(":"))
        now = now_playout()
        return now < now.replace(hour=h, minute=m, second=0, microsecond=0)
    except Exception:
        return False


def card_loop(stop):
    import random
    order, last_cycle = [], -1
    while not stop.is_set():
        st = STREAM_T[0]
        cycle, phase = int(st // CARD_P), st % CARD_P
        if CARD_ON + 4 < phase < CARD_P - 4 and cycle != last_cycle:
            last_cycle = cycle
            line = ""
            left = preshow_left()
            if left is not None and cycle % 2 == 0:
                line = countdown_line(left, cycle // 2)   # even cycles: the countdown, odd cycles: a card
            elif left is not None:
                try:
                    cards = json.load(open(CARDS)).get("cards", [])
                except Exception:
                    cards = []
                if cards:
                    if not order:
                        order = random.sample(range(len(cards)), len(cards))
                    c = cards[order.pop() % len(cards)]
                    line = five_words(c)
            wfile(f"{CACHE}/block.txt", line)
        stop.wait(1)


def wrap(text, width):
    import textwrap
    return "\n".join(textwrap.wrap(text, width))


def run():
    os.makedirs(CACHE, exist_ok=True)
    wfile(f"{CACHE}/block.txt", "")
    if not os.path.exists(f"{CACHE}/title.txt"):
        wfile(f"{CACHE}/title.txt", "Meditation Room")
    for n in ("text.txt", "now.txt"):
        if not os.path.exists(f"{CACHE}/{n}"):
            wfile(f"{CACHE}/{n}", "")
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    threading.Thread(target=card_loop, args=(stop,), daemon=True).start()
    chunk = SR * CH * 2 // 50          # 20 ms of PCM
    lead = 0.25                        # keep the encoder a quarter second ahead, never more
    i = 0
    while not stop.is_set():
        pc = poster_cfg()
        if pc:
            try:
                pc["frame"] = poster_frame(pc["src"])
            except Exception as e:
                print(f"[mrlinux] poster frame failed: {e}", flush=True)
                pc = None
        print(f"[mrlinux] encoder start, poster {'every %ss for %ss' % (pc['every'], pc['for']) if pc else 'off'}", flush=True)
        enc = Encoder(LOCAL_SRT, pc)
        enc.start()
        t0, sent = time.monotonic(), 0
        lead = getattr(enc, "lead", 0.25)   # mrbuffer: may run up to its buffer ahead of real time
        STREAM_T[0] = 0.0
        try:
            while not stop.is_set() and enc.proc.poll() is None:
                fname, title = TRACKS[i % len(TRACKS)]
                i += 1
                path = os.path.join(AUDIO, fname)
                if not os.path.exists(path):
                    continue
                enc.track = title
                wfile(CACHE + "/now.txt", title)
                print(f"[mrlinux] track {title}", flush=True)
                dec = subprocess.Popen(["ffmpeg", "-nostdin", "-v", "error", "-i", path, "-f", "s16le", "-ar", str(SR),
                                        "-ac", str(CH), "pipe:1"], stdout=subprocess.PIPE)
                while not stop.is_set():
                    g = gain_at(sent / (SR * CH * 2), pc)
                    if g <= 0.0:
                        buf = bytes(chunk)               # the poster minute: silence, the track waits where it was
                    else:
                        buf = dec.stdout.read(chunk)
                        if not buf:
                            break
                        if g < 1.0:
                            buf = audioop.mul(buf, 2, g)
                    ahead = (sent / (SR * CH * 2)) - (time.monotonic() - t0)
                    if ahead > lead:
                        time.sleep(ahead - lead)
                    enc.proc.stdin.write(buf)
                    sent += len(buf)
                    STREAM_T[0] = sent / (SR * CH * 2)
                dec.kill()
                dec.wait()
        except (BrokenPipeError, OSError) as e:
            print(f"[mrlinux] encoder pipe closed: {e}", flush=True)
        try:
            enc.proc.stdin.close()
        except OSError:
            pass
        try:
            enc.proc.terminate()
            enc.proc.wait(5)
        except Exception:
            enc.proc.kill()
        if not stop.is_set():
            write_status({"state": "restarting", "updated": time.strftime("%Y-%m-%d %H:%M:%S")})
            time.sleep(1)
    write_status({"state": "stopped", "updated": time.strftime("%Y-%m-%d %H:%M:%S")})


# ---------------------------------------------------------------- go-live (root) ------------------------------------

def in_noon(now=None):
    t = (now or dt.datetime.now(ZAGREB)).time()
    return NOON[0] <= t < NOON[1]


def site(action):
    tok = open(SITE_TOKEN).read().strip()
    req = urllib.request.Request(SITE, data=json.dumps({"action": action, "via": "relay"}).encode(), method="POST",
                                 headers={"Authorization": "Bearer " + tok, "content-type": "application/json",
                                          "user-agent": "meditation-room-linux/1"})
    d = json.load(urllib.request.urlopen(req, timeout=20))
    return {"live": d.get("live"), "via": d.get("via"), "source": d.get("source"), "name": d.get("name")}


def site_public():
    return json.load(urllib.request.urlopen(urllib.request.Request(SITE, headers={"user-agent": "meditation-room-linux/1"}),
                                            timeout=20))


def public_path():
    ctx = ssl.create_default_context()
    ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE
    return json.load(urllib.request.urlopen("https://127.0.0.1:8443/v3/paths/get/santoshi", context=ctx, timeout=10))


def local_path():
    return json.load(urllib.request.urlopen("http://127.0.0.1:9996/v3/paths/get/vmtest", timeout=10))


RESUME = os.environ.get("MRL_RESUME") == "1"   # the site is already live as OUR camera (VMTest): publish again


def checks():
    """Every reason not to go live, as a list of sentences (empty = free)."""
    why = []
    if in_noon():
        why.append(f"it is between {NOON[0]:%H:%M} and {NOON[1]:%H:%M} Zagreb time (the noon replay owns the site)")
    try:
        if site_public().get("live") and not (RESUME and site("status").get("name") in ("VM Test", "VMTest")):
            why.append("the site is already live (another camera or the cloud mixer)")
    except Exception as e:
        why.append(f"cannot read the site's live state ({e})")
    try:
        p = public_path()
        if p.get("source") or p.get("ready"):
            why.append(f"the public relay path santoshi has a publisher ({(p.get('source') or {}).get('type')})")
    except Exception as e:
        why.append(f"cannot read the public relay ({e})")
    try:
        if not local_path().get("ready"):
            why.append("the test stream is not running (mrlinux start first)")
    except Exception as e:
        why.append(f"the test stream is not running ({e})")
    return why


def end_time(arg):
    """'HH:MM[:SS]' (Zagreb, today) or minutes -> a monotonic deadline; never more than 2 hours, never past HANDOVER
    when the time falls in the noon window (the CLOUD MIXER show waits from 11:59:00 while path santoshi has a publisher)."""
    if ":" in str(arg):
        p = list(map(int, str(arg).split(":"))) + [0]
        now = dt.datetime.now(ZAGREB)
        at = now.replace(hour=p[0], minute=p[1], second=p[2], microsecond=0)
        if NOON[0] <= at.time() < NOON[1] and at.time() > HANDOVER:
            at = at.replace(hour=HANDOVER.hour, minute=HANDOVER.minute, second=HANDOVER.second)
        secs = (at - now).total_seconds()
    else:
        secs = float(arg) * 60
    return time.monotonic() + max(0.0, min(secs, 7200.0))


def live(arg):
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    why = checks()
    if why:
        print("[mrlinux] NOT going live: " + "; ".join(why), flush=True)
        sys.exit(3)
    key = open(PUBLIC_KEY).read().strip()
    pub = (f"srt://127.0.0.1:8890?streamid=publish:santoshi:santoshi:{key}&pkt_size=1316&latency=400000&transtype=live")
    forward = lambda: subprocess.Popen(["ffmpeg", "-hide_banner", "-nostdin", "-v", "error", "-i", LOCAL_READ, "-map", "0",
                                        "-c", "copy", "-f", "mpegts", pub])
    fwd = forward()
    went = False
    try:
        for _ in range(60):                       # wait until the public path has our stream
            if stop.wait(1) or fwd.poll() is not None:
                break
            try:
                if public_path().get("ready"):
                    break
            except Exception:
                pass
        if fwd.poll() is None and not stop.is_set():
            print("[mrlinux] public path ready, site GO: " + json.dumps(site("go")), flush=True)
            went = True
        end = end_time(arg)
        restarts = 0
        while went and not stop.is_set() and time.monotonic() < end:
            if in_noon() and ":" not in str(arg):
                print(f"[mrlinux] {NOON[0]:%H:%M} reached (the noon replay takes over): stopping", flush=True)
                break
            if fwd.poll() is not None:            # the encoder restarted (poster on/off) or a hiccup: forward again
                restarts += 1
                print(f"[mrlinux] forward ended (code {fwd.returncode}), again in 1 s (restart {restarts})", flush=True)
                if restarts > 30 or stop.wait(1):
                    break
                fwd = forward()
            stop.wait(1)
    finally:
        if went and NO_SITE_STOP:
            print("[mrlinux] hand-over: path santoshi freed, the site stays LIVE for the next publisher (no site STOP)", flush=True)
        elif went:
            try:
                print("[mrlinux] site STOP: " + json.dumps(site("stop")), flush=True)
            except Exception as e:
                print(f"[mrlinux] site STOP failed: {e}", flush=True)
        fwd.terminate()
        try:
            fwd.wait(5)
        except Exception:
            fwd.kill()
        print("[mrlinux] live ended", flush=True)


def site_stop_if_ours():
    """ExecStopPost safety net: STOP on the site only when the live is ours (camera 'VM Test'). In a hand-over
    (--no-site-stop) the site is left live and the encoder and test relay are stopped too, to free the CPU for the mixer."""
    if NO_SITE_STOP and os.environ.get("MRL_KEEP_ENCODER") == "1":
        print("[mrlinux] live stopped by hand: no site STOP, the encoder keeps running", flush=True)
        return
    if NO_SITE_STOP:
        subprocess.run(["systemctl", "--no-block", "stop", "meditation-room-linux.service", "mrlinux-relay.service"])
        print("[mrlinux] hand-over: no site STOP; encoder and test relay stopping", flush=True)
        return
    try:
        d = site("status")
        if d.get("live") and d.get("name") in ("VM Test", "VMTest"):
            print("[mrlinux] safety STOP: " + json.dumps(site("stop")), flush=True)
    except Exception as e:
        print(f"[mrlinux] safety check failed: {e}", flush=True)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "run"
    if cmd == "run":
        run()
    elif cmd == "live":
        live(sys.argv[2] if len(sys.argv) > 2 else "5")
    elif cmd == "checks":
        w = checks()
        print("free to go live" if not w else "NOT free: " + "; ".join(w))
    elif cmd == "site-stop-if-ours":
        site_stop_if_ours()
    else:
        sys.exit(f"unknown command {cmd}")
