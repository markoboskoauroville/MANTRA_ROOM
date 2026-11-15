// Lights.swift: KEYBOARD LIGHTS. The visualizer's frame shown on the Logitech G815 as a low-resolution display (Marko,
// 15.11.2026: "my lights are like a low resolution LED LCD display, displaying whatever the app is showing"), with the
// liveness counter in every frame and, in mode "both", one of G815 Lights' ten patterns for 20 s every 5 minutes
// (Marko, 15.11.2026: "I'm saying both, pattern and meditation.").
//
// The way to the keys, the first that answers:
//  1. G815 Lights v35+ (MANTRA_MANIFEST modules/keyboard-lights.md): GET http://127.0.0.1:8877/layout once, then raw
//     frames over its TCP stream 127.0.0.1:8878 ('R' + 4-byte big-endian length + 115 x RGB in /layout order). The app
//     does gamma and the dark floor. Patterns: POST /show/<name> {"seconds":20,"counter":true,"ttl":20}; off: POST /stop.
//  2. Direct, when G815 Lights does not answer: `G815_LIGHTS/build/g815 serve` with layout.json, changed keys only.
//
// Each key is the average of the pixels under it: the frame comes as 48 x 15 (2 pixels per key unit of the 24 x 7.5 board).
// The counter (the same as G815 Lights' Shows.counter): F1-F6 the seconds in binary (yellow on, dim red off), F7-F12
// dark, ESC green on odd seconds and red on even ones, so a frozen stream is obvious on the camera.
import Foundation
import Darwin

final class Lights: ObservableObject {
    static let W = 48, H = 15
    static let patterns = ["sweep", "rainbow", "digits", "rain", "ripple", "scan", "checker", "chase", "sparkle", "heartbeat"]
    @Published var on = UserDefaults.standard.bool(forKey: "lights")
    @Published var mode = UserDefaults.standard.string(forKey: "lightsMode") ?? "both"   // meditation | patterns | both
    @Published var way = "off"                 // "G815 Lights stream" | "direct" | "off"
    @Published var sent = 0
    @Published var fps: Double = 0
    @Published var error = ""
    @Published var pattern = ""                // the pattern playing now (mode both / patterns)

    private let q = DispatchQueue(label: "lights")
    private var busy = false
    private let base = "http://127.0.0.1:8877"
    private var keys: [(id: UInt8, x: Double, y: Double, w: Double, h: Double)] = []   // in /layout order
    private var apiOK = false
    private var lastProbe = Date.distantPast
    private var sock: Int32 = -1
    private var proc: Process? = nil
    private var inPipe: FileHandle? = nil
    private var outPipe: FileHandle? = nil
    private var last: [UInt8: UInt32] = [:]
    private var fullAt = Date.distantPast
    private var count = 0, countAt = Date()
    private var patternUntil = Date.distantPast
    private var nextPattern = Date().addingTimeInterval(300)
    private var patternIx = 0
    private var patternsShowAt = Date.distantPast
    private var clock: Timer? = nil

    init() {
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.everySecond() }
        RunLoop.main.add(clock!, forMode: .common)
    }

    func set(_ v: Bool) {
        on = v
        UserDefaults.standard.set(v, forKey: "lights")
        if v { nextPattern = Date().addingTimeInterval(300); patternsShowAt = .distantPast }
        else { pattern = ""; q.async { self.release() }; way = "off" }
    }
    func setMode(_ m: String) {
        guard ["meditation", "patterns", "both"].contains(m) else { return }
        mode = m; UserDefaults.standard.set(m, forKey: "lightsMode")
        patternUntil = .distantPast; pattern = ""; patternsShowAt = .distantPast
        nextPattern = Date().addingTimeInterval(m == "both" ? 300 : 0)
        if m == "meditation" { q.async { _ = self.post("/stop", [:]) } }
    }

    private func everySecond() {
        guard on else { return }
        let now = Date()
        if mode == "patterns" {
            // the built-in shows in turn, with the counter; asked again when something else took the keys
            if now >= patternsShowAt {
                patternsShowAt = now.addingTimeInterval(30)
                q.async {
                    if let d = self.getJSON("/status"), (d["mode"] as? String) == "show", (d["show"] as? String) == "all" { return }
                    _ = self.post("/show", ["name": "all", "seconds": 25, "counter": true, "ttl": 0])
                    DispatchQueue.main.async { self.pattern = "all"; self.way = "G815 Lights shows" }
                }
            }
            return
        }
        if mode == "both", now >= nextPattern, patternUntil < now {
            let name = Lights.patterns[patternIx % Lights.patterns.count]; patternIx += 1
            patternUntil = now.addingTimeInterval(20.5); nextPattern = now.addingTimeInterval(300)
            pattern = name
            NSLog("[Room] lights: pattern %@ for 20 s", name)
            q.async { _ = self.post("/show/\(name)", ["seconds": 20, "counter": true, "ttl": 20]) }
        }
        if pattern != "", patternUntil < now { pattern = "" }
    }

    /// a frame from the visualizer: W*H pixels as hex rrggbb, row by row. Dropped while the last one is on its way,
    /// while a pattern plays, and in mode "patterns".
    func frame(_ hex: String) {
        guard on, mode != "patterns", Date() >= patternUntil, !busy, hex.count >= Lights.W * Lights.H * 6 else { return }
        busy = true
        q.async {
            defer { self.busy = false }
            let px = Lights.stretch(Lights.parse(hex))
            let ok = self.sendStream(px) || self.sendDirect(px)
            DispatchQueue.main.async {
                if ok { self.sent += 1; self.count += 1; self.error = "" }
                let dt = Date().timeIntervalSince(self.countAt)
                if dt >= 1 { self.fps = Double(self.count) / dt; self.count = 0; self.countAt = Date() }
            }
        }
    }

    // ---------------------------------------------------------------- the picture
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
    /// MilkDrop is often dark: stretched so the brightest channel is near full (at most 4x)
    static func stretch(_ px: [UInt32]) -> [UInt32] {
        var mx: UInt32 = 1
        for p in px { mx = max(mx, p >> 16 & 255, p >> 8 & 255, p & 255) }
        let k = min(4.0, 250.0 / Double(max(mx, 40)))
        return px.map { p in
            func ch(_ v: UInt32) -> UInt32 { UInt32(min(255, Double(v) * k)) }
            return ch(p >> 16 & 255) << 16 | ch(p >> 8 & 255) << 8 | ch(p & 255)
        }
    }
    /// the average of the pixels under a key (key units: 24 x 7.5 → 48 x 15 pixels)
    private func color(_ px: [UInt32], _ k: (id: UInt8, x: Double, y: Double, w: Double, h: Double)) -> (UInt8, UInt8, UInt8) {
        let sx = Double(Lights.W) / 24, sy = Double(Lights.H) / 7.5
        let x0 = max(0, min(Lights.W - 1, Int(k.x * sx))), x1 = max(x0 + 1, min(Lights.W, Int((k.x + k.w) * sx)))
        let y0 = max(0, min(Lights.H - 1, Int(k.y * sy))), y1 = max(y0 + 1, min(Lights.H, Int((k.y + k.h) * sy)))
        var r = 0, g = 0, b = 0, n = 0
        for y in y0..<y1 { for x in x0..<x1 { let p = px[y * Lights.W + x]; r += Int(p >> 16 & 255); g += Int(p >> 8 & 255); b += Int(p & 255); n += 1 } }
        n = max(1, n)
        return (UInt8(r / n), UInt8(g / n), UInt8(b / n))
    }
    /// F1-F6 binary seconds, F7-F12 dark, ESC green/red: exactly G815 Lights' Shows.counter
    static func counter(_ id: UInt8) -> (UInt8, UInt8, UInt8)? {
        let s = Int(Date().timeIntervalSince1970) % 60
        if id >= 0x37 && id <= 0x3C { return (s >> Int(id - 0x37)) & 1 == 1 ? (255, 255, 0) : (60, 0, 0) }
        if id >= 0x3D && id <= 0x42 { return (0, 0, 0) }
        if id == 0x26 { return s % 2 == 1 ? (0, 255, 0) : (255, 0, 0) }
        return nil
    }

    // ---------------------------------------------------------------- 1. G815 Lights: layout + TCP stream
    private func loadLayout() -> Bool {
        if !keys.isEmpty && apiOK { return true }
        guard Date().timeIntervalSince(lastProbe) > 3 else { return false }
        lastProbe = Date()
        guard let d = getJSON("/layout"), let ks = d["keys"] as? [[String: Any]], !ks.isEmpty else { apiOK = false; return false }
        let sorted = ks.sorted { ($0["n"] as? Int ?? 0) < ($1["n"] as? Int ?? 0) }
        keys = sorted.compactMap { k in
            guard let s = k["id"] as? String, let id = UInt8(s, radix: 16) else { return nil }
            return (id, (k["x"] as? Double) ?? 0, (k["y"] as? Double) ?? 0, (k["w"] as? Double) ?? 1, (k["h"] as? Double) ?? 1)
        }
        apiOK = keys.count == ks.count
        return apiOK
    }
    private func connectStream() -> Bool {
        if sock >= 0 { return true }
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = UInt16(8878).bigEndian
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
        if !ok { close(s); return false }
        sock = s
        NSLog("[Room] lights: stream to G815 Lights (%d keys)", keys.count)
        return true
    }
    private func sendStream(_ px: [UInt32]) -> Bool {
        guard loadLayout(), connectStream() else { return false }
        if proc != nil { stopDirect() }
        var payload = [UInt8](); payload.reserveCapacity(keys.count * 3)
        for k in keys {
            let c = Lights.counter(k.id) ?? color(px, k)
            payload += [c.0, c.1, c.2]
        }
        let n = UInt32(payload.count)
        let msg: [UInt8] = [UInt8(ascii: "R"), UInt8(n >> 24 & 255), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)] + payload
        let w = msg.withUnsafeBytes { Darwin.write(sock, $0.baseAddress, msg.count) }
        if w != msg.count { close(sock); sock = -1; apiOK = false; return false }
        if way != "G815 Lights stream" { DispatchQueue.main.async { self.way = "G815 Lights stream" } }
        return true
    }
    private func release() {
        if sock >= 0 { close(sock); sock = -1 }
        _ = post("/stop", [:])                        // the bank's own colours come back
        blackoutDirect(); stopDirect()
    }

    // ---------------------------------------------------------------- 2. direct, through `g815 serve`
    static let cli = [NSHomeDirectory() + "/Developer/G815_LIGHTS/build/g815"]
    static let layouts = ["/Applications/G815 Lights.app/Contents/Resources/layout.json",
                          NSHomeDirectory() + "/Developer/G815_LIGHTS/build/G815 Lights.app/Contents/Resources/layout.json",
                          NSHomeDirectory() + "/Developer/G815_LIGHTS/layout.json"]
    private var directKeys: [(id: UInt8, x: Double, y: Double, w: Double, h: Double)] = []
    private func startDirect() -> Bool {
        if proc?.isRunning == true { return true }
        if directKeys.isEmpty {
            for p in Lights.layouts {
                guard let d = FileManager.default.contents(atPath: p),
                      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let ks = j["keys"] as? [[String: Any]] else { continue }
                directKeys = ks.compactMap { k in
                    guard let s = k["id"] as? String, let id = UInt8(s, radix: 16) else { return nil }
                    return (id, (k["x"] as? Double) ?? 0, (k["y"] as? Double) ?? 0, (k["w"] as? Double) ?? 1, (k["h"] as? Double) ?? 1)
                }
                if !directKeys.isEmpty { break }
            }
        }
        guard !directKeys.isEmpty else { DispatchQueue.main.async { self.error = "G815 Lights does not answer and no layout.json" }; return false }
        guard let exe = Lights.cli.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            DispatchQueue.main.async { self.error = "G815 Lights does not answer (127.0.0.1:8877)" }; return false }
        let p = Process(), i = Pipe(), o = Pipe()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = ["serve"]
        p.standardInput = i; p.standardOutput = o; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        proc = p; inPipe = i.fileHandleForWriting; outPipe = o.fileHandleForReading
        last = [:]; fullAt = .distantPast
        DispatchQueue.main.async { self.way = "direct" }
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
        for k in directKeys {
            var c = Lights.counter(k.id) ?? color(px, k)
            // a key shows nothing below about 45: lift what is not black (G815 Lights does this itself on the stream)
            func lift(_ v: UInt8) -> UInt8 { v < 6 ? 0 : UInt8(min(255, 45 + Int(v) * 210 / 255)) }
            c = (lift(c.0), lift(c.1), lift(c.2))
            let v = UInt32(c.0) << 16 | UInt32(c.1) << 8 | UInt32(c.2)
            if last[k.id] != v { parts.append(String(format: "%02x:%06x", k.id, v)); last[k.id] = v }
        }
        if parts.isEmpty { return true }
        do { try w.write(contentsOf: Data(("paint " + parts.joined(separator: " ") + "\n").utf8)) } catch { stopDirect(); return false }
        guard let line = readLine(), !line.contains("\"ok\":false") else { stopDirect(); return false }
        return true
    }
    private func blackoutDirect() {
        if let w = inPipe, !directKeys.isEmpty {
            let s = "paint " + directKeys.map { String(format: "%02x:000000", $0.id) }.joined(separator: " ") + "\n"
            try? w.write(contentsOf: Data(s.utf8)); _ = readLine()
        }
    }

    // ---------------------------------------------------------------- small HTTP, synchronous on the lights queue
    func getJSON(_ path: String) -> [String: Any]? {
        guard let u = URL(string: base + path), let d = Lights.http(URLRequest(url: u, timeoutInterval: 1)) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
    @discardableResult
    func post(_ path: String, _ body: [String: Any]) -> [String: Any]? {
        guard let u = URL(string: base + path) else { return nil }
        var r = URLRequest(url: u, timeoutInterval: 1)
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let d = Lights.http(r) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
    static func http(_ r: URLRequest) -> Data? {
        let sem = DispatchSemaphore(value: 0); var out: Data? = nil
        URLSession.shared.dataTask(with: r) { d, resp, _ in
            if let h = resp as? HTTPURLResponse, h.statusCode == 200 { out = d }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 1.5)
        return out
    }
}
