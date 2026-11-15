// Ndi.swift: the picture and the sound of the room as an NDI source "Meditation Room (Mantra)" on the network (Marko,
// 15.11.2026: "NDI HX output"). The NDI runtime that NDI Tools installs (libndi.dylib) is loaded with dlopen, as Sound Link
// does: no SDK file is in this public repository, nothing is linked. The calls and structs are the public NDI C ABI
// (NDIlib_send_create_t, NDIlib_video_frame_v2_t, NDIlib_audio_frame_v2_t).
// NOT HX: HX (H.264/HEVC) sending on the Mac needs the NDI Advanced SDK, which we do not hold for macOS. The installed
// runtime sends full NDI (SpeedHQ, I-frame video, about 100 Mbit/s at 1280 px, so Ethernet or a good Wi-Fi). Receivers
// (OBS, vMix, Sound Link) take it the same way.
import AppKit
import AVFoundation
import ImageIO
import WebKit

struct NDISendCreate { var p_ndi_name: UnsafePointer<CChar>?; var p_groups: UnsafePointer<CChar>?; var clock_video: Bool; var clock_audio: Bool }
struct NDIVideoFrame {
    var xres: Int32, yres: Int32, FourCC: UInt32, frame_rate_N: Int32, frame_rate_D: Int32
    var picture_aspect_ratio: Float, frame_format_type: Int32, timecode: Int64
    var p_data: UnsafeMutablePointer<UInt8>?, line_stride_in_bytes: Int32, p_metadata: UnsafePointer<CChar>?, timestamp: Int64
}
struct NDIAudioFrame {
    var sample_rate: Int32, no_channels: Int32, no_samples: Int32, timecode: Int64
    var p_data: UnsafeMutablePointer<Float>?, channel_stride_in_bytes: Int32, p_metadata: UnsafePointer<CChar>?, timestamp: Int64
}

final class NDISender: ObservableObject {
    static let shared = NDISender()
    static let sourceName = "Meditation Room"   // no nested parentheses: NDI Video Monitor lists but cannot connect to "Meditation Room (Mantra)"
    @Published var on = false
    @Published var note = ""
    weak var viz: Viz?

    private typealias FInit = @convention(c) () -> Bool
    private typealias FCreate = @convention(c) (UnsafeRawPointer) -> UnsafeMutableRawPointer?
    private typealias FVideo = @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer) -> Void
    private typealias FAudio = @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer) -> Void
    private typealias FDestroy = @convention(c) (UnsafeMutableRawPointer) -> Void
    private var fCreate: FCreate?, fVideo: FVideo?, fAudio: FAudio?, fDestroy: FDestroy?
    private var loaded = false
    private var sender: UnsafeMutableRawPointer?
    private let q = DispatchQueue(label: "ndi.send")
    private var gen = 0
    static let wantsOn = UserDefaults.standard.bool(forKey: "ndi")

    private func load() -> Bool {
        if loaded { return true }
        var paths: [String] = []
        for k in ["NDI_RUNTIME_DIR_V6", "NDI_RUNTIME_DIR_V5"] { if let d = ProcessInfo.processInfo.environment[k] { paths.append(d + "/libndi.dylib") } }
        paths += ["/usr/local/lib/libndi.dylib", "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib",
                  "/Library/Application Support/NewTek/NDI/libndi.dylib", "/opt/homebrew/lib/libndi.dylib"]
        for p in paths {
            guard FileManager.default.fileExists(atPath: p), let h = dlopen(p, RTLD_NOW) else { continue }
            func sym<T>(_ n: String, _ t: T.Type) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: t) } }
            guard let ini = sym("NDIlib_initialize", FInit.self), let c = sym("NDIlib_send_create", FCreate.self),
                  let v = sym("NDIlib_send_send_video_v2", FVideo.self), let a = sym("NDIlib_send_send_audio_v2", FAudio.self),
                  let d = sym("NDIlib_send_destroy", FDestroy.self), ini() else { continue }
            fCreate = c; fVideo = v; fAudio = a; fDestroy = d; loaded = true
            NSLog("[Room] NDI runtime: %@", p)
            return true
        }
        return false
    }

    func set(_ want: Bool) {
        guard want != on else { return }
        if want {
            guard load() else { note = "NDI runtime not found (install NDI Tools)"; return }
            var s: UnsafeMutableRawPointer?
            NDISender.sourceName.withCString { n in
                var c = NDISendCreate(p_ndi_name: n, p_groups: nil, clock_video: false, clock_audio: false)
                s = withUnsafePointer(to: &c) { self.fCreate?(UnsafeRawPointer($0)) }
            }
            guard let made = s else { note = "NDI could not start the source"; return }
            sender = made; gen += 1; on = true; note = ""
            UserDefaults.standard.set(true, forKey: "ndi")
            NSLog("[Room] NDI source on: %@", NDISender.sourceName)
            startPicture()
        } else {
            on = false; gen += 1; stopPicture()
            UserDefaults.standard.set(false, forKey: "ndi")
            let s = sender, d = fDestroy; sender = nil
            q.async { if let s = s { d?(s) } }
            NSLog("[Room] NDI source off")
        }
    }

    // ---------------------------------------------------------------- the picture
    // Two parts (MANTRA_MANIFEST modules/ndi-best-practice.md): (1) snapshots of the visual are taken as fast as WebKit
    // gives them (about 24 per second) into `latest`; (2) a steady 25 Hz timer sends `latest` again and again, so the
    // declared 25/1 is true even when a snapshot is late. A watchdog starts the snapshot loop anew when a callback never returns.
    private var latest = [UInt8](repeating: 0, count: 1280 * 4 * 720)   // black until the first snapshot (q only)
    private var timer: DispatchSourceTimer?
    private var watchdog: Timer?
    private var lastSnap = Date()
    private var pumpToken = 0

    private func startPicture() {
        q.async { self.latest = [UInt8](repeating: 0, count: 1280 * 4 * 720) }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: .milliseconds(40), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume(); timer = t
        lastSnap = Date()
        viz?.web.evaluateJavaScript("room.ndi(true)", completionHandler: nil)
        pumpToken += 1; pump(pumpToken)
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self, self.on, Date().timeIntervalSince(self.lastSnap) > 1.5 else { return }
            NSLog("[Room] NDI snapshot loop stalled; restarting")
            self.lastSnap = Date(); self.pumpToken += 1; self.pump(self.pumpToken)
        }
    }
    private func stopPicture() {
        timer?.cancel(); timer = nil
        watchdog?.invalidate(); watchdog = nil
        pumpToken += 1
        viz?.web.evaluateJavaScript("room.ndi(false)", completionHandler: nil)
    }
    /// every 40 ms on q: the newest picture goes out, BGRX (alpha is always 255, so no alpha channel is promised)
    private func tick() {
        guard on, let s = sender, let f = fVideo else { return }
        let w = 1280, h = 720, stride = w * 4
        latest.withUnsafeMutableBytes { raw in
            var fr = NDIVideoFrame(xres: Int32(w), yres: Int32(h), FourCC: 0x5852_4742 /* BGRX */, frame_rate_N: 25, frame_rate_D: 1,
                                   picture_aspect_ratio: Float(w) / Float(h), frame_format_type: 1,
                                   timecode: Int64.max, p_data: raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                   line_stride_in_bytes: Int32(stride), p_metadata: nil, timestamp: 0)
            withUnsafePointer(to: &fr) { f(s, UnsafeRawPointer($0)) }
        }
    }
    /// polls the page for the newest JPEG of the canvas (grabbed in the page itself, see index.html grabNdi)
    private func pump(_ token: Int) {
        guard on, token == pumpToken, let web = viz?.web else { return }
        web.evaluateJavaScript("room.jpeg()") { [weak self] res, _ in
            guard let self = self, self.on, token == self.pumpToken else { return }
            self.lastSnap = Date()
            if let b64 = res as? String, !b64.isEmpty { self.store(b64) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { self.pump(token) }
        }
    }
    /// JPEG (1280x720 already, bars included) -> BGRX, kept as the newest picture; decoded off the main thread
    private func store(_ b64: String) {
        q.async { [weak self] in
            guard let self = self, self.on, let d = Data(base64Encoded: b64),
                  let src = CGImageSourceCreateWithData(d as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
            let w = 1280, h = 720, stride = w * 4
            var buf = [UInt8](repeating: 0, count: stride * h)
            buf.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: stride,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                else { return }
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            self.latest = buf
        }
    }

    // ---------------------------------------------------------------- the sound: what the first output plays, planar float, two channels
    func audio(_ buf: AVAudioPCMBuffer) {
        guard on, let ch = buf.floatChannelData else { return }
        let n = Int(buf.frameLength), c = Int(buf.format.channelCount), rate = Int32(buf.format.sampleRate)
        guard n > 0 else { return }
        var data = [Float](repeating: 0, count: n * 2)
        for i in 0..<n { data[i] = ch[0][i]; data[n + i] = c > 1 ? ch[1][i] : ch[0][i] }
        let g = gen
        q.async { [weak self] in
            guard let self = self, self.on, g == self.gen, let s = self.sender, let f = self.fAudio else { return }
            data.withUnsafeMutableBufferPointer { p in
                var fr = NDIAudioFrame(sample_rate: rate, no_channels: 2, no_samples: Int32(n), timecode: Int64.max,
                                       p_data: p.baseAddress, channel_stride_in_bytes: Int32(n * 4), p_metadata: nil, timestamp: 0)
                withUnsafePointer(to: &fr) { f(s, UnsafeRawPointer($0)) }
            }
        }
    }
}
