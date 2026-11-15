// Door.swift: the local API (MANTRA_MANIFEST remote-door.md), JSON over HTTP on 127.0.0.1 only, port claimed as
// "meditation-room" through MANTRA_PORTS (8965 when free). GET /health, GET /api (the actions), GET /api/state,
// POST /api/<action> with a JSON body. The same actions answer at /fn/<action> for STAR_API (~/.config/star-fns).
//
//   curl -s -XPOST localhost:8965/api/play-loop -d '{"output":"BlackHole 2ch","lights":true,"until":"11:55","gain_db":-5}'
import Foundation
import Network
import AppKit

final class Door {
    static let shared = Door()
    static let id = "meditation-room"
    private(set) var port: UInt16 = 8965
    private var listener: NWListener?
    private let q = DispatchQueue(label: "door")
    weak var player: Player?
    weak var lights: Lights?
    weak var viz: Viz?

    static let actions: [[String: Any]] = [
        ["name": "play-loop", "does": "plays every track one after the other in a loop",
         "args": ["output": "device name or a word of it (optional)", "until": "HH:MM local time to stop (optional)",
                  "lights": "bool: keyboard lights on/off (optional)", "lights_mode": "meditation | patterns | both (optional)", "gain_db": "output gain in dB (optional)",
                  "from": "track number 1..13 (optional)"]],
        ["name": "next", "does": "the next track", "args": [:]],
        ["name": "stop", "does": "stops the sound (and the until time)", "args": [:]],
        ["name": "lights", "does": "keyboard lights on or off, and what they show", "args": ["on": "bool",
         "mode": "meditation (the visuals + the counter) | patterns (G815 Lights' ten shows) | both (the visuals, a 20 s pattern every 5 min; default)"]],
        ["name": "output", "does": "plays into this device from now on (the Mac's default output is not changed)", "args": ["name": "string"]],
        ["name": "outputs-on", "does": "plays on all these devices together", "args": ["names": "[string]"]],
        ["name": "outputs", "does": "the devices that can play sound", "args": [:]],
        ["name": "gain", "does": "the output gain in dB (-30 ... +6)", "args": ["db": "number"]],
        ["name": "style", "does": "the visual style: next, prev or a number", "args": ["to": "next | prev | int"]],
        ["name": "status", "does": "what plays, where, the level, the lights", "args": [:]],
    ]

    func start() {
        port = Ports.claim(Door.id, 8965)
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        guard let l = try? NWListener(using: params) else { NSLog("[Room] door: no listener"); return }
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        l.start(queue: q); listener = l
        let dir = NSHomeDirectory() + "/.config/star-fns"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var fns: [String: String] = [:]
        for a in Door.actions { fns[a["name"] as! String] = a["does"] as? String }
        let reg: [String: Any] = ["app": APP_NAME, "port": Int(port), "functions": fns]
        if let d = try? JSONSerialization.data(withJSONObject: reg, options: [.prettyPrinted]) {
            try? d.write(to: URL(fileURLWithPath: dir + "/\(Door.id).json"))
        }
        NSLog("[Room] door on 127.0.0.1:%d", Int(port))
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: q)
        read(c, Data())
    }
    private func read(_ c: NWConnection, _ acc: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self = self else { c.cancel(); return }
            var buf = acc; if let d = data { buf.append(d) }
            if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<r.lowerBound], as: UTF8.self)
                let len = head.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") })
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                if buf.count - r.upperBound >= len || done || err != nil { self.answer(c, head, Data(buf[r.upperBound...])); return }
            } else if done || err != nil || buf.count > 1_000_000 { c.cancel(); return }
            self.read(c, buf)
        }
    }
    private func answer(_ c: NWConnection, _ head: String, _ body: Data) {
        let first = head.components(separatedBy: "\r\n").first ?? ""
        let parts = first.split(separator: " ")
        let method = parts.first.map(String.init) ?? "GET"
        let path = (parts.dropFirst().first.map(String.init) ?? "/").components(separatedBy: "?")[0]
        let args = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        var out: [String: Any]
        switch (method, path) {
        case (_, "/health"):
            out = ["app": Door.id, "name": APP_NAME, "version": VERSION, "pid": Int(getpid())]
        case ("GET", "/api"):
            out = ["app": Door.id, "name": APP_NAME, "version": VERSION, "actions": Door.actions]
        case ("GET", "/api/state"):
            out = DispatchQueue.main.sync { self.state() }
        default:
            let fn = path.hasPrefix("/api/") ? String(path.dropFirst(5)) : path.hasPrefix("/fn/") ? String(path.dropFirst(4)) : String(path.dropFirst())
            out = DispatchQueue.main.sync { self.call(fn, args) }
        }
        let json = (try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        let h = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(h.utf8) + json, completion: .contentProcessed { _ in c.cancel() })
    }

    func state() -> [String: Any] {
        guard let p = player, let l = lights else { return ["ok": false] }
        var s: [String: Any] = [
            "ok": true, "version": VERSION, "playing": p.playing, "track": p.index + 1, "tracks": TRACKS.count,
            "title": p.track.title, "pos": (p.pos * 10).rounded() / 10, "dur": (p.dur * 10).rounded() / 10,
            "output": p.output?.name ?? "", "outputs_on": p.outputs.map(\.name), "system_default_output": Devices.defaultOutput()?.name ?? "",
            "gain_db": p.gainDb, "peak_dbfs": (p.peakDb * 10).rounded() / 10, "played": p.played,
            "lights": ["on": l.on, "mode": l.mode, "pattern": l.pattern, "way": l.way, "frames": l.sent, "fps": (l.fps * 10).rounded() / 10, "error": l.error],
            "visual": ["style": viz?.styleName ?? "", "auto": viz?.auto ?? true, "fps": ((viz?.fps ?? 0) * 10).rounded() / 10],
            "note": p.note, "songs_missing": Songs.missing.map(\.file),
            "title_hidden": App.shared.window?.titleVisibility == .hidden,
            "window": NSApp.windows.first(where: { $0.title == APP_NAME })?.windowNumber ?? 0,
        ]
        if let u = p.until {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            s["until"] = f.string(from: u)
        }
        return s
    }

    func call(_ fn: String, _ a: [String: Any]) -> [String: Any] {
        guard let p = player, let l = lights else { return ["ok": false, "error": "not ready"] }
        switch fn {
        case "play-loop":
            if let o = a["output"] as? String {
                guard let d = Devices.find(o) else { return ["ok": false, "error": "no output device named \(o)"] }
                if p.outputs != [d] { p.setOutput(d) }
            }
            if let os = a["outputs"] as? [String] {
                let ds = os.compactMap { Devices.find($0) }
                guard !ds.isEmpty else { return ["ok": false, "error": "outputs: names of devices"] }
                if p.outputs != ds { p.setOutputs(ds) }
            }
            if let g = a["gain_db"] as? Double { p.setGain(g) }
            if let u = a["until"] as? String {
                guard let d = untilDate(u) else { return ["ok": false, "error": "until is HH:MM"] }
                p.until = d
            }
            if let on = a["lights"] as? Bool { l.set(on) }
            if let m = a["lights_mode"] as? String { l.setMode(m) }
            let from = (a["from"] as? Int).map { $0 - 1 }
            if !p.playing || from != nil { p.play(from ?? p.index) }
            return ["ok": true, "result": state()]
        case "next": p.next(); return ["ok": true, "result": state()]
        case "stop": p.until = nil; p.stop(); return ["ok": true, "result": state()]
        case "lights":
            if let m = a["mode"] as? String {
                guard ["meditation", "patterns", "both"].contains(m) else { return ["ok": false, "error": "mode: meditation | patterns | both"] }
                l.setMode(m)
            }
            if let on = a["on"] as? Bool { l.set(on) } else if a["mode"] == nil { l.set(!l.on) }
            return ["ok": true, "result": state()]
        case "output":
            guard let o = a["name"] as? String, let d = Devices.find(o) else { return ["ok": false, "error": "name: one of the outputs"] }
            p.setOutput(d); return ["ok": true, "result": state()]
        case "outputs-on":
            guard let os = a["names"] as? [String] else { return ["ok": false, "error": "names: [device names]"] }
            p.setOutputs(os.compactMap { Devices.find($0) }); return ["ok": true, "result": state()]
        case "outputs": return ["ok": true, "result": Devices.outputs().map(\.name)]
        case "gain":
            guard let g = a["db"] as? Double else { return ["ok": false, "error": "db is a number"] }
            p.setGain(g); return ["ok": true, "result": state()]
        case "style":
            if let i = a["to"] as? Int { viz?.style(i) } else if (a["to"] as? String) == "prev" { viz?.prev() } else { viz?.next() }
            return ["ok": true]
        case "status", "state": return ["ok": true, "result": state()]
        default: return ["ok": false, "error": "actions: " + Door.actions.compactMap { $0["name"] as? String }.joined(separator: ", ")]
        }
    }
}
