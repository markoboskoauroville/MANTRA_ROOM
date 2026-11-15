// Lights.swift: KEYBOARD LIGHTS. The visualizer's frame, shrunk to a small bitmap, shown on the Logitech G815 as a
// low-resolution display (Marko, 15.11.2026: "my lights are like a low resolution LED LCD display, displaying whatever
// the app is showing").
//
// Two ways to the keys, the first that answers:
//  1. G815 Lights (repo G815_LIGHTS) with its frame API (v35+, MANTRA_MANIFEST modules/keyboard-lights.md): the app
//     registered as "g815" in ~/.config/mantra-ports.json lists "frame" in GET /api; the bitmap goes as
//     POST /api/frame {"w": W, "h": H, "rgb": "rrggbb..."} (row by row from the top left) and the app maps it onto its keys.
//  2. Direct: `g815 serve` (the G815_LIGHTS command line, the same wire the app uses) with the key layout of
//     layout.json: each key takes the colour under its centre; only changed keys are sent, all of them every 2 s
//     (G815 Lights repaints its bank now and then), as tools/lightshow.py does.
import Foundation

final class Lights: ObservableObject {
    static let W = 24, H = 8                   // the keyboard is 24 x 7.5 key units (layout.json)
    @Published var on = UserDefaults.standard.bool(forKey: "lights")
    @Published var way = "off"                 // "frame API" | "direct" | "off" | "no keyboard"
    @Published var sent = 0                    // frames that reached the keyboard
    @Published var fps: Double = 0
    @Published var error = ""

    private let q = DispatchQueue(label: "lights")
    private var busy = false
    private var apiBase: String? = nil
    private var lastProbe = Date.distantPast
    private var proc: Process? = nil
    private var inPipe: FileHandle? = nil
    private var outPipe: FileHandle? = nil
    private var keys: [(id: UInt8, x: Double, y: Double)] = []
    private var last: [UInt8: UInt32] = [:]
    private var fullAt = Date.distantPast
    private var count = 0, countAt = Date()

    func set(_ v: Bool) {
        on = v
        UserDefaults.standard.set(v, forKey: "lights")
        if !v { q.async { self.blackout(); self.stopDirect() }; way = "off" }
    }

    /// a frame from the visualizer: W*H pixels as hex rrggbb, row by row. Dropped when the last one is still on its way.
    func frame(_ hex: String) {
        guard on, !busy, hex.count >= Lights.W * Lights.H * 6 else { return }
        busy = true
        q.async {
            defer { self.busy = false }
            let px = Lights.boost(Lights.parse(hex))
            let ok = self.sendAPI(hex: Lights.hex(px)) || self.sendDirect(px)
            DispatchQueue.main.async {
                if ok { self.sent += 1; self.count += 1; self.error = "" }
                let dt = Date().timeIntervalSince(self.countAt)
                if dt >= 1 { self.fps = Double(self.count) / dt; self.count = 0; self.countAt = Date() }
            }
        }
    }

    // ---------------------------------------------------------------- the picture made readable on keys
    static func parse(_ hex: String) -> [UInt32] {
        var out = [UInt32](); out.reserveCapacity(W * H)
        let b = Array(hex.utf8)
        func nib(_ c: UInt8) -> UInt32 { c >= 97 ? UInt32(c - 87) : c >= 65 ? UInt32(c - 55) : UInt32(c &- 48) }
        var i = 0
        while i + 6 <= b.count && out.count < W * H {
            var v: UInt32 = 0
            for k in 0..<6 { v = v << 4 | nib(b[i + k]) }
            out.append(v); i += 6
        }
        return out
    }
    static func hex(_ px: [UInt32]) -> String { px.map { String(format: "%06x", $0) }.joined() }
    /// MilkDrop is often dark and a key shows nothing below about 45 of 255 (G815_LIGHTS, nightLevel): the frame is
    /// stretched so its brightest channel is near full, then lifted above that floor; real black stays black.
    static func boost(_ px: [UInt32]) -> [UInt32] {
        var mx: UInt32 = 1
        for p in px { mx = max(mx, p >> 16 & 255, p >> 8 & 255, p & 255) }
        let k = min(4.0, 250.0 / Double(max(mx, 40)))
        return px.map { p in
            func ch(_ v: UInt32) -> UInt32 {
                let s = Double(v) * k
                return s < 14 ? 0 : UInt32(min(255, 45 + s * 210 / 255))
            }
            return ch(p >> 16 & 255) << 16 | ch(p >> 8 & 255) << 8 | ch(p & 255)
        }
    }

    // ---------------------------------------------------------------- 1. the G815 Lights frame API
    private func probe() {
        guard Date().timeIntervalSince(lastProbe) > 5 else { return }
        lastProbe = Date()
        apiBase = nil
        guard let base = Ports.find("g815") ?? Ports.find("g815-lights"),
              let u = URL(string: base + "/api"), let d = Lights.get(u),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let acts = j["actions"] as? [[String: Any]],
              acts.contains(where: { ($0["name"] as? String) == "frame" }) else { return }
        apiBase = base
    }
    private func sendAPI(hex: String) -> Bool {
        if apiBase == nil { probe() }
        guard let base = apiBase, let u = URL(string: base + "/api/frame") else { return false }
        let body: [String: Any] = ["w": Lights.W, "h": Lights.H, "rgb": hex, "from": "meditation-room"]
        guard let d = Lights.post(u, body), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              (j["ok"] as? Bool) == true else { apiBase = nil; return false }
        if way != "frame API" { stopDirect(); DispatchQueue.main.async { self.way = "frame API" } }
        return true
    }

    // ---------------------------------------------------------------- 2. direct, through `g815 serve`
    static let cli = [NSHomeDirectory() + "/Developer/G815_LIGHTS/build/g815", "/Applications/G815 Lights.app/Contents/MacOS/g815"]
    static let layouts = ["/Applications/G815 Lights.app/Contents/Resources/layout.json",
                          NSHomeDirectory() + "/Developer/G815_LIGHTS/layout.json"]
    private func startDirect() -> Bool {
        if proc?.isRunning == true { return true }
        if keys.isEmpty {
            for p in Lights.layouts {
                guard let d = FileManager.default.contents(atPath: p),
                      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let ks = j["keys"] as? [[String: Any]] else { continue }
                keys = ks.compactMap { k in
                    guard let s = k["id"] as? String, let id = UInt8(s, radix: 16), let x = k["x"] as? Double ?? (k["x"] as? Int).map(Double.init),
                          let y = k["y"] as? Double ?? (k["y"] as? Int).map(Double.init) else { return nil }
                    let w = k["w"] as? Double ?? (k["w"] as? Int).map(Double.init) ?? 1
                    let h = k["h"] as? Double ?? (k["h"] as? Int).map(Double.init) ?? 1
                    return (id, x + w / 2, y + h / 2)
                }
                if !keys.isEmpty { break }
            }
        }
        guard !keys.isEmpty else { DispatchQueue.main.async { self.error = "no layout.json of G815 Lights" }; return false }
        guard let exe = Lights.cli.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            DispatchQueue.main.async { self.error = "no g815 command (G815_LIGHTS/build/g815)" }; return false }
        let p = Process(), i = Pipe(), o = Pipe()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = ["serve"]
        p.standardInput = i; p.standardOutput = o; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { DispatchQueue.main.async { self.error = "g815 serve: \(error.localizedDescription)" }; return false }
        proc = p; inPipe = i.fileHandleForWriting; outPipe = o.fileHandleForReading
        last = [:]; fullAt = .distantPast
        DispatchQueue.main.async { self.way = "direct" }
        NSLog("[Room] lights: g815 serve started (%d keys)", keys.count)
        return true
    }
    private func stopDirect() {
        if let p = proc, p.isRunning { try? inPipe?.close(); p.terminate() }
        proc = nil; inPipe = nil; outPipe = nil
    }
    private func readLine() -> String? {
        guard let h = outPipe else { return nil }
        var acc = Data()
        while true {
            let d = h.readData(ofLength: 1)
            if d.isEmpty { return nil }
            if d[0] == 10 { return String(decoding: acc, as: UTF8.self) }
            acc.append(d)
        }
    }
    private func sendDirect(_ px: [UInt32]) -> Bool {
        guard startDirect(), let w = inPipe else { return false }
        if Date().timeIntervalSince(fullAt) > 2 { last = [:]; fullAt = Date() }
        var parts: [String] = []
        for k in keys {
            // the colour under the key's centre, bilinear between the four nearest pixels
            let fx = max(0, min(Double(Lights.W) - 1.001, k.x / 24 * Double(Lights.W) - 0.5))
            let fy = max(0, min(Double(Lights.H) - 1.001, k.y / 7.5 * Double(Lights.H) - 0.5))
            let x0 = Int(fx), y0 = Int(fy), ax = fx - Double(x0), ay = fy - Double(y0)
            func at(_ x: Int, _ y: Int) -> UInt32 { px[min(Lights.H - 1, y) * Lights.W + min(Lights.W - 1, x)] }
            var c: UInt32 = 0
            for sh in [16, 8, 0] {
                func v(_ p: UInt32) -> Double { Double(p >> UInt32(sh) & 255) }
                let top = v(at(x0, y0)) * (1 - ax) + v(at(x0 + 1, y0)) * ax
                let bot = v(at(x0, y0 + 1)) * (1 - ax) + v(at(x0 + 1, y0 + 1)) * ax
                c |= UInt32(min(255, max(0, (top * (1 - ay) + bot * ay).rounded()))) << UInt32(sh)
            }
            if last[k.id] != c { parts.append(String(format: "%02x:%06x", k.id, c)); last[k.id] = c }
        }
        if parts.isEmpty { return true }
        do {
            try w.write(contentsOf: Data(("paint " + parts.joined(separator: " ") + "\n").utf8))
        } catch { stopDirect(); return false }
        guard let line = readLine() else { stopDirect(); return false }
        if line.contains("\"ok\":false") || line.contains("\"ok\" : false") {
            DispatchQueue.main.async { self.error = String(line.prefix(120)); self.way = "no keyboard" }
            stopDirect(); return false
        }
        return true
    }
    private func blackout() {
        if let w = inPipe, !keys.isEmpty {
            let s = "paint " + keys.map { String(format: "%02x:000000", $0.id) }.joined(separator: " ") + "\n"
            try? w.write(contentsOf: Data(s.utf8)); _ = readLine()
        }
    }

    // ---------------------------------------------------------------- small HTTP, synchronous on the lights queue
    static func get(_ u: URL) -> Data? { http(URLRequest(url: u, timeoutInterval: 0.6)) }
    static func post(_ u: URL, _ body: [String: Any]) -> Data? {
        var r = URLRequest(url: u, timeoutInterval: 0.6)
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return http(r)
    }
    static func http(_ r: URLRequest) -> Data? {
        let sem = DispatchSemaphore(value: 0); var out: Data? = nil
        URLSession.shared.dataTask(with: r) { d, resp, _ in
            if let h = resp as? HTTPURLResponse, h.statusCode == 200 { out = d }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 1)
        return out
    }
}
