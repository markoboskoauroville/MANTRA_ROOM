// Viz.swift: the visual engine. butterchurn (MilkDrop in WebGL 2, the same engine and presets as the Android app) runs
// in a WKWebView; the window and everything around it are Swift. Why not a Metal port: MilkDrop presets are programs
// (per-frame and per-pixel equations plus shaders written for MilkDrop); butterchurn already compiles all of them to
// WebGL, a native port would be months of work for the same picture. The page plays no sound: Swift drives it.
//
// The driver: 60 times a second Swift calls room.tick(l, r, gw, gh) with the last samples of the output, so the picture
// follows exactly what is heard (also into BlackHole). Every second tick (30 fps) it asks for the frame back at the
// keyboard's size and gives it to Lights. Driven from Swift, not by requestAnimationFrame, so it keeps running while the
// window is behind other windows (window occlusion detection is switched off too).
import AppKit
import WebKit

final class Viz: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var styleName = ""
    @Published var styleIndex = 0
    @Published var auto = true
    @Published var ready = false
    @Published var fps: Double = 0
    let web: WKWebView
    weak var player: Player?
    weak var lights: Lights?
    private var timer: Timer?
    private var inflight = false
    private var n = 0, cnt = 0, cntAt = Date()

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 540), configuration: cfg)
        super.init()
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        // keep rendering when the window is covered (private but long-standing WebKit switch; skipped if missing)
        let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if web.responds(to: sel) {
            typealias F = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(web.method(for: sel), to: F.self)(web, sel, false)
        }
        if let dir = Bundle.main.resourceURL?.appendingPathComponent("web") {
            web.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        }
    }

    func webView(_ w: WKWebView, didFinish _: WKNavigation!) {
        auto = UserDefaults.standard.object(forKey: "auto") as? Bool ?? true
        let saved = UserDefaults.standard.integer(forKey: "style")
        js("room.setAuto(\(auto)); room.style(\(saved), 0)") { [weak self] in self?.read($0) }
        ready = true
        Captions.shared.viz = self
        Captions.shared.apply()
        start()
    }

    func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    private func tick() {
        guard ready, !inflight, let p = player else { return }
        inflight = true
        n += 1
        let (l, r) = p.bytes()
        let want = (lights?.on ?? false) && n % 2 == 0
        let gw = want ? Lights.W : 0, gh = want ? Lights.H : 0
        web.evaluateJavaScript("room.tick('\(l)','\(r)',\(gw),\(gh))") { [weak self] res, _ in
            guard let s = self else { return }
            s.inflight = false
            s.cnt += 1
            let dt = Date().timeIntervalSince(s.cntAt)
            if dt >= 1 { s.fps = Double(s.cnt) / dt; s.cnt = 0; s.cntAt = Date() }
            if let hex = res as? String, !hex.isEmpty { s.lights?.frame(hex) }
        }
    }

    func run(_ code: String) { web.evaluateJavaScript(code, completionHandler: nil) }
    private func js(_ code: String, _ done: ((String) -> Void)? = nil) {
        web.evaluateJavaScript(code) { r, _ in if let s = r as? String { done?(s) } }
    }
    private func read(_ json: String) {
        guard let j = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
        styleName = j["name"] as? String ?? ""
        styleIndex = j["ix"] as? Int ?? 0
        auto = j["auto"] as? Bool ?? auto
        UserDefaults.standard.set(styleIndex, forKey: "style")
    }
    func next() { js("room.next()") { [weak self] in self?.read($0) } }
    func prev() { js("room.prev()") { [weak self] in self?.read($0) } }
    func style(_ i: Int) { js("room.style(\(i), 2)") { [weak self] in self?.read($0) } }
    func setAuto(_ on: Bool) {
        auto = on; UserDefaults.standard.set(on, forKey: "auto")
        js("room.setAuto(\(on))") { [weak self] in self?.read($0) }
    }
    /// the style name changes by itself under Auto: read it back now and then
    func refresh() { js("room.state()") { [weak self] in self?.read($0) } }
}
