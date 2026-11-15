// textfx.js: MilkDrop's melting text for any butterchurn visualizer page, plus the PRE-SHOW mode (a countdown and teaching
// cards). Plain and portable: no Swift in it. The Mac app (Swift) and the Linux VM version load this same file.
// Marko, 15.11.2026: "Drop has a way to show the text over the screen ... it is melting with the visuals ... when the voice is
// speaking anything, it should have the text on the screen" and "the same principle we can use before we start to stream the
// concert ... 10 minutes until the live stream ... teach people about Sanskrit mantras ... spoon by spoon".
//
// How the melt is real: butterchurn's own launchSongTitleAnim draws the text INTO the feedback frame (the preset's warp then
// melts it away). Only the text texture is replaced here (wrapped lines, a clean large font); the animation is butterchurn's.
//
//   TextFX.attach(visualizer)            once, after createVisualizer
//   TextFX.enable(true|false)            the TEXT switch
//   TextFX.show("a line\nsecond line")   queue a text now (also what the local API /api/text feeds)
//   TextFX.preshow(true, untilEpochMs)   countdown to the live stream + a teaching card every 45-90 s
//   cards: window.PRESHOW_CARDS (preshow/cards.js, made from preshow/cards.json), or TextFX.setCards([...])
"use strict";
window.TextFX = (function () {
  let viz = null, enabled = true, cards = (window.PRESHOW_CARDS && window.PRESHOW_CARDS.cards) || [];
  let shownCount = 0, lastText = "";
  let pre = { on: false, until: 0, marks: new Set(), nextP: 0, deck: [], timer: null };

  function attach(v) {
    viz = v;
    const tt = v && v.renderer && v.renderer.titleText;
    if (!tt || tt.__wrapped) return;
    tt.__wrapped = true;
    // butterchurn fades the text by progress^0.3 only; here the block's alpha is ours (a controlled fade in and out)
    const origRender = tt.renderTitle;
    tt.renderTitle = function (t, e, i) {
      const gl = this.gl, u = gl.uniform1f, self = this;
      if (self.__alpha == null) return origRender.call(this, t, e, i);
      gl.uniform1f = function (loc, v) { return u.call(gl, loc, loc === self.textColorLoc ? self.__alpha : v); };
      try { return origRender.call(this, t, e, i); } finally { gl.uniform1f = u; }
    };
    // the same texture upload as butterchurn's, with wrapped, centred lines in a clean bold font
    tt.generateTitleTexture = function (text) {
      const ctx = this.context2D, W = this.texsizeX, H = this.texsizeY, gl = this.gl;
      ctx.clearRect(0, 0, W, H);
      const fs = Math.max(10, Math.round(W / 22));
      ctx.font = '600 ' + fs + 'px "Helvetica Neue", Helvetica, Arial, "Devanagari Sangam MN", sans-serif';
      const maxW = W * 0.86, lines = [];
      String(text).split("\n").forEach(function (para) {
        let cur = "";
        para.split(/\s+/).forEach(function (w) {
          const t = cur ? cur + " " + w : w;
          if (cur && ctx.measureText(t).width > maxW) { lines.push(cur); cur = w; } else cur = t;
        });
        if (cur) lines.push(cur);
      });
      if (lines.length > 4) { lines.length = 4; lines[3] += "..."; }
      const lh = fs * 1.28, y0 = H / 2 - (lines.length - 1) * lh / 2;
      ctx.fillStyle = "#FFFFFF"; ctx.textBaseline = "middle";
      lines.forEach(function (l, i) {
        const w = ctx.measureText(l).width;
        ctx.lineJoin = "round"; ctx.lineWidth = fs / 8; ctx.strokeStyle = "rgba(0,0,0,0.9)";   // a dark rim: readable on a white flash too
        ctx.strokeText(l, (W - w) / 2, y0 + i * lh);
        ctx.fillText(l, (W - w) / 2, y0 + i * lh);
      });
      const px = new Uint8Array(ctx.getImageData(0, 0, W, H).data.buffer);
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);
      gl.bindTexture(gl.TEXTURE_2D, this.textTexture);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, W, H, 0, gl.RGBA, gl.UNSIGNED_BYTE, px);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      gl.generateMipmap(gl.TEXTURE_2D);
      gl.bindTexture(gl.TEXTURE_2D, null);     // as butterchurn's own: leave no texture bound
    };
  }

  // ---------------------------------------------------------------- one block at a time, slow
  // Marko, 15.11.2026: "a slow fade-in with effect, then show what is the most important, then slowly fade out. Only one block
  // of text, only 4 or 5 words ... It's too much text." So: ONE block on screen, at most 5 words; 3 s fade-in (butterchurn's own
  // zoom/wobble settling), 7 s hold, then the text is burned once into the feedback frame and the preset melts it away; then
  // visuals only: cards wait 90-120 s after a block, and never come within 60 s of a track title.
  const FADE_IN = 3000, HOLD = 5000, FADE_OUT = 3000, CARD_GAP = [90000, 120000], TITLE_QUIET = 60000, VOICE_GAP = 10000;
  let active = null, pending = null, lastEnd = 0, lastTitle = -1e9;

  function clip5(text) {             // at most 5 words (marks like "·" "—" are not words); line breaks stay
    let n = 0, out = [];
    String(text).split("\n").forEach(function (line) {
      const keep = [];
      line.split(/\s+/).forEach(function (w) { if (!w) return; if (/[\p{L}\p{N}]/u.test(w)) { if (n >= 5) return; n++; } keep.push(w); });
      if (keep.length) out.push(keep.join(" "));
    });
    return out.join("\n");
  }
  function startBlock(text) {
    const tt = viz && viz.renderer && viz.renderer.titleText;
    if (!tt) return;
    tt.generateTitleTexture(text);
    active = { t0: performance.now(), text: text }; lastText = text; shownCount++;
  }
  function setProgress(r) {          // butterchurn's title progress: <1 is drawn over the picture, >=1 is burned into the feedback
    const rr = viz.renderer;
    rr.supertext = { startTime: rr.time - r, duration: 1 };
  }
  // called once per rendered frame, BEFORE render(): drives the slow fade-in and hold, then the burn (the melt)
  function frame() {
    if (!viz || !viz.renderer) return;
    if (!enabled) { if (active) { active = null; viz.renderer.supertext = { startTime: -1 }; } return; }
    const now = performance.now();
    if (!active && pending && (pending.kind === "title" || now - lastEnd > 800)) { const p = pending; pending = null; startBlock(p.text); }
    if (!active) return;
    const e = now - active.t0, tt = viz.renderer.titleText;
    if (e < FADE_IN) {                                          // 3 s: fades in while butterchurn's zoom/wobble settles
      const x = e / FADE_IN, a = x * x * (3 - 2 * x);
      tt.__alpha = a; setProgress(Math.min(0.9, Math.pow(Math.max(a, 0.001), 1 / 0.3)));
    } else if (e < FADE_IN + HOLD) {                            // 5 s: fully there
      tt.__alpha = 1; setProgress(0.9);
    } else if (e < FADE_IN + HOLD + FADE_OUT) {                 // 3 s: a controlled fade out, no preset involved
      const x = (e - FADE_IN - HOLD) / FADE_OUT;
      tt.__alpha = 1 - x * x * (3 - 2 * x); setProgress(0.9);
    } else {
      tt.__alpha = 0.10; setProgress(1.05);                     // one faint burn into the feedback: a last whisper that melts
      active = null; lastEnd = now;
      setTimeout(function () { tt.__alpha = null; }, 120);
    }
  }

  // kind: "title" (track), "voice" (a key phrase), "api" / "count" (asked for), "card"
  function show(text, kind) {
    text = clip5(String(text == null ? "" : text).trim());
    if (!text) return;
    kind = kind || "api";
    const now = performance.now();
    if (kind === "voice") {                                     // only into a quiet moment
      if (active || pending || now - lastEnd < VOICE_GAP) return;
    }
    if (kind === "title") lastTitle = now;
    pending = { text: text, kind: kind };                       // one waiting block at most: the newest wins
  }

  // ---------------------------------------------------------------- PRE-SHOW
  function minutesText(m) { return m === 1 ? "1 minute to live" : m + " minutes to live"; }
  function shuffle(a) { for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; } return a; }
  function nextGap() { return CARD_GAP[0] + Math.random() * (CARD_GAP[1] - CARD_GAP[0]); }
  function preTick() {
    if (!pre.on) return;
    const now = Date.now(), p = performance.now(), left = Math.round((pre.until - now) / 1000);
    if (pre.until) {
      [20, 10, 5, 1].forEach(function (m) {
        if (left <= m * 60 && left > m * 60 - 20 && !pre.marks.has(m)) { pre.marks.add(m); show(minutesText(m), "count"); }
      });
      if (!pre.marks.has("first")) { pre.marks.add("first"); if (left > 60) show(minutesText(Math.round(left / 60)), "count"); }
      if (left <= 0 && !pre.marks.has(0)) { pre.marks.add(0); show("Live begins now", "count"); }
    }
    if (!active && !pending && cards.length && p >= pre.nextP && p - lastTitle > TITLE_QUIET) {
      if (!pre.deck.length) pre.deck = shuffle(cards.slice());   // no card repeats until all were shown
      show(pre.deck.pop().text, "card");
    }
  }
  function preshow(on, until) {
    pre.on = !!on; pre.until = until || 0; pre.marks = new Set();
    if (pre.timer) { clearInterval(pre.timer); pre.timer = null; }
    if (pre.on) {
      pre.deck = shuffle(cards.slice()); pre.nextP = performance.now() + 20000;
      pre.timer = setInterval(preTick, 1000); preTick();
    }
  }
  // after a block ends the next card waits its gap
  setInterval(function () { if (!active && lastEnd && pre.nextP < lastEnd + 1) pre.nextP = lastEnd + nextGap(); }, 500);
  return {
    attach: attach, show: show, preshow: preshow, frame: frame,
    enable: function (b) { enabled = !!b; if (!enabled) pending = null; },
    setCards: function (c) { cards = c || []; },
    state: function () { return { enabled: enabled, preshow: pre.on, until: pre.until, queued: pending ? 1 : 0, active: !!active, shown: shownCount, last: lastText, cards: cards.length, attached: !!(viz && viz.renderer && viz.renderer.titleText), wrapped: !!(viz && viz.renderer && viz.renderer.titleText && viz.renderer.titleText.__wrapped), err: window.__err || "" }; },
  };
})();
