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
  const queue = []; let lastShown = 0, shownCount = 0, lastText = "";
  let pre = { on: false, until: 0, marks: new Set(), next: 0, deck: [], timer: null, started: 0 };

  function attach(v) {
    viz = v;
    const tt = v && v.renderer && v.renderer.titleText;
    if (!tt || tt.__wrapped) return;
    tt.__wrapped = true;
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
        ctx.fillText(l, (W - w) / 2, y0 + i * lh);
      });
      const px = new Uint8Array(ctx.getImageData(0, 0, W, H).data.buffer);
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);
      gl.bindTexture(gl.TEXTURE_2D, this.textTexture);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, W, H, 0, gl.RGBA, gl.UNSIGNED_BYTE, px);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
    };
  }

  function launch(text) {
    if (!viz || !viz.launchSongTitleAnim) return;
    viz.launchSongTitleAnim(text); lastShown = Date.now(); shownCount++; lastText = text;
  }
  // one text at a time: butterchurn's animation runs 1.7 s, the next one waits for it
  function pump() {
    if (!enabled || !queue.length) return;
    if (Date.now() - lastShown < 1900) return;
    launch(queue.shift());
  }
  setInterval(pump, 200);

  function show(text) {
    text = String(text == null ? "" : text).trim();
    if (!text) return;
    if (queue.length >= 4) queue.shift();       // never a long backlog: the newest words matter
    queue.push(text); pump();
  }

  // ---------------------------------------------------------------- PRE-SHOW
  function minutesText(m) { return m === 1 ? "1 minute until the live stream" : m + " minutes until the live stream"; }
  function shuffle(a) { for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; } return a; }
  function cardText(c) { return c.title + (c.sanskrit ? "   " + c.sanskrit : "") + "\n" + c.text; }
  function scheduleCard() { pre.next = Date.now() + (45 + Math.random() * 45) * 1000; }
  function preTick() {
    if (!pre.on) return;
    const now = Date.now(), left = Math.round((pre.until - now) / 1000);
    if (pre.until) {
      // the marks 20, 10, 5, 1 minutes; on start the one we are inside is said once
      [20, 10, 5, 1].forEach(function (m) {
        if (left <= m * 60 && left > m * 60 - 20 && !pre.marks.has(m)) { pre.marks.add(m); show(minutesText(m)); }
      });
      if (!pre.marks.has("first")) { pre.marks.add("first"); if (left > 60) show(minutesText(Math.round(left / 60))); }
      if (left <= 0 && !pre.marks.has(0)) { pre.marks.add(0); show("The live stream begins now"); }
    }
    if (now >= pre.next && cards.length && (left > 20 || !pre.until || left <= 0 || true)) {
      if (!pre.deck.length) pre.deck = shuffle(cards.slice());       // no card repeats until all were shown
      show(cardText(pre.deck.pop()));
      scheduleCard();
    }
  }
  function preshow(on, until) {
    pre.on = !!on; pre.until = until || 0; pre.marks = new Set();
    if (pre.timer) { clearInterval(pre.timer); pre.timer = null; }
    if (pre.on) {
      pre.deck = shuffle(cards.slice()); pre.next = Date.now() + 8000;
      pre.timer = setInterval(preTick, 1000); preTick();
    }
  }
  return {
    attach: attach, show: show, preshow: preshow,
    enable: function (b) { enabled = !!b; if (!enabled) queue.length = 0; },
    setCards: function (c) { cards = c || []; },
    state: function () { return { enabled: enabled, preshow: pre.on, until: pre.until, queued: queue.length, shown: shownCount, last: lastText, cards: cards.length, attached: !!(viz && viz.renderer && viz.renderer.titleText), wrapped: !!(viz && viz.renderer && viz.renderer.titleText && viz.renderer.titleText.__wrapped), err: window.__err || "" }; },
  };
})();
