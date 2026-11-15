#!/usr/bin/env python3
"""mrvisuals: the Linux stream's picture as the desktop app has it: visuals that CHANGE, and the same one-block text.

Marko, 15.11.2026: "our Mantra room in virtual machine is playing always the same visuals. It needs to act the same as
desktop app and the same as my phone app. It needs to change the visuals and have text, everything the same. It's stuck in
one view."

The VM cannot draw MilkDrop live (no GPU: 2.7 fps), so the presets are rendered OFFLINE into clips (milkrender.py, the
night job) and this module PLAYS them: a shuffle with no repeats until every clip was shown, a 1.5 s cross-fade between
clips, all under the live meditation audio. Until the library holds enough MilkDrop clips (MRV_MIN_MILK, 24), the cheap
ffmpeg styles (the old mandala and four others, rendered by `mrvisuals.py styles`) are mixed in, so it is never one view.

The text is the desktop's (mac/web/textfx.js, Captions.swift): ONE block at a time, at most five words, 3 s fade in, 5 s
readable, 3 s fade out (here: in from a soft blur, out with a blur and a small upward drift, the "melt"); the track title at
each track start (element + style on two lines), the guide's spoken key phrases (mac/web/lines/<track>.json) only into a
quiet moment, and in the PRE-SHOW the countdown and a teaching card (preshow/cards.json) 90-120 s apart, never within 60 s of
a title. The text is drawn here, into the frames, with the desktop's look: a bold font, white with a dark rim, centred.

How it plugs in (meditation_room_linux.py hook VIS): the encoder ffmpeg gets one more input, raw 1280x720 yuv420p frames on
a pipe (pipe:N, pass_fds), written by a thread here. The pipe paces it: frames are made only as fast as the encoder takes
them, in step with the audio by timestamps. Cost: decoding one 720p clip (two during a cross-fade) + a little numpy.

  mrvisuals.py styles [--secs 75]      render the ffmpeg styles into the library (fast, minutes)
  mrvisuals.py status                  the library
  mrvisuals.py preview <out.mp4> [--secs 120] [--preshow HH:MM]   the player + text alone into a file (a test, no stream)

Library: $MRV_LIB (default ~ubuntu/mrvisuals/clips), shared with milkrender.py. Switch: ~/.cache/mrlinux/visuals
("library" or "mandala"; `mrlinux visuals library|mandala`), read when the encoder starts.
"""
import fcntl
import json
import os
import random
import subprocess
import sys
import threading
import time

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
if not os.path.isdir(REPO + "/android"):          # the installed copy (/usr/local/lib/...) reads the VM's checkout
    REPO = os.path.expanduser("~ubuntu") + "/MANTRA_ROOM"
LIB = os.environ.get("MRV_LIB", os.path.expanduser("~ubuntu") + "/mrvisuals/clips")
LINES = os.environ.get("MRV_LINES", REPO + "/mac/web/lines")
AUDIO = os.environ.get("MRL_AUDIO", REPO + "/android/app/src/main/assets/web/audio")
MIN_MILK = int(os.environ.get("MRV_MIN_MILK", "24"))   # below this many MilkDrop clips the ffmpeg styles are mixed in
W, H, FPS = 1280, 720, 25
FRAME = W * H * 3 // 2
XF = int(float(os.environ.get("MRV_XFADE", "1.0")) * FPS)   # cross-fade frames
# Marko, 15.11.2026: "Let it, just every, thirty seconds show different visualization." Each clip plays a random stretch of
# SWITCH seconds (the whole clip if shorter), then the next one; 0 = whole clips.
SWITCH = float(os.environ.get("MRV_SWITCH", "30"))
FONTS = [os.environ.get("MRV_FONT", ""), "/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf",
         "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
         "/Library/Fonts/Arial Bold.ttf"]
# the desktop's timing (textfx.js)
FADE_IN, HOLD, FADE_OUT = 3.0, 5.0, 3.0
BLOCK = FADE_IN + HOLD + FADE_OUT
CARD_GAP, TITLE_QUIET, VOICE_GAP = (90.0, 120.0), 60.0, 10.0


def log(msg):
    print(f"[mrvisuals] {time.strftime('%H:%M:%S')} {msg}", flush=True)


# ------------------------------------------------------------------ the library -------------------------------------------

def library(lib=LIB):
    out = []
    try:
        names = sorted(os.listdir(lib))
    except OSError:
        return out
    for n in names:
        if n.endswith(".json") and not n.endswith(".tmp"):
            mp4 = os.path.join(lib, n[:-5] + ".mp4")
            if os.path.exists(mp4):
                try:
                    m = json.load(open(os.path.join(lib, n)))
                    m["path"] = mp4
                    out.append(m)
                except Exception:
                    pass
    return out


def playable(lib=LIB):
    """MilkDrop clips; the ffmpeg styles too while there are fewer than MIN_MILK MilkDrop clips."""
    clips = library(lib)
    milk = [c for c in clips if c.get("kind") == "milkdrop"]
    return milk if len(milk) >= MIN_MILK else clips


class Bag:
    """Random order, no clip again until all were shown; the new bag never starts with the clip just shown."""

    def __init__(self, lib=LIB):
        self.lib, self.bag, self.last = lib, [], None

    def next(self):
        if not self.bag:
            clips = playable(self.lib)
            if not clips:
                return None
            random.shuffle(clips)
            if len(clips) > 1 and self.last and clips[-1]["path"] == self.last:
                clips[0], clips[-1] = clips[-1], clips[0]
            self.bag = clips
        c = self.bag.pop()
        self.last = c["path"]
        return c


class Decoder:
    def __init__(self, clip, switch=None):
        self.clip, self.pos = clip, 0
        total = int(clip.get("frames") or float(clip.get("secs", 60)) * FPS)
        seg = int((SWITCH if switch is None else switch) * FPS)
        start = 0
        if 0 < seg < total - FPS:                      # a random stretch of the clip, so a long clip is several looks
            start = random.randint(0, total - seg - 1)
            self.frames = seg
        else:
            self.frames = total
        self.start = start / FPS
        self.p = subprocess.Popen(["ffmpeg", "-nostdin", "-v", "error", "-threads", "1", "-ss", f"{self.start:.2f}",
                                   "-i", clip["path"], "-an",
                                   "-vf", f"scale={W}:{H},fps={FPS},format=yuv420p", "-f", "rawvideo", "pipe:1"],
                                  stdout=subprocess.PIPE, bufsize=0)

    def read(self):
        buf = bytearray()
        while len(buf) < FRAME:
            b = self.p.stdout.read(FRAME - len(buf))
            if not b:
                return None
            buf += b
        self.pos += 1
        return bytes(buf)

    def left(self):
        return self.frames - self.pos

    def close(self):
        try:
            self.p.kill()
            self.p.wait(3)
        except Exception:
            pass


def blend(a, b, w):
    """a*(1-w) + b*w on whole yuv420p frames (w 0..1)."""
    wi = int(w * 256)
    x = np.frombuffer(a, np.uint8).astype(np.uint16)
    y = np.frombuffer(b, np.uint8).astype(np.uint16)
    return ((x * (256 - wi) + y * wi) >> 8).astype(np.uint8).tobytes()


# ------------------------------------------------------------------ the text ----------------------------------------------

def font(size):
    for f in FONTS:
        if f and os.path.exists(f):
            return ImageFont.truetype(f, size)
    return ImageFont.load_default()


def clip5(text):
    """At most 5 words (marks like '·' are not words); line breaks stay (textfx.js clip5)."""
    n, out = 0, []
    for line in str(text).split("\n"):
        keep = []
        for w in line.split():
            if any(ch.isalnum() for ch in w):
                if n >= 5:
                    continue
                n += 1
            keep.append(w)
        if keep:
            out.append(" ".join(keep))
    return "\n".join(out)


def smooth(x):
    x = min(1.0, max(0.0, x))
    return x * x * (3 - 2 * x)


class Block:
    """One text block, drawn as textfx.js draws it (bold, white, dark rim fs/8, centred, max 0.86 W, max 4 lines), as luma
    and alpha planes, with blurred copies for the soft entry and the melt."""
    BLURS = (0, 1.5, 3.0, 5.0, 8.0)

    def __init__(self, text, t0):
        self.text, self.t0 = text, t0
        fs = round(W / 22)
        f = font(fs)
        d = ImageDraw.Draw(Image.new("L", (8, 8)))
        lines = []
        for para in text.split("\n"):
            cur = ""
            for w in para.split():
                t = (cur + " " + w) if cur else w
                if cur and d.textlength(t, font=f) > W * 0.86:
                    lines.append(cur)
                    cur = w
                else:
                    cur = t
            if cur:
                lines.append(cur)
        lines = lines[:4]
        lh = round(fs * 1.28)
        stroke = max(2, round(fs / 8))
        pad = 40
        bw = int(max(d.textlength(l, font=f) for l in lines) + 2 * stroke + 2 * pad)
        bh = int(lh * len(lines) + 2 * stroke + 2 * pad)
        bw += bw % 2
        bh += bh % 2
        rgba = Image.new("RGBA", (bw, bh), (0, 0, 0, 0))
        dr = ImageDraw.Draw(rgba)
        for i, l in enumerate(lines):
            x = (bw - d.textlength(l, font=f)) / 2
            y = pad + stroke + i * lh + (lh - fs) / 2 - fs * 0.12
            dr.text((x, y), l, font=f, fill=(255, 255, 255, 255), stroke_width=stroke, stroke_fill=(0, 0, 0, 230))
        self.levels = []
        for r in self.BLURS:
            im = rgba.filter(ImageFilter.GaussianBlur(r)) if r else rgba
            a = np.asarray(im, np.float32)
            luma = (0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2]) / 255.0
            self.levels.append((16.0 + 219.0 * luma, a[..., 3] / 255.0))
        self.bw, self.bh = bw, bh
        self.x0, self.y0 = (W - bw) // 2 & ~1, (H - bh) // 2 & ~1

    def state(self, t):
        """(alpha, blur level float, dy px) at stream time t, or None when over."""
        e = t - self.t0
        if e < 0 or e >= BLOCK:
            return None
        if e < FADE_IN:                       # in: from a soft blur, settling
            x = smooth(e / FADE_IN)
            return x, 3.0 * (1 - x), 8 * (1 - x)
        if e < FADE_IN + HOLD:
            return 1.0, 0.0, 0.0
        x = smooth((e - FADE_IN - HOLD) / FADE_OUT)   # out: the melt (blur grows, drifts up, fades)
        return 1 - x, 4.0 * x, -18 * x

    def draw(self, frame, t):
        st = self.state(t)
        if st is None:
            return frame
        a, lv, dy = st
        if a <= 0.003:
            return frame
        Lt, At = self.levels[min(len(self.levels) - 1, int(round(lv)))]
        f = np.frombuffer(frame, np.uint8).copy()
        y0 = self.y0 + (int(dy) & ~1)
        x0 = self.x0
        y0 = max(0, min(H - self.bh, y0))
        Y = f[:W * H].reshape(H, W)
        al = At * a
        reg = Y[y0:y0 + self.bh, x0:x0 + self.bw].astype(np.float32)
        Y[y0:y0 + self.bh, x0:x0 + self.bw] = (reg * (1 - al) + Lt * al).astype(np.uint8)
        # chroma: towards neutral grey where the text is (white text, dark rim)
        a2 = al[::2, ::2]
        cw = W // 2
        for off in (W * H, W * H + (W * H) // 4):
            C = f[off:off + (W * H) // 4].reshape(H // 2, cw)
            r = C[y0 // 2:y0 // 2 + self.bh // 2, x0 // 2:x0 // 2 + self.bw // 2].astype(np.float32)
            C[y0 // 2:y0 // 2 + self.bh // 2, x0 // 2:x0 // 2 + self.bw // 2] = (r * (1 - a2) + 128.0 * a2).astype(np.uint8)
        return f.tobytes()


class Text:
    """The scheduler of textfx.js + Captions.swift, in stream time (seconds of the current encoder's output)."""

    def __init__(self, mrl=None):
        self.mrl = mrl                 # meditation_room_linux (pre-show state, countdown wording, cards), may be None
        self.active, self.pending = None, None
        self.last_end, self.last_title = -1e9, -1e9
        self.track = None              # (start t, lines, next index)
        self.next_card, self.slot, self.deck = None, 0, []
        self.shown = 0
        self.lock = threading.Lock()
        self.events = []

    def reset(self):
        with self.lock:
            self.events = []
        self.active = self.pending = self.track = None
        self.last_end = self.last_title = -1e9
        self.next_card = None

    # called from the audio thread: a track starts at stream time t
    def track_start(self, fname, title, t):
        with self.lock:
            self.events.append(("track", fname, title, t))

    def say(self, text, t=None):
        with self.lock:
            self.events.append(("api", text, None, t))

    def show(self, text, kind, t):
        text = clip5(text.strip())
        if not text:
            return
        if kind == "voice" and (self.active or self.pending or t - self.last_end < VOICE_GAP):
            return
        if kind == "title":
            self.last_title = t
        self.pending = (text, kind)

    def _lines(self, fname):
        try:
            return json.load(open(os.path.join(LINES, fname + ".json"))).get("lines", [])
        except Exception:
            return []

    def _preshow(self, t):
        m = self.mrl
        if m is None:
            return
        try:
            left = m.preshow_left()
        except Exception:
            left = None
        if left is None:
            self.next_card = None
            return
        if self.next_card is None:
            self.next_card = t + 20.0
        if self.active or self.pending or t < self.next_card:
            return
        count = self.slot % 2 == 0
        if not count and t - self.last_title < TITLE_QUIET:   # a card never comes within 60 s of a title (the countdown may)
            return
        if count:
            line = m.countdown_line(left, self.slot // 2)
        else:
            try:
                cards = json.load(open(m.CARDS)).get("cards", [])
            except Exception:
                cards = []
            if not self.deck:
                self.deck = random.sample(cards, len(cards)) if cards else []
            line = m.five_words(self.deck.pop()) if self.deck else ""
        self.slot += 1
        if line:
            self.show(line, "card", t)

    def tick(self, t):
        with self.lock:
            evs, self.events = self.events, []
        for e in evs:
            if e[0] == "track":
                _, fname, title, t0 = e
                el, _, style = title.rpartition(" · ")
                self.show(f"{el}\n{style}" if el else title, "title", t)
                self.track = [t0, self._lines(fname), 0]
            elif e[0] == "api":
                self.show(e[1], "api", t)
        if self.track:                              # the guide's spoken key phrases
            t0, lines, i = self.track
            while i < len(lines) and t0 + lines[i]["t"] <= t:
                ln = lines[i]
                i += 1
                if t < t0 + ln.get("e", ln["t"]) + 1.5 and ln.get("key"):
                    self.show(ln["key"], "voice", t)
            self.track[2] = i
        self._preshow(t)
        if self.active and self.active.state(t) is None:
            self.active, self.last_end = None, t
            if self.next_card is not None:
                self.next_card = t + random.uniform(*CARD_GAP)
        if not self.active and self.pending and (self.pending[1] == "title" or t - self.last_end > 0.8):
            text, _ = self.pending
            self.pending = None
            self.active = Block(text, t)
            self.shown += 1
            log(f"text: {text!r}")

    def draw(self, frame, t):
        return self.active.draw(frame, t) if self.active else frame


# ------------------------------------------------------------------ the player ---------------------------------------------

class Visuals:
    """The hook object for meditation_room_linux.py: input args for the encoder, the writer thread, the text."""

    @staticmethod
    def create(mrl=None, lib=LIB):
        clips = playable(lib)
        if len(clips) < 2:
            log(f"library {lib}: {len(clips)} playable clips, staying with the mandala")
            return None
        log(f"library {lib}: {len(clips)} playable clips "
            f"({sum(1 for c in clips if c.get('kind') == 'milkdrop')} MilkDrop)")
        return Visuals(mrl, lib)

    def __init__(self, mrl=None, lib=LIB):
        self.mrl, self.bag, self.text = mrl, Bag(lib), Text(mrl)
        self.rfd = self.wfd = None
        self.thread, self.stop = None, threading.Event()
        self.now = ""
        self.stats = {"frames": 0, "clips": 0, "slow_frames": 0}

    def input_args(self):
        self.rfd, self.wfd = os.pipe()
        try:
            fcntl.fcntl(self.wfd, 1031, 1 << 20)     # F_SETPIPE_SZ: 1 MB (most of a frame in hand)
        except OSError:
            pass
        return ["-thread_queue_size", "16", "-f", "rawvideo", "-pix_fmt", "yuv420p", "-s", f"{W}x{H}", "-r", str(FPS),
                "-i", f"pipe:{self.rfd}"], (self.rfd,)

    def started(self, proc=None):
        os.close(self.rfd)
        self.stop.clear()
        self.text.reset()
        self.thread = threading.Thread(target=self._run, args=(self.wfd,), daemon=True)
        self.thread.start()

    def track_start(self, fname, title, t):
        self.text.track_start(fname, title, t)

    def _open(self):
        for _ in range(5):
            c = self.bag.next()
            if c is None:
                return None
            try:
                d = Decoder(c)
                self.stats["clips"] += 1
                return d
            except Exception as e:
                log(f"cannot open {c.get('path')}: {e}")
        return None

    def _run(self, wfd):
        out = os.fdopen(wfd, "wb", buffering=0)
        cur, nxt, n, last = self._open(), None, 0, bytes(FRAME)
        if cur:
            log(f"clip: {cur.clip.get('name')}")
        try:
            while not self.stop.is_set():
                t = n / FPS
                fr = cur.read() if cur else None
                if fr is None:                                  # the clip ended (or never opened)
                    if cur:
                        cur.close()
                    cur, nxt = (nxt, None) if nxt else (self._open(), None)
                    if cur:
                        log(f"clip: {cur.clip.get('name')} from {cur.start:.0f} s")
                    fr = (cur.read() if cur else None) or last
                if cur and nxt is None and cur.left() <= XF + 40:
                    nxt = self._open()                          # starts decoding 2 s before the cross-fade
                if cur and nxt and cur.left() < XF:
                    fb = nxt.read()
                    if fb is not None:
                        fr = blend(fr, fb, 1.0 - cur.left() / XF)
                self.text.tick(t)
                fr = self.text.draw(fr, t)
                out.write(fr)
                last = fr
                n += 1
                self.stats["frames"] = n
        except (BrokenPipeError, OSError, ValueError):
            pass
        finally:
            for d in (cur, nxt):
                if d:
                    d.close()
            try:
                out.close()
            except OSError:
                pass


# ------------------------------------------------------------------ the ffmpeg styles --------------------------------------

def _mandala(colour):
    rc, gc, bc = colour
    return ("[0:a]aformat=channel_layouts=stereo,avectorscope=s=320x320:r=25:mode=lissajous:draw=line:scale=sqrt:zoom=0.9:"
            f"rc={rc}:gc={gc}:bc={bc}:ac=170:rf=30:gf=34:bf=40:af=20,format=gbrp,split=2[s1][s2];[s2]hflip[s2f];"
            "[s1][s2f]blend=all_mode=lighten,split=2[m1][m2];[m2]vflip[m2f];[m1][m2f]blend=all_mode=lighten,"
            "gblur=sigma=1.0,pad=640:360:160:20:black[scope];")


STYLES = {
    # the stream's own mandala (meditation_room_linux.py), warm gold over the slow gradient
    "mandala-gold": ("Mandala (gold)", "earth-raga.ogg", _mandala((200, 150, 70)) +
                     "gradients=s=160x90:r=25:c0=0x1a0b2e:c1=0x3d1a0a:c2=0x0a2a2a:c3=0x2a0a1e:nb_colors=4:speed=0.003,"
                     "scale=640:360,format=gbrp[bg];[bg][scope]blend=all_mode=screen:shortest=1"),
    # the same mandala in moonlight, with trails and a slow turn
    "mandala-moon": ("Mandala (moon)", "water-raga.ogg", _mandala((120, 160, 230)).replace(
                     "pad=640:360:160:20:black[scope];", "pad=640:360:160:20:black,lagfun=decay=0.93,"
                     "rotate=a=t*0.05:fillcolor=black[scope];") +
                     "gradients=s=160x90:r=25:c0=0x050a24:c1=0x1a0a30:c2=0x002030:c3=0x10102a:nb_colors=4:speed=0.004,"
                     "scale=640:360,format=gbrp[bg];[bg][scope]blend=all_mode=screen:shortest=1"),
    # breathing rings of soft light, slowly changing colour, the sound's wave glowing faintly through them
    "rings": ("Rings of light", "aum-raga.ogg",
              "nullsrc=s=320x180:r=25,geq=r='45+40*sin(hypot(X-W/2\\,Y-H/2)/7-T*0.9)':"
              "g='30+25*sin(hypot(X-W/2\\,Y-H/2)/9-T*0.7+2)':b='60+50*sin(hypot(X-W/2\\,Y-H/2)/11-T*0.5+4)',"
              "hue=h=t*3:s=0.8,gblur=sigma=2,scale=640:360,format=gbrp[bg];"
              "[0:a]showwaves=s=640x360:r=25:mode=cline:colors=0x806040:scale=sqrt,format=gbrp,gblur=sigma=10,"
              "lagfun=decay=0.9[wv];[bg][wv]blend=all_mode=screen:shortest=1"),
    # a slow dive into the Mandelbrot set, in night colours
    "mandelbrot": ("Mandelbrot dive", "fire-raga.ogg",
                   "mandelbrot=s=480x270:r=25:start_x=-0.743643887037151:start_y=0.13182590420533:start_scale=3:"
                   "end_scale=0.05:end_pts=1875:maxiter=600:inner=black:outer=normalized_iteration_count,"
                   "hue=s=0,lutyuv=y='if(lt(val\\,24)\\,16\\,255-val)',curves=r='0/0 0.6/0.25 1/0.9':g='0/0 0.6/0.15 1/0.7':b='0/0.02 0.6/0.4 1/1',"
                   "hue=h=t*2,scale=640:360,format=gbrp[bg];"
                   "[0:a]anullsink;[bg]null"),
    # an aurora: a slow spiral of colours with the sound's wave glowing through it
    "aurora": ("Aurora", "air-raga.ogg",
               "gradients=s=320x180:r=25:type=spiral:speed=0.012:nb_colors=5:c0=0x0e4a36:c1=0x183070:c2=0x4a1858:"
               "c3=0x0e5656:c4=0x2a2a80,lagfun=decay=0.9,scale=640:360,format=gbrp[bg];"
               "[0:a]showwaves=s=640x360:r=25:mode=cline:colors=0x60d0a0|0xa080e0:split_channels=0:scale=sqrt,format=gbrp,"
               "gblur=sigma=4,lagfun=decay=0.85[wv];[bg][wv]blend=all_mode=screen:shortest=1"),
}


def render_styles(lib=LIB, secs=75, only=None):
    os.makedirs(lib, exist_ok=True)
    for key, (name, track, g) in STYLES.items():
        if only and key not in only:
            continue
        out = os.path.join(lib, f"ff-{key}")
        t0 = time.monotonic()
        graph = g + ",format=yuv420p,scale=1280:720:flags=bicubic[v]"
        cmd = ["ffmpeg", "-hide_banner", "-nostdin", "-v", "error", "-y", "-ss", "40", "-t", str(secs), "-i",
               os.path.join(AUDIO, track), "-filter_complex", graph, "-map", "[v]", "-t", str(secs), "-r", str(FPS),
               "-c:v", "libx264", "-preset", "medium", "-crf", "24", "-maxrate", "3000k", "-bufsize", "6000k",
               "-g", "50", "-pix_fmt", "yuv420p", "-threads", "1", "-an", "-movflags", "+faststart", out + ".part.mp4"]
        r = subprocess.run(cmd)
        if r.returncode != 0:
            log(f"style {key}: ffmpeg failed ({r.returncode})")
            continue
        os.replace(out + ".part.mp4", out + ".mp4")
        took = time.monotonic() - t0
        meta = {"kind": "ffmpeg", "style": key, "name": name, "secs": secs, "frames": int(secs * FPS), "track": track,
                "render_s": round(took, 1), "render_fps": round(secs * FPS / took, 1),
                "bytes": os.path.getsize(out + ".mp4"), "made": time.strftime("%Y-%m-%d %H:%M:%S")}
        with open(out + ".json.tmp", "w") as f:
            json.dump(meta, f, indent=1)
        os.replace(out + ".json.tmp", out + ".json")
        log(f"style {key}: {secs} s in {took:.0f} s, {meta['bytes'] / 1e6:.1f} MB")


def preview(path, secs=120, preshow=None, lib=LIB):
    """The player and the text alone (the tracks' titles every 40 s, one guide start) into a file: a look without a stream."""
    sys.path.insert(0, HERE)
    mrl = None
    try:
        import meditation_room_linux as mrl
        if preshow:
            mrl.CACHE = os.path.dirname(os.path.abspath(path))
            open(mrl.CACHE + "/preshow", "w").write(preshow)
    except Exception as e:
        log(f"no pre-show ({e})")
    v = Visuals(mrl, lib)
    args, fds = v.input_args()
    enc = subprocess.Popen(["ffmpeg", "-hide_banner", "-nostdin", "-v", "error", "-y", *args, "-t", str(secs),
                            "-c:v", "libx264", "-preset", "veryfast", "-b:v", "2500k", "-pix_fmt", "yuv420p", path],
                           pass_fds=fds)
    v.started(enc)
    v.track_start("guide.mp3", "The guide", 0.0)
    t0 = time.monotonic()
    k = 1
    while enc.poll() is None:
        time.sleep(0.5)
        if v.stats["frames"] / FPS > 40 * k + 4:
            v.track_start("earth-voice.ogg", "Earth · A · Mantra Voice", v.stats["frames"] / FPS)
            k += 1
    v.stop.set()
    took = time.monotonic() - t0
    log(f"preview {path}: {secs} s in {took:.0f} s ({secs * FPS / took:.1f} fps), text blocks {v.text.shown}, "
        f"clips {v.stats['clips']}")


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["styles", "status", "preview"])
    ap.add_argument("out", nargs="?")
    ap.add_argument("--secs", type=float, default=75)
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--preshow")
    ap.add_argument("--lib", default=LIB)
    a = ap.parse_args()
    if a.cmd == "styles":
        render_styles(a.lib, a.secs, a.only)
    elif a.cmd == "status":
        cl = library(a.lib)
        mk = sum(1 for c in cl if c.get("kind") == "milkdrop")
        print(f"{len(cl)} clips in {a.lib}: {mk} MilkDrop, {len(cl) - mk} ffmpeg styles; "
              f"playing {'MilkDrop only' if mk >= MIN_MILK else 'all (MilkDrop < %d)' % MIN_MILK}")
        for c in cl:
            print(f"  {c.get('kind'):8s} {c.get('name')!s:40.40s} {c.get('secs')} s")
    elif a.cmd == "preview":
        preview(a.out or "/tmp/mrvisuals-preview.mp4", a.secs, a.preshow, a.lib)
