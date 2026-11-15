// Ndi.swift: the picture and the sound of the room as an NDI source "Meditation Room (Mantra)" on the network (Marko,
// 15.11.2026: "NDI HX output"). The NDI runtime that NDI Tools installs (libndi.dylib) is loaded with dlopen, as Sound Link
// does: no SDK file is in this public repository, nothing is linked. The calls and structs are the public NDI C ABI
// (NDIlib_send_create_t, NDIlib_video_frame_v2_t, NDIlib_audio_frame_v2_t).
// NOT HX: HX (H.264/HEVC) sending on the Mac needs the NDI Advanced SDK, which we do not hold for macOS. The installed
// runtime sends full NDI (SpeedHQ, I-frame video, about 100 Mbit/s at 1280 px, so Ethernet or a good Wi-Fi). Receivers
// (OBS, vMix, Sound Link) take it the same way.
import AppKit
import AVFoundation
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
    static let sourceName = "Meditation Room (Mantra)"
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
    private var pixels = [UInt8]()
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
            pump(gen)
        } else {
            on = false; gen += 1
            UserDefaults.standard.set(false, forKey: "ndi")
            let s = sender, d = fDestroy; sender = nil
            q.async { if let s = s { d?(s) } }
            NSLog("[Room] NDI source off")
        }
    }

    // ---------------------------------------------------------------- the picture: a snapshot of the visual, 25 per second at most
    private func pump(_ g: Int) {
        guard on, g == gen, let web = viz?.web else { return }
        let t0 = Date()
        let cfg = WKSnapshotConfiguration()
        cfg.snapshotWidth = 1280
        web.takeSnapshot(with: cfg) { [weak self] img, _ in
            guard let self = self, self.on, g == self.gen else { return }
            if let img = img { self.send(img) }
            let wait = max(0.001, 0.04 - Date().timeIntervalSince(t0))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self.pump(g) }
        }
    }
    private func send(_ img: NSImage) {
        var r = CGRect(origin: .zero, size: img.size)
        guard let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil) else { return }
        let w = cg.width & ~1, h = cg.height & ~1
        guard w > 0, h > 0 else { return }
        let stride = w * 4
        let bytes = Array(repeating: UInt8(0), count: stride * h)
        let g = gen
        q.async { [weak self] in
            guard let self = self, self.on, g == self.gen, let s = self.sender, let f = self.fVideo else { return }
            var buf = bytes
            buf.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: stride,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                else { return }
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                var fr = NDIVideoFrame(xres: Int32(w), yres: Int32(h), FourCC: 0x4152_4742 /* BGRA */, frame_rate_N: 25, frame_rate_D: 1,
                                       picture_aspect_ratio: Float(w) / Float(h), frame_format_type: 1,
                                       timecode: Int64.max, p_data: raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                       line_stride_in_bytes: Int32(stride), p_metadata: nil, timestamp: 0)
                withUnsafePointer(to: &fr) { f(s, UnsafeRawPointer($0)) }
            }
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
