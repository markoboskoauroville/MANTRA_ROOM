// Captions.swift: the melting text (MilkDrop's song-title animation, butterchurn's own, drawn INTO the visual's frame so the
// preset melts it) and PRE-SHOW. The engine is web/textfx.js (portable, the Linux VM version loads the same file); this file
// only feeds it: the track title at each track start, the guide's spoken lines (timed with Whisper through MANTRA_VOICE
// /hear, mac/web/lines/<track>.json) while it speaks, the PRE-SHOW switch and the lines pushed through the local API.
// Marko, 15.11.2026 (momentaryupdates.md, Requests 46).
import AppKit
import Foundation

final class Captions: ObservableObject {
    static let shared = Captions()
    struct Line: Decodable { let t: Double; let e: Double; let text: String }
    private struct File: Decodable { let lines: [Line] }

    @Published var textOn: Bool = UserDefaults.standard.object(forKey: "textOn") as? Bool ?? true
    @Published var preOn: Bool = UserDefaults.standard.bool(forKey: "preOn")
    @Published var preUntil: Date? = {
        let t = UserDefaults.standard.double(forKey: "preUntil"); return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }()
    weak var viz: Viz?
    private var lines: [Line] = []
    private var shown = -1
    @Published var engine = ""                 // TextFX.state() as the page reports it (for /api/state)
    func poll() { viz?.web.evaluateJavaScript("window.TextFX ? JSON.stringify(TextFX.state()) : 'no TextFX'") { [weak self] r, e in self?.engine = (r as? String) ?? (e.map { "\($0)" } ?? "") } }

    private func q(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s]), let j = String(data: d, encoding: .utf8) else { return "\"\"" }
        return String(j.dropFirst().dropLast())
    }
    /// the page is ready (or the state changed): tell textfx.js
    func apply() {
        viz?.run("TextFX.enable(\(textOn))")
        let ms = Int((preUntil?.timeIntervalSince1970 ?? 0) * 1000)
        viz?.run("TextFX.preshow(\(preOn), \(ms))")
    }
    func show(_ text: String) { viz?.run("TextFX.show(\(q(text)))") }

    func setText(_ on: Bool) { textOn = on; UserDefaults.standard.set(on, forKey: "textOn"); apply() }
    func setPre(_ on: Bool, until: Date? = nil) {
        if let u = until { preUntil = u }
        if on && preUntil == nil || on && (preUntil ?? .distantPast) < Date() { preUntil = Date().addingTimeInterval(20 * 60) }
        preOn = on
        UserDefaults.standard.set(on, forKey: "preOn")
        UserDefaults.standard.set(preUntil?.timeIntervalSince1970 ?? 0, forKey: "preUntil")
        apply()
    }
    func shift(minutes: Int) {
        let base = max(preUntil ?? Date(), Date())
        setPre(preOn, until: base.addingTimeInterval(Double(minutes) * 60))
    }

    /// a track begins (or is entered at `from`): its title melts in, and its spoken lines are loaded
    func trackStarted(_ t: Track, from: Double) {
        show("DJ Mantra — " + t.title)
        shown = -1
        lines = []
        if let dir = Bundle.main.resourceURL?.appendingPathComponent("web/lines"),
           let d = try? Data(contentsOf: dir.appendingPathComponent(t.file + ".json")),
           let f = try? JSONDecoder().decode(File.self, from: d) {
            lines = f.lines
            while shown + 1 < lines.count && lines[shown + 1].e <= from { shown += 1 }     // lines already spoken stay unshown
        }
    }
    /// every quarter second while playing: a spoken line appears when it starts (within 1.5 s of its start)
    func tick(pos: Double) {
        while shown + 1 < lines.count, lines[shown + 1].t <= pos {
            shown += 1
            if pos < lines[shown].e + 1.5 { show(lines[shown].text) }
        }
    }
}
